import Foundation

/// A session that waits to start: it has no folder and no claude until
/// `followup start` makes its worktree and launches claude with `prompt`.
public struct Followup: Codable, Equatable, Sendable {
  public var prompt: String
  /// `owner/name` on GitHub. `followup start` makes the worktree from a
  /// checkout of it.
  public var repository: String?
  /// The branch that the follow-up came up on.
  public var sourceBranch: String?
  public var link: String?
  /// The plan row that `sb plan followup` made the follow-up from.
  public var planRow: PlanRowRef?
  public var trigger: Trigger
  /// When the trigger fired, in ms since the epoch. The follow-up then shows
  /// in Needs you. It still doesn't start on its own.
  public var ready: Int64?
  /// When `followup start` started the session. Nil while it is Not started.
  public var started: Int64?

  public init(
    prompt: String, repository: String? = nil, sourceBranch: String? = nil, link: String? = nil,
    planRow: PlanRowRef? = nil, trigger: Trigger = .manual
  ) {
    self.prompt = prompt
    self.repository = repository
    self.sourceBranch = sourceBranch
    self.link = link
    self.planRow = planRow
    self.trigger = trigger
  }

  /// A row of a plan document. A row has a follow-up while a session's
  /// `planRow` names the plan's document and the row's item.
  public struct PlanRowRef: Codable, Equatable, Sendable {
    public var source: PlanSource
    public var item: String

    public init(source: PlanSource, item: String) {
      self.source = source
      self.item = item
    }
  }

  /// What moves a follow-up to Needs you.
  public struct Trigger: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
      case manual
      case date
      case merge
    }

    public var kind: Kind
    /// When a date trigger fires, in ms since the epoch.
    public var at: Int64?
    /// The PR whose merge fires a merge trigger.
    public var pr: Wait.PullRequest?

    public static let manual = Trigger(kind: .manual)
    public static func date(_ at: Int64) -> Trigger { Trigger(kind: .date, at: at) }
    public static func merge(_ pr: Wait.PullRequest) -> Trigger { Trigger(kind: .merge, pr: pr) }

    /// What a follow-up that hasn't fired waits for, or nil for a manual one.
    public var pending: String? {
      switch kind {
      case .manual: nil
      case .date: "ready at \(Wait.formatTime(at ?? 0))"
      case .merge: "ready when \(pr?.text ?? "a PR") merges"
      }
    }

    /// What happened when the trigger fired.
    public var outcome: String {
      switch kind {
      case .manual: "marked ready"
      case .date: "\(Wait.formatTime(at ?? 0)) passed"
      case .merge: "\(pr?.text ?? "a PR") merged"
      }
    }
  }
}

