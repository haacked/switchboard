import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct GitHubBranchKey {
  static let origin = ["remote.origin.url": "git@github.com:PostHog/posthog.git"]

  static func key(_ config: [String: String], branch: String = "haacked/x", heads: [String: String] = [:]) -> PRKey? {
    GitHub.branchKey(branch: branch, config: config) { heads[$0] }
  }

  @Test func branchWithoutConfigUsesOrigin() {
    #expect(Self.key(Self.origin) == .branch(repo: "PostHog/posthog", branch: "haacked/x", owner: "PostHog"))
  }

  @Test(arguments: [
    (
      ["branch.haacked/x.pushremote": "mine", "remote.pushdefault": "other", "branch.haacked/x.remote": "other"], "mine"
    ),
    (["remote.pushdefault": "mine", "branch.haacked/x.remote": "other"], "mine"),
    (["branch.haacked/x.remote": "mine"], "mine"),
  ])
  func pushRemoteFollowsGitsOrder(_ config: [String: String], _ remote: String) {
    let all = config.merging([
      "remote.mine.url": "https://github.com/me/posthog.git",
      "remote.other.url": "https://github.com/other/posthog.git",
    ]) { $1 }
    #expect(Self.key(all) == .branch(repo: "me/posthog", branch: "haacked/x", owner: "me"))
  }

  @Test func mergeRefNamesTheBranchOnTheRemote() {
    let config = Self.origin.merging(["branch.haacked/x.merge": "refs/heads/haacked/y"]) { $1 }
    #expect(Self.key(config) == .branch(repo: "PostHog/posthog", branch: "haacked/y", owner: "PostHog"))
  }

  @Test func branchThatTracksALocalBranchUsesOriginAndItsOwnName() {
    let config = Self.origin.merging(["branch.haacked/x.remote": ".", "branch.haacked/x.merge": "refs/heads/main"]) {
      $1
    }
    #expect(Self.key(config) == .branch(repo: "PostHog/posthog", branch: "haacked/x", owner: "PostHog"))
  }

  @Test func forkBranchIsLookedUpInTheUpstreamRepoByTheForksOwner() {
    let config = [
      "remote.origin.url": "git@github.com:haacked/posthog.git",
      "remote.upstream.url": "git@github.com:PostHog/posthog.git",
    ]
    #expect(Self.key(config) == .branch(repo: "PostHog/posthog", branch: "haacked/x", owner: "haacked"))
  }

  @Test func ghDefaultRepoWinsOverUpstream() {
    let config = [
      "remote.origin.url": "git@github.com:haacked/posthog.git",
      "remote.upstream.url": "git@github.com:other/posthog.git",
      "remote.main.url": "git@github.com:PostHog/posthog.git", "remote.main.gh-resolved": "base",
    ]
    #expect(Self.key(config) == .branch(repo: "PostHog/posthog", branch: "haacked/x", owner: "haacked"))
  }

  @Test func theRemotesDefaultBranchHasNoPR() {
    #expect(Self.key(Self.origin, branch: "main", heads: ["origin": "main"]) == nil)
    #expect(Self.key(Self.origin, heads: ["origin": "main"]) != nil)
  }

  @Test(arguments: [
    [:], ["remote.origin.url": "https://gitlab.com/a/b.git"], ["branch.haacked/x.remote": "gone"] as [String: String],
  ])
  func pushRemoteOffGitHubHasNoPR(_ config: [String: String]) {
    #expect(Self.key(config) == nil)
  }

  @Test(
    arguments: [
      ("ref: refs/heads/haacked/x\n", "haacked/x"),
      ("ref: refs/heads/main", "main"),
      ("89918967ababc0def2d9c2d50d3a5069ea799dc0\n", nil),
      ("", nil),
    ] as [(String, String?)])
  func headFileNamesTheBranch(_ head: String, _ branch: String?) {
    #expect(GitHub.branch(head: head) == branch)
  }

  @Test func remoteHeadFileNamesTheRemotesDefaultBranch() {
    #expect(GitHub.branch(head: "ref: refs/remotes/origin/master\n", under: "refs/remotes/origin/") == "master")
  }

  @Test func gitConfigOutputGivesValuesByKey() {
    let text =
      "remote.origin.url git@github.com:PostHog/posthog.git\nbranch.haacked/X.remote origin\nremote.empty.url\n"
    #expect(
      GitHub.gitConfig(text) == [
        "remote.origin.url": "git@github.com:PostHog/posthog.git", "branch.haacked/X.remote": "origin",
        "remote.empty.url": "",
      ])
  }
}

@Suite struct GitHubHelpers {
  static func comment(_ author: String, edited: Bool = true, _ body: String?) -> PRComment {
    PRComment(id: "IC_\(body ?? "none")", author: author, createdAt: "2026-10-25T00:00:00Z", edited: edited, body: body)
  }

  static let control = comment(
    "trunk-io[bot]", edited: false, "<!-- Trunk Merge -->\nMerging to `master` in this repository is managed by Trunk.")
  static let testing = comment("trunk-io[bot]", "⏳ Running tests in the merge queue")
  static let deploy = comment("deployment-status-posthog[bot]", "Running tests")

  @Test(
    arguments: [
      ([deploy, control, testing], .testing),
      ([control, comment("trunk-io[bot]", "Removed from the merge queue")], .removed),
      ([deploy, control], nil),
      ([deploy, comment("trunk-io", "⏳ Running tests in the merge queue")], nil),
      ([control, comment("trunk-io[bot]", nil)], .unknown),
    ] as [([PRComment], TrunkQueueState?)])
  func openPRTakesTheQueueStateOfItsTrunkComments(_ comments: [PRComment], _ queue: TrunkQueueState?) {
    let open = PullRequest(id: "a", number: 1, url: "", repo: "a/b")

    #expect(GitHub.queueStatus(of: open, comments) == queue)
  }

