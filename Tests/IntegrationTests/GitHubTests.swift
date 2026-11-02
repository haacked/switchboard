import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A private sbd whose poller asks `github`, with the stub gh. Polls run
  /// only when a test asks, unless `pollSeconds` starts the poller's timer.
  /// These tests need no fast process checks, so sbd ticks once a second
  /// instead of running ps five times a second.
  static func withGitHub(_ github: FakeGitHub, pollSeconds: Double = 0) throws -> Instance {
    try Instance(config: [
      "github": [
        "gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url),
        "pollSeconds": .number(pollSeconds),
      ],
      "tickSeconds": 1,
    ])
  }

  /// The sessions' Claude config folder, which sbd inherits.
  var claudeConfig: String { inheritedAccount! }

  @discardableResult
  func poll(all: Bool = false) throws -> JSON {
    try client.call("poll", ["all": .bool(all)])
  }

  /// A git repo on `branch` whose origin is the GitHub repo `repo`, and a
  /// session in it that has answered its first prompt.
  func session(in repo: String, branch: String) throws -> SessionSummary {
    let path = "\(home.path)/\(repo.replacingOccurrences(of: "/", with: "-"))"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try git(path, "init", "-q", "-b", "main")
    try git(
      path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty",
      "-m", "first")
    try git(path, "remote", "add", "origin", "https://github.com/\(repo).git")
    try git(path, "checkout", "-q", "-b", branch)
    let s = try client.call("new", ["path": .string(path), "prompt": "hello"], as: SessionSummary.self)
    return try waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
  }

  /// A session in a plain folder, whose transcript links haacked/review-code
  /// #189. The transcript's folder differs from Claude Code's name for the
  /// cwd, so the poller has to search the project folders.
  func sessionWithAPRLink() throws -> SessionSummary {
    let s = try new(prompt: "hello")
    try waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try writeTranscript(
      s,
      [
        #"{"type":"user","message":{"content":"héllo ✓"}}"#,
        #"{"type":"pr-link","sessionId":"x","prNumber":189,"prUrl":"https://github.com/haacked/review-code/pull/189","prRepository":"haacked/review-code","timestamp":"2026-10-25T20:00:00Z"}"#,
      ])
    return s
  }

  /// Writes a transcript for `s` whose one line links `repo`#`number`.
  func link(_ s: SessionSummary, _ repo: String, _ number: Int) throws {
    try writeTranscript(s, [#"{"type":"pr-link","prNumber":\#(number),"prRepository":"\#(repo)"}"#])
  }

  /// Replaces the transcript that the stub wrote in the cwd's folder with
  /// one at `transcript(s)`. The poller would find the stub's copy instead
  /// when its folder lists first.
  func writeTranscript(_ s: SessionSummary, _ lines: [String]) throws {
    if let stub = Transcript.find(s.claudeSessionId, account: claudeConfig, cwd: s.cwd) {
      try FileManager.default.removeItem(atPath: stub)
    }
    try FileManager.default.createDirectory(
      atPath: (transcript(s) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(toFile: transcript(s), atomically: true, encoding: .utf8)
  }

  func transcript(_ s: SessionSummary) -> String {
    "\(claudeConfig)/projects/-somewhere-else/\(s.claudeSessionId).jsonl"
  }
}

@Suite(.timeLimit(.minutes(2))) struct GitHubTests {
  @Test func findsASessionsPRByItsBranch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    let result = try sbd.poll()
    #expect(result["lookups"]?.int == 1)
    #expect(result["polled"]?.int == 1)
    #expect(result["points"]?.int == 2)
    let after = try sbd.get(s.id)
    #expect(after.pr?.number == 18303)
    #expect(after.pr?.status == .approved)
    #expect(after.state == .needsYou)
    #expect(after.reason == "merge #18303, approved by stamphog")
    #expect(github.requests.map(\.kind) == ["lookup", "status"])
    #expect(github.requests.first?.ids == ["PostHog/charts:haacked/cdp-dlq-runbook-lookup-step"])
    #expect(github.requests.allSatisfy { $0.authorization == "bearer token-1" })
    #expect(
      try sbd.sb("get", s.id).contains(
        "pr:      #18303 Approved, checks success  https://github.com/PostHog/charts/pull/18303"))
    try sbd.poll(all: true)
    #expect(try sbd.events(s.id).filter { $0.kind == "pr" }.count == 1)
  }

  @Test func showsEachPRRuleAsThePRChanges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    let head = github.pr(18303)["headRefOid"]!
    func reason(after edit: (inout [String: JSON]) -> Void) throws -> String {
      github.change(18303, edit)
      try sbd.poll(all: true)
      return try sbd.get(s.id).reason
    }
    #expect(try reason { $0["mergeable"] = "CONFLICTING" } == "rebase; #18303 conflicts with its base")
    // A pr event carries the comments only when they changed.
    #expect(try sbd.events(s.id).last { $0.kind == "pr" }?.data["comments"] == nil)
    // GitHub answers UNKNOWN while it computes mergeability again, as after
    // the base moved. A push changes the head commit, which can fix the conflict.
    #expect(try reason { $0["mergeable"] = "UNKNOWN" } == "rebase; #18303 conflicts with its base")
    #expect(try reason { $0["headRefOid"] = "pushed" } == "merge #18303, approved by stamphog")
    #expect(
      try reason {
        $0["headRefOid"] = head
        $0["mergeable"] = "MERGEABLE"
        $0["reviewDecision"] = "CHANGES_REQUESTED"
        $0["latestOpinionatedReviews"] = [
          "nodes": [["author": ["login": "alice"], "state": "CHANGES_REQUESTED", "commit": ["oid": head]]]
        ]
      } == "address the changes that alice requested on #18303")
    #expect(
      try reason {
        $0["baseRefName"] = "haacked/base"
        $0["baseRef"] = [
          "target": ["oid": "b1"], "associatedPullRequests": ["nodes": [["number": 18000, "headRefOid": "b1"]]],
        ]
      } == "retarget #18303; its base #18000 merged")
    github.fail(18303, in: .base)
    #expect(try reason { _ in } == "retarget #18303; its base #18000 merged")
    #expect(try reason { $0["baseRefName"] = "main" } == "address the changes that alice requested on #18303")
    let merged = try reason { $0["state"] = "MERGED" }
    #expect(merged == "#18303 merged; archive the worktree")
    #expect(try sbd.get(s.id).state == .done)
    #expect(try sbd.get(s.id).markedDone == false)
    // The count comes first, so the merged PR is never judged by an older count.
    let poller = try sbd.events(s.id).filter { $0.kind == "pr" || $0.kind == "worktree" }
    #expect(poller.suffix(2).map(\.kind) == ["worktree", "pr"])
    let file = "\(s.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).reason == "#18303 merged; commit or discard the uncommitted changes")
    #expect(try sbd.get(s.id).state == .needsYou)
    try FileManager.default.removeItem(atPath: file)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state == .done)
    // A clean folder is counted again after the session's next activity, not
    // at every poll.
    try "y".write(toFile: file, atomically: true, encoding: .utf8)
    try sbd.poll()
    #expect(try sbd.get(s.id).state == .done)
    try sbd.sb("send", s.id, "after the merge")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: after the merge" }
    try sbd.poll()
    #expect(try sbd.get(s.id).reason == "#18303 merged; commit or discard the uncommitted changes")
    // A commit from the user's own shell fires no hook, so a dirty folder is
    // counted again once per idle interval.
    try FileManager.default.removeItem(atPath: file)
    try sbd.poll()
    #expect(try sbd.get(s.id).state == .needsYou)
    try sbd.advanceClock(300_000)
    try sbd.poll()
    #expect(try sbd.get(s.id).state == .done)
    try sbd.sb("done", s.id)
    #expect(try sbd.get(s.id).markedDone == true)
    try sbd.sb("undone", s.id)
    #expect(try sbd.get(s.id).markedDone == false)
  }

  @Test func mergedPRWhoseFolderWasRemovedIsDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    github.change(18303) { $0["state"] = "MERGED" }
    let file = "\(s.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state == .needsYou)
    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.sb("send", s.id, "after the merge")
    try sbd.poll()
    try sbd.poll(all: true)
    let done = try sbd.get(s.id)
    #expect(done.state == .done)
    #expect(done.reason == "#18303 merged; its folder is gone")
  }

  @Test func waitsForAReviewerUntilTheReviewArrives() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    func state(after edit: (inout [String: JSON]) -> Void) throws -> SessionSummary {
      github.change(18303, edit)
      try sbd.poll(all: true)
      return try sbd.get(s.id)
    }
    let copilot: JSON = ["requestedReviewer": ["__typename": "Bot", "login": "copilot-pull-request-reviewer"]]
    let draft = try state {
      $0["isDraft"] = true
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
      $0["reviewRequests"] = ["nodes": [copilot]]
    }
    #expect(draft.state == .needsYou)

    let requested = try state { $0["isDraft"] = false }
    #expect(requested.state == .waiting)
    #expect(requested.reason == "review of #18303 by copilot-pull-request-reviewer")
    #expect(try sbd.triage().isEmpty)

    // GitHub clears the request when the reviewer submits.
    let reviewed = try state {
      $0["reviewRequests"] = ["nodes": []]
      $0["reviews"] = [
        "nodes": [["author": ["__typename": "Bot", "login": "copilot-pull-request-reviewer"], "state": "COMMENTED"]]
      ]
    }
    #expect(reviewed.state == .needsYou)
    #expect(reviewed.reason == "read its last reply and decide what's next")
    #expect(try sbd.triage().map(\.id) == [s.id])

    #expect(try state { $0["reviewRequests"] = ["nodes": [copilot]] }.state == .waiting)
    let failing = try state { $0["commits"] = ["nodes": [["commit": ["statusCheckRollup": ["state": "FAILURE"]]]]] }
    #expect(failing.state == .needsYou)
  }

  @Test func findsTheBranchsNewPRAfterItsPRCloses() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.poll()
    github.change(122953) { $0["state"] = "CLOSED" }
    github.change(122896) { $0["headRefName"] = "haacked/cdp-dlq-breaker-counts-lookups" }
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).reason == "#122953 closed; archive the worktree")
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 122896)
  }

  @Test func findsTheBranchsNewPRAfterItsPRMerges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.poll()
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).reason.hasPrefix("#122953 merged"))
    github.change(122896) { $0["headRefName"] = "haacked/cdp-dlq-breaker-counts-lookups" }
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 122896)
  }

  @Test func looksUpAMergedBranchAgainOnlyAtTheIdleInterval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.poll()
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    github.change(122896) { $0["headRefName"] = "haacked/cdp-dlq-breaker-counts-lookups" }
    let count = github.requests.count
    try sbd.poll()
    #expect(!github.requests.dropFirst(count).contains { $0.kind == "lookup" })
    try sbd.advanceClock(300_000)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122896)
  }

  @Test func followsTheSessionToAnotherBranch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.poll()
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/mcp-experiment-condition-ids")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122896)
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/no-pr-yet")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr == nil)
  }

  @Test func dropsTheLinkedPROfAnEarlierBranch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.link(s, "PostHog/posthog", 122953)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122953)
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/no-pr-yet")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr == nil)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr == nil)
  }

  @Test func prefersTheBranchsPRToTheLinkedPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.link(s, "haacked/review-code", 189)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  @Test func pollsOnItsTimer() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github, pollSeconds: 1)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.waitFor(s.id, "the timer's poll") { $0.pr?.number == 18303 }
  }

  @Test func findsThePRFromThePRLinkInTheTranscript() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.sessionWithAPRLink()
    try sbd.poll()
    let after = try sbd.get(s.id)
    #expect(after.pr?.number == 189)
    #expect(after.pr?.status == .draft)
    #expect(after.reason == "read its last reply and decide what's next")
    #expect(github.requests.map(\.kind) == ["lookup", "status"])
    #expect(github.requests.first?.ids == ["haacked/review-code#189"])

    let file = try #require(FileHandle(forWritingAtPath: sbd.transcript(s)))
    try file.seekToEnd()
    try file.write(
      contentsOf: Data((#"{"type":"pr-link","prNumber":18303,"prRepository":"PostHog/charts"}"# + "\n").utf8))
    try file.close()
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  @Test func readsPendingPRsAndChangedCommentsAgain() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    // #122953's recorded mergeability is UNKNOWN, so it is pending.
    let pending = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    _ = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    let pendingId = github.pr(122953)["id"]!.string!
    try sbd.poll()
    #expect(github.requests.filter { $0.kind == "status" }.map { $0.ids.count } == [2])
    let trunk = (github.pr(122953)["firstComments"]?["nodes"]?.array ?? []).filter {
      $0["author"]?["login"]?.string == "trunk-io"
    }.compactMap { $0["id"]?.string }
    #expect(Set(github.requests.filter { $0.kind == "bodies" }.flatMap(\.ids)) == Set(trunk))
    // Its trunk-io comments are Trunk's control comment and its test analytics.
    #expect(try sbd.get(pending.id).pr?.queue == nil)

    let before = github.requests.count
    try sbd.poll()
    #expect(github.requests.dropFirst(before).map(\.kind) == ["status"])
    #expect(github.requests.last?.ids == [pendingId])

    github.edit(comment: trunk[0], body: "Testing in the queue", at: "2026-10-26T00:00:00Z")
    let edited = github.requests.count
    try sbd.poll()
    let requests = github.requests.dropFirst(edited)
    #expect(requests.map(\.kind) == ["status", "bodies"])
    #expect(requests.last?.ids == [trunk[0]])
    let event = try sbd.events(pending.id).last { $0.kind == "pr" }
    let comments = event?.data["comments"]?.array ?? []
    #expect(comments.contains { $0["body"]?.string == "Testing in the queue" })
    #expect(try sbd.get(pending.id).pr?.queue == .queued)

    try sbd.advanceClock(300_000)
    let idle = github.requests.count
    try sbd.poll()
    #expect(github.requests.dropFirst(idle).filter { $0.kind == "status" }.flatMap(\.ids).count == 2)
  }

  @Test func readsACommentBodyThatFailedToLoadAgain() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    let control = try #require(github.pr(122953)["firstComments"]?["nodes"]?.array?.first?["id"]?.string)
    github.fail(comment: control)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.queue == .unknown)
    github.recover(comment: control)
    let before = github.requests.count
    try sbd.poll()
    #expect(github.requests.dropFirst(before).filter { $0.kind == "bodies" }.flatMap(\.ids) == [control])
    #expect(try sbd.get(s.id).pr?.queue == nil)
  }

  @Test func dropsAPRThatGitHubNoLongerReturns() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    github.remove(18303)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr == nil)
    let count = github.requests.count
    try sbd.poll()
    #expect(github.requests.count == count)
    try sbd.advanceClock(300_000)
    try sbd.poll()
    #expect(github.requests.dropFirst(count).map(\.kind) == ["lookup"])
  }

  @Test func keepsAPRThatGitHubFailedToReturn() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    github.fail(18303)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 18303)
    #expect(try sbd.get(s.id).reason == "merge #18303, approved by stamphog")
  }

  /// The session keeps its PR through a rebase, and through a restart of
  /// sbd during the rebase.
  @Test func keepsThePRWhileHEADIsDetached() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    try sbd.git(s.cwd, "checkout", "-q", "--detach")
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 18303)
    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  /// `/clear` starts a conversation whose transcript links no PR, and the
  /// session keeps the old one's PR, also after a restart of sbd.
  @Test func keepsTheTranscriptsPRAfterClear() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.sessionWithAPRLink()
    try sbd.poll()
    let next = UUID().uuidString.lowercased()
    try sbd.sb("send", s.id, "clear \(next)")
    try sbd.waitFor(s.id, "the new conversation") { $0.claudeSessionId == next }
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 189)
    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 189)
  }

  @Test(arguments: [
    (200, "API rate limit exceeded", #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#),
    (403, "secondary rate limit", #"{"message":"You have exceeded a secondary rate limit."}"#),
  ])
  func pausesAfterARateLimit(_ status: Int, _ error: String, _ body: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    let reset = Int(Date().timeIntervalSince1970) + 600
    github.reply(status, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"], body)
    let first = try sbd.poll()
    #expect(first["error"]?.string?.contains(error) == true)
    #expect((first["pausedUntil"]?.int ?? 0) > Int(nowMs()) + 500_000)
    #expect(try sbd.poll()["requests"]?.int == 0)
    #expect(github.requests.count == 1)
    #expect(try sbd.get(s.id).pr == nil)
    try sbd.advanceClock(601_000)
    #expect((try sbd.poll()["requests"]?.int ?? 0) > 0)
    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  @Test func getsANewTokenAfterA401() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    github.reply(401, #"{"message":"Bad credentials"}"#)
    try sbd.poll()
    #expect(github.requests.map(\.authorization) == ["bearer token-1", "bearer token-2", "bearer token-2"])
    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  /// A session on a branch without a PR keeps the PR that its conversation
  /// linked in another repo, also after `/clear` and a restart of sbd.
  @Test func keepsALinkedPRFromAnotherRepoAfterClearAndARestart() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/no-pr-yet")
    try sbd.link(s, "haacked/review-code", 189)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 189)
    let next = UUID().uuidString.lowercased()
    try sbd.sb("send", s.id, "clear \(next)")
    try sbd.waitFor(s.id, "the new conversation") { $0.claudeSessionId == next }
    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 189)
  }

  /// A restart doesn't keep the PR of a branch that the session left while
  /// sbd was stopped.
  @Test func dropsTheRecordedPROfAnEarlierBranchAfterARestart() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/mcp-experiment-condition-ids")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122896)
    sbd.stopSbd()
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/no-pr-yet")
    try sbd.startSbd()
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr == nil)
  }

  @Test func keepsThePRAcrossARestartOfSbd() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    let count = github.requests.count
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.pr?.number == 18303)
    #expect(after.reason == "merge #18303, approved by stamphog")
    #expect(github.requests.count == count)
  }
}
