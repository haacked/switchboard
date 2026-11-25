import Foundation
import SwitchboardCore
import Testing
import os

@testable import SwitchboardService

/// A harness whose session names a settled PR, which the poller read a second ago. The timer is off, which makes the
/// pending interval 0, but a settled PR polls at the idle interval, so no poll finds it due. GitHub answers every
/// request with a 502. `statusReads` counts the status reads, and each poll that reads the PR sends one. `otherReads`
/// counts the other GraphQL requests, such as lookups.
private final class FailingReads {
  let h: PollerHarness
  let statusRequests = OSAllocatedUnfairLock(initialState: 0)
  let otherRequests = OSAllocatedUnfairLock(initialState: 0)
  /// The times at which the poller scheduled a wake, in order.
  let wakes = OSAllocatedUnfairLock(initialState: [Int64]())

  init(waits: [Wait] = []) throws {
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
    h.poller.store(pr, comments: [], polled: nowMs() - 1_000)
    h.poller.client.transport = { [statusRequests, otherRequests] req in
      if JSON.parse(String(decoding: req.httpBody ?? Data(), as: UTF8.self))?["query"]?.string == GitHub.statusQuery {
        statusRequests.withLock { $0 += 1 }
      } else {
        otherRequests.withLock { $0 += 1 }
      }
      return (502, [:], Data(#"{"message":"bad gateway"}"#.utf8))
    }
    h.poller.scheduleWake = { [wakes] at in wakes.withLock { $0.append(at) } }
  }

  var poller: GitHubPoller { h.poller }
  var statusReads: Int { statusRequests.withLock { $0 } }
  var otherReads: Int { otherRequests.withLock { $0 } }
  var scheduled: [Int64] { wakes.withLock { $0 } }
  var requests: ReadRequests { poller.queue.sync { poller.readRequests } }

  func request(_ ids: [String], after: Int64, trigger: ReadTrigger) {
    poller.queue.sync { poller.requestRead(ids, after: after, trigger: trigger) }
  }
  func wake() { poller.queue.sync { poller.readWake() } }

  /// What a poll at `now` would take from the requests, with each one's trigger.
  func pendingReads(now: Int64 = .max) -> [String: ReadTrigger] {
    var copy = requests
    return copy.take(now: now)
  }

  /// The PR reads that `sb poll --stats` reports under `trigger` for the harness PR's owner.
  func usage(_ trigger: String) -> JSON? { poller.usageReport()["reads"]?[trigger]?["acme"] }
  /// The triggers that `sb poll --stats` reports any PR read under.
  func usedTriggers() -> Set<String> { Set(poller.usageReport()["reads"]?.object.map { Array($0.keys) } ?? []) }

  func clearWaits() { h.service.queue.sync { h.service.entries["s1"]?.session.waits = [] } }
}

/// A poll that fails puts the requested reads that it took back, so the next poll reads them with their triggers.
@Suite struct GitHubPollerRequestRestoreTests {
  /// After a wake whose poll fails, the next poll reads the requested PR once more.
  @Test func theNextPollReadsARequestThatAFailedWakeTook() throws {
    let r = try FailingReads()
    r.request(["PR_7"], after: 0, trigger: .confirm)
    r.wake()
    #expect(r.statusReads == 1)

    _ = r.poller.poll(all: false)

    #expect(r.statusReads == 2)
  }

  /// A wake whose poll fails schedules no second wake, and neither does the poll after it.
  @Test func aFailedWakeSchedulesNoExtraWake() throws {
    let r = try FailingReads()
    r.request(["PR_7"], after: 0, trigger: .confirm)
    r.wake()

    _ = r.poller.poll(all: false)

    #expect(r.scheduled.count == 1)
  }

  /// A failed poll puts each taken read back as a next-poll read with the trigger it was requested with.
  @Test(arguments: [ReadTrigger.event, .catchup, .confirm, .wait])
  func aFailedPollPutsTheTakenReadBackAtTheNextPollWithItsTrigger(_ trigger: ReadTrigger) throws {
    let r = try FailingReads()
    r.request(["PR_7"], after: 0, trigger: trigger)

    r.wake()

    #expect(Set(r.requests.nextPoll.keys) == ["PR_7"])
    #expect(r.requests.timed["PR_7"] == nil)
    #expect(r.pendingReads() == ["PR_7": trigger])
  }

  /// A failed poll leaves a timed read that it did not take at its time, with its own trigger.
  @Test func aFailedPollLeavesTheReadsItDidNotTakeTimed() throws {
    let r = try FailingReads()
    r.request(["PR_7"], after: 0, trigger: .event)
    r.request(["PR_8"], after: 60_000, trigger: .confirm)

    r.wake()

    #expect(Set(r.requests.nextPoll.keys) == ["PR_7"])
    #expect(Set(r.requests.timed.keys) == ["PR_8"])
    #expect(r.pendingReads() == ["PR_7": .event, "PR_8": .confirm])
  }

  /// A poll whose lookup fails, before it reads any PR, puts the taken read back with its trigger.
  @Test func aFailedLookUpPutsTheTakenReadBack() throws {
    let other = Wait(
      id: "w9", kind: .merge, pr: Wait.PullRequest(repository: "acme/widgets", number: 9), created: 1, then: .notify)
    let r = try FailingReads(waits: [other])
    r.request(["PR_7"], after: 0, trigger: .confirm)

    r.wake()

    try #require(r.otherReads > 0)
    try #require(r.statusReads == 0)
    #expect(r.pendingReads() == ["PR_7": .confirm])
  }

  /// Once the lookup no longer fails, the next poll reads the read that the failed lookup put back.
  @Test func theNextPollReadsARequestThatAFailedLookUpTook() throws {
    let other = Wait(
      id: "w9", kind: .merge, pr: Wait.PullRequest(repository: "acme/widgets", number: 9), created: 1, then: .notify)
    let r = try FailingReads(waits: [other])
    r.request(["PR_7"], after: 0, trigger: .confirm)
    r.wake()
    try #require(r.statusReads == 0)
    r.clearWaits()

    _ = r.poller.poll(all: false)

    #expect(r.statusReads == 1)
  }

  /// `sb poll --stats` counts a requested read under the trigger it was requested with, not under `wait`.
  @Test(arguments: [ReadTrigger.event, .catchup, .confirm])
  func aRequestedReadCountsUnderItsTrigger(_ trigger: ReadTrigger) throws {
    let r = try FailingReads()
    r.request(["PR_7"], after: 0, trigger: trigger)

    r.wake()

    #expect(r.usedTriggers() == [trigger.rawValue])
  }

  /// The read that a failed poll put back counts under its trigger at the next poll too.
  @Test func aReadThatAFailedPollPutBackCountsUnderItsTrigger() throws {
    let r = try FailingReads()
    r.request(["PR_7"], after: 0, trigger: .catchup)
    r.wake()

    _ = r.poller.poll(all: false)

    try #require(r.statusReads == 2)
    #expect(r.usedTriggers() == ["catchup"])
    #expect(r.usage("catchup")?["requests"]?.double == Double(r.statusReads))
  }

  /// `sb poll --all` counts a requested read as `poll`.
  @Test func sbPollAllCountsARequestedReadAsPoll() throws {
    let r = try FailingReads()
    r.request(["PR_7"], after: 0, trigger: .event)

    _ = r.poller.poll(all: true)

    #expect(r.usedTriggers() == ["poll"])
  }

  /// A wait newer than the PR's last read counts a requested read as `wait`.
  @Test func aNewerWaitCountsARequestedReadAsWait() throws {
    let r = try FailingReads(waits: [Wait(id: "w1", kind: .ci, headSha: "head1", created: nowMs())])
    r.request(["PR_7"], after: 0, trigger: .event)

    _ = r.poller.poll(all: false)

    #expect(r.usedTriggers() == ["wait"])
  }
}
