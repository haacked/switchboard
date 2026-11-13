import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A private sbd whose poller asks `github`, with the stub gh. Polls run
  /// only when a test asks, unless `pollSeconds` starts the poller's timer.
  /// These tests need no fast process checks, so sbd ticks once a second
  /// instead of running ps five times a second. `extra` adds other config keys.
  static func withGitHub(
    _ github: FakeGitHub, pollSeconds: Double = 0, config extra: [String: JSON] = [:]
  ) throws -> Instance {
    let config: [String: JSON] = [
      "github": [
        "gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url),
        "pollSeconds": .number(pollSeconds),
      ],
      "tickSeconds": 1,
    ]
    return try Instance(config: config.merging(extra) { $1 })
  }

  /// The sessions' Claude config folder, which sbd inherits.
  var claudeConfig: String { inheritedAccount! }

  @discardableResult
  func poll(all: Bool = false) throws -> JSON {
    try client.call("poll", ["all": .bool(all)])
  }

  /// A git repo on `branch` whose origin is the GitHub repo `repo`, and a
  /// session in it that has answered its first prompt. A `folder` lets two
  /// sessions work in the same GitHub repo. A session with a `parent` takes
  /// the parent's group, and it is not placed by hand.
  func session(in repo: String, branch: String, folder: String? = nil, parent: String? = nil, name: String? = nil)
    throws
    -> SessionSummary
  {
    let path = "\(home.path)/\(folder ?? repo.replacingOccurrences(of: "/", with: "-"))"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try git(path, "init", "-q", "-b", "main")
    try git(
      path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty",
      "-m", "first")
    try git(path, "remote", "add", "origin", "https://github.com/\(repo).git")
    try git(path, "checkout", "-q", "-b", branch)
    var args: [String: JSON] = ["path": .string(path), "prompt": "hello"]
    if let parent { args["parent"] = .string(parent) }
    if let name { args["name"] = .string(name) }
    let s = try client.call("new", args, as: SessionSummary.self)
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
  /// one at `transcript(s)`. The poller looks in the cwd's folder first.
  /// It would otherwise read the stub's copy.
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

  /// A session in a PostHog/posthog checkout on a branch without a PR, whose
  /// transcript links haacked/review-code#189, a repo that no remote names.
  /// The poll links #189.
  func sessionWithAForeignPRLink() throws -> SessionSummary {
    let s = try session(in: "PostHog/posthog", branch: "haacked/no-pr-yet")
    try link(s, "haacked/review-code", 189)
    try poll()
    guard try get(s.id).pr?.number == 189 else { throw TestError(description: "the poll did not link #189") }
    return s
  }

  /// Ends the session's conversation with `/clear`. The new conversation's
  /// transcript links no PR.
  func clear(_ s: SessionSummary) throws {
    let next = UUID().uuidString.lowercased()
    try sb("send", s.id, "clear \(next)")
    try waitFor(s.id, "the new conversation") { $0.claudeSessionId == next }
  }
}

