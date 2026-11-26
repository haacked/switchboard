import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A clock that only the test moves, in ms.
private final class ShadowClock {
  var now: Int64
  init(_ now: Int64) { self.now = now }
}

/// A poller's side of the hub that records each call the hub makes.
private final class RecordingReader: PRReader {
  private(set) var calls: [String] = []

  func requestRead(_ ids: some Sequence<String>, after: Int64, trigger: ReadTrigger) {
    calls.append("requestRead \(ids.sorted()) after \(after) (\(trigger.rawValue))")
  }

  func readAtNextPoll(_ ids: some Sequence<String>, trigger: ReadTrigger) {
    calls.append("readAtNextPoll \(ids.sorted()) (\(trigger.rawValue))")
  }

  func cancelRead(_ id: String, trigger: ReadTrigger) {
    calls.append("cancelRead \(id) (\(trigger.rawValue))")
  }

  func called(_ method: String) -> Bool { calls.contains { $0.hasPrefix(method + " ") } }
}

/// A hub with one fake provider and a recording reader on a test clock. The poller knows PR_7 and PR_8 in
/// acme/widgets, and it read each with `base` a minute before the test starts.
private final class ShadowHarness {
  static let t0: Int64 = 1_000_000_000_000
  static let base = ShadowTally.Snapshot(
    head: "head7", state: "OPEN", draft: false, reviews: 0, checks: "PENDING", mergeable: "MERGEABLE")

  let queue = DispatchQueue(label: "test.shadow-hub")
  let clock = ShadowClock(ShadowHarness.t0)
  let reader = RecordingReader()
  let provider = FakeProvider()
  let hub: PRChangeHub
  var known: [String: PRChangeHub.KnownPR] = [:]

  init(shadow: Bool = true) {
    hub = PRChangeHub(providers: [provider], queue: queue, shadow: shadow)
    for (id, number) in [("PR_7", 7), ("PR_8", 8)] {
      var pr = PRChangeHub.KnownPR(ref: prRef(number), headSha: "head\(number)", polled: ShadowHarness.t0 - 60_000)
      pr.snapshot = ShadowHarness.base
      known[id] = pr
    }
    hub.now = { [clock] in clock.now }
    hub.reader = reader
    hub.start()
    endCycle()
  }

  var now: Int64 { clock.now }

  func setNow(_ t: Int64) { clock.now = t }

  func endCycle() {
    let interest = known.values.map(\.ref).sorted { $0.number < $1.number }
    queue.sync { hub.cycleEnded(known: known, interest: interest) }
  }

  func signal(_ ref: PRRef = prRef(7), kind: PRSignal.Kind = .checks, failed: Bool = false) {
    provider.emit(.pr(ref), kind: kind, failed: failed, at: clock.now)
    queue.sync {}
  }

  func coverage(_ change: CoverageChange) {
    provider.emit(change)
    queue.sync {}
  }

  /// Stores a read of the PR at `t` that shows `snapshot`, and ends the cycle. The hub tallies a poll's reads when
  /// the next poll ends, so a second cycle without a read follows.
  func read(_ id: String = "PR_7", _ snapshot: ShadowTally.Snapshot = ShadowHarness.base, at t: Int64) {
    clock.now = t
    known[id]?.polled = t
    known[id]?.snapshot = snapshot
    endCycle()
    endCycle()
  }

  func read(_ snapshot: ShadowTally.Snapshot, at t: Int64) { read("PR_7", snapshot, at: t) }

  var source: PRSources.Source? { queue.sync { hub.report().providers.first } }
  var covered: [String: ChangeSignals] { queue.sync { hub.coveredSignals() } }
}

private let t0 = ShadowHarness.t0

private func withHead(_ head: String) -> ShadowTally.Snapshot {
  var s = ShadowHarness.base
  s.head = head
  return s
}

/// In shadow mode the hub never asks the poller for a read. Each test also runs without shadow mode, where the same
/// steps do call the reader, so the shadow flag is what stops the calls.
@Suite struct PRChangeHubShadowReaderTests {
  @Test(arguments: [true, false], [PRSignal.Kind.checks, .head, .review, .other])
  func aSignalCallsTheReaderOnlyWithoutShadowMode(_ shadow: Bool, _ kind: PRSignal.Kind) {
    let h = ShadowHarness(shadow: shadow)

    h.signal(kind: kind)

    #expect(h.reader.called("requestRead") == !shadow, "\(h.reader.calls)")
  }

