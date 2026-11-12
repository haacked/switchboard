import Foundation

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

  /// The stage of a PR in that state. A deployed PR reads as merged, because
  /// GitHub's PR state has no deployed value.
  public init(_ state: PRState) {
    switch state {
    case .open: self = .open
    case .merged: self = .merged
    case .closed: self = .closed
    }
  }
}

/// The table of a plan that a new row goes into: the one with `Item` and
/// `Status` columns that holds the most rows.
public struct PlanTable: Codable, Equatable, Sendable {
  public var header: [String]
  /// The table's last line, trimmed. A new row goes after it.
  public var last: String
  /// The largest number in the `#` column, or nil when it has none.
  public var lastNumber: Int?

  public init(header: [String], last: String, lastNumber: Int? = nil) {
    self.header = header
    self.last = last
    self.lastNumber = lastNumber
  }
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
  /// The index of the status cell among the row's cells.
  public var statusColumn: Int?
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
  public var workTable: PlanTable?
  /// The update that waits for the user's Apply or Reject.
  public var proposal: PlanProposal?
  /// When sbd last asked the model for an update, in ms since the epoch.
  public var proposed: Int64?
  /// The key of the last batch that the user rejected or that changed no
  /// cell. Later polls don't propose that batch again.
  public var settled: String?
  /// Why sbd ran no update, or nil after one ran.
  public var updateNote: String?
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
      kept.statusColumn = row.statusColumn
      return kept
    }
    statusBlock = content.statusBlock
    workTable = content.workTable
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
  /// The id of the update that waits for the user.
  public var update: String?
  public var updateNote: String?
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
    update = plan.proposal?.id
    updateNote = plan.updateNote
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
      /// The index of the status cell among the row's cells, or nil when its
      /// table has no `Item` and `Status` columns.
      public var statusColumn: Int?
    }

    public var links: [PlanLink]
    public var rows: [Row]
    /// The text between the status markers, or nil without them.
    public var statusBlock: String?
    public var workTable: PlanTable?
  }

  static let prURL = try! NSRegularExpression(
    pattern: #"https?://github\.com/([\w.-]+)/([\w.-]+)/pull/([0-9]+)"#, options: [.caseInsensitive])

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
}
