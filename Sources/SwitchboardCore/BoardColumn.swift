import Foundation

/// Where a work session's task is in its flow. The board has a column for
/// each, left to right, with Done as its footer.
public enum BoardColumn: String, Codable, CaseIterable, Sendable {
  case inProgress = "in_progress"
  case waiting
  case inReview = "in_review"
  case approved
  case merging
  case done

  public var title: String {
    switch self {
    case .inProgress: "In progress"
    case .waiting: "Waiting"
    case .inReview: "In review"
    case .approved: "Approved"
    case .merging: "Merging"
    case .done: "Done"
    }
  }

  /// How far the PR has gone, for moves back. In progress and Waiting are
  /// not PR columns, so they rank with a PR that no PR column claims.
  var rank: Int {
    switch self {
    case .inProgress, .waiting: 0
    case .inReview: 1
    case .approved: 2
    case .merging: 3
    case .done: 4
    }
  }

  /// The session's column, from its attention state, its open waits, and its
  /// facts. The first rule that matches wins: Done, Merging, In progress,
  /// Approved, In review, and Waiting. `acknowledged` is true when
  /// `Attention.shown` moved an acknowledged Inbox verdict to Waiting. It
  /// decides only a Waiting card's holder. `stateSince` is when the session
  /// entered `state`. A session that no `pr` event has placed counts its PR
  /// column from `created`.
  public static func place(
    state: AttentionState, acknowledged: Bool = false, stateSince: Int64, waits: [Wait], facts: SessionFacts,
    created: Int64
  ) -> BoardPlacement {
    var placement = column(
      state: state, acknowledged: acknowledged, stateSince: stateSince, waits: waits, facts: facts, created: created)
    placement.back = facts.boardBack
    return placement
  }

  private static func column(
    state: AttentionState, acknowledged: Bool, stateSince: Int64, waits: [Wait], facts: SessionFacts, created: Int64
  ) -> BoardPlacement {
    let pr = facts.pr
    let column = prColumn(pr)
    let prSince = facts.boardSince ?? created
    if MergeBoard.isDone(state: state, column: column) { return BoardPlacement(column: .done, since: stateSince) }
    if let pr, column == .merging {
      let phrase = TrunkQueueState.phrase(pr.queue, label: pr.queueLabel, inMergeQueue: pr.inMergeQueue)
      let line = phrase.map { $0 + (pr.queueText.map { ": \($0)" } ?? "") }
      return BoardPlacement(column: .merging, since: prSince, line: line)
    }
    if state == .working || state == .notStarted { return BoardPlacement(column: .inProgress, since: stateSince) }
    if let pr, column == .approved {
      let line = pr.approvers.isEmpty ? nil : "approved by \(Attention.names(pr.approvers))"
      return BoardPlacement(column: .approved, since: prSince, line: line)
    }
    if let pr, column == .inReview {
      let names = reviewers(facts)
      let line =
        "waits on \(names.isEmpty ? "a review" : Attention.names(names))" + (pr.checksRunning ? ", CI running" : "")
      return BoardPlacement(column: .inReview, since: prSince, line: line, reviewers: names.isEmpty ? nil : names)
    }
    let oldest = waits.min { $0.created < $1.created }
    let on = waitingOn(oldest, facts)
    let yours = acknowledged || [.needsYou, .readyToMerge, .canContinue, .stale].contains(state)
    return BoardPlacement(
      column: .waiting, since: oldest?.created ?? stateSince, line: on?.line, holder: yours ? .you : on?.holder)
  }

  /// The column that the PR alone gives, or nil when no PR column claims it.
  /// It decides the PR columns of `place`, `SessionFacts.boardSince`, and
  /// moves back, so the three always agree.
  static func prColumn(_ pr: PullRequest?) -> BoardColumn? {
    guard let pr else { return nil }
    if pr.state == .merged { return .done }
    // Trunk drops a draft from its queue, and GitHub's queue holds no draft.
    guard pr.ready else { return nil }
    if pr.queue?.isHeld == true || pr.inMergeQueue == true { return .merging }
    guard !pr.ciFailed, pr.mergeable != .conflicting else { return nil }
    if pr.reviewSatisfied && !pr.checksRunning { return .approved }
    // A branch that requires no review still waits on a reviewer whom someone asked.
    let awaits =
      pr.needsReview == true
      || (pr.needsReview == false && pr.reviewDecision == nil && pr.reviewRequests?.isEmpty == false)
    return awaits && pr.changesRequestedLine == nil ? .inReview : nil
  }

