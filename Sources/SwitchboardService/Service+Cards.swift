import Foundation
import SwitchboardCore

/// A PermissionRequest hook that sbd holds open until its card gets an
/// answer. Its `sb hook` process waits on sbd's socket the whole time.
final class HeldRequest {
  let session: String
  /// Reports whether Claude Code closed the request, which ends the hook.
  let hookGone: () -> Bool
  /// What the hook prints. Only sbd's state queue sets it.
  private(set) var reply: JSON?
  private let answered = DispatchSemaphore(value: 0)

  init(session: String, hookGone: @escaping () -> Bool) {
    self.session = session
    self.hookGone = hookGone
  }

  /// Sets the reply once. A later call changes nothing.
  func resolve(_ reply: JSON) {
    guard self.reply == nil else { return }
    self.reply = reply
    answered.signal()
  }

  /// Waits until the request has a reply or Claude Code closed it.
  func wait() {
    while answered.wait(timeout: .now() + 0.25) == .timedOut, !hookGone() {}
  }
}

extension Service {
  /// Records a hook event. When the event opened a card, it holds the hook
  /// off the state queue until the card gets an answer. When the hook goes
  /// away first, it records `card_closed`. No or Escape in the terminal ends
  /// the hook.
  func handleHook(_ args: JSON, hookGone: @escaping () -> Bool) throws -> Response {
    let opened: (card: Int64, request: HeldRequest)? = try queue.sync {
      guard let event = try hook(args),
        entries[event.session]?.facts.cards.contains(where: { $0.id == event.id }) == true
      else { return nil }
      let request = HeldRequest(session: event.session, hookGone: hookGone)
      held[event.id] = request
      return (event.id, request)
    }
    guard let (card, request) = opened else { return .success([:]) }
    request.wait()
    return .success(
      queue.sync {
        if let reply = request.reply { return reply }
        held[card] = nil
        if entries[request.session] != nil {
          record(request.session, "card_closed", ["card": .number(Double(card))])
        }
        return [:]
      })
  }

  /// Drops the session's held requests whose card is gone or deferred. A
  /// request that has no reply yet gets an empty body, which Claude Code
  /// reads as no decision.
  func releaseCards(_ id: String) {
    guard !held.isEmpty else { return }
    let open = Set(entries[id]?.facts.cards.filter { !$0.deferred }.map(\.id) ?? [])
    for (card, request) in held where request.session == id && !open.contains(card) {
      request.resolve([:])
      held[card] = nil
    }
  }

  /// The card that `args` names: its `card` id, or the session's only card.
  func chosenCard(_ args: JSON) throws -> Card {
    let id = try lookup(args)
    return try Card.choose(args["card"]?.int, from: entries[id]?.facts.cards ?? [], session: id)
  }

