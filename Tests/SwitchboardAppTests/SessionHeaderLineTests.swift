import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let posthog = "PostHog/posthog"

private func pr(url: String = "https://github.com/PostHog/posthog/pull/7") throws -> PRSummary {
  try JSONDecoder().decode(
    PRSummary.self,
    from: Data(
      """
      {"number":7,"url":"\(url)","repo":"\(posthog)","title":"Fix the flags API","state":"MERGED","status":"Merged"}
      """.utf8))
}

/// A work session in the worktree of branch haacked/fix, in a checkout of PostHog/posthog, with a PR and an issue.
private func linkedWork() throws -> SessionSummary {
  var s = notedSession([])
  s.repository = posthog
  s.pr = try pr()
  s.issues = [bodyIssue(394)]
  return s
}

/// A session in /tmp with no repo, branch, PR, or issue.
private func bareSession() -> SessionSummary { needsItem("s1") }

private func kinds(_ s: SessionSummary) -> [SessionHeaderLine.Item.Kind] {
  SessionHeaderLine.links(for: s).map(\.kind)
}

private func item(_ kind: SessionHeaderLine.Item.Kind, of s: SessionSummary) -> SessionHeaderLine.Item? {
  SessionHeaderLine.links(for: s).first { $0.kind == kind }
}

/// The caption beside the name says whether claude runs, and the permission mode when the session has one.
@Suite struct SessionHeaderLineCaption {
  @Test func saysClaudeIsRunningForALiveSession() {
    #expect(SessionHeaderLine.caption(for: bareSession()) == "claude running")
  }

  @Test func saysClaudeIsStoppedForAStoppedSession() {
    var s = bareSession()
    s.live = false

    #expect(SessionHeaderLine.caption(for: s) == "claude stopped")
  }

  @Test(arguments: ["plan", "auto", "default", "acceptEdits", "bypassPermissions", "dontAsk"])
  func addsThePermissionModeWhenItIsSet(_ mode: String) {
    var s = bareSession()
    s.permissionMode = mode

    #expect(SessionHeaderLine.caption(for: s) == "claude running · \(PermissionMode.title(mode)) mode")
  }

  /// Hook payloads call manual mode `default`. The caption shows the name that Claude Code's status line shows.
  @Test func namesManualModeByItsTitleNotItsRawValue() {
    var s = bareSession()
    s.live = false
    s.permissionMode = PermissionMode.manual

    #expect(SessionHeaderLine.caption(for: s) == "claude stopped · manual mode")
  }

  @Test func addsNoModeWhenItIsNotSet() {
    var s = bareSession()
    s.permissionMode = nil

    #expect(!SessionHeaderLine.caption(for: s).contains("mode"))
  }
}

/// The link line under the reason: the repo, the PR, the issue, and then the branch, or the folder when the session
/// has no branch.
@Suite struct SessionHeaderLineLinks {
  @Test func listsTheRepoPRIssueAndBranchInOrder() throws {
    let s = try linkedWork()

    #expect(kinds(s) == [.repo, .pr, .issue, .branch])
  }

  // MARK: Repo

  @Test func labelsTheRepoWithItsOwnerAndName() throws {
    let s = try linkedWork()

    #expect(item(.repo, of: s)?.text == posthog)
  }

  @Test func labelsTheRepoAsTheRepoLabelsDo() throws {
    let s = try linkedWork()

    #expect(item(.repo, of: s)?.text == RepoLabels.label(for: s))
  }

  @Test func explainsTheRepoInItsHelp() throws {
    let s = try linkedWork()

    #expect(item(.repo, of: s)?.help == "The repo this session works in")
  }

  @Test func listsNoRepoForASessionWithNoRepo() {
    #expect(!kinds(bareSession()).contains(.repo))
  }

  /// `RepoLabels` gives a label only to a work session, so a conversation, a chat, or the Operator in a repo shows
  /// none.
  @Test(arguments: [SessionKind.manager, .chat, .operator])
  func listsNoRepoForASessionThatIsNotWork(_ kind: SessionKind) throws {
    var s = try linkedWork()
    s.kind = kind

    #expect(!kinds(s).contains(.repo))
  }

  // MARK: PR

  @Test func showsThePRsStatusLine() throws {
    let s = try linkedWork()

    #expect(item(.pr, of: s)?.text == s.pr?.line)
  }

