import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A repo whose origin is a bare repo in the home, with main pushed.
  func repoWithOrigin() throws -> String {
    let repo = try makeRepo()
    let origin = "\(home.path)/origin.git"
    try git(home.path, "init", "-q", "--bare", origin)
    try git(repo, "remote", "add", "origin", origin)
    try git(repo, "push", "-q", "origin", "main")
    return repo
  }

  /// A session in a worktree that sbd made, after its first reply.
  func worktreeSession(_ repo: String, branch: String = "haacked/feature") throws -> SessionSummary {
    let s = try client.call(
      "new", ["path": .string(repo), "branch": .string(branch), "prompt": "hello"], as: SessionSummary.self)
    return try waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
  }

  func commit(_ dir: String, _ file: String) throws {
    try "x".write(toFile: "\(dir)/\(file)", atomically: true, encoding: .utf8)
    try git(dir, "add", file)
    try git(dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", file)
  }

  func deleteSession(_ id: String) throws -> CommandResult { try run(["rm", id, "--worktree"]) }

  func deleteSessionAndBranch(_ id: String) throws -> CommandResult {
    try run(["rm", id, "--worktree", "--delete-branch"])
  }

  /// Restarts sbd with a `git` in front of the real one that runs `afterRemove` (a shell
  /// snippet, with `$REPO` the repo) once `git worktree remove` succeeds.
  func runAfterWorktreeRemoval(_ repo: String, _ afterRemove: String) throws {
    let dir = "\(home.path)/git-wrapper"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      /usr/bin/git "$@" || exit $?
      case " $* " in *" worktree remove "*) REPO='\(repo)'; \(afterRemove);; esac
      """
    try script.write(toFile: "\(dir)/git", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(dir)/git")
    stopSbd()
    sbdEnvironment["PATH"] = "\(dir):" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
    try startSbd()
  }

  func intact(_ s: SessionSummary) throws -> Bool {
    try FileManager.default.fileExists(atPath: s.cwd) && client.sessions().map(\.id).contains(s.id)
  }
}

@Suite(.timeLimit(.minutes(2))) struct DeleteSessionTests {
  @Test func deletesTheWorktreeAndTheSessionAndKeepsTheTranscript() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    let transcript = try #require(Transcript.find(s.claudeSessionId, account: sbd.claudeConfig, cwd: s.cwd))
    let terminals = try sbd.client.terminals(s.id)
    #expect(try sbd.deleteSession(s.id).status == 0)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains("/worktrees/repo/haacked/feature") == false)
    #expect(try sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: sbd.home.sessionFolder(s.id)))
    #expect(
      try runCommand(terminals.tmux, ["-S", terminals.socket, "has-session", "-t", "=\(terminals.claude)"]).status != 0)
    #expect(FileManager.default.fileExists(atPath: transcript))
    #expect(try sbd.git(repo, "branch", "--list", "haacked/feature") != "")
  }

  @Test func refusesAWorktreeWithUncommittedChanges() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let file = "\(s.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("uncommitted"))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    try FileManager.default.removeItem(atPath: file)
    #expect(try sbd.deleteSession(s.id).status == 0)
  }

  @Test func refusesCommitsThatNoPushedBranchHas() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.commit(s.cwd, "a.txt")
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("not on a pushed branch"))
    #expect(try sbd.intact(s))
    try sbd.git(s.cwd, "push", "-q", "origin", "haacked/feature")
    #expect(try sbd.deleteSession(s.id).status == 0)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  @Test func refusesWhenTheRepoHasNoRemote() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.makeRepo())
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("not on a pushed branch"))
    #expect(try sbd.intact(s))
  }

  @Test func allowsUnpushedCommitsOfAMergedPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let repo = try Repos.create("\(sbd.home.path)/posthog", origin: "https://github.com/PostHog/posthog.git")
    let branch = "haacked/cdp-dlq-breaker-counts-lookups"
    let s = try sbd.worktreeSession(repo, branch: branch)
    try sbd.commit(s.cwd, "a.txt")
    try sbd.poll()
    #expect(try sbd.deleteSession(s.id).stderr.contains("not on a pushed branch"))
    github.change(122953) { $0["state"] = "CLOSED" }
    try sbd.poll(all: true)
    #expect(try sbd.deleteSession(s.id).stderr.contains("not on a pushed branch"))
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    #expect(try sbd.deleteSession(s.id).status == 0)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  @Test func refusesAFolderThatSbdDidNotCreate() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    // Started in the main checkout, as an imported session or one in the
    // user's own folder would be.
    let s = try sbd.client.call("new", ["path": .string(repo), "prompt": "hello"], as: SessionSummary.self)
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("didn't make a worktree"))
    #expect(try sbd.intact(s))
    #expect(FileManager.default.fileExists(atPath: "\(repo)/.git"))
  }

  @Test func refusesAFolderThatIsNoLongerAWorktreeOfTheRepo() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.git(repo, "worktree", "remove", "--force", s.cwd)
    try FileManager.default.createDirectory(atPath: s.cwd, withIntermediateDirectories: true)
    let keep = "\(s.cwd)/mine.txt"
    try "x".write(toFile: keep, atomically: true, encoding: .utf8)
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("is not a worktree of"))
    #expect(FileManager.default.fileExists(atPath: keep))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
  }

  @Test func refusesACommitOnADetachedHeadEvenWithAMergedPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let repo = try Repos.create("\(sbd.home.path)/posthog", origin: "https://github.com/PostHog/posthog.git")
    let s = try sbd.worktreeSession(repo, branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.git(s.cwd, "checkout", "-q", "--detach")
    try sbd.commit(s.cwd, "a.txt")
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("not on a pushed branch"))
    #expect(try sbd.intact(s))
  }

  @Test func refusesAWorktreeThatAnotherSessionRunsIn() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let first = try sbd.worktreeSession(repo)
    let second = try sbd.worktreeSession(repo)
    #expect(second.cwd == first.cwd)
    let r = try sbd.deleteSession(first.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("also runs in"))
    #expect(try sbd.intact(first))
    try sbd.sb("rm", second.id)
    #expect(try sbd.deleteSession(first.id).status == 0)
  }

  /// A session on the recorded branch of PR 122953, whose PR is merged and whose
  /// head is the branch tip after a commit.
  private func mergedBranchSession(_ github: FakeGitHub) throws -> (Instance, String, SessionSummary) {
    let sbd = try Instance.withGitHub(github)
    let repo = try Repos.create("\(sbd.home.path)/posthog", origin: "https://github.com/PostHog/posthog.git")
    let s = try sbd.worktreeSession(repo, branch: "haacked/cdp-dlq-breaker-counts-lookups")
    try sbd.commit(s.cwd, "a.txt")
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    return (sbd, repo, s)
  }

  @Test func deletesTheBranchOfAMergedPR() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try mergedBranchSession(github)
    try sbd.git(repo, "config", "branch.haacked/cdp-dlq-breaker-counts-lookups.remote", "origin")
    let r = try sbd.deleteSessionAndBranch(s.id)
    #expect(r.status == 0)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.git(repo, "branch", "--list", "haacked/cdp-dlq-breaker-counts-lookups") == "")
    #expect(!(try sbd.git(repo, "config", "--list")).contains("branch.haacked/cdp-dlq-breaker-counts-lookups"))
    #expect(try sbd.client.sessions().isEmpty)
  }

  @Test func refusesToDeleteTheBranchOfASessionWithNoMergedPRBeforeStoppingAnything() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    // Nothing is uncommitted or unpushed, so only the branch check refuses.
    let s = try sbd.worktreeSession(repo)
    let r = try sbd.deleteSessionAndBranch(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("no merged PR"))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.git(repo, "branch", "--list", "haacked/feature") != "")
  }

  @Test func refusesToDeleteTheBranchWithoutTheWorktree() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try mergedBranchSession(github)
    let r = try sbd.run(["rm", s.id, "--delete-branch"])
    #expect(r.status != 0)
    #expect(r.stderr.contains("Remove the worktree too"))
    #expect(try sbd.intact(s))
    #expect(try sbd.git(repo, "branch", "--list", "haacked/cdp-dlq-breaker-counts-lookups") != "")
  }

  @Test func refusesToDeleteTheBranchOfACommitAfterTheMerge() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try mergedBranchSession(github)
    try sbd.commit(s.cwd, "b.txt")
    let r = try sbd.deleteSessionAndBranch(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("not in its merged PR"))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.git(repo, "branch", "--list", "haacked/cdp-dlq-breaker-counts-lookups") != "")
  }

  @Test func refusesToDeleteTheBranchOfADetachedWorktree() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try mergedBranchSession(github)
    try sbd.commit(s.cwd, "b.txt")
    try sbd.git(s.cwd, "checkout", "-q", "--detach", "HEAD~1")
    let r = try sbd.deleteSessionAndBranch(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("checked out"))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.git(repo, "branch", "--list", "haacked/cdp-dlq-breaker-counts-lookups") != "")
  }

  private static let mergedBranch = "haacked/cdp-dlq-breaker-counts-lookups"

  /// After the worktree is gone, the branch fails a safety check. The worktree and the session
  /// go, because the session's folder is missing, and the branch stays.
  private func refusesTheBranchAfterTheWorktreeIsRemoved(
    _ afterRemove: String, error: String
  ) throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try mergedBranchSession(github)
    try sbd.runAfterWorktreeRemoval(repo, afterRemove)
    // The restart drops the polled PR, so poll it again.
    try sbd.poll(all: true)
    let r = try sbd.deleteSessionAndBranch(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains(error))
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.client.sessions().isEmpty)
  }

  @Test func keepsTheBranchWhenACommitLandsAfterTheWorktreeIsRemoved() throws {
    try refusesTheBranchAfterTheWorktreeIsRemoved(
      "git -C \"$REPO\" branch -f \(Self.mergedBranch) main", error: "not in its merged PR")
  }

  @Test func keepsTheBranchWhenAnotherWorktreeChecksItOutAfterTheWorktreeIsRemoved() throws {
    try refusesTheBranchAfterTheWorktreeIsRemoved(
      "git -C \"$REPO\" checkout -q \(Self.mergedBranch)", error: "checked out")
  }

  @Test func reportsABranchThatIsGoneAfterTheWorktreeIsRemoved() throws {
    try refusesTheBranchAfterTheWorktreeIsRemoved(
      "git -C \"$REPO\" branch -D \(Self.mergedBranch) >/dev/null", error: "no longer exists")
  }
}
