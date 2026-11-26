import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let t0 = HubHarness.t0

extension HubHarness {
  /// Sends a signal whose GitHub time is `at`, which can differ from its arrival now, or which can be nil.
  fileprivate func signal(
    _ kind: PRSignal.Kind, at: Int64?, target: PRSignal.Target = .pr(prRef(7)), from provider: FakeProvider? = nil
  ) {
    (provider ?? self.provider).emit(target, kind: kind, at: at)
    flush()
  }

  /// Tells the hub that a wait of `kind` on the PR, set at `created`, resolved now.
  fileprivate func resolved(_ id: String = "PR_7", kind: Wait.Kind, created: Int64) {
    queue.sync { hub.waitResolved(id, kind: kind, created: created) }
  }

  fileprivate func confirmDelay(_ id: String = "PR_7") -> Int64? { queue.sync { hub.confirmDelay(id) } }

  fileprivate var sources: PRSources { queue.sync { hub.report() } }

  /// The provider's time from signal to `wait-resolved` for waits of `kind`, or nil when it has none.
  fileprivate func latency(_ kind: Wait.Kind, of provider: String = "fake") -> PRSources.Latency? {
    sources.providers.first { $0.id == provider }?.resolveLatency?[kind.rawValue]
  }

  /// Whether the provider measured no time to `wait-resolved` for any kind.
  fileprivate func measuredNothing(_ provider: String = "fake") -> Bool {
    sources.providers.first { $0.id == provider }?.resolveLatency?.isEmpty ?? true
  }
}

/// In read mode a signal asks the poller for a read with the same delays and spacing as in the mode that slows the
/// poll rates, and each attach with a gap asks for a catch-up read.
@Suite struct PRChangeHubReadModeTests {
  /// A signal's read comes after its kind's delay: 5 s for a `head` signal, 2 s for any other.
  @Test(
    arguments: zip(
      [PRSignal.Kind.checks, .head, .review, .state, .other], [2_000, 5_000, 2_000, 2_000, 2_000] as [Int64]))
  func aSignalAsksForAnEventReadAfterItsDelay(_ kind: PRSignal.Kind, _ delay: Int64) {
    let h = HubHarness(mode: .read)

    h.signal(kind: kind)
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + delay, trigger: .event)])
  }

  @Test func fiveSignalsInASecondCauseOneRead() {
    let h = HubHarness(mode: .read)

    for i in 0..<5 {
      h.setNow(t0 + Int64(i) * 200)
      h.signal()
    }
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 2_000, trigger: .event)])
  }

  @Test func aSecondSignalWaitsFifteenSecondsAfterTheFirstRead() throws {
    let h = HubHarness(mode: .read)
    h.signal()
    h.advance(to: t0 + 3_000)
    try #require(h.reads.map(\.at) == [t0 + 2_000])

    h.signal()

    #expect(h.reader.requests.timed["PR_7"] == t0 + 17_000)
  }

  @Test func aFailedSignalSkipsTheSpacing() {
    let h = HubHarness(mode: .read)
    h.signal()
    h.advance(to: t0 + 3_000)

    h.signal(failed: true)
    h.advance(by: 60_000)

    #expect(h.reads.map(\.at) == [t0 + 2_000, t0 + 5_000])
  }

  @Test func liveWithAGapAsksForACatchUpRead() {
    let h = HubHarness(mode: .read)

    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 5_000, trigger: .catchup)])
  }

  /// Each attach asks for a catch-up read, so a stream that drops and comes back reads the PR again.
  @Test func aStreamThatComesBackAsksForAnotherCatchUpRead() {
    let h = HubHarness(mode: .read)
    h.cover()
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))
    let since = h.now + 10_000
    h.setNow(since)

    h.coverage(.live(.pr(prRef(7)), since: since, gap: true))
    h.advance(by: 60_000)

    #expect(h.reads.map(\.trigger) == [.catchup, .catchup])
    #expect(h.reads.last == .init(id: "PR_7", at: since + 5_000, trigger: .catchup))
  }

  /// Read mode leaves the poll rates as they are with the source off, even for a PR that the provider covers.
  @Test func aCoveredPRGivesThePollRatesNoSignals() {
    let h = HubHarness(mode: .read)

    h.cover()

    #expect(h.covered.isEmpty)
  }

  /// The report still counts the PR that the provider covers, as shadow mode's report does.
  @Test func theReportCountsACoveredPR() {
    let h = HubHarness(mode: .read)

    h.cover()

    #expect(h.sources.providers.first?.covered == 1)
  }

  /// The same signals and coverage cause the same reads in read mode as in the mode that slows the poll rates. Only
  /// the coverage that the poll rates read differs.
  @Test func readModeAsksForTheSameReadsAsTheModeThatSlowsPolling() {
    func run(_ mode: PRChangeHub.Mode) -> (reads: [HubHarness.Read], covered: [String: ChangeSignals]) {
      let h = HubHarness(mode: mode)
      h.coverage(.live(.everything, since: t0, gap: true))
      h.signal(kind: .checks)
      h.setNow(t0 + 1_000)
      h.signal(kind: .head)
      h.signal(.pr(prRef(8)), kind: .review)
      h.signal(.commit(repo: "acme/gadgets", sha: "head9"), kind: .checks)
      h.advance(to: t0 + 8_000)
      h.signal(kind: .checks, failed: true)
      h.signal(.pr(prRef(8)), kind: .state)
      h.advance(to: t0 + 70_000)
      let covered = h.covered
      h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))
      h.setNow(t0 + 80_000)
      h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
      h.signal(kind: .review)
      h.advance(by: 120_000)
      return (h.reads, covered)
    }

    let slows = run(.slowsPolling)
    let read = run(.read)

    #expect(read.reads == slows.reads)
    #expect(!slows.covered.isEmpty)
    #expect(read.covered.isEmpty)
  }

  @Test func readModeCountsTheReadsItAskedFor() {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    h.signal(.pr(prRef(8)))
    h.advance(by: 60_000)

    #expect(h.sources.providers.first?.reads == 2)
  }
}

