import Foundation
import SwitchboardCore
import Testing
import os

@testable import SwitchboardService

/// A harness whose session names a settled PR, which the poller read a second ago. The timer is off, which makes the
/// pending interval 0, but a settled PR polls at the idle interval, so no poll finds it due. GitHub answers
/// every request with a 502, and `requests` counts the status reads. Each poll that reads the PR sends one.
/// `otherRequests` counts the other GraphQL requests, such as lookups.
private final class RequestedReads {
  let h: PollerHarness
  let requests = OSAllocatedUnfairLock(initialState: 0)
  let otherRequests = OSAllocatedUnfairLock(initialState: 0)
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
    h.poller.client.transport = { [requests, otherRequests] req in
      if JSON.parse(String(decoding: req.httpBody ?? Data(), as: UTF8.self))?["query"]?.string == GitHub.statusQuery {
        requests.withLock { $0 += 1 }
      } else {
        otherRequests.withLock { $0 += 1 }
      }
      return (502, [:], Data(#"{"message":"bad gateway"}"#.utf8))
    }
    if fakeWakes { h.poller.scheduleWake = { [wakes] at in wakes.withLock { $0.append(at) } } }
  }

  var poller: GitHubPoller { h.poller }
  var count: Int { requests.withLock { $0 } }
  var otherReads: Int { otherRequests.withLock { $0 } }
  var scheduled: [Int64] { wakes.withLock { $0 } }
  var readRequests: ReadRequests { poller.queue.sync { poller.readRequests } }

  func request(_ ids: [String], after: Int64, trigger: ReadTrigger = .event) {
    poller.queue.sync { poller.requestRead(ids, after: after, trigger: trigger) }
  }
  func wake() { poller.queue.sync { poller.readWake() } }

  /// What a poll at `now` would take from the requests, with each one's trigger.
  func pendingReads(now: Int64 = .max) -> [String: ReadTrigger] {
    var copy = readRequests
    return copy.take(now: now)
  }

  /// The PR reads that `sb poll --stats` reports under `trigger` for the harness PR's owner.
  func usage(_ trigger: String) -> JSON? { poller.usageReport()["reads"]?[trigger]?["acme"] }
  /// The triggers that `sb poll --stats` reports any PR read under.
  func usedTriggers() -> Set<String> { Set(poller.usageReport()["reads"]?.object.map { Array($0.keys) } ?? []) }

  func clearWaits() { h.service.queue.sync { h.service.entries["s1"]?.session.waits = [] } }
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
    #expect(r.poller.queue.sync { r.poller.readRequests.timedReads["PR_7"]?.trigger } == .confirm)
  }
}

