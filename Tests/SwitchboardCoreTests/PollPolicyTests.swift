import Foundation
import Testing

@testable import SwitchboardCore

/// Which PRs a poll reads, at the rates that a policy gives each PR.
@Suite struct DueReadsTests {
  static let now: Int64 = 1_000_000_000
  static let rates = PollRates(pendingMs: 30_000, idleMs: 300_000)
  static let slow = PollRates(pendingMs: 600_000, idleMs: 1_800_000)

  static let pending = samplePR(checks: "PENDING")
  static let settled = samplePR(reviewDecision: .approved, checks: "SUCCESS", reviewDecisionRead: true)

  static func inRepo(_ pr: PullRequest, _ repo: String) -> PullRequest {
    var pr = pr
    pr.repo = repo
    return pr
  }

  static func candidate(
    _ pr: PullRequest?, polledAgo: Int64?, waitedAgo: Int64? = nil, pendingRate: Bool = false
  ) -> ReadCandidate {
    ReadCandidate(
      pr: pr, lastPolled: polledAgo.map { now - $0 }, waitedAt: waitedAgo.map { now - $0 },
      needs: pendingRate ? Wait.Kind.ci.needs : [])
  }

  /// The policy of `GitHubSettings` gives every PR the settings' rates.
  @Test func theSettingsPolicyGivesEveryPRTheSettingsRates() {
    var settings = GitHubSettings()
    settings.pollSeconds = 20
    settings.idlePollSeconds = 200
    let expected = PollRates(pendingMs: settings.pendingMs, idleMs: settings.idleMs)
    for pr in [nil, Self.pending, Self.inRepo(Self.settled, "haacked/switchboard")] as [PullRequest?] {
      for needs in [[], Wait.Kind.ci.needs, .all] as [ChangeSignals] {
        #expect(settings.pollPolicy().rates(pr, needs) == expected)
      }
    }
  }

  /// With one rate for every PR, a PR is due exactly when `readTrigger` says so at those rates.
  @Test(
    arguments: [nil, DueReadsTests.pending, DueReadsTests.settled] as [PullRequest?],
    [nil, 0, 29_999, 30_000, 299_999, 300_000] as [Int64?])
  func aUniformPolicyMatchesReadTrigger(_ pr: PullRequest?, _ polledAgo: Int64?) {
    for all in [false, true] {
      for pendingRate in [false, true] {
        for waitedAgo in [nil, 0, 5, 10_000_000] as [Int64?] {
          let c = Self.candidate(pr, polledAgo: polledAgo, waitedAgo: waitedAgo, pendingRate: pendingRate)
          let expected = GitHub.readTrigger(
            c.pr, lastPolled: c.lastPolled, waitedAt: c.waitedAt, all: all, pendingRate: pendingRate, now: Self.now,
            pendingMs: Self.rates.pendingMs, idleMs: Self.rates.idleMs)
          let due = GitHub.dueReads(["PR_42": c], all: all, now: Self.now, policy: .uniform(Self.rates))
          #expect(
            due["PR_42"] == expected,
            "all \(all), pendingRate \(pendingRate), waitedAgo \(String(describing: waitedAgo))")
        }
      }
    }
  }

  /// A policy that slows one repo's PRs leaves the other repo's PRs at their own rates.
  @Test func eachPRPollsAtTheRatesThatThePolicyGivesIt() {
    let policy = PollPolicy { pr, _ in pr?.repo == "haacked/switchboard" ? Self.slow : Self.rates }
    let candidates = [
      "fast-pending": Self.candidate(Self.inRepo(Self.pending, "acme/widgets"), polledAgo: Self.rates.pendingMs),
      "slow-pending": Self.candidate(Self.inRepo(Self.pending, "haacked/switchboard"), polledAgo: Self.rates.pendingMs),
      "fast-idle": Self.candidate(Self.inRepo(Self.settled, "acme/widgets"), polledAgo: Self.rates.idleMs),
      "slow-idle": Self.candidate(Self.inRepo(Self.settled, "haacked/switchboard"), polledAgo: Self.rates.idleMs),
      "slow-pending-due": Self.candidate(
        Self.inRepo(Self.pending, "haacked/switchboard"), polledAgo: Self.slow.pendingMs),
      "slow-idle-due": Self.candidate(Self.inRepo(Self.settled, "haacked/switchboard"), polledAgo: Self.slow.idleMs),
    ]
    #expect(
      GitHub.dueReads(candidates, all: false, now: Self.now, policy: policy)
        == ["fast-pending": .pending, "fast-idle": .idle, "slow-pending-due": .pending, "slow-idle-due": .idle])
  }

  /// A slow policy never delays a PR that a newer wait, `sb poll --all`, or a first read needs.
  @Test func aSlowPolicyStillReadsWaitedFirstAndAllReads() {
    let policy = PollPolicy.uniform(Self.slow)
    let candidates = [
      "waited": Self.candidate(Self.settled, polledAgo: 10, waitedAgo: 5),
      "never": Self.candidate(nil, polledAgo: nil),
      "recent": Self.candidate(Self.pending, polledAgo: 10),
    ]
    #expect(
      GitHub.dueReads(candidates, all: false, now: Self.now, policy: policy) == ["waited": .wait, "never": .first])
    #expect(
      GitHub.dueReads(candidates, all: true, now: Self.now, policy: policy)
        == ["waited": .poll, "never": .poll, "recent": .poll])
  }

  /// `pendingRate` applies to its own PR only.
  @Test func thePendingRateAppliesToItsOwnPROnly() {
    let candidates = [
      "held": Self.candidate(Self.settled, polledAgo: Self.rates.pendingMs, pendingRate: true),
      "free": Self.candidate(Self.settled, polledAgo: Self.rates.pendingMs),
    ]
    #expect(GitHub.dueReads(candidates, all: false, now: Self.now, policy: .uniform(Self.rates)) == ["held": .pending])
  }
}

