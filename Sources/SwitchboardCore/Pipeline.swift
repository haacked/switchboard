import Foundation

/// How far a session's PR has gone toward a merge. The merge board has a
/// column for each stage before Merged.
public enum PipelineStage: String, Codable, CaseIterable, Sendable {
  case building, ci, review, ready, merging, merged

  public var title: String {
    switch self {
    case .building: "Building"
    case .ci: "CI"
    case .review: "Review"
    case .ready: "Ready"
    case .merging: "Merging"
    case .merged: "Merged"
    }
  }

  /// A merge conflict leaves the stage alone, because it is a blocker
  /// inside any stage.
  public init(_ pr: PullRequest?) {
    guard let pr else {
      self = .building
      return
    }
    switch pr.state {
    case .merged: self = .merged
    case .closed: self = .building
    case .open:
      if pr.draft {
        self = .building
      } else if pr.queue?.isHeld == true || pr.inMergeQueue == true {
        self = .merging
      } else if pr.checksRunning || pr.ciFailed {
        self = .ci
      } else if pr.reviewSatisfied {
        self = .ready
      } else {
        self = .review
      }
    }
  }
}

/// A session's stage, when it entered it, and what holds it there.
public struct Pipeline: Codable, Equatable, Sendable {
  public var stage: PipelineStage
  /// When the session entered the stage, in milliseconds since the epoch.
  public var since: Int64
  public var blocker: String?

  public init(stage: PipelineStage, since: Int64, blocker: String? = nil) {
    self.stage = stage
    self.since = since
    self.blocker = blocker
  }

  /// A session that no `pr` event has placed yet counts from `created`.
  public init(_ facts: SessionFacts, created: Int64) {
    stage = PipelineStage(facts.pr)
    since = facts.pipelineSince ?? created
    blocker = facts.pr.flatMap { Self.blocker($0, dependencies: facts.dependencies) }
  }

  /// The first thing that keeps an open PR from moving on, or nil.
  public static func blocker(_ pr: PullRequest, dependencies: [Dependency]) -> String? {
    guard pr.state == .open else { return nil }
    if pr.mergeable == .conflicting { return "conflicts with \(pr.base)" }
    guard !pr.draft else { return nil }
    if pr.checksFailed || pr.blockingDepotFailure != nil { return "CI failed" }
    if !pr.changesRequestedBy.isEmpty { return "changes requested by \(Attention.names(pr.changesRequestedBy))" }
    if let d = dependencies.first(where: \.holds) { return "waits on \(d.label(from: pr.repo))" }
    return nil
  }
}

extension SessionFacts {
  /// Restarts the stage's time when a `pr` event moves the PR from `old` to
  /// `new` and changes its stage. While the stage is CI, a new head commit
  /// starts a new run, so it restarts the time too.
  mutating func notePipeline(from old: PullRequest?, to new: PullRequest?, at t: Int64) {
    let stage = PipelineStage(new)
    if stage != PipelineStage(old) || (stage == .ci && new?.headSha != old?.headSha) { pipelineSince = t }
  }
}

/// The merge board: a lane per repo or group, and a column per stage.
/// Done sessions and merged PRs leave the columns.
public enum MergeBoard {
  public struct Lane: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sessions: [SessionSummary]
  }

  public static let columns: [PipelineStage] = [.building, .ci, .review, .ready, .merging]

  public static let otherLane = "Other"

  public static func isDone(_ s: SessionSummary) -> Bool { isDone(state: s.state, stage: s.pipeline?.stage) }

  /// The rule for the Done footer. Group suggestions also use it to leave a finished session alone.
  public static func isDone(state: AttentionState, stage: PipelineStage?) -> Bool { state == .done || stage == .merged }

  /// A session without a pipeline, such as a follow-up that hasn't started, is Building.
  public static func stage(_ s: SessionSummary) -> PipelineStage { s.pipeline?.stage ?? .building }

  /// The column's sessions: blocked ones first, then the longest in the
  /// stage, then by id.
  public static func cards(_ sessions: [SessionSummary], in stage: PipelineStage) -> [SessionSummary] {
    sessions.filter { !isDone($0) && Self.stage($0) == stage }.sorted { a, b in
      let blocked = (a.pipeline?.blocker != nil, b.pipeline?.blocker != nil)
      if blocked.0 != blocked.1 { return blocked.0 }
      let since = (a.pipeline?.since ?? a.since, b.pipeline?.since ?? b.since)
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