  /// The reviewers that the PR asks, as its code owner requests and
  /// `requestedReviewers` name them, once each. A reviewer that both name keeps
  /// the code owner form, which carries the `@` and a team's org.
  static func reviewers(_ facts: SessionFacts) -> [String] {
    var seen = Set<String>()
    return ((facts.pr?.codeOwnerRequests ?? []) + (facts.requestedReviewers ?? [])).filter { name in
      let bare = name.lowercased().drop { $0 == "@" }.split(separator: "/").last.map(String.init) ?? ""
      return seen.insert(bare).inserted
    }
  }

  /// What a Waiting card waits on and who holds it, from the first of these
  /// that applies: the oldest open wait, a dependency that holds the PR, a
  /// running background job, and the open PR's running checks, failed checks,
  /// conflict, or change request. A `review` or `approval` wait names a
  /// person, so it gives no holder.
  static func waitingOn(_ oldest: Wait?, _ facts: SessionFacts) -> (holder: BoardHolder?, line: String)? {
    if let wait = oldest {
      let holder: BoardHolder? =
        switch wait.kind {
        case .session: .session
        case .manual: .you
        case .review, .approval: nil
        case .ci, .queue, .merge, .deploy, .date, .botReview: .machine
        }
      return (holder, wait.line)
    }
    if let d = facts.dependencies.first(where: \.holds) {
      return (d.session == nil ? .machine : .session, d.waitLine(from: facts.pr?.repo ?? d.repo))
    }
    if facts.jobs > 0 { return (.machine, facts.jobs == 1 ? "a background job" : "\(facts.jobs) background jobs") }
    guard let pr = facts.pr, pr.state == .open else { return nil }
    if pr.checksRunning { return (.machine, "CI running") }
    if pr.ciFailed { return (.you, "CI failed") }
    if pr.mergeable == .conflicting { return (.you, "conflicts with \(pr.base)") }
    if let changes = pr.changesRequestedLine { return (.you, changes) }
    return nil
  }
}

/// Who holds a Waiting card.
public enum BoardHolder: String, Codable, Sendable {
  case you
  /// CI, a queue, a deploy, a timer, a background job, or a PR that no session owns.
  case machine
  /// Another session.
  case session
}

/// The column that a session's PR left when a `pr` event moved it back, and why.
public struct BoardMove: Codable, Equatable, Sendable {
  public var from: BoardColumn
  public var reason: String
  /// Milliseconds since the epoch.
  public var at: Int64

  public init(from: BoardColumn, reason: String, at: Int64) {
    self.from = from
    self.reason = reason
    self.at = at
  }

  /// "back from Merging: CI failed", as the card and `sb get` show it.
  public var text: String { "back from \(from.title): \(reason)" }

  /// Why the same PR left `from` between `old` and `new`, or nil when no
  /// listed reason applies, as for checks that run again on the same head.
  static func reason(leaving from: BoardColumn, _ old: PullRequest, _ new: PullRequest) -> String? {
    if from == .merging {
      if new.queue == .removed {
        guard let label = new.queueLabel else { return "removed from the queue" }
        return "removed from the queue (\(label))" + (new.queueText.map { ": \($0)" } ?? "")
      }
      return old.inMergeQueue == true && new.inMergeQueue == false ? "left the merge queue" : nil
    }
    if new.draft { return "back to draft" }
    if new.headSha != old.headSha { return "new commits" }
    if new.ciFailed { return "CI failed" }
    if new.mergeable == .conflicting { return "conflicts with \(new.base)" }
    if let changes = new.changesRequestedLine { return changes }
    if (old.reviewDecision == .approved && new.reviewDecision != .approved)
      || (!old.approvers.isEmpty && new.approvers.isEmpty)
    {
      return "approval dismissed"
    }
    return nil
  }
}

