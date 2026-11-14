import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"
private let statusRead = "status --porcelain"

extension Instance {
  /// Whether the box repo has the branch, read with this Mac's git, which also reads the box.
  fileprivate func boxHasBranch(_ repo: String, _ name: String) throws -> Bool {
    try runCommand("/usr/bin/git", ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0
  }

  fileprivate func cleanups(_ id: String) throws -> Int { try events(id, kind: "cleanup").count }
}

/// `sb cleanup` of a session on a host whose PR merged. sbd runs the local checks on the host, removes the worktree
/// and the branch there, and keeps the session in Done. Each refusal here checks that nothing was removed on the
/// box, no `cleanup` was recorded, and this Mac ran nothing for the session.
@Suite(.blocking(timeLimit: .seconds(180))) struct RemoteCleanupTests {
  /// A remote session in a worktree on the branch of PR 122953, after a commit. GitHub reports the PR in `state`
  /// with that commit as its head, and the poller has read it. With `url`, the box repo pushes to another GitHub
  /// repo, so the poller finds no PR for the branch. With `shortHostWait`, a request waits 2 s for the link.
  private func finishedOnBox(_ github: FakeGitHub, state: String = "MERGED", shortHostWait: Bool = false) throws
    -> (Instance, Instance.BoxSession, String)
  {
    let wait = shortHostWait ? Instance.shortHostWait : [:]
    let sbd = try Instance.remoteForRemoval(
      host: Instance.listsPostHog, config: Instance.gitHubConfig(github).merging(wait) { $1 })
    if shortHostWait { try sbd.connectHost() }
    let (_, origin) = try sbd.makeBoxRepoWithOrigin()
    let s = try sbd.startBoxWorktree(branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = .string(state)
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the PR's state") { $0.pr?.number == 122953 && $0.pr?.state.rawValue == state }
    return (sbd, s, origin)
  }

  /// Runs `sb cleanup`, expects it to fail, and expects nothing removed on the box and no `cleanup` recorded.
  private func expectRefusal(
    _ sbd: Instance, _ s: Instance.BoxSession, origin: String, saying texts: [String] = [],
    keepingClaude: Bool = true
  ) throws {
    let before = try sbd.removalState(s, origin: origin)

    let r = try sbd.run("cleanup", s.id, "--json")

    #expect(r.status != 0, "cleanup succeeded: \(r.stdout)")
    if !texts.isEmpty { #expect(texts.contains { r.stderr.contains($0) }, "\(r.stderr)") }
    let after = try sbd.removalState(s, origin: origin)
    if keepingClaude {
      #expect(after == before)
    } else {
      #expect(after.withoutClaude == before.withoutClaude)
    }
    #expect(FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.boxHasBranch(s.repo, Instance.mergedBranch))
    #expect(try sbd.cleanups(s.id) == 0)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  // MARK: Cleanup after a merge

  @Test func thePollerReportsAMergedRemoteSessionReadyForCleanup() throws {
    let github = try FakeGitHub()
    let (sbd, s, _) = try finishedOnBox(github)

    let after = try sbd.get(s.id)

    #expect(after.cleanup == CleanupStatus(state: .ready), "\(String(describing: after.cleanup))")
    #expect(after.state == .done)
  }

  @Test func cleanupRemovesTheWorktreeAndTheBranchOnTheBoxAndKeepsTheSessionInDone() throws {
    let github = try FakeGitHub()
    let (sbd, s, _) = try finishedOnBox(github)
    let listed = real(s.cwd)

    let r = try sbd.run("cleanup", s.id, "--json")

    #expect(r.status == 0, "\(r.stderr)")
    let json = try #require(JSON.parse(r.stdout))
    #expect(json["cleaned"]?.string == s.id)
    #expect(json["worktree"]?.string == s.cwd)
    #expect(json["branch"]?.string == Instance.mergedBranch)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    let worktrees = try sbd.git(s.repo, "worktree", "list", "--porcelain")
    #expect(!worktrees.contains(listed) && !worktrees.contains(s.cwd), "\(worktrees)")
    #expect(try !sbd.boxHasBranch(s.repo, Instance.mergedBranch))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    let after = try sbd.get(s.id)
    #expect(after.state == .done)
    #expect(after.cleanup?.state == .removed)
    #expect(try sbd.cleanups(s.id) == 1)
  }

  @Test func cleanupStopsTheClaudeOnTheBoxClosesBothPanesAndRunsNothingOnThisMac() throws {
    let github = try FakeGitHub()
    let (sbd, s, _) = try finishedOnBox(github)

    let r = try sbd.run("cleanup", s.id, "--json")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!sbd.runs(s.pid))
    #expect(try sbd.boxTmuxSessions().isEmpty)
    #expect(try sbd.get(s.id).live == false)
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac")
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  // MARK: Each local refusal refuses on the box

  /// Each change to a ready session that `sb cleanup` refuses on this Mac, with the texts of that refusal.
  enum Fault: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case untrackedFile = "an untracked file"
    case ignoredFileThatNoBuildMakes = "an ignored file that no build makes"
    case commitAfterTheMerge = "a commit after the merge"
    case branchBehindTheMerge = "a branch behind the merged head"
    case anotherBranch = "another branch at the merged commit"
    case locked = "a lock"
    case hiddenChange = "a change that skip-worktree hides"

    var testDescription: String { rawValue }

    var texts: [String] {
      switch self {
      case .untrackedFile: ["uncommitted"]
      case .ignoredFileThatNoBuildMakes: ["no build makes again"]
      case .commitAfterTheMerge, .branchBehindTheMerge: ["not in its merged PR"]
      case .anotherBranch: ["checked out"]
      case .locked: ["locked"]
      case .hiddenChange: ["git status skips"]
      }
    }

    func apply(_ sbd: Instance, _ s: Instance.BoxSession) throws {
      switch self {
      case .untrackedFile:
        try "x".write(toFile: "\(s.cwd)/notes.txt", atomically: true, encoding: .utf8)
      case .ignoredFileThatNoBuildMakes:
        try ".env\n".write(toFile: "\(s.repo)/.git/info/exclude", atomically: true, encoding: .utf8)
        try "SECRET=1".write(toFile: "\(s.cwd)/.env", atomically: true, encoding: .utf8)
      case .commitAfterTheMerge:
        try sbd.commit(s.cwd, "b.txt")
      case .branchBehindTheMerge:
        try sbd.git(s.cwd, "reset", "-q", "--hard", "HEAD~1")
      case .anotherBranch:
        try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/other")
      case .locked:
        try sbd.git(s.repo, "worktree", "lock", s.cwd)
      case .hiddenChange:
        try sbd.git(s.cwd, "update-index", "--skip-worktree", "a.txt")
        try "changed".write(toFile: "\(s.cwd)/a.txt", atomically: true, encoding: .utf8)
      }
    }
  }

  @Test(arguments: Fault.allCases)
  func eachRefusalOfALocalCleanupRefusesOnTheBoxAndChangesNothing(_ fault: Fault) throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github)
    try fault.apply(sbd, s)

    try expectRefusal(sbd, s, origin: origin, saying: fault.texts)

    #expect(sbd.runs(s.pid), "the refusal stopped the box's claude")
  }

  @Test func cleanupRefusesAWorktreeThatAnotherRemoteSessionRunsIn() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github)
    let second = try sbd.newOnHost("~/sb-box-repo", "--branch", Instance.mergedBranch)
    #expect(second["cwd"]?.string == s.cwd)
    try sbd.waitFor(try sbd.id(of: second), "the second session's claude on the box", timeout: 30) {
      $0.claudePid != nil
    }