extension FakeGitHub {
  /// Every lookup key that the poller asked for.
  var lookedUp: [String] { requests.filter { $0.kind == "lookup" }.flatMap(\.ids) }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct GitHubTests {
  @Test func findsASessionsPRByItsBranch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    let result = try sbd.poll()
    #expect(result["lookups"]?.int == 1)
    #expect(result["polled"]?.int == 1)
    #expect(result["points"]?.int == 4)
    let after = try sbd.get(s.id)
    #expect(after.pr?.number == 18303)
    #expect(after.pr?.status == .approved)
    #expect(after.state == .readyToMerge)
    #expect(after.reason == "#18303 is ready to merge, approved by stamphog")
    #expect(github.requests.map(\.kind) == ["lookup", "status", "codeowners", "mergeDetails"])
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
    #expect(try reason { $0["mergeable"] = "CONFLICTING" } == "merge main in; #18303 conflicts with main")
    // A pr event carries the comments only when they changed.
    #expect(try sbd.events(s.id).last { $0.kind == "pr" }?.data["comments"] == nil)
    // GitHub answers UNKNOWN while it computes mergeability again, as after
    // the base moved. A push changes the head commit, which can fix the conflict.
    #expect(try reason { $0["mergeable"] = "UNKNOWN" } == "merge main in; #18303 conflicts with main")
    #expect(
      try reason { $0["headRefOid"] = "pushed" }
        == "GitHub is still checking whether #18303 can merge; #18303 approved")
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
    #expect(requested.state == .readyForReview)
    #expect(
      requested.reason
        == "#18303 chore(cdp): document lookup records in the dead-letter runbook; review required; review requested from copilot-pull-request-reviewer, checks success"
    )
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

    #expect(try state { $0["reviewRequests"] = ["nodes": [copilot]] }.state == .readyForReview)
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

  @Test func showsTheBranchThatTheFolderHasCheckedOut() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.poll()
    #expect(try sbd.get(s.id).branch == "haacked/cdp-dlq-breaker-counts-lookups")
    #expect(try sbd.count("branch", of: s.id) == 0)
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/mcp-experiment-condition-ids")
    try sbd.poll()
    #expect(try sbd.get(s.id).branch == "haacked/mcp-experiment-condition-ids")
    #expect(try sbd.get(s.id).pr?.number == 122896)
    #expect(try sbd.sb("get", s.id).contains("branch:  haacked/mcp-experiment-condition-ids"))
    #expect(try sbd.client.sessions().first { $0.id == s.id }?.branch == "haacked/mcp-experiment-condition-ids")
    // A detached HEAD keeps the last branch. A poll that finds no change records nothing.
    try sbd.git(s.cwd, "checkout", "-q", "--detach")
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).branch == "haacked/mcp-experiment-condition-ids")
    #expect(try sbd.count("branch", of: s.id) == 1)
    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try sbd.get(s.id).branch == "haacked/mcp-experiment-condition-ids")
  }

  @Test func showsTheCheckedOutBranchOfAFolderWithoutAGitHubRemote() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let s = try sbd.new(prompt: "hello")
    try Repos.create(s.cwd)
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/local-only")
    try sbd.poll()
    #expect(try sbd.get(s.id).branch == "haacked/local-only")
  }

  @Test func showsTheStartingBranchAfterACheckoutBackToIt() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122953)
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/mcp-experiment-condition-ids")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122896)
    try sbd.git(s.cwd, "checkout", "-q", "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122953)
    #expect(try sbd.get(s.id).branch == "haacked/cdp-dlq-breaker-counts-lookups")
    #expect(try sbd.count("branch", of: s.id) == 2)
  }

  @Test func aResolvedTodoRecordsTheBranchOfItsPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/mcp-experiment-condition-ids")
    try sbd.poll()
    let todo = try sbd.addTodo(s.id, "check the flag")
    try sbd.resolveTodo(s.id, todo.id)
    let row = try #require(try sbd.resolvedTodos().first)
    #expect(row["branch"]?.string == "haacked/mcp-experiment-condition-ids")
    #expect(row["pr"]?.int == 122896)
  }

  @Test func keepsTheLastBranchOfAFolderThatIsGone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/mcp-experiment-condition-ids")
    try sbd.poll()
    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).branch == "haacked/mcp-experiment-condition-ids")
    #expect(try sbd.count("branch", of: s.id) == 1)
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

  /// The PR's head is the upstream name that the local branch's `merge`
  /// config gives, which the reflog doesn't name.
  @Test func dropsTheLinkedPROfAnEarlierBranchWithAnotherUpstreamName() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "local-name")
    try sbd.git(s.cwd, "config", "branch.local-name.remote", "origin")
    try sbd.git(s.cwd, "config", "branch.local-name.merge", "refs/heads/haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.link(s, "PostHog/posthog", 122953)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122953)
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/no-pr-yet")
    try sbd.poll()
    #expect(try sbd.get(s.id).pr == nil)
  }

  /// A session can open its PR from another worktree of its own repo. The
  /// main checkout's reflog names the PR's head. The session's worktree never
  /// had it checked out, so the PR stays the session's. Its merge moves the
  /// session to Done.
  @Test func keepsALinkedPRWhoseHeadAnotherWorktreeOfTheRepoHad() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let repo = try sbd.makeRepo("posthog", origin: "https://github.com/PostHog/posthog.git")
    try sbd.git(repo, "checkout", "-q", "-b", "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.git(repo, "checkout", "-q", "main")
    let tree = try sbd.addWorktree(repo, "haacked/no-pr-yet")
    let started = try sbd.client.call("new", ["path": .string(tree), "prompt": "hello"], as: SessionSummary.self)
    let s = try sbd.waitFor(started.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.link(s, "PostHog/posthog", 122953)
    try sbd.poll()
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122953)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).state == .done)
    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 122953)
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
    #expect(github.requests.map(\.kind) == ["lookup", "status", "codeowners"])
    #expect(github.requests.first?.ids == ["haacked/review-code#189"])

    let file = try #require(FileHandle(forWritingAtPath: sbd.transcript(s)))
    try file.seekToEnd()
    try file.write(
      contentsOf: Data((#"{"type":"pr-link","prNumber":18303,"prRepository":"PostHog/charts"}"# + "\n").utf8))
    try file.close()
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  @Test func prThatWaitsOnReviewPollsUntilItIsApproved() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    // #122953's checks passed and its review decision is REVIEW_REQUIRED.
    github.change(122953) { $0["mergeable"] = "MERGEABLE" }
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    let id = try #require(github.pr(122953)["id"]?.string)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.status == .reviewRequired)

    github.change(122953) { $0["reviewDecision"] = "APPROVED" }
    let waiting = github.requests.count
    try sbd.poll()
    #expect(github.readStatus(of: id, since: waiting))
    #expect(try sbd.get(s.id).pr?.status == .approved)

    let approved = github.requests.count
    try sbd.poll()
    #expect(!github.readStatus(of: id, since: approved))
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
    #expect(try sbd.get(s.id).reason == "#18303 is ready to merge, approved by stamphog")
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

  /// The conversation that `/clear` starts writes its transcript in the old
  /// one's folder, which the cwd doesn't name.
  @Test func findsThePRLinkOfTheConversationThatClearStarts() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.sessionWithAPRLink()
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 189)
    let next = UUID().uuidString.lowercased()
    try sbd.sb("send", s.id, "clear \(next)")
    let cleared = try sbd.waitFor(s.id, "the new conversation") { $0.claudeSessionId == next }
    // The stub writes the new transcript after sbd switches the session id.
    try sbd.waitFor("the stub's transcript of the new conversation") {
      Transcript.find(next, account: sbd.claudeConfig, cwd: s.cwd) != nil
    }
    try sbd.link(cleared, "PostHog/charts", 18303)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 18303)
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
    #expect(
      github.requests.map(\.authorization) == [
        "bearer token-1", "bearer token-2", "bearer token-2", "bearer token-2", "bearer token-2",
      ])
    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  /// A session can open its PR from another repo's checkout, so its own
  /// folder's branch has no PR. The linked PR's merge moves it to Done.
  @Test func aMergedPRLinkedFromAnotherReposCheckoutMovesTheSessionToDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.sessionWithAForeignPRLink()
    #expect(github.lookedUp.contains("PostHog/posthog:haacked/no-pr-yet"))
    #expect(try sbd.get(s.id).state != .done)

    github.change(189) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    let done = try sbd.get(s.id)
    #expect(done.state == .done)
    #expect(done.reason == "#189 merged; archive the worktree")
    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state == .done)
  }

  @Test(arguments: [false, true])
  func keepsALinkedPRWhileHEADIsDetached(restart: Bool) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.sessionWithAForeignPRLink()
    if restart { sbd.stopSbd() }
    try sbd.git(s.cwd, "checkout", "-q", "--detach")
    if restart { try sbd.startSbd() }

    try sbd.poll()

    #expect(try sbd.get(s.id).pr?.number == 189)
  }

  @Test func keepsTheRecordedPRWhenTheFolderIsGoneAcrossARestart() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.sessionWithAForeignPRLink()
    // The new conversation links no PR, so only the recorded PR is left.
    try sbd.clear(s)
    sbd.stopSbd()
    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.startSbd()

    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).pr?.number == 189)
  }

  @Test func keepsALinkedPRWhenTheFolderIsGoneWhileSbdRuns() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.sessionWithAForeignPRLink()

    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).pr?.number == 189)
  }

  /// A fork's PR is in its upstream repo, which `branchKey` asks for the
  /// branch's PR. The branch's PR has another head owner, so only the link
  /// finds it.
  @Test(arguments: ["upstream", "base"])
  func keepsALinkedPRFromTheUpstreamRemote(_ remote: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "haacked/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.git(s.cwd, "remote", "add", remote, "https://github.com/PostHog/charts.git")
    if remote != "upstream" { try sbd.git(s.cwd, "config", "remote.\(remote).gh-resolved", "base") }
    try sbd.link(s, "PostHog/charts", 18303)

    try sbd.poll()

    #expect(try sbd.get(s.id).pr?.number == 18303)
    #expect(github.lookedUp.contains("PostHog/charts#18303"))
    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr?.number == 18303)
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
    #expect(after.reason == "#18303 is ready to merge, approved by stamphog")
    #expect(github.requests.count == count)
  }

  // MARK: The session's PR on another branch

  /// PostHog/charts#18303, whose head is `charts18303`.
  static let charts18303 = "haacked/cdp-dlq-runbook-lookup-step"
  static let charts18303Id = "PR_kwDOJsIKrs8AAAABKhgNxg"

  /// A session on #18303's branch whose transcript links #18303, after a
  /// poll that found it. The folder then switches to `-v2`, and a poll hides
  /// the PR.
  func sessionThatLeftItsPR(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: "PostHog/charts", branch: Self.charts18303)
    try sbd.link(s, "PostHog/charts", 18303)
    try sbd.poll()
    guard try sbd.get(s.id).pr?.number == 18303 else { throw TestError(description: "the poll did not find #18303") }
    try sbd.git(s.cwd, "checkout", "-q", "-b", "\(Self.charts18303)-v2")
    try sbd.poll()
    return s
  }

  /// Makes a commit on `-v2` and makes it #18303's head, as a push would.
  func pushFromV2(_ github: FakeGitHub, _ s: SessionSummary) throws {
    let sha = try Repos.commit(s.cwd, "work on v2")
    github.change(18303) { $0["headRefOid"] = .string(sha) }
  }

  @Test func keepsAnEarlierPRWhoseHeadThisFolderMade() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sessionThatLeftItsPR(sbd)
    #expect(try sbd.get(s.id).pr == nil)

    try pushFromV2(github, s)
    try sbd.poll(all: true)

    let after = try sbd.get(s.id)
    #expect(after.pr?.number == 18303)
    #expect(after.branch == "\(Self.charts18303)-v2")
  }

  @Test func keepsAnEarlierPRWhoseHeadThisFolderMadeAcrossARestart() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sessionThatLeftItsPR(sbd)
    try pushFromV2(github, s)
    try sbd.poll(all: true)

    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).pr?.number == 18303)
  }

  /// The folder made the PR's head on the PR's branch, then `checkout -b`
  /// started `-v2` there. The folder made no commit after the switch.
  @Test func hidesAnEarlierPRWhoseHeadIsTheSwitchCommit() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: Self.charts18303)
    let tip = try Repos.commit(s.cwd, "work on the PR's branch")
    github.change(18303) { $0["headRefOid"] = .string(tip) }
    try sbd.link(s, "PostHog/charts", 18303)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 18303)

    try sbd.git(s.cwd, "checkout", "-q", "-b", "\(Self.charts18303)-v2")
    try sbd.poll()

    #expect(try sbd.get(s.id).pr == nil)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr == nil)
  }

  @Test func aMergedEarlierPRThatThisFolderMadeMovesTheSessionToDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sessionThatLeftItsPR(sbd)
    try pushFromV2(github, s)
    try sbd.poll(all: true)

    github.change(18303) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).state == .done)
  }

  /// A hidden PR stays in the poller's reads, so it polls at the idle rate
  /// like any other PR and not on every poll.
  @Test func pollsAHiddenPRAtTheIdleRate() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sessionThatLeftItsPR(sbd)
    #expect(try sbd.get(s.id).pr == nil)
    try sbd.advanceClock(300_000)
    let mark = github.requests.count

    try sbd.poll()
    try sbd.poll()

    let reads = github.requests.dropFirst(mark).filter { $0.kind == "status" && $0.ids.contains(Self.charts18303Id) }
    #expect(reads.count == 1)
  }

  @Test func dropsAMergedEarlierPRThatThisFolderDidNotMake() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.link(s, "PostHog/posthog", 122953)
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.number == 122953)
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/no-pr-yet")
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).pr == nil)

    let sha = try Repos.commit(s.cwd, "work on no-pr-yet")
    github.change(122953) { $0["headRefOid"] = .string(sha) }
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).pr == nil)
  }

  /// The plan's example, end to end: the folder on `-v2` made #18303's head,
  /// and its reply offers to delete `-v2` while no summary exists.
  @Test func anOfferToDeleteTheBranchNamesItAndThePRsBranch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github, config: ["triage": ["perHour": 0]])
    // A draft PR gives no PR rule, so the reply decides the session's item.
    github.change(18303) { $0["isDraft"] = true }
    let s = try sessionThatLeftItsPR(sbd)
    try pushFromV2(github, s)
    try sbd.poll(all: true)
    let reply = try String(contentsOfFile: offerDeleteBranchReply, encoding: .utf8)
      .replacingOccurrences(of: "haacked/round-trip-drop-old-bounds-v2", with: "\(Self.charts18303)-v2")
      .replacingOccurrences(of: "haacked/round-trip-drop-old-bounds", with: Self.charts18303)
    try reply.write(toFile: "\(sbd.home.path)/offer-delete-branch.md", atomically: true, encoding: .utf8)

    try sbd.sb("send", s.id, "reply offer-delete-branch")

    let after = try sbd.waitFor(s.id, "the offer") { $0.lastReply?.contains("Do you want me to delete it?") == true }
    let item = try #require(after.triage)
    #expect(item.title == "Delete the branch \(Self.charts18303)-v2?")
    #expect(item.options.map(\.label) == ["Yes", "No"])
    #expect(after.pr?.number == 18303)
    #expect(after.pr?.head == Self.charts18303)
    #expect(item.callouts.contains { $0.title == "#18303 uses \(Self.charts18303)" })
  }
}
