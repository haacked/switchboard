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

/// A hub with one fake provider and a recording reader on a test clock, in shadow mode unless the test names another
/// mode. The poller knows PR_7 and PR_8 in acme/widgets, and it read each with `base` a minute before the test starts.
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

  init(mode: PRChangeHub.Mode = .shadow) {
    hub = PRChangeHub(providers: [provider], queue: queue, mode: mode)
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

/// Every mode of the hub.
private let allModes: [PRChangeHub.Mode] = [.shadow, .read, .slowsPolling]

/// The modes that count misses and matches: shadow mode and read mode.
private let tallyModes: [PRChangeHub.Mode] = [.shadow, .read]

/// In shadow mode the hub never asks the poller for a read. Each test also runs in read mode and in the mode that
/// slows the poll rates, where the same steps do call the reader, so shadow mode is what stops the calls.
@Suite struct PRChangeHubShadowReaderTests {
  @Test(arguments: allModes, [PRSignal.Kind.checks, .head, .review, .other])
  func aSignalCallsTheReaderOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode, _ kind: PRSignal.Kind) {
    let h = ShadowHarness(mode: mode)

    h.signal(kind: kind)

    #expect(h.reader.called("requestRead") == (mode != .shadow), "\(h.reader.calls)")
  }

  @Test(arguments: allModes)
  func aFailedSignalAfterASignalReadCallsTheReaderOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode) {
    let shadow = mode == .shadow
    let h = ShadowHarness(mode: mode)
    h.signal()
    h.read(at: t0 + 2_000)
    let before = h.reader.calls.count
    h.setNow(t0 + 3_000)

    h.signal(failed: true)

    #expect((h.reader.calls.count > before) == !shadow, "\(h.reader.calls)")
  }

  /// A read that serves a signal before the hub's timed read withdraws that read.
  @Test(arguments: allModes)
  func aReadThatServesASignalCancelsOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode) {
    let shadow = mode == .shadow
    let h = ShadowHarness(mode: mode)
    h.signal()

    h.read(at: t0 + 1_000)

    #expect(h.reader.called("cancelRead") == !shadow, "\(h.reader.calls)")
  }

  /// A signal whose read didn't run by the next cycle is asked for at the next poll.
  @Test(arguments: allModes)
  func aSignalReadThatAPollMissedIsAskedAgainOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode) {
    let shadow = mode == .shadow
    let h = ShadowHarness(mode: mode)
    h.signal()
    h.setNow(t0 + 30_000)

    h.endCycle()

    #expect(h.reader.called("readAtNextPoll") == !shadow, "\(h.reader.calls)")
  }

  @Test(arguments: allModes)
  func liveWithAGapAsksForACatchUpOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode) {
    let shadow = mode == .shadow
    let h = ShadowHarness(mode: mode)

    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))

    #expect(h.reader.called("requestRead") == !shadow, "\(h.reader.calls)")
  }

  /// A catch-up read whose time passed is asked for at the next poll when a cycle ends.
  @Test(arguments: allModes)
  func aPastCatchUpIsAskedAtTheNextPollOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode) {
    let shadow = mode == .shadow
    let h = ShadowHarness(mode: mode)
    h.coverage(.live(.pr(prRef(7)), since: t0 - 30_000, gap: true))

    h.endCycle()

    #expect(h.reader.called("readAtNextPoll") == !shadow, "\(h.reader.calls)")
  }

  @Test(arguments: allModes)
  func aStreamThatComesBackAsksForAReadOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode) {
    let shadow = mode == .shadow
    let h = ShadowHarness(mode: mode)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 60_000)
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))
    let before = h.reader.calls.count
    h.setNow(t0 + 70_000)

    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))

    #expect((h.reader.calls.count > before) == !shadow, "\(h.reader.calls)")
  }

  /// Signals of every kind, coverage that comes and goes, and reads whose times move, as a shadow run sees them.
  @Test(arguments: allModes)
  func aWholeRunCallsTheReaderOnlyWithoutShadowMode(_ mode: PRChangeHub.Mode) {
    let shadow = mode == .shadow
    let h = ShadowHarness(mode: mode)

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

/// What a shadow hub reports in `sb sources`. Read mode keeps the matches, misses, and pending reads that shadow mode
/// counts, so the tests of those counts run in both modes.
@Suite struct PRChangeHubShadowReportTests {
  @Test func aShadowHubReportsShadowMode() {
    let h = ShadowHarness()

    #expect(h.source?.shadow == true)
  }

  @Test(arguments: [PRChangeHub.Mode.read, .slowsPolling])
  func aHubWithoutShadowModeReportsNoShadowMode(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)

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

  /// The report counts the PRs that the provider would cover, but the poll rates see no coverage. Read mode leaves the
  /// poll rates as they are too.
  @Test(arguments: tallyModes)
  func aHubReportsCoverageThatThePollRatesDoNotSee(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 5_000)

    h.setNow(t0 + 60_000)

    #expect(h.source?.covered == 1)
    #expect(h.covered.isEmpty)
  }

  /// In the mode that slows the poll rates, the same steps cover the PR for the poll rates.
  @Test func aHubThatSlowsPollingGivesThePollRatesItsCoverage() {
    let h = ShadowHarness(mode: .slowsPolling)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 5_000)

    h.setNow(t0 + 60_000)

    #expect(h.covered["PR_7"] == h.provider.signals)
  }

  @Test(arguments: tallyModes)
  func aSignalThatALaterReadShowsIsMatched(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
    h.setNow(t0 + 10_000)
    h.signal(kind: .head)

    h.read(withHead("head7b"), at: t0 + 13_000)

    #expect(h.source?.matched == 1)
    #expect(h.source?.medianLeadMs == 3_000)
    #expect(h.source?.misses == 0)
  }

  @Test(arguments: tallyModes)
  func aReadWhoseSnapshotDidNotChangeMatchesNothing(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
    h.signal(kind: .head)

    h.read(at: t0 + 3_000)

    #expect(h.source?.matched == 0)
  }

  /// The provider was live from before the previous read, and a later read shows a new head without a signal.
  @Test(arguments: tallyModes)
  func aChangeOfALivePRWithoutASignalIsAMiss(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 1)
    #expect(h.source?.matched == 0)
  }

  /// The provider went live after the previous read, so the change may have come before it.
  @Test(arguments: tallyModes)
  func aChangeOfAPRThatWentLiveAfterThePreviousReadIsNotAMiss(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 0)
  }

  @Test(arguments: tallyModes)
  func aChangeOfAPRThatIsNotLiveIsNotAMiss(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
    h.read(at: t0 + 10_000)

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 0)
  }

  @Test(arguments: tallyModes)
  func aChangeAfterTheStreamWentDownIsNotAMiss(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
    h.coverage(.live(.pr(prRef(7)), since: h.now, gap: true))
    h.read(at: t0 + 10_000)
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))

    h.read(withHead("head7b"), at: t0 + 200_000)

    #expect(h.source?.misses == 0)
  }

  @Test(arguments: tallyModes)
  func aSignalBeforeTheChangeOfALivePRPreventsTheMiss(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
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
  @Test(arguments: tallyModes)
  func aSignalThatArrivesDuringThePollThatShowsItsChangeIsMatched(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
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
  @Test(arguments: tallyModes)
  func aChangeWhoseStreamClosesBeforeTheTallyIsStillAMiss(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
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
  @Test(arguments: tallyModes)
  func aStreamThatDropsDuringThePollCountsNoMiss(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)
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

  @Test(arguments: tallyModes)
  func countPendingReadsAddsUpInTheReport(_ mode: PRChangeHub.Mode) {
    let h = ShadowHarness(mode: mode)

    h.queue.sync {
      h.hub.countPendingReads(total: 10, reviewOnly: 4)
      h.hub.countPendingReads(total: 5, reviewOnly: 1)
    }

    let report = h.queue.sync { h.hub.report() }
    #expect(report.pendingReads == 15)
    #expect(report.reviewOnlyReads == 5)
  }
}
