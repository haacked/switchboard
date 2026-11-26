import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A clock that only the test moves, in ms.
final class TestClock {
  var now: Int64
  init(_ now: Int64) { self.now = now }
}

/// The poller's side of the hub. It keeps the requests in a real `ReadRequests` at the test clock's time, so a
/// request that `ReadRequests` merges with an earlier one is merged here too.
final class FakeReader: PRReader {
  let clock: TestClock
  var requests = ReadRequests()

  init(clock: TestClock) { self.clock = clock }

  func requestRead(_ ids: some Sequence<String>, after: Int64, trigger: ReadTrigger) {
    _ = requests.request(ids, at: clock.now + after, trigger: trigger)
  }

  func readAtNextPoll(_ ids: some Sequence<String>, trigger: ReadTrigger) {
    requests.readAtNextPoll(ids, trigger: trigger)
  }

  func cancelRead(_ id: String, trigger: ReadTrigger) {
    requests.cancel(id, trigger: trigger)
  }
}

/// A hub with fake providers and a fake poller on a test clock. The poller knows PR_7 and PR_8 in acme/widgets and
/// PR_9 in acme/gadgets, and it read each a minute before the test starts. `advance` runs a poll at the time of
/// each timed read, as the poller's wake does, and each poll stores its reads and ends with `cycleEnded`. The hub runs
/// in `mode`, which by default is the one where signals cause reads and coverage slows the poll rates.
final class HubHarness {
  static let t0: Int64 = 1_000_000_000_000

  struct Read: Equatable, CustomStringConvertible {
    var id: String
    var at: Int64
    var trigger: ReadTrigger
    var description: String { "\(id) at t0+\(at - HubHarness.t0) (\(trigger.rawValue))" }
  }

  let queue = DispatchQueue(label: "test.hub")
  let clock = TestClock(HubHarness.t0)
  let reader: FakeReader
  let providers: [FakeProvider]
  let hub: PRChangeHub
  var known: [String: PRChangeHub.KnownPR] = [
    "PR_7": .init(ref: prRef(7), headSha: "head7", polled: HubHarness.t0 - 60_000),
    "PR_8": .init(ref: prRef(8), headSha: "head8", polled: HubHarness.t0 - 60_000),
    "PR_9": .init(ref: prRef(9, repo: "acme/gadgets"), headSha: "head9", polled: HubHarness.t0 - 60_000),
  ]
  /// The reads that the polls ran, in order.
  private(set) var reads: [Read] = []

  init(providers: [FakeProvider] = [FakeProvider()], mode: PRChangeHub.Mode = .slowsPolling) {
    reader = FakeReader(clock: clock)
    self.providers = providers
    hub = PRChangeHub(providers: providers, queue: queue, mode: mode)
    hub.now = { [clock] in clock.now }
    hub.reader = reader
    hub.start()
    endCycle()
  }

  var provider: FakeProvider { providers[0] }
  var now: Int64 { clock.now }

  /// The known PRs in number order, which is the ranked list that the tests pass unless they pass their own.
  var defaultInterest: [PRRef] { known.values.map(\.ref).sorted { $0.number < $1.number } }

  func endCycle(interest: [PRRef]? = nil) {
    let interest = interest ?? defaultInterest
    queue.sync { hub.cycleEnded(known: known, interest: interest) }
  }

  /// Waits for what the providers sent to reach the hub.
  func flush() { queue.sync {} }

  func signal(
    _ target: PRSignal.Target = .pr(prRef(7)), kind: PRSignal.Kind = .checks, id: String? = nil, failed: Bool = false,
    from provider: FakeProvider? = nil
  ) {
    (provider ?? self.provider).emit(target, kind: kind, id: id, failed: failed, at: clock.now)
    flush()
  }

  func coverage(_ change: CoverageChange, from provider: FakeProvider? = nil) {
    (provider ?? self.provider).emit(change)
    flush()
  }

  func availability(_ a: Availability, from provider: FakeProvider? = nil) {
    (provider ?? self.provider).report(a)
    flush()
  }

  /// Moves the clock without running a poll, as when the poller's reads fail or haven't run.
  func setNow(_ t: Int64) { clock.now = t }

