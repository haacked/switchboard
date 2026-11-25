import Foundation
import Testing

@testable import SwitchboardCore

/// The reason that `ReadRequests` keeps for each requested read, which `take` hands to the poll.
@Suite struct ReadRequestTriggerTests {
  static let t: Int64 = 1_000_000

  /// A read at the next poll comes back from `take` with the trigger it was requested with.
  @Test(arguments: ReadTrigger.allCases)
  func aNextPollRequestIsTakenWithItsTrigger(_ trigger: ReadTrigger) {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: trigger)

    let taken = r.take(now: Self.t)

    #expect(taken == ["A": trigger])
  }

  /// A timed read comes back from `take` with its trigger once it is due, and not before.
  @Test(arguments: ReadTrigger.allCases)
  func aTimedRequestIsTakenWithItsTriggerOnceDue(_ trigger: ReadTrigger) {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 2_000, trigger: trigger)

    let early = r.take(now: Self.t + 1_999)
    let due = r.take(now: Self.t + 2_000)

    #expect(early == [:])
    #expect(due == ["A": trigger])
  }

  /// A poll takes the next-poll reads and the due timed reads, each with its own trigger.
  @Test func aPollTakesEachDueReadWithItsOwnTrigger() {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: .wait)
    _ = r.request(["B"], at: Self.t, trigger: .confirm)
    _ = r.request(["C"], at: Self.t + 1, trigger: .catchup)
    r.readAtNextPoll(["D"], trigger: .event)

    let taken = r.take(now: Self.t)

    #expect(taken == ["A": .wait, "B": .confirm, "D": .event])
  }

  /// A second timed request that comes due earlier replaces the first request's trigger.
  @Test func anEarlierTimedRequestReplacesTheTrigger() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 2_000, trigger: .confirm)
    _ = r.request(["A"], at: Self.t + 1_000, trigger: .event)

    let taken = r.take(now: Self.t + 2_000)

    #expect(taken == ["A": .event])
  }

  /// A second timed request that comes due later leaves the first request's trigger.
  @Test func aLaterTimedRequestKeepsTheEarlierTrigger() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 1_000, trigger: .confirm)
    _ = r.request(["A"], at: Self.t + 2_000, trigger: .event)

    let taken = r.take(now: Self.t + 2_000)

    #expect(taken == ["A": .confirm])
  }

  /// Two timed requests that come due at the same time keep the trigger of the first one.
  @Test(arguments: [(ReadTrigger.confirm, ReadTrigger.event), (.event, .confirm), (.catchup, .wait)])
  func aTimedRequestAtTheSameTimeKeepsTheExistingTrigger(_ first: ReadTrigger, _ second: ReadTrigger) {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 1_000, trigger: first)
    _ = r.request(["A"], at: Self.t + 1_000, trigger: second)

    let taken = r.take(now: Self.t + 1_000)

    #expect(taken == ["A": first])
  }

  /// Two next-poll requests keep the trigger of the first one.
  @Test func aRepeatedNextPollRequestKeepsTheExistingTrigger() {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: .event)
    r.readAtNextPoll(["A", "B"], trigger: .catchup)

    let taken = r.take(now: Self.t)

    #expect(taken == ["A": .event, "B": .catchup])
  }

  /// A next-poll request comes due before a timed one, so it replaces the timed request's trigger, even when the
  /// timed request is already due.
  @Test(arguments: [ReadRequestTriggerTests.t - 1_000, ReadRequestTriggerTests.t, ReadRequestTriggerTests.t + 5_000])
  func aNextPollRequestReplacesTheTriggerOfATimedRequest(_ at: Int64) {
    var r = ReadRequests()
    _ = r.request(["A"], at: at, trigger: .confirm)
    r.readAtNextPoll(["A"], trigger: .event)

    let taken = r.take(now: Self.t)

    #expect(taken["A"] == .event)
  }

  /// A timed request after a next-poll request comes due later, so the next-poll request's trigger stays, even when
  /// the timed request is already due.
  @Test(arguments: [ReadRequestTriggerTests.t - 1_000, ReadRequestTriggerTests.t, ReadRequestTriggerTests.t + 5_000])
  func aTimedRequestKeepsTheTriggerOfANextPollRequest(_ at: Int64) {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: .event)
    _ = r.request(["A"], at: at, trigger: .confirm)

    let taken = r.take(now: Self.t)

    #expect(taken["A"] == .event)
  }

  /// A PR with a next-poll request and a later timed request reads at each, each time with its own trigger.
  @Test func aTimedRequestThatANextPollTakeLeavesKeepsItsOwnTrigger() {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: .wait)
    _ = r.request(["A"], at: Self.t + 5_000, trigger: .confirm)

    let first = r.take(now: Self.t)
    let second = r.take(now: Self.t + 5_000)

    #expect(first == ["A": .wait])
    #expect(second == ["A": .confirm])
  }

  /// A timed request that a take leaves comes back with its own trigger at a later take.
  @Test func aRequestThatATakeLeavesKeepsItsTrigger() {
    var r = ReadRequests()
    r.readAtNextPoll(["C"], trigger: .catchup)
    _ = r.request(["A"], at: Self.t + 1_000, trigger: .event)
    _ = r.request(["B"], at: Self.t + 5_000, trigger: .confirm)

    let first = r.take(now: Self.t + 1_000)
    let second = r.take(now: Self.t + 5_000)

    #expect(first == ["A": .event, "C": .catchup])
    #expect(second == ["B": .confirm])
  }

  /// A read that a poll took leaves no trigger behind, so a new request for the PR carries the new trigger.
  @Test(arguments: [false, true])
  func aNewRequestAfterATakeCarriesItsOwnTrigger(_ timed: Bool) {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: .event)
    _ = r.take(now: Self.t)
    if timed {
      _ = r.request(["A"], at: Self.t, trigger: .confirm)
    } else {
      r.readAtNextPoll(["A"], trigger: .confirm)
    }

    let taken = r.take(now: Self.t)

    #expect(taken == ["A": .confirm])
  }

  /// A timed read that was already taken leaves no trigger behind for a later request at a later time.
  @Test func aLaterRequestAfterATakenTimedReadCarriesItsOwnTrigger() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t, trigger: .event)
    _ = r.take(now: Self.t)
    _ = r.request(["A"], at: Self.t + 5_000, trigger: .confirm)

    let taken = r.take(now: Self.t + 5_000)

    #expect(taken == ["A": .confirm])
  }

  /// A request at the latest time that an `Int64` holds still comes back with its trigger.
  @Test func aRequestAtTheLatestTimeIsTakenWithItsTrigger() {
    var r = ReadRequests()
    _ = r.request(["A"], at: .max, trigger: .confirm)

    let taken = r.take(now: .max)

    #expect(taken == ["A": .confirm])
  }
}

