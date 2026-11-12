import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct PlanModeTests: MCPToolServerSuite {
  func instance(_ extra: [String: JSON] = [:]) throws -> Instance {
    let base: [String: JSON] = ["autoMode": true]
    return try Instance(config: base.merging(extra) { $1 })
  }

  /// An instance whose repo root, `repos`, holds acme/widgets. The caller keeps `repos`, whose deinit removes it.
  func spawnInstance(_ repos: Repos) throws -> Instance {
    try repos.make("acme/widgets")
    return try instance(["repoRoots": [.string(repos.root)]])
  }

  /// A session that `sb new --json` started in the work folder.
  func new(_ sbd: Instance, _ flags: String..., prompt: String? = "hello", name: String = "t") throws -> SessionSummary
  {
    let args = ["new", "--json", "--name", name] + flags + (prompt.map { ["--prompt", $0] } ?? []) + [sbd.work]
    return try decode(SessionSummary.self, sbd.sb(args))
  }

  /// A session that `sb spawn --json` started or added as a follow-up.
  func spawn(_ sbd: Instance, branch: String, _ flags: String...) throws -> SessionSummary {
    try decode(
      SessionSummary.self,
      sbd.sb(["spawn", "--json", "--repo", "acme/widgets", "--branch", branch, "--prompt", "hello"] + flags))
  }

  @discardableResult
  func firstReply(_ sbd: Instance, _ id: String, timeout: Double = 15) throws -> SessionSummary {
    try sbd.waitFor(id, "the first reply", timeout: timeout) { $0.lastReply == "Done: hello" }
  }

  /// Stops the session's claude, resumes it with a message, and returns the resume's argument line.
  func resume(_ sbd: Instance, _ s: SessionSummary, _ message: String = "again") throws -> String {
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to exit") { !$0.live }
    try sbd.sb("send", s.id, message)
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: \(message)" }
    return try #require(launchLines(sbd, s).last)
  }

  /// Sends the stub's `mode` prompt and waits until its hooks report the mode.
  func switchMode(_ sbd: Instance, _ id: String, to mode: String) throws {
    try sbd.sb("send", id, "mode \(mode)")
    try sbd.waitFor(id, "the switch to \(mode)") { $0.lastReply == "Mode: \(mode)" && $0.permissionMode == mode }
  }

  /// The stub's argument line of each launch of the session. The log also holds other claude commands.
  func launchLines(_ sbd: Instance, _ s: SessionSummary) -> [String] {
    sbd.stubArgs().filter { $0.contains(s.claudeSessionId) }
  }

  /// The value after each `--permission-mode` in the line.
  func modesPassed(_ line: String) -> [String] {
    let words = line.split(separator: " ").map(String.init)
    return words.indices.dropLast().filter { words[$0] == "--permission-mode" }.map { words[$0 + 1] }
  }

  /// The mode that each launch passed to claude, and the mode that each launch event recorded, in order.
  func launchModes(_ sbd: Instance, _ s: SessionSummary) throws -> (passed: [String?], recorded: [String?]) {
    let passed = launchLines(sbd, s).map { modesPassed($0).last }
    let recorded = try sbd.events(s.id).filter { $0.kind == "started" || $0.kind == "resumed" }.map {
      $0.data["permission_mode"]?.string
    }
    return (passed, recorded)
  }

  /// Checks that the launches passed `expected`, one mode each, and that their events recorded the same.
  func expectLaunches(
    _ sbd: Instance, _ s: SessionSummary, _ expected: [String?], sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let modes = try launchModes(sbd, s)
    #expect(modes.passed == expected, sourceLocation: sourceLocation)
    #expect(modes.recorded == expected, sourceLocation: sourceLocation)
    #expect(launchLines(sbd, s).allSatisfy { modesPassed($0).count <= 1 }, sourceLocation: sourceLocation)
  }

  // MARK: The first launch

  @Test func newWithPlanModeStartsClaudeInPlanMode() throws {
    let sbd = try instance()

    let s = try new(sbd, "--plan-mode")

    try firstReply(sbd, s.id)
    let line = try #require(launchLines(sbd, s).first)
    #expect(line.hasPrefix("--session-id \(s.claudeSessionId)"), "\(line)")
    #expect(line.hasSuffix("--permission-mode plan -- hello"), "\(line)")
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan"])
  }

  @Test func newWithPlanModeAndNoAutoStartsClaudeInPlanMode() throws {
    let sbd = try instance()

    let s = try new(sbd, "--plan-mode", "--no-auto")

    try firstReply(sbd, s.id)
    #expect(launchLines(sbd, s).first?.hasSuffix("--permission-mode plan -- hello") == true)
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan"])
  }

  // MARK: Relaunches while in plan mode

  @Test func aResumeInPlanModeKeepsPlanMode() throws {
    let sbd = try instance()
    let s = try new(sbd, "--plan-mode")
    try firstReply(sbd, s.id)

    let line = try resume(sbd, s)

    #expect(line.hasPrefix("--resume \(s.claudeSessionId)"), "\(line)")
    #expect(line.hasSuffix("--permission-mode plan -- again"), "\(line)")
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan", "plan"])
  }

  /// The resume reads the mode that sbd replays from the event log and the planMode that it loads from the session.
  @Test func aResumeAfterAnSbdRestartInPlanModeKeepsPlanMode() throws {
    let sbd = try instance()
    let s = try new(sbd, "--plan-mode")
    try firstReply(sbd, s.id)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to exit") { !$0.live }

    try sbd.restart(setting: "autoMode", to: true)
    try sbd.sb("send", s.id, "again")

    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: again" }
    let line = try #require(launchLines(sbd, s).last)
    #expect(line.hasPrefix("--resume \(s.claudeSessionId)"), "\(line)")
    #expect(line.hasSuffix("--permission-mode plan -- again"), "\(line)")
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan", "plan"])
  }

  /// Claude wrote no transcript before its first prompt, so the relaunch is a first launch.
  @Test func aRelaunchBeforeTheFirstPromptKeepsPlanMode() throws {
    let sbd = try instance()
    let s = try new(sbd, "--plan-mode", prompt: nil)
    try sbd.waitFor(s.id, "claude to start") { $0.live }
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to exit") { !$0.live }

    try sbd.sb("send", s.id, "begin")

    try sbd.waitFor(s.id, "the first turn's reply") { $0.lastReply == "Done: begin" }
    let line = try #require(launchLines(sbd, s).last)
    #expect(line.hasPrefix("--session-id \(s.claudeSessionId)"), "\(line)")
    #expect(line.hasSuffix("--permission-mode plan -- begin"), "\(line)")
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan", "plan"])
  }

  /// A queued start launches claude without the prompt and delivers the prompt as a message.
  @Test func aStartQueuedBehindTheLiveCapStartsInPlanMode() throws {
    let sbd = try instance(["liveCap": 1])
    let busy = try sbd.new(prompt: "slow 30", name: "busy")
    try sbd.waitFor(busy.id, "busy's slow tool") { $0.state == .working && $0.claudePid != nil }
    let s = try new(sbd, "--plan-mode", name: "planner")
    try sbd.waitFor(s.id, "the queued start") { $0.reason == "queued: 1 of 1 live" }

    try sbd.sb("live", "--set", "2")

    try firstReply(sbd, s.id)
    let line = try #require(launchLines(sbd, s).first)
    #expect(line.hasPrefix("--session-id \(s.claudeSessionId)"), "\(line)")
    #expect(line.hasSuffix("--permission-mode plan"), "\(line)")
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan"])
  }

  // MARK: Leaving plan mode

  /// LaunchModeTests covers the other modes that claude can report.
  @Test func aResumeAfterLeavingPlanModePassesAutoMode() throws {
    let sbd = try instance()
    let s = try new(sbd, "--plan-mode")
    try firstReply(sbd, s.id)
    try switchMode(sbd, s.id, to: "default")

    let line = try resume(sbd, s)

    #expect(line.hasPrefix("--resume \(s.claudeSessionId)"), "\(line)")
    #expect(line.hasSuffix("--permission-mode auto -- again"), "\(line)")
    #expect(try sbd.get(s.id).permissionMode == "auto")
    try expectLaunches(sbd, s, ["plan", "auto"])
  }

  /// The first resume records no mode. The second resume must not read that nil as plan mode.
  @Test func noAutoResumesAfterLeavingPlanModePassNoMode() throws {
    let sbd = try instance()
    let s = try new(sbd, "--plan-mode", "--no-auto")
    try firstReply(sbd, s.id)
    try switchMode(sbd, s.id, to: "default")

    let first = try resume(sbd, s)
    #expect(first.hasPrefix("--resume \(s.claudeSessionId)"), "\(first)")
    #expect(modesPassed(first).isEmpty, "\(first)")
    #expect(try sbd.get(s.id).permissionMode == "default")

    let second = try resume(sbd, s, "once more")
    #expect(modesPassed(second).isEmpty, "\(second)")
    try expectLaunches(sbd, s, ["plan", nil, nil])
  }

  /// The mode that a hook reported survives the replay of the event log.
  @Test func aResumeAfterAnSbdRestartOutsidePlanModePassesAutoMode() throws {
    let sbd = try instance()
    let s = try new(sbd, "--plan-mode")
    try firstReply(sbd, s.id)
    try switchMode(sbd, s.id, to: "default")
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to exit") { !$0.live }

    try sbd.restart(setting: "autoMode", to: true)
    try sbd.sb("send", s.id, "again")

    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: again" }
    let line = try #require(launchLines(sbd, s).last)
    #expect(line.hasSuffix("--permission-mode auto -- again"), "\(line)")
    try expectLaunches(sbd, s, ["plan", "auto"])
  }

  /// Only a session created with --plan-mode keeps plan mode across a resume.
  @Test func aSessionWithoutPlanModeThatReportedPlanResumesInAutoMode() throws {
    let sbd = try instance()
    let s = try new(sbd)
    try firstReply(sbd, s.id)
    try switchMode(sbd, s.id, to: "plan")

    let line = try resume(sbd, s)

    #expect(line.hasSuffix("--permission-mode auto -- again"), "\(line)")
    #expect(try sbd.get(s.id).permissionMode == "auto")
    try expectLaunches(sbd, s, ["auto", "auto"])
  }

  // MARK: sb spawn and the MCP spawn tool

  @Test func spawnWithPlanModeStartsClaudeInPlanMode() throws {
    let repos = try Repos()
    let sbd = try spawnInstance(repos)

    let s = try spawn(sbd, branch: "b1", "--plan-mode")

    try firstReply(sbd, s.id)
    #expect(launchLines(sbd, s).first?.hasSuffix("--permission-mode plan -- hello") == true)
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan"])
  }

  @Test func aStartedFollowupSpawnedWithPlanModeStartsClaudeInPlanMode() throws {
    let repos = try Repos()
    let sbd = try spawnInstance(repos)
    let f = try spawn(sbd, branch: "b1", "--plan-mode", "--followup")

    try sbd.sb("followup", "start", f.id)

    try firstReply(sbd, f.id)
    let line = try #require(launchLines(sbd, f).first)
    #expect(line.contains("--permission-mode plan"), "\(line)")
    #expect(try sbd.get(f.id).permissionMode == "plan")
    try expectLaunches(sbd, f, ["plan"])
  }

  @Test func theMCPSpawnToolWithPlanModeStartsClaudeInPlanMode() throws {
    let sbd = try instance()
    let mcp = try MCPClient(sbd)
    var args = try spawnArgs(sbd, "kid")
    args["planMode"] = true

    let s = try mcp.call("spawn", args).decode(SessionSummary.self)

    try firstReply(sbd, s.id)
    #expect(launchLines(sbd, s).first?.hasSuffix("--permission-mode plan -- hello") == true)
    #expect(try sbd.get(s.id).permissionMode == "plan")
    try expectLaunches(sbd, s, ["plan"])
  }

  // MARK: --plan names a plan document

  /// `--plan` takes a value, so a bare `--plan` swallows the next argument. sb refuses it before it calls sbd.
  @Test func planIsRefusedWithAPointerToPlanMode() throws {
    let repos = try Repos()
    let sbd = try spawnInstance(repos)
    let refused = [
      ["new", sbd.work, "--plan", "--prompt", "hi"],
      ["new", "--plan", "p1", "--prompt", "hi", sbd.work],
      ["new", "--plan-mode", "--plan", "p1", "--prompt", "hi", sbd.work],
      ["spawn", "--repo", "acme/widgets", "--branch", "b1", "--plan", "--prompt", "hi"],
      ["spawn", "--repo", "acme/widgets", "--branch", "b1", "--prompt", "hi", "--plan", "p1", "--followup"],
    ]

    for argv in refused {
      let r = try sbd.run(argv)
      #expect(r.status != 0, "\(argv)")
      #expect(r.stderr.contains("--plan-mode"), "\(argv): \(r.stderr)")
    }

    #expect(try decode([SessionSummary].self, sbd.sb("ls", "--json")).isEmpty)
    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty)
    #expect(sbd.stubArgs().isEmpty)
  }
}
