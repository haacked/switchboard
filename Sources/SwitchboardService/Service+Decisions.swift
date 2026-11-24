import Foundation
import SwitchboardCore

extension Service {
  func decisionRequest(_ op: String, _ args: JSON) throws -> Response {
    switch op {
    case "decision-submit":
      return submitDecisions(args)
    case "decision-resend":
      return resendDecisions(args)
    case "decision-ask":
      return askDecision(args)
    case "decision-answer":
      return .success(try queue.sync { try answerDecision(args) })
    case "decision-discard":
      return .success(
        try queue.sync {
          let id = try lookup(args)
          guard entries[id]!.facts.decisionList != nil else { throw noOpenList(summary(id)) }
          try refuseListChange(id)
          record(id, "decisions_discarded")
          return ["session": .string(id)]
        })
    default:
      return .success(try queue.sync { try JSON(encoding: decisionList(try lookup(args))) })
    }
  }

  /// The open list, or the one that the first answer opens from the
  /// session's current item. Decisions that a submit already sent don't open
  /// again.
  private func decisionList(_ id: String) throws -> DecisionList {
    let s = summary(id)
    if let list = s.shownDecisions { return list }
    if s.decisionsSent == true { throw noOpenList(s) }
    let count = s.triage?.decisions.count ?? 0
    throw APIError(
      "\(s.name) has \(count == 0 ? "no decisions" : "one decision") to answer. sb decide needs two or more")
  }

  private func noOpenList(_ s: SessionSummary) -> APIError {
    APIError(
      s.decisionsSent == true
        ? "\(s.name) already got your answers to these decisions" : "\(s.name) has no open decision list")
  }

  /// Refuses a change to the list while sbd sends a message about it, so the message that goes out is the list that
  /// sbd closes. It refuses while a question about one of its decisions is pending too, because the reply can change
  /// the user's answers.
  private func refuseListChange(_ id: String) throws {
    guard !sendingAboutDecisions.contains(id) else { throw sendingDecisions(id) }
    if let reason = entries[id]!.facts.decisionList?.pendingAskReason { throw APIError(reason) }
  }

  private func sendingDecisions(_ id: String) -> APIError {
    APIError("\(entries[id]!.session.name) is still sending your last message about these decisions")
  }

  /// Refuses a request whose `ref` names a list other than `list`, the one that the session shows now.
  private func refuseNewItem(_ id: String, ref: String?, _ list: DecisionList) throws {
    guard ref == list.ref else {
      throw APIError("\(entries[id]!.session.name) has a new item since you looked. Look again")
    }
  }

