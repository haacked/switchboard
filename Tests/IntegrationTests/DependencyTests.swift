import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// Like `session(in:branch:)`, with the git repo in `folder`, so that two
  /// sessions can work in the same GitHub repo.
  func session(in repo: String, branch: String, folder: String) throws -> SessionSummary {
    let path = "\(home.path)/\(folder)"
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

  /// The first poll reads the session's PR and learns its body refs. The
  /// second poll reads the PRs that those refs name.
  func pollTwice() throws {
    try poll()
    try poll(all: true)
  }

  /// The session's edges as `sb get --json` shows them.
  func edges(_ id: String) throws -> [Dependency]? {
    try JSONCoding.decode(SessionSummary.self, from: try sb("get", "--json", id)).dependencies
  }

  /// The text of each message that sbd itself sent to the session.
  func messagesFromSbd(_ id: String) throws -> [String] {
    try events(id).filter { $0.kind == "sent" && $0.data["by"]?.string == "sbd" }.compactMap { $0.data["text"]?.string }
  }
}

private let posthog = "PostHog/posthog"
/// #122953's head branch.
private let baseBranch = "haacked/cdp-dlq-breaker-counts-lookups"
/// #122896's head branch.
private let dependentBranch = "haacked/mcp-experiment-condition-ids"
/// The deployment-status-posthog comment on #122179, which shows it deployed to dev, prod-us, and prod-eu.
private let deployComment = "IC_kwDODg-Tdc8AAAABfAhApw"
private let readTheReply = "read its last reply and decide what's next"

/// Makes #122896's base #122953's head branch, as a stacked PR's base is.
/// The base ref names no merged PR, so the retarget rule does not fire.
private func stack(_ github: FakeGitHub, on base: String = baseBranch) {
  github.change(122896) {
    $0["baseRefName"] = .string(base)
    $0["baseRef"] = ["associatedPullRequests": ["nodes": []]]
  }
}

private func body(_ github: FakeGitHub, _ text: String) {
  github.change(122896) { $0["body"] = .string(text) }
}

