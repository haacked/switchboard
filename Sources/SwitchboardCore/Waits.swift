import Foundation

/// Who set a wait or wrote a note.
public enum Author: String, Codable, Sendable {
  case you
  case claude

  /// Reads `you` or `claude`. Nil means you.
  public init(parsing text: String?) throws {
    guard let author = Author(rawValue: text ?? Author.you.rawValue) else {
      throw APIError("by is you or claude, not \(text ?? "")")
    }
    self = author
  }
}

/// Something a session waits on, and what happens when it resolves. sbd
/// resolves the `date`, `session`, and `manual` kinds on each tick. A poller
/// resolves the others through `Service.resolveWait`.
public struct Wait: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case ci
    case review
    case botReview = "bot-review"
    case approval
    case queue
    case merge
    case deploy
    case session
    case date
    case manual

    /// True for the kinds that a poller resolves. sbd resolves the others.
    public var needsPoller: Bool {
      switch self {
      case .session, .date, .manual: false
      default: true
      }
    }

    /// The `wait` request's fields that this kind reads.
    var fields: Set<String> {
      switch self {
      case .ci, .queue, .merge: ["target"]
      case .review, .botReview, .approval: ["target", "who"]
      case .deploy: ["target", "environment", "service"]
      case .session: ["target", "state"]
      case .date, .manual: ["until"]
      }
    }
  }

  /// What happens when the wait resolves.
  public enum Then: String, Codable, Sendable {
    /// Send the session a message that says what happened, which resumes it.
    case resume
    /// Move the session to Needs you with what happened as the reason.
    case notify
  }

  public struct PullRequest: Codable, Equatable, Sendable {
    /// `owner/name`, or nil for the session's own repository.
    public var repository: String?
    public var number: Int

    public init(repository: String? = nil, number: Int) {
      self.repository = repository
      self.number = number
    }

    /// Reads `1204`, `#1204`, `owner/name#1204`, or a PR URL such as
    /// `https://github.com/owner/name/pull/1204/files`.
    public init?(parsing text: String) {
      var number = text.trimmingCharacters(in: .whitespaces)
      if let url = URL(string: number), url.scheme == "https" || url.scheme == "http" {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.host?.lowercased() == "github.com", parts.count >= 4, parts[2] == "pull" else { return nil }
        repository = "\(parts[0])/\(parts[1])"
        number = parts[3]
      } else if let hash = number.lastIndex(of: "#") {
        let repo = number[..<hash]
        if !repo.isEmpty {
          let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
          guard parts.count == 2, !parts.contains(where: \.isEmpty) else { return nil }
          repository = String(repo)
        }
        number = String(number[number.index(after: hash)...])
      }
      guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(number), n > 0 else {
        return nil
      }
      self.number = n
    }

    /// `#1204`, or `owner/name#1204`.
    public var text: String { repository.map { "\($0)#\(number)" } ?? "#\(number)" }
  }

  /// The other session of a `session` wait, with its name when the wait was set.
  public struct SessionTarget: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public var id: String
  public var kind: Kind
  /// The PR of a PR kind. Nil means the session's own PR.
  public var pr: PullRequest?
  public var session: SessionTarget?
  /// The state that the other session of a `session` wait has to reach.
  public var state: AttentionState?
  /// The reviewer of `review`, the bot of `bot-review`, or the approver of `approval`.
  public var who: String?
  /// `dev`, `prod-us`, `prod-eu`, or `prod` for both prod regions.
  public var environment: String?
  public var service: String?
  /// When a `date` wait resolves, or when a `manual` wait returns to Needs you.
  public var until: Int64?
  public var note: String?
  public var by: Author
  /// Milliseconds since the epoch.
  public var created: Int64
  public var then: Then

  public init(
    id: String, kind: Kind, pr: PullRequest? = nil, session: SessionTarget? = nil, state: AttentionState? = nil,
    who: String? = nil, environment: String? = nil, service: String? = nil, until: Int64? = nil, note: String? = nil,
    by: Author = .you, created: Int64, then: Then = .resume
  ) {
    self.id = id
    self.kind = kind
    self.pr = pr
    self.session = session
    self.state = state
    self.who = who
    self.environment = environment
    self.service = service
    self.until = until
    self.note = note
    self.by = by
    self.created = created
    self.then = then
  }

  public static let environments = ["dev", "prod-us", "prod-eu", "prod"]

  /// What the session waits on, such as `CI on #1204`, `a review from alex on
  /// #1204`, `#1190 to merge`, `flag-cache to reach Done`, or `until
  /// 2026-10-26 09:00`. A manual wait's summary is its note.
  public var summary: String {
    let pr = self.pr?.text ?? "the session's PR"
    switch kind {
    case .ci: return "CI on \(pr)"
    case .review: return "a review from \(who ?? "a reviewer") on \(pr)"
    case .botReview: return who.map { "\($0)'s review on \(pr)" } ?? "a bot review on \(pr)"
    case .approval: return who.map { "approval from \($0) on \(pr)" } ?? "approval on \(pr)"
    case .queue: return "the merge queue for \(pr)"
    case .merge: return "\(pr) to merge"
    case .deploy: return "\(pr) to reach \(environment ?? "prod")" + (service.map { " in \($0)" } ?? "")
    case .session: return "\(session?.name ?? "another session") to reach \((state ?? .done).title)"
    case .date: return "until " + (until.map { Wait.formatTime($0) } ?? "a date")
    case .manual: return note ?? "a manual wait"
    }
  }

  /// The reason line while the wait is open: the summary, the note in
  /// parentheses, and a manual wait's recheck time.
  public var line: String {
    if kind == .manual { return summary + (until.map { " (recheck \(Wait.formatTime($0)))" } ?? "") }
    return summary + (note.map { " (\($0))" } ?? "")
  }

  /// The reason line after the wait resolved with `notify`.
  public func outcomeLine(_ outcome: String) -> String { "\(summary): \(outcome)" }

  /// The message that resumes the session when the wait resolves with `resume`.
  public func message(outcome: String) -> String {
    var text = "Switchboard: " + Wait.sentence(outcomeLine(outcome))
    if kind != .manual, let note { text += " Your note: " + Wait.sentence(note) }
    return text
  }

  static func sentence(_ text: String) -> String {
    text.last.map { ".!?".contains($0) } == true ? text : text + "."
  }

  /// What happened, when sbd itself resolves this wait at `now`, or nil while
  /// it stays open. `stateOf` gives another session's state, or nil when that
  /// session no longer exists. The kinds that a poller resolves return nil.
  public func resolution(now: Int64, stateOf: (String) -> AttentionState?) -> String? {
    switch kind {
    case .date, .manual:
      guard let until, until <= now else { return nil }
      return kind == .date ? "the time came" : "time to recheck"
    case .session:
      guard let target = session else { return nil }
      guard let current = stateOf(target.id) else { return "it was removed" }
      return current == (state ?? .done) ? "it did" : nil
    default:
      return nil
    }
  }

  /// What happened, when this PR kind of wait can resolve from the PR as the
  /// poller read it, or nil while the wait stays open. A wait that names a PR
  /// that merged or closed first resolves too, since nothing else would end it.
  /// The `queue` and `deploy` kinds wait for other pollers.
  ///
  /// - `ci`: the head commit's rollup is SUCCESS, or FAILURE or ERROR.
  /// - `review` and `bot-review`: a review that was submitted after the wait was
  ///   set, by `who`, or by any app when a `bot-review` wait has no `who`. The
  ///   outcome names the newest one.
  /// - `approval`: `who`'s last verdict is an approval, or the PR is approved
  ///   when there is no `who`. It holds at any time, since an approval is a
  ///   state.
  /// - `merge`: the PR merged or closed.
  public func resolution(of pr: SwitchboardCore.PullRequest) -> String? {
    let ended: String? =
      switch pr.state {
      case .open: nil
      case .merged: kind == .merge ? "it merged" : "the PR merged first"
      case .closed: kind == .merge ? "it closed without merging" : "the PR closed first"
      }
    switch kind {
    case .merge:
      return ended
    case .ci:
      switch pr.checks {
      case "SUCCESS": return "the checks passed"
      case "FAILURE", "ERROR": return "the checks failed"
      default: return ended
      }
    case .review, .botReview:
      let verbs = ["APPROVED": "approved", "CHANGES_REQUESTED": "requested changes", "COMMENTED": "reviewed"]
      let newest = pr.reviews.last { r in
        guard verbs[r.state] != nil, let at = r.submittedAt.flatMap(Transcript.milliseconds), at > created else {
          return false
        }
        if let who { return Wait.sameLogin(r.author, who) }
        return kind == .botReview && r.bot == true
      }
      return newest.flatMap { r in verbs[r.state].map { "\(r.author) \($0)" } } ?? ended
    case .approval:
      if let who {
        return pr.verdicts.first { $0.state == "APPROVED" && Wait.sameLogin($0.author, who) }
          .map { "\($0.author) approved" } ?? ended
      }
      guard pr.isApproved else { return ended }
      return pr.approvers.isEmpty ? "the PR is approved" : "approved by " + pr.approvers.joined(separator: ", ")
    case .queue, .deploy, .session, .date, .manual:
      return nil
    }
  }

  /// Whether the PR merged or closed before this wait was set, or at a time
  /// that GitHub didn't give.
  public func finishedBeforeSet(_ pr: SwitchboardCore.PullRequest) -> Bool {
    guard pr.state != .open else { return false }
    guard let at = (pr.state == .merged ? pr.mergedAt : pr.closedAt).flatMap(Transcript.milliseconds) else {
      return true
    }
    return at < created
  }

  /// GitHub's REST API shows a GitHub App's login with `[bot]`, and its
  /// GraphQL API without.
  static func sameLogin(_ a: String, _ b: String) -> Bool {
    func bare(_ login: String) -> String {
      var s = login.lowercased()
      if s.hasPrefix("@") { s.removeFirst() }
      return s.hasSuffix("[bot]") ? String(s.dropLast(5)) : s
    }
    return bare(a) == bare(b)
  }

  /// A time in the local format that the summaries use, `yyyy-MM-dd HH:mm`.
  /// Attention calls it on every tick, so it formats the parts itself. A
  /// DateFormatter costs about 30 times as much to build.
  public static func formatTime(_ ms: Int64, zone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let c = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
    return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
  }

  static let units: [Character: Int64] = ["s": 1, "m": 60, "h": 3600, "d": 86_400, "w": 604_800]
  static let localFormats = [
    "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
  ]

  /// Reads a duration after `now` (`90s`, `30m`, `2h`, `1d`, `1w`), a date
  /// (`2026-10-26`, midnight in `zone`), a date and time in `zone`
  /// (`2026-10-26T09:00`, `2026-10-26 09:00`, optionally with seconds), or an
  /// ISO 8601 time with a zone. Returns ms since the epoch.
  public static func parseTime(_ text: String, now: Int64, zone: TimeZone = .current) -> Int64? {
    let text = text.trimmingCharacters(in: .whitespaces)
    if let unit = text.last.flatMap({ units[$0] }) {
      let count = text.dropLast()
      guard !count.isEmpty, count.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int64(count) else { return nil }
      let (ms, overflow) = n.multipliedReportingOverflow(by: unit * 1000)
      let (time, later) = now.addingReportingOverflow(ms)
      return overflow || later ? nil : time
    }
    let local = localFormats.lazy.compactMap { formatter($0, zone).date(from: text) }
    return (ISO8601DateFormatter().date(from: text) ?? local.first).map { Int64($0.timeIntervalSince1970 * 1000) }
  }

  static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.dateFormat = format
    return f
  }
}