  /// Moves the clock to `t`, running a poll at the time of each timed read that comes due on the way.
  func advance(to t: Int64) {
    while let next = reader.requests.timed.values.filter({ $0 <= t }).min() {
      clock.now = max(clock.now, next)
      poll()
    }
    clock.now = t
  }

  func advance(by ms: Int64) { advance(to: clock.now + ms) }

  /// Runs a poll now: it takes the due reads, stores each PR as read now, and ends the cycle.
  func poll() {
    let taken = reader.requests.take(now: clock.now)
    for (id, trigger) in taken.sorted(by: { $0.key < $1.key }) {
      reads.append(Read(id: id, at: clock.now, trigger: trigger))
      known[id]?.polled = clock.now
    }
    endCycle()
  }

  /// Stores a read of the PR at `polled` without taking a request, as a timer poll does.
  func store(_ id: String, polled: Int64) {
    known[id]?.polled = polled
    endCycle()
  }

  var covered: [String: ChangeSignals] { queue.sync { hub.coveredSignals() } }

  /// Makes the PR covered by the provider: live with a gap now, the catch-up read, and 60 s.
  func cover(_ ref: PRRef = prRef(7), by provider: FakeProvider? = nil) {
    coverage(.live(.pr(ref), since: clock.now, gap: true), from: provider)
    advance(by: 60_000)
  }
}

private let t0 = HubHarness.t0

