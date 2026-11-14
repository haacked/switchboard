import Foundation

/// The arguments of the `wait` request, as sb sends them. Every field is text,
/// so that a bad value gets an error that names it.
public struct WaitRequest: Codable, Equatable, Sendable {
  public var kind: String?
  /// A PR for the PR kinds, or a session for `session`.
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
  public var then: String?
  public var by: String?

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
      by: try Author(parsing: by), created: now, then: kind == .manual ? .notify : .resume)
    if let then {
      guard let value = Wait.Then(rawValue: then) else { throw APIError("then is resume or notify, not \(then)") }
      wait.then = value
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
