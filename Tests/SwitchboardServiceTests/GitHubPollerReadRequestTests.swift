import Foundation
import SwitchboardCore
import Testing
import os

@testable import SwitchboardService

/// A harness whose session names a settled PR, which the poller read a second ago. The timer is off, which makes the
/// pending interval 0, but a settled PR polls at the idle interval, so no poll finds it due. GitHub answers
/// every request with a 502, and `requests` counts the status reads. Each poll that reads the PR sends one.
private final class RequestedReads {
  let h: PollerHarness
  let requests = OSAllocatedUnfairLock(initialState: 0)
  /// The times at which the poller scheduled a wake, in order.
  let wakes = OSAllocatedUnfairLock(initialState: [Int64]())

  init(fakeWakes: Bool = true, waits: [Wait] = []) throws {
    h = try PollerHarness()
    var pr = cachePR()
    pr.reviewDecision = .approved
    pr.reviewDecisionRead = true
    pr.checks = "SUCCESS"
    h.service.queue.sync {
      var s = Session(id: "s1", name: "s1", cwd: h.home.path, claudeSessionId: "uuid-s1", created: 0)
      s.started = true
      s.waits = waits
      var entry = Service.Entry(session: s)
      entry.facts.pr = pr
      h.service.entries["s1"] = entry
    }
    // A requested read counts only when it is newer than the last read, as a wait does.
    h.poller.store(pr, comments: [], polled: nowMs() - 1_000)
    h.poller.client.transport = { [requests] req in
      if JSON.parse(String(decoding: req.httpBody ?? Data(), as: UTF8.self))?["query"]?.string == GitHub.statusQuery {
        requests.withLock { $0 += 1 }
      }
      return (502, [:], Data(#"{"message":"bad gateway"}"#.utf8))
    }
    if fakeWakes { h.poller.scheduleWake = { [wakes] at in wakes.withLock { $0.append(at) } } }
  }

  var poller: GitHubPoller { h.poller }
  var count: Int { requests.withLock { $0 } }
  var scheduled: [Int64] { wakes.withLock { $0 } }

  func request(_ ids: [String], after: Int64) {
    poller.queue.sync { poller.requestRead(ids, after: after, trigger: .event) }
  }
  func wake() { poller.queue.sync { poller.readWake() } }
}

/// `requestRead` reads a PR outside its interval, at one poll that a burst of requests shares.
@Suite struct GitHubPollerReadRequestTests {
  @Test func aPollReadsNothingWhileThePRIsNotDue() throws {
    let r = try RequestedReads()
    _ = r.poller.poll(all: false)
    #expect(r.count == 0)
  }

  @Test func theWakeReadsARequestedPRThatIsNotDue() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0)
    r.wake()
    #expect(r.count == 1)
  }

  @Test func aBurstOfRequestsSchedulesOneWakeAndOneRead() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0)
    r.request(["PR_7"], after: 0)
    r.request(["PR_7", "PR_8"], after: 0)
    #expect(r.scheduled.count == 1)
    r.wake()
    #expect(r.count == 1)
    #expect(r.scheduled.count == 1)
  }

  /// The timer's poll or `sb poll` read the request first, so the wake runs no second poll.
  @Test func aWakeAfterAPollReadTheRequestRunsNoPoll() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0)
    _ = r.poller.poll(all: false)
    #expect(r.count == 1)
    r.wake()
    #expect(r.count == 1)
  }

  /// A request after the scheduled wake joins it, and the wake's poll schedules the next wake for it.
  @Test func aLaterRequestGetsAWakeOnceTheFirstWakesPollRan() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0)
    r.request(["PR_8"], after: 60_000)
    #expect(r.scheduled.count == 1)
    r.wake()
    #expect(r.count == 1)
    let wakes = r.scheduled
    try #require(wakes.count == 2)
    #expect(wakes[1] - wakes[0] >= 59_000)
  }

  /// Without the test's wakes, the poller's own timer runs the poll.
  @Test func theTimerRunsThePollOfARequest() throws {
    let r = try RequestedReads(fakeWakes: false)
    r.request(["PR_7"], after: 0)
    let deadline = Date().addingTimeInterval(30)
    while r.count == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    #expect(r.count == 1)
  }
}

/// `confirmReadAfter` asks for the read that confirms a `ci` wait's outcome at a set time.
@Suite struct GitHubPollerConfirmReadTests {
  /// A `ci` wait at the harness PR's head, set before the PR's last read, which shows the checks passed.
  static func ciWait() -> Wait { Wait(id: "w1", kind: .ci, headSha: "head1", created: nowMs() - 2_000) }

  @Test func withoutADelayTheConfirmingReadWaitsForTheNextDuePoll() throws {
    let r = try RequestedReads(waits: [Self.ciWait()])
    _ = r.poller.poll(all: false)
    #expect(r.poller.queue.sync { r.poller.confirming["w1"] } != nil)
    #expect(r.scheduled.isEmpty)
  }

  @Test func aDelaySchedulesTheConfirmingReadThatLongAfterTheFirstRead() throws {
    let r = try RequestedReads(waits: [Self.ciWait()])
    r.poller.confirmReadAfter = 10_000
    let before = nowMs()
    _ = r.poller.poll(all: false)
    #expect(r.poller.queue.sync { r.poller.confirming["w1"] } != nil)
    let wakes = r.scheduled
    try #require(wakes.count == 1)
    #expect(wakes[0] >= before + 10_000)
    #expect(r.poller.queue.sync { r.poller.readRequests.timed.keys.sorted() } == ["PR_7"])
  }
}
