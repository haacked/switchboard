import Foundation
import Testing

@testable import SwitchboardCore

/// The order in which sbd asks the sources of PR changes to report its PRs.
@Suite struct PRInterestTests {
  static func ref(_ number: Int, repo: String = "acme/widgets") -> PRRef {
    PRRef(forge: "github.com", repo: repo, number: number)
  }

  static func pr(
    _ number: Int, repo: String = "acme/widgets", open: Bool = true, waitedAt: Int64? = nil, pending: Bool = false,
    live: Bool = false
  ) -> PRInterest {
    PRInterest(ref: ref(number, repo: repo), open: open, waitedAt: waitedAt, pending: pending, live: live)
  }

  /// PRs with an open wait come first, the newest wait first.
  @Test func prsWithAnOpenWaitComeFirstNewestWaitFirst() {
    let prs = [
      Self.pr(1), Self.pr(2, waitedAt: 100), Self.pr(3, pending: true, live: true), Self.pr(4, waitedAt: 300),
      Self.pr(5, waitedAt: 200),
    ]

    let ranked = PRInterest.ranked(prs)

    #expect(ranked == [Self.ref(4), Self.ref(5), Self.ref(2), Self.ref(3), Self.ref(1)])
  }

  /// A waited-on PR ranks first even when it is neither pending nor shown by a live session.
  @Test func aWaitRanksAPRFirstWhateverItsState() {
    let prs = [Self.pr(1, pending: true, live: true), Self.pr(2, waitedAt: 50)]

    #expect(PRInterest.ranked(prs) == [Self.ref(2), Self.ref(1)])
  }

  /// Pending PRs of live sessions come after the waited-on PRs and before the other open PRs.
  @Test func pendingPRsOfLiveSessionsComeBeforeTheOtherOpenPRs() {
    let prs = [
      Self.pr(1, live: true), Self.pr(2, pending: true), Self.pr(3, pending: true, live: true), Self.pr(4),
      Self.pr(5, waitedAt: 10),
    ]

    let ranked = PRInterest.ranked(prs)

    #expect(ranked == [Self.ref(5), Self.ref(3), Self.ref(1), Self.ref(2), Self.ref(4)])
  }

  /// A PR that is pending but has no live session, or live but not pending, ranks with the other open PRs.
  @Test(arguments: [(true, false), (false, true), (false, false)])
  func aPRThatIsNotBothPendingAndLiveRanksWithTheOtherOpenPRs(_ pending: Bool, _ live: Bool) {
    let prs = [Self.pr(2), Self.pr(1, pending: pending, live: live), Self.pr(3, pending: true, live: true)]

    #expect(PRInterest.ranked(prs) == [Self.ref(3), Self.ref(1), Self.ref(2)])
  }

  /// Merged and closed PRs are left out, even with an open wait or a pending check in a live session.
  @Test(arguments: [
    PRInterestTests.pr(9, open: false), PRInterestTests.pr(9, open: false, waitedAt: 1_000),
    PRInterestTests.pr(9, open: false, pending: true, live: true),
  ])
  func mergedAndClosedPRsAreLeftOut(_ finished: PRInterest) {
    let prs = [Self.pr(1), finished, Self.pr(2, waitedAt: 5)]

    #expect(PRInterest.ranked(prs) == [Self.ref(2), Self.ref(1)])
  }

  /// PRs of one rank are ordered by repo, then by number as a number.
  @Test func prsOfOneRankAreOrderedByRepoThenNumber() {
    let prs = [
      Self.pr(2, repo: "acme/gadgets"), Self.pr(1, repo: "acme/widgets"), Self.pr(10, repo: "acme/gadgets"),
      Self.pr(5, repo: "acme/alpha"),
    ]

    let ranked = PRInterest.ranked(prs)

    #expect(
      ranked == [
        Self.ref(5, repo: "acme/alpha"), Self.ref(2, repo: "acme/gadgets"), Self.ref(10, repo: "acme/gadgets"),
        Self.ref(1, repo: "acme/widgets"),
      ])
  }

  /// Two waits set at the same time are ordered by repo, then by number.
  @Test func waitsOfOneTimeAreOrderedByRepoThenNumber() {
    let prs = [Self.pr(8, waitedAt: 100), Self.pr(3, waitedAt: 100), Self.pr(4, repo: "acme/gadgets", waitedAt: 100)]

    #expect(PRInterest.ranked(prs) == [Self.ref(4, repo: "acme/gadgets"), Self.ref(3), Self.ref(8)])
  }

  /// The order of the input doesn't change the ranking.
  @Test func theRankingDoesNotDependOnTheInputOrder() {
    let prs = [
      Self.pr(1), Self.pr(2, waitedAt: 100), Self.pr(3, pending: true, live: true), Self.pr(4, waitedAt: 300),
      Self.pr(5, open: false), Self.pr(6, pending: true),
    ]

    #expect(PRInterest.ranked(prs) == PRInterest.ranked(prs.reversed()))
  }

  @Test func noPRsGiveAnEmptyList() {
    #expect(PRInterest.ranked([]).isEmpty)
  }
}
