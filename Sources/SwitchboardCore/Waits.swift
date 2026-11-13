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
/// resolves the others through `Service.resolveWait`. A wait that passes its
/// `recheck` time stays open, and its session moves to Needs you until the
/// wait resolves or the user clears it.
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
    /// `https://github.com/owner/name/pull/1204/files`. A leading `pr:`, as
    /// in `pr:1204`, is dropped.
    public init?(parsing text: String) {
      var number = text.trimmingCharacters(in: .whitespaces)
      if number.hasPrefix("pr:") { number.removeFirst(3) }
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
  /// The commit that the session's checked-out branch pointed at when a `ci`
  /// wait on the session's own PR was set. Nil for a wait on another PR, for
  /// a folder that doesn't have the session's branch checked out, and for a
  /// wait set before sbd recorded it.
  public var headSha: String?
  public var by: Author
  /// Milliseconds since the epoch.
  public var created: Int64
  public var then: Then
  /// When the wait stops holding the session in Waiting and moves it to
  /// Needs you. It is nil for a `date` wait, for a manual wait, whose `until`
  /// serves instead, and for a wait that sbd has not stamped yet.
  public var recheck: Int64?

  public init(
    id: String, kind: Kind, pr: PullRequest? = nil, session: SessionTarget? = nil, state: AttentionState? = nil,
    who: String? = nil, environment: String? = nil, service: String? = nil, until: Int64? = nil, note: String? = nil,
    headSha: String? = nil, by: Author = .you, created: Int64, then: Then = .resume, recheck: Int64? = nil
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
    self.headSha = headSha
    self.by = by
    self.created = created
    self.then = then
    self.recheck = recheck
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

  /// Whether the wait is past its recheck time and still open.
  public func isOverdue(now: Int64) -> Bool {
    guard let recheck else { return false }
    return recheck <= now
  }

  /// The reason line of an overdue wait. The age is the time from when the
  /// wait was set to its recheck time, so the line stays the same while the
  /// wait stays overdue.
  public var overdueLine: String {
    outcomeLine("still open after \(Wait.age((recheck ?? created) - created))")
  }

  /// A duration in its largest whole unit, such as `45 min`, `2 h`, or `3 d`.
  static func age(_ ms: Int64) -> String {
    let minute: Int64 = 60_000
    let hour = 60 * minute
    let day = 24 * hour
    if ms >= day { return "\(ms / day) d" }
    if ms >= hour { return "\(ms / hour) h" }
    return "\(max(1, ms / minute)) min"
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
  ///
  /// A `session` wait also resolves when its target can't reach the wanted
  /// state on its own: the target was removed, it reached Done, or it went
  /// Stale, which is how sbd defines an abandoned session.
  public func resolution(now: Int64, stateOf: (String) -> AttentionState?) -> String? {
    switch kind {
    case .date, .manual:
      guard let until, until <= now else { return nil }
      return kind == .date ? "the time came" : "time to recheck"
    case .session:
      guard let target = session else { return nil }
      guard let current = stateOf(target.id) else { return "it was removed" }
      switch current {
      case state ?? .done: return "it did"
      case .done: return "it reached Done first"
      case .stale: return "it went stale"
      default: return nil
      }
    default:
      return nil
    }
  }

  /// What happened, when this PR kind of wait can resolve from the PR as the
  /// poller read it, or nil while the wait stays open. A wait that names a PR
  /// that merged or closed first resolves too, since nothing else would end it.
  /// `deployResolution` decides the `deploy` kind.
  ///
  /// - `ci`: the head commit's rollup is SUCCESS, or FAILURE or ERROR, or the
  ///   head commit's Depot run has a failed job. A Depot failure names the
  ///   failed jobs.
  /// - `review` and `bot-review`: a review that was submitted after the wait was
  ///   set, by `who`, or by any app when a `bot-review` wait has no `who`. The
  ///   outcome names the newest one.
  /// - `approval`: `who`'s last verdict is an approval, or the PR is approved
  ///   when there is no `who`. It holds at any time, since an approval is a
  ///   state.
  /// - `merge`: the PR merged or closed.
  /// - `queue`: the PR merged or closed, or the queue state shows that Trunk
  ///   merged it or removed it from the queue after the wait was set. A PR that
  ///   Trunk has not queued yet keeps the wait open. A state that trunk gave
  ///   names Trunk's reason for a removal.
  public func resolution(of pr: SwitchboardCore.PullRequest) -> String? {
    let ended: String? =
      switch (pr.state, kind) {
      case (.open, _): nil
      case (.merged, .merge): "it merged"
      case (.merged, .queue): "it merged"
      case (.merged, _): "the PR merged first"
      case (.closed, .merge), (.closed, .queue): "it closed without merging"
      case (.closed, _): "the PR closed first"
      }
    switch kind {
    case .merge:
      return ended
    case .ci:
      if pr.checks == "SUCCESS" { return "the checks passed" }
      if let depot = pr.depotFailure { return depot.outcome }
      return pr.checksFailed ? "the checks failed" : ended
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
    case .queue:
      if ended != nil { return ended }
      // A status from before the wait can describe an earlier run of the PR.
      guard let at = pr.queueAt, at > created else { return nil }
      switch pr.queue {
      case .removed?:
        guard let label = pr.queueLabel, let text = pr.queueText else { return "Trunk removed it from the queue" }
        return "Trunk removed it from the queue (\(label)): \(text)"
      case .merged?: return "Trunk merged it"
      default: return nil
      }
    case .deploy, .session, .date, .manual:
      return nil
    }
  }

  /// Whether the PR merged or closed before this wait was set, or at a time
  /// that GitHub didn't give. A deploy wait is usually set after its PR
  /// merged, so a merge doesn't count for it.
  public func finishedBeforeSet(_ pr: SwitchboardCore.PullRequest) -> Bool {
    guard pr.state != .open, !(kind == .deploy && pr.state == .merged) else { return false }
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

  /// The milliseconds in a duration such as `90s`, `30m`, `2h`, `1d`, or `1w`.
  public static func durationMs(_ text: String) -> Int64? {
    guard let unit = text.last.flatMap({ units[$0] }) else { return nil }
    let count = text.dropLast()
    guard !count.isEmpty, count.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int64(count) else { return nil }
    let (ms, overflow) = n.multipliedReportingOverflow(by: unit * 1000)
    return overflow ? nil : ms
  }

  /// Reads a duration after `now` (`90s`, `30m`, `2h`, `1d`, `1w`), a date
  /// (`2026-10-26`, midnight in `zone`), a date and time in `zone`
  /// (`2026-10-26T09:00`, `2026-10-26 09:00`, optionally with seconds), or an
  /// ISO 8601 time with a zone. Returns ms since the epoch. A local time that
  /// `zone` skips at a daylight-saving change moves forward by the length of
  /// the skip, so `02:30` on a day that jumps from 02:00 to 03:00 reads as
  /// `03:30`.
  public static func parseTime(_ text: String, now: Int64, zone: TimeZone = .current) -> Int64? {
    let text = text.trimmingCharacters(in: .whitespaces)
    if let unit = text.last, units[unit] != nil {
      guard let ms = durationMs(text) else { return nil }
      let (time, later) = now.addingReportingOverflow(ms)
      return later ? nil : time
    }
    // The zone formatter reads a time that the zone repeats as the later one.
    // Calendar would read it as the earlier one, so it only handles skips.
    let local =
      localFormats.lazy.compactMap { formatter($0, zone).date(from: text) }.first
      ?? localFormats.lazy.compactMap { skippedTime(text, $0, zone) }.first
    return (ISO8601DateFormatter().date(from: text) ?? local).map { Int64($0.timeIntervalSince1970 * 1000) }
  }

  /// The strict zone formatter refuses a time that `zone` skips. GMT skips no
  /// time, so a GMT parse checks the text, and Calendar then moves the parts
  /// past the skip. Calendar alone would also accept `25:00` and `02-30`.
  static func skippedTime(_ text: String, _ format: String, _ zone: TimeZone) -> Date? {
    guard let wall = formatter(format, .gmt).date(from: text) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
    calendar.timeZone = zone
    return calendar.date(from: parts)
  }

  static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.dateFormat = format
    return f
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
  /// even while other waits stay open. Needs you while an open wait is past
  /// its recheck time, naming each overdue wait. Otherwise Waiting while the
  /// session has an open wait.
  static func waitVerdict(_ session: Session, _ facts: SessionFacts, now: Int64) -> Verdict? {
    if let outcome = facts.waitOutcome { return Verdict(state: .needsYou, reason: oneLine(outcome), kind: .info) }
    guard let waits = session.waits, !waits.isEmpty else { return nil }
    let overdue = waits.filter { $0.isOverdue(now: now) }
    if !overdue.isEmpty {
      return Verdict(state: .needsYou, reason: oneLine(overdue.map(\.overdueLine).joined(separator: "; ")), kind: .info)
    }
    return Verdict(state: .waiting, reason: oneLine(waits.map(\.line).joined(separator: "; ")))
  }
}
