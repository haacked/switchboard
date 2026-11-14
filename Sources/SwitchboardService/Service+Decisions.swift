import Foundation
import SwitchboardCore

extension Service {
  func decisionRequest(_ op: String, _ args: JSON) throws -> Response {
    switch op {
    case "decision-submit":
      return submitDecisions(args)
    case "decision-resend":
      return resendDecisions(args)
    case "decision-answer":
      return .success(try queue.sync { try answerDecision(args) })
    case "decision-discard":
      return .success(
        try queue.sync {
          let id = try lookup(args)
          guard entries[id]!.facts.decisionList != nil else { throw noOpenList(summary(id)) }
          try refuseWhileSubmitting(id)
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

  /// Refuses a change to the list while its submit sends it, so the message
  /// that goes out is the list that sbd closes.
  private func refuseWhileSubmitting(_ id: String) throws {
    guard !submittingDecisions.contains(id) else {
      throw APIError("\(entries[id]!.session.name) is sending these decisions")
    }
  }

  /// Records an answer to a decision of the stored list. The first answer
  /// opens the list from the current item. Nothing is recorded unless the
  /// answer names a decision and an option that the list has. The caller's
  /// `ref` names the list that the user saw, so an answer never lands in
  /// another list.
  private func answerDecision(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    try refuseWhileSubmitting(id)
    let list = try decisionList(id)
    if let ref = args["ref"]?.string, ref != list.ref {
      throw APIError("\(entries[id]!.session.name) has a new item since you looked. Look again")
    }
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
    let id: String
    let ref: String
    let message: String
    do {
      (id, ref, message) = try queue.sync {
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
        try refuseWhileSubmitting(id)
        submittingDecisions.insert(id)
        return (id, list.ref, message)
      }
    } catch {
      return .failure("\(error)")
    }
    return sendDecisions(id, message) { delivery in
      guard entries[id]?.facts.decisionList != nil else { return }
      try recordStored(
        id, "decisions_submitted",
        ["message": .string(message), "ref": .string(ref), "delivery": .string(delivery.rawValue)])
    }
  }

  /// Sends the last submit's message once more, only while sbd can't tell
  /// whether the session got it.
  private func resendDecisions(_ args: JSON) -> Response {
    let id: String
    let message: String
    do {
      (id, message) = try queue.sync {
        let id = try lookup(args)
        let name = entries[id]!.session.name
        let facts = entries[id]!.facts
        switch (facts.decisionsDelivery, facts.submittedDecisionsMessage) {
        case (.unknown, let message?):
          guard summary(id).decisionsSent == true else {
            throw APIError("nothing to resend: \(name) has moved past those decisions")
          }
          try refuseWhileSubmitting(id)
          submittingDecisions.insert(id)
          return (id, message)
        case (.sending, _): throw APIError("nothing to resend: sbd is still sending your answers to \(name)")
        case (.delivered, _): throw APIError("nothing to resend: \(name) got your answers")
        default: throw APIError("nothing to resend: \(name) has no submitted answers")
        }
      }
    } catch {
      return .failure("\(error)")
    }
    return sendDecisions(id, message) { _ in }
  }

  /// Sends a decisions message as `send` does, and runs `alongside` in the
  /// same block of the state queue and the same store transaction as the
  /// send. No other request comes between the send's `sent` event and what
  /// `alongside` records, and the log keeps both or neither. A stopped claude starts
  /// without the message as its prompt, so nothing reaches claude before the
  /// transaction commits. The session leaves `submittingDecisions` in that
  /// block too.
  private func sendDecisions(_ id: String, _ message: String, alongside: (Delivery) throws -> Void) -> Response {
    let request = Request(op: "send", args: ["session": .string(id), "text": .string(message)])
    do {
      return .success(
        try prepared(request, origin: .mac) {
          defer { submittingDecisions.remove(id) }
          let before = entries[id]
          do {
            return try store.transaction {
              let delivery = try send(id, message, launchesWithPrompt: false, trigger: .decision)
              try alongside(delivery)
              return ["delivery": .string(delivery.rawValue)]
            }
          } catch {
            // The log kept none of the writes, so the session's state goes back to match it.
            // A paste that the send started finds no `sent` event, and drops the message.
            entries[id] = before
            throw error
          }
        })
    } catch {
      return .failure("\(error)")
    }
  }
}
