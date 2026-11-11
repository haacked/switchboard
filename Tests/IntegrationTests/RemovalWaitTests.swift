import Foundation
import SwitchboardCore
import Testing

/// The head branch of the recorded PR 122953 in PostHog/posthog.
private let mergedBranch = "haacked/cdp-dlq-breaker-counts-lookups"

/// The two commands that remove a worktree after they wait for the session's processes.
enum WorktreeRemoval: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case cleanup
  case rm

  var testDescription: String { self == .cleanup ? "sb cleanup" : "sb rm --worktree" }
}

extension Instance {
  fileprivate func removeWorktree(_ how: WorktreeRemoval, _ id: String) throws -> CommandResult {
    switch how {
    case .cleanup: try run(["cleanup", id, "--json"])
    case .rm: try deleteSession(id)
    }
  }

  fileprivate func localBranchExists(_ repo: String, _ name: String) throws -> Bool {
    try runCommand("/usr/bin/git", ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0
  }

  fileprivate func cleanupCount(_ id: String) throws -> Int { try events(id).filter { $0.kind == "cleanup" }.count }

  /// Types the text into the session's shell pane and presses Enter.
  fileprivate func typeInShell(_ t: Terminals, _ text: String) throws {
    for keys in [["-l", text], ["Enter"]] {
      let r = try runCommand(t.tmux, ["-S", t.socket, "send-keys", "-t", "=\(t.shell):"] + keys)
      guard r.status == 0 else { throw TestError(description: "tmux send-keys: \(r.stderr)") }
    }
  }
}

private func paneExists(_ t: Terminals, _ target: String) throws -> Bool {
  try runCommand(t.tmux, ["-S", t.socket, "has-session", "-t", "=\(target)"]).status == 0
}

/// Whether the text names the pid as a whole number.
private func names(_ text: String, _ pid: pid_t) -> Bool {
  text.contains(try! Regex("\\b\(pid)\\b"))
}

/// Whether the process has exec'd sleep. Each process that a test starts opens its files and changes its folder
/// before that exec.
private func runsSleep(_ pid: pid_t) -> Bool {
  guard let r = try? runCommand("/bin/ps", ["-o", "comm=", "-p", String(pid)]) else { return false }
  return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("sleep")
}

/// Copies /bin/sleep to the path. macOS kills a copy of a system program that keeps Apple's signature, so the copy
/// gets an ad hoc signature.
private func copySleep(to path: String) throws {
  try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
  let r = try runCommand("/usr/bin/codesign", ["--force", "-s", "-", path])
  guard r.status == 0 else { throw TestError(description: "codesign: \(r.stderr)") }
}

/// The processes that a test starts. Fixtures/reap finds a process only by a home path in its arguments, and
/// `sleep 100` has none, so a test calls `killAll` in a `defer`.
private final class Strays {
  let sbd: Instance
  /// Files in SB_HOME that each hold the pid of a process that the stub or the shell pane started.
  var pidFiles: [String] = []
  var spawned: [Process] = []

  init(_ sbd: Instance) { self.sbd = sbd }

  /// Every pid, or nil while a pid file is missing.
  func pids() -> [pid_t]? {
    let fromFiles = pidFiles.map(sbd.stubPid)
    guard !fromFiles.contains(nil) else { return nil }
    return fromFiles.compactMap { $0 } + spawned.map(\.processIdentifier)
  }

  /// Starts the program in the folder, outside every pane.
  func spawn(_ path: String, _ args: [String], cwd: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    spawned.append(p)
  }

