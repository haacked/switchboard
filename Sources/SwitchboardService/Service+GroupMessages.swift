import Foundation
import SwitchboardCore

/// Group messages from inside Claude. sbd sends one only after the user
/// sends its card from the app or with `sb allow`.
extension Service {
  /// Opens a `send` card on the session that asked, and sends nothing.
  func openGroupMessage(from: String, group: String, text: String, targets: [GroupSend.Target]) throws -> GroupSend {
    guard entries[from] != nil else { throw APIError("no session \(from)") }
    let name = groups[group]?.name ?? group
    guard !targets.isEmpty else { throw APIError("\(name) has no session to send to") }
    let message = GroupMessage(
      group: group, groupName: name, text: text, targets: targets,
      expires: nowMs() + GroupMessage.expirySeconds * 1000)
    let event = record(from, "send_pending", try JSON(encoding: message))
    return GroupSend(message, pending: event.id, decision: .pending)
  }

  /// Sends a `send` card's message to the sessions that the card lists, or
  /// cancels it. The user approved those sessions, so a session that joined
  /// the group since gets nothing. A card past its expiry records that it
  /// expired and refuses.
  func decideGroupMessage(_ card: Card, _ message: GroupMessage, send: Bool) throws -> JSON {
    guard nowMs() < message.expires else {
      record(card.session, "send_decided", decision(card, .expired))
      throw APIError("the message to \(message.groupName) expired, so nothing was sent")
    }
    let deliveries = send ? deliver(message.text, to: message.targets.map(\.id)) : nil
    let result = GroupSend(message, pending: card.id, decision: send ? .sent : .cancelled, deliveries: deliveries)
    record(card.session, "send_decided", decision(card, result.decision!, deliveries))
    return try JSON(encoding: result)
  }

  /// Whether `answer` with these arguments answers a `send` card.
  func answersGroupMessage(_ args: JSON) -> Bool {
    (try? chosenCard(args))?.kind == .send
  }

  /// The group message that the card id names: pending while its card is
  /// open, else the decision that closed it.
  func groupMessageStatus(_ args: JSON) throws -> GroupSend {
    guard let id = args["card"]?.int.map(Int64.init) else { throw APIError("name a group message by its id") }
    if let m = entries.values.lazy.flatMap(\.facts.cards).first(where: { $0.id == id })?.send {
      return GroupSend(m, pending: id, decision: .pending)
    }
    guard let opened = try store.event(id: id), opened.kind == "send_pending",
      let m = Card(groupMessage: opened)?.send,
      let decided = try store.decision(card: id, session: opened.session),
      let decision = decided.data["decision"]?.string.flatMap(SendDecision.init(rawValue:))
    else { throw APIError("no group message \(id)") }
    let deliveries = try decided.data["deliveries"].map { try JSONCoding.convert($0, to: [GroupSend.Result].self) }
    return GroupSend(m, pending: id, decision: decision, deliveries: deliveries)
  }

  /// Records `expired` for each group message whose time ran out.
  func expireGroupMessages(now: Int64) {
    let due = entries.values.flatMap(\.facts.cards).filter { $0.send.map { now >= $0.expires } == true }
    for card in due { record(card.session, "send_decided", decision(card, .expired)) }
  }

  private func decision(_ card: Card, _ decision: SendDecision, _ deliveries: [GroupSend.Result]? = nil) -> JSON {
    var data: [String: JSON] = ["card": .number(Double(card.id)), "decision": .string(decision.rawValue)]
    if let deliveries { data["deliveries"] = try? JSON(encoding: deliveries) }
    return .object(data)
  }
}
