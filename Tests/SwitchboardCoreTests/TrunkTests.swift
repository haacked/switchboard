import Foundation
import Testing

@testable import SwitchboardCore

/// Output that `trunk merge status <N>` printed, recorded with the time it ran.
/// Some recordings had the colors stripped. The rest keep trunk's colors and
/// its CRLF line ends.
func trunkFixture(_ name: String) throws -> String {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/trunk")
  return try String(contentsOf: dir.appendingPathComponent("\(name).txt"), encoding: .utf8)
}

func ms(_ iso: String) -> Int64 {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return Int64((f.date(from: iso)!.timeIntervalSince1970 * 1000).rounded())
}

func found(_ output: String, now: String) throws -> TrunkTimeline {
  let result = TrunkTimeline.parse(output, now: ms(now))
  guard case .found(let t) = result else {
    Issue.record("parsed as \(result)")
    throw CancellationError()
  }
  return t
}

func timeline(_ name: String, now: String) throws -> TrunkTimeline { try found(trunkFixture(name), now: now) }

@Suite struct TrunkTimelineTests {
  @Test func queuedPRUnderTestInABatch() throws {
    let t = try timeline("testing-in-batch", now: "2026-09-09T23:33:24.916Z")
    #expect(t.entries.map(\.label) == ["Not Ready", "Pending", "Testing"])
    #expect(t.entries.map(\.state) == [.submitted, .pending, .testing])
    #expect(
      t.entries.map(\.time) == [
        ms("2026-09-09T22:04:52.434Z"), ms("2026-09-09T23:30:15.165Z"), ms("2026-09-09T23:30:24.522Z"),
      ])
    #expect(t.entries.last?.state == .testing)
    #expect(t.entries.last?.state.isQueued == true)
    #expect(
      t.entries[0].text
        == "Pull request has been submitted to Merge by Phil Haack. It will be added to the merge queue once all "
        + "branch protection rules pass.")
  }

  @Test func linksThatTrunkBrokeAcrossLinesJoinWithoutASpace() throws {
    let t = try timeline("testing-in-batch", now: "2026-09-09T23:33:24.916Z")
    let queue = "https://app.trunk.io/posthog-inc/merge-queue/3921a8a3-abf7-42ff-b9cf-ef4fab8f3649"
    #expect(
      t.entries[2].text
        == "This pull request is currently being tested in a batch (96996 "
        + "([gh](https://github.com/PostHog/posthog/pull/96996), [trunk](\(queue)/96996)), 97577 "
        + "([gh](https://github.com/PostHog/posthog/pull/97577), [trunk](\(queue)/97577))) on "
        + "[PR 98034](https://github.com/PostHog/posthog/pull/98034)")
  }

  @Test func aWordThatFillsTheLineJoinsWithASpace() throws {
    let t = try timeline("failed-check", now: "2026-09-29T17:32:37.693Z")
    #expect(t.entries.map(\.label) == ["Not Ready", "Pending", "Testing", "Failed"])
    #expect(t.entries.last?.state == .removed)
    #expect(t.entries.last?.state.isQueued == false)
    #expect(
      t.entries[3].text
        == "Pull request was removed from the merge queue because the following required check failed: "
        + "[`Visual regression tests pass`](https://github.com/PostHog/posthog/actions/runs/36603853950/job/"
        + "109533729965) (Failure).")
  }

  @Test func aLinkThatFillsTheLineExactlyKeepsTheSpaceAfterIt() throws {
    // The edit drops a digit from the job id and moves the link's ")" up a line. The link then ends at the line's
    // end, and "(Failure)." starts the next line.
    let output = TrunkTimeline.plainText(try trunkFixture("failed-check"))
      .replacingOccurrences(of: "job/109533729965\n", with: "job/10953372996)\n")
      .replacingOccurrences(of: ") (Failure).", with: "(Failure).")
    let t = try found(output, now: "2026-09-29T17:32:37.693Z")
    #expect(
      t.entries[3].text
        == "Pull request was removed from the merge queue because the following required check failed: "
        + "[`Visual regression tests pass`](https://github.com/PostHog/posthog/actions/runs/36603853950/job/"
        + "10953372996) (Failure).")
  }

  @Test func aLineWithMoreCodePointsThanColumnsLeavesTheWidthAlone() throws {
    let original = try trunkFixture("failed-check")
    let output = original.replacingOccurrences(of: "\u{FA}", with: "u\u{301}")
    #expect(output.unicodeScalars.count == original.unicodeScalars.count + 1)
    let t = try found(output, now: "2026-09-29T17:32:37.693Z")
    #expect(
      t.entries[3].text.contains("(https://github.com/PostHog/posthog/actions/runs/36603853950/job/109533729965)"))
  }

  @Test func stackThatFailsWhileThePRsBelowItFinishTesting() throws {
    let t = try timeline("stack-pending-failure", now: "2026-10-02T22:07:35.831Z")
    #expect(
      t.entries.map(\.label) == [
        "Not Ready", "Pending", "Testing", "Pending Failure", "Pending", "Testing", "Pending", "Testing",
        "Tests Passed",
        "Pending", "Testing", "Pending Failure",
      ])
    #expect(t.entries.last?.state == .failing)
    #expect(t.entries.last?.state.isQueued == true)
    #expect(
      t.entries[8].text
        == "Stack passed testing during a batch bisection (tested using "
        + "[PR 111131](https://github.com/PostHog/posthog/pull/111131)).")
  }

  @Test func mergedStackWithoutBlankLines() throws {
    let t = try timeline("stack-merged", now: "2026-10-02T23:31:24.556Z")
    #expect(t.entries.map(\.state) == [.submitted, .pending, .testing, .passed, .merged])
    #expect(t.entries.last?.time == ms("2026-10-02T23:30:35.039Z"))
    #expect(t.entries.last?.state == .merged)
    #expect(t.entries.last?.state.isQueued == false)
    #expect(t.entries.last?.text == "Stack has been merged successfully.")
  }

  @Test func singlePRThroughABisectionToRemoval() throws {
    let t = try timeline("bisection-failed", now: "2026-10-14T17:23:02.532Z")
    #expect(t.entries.count == 12)
    #expect(t.entries.contains { $0.label == "Pending Failure" })
    #expect(t.entries.last?.state == .removed)
  }

  @Test func cancelledPRsAreRemoved() throws {
    let timeout = try timeline("cancelled-timeout", now: "2026-09-23T17:27:33.361Z")
    #expect(timeout.entries.map(\.label) == ["Not Ready", "Cancelled"])
    #expect(timeout.entries.last?.state == .removed)
    let byUser = try timeline("cancelled-by-user", now: "2026-10-19T23:06:47.364Z")
    #expect(byUser.entries.last?.state == .removed)
    #expect(
      byUser.entries.last?.text
        == "Pull request was removed from the merge queue because it was canceled by Phil Haack.")
  }

  @Test func trunkErrors() throws {
    #expect(TrunkTimeline.parse(try trunkFixture("not-logged-in"), now: 0) == .notLoggedIn)
    #expect(TrunkTimeline.parse(try trunkFixture("not-found"), now: 0) == .notFound)
    #expect(TrunkTimeline.parse(try trunkFixture("not-set-up"), now: 0) == .notSetUp)
    #expect(TrunkTimeline.parse("✖ Something new went wrong\n", now: 0) == .unrecognized("✖ Something new went wrong"))
    #expect(TrunkTimeline.parse("", now: 0) == .unrecognized(""))
  }

  @Test func aHeaderWithoutAPRNumberIsUnrecognized() throws {
    let output = try trunkFixture("stack-merged").replacingOccurrences(of: "#110487 ", with: "#PR ")
    guard case .unrecognized = TrunkTimeline.parse(output, now: ms("2026-10-02T23:31:24.556Z")) else {
      Issue.record("parsed a header without a PR number")
      return
    }
  }

  @Test func theYearIsTheLatestThatIsNotInTheFuture() throws {
    let output = """
      #5 fix: a thing (haacked)
       Learn more at https://app.trunk.io/gh/o/r/merge/main/5

       12-31 23:59:00.000000    Not Ready   Pull request has been submitted.
       01-01 00:01:00.000000    Pending     Pull request has been added to the merge queue.
       01-02 00:30:00.000000    Testing     Tests running.
      """
    let t = try found(output, now: "2027-01-02T00:00:00.000Z")
    // A clock that runs behind trunk's still reads the newest entry as this year.
    #expect(
      t.entries.map(\.time) == [
        ms("2026-12-31T23:59:00.000Z"), ms("2027-01-01T00:01:00.000Z"), ms("2027-01-02T00:30:00.000Z"),
      ])
  }

  @Test func aTimeJustPastNewYearOnTrunksClockIsNextYear() throws {
    let output = """
      #5 fix: a thing (haacked)
       Learn more at https://app.trunk.io/gh/o/r/merge/main/5

       01-01 00:00:05.000000    Pending     Pull request has been added to the merge queue.
      """
    let t = try found(output, now: "2026-12-31T23:59:50.000Z")
    #expect(t.entries.map(\.time) == [ms("2027-01-01T00:00:05.000Z")])
  }

  @Test func labelsTheParserDoesNotKnow() throws {
    let output = """
      #5 fix: a thing (haacked)
       Learn more at https://app.trunk.io/gh/o/r/merge/main/5

       10-01 10:00:00.000000    Paused      The queue is paused.
       10-01 11:00:00.000000  ✖ Evicted     Pull request was evicted.
       10-01 12:00:00.000000  ✔ Landed      Pull request landed.
      """
    let t = try found(output, now: "2026-10-02T00:00:00.000Z")
    #expect(t.entries.map(\.label) == ["Paused", "Evicted", "Landed"])
    #expect(t.entries.map(\.state) == [.queued, .removed, .merged])
  }

  @Test func aLearnMoreLineAfterAnEntryDoesNotJoinItsText() throws {
    let output = """
      #5 fix: a thing (haacked)

       10-01 10:00:00.000000    Pending     Pull request has been added to the merge queue.
       Learn more at https://app.trunk.io/gh/o/r/merge/main/5
       10-01 11:00:00.000000    Testing     Tests running.
      """
    let t = try found(output, now: "2026-10-02T00:00:00.000Z")
    #expect(t.entries.map(\.text) == ["Pull request has been added to the merge queue.", "Tests running."])
  }
}

