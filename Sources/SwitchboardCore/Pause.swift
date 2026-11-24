import Foundation

/// Who paused a session, why, and what resumes it. While a session has one, sbd starts no claude for it and
/// pastes nothing into it. Every message waits in its queue until the resume.
public struct Pause: Codable, Equatable, Sendable {
  /// The session that paused another, as it was at the pause, so that the label outlives it.
  public struct Pauser: Codable, Equatable, Sendable {
    public var id: String
    /// The session's name. For a group chat, it is the group's name.
    public var name: String
    public var kind: SessionKind

    public init(id: String, name: String, kind: SessionKind) {
      self.id = id
      self.name = name
      self.kind = kind
    }
  }

  public var by: Author
  /// The session whose Claude paused this one, or nil when the user paused it or sbd doesn't know the session.
  public var from: Pauser?
  public var reason: String?
  /// When the session was first paused, in ms since the epoch. A second pause keeps it.
  public var since: Int64
  /// The condition that resumes the session on its own.
  public var until: Wait?
  /// The message that the resume sends, verbatim, unless the resume names its own.
  public var message: String?

  /// The longest reason, in characters.
  public static let reasonLimit = 280

  public init(
    by: Author, from: Pauser? = nil, reason: String? = nil, since: Int64, until: Wait? = nil, message: String? = nil
  ) {
    self.by = by
    self.from = from
    self.reason = reason
    self.since = since
    self.until = until
    self.message = message
  }

  /// "you", "Manager", "Operator", "the <group> chat", a work session's name, or "Claude" when no session is known.
  public var byText: String {
    guard by == .claude else { return "you" }
    guard let from else { return "Claude" }
    switch from.kind {
    case .manager: return "Manager"
    case .operator: return Manager.operatorName
    case .chat: return "the \(from.name) chat"
    case .work: return from.name
    }
  }

  /// "Paused by <who>", then the reason and the condition.
  public var line: String { "Paused by \(byText)\(detail)" }

  /// The part of `line` after who paused: ": <reason>" and "; resumes when <condition>", each when set.
  public var detail: String {
    (reason.map { ": \($0)" } ?? "") + (until.map { "; resumes when \(Pause.condition($0))" } ?? "")
  }

  /// "#123 merges", "<name> reaches <State>", or "at 2026-11-15 09:00".
  static func condition(_ until: Wait) -> String {
    switch until.kind {
    case .merge: return "\(until.pr?.text ?? "the session's PR") merges"
    case .session: return "\(until.session?.name ?? "another session") reaches \((until.state ?? .done).title)"
    case .date: return "at " + (until.until.map { Wait.formatTime($0) } ?? "a date")
    default: return until.summary
    }
  }

  /// Why sbd delivers nothing to the session on its own, or nil when it isn't paused. A session marked done
  /// keeps its pause, so it keeps the blocker too.
  public static func blocker(_ session: Session) -> String? {
    session.pause.map { "paused by \($0.byText)" }
  }

  /// The message that the resume sends: `override` verbatim, else the stored message verbatim, else
  /// `defaultMessage`. `outcome` says why the session resumes, such as "#123 merged".
  public func resumeText(outcome: String?, override: String?) -> String {
    override ?? message ?? defaultMessage(outcome: outcome)
  }

  private func defaultMessage(outcome: String?) -> String {
    let why = reason.map { " (\($0))" } ?? ""
    let because = outcome.map { " You resume because \(Wait.sentence($0))" } ?? ""
    return "Switchboard: You were paused by \(byText)\(why).\(because) Continue where you left off."
  }

  /// Reads the `--until` condition as the `wait` request that builds it: `session:<ref>[=<state>]` is a
  /// `session` wait, a PR (`pr:123`, `#123`, `owner/name#123`, or a PR URL) is a `merge` wait, and a time that
  /// `Wait.parseTime` reads is a `date` wait. `makeWait` then checks the state, the session, and that the time
  /// hasn't passed.
  public static func parseUntil(_ text: String, now: Int64) throws -> WaitRequest {
    let text = text.trimmingCharacters(in: .whitespaces)
    let forms = "Use a time such as 2h or 2026-11-15 09:00, a PR such as #123, or session:<name>[=<state>]"
    guard !text.isEmpty else { throw APIError("--until needs a condition. \(forms)") }
    // Wait.PullRequest reads a bare number as a PR, so this refusal comes first.
    if text.allSatisfy({ $0.isASCII && $0.isNumber }) {
      throw APIError("--until \(text) could be a PR or a time. Write #\(text) for a PR or \(text)m for minutes")
    }
    if text.hasPrefix("session:") {
      let rest = text.dropFirst("session:".count)
      let parts = rest.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let ref = parts.first, !ref.isEmpty else {
        throw APIError("--until \(text) needs a session after session:")
      }
      return WaitRequest(
        kind: Wait.Kind.session.rawValue, target: String(ref), state: parts.dropFirst().first.map(String.init))
    }
    let url = URL(string: text).flatMap(\.scheme).map { ["http", "https"].contains($0.lowercased()) } ?? false
    if text.hasPrefix("pr:") || text.contains("#") || url {
      guard Wait.PullRequest(parsing: text) != nil else { throw APIError("--until \(text) isn't a PR. \(forms)") }
      return WaitRequest(kind: Wait.Kind.merge.rawValue, target: text)
    }
    guard Wait.parseTime(text, now: now) != nil else { throw APIError("can't read --until \(text). \(forms)") }
    return WaitRequest(kind: Wait.Kind.date.rawValue, until: text)
  }