/// A signal asks the poller for a read, after a delay that lets a burst share one read.
@Suite struct PRChangeHubSignalTests {
  /// One signal causes one read, 2 s after the signal.
  @Test func oneSignalCausesOneRead() {
    let h = HubHarness()

    h.signal()
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 2_000, trigger: .event)])
  }

  /// Five signals within one second cause one read.
  @Test func fiveSignalsInASecondCauseOneRead() {
    let h = HubHarness()

    for i in 0..<5 {
      h.setNow(t0 + Int64(i) * 200)
      h.signal()
    }
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 2_000, trigger: .event)])
  }

  /// A `head` signal waits 5 s, so GitHub can create the new head's check suites.
  @Test func aHeadSignalWaitsFiveSeconds() {
    let h = HubHarness()

    h.signal(kind: .head)
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 5_000, trigger: .event)])
  }

  /// A `head` signal that comes while an earlier signal's read is pending gets a spaced read of its own.
  @Test func aHeadSignalDuringAPendingReadGetsASpacedReadOfItsOwn() {
    let h = HubHarness()
    h.signal(kind: .checks)
    h.setNow(t0 + 1_000)

    h.signal(kind: .head)
    h.advance(by: 60_000)

    #expect(h.reads.map(\.at) == [t0 + 2_000, t0 + 17_000], "\(h.reads)")
  }

  /// A signal after a signal-caused read waits until 15 s after that read.
  @Test func theSpacingDelaysASecondReadUntilFifteenSecondsAfterTheFirst() throws {
    let h = HubHarness()
    h.signal()
    h.advance(to: t0 + 3_000)
    try #require(h.reads.map(\.at) == [t0 + 2_000])

    h.signal()

    #expect(h.reader.requests.timed["PR_7"] == t0 + 17_000)
  }

  /// The spacing moves a read later but never drops it: every signal has a read at or after it.
  @Test func theSpacingNeverDropsARead() {
    let h = HubHarness()
    h.signal()
    h.advance(to: t0 + 3_000)
    var signalled: [Int64] = [t0]

    for at in [t0 + 3_000, t0 + 10_000, t0 + 16_000, t0 + 17_500] {
      h.advance(to: at)
      h.signal()
      signalled.append(at)
    }
    h.advance(by: 120_000)

    for at in signalled {
      #expect(h.reads.contains { $0.id == "PR_7" && $0.at >= at }, "no read after the signal at t0+\(at - t0)")
    }
    #expect(h.reads.map(\.at) == [t0 + 2_000, t0 + 17_000, t0 + 32_000])
  }

  /// A signal for a failed check skips the spacing and reads after the usual 2 s.
  @Test func aFailedSignalSkipsTheSpacing() {
    let h = HubHarness()
    h.signal()
    h.advance(to: t0 + 3_000)

    h.signal(failed: true)
    h.advance(by: 60_000)

    #expect(h.reads.map(\.at) == [t0 + 2_000, t0 + 5_000])
  }

  /// A failed check moves a read that the spacing put off to 2 s after the failure.
  @Test func aFailedSignalBringsASpacedReadForward() {
    let h = HubHarness()
    h.signal()
    h.advance(to: t0 + 3_000)
    h.signal()
    h.setNow(t0 + 4_000)

    h.signal(failed: true)
    h.advance(by: 60_000)

    #expect(h.reads.map(\.at) == [t0 + 2_000, t0 + 6_000])
  }

  /// The spacing applies to each PR on its own.
  @Test func theSpacingOfOnePRDoesNotDelayAnother() {
    let h = HubHarness()
    h.signal(.pr(prRef(7)))
    h.advance(to: t0 + 3_000)

    h.signal(.pr(prRef(8)))
    h.advance(by: 60_000)

    #expect(
      h.reads == [
        .init(id: "PR_7", at: t0 + 2_000, trigger: .event), .init(id: "PR_8", at: t0 + 5_000, trigger: .event),
      ])
  }

  /// A signal whose id the hub saw is ignored.
  @Test func aDuplicateIdIsIgnored() {
    let h = HubHarness()
    h.signal(id: "e1")
    h.advance(to: t0 + 30_000)

    h.signal(id: "e1")
    h.advance(by: 60_000)

    #expect(h.reads.count == 1)
  }

  /// The hub ignores an id for 10 minutes after it saw it, and reads for it after that.
  @Test(arguments: zip([599_999, 600_000] as [Int64], [1, 2]))
  func aRepeatedIdCausesAReadOnlyAfterTenMinutes(_ later: Int64, _ reads: Int) {
    let h = HubHarness()
    h.signal(id: "e1")
    h.advance(to: t0 + later)

    h.signal(id: "e1")
    h.advance(by: 60_000)

    #expect(h.reads.count == reads)
  }

  /// A signal for a PR that the poller doesn't track asks for no read.
  @Test(arguments: [
    prRef(99), prRef(7, repo: "acme/gadgets"), PRRef(forge: "gitlab.com", repo: "acme/widgets", number: 7),
  ])
  func aSignalForAnUntrackedPRIsIgnored(_ ref: PRRef) {
    let h = HubHarness()

    h.signal(.pr(ref))
    h.advance(by: 60_000)

    #expect(h.reads.isEmpty)
    #expect(h.reader.requests == ReadRequests())
  }

  /// A signal for a PR that left the poller's PRs at the last cycle asks for no read.
  @Test func aSignalForAPRThatTheLastCycleDroppedIsIgnored() {
    let h = HubHarness()
    h.known["PR_7"] = nil
    h.endCycle()

    h.signal(.pr(prRef(7)))
    h.advance(by: 60_000)

    #expect(h.reads.isEmpty)
  }

  /// A signal for a commit reads the PR whose head the commit is.
  @Test func aCommitSignalReadsThePRWhoseHeadItIs() {
    let h = HubHarness()

    h.signal(.commit(repo: "acme/widgets", sha: "head7"))
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 2_000, trigger: .event)])
  }

  /// A commit that is the head of two PRs reads both.
  @Test func aCommitSignalReadsEachPRWhoseHeadItIs() {
    let h = HubHarness()
    h.known["PR_8"]?.headSha = "head7"
    h.endCycle()

    h.signal(.commit(repo: "acme/widgets", sha: "head7"))
    h.advance(by: 60_000)

    #expect(Set(h.reads.map(\.id)) == ["PR_7", "PR_8"])
  }

  /// A commit that is no tracked PR's head in its repo asks for no read.
  @Test(arguments: zip(["acme/widgets", "acme/gadgets", "acme/widgets"], ["other", "head7", "head9"]))
  func aCommitSignalForNoTrackedHeadIsIgnored(_ repo: String, _ sha: String) {
    let h = HubHarness()

    h.signal(.commit(repo: repo, sha: sha))
    h.advance(by: 60_000)

    #expect(h.reads.isEmpty)
  }
}