/// The new triggers that `sb poll --stats` reports reads under.
@Suite struct NewReadTriggerTests {
  /// The new triggers carry the names that `sb poll --stats` shows.
  @Test func theNewTriggersHaveTheirDecidedNames() {
    #expect(Set(ReadTrigger.allCases.map(\.rawValue)).isSuperset(of: ["event", "catchup", "confirm"]))
  }

  /// The usage report keys a read under each new trigger by the trigger's name.
  @Test(arguments: [ReadTrigger.event, .catchup, .confirm])
  func theUsageReportCountsAReadUnderANewTrigger(_ trigger: ReadTrigger) {
    var usage = GitHubUsage(since: 0)
    usage.share(
      requests: 1, points: 1, among: [GitHubUsage.Read(trigger: trigger, owner: "haacked")], countsReads: true)

    let report = usage.report(now: 3_600_000)

    #expect(report.reads[trigger.rawValue]?["haacked"]?.reads == 1)
  }
}

/// Where a requested read falls in the order of `GitHub.readTrigger`: after `all` and a newer wait, before a first,
/// pending, or idle read.
@Suite struct RequestedReadTriggerTests {
  static let now: Int64 = 1_000_000_000
  static let pendingMs: Int64 = 30_000
  static let idleMs: Int64 = 300_000

  static let pending = samplePR(checks: "PENDING")
  static let settled = samplePR(reviewDecision: .approved, checks: "SUCCESS", reviewDecisionRead: true)

  func trigger(
    _ pr: PullRequest?, polledAgo: Int64?, waitedAgo: Int64? = nil, requested: ReadTrigger?, all: Bool = false,
    pendingRate: Bool = false
  ) -> ReadTrigger? {
    GitHub.readTrigger(
      pr, lastPolled: polledAgo.map { Self.now - $0 }, waitedAt: waitedAgo.map { Self.now - $0 },
      requested: requested, all: all, pendingRate: pendingRate, now: Self.now, pendingMs: Self.pendingMs,
      idleMs: Self.idleMs)
  }