extension Followup {
  /// Whether the text has the form `owner/name`.
  public static func isRepository(_ text: String) -> Bool {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2
      && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: \.isWhitespace) }
  }

  /// The `owner/name` of a remote whose host is github.com, such as
  /// `git@github.com:owner/name.git` or `https://github.com/owner/name`.
  public static func repository(remote: String) -> String? {
    let host: Substring
    var path: Substring
    if let scheme = remote.range(of: "://") {
      let rest = remote[scheme.upperBound...]
      let authority = rest.prefix { !"/?#\\".contains($0) }
      host = authority.split(separator: "@").last.map { $0.split(separator: ":").first ?? $0 } ?? ""
      path = rest.dropFirst(authority.count)
    } else {
      // An scp-style remote, `user@host:path`.
      guard let colon = remote.firstIndex(of: ":") else { return nil }
      host = remote[..<colon].split(separator: "@").last ?? ""
      path = remote[remote.index(after: colon)...]
    }
    guard host.lowercased() == "github.com" else { return nil }
    while path.hasPrefix("/") { path = path.dropFirst() }
    if path.hasSuffix("/") { path = path.dropLast() }
    if path.hasSuffix(".git") { path = path.dropLast(4) }
    return isRepository(String(path)) ? String(path) : nil
  }

  /// The prompt's first sentence, with each markdown link reduced to its
  /// text, on one line and cut to 70 characters.
  public static func title(_ prompt: String) -> String {
    let plain = prompt.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    let line = oneLine(plain, max: Int.max)
    guard let end = line.range(of: #"[.?!](\s|$)"#, options: .regularExpression) else { return oneLine(line) }
    var sentence = String(line[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
    if sentence.hasSuffix(".") { sentence.removeLast() }
    return oneLine(sentence)
  }

  /// The first http or https URL in the text, without trailing punctuation.
  public static func firstLink(_ text: String) -> String? {
    guard let range = text.range(of: #"https?://[^\s)\]>`"']+"#, options: .regularExpression) else { return nil }
    var link = String(text[range])
    while let last = link.last, ".,;:!?".contains(last) { link.removeLast() }
    return link
  }

  /// A branch name from a title: lowercase ASCII letters and digits joined
  /// by dashes, cut at a dash to at most `max` characters.
  public static func slug(_ title: String, max: Int = 50) -> String {
    var out = ""
    for ch in title.lowercased() {
      if ch.isASCII && (ch.isLetter || ch.isNumber) {
        out.append(ch)
      } else if !out.isEmpty && out.last != "-" {
        out.append("-")
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    guard out.count > max else { return out }
    let cut = out.prefix(max)
    return String(cut.lastIndex(of: "-").map { cut[..<$0] } ?? cut)
  }
}

extension Wait.PullRequest {
  /// GitHub compares repository names without case.
  public func same(as other: Wait.PullRequest) -> Bool {
    number == other.number && repository?.lowercased() == other.repository?.lowercased()
  }
}

// MARK: Followups.md

extension Followup {
  /// One open item of Followups.md.
  public struct Item: Equatable, Sendable {
    /// The line after `- [ ] `. An import records it, so a later import
    /// skips the line.
    public var key: String
    public var prompt: String
    public var repository: String?
    public var sourceBranch: String?
    /// Midnight in the local zone of the line's date, in ms since the epoch.
    public var added: Int64?
  }

  /// The `- [ ]` items under `## Open`, in file order. An item reads
  /// `- [ ] 2026-10-24 · [owner/repo · branch] text`, where the context can
  /// also be `[owner/repo]` or `[no-repo]`. A line in another shape becomes
  /// an item whose prompt is the whole line after `- [ ] `.
  public static func openItems(_ markdown: String, zone: TimeZone = .current) -> [Item] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var open = false
    var items: [Item] = []
    for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#") {
        open = line == "## Open"
        continue
      }
      guard open, line.hasPrefix("- [ ] ") else { continue }
      let key = String(line.dropFirst("- [ ] ".count)).trimmingCharacters(in: .whitespaces)
      if !key.isEmpty { items.append(item(key, calendar)) }
    }
    return items
  }

  /// An import reads hundreds of lines, so the date comes from `calendar`
  /// instead of a DateFormatter for each line.
  static func item(_ key: String, _ calendar: Calendar) -> Item {
    var item = Item(key: key, prompt: key)
    let dated = key.split(separator: " · ", maxSplits: 1).map(String.init)
    guard dated.count == 2, dated[0].range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
    else { return item }
    let ymd = dated[0].split(separator: "-").compactMap { Int($0) }
    guard ymd.count == 3, let day = calendar.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2]))
    else { return item }
    item.added = Int64(day.timeIntervalSince1970 * 1000)
    item.prompt = dated[1]
    guard dated[1].hasPrefix("["), let close = dated[1].range(of: "] ") else { return item }
    let context = dated[1][dated[1].index(after: dated[1].startIndex)..<close.lowerBound]
      .split(separator: " · ", maxSplits: 1).map(String.init)
    item.prompt = String(dated[1][close.upperBound...]).trimmingCharacters(in: .whitespaces)
    if let repo = context.first, isRepository(repo) { item.repository = repo }
    if context.count == 2 { item.sourceBranch = context[1] }
    return item
  }
}

extension Session {
  /// True for a follow-up that hasn't started, which has no folder and no
  /// claude. It stays true after its trigger fires, while it shows in Needs you.
  public var waitsToStart: Bool { followup != nil && followup?.started == nil }
}

extension SessionSummary {
  public var waitsToStart: Bool { followup != nil && followup?.started == nil }
}

extension Attention {
  /// The state of a follow-up that hasn't started, or nil for any other session.
  static func followupVerdict(_ session: Session) -> Verdict? {
    guard let f = session.followup, f.started == nil else { return nil }
    if f.ready != nil { return Verdict(state: .needsYou, reason: oneLine("ready to start: \(f.trigger.outcome)")) }
    let repo = f.repository ?? "no repository"
    return Verdict(state: .notStarted, reason: oneLine(f.trigger.pending.map { "\(repo) · \($0)" } ?? repo))
  }
}