let trunkControl = "<!-- Trunk Merge -->\nMerging to `master` in this repository is managed by Trunk."
let trunkAnalytics = "<!-- Trunk Test Analytics -->"
let trunkSubmitted =
  "✨ Submitted to Merge by Phil Haack (@haacked). It will be added to the merge queue once all branch protection "
  + "rules pass. See more details [here](https://app.trunk.io/x)."
let trunkStackSubmitted =
  "✨ Stack submitted to Merge by Phil Haack (@haacked). It will be added to the merge queue once all branch "
  + "protection rules pass. See more details [here](https://app.trunk.io/x)."
let trunkStackPosted = "<!-- Trunk Merge -->\n" + trunkStackSubmitted
let trunkInStack =
  "This pull request is queued for merge as part of [13](https://www.github.com/haacked/dotfiles/pull/13), which "
  + "will merge [9](https://www.github.com/haacked/dotfiles/pull/9), [13](https://www.github.com/haacked/dotfiles/pull/13)."
let trunkStackFailed =
  "Stacked PR [13](https://www.github.com/haacked/dotfiles/pull/13) failed testing in the merge queue. Please "
  + "investigate the failure and re-submit the stack."
let trunkStackCancelled =
  "Stacked PR [13](https://www.github.com/haacked/dotfiles/pull/13) was cancelled: the stack changed after it was queued."
