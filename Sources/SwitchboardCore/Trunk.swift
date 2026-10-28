import Foundation

/// Where a pull request stands in Trunk's merge queue. `trunk merge status`
/// and Trunk's PR comments both map to these states.
public enum TrunkQueueState: String, Codable, Sendable {
  /// Submitted. Trunk adds the PR to the queue once its branch protection
  /// rules pass.
  case submitted
  /// In the queue, waiting to form a batch or to start its tests.
  case pending
  case testing
  /// Passed its tests. Trunk merges it soon.
  case passed
  /// Failed its tests. It waits for the PRs ahead of it to finish theirs.
  case failing
  /// In the queue, in a state that the parser doesn't name.
  case queued
  case merged
  /// Out of the queue without a merge: its tests failed, it conflicted, it
  /// waited too long to become mergeable, or someone cancelled it.
  case removed
  /// sbd couldn't read the body of every trunk-io comment, so it can't tell
  /// the state. Only `GitHub.queueStatus` gives it.
  case unknown

  /// Whether Trunk still holds the PR. false when sbd can't tell.
  public var isQueued: Bool {
    switch self {
    case .submitted, .pending, .testing, .passed, .failing, .queued: true
    case .merged, .removed, .unknown: false
    }
  }
}

/// What `trunk merge status <N>` prints about a pull request: a header and a
/// timeline of its queue states, oldest first. The CLI has no JSON output.
public struct TrunkTimeline: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    /// Milliseconds since the epoch.
    public var time: Int64
    /// Trunk's name for the state, such as "Not Ready" or "Pending Failure",
    /// without its ✖ or ✔ mark.
    public var label: String
    public var state: TrunkQueueState
    /// The description as markdown, with Trunk's line wrapping undone.
    public var text: String
  }

  public enum Result: Equatable, Sendable {
    case found(TrunkTimeline)
    /// The queue has no item for the PR. Nobody submitted it, or the login
    /// can't see that queue.
    case notFound
    /// trunk has no login, or its login expired. `trunk login` signs in.
    case notLoggedIn
    /// Output that the parser doesn't know, without its colors.
    case unrecognized(String)
  }

  public var number: Int
  public var title: String
  public var author: String
  /// The PR's page on app.trunk.io.
  public var url: String?
  public var entries: [Entry]

  /// The newest entry's state. A PR submitted again after a removal ends
  /// with the entries of its new run.
  public var state: TrunkQueueState? { entries.last?.state }

  /// Whether the newest run queues the stack that this PR tops. Trunk queues
  /// a stack under its top PR. The newest entry that names its subject
  /// decides, because entries such as "Tests ran on" name none.
  public var isStack: Bool {
    for e in entries.reversed() {
      if e.text.hasPrefix("Stack ") || e.text.hasPrefix("This stack ") { return true }
      if e.text.hasPrefix("Pull request ") || e.text.hasPrefix("This pull request ") { return false }
    }
    return false
  }

  /// Parses the output of `trunk merge status <N>`. Trunk prints times in
  /// UTC without a year. Each time gets the latest year that doesn't put it
  /// more than a day after `now`, in milliseconds since the epoch.
  public static func parse(_ output: String, now: Int64) -> Result {
    let plain = plainText(output)
    let lines = plain.components(separatedBy: "\n")
    let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("✖ User not logged in") { return .notLoggedIn }
    if trimmed.hasPrefix("✖ Item for merge queue instance not found") { return .notFound }
    guard let start = lines.firstIndex(where: { $0.hasPrefix("#") }),
      let header = match(lines[start], headerPattern), let number = Int(header[0])
    else { return .unrecognized(trimmed) }

    var timeline = TrunkTimeline(number: number, title: header[1], author: header[2], entries: [])
    // trunk pads each line of its table to the table's width, except the
    // output's last line. The most common length is the width, because a
    // character that takes two code points makes its line longer.
    let firstRow = lines[start...].firstIndex { match($0, rowPattern) != nil } ?? lines.endIndex
    let lengths = Dictionary(grouping: lines[firstRow...].map(\.unicodeScalars.count)) { $0 }.mapValues(\.count)
    let width = lengths.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
    var brokeMidLink = false
    for line in lines[(start + 1)...] {
      let content = line.trimmingCharacters(in: .whitespaces)
      let full = line.unicodeScalars.count == width && line.last != " "
      if let url = match(line, learnMorePattern) {
        timeline.url = url[0]
      } else if let row = match(line, rowPattern), let time = time(row[0], now: now) {
        let text = row[3].trimmingCharacters(in: .whitespaces)
        timeline.entries.append(Entry(time: time, label: row[2], state: state(label: row[2], mark: row[1]), text: text))
        brokeMidLink = breaksLink(text, full: full, continuing: false)
      } else if !content.isEmpty, !timeline.entries.isEmpty {
        timeline.entries[timeline.entries.count - 1].text += (brokeMidLink ? "" : " ") + content
        brokeMidLink = breaksLink(content, full: full, continuing: brokeMidLink)
      }
    }
    return .found(timeline)
  }

  /// Whether trunk broke a link at the end of this piece of a description.
  /// trunk breaks only a link that is longer than a line. Such a piece fills
  /// the line and holds no space. A link that ends exactly at the line's end
  /// looks the same. A break leaves the link's parenthesis open, unless the
  /// piece continues a link that an earlier line broke.
  static func breaksLink(_ piece: String, full: Bool, continuing: Bool) -> Bool {
    full && !piece.contains(" ")
      && (continuing || piece.filter { $0 == "(" }.count > piece.filter { $0 == ")" }.count)
  }

  /// trunk's output without its colors and carriage returns. trunk colors its
  /// output even when stdout isn't a terminal. It ends its table rows with
  /// CRLF.
  public static func plainText(_ output: String) -> String {
    output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\r", with: "")
  }

  static let headerPattern = regex(#"^#(\d+) (.*) \(([^()]*)\)\s*$"#)
  static let learnMorePattern = regex(#"^ Learn more at (\S+)"#)
  /// A timeline row: the time, an optional ✖ or ✔ mark, the label, and the
  /// first line of the description.
  static let rowPattern = regex(#"^ (\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(?:([✖✔]) )?(\S+(?: \S+)*?)(?:\s{2,}(.*))?$"#)

  static func state(label: String, mark: String) -> TrunkQueueState {
    switch (mark, label) {
    case ("✔", _): .merged
    case ("✖", _): .removed
    case (_, "Not Ready"): .submitted
    case (_, "Pending"): .pending
    case (_, "Testing"): .testing
    case (_, "Tests Passed"): .passed
    case (_, "Pending Failure"): .failing
    default: .queued
    }
  }

  static let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  /// Reads `MM-dd HH:mm:ss.ffffff` in UTC. `rowPattern` has matched the
  /// stamp, so each part holds only digits.
  static func time(_ stamp: String, now: Int64) -> Int64? {
    let parts = stamp.split(whereSeparator: { "-: .".contains($0) }).map(String.init)
    let n = parts[0..<5].map { Int($0)! }
    let ms = Int(String(parts[5].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))!
    func at(year: Int) -> Int64? {
      let c = DateComponents(year: year, month: n[0], day: n[1], hour: n[2], minute: n[3], second: n[4])
      return utc.date(from: c).map { Int64($0.timeIntervalSince1970) * 1000 + Int64(ms) }
    }
    let year = utc.component(.year, from: Date(timeIntervalSince1970: Double(now) / 1000))
    return [year + 1, year, year - 1].lazy.compactMap(at).first { $0 <= now + Attention.dayMs }
  }

  static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

  /// The capture groups of the regex's first match, with "" for a group that
  /// didn't take part.
  static func match(_ text: String, _ regex: NSRegularExpression) -> [String]? {
    guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
  }
}

/// A comment on a pull request.
public struct TrunkComment: Equatable, Sendable {
  /// The login as GitHub's REST API gives it. A GitHub App comments as
  /// `<app>[bot]`. GraphQL leaves out the suffix. A caller adds it for an
  /// author whose `__typename` is `Bot`. GitHub forbids brackets in a user's
  /// login, which keeps any user from passing for Trunk.
  public var author: String
  public var body: String
  /// GitHub's `includesCreatedEdit`: whether someone edited the comment
  /// after it was created.
  public var edited: Bool

  public init(author: String, body: String, edited: Bool) {
    self.author = author
    self.body = body
    self.edited = edited
  }
}

/// Reads the queue state from the comments that Trunk posts on a pull
/// request. It ports the jq in git-pr (`~/.dotfiles/bin/git-pr`).
public enum TrunkComments {
  public static let author = "trunk-io[bot]"

  /// The PR's queue state, or nil when no Trunk comment names one. Only an
  /// open PR's state says whether Trunk holds it. A PR below the top of a
  /// merged stack keeps the reply that says it is queued.
  ///
  /// Trunk posts a control comment on each PR and edits that comment in place
  /// into the queue status. Its first line names the state. Trunk posts
  /// replies and errors as new comments that it never edits. A stack's PRs
  /// get replies of their own: the top PR gets the stack's submission, and
  /// each PR below it gets a reply when the stack enters the queue and again
  /// when the stack fails, is cancelled, or returns to waiting.
  ///
  /// Nothing orders the newest status against the newest reply. Trunk runs a
  /// PR through one queue run at a time and ends each run with a removal or a
  /// merge. Any other state from either kind therefore outranks a removal
  /// from the other.
  public static func state(_ comments: [TrunkComment]) -> TrunkQueueState? {
    let trunk = comments.filter { $0.author == author }
    let found = [
      trunk.filter(\.edited).compactMap { statusState($0.body) }.last,
      trunk.filter { !$0.edited }.compactMap { replyState($0.body) }.last,
    ].compactMap { $0 }
    return found.first { $0 != .removed } ?? found.first
  }

  /// The state that an edited status comment names. The control comment and
  /// the test analytics comment start with a marker and name none. Trunk
  /// rewords its statuses. A status without a known phrase therefore means
  /// that the queue holds the PR.
  static func statusState(_ body: String) -> TrunkQueueState? {
    // Swift reads CRLF as one Character, which isn't "\n".
    let first = body.prefix { !$0.isNewline }.lowercased()
    if first.hasPrefix("<!-- trunk") { return nil }
    if first.contains("merged successfully") { return .merged }
    // A status that offers the unchecked submit checkbox again means that
    // Trunk dropped the PR.
    if first.contains("removed from the merge queue") || first.contains("will not be merged")
      || body.contains("- [ ] <!-- End PR Submit Checkbox -->")
    {
      return .removed
    }
    if first.contains("running tests") { return .testing }
    if first.contains("waiting to start tests") { return .pending }
    if first.contains("will be merged soon") { return .passed }
    if first.contains("submitted to merge") { return .submitted }
    if first.range(of: "the required check .* has failed", options: .regularExpression) != nil { return .failing }
    return .queued
  }

  /// The state that a reply names. Only stack replies name one. Trunk posts
  /// a stack's submission under the control comment's marker and edits it
  /// into the stack's status later.
  static func replyState(_ body: String) -> TrunkQueueState? {
    let text = body.lowercased()
    if text.range(of: "^<!-- trunk merge -->\r?\n[^\n]*stack submitted to merge", options: .regularExpression) != nil {
      return .submitted
    }
    if text.hasPrefix("this pull request is queued for merge as part of") { return .queued }
    guard text.hasPrefix("stacked pr ") else { return nil }
    if text.contains("returned to waiting") { return .pending }
    if text.contains("failed testing") || text.contains("was cancelled") { return .removed }
    return .queued
  }
}
