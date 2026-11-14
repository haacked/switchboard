import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"
/// The words of the git status that the worktree checks run.
private let statusRead = "status --porcelain"

/// `sb` in the background, for a request that a gate on the box holds. Its output goes to files in the home, so a
/// full pipe can't stall it.
final class BackgroundSb {
  private let process = Process()
  private let out: String
  private let err: String

  init(_ sbd: Instance, _ args: [String]) throws {
    let tag = UUID().uuidString.prefix(8)
    out = "\(sbd.home.path)/background-\(tag).out"
    err = "\(sbd.home.path)/background-\(tag).err"
    FileManager.default.createFile(atPath: out, contents: nil)
    FileManager.default.createFile(atPath: err, contents: nil)
    process.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sb")
    process.arguments = args
    process.environment = sbd.environment()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle(forWritingAtPath: out)
    process.standardError = FileHandle(forWritingAtPath: err)
    try process.run()
  }

  /// Whether sb exits within the seconds.
  func exits(within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds * Instance.timeoutScale)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    return !process.isRunning
  }

  /// Waits for sb to exit and returns what it printed.
  func result() -> CommandResult {
    process.waitUntilExit()
    return CommandResult(
      status: process.terminationStatus, stdout: (try? String(contentsOfFile: out, encoding: .utf8)) ?? "",
      stderr: (try? String(contentsOfFile: err, encoding: .utf8)) ?? "")
  }
}

extension Instance {
  /// A session on mini in a plain folder under the box's home, whose claude runs and has answered its first
  /// prompt.
  func liveOnHost(_ folder: String = "sb-box-repo") throws -> BoxSession {
    let s = try startOnHost(folder, prompt: "hello")
    try waitFor(s.id, "the first reply on the box", timeout: 30) { $0.lastReply == "Done: hello" }
    return BoxSession(
      id: s.id, claudeSessionId: s.claudeSessionId, cwd: s.cwd, pid: s.pid, repo: "\(boxHome)/\(folder)")
  }

  /// Stops the session's claude and waits until sbd reads it stopped.
  func stopOnHost(_ id: String) throws {
    try sb("stop", id)
    try waitFor(id, "claude to stop on the box") { $0.claudePid == nil && !$0.live }
  }
}

/// A change to a worktree that `rm --worktree` refuses on this Mac, and a text of that refusal.
enum WorktreeFault: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case untrackedFile = "an untracked file"
  case stagedFile = "a staged file"
  case assumeUnchanged = "a change that assume-unchanged hides"
  case skipWorktree = "a change that skip-worktree hides"
  case unpushedCommit = "a commit on no pushed branch"
  case detachedCommit = "a commit on a detached HEAD"
  case locked = "a lock"
  case notAWorktree = "a folder that is no longer a worktree of the repo"

  var testDescription: String { rawValue }

  /// A text of the refusal on this Mac.
  var refusal: String {
    switch self {
    case .untrackedFile, .stagedFile: "uncommitted"
    case .assumeUnchanged, .skipWorktree: "git status skips"
    case .unpushedCommit, .detachedCommit: "not on a pushed branch"
    case .locked: "locked worktree"
    case .notAWorktree: "is not a worktree of"
    }
  }

  /// Makes the change in the worktree at `cwd` of `repo`, whose branch is `branch`. git runs on this Mac, which is
  /// also the box.
  func apply(_ sbd: Instance, cwd: String, repo: String, branch: String) throws {
    switch self {
    case .untrackedFile:
      try "x".write(toFile: "\(cwd)/notes.txt", atomically: true, encoding: .utf8)
    case .stagedFile:
      try "x".write(toFile: "\(cwd)/staged.txt", atomically: true, encoding: .utf8)
      try sbd.git(cwd, "add", "staged.txt")
    case .assumeUnchanged, .skipWorktree:
      try sbd.commit(cwd, "a.txt")
      try sbd.git(cwd, "push", "-q", "origin", branch)
      try sbd.git(cwd, "update-index", self == .assumeUnchanged ? "--assume-unchanged" : "--skip-worktree", "a.txt")
      try "changed".write(toFile: "\(cwd)/a.txt", atomically: true, encoding: .utf8)
    case .unpushedCommit:
      try sbd.commit(cwd, "a.txt")
    case .detachedCommit:
      try sbd.git(cwd, "checkout", "-q", "--detach")
      try sbd.commit(cwd, "lonely.txt")
    case .locked:
      try sbd.git(repo, "worktree", "lock", cwd)
    case .notAWorktree:
      try sbd.git(repo, "worktree", "remove", "--force", cwd)
      try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
      try "x".write(toFile: "\(cwd)/mine.txt", atomically: true, encoding: .utf8)
    }
  }
}

