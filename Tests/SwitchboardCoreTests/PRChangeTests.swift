import Foundation
import Testing

@testable import SwitchboardCore

/// Which PRs a coverage scope holds.
@Suite struct CoverageScopeTests {
  static let pr7 = PRRef(repo: "acme/widgets", number: 7)
  static let pr8 = PRRef(repo: "acme/gears", number: 8)

  @Test func aPRScopeHoldsOnlyItsPR() {
    #expect(CoverageChange.Scope.pr(Self.pr7).contains(Self.pr7))
    #expect(!CoverageChange.Scope.pr(Self.pr7).contains(Self.pr8))
    #expect(!CoverageChange.Scope.pr(Self.pr7).contains(PRRef(forge: "gitlab.com", repo: "acme/widgets", number: 7)))
  }

  @Test func aReposScopeHoldsEveryPRInItsRepos() {
    let scope = CoverageChange.Scope.repos(["acme/widgets"])
    #expect(scope.contains(Self.pr7))
    #expect(!scope.contains(Self.pr8))
  }

  @Test func everythingHoldsEveryPR() {
    #expect(CoverageChange.Scope.everything.contains(Self.pr7))
    #expect(CoverageChange.Scope.everything.contains(CoverageChange.Scope.repos(["acme/gears"])))
  }

  @Test func aScopeHoldsAnotherWhenItHoldsEachOfItsPRs() {
    let both = CoverageChange.Scope.repos(["acme/widgets", "acme/gears"])
    #expect(both.contains(CoverageChange.Scope.pr(Self.pr7)))
    #expect(both.contains(CoverageChange.Scope.repos(["acme/gears"])))
    #expect(!CoverageChange.Scope.repos(["acme/gears"]).contains(both))
    #expect(!CoverageChange.Scope.pr(Self.pr7).contains(CoverageChange.Scope.repos(["acme/widgets"])))
    #expect(!both.contains(CoverageChange.Scope.everything))
  }
}

/// The lines that `sb sources` prints.
@Suite struct PRSourcesTextTests {
  static let now: Int64 = 1_000_000_000

  @Test func noProviderSaysThatSbdPollsEveryPR() {
    #expect(
      PRSources(providers: []).lines(now: Self.now) == ["no sources of PR changes: sbd polls GitHub for every PR"])
  }

  @Test func aLiveProviderShowsItsCounts() {
    let source = PRSources.Source(
      id: "github-events", state: "live", changedAt: Self.now - 120_000, wanted: 45, covered: 42, signals: 10,
      reads: 4, lastSignalAt: Self.now - 5_000, counts: ["streams": 42, "reconnects": 1])

    #expect(
      PRSources(providers: [source]).lines(now: Self.now) == [
        "github-events: live, since 2m ago, covers 42 of 45 PRs, 10 signals, 4 reads, last signal 5s ago,"
          + " reconnects 1, streams 42"
      ])
  }

  @Test func anUnavailableProviderShowsItsReasonAndRetry() {
    let source = PRSources.Source(
      id: "github-events", state: "unavailable", reason: "Event subscriptions are not enabled for this account.",
      retryAt: Self.now + 21_600_000)

    #expect(
      PRSources(providers: [source]).lines(now: Self.now) == [
        "github-events: unavailable (Event subscriptions are not enabled for this account.), retries in 6h,"
          + " covers 0 of 0 PRs, 0 signals, 0 reads"
      ])
  }
}