  /// Records an answer to a decision of the stored list. The first answer
  /// opens the list from the current item. Nothing is recorded unless the
  /// answer names a decision and an option that the list has. The caller's
  /// `ref` names the list that the user saw, so an answer never lands in
  /// another list.
  private func answerDecision(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    try refuseListChange(id)
    let list = try decisionList(id)
    if let ref = args["ref"]?.string { try refuseNewItem(id, ref: ref, list) }
    let numbers = englishList(list.decisions.map { String($0.number) })
    guard let number = args["number"]?.int, let decision = list.decisions.first(where: { $0.number == number }) else {
      throw APIError("name a decision by its number: \(numbers)")
    }
    let text = args["text"].map { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    if text?.isEmpty == true { throw APIError("the answer to decision \(number) is empty") }
    let answer = DecisionAnswer(
      number: number, labels: try args["options"]?.array.map { try decision.labels($0.map { $0.string ?? "" }) },
      text: text, skip: args["skip"]?.bool == true ? true : nil)
    guard answer.isValid else { throw APIError("answer decision \(number) with options, text, or skip") }
    if entries[id]!.facts.decisionList == nil {
      record(id, "decisions_opened", ["decisions": try JSON(encoding: list.decisions), "ref": .string(list.ref)])
    }
    record(id, "decision_answered", try JSON(encoding: answer))
    // An answer changes neither the verdict nor the live item.
    // The list's newer decisions stay as they were.
    var answered = entries[id]!.facts.decisionList!
    answered.newer = list.newer
    return try JSON(encoding: answered)
  }

  /// Sends the message that answers every decision, as `send` does, and
  /// closes the list only when the send succeeds. A list that a turn made
  /// stale needs `stale: true`.
  private func submitDecisions(_ args: JSON) -> Response {
    sendDecisions(by: .you) {
      let id = try lookup(args)
      let name = entries[id]!.session.name
      guard let list = entries[id]!.facts.decisionList else { throw noOpenList(summary(id)) }
      guard let message = list.message else {
        let open = list.unanswered
        throw APIError(
          "decision\(open.count == 1 ? "" : "s") \(englishList(open.map(String.init))) of \(name) "
            + "\(open.count == 1 ? "has" : "have") no answer. Answer or skip each one")
      }
      if list.stale, args["stale"]?.bool != true {
        throw APIError("\(name) took a turn since these decisions. Submit with --stale to send them anyway")
      }
      try refuseListChange(id)
      return (id, message)
    } body: { id, message, send in
      let delivery = try send()
      if let list = entries[id]?.facts.decisionList {
        try recordStored(
          id, "decisions_submitted",
          ["message": .string(message), "ref": .string(list.ref), "delivery": .string(delivery.rawValue)])
      }
      return ["delivery": .string(delivery.rawValue)]
    }
  }

  /// Sends the last submit's message once more, only while sbd can't tell
  /// whether the session got it.
  private func resendDecisions(_ args: JSON) -> Response {
    sendDecisions(by: .you) {
      let id = try lookup(args)
      let name = entries[id]!.session.name
      let facts = entries[id]!.facts
      switch (facts.decisionsDelivery, facts.submittedDecisionsMessage) {
      case (.unknown, let message?):
        guard summary(id).decisionsSent == true else {
          throw APIError("nothing to resend: \(name) has moved past those decisions")
        }
        return (id, message)
      case (.sending, _): throw APIError("nothing to resend: sbd is still sending your answers to \(name)")
      case (.delivered, _): throw APIError("nothing to resend: \(name) got your answers")
      default: throw APIError("nothing to resend: \(name) has no submitted answers")
      }
    } body: { _, _, send in
      ["delivery": .string(try send().rawValue)]
    }
  }

  /// Sends the session a question about one decision of the list that the user saw, as `sendDecisions` sends,
  /// and returns the ask's id. The first ask opens the list, because the question's prompt drops the item that
  /// the list would otherwise come from. `decision_asked` saves the verdict and the item from before the
  /// send, so the clarifying turn changes neither.
  private func askDecision(_ args: JSON) -> Response {
    sendDecisions(by: .sbd) {
      let id = try lookup(args)
      return (id, try askable(id, args).message)
    } body: { id, _, send in
      // The session can take a turn while `prepared` reads the processes, so the checks run again here.
      let (list, decision, text, message) = try askable(id, args)
      let e = entries[id]!
      let askId = shortId("q", taken: list.exchanges.map(\.askId))
      let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
      guard let item = Triage.item(e.facts, verdict, kind: e.session.kind) else {
        throw APIError("\(e.session.name) shows no item to ask about")
      }
      if e.facts.decisionList == nil {
        try recordStored(
          id, "decisions_opened", ["decisions": try JSON(encoding: list.decisions), "ref": .string(list.ref)])
      }
      let ask = DecisionAsk(
        ref: list.ref, number: decision.number, askId: askId, text: text, message: message,
        verdict: .init(state: e.facts.lastState ?? verdict.state, reason: verdict.reason), item: item)
      try recordStored(id, "decision_asked", try JSON(encoding: ask))
      _ = try send()
      return ["askId": .string(askId)]
    }
  }

  /// The list, the decision, the trimmed question, and the message for an ask that sbd takes now. It throws the
  /// reason that sbd refuses the ask.
  private func askable(_ id: String, _ args: JSON) throws -> (
    list: DecisionList, decision: PendingDecision, text: String, message: String
  ) {
    let e = entries[id]!
    let name = e.session.name
    let list = try decisionList(id)
    try refuseNewItem(id, ref: args["ref"]?.string, list)
    if list.stale {
      throw APIError("\(name) took a turn since these decisions. Send your question as a message instead")
    }
    guard let number = args["number"]?.int, let decision = list.decisions.first(where: { $0.number == number }) else {
      throw APIError("name a decision by its number: \(englishList(list.decisions.map { String($0.number) }))")
    }
    let text = args["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.isEmpty { throw APIError("the question about decision \(number) is empty") }
    if let pending = e.facts.clarifying {
      throw APIError("\(name) is still answering your question about decision \(pending.number)")
    }
    if !e.facts.cards.isEmpty { throw APIError("\(name) waits on a card. Answer it before you ask") }
    if Pause.blocker(e.session) != nil { throw APIError("Resume \(name) first") }
    // `turnRuns` leaves out a pending message for a stopped claude.
    if turnRuns(e) || !e.pending.isEmpty {
      throw APIError("\(name) is working; ask when it stops")
    }
    return (list, decision, text, DecisionAsk.message(about: decision, text))
  }

  /// Runs `check` and claims the session's send in one block of the state queue. `check` returns the session and
  /// the message, or throws the reason that sbd refuses the request. The session stays in `sendingAboutDecisions`
  /// from that block until the send ends, so no change to the list comes between the check and the send.
  ///
  /// Then it runs `body` in one block of the state queue and one store transaction. `body` calls the function that
  /// it gets to send the message as `send` does, and records what goes with the send, before or after it. No other
  /// request comes between those events, and the log keeps all of them or none. A stopped claude starts without
  /// the message as its prompt, so nothing reaches claude before the transaction commits. The response is what
  /// `body` returns.
  private func sendDecisions(
    by: MessageAuthor, _ check: () throws -> (id: String, message: String),
    body: (_ id: String, _ message: String, _ send: () throws -> Delivery) throws -> JSON
  ) -> Response {
    let id: String
    let message: String
    do {
      (id, message) = try queue.sync {
        let checked = try check()
        guard sendingAboutDecisions.insert(checked.id).inserted else { throw sendingDecisions(checked.id) }
        return checked
      }
    } catch {
      return .failure("\(error)")
    }
    let request = Request(op: "send", args: ["session": .string(id), "text": .string(message)])
    do {
      return .success(
        try prepared(request, origin: .mac) {
          let before = entries[id]
          do {
            let result = try store.transaction {
              try body(id, message) { try send(id, message, by: by, launchesWithPrompt: false, trigger: .decision) }
            }
            sendingAboutDecisions.remove(id)
            return result
          } catch {
            // The log kept none of the writes, so the session's state goes back to match it.
            // A paste that the send started finds no `sent` event, and drops the message.
            entries[id] = before
            throw error
          }
        })
    } catch {
      // `prepared` can refuse before the block runs, as for a session that is being deleted.
      queue.sync { _ = sendingAboutDecisions.remove(id) }
      return .failure("\(error)")
    }
  }
}