let trunkStackReturned =
  "Stacked PR [13](https://www.github.com/haacked/dotfiles/pull/13) was returned to waiting: this pull request was "
  + "pushed to. Rebase the stack onto this pull request's new head and the stacked merge re-enters the queue on its own."
let trunkStackUnknown = "Stacked PR [13](https://www.github.com/haacked/dotfiles/pull/13) was moved to a new batch."
let trunkWaiting =
  "⏳ Stack waiting to start tests on this stack because a batch ([#106996](https://www.github.com/haacked/dotfiles/"
  + "pull/106996)) ahead of it failed tests - [details](https://app.trunk.io/x)."
let trunkTesting =
  "🧪 Running tests on this stack (testing on PR [#12](https://www.github.com/haacked/dotfiles/pull/12)) - "
  + "[details](https://app.trunk.io/x)."
let trunkPassed =
  "👍 Pull request will be merged soon because it has passed required tests (tested on PR "
  + "[#12](https://www.github.com/haacked/dotfiles/pull/12)) - [details](https://app.trunk.io/x)."
let trunkFailed =
  "❌ This pull request was removed from the merge queue because it failed tests. PR "
  + "[#12](https://github.com/haacked/dotfiles/pull/12) was used for testing. See more details [here](https://app.trunk.io/x)."
