import Foundation

/// Where a plan document lives.
public struct PlanSource: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// A markdown file on this Mac, such as one in the notes repo.
    case file
    /// The body of a GitHub issue.
    case issue
    /// A markdown file on the head branch of a PR.
    case pr
    /// A claude.ai artifact, which only the group's chat can read or write.
    case artifact
  }

  public var kind: Kind
  /// owner/name of an issue or a PR.
  public var repo: String?
  public var number: Int?
  /// The absolute path of a file, or the path of a PR's file in its repo.
  public var path: String?
  /// The link of an artifact.
  public var url: String?

  public init(kind: Kind, repo: String? = nil, number: Int? = nil, path: String? = nil, url: String? = nil) {
    self.kind = kind
    self.repo = repo
    self.number = number
    self.path = path
    self.url = url
  }

  /// Reads an issue as `owner/name#N` or an issue URL, a PR as `owner/name#N`
  /// or a PR URL with the file's `path`, or else a local path, which is
  /// relative to `cwd`. An existing local file wins over the `owner/name#N` form.
  public init(parsing doc: String, path: String?, cwd: String = FileManager.default.currentDirectoryPath) throws {
    let text = doc.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { throw APIError("name a plan document") }
    let file = path?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["/"])
    if file?.isEmpty == true { throw APIError("--path needs a file in the PR") }
    if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
      if let artifact = PlanSource.artifact(url) {
        if file != nil { throw APIError("--path names a file in a PR, and \(text) is an artifact") }
        self = artifact
        return
      }
      let parts = url.path.split(separator: "/").map(String.init)
      guard url.host?.lowercased() == "github.com", parts.count >= 4, ["issues", "pull"].contains(parts[2]),
        let number = Int(parts[3]), number > 0
      else { throw APIError("\(text) is not a GitHub issue or PR") }
      self = try PlanSource.remote(
        repo: "\(parts[0])/\(parts[1])", number: number, path: file, pull: parts[2] == "pull")
      return
    }
    let local = ((text.expandingTilde as NSString).isAbsolutePath ? text.expandingTilde : "\(cwd)/\(text)")
    let standard = (local as NSString).standardizingPath
    if !FileManager.default.fileExists(atPath: standard), let ref = Wait.PullRequest(parsing: text),
      let repo = ref.repository
    {
      self = try PlanSource.remote(repo: repo, number: ref.number, path: file, pull: nil)
      return
    }
    if file != nil { throw APIError("--path names a file in a PR, and \(text) is a local file") }
    self.init(kind: .file, path: standard)
  }

  private static let artifactIdCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

  /// An artifact from a `https://claude.ai/artifact/<id>` or
  /// `https://claude.ai/code/artifact/<id>` link, without its query or fragment.
  /// The id may hold only ASCII letters, digits, `-`, and `_`. `url.path` is
  /// percent-decoded, and the URL goes into the text of the chat's turns, so
  /// an id with `%0A` would add lines to those turns.
  static func artifact(_ url: URL) -> PlanSource? {
    let parts = url.path.split(separator: "/").map(String.init)
    guard url.host?.lowercased() == "claude.ai", url.scheme?.lowercased() == "https", parts.count >= 2,
      [["artifact"], ["code", "artifact"]].contains(Array(parts.dropLast())),
      parts.last!.unicodeScalars.allSatisfy(artifactIdCharacters.contains)
    else { return nil }
    return PlanSource(kind: .artifact, url: "https://claude.ai/" + parts.joined(separator: "/"))
  }

  /// `pull` is nil for `owner/name#N`, which names an issue or a PR.
  private static func remote(repo: String, number: Int, path: String?, pull: Bool?) throws -> PlanSource {
    if let path {
      if pull == false { throw APIError("an issue holds no files. --path names a file in a PR") }
      return PlanSource(kind: .pr, repo: repo, number: number, path: path)
    }
    if pull == true { throw APIError("name the PR's plan file with --path") }
    return PlanSource(kind: .issue, repo: repo, number: number)
  }

  /// `owner/name#N` of an issue or a PR.
  public var ref: String { "\(repo ?? "")#\(number ?? 0)" }

  /// The file's path, or the URL of the issue or the PR.
  public var link: String {
    switch kind {
    case .file: path ?? ""
    case .issue: "https://github.com/\(repo ?? "")/issues/\(number ?? 0)"
    case .pr: "https://github.com/\(repo ?? "")/pull/\(number ?? 0)"
    case .artifact: url ?? ""
    }
  }

  /// The path, `owner/name#N`, or `owner/name#N:path`.
  public var text: String {
    switch kind {
    case .file: path ?? ""
    case .issue: ref
    case .pr: "\(ref):\(path ?? "")"
    case .artifact: url ?? ""
    }
  }
}

