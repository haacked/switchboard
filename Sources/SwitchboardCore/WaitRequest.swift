import Foundation

/// The arguments of the `wait` request, as sb sends them. Every field is text,
/// so that a bad value gets an error that names it.
public struct WaitRequest: Codable, Equatable, Sendable {
  public var kind: String?
  /// A PR for the PR kinds, a session for `session`, or a Slack message link for `reply`.
  public var target: String?
  public var who: String?
  public var environment: String?
  public var service: String?
  public var state: String?
  public var until: String?
  /// For a `review`, `bot-review`, or `queue` wait, the time after which a
  /// review or a queue change counts.
  public var since: String?
  public var note: String?
  /// `resume`, `notify`, or the name of a `WaitAction.Kind`, which arms that action and resumes.
  public var then: String?
  public var by: String?
  /// For `then` `report`, makes the report an Inbox item.
  public var needsYou: Bool?

  /// The action that `then` arms, or nil when `then` names none.
  public var actionKind: WaitAction.Kind? { then.flatMap(WaitAction.Kind.init(rawValue:)) }

  /// The refusal of a `then` that names nothing that a wait does.
  public static func unknownThen(_ text: String) -> APIError {
    let actions = WaitAction.Kind.allCases.map(\.rawValue)
    return APIError(
      "then is resume or notify, or an action (\(actions.dropLast().joined(separator: ", ")), or \(actions.last!)), "
        + "not \(text)")
  }

  /// Checks the arguments against the kind and builds the wait. The kind
  /// defaults to `manual`. A field that the kind doesn't use is refused.
  /// `waiter` is the id of the session that waits, which a `session` wait
  /// can't target. `findSession` looks up a session by id, prefix, or name.
  public func makeWait(id: String, waiter: String, now: Int64, findSession: (String) throws -> Wait.SessionTarget)
    throws -> Wait
  {
    let kind = try oneOf("wait kind", self.kind ?? Wait.Kind.manual.rawValue, Wait.Kind.allCases, \.rawValue)
    let given = [
      ("target", target), ("who", who), ("environment", environment), ("service", service), ("state", state),
      ("until", until), ("since", since),
    ]
    if let (field, _) = given.first(where: { $0.1 != nil && !kind.fields.contains($0.0) }) {
      throw APIError("a \(kind.rawValue) wait doesn't take \(field)")
    }
    let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    var wait = Wait(
      id: id, kind: kind, who: who, service: service, note: trimmed?.isEmpty == false ? trimmed : nil,
      by: try Author(parsing: by), created: now, then: kind.defaultThen)
    if let then {
      if let value = Wait.Then(rawValue: then) {
        wait.then = value
      } else if let action = WaitAction.Kind(rawValue: then) {
        wait.action = WaitAction(kind: action, needsYou: needsYou == true ? true : nil)
        wait.then = .resume
      } else {
        throw Self.unknownThen(then)
      }
    }
    if needsYou == true && wait.action?.kind != .report {
      throw APIError("needsYou makes a report an Inbox item, so it goes only with then report")
    }
    if wait.action?.kind == .report && wait.note == nil {
      throw APIError("then report records the note as the report, so it needs a note")
    }
    if let since {
      guard let time = Wait.parseTime(since, now: now) else { throw APIError("can't read the time \(since)") }
      guard time <= now else { throw APIError("since \(since) hasn't come yet") }
      wait.since = time
    }
    switch kind {
    case .session:
      guard let target else { throw APIError("a session wait needs the other session as its target") }
      let other = try findSession(target)
      guard other.id != waiter else { throw APIError("a session can't wait on itself") }
      wait.session = other
      wait.state = try oneOf("state", state ?? AttentionState.done.rawValue, AttentionState.allCases, \.rawValue)
    case .reply:
      guard let target else { throw APIError("a reply wait needs a Slack message link as its target") }
      wait.url = try? ExternalLink.cleanURL(target)
      guard wait.replyThread != nil else { throw APIError("\(target) isn't a Slack message link") }
    case .date, .manual:
      if let until {
        guard let time = Wait.parseTime(until, now: now) else { throw APIError("can't read the time \(until)") }
        guard time > now else { throw APIError("\(until) has passed") }
        wait.until = time
      } else if kind == .date {
        throw APIError("a date wait needs until")
      }
    default:
      if let target {
        guard let pr = Wait.PullRequest(parsing: target) else { throw APIError("\(target) isn't a PR") }
        wait.pr = pr
      }
      if kind == .review && who == nil { throw APIError("a review wait needs who, the reviewer") }
      if kind == .deploy {
        wait.environment = try oneOf("environment", environment ?? "prod", Wait.environments) { $0 }
      }
    }
    try wait.action?.requireShape(of: wait)
    return wait
  }

  /// The value whose name is `text`, or an error that lists the names.
  private func oneOf<T>(_ what: String, _ text: String, _ values: [T], _ name: (T) -> String) throws -> T {
    guard let value = values.first(where: { name($0) == text }) else {
      throw APIError("no \(what) \(text). Use one of: \(values.map(name).joined(separator: ", "))")
    }
    return value
  }
}

/// Whether sbd stores `wait` on the operator instead of `namedSession`, the session that the request named.
/// It does when the wait resolves the same way there and only the recipient of the message changes:
/// the named session is a Manager conversation, Claude set the wait and it resumes or the wait has an action, `here`
/// is not set, its resolution reads nothing of the waiter, and it is not a `session` wait on the operator, whose id
/// is `operatorID`.
public func handsOff(_ wait: Wait, namedSession: Session, here: Bool, operatorID: String?) -> Bool {
  let fromConversation = namedSession.kind == .manager && !here
  let claudeResumeWait = wait.by == .claude && wait.then == .resume
  let resolvesTheSameOnOperator = !wait.readsWaiter && (wait.session.map { $0.id != operatorID } ?? true)
  return fromConversation && (claudeResumeWait || wait.action != nil) && resolvesTheSameOnOperator
}
