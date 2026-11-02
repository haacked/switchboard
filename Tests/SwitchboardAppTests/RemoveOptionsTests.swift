import Foundation
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

@Suite struct LinkedWorktreeCheck {
  func git(_ dir: String, _ args: String...) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
  }

  @Test func tellsALinkedWorktreeFromTheMainCheckoutAndTheirSubfolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let main = root + "/main"
    let linked = root + "/linked"
    try FileManager.default.createDirectory(atPath: main + "/sub", withIntermediateDirectories: true)
    try git(main, "init", "-q")
    try git(main, "commit", "-q", "--allow-empty", "-m", "x")
    try git(main, "worktree", "add", "-q", linked)
    try FileManager.default.createDirectory(atPath: linked + "/sub", withIntermediateDirectories: true)
    #expect(RemoveOptions.isLinkedWorktree(linked))
    #expect(!RemoveOptions.isLinkedWorktree(main))
    #expect(!RemoveOptions.isLinkedWorktree(linked + "/sub"))
    #expect(!RemoveOptions.isLinkedWorktree(main + "/sub"))
    #expect(!RemoveOptions.isLinkedWorktree(root + "/missing"))
  }
}