/// What a provider reports about its coverage decides when the poll rates may leave a PR to it.
@Suite struct PRChangeHubCoverageTests {
  /// `live` with a gap asks for a catch-up read 5 s after `since`.
  @Test func liveWithAGapRequestsACatchUpRead() {
    let h = HubHarness()

    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 5_000, trigger: .catchup)])
  }

  /// A catch-up read whose time has passed comes at once.
  @Test func liveWithAGapThatStartedEarlierReadsAtOnce() {
    let h = HubHarness()

    h.coverage(.live(.pr(prRef(7)), since: t0 - 30_000, gap: true))
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0, trigger: .catchup)])
  }

  /// `live` without a gap asks for no read.
  @Test func liveWithoutAGapRequestsNoRead() {
    let h = HubHarness()

    h.coverage(.live(.pr(prRef(7)), since: t0, gap: false))
    h.advance(by: 60_000)

    #expect(h.reads.isEmpty)
  }

  /// `live` with a gap asks for a catch-up read of each tracked PR in its scope and of no other PR.
  @Test(
    arguments: zip(
      [.pr(prRef(8)), .repos(["acme/widgets"]), .repos(["acme/gadgets", "acme/other"]), .everything]
        as [CoverageChange.Scope],
      [["PR_8"], ["PR_7", "PR_8"], ["PR_9"], ["PR_7", "PR_8", "PR_9"]] as [Set<String>]))
  func liveWithAGapReadsEachPRInItsScope(_ scope: CoverageChange.Scope, _ expected: Set<String>) {
    let h = HubHarness()

    h.coverage(.live(scope, since: t0, gap: true))
    h.advance(by: 60_000)

    #expect(Set(h.reads.map(\.id)) == expected)
    #expect(h.reads.allSatisfy { $0.trigger == .catchup && $0.at == t0 + 5_000 })
  }

  /// A signal read that comes before the catch-up time doesn't replace the catch-up read.
  @Test func aCatchUpReadStillHappensAfterAnEarlierSignalRead() throws {
    let h = HubHarness()
    h.signal()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    h.advance(by: 60_000)

    try #require(h.reads.first == .init(id: "PR_7", at: t0 + 2_000, trigger: .event))
    #expect(h.reads.contains { $0.id == "PR_7" && $0.trigger == .catchup && $0.at >= t0 + 5_000 }, "\(h.reads)")
  }

  /// A PR is covered only once the catch-up read is stored and the provider has been live for 60 s.
  @Test func aPRIsCoveredOnlyAfterTheCatchUpReadAndSixtySeconds() {
    let h = HubHarness()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    #expect(h.covered["PR_7"] == nil)

    h.advance(to: t0 + 5_000)
    #expect(h.reads.map(\.trigger) == [.catchup])
    #expect(h.covered["PR_7"] == nil)

    h.advance(to: t0 + 59_999)
    #expect(h.covered["PR_7"] == nil)

    h.advance(to: t0 + 60_000)
    #expect(h.covered["PR_7"] == h.provider.signals)
  }

  /// Without a read from 5 s after `since`, 60 s of a live provider don't cover the PR.
  @Test(arguments: zip([4_999, 5_000] as [Int64], [false, true]))
  func onlyAReadFromFiveSecondsAfterSinceCatchesThePRUp(_ readAt: Int64, _ covers: Bool) {
    let h = HubHarness()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    h.setNow(t0 + readAt)

    h.store("PR_7", polled: t0 + readAt)
    h.setNow(t0 + 120_000)

    #expect((h.covered["PR_7"] != nil) == covers)
  }

  /// A provider that never got its catch-up read doesn't cover the PR, however long it stays live.
  @Test func aPRWithoutACatchUpReadIsNeverCovered() {
    let h = HubHarness()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))

    h.setNow(t0 + 3_600_000)

    #expect(h.covered.isEmpty)
  }

  /// `down` uncovers the PR at once, whether it names the PR, its repo, or every PR.
  @Test(arguments: [.pr(prRef(7)), .repos(["acme/widgets"]), .everything] as [CoverageChange.Scope])
  func downUncoversAtOnce(_ scope: CoverageChange.Scope) throws {
    let h = HubHarness()
    h.cover()
    try #require(h.covered["PR_7"] != nil)

    h.coverage(.down(scope, reason: "stream ended"))

    #expect(h.covered["PR_7"] == nil)
  }

  /// `down` for one PR inside a live repo uncovers only that PR.
  @Test func downForOnePRInALiveRepoUncoversOnlyThatPR() throws {
    let h = HubHarness()
    h.coverage(.live(.repos(["acme/widgets"]), since: t0, gap: true))
    h.advance(by: 60_000)
    try #require(Set(h.covered.keys) == ["PR_7", "PR_8"])

    h.coverage(.down(.pr(prRef(7)), reason: "subscription ended"))

    #expect(Set(h.covered.keys) == ["PR_8"])
  }

  /// `down` for another repo leaves the PR covered.
  @Test func downForAnotherRepoLeavesThePRCovered() {
    let h = HubHarness()
    h.cover()

    h.coverage(.down(.repos(["acme/gadgets"]), reason: "stream ended"))

    #expect(h.covered["PR_7"] != nil)
  }

  /// A provider that becomes unavailable or off uncovers its PRs at once.
  @Test(arguments: [.unavailable(reason: "not enabled", retryAt: nil), .off] as [Availability])
  func aProviderThatCannotReportUncoversAtOnce(_ a: Availability) throws {
    let h = HubHarness()
    h.cover()
    try #require(h.covered["PR_7"] != nil)

    h.availability(a)

    #expect(h.covered["PR_7"] == nil)
  }

  /// A stream that drops before 60 s starts the 60 s again when it comes back.
  @Test func aStreamThatDropsStartsItsSixtySecondsAgain() {
    let h = HubHarness()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    h.advance(to: t0 + 30_000)
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))
    h.advance(to: t0 + 40_000)

    h.coverage(.live(.pr(prRef(7)), since: t0 + 40_000, gap: true))
    h.advance(to: t0 + 61_000)
    #expect(h.covered["PR_7"] == nil)

    h.advance(to: t0 + 100_000)
    #expect(h.covered["PR_7"] != nil)
  }

  /// A covered PR that comes back after a drop needs a new catch-up read.
  @Test func aStreamThatComesBackWithAGapReadsThePRAgain() {
    let h = HubHarness()
    h.cover()
    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"))
    let since = h.now + 10_000
    h.setNow(since)

    h.coverage(.live(.pr(prRef(7)), since: since, gap: true))
    h.advance(by: 60_000)

    #expect(h.reads.last == .init(id: "PR_7", at: since + 5_000, trigger: .catchup))
  }
}

