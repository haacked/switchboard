import Foundation
import SwitchboardCore
import Testing

extension FakeGitHub {
  func checks(_ number: Int, _ state: String) {
    change(number) { $0["commits"] = ["nodes": [["commit": ["statusCheckRollup": ["state": .string(state)]]]]] }
  }

  /// Gives the PR's last commit the PR's head as its oid, and GitHub Actions
  /// suites with `statuses`. Call it after `checks`, which replaces the commit.
  func actions(_ number: Int, _ statuses: [String]) {
    change(number) { pr in
      var commit = pr["commits"]?["nodes"]?.array?.first?["commit"]?.object ?? [:]
      commit["oid"] = pr["headRefOid"] ?? ""
      commit["checkSuites"] = [
        "pageInfo": ["hasNextPage": false], "nodes": .array(statuses.map { ["status": .string($0)] }),
      ]
      pr["commits"] = ["nodes": [["commit": .object(commit)]]]
    }
  }

  /// Adds a review of `commit` to the PR's last reviews, and to its verdicts
  /// when `verdict`.
  func review(
    _ number: Int, by login: String, _ state: String, at time: String, bot: Bool = false, verdict: Bool = false,
    on commit: String = "abc"
  ) {
    let node: JSON = [
      "author": ["login": .string(login), "__typename": bot ? "Bot" : "User"], "state": .string(state),
      "submittedAt": .string(time), "commit": ["oid": .string(commit)],
    ]
    change(number) { pr in
      for key in verdict ? ["reviews", "latestOpinionatedReviews"] : ["reviews"] {
        pr[key] = ["nodes": .array((pr[key]?["nodes"]?.array ?? []) + [node])]
      }
    }
  }

  /// The id of Trunk's first status comment on the PR.
  func trunkComment(_ number: Int) throws -> String {
    let nodes = pr(number)["firstComments"]?["nodes"]?.array ?? []
    return try #require(nodes.first { $0["author"]?["login"]?.string == "trunk-io" }?["id"]?.string)
  }
}

/// A GitHub timestamp `seconds` from now.
func stamp(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds)) }

/// Waits for the session's turn that a resolved wait's message started, and
/// checks that the wait is gone.
func resumed(_ sbd: Instance, _ s: SessionSummary, with message: String) throws {
  try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: Switchboard: \(message)" }
  #expect(try sbd.get(s.id).waits.isEmpty)
}