/// A PR that a plan links.
public struct PlanLink: Codable, Equatable, Hashable, Sendable {
  /// owner/name.
  public var repo: String
  public var number: Int

  public init(repo: String, number: Int) {
    self.repo = repo
    self.number = number
  }

  public var text: String { "\(repo)#\(number)" }

  /// The link with its repo lowercased. GitHub ignores the case of owner/name.
  public var key: PlanLink { PlanLink(repo: repo.lowercased(), number: number) }
}

/// How far a PR has gone, as a plan row tracks it.
public enum PlanStage: String, Codable, Sendable {
  case open, merged, deployed, closed
}

/// A table row of a plan that links at least one PR, or that links none and
/// whose status reads Not started.
public struct PlanRow: Codable, Equatable, Sendable {
  public struct PR: Codable, Equatable, Sendable {
    public var repo: String
    public var number: Int
    /// The PR's stage when sbd first knew it after the row's text last
    /// changed. Nil until sbd reads the PR.
    public var seen: PlanStage?
    /// The PR's stage at sbd's last read.
    public var now: PlanStage?

    public init(repo: String, number: Int, seen: PlanStage? = nil, now: PlanStage? = nil) {
      self.repo = repo
      self.number = number
      self.seen = seen
      self.now = now
    }

    public var link: PlanLink { PlanLink(repo: repo, number: number) }

    /// The PR merged, deployed, or closed since the row last changed.
    public var advanced: Bool {
      guard let seen, let now else { return false }
      return now != seen && now != .open
    }
  }

  /// The row's markdown line, trimmed.
  public var text: String
  /// When sbd first saw this text, in ms since the epoch.
  public var changed: Int64
  public var prs: [PR]
  /// The cells of the row's `#`, `Item`, and `Status` columns, or nil when
  /// its table has no such column.
  public var number: String?
  public var item: String?
  public var status: String?
  /// The follow-up made from the row. sbd fills it in when it reports the
  /// plan, and the stored record leaves it nil. The follow-up's
  /// `planRow` is what records the link.
  public var followup: String?

  public init(text: String, changed: Int64, prs: [PR]) {
    self.text = text
    self.changed = changed
    self.prs = prs
  }

  public var outOfDate: Bool { prs.contains(where: \.advanced) }

  /// The row links no PR, names an item, and its status reads Not started.
  public var notStarted: Bool { prs.isEmpty && Plans.notStarted(item: item, status: status) }

  /// The row's `#` and item, as `sb plan` prints it.
  public var label: String {
    [number.map { "#\($0)" }, item].compactMap { $0 }.joined(separator: " ")
  }

  /// What `sb plan followup` takes to name the row: its `#`, else its item,
  /// else its text, whichever names only this row. `PlanSummary` fills it in
  /// for the rows it lists, and the stored record leaves it nil.
  public var ref: String?
}

/// A plan attached to a group or a session, with what sbd last read from it.
/// A field added later needs a default or an optional type, because sbd
/// decodes the plans that an older sbd stored.
public struct PlanDocument: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var source: PlanSource
  /// The group the plan belongs to, or nil for a session's plan.
  public var group: String?
  public var session: String?
  /// True when sbd writes the generated table on its own.
  public var autoUpdate: Bool
  /// Milliseconds since the epoch.
  public var attached: Int64
  /// When sbd last read the document without an error.
  public var read: Int64?
  /// Why the last read or write failed, or nil after a success.
  public var error: String?
  /// Every PR that the document links outside the generated table.
  public var links: [PlanLink]
  public var rows: [PlanRow]
  /// The text between the status markers at the last read, or nil when the
  /// document has none.
  public var statusBlock: String?
  /// The copy of an artifact plan and its pending update, or nil for other types.
  public var artifact: ArtifactPlan?

  public init(id: String, source: PlanSource, group: String? = nil, session: String? = nil, attached: Int64) {
    self.id = id
    self.source = source
    self.group = group
    self.session = session
    self.autoUpdate = false
    self.attached = attached
    self.links = []
    self.rows = []
    if source.kind == .artifact { artifact = ArtifactPlan() }
  }

  /// Takes in the document's text. A row whose text is unchanged keeps when
  /// it changed and the stages it saw.
  public mutating func update(from text: String, now: Int64) {
    let content = Plans.parse(text)
    links = content.links
    let old = Dictionary(rows.map { ($0.text, $0) }) { first, _ in first }
    var seen: Set<String> = []
    rows = content.rows.compactMap { row in
      guard seen.insert(row.text).inserted else { return nil }
      // A record from an older sbd lacks the cells, and a header change can
      // move them without changing the row's text.
      var kept =
        old[row.text]
        ?? PlanRow(text: row.text, changed: now, prs: row.links.map { PlanRow.PR(repo: $0.repo, number: $0.number) })
      kept.number = row.number
      kept.item = row.item
      kept.status = row.status
      return kept
    }
    statusBlock = content.statusBlock
    read = now
    error = nil
  }

  /// Sets each row PR's stage from `stage`, which returns nil for a PR that
  /// sbd hasn't read. A PR with no `seen` stage takes the first known one.
  /// A deployed PR stays deployed when a read says merged, because a read
  /// after sbd restarts may not have the deploy comment's body yet.
  public mutating func setStages(_ stage: (PlanLink) -> PlanStage?) {
    for r in rows.indices {
      for p in rows[r].prs.indices {
        guard let s = stage(rows[r].prs[p].link), !(s == .merged && rows[r].prs[p].now == .deployed) else {
          continue
        }
        if rows[r].prs[p].seen == nil { rows[r].prs[p].seen = s }
        rows[r].prs[p].now = s
      }
    }
  }
}

