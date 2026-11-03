import Foundation
import SwitchboardCore
import Testing

/// The head branch of the recorded PR 122953 in PostHog/posthog.
private let branch = "haacked/cdp-dlq-breaker-counts-lookups"
private let ready = "#122953 merged; ready for `sb cleanup`"
private let archive = "#122953 merged; archive the worktree"
private let removed = "#122953 merged; worktree and branch removed"
/// The messages that name a PR that did not merge.
private let notMerged = ["not merged", "without merging", "no merged PR"]

extension Instance {
  fileprivate func cleanup(_ id: String) throws -> CommandResult { try run(["cleanup", id, "--json"]) }

  fileprivate func hasBranch(_ repo: String, _ name: String) throws -> Bool {
    try runCommand("/usr/bin/git", ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0
  }

  fileprivate func count(_ kind: String, _ id: String) throws -> Int { try events(id).filter { $0.kind == kind }.count }
}

/// What `sb cleanup` would remove or change: the record, the running claude, the worktree and its
/// files, the branch, and the event log's `cleanup` events.
private struct Placed: Equatable {
  var sessions: [String]
  var live: Bool?
  var worktreeFiles: [String]
  var worktrees: String
  var localBranch: String
  var cleanups: Int
}

private func placed(_ sbd: Instance, _ repo: String, _ s: SessionSummary, ref: String) throws -> Placed {
  Placed(
    sessions: try sbd.client.sessions().map(\.id).sorted(),
    live: try? sbd.get(s.id).live,
    worktreeFiles: ((try? FileManager.default.contentsOfDirectory(atPath: s.cwd)) ?? []).sorted(),
    worktrees: try sbd.git(repo, "worktree", "list", "--porcelain"),
    localBranch: try sbd.git(repo, "branch", "--list", "-v", ref),
    cleanups: try sbd.count("cleanup", s.id))
}

private func tmuxHas(_ t: Terminals, _ target: String) throws -> Bool {
  try runCommand(t.tmux, ["-S", t.socket, "has-session", "-t", "=\(target)"]).status == 0
}

@Suite(.timeLimit(.minutes(2))) struct WorktreeCleanupTests {
  /// A session in a worktree that sbd made on PR 122953's branch, after a commit. GitHub reports
  /// the PR with `state` and with the branch tip as its head commit, and the poller has counted
  /// the folder.
  private func finishedSession(_ github: FakeGitHub, state: String = "MERGED") throws -> (
    Instance, String, SessionSummary
  ) {
    let sbd = try Instance.withGitHub(github)
    let repo = try Repos.create("\(sbd.home.path)/posthog", origin: "https://github.com/PostHog/posthog.git")
    let s = try sbd.worktreeSession(repo, branch: branch)
    try sbd.commit(s.cwd, "a.txt")
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = .string(state)
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    return (sbd, repo, s)
  }

  // MARK: The poller's cleanup checks

  @Test func mergedPRWithACleanWorktreeIsReadyForCleanup() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)

    let after = try sbd.get(s.id)