/// The read that confirms a `ci` wait comes 10 s after the first read when a provider is live for the PR.
@Suite struct PRChangeHubConfirmDelayTests {
  /// Any report that covers the PR makes the delay 10 s at once, without the 60 s that coverage of the poll rates
  /// needs.
  @Test(arguments: [.pr(prRef(7)), .repos(["acme/widgets"]), .everything] as [CoverageChange.Scope])
  func aLivePRConfirmsAfterTenSeconds(_ scope: CoverageChange.Scope) {
    let h = HubHarness(mode: .read)

    h.coverage(.live(scope, since: t0, gap: true))

    #expect(h.confirmDelay() == 10_000)
  }

  @Test func liveWithoutAGapAlsoConfirmsAfterTenSeconds() {
    let h = HubHarness(mode: .read)

    h.coverage(.live(.pr(prRef(7)), since: t0, gap: false))

    #expect(h.confirmDelay() == 10_000)
  }

  @Test func theModeThatSlowsPollingAlsoConfirmsAfterTenSeconds() {
    let h = HubHarness(mode: .slowsPolling)

    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    #expect(h.confirmDelay() == 10_000)
  }

  @Test func aPRWithoutAReportHasNoDelay() {
    let h = HubHarness(mode: .read)

    #expect(h.confirmDelay() == nil)
  }

  /// A delay of nil leaves the confirming read to the poller's own rule.
  @Test func shadowModeHasNoDelay() {
    let h = HubHarness(mode: .shadow)

    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    #expect(h.confirmDelay() == nil)
  }

  @Test func aLiveReportForAnotherRepoGivesNoDelay() {
    let h = HubHarness(mode: .read)

    h.coverage(.live(.repos(["acme/gadgets"]), since: t0, gap: true))

    #expect(h.confirmDelay() == nil)
    #expect(h.confirmDelay("PR_9") == 10_000)
  }