  /// The reason on one line, or nil when nothing remains. It refuses text over `reasonLimit`.
  public static func cleanReason(_ text: String?) throws -> String? {
    try SessionGroup.cleanLine(text, limit: reasonLimit, noun: "a pause reason")
  }
}

extension Session {
  /// The open waits, then the pause condition. A resolver checks the condition as it checks a wait.
  public var resolvableWaits: [Wait] {
    guard let until = pause?.until else { return waits ?? [] }
    return (waits ?? []) + [until]
  }

  /// The items that ending the session as a Manager conversation drops.
  public var ownItems: [OwnItem] { OwnItem.list(waits: waits ?? [], pause: pause, schedules: schedules ?? []) }
}

extension SessionSummary {
  /// The items that ending the conversation drops.
  public var ownItems: [OwnItem] { OwnItem.list(waits: waits, pause: pause, schedules: schedules ?? []) }
}

/// One of a Manager conversation's own waits, its pause condition, or one of its schedules. Ending the
/// conversation drops it, so sbd refuses the end until the request names its id.
public struct OwnItem: Equatable, Sendable {
  public var id: String
  public var line: String

  /// The waits, then the pause condition, then the schedules.
  static func list(waits: [Wait], pause: Pause?, schedules: [Schedule]) -> [OwnItem] {
    let condition = pause.flatMap { p in p.until.map { OwnItem(id: $0.id, line: p.endLine) } }
    return waits.map { OwnItem(id: $0.id, line: $0.line) } + (condition.map { [$0] } ?? [])
      + schedules.map { OwnItem(id: $0.id, line: "Loop: \(oneLine($0.prompt))") }
  }
}

extension Pause {
  /// The pause's line, then the message that the resume would send.
  public var endLine: String { line + (message.map { ". The resume would send: \(oneLine($0))" } ?? "") }
}

/// A session as a group pause or resume sees it. sbd decides each member's row with this rule, and the app shows
/// Pause All and Resume All with it.
public protocol GroupPauseMember {
  var kind: SessionKind { get }
  var runsClaude: Bool { get }
  /// True when `sb done` or the app marked the session done. A merged PR alone doesn't mark it.
  var markedDone: Bool { get }
  var pause: Pause? { get }
}

extension Session: GroupPauseMember {
  public var markedDone: Bool { done }
}

extension SessionSummary: GroupPauseMember {}

extension GroupPauseMember {
  /// The row that a group pause gives the member without pausing it, or nil when it pauses the member. It skips a
  /// member that hasn't started or is marked done.
  /// It keeps the pause that a member already has.
  public var groupPauseSkip: PauseRow.Result? {
    if !runsClaude || markedDone { return .skipped }
    return pause == nil ? nil : .alreadyPaused
  }

  /// The row that a group resume gives the member without resuming it, or nil when it resumes the member.
  public var groupResumeSkip: PauseRow.Result? { pause == nil ? .skipped : nil }
}

extension Sequence where Element: GroupPauseMember {
  /// The members that a group pause or resume gives a row. A Manager conversation or a group chat gets none.
  public var workMembers: [Element] { filter { $0.kind == .work } }
}

/// sbd's answer to a `pause` or `resume` request that names a group: one row for each session in the group.
public struct PauseReport: Codable, Equatable, Sendable {
  public var group: String
  public var name: String
  public var sessions: [PauseRow]

  public init(group: String, name: String, sessions: [PauseRow]) {
    self.group = group
    self.name = name
    self.sessions = sessions
  }
}

/// What a group pause or resume did to one session of the group.
public struct PauseRow: Codable, Equatable, Sendable {
  public enum Result: String, Codable, Sendable {
    case paused
    /// A group pause keeps the pause that the session already had.
    case alreadyPaused = "already_paused"
    /// A pause skips a session that hasn't started or is marked done. A resume skips a session that isn't paused.
    case skipped
    case resumed
    case failed
  }

  public var session: String
  public var name: String
  public var result: Result
  public var error: String?

  public init(session: String, name: String, result: Result, error: String? = nil) {
    self.session = session
    self.name = name
    self.result = result
    self.error = error
  }
}