/// A work session's place on the board.
public struct BoardPlacement: Codable, Equatable, Sendable {
  public var column: BoardColumn
  /// When the session entered the column, in milliseconds since the epoch.
  public var since: Int64
  /// What the card waits on, who approved it, or the queue's state. nil in
  /// In progress, whose card shows the session's reason, and in Done.
  public var line: String?
  /// Who holds a Waiting card. nil in the other columns.
  public var holder: BoardHolder?
  /// The reviewers that an In review card waits on: a login or a team's bare
  /// slug from the review requests, or `@login` or `@org/team` from the code
  /// owner requests.
  public var reviewers: [String]?
  /// The last move back of the session's PR, while it stands.
  public var back: BoardMove?

  public init(
    column: BoardColumn, since: Int64, line: String? = nil, holder: BoardHolder? = nil, reviewers: [String]? = nil,
    back: BoardMove? = nil
  ) {
    self.column = column
    self.since = since
    self.line = line
    self.holder = holder
    self.reviewers = reviewers
    self.back = back
  }
}

extension SessionFacts {
  /// Restarts the PR column's time when a `pr` event changes the PR's column
  /// or swaps the PR. Records a move back when the same PR's rank drops for a
  /// listed reason. Clears the note once the PR's rank reaches the column it
  /// left, and when the PR changes or goes away.
  mutating func noteBoard(from old: PullRequest?, to new: PullRequest?, at t: Int64) {
    let was = BoardColumn.prColumn(old)
    let now = BoardColumn.prColumn(new)
    if was != now || old?.id != new?.id { boardSince = t }
    guard let old, let new, old.id == new.id else {
      boardBack = nil
      return
    }
    let rank = now?.rank ?? 0
    if let back = boardBack, rank >= back.from.rank { boardBack = nil }
    if let from = was, rank < from.rank, let reason = BoardMove.reason(leaving: from, old, new) {
      boardBack = BoardMove(from: from, reason: reason, at: t)
    }
  }
}

/// The board: a lane per repo or group, and a column for each of
/// `columns`. Done sessions and merged PRs leave the columns.
public enum MergeBoard {
  public struct Lane: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sessions: [SessionSummary]
  }

  public static let columns: [BoardColumn] = [.inProgress, .waiting, .inReview, .approved, .merging]

  public static let otherLane = "Other"

  public static func isDone(_ s: SessionSummary) -> Bool { isDone(state: s.state, column: s.board?.column) }

  /// The rule for the Done footer.
  public static func isDone(state: AttentionState, column: BoardColumn?) -> Bool { state == .done || column == .done }

  /// Whether the session is Done from its state and PR alone. Group suggestions use it to leave a finished session alone.
  public static func isDone(state: AttentionState, pr: PullRequest?) -> Bool {
    isDone(state: state, column: BoardColumn.prColumn(pr))
  }

  /// A session without a placement, such as a follow-up that hasn't started, is In progress.
  public static func column(_ s: SessionSummary) -> BoardColumn { s.board?.column ?? .inProgress }

  /// The column's sessions: the longest in the column first, then by id.
  public static func cards(_ sessions: [SessionSummary], in column: BoardColumn) -> [SessionSummary] {
    sessions.filter { !isDone($0) && Self.column($0) == column }.sorted { a, b in
      let since = (a.board?.since ?? a.since, b.board?.since ?? b.since)
      if since.0 != since.1 { return since.0 < since.1 }
      return a.id < b.id
    }
  }

  /// A lane per repo label, ordered by title. A session without a label goes in Other.
  public static func repoLanes(_ sessions: [SessionSummary], labels: [String: String]) -> [Lane] {
    let byLabel = Dictionary(grouping: sessions.filter { !isDone($0) }) { labels[$0.id] ?? otherLane }
    return byLabel.keys.sorted().map { Lane(id: $0, title: $0, sessions: byLabel[$0]!) }
  }
}