/// Which PRs poll at the pending rate only because they await a review, which stage 5's slower rates would serve.
@Suite struct OnlyAwaitsReviewTests {
  static let awaiting = samplePR(reviewDecision: .reviewRequired, reviewDecisionRead: true)
  static let approved = samplePR(reviewDecision: .approved, checks: "SUCCESS", reviewDecisionRead: true)

  @Test func anOpenPRThatAwaitsReviewOnlyAwaitsReview() {
    #expect(GitHub.onlyAwaitsReview(Self.awaiting, needs: []))
  }

  @Test(arguments: [[.reviews], [.state], [.reviews, .state]] as [ChangeSignals])
  func aWaitThatNeedsOnlyReviewsOrStateOnlyAwaitsReview(_ needs: ChangeSignals) {
    #expect(GitHub.onlyAwaitsReview(Self.awaiting, needs: needs))
  }

  @Test(arguments: [nil, "SUCCESS", "FAILURE", "ERROR"] as [String?])
  func aPRWhoseChecksAreNotRunningOnlyAwaitsReview(_ checks: String?) {
    #expect(GitHub.onlyAwaitsReview(samplePR(reviewDecision: .reviewRequired, checks: checks), needs: []))
  }

  /// An approved PR that a `merge` or `review` wait reads at the pending rate only awaits that review or merge.
  @Test(arguments: [[.state], [.reviews]] as [ChangeSignals])
  func anApprovedPRWithAReviewOrMergeWaitOnlyAwaitsReview(_ needs: ChangeSignals) {
    #expect(GitHub.onlyAwaitsReview(Self.approved, needs: needs))
  }

  @Test func anApprovedPRWithoutAWaitDoesNotPollAtThePendingRate() {
    #expect(!GitHub.onlyAwaitsReview(Self.approved, needs: []))
  }

  @Test(arguments: ["PENDING", "EXPECTED"])
  func aPRWithRunningChecksDoesNotOnlyAwaitReview(_ checks: String) {
    #expect(!GitHub.onlyAwaitsReview(samplePR(reviewDecision: .reviewRequired, checks: checks), needs: [.reviews]))
  }

  @Test func aPRWhoseMergeabilityIsUnknownDoesNotOnlyAwaitReview() {
    #expect(!GitHub.onlyAwaitsReview(samplePR(mergeable: .unknown, reviewDecision: .reviewRequired), needs: []))
  }

  @Test(arguments: [.merged, .closed] as [PRState])
  func aPRThatIsNotOpenDoesNotOnlyAwaitReview(_ state: PRState) {
    #expect(!GitHub.onlyAwaitsReview(samplePR(state: state, reviewDecision: .reviewRequired), needs: [.state]))
  }

  @Test(
    arguments: [
      Wait.Kind.ci.needs, Wait.Kind.queue.needs, Wait.Kind.deploy.needs, [.reviews, .comments], [.head], .all,
    ] as [ChangeSignals])
  func aWaitThatNeedsMoreThanReviewsAndStateDoesNotOnlyAwaitReview(_ needs: ChangeSignals) {
    #expect(!GitHub.onlyAwaitsReview(Self.awaiting, needs: needs))
  }

  /// A draft doesn't await review, so only a wait can put it at the pending rate.
  @Test func aDraftWithoutAWaitDoesNotOnlyAwaitReview() {
    #expect(!GitHub.onlyAwaitsReview(samplePR(draft: true, reviewDecision: .reviewRequired), needs: []))
  }

  @Test func aDraftWithAReviewWaitOnlyAwaitsReview() {
    #expect(GitHub.onlyAwaitsReview(samplePR(draft: true, reviewDecision: .reviewRequired), needs: [.reviews]))
  }

  /// Only UNKNOWN keeps a PR pending. A PR that GitHub gave no mergeability for is not pending.
  @Test func aPRWithoutAMergeabilityOnlyAwaitsReview() {
    #expect(GitHub.onlyAwaitsReview(samplePR(mergeable: nil, reviewDecision: .reviewRequired), needs: []))
  }

  @Test(arguments: [[], [.reviews], .all] as [ChangeSignals])
  func aPRThatWasNeverReadDoesNotOnlyAwaitReview(_ needs: ChangeSignals) {
    #expect(!GitHub.onlyAwaitsReview(nil, needs: needs))
  }
}
