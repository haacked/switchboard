import Foundation
import Testing

@testable import SwitchboardCore

/// The reads that the poller makes outside a PR's interval, and the wakes that run a poll for them.
@Suite struct ReadRequestsTests {
  static let t: Int64 = 1_000_000

  @Test func theFirstTimedRequestSchedulesAWakeAtItsTime() {
    var r = ReadRequests()
    let wake = r.request(["A"], at: Self.t + 2_000, trigger: .event)
    #expect(wake == Self.t + 2_000)
    #expect(r.wake == Self.t + 2_000)
  }

  /// Later requests join the scheduled wake. Each of them would otherwise push the poll back.
  @Test func aBurstOfRequestsSharesOneWake() {
    var r = ReadRequests()
    var wakes = [r.request(["A"], at: Self.t + 2_000, trigger: .event)]
    wakes.append(r.request(["B"], at: Self.t + 2_100, trigger: .event))
    wakes.append(r.request(["A", "C"], at: Self.t + 2_200, trigger: .event))
    wakes.append(r.request(["D"], at: Self.t + 2_000, trigger: .event))
    #expect(wakes == [Self.t + 2_000, nil, nil, nil])
    let taken = Set(r.take(now: Self.t + 2_200).keys)
    #expect(taken == ["A", "B", "C", "D"])
  }

  @Test func anEarlierRequestMovesTheWakeEarlier() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 10_000, trigger: .event)
    let wake = r.request(["B"], at: Self.t + 2_000, trigger: .event)
    #expect(wake == Self.t + 2_000)
    #expect(r.wake == Self.t + 2_000)
  }

  /// A PR that is requested again keeps its earlier time, so a stream of requests can't put its read off.
  @Test func aRepeatedRequestKeepsTheEarlierTime() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 2_000, trigger: .event)
    _ = r.request(["A"], at: Self.t + 9_000, trigger: .event)
    #expect(r.timed == ["A": Self.t + 2_000])
    _ = r.request(["A"], at: Self.t + 1_000, trigger: .event)
    #expect(r.timed == ["A": Self.t + 1_000])
  }

  /// A poll reads the timed requests that are due and leaves the rest for a later wake.
  @Test func aPollTakesOnlyTheDueRequests() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 2_000, trigger: .event)
    _ = r.request(["B"], at: Self.t + 5_000, trigger: .event)
    let taken = Set(r.take(now: Self.t + 1_999).keys)
    #expect(taken == [])
    let taken2 = Set(r.take(now: Self.t + 2_000).keys)
    #expect(taken2 == ["A"])
    #expect(r.timed == ["B": Self.t + 5_000])
  }

  /// After the wake's poll, the poller schedules a wake for the requests that the poll left.
  @Test func theWakeRearmsForTheRequestsThatThePollLeft() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 2_000, trigger: .event)
    _ = r.request(["B"], at: Self.t + 5_000, trigger: .event)
    let due = r.fire(now: Self.t + 2_000)
    #expect(due)
    let taken = Set(r.take(now: Self.t + 2_000).keys)
    #expect(taken == ["A"])
    let next = r.rearm()
    #expect(next == Self.t + 5_000)
    #expect(r.wake == Self.t + 5_000)
    let next2 = r.rearm()
    #expect(next2 == nil)
  }

  /// A timer poll that came first took the request, so the wake runs no second poll.
  @Test func aWakeAfterAPollTookItsRequestsRunsNoPoll() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 2_000, trigger: .event)
    let taken = Set(r.take(now: Self.t + 2_000).keys)
    #expect(taken == ["A"])
    let due = r.fire(now: Self.t + 2_001)
    #expect(!due)
    let next = r.rearm()
    #expect(next == nil)
    #expect(r.wake == nil)
  }

  /// A request made during the wake's poll schedules its own wake, and the rearm keeps it.
  @Test func aRequestDuringTheWakesPollSchedulesItsOwnWake() {
    var r = ReadRequests()
    _ = r.request(["A"], at: Self.t + 2_000, trigger: .event)
    _ = r.request(["B"], at: Self.t + 20_000, trigger: .event)
    let due = r.fire(now: Self.t + 2_000)
    #expect(due)
    _ = r.take(now: Self.t + 2_000)
    let wake = r.request(["C"], at: Self.t + 12_000, trigger: .event)
    #expect(wake == Self.t + 12_000)
    let next = r.rearm()
    #expect(next == nil)
    #expect(r.wake == Self.t + 12_000)
  }

  /// A read at the next poll waits for whatever poll comes next, as the dependency recheck does.
  @Test func aReadAtTheNextPollSchedulesNoWake() {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: .wait)
    #expect(r.wake == nil)
    let next = r.rearm()
    #expect(next == nil)
    let due = r.fire(now: Self.t)
    #expect(!due)
    let taken = Set(r.take(now: Self.t).keys)
    #expect(taken == ["A"])
    let taken2 = Set(r.take(now: Self.t + 1).keys)
    #expect(taken2 == [])
  }

  @Test func aPollTakesTheNextPollReadsWithTheDueTimedReads() {
    var r = ReadRequests()
    r.readAtNextPoll(["A"], trigger: .wait)
    _ = r.request(["B"], at: Self.t, trigger: .event)
    _ = r.request(["C"], at: Self.t + 1, trigger: .event)
    let taken = Set(r.take(now: Self.t).keys)
    #expect(taken == ["A", "B"])
  }
}