  @Test(arguments: [true, false])
  func aFailedSignalAfterASignalReadCallsTheReaderOnlyWithoutShadowMode(_ shadow: Bool) {
    let h = ShadowHarness(shadow: shadow)
    h.signal()
    h.read(at: t0 + 2_000)
    let before = h.reader.calls.count
    h.setNow(t0 + 3_000)

    h.signal(failed: true)

    #expect((h.reader.calls.count > before) == !shadow, "\(h.reader.calls)")
  }

  /// A read that serves a signal before the hub's timed read withdraws that read.
  @Test(arguments: [true, false])
  func aReadThatServesASignalCancelsOnlyWithoutShadowMode(_ shadow: Bool) {
    let h = ShadowHarness(shadow: shadow)
    h.signal()

    h.read(at: t0 + 1_000)

    #expect(h.reader.called("cancelRead") == !shadow, "\(h.reader.calls)")
  }

  /// A signal whose read didn't run by the next cycle is asked for at the next poll.
  @Test(arguments: [true, false])
  func aSignalReadThatAPollMissedIsAskedAgainOnlyWithoutShadowMode(_ shadow: Bool) {
    let h = ShadowHarness(shadow: shadow)
    h.signal()
    h.setNow(t0 + 30_000)

    h.endCycle()

    #expect(h.reader.called("readAtNextPoll") == !shadow, "\(h.reader.calls)")
  }

  @Test(arguments: [true, false])
  func liveWithAGapAsksForACatchUpOnlyWithoutShadowMode(_ shadow: Bool) {
    let h = ShadowHarness(shadow: shadow)

    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))

    #expect(h.reader.called("requestRead") == !shadow, "\(h.reader.calls)")
  }

  /// A catch-up read whose time passed is asked for at the next poll when a cycle ends.
  @Test(arguments: [true, false])
  func aPastCatchUpIsAskedAtTheNextPollOnlyWithoutShadowMode(_ shadow: Bool) {
    let h = ShadowHarness(shadow: shadow)
    h.coverage(.live(.pr(prRef(7)), since: t0 - 30_000, gap: true))

    h.endCycle()

    #expect(h.reader.called("readAtNextPoll") == !shadow, "\(h.reader.calls)")
  }

  @Test(arguments: [true, false])
  func aStreamThatComesBackAsksForAReadOnlyWithoutShadowMode(_ shadow: Bool) {
    let h = ShadowHarness(shadow: shadow)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 60_000)
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))
    let before = h.reader.calls.count
    h.setNow(t0 + 70_000)

    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))

    #expect((h.reader.calls.count > before) == !shadow, "\(h.reader.calls)")
  }

  /// Signals of every kind, coverage that comes and goes, and reads whose times move, as a shadow run sees them.
  @Test(arguments: [true, false])
  func aWholeRunCallsTheReaderOnlyWithoutShadowMode(_ shadow: Bool) {
    let h = ShadowHarness(shadow: shadow)

    h.coverage(.live(.everything, since: t0 - 10_000, gap: true))
    h.signal(kind: .head)
    h.signal(prRef(8), kind: .review)
    h.endCycle()
    h.read(at: t0 + 1_000)
    h.setNow(t0 + 3_000)
    h.signal(kind: .checks, failed: true)
    h.signal(kind: .checks)
    h.read("PR_8", withHead("head8b"), at: t0 + 30_000)
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))
    h.setNow(t0 + 40_000)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(withHead("head7b"), at: t0 + 120_000)
    h.setNow(t0 + 200_000)
    h.endCycle()

    #expect(h.reader.calls.isEmpty == shadow, "\(h.reader.calls)")
    #expect((h.source?.reads == 0) == shadow)
  }
}

/// What a shadow hub reports in `sb sources`.
@Suite struct PRChangeHubShadowReportTests {
  @Test func aShadowHubReportsShadowMode() {
    let h = ShadowHarness()

    #expect(h.source?.shadow == true)
  }

  @Test func aHubWithoutShadowModeReportsNoShadowMode() {
    let h = ShadowHarness(shadow: false)

    #expect(h.source?.shadow == false)
  }

