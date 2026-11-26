import Foundation

/// How long a PR waits between two reads.
public struct PollRates: Equatable, Sendable {
  /// The wait while the PR's checks or review are pending, or while a wait or Trunk's queue needs the PR read at
  /// the pending rate.
  public var pendingMs: Int64
  /// The wait otherwise.
  public var idleMs: Int64

  public init(pendingMs: Int64, idleMs: Int64) {
    self.pendingMs = pendingMs
    self.idleMs = idleMs
  }
}

extension PollRates {
  /// The rates of a PR, given its last read or nil before its first one, the changes that its open waits and queue
  /// need, and the changes that a source of PR changes reports for it. Every PR polls at `base`, because no source
  /// of PR changes exists yet.
  public static func of(_ pr: PullRequest?, needs: ChangeSignals, signals: ChangeSignals?, base: PollRates)
    -> PollRates
  {
    base
  }
}

/// The rates at which each PR polls. The arguments are the PR's last read, or nil before its first one, and the
/// changes that its open waits and queue need.
public struct PollPolicy: Sendable {
  public var rates: @Sendable (PullRequest?, ChangeSignals) -> PollRates

  public init(rates: @escaping @Sendable (PullRequest?, ChangeSignals) -> PollRates) {
    self.rates = rates
  }

  /// The same rates for every PR.
  public static func uniform(_ rates: PollRates) -> PollPolicy {
    PollPolicy { _, _ in rates }
  }
}

extension GitHubSettings {
  /// The rates from `pendingMs` and `idleMs`, given the signals of the source of PR changes that covers each PR,
  /// by node id.
  public func pollPolicy(covered: [String: ChangeSignals] = [:]) -> PollPolicy {
    let base = PollRates(pendingMs: pendingMs, idleMs: idleMs)
    return PollPolicy { pr, needs in .of(pr, needs: needs, signals: pr.flatMap { covered[$0.id] }, base: base) }
  }
}

/// A PR that a poll may read, with what `GitHub.readTrigger` needs to know about it.
public struct ReadCandidate: Sendable {
  /// The PR's last read, or nil before its first one.
  public var pr: PullRequest?
  public var lastPolled: Int64?
  /// The newest wait, finished turn, or expired acknowledgment that needs a read after it.
  public var waitedAt: Int64?
  /// Why the PR's read was requested, when a request reads it whether or not it is due.
  public var requested: ReadTrigger?
  /// The changes that the PR's open waits and queue need the poller to see. A PR with any need polls at the
  /// pending rate whatever its state.
  public var needs: ChangeSignals

  public init(
    pr: PullRequest?, lastPolled: Int64?, waitedAt: Int64?, requested: ReadTrigger? = nil, needs: ChangeSignals
  ) {
    self.pr = pr
    self.lastPolled = lastPolled
    self.waitedAt = waitedAt
    self.requested = requested
    self.needs = needs
  }
}

extension GitHub {
  /// Whether an open PR polls at the pending rate only because it awaits a review: no check runs, GitHub knows
  /// whether it merges, the changes that its waits need are reviews and state at most, and it awaits a review or a
  /// wait needs it. A source that reports reviews and state could slow these reads. False before the PR's first read.
  public static func onlyAwaitsReview(_ pr: PullRequest?, needs: ChangeSignals) -> Bool {
    guard let pr, pr.state == .open, !pr.isPending, needs.isSubset(of: [.reviews, .state]) else { return false }
    return pr.awaitsReview || !needs.isEmpty
  }

  /// Why a poll at `now` reads each due PR, by id. A PR that isn't due is left out. Each PR's intervals come from
  /// `policy`.
  public static func dueReads(_ candidates: [String: ReadCandidate], all: Bool, now: Int64, policy: PollPolicy)
    -> [String: ReadTrigger]
  {
    candidates.compactMapValues { c in
      let rates = policy.rates(c.pr, c.needs)
      return readTrigger(
        c.pr, lastPolled: c.lastPolled, waitedAt: c.waitedAt, requested: c.requested, all: all,
        pendingRate: !c.needs.isEmpty, now: now, pendingMs: rates.pendingMs, idleMs: rates.idleMs)
    }
  }
}