  /// Answers a card: allow, deny with an optional message, or `answers`, one
  /// per question. A held card answers through its hook. A deferred question
  /// answers with a message to the session. A card whose hook closed answers
  /// by typing into the terminal. An allow with `autoMode` also switches the
  /// session to auto mode, which only a held card's hook can do.
  func answer(_ args: JSON) throws -> JSON {
    let card = try chosenCard(args)
    let id = card.session
    if let message = card.send {
      switch args["behavior"]?.string {
      case "allow": return try decideGroupMessage(card, message, send: true)
      case "deny": return try decideGroupMessage(card, message, send: false)
      default: throw APIError("card \(card.id) is a group message. Send it with allow, or cancel it with deny")
      }
    }
    var data: [String: JSON] = ["card": .number(Double(card.id)), "behavior": "allow"]
    func answered(_ delivery: String) -> JSON {
      record(id, "answered", .object(data))
      return ["card": .number(Double(card.id)), "session": .string(id), "delivery": .string(delivery)]
    }
    // What the hook prints, and what sbd types when Claude Code no longer
    // waits on the hook.
    let reply: (decision: Decision, typed: TypedAnswer)
    let autoMode = args["autoMode"]?.bool == true
    if let given = args["answers"]?.array {
      guard card.kind == .question else { throw APIError("card \(card.id) is a permission prompt. Allow or deny it") }
      let answers = try card.match(given.map { $0.string ?? "" })
      data["answers"] = .array(answers.map(JSON.string))
      if card.deferred { return answered(try send(id, card.answerMessage(answers), byUser: false).rawValue) }
      reply = (card.decision(answers: answers), .escape(then: card.answerMessage(answers)))
    } else {
      let message = args["message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      switch args["behavior"]?.string {
      case "allow" where card.kind == .permission:
        if autoMode {
          if let refusal = card.autoModeRefusal { throw autoModeRefused(refusal) }
          data["permission_mode"] = .string(PermissionMode.auto)
        }
        reply = (.allow(updatedInput: nil, autoMode: autoMode), .yes)
      case "allow":
        throw APIError("card \(card.id) is a question. Answer it")
      case "deny":
        data["behavior"] = "deny"
        data["message"] = message.map(JSON.string)
        reply = (.deny(message: message), .escape(then: message))
      default:
        throw APIError("answer needs answers, or a behavior of allow or deny")
      }
    }
    // The hook's thread notices a closed request only every 0.25 s, so this
    // checks again first.
    if let request = held[card.id], !request.hookGone() {
      request.resolve(reply.decision.hookOutput)
      if autoMode { try update(id) { $0.autoMode = true } }
      return answered("hook")
    }
    // The hook can close after the check above.
    guard !autoMode else { throw autoModeRefused(card.hookClosedRefusal) }
    guard !card.deferred else {
      throw APIError("card \(card.id) was deferred, so answer its questions or send \(card.session) a message")
    }
    try type(reply.typed, card)
    switch reply.typed {
    case .yes:
      return answered("terminal")
    case .escape(let message):
      data["interrupted"] = true
      let result = answered("terminal")
      // The Escape ended the turn, so the message pastes once the dialog closes.
      if let message {
        guard dialogClosed(card) else {
          throw APIError(
            "card \(card.id)'s dialog still shows after Escape, so sbd didn't send the message. Answer it in the terminal"
          )
        }
        _ = try send(id, message, byUser: false)
      }
      return result
    }
  }

  private func autoModeRefused(_ reason: String) -> APIError { APIError("\(reason). Allow it without auto mode") }

  /// Defers each held question that has been open for `idleStopSeconds`,
  /// unless a terminal shows its session. The stop rule then leaves claude
  /// running, so a deferral would only close the dialog the user reads.
  func deferDueQuestions(now: Int64) {
    let wait = Int64(config.idleStopSeconds) * 1000
    for (card, request) in heldQuestions() where now - card.since >= wait && !attached(card.session) {
      deferQuestion(card, request)
    }
  }

  /// Whether a terminal shows the session's Claude pane.
  func attached(_ id: String) -> Bool {
    (snapshot.panes[paneName(id, .claude)]?.clients ?? 0) > 0
  }

  /// Defers the session's held questions at once, so that its claude can
  /// stop without losing them.
  func deferQuestions(_ id: String) {
    for (card, request) in heldQuestions() where card.session == id {
      deferQuestion(card, request)
    }
  }

  private func heldQuestions() -> [(Card, HeldRequest)] {
    held.compactMap { number, request in
      entries[request.session]?.facts.cards.first { $0.id == number && $0.kind == .question }.map { ($0, request) }
    }
  }

  /// Denies the question's held request with a message that tells Claude to
  /// end its turn. The card stays, and its answer resumes the session.
  private func deferQuestion(_ card: Card, _ request: HeldRequest) {
    request.resolve(Decision.deny(message: Card.deferMessage).hookOutput)
    record(card.session, "deferred", ["card": .number(Double(card.id))])
  }
}