  @Test(arguments: [.pr(prRef(7)), .repos(["acme/widgets"]), .everything] as [CoverageChange.Scope])
  func downEndsTheDelay(_ scope: CoverageChange.Scope) {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    h.coverage(.down(scope, reason: "stream ended"))

    #expect(h.confirmDelay() == nil)
  }

  /// The latest report for the PR wins over an earlier one for its repo.
  @Test func downForThePRInsideALiveRepoEndsTheDelay() {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.repos(["acme/widgets"]), since: t0, gap: true))

    h.coverage(.down(.pr(prRef(7)), reason: "subscription ended"))

    #expect(h.confirmDelay() == nil)
    #expect(h.confirmDelay("PR_8") == 10_000)
  }

  @Test(arguments: [.unavailable(reason: "not enabled", retryAt: nil), .off] as [Availability])
  func aProviderThatCannotReportEndsTheDelay(_ a: Availability) {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    h.availability(a)

    #expect(h.confirmDelay() == nil)
  }

  @Test func aPRThatTheLastCycleDroppedHasNoDelay() {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.everything, since: t0, gap: true))
    h.known["PR_7"] = nil

    h.endCycle()

    #expect(h.confirmDelay() == nil)
  }

  @Test func anUnknownPRHasNoDelay() {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.everything, since: t0, gap: true))

    #expect(h.confirmDelay("PR_99") == nil)
  }
}