  func killAll() {
    for pid in pidFiles.compactMap(sbd.stubPid) where Processes.exists(Int(pid)) { kill(pid, SIGKILL) }
    for p in spawned where p.isRunning {
      kill(p.processIdentifier, SIGKILL)
      p.waitUntilExit()
    }
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct RemovalWaitTests {
  /// A session in a worktree that sbd made on PR 122953's branch, after a commit of a.txt. GitHub reports the PR
  /// as merged at the branch tip, so both `sb cleanup` and `sb rm --worktree` accept it.
  private func finishedSession(_ github: FakeGitHub) throws -> (Instance, String, SessionSummary) {
    let sbd = try Instance.withGitHub(github)
    let repo = try Repos.create("\(sbd.home.path)/posthog", origin: "https://github.com/PostHog/posthog.git")
    let s = try sbd.worktreeSession(repo, branch: mergedBranch)
    try sbd.commit(s.cwd, "a.txt")
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try sbd.poll(all: true)
    return (sbd, repo, s)
  }

  private func expectKept(_ sbd: Instance, _ repo: String, _ s: SessionSummary) throws {
    #expect(try sbd.client.sessions().map(\.id).contains(s.id))
    #expect(FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.localBranchExists(repo, mergedBranch))
    #expect(try sbd.cleanupCount(s.id) == 0)
  }

  private func expectRemoved(_ how: WorktreeRemoval, _ sbd: Instance, _ s: SessionSummary) throws {
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    switch how {
    case .cleanup: #expect(try sbd.cleanupCount(s.id) == 1)
    case .rm: #expect(try !sbd.client.sessions().map(\.id).contains(s.id))
    }
  }

  /// Runs `start`, which starts processes and registers them with the strays, and waits until each runs sleep.
  /// The removal must refuse, name each pid, leave the session, the folder, and the branch, and send no signal to
  /// the processes. Once the test kills them, a retry must remove the worktree.
  private func expectRefusalUntilTheyExit(
    _ how: WorktreeRemoval, naming use: String? = nil, startedBySession: Bool = false,
    _ start: (Instance, SessionSummary, Terminals, Strays) throws -> Void
  ) throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    let terminals = try sbd.client.terminals(s.id)
    let strays = Strays(sbd)
    defer { strays.killAll() }
    try start(sbd, s, terminals, strays)
    let pids = try sbd.waitFor("the started processes to run sleep", fetch: strays.pids) {
      !$0.isEmpty && $0.allSatisfy(runsSleep)
    }

    let r = try sbd.removeWorktree(how, s.id)

    try #require(r.status != 0, Comment(rawValue: r.stderr))
    for pid in pids {
      #expect(names(r.stderr, pid), Comment(rawValue: "\(pid) is not in: \(r.stderr)"))
      if startedBySession {
        #expect(
          r.stderr.contains(try Regex("\\b\(pid) \\([^)]*, started by the session\\)")),
          Comment(rawValue: r.stderr))
      }
      #expect(Processes.exists(Int(pid)), "sbd ended \(pid)")
    }
    if let use, let folder = realPath(s.cwd) {
      #expect(r.stderr.contains(", \(use) \(folder)"), Comment(rawValue: r.stderr))
    }
    try expectKept(sbd, repo, s)

    strays.killAll()
    try sbd.waitFor("the started processes to exit") { pids.allSatisfy { !Processes.exists(Int($0)) } }

    let retry = try sbd.removeWorktree(how, s.id)

    #expect(retry.status == 0, Comment(rawValue: retry.stderr))
    try expectRemoved(how, sbd, s)
  }

  /// Runs `start`, which starts processes, registers them with the strays, and returns the check that tells when
  /// each has reached the state the test needs. The removal must succeed and leave each process running.
  private func expectRemovalWhileTheyRun(
    _ how: WorktreeRemoval, _ start: (SessionSummary, Strays) throws -> (pid_t) -> Bool
  ) throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    let strays = Strays(sbd)
    defer { strays.killAll() }
    let ready = try start(s, strays)
    let pids = try sbd.waitFor("the started processes to start", fetch: strays.pids) {
      !$0.isEmpty && $0.allSatisfy(ready)
    }

    let r = try sbd.removeWorktree(how, s.id)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try expectRemoved(how, sbd, s)
    for pid in pids { #expect(Processes.exists(Int(pid)), "sbd ended \(pid)") }
  }

  // MARK: claude that has not exited

  /// The stub outlives the first 5 s wait and exits within the retry's wait. The refusal leaves the Claude pane
  /// open, which is how the retry finds that claude.
  @Test func rmRefusesAClaudeThatHasNotExitedAfterTheWait() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.sb("send", s.id, "linger 7")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "I'll linger 7 s when I stop." }
    let pid = try #require(try sbd.waitFor(s.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    let terminals = try sbd.client.terminals(s.id)

    let r = try sbd.deleteSession(s.id)

