import Foundation
import SwitchboardCore
import Testing

private let tmuxInstall = "tmux is not installed on mini. Install it there with `sudo apt-get install -y tmux`"

/// What one run of a remote session's start, stop, resume, and open left behind.
private struct Lifecycle {
  var id: String
  var cwd: String
  var claudeSessionId: String
  /// The claude pid after the first launch, after `resume`, and after `open`.
  var pids: [Int]
  var screen: String
}

/// A session on a remote host, which the ssh stub stands in for. Its claude and shell run in the tmux server of the
/// box, at `<box home>/.sb/tmux.sock`. These tests read `claudePid`, the stub's argument log on the box, and the
/// pane's screen. `RemoteHookTests` covers the hooks of a remote claude.
@Suite(.blocking(timeLimit: .seconds(180))) struct RemoteSessionTests {
  /// Starts a session on mini in `~/sb-box-repo` with a first prompt and waits for its claude and for its transcript,
  /// which the stub writes when it answers the prompt.
  private func start(_ sbd: Instance, prompt: String = "hello", _ more: String...) throws -> (
    id: String, claudeSessionId: String, pid: Int, summary: JSON
  ) {
    try sbd.makeBoxFolder()
    let summary = try #require(
      JSON.parse(try sbd.sb(["new", "~/sb-box-repo", "--host", "mini", "--json", "--prompt", prompt] + more)))
    let id = try sbd.id(of: summary)
    let claudeSessionId = try #require(summary["claudeSessionId"]?.string)
    let pid = try #require(try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }.claudePid)
    try sbd.waitFor("the first turn's transcript on the box") { !sbd.boxTranscripts(claudeSessionId).isEmpty }
    return (id, claudeSessionId, pid, summary)
  }

  private func stop(_ sbd: Instance, _ id: String) throws {
    try sbd.sb("stop", id)
    try sbd.waitFor(id, "claude to stop on the box") { $0.claudePid == nil }
  }

  /// new, stop, resume, stop, open, screen.
  private func runLifecycle(_ sbd: Instance) throws -> Lifecycle {
    let s = try start(sbd)
    try stop(sbd, s.id)
    try sbd.sb("resume", s.id)
    let resumed = try #require(try sbd.waitFor(s.id, "claude to run after resume") { $0.claudePid != nil }.claudePid)
    try stop(sbd, s.id)
    try sbd.sb("open", s.id)
    let opened = try #require(try sbd.waitFor(s.id, "claude to run after open") { $0.claudePid != nil }.claudePid)
    try sbd.waitFor("the resumed stub's first line on the screen") {
      try sbd.sb("screen", s.id).contains("claude-stub \(s.claudeSessionId) (resume)")
    }
    let cwd = try #require(s.summary["cwd"]?.string)
    return Lifecycle(
      id: s.id, cwd: cwd, claudeSessionId: s.claudeSessionId, pids: [s.pid, resumed, opened],
      screen: try sbd.sb("screen", s.id))
  }

  // MARK: Start

  @Test func aNewSessionOnAHostNamesItsHostAndItsLink() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()

    let summary = try sbd.newOnHost("~/sb-box-repo")

    #expect(summary["host"] == "mini")
    #expect(summary["link"] == "connected")
    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array?.first)
    #expect(listed["host"] == "mini")
    #expect(listed["link"] == "connected")
    #expect(try sbd.summaryJSON(try sbd.id(of: summary))["host"] == "mini")
  }

  @Test func aNewSessionOnAHostRunsItsPanesInTheBoxesTmuxServer() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()

    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo"))
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }

    #expect(try sbd.boxTmuxSessions() == ["\(id)-claude", "\(id)-shell"])
    #expect(kindOfBoxFile(sbd, ".sb/tmux.sock") == "socket")
    let mac = try runCommand(try #require(findExecutable("tmux")), ["-S", sbd.home.tmuxSocket, "list-sessions"])
    #expect(!mac.stdout.contains(id), "the Mac's tmux server holds a pane of \(id): \(mac.stdout)")
  }

  @Test func theFolderOfANewSessionResolvesOnTheBoxAndNotOnThisMac() throws {
    let sbd = try Instance.remote()
    let folder = try sbd.makeBoxFolder()

    let summary = try sbd.newOnHost("~/sb-box-repo")

    let cwd = try #require(summary["cwd"]?.string)
    #expect(real(cwd) == real(folder))
    #expect(!cwd.hasPrefix(NSHomeDirectory()))
  }

  @Test func theClaudeOfARemoteSessionRunsInTheSessionsFolderOnTheBox() throws {
    let sbd = try Instance.remote()
    let folder = try sbd.makeBoxFolder()
    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo"))
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }

    let path = try sbd.boxTmux("display-message", "-p", "-t", "=\(id)-claude:", "#{pane_current_path}")

    #expect(real(path.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == real(folder))
  }

  @Test func theTerminalsOfARemoteSessionNameTheHostAndTheBoxesSocket() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo"))

    let terminals = try sbd.client.call("terminals", ["session": .string(id)])

    #expect(terminals["host"] == "mini")
    #expect(terminals["socket"]?.string.map(real) == real("\(sbd.boxSB)/tmux.sock"))
    #expect(terminals["claude"] == .string("\(id)-claude"))
    #expect(terminals["shell"] == .string("\(id)-shell"))
  }

  @Test func theLauncherOfARemoteSessionIsWrittenOnTheBoxAndNotOnThisMac() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()

    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo"))
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }

    #expect(FileManager.default.fileExists(atPath: "\(sbd.boxSB)/sessions/\(id)/claude.sh"))
    #expect(!FileManager.default.fileExists(atPath: sbd.home.sessionFolder(id)))
  }

  // MARK: Setup on the box

  @Test func setupCreatesTheBoxesFoldersForTheUserOnlyAndWritesTheTmuxConfigOfThisMac() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()

    _ = try sbd.newOnHost("~/sb-box-repo")

    for folder in [".sb", ".sb/bin", ".sb/sessions"] {
      let mode = try #require(
        try FileManager.default.attributesOfItem(atPath: "\(sbd.boxHome)/\(folder)")[.posixPermissions] as? NSNumber)
      #expect(mode.intValue == 0o700, "\(folder) has mode \(String(mode.intValue, radix: 8))")
    }
    let conf = try String(contentsOfFile: "\(sbd.boxSB)/tmux.conf", encoding: .utf8)
    #expect(conf == (try String(contentsOfFile: sbd.home.tmuxConfig, encoding: .utf8)))
  }

  @Test func aRemotePaneReachesTheLinksAgentThroughTheBoxesAgentSocket() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)

    let call = try #require(sbd.boxStubCalls().first { $0.args.contains(s.claudeSessionId) })

    #expect(real(call.agent) == real("\(sbd.boxSB)/agent.sock"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(sbd.boxSB)/agent.sock") == sbd.sbdAgent)
  }

  @Test func aRemotePaneGetsTheBoxesEnvironmentAndNotThisMacs() throws {
    let sbd = try Instance.remote(config: ["env": ["SB_TEST_MARK": "from-config"]])
    try sbd.makeBoxFolder()
    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo"))
    try sbd.waitFor(id, "the shell pane on the box") { _ in (try? sbd.boxTmuxSessions().contains("\(id)-shell")) == true
    }

    let env = try sbd.boxTmux("show-environment", "-t", "=\(id)-claude")
    let global = try sbd.boxTmux("show-environment", "-g")
    let both = env.stdout + global.stdout
    let lines = Set(both.split(separator: "\n").map(String.init))

    #expect(lines.contains("SB_SESSION_ID=\(id)"), "\(env.stdout)")
    #expect(
      lines.contains { $0.hasPrefix("SB_HOME=") && real(String($0.dropFirst("SB_HOME=".count))) == real(sbd.boxSB) })
    #expect(lines.contains { $0.hasPrefix("HOME=") && real(String($0.dropFirst("HOME=".count))) == real(sbd.boxHome) })
    #expect(lines.contains("PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"), "\(global.stdout)")
    #expect(!lines.contains { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }, "\(both)")
    #expect(!lines.contains { $0.hasPrefix("SB_TEST_MARK=") }, "\(both)")
    #expect(!lines.contains { $0.hasPrefix("TMPDIR=") }, "\(both)")
    #expect(!both.contains(sbd.home.tmuxSocket))
  }

  // MARK: Stop, resume, open, screen

  @Test func theFirstLaunchStartsAConversationAndEachLaterLaunchResumesIt() throws {
    let sbd = try Instance.remote()

    let run = try runLifecycle(sbd)

    let args = sbd.boxStubArgs()
    try #require(args.count == 3, "\(args)")
    #expect(args[0].hasPrefix("--session-id \(run.claudeSessionId)"), "\(args[0])")
    #expect(args[0].hasSuffix("-- hello"), "\(args[0])")
    #expect(args[1].hasPrefix("--resume \(run.claudeSessionId)"), "\(args[1])")
    #expect(args[2].hasPrefix("--resume \(run.claudeSessionId)"), "\(args[2])")
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac: \(sbd.stubArgs())")
  }

  @Test func stopEndsTheClaudeOnTheBoxAndEachLaunchStartsANewOne() throws {
    let sbd = try Instance.remote()

    let run = try runLifecycle(sbd)

    #expect(Set(run.pids).count == 3, "\(run.pids)")
    #expect(!sbd.runs(run.pids[0]))
    #expect(!sbd.runs(run.pids[1]))
    #expect(sbd.runs(run.pids[2]))
    #expect(try sbd.events(run.id).filter { $0.kind == "stopped" }.count == 2)
  }

  @Test func screenShowsTheClaudePaneOnTheBox() throws {
    let sbd = try Instance.remote()

    let s = try start(sbd)
    try sbd.waitFor("the reply on the screen") { try sbd.sb("screen", s.id).contains("⏺ Done: hello") }
    let screen = try sbd.sb("screen", s.id)

    #expect(screen.contains("claude-stub \(s.claudeSessionId) (startup)"))
  }

  @Test func aSessionWithoutATranscriptStartsItsConversationAgainOnResume() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let summary = try sbd.newOnHost("~/sb-box-repo")
    let id = try sbd.id(of: summary)
    let claudeSessionId = try #require(summary["claudeSessionId"]?.string)
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }

    try stop(sbd, id)
    try sbd.sb("resume", id)
    try sbd.waitFor(id, "claude to run after resume") { $0.claudePid != nil }

    let args = sbd.boxStubArgs()
    try #require(args.count == 2, "\(args)")
    #expect(args.allSatisfy { $0.hasPrefix("--session-id \(claudeSessionId)") }, "\(args)")
  }

  // MARK: Nothing runs on this Mac

  @Test func aRemoteSessionsStartStopResumeAndOpenLeaveNoLineInTheMacsMachineLog() throws {
    let sbd = try Instance.remote()
    // A local session shows that the log records a session's calls at all.
    let local = try sbd.new()
    _ = try sbd.waitForMachineCall("the new-session call of the local session") {
      $0.runs("tmux") && $0.has("new-session") && $0.has("\(local.id)-claude")
    }

    let run = try runLifecycle(sbd)
    // Two ticks more, so that a read that the tick makes for the session is in the log too.
    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    let named = try sbd.macCalls(holding: sbd.namesOfRemoteSession(run.id, cwd: run.cwd) + [run.claudeSessionId])
    #expect(named.isEmpty, "this Mac ran \(named.count) calls for the remote session, first: \(named.prefix(3))")
    let pids = try sbd.machineCalls().filter { call in
      (call.has("signal") || call.has("stopClaude") || call.has("alive")) && run.pids.contains { call.has(String($0)) }
    }
    #expect(pids.isEmpty, "this Mac signalled or checked a pid of the box: \(pids)")
  }

  // MARK: A worktree on the box

  @Test func aNewBranchMakesAWorktreeUnderTheBoxesWorktreeRootFromARepoThatOnlyTheBoxHolds() throws {
    let sbd = try Instance.remote()
    let repo = try sbd.makeBoxRepo()

    let summary = try sbd.newOnHost("~/sb-box-repo", "--branch", "haacked/remote")

    let id = try sbd.id(of: summary)
    let cwd = try #require(summary["cwd"]?.string)
    #expect(real(cwd).hasPrefix(real("\(sbd.boxHome)/worktrees") + "/"), "\(cwd)")
    #expect(try sbd.git(cwd, "branch", "--show-current") == "haacked/remote")
    #expect(real(try sbd.git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")) == real("\(repo)/.git"))
    #expect(summary["branch"] == "haacked/remote")
    #expect(summary["host"] == "mini")
    let onMac = (try? FileManager.default.contentsOfDirectory(atPath: "\(sbd.home.path)/worktrees")) ?? []
    #expect(onMac.isEmpty, "this Mac's worktree root holds \(onMac)")
    let named = try sbd.macCalls(holding: sbd.namesOfRemoteSession(id, cwd: cwd) + ["haacked/remote"])
    #expect(named.isEmpty, "this Mac ran \(named.prefix(3)) for the remote worktree")
  }

  @Test func aNewBranchUsesTheHostsOwnWorktreeRoot() throws {
    let sbd = try Instance.remote(host: ["worktreeRoot": "~/trees"])
    try sbd.makeBoxRepo()

    let summary = try sbd.newOnHost("~/sb-box-repo", "--branch", "haacked/remote")

    let cwd = try #require(summary["cwd"]?.string)
    #expect(real(cwd).hasPrefix(real("\(sbd.boxHome)/trees") + "/"), "\(cwd)")
  }

  /// The checks of a worktree removal run on the host. The box repo has no remote, so its commits are on no pushed
  /// branch, and sbd refuses as it does on this Mac.
  @Test func removingTheWorktreeOfARemoteSessionIsRefusedAndRemovesNothing() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxRepo()
    let summary = try sbd.newOnHost("~/sb-box-repo", "--branch", "haacked/remote")
    let id = try sbd.id(of: summary)
    let cwd = try #require(summary["cwd"]?.string)

    let r = try sbd.run("rm", id, "--worktree")

    #expect(r.status != 0)
    #expect(r.stderr.contains("not on a pushed branch"), "\(r.stderr)")
    #expect(FileManager.default.fileExists(atPath: cwd))
    #expect(try sbd.git(cwd, "branch", "--show-current") == "haacked/remote")
    #expect(try sbd.client.sessions().map(\.id) == [id])
    #expect(try sbd.boxTmuxSessions().contains("\(id)-shell"))
  }

  // MARK: Hosts that can't take a session

  @Test(arguments: [
    ("nope", "nope"), ("typo", "typo is not usable: a hogli host with the shared layout needs a workspace"),
    ("boxes", "perSession"),
  ])
  func newRefusesAHostThatHasNoLink(host: String, message: String) throws {
    let sbd = try Instance.remote(hosts: [
      "boxes": ["kind": "hogli", "layout": "perSession"], "typo": ["kind": "hogli"],
    ])
    try sbd.makeBoxFolder()

    let r = try sbd.run("new", "~/sb-box-repo", "--host", host, "--json")

    #expect(r.status == 1)
    #expect(r.stderr.contains(message), "\(r.stderr)")
    #expect(r.stdout.isEmpty)
    #expect(try sbd.client.sessions().isEmpty)
    #expect(sbd.sshStubLog.isEmpty)
    #expect(sbd.stubArgs().isEmpty)
    #expect(try sbd.macCalls(holding: [sbd.boxHome, "new-session"]).isEmpty)
  }

  @Test func aHostWithNoTmuxFailsTheNewSessionWithTheInstallMessage() throws {
    let sbd = try Instance.remote(host: ["tmux": "/nonexistent/sb/tmux"])
    try sbd.makeBoxFolder()

    let r = try sbd.run("new", "~/sb-box-repo", "--host", "mini", "--json")

    #expect(r.status == 1)
    #expect(r.stderr.contains(tmuxInstall), "\(r.stderr)")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.boxTmuxSessions().isEmpty)
    #expect(sbd.stubArgs().isEmpty)
  }

  @Test func aHostWithNoTmuxShowsTheInstallMessageInTheHostList() throws {
    let sbd = try Instance.remote(host: ["tmux": "/nonexistent/sb/tmux"])
    try sbd.makeBoxFolder()
    _ = try sbd.run("new", "~/sb-box-repo", "--host", "mini", "--json")

    let rows = try #require(JSON.parse(try sbd.sb("host", "ls", "--json"))?.array)

    let mini = try #require(rows.first { $0["name"] == "mini" })
    #expect(mini["link"] == "connected")
    #expect(mini["error"]?.string?.contains(tmuxInstall) == true, "\(mini.text)")
  }

  @Test func aSessionCantStartOnAHostWhileTheHostRefusesTheLink() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let refusal = "ssh: connect to host mini.local port 22: Operation timed out"
    try sbd.setSSHStub("refuse", refusal + "\n")

    let r = try sbd.run("new", "~/sb-box-repo", "--host", "mini", "--json")

    #expect(r.status == 1)
    #expect(r.stderr.contains("mini is not connected"), "\(r.stderr)")
    #expect(r.stderr.contains(refusal), "\(r.stderr)")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(sbd.stubArgs().isEmpty)
    #expect(try sbd.macCalls(holding: ["new-session"]).isEmpty)
  }

  // MARK: What a remote session can't do

  @Test func sendingAnImageToARemoteSessionIsRefused() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    let picture = "\(sbd.home.path)/shot.png"
    try AttachmentTests.png.write(to: URL(fileURLWithPath: picture))

    let r = try sbd.run("send", s.id, "--image", picture, "look at this")

    #expect(r.status != 0)
    #expect(r.stderr.contains("images can't reach a session on a host yet"), "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: sbd.home.attachmentsFolder(s.id)))
    #expect(try !sbd.sb("screen", s.id).contains("look at this"))
  }

  @Test func attachingToARemoteSessionIsRefused() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)

    let r = try sbd.run("attach", s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("sb attach can't reach a session on a host yet"), "\(r.stderr)")
  }

  /// The move may refuse as a whole or skip the session. Either way it names the reason and moves nothing.
  @Test func anAccountMoveLeavesARemoteSessionUnderTheHostsLogin() throws {
    let sbd = try Instance.remote()
    for name in ["A", "B"] {
      try FileManager.default.createDirectory(atPath: sbd.account(name), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: "\(sbd.account(name))/.claude.json", contents: Data("{}".utf8))
    }
    try sbd.restart(setting: "claudeConfigDirs", to: .array(["A", "B"].map { .string(sbd.account($0)) }))
    let s = try start(sbd)
    try stop(sbd, s.id)

    let r = try sbd.run("account", "move", "--json", "B")

    let events = try sbd.events(s.id)
    let said = r.stdout + r.stderr + events.map(\.data.text).joined()
    #expect(said.contains("it runs under the Claude login of mini"), "\(said)")
    #expect(!events.contains { $0.kind == "account-moved" })
    #expect(try sbd.macCalls(holding: [s.claudeSessionId, sbd.boxHome]).isEmpty)
    try sbd.sb("resume", s.id)
    try sbd.waitFor(s.id, "claude to run after the move") { $0.claudePid != nil }
    #expect(sbd.boxStubCalls().filter { $0.args.contains(s.claudeSessionId) }.allSatisfy { $0.account.isEmpty })
  }

  @Test func aGroupAccountLeavesARemoteSessionUnderTheHostsLogin() throws {
    let sbd = try Instance.remote()
    for name in ["A", "B"] {
      try FileManager.default.createDirectory(atPath: sbd.account(name), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: "\(sbd.account(name))/.claude.json", contents: Data("{}".utf8))
    }
    try sbd.restart(setting: "claudeConfigDirs", to: .array(["A", "B"].map { .string(sbd.account($0)) }))
    let s = try start(sbd)
    try stop(sbd, s.id)
    try sbd.sb("group", "add", "--json", "Flags", s.id)

    let r = try sbd.run("group", "account", "--json", "Flags", "B")

    let events = try sbd.events(s.id)
    let said = r.stdout + r.stderr + events.map(\.data.text).joined()
    #expect(said.contains("it runs under the Claude login of mini"), "\(said)")
    try sbd.sb("resume", s.id)
    try sbd.waitFor(s.id, "claude to run after the group's account was set") { $0.claudePid != nil }
    #expect(!(try sbd.events(s.id)).contains { $0.kind == "account-moved" })
    #expect(sbd.boxStubCalls().filter { $0.args.contains(s.claudeSessionId) }.allSatisfy { $0.account.isEmpty })
  }

  // MARK: Local sessions

  @Test func aLocalSessionHasNoHostAndNoLinkInItsSummary() throws {
    let sbd = try Instance.remote()

    let s = try sbd.new()

    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array?.first)
    let got = try sbd.summaryJSON(s.id)
    for summary in [listed, got] {
      #expect(summary.object?.keys.contains("host") == false)
      #expect(summary.object?.keys.contains("link") == false)
    }
    let terminals = try sbd.client.call("terminals", ["session": .string(s.id)])
    #expect(terminals.object?.keys.contains("host") == false)
    #expect(sbd.sshStubLog.isEmpty)
  }

  @Test func aLocalSessionNextToARemoteOneRunsOnThisMac() throws {
    let sbd = try Instance.remote()
    let remote = try start(sbd)

    let local = try sbd.new(prompt: "hello there")
    let done = try sbd.waitFor(local.id, "the local session's reply") { $0.lastReply == "Done: hello there" }

    #expect(done.live)
    #expect(
      sbd.stubArgs().first?.hasPrefix(
        "--session-id \(local.claudeSessionId) --settings \(sbd.home.claudeSettings(local.id))")
        == true)
    #expect(try sbd.boxTmuxSessions() == ["\(remote.id)-claude", "\(remote.id)-shell"])
    #expect(sbd.boxStubArgs().count == 1)
  }

  // MARK: Parity

  /// A remote launch names the box's hook settings in place of this Mac's, leaves out the shared MCP config and
  /// `claudeArgs`, and its pane has no CLAUDE_CONFIG_DIR. It gets the triage nudge, because claude on the box can
  /// run `sb`. Everything else matches a local launch with the same arguments.
  @Test func aRemoteLaunchGetsTheArgumentsOfALocalOneExceptTheListedDifferences() throws {
    let sbd = try Instance.remote(config: ["claudeArgs": ["--verbose"], "triage": ["systemPrompt": "nudge"]])
    try sbd.makeBoxFolder()

    let local = try #require(JSON.parse(try sbd.sb("new", sbd.work, "--json", "--prompt", "hello", "--model", "opus")))
    let remote = try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello", "--model", "opus")
    let localId = try #require(local["claudeSessionId"]?.string)
    let localSession = try #require(local["id"]?.string)
    let remoteId = try #require(remote["claudeSessionId"]?.string)
    let localCall = try sbd.waitFor(
      "the local launch", fetch: { sbd.stubCalls().first { $0.args.contains(localId) } }, until: { _ in true })
    let remoteCall = try sbd.waitFor(
      "the remote launch", fetch: { sbd.boxStubCalls().first { $0.args.contains(remoteId) } }, until: { _ in true })

    var expected = localCall.args.replacingOccurrences(of: localId, with: remoteId).split(separator: " ").map(
      String.init)
    for (flag, values) in [("--mcp-config", 1), ("--verbose", 0)] {
      if let at = expected.firstIndex(of: flag) { expected.removeSubrange(at...(at + values)) }
    }
    let remoteArgs = remoteCall.args.split(separator: " ").map(String.init)
    let settings = try #require(expected.firstIndex(of: "--settings")) + 1
    try #require(remoteArgs.count > settings, "\(remoteArgs)")
    #expect(real(remoteArgs[settings]) == real(sbd.boxSettings))
    #expect(expected[settings] == sbd.home.claudeSettings(localSession))
    expected[settings] = remoteArgs[settings]
    #expect(remoteArgs == expected)
    #expect(
      remoteCall.args
        == "--session-id \(remoteId) --settings \(remoteArgs[settings]) --model opus --append-system-prompt nudge -- hello"
    )
    #expect(localCall.args.contains("--verbose") && localCall.args.contains("--append-system-prompt nudge"))
    #expect(!localCall.account.isEmpty)
    #expect(remoteCall.account.isEmpty)
  }

  /// A resume differs from a local resume in the same ways. The remote `claude.sh` starts with the line that puts
  /// the box's `sb` on claude's PATH.
  @Test func aRemoteResumeGetsTheArgumentsOfALocalOneExceptTheListedDifferences() throws {
    let sbd = try Instance.remote()
    let remote = try start(sbd)
    let local = try sbd.new(prompt: "hello")
    try sbd.waitFor(local.id, "the local session's reply") { $0.lastReply == "Done: hello" }

    try stop(sbd, remote.id)
    try sbd.sb("stop", local.id)
    try sbd.waitFor(local.id, "the local claude to stop") { $0.claudePid == nil }
    try sbd.sb("resume", remote.id)
    try sbd.sb("resume", local.id)
    try sbd.waitFor(remote.id, "the remote claude to run again") { $0.claudePid != nil }
    try sbd.waitFor(local.id, "the local claude to run again") { $0.claudePid != nil }

    #expect(sbd.stubArgs().last == "--resume \(local.claudeSessionId) --settings \(sbd.home.claudeSettings(local.id))")
    let resumed = (sbd.boxStubArgs().last ?? "").split(separator: " ").map(String.init)
    try #require(resumed.count == 4, "\(resumed)")
    #expect(Array(resumed.prefix(3)) == ["--resume", remote.claudeSessionId, "--settings"])
    #expect(real(resumed[3]) == real(sbd.boxSettings))
    let remoteLauncher = try String(contentsOfFile: "\(sbd.boxSB)/sessions/\(remote.id)/claude.sh", encoding: .utf8)
    let localLauncher = try String(contentsOfFile: "\(sbd.home.sessionFolder(local.id))/claude.sh", encoding: .utf8)
    #expect(
      remoteLauncher.split(separator: "\n").first == #"export PATH="$SB_HOME/bin:$PATH""#, "\(remoteLauncher)")
    #expect(!localLauncher.contains("export PATH"), "\(localLauncher)")
  }

  // MARK: The fixtures

  @Test func reapEndsTheBoxesTmuxServer() throws {
    var home = ""
    var socket = ""
    do {
      let sbd = try Instance.remote()
      try sbd.makeBoxFolder()
      let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo"))
      try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }
      home = sbd.home.path
      socket = "\(sbd.boxSB)/tmux.sock"
      try #require(try sbd.boxTmuxSessions().count == 2)

      try Instance.reapHome(home)
    }

    let servers = try runCommand("/usr/bin/pgrep", ["-f", socket])
    #expect(servers.stdout.isEmpty, "a tmux server of the box outlived its home: \(servers.stdout)")
    #expect(!FileManager.default.fileExists(atPath: home))
  }

  private func kindOfBoxFile(_ sbd: Instance, _ name: String) -> String? {
    var info = stat()
    guard lstat("\(sbd.boxHome)/\(name)", &info) == 0 else { return nil }
    switch info.st_mode & S_IFMT {
    case S_IFSOCK: return "socket"
    case S_IFDIR: return "folder"
    case S_IFLNK: return "symlink"
    default: return "file"
    }
  }
}