let trunkStaleTimeout =
  "🚫 This pull request was removed from the merge queue because it was waiting to become mergeable for too long "
  + "(for example: missing required approvals or checks, or a merge conflict). Submit it again once it is ready."
let trunkCheckFailing =
  "⚠️ The required check [`Visual regression tests pass`](https://github.com/haacked/dotfiles/actions/runs/1/job/2) "
  + "(Failure) has failed. Pull request failed tests and is waiting for other pull requests to finish testing. PR "
  + "[#12](https://www.github.com/haacked/dotfiles/pull/12) was used for testing. See more details [here](https://app.trunk.io/x)."
let trunkUntested =
  "❌ This pull request could not start testing because there was a merge conflict. See more details "
  + "[here](https://app.trunk.io/x).\n<!-- Start PR Submit Checkbox -->\n- [ ] <!-- End PR Submit Checkbox -->To merge "
  + "this pull request, check the box to the left or comment `/trunk merge` below."
let trunkReentering =
  "⏳ Re-entering the merge queue because it has passed tests on a bisection of its original batch - "
  + "[details](https://app.trunk.io/x)."
let trunkCancelled = "🛑 This pull request was cancelled and will not be merged."
let trunkAlreadyQueued = "This PR is already queued as a stacked merge. Cancel it first to re-submit."
let trunkError = "An error occurred while submitting your PR to the queue: `Something went wrong. Please try again`"
let trunkMerged = "😎 Merged successfully - [details](https://app.trunk.io/x)."

let trunkTime = "2026-10-25T00:00:00Z"

/// Trunk's comment that it edits in place into the queue status. `at` is the time of the last edit.
func status(_ body: String, at: String = trunkTime) -> PRComment {
  PRComment(
    id: "S_\(body.hashValue)_\(at)", author: "trunk-io[bot]", createdAt: "2026-10-24T00:00:00Z", editedAt: at,
    edited: true, body: body)
}
/// A comment that Trunk posts and never edits.
func reply(_ body: String, at: String = trunkTime) -> PRComment {
  PRComment(id: "R_\(body.hashValue)_\(at)", author: "trunk-io[bot]", createdAt: at, edited: false, body: body)
}
func queue(_ comments: [PRComment], _ state: PRState = .open) -> TrunkQueueState? {
  TrunkComments.change(of: PullRequest(id: "a", number: 1, url: "", repo: "a/b", state: state), comments)?.state
}

/// The comment cases come from git-pr's tests (`~/.dotfiles/bin/lib/test-git-pr.sh`), whose jq this parser ports.
@Suite struct TrunkCommentTests {
  @Test func commentsThatNameNoQueueState() {
    #expect(queue([]) == nil)
    #expect(queue([status(trunkControl), status(trunkAnalytics)]) == nil)
    #expect(queue([reply(trunkError)]) == nil)
    #expect(queue([reply(trunkControl)]) == nil)
    // Only a status's first line names the state.
    #expect(queue([status(trunkControl + "\n" + trunkSubmitted)]) == nil)
  }