/// A poll that fails puts the requested reads that it took back, so the next poll reads them with their triggers.
@Suite struct GitHubPollerRequestRestoreTests {
  /// After a wake whose poll fails, the next poll reads the requested PR once more.
  @Test func theNextPollReadsARequestThatAFailedWakeTook() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0, trigger: .confirm)
    r.wake()
    #expect(r.count == 1)

    _ = r.poller.poll(all: false)

    #expect(r.count == 2)
  }

  /// A wake whose poll fails schedules no second wake, and neither does the poll after it.
  @Test func aFailedWakeSchedulesNoExtraWake() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0, trigger: .confirm)
    r.wake()

    _ = r.poller.poll(all: false)

    #expect(r.scheduled.count == 1)
  }

  /// A failed poll puts each taken read back as a next-poll read with the trigger it was requested with.
  @Test(arguments: [ReadTrigger.event, .catchup, .confirm, .wait])
  func aFailedPollPutsTheTakenReadBackAtTheNextPollWithItsTrigger(_ trigger: ReadTrigger) throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0, trigger: trigger)

    r.wake()

    #expect(Set(r.readRequests.nextPoll.keys) == ["PR_7"])
    #expect(r.readRequests.timed["PR_7"] == nil)
    #expect(r.pendingReads() == ["PR_7": trigger])
  }

  /// A failed poll leaves a timed read that it did not take at its time, with its own trigger.
  @Test func aFailedPollLeavesTheReadsItDidNotTakeTimed() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0, trigger: .event)
    r.request(["PR_8"], after: 60_000, trigger: .confirm)

    r.wake()

    #expect(Set(r.readRequests.nextPoll.keys) == ["PR_7"])
    #expect(Set(r.readRequests.timed.keys) == ["PR_8"])
    #expect(r.pendingReads() == ["PR_7": .event, "PR_8": .confirm])
  }

  /// A poll that reads a requested PR and then fails on a later query doesn't put that read back.
  @Test func aFailureAfterTheStatusReadDoesNotPutTheReadBack() throws {
    let r = try RequestedReads()
    // The PR's base isn't its repo's default branch, so the poll reads the merged base after the status, and that
    // read fails.
    let node: JSON = [
      "id": "PR_7", "number": 7, "state": "OPEN", "headRefName": "feature", "baseRefName": "stack-1", "body": "",
      "mergeCommit": .null, "repository": ["nameWithOwner": "acme/widgets", "defaultBranchRef": ["name": "main"]],
    ]
    let status = Data(JSON.object(["data": ["rateLimit": ["cost": 1], "nodes": [node]]]).text.utf8)
    r.poller.client.transport = { req in
      let query = JSON.parse(String(decoding: req.httpBody ?? Data(), as: UTF8.self))?["query"]?.string
      return query == GitHub.statusQuery ? (200, [:], status) : (502, [:], Data(#"{"message":"bad gateway"}"#.utf8))
    }
    r.request(["PR_7"], after: 0, trigger: .event)

    let result = r.poller.poll(all: false)

    #expect(result["error"] != nil)
    #expect(r.poller.queue.sync { r.poller.prs["PR_7"]?.pr.base } == "stack-1")
    #expect(r.pendingReads().isEmpty)
  }

  /// A failed poll drops a requested read of a PR that no session, wait, or merge trigger names.
  @Test func aFailedPollDropsARequestForAPRThatNothingNames() throws {
    let r = try RequestedReads()
    r.request(["PR_7", "PR_99"], after: 0, trigger: .event)

    r.wake()

    #expect(r.pendingReads() == ["PR_7": .event])
  }

  /// A poll whose lookup fails, before it reads any PR, puts the taken read back with its trigger.
  @Test func aFailedLookUpPutsTheTakenReadBack() throws {
    let other = Wait(
      id: "w9", kind: .merge, pr: Wait.PullRequest(repository: "acme/widgets", number: 9), created: 1, then: .notify)
    let r = try RequestedReads(waits: [other])
    r.request(["PR_7"], after: 0, trigger: .confirm)

    r.wake()

    try #require(r.otherReads > 0)
    try #require(r.count == 0)
    #expect(r.pendingReads() == ["PR_7": .confirm])
  }

  /// Once the lookup no longer fails, the next poll reads the read that the failed lookup put back.
  @Test func theNextPollReadsARequestThatAFailedLookUpTook() throws {
    let other = Wait(
      id: "w9", kind: .merge, pr: Wait.PullRequest(repository: "acme/widgets", number: 9), created: 1, then: .notify)
    let r = try RequestedReads(waits: [other])
    r.request(["PR_7"], after: 0, trigger: .confirm)
    r.wake()
    try #require(r.count == 0)
    r.clearWaits()

    _ = r.poller.poll(all: false)

    #expect(r.count == 1)
  }

  /// `sb poll --stats` counts a requested read under the trigger it was requested with, not under `wait`.
  @Test(arguments: [ReadTrigger.event, .catchup, .confirm])
  func aRequestedReadCountsUnderItsTrigger(_ trigger: ReadTrigger) throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0, trigger: trigger)

    r.wake()

    #expect(r.usedTriggers() == [trigger.rawValue])
  }

  /// The read that a failed poll put back counts under its trigger at the next poll too.
  @Test func aReadThatAFailedPollPutBackCountsUnderItsTrigger() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0, trigger: .catchup)
    r.wake()

    _ = r.poller.poll(all: false)

    try #require(r.count == 2)
    #expect(r.usedTriggers() == ["catchup"])
    #expect(r.usage("catchup")?["requests"]?.double == Double(r.count))
  }

  /// `sb poll --all` counts a requested read as `poll`.
  @Test func sbPollAllCountsARequestedReadAsPoll() throws {
    let r = try RequestedReads()
    r.request(["PR_7"], after: 0, trigger: .event)

    _ = r.poller.poll(all: true)

    #expect(r.usedTriggers() == ["poll"])
  }

  /// A wait newer than the PR's last read counts a requested read as `wait`.
  @Test func aNewerWaitCountsARequestedReadAsWait() throws {
    let r = try RequestedReads(waits: [Wait(id: "w1", kind: .ci, headSha: "head1", created: nowMs())])
    r.request(["PR_7"], after: 0, trigger: .event)

    _ = r.poller.poll(all: false)

    #expect(r.usedTriggers() == ["wait"])
  }
}