/// The hub measures the time from the GitHub time of the newest signal that matches a resolved wait to the wait's
/// resolution, for `sb sources`.
@Suite struct PRChangeHubResolveLatencyTests {
  @Test(arguments: [PRChangeHub.Mode.read, .slowsPolling])
  func aResolvedWaitMeasuresFromTheNewestMatchingSignal(_ mode: PRChangeHub.Mode) {
    let h = HubHarness(mode: mode)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 500)
    h.setNow(t0 + 3_000)
    h.signal(.checks, at: t0 + 2_500)
    h.setNow(t0 + 20_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.latency(.ci) == PRSources.Latency(count: 1, medianMs: 17_500))
  }

  /// The newest signal is the one with the newest GitHub time, which need not be the one that arrived last. GitHub
  /// can send a `state` change after a `head` change that it stamped later.
  @Test func theNewestSignalIsTheOneWithTheNewestGitHubTime() {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 900)
    h.setNow(t0 + 2_000)
    h.signal(.head, at: t0 + 400)
    h.setNow(t0 + 10_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.latency(.ci)?.medianMs == 9_100)
  }

  @Test(
    arguments: [
      (Wait.Kind.ci, PRSignal.Kind.checks), (.ci, .head), (.review, .review), (.botReview, .review),
      (.approval, .review), (.merge, .state),
    ] as [(Wait.Kind, PRSignal.Kind)])
  func aSignalOfAMatchingKindIsMeasured(_ wait: Wait.Kind, _ signal: PRSignal.Kind) {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(signal, at: t0 + 1_000)
    h.setNow(t0 + 7_000)

    h.resolved(kind: wait, created: t0)

    #expect(h.latency(wait) == PRSources.Latency(count: 1, medianMs: 6_000))
  }

  @Test(
    arguments: [
      (Wait.Kind.ci, PRSignal.Kind.review), (.ci, .state), (.ci, .conflict), (.ci, .other), (.review, .checks),
      (.review, .state), (.approval, .head), (.botReview, .checks), (.merge, .review), (.merge, .checks),
      (.queue, .state), (.queue, .checks), (.deploy, .state), (.manual, .review), (.date, .checks), (.session, .head),
      (.reply, .review),
    ] as [(Wait.Kind, PRSignal.Kind)])
  func aSignalOfAnotherKindIsNotMeasured(_ wait: Wait.Kind, _ signal: PRSignal.Kind) {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(signal, at: t0 + 1_000)
    h.setNow(t0 + 7_000)

    h.resolved(kind: wait, created: t0)

    #expect(h.measuredNothing())
  }

  /// Only a signal that arrived at or after the time the wait was set counts. Its GitHub time may be earlier.
  @Test(arguments: zip([-1, 0, 1] as [Int64], [false, true, true]))
  func onlyASignalFromWhenTheWaitWasSetCounts(_ arrival: Int64, _ measured: Bool) {
    let h = HubHarness(mode: .read)
    let created = t0 + 10_000
    h.setNow(created + arrival)
    h.signal(.checks, at: t0 + 9_000)
    h.setNow(t0 + 30_000)

    h.resolved(kind: .ci, created: created)

    #expect((h.latency(.ci) != nil) == measured)
    if measured { #expect(h.latency(.ci)?.medianMs == 21_000) }
  }

  @Test func aSignalWithoutAGitHubTimeIsNotMeasured() {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: nil)
    h.setNow(t0 + 7_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.measuredNothing())
  }

  /// A newer signal without a GitHub time leaves the measure to the newest signal that has one.
  @Test func aSignalWithoutAGitHubTimeIsSkipped() {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 1_000)
    h.setNow(t0 + 2_000)
    h.signal(.checks, at: nil)
    h.setNow(t0 + 7_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.latency(.ci) == PRSources.Latency(count: 1, medianMs: 6_000))
  }

  /// A GitHub time after sbd's clock measures 0, not a negative time.
  @Test func aGitHubTimeAfterTheResolutionMeasuresZero() {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 60_000)
    h.setNow(t0 + 7_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.latency(.ci) == PRSources.Latency(count: 1, medianMs: 0))
  }

  @Test func aSignalForAnotherPRIsNotMeasured() {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 1_000, target: .pr(prRef(8)))
    h.setNow(t0 + 7_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.measuredNothing())
  }

  /// A signal for the PR's head commit is a signal for the PR.
  @Test func aSignalForThePRsHeadCommitIsMeasured() {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 1_000, target: .commit(repo: "acme/widgets", sha: "head7"))
    h.setNow(t0 + 7_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.latency(.ci)?.count == 1)
  }

  /// The provider that sent the newest matching signal gets the measure.
  @Test func theProviderOfTheNewestSignalGetsTheMeasure() {
    let a = FakeProvider(id: "a")
    let b = FakeProvider(id: "b")
    let h = HubHarness(providers: [a, b], mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 1_000, from: a)
    h.setNow(t0 + 2_000)
    h.signal(.checks, at: t0 + 2_000, from: b)
    h.setNow(t0 + 7_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.latency(.ci, of: "b") == PRSources.Latency(count: 1, medianMs: 5_000))
    #expect(h.measuredNothing("a"))
  }

  /// Resolves a wait of `kind` set now after a signal of `signal` that arrives now, `latency` later.
  private func resolve(_ h: HubHarness, _ kind: Wait.Kind, _ signal: PRSignal.Kind, after latency: Int64) {
    let created = h.now
    h.signal(signal, at: created)
    h.setNow(created + latency)
    h.resolved(kind: kind, created: created)
    h.setNow(h.now + 1_000)
  }

  @Test func theReportShowsTheMedianOfEachKind() {
    let h = HubHarness(mode: .read)

    resolve(h, .ci, .checks, after: 3_000)
    resolve(h, .ci, .checks, after: 9_000)
    resolve(h, .ci, .checks, after: 5_000)
    resolve(h, .review, .review, after: 4_000)

    #expect(h.latency(.ci) == PRSources.Latency(count: 3, medianMs: 5_000))
    #expect(h.latency(.review) == PRSources.Latency(count: 1, medianMs: 4_000))
  }

  /// The hub keeps the last 100 measures of each kind, so the older slow ones leave the median.
  @Test func theReportKeepsTheLastHundredMeasures() {
    let h = HubHarness(mode: .read)
    for _ in 0..<100 { resolve(h, .merge, .state, after: 30_000) }

    for _ in 0..<100 { resolve(h, .merge, .state, after: 2_000) }

    #expect(h.latency(.merge) == PRSources.Latency(count: 100, medianMs: 2_000))
  }

  @Test func shadowModeMeasuresNothing() {
    let h = HubHarness(mode: .shadow)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 1_000)
    h.setNow(t0 + 7_000)

    h.resolved(kind: .ci, created: t0)

    #expect(h.measuredNothing())
  }

  @Test func noResolvedWaitMeasuresNothing() {
    let h = HubHarness(mode: .read)
    h.setNow(t0 + 1_000)
    h.signal(.checks, at: t0 + 1_000)

    #expect(h.measuredNothing())
  }
}