  @Test(arguments: [
    (trunkSubmitted, TrunkQueueState.submitted),
    (trunkStackSubmitted, .submitted),
    (trunkWaiting, .pending),
    (trunkTesting, .testing),
    (trunkPassed, .passed),
    (trunkFailed, .removed),
    (trunkStaleTimeout, .removed),
    (trunkCheckFailing, .failing),
    (trunkReentering, .queued),
    (trunkUntested, .removed),
    (trunkCancelled, .removed),
    (trunkMerged, .merged),
  ])
  func eachStatusNamesAState(body: String, state: TrunkQueueState) {
    #expect(queue([status(body)]) == state)
  }

  @Test func aLaterReplyKeepsTheStatus() {
    #expect(queue([status(trunkSubmitted), reply(trunkError)]) == .submitted)
    #expect(queue([status(trunkPassed), reply(trunkAlreadyQueued)]) == .passed)
  }

  @Test func onlyTheFirstLineOfAStatusWithCRLFLineEndsNamesTheState() {
    #expect(queue([status(trunkReentering + "\r\n" + trunkFailed)]) == .queued)
  }

  @Test func theLastStatusWins() {
    #expect(
      queue([status(trunkFailed, at: "2026-10-25T01:00:00Z"), status(trunkSubmitted, at: "2026-10-25T02:00:00Z")])
        == .submitted)
    #expect(
      queue([status(trunkSubmitted, at: "2026-10-25T01:00:00Z"), status(trunkFailed, at: "2026-10-25T02:00:00Z")])
        == .removed)
  }

  @Test func stackRepliesNameAState() {
    #expect(queue([reply(trunkStackPosted)]) == .submitted)
    #expect(queue([reply(trunkInStack)]) == .queued)
    #expect(queue([reply(trunkInStack), reply(trunkStackFailed)]) == .removed)
    #expect(queue([reply(trunkInStack), reply(trunkStackCancelled)]) == .removed)
    #expect(queue([reply(trunkInStack), reply(trunkStackReturned)]) == .pending)
    #expect(queue([reply(trunkInStack), reply(trunkStackUnknown)]) == .queued)
  }

  @Test func theNewerOfTheStatusAndTheReplyWins() {
    let early = "2026-10-25T01:00:00Z"
    let late = "2026-10-25T02:00:00Z"
    #expect(queue([status(trunkTesting, at: early), reply(trunkStackFailed, at: late)]) == .removed)
    #expect(queue([status(trunkFailed, at: early), reply(trunkInStack, at: late)]) == .queued)
    #expect(queue([reply(trunkStackFailed, at: early), status(trunkTesting, at: late)]) == .testing)
    #expect(queue([reply(trunkInStack, at: early), status(trunkFailed, at: late)]) == .removed)
    #expect(
      queue([
        status(trunkFailed, at: early), reply(trunkInStack, at: late),
        reply(trunkStackCancelled, at: "2026-10-25T03:00:00Z"),
      ]) == .removed)
  }

  @Test func theEditTimeOrdersAStatusPostedBeforeTheReply() {
    let posted = status(trunkTesting, at: "2026-10-25T03:00:00Z")
    #expect(queue([posted, reply(trunkStackFailed, at: "2026-10-25T02:00:00Z")]) == .testing)
  }

  @Test func onlyTrunkSetsTheState() {
    #expect(
      queue([PRComment(id: "a", author: "someone", createdAt: trunkTime, edited: true, body: trunkSubmitted)]) == nil)
    // GraphQL gives a bot's login without the [bot] suffix that GitHub forbids in a user's login.
    #expect(
      queue([PRComment(id: "a", author: "trunk-io", createdAt: trunkTime, edited: true, body: trunkSubmitted)]) == nil)
  }

  @Test(arguments: [PRState.merged, .closed])
  func finishedPRHasNoQueueState(_ state: PRState) {
    #expect(queue([status(trunkTesting), reply(trunkInStack)], state) == nil)
    #expect(queue([PRComment(id: "a", author: "trunk-io[bot]", createdAt: trunkTime, edited: true)], state) == nil)
  }

  @Test func anUnloadedTrunkBodyMakesTheStateUnknown() {
    let unloaded = PRComment(id: "a", author: "trunk-io[bot]", createdAt: trunkTime, edited: true)
    #expect(queue([status(trunkTesting), unloaded]) == .unknown)
  }
}