/// A plan as groups and sessions show it: the out-of-date rows and counts.
public struct PlanSummary: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var source: PlanSource
  public var group: String?
  public var session: String?
  public var autoUpdate: Bool
  public var read: Int64?
  public var error: String?
  public var links: Int
  public var rows: Int
  public var outOfDate: [PlanRow]
  /// The Not started rows that have no follow-up yet.
  public var canFollowUp: [PlanRow]
  /// For an artifact plan: true when its copy is missing or old.
  public var copyStale: Bool?
  /// For an artifact plan: its pending update.
  public var proposal: ArtifactProposal.Summary?

  public init(_ plan: PlanDocument) {
    id = plan.id
    source = plan.source
    group = plan.group
    session = plan.session
    autoUpdate = plan.autoUpdate
    read = plan.read
    error = plan.error
    links = plan.links.count
    rows = plan.rows.count
    outOfDate = plan.rows.filter(\.outOfDate)
    canFollowUp = plan.rows.filter { $0.notStarted && $0.followup == nil }.map { row in
      var row = row
      row.ref = Plans.ref(of: row, in: plan.rows)
      return row
    }
    copyStale = plan.artifact?.stale
    proposal = plan.artifact?.proposal.map(ArtifactProposal.Summary.init)
  }
}

public enum Plans {
  public static let startMarker = "<!-- sb:status -->"
  public static let endMarker = "<!-- /sb:status -->"