/// How the hub shares the PRs between providers.
@Suite struct PRChangeHubProviderTests {
  private static func twoProviders() -> (h: HubHarness, poor: FakeProvider, rich: FakeProvider) {
    // The provider with fewer signals comes first, so the preference can't come from the order.
    let poor = FakeProvider(id: "poor", signals: [.checkSuites])
    let rich = FakeProvider(id: "rich")
    return (HubHarness(providers: [poor, rich]), poor, rich)
  }

  /// The hub starts each provider.
  @Test func theHubStartsEachProvider() {
    let (_, poor, rich) = Self.twoProviders()

    #expect(poor.starts == 1 && poor.sink != nil)
    #expect(rich.starts == 1 && rich.sink != nil)
  }

  /// Each provider gets the ranked list in the order the poller ranked it.
  @Test func eachProviderGetsTheRankedInterestList() {
    let (h, poor, rich) = Self.twoProviders()
    let ranked = [prRef(9, repo: "acme/gadgets"), prRef(7), prRef(8)]

    h.endCycle(interest: ranked)

    #expect(poor.interest == ranked)
    #expect(rich.interest == ranked)
  }

  /// Signals from two providers for one PR cause one read.
  @Test func twoProvidersOnOnePRCauseOneRead() {
    let (h, poor, rich) = Self.twoProviders()

    h.signal(from: poor)
    h.signal(from: rich)
    h.advance(by: 60_000)

    #expect(h.reads == [.init(id: "PR_7", at: t0 + 2_000, trigger: .event)])
  }

