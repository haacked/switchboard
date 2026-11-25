import Foundation
import Testing

@testable import SwitchboardCore

/// The kinds of PR change that a wait needs the poller to see, and the rates that follow from them.
@Suite struct ChangeSignalsTests {
  static let now: Int64 = 1_000_000_000
  static let rates = PollRates(pendingMs: 30_000, idleMs: 300_000)

  static let pending = samplePR(checks: "PENDING")
  static let awaitingReview = samplePR(reviewDecision: .reviewRequired, checks: "SUCCESS", reviewDecisionRead: true)
  static let settled = samplePR(reviewDecision: .approved, checks: "SUCCESS", reviewDecisionRead: true)

  static let members: [ChangeSignals] = [
    .head, .checkSuites, .checkRuns, .commitStatuses, .reviews, .state, .conflict, .comments, .mergeQueue, .labels,
  ]

  /// The needs that the tests try: none, each member alone, two members, and every member.
  static let needsSets: [ChangeSignals] = {
    var sets: [ChangeSignals] = [[]]
    sets.append(contentsOf: ChangeSignalsTests.members)
    sets.append([.reviews, .state])
    sets.append(ChangeSignals(ChangeSignalsTests.members))
    return sets
  }()

  /// Each member is a change of its own, which no other member includes.
  @Test func eachMemberIsDistinctFromTheOthers() {
    for (i, a) in Self.members.enumerated() {
      #expect(!a.isEmpty, "member \(i)")
      for (j, b) in Self.members.enumerated() where i != j {
        #expect(a.isDisjoint(with: b), "members \(i) and \(j)")
      }
    }
  }

  /// Every wait kind needs at least one change, so a PR with any open wait polls at the pending rate.
  @Test(arguments: Wait.Kind.allCases)
  func everyWaitKindNeedsAChange(_ kind: Wait.Kind) {
    #expect(!kind.needs.isEmpty)
  }

  /// A `ci` wait needs the check suites, check runs, and commit statuses.
  @Test func aCIWaitNeedsTheCheckSignals() {
    #expect(Wait.Kind.ci.needs.isSuperset(of: [.checkSuites, .checkRuns, .commitStatuses]))
  }

  /// A `review` wait needs the reviews.
  @Test func aReviewWaitNeedsTheReviews() {
    #expect(Wait.Kind.review.needs.contains(.reviews))
  }

  /// A `merge` wait needs the PR's state.
  @Test func aMergeWaitNeedsTheState() {
    #expect(Wait.Kind.merge.needs.contains(.state))
  }

  /// A `queue` wait needs the comments, where Trunk reports the queue.
  @Test func aQueueWaitNeedsTheComments() {
    #expect(Wait.Kind.queue.needs.contains(.comments))
  }

  /// A settled PR that a wait of any kind needs reads at the pending rate.
  @Test(arguments: Wait.Kind.allCases)
  func aSettledPRWithAWaitOfAnyKindPollsAtThePendingRate(_ kind: Wait.Kind) {
    let c = ReadCandidate(
      pr: Self.settled, lastPolled: Self.now - Self.rates.pendingMs, waitedAt: nil, needs: kind.needs)

    let due = GitHub.dueReads(["PR_42": c], all: false, now: Self.now, policy: .uniform(Self.rates))

    #expect(due["PR_42"] == .pending)
  }

  /// A settled PR with no needs waits for the idle interval.
  @Test func aSettledPRWithNoNeedsPollsAtTheIdleRate() {
    let early = ReadCandidate(pr: Self.settled, lastPolled: Self.now - Self.rates.pendingMs, waitedAt: nil, needs: [])
    let late = ReadCandidate(pr: Self.settled, lastPolled: Self.now - Self.rates.idleMs, waitedAt: nil, needs: [])

    let due = GitHub.dueReads(
      ["early": early, "late": late], all: false, now: Self.now, policy: .uniform(Self.rates))

    #expect(due == ["late": .idle])
  }

  /// Non-empty needs read a PR exactly as `pendingRate: true` did, and empty needs exactly as `pendingRate: false`
  /// did, for every PR state, read age, wait, request, and `all`.
  @Test(
    arguments: [nil, ChangeSignalsTests.pending, ChangeSignalsTests.awaitingReview, ChangeSignalsTests.settled]
      as [PullRequest?],
    [nil, 0, 1, 29_999, 30_000, 299_999, 300_000] as [Int64?])
  func needsMatchThePendingRate(_ pr: PullRequest?, _ polledAgo: Int64?) {
    let lastPolled = polledAgo.map { Self.now - $0 }
    for needs in Self.needsSets {
      for all in [false, true] {
        for waitedAgo in [nil, 0, 5, 10_000_000] as [Int64?] {
          for requested in [nil, ReadTrigger.event] {
            let c = ReadCandidate(
              pr: pr, lastPolled: lastPolled, waitedAt: waitedAgo.map { Self.now - $0 }, requested: requested,
              needs: needs)
            let expected = GitHub.readTrigger(
              pr, lastPolled: c.lastPolled, waitedAt: c.waitedAt, requested: requested, all: all,
              pendingRate: !needs.isEmpty, now: Self.now, pendingMs: Self.rates.pendingMs,
              idleMs: Self.rates.idleMs)

            let due = GitHub.dueReads(["PR_42": c], all: all, now: Self.now, policy: .uniform(Self.rates))

            let waited = String(describing: waitedAgo)
            #expect(
              due["PR_42"] == expected,
              "needs \(needs.rawValue), all \(all), waitedAgo \(waited), requested \(String(describing: requested))")
          }
        }
      }
    }
  }

  /// With no signals from a source of PR changes, every PR polls at the base rates whatever it needs.
  @Test(
    arguments: [nil, ChangeSignalsTests.pending, ChangeSignalsTests.awaitingReview, ChangeSignalsTests.settled]
      as [PullRequest?])
  func noSignalsGiveTheBaseRates(_ pr: PullRequest?) {
    for needs in Self.needsSets {
      #expect(PollRates.of(pr, needs: needs, signals: nil, base: Self.rates) == Self.rates, "needs \(needs.rawValue)")
    }
  }

  /// The policy of `GitHubSettings` gives every PR the settings' rates whatever it needs.
  @Test(
    arguments: [nil, ChangeSignalsTests.pending, ChangeSignalsTests.awaitingReview, ChangeSignalsTests.settled]
      as [PullRequest?])
  func theSettingsPolicyGivesTheSettingsRatesWhateverThePRNeeds(_ pr: PullRequest?) {
    var settings = GitHubSettings()
    settings.pollSeconds = 20
    settings.idlePollSeconds = 200
    let expected = PollRates(pendingMs: settings.pendingMs, idleMs: settings.idleMs)

    for needs in Self.needsSets {
      #expect(settings.pollPolicy.rates(pr, needs) == expected, "needs \(needs.rawValue)")
    }
  }
}