  /// What a plan document holds, as sbd reads it.
  public struct Content: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
      public var text: String
      public var links: [PlanLink]
      public var number: String?
      public var item: String?
      public var status: String?
    }

    public var links: [PlanLink]
    public var rows: [Row]
    /// The text between the status markers, or nil without them.
    public var statusBlock: String?
  }

  static let prURL = try! NSRegularExpression(
    pattern: #"https?://github\.com/([\w.-]+)/([\w.-]+)/pull/([0-9]+)"#, options: [.caseInsensitive])
  static let separatorCell = try! NSRegularExpression(pattern: #"^\s*:?-+:?\s*$"#)

  /// The PR URLs in `text`, in order and without repeats.
  public static func links(in text: String) -> [PlanLink] {
    var out: [PlanLink] = []
    var seen: Set<PlanLink> = []
    for match in prURL.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let owner = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text),
        let number = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) })
      else { continue }
      let link = PlanLink(repo: "\(text[owner])/\(text[name])", number: number)
      if seen.insert(link.key).inserted { out.append(link) }
    }
    return out
  }

  /// The ranges of the first start marker and the first end marker after
  /// it. An end marker before the first start marker leaves no end.
  static func markers(_ markdown: String) -> (start: Range<String.Index>, end: Range<String.Index>?)? {
    guard let start = markdown.range(of: startMarker) else { return nil }
    if let stray = markdown.range(of: endMarker), stray.lowerBound < start.lowerBound { return (start, nil) }
    return (start, markdown.range(of: endMarker, range: start.upperBound..<markdown.endIndex))
  }

  /// The PR links and table rows outside the generated table, and the text
  /// inside it.
  public static func parse(_ markdown: String) -> Content {
    var outside = markdown
    var block: String?
    if let (start, end) = markers(markdown), let end {
      block = String(markdown[start.upperBound..<end.lowerBound])
      outside = String(markdown[..<start.lowerBound]) + "\n" + String(markdown[end.upperBound...])
    }
    let lines = outside.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    var rows: [Content.Row] = []
    var columns: Columns?
    for (i, line) in lines.enumerated() {
      guard line.hasPrefix("|") else {
        columns = nil
        continue
      }
      if isSeparator(line) { continue }
      // The line above a separator is the table's header.
      if i + 1 < lines.count, isSeparator(lines[i + 1]) {
        columns = Columns(header: cells(line))
        continue
      }
      let links = links(in: line)
      let row = cells(line)
      func cell(_ index: Int?) -> String? { index.flatMap { $0 < row.count && !row[$0].isEmpty ? row[$0] : nil } }
      let item = cell(columns?.item)
      let status = cell(columns?.status)
      guard !links.isEmpty || notStarted(item: item, status: status) else { continue }
      rows.append(Content.Row(text: line, links: links, number: cell(columns?.number), item: item, status: status))
    }
    return Content(links: links(in: outside), rows: rows, statusBlock: block)
  }

  /// Where a table's `#`, `Item`, and `Status` columns are. A table without
  /// both `Item` and `Status` has none of them.
  struct Columns {
    var number: Int?
    var item: Int?
    var status: Int?

    init(header: [String]) {
      let names = header.map { $0.lowercased() }
      guard let item = names.firstIndex(of: "item"), let status = names.firstIndex(of: "status") else { return }
      self.item = item
      self.status = status
      number = names.firstIndex(of: "#")
    }
  }

  /// The trimmed cells of a table line, which starts with `|`. A `|` after
  /// a backslash belongs to its cell and reads as `|`.
  static func cells(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var escaped = false
    for ch in line.dropFirst() {
      if escaped {
        if ch != "|" { current.append("\\") }
        current.append(ch)
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else if ch == "|" {
        cells.append(current)
        current = ""
      } else {
        current.append(ch)
      }
    }
    if escaped { current.append("\\") }
    // The text after the last `|` is a cell only when the line has no trailing `|`.
    if !current.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(current) }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// Whether a row names an item and its status cell reads Not started,
  /// ignoring case and the marks around it, such as `**Not started**` or
  /// `Not started.`.
  static func notStarted(item: String?, status: String?) -> Bool {
    guard item?.isEmpty == false, let status else { return false }
    return status.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased() == "not started"
  }

  static func isSeparator(_ line: String) -> Bool {
    guard line.hasPrefix("|") else { return false }
    let cells = line.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
    return !cells.isEmpty
      && cells.allSatisfy { separatorCell.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
  }

  /// The row that `ref` names: by its whole text, else by its `#` cell, else
  /// by its item, else by a prefix of its item that no other row has. Items
  /// compare without case.
  public static func row(_ ref: String, in rows: [PlanRow]) throws -> PlanRow {
    let key = ref.trimmingCharacters(in: .whitespaces)
    let number = key.hasPrefix("#") ? String(key.dropFirst()) : key
    let item = key.lowercased()
    let tries: [(PlanRow) -> Bool] = [
      { $0.text == key },
      { $0.number == number },
      { $0.item?.lowercased() == item },
      { $0.item?.lowercased().hasPrefix(item) == true },
    ]
    for matches in tries {
      let found = rows.filter(matches)
      if found.count == 1 { return found[0] }
      if found.count > 1 {
        throw APIError("\(key) names \(found.count) rows: \(found.map(\.label).joined(separator: ", "))")
      }
    }
    throw APIError("the plan has no row \(key) that links a PR or reads Not started")
  }

  /// The first of the row's `#` and item that `row(_:in:)` resolves to this
  /// row alone, else the row's text. A `#` that two tables share names more
  /// than one row.
  static func ref(of row: PlanRow, in rows: [PlanRow]) -> String {
    [row.number, row.item].compactMap { $0 }.first { (try? Plans.row($0, in: rows))?.text == row.text } ?? row.text
  }

  /// The text that `splice` puts between the markers for this table.
  public static func block(_ table: String) -> String { "\n\(table)\n" }

  /// The document with the text between its first pair of status markers
  /// replaced by the table.
  public static func splice(_ markdown: String, _ table: String) throws -> String {
    guard let (start, end) = markers(markdown) else {
      throw APIError("the plan has no \(startMarker) line. Add \(startMarker) and \(endMarker) where the table goes")
    }
    guard let end else {
      throw APIError("the plan needs one \(endMarker) after its first \(startMarker), and none before it")
    }
    return String(markdown[..<start.upperBound]) + block(table) + String(markdown[end.lowerBound...])
  }

  /// The generated table: one row per session, sorted by name. Nothing in it
  /// changes unless a session's state, wait, or PR does.
  public static func table(_ sessions: [SessionSummary]) -> String {
    var lines = ["| Session | State | Wait | PR |", "| --- | --- | --- | --- |"]
    for s in sessions.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) {
      let pr = s.pr.map { "[\($0.repo)#\($0.number)](\($0.url)) \($0.state.rawValue.lowercased())" } ?? ""
      let cells = [s.name, s.state.title, s.waits.first?.line ?? "", pr].map(cell)
      lines.append("| " + cells.joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n")
  }

  /// A table cell on one line. It escapes `<` as `&lt;`, so that no cell can
  /// hold a status marker.
  static func cell(_ text: String) -> String {
    oneLine(text, max: 200).replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "|", with: "\\|")
  }
}
