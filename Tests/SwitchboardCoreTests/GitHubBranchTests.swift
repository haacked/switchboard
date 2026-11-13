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

  static func mergeable(_ mergeable: Mergeable?, id: String = "a", head: String = "h1") -> PullRequest {
    PullRequest(id: id, number: 1, url: "", repo: "a/b", headSha: head, mergeable: mergeable)
  }

  @Test(
    arguments: [
      (mergeable(.unknown), mergeable(.conflicting), Mergeable.conflicting),
      (mergeable(.unknown), mergeable(.conflicting, head: "h0"), .unknown),
      (mergeable(.unknown), mergeable(.conflicting, id: "b"), .unknown),
      (mergeable(.unknown), mergeable(nil), .unknown),
      (mergeable(.unknown), nil, .unknown),
      (mergeable(.mergeable), mergeable(.conflicting), .mergeable),
    ] as [(PullRequest, PullRequest?, Mergeable)])
  func unknownMergeabilityKeepsTheLastAnswerForTheSameHead(_ pr: PullRequest, _ last: PullRequest?, _ shown: Mergeable)
  {
    #expect(GitHub.shown(pr, [], last: last).mergeable == shown)
  }

  @Test func shownPRTakesTheQueueStateOfItsComments() {
    #expect(GitHub.shown(Self.mergeable(.mergeable), [Self.control, Self.testing], last: nil).queue == .testing)
  }

  @Test(arguments: [
    ("https://github.com/PostHog/charts/pull/18303", true),
    ("HTTPS://github.com/PostHog/charts/pull/18303", true),
    ("http://github.com/PostHog/charts/pull/18303", false),
    ("javascript:alert(1)", false),
    ("file:///tmp/run.command", false),
    ("/tmp/run.command", false),
    ("", false),
  ])
  func linkIsOnlyAnHTTPSURL(_ url: String, _ linked: Bool) {
    let pr = PullRequest(id: "a", number: 1, url: url, repo: "a/b")
    #expect((PRSummary(pr).link != nil) == linked)
    let docket = DocketSummary(DocketSession(pullRequest: "a/b#1", url: url), DocketStatus())
    #expect((docket.link != nil) == linked)
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
    #expect(PRSummary(pr).status == .approved)
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
      (200, ["retry-after": "30"], #"{"data":{}}"#, false, nil),
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

/// `GitHub.isEarlierWork`, which `earlierStanding` checks first.
@Suite struct GitHubEarlierWork {
  static let checkedOut: Set<String> = ["haacked/x", "haacked/x-v2"]

  @Test(
    arguments: [
      ("PostHog/charts", "haacked/x", true),
      ("posthog/CHARTS", "haacked/x", true),
      ("PostHog/posthog", "haacked/x", false),
      ("PostHog/charts", "haacked/x-v2", false),
      ("PostHog/charts", "haacked/elsewhere", false),
    ] as [(String, String, Bool)])
  func earlierWorkIsAnotherCheckedOutBranchsPRInTheSameRepo(_ prRepo: String, _ head: String, _ earlier: Bool) {
    let pr = PullRequest(id: "PR_1", number: 1, url: "", repo: prRepo, head: head)

    let found = GitHub.isEarlierWork(pr, repo: "PostHog/charts", branch: "haacked/x-v2", checkedOut: Self.checkedOut)

    #expect(found == earlier)
  }
}

/// A HEAD reflog in git's format: one line per move of HEAD, with the old and
/// new commit, the committer, and a tab before the message.
enum Reflog {
  static func sha(_ prefix: String) -> String { prefix.padding(toLength: 40, withPad: "0", startingAt: 0) }

  static func line(_ old: String, _ new: String, _ message: String) -> String {
    "\(sha(old)) \(sha(new)) t <t@t> 1700000000 +0000\t\(message)"
  }

  static func text(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

  static let original = "haacked/round-trip-drop-old-bounds"
  static let v2 = "haacked/round-trip-drop-old-bounds-v2"
  static let prHead = "96c41f51ca0162153f325cda85f3f97c99e0e259"

  /// The folder of the plan's example: it switched to `-v2`, then rebased its
  /// three commits onto origin/main. The last pick made the PR's head commit.
  static let example = text(
    line("0", "1a2b3c4d", "commit (initial): first"),
    line("1a2b3c4d", "1a2b3c4d", "checkout: moving from main to \(original)"),
    line("1a2b3c4d", "6ec79c44", "commit: Add the statuspage files"),
    line("6ec79c44", "6ec79c44", "checkout: moving from \(original) to \(v2)"),
    line("6ec79c44", "53d4849c", "rebase (start): checkout origin/main"),
    line("53d4849c", "4821863b", "rebase (pick): Add the first statuspage file"),
    line("4821863b", "97331170", "rebase (pick): Add the second statuspage file"),
    line("97331170", prHead, "rebase (pick): Drop the old bounds"),
    line(prHead, prHead, "rebase (finish): returning to refs/heads/\(v2)"))

  /// A switch from `haacked/x` to `haacked/x-v2` at commit `5`, then `after`.
  static func afterSwitch(_ after: String...) -> String {
    ([
      line("0", "1", "commit (initial): first"),
      line("1", "1", "checkout: moving from main to haacked/x"),
      line("1", "5", "commit: Work on x"),
      line("5", "5", "checkout: moving from haacked/x to haacked/x-v2"),
    ] + after).joined(separator: "\n") + "\n"
  }
}

@Suite struct GitHubCommitsSinceSwitch {
  @Test func theExampleHoldsTheCommitsOfTheRebasePicksAfterTheSwitch() {
    let made = GitHub.commitsSinceSwitch(reflog: Reflog.example, to: Reflog.v2)

    #expect(made == [Reflog.sha("4821863b"), Reflog.sha("97331170"), Reflog.prHead])
  }

  @Test func theExampleLeavesOutTheSwitchCommitAndTheRebaseStart() {
    let made = GitHub.commitsSinceSwitch(reflog: Reflog.example, to: Reflog.v2) ?? []

    #expect(!made.contains(Reflog.sha("6ec79c44")))
    #expect(!made.contains(Reflog.sha("53d4849c")))
  }

  @Test(arguments: [
    "commit: Add a file", "commit (amend): Add a file", "commit (merge): Merge branch 'main'",
    "commit (initial): first", "rebase (pick): Add a file", "rebase -i (pick): Add a file",
    "rebase (squash): Add a file", "rebase -i (squash): Add a file", "rebase (fixup): Add a file",
    "rebase -i (fixup): Add a file", "rebase (reword): Add a file", "rebase -i (reword): Add a file",
    "rebase (edit): Add a file", "rebase -i (edit): Add a file", "cherry-pick: Add a file",
    "revert: Revert \"Add a file\"", "merge feature: Merge made by the 'ort' strategy.",
    "pull --rebase (pick): Add a file", "rebase (continue): Add a file",
  ])
  func aCommitCreatingEntryAfterTheSwitchCounts(_ message: String) {
    let reflog = Reflog.afterSwitch(Reflog.line("5", "abc", message))

    #expect(GitHub.commitsSinceSwitch(reflog: reflog, to: "haacked/x-v2") == [Reflog.sha("abc")])
  }

  /// These move HEAD to a commit that the folder did not make.
  @Test(arguments: [
    "reset: moving to origin/haacked/x", "reset: moving to HEAD~1", "pull: Fast-forward",
    "merge origin/haacked/x: Fast-forward", "merge haacked/x: Fast-forward", "rebase (start): checkout origin/main",
    "rebase -i (start): checkout origin/main", "rebase (finish): returning to refs/heads/haacked/x-v2",
    "rebase -i (finish): returning to refs/heads/haacked/x-v2",
  ])
  func anEntryThatMakesNoCommitDoesNotCount(_ message: String) {
    let reflog = Reflog.afterSwitch(Reflog.line("5", "abc", message))

    #expect(GitHub.commitsSinceSwitch(reflog: reflog, to: "haacked/x-v2") == [])
  }

  /// `checkout -b next` from the PR branch starts `next` at the PR's head.
  @Test func theSwitchEntrysOwnCommitDoesNotCount() {
    let made = GitHub.commitsSinceSwitch(reflog: Reflog.afterSwitch(), to: "haacked/x-v2")

    #expect(made == [])
  }

  @Test func commitsBeforeTheSwitchDoNotCount() {
    let reflog = Reflog.afterSwitch(Reflog.line("5", "abc", "commit: More work"))

    #expect(GitHub.commitsSinceSwitch(reflog: reflog, to: "haacked/x-v2")?.contains(Reflog.sha("5")) == false)
  }

  @Test func aRenameToTheBranchIsTheSwitch() {
    let reflog = Reflog.text(
      Reflog.line("0", "1", "commit (initial): first"),
      Reflog.line("1", "1", "checkout: moving from main to haacked/x"),
      Reflog.line("1", "5", "commit: Before the rename"),
      Reflog.line("5", "5", "Branch: renamed refs/heads/haacked/x to refs/heads/haacked/x-v2"),
      Reflog.line("5", "abc", "commit: After the rename"))

    #expect(GitHub.commitsSinceSwitch(reflog: reflog, to: "haacked/x-v2") == [Reflog.sha("abc")])
  }

  @Test func theLastOfTwoCheckoutsToTheBranchCounts() {
    let reflog = Reflog.afterSwitch(
      Reflog.line("5", "aaa", "commit: First visit"),
      Reflog.line("aaa", "5", "checkout: moving from haacked/x-v2 to haacked/x"),
      Reflog.line("5", "aaa", "checkout: moving from haacked/x to haacked/x-v2"),
      Reflog.line("aaa", "bbb", "commit: Second visit"))

    #expect(GitHub.commitsSinceSwitch(reflog: reflog, to: "haacked/x-v2") == [Reflog.sha("bbb")])
  }

  @Test(arguments: [
    "",
    Reflog.text(Reflog.line("0", "1", "commit (initial): first"), Reflog.line("1", "2", "commit: Work")),
    Reflog.text(
      Reflog.line("0", "1", "commit (initial): first"),
      Reflog.line("1", "1", "checkout: moving from main to haacked/x-v2-old"),
      Reflog.line("1", "2", "commit: Work on the old branch")),
    Reflog.text(
      Reflog.line("0", "1", "commit (initial): first"),
      Reflog.line("1", "1", "Branch: renamed refs/heads/main to refs/heads/haacked/x-v2-old"),
      Reflog.line("1", "2", "commit: Work on the old branch")),
    Reflog.text(
      Reflog.line("0", "1", "commit (initial): first"),
      Reflog.line("1", "1", "checkout: moving from haacked/x-v2 to haacked/x"),
      Reflog.line("1", "2", "commit: Work on x")),
  ])
  func isNilWithoutAnEntryThatMovedHEADToTheBranch(_ reflog: String) {
    #expect(GitHub.commitsSinceSwitch(reflog: reflog, to: "haacked/x-v2") == nil)
  }
}

@Suite struct GitHubEarlierStanding {
  static let repo = "PostHog/charts"
  static let branch = "haacked/x-v2"
  static let checkedOut: Set<String> = ["haacked/x", "haacked/x-v2"]
  static let head = Reflog.sha("feed")

  static func pr(_ state: PRState, repo: String = repo, head: String = "haacked/x") -> PullRequest {
    PullRequest(id: "PR_1", number: 18303, url: "", repo: repo, state: state, head: head, headSha: Self.head)
  }

  static func standing(_ pr: PullRequest, made: Set<String>?) -> GitHub.EarlierStanding {
    GitHub.earlierStanding(pr, repo: repo, branch: branch, checkedOut: checkedOut, made: made)
  }

  /// A PR that is not the folder's earlier work counts as it does today,
  /// whatever the reflog shows.
  @Test(
    arguments: [
      ("PostHog/posthog", "haacked/x"),
      ("PostHog/charts", "haacked/x-v2"),
      ("PostHog/charts", "haacked/sibling-worktree"),
    ] as [(String, String)], [PRState.open, .merged, .closed])
  func aPRThatIsNotEarlierWorkIsCurrent(_ repoAndHead: (String, String), _ state: PRState) {
    let (prRepo, head) = repoAndHead
    #expect(Self.standing(Self.pr(state, repo: prRepo, head: head), made: nil) == .current)
  }

  @Test(arguments: [PRState.open, .merged, .closed])
  func anEarlierPRWhoseHeadTheFolderMadeIsCurrent(_ state: PRState) {
    #expect(Self.standing(Self.pr(state), made: [Reflog.sha("aaa"), Self.head]) == .current)
  }

  @Test(arguments: [nil, [], [Reflog.sha("aaa")]] as [Set<String>?])
  func anOpenEarlierPRWhoseHeadTheFolderDidNotMakeIsHidden(_ made: Set<String>?) {
    #expect(Self.standing(Self.pr(.open), made: made) == .hidden)
  }

  @Test(arguments: [nil, [], [Reflog.sha("aaa")]] as [Set<String>?], [PRState.merged, .closed])
  func anEndedEarlierPRWhoseHeadTheFolderDidNotMakeIsDropped(_ made: Set<String>?, _ state: PRState) {
    #expect(Self.standing(Self.pr(state), made: made) == .dropped)
  }

  @Test func aRepoThatDiffersOnlyInCaseIsStillTheSameRepo() {
    #expect(Self.standing(Self.pr(.open, repo: "posthog/CHARTS"), made: nil) == .hidden)
  }

  /// Each Risk 1 reflog shape, as the poller reads it, with the PR's head at
  /// commit `feed`. `kept` is whether the folder made that commit after it
  /// switched to `haacked/x-v2`.
  static let shapes: [(String, String, Bool)] = [
    (
      "rebase picks after the switch",
      Reflog.afterSwitch(
        Reflog.line("5", "b0", "rebase (start): checkout origin/main"),
        Reflog.line("b0", "c1", "rebase (pick): One"),
        Reflog.line("c1", "feed", "rebase (pick): Two"),
        Reflog.line("feed", "feed", "rebase (finish): returning to refs/heads/haacked/x-v2")),
      true
    ),
    ("a commit after the switch", Reflog.afterSwitch(Reflog.line("5", "feed", "commit: Work")), true),
    (
      "a reset to the PR's head", Reflog.afterSwitch(Reflog.line("5", "feed", "reset: moving to origin/haacked/x")),
      false
    ),
    ("a fast-forward pull to the PR's head", Reflog.afterSwitch(Reflog.line("5", "feed", "pull: Fast-forward")), false),
    (
      "a fast-forward merge to the PR's head",
      Reflog.afterSwitch(Reflog.line("5", "feed", "merge origin/haacked/x: Fast-forward")), false
    ),
    (
      "a rebase that starts on the PR's head",
      Reflog.afterSwitch(
        Reflog.line("5", "feed", "rebase (start): checkout origin/haacked/x"),
        Reflog.line("feed", "feed", "rebase (finish): returning to refs/heads/haacked/x-v2")),
      false
    ),
    (
      "a switch at the PR's head",
      Reflog.text(
        Reflog.line("0", "1", "commit (initial): first"),
        Reflog.line("1", "1", "checkout: moving from main to haacked/x"),
        Reflog.line("1", "feed", "commit: Work on x"),
        Reflog.line("feed", "feed", "checkout: moving from haacked/x to haacked/x-v2")),
      false
    ),
    ("other commits after the switch", Reflog.afterSwitch(Reflog.line("5", "abc", "commit: Other work")), false),
    (
      "a rename as the switch, then the PR's head",
      Reflog.text(
        Reflog.line("0", "1", "commit (initial): first"),
        Reflog.line("1", "1", "checkout: moving from main to haacked/x"),
        Reflog.line("1", "1", "Branch: renamed refs/heads/haacked/x to refs/heads/haacked/x-v2"),
        Reflog.line("1", "feed", "commit: Work")),
      true
    ),
    (
      "the PR's head made before the last of two checkouts",
      Reflog.afterSwitch(
        Reflog.line("5", "feed", "commit: First visit"),
        Reflog.line("feed", "5", "checkout: moving from haacked/x-v2 to haacked/x"),
        Reflog.line("5", "feed", "checkout: moving from haacked/x to haacked/x-v2"),
        Reflog.line("feed", "abc", "commit: Second visit")),
      false
    ),
    (
      "no switch to the branch",
      Reflog.text(Reflog.line("0", "1", "commit (initial): first"), Reflog.line("1", "feed", "commit: Work")), false
    ),
    (
      "a switch to a longer name",
      Reflog.text(
        Reflog.line("0", "1", "commit (initial): first"),
        Reflog.line("1", "1", "checkout: moving from haacked/x to haacked/x-v2-old"),
        Reflog.line("1", "feed", "commit: Work")),
      false
    ),
    ("an unreadable reflog", "", false),
  ]

  @Test(arguments: shapes, [PRState.open, .merged, .closed])
  func theReflogDecidesWhetherAnEarlierPRCounts(_ shape: (String, String, Bool), _ state: PRState) {
    let (name, reflog, kept) = shape
    let made = GitHub.commitsSinceSwitch(reflog: reflog, to: Self.branch)

    let standing = Self.standing(Self.pr(state), made: made)

    let expected: GitHub.EarlierStanding = kept ? .current : state == .open ? .hidden : .dropped
    #expect(standing == expected, "\(name)")
  }

  @Test(arguments: [PRState.open, .merged])
  func theExamplesPRIsTheSessions(_ state: PRState) {
    let pr = PullRequest(
      id: "PR_1", number: 20493, url: "", repo: "PostHog/charts", state: state, head: Reflog.original,
      headSha: Reflog.prHead)
    let made = GitHub.commitsSinceSwitch(reflog: Reflog.example, to: Reflog.v2)

    let standing = GitHub.earlierStanding(
      pr, repo: "PostHog/charts", branch: Reflog.v2, checkedOut: GitHub.checkedOutBranches(reflog: Reflog.example),
      made: made)

    #expect(standing == .current)
  }
}