/// The arguments of the `wait` request, as sb sends them. Every field is text,
/// so that a bad value gets an error that names it.
public struct WaitRequest: Codable, Sendable {
  public var kind: String?
  /// A PR for the PR kinds, or a session for `session`.
  public var target: String?
  public var who: String?
  public var environment: String?
  public var service: String?
  public var state: String?
  public var until: String?
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
      ("until", until),
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

/// A note on a session.
public struct Note: Codable, Equatable, Sendable {
  public var id: String
  public var text: String
  public var by: Author
  /// Milliseconds since the epoch.
  public var t: Int64

  public init(id: String, text: String, by: Author, t: Int64) {
    self.id = id
    self.text = text
    self.by = by
    self.t = t
  }
}

/// A prefix and 5 random characters that aren't in `taken`, such as `w3k9ap`.
public func shortId(_ prefix: String, taken: some Collection<String> = [String]()) -> String {
  var id: String
  repeat {
    id = prefix + String((0..<5).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
  } while taken.contains(id)
  return id
}

extension SessionFacts {
  /// Folds the wait events into the facts. `apply` calls it for every event.
  mutating func applyWait(_ event: Event, userPrompt: Bool) {
    switch event.kind {
    case "wait":
      waitOutcome = nil
    case "UserPromptSubmit" where userPrompt:
      waitOutcome = nil
    case "wait-resolved":
      guard let json = event.data["wait"], let wait = try? JSONCoding.convert(json, to: Wait.self),
        wait.then == .notify
      else { return }
      waitOutcome = wait.outcomeLine(event.data["outcome"]?.string ?? "")
    default:
      break
    }
  }
}

extension Attention {
  /// Needs you after a wait resolved with `notify`, until the next prompt,
  /// even while other waits stay open. Otherwise Waiting while the session
  /// has an open wait.
  static func waitVerdict(_ session: Session, _ facts: SessionFacts) -> Verdict? {
    if let outcome = facts.waitOutcome { return Verdict(state: .needsYou, reason: oneLine(outcome)) }
    guard let waits = session.waits, !waits.isEmpty else { return nil }
    return Verdict(state: .waiting, reason: oneLine(waits.map(\.line).joined(separator: "; ")))
  }
}