  @Test func aShadowHubCountsSignalsAndNoReads() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))

    h.signal()
    h.signal(kind: .head)
    h.signal(prRef(8), kind: .review)

    #expect(h.source?.signals == 3)
    #expect(h.source?.reads == 0)
  }

  /// The report counts the PRs that the provider would cover, but the poll rates see no coverage.
  @Test func aShadowHubReportsCoverageThatThePollRatesDoNotSee() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 5_000)

    h.setNow(t0 + 60_000)

    #expect(h.source?.covered == 1)
    #expect(h.covered.isEmpty)
  }

  /// Without shadow mode the same steps cover the PR for the poll rates.
  @Test func aHubWithoutShadowModeGivesThePollRatesItsCoverage() {
    let h = ShadowHarness(shadow: false)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 5_000)

    h.setNow(t0 + 60_000)

    #expect(h.covered["PR_7"] == h.provider.signals)
  }

  @Test func aSignalThatALaterReadShowsIsMatched() {
    let h = ShadowHarness()
    h.setNow(t0 + 10_000)
    h.signal(kind: .head)

    h.read(withHead("head7b"), at: t0 + 13_000)

    #expect(h.source?.matched == 1)
    #expect(h.source?.medianLeadMs == 3_000)
    #expect(h.source?.misses == 0)
  }

  @Test func aReadWhoseSnapshotDidNotChangeMatchesNothing() {
    let h = ShadowHarness()
    h.signal(kind: .head)

    h.read(at: t0 + 3_000)

    #expect(h.source?.matched == 0)
  }

  /// The provider was live from before the previous read, and a later read shows a new head without a signal.
  @Test func aChangeOfALivePRWithoutASignalIsAMiss() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 1)
    #expect(h.source?.matched == 0)
  }

  /// The provider went live after the previous read, so the change may have come before it.
  @Test func aChangeOfAPRThatWentLiveAfterThePreviousReadIsNotAMiss() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 0)
  }

  @Test func aChangeOfAPRThatIsNotLiveIsNotAMiss() {
    let h = ShadowHarness()
    h.read(at: t0 + 10_000)

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 0)
  }

  @Test func aChangeAfterTheStreamWentDownIsNotAMiss() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 0)
  }

  @Test func aSignalBeforeTheChangeOfALivePRPreventsTheMiss() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)
    h.setNow(t0 + 190_000)
    h.signal(kind: .head)

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 0)
    #expect(h.source?.matched == 1)
  }

  /// A signal that arrives while a poll holds the poller's queue reaches the hub after that poll ends. The read of
  /// that poll still counts it, because the hub tallies a poll's reads when the next poll ends.
  @Test func aSignalThatArrivesDuringThePollThatShowsItsChangeIsMatched() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)
    h.known["PR_7"]?.polled = t0 + 200_000
    h.known["PR_7"]?.snapshot = withHead("head7b")
    h.setNow(t0 + 201_000)

    let interest = [prRef(7), prRef(8)]
    h.queue.sync {
      h.provider.emit(.pr(prRef(7)), kind: .head)
      h.hub.cycleEnded(known: h.known, interest: interest)
    }
    h.endCycle()

    #expect(h.source?.misses == 0)
    #expect(h.source?.matched == 1)
    #expect(h.source?.unmatched == 0)
  }

  /// A merge ends the PR's subscription before the next poll tallies the read that showed the merge. The miss still
  /// counts, because the hub keeps the coverage that held when that poll ended.
  @Test func aChangeWhoseStreamClosesBeforeTheTallyIsStillAMiss() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)
    var merged = ShadowHarness.base
    merged.state = "MERGED"
    h.setNow(t0 + 200_000)
    h.known["PR_7"]?.polled = t0 + 200_000
    h.known["PR_7"]?.snapshot = merged
    h.endCycle()

    h.setNow(t0 + 200_001)
    h.coverage(.down(.pr(prRef(7)), reason: "sbd no longer wants the PR"))
    h.endCycle()

    #expect(h.source?.misses == 1)
  }

  /// A stream that drops during a poll reports down after the poll ends. The change that poll read isn't a miss.
  @Test func aStreamThatDropsDuringThePollCountsNoMiss() {
    let h = ShadowHarness()
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)
    h.known["PR_7"]?.polled = t0 + 200_000
    h.known["PR_7"]?.snapshot = withHead("head7b")
    h.setNow(t0 + 201_000)

    let interest = [prRef(7), prRef(8)]
    h.queue.sync {
      h.provider.emit(.down(.pr(prRef(7)), reason: "the stream dropped"))
      h.hub.cycleEnded(known: h.known, interest: interest)
    }
    h.endCycle()

    #expect(h.source?.misses == 0)
  }

  @Test func countPendingReadsAddsUpInTheReport() {
    let h = ShadowHarness()

    h.queue.sync {
      h.hub.countPendingReads(total: 10, reviewOnly: 4)
      h.hub.countPendingReads(total: 5, reviewOnly: 1)
    }

    let report = h.queue.sync { h.hub.report() }
    #expect(report.pendingReads == 15)
    #expect(report.reviewOnlyReads == 5)
  }
}