/// `sb get` names how sbd learns of the PR's changes: `events` once a provider covers it, `polling` before.
@Suite struct PRChangeHubSourceTests {
  @Test func aPRIsPolledBeforeItsProviderHasBeenLiveForSixtySeconds() throws {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    h.advance(to: t0 + 59_999)
    h.endCycle()

    try #require(h.reads.map(\.trigger) == [.catchup])
    #expect(h.hub.source(of: prRef(7)) == "polling")
  }

  @Test(arguments: [PRChangeHub.Mode.read, .slowsPolling])
  func aPRIsCoveredByEventsAfterTheCatchUpReadAndSixtySeconds(_ mode: PRChangeHub.Mode) {
    let h = HubHarness(mode: mode)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    h.advance(to: t0 + 60_000)
    h.endCycle()

    #expect(h.hub.source(of: prRef(7)) == "events")
  }

  /// Without a read from 5 s after the provider went live, the PR stays polled however long the provider is live.
  @Test func aPRWithoutTheCatchUpReadIsPolled() {
    let h = HubHarness(mode: .read)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    h.setNow(t0 + 4_999)
    h.store("PR_7", polled: t0 + 4_999)

    h.setNow(t0 + 3_600_000)
    h.endCycle()

    #expect(h.hub.source(of: prRef(7)) == "polling")
  }

  @Test func shadowModeNamesEveryPRPolled() {
    let h = HubHarness(mode: .shadow)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    h.store("PR_7", polled: t0 + 5_000)

    h.setNow(t0 + 120_000)
    h.endCycle()

    #expect(h.hub.source(of: prRef(7)) == "polling")
  }

  /// The hub publishes the PR's source when the coverage report arrives, without waiting for a poll.
  @Test(arguments: [.pr(prRef(7)), .repos(["acme/widgets"]), .everything] as [CoverageChange.Scope])
  func downNamesThePRPolledAtOnce(_ scope: CoverageChange.Scope) throws {
    let h = HubHarness(mode: .read)
    h.cover()
    h.endCycle()
    try #require(h.hub.source(of: prRef(7)) == "events")

    h.coverage(.down(scope, reason: "stream ended"))

    #expect(h.hub.source(of: prRef(7)) == "polling")
  }

  @Test(arguments: [.unavailable(reason: "not enabled", retryAt: nil), .off] as [Availability])
  func aProviderThatCannotReportNamesThePRPolledAtOnce(_ a: Availability) throws {
    let h = HubHarness(mode: .read)
    h.cover()
    h.endCycle()
    try #require(h.hub.source(of: prRef(7)) == "events")

    h.availability(a)

    #expect(h.hub.source(of: prRef(7)) == "polling")
  }

  @Test func anotherPRStaysPolled() {
    let h = HubHarness(mode: .read)
    h.cover()
    h.endCycle()

    #expect(h.hub.source(of: prRef(8)) == "polling")
    #expect(h.hub.source(of: prRef(99)) == "polling")
  }

  /// `sb get` builds its summary on the service's queue, so the source is read from another thread than the hub's.
  @Test func theSourceCanBeReadFromAnotherQueue() {
    let h = HubHarness(mode: .read)
    h.cover()
    h.endCycle()

    let source = DispatchQueue(label: "test.summary").sync { h.hub.source(of: prRef(7)) }

    #expect(source == "events")
  }
}