  /// When two providers are live for one PR, the one that reports more signals covers it.
  @Test func theProviderThatReportsMoreSignalsCoversThePR() {
    let (h, poor, rich) = Self.twoProviders()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: poor)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: rich)

    h.advance(by: 60_000)

    #expect(h.covered["PR_7"] == rich.signals)
  }

  /// The PR leaves the interest list of the provider that reports fewer signals, and stays on the other's.
  @Test func thePRLeavesTheOtherProvidersInterestList() {
    let (h, poor, rich) = Self.twoProviders()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: poor)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: rich)

    h.endCycle()

    #expect(poor.interest == [prRef(8), prRef(9, repo: "acme/gadgets")])
    #expect(rich.interest == h.defaultInterest)
  }

  /// A provider with fewer signals keeps a PR that only it is live for.
  @Test func aProviderKeepsAPRThatOnlyItIsLiveFor() {
    let (h, poor, _) = Self.twoProviders()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: poor)

    h.endCycle()

    #expect(poor.interest == h.defaultInterest)
  }

  /// When the preferred provider goes down for the PR, the other provider gets the PR back.
  @Test func theOtherProviderGetsThePRBackWhenThePreferredOneGoesDown() throws {
    let (h, poor, rich) = Self.twoProviders()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: rich)
    h.endCycle()
    try #require(poor.interest?.contains(prRef(7)) == false)

    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"), from: rich)
    h.endCycle()

    #expect(poor.interest?.contains(prRef(7)) == true)
  }

  /// `down` from a provider that doesn't cover the PR leaves it covered by the other.
  @Test func downFromTheOtherProviderLeavesThePRCovered() {
    let (h, poor, rich) = Self.twoProviders()
    h.cover(by: rich)

    h.coverage(.down(.pr(prRef(7)), reason: "stream ended"), from: poor)

    #expect(h.covered["PR_7"] == rich.signals)
  }
}

/// Without a provider, or before one goes live, the poll rates stay what they are today.
@Suite struct PRChangeHubEmptyTests {
  static let pending = { () -> PullRequest in
    var pr = cachePR()
    pr.checks = "PENDING"
    return pr
  }()
  static let settled = { () -> PullRequest in
    var pr = cachePR()
    pr.reviewDecision = .approved
    pr.reviewDecisionRead = true
    pr.checks = "SUCCESS"
    return pr
  }()

  /// `dueReads` with the hub's coverage gives what it gives at the settings' uniform rates, for each PR state,
  /// read age, need, and `all`.
  @Test(arguments: [0, 1])
  func aHubWithoutCoverageLeavesDueReadsUnchanged(_ providers: Int) {
    let h = HubHarness(providers: (0..<providers).map { FakeProvider(id: "p\($0)") })
    var settings = GitHubSettings()
    settings.pollSeconds = 30
    settings.idlePollSeconds = 300
    let now = h.now
    let covered = h.covered
    let uniform = PollPolicy.uniform(PollRates(pendingMs: settings.pendingMs, idleMs: settings.idleMs))

    #expect(covered.isEmpty)
    for pr in [nil, Self.pending, Self.settled] as [PullRequest?] {
      for ago in [nil, 0, 29_999, 30_000, 299_999, 300_000] as [Int64?] {
        for needs in [[], Wait.Kind.ci.needs] as [ChangeSignals] {
          for all in [false, true] {
            let candidates = [
              "PR_7": ReadCandidate(pr: pr, lastPolled: ago.map { now - $0 }, waitedAt: nil, needs: needs)
            ]
            #expect(
              GitHub.dueReads(candidates, all: all, now: now, policy: settings.pollPolicy(covered: covered))
                == GitHub.dueReads(candidates, all: all, now: now, policy: uniform))
          }
        }
      }
    }
  }

  /// An empty hub reports no sources, which `sb sources` prints.
  @Test func anEmptyHubReportsNoSources() {
    let h = HubHarness(providers: [])

    #expect(h.queue.sync { h.hub.report() } == PRSources(providers: []))
  }

  /// An unavailable provider's report shows its state, reason, and retry time.
  @Test func anUnavailableProviderReportsItsReason() {
    let h = HubHarness()
    let reason = "Event subscriptions are not enabled for this account."

    h.availability(.unavailable(reason: reason, retryAt: t0 + 21_600_000))

    let source = h.queue.sync { h.hub.report() }.providers.first
    #expect(source?.id == "fake")
    #expect(source?.state == "unavailable")
    #expect(source?.reason == reason)
    #expect(source?.retryAt == t0 + 21_600_000)
  }
}