/// The text with the session's id, folder, and repo replaced by names that do not depend on the site, so a refusal
/// on the box and one on this Mac compare as text.
private func placeholders(_ text: String, id: String, cwd: String, repo: String) -> String {
  var out = text
  for (value, name) in [(cwd, "<cwd>"), (real(cwd), "<cwd>"), (repo, "<repo>"), (real(repo), "<repo>"), (id, "<id>")]
  where !value.isEmpty {
    out = out.replacingOccurrences(of: value, with: name)
  }
  return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `sb rm`, `sb rm --worktree`, and `sb rm --done` of a session on a host. sbd runs the local checks on the host
/// and refuses when any of them got no answer. Each refusal here checks that nothing was removed or signalled on
/// the box and that this Mac ran nothing for the session.
@Suite(.blocking(timeLimit: .seconds(180))) struct RemoteRemovalTests {
  /// A remote session in a worktree of a box repo whose main is pushed, after its first reply.
  private func cleanWorktree(_ sbd: Instance, branch: String = "haacked/remote") throws -> (
    Instance.BoxSession, String
  ) {
    let (_, origin) = try sbd.makeBoxRepoWithOrigin()
    return (try sbd.startBoxWorktree(branch: branch), origin)
  }

  /// Runs the removal, expects it to fail, and expects the state of the box, the store, and sbd unchanged.
  private func expectRefusal(
    _ sbd: Instance, _ s: Instance.BoxSession, origin: String? = nil, _ args: [String], saying text: String? = nil
  ) throws {
    let before = try sbd.removalState(s, origin: origin)

    let r = try sbd.run(args)

    #expect(r.status != 0, "sb \(args.joined(separator: " ")) succeeded: \(r.stdout)")
    if let text { #expect(r.stderr.contains(text), "\(r.stderr)") }
    #expect(try sbd.removalState(s, origin: origin) == before)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  // MARK: rm --worktree removes everything on the box

  @Test func removingTheWorktreeOfACleanRemoteSessionRemovesTheWorktreeTheSessionAndItsPanes() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, _) = try cleanWorktree(sbd)
    let listed = real(s.cwd)

    let r = try sbd.run("rm", s.id, "--worktree")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    let worktrees = try sbd.git(s.repo, "worktree", "list", "--porcelain")
    #expect(!worktrees.contains(listed) && !worktrees.contains(s.cwd), "\(worktrees)")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.boxTmuxSessions().isEmpty)
    #expect(try sbd.git(s.repo, "branch", "--list", "haacked/remote") != "", "rm --worktree keeps the branch")
    #expect(!sbd.boxTranscripts(s.claudeSessionId).isEmpty, "the removal keeps the transcript")
  }

  @Test func removingTheWorktreeOfARemoteSessionRemovesItsLauncherFolderOnTheBoxAndRecordsTheRemoval() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, _) = try cleanWorktree(sbd)
    try #require(FileManager.default.fileExists(atPath: "\(sbd.boxSessionFolder(s.id))/claude.sh"))
    let other = try sbd.liveOnHost("other-folder")

    let r = try sbd.run("rm", s.id, "--worktree")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: sbd.boxSessionFolder(s.id)))
    #expect(FileManager.default.fileExists(atPath: sbd.boxSessionFolder(other.id)), "another session's folder stays")
    #expect(try sbd.removedHostSessions() == [s.id])
  }

  @Test func removingTheWorktreeStopsTheClaudeOnTheBox() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, _) = try cleanWorktree(sbd)

    let r = try sbd.run("rm", s.id, "--worktree")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!sbd.runs(s.pid))
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac")
  }

  @Test func aRemovalOnTheBoxLeavesNoLineOfTheSessionInTheMacsMachineLog() throws {
    let sbd = try Instance.remoteForRemoval()
    // A local session shows that the log records a session's calls at all.
    let local = try sbd.new()
    _ = try sbd.waitForMachineCall("the new-session call of the local session") {
      $0.runs("tmux") && $0.has("new-session") && $0.has("\(local.id)-claude")
    }
    let (s, _) = try cleanWorktree(sbd)

    let r = try sbd.run("rm", s.id, "--worktree")
    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    #expect(r.status == 0, "\(r.stderr)")
    let named = try sbd.macCalls(for: s)
    #expect(named.isEmpty, "this Mac ran \(named.count) calls for the removal, first: \(named.prefix(3))")
  }

  // MARK: Plain rm

  @Test func plainRmOfALiveRemoteSessionStopsItsClaudeOnTheBoxAndRemovesTheSession() throws {
    let sbd = try Instance.remote()
    let s = try sbd.liveOnHost()

    let r = try sbd.run("rm", s.id)

    #expect(r.status == 0, "\(r.stderr)")
    try sbd.waitFor("the claude on the box to exit") { !sbd.runs(s.pid) }
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.boxTmuxSessions().isEmpty)
    #expect(FileManager.default.fileExists(atPath: s.cwd), "plain rm leaves the folder")
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  @Test func plainRmOfARemoteSessionRemovesItsLauncherFolderOnTheBoxAndRecordsTheRemoval() throws {
    let sbd = try Instance.remote()
    let s = try sbd.liveOnHost()
    try #require(FileManager.default.fileExists(atPath: sbd.boxSessionFolder(s.id)))

    let r = try sbd.run("rm", s.id)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: sbd.boxSessionFolder(s.id)))
    #expect(try sbd.removedHostSessions() == [s.id])
  }

  @Test func plainRmOfAStoppedRemoteSessionRemovesItAndRecordsTheRemoval() throws {
    let sbd = try Instance.remote()
    let s = try sbd.liveOnHost()
    try sbd.stopOnHost(s.id)

    let r = try sbd.run("rm", s.id)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.boxTmuxSessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: sbd.boxSessionFolder(s.id)))
    #expect(try sbd.removedHostSessions() == [s.id])
  }

  /// A local session's removal writes nothing to `removed_host_sessions`.
  @Test func plainRmOfALocalSessionRecordsNoRemovedHostSession() throws {
    let sbd = try Instance.remote()
    let local = try sbd.new()

    try sbd.sb("rm", local.id)

    #expect(try sbd.removedHostSessions().isEmpty)
    #expect(try sbd.removedHostSessions("").isEmpty)
  }

  @Test func plainRmWithTheLinkDownRefusesWithTheReasonAndKeepsTheSessionAndItsClaude() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    try sbd.connectHost()
    let s = try sbd.liveOnHost()
    try sbd.dropLinkAndRefuse(refusal)

    try expectRefusal(sbd, s, ["rm", s.id], saying: "mini is not connected")

    #expect(sbd.runs(s.pid))
  }

  /// The link is connected, but sbd has not read the host's spool on this connection, so the session reads
  /// `.unknown`: sbd can't say whether its claude runs. The removal must not forget a session whose claude may
  /// still run on the host. It may refuse, or wait for the reconcile and then stop claude, but it never forgets
  /// the session while the host is unread.
  @Test func plainRmBeforeTheReconcileFinishedNeverForgetsASessionWhoseClaudeMayRun() throws {
    let sbd = try Instance.remoteWithGates()
    let s = try sbd.liveOnHost()
    let before = try sbd.removalState(s)
    let first = try #require(try sbd.sshStubPid(Instance.boxDestination))
    try sbd.holdBoxGate(.spoolRead)
    try sbd.dropLink("mini")
    try sbd.waitFor("a new master") { try sbd.sshStubPid(Instance.boxDestination).map { $0 != first } ?? false }
    try sbd.waitFor("the reconcile to reach the spool read", timeout: 45) { sbd.boxGateReached(.spoolRead) }

    let rm = try BackgroundSb(sbd, ["rm", s.id])
    var forgotWhileUnread = false
    var refusedInTime = false
    // A removal that waits for the reconcile runs this loop to its end, so the window does not scale on CI. A
    // removal that does not wait finishes well within it, and a forgotten session fails the checks below too.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !refusedInTime {
      if !(try sbd.client.sessions().map(\.id).contains(s.id)) { forgotWhileUnread = true }
      refusedInTime = rm.exits(within: 0.2)
    }
    try sbd.releaseBoxGate(.spoolRead)
    let r = rm.result()

    #expect(!forgotWhileUnread, "sbd forgot \(s.id) while it could not read the host")
    if refusedInTime || r.status != 0 {
      #expect(r.status != 0, "rm finished while the reconcile was held: \(r.stdout)")
      #expect(try sbd.removalState(s) == before)
    } else {
      // rm waited for the reconcile, then removed the session with its claude stopped.
      try sbd.waitFor("the claude on the box to exit") { !sbd.runs(s.pid) }
      #expect(try sbd.client.sessions().isEmpty)
    }
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  /// The host's pane and process read gets no answer, so sbd clears the host's snapshot and the session reads
  /// `.unknown` though the link reconnects. The removal refuses and leaves the claude running.
  @Test func plainRmWhileTheHostsPaneReadGetsNoAnswerRefusesAndKeepsTheSessionAndItsClaude() throws {
    let sbd = try Instance.remote(boxBin: true)
    try sbd.installBoxPsGate()
    let s = try sbd.liveOnHost()
    let before = try sbd.removalState(s)
    sbd.hold("ps-gate")
    try? FileManager.default.removeItem(atPath: sbd.gate("ps-waiting"))
    try sbd.waitFor("a pane read to reach the box's ps") {
      FileManager.default.fileExists(atPath: sbd.gate("ps-waiting"))
    }
    try sbd.waitFor(s.id, "the session to read unknown", timeout: 30) { $0.claudePid == nil }

    let r = try sbd.run("rm", s.id)
    try sbd.release("ps-gate")

    #expect(r.status != 0, "rm removed a session whose claude sbd could not read: \(r.stdout)")
    #expect(try sbd.removalState(s) == before)
    #expect(sbd.runs(s.pid))
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  @Test func plainRmOfARemoteSessionWithAnOpenToDoKeepsItsClaudeAndItsLauncherFolder() throws {
    let sbd = try Instance.remote()
    let s = try sbd.liveOnHost()
    try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    try expectRefusal(sbd, s, ["rm", s.id], saying: "to-do")

    #expect(sbd.runs(s.pid))
  }

  @Test func plainRmWhenTheStoreCannotDeleteTheSessionKeepsItsClaudeAndItsLauncherFolder() throws {
    let sbd = try Instance.remote()
    let s = try sbd.liveOnHost()
    try sbd.block("DELETE", on: "sessions")

    try expectRefusal(sbd, s, ["rm", s.id], saying: "store is read-only")

    #expect(sbd.runs(s.pid))
  }

  // MARK: A host that left config.json

  /// sbd can't reach a host that config.json no longer lists, so it can't stop anything there. A session whose
  /// claude had stopped on record can still be forgotten, and nothing runs on this Mac or reaches the host.
  @Test func plainRmOfAStoppedSessionWhoseHostLeftTheConfigForgetsItAndRunsNothing() throws {
    let sbd = try Instance.remote()
    let s = try sbd.liveOnHost()
    try sbd.stopOnHost(s.id)
    try sbd.restart(setting: "hosts", to: [:])
    let masters = sbd.sshStubMasters().count
    let panes = try sbd.boxTmuxSessions()

    let r = try sbd.run("rm", s.id)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.removedHostSessions() == [s.id])
    #expect(sbd.sshStubMasters().count == masters, "sbd connected to a host that config.json no longer lists")
    #expect(try sbd.boxTmuxSessions() == panes)
    #expect(sbd.stubArgs().isEmpty)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  @Test func removingTheWorktreeOfASessionWhoseHostLeftTheConfigRefusesAndRemovesNothing() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    try sbd.stopOnHost(s.id)
    try sbd.restart(setting: "hosts", to: [:])

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"], saying: "mini")

    #expect(FileManager.default.fileExists(atPath: s.cwd))
  }

  /// A choice that the plan does not make: the session's claude ran on record when its host left config.json, so
  /// it may still run there, and sbd can't stop it. sbd refuses rather than forget it.
  @Test func plainRmOfASessionThatRanWhenItsHostLeftTheConfigRefuses() throws {
    let sbd = try Instance.remote()
    let s = try sbd.liveOnHost()
    try sbd.restart(setting: "hosts", to: [:])

    let r = try sbd.run("rm", s.id)

    #expect(r.status != 0, "rm forgot a session whose claude may still run on mini")
    #expect(r.stderr.contains("mini"), "\(r.stderr)")
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.removedHostSessions().isEmpty)
    #expect(sbd.runs(s.pid))
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  // MARK: Each local refusal refuses the same way on the box

  @Test(arguments: WorktreeFault.allCases)
  func eachRefusalOfALocalWorktreeRefusesTheSameWayOnTheBox(_ fault: WorktreeFault) throws {
    let sbd = try Instance.remoteForRemoval()
    let localRepo = try sbd.repoWithOrigin()
    let local = try sbd.worktreeSession(localRepo, branch: "haacked/feature")
    let (s, origin) = try cleanWorktree(sbd, branch: "haacked/feature")
    try fault.apply(sbd, cwd: local.cwd, repo: localRepo, branch: "haacked/feature")
    try fault.apply(sbd, cwd: s.cwd, repo: s.repo, branch: "haacked/feature")
    let before = try sbd.removalState(s, origin: origin)

    let mac = try sbd.run("rm", local.id, "--worktree")
    let box = try sbd.run("rm", s.id, "--worktree")

    #expect(mac.status != 0 && mac.stderr.contains(fault.refusal), "this Mac: \(mac.stderr)")
    #expect(box.status != 0, "the box: \(box.stdout)")
    #expect(
      placeholders(box.stderr, id: s.id, cwd: s.cwd, repo: s.repo)
        == placeholders(mac.stderr, id: local.id, cwd: local.cwd, repo: localRepo))
    #expect(try sbd.removalState(s, origin: origin) == before)
    #expect(sbd.runs(s.pid), "the refusal stopped the box's claude")
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  @Test func aWorktreeThatAnotherRemoteSessionRunsInIsRefusedUntilThatSessionIsRemoved() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    let second = try sbd.newOnHost("~/sb-box-repo", "--branch", "haacked/remote")
    let secondId = try sbd.id(of: second)
    #expect(second["cwd"]?.string == s.cwd)
    try sbd.waitFor(secondId, "the second session's claude on the box", timeout: 30) { $0.claudePid != nil }

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"], saying: "also runs in")

    try sbd.sb("rm", secondId)
    #expect(try sbd.run("rm", s.id, "--worktree").status == 0)
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  /// A session on this Mac whose folder has the same path as the remote session's does not share it: the box's
  /// folder is another folder. The box is this Mac in these tests, so the local session's claude stops and its
  /// shell pane closes first, as their processes would otherwise use the folder.
  @Test func aLocalSessionInAFolderOfTheSamePathDoesNotShareTheRemoteWorktree() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, _) = try cleanWorktree(sbd)
    let local = try sbd.client.call(
      "new", ["path": .string(s.cwd), "name": "mac"], as: SessionSummary.self)
    try sbd.sb("stop", local.id)
    try sbd.waitFor(local.id, "the local claude to stop") { $0.claudePid == nil && !$0.live }
    let tmux = try #require(findExecutable("tmux"))
    try runCommand(tmux, ["-S", sbd.home.tmuxSocket, "kill-session", "-t", "=\(local.id)-shell"])

    let r = try sbd.run("rm", s.id, "--worktree")

    #expect(!r.stderr.contains("also runs in"), "\(r.stderr)")
    #expect(r.status == 0, "\(r.stderr)")
    #expect(try sbd.client.sessions().map(\.id) == [local.id])
  }

  /// The box is this Mac, so a process started here with its working folder in the worktree stands in for a
  /// program that the user left running on the box. sbd does not signal it.
  @Test func aProcessThatUsesTheWorktreeOnTheBoxRefusesTheRemovalAndKeepsTheWorktree() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    let user = try sbd.startProcess(in: s.cwd)
    defer { user.terminate() }
    let before = try sbd.removalState(s, origin: origin)

    let r = try sbd.run("rm", s.id, "--worktree")

    #expect(r.status != 0)
    #expect(r.stderr.contains("still run"), "\(r.stderr)")
    #expect(r.stderr.contains(String(user.processIdentifier)), "\(r.stderr)")
    #expect(user.isRunning)
    #expect(try sbd.removalState(s, origin: origin).withoutClaude == before.withoutClaude)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  /// Supacode runs on this Mac and can't delete a worktree on a host.
  @Test func aWorktreeThatSupacodeLockedOnTheBoxIsRefusedAndSupacodeNeverRuns() throws {
    let sbd = try Instance.remoteForRemoval()
    let calls = "\(sbd.home.path)/supacode-calls.log"
    let stub = "\(sbd.home.path)/supacode-stub"
    try "#!/bin/sh\necho \"$@\" >> \(calls)\nexit 0\n".write(toFile: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
    try sbd.restart(setting: "supacode", to: .string(stub))
    let (s, origin) = try cleanWorktree(sbd)
    let lock = #"{"build":"1792934673","createdAt":1793889333,"owner":"supacode","version":"0.11.6"}"#
    try sbd.git(s.repo, "worktree", "lock", "--reason", lock, s.cwd)

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"])

    #expect(!FileManager.default.fileExists(atPath: calls), "Supacode ran on this Mac for a worktree on mini")
  }

  // MARK: Merged PRs

  /// A merged PR that sbd found by the branch and repo that the box's git reports, with an unpushed commit at its
  /// head. As on this Mac, the worktree and the branch go.
  @Test func theWorktreeAndTheBranchOfAMergedPRAreRemovedOnTheBox() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.remoteForRemoval(config: Instance.gitHubConfig(github))
    let (s, _) = try cleanWorktree(sbd, branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the merged PR") { $0.pr?.number == 122953 && $0.pr?.state == .merged }

    let r = try sbd.run("rm", s.id, "--worktree", "--delete-branch")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.git(s.repo, "branch", "--list", Instance.mergedBranch) == "")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.removedHostSessions() == [s.id])
  }

  /// The box's `git worktree remove` runs longer than the deadline of a command that waits behind it on the host's
  /// shell, here a read of another session's screen. That command fails unsent, and the removal's later steps run
  /// on the same connection.
  @Test func aSlowWorktreeRemovalFinishesItsLaterStepsOnTheSameConnection() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.remoteForRemoval(config: Instance.gitHubConfig(github))
    let (s, _) = try cleanWorktree(sbd, branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the merged PR") { $0.pr?.number == 122953 && $0.pr?.state == .merged }
    let other = try sbd.liveOnHost("other-folder")
    let master = try sbd.sshStubPid(Instance.boxDestination)
    try sbd.holdBoxGit("worktree remove")

    let rm = try BackgroundSb(sbd, ["rm", s.id, "--worktree", "--delete-branch"])
    try sbd.waitFor("the worktree removal to reach the box's git", timeout: 60) { sbd.boxGitHeld }
    let screen = try BackgroundSb(sbd, ["screen", other.id])
    #expect(screen.exits(within: 20), "the screen read waited for the worktree removal")
    try sbd.releaseBoxGit()
    #expect(screen.result().status != 0)
    let r = rm.result()

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.git(s.repo, "branch", "--list", Instance.mergedBranch) == "")
    #expect(!FileManager.default.fileExists(atPath: sbd.boxSessionFolder(s.id)))
    #expect(try sbd.removedHostSessions() == [s.id])
    #expect(try sbd.sshStubPid(Instance.boxDestination) == master)
    // The tick's reads of the box also missed their deadlines during the hold. None of them reads as an exit.
    #expect(sbd.runs(other.pid))
    #expect(try sbd.events(other.id, kind: "exited").isEmpty)
    #expect(try sbd.events(other.id, kind: "stopped").isEmpty)
    #expect(try sbd.client.sessions().map(\.id) == [other.id])
  }

  @Test func theRemoteBranchOfAMergedPRIsDeletedFromTheBoxesOriginAtThePRsHead() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.remoteForRemoval(config: Instance.gitHubConfig(github))
    let (s, origin) = try cleanWorktree(sbd, branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    try sbd.git(s.cwd, "push", "-q", "origin", Instance.mergedBranch)
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the merged PR") { $0.pr?.state == .merged }

    let r = try sbd.run("rm", s.id, "--worktree", "--delete-branch", "--delete-remote-branch")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(try sbd.git(origin, "branch", "--list", Instance.mergedBranch) == "")
    #expect(try sbd.git(s.repo, "branch", "--list", Instance.mergedBranch) == "")
  }

  /// The box's transcript names PostHog/posthog#122953, which merged at the worktree's tip and whose head is the
  /// session's branch. The box's repo pushes elsewhere, so GitHub has no PR for its branch. A host can name any
  /// PR in its transcript, so that PR is no proof that the work merged: sbd refuses as it does without a PR.
  @Test(arguments: [["--worktree"], ["--worktree", "--delete-branch"]])
  func aPRThatOnlyTheBoxesTranscriptNamesIsNoProofOfAMerge(_ flags: [String]) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.remoteForRemoval(config: Instance.gitHubConfig(github))
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

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id] + flags)

    #expect(try sbd.git(s.repo, "branch", "--list", Instance.mergedBranch) != "")
    #expect(FileManager.default.fileExists(atPath: "\(s.cwd)/a.txt"))
  }

  // MARK: The link

  @Test func aLinkThatDroppedBeforeTheRemovalRefusesWithTheReasonAndRemovesNothing() throws {
    let sbd = try Instance.remoteForRemoval(config: Instance.shortHostWait)
    try sbd.connectHost()
    let (s, origin) = try cleanWorktree(sbd)
    try sbd.dropLinkAndRefuse(refusal)

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"], saying: "mini is not connected")
  }

  /// The link drops while the first worktree check waits on the box.
  @Test func aLinkThatDropsDuringTheChecksRefusesAndRemovesNothing() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    let before = try sbd.removalState(s, origin: origin)
    try sbd.holdBoxGit(statusRead)

    let rm = try BackgroundSb(sbd, ["rm", s.id, "--worktree"])
    try sbd.waitFor("the worktree check to reach the box's git", timeout: 30) { sbd.boxGitHeld }
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.releaseBoxGit()
    let r = rm.result()

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.removalState(s, origin: origin) == before)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  /// The link drops after sbd stopped claude, while the checks that run again after the stop wait on the box.
  /// Stopping claude is not a removal, so only claude's state may differ.
  @Test func aLinkThatDropsAfterClaudeStoppedRefusesAndRemovesNothing() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    let before = try sbd.removalState(s, origin: origin)
    try sbd.holdBoxGit(statusRead, skipping: 1)

    let rm = try BackgroundSb(sbd, ["rm", s.id, "--worktree"])
    try sbd.waitFor("the check after the stop to reach the box's git", timeout: 45) { sbd.boxGitHeld }
    #expect(!sbd.runs(s.pid), "the second check ran before claude stopped")
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.releaseBoxGit()
    let r = rm.result()

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.removalState(s, origin: origin).withoutClaude == before.withoutClaude)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  /// The link drops and reconnects on its own while a check waits on the box. The answer belongs to an earlier
  /// connection, so it is no answer.
  @Test func aLinkThatReconnectsDuringTheChecksRefusesAndRemovesNothing() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    let before = try sbd.removalState(s, origin: origin)
    let first = try #require(try sbd.sshStubPid(Instance.boxDestination))
    try sbd.holdBoxGit(statusRead)

    let rm = try BackgroundSb(sbd, ["rm", s.id, "--worktree"])
    try sbd.waitFor("the worktree check to reach the box's git", timeout: 30) { sbd.boxGitHeld }
    try sbd.dropLink("mini")
    try sbd.waitFor("a new master") { try sbd.sshStubPid(Instance.boxDestination).map { $0 != first } ?? false }
    try sbd.waitForLink("mini", .connected)
    try sbd.releaseBoxGit()
    let r = rm.result()

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.removalState(s, origin: origin) == before)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  /// A check's git ends with status 143 and no output, as one that its timeout ended does, while the worktree
  /// holds what that check would find. Its empty output must not read as a clean answer.
  @Test(arguments: [
    (statusRead, WorktreeFault.untrackedFile), ("ls-files -v", .skipWorktree), ("rev-list --count", .unpushedCommit),
    ("worktree list", .untrackedFile),
  ])
  func aCheckThatGotNoAnswerRefusesAndRemovesNothing(_ word: String, _ fault: WorktreeFault) throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    try fault.apply(sbd, cwd: s.cwd, repo: s.repo, branch: "haacked/remote")
    try sbd.endBoxGit(word)

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"])

    #expect(sbd.boxGitEnded, "no check ran `git \(word)` on the box")
    #expect(sbd.runs(s.pid))
  }

  /// The local branch is deleted, and the check that it is gone gets no answer. sbd must not read that as gone
  /// and delete the remote branch.
  @Test func anUnansweredCheckThatTheLocalBranchIsGoneKeepsTheRemoteBranch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.remoteForRemoval(config: Instance.gitHubConfig(github))
    let (s, origin) = try cleanWorktree(sbd, branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    try sbd.git(s.cwd, "push", "-q", "origin", Instance.mergedBranch)
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the merged PR") { $0.pr?.state == .merged }
    try sbd.endBoxGit("rev-parse --verify --quiet", whenMissing: true)

    let r = try sbd.run("rm", s.id, "--worktree", "--delete-branch", "--delete-remote-branch")

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.git(origin, "branch", "--list", Instance.mergedBranch) != "", "sbd deleted the remote branch")
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  // MARK: rm --done

  @Test func rmDoneRemovesALocalAndARemoteSessionWithTheirWorktreesAndBranches() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.remoteForRemoval(config: Instance.gitHubConfig(github))
    let localRepo = try Repos.create("\(sbd.home.path)/posthog", origin: Instance.posthogURL)
    let localOrigin = "\(sbd.home.path)/origin.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", localOrigin)
    try sbd.git(localRepo, "config", "url.\(localOrigin).insteadOf", Instance.posthogURL)
    try sbd.git(localRepo, "push", "-q", "origin", "main")
    let localBranch = "posthog/groups-list-two-phase-dedup"
    let local = try sbd.worktreeSession(localRepo, branch: localBranch)
    try sbd.commit(local.cwd, "local.txt")
    let localTip = try sbd.git(local.cwd, "rev-parse", "HEAD")
    let (s, _) = try cleanWorktree(sbd, branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "remote.txt")
    let remoteTip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122179) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(localTip)
    }
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(remoteTip)
    }
    try sbd.poll(all: true)
    for id in [local.id, s.id] { try sbd.waitFor(id, "Done") { $0.state == .done } }

    let r = try sbd.run("rm", "--done", "--worktree", "--yes", "--json")

    #expect(r.status == 0, "\(r.stderr)")
    let removed = Set(JSON.parse(r.stdout)?["removed"]?.array?.compactMap(\.string) ?? [])
    #expect(removed == [local.id, s.id], "\(r.stdout)")
    #expect(!FileManager.default.fileExists(atPath: local.cwd))
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.git(localRepo, "branch", "--list", localBranch) == "")
    #expect(try sbd.git(s.repo, "branch", "--list", Instance.mergedBranch) == "")
    #expect(try sbd.removedHostSessions() == [s.id])
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  @Test func rmDoneWithTheLinkDownSkipsTheRemoteSessionWithTheReasonAndRemovesTheLocalOne() throws {
    let sbd = try Instance.remoteForRemoval(config: Instance.shortHostWait)
    try sbd.connectHost()
    let localRepo = try sbd.repoWithOrigin()
    let local = try sbd.worktreeSession(localRepo, branch: "haacked/local")
    let (s, origin) = try cleanWorktree(sbd)
    for id in [local.id, s.id] {
      try sbd.sb("done", id)
      try sbd.waitFor(id, "Done") { $0.state == .done }
    }
    let before = try sbd.removalState(s, origin: origin)
    try sbd.dropLinkAndRefuse(refusal)

    let r = try sbd.run("rm", "--done", "--worktree", "--yes", "--json")

    let result = try #require(JSON.parse(r.stdout), "\(r.stdout)\n\(r.stderr)")
    #expect(result["removed"]?.array?.compactMap(\.string) == [local.id])
    let skipped = result["skipped"]?.array?.first { $0["id"]?.string == s.id }
    #expect(skipped?["reason"]?.string?.contains("mini") == true, "\(result.text)")
    #expect(!FileManager.default.fileExists(atPath: local.cwd))
    var after = try sbd.removalState(s, origin: origin)
    after.sessions = after.sessions.filter { $0 != local.id }
    var expected = before
    expected.sessions = expected.sessions.filter { $0 != local.id }
    #expect(after == expected)
    #expect(try sbd.macCalls(for: s).isEmpty)
  }

  // MARK: A worktree whose folder is gone

  /// The box is this Mac, so the test deletes the folder here, as a user who deleted it on the box does.
  @Test func aGoneWorktreeWhoseHeadIsPushedLosesOnlyItsOwnRecord() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, _) = try cleanWorktree(sbd)
    let other = "\(sbd.boxHome)/worktrees/sb-box-repo/haacked/other"
    try sbd.git(s.repo, "worktree", "add", "-q", "-b", "haacked/other", other)
    let otherListed = real(other)
    try FileManager.default.removeItem(atPath: other)
    let listed = real(s.cwd)
    try FileManager.default.removeItem(atPath: s.cwd)

    let r = try sbd.run("rm", s.id, "--worktree")

    #expect(r.status == 0, "\(r.stderr)")
    let worktrees = try sbd.git(s.repo, "worktree", "list", "--porcelain")
    #expect(!worktrees.contains(listed) && !worktrees.contains(s.cwd), "\(worktrees)")
    #expect(
      worktrees.contains(otherListed) || worktrees.contains(other), "rm pruned another gone worktree: \(worktrees)")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.removedHostSessions() == [s.id])
  }

  @Test func aGoneWorktreeWhoseDetachedHeadHasUnpushedCommitsIsRefusedAndKeepsItsRecord() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    try sbd.git(s.cwd, "checkout", "-q", "--detach")
    try sbd.commit(s.cwd, "lonely.txt")
    try FileManager.default.removeItem(atPath: s.cwd)

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"], saying: "Push them first")

    #expect(try sbd.git(s.repo, "worktree", "list", "--porcelain").contains("haacked/remote"))
  }

  @Test func aGoneWorktreeThatGitLocksIsRefusedBeforeAnythingStops() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)
    try sbd.git(s.repo, "worktree", "lock", s.cwd)
    try FileManager.default.removeItem(atPath: s.cwd)

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"], saying: "locked")

    #expect(sbd.runs(s.pid))
  }

  /// A folder that the host did not answer for is not gone, so sbd never drops the worktree's record for it.
  @Test func aGoneWorktreeWithTheLinkDownIsRefusedAndKeepsItsRecord() throws {
    let sbd = try Instance.remoteForRemoval(config: Instance.shortHostWait)
    try sbd.connectHost()
    let (s, origin) = try cleanWorktree(sbd)
    try FileManager.default.removeItem(atPath: s.cwd)
    try sbd.dropLinkAndRefuse(refusal)

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree"], saying: "mini is not connected")

    #expect(try sbd.git(s.repo, "worktree", "list", "--porcelain").contains("haacked/remote"))
  }

  // MARK: The branch after the worktree is gone

  @Test func theBranchOfASessionWithNoMergedPRIsRefusedBeforeAnythingStops() throws {
    let sbd = try Instance.remoteForRemoval()
    let (s, origin) = try cleanWorktree(sbd)

    try expectRefusal(sbd, s, origin: origin, ["rm", s.id, "--worktree", "--delete-branch"], saying: "no merged PR")

    #expect(sbd.runs(s.pid))
  }

  /// A session on the branch of PR 122953, which merged at the worktree's tip. The branch is on the box's origin.
  private func mergedOnBox(_ github: FakeGitHub) throws -> (Instance, Instance.BoxSession, String) {
    let sbd = try Instance.remoteForRemoval(config: Instance.gitHubConfig(github))
    let (s, origin) = try cleanWorktree(sbd, branch: Instance.mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    try sbd.git(s.cwd, "push", "-q", "origin", Instance.mergedBranch)
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the merged PR") { $0.pr?.state == .merged }
    return (sbd, s, origin)
  }

  /// The branch moves after `git worktree remove`, so the check that runs again before the delete refuses.
  @Test func theBranchStaysWhenACommitLandsOnItAfterTheWorktreeIsRemoved() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try mergedOnBox(github)
    try sbd.afterBoxWorktreeRemoval("/usr/bin/git -C \(shellQuote(s.repo)) branch -f \(Instance.mergedBranch) main")

    let r = try sbd.run("rm", s.id, "--worktree", "--delete-branch", "--delete-remote-branch")

    #expect(r.status != 0)
    #expect(r.stderr.contains("kept \(Instance.mergedBranch)"), "\(r.stderr)")
    #expect(try sbd.git(s.repo, "branch", "--list", Instance.mergedBranch) != "")
    #expect(try sbd.git(origin, "branch", "--list", Instance.mergedBranch) != "", "sbd deleted the remote branch")
  }

  /// Deleting the ref of a branch that a worktree has checked out breaks that worktree.
  @Test func theBranchStaysWhenAnotherWorktreeChecksItOutAfterTheRemoval() throws {
    let github = try FakeGitHub()
    let (sbd, s, origin) = try mergedOnBox(github)
    try sbd.afterBoxWorktreeRemoval("/usr/bin/git -C \(shellQuote(s.repo)) checkout -q \(Instance.mergedBranch)")

    let r = try sbd.run("rm", s.id, "--worktree", "--delete-branch", "--delete-remote-branch")

    #expect(r.status != 0)
    #expect(r.stderr.contains("checked out"), "\(r.stderr)")
    #expect(try sbd.git(s.repo, "branch", "--show-current") == Instance.mergedBranch)
    #expect(try sbd.git(origin, "branch", "--list", Instance.mergedBranch) != "", "sbd deleted the remote branch")
  }

  // MARK: The box's git that these tests drive

  /// The wrapper needs no sbd change, so this passes before Stage 5 does. A bug in it would show up as failures of
  /// the removal tests that hold or end the box's git.
  @Test func theBoxesGitHoldsSkipsEndsAndHooksOnlyTheRunsThatATestNames() throws {
    let sbd = try Instance.remoteForRemoval()
    let repo = try sbd.makeBoxRepo("wrapped")
    let git = "\(sbd.boxBin)/git"
    let status = ["-C", repo, "status", "--porcelain"]

    #expect(try runCommand(git, status).status == 0)

    try sbd.endBoxGit("status --porcelain")
    let ended = try runCommand(git, status)
    #expect(ended.status == 143 && ended.stdout.isEmpty, "\(ended)")
    #expect(sbd.boxGitEnded)
    #expect(try runCommand(git, ["-C", repo, "log", "-1"]).status == 0)
    try sbd.stopEndingBoxGit()
    #expect(try runCommand(git, status).status == 0)

    try sbd.endBoxGit("rev-parse --verify --quiet", whenMissing: true)
    #expect(try runCommand(git, ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/main"]).status == 0)
    #expect(try runCommand(git, ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/gone"]).status == 143)
    try sbd.stopEndingBoxGit()
    #expect(try runCommand(git, ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/gone"]).status == 1)

    try sbd.holdBoxGit("status --porcelain", skipping: 1)
    #expect(try runCommand(git, status).status == 0)
    #expect(!sbd.boxGitHeld, "the wrapper held the run that it should skip")
    let held = Process()
    held.executableURL = URL(fileURLWithPath: git)
    held.arguments = status
    held.standardOutput = FileHandle.nullDevice
    held.standardError = FileHandle.nullDevice
    try held.run()
    try sbd.waitFor("the second run to wait at the hold") { sbd.boxGitHeld }
    #expect(held.isRunning)
    try sbd.releaseBoxGit()
    held.waitUntilExit()
    #expect(held.terminationStatus == 0)

    let marker = "\(sbd.home.path)/after-remove-ran"
    try sbd.afterBoxWorktreeRemoval(": >\(shellQuote(marker))")
    let tree = "\(sbd.boxHome)/wrapped-tree"
    #expect(try runCommand(git, ["-C", repo, "worktree", "add", "-q", "-b", "t", tree]).status == 0)
    #expect(!FileManager.default.fileExists(atPath: marker))
    #expect(try runCommand(git, ["-C", repo, "worktree", "remove", tree]).status == 0)
    #expect(FileManager.default.fileExists(atPath: marker))
  }
}