@Suite(.timeLimit(.minutes(2))) struct DependencyTests {
  @Test func bodyEdgesShowInGetAndLs() throws {
    let github = try FakeGitHub()
    body(github, "Moves the flags.\r\n\r\nDepends on #122953\r\nDepends on PostHog/charts#18303\r\n")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    #expect(try sbd.edges(s.id) == nil)
    let activity = try sbd.get(s.id).lastActivity

    try sbd.pollTwice()

    let expected = [
      Dependency(via: .body, repo: posthog, number: 122953, state: .open),
      Dependency(via: .body, repo: "PostHog/charts", number: 18303, state: .open),
    ]
    #expect(try sbd.edges(s.id) == expected)
    let listed = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
    #expect(listed.first { $0.id == s.id }?.dependencies == expected)
    let text = try sbd.sb("get", s.id)
    #expect(text.contains("  depends: #122953 open\n"))
    #expect(text.contains("  depends: PostHog/charts#18303 open\n"))
    #expect(try sbd.events(s.id).contains { $0.kind == "dependencies" })
    #expect(try sbd.get(s.id).lastActivity == activity)
  }

  @Test func bodyEdgeHoldsTheSessionInWaiting() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    let after = try sbd.get(s.id)
    #expect(after.state == .waiting)
    #expect(after.reason == "waits on #122953")
    #expect(try sbd.triage().isEmpty)
  }

  @Test func bodyEdgeInAnotherRepoNamesItsRepo() throws {
    let github = try FakeGitHub()
    body(github, "- Depends on https://github.com/PostHog/charts/pull/18303")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.get(s.id).reason == "waits on PostHog/charts#18303")
  }

  @Test func unreadEdgePrintsUnknown() throws {
    let github = try FakeGitHub()
    // The fake has no PR #1, so the poller never reads the edge's state.
    body(github, "Depends on #1")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == [Dependency(via: .body, repo: posthog, number: 1, state: nil)])
    #expect(try sbd.sb("get", s.id).contains("  depends: #1 unknown\n"))
    #expect(try sbd.get(s.id).reason == "waits on #1")
  }

  @Test func repeatedRefsCollapseToOneEdge() throws {
    let github = try FakeGitHub()
    body(
      github,
      "Depends on #122953\nDepends on PostHog/posthog#122953 and https://github.com/PostHog/posthog/pull/122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == [Dependency(via: .body, repo: posthog, number: 122953, state: .open)])
  }

  @Test func bodyLinesThatOnlyMentionAPRGiveNoEdge() throws {
    let github = try FakeGitHub()
    body(github, "Follows #122953.\nSee PostHog/charts#18303 for the runbook.\nThis depends on #122179.")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == nil)
    #expect(try sbd.get(s.id).reason == readTheReply)
  }

  @Test func stackEdgeLinksTwoSessions() throws {
    let github = try FakeGitHub()
    stack(github)
    let sbd = try Instance.withGitHub(github)
    let base = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")

    try sbd.pollTwice()

    #expect(
      try sbd.edges(top.id) == [
        Dependency(via: .stack, repo: posthog, number: 122953, base: baseBranch, state: .open, session: base.id)
      ])
    #expect(try sbd.edges(base.id) == nil)
    #expect(try sbd.get(top.id).state == .waiting)
    #expect(try sbd.get(top.id).reason == "waits on #122953")
    #expect(try sbd.sb("get", top.id).contains("  depends: #122953 open (session \(base.id))\n"))
  }

  @Test(arguments: [
    "release/2026-11",
    // #122953 heads this branch, but no session works on #122953.
    baseBranch,
  ])
  func baseThatNoOtherSessionsPRHeadsGivesNoEdge(_ base: String) throws {
    let github = try FakeGitHub()
    stack(github, on: base)
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == nil)
    #expect(try sbd.get(s.id).reason == readTheReply)
  }

  @Test func bodyRefToTheStackBaseMergesIntoTheStackEdge() throws {
    let github = try FakeGitHub()
    stack(github)
    body(github, "Depends on #122953 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let base = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")

    try sbd.pollTwice()

    #expect(
      try sbd.edges(top.id) == [
        Dependency(
          via: .stack, repo: posthog, number: 122953, base: baseBranch, deploy: true, state: .open, session: base.id)
      ])
  }

  @Test func mergedStackBaseResumesTheSession() throws {
    let github = try FakeGitHub()
    stack(github)
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")
    try sbd.pollTwice()
    #expect(try sbd.messagesFromSbd(top.id).isEmpty)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(top.id).isEmpty }
    #expect(try sbd.messagesFromSbd(top.id) == ["Switchboard: #122953 merged; retarget and rebase #122896."])
  }

  /// GitHub retargets a stacked PR when its base merges and the base branch
  /// is deleted. A poll can read the retarget before it reads the merge.
  @Test func retargetReadBeforeTheBaseMergeStillResumesTheSession() throws {
    let github = try FakeGitHub()
    stack(github)
    // A settled base polls only at the idle interval. The dependent PR's
    // UNKNOWN mergeability keeps it due at every poll.
    github.change(122953) { $0["mergeable"] = "MERGEABLE" }
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")
    try sbd.pollTwice()
    #expect(try sbd.edges(top.id)?.map(\.via) == [.stack])

    github.change(122953) { $0["state"] = "MERGED" }
    github.change(122896) { $0["baseRefName"] = "master" }
    try sbd.poll()
    #expect(github.requests.last { $0.kind == "status" }?.ids == [github.pr(122896)["id"]!.string!])
    #expect(try sbd.edges(top.id)?.map(\.state) == [.open])
    #expect(try sbd.messagesFromSbd(top.id).isEmpty)

    try sbd.poll()
    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(top.id).isEmpty }
    #expect(try sbd.messagesFromSbd(top.id) == ["Switchboard: #122953 merged; retarget and rebase #122896."])
    #expect(try sbd.edges(top.id) == nil)
  }

  @Test func dependenciesThatMergeInOnePollSendOneMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953 and PostHog/charts#18303")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()

    github.change(122953) { $0["state"] = "MERGED" }
    github.change(18303) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == [
        "Switchboard: #122953 merged, so #122896 no longer waits on it.\nPostHog/charts#18303 merged, so #122896 no longer waits on it."
      ])
  }

  @Test func mergedBodyDependencyResumesTheSessionOnce() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id) == ["Switchboard: #122953 merged, so #122896 no longer waits on it."])
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    #expect(try sbd.messagesFromSbd(s.id).count == 1)
  }

  @Test func dependencyAlreadyMergedAtFirstSightSendsNoMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122179")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.edges(s.id) == [Dependency(via: .body, repo: posthog, number: 122179, state: .merged)])
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
    #expect(try sbd.get(s.id).reason == readTheReply)
  }

  @Test func sessionMarkedDoneGetsNoMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    try sbd.sb("done", s.id)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  @Test func sessionWhoseOwnPRClosedGetsNoMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()

    github.change(122896) { $0["state"] = "CLOSED" }
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  @Test func deployEdgeResolvesFromTheDeployComment() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122179 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(
      try sbd.edges(s.id) == [
        Dependency(via: .body, repo: posthog, number: 122179, deploy: true, state: .merged, deployed: true)
      ])
    #expect(try sbd.get(s.id).reason == readTheReply)
    #expect(try sbd.sb("get", s.id).contains("  depends: #122179 merged, deploy"))
  }

  @Test func deployToBothProdRegionsResumesTheSession() throws {
    let github = try FakeGitHub()
    let deployed = try #require(
      FakeGitHub.recorded("github-bodies.json").first { $0["id"]?.string == deployComment }?["body"]?.string)
    let euPending = deployed.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.contains("**prod-eu**") ? "| **prod-eu** | :hourglass_flowing_sand: Pending |  |  |" : String($0)
    }.joined(separator: "\n")
    github.edit(comment: deployComment, body: euPending, at: "2026-10-23T22:30:00Z")
    body(github, "Depends on #122179 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    #expect(
      try sbd.edges(s.id) == [
        Dependency(via: .body, repo: posthog, number: 122179, deploy: true, state: .merged, deployed: false)
      ])
    #expect(try sbd.get(s.id).state == .waiting)
    #expect(try sbd.get(s.id).reason == "waits on the deploy of #122179")
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)

    github.edit(comment: deployComment, body: deployed, at: "2026-10-23T22:34:45Z")
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == ["Switchboard: #122179 deployed to prod, so #122896 no longer waits on it."])
  }

  @Test func closedDependencyNeedsYou() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()

    github.change(122953) { $0["state"] = "CLOSED" }
    try sbd.poll(all: true)

    let after = try sbd.get(s.id)
    #expect(after.state == .needsYou)
    #expect(after.reason == "decide what replaces #122953, which closed unmerged")
    #expect(try sbd.sb("get", s.id).contains("  depends: #122953 closed\n"))
    sleep(1)
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }
}