/// A poller with a fake provider whose session names a cached open PR, PR_7 in acme/widgets. GitHub answers every
/// request with a 502, so a poll changes nothing that the poller read.
private final class HubPoller {
  let h: PollerHarness
  let poller: GitHubPoller
  let provider = FakeProvider()

  init() throws {
    h = try PollerHarness()
    poller = GitHubPoller(
      service: h.service, settings: h.service.config.github, depot: h.service.config.depot,
      trunk: h.service.config.trunk, providers: [provider])
    h.service.github = poller
    h.service.queue.sync {
      var s = Session(id: "s1", name: "s1", cwd: h.home.path, claudeSessionId: "uuid-s1", created: 0)
      s.started = true
      var entry = Service.Entry(session: s)
      entry.facts.pr = cachePR()
      h.service.entries["s1"] = entry
    }
    poller.store(cachePR(), comments: [], polled: nowMs() - 1_000)
    poller.client.transport = { _ in (502, [:], Data(#"{"message":"bad gateway"}"#.utf8)) }
    poller.scheduleWake = { _ in }
    poller.start()
  }
}

/// The poller gives the hub its PRs at the end of each poll, and the hub's reads go through the poller's requests.
@Suite struct GitHubPollerHubTests {
  /// A poll gives the provider the open PR that the session names.
  @Test func aPollGivesTheProviderTheOpenPR() throws {
    let p = try HubPoller()

    _ = p.poller.poll(all: false)

    #expect(p.provider.interest == [PRRef(forge: "github.com", repo: "acme/widgets", number: 7)])
  }

  /// A poller with a provider reports it with the poll interval that the row shows.
  @Test func thePollerWithAProviderReportsThePollInterval() throws {
    let p = try HubPoller()

    let sources = p.poller.sources()

    #expect(sources.providers.map(\.id) == [p.provider.id])
    #expect(sources.pollSeconds == p.h.service.config.github.pollSeconds)
  }

  /// A signal for the PR asks the poller for an `event` read 2 s later.
  @Test func aSignalAsksThePollerForAnEventRead() throws {
    let p = try HubPoller()
    _ = p.poller.poll(all: false)
    let before = nowMs()

    p.provider.emit(.pr(prRef(7)))
    let read = p.poller.queue.sync { p.poller.readRequests.timedReads["PR_7"] }
    let after = nowMs()

    #expect(read?.trigger == .event)
    #expect(read.map { (before + 2_000)...(after + 2_000) ~= $0.at } == true)
  }

  /// The policy that a poll builds from a hub without coverage gives each PR the settings' rates.
  @Test func thePollsPolicyWithoutCoverageIsTheSettingsPolicy() throws {
    let p = try HubPoller()
    _ = p.poller.poll(all: false)
    let policy = p.poller.queue.sync { p.poller.pollPolicy() }
    let settings = p.h.service.config.github.pollPolicy()

    for pr in [nil, cachePR()] as [PullRequest?] {
      for needs in [[], Wait.Kind.ci.needs, .all] as [ChangeSignals] {
        #expect(policy.rates(pr, needs) == settings.rates(pr, needs))
      }
    }
  }

  /// The poller's own hub has no provider and reports no sources, with the poll interval that the row shows.
  @Test func thePollerWithoutProvidersReportsNoSources() throws {
    let h = try PollerHarness()

    #expect(h.poller.sources() == PRSources(providers: [], pollSeconds: h.poller.settings.pollSeconds))
  }
}

/// Edges of the hub's rules that the suites above don't reach.
@Suite struct PRChangeHubEdgeTests {
  /// A catch-up read whose poll stored no read is asked for at the next poll, not at a timed wake, so a failing
  /// GitHub can't make the wakes spin.
  @Test func aCatchUpThatAPollMissedWaitsForTheNextPoll() {
    let h = HubHarness()
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true))
    h.setNow(t0 + 10_000)
    _ = h.reader.requests.take(now: h.now)

    h.endCycle()

    #expect(h.reader.requests.nextPoll == ["PR_7": .catchup])
    #expect(h.reader.requests.timed.isEmpty)
  }

  /// A catch-up read that `ReadRequests` runs in place of the hub's spaced read serves the signals before it, and a
  /// signal after it gets a read of its own.
  @Test func aSignalAfterAnEarlierReadReplacedTheSpacedReadGetsARead() throws {
    let h = HubHarness()
    h.signal()
    h.advance(to: t0 + 3_000)
    h.signal()
    try #require(h.reader.requests.timed["PR_7"] == t0 + 17_000)
    h.coverage(.live(.pr(prRef(7)), since: t0 + 3_000, gap: true))
    h.advance(to: t0 + 9_000)
    try #require(h.reads.map(\.at) == [t0 + 2_000, t0 + 8_000])

    h.signal()
    h.advance(by: 60_000)

    #expect(h.reads.map(\.at) == [t0 + 2_000, t0 + 8_000, t0 + 23_000], "\(h.reads)")
  }

  /// A catch-up read that `ReadRequests` runs in place of a `head` signal's read comes too soon for the new head's
  /// suites, so the hub asks for the `head` read again.
  @Test func anEarlierCatchUpDoesNotTakeTheHeadSignalsRead() {
    let h = HubHarness()
    h.coverage(.live(.pr(prRef(7)), since: t0 - 4_000, gap: true))

    h.signal(kind: .head)
    h.advance(by: 60_000)

    #expect(
      h.reads == [
        .init(id: "PR_7", at: t0 + 1_000, trigger: .catchup), .init(id: "PR_7", at: t0 + 5_000, trigger: .event),
      ],
      "\(h.reads)")
  }