  @Test(arguments: [PRState.merged, .closed])
  func finishedPRHasNoQueueState(_ state: PRState) {
    let pr = PullRequest(id: "a", number: 1, url: "", repo: "a/b", state: state)

    #expect(GitHub.queueStatus(of: pr, [Self.control, Self.testing]) == nil)
  }

  @Test func elapsedCountsFromTheLastTime() {
    #expect(GitHub.elapsed(since: nil, 1000, now: 0))
    #expect(!GitHub.elapsed(since: 1000, 1000, now: 1999))
    #expect(GitHub.elapsed(since: 1000, 1000, now: 2000))
  }

  @Test func summaryLineNamesTheStatusAndChecks() {
    let pr = PullRequest(
      id: "PR_1", number: 18303, url: "https://github.com/PostHog/charts/pull/18303", repo: "PostHog/charts",
      reviewDecision: .approved, checks: "SUCCESS")
    #expect(PRSummary(pr).line == "#18303 Approved, checks success")
    var none = pr
    none.checks = nil
    #expect(PRSummary(none).line == "#18303 Approved")
    #expect(PRSummary(pr).status == "Approved")
  }

  @Test(arguments: [
    (PullRequest(id: "a", number: 1, url: "", repo: "a/b", reviewDecision: .approved), true),
    (PullRequest(id: "a", number: 1, url: "", repo: "a/b", draft: true, reviewDecision: .approved), false),
    (PullRequest(id: "a", number: 1, url: "", repo: "a/b", state: .merged, reviewDecision: .approved), false),
    (PullRequest(id: "a", number: 1, url: "", repo: "a/b", reviewDecision: .reviewRequired), false),
  ])
  func isApprovedOnlyForAnOpenApprovedPR(_ pr: PullRequest, _ approved: Bool) {
    #expect(pr.isApproved == approved)
  }

  @Test func pollerEventsDontCountAsActivity() throws {
    var f = facts([event("UserPromptSubmit", 1000, ["prompt": "go"]), event("Stop", 2000)])
    let pr = PullRequest(id: "a", number: 1, url: "", repo: "a/b")
    f.apply(event("pr", 9000, ["pr": try JSON(encoding: pr), "comments": []]))
    f.apply(event("worktree", 9500, ["dirty": 0]))
    #expect(f.lastActivity == 2000)
    #expect(f.pr == pr)
  }
}

@Suite struct GitHubErrors {
  @Test func errorTypesAreKeyedByAliasOrNode() {
    let response: JSON = [
      "errors": [
        ["type": "NOT_FOUND", "path": ["nodes", 1], "message": "Could not resolve"],
        ["type": "INTERNAL", "path": ["q3", "pullRequests"], "message": "Something went wrong"],
        ["message": "no path"],
      ]
    ]
    #expect(GitHub.errorTypes(response) == ["nodes.1": "NOT_FOUND", "q3": "INTERNAL"])
    #expect(GitHub.errorTypes(["data": [:]]).isEmpty)
  }

  @Test func statusGivesThePRsAndTheIdsThatAreNotFound() throws {
    let response: JSON = [
      "data": ["nodes": [try #require(GitHubFixtures.statusNode(18303)), .null, .null]],
      "errors": [["type": "NOT_FOUND", "path": ["nodes", 1]], ["type": "INTERNAL", "path": ["nodes", 2]]],
    ]

    let (prs, gone) = GitHub.parseStatus(response, ["PR_kwDOJsIKrs8AAAABKhgNxg", "PR_gone", "PR_failed"])

    #expect(prs.map(\.pr.number) == [18303])
    #expect(gone == ["PR_gone"])
  }

  @Test func bodiesGiveTheCommentsAndTheIdsThatAreNotFound() throws {
    let node = try #require(GitHubFixtures.bodyNodes.first)
    let id = try #require(node["id"]?.string)
    let response: JSON = [
      "data": ["nodes": [node, .null, .null]],
      "errors": [["type": "NOT_FOUND", "path": ["nodes", 1]], ["type": "INTERNAL", "path": ["nodes", 2]]],
    ]

    let (comments, gone) = GitHub.parseBodies(response, [id, "IC_deleted", "IC_failed"])

    #expect(comments.map(\.id) == [id])
    #expect(gone == ["IC_deleted"])
  }

  static let now = 1_800_000_000.0

  @Test(
    arguments: [
      // A 200 that spent the last point succeeds, and the next request waits for the reset.
      (200, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000600"], #"{"data":{}}"#, false, 600),
      (
        200, ["x-ratelimit-remaining": "0"],
        #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#, true, 60
      ),
      (403, ["retry-after": "120"], #"{"message":"You have exceeded a secondary rate limit."}"#, true, 120),
      (403, [:], #"{"message":"You have exceeded a secondary rate limit."}"#, true, 60),
      (429, ["retry-after": "30", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000300"], "{}", true, 300),
      (403, [:], #"{"message":"Resource protected by organization SAML enforcement."}"#, false, nil),
      (200, ["x-ratelimit-remaining": "4000"], #"{"data":{}}"#, false, nil),
      (502, [:], "<html>", false, nil),
    ] as [(Int, [String: String], String, Bool, Double?)])
  func rateLimitSaysWhetherAndHowLongToWait(
    _ status: Int, _ headers: [String: String], _ body: String, _ limited: Bool, _ pause: Double?
  ) {
    let limit = GitHub.rateLimit(status: status, headers: headers, response: JSON.parse(body), now: Self.now)
    #expect(limit.limited == limited)
    #expect(limit.pause == pause)
  }
}