  /// `sb poll --all` counts a requested read as `poll`.
  @Test(arguments: ReadTrigger.allCases)
  func sbPollAllWinsOverARequest(_ requested: ReadTrigger) {
    #expect(trigger(Self.settled, polledAgo: 10, requested: requested, all: true) == .poll)
  }

  /// A wait newer than the PR's last read counts a requested read as `wait`.
  @Test(arguments: ReadTrigger.allCases)
  func aNewerWaitWinsOverARequest(_ requested: ReadTrigger) {
    #expect(trigger(Self.settled, polledAgo: 10, waitedAgo: 5, requested: requested) == .wait)
  }

  /// A wait no newer than the PR's last read leaves a requested read under its requested trigger.
  @Test(arguments: [Int64(10), 11, 1_000_000])
  func anOlderWaitLeavesTheRequestedTrigger(_ waitedAgo: Int64) {
    #expect(trigger(Self.settled, polledAgo: 10, waitedAgo: waitedAgo, requested: .event) == .event)
  }

  /// A requested read of a PR that was never read counts under its requested trigger, not as `first`.
  @Test(arguments: ReadTrigger.allCases)
  func aRequestWinsOverAFirstRead(_ requested: ReadTrigger) {
    #expect(trigger(nil, polledAgo: nil, requested: requested) == requested)
  }

  /// A requested read of a PR that isn't due still reads it, under its requested trigger.
  @Test(
    arguments: [
      (RequestedReadTriggerTests.settled, false), (RequestedReadTriggerTests.settled, true),
      (RequestedReadTriggerTests.pending, false),
    ] as [(PullRequest, Bool)])
  func aRequestReadsAPRThatIsNotDue(_ pr: PullRequest, _ pendingRate: Bool) {
    for requested in ReadTrigger.allCases {
      #expect(trigger(pr, polledAgo: 0, requested: requested, pendingRate: pendingRate) == requested)
    }
  }

  /// A requested read of a PR that is due counts under its requested trigger, not as `pending` or `idle`.
  @Test(
    arguments: [
      (RequestedReadTriggerTests.pending, RequestedReadTriggerTests.pendingMs),
      (RequestedReadTriggerTests.settled, RequestedReadTriggerTests.idleMs),
    ] as [(PullRequest, Int64)])
  func aRequestWinsOverAPendingOrIdleRead(_ pr: PullRequest, _ polledAgo: Int64) {
    #expect(trigger(pr, polledAgo: polledAgo, requested: .confirm) == .confirm)
  }

  /// Without a request, the trigger stays what it was before requests carried a trigger.
  @Test func noRequestLeavesTheOtherTriggers() {
    #expect(trigger(nil, polledAgo: nil, requested: nil) == .first)
    #expect(trigger(Self.settled, polledAgo: 0, requested: nil) == nil)
    #expect(trigger(Self.pending, polledAgo: Self.pendingMs, requested: nil) == .pending)
    #expect(trigger(Self.settled, polledAgo: Self.idleMs, requested: nil) == .idle)
  }

  /// `dueReads` reads a requested candidate under the trigger that `readTrigger` gives it.
  @Test(arguments: [false, true])
  func dueReadsCountsARequestedCandidateUnderItsTrigger(_ all: Bool) {
    let rates = PollRates(pendingMs: Self.pendingMs, idleMs: Self.idleMs)
    let candidates = [
      "requested": ReadCandidate(
        pr: Self.settled, lastPolled: Self.now - 10, waitedAt: nil, requested: .catchup, needs: []),
      "waited": ReadCandidate(
        pr: Self.settled, lastPolled: Self.now - 10, waitedAt: Self.now - 5, requested: .catchup, needs: []),
      "quiet": ReadCandidate(pr: Self.settled, lastPolled: Self.now - 10, waitedAt: nil, requested: nil, needs: []),
    ]

    let due = GitHub.dueReads(candidates, all: all, now: Self.now, policy: .uniform(rates))

    #expect(
      due == (all ? ["requested": .poll, "waited": .poll, "quiet": .poll] : ["requested": .catchup, "waited": .wait]))
  }
}
