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

  /// Answers a card: allow, deny with an optional message, or `answers`, one
  /// per question. A held card answers through its hook. A deferred question
  /// answers with a message to the session.
  func answer(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    let card = try Card.choose(args["card"]?.int, from: entries[id]?.facts.cards ?? [], session: id)
    var data: [String: JSON] = ["card": .number(Double(card.id)), "behavior": "allow"]
    let delivery: String
    if let given = args["answers"]?.array {
      guard card.kind == .question else { throw APIError("card \(card.id) is a permission prompt. Allow or deny it") }
      let answers = try card.match(given.map { $0.string ?? "" })
      data["answers"] = .array(answers.map(JSON.string))
      if card.deferred {
        delivery = try send(id, card.answerMessage(answers), byUser: false).rawValue
      } else {
        delivery = try answerHook(card, card.decision(answers: answers))
      }
    } else {
      let message = args["message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      switch args["behavior"]?.string {
      case "allow" where card.kind == .permission:
        delivery = try answerHook(card, .allow(updatedInput: nil))
      case "allow":
        throw APIError("card \(card.id) is a question. Answer it")
      case "deny":
        data["behavior"] = "deny"
        data["message"] = message.map(JSON.string)
        delivery = try answerHook(card, .deny(message: message))
      default:
        throw APIError("answer needs answers, or a behavior of allow or deny")
      }
    }
    record(id, "answered", .object(data))
    return ["card": .number(Double(card.id)), "session": .string(id), "delivery": .string(delivery)]
  }

  /// Answers a held card through its hook. The hook's thread notices a closed
  /// request only every 0.25 s, so this checks again first.
  private func answerHook(_ card: Card, _ decision: Decision) throws -> String {
    guard let request = held[card.id], !request.hookGone() else {
      throw APIError(
        card.deferred
          ? "card \(card.id) was deferred, so answer its questions or send \(card.session) a message"
          : "Claude Code no longer waits on card \(card.id). Answer it in the terminal")
    }
    request.resolve(decision.hookOutput)
    return "hook"
  }

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