  @Test func namesThePRsRepoAndTitleInItsHelp() throws {
    let s = try linkedWork()

    #expect(item(.pr, of: s)?.help == "PostHog/posthog: Fix the flags API")
  }

  @Test func listsNoPRForASessionWithNoPR() throws {
    var s = try linkedWork()
    s.pr = nil

    #expect(!kinds(s).contains(.pr))
  }

  /// Any local process can record a `pr` event, and the app opens the PR's link. A PR whose url is not https has no
  /// link, so the line leaves it out.
  @Test(arguments: [
    "http://github.com/PostHog/posthog/pull/7", "file:///tmp/x", "javascript:alert(1)", "",
  ])
  func listsNoPRWhoseURLIsNotHTTPS(_ url: String) throws {
    var s = try linkedWork()
    s.pr = try pr(url: url)

    #expect(!kinds(s).contains(.pr), "\(url)")
  }

  // MARK: Issue

  @Test func showsTheIssueAsTheIssueBadgeDoes() throws {
    let s = try linkedWork()

    #expect(item(.issue, of: s)?.text == IssueBadge.label(for: [bodyIssue(394)], prRepo: posthog))
  }

  @Test func showsTheFirstIssueAndHowManyMore() throws {
    var s = try linkedWork()
    s.issues = [bodyIssue(394), bodyIssue(9, "PostHog/charts")]

    #expect(item(.issue, of: s)?.text == "#394 +1")
  }

  @Test func namesEveryIssueInItsHelp() throws {
    var s = try linkedWork()
    s.issues = [bodyIssue(394), bodyIssue(9, "PostHog/charts")]

    #expect(item(.issue, of: s)?.help == IssueBadge.tooltip(for: s.issues ?? [], prRepo: posthog))
  }

  @Test(arguments: [[SessionIssue]?.none, []])
  func listsNoIssueForASessionWithNoIssues(_ issues: [SessionIssue]?) throws {
    var s = try linkedWork()
    s.issues = issues

    #expect(!kinds(s).contains(.issue))
  }

  @Test func listsTheIssueOfABranchWithoutAPR() throws {
    var s = try linkedWork()
    s.pr = nil
    s.issues = [branchIssue]

    #expect(item(.issue, of: s)?.text == "#123")
  }

  // MARK: Branch and folder

  @Test func showsTheBranch() throws {
    let s = try linkedWork()

    #expect(item(.branch, of: s)?.text == "haacked/fix")
  }

  /// The branch's tooltip names the folder.
  @Test func namesTheFolderInTheBranchsHelp() throws {
    let s = try linkedWork()

    #expect(item(.branch, of: s)?.help == "Folder: /worktrees/posthog/haacked/fix")
  }

  @Test func listsNoFolderWhenTheSessionHasABranch() throws {
    let s = try linkedWork()

    #expect(!kinds(s).contains(.folder))
  }

  @Test func showsTheFolderInPlaceOfAMissingBranch() throws {
    var s = try linkedWork()
    s.branch = nil

    #expect(kinds(s) == [.repo, .pr, .issue, .folder])
    #expect(item(.folder, of: s)?.text == "/worktrees/posthog/haacked/fix")
  }

  /// `cwd` is always set for a session that a session view shows, so the line always has the folder or the branch.
  @Test func showsOnlyTheFolderForABareSession() {
    let links = SessionHeaderLine.links(for: bareSession())

    #expect(links.map(\.kind) == [.folder])
    #expect(links.first?.text == "/tmp")
  }

  @Test(arguments: [SessionKind.work, .manager, .chat, .operator], [String?.none, "haacked/fix"])
  func listsExactlyOneOfTheBranchAndTheFolder(_ kind: SessionKind, _ branch: String?) throws {
    var s = try linkedWork()
    s.kind = kind
    s.branch = branch

    let shown = kinds(s).filter { $0 == .branch || $0 == .folder }

    #expect(shown == [branch == nil ? .folder : .branch], "\(kind) \(String(describing: branch))")
  }

  @Test func putsTheBranchLast() throws {
    let s = try linkedWork()

    #expect(kinds(s).last == .branch)
  }

  @Test func putsTheFolderLastWithoutABranch() throws {
    var s = try linkedWork()
    s.branch = nil

    #expect(kinds(s).last == .folder)
  }
}