    try #require(r.status != 0, Comment(rawValue: r.stderr))
    #expect(r.stderr.contains("has not exited"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
    #expect(try sbd.localBranchExists(repo, "haacked/feature"))
    #expect(Processes.exists(pid))
    #expect(try paneExists(terminals, terminals.claude))
    #expect(try !paneExists(terminals, terminals.shell))

    let retry = try sbd.deleteSession(s.id)

    #expect(retry.status == 0, Comment(rawValue: retry.stderr))
    #expect(!Processes.exists(pid))
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try !sbd.client.sessions().map(\.id).contains(s.id))
    #expect(try !paneExists(terminals, terminals.claude))
  }

  /// The stub writes notes.txt when SIGTERM arrives, which is after the first check passed. Only the check after
  /// claude exits can find it.
  @Test func rmRefusesAnUntrackedFileThatClaudeWritesAsItStops() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    try sbd.sb("send", s.id, "onterm notes.txt")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "I'll write notes.txt when I stop." }
    let file = "\(s.cwd)/notes.txt"
    #expect(!FileManager.default.fileExists(atPath: file))

    let r = try sbd.deleteSession(s.id)

    try #require(r.status != 0, Comment(rawValue: r.stderr))
    #expect(r.stderr.contains("uncommitted"), Comment(rawValue: r.stderr))
    #expect(FileManager.default.fileExists(atPath: file))
    #expect(try sbd.intact(s))
    #expect(try sbd.localBranchExists(repo, "haacked/feature"))
  }

  // MARK: Processes of the session that outlive claude

  /// The job descends from claude when the stop begins, and its folder is the worktree.
  @Test(arguments: WorktreeRemoval.allCases)
  func refusesUntilClaudesBackgroundJobExits(_ how: WorktreeRemoval) throws {
    try expectRefusalUntilTheyExit(how) { sbd, s, _, strays in
      strays.pidFiles = ["job.pid"]
      try sbd.sb("send", s.id, "background 100 held")
      try sbd.waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
    }
  }

  @Test(arguments: WorktreeRemoval.allCases)
  func namesEachBackgroundJobThatOutlivesClaude(_ how: WorktreeRemoval) throws {
    try expectRefusalUntilTheyExit(how) { sbd, s, _, strays in
      strays.pidFiles = ["job.pid", "job2.pid"]
      try sbd.sb("send", s.id, "background 100 held two")
      try sbd.waitFor(s.id, "the turn that starts the jobs") { $0.lastReply == "Started a job of 100 s." }
    }
  }

  /// A plain `&` job dies from the SIGHUP that closing the pane sends, so the shell starts it with nohup.
  @Test(arguments: WorktreeRemoval.allCases)
  func refusesUntilAProcessFromTheShellPaneExits(_ how: WorktreeRemoval) throws {
    try expectRefusalUntilTheyExit(how) { sbd, _, terminals, strays in
      strays.pidFiles = ["shell.pid"]
      try sbd.typeInShell(terminals, "nohup sleep 100 >/dev/null 2>&1 & echo $! > \"$SB_HOME/shell.pid\"")
    }
  }

  /// The process runs in / and opens nothing in the worktree, so only its descent from the shell pane, recorded
  /// when the stop begins, finds it. The subshell runs in the background and execs sleep, so it stays the shell's
  /// child with the pid that `$!` names.
  @Test(arguments: WorktreeRemoval.allCases)
  func refusesUntilAShellPaneProcessOutsideTheFolderExits(_ how: WorktreeRemoval) throws {
    try expectRefusalUntilTheyExit(how, startedBySession: true) { sbd, _, terminals, strays in
      strays.pidFiles = ["root.pid"]
      try sbd.typeInShell(
        terminals,
        "(cd / && exec /usr/bin/nohup /bin/sleep 100 >/dev/null 2>&1) & echo $! > \"$SB_HOME/root.pid\"")
    }
  }

  /// The process descends from no pane, so only its working folder in the worktree finds it.
  @Test(arguments: WorktreeRemoval.allCases)
  func refusesUntilAProcessWorkingInTheFolderExits(_ how: WorktreeRemoval) throws {
    try expectRefusalUntilTheyExit(how, naming: "cwd") { _, s, _, strays in
      try strays.spawn("/bin/sleep", ["100"], cwd: s.cwd)
    }
  }

  /// The process descends from no pane and runs in /, so only its open a.txt finds it. a.txt is committed, so the
  /// uncommitted-file check passes.
  @Test(arguments: WorktreeRemoval.allCases)
  func refusesUntilAProcessWithAFileOpenInTheFolderExits(_ how: WorktreeRemoval) throws {
    try expectRefusalUntilTheyExit(how, naming: "open file") { _, s, _, strays in
      try strays.spawn("/bin/sh", ["-c", "exec 3<\"$1\"; exec /bin/sleep 100", "sh", "\(s.cwd)/a.txt"], cwd: "/")
    }
  }

  /// The process descends from no pane and runs, in /, a copy of sleep in the worktree's .build, so only its
  /// program finds it. Git ignores .build through info/exclude, and cleanup counts it as a build's output, so the
  /// file checks pass.
  @Test(arguments: WorktreeRemoval.allCases)
  func refusesUntilAProcessWhoseProgramIsInTheFolderExits(_ how: WorktreeRemoval) throws {
    try expectRefusalUntilTheyExit(how, naming: "program") { sbd, s, _, strays in
      let exclude = try sbd.git(s.cwd, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude")
      try FileManager.default.createDirectory(
        atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      try ".build/\n".write(toFile: exclude, atomically: true, encoding: .utf8)
      try FileManager.default.createDirectory(atPath: "\(s.cwd)/.build", withIntermediateDirectories: true)
      try copySleep(to: "\(s.cwd)/.build/sleep")
      try strays.spawn("\(s.cwd)/.build/sleep", ["100"], cwd: "/")
    }
  }

  // MARK: Processes that use the folder without blocking

  /// A file watcher such as Supacode holds the worktree open as a directory for as long as it runs. The process
  /// runs in / and holds only that directory handle, so the removal goes ahead and sends it no signal.
  @Test(arguments: WorktreeRemoval.allCases)
  func removesWhileAProcessHoldsOnlyTheFolderOpenAsADirectory(_ how: WorktreeRemoval) throws {
    try expectRemovalWhileTheyRun(how) { s, strays in
      try strays.spawn("/bin/sh", ["-c", "exec 3<\"$1\"; exec /bin/sleep 100", "sh", s.cwd], cwd: "/")
      return runsSleep
    }
  }

  /// `git push` over ssh with ControlPersist leaves a master process that keeps the worktree as its working
  /// folder and renames itself `ssh: <socket> [mux]`. The fake is a copy of sleep named ssh, outside the worktree,
  /// that bash execs under that name.
  @Test(arguments: WorktreeRemoval.allCases)
  func removesWhileAnSSHMultiplexerWorksInTheFolder(_ how: WorktreeRemoval) throws {
    try expectRemovalWhileTheyRun(how) { s, strays in
      let bin = "\(strays.sbd.home.path)/fake-ssh"
      try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
      try copySleep(to: "\(bin)/ssh")
      try strays.spawn(
        "/bin/bash", ["-c", "exec -a \"ssh: $0/sock [mux]\" \"$0/ssh\" 100", bin], cwd: s.cwd)
      return { pid in
        guard let r = try? runCommand("/bin/ps", ["-ww", "-o", "args=", "-p", String(pid)]) else { return false }
        return r.stdout.hasPrefix("ssh: ")
      }
    }
  }

  /// `held` keeps the stub from starting the turn that reports the job, which would refuse as a running turn.
  @Test(arguments: WorktreeRemoval.allCases)
  func removesWhenTheJobExitsDuringTheWait(_ how: WorktreeRemoval) throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    let strays = Strays(sbd)
    strays.pidFiles = ["job.pid"]
    defer { strays.killAll() }
    try sbd.sb("send", s.id, "background 2 held")
    try sbd.waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 2 s." }
    let job = try #require(strays.pids()?.first)
    try #require(Processes.exists(Int(job)), "the job ended before the removal began")

    let r = try sbd.removeWorktree(how, s.id)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(!Processes.exists(Int(job)))
    try expectRemoved(how, sbd, s)
  }

  /// The process descends from no pane, so only the folder scan's retry can see it exit.
  @Test(arguments: WorktreeRemoval.allCases)
  func removesWhenAProcessInTheFolderExitsDuringTheWait(_ how: WorktreeRemoval) throws {
    let github = try FakeGitHub()
    let (sbd, _, s) = try finishedSession(github)
    let strays = Strays(sbd)
    defer { strays.killAll() }
    try strays.spawn("/bin/sleep", ["3"], cwd: s.cwd)

    let r = try sbd.removeWorktree(how, s.id)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try expectRemoved(how, sbd, s)
  }

  // MARK: To-dos

  /// Starts `sleep 100` in the session's folder and waits until it runs sleep. The folder scan then holds the pane
  /// stop until the test kills it, or for 5 s.
  private func holdFolder(_ sbd: Instance, _ s: SessionSummary) throws -> Strays {
    let strays = Strays(sbd)
    try strays.spawn("/bin/sleep", ["100"], cwd: s.cwd)
    _ = try sbd.waitFor("the stray to run sleep", fetch: strays.pids) { !$0.isEmpty && $0.allSatisfy(runsSleep) }
    return strays
  }

  /// The to-do arrives after rm's first check, while the stop waits for the folder. The worktree goes, and the
  /// record and the to-do stay. A second rm that resolves the to-do finishes the delete.
  @Test func rmKeepsTheRecordWhenAToDoArrivesDuringThePaneStop() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let terminals = try sbd.client.terminals(s.id)
    let strays = try holdFolder(sbd, s)
    defer { strays.killAll() }

    let removal = Outcome<CommandResult>.detached { try sbd.deleteSession(s.id) }
    // finishPaneStop closes the Claude pane just before it waits for the folder.
    try sbd.waitFor("the stop to close the Claude pane") { try !paneExists(terminals, terminals.claude) }
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    strays.killAll()
    try #require(removal.done.wait(timeout: .now() + 60) == .success, "rm did not return")
    let r = try #require(try removal.result?.get())

    #expect(r.status != 0)
    #expect(
      r.stderr.contains("Removed the worktree of \(s.id) and kept the session, because it has an open to-do"),
      Comment(rawValue: r.stderr))
    #expect(r.stderr.contains(todo.id), Comment(rawValue: r.stderr))
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.client.sessions().map(\.id).contains(s.id))
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)

    let retry = try sbd.run(["rm", s.id, "--resolve", todo.id])

    #expect(retry.status == 0, Comment(rawValue: retry.stderr))
    #expect(try !sbd.client.sessions().map(\.id).contains(s.id))
    #expect(try sbd.resolvedTodoIds() == [todo.id])
  }

  /// `rm --delete-branch` deletes the branch before its last to-do check. A late refusal names the branch too.
  @Test func aLateToDoRefusalNamesTheBranchThatRmDeleted() throws {
    let github = try FakeGitHub()
    let (sbd, repo, s) = try finishedSession(github)
    let terminals = try sbd.client.terminals(s.id)
    let strays = try holdFolder(sbd, s)
    defer { strays.killAll() }

    let removal = Outcome<CommandResult>.detached { try sbd.deleteSessionAndBranch(s.id) }
    try sbd.waitFor("the stop to close the Claude pane") { try !paneExists(terminals, terminals.claude) }
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    strays.killAll()
    try #require(removal.done.wait(timeout: .now() + 60) == .success, "rm did not return")
    let r = try #require(try removal.result?.get())

    #expect(r.status != 0)
    #expect(
      r.stderr.contains(
        "Removed the worktree and the local branch of \(s.id) and kept the session, because it has an open to-do"),
      Comment(rawValue: r.stderr))
    #expect(try !sbd.localBranchExists(repo, mergedBranch))
    #expect(try sbd.client.sessions().map(\.id).contains(s.id))
    #expect(try sbd.isOpenTodo(s.id, todo.id))
  }

  /// The folder scan refuses after the pane stop began, which is after the first check accepted the to-do's id.
  @Test func aRefusalAfterThePaneStopBeganLeavesTheToDoOpen() throws {
    let sbd = try Instance()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    let strays = try holdFolder(sbd, s)
    defer { strays.killAll() }

    let r = try sbd.run(["rm", s.id, "--worktree", "--resolve", todo.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("still run"), Comment(rawValue: r.stderr))
    #expect(FileManager.default.fileExists(atPath: s.cwd))
    #expect(try sbd.client.sessions().map(\.id).contains(s.id))
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }
}