    #expect(after.cleanup == CleanupStatus(state: .ready))
    #expect(after.state == .done)
    #expect(after.reason == ready)
  }

  @Test func countOfAReadyWorktreeCarriesANullCleanup() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)

    let count = try #require(try sbd.events(s.id).last { $0.kind == "worktree" })

    #expect(count.data["cleanup"] == .null)
    #expect(count.data["dirty"] == 0)
  }

  @Test func pollRecordsNoCountWhenNothingChanged() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    let counts = try sbd.count("worktree", s.id)

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.count("worktree", s.id) == counts)
  }

  /// Only `cleanup` changes, because the folder stays clean and present.
  @Test func commitAfterTheMergeBlocksCleanupWithAReason() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    try sbd.commit(s.cwd, "b.txt")

    try sbd.poll(all: true)

    let after = try sbd.get(s.id)
    #expect(after.cleanup?.state == .blocked)
    #expect(after.cleanup?.reason?.isEmpty == false)
    #expect(after.state == .done)
    #expect(after.reason == archive)
    let count = try sbd.events(s.id).last { $0.kind == "worktree" }
    #expect(count?.data["cleanup"]?.string == after.cleanup?.reason)
  }

  @Test func undoingTheCommitAfterTheMergeMakesCleanupReadyAgain() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    try sbd.commit(s.cwd, "b.txt")
    try sbd.poll(all: true)
    try sbd.git(s.cwd, "reset", "-q", "--hard", "HEAD~1")

    try sbd.poll(all: true)

    let after = try sbd.get(s.id)
    #expect(after.cleanup == CleanupStatus(state: .ready))
    #expect(after.reason == ready)
  }

  @Test func openPRHasNoCleanupStatus() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github, state: "OPEN")

    #expect(try sbd.get(s.id).cleanup == nil)
  }

  @Test func sessionBeforeThePollerCountedHasNoCleanupStatus() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let repo = try Repos.create("\(sbd.home.path)/posthog", origin: "https://github.com/PostHog/posthog.git")

    let s = try sbd.worktreeSession(repo, branch: branch)

    #expect(try sbd.get(s.id).cleanup == nil)
  }

  // MARK: sb cleanup

  @Test func cleanupAnswersWithTheSessionTheWorktreeAndTheBranch() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)

    let r = try sbd.cleanup(s.id)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let json = try #require(JSON.parse(r.stdout))
    #expect(json["cleaned"]?.string == s.id)
    #expect(json["worktree"]?.string == s.cwd)
    #expect(json["branch"]?.string == branch)
  }

  @Test func cleanupRemovesTheWorktreeAndTheLocalBranch() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)

    #expect(try sbd.cleanup(s.id).status == 0)

    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try !sbd.git(repo, "worktree", "list", "--porcelain").contains(s.cwd))
    #expect(try !sbd.hasBranch(repo, branch))
  }

  @Test func cleanupKeepsTheSessionInDone() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)

    #expect(try sbd.cleanup(s.id).status == 0)

    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    let after = try sbd.get(s.id)
    #expect(after.state == .done)
    #expect(after.reason == removed)
    #expect(after.cleanup?.state == .removed)
  }

  @Test func cleanupRecordsACleanupEvent() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)

    #expect(try sbd.cleanup(s.id).status == 0)

    let recorded = try sbd.events(s.id).filter { $0.kind == "cleanup" }
    #expect(recorded.count == 1)
    #expect(recorded.first?.data["worktree"]?.string == s.cwd)
    #expect(recorded.first?.data["branch"]?.string == branch)
    #expect(recorded.first?.data["branch_removed"] == .bool(true))
  }

  /// The branch moves after `git worktree remove`, so the delete refuses and the branch stays.
  @Test func keepsTheBranchWhenACommitLandsAfterTheWorktreeIsRemoved() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    try sbd.runAfterWorktreeRemoval(repo, "git -C \"$REPO\" branch -f \(branch) main")
    // The restart drops the polled PR, so poll it again.
    try sbd.poll(all: true)

    let r = try sbd.cleanup(s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("kept \(branch)"))
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.hasBranch(repo, branch))
    #expect(try sbd.get(s.id).reason == "#122953 merged; worktree removed, kept \(branch)")
  }

  @Test func cleanupStopsClaudeAndClosesBothPanes() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    let terminals = try sbd.client.terminals(s.id)
    #expect(try tmuxHas(terminals, terminals.claude))

    #expect(try sbd.cleanup(s.id).status == 0)

    #expect(try sbd.get(s.id).live == false)
    #expect(try !tmuxHas(terminals, terminals.claude))
    #expect(try !tmuxHas(terminals, terminals.shell))
  }

  /// A folder that the user deleted by hand gets the same refusal as a cleaned-up one.
  @Test func sessionWhoseFolderIsGoneStartsNoPane() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop") { !$0.live }
    try FileManager.default.removeItem(atPath: s.cwd)

    for op in ["resume", "terminals"] {
      #expect(failure(sbd, op, ["session": .string(s.id)]).contains("is gone"), "\(op)")
    }
  }

  /// tmux would start a pane whose folder is gone in the home folder.
  @Test func cleanedUpSessionStartsNoPane() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    #expect(try sbd.cleanup(s.id).status == 0)

    for op in ["resume", "terminals"] {
      #expect(failure(sbd, op, ["session": .string(s.id)]).contains("cleaned up"), "\(op)")
    }
    #expect(try sbd.get(s.id).live == false)
  }

  @Test func cleanupOpAnswersLikeTheCommand() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)

    let json = try sbd.client.call("cleanup", ["session": .string(s.id)])

    #expect(json["cleaned"]?.string == s.id)
    #expect(try !sbd.hasBranch(repo, branch))
  }

  @Test func pollAfterCleanupDoesNotCountTheFolderAgain() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    #expect(try sbd.cleanup(s.id).status == 0)
    let counts = try sbd.count("worktree", s.id)

    try sbd.poll(all: true)
    try sbd.advanceClock(300_000)
    try sbd.poll()

    #expect(try sbd.count("worktree", s.id) == counts)
    #expect(try sbd.get(s.id).reason == removed)
  }

  @Test func removedStateSurvivesARestartOfSbd() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    #expect(try sbd.cleanup(s.id).status == 0)

    sbd.stopSbd()
    try sbd.startSbd()

    let after = try sbd.get(s.id)
    #expect(after.state == .done)
    #expect(after.reason == removed)
    #expect(after.cleanup?.state == .removed)
  }

  /// A restart forgets which folders the poller counted, so the poller must not count the removed
  /// folder as gone.
  @Test func pollAfterARestartDoesNotCountTheRemovedFolder() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    #expect(try sbd.cleanup(s.id).status == 0)
    let counts = try sbd.count("worktree", s.id)
    sbd.stopSbd()
    try sbd.startSbd()

    try sbd.poll(all: true)

    #expect(try sbd.count("worktree", s.id) == counts)
    #expect(try sbd.get(s.id).reason == removed)
    #expect(try sbd.get(s.id).cleanup?.state == .removed)
  }

  // MARK: Every refusal leaves the session, its folder, and its branch

  /// Runs `sb cleanup` on `s` and expects it to fail with one of `errors` in its message, or with
  /// any message when `errors` is empty, and to change nothing.
  private func expectRefusal(
    _ sbd: Instance, _ repo: String, _ s: SessionSummary, _ errors: [String], ref: String = branch
  ) throws {
    let before = try placed(sbd, repo, s, ref: ref)
    #expect(before.sessions.contains(s.id))
    #expect(before.localBranch != "")

    let r = try sbd.cleanup(s.id)

    #expect(r.status != 0)
    #expect(!r.stderr.isEmpty)
    if !errors.isEmpty {
      #expect(errors.contains { r.stderr.contains($0) }, Comment(rawValue: r.stderr))
    }
    #expect(try placed(sbd, repo, s, ref: ref) == before)
  }

  /// Makes a ready session fail one check, without a poll, so `sb cleanup` must run the check
  /// itself. Then it polls and returns the session as the poller sees it, which must not be ready.
  @discardableResult
  private func refusesAReadySession(
    _ errors: [String], _ breakIt: (Instance, String, SessionSummary) throws -> Void
  ) throws -> SessionSummary {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    #expect(try sbd.get(s.id).cleanup?.state == .ready)
    try breakIt(sbd, repo, s)

    try expectRefusal(sbd, repo, s, errors)

    try sbd.poll(all: true)
    let after = try sbd.get(s.id)
    #expect(after.cleanup?.state != .ready)
    #expect(after.cleanup?.state != .removed)
    return after
  }

  private func expectBlocked(_ s: SessionSummary, reason: String = archive) {
    #expect(s.cleanup?.state == .blocked)
    #expect(s.cleanup?.reason?.isEmpty == false)
    #expect(s.reason == reason)
  }

  @Test func refusesAnUntrackedFile() throws {
    let after = try refusesAReadySession(["uncommitted"]) { _, _, s in
      try "x".write(toFile: "\(s.cwd)/notes.txt", atomically: true, encoding: .utf8)
    }

    #expect(after.state == .needsYou)
    #expect(after.reason == "#122953 merged; commit or discard the uncommitted changes")
  }

  @Test func refusesAModifiedTrackedFile() throws {
    let after = try refusesAReadySession(["uncommitted"]) { _, _, s in
      try "changed".write(toFile: "\(s.cwd)/a.txt", atomically: true, encoding: .utf8)
    }

    #expect(after.state == .needsYou)
  }

  @Test func refusesAStagedFile() throws {
    try refusesAReadySession(["uncommitted"]) { sbd, _, s in
      try "x".write(toFile: "\(s.cwd)/staged.txt", atomically: true, encoding: .utf8)
      try sbd.git(s.cwd, "add", "staged.txt")
    }
  }

  @Test func refusesAnIgnoredFileThatNoBuildMakes() throws {
    let after = try refusesAReadySession(["no build makes again", ".env"]) { _, repo, s in
      try ".env\n".write(toFile: "\(repo)/.git/info/exclude", atomically: true, encoding: .utf8)
      try "SECRET=1".write(toFile: "\(s.cwd)/.env", atomically: true, encoding: .utf8)
    }

    #expect(after.cleanup?.reason?.contains(".env") == true)
  }

  /// The stub writes `.env` when SIGTERM arrives, which is after the first check passed. Only the
  /// check after the panes close can find it.
  @Test func refusesAnIgnoredFileThatClaudeWritesAsItStops() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    try ".env\n".write(toFile: "\(repo)/.git/info/exclude", atomically: true, encoding: .utf8)
    try sbd.sb("send", s.id, "onterm .env")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "I'll write .env when I stop." }
    let env = "\(s.cwd)/.env"
    #expect(!FileManager.default.fileExists(atPath: env))
    let terminals = try sbd.client.terminals(s.id)

    let r = try sbd.cleanup(s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains(".env"), Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().map(\.id).contains(s.id))
    #expect(FileManager.default.fileExists(atPath: env))
    #expect(try sbd.hasBranch(repo, branch))
    #expect(try sbd.count("cleanup", s.id) == 0)
    #expect(try !tmuxHas(terminals, terminals.claude))
    #expect(try !tmuxHas(terminals, terminals.shell))
  }

  /// A claude that has not exited could still write to the folder after the second check. The
  /// stub outlives the first 5 s wait and exits within the retry's wait. The retry finds no
  /// claude pane. Only the pid that the refusal kept makes it wait.
  @Test func refusesAClaudeThatHasNotExitedAfterTheWait() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    try sbd.sb("send", s.id, "linger 7")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "I'll linger 7 s when I stop." }
    let pid = try #require(try sbd.waitFor(s.id, "claude's pid") { $0.claudePid != nil }.claudePid)

    let r = try sbd.cleanup(s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("has not exited"), Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().map(\.id).contains(s.id))
    #expect(FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.hasBranch(repo, branch))
    #expect(try sbd.count("cleanup", s.id) == 0)
    #expect(Processes.exists(pid))

    let retry = try sbd.cleanup(s.id)

    #expect(retry.status == 0, Comment(rawValue: retry.stderr))
    #expect(!Processes.exists(pid))
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.count("cleanup", s.id) == 1)
  }

  @Test func waitsForAClaudeThatExitsWithinTheWait() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    try sbd.sb("send", s.id, "linger 2")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "I'll linger 2 s when I stop." }

    let r = try sbd.cleanup(s.id)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try !sbd.hasBranch(repo, branch))
  }

  @Test func cleanupDeletesTheIgnoredNamesThatConfigLists() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    try ".env\n.notes/\n".write(toFile: "\(repo)/.git/info/exclude", atomically: true, encoding: .utf8)
    try "SECRET=1".write(toFile: "\(s.cwd)/.env", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: "\(s.cwd)/.notes", withIntermediateDirectories: true)
    try "x".write(toFile: "\(s.cwd)/.notes/brief.md", atomically: true, encoding: .utf8)
    try sbd.restart(setting: "cleanupDeletes", to: [".env", ".notes"])

    try sbd.sb("cleanup", s.id)

    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  @Test(arguments: ["--assume-unchanged", "--skip-worktree"])
  func refusesAChangeThatGitStatusSkips(_ flag: String) throws {
    try refusesAReadySession(["git status skips"]) { sbd, _, s in
      try sbd.git(s.cwd, "update-index", flag, "a.txt")
      try "changed".write(toFile: "\(s.cwd)/a.txt", atomically: true, encoding: .utf8)
    }
  }

  @Test func removesIgnoredBuildOutput() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    try "node_modules/\n".write(toFile: "\(repo)/.git/info/exclude", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: "\(s.cwd)/web/node_modules/x", withIntermediateDirectories: true)
    try "x".write(toFile: "\(s.cwd)/web/node_modules/x/index.js", atomically: true, encoding: .utf8)

    try sbd.sb("cleanup", s.id)

    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  /// ruff ignores its cache with a `.gitignore` of `*` inside it, so git lists the cache's files.
  @Test func removesACacheThatIgnoresItself() throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    try FileManager.default.createDirectory(atPath: "\(s.cwd)/.ruff_cache/0.15.20", withIntermediateDirectories: true)
    try "*".write(toFile: "\(s.cwd)/.ruff_cache/.gitignore", atomically: true, encoding: .utf8)
    try "x".write(toFile: "\(s.cwd)/.ruff_cache/CACHEDIR.TAG", atomically: true, encoding: .utf8)
    try "x".write(toFile: "\(s.cwd)/.ruff_cache/0.15.20/a", atomically: true, encoding: .utf8)

    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).cleanup == CleanupStatus(state: .ready))

    try sbd.sb("cleanup", s.id)

    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  @Test func refusesACommitAfterTheMerge() throws {
    let after = try refusesAReadySession(["not in its merged PR"]) { sbd, _, s in
      try sbd.commit(s.cwd, "b.txt")
    }

    expectBlocked(after)
  }

  @Test func refusesABranchBehindTheMergedPRsHead() throws {
    let after = try refusesAReadySession(["not in its merged PR"]) { sbd, _, s in
      try sbd.git(s.cwd, "reset", "-q", "--hard", "HEAD~1")
    }

    expectBlocked(after)
  }

  @Test func refusesAnotherBranchAtTheMergedCommit() throws {
    let after = try refusesAReadySession(["checked out"]) { sbd, _, s in
      try sbd.git(s.cwd, "checkout", "-q", "-b", "haacked/other")
    }

    #expect(after.cleanup?.state != .ready)
  }

  @Test func refusesADetachedHeadAtTheMergedCommit() throws {
    let after = try refusesAReadySession(["checked out"]) { sbd, _, s in
      try sbd.git(s.cwd, "checkout", "-q", "--detach")
    }

    expectBlocked(after)
  }

  @Test func refusesALockedWorktree() throws {
    let after = try refusesAReadySession(["locked"]) { sbd, repo, s in
      try sbd.git(repo, "worktree", "lock", "--reason", "Supacode", s.cwd)
    }

    expectBlocked(after)
  }

  @Test func refusesAWorktreeThatAnotherSessionRunsIn() throws {
    let after = try refusesAReadySession(["also runs in"]) { sbd, repo, _ in
      _ = try sbd.worktreeSession(repo, branch: branch)
    }

    expectBlocked(after)
  }

  /// While a turn runs, the poller keeps its last cleanup result, so the reason says ready once it stops.
  /// `sb cleanup` refuses the running turn.
  @Test func refusesWhileATurnRuns() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    try sbd.sb("send", s.id, "slow 30")
    try sbd.waitFor("the turn to start") {
      try sbd.events(s.id).contains { $0.kind == "UserPromptSubmit" && $0.data["prompt"]?.string == "slow 30" }
    }

    try expectRefusal(sbd, repo, s, ["running a turn"])
    try sbd.poll(all: true)

    let after = try sbd.get(s.id)
    #expect(after.cleanup?.state == .ready)
    #expect(after.reason == "#122953 merged; ready for `sb cleanup` once it stops")
  }

  @Test func refusesAWorktreeWhoseFolderIsGone() throws {
    let after = try refusesAReadySession([]) { _, _, s in
      try FileManager.default.removeItem(atPath: s.cwd)
    }

    #expect(after.reason == "#122953 merged; its folder is gone")
  }

  @Test func refusesAFolderThatIsNoLongerAWorktreeOfTheRepo() throws {
    try refusesAReadySession(["is not a worktree of"]) { sbd, repo, s in
      try sbd.git(repo, "worktree", "remove", "--force", s.cwd)
      try FileManager.default.createDirectory(atPath: s.cwd, withIntermediateDirectories: true)
      try "x".write(toFile: "\(s.cwd)/mine.txt", atomically: true, encoding: .utf8)
    }
  }

  @Test(arguments: ["CLOSED", "OPEN"])
  func refusesAPRThatIsNotMerged(_ state: String) throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github, state: state)

    try expectRefusal(sbd, repo, s, notMerged)

    #expect(try sbd.get(s.id).cleanup?.state != .ready)
  }

  @Test func refusesAMergedPRThatClosedAfterThePollerSaidReady() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    github.change(122953) { $0["state"] = "CLOSED" }
    try sbd.poll(all: true)

    try expectRefusal(sbd, repo, s, notMerged)

    #expect(try sbd.get(s.id).cleanup?.state != .ready)
  }

  @Test func refusesASessionWithNoPR() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)

    try expectRefusal(sbd, repo, s, ["no merged PR"], ref: "haacked/feature")

    #expect(try sbd.hasBranch(repo, "haacked/feature"))
  }

  @Test func refusesAPlainFolderThatSbdDidNotMake() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/posthog", branch: branch)
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)

    try expectRefusal(sbd, s.cwd, s, ["didn't make"])

    #expect(FileManager.default.fileExists(atPath: "\(s.cwd)/.git"))
    expectBlocked(try sbd.get(s.id))
  }
}

