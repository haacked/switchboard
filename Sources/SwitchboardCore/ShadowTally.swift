import Foundation

/// What shadow mode measures for one source of PR changes: for each signal, when a normal poll first showed its
/// change, and each poll that showed a change of a PR that the source was live for without a signal.
public struct ShadowTally: Equatable, Sendable {
  /// The fields of a read that a signal can announce.
  public struct Snapshot: Equatable, Sendable {
    public var head: String
    public var state: String
    public var draft: Bool
    /// The number of reviews that the read holds. The status query reads the last 20, so the count stops at 20 and
    /// `lastReview` tells a later review apart.
    public var reviews: Int
    /// When the newest review was submitted.
    public var lastReview: String?
    /// The check rollup state.
    public var checks: String?
    public var mergeable: String?

    public init(
      head: String, state: String, draft: Bool, reviews: Int, checks: String?, mergeable: String?,
      lastReview: String? = nil
    ) {
      self.head = head
      self.state = state
      self.draft = draft
      self.reviews = reviews
      self.lastReview = lastReview
      self.checks = checks
      self.mergeable = mergeable
    }

    public init(_ pr: PullRequest) {
      let submitted = pr.reviews.filter { !$0.isPending }
      self.init(
        head: pr.headSha, state: pr.state.rawValue, draft: pr.draft, reviews: submitted.count, checks: pr.checks,
        mergeable: pr.mergeable?.rawValue, lastReview: submitted.last?.submittedAt)
    }

    /// The kinds of signal that announce a change from `old` to this snapshot.
    func changes(from old: Snapshot) -> Set<PRSignal.Kind> {
      var kinds: Set<PRSignal.Kind> = []
      if head != old.head { kinds.insert(.head) }
      if state != old.state || draft != old.draft { kinds.insert(.state) }
      if reviews != old.reviews || lastReview != old.lastReview { kinds.insert(.review) }
      if checks != old.checks { kinds.insert(.checks) }
      if mergeable != old.mergeable { kinds.insert(.conflict) }
      return kinds
    }
  }

  /// How long a signal waits for a poll that shows its change, and how long a signal's time is kept.
  static let keepMs: Int64 = 600_000
  /// A poll that shows a change counts a miss unless a signal for the PR came this soon before it, or since the
  /// PR's previous read.
  static let missWindowMs: Int64 = 60_000
  /// The most lead times kept for the median.
  static let leadsKept = 1_000

  private struct Pending: Equatable, Sendable {
    var pr: String
    var kind: PRSignal.Kind
    var at: Int64
  }

  private var pending: [Pending] = []
  /// When each signal of the last `keepMs` arrived, by PR.
  private var arrivals: [String: [Int64]] = [:]
  private var leads: [Int64] = []
  public private(set) var matched = 0
  public private(set) var unmatched = 0
  public private(set) var misses = 0

  public init() {}

  /// The median time from a matched signal to the poll that showed its change, in ms.
  public var medianLeadMs: Int64? { leads.isEmpty ? nil : leads.sorted()[leads.count / 2] }

  public mutating func signal(_ pr: String, kind: PRSignal.Kind, at: Int64) {
    pending.append(Pending(pr: pr, kind: kind, at: at))
    arrivals[pr, default: []].append(at)
  }

  /// Takes a read of `pr` at `polled`. `previous` is the PR's last read and its time, or nil for its first read.
  /// `liveSince` is when the source went live for the PR, or nil when it isn't live. Each pending signal from
  /// before the read whose change the read shows counts as matched once. A change of the head, state, draft flag,
  /// reviews, or checks counts a miss when the source was live since before the previous read and no signal came
  /// in the window before the read. Returns the changed fields when it counts a miss.
  @discardableResult
  public mutating func read(
    _ pr: String, previous: (snapshot: Snapshot, polled: Int64)?, now snapshot: Snapshot, polled: Int64,
    liveSince: Int64?
  ) -> [String] {
    guard let previous else { return [] }
    let changed = snapshot.changes(from: previous.snapshot)
    guard !changed.isEmpty else { return [] }
    pending.removeAll { p in
      guard p.pr == pr, p.at <= polled, p.kind == .other || changed.contains(p.kind) else { return false }
      matched += 1
      leads.append(polled - p.at)
      return true
    }
    if leads.count > Self.leadsKept { leads.removeFirst(leads.count - Self.leadsKept) }
    let announced: [(PRSignal.Kind, String)] = [
      (.head, "head"), (.state, "state"), (.review, "reviews"), (.checks, "checks"),
    ]
    let fields = announced.filter { changed.contains($0.0) }.map(\.1)
    guard !fields.isEmpty, let since = liveSince, since <= previous.polled else { return [] }
    let start = min(previous.polled, polled - Self.missWindowMs)
    guard !(arrivals[pr] ?? []).contains(where: { $0 >= start && $0 <= polled }) else { return [] }
    misses += 1
    return fields
  }

  /// Counts each signal that waited `keepMs` without a poll that showed its change as unmatched, and forgets
  /// signal times older than that.
  public mutating func prune(now: Int64) {
    let before = pending.count
    pending.removeAll { now - $0.at >= Self.keepMs }
    unmatched += before - pending.count
    arrivals = arrivals.compactMapValues { times in
      let kept = times.filter { now - $0 < Self.keepMs }
      return kept.isEmpty ? nil : kept
    }
  }
}
