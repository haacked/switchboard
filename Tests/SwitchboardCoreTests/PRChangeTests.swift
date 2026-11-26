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
      Self.unindented(PRSources(providers: [source]).lines(now: Self.now)) == [
        "github-events: live, since 2m ago, covers 42 of 45 PRs, 10 signals, 4 reads, last signal 5s ago,"
          + " reconnects 1, streams 42",
        "misses: 0",
      ])
  }

  @Test func anUnavailableProviderShowsItsReasonAndRetry() {
    let source = PRSources.Source(
      id: "github-events", state: "unavailable", reason: "Event subscriptions are not enabled for this account.",
      retryAt: Self.now + 21_600_000)

    #expect(
      Self.unindented(PRSources(providers: [source]).lines(now: Self.now)) == [
        "github-events: unavailable (Event subscriptions are not enabled for this account.), retries in 6h,"
          + " covers 0 of 0 PRs, 0 signals, 0 reads",
        "misses: 0",
      ])
  }

  static let liveLine =
    "github-events: live, since 2m ago, covers 42 of 45 PRs, 10 signals, 0 reads, last signal 5s ago, streams 42"

  /// The lines without their indent, which the spec leaves to the implementation.
  static func unindented(_ lines: [String]) -> [String] {
    lines.map { String($0.drop { $0 == " " }) }
  }

  static func liveSource() -> PRSources.Source {
    PRSources.Source(
      id: "github-events", state: "live", changedAt: now - 120_000, wanted: 45, covered: 42, signals: 10,
      lastSignalAt: now - 5_000, counts: ["streams": 42])
  }

  @Test func aShadowSourceShowsWhatItMeasuredOnALineOfItsOwn() {
    var source = Self.liveSource()
    source.shadow = true
    source.matched = 7
    source.unmatched = 2
    source.misses = 1
    source.medianLeadMs = 12_000

    #expect(
      Self.unindented(PRSources(providers: [source]).lines(now: Self.now)) == [
        Self.liveLine, "shadow: 7 matched, 2 unmatched, 1 misses, median lead 12 s",
      ])
  }

  @Test func aShadowSourceWithoutAMatchStillShowsItsCounts() throws {
    var source = Self.liveSource()
    source.shadow = true
    source.unmatched = 3

    let lines = Self.unindented(PRSources(providers: [source]).lines(now: Self.now))

    try #require(lines.count == 2)
    #expect(lines[0] == Self.liveLine)
    #expect(lines[1].hasPrefix("shadow: 0 matched, 3 unmatched, 0 misses"))
  }

  /// Outside shadow mode, as in read mode, a source shows only its misses on its second line.
  @Test func aSourceThatIsNotInShadowModeShowsItsMissesInsteadOfTheShadowLine() {
    var source = Self.liveSource()
    source.matched = 7
    source.unmatched = 2
    source.misses = 3
    source.medianLeadMs = 12_000

    #expect(Self.unindented(PRSources(providers: [source]).lines(now: Self.now)) == [Self.liveLine, "misses: 3"])
  }

  @Test func aSourceShowsTheTimeToWaitResolvedByKindSortedByName() {
    var source = Self.liveSource()
    source.resolveLatency = [
      "review": PRSources.Latency(count: 2, medianMs: 6_400), "ci": PRSources.Latency(count: 4, medianMs: 18_900),
    ]

    #expect(
      Self.unindented(PRSources(providers: [source]).lines(now: Self.now)) == [
        Self.liveLine, "misses: 0", "event to wait-resolved: ci 18 s (4), review 6 s (2)",
      ])
  }

  /// The median shows in whole seconds, rounded down.
  @Test(arguments: zip([0, 999, 1_000, 24_999] as [Int64], ["0 s", "0 s", "1 s", "24 s"]))
  func theTimeToWaitResolvedShowsWholeSeconds(_ ms: Int64, _ shown: String) {
    var source = Self.liveSource()
    source.resolveLatency = ["merge": PRSources.Latency(count: 1, medianMs: ms)]

    let lines = Self.unindented(PRSources(providers: [source]).lines(now: Self.now))

    #expect(lines.last == "event to wait-resolved: merge \(shown) (1)")
  }

  @Test func aShadowSourceWithLatenciesShowsThemAfterItsShadowLine() {
    var source = Self.liveSource()
    source.shadow = true
    source.resolveLatency = ["ci": PRSources.Latency(count: 1, medianMs: 20_000)]

    #expect(
      Self.unindented(PRSources(providers: [source]).lines(now: Self.now)) == [
        Self.liveLine, "shadow: 0 matched, 0 unmatched, 0 misses", "event to wait-resolved: ci 20 s (1)",
      ])
  }

  @Test(arguments: [nil, [:]] as [[String: PRSources.Latency]?])
  func noLatenciesShowNoLatencyLine(_ latency: [String: PRSources.Latency]?) {
    var source = Self.liveSource()
    source.resolveLatency = latency

    #expect(!PRSources(providers: [source]).lines(now: Self.now).contains { $0.contains("wait-resolved") })
  }

  @Test func theLatenciesSurviveARoundTrip() throws {
    var source = Self.liveSource()
    source.resolveLatency = [
      "ci": PRSources.Latency(count: 4, medianMs: 18_900), "review": PRSources.Latency(count: 2, medianMs: 6_400),
    ]
    let sources = PRSources(providers: [source])

    #expect(try JSONCoding.convert(sources, to: PRSources.self) == sources)
  }

  /// An sbd from before read mode sends no resolveLatency key.
  @Test func aSourceFromAnOlderSbdDecodesWithoutLatencies() throws {
    var object = try #require(try JSON(encoding: Self.liveSource()).object)
    object["resolveLatency"] = nil

    let decoded = try JSONCoding.convert(JSON.object(object), to: PRSources.Source.self)

    #expect(decoded.resolveLatency == nil)
    #expect(decoded.covered == 42)
  }

  @Test func theNewFieldsDefaultToNoShadowAndNoCounts() {
    let source = Self.liveSource()

    #expect(!source.shadow)
    #expect(source.matched == 0 && source.unmatched == 0 && source.misses == 0)
    #expect(source.medianLeadMs == nil)
    #expect(source.resolveLatency == nil)
    #expect(PRSources(providers: [source]).pendingReads == 0)
    #expect(PRSources(providers: [source]).reviewOnlyReads == 0)
  }

  @Test func pendingReadsShowHowManyOnlyAwaitReview() {
    var source = Self.liveSource()
    source.shadow = true
    source.medianLeadMs = 3_000
    var sources = PRSources(providers: [source])
    sources.pendingReads = 217
    sources.reviewOnlyReads = 150

    #expect(
      Self.unindented(sources.lines(now: Self.now)) == [
        Self.liveLine, "shadow: 0 matched, 0 unmatched, 0 misses, median lead 3 s",
        "pending reads: 150 of 217 only await review",
      ])
  }

  @Test func noPendingReadsShowNoPendingReadsLine() {
    let sources = PRSources(providers: [Self.liveSource()])

    #expect(!sources.lines(now: Self.now).contains { $0.contains("pending reads") })
  }

  @Test func theShadowFieldsSurviveARoundTrip() throws {
    var source = Self.liveSource()
    source.shadow = true
    source.matched = 7
    source.unmatched = 2
    source.misses = 1
    source.medianLeadMs = 12_000
    var sources = PRSources(providers: [source])
    sources.pendingReads = 217
    sources.reviewOnlyReads = 150

    #expect(try JSONCoding.convert(sources, to: PRSources.self) == sources)
  }
}
