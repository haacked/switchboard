import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct RemoveOptionsDefaults {
  func session(repo: String? = "a/b", branch: String? = "feat", pr: PRState? = nil) -> SessionSummary {
    var s = SessionSummary(
      id: "s", name: "s", cwd: "/wt/s", repo: repo, branch: branch, claudeSessionId: "s", state: .working,
      reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [],
      notes: [])
    if let pr {
      s.pr = PRSummary(
        PullRequest(id: "p", number: 1, url: "https://github.com/a/b/pull/1", repo: "a/b", state: pr))
    }
    return s
  }

  @Test func checksBothWhenTheFolderExistsAndThePRIsMerged() {
    let o = RemoveOptions(session(pr: .merged), folderExists: { _ in true }, isLinkedWorktree: { _ in true })
    #expect(o.worktree && o.worktreeEnabled)
    #expect(o.branch && o.branchEnabled)
    #expect(o.worktreeNote == nil && o.branchNote == nil)
  }

  @Test(arguments: [PRState?.none, .open, .closed])
  func keepsTheBranchUncheckedAndDisabledWithoutAMergedPR(_ pr: PRState?) {
    let o = RemoveOptions(session(pr: pr), folderExists: { _ in true }, isLinkedWorktree: { _ in true })
    #expect(o.worktree && o.worktreeEnabled)
    #expect(!o.branch && !o.branchEnabled)
    #expect(o.branchNote?.contains("PR is not merged") == true)
  }

  @Test func keepsBothUncheckedAndDisabledWhenTheFolderIsGone() {
    let o = RemoveOptions(session(pr: .merged), folderExists: { _ in false }, isLinkedWorktree: { _ in true })
    #expect(!o.worktree && !o.worktreeEnabled)
    #expect(!o.branch && !o.branchEnabled)
    #expect(o.worktreeNote?.contains("folder is gone") == true)
    #expect(o.branchNote?.contains("folder is gone") == true)
  }

  @Test func keepsTheBranchUncheckedWhenTheSessionHasNone() {
    let o = RemoveOptions(
      session(branch: nil, pr: .merged), folderExists: { _ in true }, isLinkedWorktree: { _ in true })
    #expect(o.worktree)
    #expect(!o.branch && !o.branchEnabled)
  }

  @Test func offersNothingWhenTheSessionHasNoRepo() {
    let o = RemoveOptions(session(repo: nil, pr: .merged), folderExists: { _ in true }, isLinkedWorktree: { _ in true })
    #expect(!o.worktree && !o.worktreeEnabled)
    #expect(!o.branch && !o.branchEnabled)
  }
}

extension RemoveOptionsDefaults {
  @Test func keepsBothUncheckedAndDisabledForTheMainCheckout() {
    let o = RemoveOptions(session(pr: .merged), folderExists: { _ in true }, isLinkedWorktree: { _ in false })
    #expect(!o.worktree && !o.worktreeEnabled)
    #expect(!o.branch && !o.branchEnabled)
    #expect(o.worktreeNote?.contains("main checkout") == true)
    #expect(o.branchNote?.contains("main checkout") == true)
  }
}