/// Polls resolve waits on the PR kinds, and merge triggers fire, through
/// `sb poll` against the fake GitHub.
@Suite(.blocking(timeLimit: .seconds(120))) struct PollerWaitTests {
  static let charts = "PostHog/charts"
  static let branch = "haacked/cdp-dlq-runbook-lookup-step"
  static let posthog = "PostHog/posthog"
  /// The branch of PostHog/posthog#122953, which has Trunk's status comment.
  static let posthogBranch = "haacked/cdp-dlq-breaker-counts-lookups"

  /// A session on the branch of PostHog/charts#18303, whose PR the poller has read.
  func chartsSession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: PollerWaitTests.charts, branch: PollerWaitTests.branch)
    try sbd.poll()
    return s
  }

  @Test func aCIWaitResumesTheSessionOnceTheChecksPass() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.checks(18303, "PENDING")
    try sbd.sb("wait", s.id, "--kind", "ci", "--note", "then merge")
    let open = try sbd.poll()
    #expect(open["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)
    github.checks(18303, "SUCCESS")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "CI on the session's PR: the checks passed. Your note: then merge.")
  }

  @Test func aCIWaitThatNotifiesMovesToNeedsYouWhenTheChecksFail() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.checks(18303, "PENDING")
    try sbd.sb("wait", s.id, "--kind", "ci", "--then", "notify")
    github.checks(18303, "FAILURE")
    try sbd.poll()
    try sbd.poll()
    let after = try sbd.get(s.id)
    #expect(after.state == .needsYou)
    #expect(after.reason == "CI on the session's PR: the checks failed")
    #expect(after.waits.isEmpty)
  }

  @Test func aWaitIgnoresTheStateThePollerReadBeforeItWasSet() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    // The poller read SUCCESS before the wait. The next poll reads the PR again
    // because the wait is newer than the last read, so a push that started new
    // checks keeps the wait open.
    github.checks(18303, "PENDING")
    try sbd.sb("wait", s.id, "--kind", "ci")
    try sbd.poll()
    #expect(try sbd.get(s.id).waits.count == 1)
    #expect(github.requests.filter { $0.kind == "status" }.count == 2)
  }

  @Test func aCIWaitNeedsTwoReadsOfTheSameHeadCommit() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "ci")
    // The first read shows SUCCESS for the old head, as GitHub can just after a push.
    #expect(try sbd.poll()["resolved"]?.int == 0)
    github.change(18303) { $0["headRefOid"] = "pushed-commit" }
    github.checks(18303, "PENDING")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    github.checks(18303, "FAILURE")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "CI on the session's PR: the checks failed.")
  }

  /// A session whose `ci` wait recorded the PR's head commit, whose checks
  /// read SUCCESS.
  func headWait(_ sbd: Instance, _ github: FakeGitHub) throws -> SessionSummary {
    let s = try chartsSession(sbd)
    let head = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(18303) { $0["headRefOid"] = .string(head) }
    try sbd.sb("wait", s.id, "--kind", "ci")
    #expect(try sbd.get(s.id).waits.first?.head == head)
    return s
  }

  @Test func aCIWaitSetOnTheHeadCommitResolvesOnOneReadOnceItsActionsRunsComplete() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try headWait(sbd, github)
    github.actions(18303, ["COMPLETED", "COMPLETED"])
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "CI on the session's PR: the checks passed.")
  }

  /// An external status that reports before CI queues shows SUCCESS for the
  /// head commit before it has any Actions suite. `ActionsReadTests` covers
  /// the other reads that can't show a finished run.
  @Test func aCIWaitOnTheHeadCommitNeedsTwoReadsBeforeItsActionsRunStarts() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try headWait(sbd, github)
    github.actions(18303, [])
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    // The second poll's two agreeing reads settle the wait without a second Actions read.
    #expect(github.requests.filter { $0.kind == "actions" }.count == 1)
  }

  @Test func aCIWaitOnTheHeadCommitNeedsTwoReadsWhileItsActionsRunIsRunning() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try headWait(sbd, github)
    github.actions(18303, ["COMPLETED", "IN_PROGRESS"])
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
  }

  @Test func aCIWaitOnTheHeadCommitNeedsTwoReadsWhenTheActionsReadFails() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try headWait(sbd, github)
    github.actions(18303, ["COMPLETED"])
    github.fail(18303, in: .actions)
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
  }

  @Test func aCIWaitKeepsTwoReadsWhenTheHeadCommitDiffers() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.change(18303) { $0["headRefOid"] = "pushed-commit" }
    github.actions(18303, ["COMPLETED"])
    try sbd.sb("wait", s.id, "--kind", "ci")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    #expect(!github.requests.contains { $0.kind == "actions" })
  }

  @Test func aWaitStaysOpenWhenTheReadAfterItFails() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "merge")
    github.change(18303) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
    }
    github.fail(18303)
    try sbd.poll()
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func aWaitIgnoresAnEarlierPROfAReusedBranch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "posthog/groups-list-two-phase-dedup")
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "merge")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func aDoneSessionIsNotResumedByAResolution() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "merge")
    try sbd.sb("done", s.id)
    github.change(18303) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
    }
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func aReviewWaitNeedsANewReviewByTheReviewer() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.review(18303, by: "alex", "APPROVED", at: "2020-01-01T00:00:00Z")
    try sbd.sb("wait", s.id, "--kind", "review", "--who", "alex")
    try sbd.poll()
    github.review(18303, by: "sam", "APPROVED", at: stamp(60))
    try sbd.poll()
    #expect(try sbd.get(s.id).waits.count == 1)
    github.review(18303, by: "alex", "CHANGES_REQUESTED", at: stamp(60))
    try sbd.poll()
    try resumed(sbd, s, with: "a review from alex on the session's PR: alex requested changes.")
  }

  @Test func aBotReviewWaitResolvesOnAReviewFromAnApp() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "bot-review")
    github.review(18303, by: "alex", "COMMENTED", at: stamp(60))
    try sbd.poll()
    #expect(try sbd.get(s.id).waits.count == 1)
    github.review(18303, by: "greptile-apps", "COMMENTED", at: stamp(60), bot: true)
    try sbd.poll()
    try resumed(sbd, s, with: "a bot review on the session's PR: greptile-apps reviewed.")
  }

  @Test func anApprovalWaitResolvesOnceTheApproverApproves() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    try sbd.sb("wait", s.id, "--kind", "approval", "--who", "alex")
    try sbd.poll()
    #expect(try sbd.get(s.id).waits.count == 1)
    github.review(122953, by: "alex", "APPROVED", at: stamp(60), verdict: true)
    try sbd.poll()
    try resumed(sbd, s, with: "approval from alex on the session's PR: alex approved.")
  }

  @Test func aMergeWaitResolvesWhenThePRMerges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "merge")
    try sbd.poll()
    #expect(try sbd.get(s.id).waits.count == 1)
    github.change(18303) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
    }
    try sbd.poll()
    try resumed(sbd, s, with: "the session's PR to merge: it merged.")
  }

  @Test func aWaitOnAnotherPRInTheSessionsRepoPollsThatPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "#122179")
    let result = try sbd.poll()
    #expect(result["resolved"]?.int == 1)
    try resumed(sbd, s, with: "#122179 to merge: it merged.")
  }

  @Test func aWaitOnAPRInAnotherRepoWorksFromASessionWithoutAPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("wait", s.id, "--kind", "ci", "--target", "https://github.com/PostHog/charts/pull/18303")
    try sbd.poll()
    try sbd.poll()
    try resumed(sbd, s, with: "CI on PostHog/charts#18303: the checks passed.")
    #expect(github.requests.contains { $0.kind == "lookup" && $0.ids == ["PostHog/charts#18303"] })
  }

  @Test func aWaitOnAPRThatCantBeFoundStaysOpen() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "PostHog/charts#9")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func aQueueWaitResumesTheSessionWhenTrunkRemovesThePR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    let comment = try github.trunkComment(122953)
    try sbd.poll()
    github.edit(comment: comment, body: "Testing in the queue", at: stamp(-3600))
    try sbd.sb("wait", s.id, "--kind", "queue", "--note", "then deploy")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)
    github.edit(comment: comment, body: "Removed from the merge queue", at: stamp(3600))
    try sbd.advanceClock(30_000)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(
      sbd, s, with: "the merge queue for the session's PR: Trunk removed it from the queue. Your note: then deploy.")
  }

  @Test func aQueueWaitIgnoresARemovalFromBeforeItWasSet() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    let comment = try github.trunkComment(122953)
    github.edit(comment: comment, body: "Removed from the merge queue", at: stamp(-3600))
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "queue")
    try sbd.advanceClock(30_000)
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).pr?.queue == .removed)
    #expect(try sbd.get(s.id).waits.count == 1)
    github.edit(comment: comment, body: "Testing in the queue", at: stamp(60))
    try sbd.advanceClock(30_000)
    #expect(try sbd.poll()["resolved"]?.int == 0)
    github.edit(comment: comment, body: "Removed from the merge queue", at: stamp(3600))
    try sbd.advanceClock(30_000)
    #expect(try sbd.poll()["resolved"]?.int == 1)
  }

  @Test func aQueueWaitResumesTheSessionWhenThePRMerges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "queue")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
    }
    try sbd.advanceClock(30_000)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "the merge queue for the session's PR: it merged.")
  }

  @Test func aMergeTriggerFiresWhenThePollSeesThePRMerge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let open = try add(
      sbd, ["prompt": "Clean up.", "repository": "PostHog/posthog", "after": "PostHog/posthog#122953"])
    let merged = try add(
      sbd, ["prompt": "Retarget.", "repository": "PostHog/posthog", "after": "PostHog/posthog#122179"])
    try sbd.poll()
    #expect(try sbd.get(open.id).state == .notStarted)
    #expect(try sbd.get(merged.id).reason == "ready to start: PostHog/posthog#122179 merged")
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll()
    #expect(try sbd.get(open.id).reason == "ready to start: PostHog/posthog#122953 merged")
    #expect(try sbd.events(open.id).filter { $0.kind == "followup-ready" }.count == 1)
  }
}
