import Foundation
import SwitchboardCore

extension Service {
  func decisionRequest(_ op: String, _ args: JSON) throws -> Response {
    switch op {
    case "decision-submit":
      return submitDecisions(args)
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
    if let open = s.decisions { return open }
    if s.decisionsSent == true { throw noOpenList(s) }
    guard let item = s.triage, item.decisions.count > 1 else {
      let count = s.triage?.decisions.count ?? 0
      throw APIError(
        "\(s.name) has \(count == 0 ? "no decisions" : "one decision") to answer. sb decide needs two or more")
    }
    return DecisionList(decisions: item.decisions, ref: item.ref)
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
    let keys = args["options"]?.array
    let skip = args["skip"]?.bool == true
    guard [keys != nil, args["text"] != nil, skip].filter({ $0 }).count == 1 else {
      throw APIError("answer decision \(number) with options, text, or skip")
    }
    var answer: [String: JSON] = ["number": .number(Double(number))]
    if let keys {
      answer["labels"] = .array(try decision.labels(keys.map { $0.string ?? "" }).map(JSON.string))
    } else if skip {
      answer["skip"] = true
    } else {
      let text = args["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { throw APIError("the answer to decision \(number) is empty") }
      answer["text"] = .string(text)
    }
    if entries[id]!.facts.decisionList == nil {
      record(
        id, "decisions_opened",
        [
          "decisions": try JSON(encoding: list.decisions), "ref": .string(list.ref),
          "lastStop": .number(Double(entries[id]!.facts.lastStop)),
        ])
    }
    record(id, "decision_answered", .object(answer))
    return try JSON(encoding: decisionList(id))
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
    let response = handle(Request(op: "send", args: ["session": .string(id), "text": .string(message)]))
    queue.sync {
      submittingDecisions.remove(id)
      if response.ok, entries[id]?.facts.decisionList != nil {
        record(id, "decisions_submitted", ["message": .string(message), "ref": .string(ref)])
      }
    }
    return response
  }
}
