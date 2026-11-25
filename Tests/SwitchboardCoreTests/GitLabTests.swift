import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct GitLabRemotes {
  @Test(arguments: [
    "git@gitlab.com:acme/widgets.git",
    "git@gitlab.com:acme/widgets",
    "https://gitlab.com/acme/widgets.git",
    "https://gitlab.com/acme/widgets/",
    "https://user@gitlab.com/acme/widgets.git",
    "ssh://git@gitlab.com/acme/widgets.git",
    "ssh://git@gitlab.com:22/acme/widgets.git",
    "https://GitLab.com/acme/widgets.git",
  ])
  func gitlabRemoteGivesTheProject(_ url: String) {
    #expect(GitLab.remote(remoteURL: url)?.project == "acme/widgets")
    #expect(GitLab.remote(remoteURL: url)?.host == "gitlab.com")
  }

  @Test func subgroupKeepsEveryPathPart() {
    #expect(GitLab.project(remoteURL: "git@gitlab.com:acme/team/widgets.git") == "acme/team/widgets")
  }

  @Test func aHostWhoseNameContainsGitlabCounts() {
    #expect(GitLab.project(remoteURL: "https://gitlab.example.com/acme/widgets.git") == "acme/widgets")
  }

  @Test func anExtraHostCountsWhenItIsListed() {
    let url = "git@git.example.com:acme/widgets.git"
    #expect(GitLab.project(remoteURL: url) == nil)
    #expect(GitLab.project(remoteURL: url, extraHosts: ["git.example.com"]) == "acme/widgets")
  }

  @Test(arguments: [
    "https://github.com/acme/widgets.git",
    "https://git.example.com/acme/widgets.git",
    "/local/path/repo",
    "https://gitlab.com/acme",
    "https://gitlab.com/acme/../widgets.git",
  ])
  func otherRemoteGivesNil(_ url: String) {
    #expect(GitLab.project(remoteURL: url) == nil)
  }

  @Test func branchOnGitLabNamesTheMergeRequest() {
    let config = ["remote.origin.url": "git@gitlab.com:acme/widgets.git"]
    #expect(
      GitHub.branchKey(branch: "haacked/x", config: config) { _ in nil }
        == .gitlabBranch(host: "gitlab.com", project: "acme/widgets", branch: "haacked/x", source: "acme/widgets"))
  }

  @Test func aForkIsLookedUpOnTheUpstreamProject() {
    let config = [
      "remote.origin.url": "git@gitlab.com:haacked/widgets.git",
      "remote.upstream.url": "https://gitlab.com/acme/team/widgets.git",
    ]
    #expect(
      GitHub.branchKey(branch: "haacked/x", config: config) { _ in nil }
        == .gitlabBranch(
          host: "gitlab.com", project: "acme/team/widgets", branch: "haacked/x", source: "haacked/widgets"))
  }

  @Test func theRemotesDefaultBranchHasNoMergeRequest() {
    let config = ["remote.origin.url": "git@gitlab.com:acme/widgets.git"]
    #expect(GitHub.branchKey(branch: "main", config: config) { _ in "main" } == nil)
  }
}

@Suite struct GitLabMergeRequest {
  @Test func aPageRoundTrips() {
    let url = "https://gitlab.com/acme/team/widgets/-/merge_requests/12"
    #expect(GitLab.ref(url) == GitLab.Ref(host: "gitlab.com", project: "acme/team/widgets", number: 12))
    #expect(GitLab.isMR(url))
    #expect(GitLab.page(host: "gitlab.com", project: "acme/team/widgets", number: 12) == url)
  }

  @Test func aPageMayEndInDiffs() {
    let ref = GitLab.ref("https://GitLab.Example.com/acme/widgets/-/merge_requests/3/diffs?q=1")
    #expect(ref == GitLab.Ref(host: "gitlab.example.com", project: "acme/widgets", number: 3))
  }