    try expectRefusal(sbd, s, origin: origin, saying: ["also runs in"])
  }

  /// A turn runs on the box, so its claude may still write to the folder.
  @Test func cleanupRefusesWhileATurnRunsOnTheBox() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github)
    try sbd.sb("send", s.id, "slow 30")
    try sbd.waitFor("the turn to start on the box", timeout: 30) {
      try sbd.events(s.id).contains { $0.kind == "UserPromptSubmit" && $0.data["prompt"]?.string == "slow 30" }
    }

    try expectRefusal(sbd, s, origin: origin, saying: ["running a turn"])

    #expect(sbd.runs(s.pid))
  }

  /// The box is this Mac, so a process started here with its working folder in the worktree stands in for a
  /// program that the user left running on the box.
  @Test func cleanupRefusesAWorktreeThatAProcessOnTheBoxStillUses() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github)
    let user = try sbd.startProcess(in: s.cwd)
    defer { user.terminate() }

    try expectRefusal(sbd, s, origin: origin, saying: ["still run"], keepingClaude: false)

    #expect(user.isRunning)
  }

  /// The box's transcript names PostHog/posthog#122953, which merged at the worktree's tip. The box's repo pushes
  /// to another GitHub repo, so GitHub has no PR for its branch. A host can name any PR in its transcript, so that
  /// PR is no proof that the work merged.
  @Test func aPRThatOnlyTheBoxesTranscriptNamesDoesNotLetCleanupRun() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.remoteForRemoval(host: Instance.listsPostHog, config: Instance.gitHubConfig(github))
    let (repo, origin) = try sbd.makeBoxRepoWithOrigin(url: "https://github.com/haacked/elsewhere.git")
    // A transcript's PR counts only in a repo that a remote names.
    try sbd.git(repo, "remote", "add", "mirror", "https://github.com/PostHog/posthog.git")
    let s = try sbd.startBoxWorktree(branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    let transcript = try #require(sbd.boxTranscripts(s.claudeSessionId).first)
    let handle = try #require(FileHandle(forWritingAtPath: transcript))
    handle.seekToEndOfFile()
    handle.write(Data((#"{"type":"pr-link","prNumber":122953,"prRepository":"PostHog/posthog"}"# + "\n").utf8))
    try handle.close()
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the PR that the box's transcript names") { $0.pr?.number == 122953 }

    try expectRefusal(sbd, s, origin: origin)

    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).cleanup?.state != .ready)
  }

  // MARK: The link

  @Test func cleanupWithTheLinkDownRefusesWithTheReasonAndChangesNothing() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github, shortHostWait: true)
    try sbd.dropLinkAndRefuse(refusal)

    try expectRefusal(sbd, s, origin: origin, saying: ["mini is not connected"])
  }

  @Test func cleanupThatLosesTheLinkDuringTheChecksChangesNothing() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github)
    let before = try sbd.removalState(s, origin: origin)
    try sbd.holdBoxGit(statusRead)

    let cleanup = try BackgroundSb(sbd, ["cleanup", s.id, "--json"])
    try sbd.waitFor("the cleanup check to reach the box's git", timeout: 30) { sbd.boxGitHeld }
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.releaseBoxGit()
    let r = cleanup.result()

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.removalState(s, origin: origin) == before)
    #expect(try sbd.cleanups(s.id) == 0)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  /// The link drops while the checks that run again after claude stopped wait on the box.
  @Test func cleanupThatLosesTheLinkAfterClaudeStoppedChangesNothing() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github)
    let before = try sbd.removalState(s, origin: origin)
    try sbd.holdBoxGit(statusRead, skipping: 1)

    let cleanup = try BackgroundSb(sbd, ["cleanup", s.id, "--json"])
    try sbd.waitFor("the check after the stop to reach the box's git", timeout: 45) { sbd.boxGitHeld }
    #expect(!sbd.runs(s.pid), "the held check ran before claude stopped")
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.releaseBoxGit()
    let r = cleanup.result()

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.removalState(s, origin: origin).withoutClaude == before.withoutClaude)
    #expect(try sbd.cleanups(s.id) == 0)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  @Test(arguments: [statusRead, "ls-files -v", "branch --show-current", "rev-parse HEAD", "worktree list"])
  func aCleanupCheckThatGotNoAnswerRefusesAndChangesNothing(_ word: String) throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try finishedOnBox(github)
    try sbd.endBoxGit(word)

    try expectRefusal(sbd, s, origin: origin)

    #expect(sbd.boxGitEnded, "no check ran `git \(word)` on the box")
  }
}