/// `sb rm --worktree` deletes ignored files with the worktree, and refuses the changes that git status skips.
@Suite(.timeLimit(.minutes(2))) struct RemoveWorktreeLossTests {
  @Test func deletesIgnoredFilesWithTheWorktree() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try ".env\n".write(toFile: "\(repo)/.git/info/exclude", atomically: true, encoding: .utf8)
    try "SECRET=1".write(toFile: "\(s.cwd)/.env", atomically: true, encoding: .utf8)

    #expect(try sbd.deleteSession(s.id).status == 0)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  @Test(arguments: ["--assume-unchanged", "--skip-worktree"])
  func refusesAChangeThatGitStatusSkips(_ flag: String) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try "x".write(toFile: "\(s.cwd)/a.txt", atomically: true, encoding: .utf8)
    try sbd.git(s.cwd, "add", "a.txt")
    try sbd.git(
      s.cwd, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "a")
    try sbd.git(s.cwd, "push", "-q", "origin", "HEAD")
    try sbd.git(s.cwd, "update-index", flag, "a.txt")
    try "changed".write(toFile: "\(s.cwd)/a.txt", atomically: true, encoding: .utf8)

    let r = try sbd.deleteSession(s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("git status skips (1): a.txt"))
    #expect(try sbd.intact(s))
  }
}