  @Test func aWaitReadsAMergeRequestURL() {
    #expect(
      Wait.PullRequest(parsing: "pr:https://gitlab.com/acme/widgets/-/merge_requests/12")
        == Wait.PullRequest(repository: "acme/widgets", number: 12, host: "gitlab.com"))
  }

  @Test func aGitHubNodeIdIsNotAMergeRequest() {
    #expect(!GitLab.isMR("PR_kwDOAbc"))
  }

  @Test func pathIDEncodesSlashes() {
    #expect(GitLab.pathID("acme/team/widgets") == "acme%2Fteam%2Fwidgets")
  }

  @Test func anOpenMergeRequestWinsOverANewerClosedOneFromAnotherFork() {
    let open = mr(iid: 4, state: "opened", source: 9)
    let closed = mr(iid: 8, state: "merged", source: 9)
    let other = mr(iid: 9, state: "opened", source: 3)
    #expect(GitLab.choose([other, closed, open], sourceProjectID: 9)?["iid"]?.int == 4)
    #expect(GitLab.choose([closed], sourceProjectID: 9)?["iid"]?.int == 8)
    #expect(GitLab.choose([other], sourceProjectID: 9) == nil)
  }

  @Test func anOpenMergeRequestBecomesAPullRequest() {
    let pr = GitLab.pullRequest(
      mr: mr(iid: 12, state: "opened", source: 1, pipeline: "running", detailed: "mergeable", draft: true),
      approvals: ["approvals_required": 1, "approved": false, "approved_by": []], host: "gitlab.com",
      project: "acme/widgets")
    #expect(pr?.id == "https://gitlab.com/acme/widgets/-/merge_requests/12")
    #expect(pr?.number == 12)
    #expect(pr?.repo == "acme/widgets")
    #expect(pr?.state == .open)
    #expect(pr?.draft == true)
    #expect(pr?.head == "haacked/x")
    #expect(pr?.headSha == "abc")
    #expect(pr?.base == "main")
    #expect(pr?.checks == "PENDING")
    #expect(pr?.mergeable == .mergeable)
    #expect(pr?.reviewDecision == .reviewRequired)
    #expect(pr?.reviewDecisionRead == true)
    #expect(pr?.author == "ada")
    #expect(pr?.labels == ["bug"])
  }

  @Test func anApprovalAndAFailedPipelineShowOnThePullRequest() {
    let pr = GitLab.pullRequest(
      mr: mr(iid: 2, state: "opened", source: 1, pipeline: "failed", detailed: "conflict"),
      approvals: ["approved": true, "approved_by": [["user": ["username": "ada"]]]], host: "gitlab.com",
      project: "acme/widgets")
    #expect(pr?.checks == "FAILURE")
    #expect(pr?.mergeable == .conflicting)
    #expect(pr?.reviewDecision == .approved)
    #expect(pr?.verdicts == [Review(author: "ada", state: "APPROVED")])
    #expect(pr?.status == .approved)
  }

  @Test func noRequiredApprovalLeavesTheDecisionUnreadOfARequirement() {
    let pr = GitLab.pullRequest(
      mr: mr(iid: 2, state: "merged", source: 1, pipeline: "success", detailed: "not_open"),
      approvals: ["approvals_required": 0, "approved": false], host: "gitlab.com", project: "acme/widgets")
    #expect(pr?.state == .merged)
    #expect(pr?.checks == "SUCCESS")
    #expect(pr?.reviewDecision == nil)
    #expect(pr?.reviewDecisionRead == true)
    #expect(pr?.needsReview == false)
    #expect(pr?.mergeCommit == "def")
  }

  @Test func aMissingApprovalsReadLeavesTheDecisionUnread() {
    let pr = GitLab.pullRequest(
      mr: mr(iid: 2, state: "opened", source: 1, pipeline: "skipped"), approvals: nil, host: "gitlab.com",
      project: "acme/widgets")
    #expect(pr?.checks == "SUCCESS")
    #expect(pr?.reviewDecisionRead == nil)
    #expect(pr?.awaitsReview == true)
  }

  private func mr(
    iid: Int, state: String, source: Int, pipeline: String? = nil, detailed: String? = nil, draft: Bool = false
  ) -> JSON {
    var object: [String: JSON] = [
      "iid": .number(Double(iid)), "state": .string(state), "title": "Fix it", "draft": .bool(draft),
      "source_branch": "haacked/x", "target_branch": "main", "sha": "abc", "source_project_id": .number(Double(source)),
      "web_url": .string("https://gitlab.com/acme/widgets/-/merge_requests/\(iid)"),
      "author": ["username": "ada"], "labels": [["name": "bug"]], "merged_at": "2026-01-02T00:00:00Z",
      "merge_commit_sha": "def",
    ]
    if let pipeline { object["head_pipeline"] = ["status": .string(pipeline)] }
    if let detailed { object["detailed_merge_status"] = .string(detailed) }
    return .object(object)
  }
}