  /// The spacing counts from the time a signal's read ran, not from the time the hub asked for it.
  @Test func theSpacingCountsFromALateReadsTime() {
    let h = HubHarness()
    h.signal()
    h.setNow(t0 + 10_000)
    h.poll()

    h.setNow(t0 + 11_000)
    h.signal()

    #expect(h.reader.requests.timed["PR_7"] == t0 + 25_000)
  }

  /// After a failed read, a later read that serves the signal withdraws the hub's timed retry, so the next signal's
  /// read keeps the 15 s spacing.
  @Test func aReadThatServesTheSignalWithdrawsTheTimedRetry() throws {
    let h = HubHarness()
    h.signal()
    h.setNow(t0 + 2_000)
    _ = h.reader.requests.take(now: h.now)
    h.reader.requests.readAtNextPoll(["PR_7"], trigger: .event)
    h.endCycle()
    try #require(h.reader.requests.timed["PR_7"] == t0 + 17_000)
    h.setNow(t0 + 10_000)
    h.poll()

    h.setNow(t0 + 11_000)
    h.signal()

    #expect(h.reader.requests.timed["PR_7"] == t0 + 25_000)
  }

  /// A `head` signal that needs a read of its own after a pending read counts that read in `sb sources`.
  @Test func aHeadSignalsSecondReadCountsInTheReport() {
    let h = HubHarness()
    h.signal(kind: .checks)
    h.setNow(t0 + 1_000)
    h.signal(kind: .head)
    h.advance(by: 60_000)

    #expect(h.reads.count == 2)
    #expect(h.queue.sync { h.hub.report() }.providers.first?.reads == 2)
  }

  /// Of two live providers that report as many kinds of change, the one registered first keeps the PR.
  @Test func onATieTheFirstProviderKeepsThePR() {
    let a = FakeProvider(id: "a")
    let b = FakeProvider(id: "b")
    let h = HubHarness(providers: [a, b])
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: b)
    h.coverage(.live(.pr(prRef(7)), since: t0, gap: true), from: a)

    h.endCycle()

    #expect(a.interest?.contains(prRef(7)) == true)
    #expect(b.interest?.contains(prRef(7)) == false)
  }
}
