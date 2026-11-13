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

  /// Sets a session's stored repo to a folder that no longer exists, as older sbd versions stored a removed linked worktree.
  func storeGoneRepo(_ id: String) throws {
    let gone = "\(home.path)/gone-worktree"
    stopSbd()
    let store = try Store(path: home.database)
    var session = try #require(try store.sessions().first { $0.id == id })
    session.repo = gone
    try store.save(session)
    try startSbd()
  }

  func deleteSession(_ id: String) throws -> CommandResult { try run(["rm", id, "--worktree"]) }

  func deleteSessionAndBranch(_ id: String) throws -> CommandResult {
    try run(["rm", id, "--worktree", "--delete-branch"])
  }

  /// What the Done column's delete icon asks for.
  func deleteDoneSession(_ id: String) throws -> CommandResult {
    try run(["rm", id, "--worktree", "--delete-branch", "--delete-remote-branch"])
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

  /// Makes every `statement`, such as `DELETE` or `INSERT`, on `table` abort, as a constraint on the store would.
  func block(_ statement: String, on table: String) throws {
    let trigger = "block_\(statement.lowercased())_\(table)"
    let r = try runCommand(
      "/usr/bin/sqlite3",
      [
        home.database,
        "CREATE TRIGGER \(trigger) BEFORE \(statement) ON \(table) BEGIN SELECT RAISE(ABORT, 'store is read-only'); END;",
      ])
    try #require(r.status == 0)
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct DeleteSessionTests {
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
    let s = try sbd.client.call(
      "new", ["path": .string(repo), "prompt": "hello", "name": "zsh-startup-for-switchboard"],
      as: SessionSummary.self)
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("didn't make a worktree"))
    #expect(r.stderr.contains("zsh-startup-for-switchboard (\(s.id)) runs in"), Comment(rawValue: r.stderr))
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

  @Test func refusesTheBranchOfASessionWhoseFolderIsGoneAndWhosePRIsNotMerged() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try FileManager.default.removeItem(atPath: s.cwd)
    let r = try sbd.deleteSessionAndBranch(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("no merged PR"))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
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
    #expect(r.stderr.contains("Removed \(s.name) (\(s.id)) and its worktree, and kept"), Comment(rawValue: r.stderr))
    #expect(!r.stderr.contains(".."))
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

  /// The store refuses the delete, so sbd refuses before it stops claude or removes the worktree.
  private func refusesWhenTheStoreCannotDelete(_ table: String, branch: Bool, statement: String = "DELETE") throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try mergedBranchSession(github)
    try sbd.block(statement, on: table)
    let r = try (branch ? sbd.deleteSessionAndBranch(s.id) : sbd.deleteSession(s.id))
    #expect(r.status != 0)
    #expect(r.stderr.contains("store is read-only"))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) != "")
    // sqlite3 has no busy timeout, so this fails while sbd's connection still holds the write lock.
    #expect(try runCommand("/usr/bin/sqlite3", [sbd.home.database, "BEGIN IMMEDIATE; ROLLBACK;"]).status == 0)
  }

  @Test func refusesBeforeRemovingTheWorktreeWhenTheStoreCannotDeleteTheSession() throws {
    try refusesWhenTheStoreCannotDelete("sessions", branch: false)
  }

  @Test func refusesBeforeRemovingTheWorktreeWhenTheStoreCannotDeleteTheEvents() throws {
    try refusesWhenTheStoreCannotDelete("events", branch: true)
  }

  /// The dry run in `checkDeletable` writes the removal's name too, so a store that can't record it refuses
  /// before the worktree goes.
  @Test func refusesBeforeRemovingTheWorktreeWhenTheStoreCannotRecordTheRemoval() throws {
    try refusesWhenTheStoreCannotDelete("removed_sessions", branch: true, statement: "INSERT")
  }

  @Test func aRemovalWithTheWorktreeRecordsTheSessionsName() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)

    #expect(try sbd.deleteSession(s.id).status == 0)

    #expect(try sbd.removedSessions().map(\.id) == [s.id])
    #expect(try sbd.removedSessions().map(\.name) == [s.name])
  }

  // MARK: The Done column's delete icon

  /// A session like `mergedBranchSession`, whose origin is a bare repo that holds the branch at the
  /// merged PR's head.
  private func doneSessionWithRemote(_ github: FakeGitHub) throws -> (Instance, String, SessionSummary, String) {
    let (sbd, repo, s) = try mergedBranchSession(github)
    let origin = "\(sbd.home.path)/origin.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", origin)
    try sbd.git(repo, "config", "url.\(origin).insteadOf", "https://github.com/PostHog/posthog.git")
    try sbd.git(s.cwd, "push", "-q", "origin", Self.mergedBranch)
    return (sbd, repo, s, origin)
  }

  private func removeFolderAndLocalBranch(_ sbd: Instance, _ repo: String, _ s: SessionSummary) throws {
    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.git(repo, "worktree", "prune")
    try sbd.git(repo, "branch", "-D", Self.mergedBranch)
  }

  private func remoteBranch(_ origin: String) throws -> String {
    try runCommand("/usr/bin/git", ["-C", origin, "branch", "--list", Self.mergedBranch]).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @Test func keepsTheRemoteBranchWhenItsTipIsNotTheMergedPRsHead() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    // Someone pushed another commit to the remote branch after the merge.
    let other = "\(sbd.home.path)/other"
    try sbd.git(sbd.home.path, "clone", "-q", origin, other)
    try sbd.git(other, "checkout", "-q", Self.mergedBranch)
    try sbd.commit(other, "later.txt")
    try sbd.git(other, "push", "-q", "origin", Self.mergedBranch)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("kept the remote branch: origin/\(Self.mergedBranch) is at"))
    #expect(r.stderr.contains("not the merged PR's head"))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) == "")
    #expect(try remoteBranch(origin) != "")
  }

  @Test func deletesTheRestWhenTheRemoteBranchIsAlreadyGone() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    try sbd.git(origin, "branch", "-D", Self.mergedBranch)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status == 0)
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) == "")
  }

  @Test func refusesTheRemoteBranchWithoutTheLocalBranch() throws {
    let github = try FakeGitHub()
    let (sbd, _, s, origin) = try doneSessionWithRemote(github)
    let r = try sbd.run(["rm", s.id, "--worktree", "--delete-remote-branch"])
    #expect(r.status != 0)
    #expect(r.stderr.contains("Delete the local branch too"))
    #expect(try sbd.intact(s))
    #expect(try remoteBranch(origin) != "")
  }

  @Test func theIconRefusesABranchThatIsOnNoRemoteAndHasNoMergedPR() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.commit(s.cwd, "a.txt")
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("not on a pushed branch"))
    #expect(try sbd.intact(s))
    #expect(try sbd.git(repo, "branch", "--list", "haacked/feature") != "")
  }

  @Test func theIconKeepsTheBranchAnotherWorktreeChecksOut() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    try sbd.runAfterWorktreeRemoval(repo, "git -C \"$REPO\" checkout -q \(Self.mergedBranch)")
    try sbd.poll(all: true)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("kept \(Self.mergedBranch)"))
    #expect(r.stderr.contains("checked out"))
    #expect(r.stderr.contains("also kept the remote branch"))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try remoteBranch(origin) != "")
  }

  @Test func refusesASessionWhoseFolderIsGoneAndWhoseDetachedHeadHasUnpushedCommits() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.git(s.cwd, "checkout", "-q", "--detach")
    try sbd.commit(s.cwd, "lonely.txt")
    try FileManager.default.removeItem(atPath: s.cwd)
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("Push them first"), Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains(s.cwd))
  }

  @Test func deletesADoneSessionWhoseFolderIsGone() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    try FileManager.default.removeItem(atPath: s.cwd)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) == "")
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains(s.cwd) == false)
    #expect(try remoteBranch(origin) == "")
  }

  @Test func deletesASessionStartedFromAWorktreeThatIsGone() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let first = try sbd.worktreeSession(repo, branch: "haacked/first")
    let second = try sbd.client.call(
      "new", ["path": .string(first.cwd), "branch": "haacked/second"], as: SessionSummary.self)
    #expect(try sbd.deleteSession(first.id).status == 0)
    try FileManager.default.removeItem(atPath: second.cwd)
    let r = try sbd.deleteSession(second.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains(second.cwd) == false)
  }

  @Test func deletesASessionWhoseStoredRepoIsGoneThroughTheCheckoutThatListsItsWorktree() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let first = try sbd.worktreeSession(repo, branch: "haacked/first")
    let second = try sbd.worktreeSession(repo, branch: "haacked/second")
    try sbd.storeGoneRepo(second.id)
    try FileManager.default.removeItem(atPath: second.cwd)
    let r = try sbd.deleteSession(second.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains(second.cwd) == false)
    #expect(try sbd.client.sessions().map(\.id) == [first.id])
  }

  @Test func deletesASessionWhoseStoredRepoIsGoneWhileItsOwnWorktreeStillExists() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let only = try sbd.worktreeSession(repo, branch: "haacked/only")
    try sbd.storeGoneRepo(only.id)
    let r = try sbd.deleteSession(only.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(FileManager.default.fileExists(atPath: only.cwd) == false)
    #expect(try sbd.client.sessions().isEmpty)
  }

  @Test func refusesASessionWhoseStoredRepoIsGoneAndNoKnownCheckoutListsItsWorktree() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let only = try sbd.worktreeSession(repo, branch: "haacked/only")
    try sbd.storeGoneRepo(only.id)
    try FileManager.default.removeItem(atPath: only.cwd)
    let r = try sbd.deleteSession(only.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("no known checkout"))
    #expect(try sbd.client.sessions().map(\.id) == [only.id])
  }

  @Test func deletesADoneSessionWhoseFolderAndItsParentAreGone() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    try FileManager.default.removeItem(atPath: (s.cwd as NSString).deletingLastPathComponent)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) == "")
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains(s.cwd) == false)
    #expect(try remoteBranch(origin) == "")
  }

  @Test func keepsTheBranchOfADoneSessionWhoseFolderIsGoneAndWhoseBranchMovedOffThePRsHead() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    try sbd.commit(s.cwd, "b.txt")
    try FileManager.default.removeItem(atPath: s.cwd)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("not in its merged PR"))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) != "")
    #expect(try remoteBranch(origin) != "")
  }

  @Test func keepsTheRecordsOfOtherWorktreesWhoseFoldersAreGone() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, _) = try doneSessionWithRemote(github)
    let other = "\(sbd.home.path)/other-worktree"
    try sbd.git(repo, "worktree", "add", "-q", "-b", "other-branch", other)
    try FileManager.default.removeItem(atPath: other)
    try FileManager.default.removeItem(atPath: s.cwd)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains("other-worktree"))
  }

  @Test func deletesTheRemoteBranchOfTheRemoteTheBranchTracks() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    let fork = "\(sbd.home.path)/fork.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", fork)
    try sbd.git(repo, "remote", "add", "fork", fork)
    try sbd.git(repo, "config", "url.\(fork).insteadOf", "fork:")
    try sbd.git(s.cwd, "push", "-q", "-u", "fork", Self.mergedBranch)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try remoteBranch(fork) == "")
    #expect(try remoteBranch(origin) != "")
  }

  @Test func refusesAGoneWorktreeWhoseBranchRefWasDeletedWhileItsCommitsAreOnNoRemote() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.commit(s.cwd, "only-in-the-reflog.txt")
    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.git(repo, "update-ref", "-d", "refs/heads/haacked/feature")
    let r = try sbd.deleteSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("can't be checked"), Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains(s.cwd))
  }

  @Test func deletesADoneSessionWhoseFolderAndBranchAreBothGone() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    try removeFolderAndLocalBranch(sbd, repo, s)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try remoteBranch(origin) == "")
  }

  @Test func keepsTheRemoteBranchOfAnOpenPRWhenTheFolderAndBranchAreGone() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    github.change(122953) { $0["state"] = "OPEN" }
    try sbd.poll(all: true)
    try removeFolderAndLocalBranch(sbd, repo, s)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try remoteBranch(origin) != "")
  }

  @Test func refusesABranchWhoseTipIsBehindTheMergedPRsHead() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try mergedBranchSession(github)
    try sbd.commit(s.cwd, "b.txt")
    let head = try sbd.git(s.cwd, "rev-parse", "HEAD")
    try sbd.git(s.cwd, "reset", "-q", "--hard", "HEAD~1")
    github.change(122953) { $0["headRefOid"] = .string(head) }
    try sbd.poll(all: true)
    let r = try sbd.deleteSessionAndBranch(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("not in its merged PR"))
    #expect(try sbd.intact(s))
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) != "")
  }

  @Test func refusesALockedWorktreeWhoseFolderIsGoneBeforeStoppingAnything() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, _) = try doneSessionWithRemote(github)
    try sbd.git(repo, "worktree", "lock", s.cwd)
    try FileManager.default.removeItem(atPath: s.cwd)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("is a locked worktree"))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) != "")
  }

  @Test func refusesABranchCheckedOutElsewhereWhoseFolderIsGoneBeforeStoppingAnything() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, _) = try doneSessionWithRemote(github)
    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.git(repo, "worktree", "add", "-q", "-f", "\(sbd.home.path)/elsewhere", Self.mergedBranch)
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("checked out"))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.git(repo, "branch", "--list", Self.mergedBranch) != "")
  }

  // MARK: Every refusal of the Done delete leaves everything in place

  /// What the delete would remove: the record, the running claude, the worktree and its files, and both branches.
  private struct Placed: Equatable {
    var sessions: [String]
    var live: Bool?
    var worktreeFiles: [String]
    var localBranch: String
    var remoteBranch: String
  }

  private func placed(_ sbd: Instance, _ repo: String, _ s: SessionSummary, _ origin: String) throws -> Placed {
    Placed(
      sessions: try sbd.client.sessions().map(\.id),
      live: try? sbd.get(s.id).live,
      worktreeFiles: ((try? FileManager.default.contentsOfDirectory(atPath: s.cwd)) ?? []).sorted(),
      localBranch: try sbd.git(repo, "branch", "--list", "-v", Self.mergedBranch),
      remoteBranch: try remoteBranch(origin))
  }

  /// Deletes a Done session after `breakIt` makes one safety check fail, and expects the refusal to
  /// name `error` and to change nothing.
  private func refusesAndChangesNothing(
    _ error: String, _ breakIt: (Instance, String, SessionSummary, String) throws -> Void
  )
    throws
  {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    try breakIt(sbd, repo, s, origin)
    let before = try placed(sbd, repo, s, origin)
    #expect(before.sessions.contains(s.id))
    #expect(before.live == true)
    #expect(before.localBranch != "")
    #expect(before.remoteBranch != "")
    let r = try sbd.deleteDoneSession(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains(error), Comment(rawValue: r.stderr))
    #expect(try placed(sbd, repo, s, origin) == before)
  }

  /// `sb get` shows the other branch once the poller reads it. The delete still reads the
  /// session's own branch, so it deletes neither branch.
  @Test func refusesAnotherBranchThatThePollerRecorded() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    // The other branch is the head of #122896, which merged at its tip. So the only check that
    // refuses is whether the folder has the session's starting branch checked out.
    let other = "haacked/mcp-experiment-condition-ids"
    try sbd.git(s.cwd, "checkout", "-q", "-b", other)
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122896) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).branch == other)
    #expect(try sbd.get(s.id).pr?.number == 122896)
    let before = try placed(sbd, repo, s, origin)

    let r = try sbd.deleteDoneSession(s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("checked out"), Comment(rawValue: r.stderr))
    #expect(try placed(sbd, repo, s, origin) == before)
    #expect(try sbd.git(repo, "branch", "--list", other) != "")
  }

  @Test func deletesADoneSessionWhoseWorktreeAndBranchesExist() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s, origin) = try doneSessionWithRemote(github)
    let before = try placed(sbd, repo, s, origin)
    #expect(before.sessions == [s.id])
    #expect(!before.worktreeFiles.isEmpty)
    #expect(before.localBranch != "")
    #expect(before.remoteBranch != "")
    #expect(try sbd.deleteDoneSession(s.id).status == 0)
    let after = try placed(sbd, repo, s, origin)
    #expect(after.sessions.isEmpty)
    #expect(after.worktreeFiles.isEmpty)
    #expect(after.localBranch == "")
    #expect(after.remoteBranch == "")
  }

  @Test func leavesEverythingWhenTheWorktreeHasUncommittedFiles() throws {
    try refusesAndChangesNothing("uncommitted files") { _, _, s, _ in
      try "x".write(toFile: "\(s.cwd)/dirty.txt", atomically: true, encoding: .utf8)
    }
  }

  @Test func leavesEverythingWhenTheBranchHasACommitAfterTheMerge() throws {
    try refusesAndChangesNothing("not in its merged PR") { sbd, _, s, _ in
      try sbd.commit(s.cwd, "later.txt")
      try sbd.git(s.cwd, "push", "-q", "origin", Self.mergedBranch)
    }
  }

  @Test func leavesEverythingWhenTheWorktreeHasACommitOnNoBranch() throws {
    try refusesAndChangesNothing("not on a pushed branch") { sbd, _, s, _ in
      try sbd.git(s.cwd, "checkout", "-q", "--detach")
      try sbd.commit(s.cwd, "detached.txt")
    }
  }

  @Test func leavesEverythingWhenTheGoneWorktreeHasACommitOnNoBranch() throws {
    try refusesAndChangesNothing("Push them first") { sbd, _, s, _ in
      try sbd.git(s.cwd, "checkout", "-q", "--detach")
      try sbd.commit(s.cwd, "detached.txt")
      try FileManager.default.removeItem(atPath: s.cwd)
    }
  }

  @Test func leavesEverythingWhenTheWorktreeIsLocked() throws {
    try refusesAndChangesNothing("is a locked worktree") { sbd, repo, s, _ in
      try sbd.git(repo, "worktree", "lock", "--reason", "Supacode", s.cwd)
    }
  }

  @Test func leavesEverythingWhenAnotherSessionRunsInTheWorktree() throws {
    try refusesAndChangesNothing("also runs in") { sbd, repo, s, _ in
      _ = try sbd.worktreeSession(repo, branch: Self.mergedBranch)
    }
  }

  @Test func leavesEverythingWhenTheWorktreeIsDetachedFromTheBranch() throws {
    try refusesAndChangesNothing("checked out") { sbd, _, s, _ in
      try sbd.git(s.cwd, "checkout", "-q", "--detach", "HEAD~1")
    }
  }

  @Test func leavesEverythingWhenTheSessionHasAnOpenToDo() throws {
    try refusesAndChangesNothing("open to-do") { sbd, _, s, _ in
      _ = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    }
  }

  // MARK: To-dos

  private func paneRuns(_ t: Terminals, _ pane: String) throws -> Bool {
    try runCommand(t.tmux, ["-S", t.socket, "has-session", "-t", "=\(pane)"]).status == 0
  }

  /// Without --worktree, rm sends SIGTERM to claude once its checks pass. Only a claude that still runs after the
  /// refusal shows that the check came first.
  @Test(arguments: [false, true])
  func rmRefusesAnOpenToDoNamesItAndChangesNothing(worktree: Bool) throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let first = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    let second = try sbd.addTodo(s.id, "close the incident")
    let pid = try #require(try sbd.waitFor(s.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    let terminals = try sbd.client.terminals(s.id)
    try #require(try paneRuns(terminals, terminals.claude))
    try #require(try paneRuns(terminals, terminals.shell))

    let r = try sbd.run(["rm", s.id] + (worktree ? ["--worktree"] : []))

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(s.id) has an open to-do"), Comment(rawValue: r.stderr))
    for todo in [first, second] {
      #expect(r.stderr.contains(todo.id), Comment(rawValue: r.stderr))
      #expect(r.stderr.contains("\"\(todo.text)\""), Comment(rawValue: r.stderr))
    }
    #expect(r.stderr.contains("sb note \(s.id) --resolve"), Comment(rawValue: r.stderr))
    #expect(
      r.stderr.contains("sb rm \(s.id)\(worktree ? " --worktree" : "") --resolve"), Comment(rawValue: r.stderr))
    sleep(1)
    #expect(Processes.exists(pid))
    #expect(try paneRuns(terminals, terminals.claude))
    #expect(try paneRuns(terminals, terminals.shell))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.isOpenTodo(s.id, first.id))
    #expect(try sbd.isOpenTodo(s.id, second.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  /// Claude can write a to-do whose text holds terminal escapes. The refusal prints them escaped.
  @Test func rmRefusalEscapesTheToDoText() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    _ = try sbd.addTodo(s.id, "done\u{1b}[2Kremoved", by: .claude)

    let r = try sbd.run(["rm", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("done\\u{1b}[2Kremoved"), Comment(rawValue: r.stderr))
    #expect(!r.stderr.contains("\u{1b}"), Comment(rawValue: r.stderr))
  }

  /// Two to-dos need two --resolve flags, and each one counts.
  @Test func rmResolveWithEveryOpenIdRemovesTheSessionAndKeepsTheRecord() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let first = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    let second = try sbd.addTodo(s.id, "close the incident", by: .claude)
    try sbd.addPlainNote(s.id, "stacked on #1190")

    let r = try sbd.run(["rm", s.id, "--worktree", "--resolve", first.id, "--resolve", second.id])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    let rows = try sbd.resolvedTodos()
    #expect(Set(rows.compactMap { $0["note"]?.string }) == [first.id, second.id])
    #expect(rows.count == 2)
    for row in rows {
      #expect(row["session"]?.string == s.id, Comment(rawValue: row.text))
      #expect(row["name"]?.string == s.name, Comment(rawValue: row.text))
      #expect(row["branch"]?.string == "haacked/feature", Comment(rawValue: row.text))
      #expect(row["how"]?.string == "resolved and deleted the session", Comment(rawValue: row.text))
    }
    #expect(rows.first { $0["note"]?.string == first.id }?["text"]?.string == first.text)
    #expect(rows.first { $0["note"]?.string == second.id }?["text"]?.string == second.text)
  }

  /// `resolve` must name exactly the session's open to-dos. Each other list refuses before anything stops.
  /// It resolves nothing.
  @Test func rmRefusesAResolveListThatIsNotTheOpenToDosAndResolvesNothing() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let first = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    let second = try sbd.addTodo(s.id, "close the incident")
    let plain = try sbd.addPlainNote(s.id, "stacked on #1190")
    let resolved = try sbd.addTodo(s.id, "update the runbook")
    try sbd.resolveTodo(s.id, resolved.id)
    let other = try sbd.new(name: "other")
    let elsewhere = try sbd.addTodo(other.id, "ping Ana")
    let rowsBefore = try sbd.resolvedTodoIds()
    let open: [JSON] = [.string(first.id), .string(second.id)]
    // shortId never uses 0. Therefore n00000 names no note.
    let lists: [(String, JSON)] = [
      ("a subset of the open ids", [.string(first.id)]),
      ("an unknown id", .array(open + ["n00000"])),
      ("a plain note's id", .array(open + [.string(plain.id)])),
      ("a resolved to-do's id", .array(open + [.string(resolved.id)])),
      ("another session's to-do", .array(open + [.string(elsewhere.id)])),
      ("another session's to-do in place of one", [.string(first.id), .string(elsewhere.id)]),
      ("a boolean", true),
    ]

    for (what, resolve) in lists {
      let message = failure(sbd, "rm", ["session": .string(s.id), "worktree": true, "resolve": resolve])

      #expect(message != "no error", "\(what)")
      #expect(try sbd.intact(s), "\(what)")
      #expect(try sbd.get(s.id).live, "\(what)")
      #expect(try sbd.isOpenTodo(s.id, first.id), "\(what)")
      #expect(try sbd.isOpenTodo(s.id, second.id), "\(what)")
      #expect(try sbd.storedNote(s.id, plain.id) == plain, "\(what)")
      #expect(try sbd.isOpenTodo(other.id, elsewhere.id), "\(what)")
      #expect(try sbd.resolvedTodoIds() == rowsBefore, "\(what)")
    }
  }

  /// The dialog sends the ids it showed. A to-do that arrived after that is not among them.
  @Test func aToDoAddedAfterTheIdsWereReadBlocksTheDelete() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let first = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    let shown = try sbd.get(s.id).openTodos.map(\.id)
    #expect(shown == [first.id])
    let late = try sbd.addTodo(s.id, "close the incident")

    let r = try sbd.run(["rm", s.id, "--worktree"] + shown.flatMap { ["--resolve", $0] })

    #expect(r.status != 0)
    #expect(r.stderr.contains(late.id), Comment(rawValue: r.stderr))
    #expect(r.stderr.contains("\"close the incident\""), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
    #expect(try sbd.isOpenTodo(s.id, first.id))
    #expect(try sbd.isOpenTodo(s.id, late.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  /// The stub writes notes.txt when SIGTERM arrives. Only the check after claude exits refuses.
  @Test(arguments: [false, true])
  func aRefusalForAnotherReasonLeavesTheToDoOpen(writtenAsClaudeStops: Bool) throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    if writtenAsClaudeStops {
      try sbd.sb("send", s.id, "onterm notes.txt")
      try sbd.waitFor(s.id, "the reply") { $0.lastReply == "I'll write notes.txt when I stop." }
    } else {
      try "x".write(toFile: "\(s.cwd)/notes.txt", atomically: true, encoding: .utf8)
    }

    let r = try sbd.run(["rm", s.id, "--worktree", "--resolve", todo.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("uncommitted"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  @Test func aStoreThatCannotDeleteTheSessionLeavesTheToDoOpenAndWritesNoRecord() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    try sbd.block("DELETE", on: "sessions")

    let r = try sbd.run(["rm", s.id, "--worktree", "--resolve", todo.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("store is read-only"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  /// A resolve list must hold only note ids. Dropping the other elements would leave exactly the open ids.
  @Test func rmRefusesAResolveThatIsNotAListOfIds() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let first = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    let second = try sbd.addTodo(s.id, "close the incident")
    let lists: [(String, JSON)] = [
      ("the open ids and a number", [.string(first.id), .string(second.id), 1]),
      ("the open ids and null", [.string(first.id), .string(second.id), .null]),
      ("one id as a string", .string(first.id)),
    ]

    for (what, resolve) in lists {
      let message = failure(sbd, "rm", ["session": .string(s.id), "worktree": true, "resolve": resolve])

      #expect(message.contains("resolve is a list of note ids"), "\(what): \(message)")
      #expect(try sbd.intact(s), "\(what)")
      #expect(try sbd.isOpenTodo(s.id, first.id), "\(what)")
      #expect(try sbd.isOpenTodo(s.id, second.id), "\(what)")
      #expect(try sbd.resolvedTodos().isEmpty, "\(what)")
    }
  }

  /// The check before the stop runs the inserts too. A store that refuses the record therefore refuses the delete first.
  @Test func aStoreThatCannotRecordTheResolutionRefusesBeforeAnythingStops() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    try sbd.block("INSERT", on: "resolved_todos")

    let r = try sbd.run(["rm", s.id, "--worktree", "--resolve", todo.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("store is read-only"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.isOpenTodo(s.id, todo.id))
  }

  @Test func rmResolveInsideClaudeCodeExitsWithAnErrorAndChangesNothing() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    let r = try sbd.run(["rm", s.id, "--worktree", "--resolve", todo.id], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  @Test func rmRequestWithResolveByClaudeRefusesAndChangesNothing() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    let message = failure(
      sbd, "rm",
      ["session": .string(s.id), "worktree": true, "resolve": [.string(todo.id)], "by": "claude"])

    #expect(message.contains("Only you can resolve a to-do."), Comment(rawValue: message))
    #expect(try sbd.intact(s))
    #expect(try sbd.get(s.id).live)
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  @Test func rmRemovesASessionWhoseNotesArePlainOrResolvedToDos() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    try sbd.addPlainNote(s.id, "stacked on #1190")
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    try sbd.resolveTodo(s.id, todo.id)

    let r = try sbd.deleteSession(s.id)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.resolvedTodos().map { $0["how"]?.string } == ["resolved"])
  }
}
