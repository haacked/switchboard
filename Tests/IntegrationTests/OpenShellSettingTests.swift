import Foundation
import SwitchboardCore
import Testing

/// `sb open-shell` and the `open-shell` op read and set config.json's `openShell`. A set saves the key and applies
/// to the work sessions created or started after it without a restart. Sessions that exist keep their shell. Unlike
/// `sb auto-mode`, Claude Code can set it.
@Suite(.blocking(timeLimit: .seconds(120))) struct OpenShellSettingTests {
  static let notABool = "open shell is on or off"
  static let badWord = "open-shell takes on or off"

  /// What `sb open-shell --json` prints.
  func shown(_ sbd: Instance, env: [String: String] = [:]) throws -> JSON {
    try #require(JSON.parse(try sbd.sb(["open-shell", "--json"], env: env)))
  }

  func configText(_ sbd: Instance) throws -> String {
    try String(contentsOfFile: sbd.home.config, encoding: .utf8)
  }

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// Each request that creates a work session and launches claude in it.
  enum Creation: String, CaseIterable, Sendable {
    case sbNew, newOp, spawn
  }

  func create(_ sbd: Instance, _ how: Creation) throws -> SessionSummary {
    switch how {
    case .sbNew:
      return try decode(SessionSummary.self, sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    case .newOp:
      return try sbd.new(prompt: "hello")
    case .spawn:
      let args: [String: JSON] = [
        "repository": .string(try sbd.makeRepo()), "branch": "b1", "name": "spawned", "prompt": "hello",
      ]
      return try sbd.client.call("spawn", args, as: SessionSummary.self)
    }
  }

  /// Sets the setting through the op, so a test of a creation path does not depend on the CLI.
  func setOpenShell(_ sbd: Instance, _ on: Bool) throws {
    #expect(try sbd.client.call("open-shell", ["openShell": .bool(on)]) == ["openShell": .bool(on)])
  }

  /// Requires that claude and the shell both run.
  func expectShellRuns(_ sbd: Instance, _ id: String) throws {
    try sbd.waitFor(id, "claude") { $0.live && $0.claudePid != nil }
    #expect(try sbd.get(id).shellClosed != true)
    try ShellPaneTests().waitForShell(sbd, try sbd.client.terminals(id))
  }

  // MARK: Reading

  @Test func aReadChangesNothingAndSaysWhatNewSessionsDo() throws {
    let sbd = try Instance()
    let before = try configText(sbd)

    #expect(try shown(sbd) == ["openShell": true])
    #expect(try sbd.client.call("open-shell") == ["openShell": true])
    #expect(try configText(sbd) == before)
    let read = try sbd.sb("open-shell")
    let set = try sbd.sb("open-shell", "off")
    #expect(read.contains("New sessions open a shell."), "\(read)")
    #expect(!read.contains("Sessions that already exist keep their shell."), "\(read)")
    #expect(set.contains("New sessions open without a shell."), "\(set)")
    #expect(set.contains("Sessions that already exist keep their shell."), "\(set)")
  }

  // MARK: A set applies to new sessions only

  @Test func aSetSavesAndSurvivesARestart() throws {
    let sbd = try Instance()
    var config = try sbd.config()

    let printed = try #require(JSON.parse(try sbd.sb("open-shell", "off", "--json")))

    #expect(printed == ["openShell": false])
    config["openShell"] = false
    #expect(try sbd.config() == config)

    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try shown(sbd) == ["openShell": false])
    #expect(try JSON.parse(try sbd.sb("open-shell", "on", "--json")) == ["openShell": true])
    #expect(try sbd.config()["openShell"] == true)
  }

  /// sbd reads the setting from config.json when it starts.
  @Test func aConfigWithTheSettingOffStartsSessionsWithoutAShell() throws {
    let sbd = try Instance(config: ["openShell": false])

    let s = try sbd.new(prompt: "hello")

    #expect(try sbd.client.call("open-shell") == ["openShell": false])
    #expect(s.shellClosed == true)
    try sbd.expectShellAbsent(s.id)
  }

  @Test(arguments: Creation.allCases) func aWorkSessionCreatedWhileOffStartsWithoutAShell(_ how: Creation) throws {
    let sbd = try Instance()
    try setOpenShell(sbd, false)

    let s = try create(sbd, how)

    #expect(s.shellClosed == true)
    try sbd.expectShellAbsent(s.id)
  }

  @Test func turningTheSettingOnAgainOpensTheShellOfLaterSessions() throws {
    let sbd = try Instance()
    try setOpenShell(sbd, false)
    try setOpenShell(sbd, true)

    let s = try sbd.new(prompt: "hello")

    #expect(s.shellClosed != true)
    try expectShellRuns(sbd, s.id)
  }

  @Test func offLeavesTheOpenShellOfAnExistingSessionOpen() throws {
    let sbd = try Instance()
    let a = try sbd.idleSession(name: "a")
    try expectShellRuns(sbd, a.id)
    let shell = try sbd.client.terminals(a.id).shell

    try setOpenShell(sbd, false)

    #expect(try sbd.get(a.id).shellClosed != true)
    #expect(try sbd.hasTmuxSession(shell))
  }

  /// A `terminals` request starts a missing shell again, so it must read the session's flag and not the setting.
  @Test func anExistingSessionKeepsItsShellWhenItResumesAfterOff() throws {
    let sbd = try Instance()
    let a = try sbd.idleSession(name: "a")
    try expectShellRuns(sbd, a.id)
    let shell = try sbd.client.terminals(a.id).shell

    try setOpenShell(sbd, false)
    #expect(try sbd.tmux("kill-session", "-t", "=\(shell)").status == 0)
    try AutoModeTests().resume(sbd, a.id, "again")

    try expectShellRuns(sbd, a.id)
  }

  /// A `terminals` request after a restart starts a missing shell again, so it must read the session's flag and not the setting.
  @Test func anExistingSessionKeepsItsShellAfterSbdRestartsWithTheSettingOff() throws {
    let sbd = try Instance()
    let a = try sbd.idleSession(name: "a")
    try expectShellRuns(sbd, a.id)
    let shell = try sbd.client.terminals(a.id).shell

    try setOpenShell(sbd, false)
    #expect(try sbd.tmux("kill-session", "-t", "=\(shell)").status == 0)
    sbd.stopSbd()
    try sbd.startSbd()

    try expectShellRuns(sbd, a.id)
  }

  @Test func shellOpenOpensTheShellOfASessionCreatedWhileOff() throws {
    let sbd = try Instance()
    try setOpenShell(sbd, false)
    let s = try sbd.waitFor(try sbd.new(prompt: "hello").id, "claude") { $0.live && $0.claudePid != nil }
    let t = try sbd.client.terminals(s.id)

    let opened = try decode(SessionSummary.self, sbd.sb("shell", s.id, "--open", "--json"))

    #expect(opened.shellClosed != true)
    #expect(try sbd.hasTmuxSession(t.shell))
    try ShellPaneTests().waitForShell(sbd, t)
    #expect(try sbd.get(s.id).claudePid == s.claudePid)
  }

  // MARK: Every creation path reads the setting

  /// config.json leaves the setting on, so only the set reaches the import.
  @Test func anImportedSessionStartsWithoutAShellWhileOff() throws {
    let sbd = try Instance(accounts: ["A"])
    let id = UUID().uuidString.lowercased()
    try sbd.writeAgents("A", [OperatorResetTests().agentRow(sbd, id, name: "unprompted")])

    try setOpenShell(sbd, false)
    let s = try #require(try sbd.client.importSessions([id]).imported.first)
    #expect(s.shellClosed == true)
    #expect(try sbd.sb("send", s.id, "begin") == "resumed\n")
    try sbd.waitFor(s.id, "the first turn's reply") { $0.lastReply == "Done: begin" }

    try sbd.expectShellAbsent(s.id)
  }

  /// `followup add` and `followup import` each create a follow-up that has not started.
  enum FollowupSource: String, CaseIterable, Sendable {
    case added, imported
  }

  /// A sbd that knows acme/widgets, and a Followups.md with one open item for it. `Repos` deletes its folder when
  /// it is freed, so the bench keeps both folders.
  struct FollowupBench {
    let repos: Repos
    let notes: Repos
    let sbd: Instance
    var file: String { "\(notes.root)/Followups.md" }

    init() throws {
      repos = try Repos()
      try repos.make("acme/widgets")
      notes = try Repos()
      sbd = try Instance(config: ["repoRoots": [.string(repos.root)]])
      try "# Followups\n\n## Open\n\n- [ ] 2026-10-26 · [acme/widgets] Fix the flag.\n"
        .write(toFile: file, atomically: true, encoding: .utf8)
    }
  }

  func followup(_ sbd: Instance, _ source: FollowupSource, file: String) throws -> String {
    switch source {
    case .added:
      return try decode(SessionSummary.self, sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "Fix it."))
        .id
    case .imported:
      let imported = try decode(JSON.self, sbd.sb("followup", "import", "--json", "--file", file))
      return try #require(imported["imported"]?.array?.first?["id"]?.string)
    }
  }

  func start(_ sbd: Instance, _ id: String) throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb("followup", "start", "--json", id))
  }

  /// sbd reads the setting when the follow-up starts, not when it is added.
  @Test(arguments: FollowupSource.allCases)
  func aFollowupAddedWhileOnAndStartedWhileOffStartsWithoutAShell(_ source: FollowupSource) throws {
    let bench = try FollowupBench()
    let (sbd, file) = (bench.sbd, bench.file)
    let id = try followup(sbd, source, file: file)
    try setOpenShell(sbd, false)

    let started = try start(sbd, id)

    #expect(started.shellClosed == true)
    try sbd.expectShellAbsent(id)
    withExtendedLifetime(bench) {}
  }

  @Test func aFollowupAddedWhileOffAndStartedWhileOnStartsWithItsShell() throws {
    let bench = try FollowupBench()
    let (sbd, file) = (bench.sbd, bench.file)
    try setOpenShell(sbd, false)
    let id = try followup(sbd, .added, file: file)
    try setOpenShell(sbd, true)

    let started = try start(sbd, id)

    #expect(started.shellClosed != true)
    try expectShellRuns(sbd, id)
    withExtendedLifetime(bench) {}
  }

  // MARK: Claude Code may set it

  @Test func aSetInsideClaudeCodeIsSaved() throws {
    let sbd = try Instance()
    let env = ["CLAUDECODE": "1"]

    let r = try sbd.run(["open-shell", "off"], env: env)

    #expect(r.status == 0, "\(text(r))")
    #expect(try sbd.config()["openShell"] == false)
    #expect(try shown(sbd, env: env) == ["openShell": false])
  }

  // MARK: Refusals

  /// A value that is not a bool must fail, not read as `{}` and answer the current setting.
  @Test func aBadValueIsRefused() throws {
    let sbd = try Instance()
    let before = try configText(sbd)
    let values: [JSON] = ["yes", "false", "off", "", .number(1), .number(0), .null, [false], ["off": true]]

    for value in values {
      let error = try #require(throws: APIError.self, "\(value.text)") {
        try sbd.client.call("open-shell", ["openShell": value])
      }
      #expect(error.description.contains(Self.notABool), "\(value.text): \(error)")
    }
    for words in [["maybe"], ["no"], ["false"], ["0"], ["OFF"], ["disable"], ["status"], ["off", "on"]] {
      let r = try sbd.run(["open-shell"] + words)
      #expect(r.status != 0, "\(words): \(text(r))")
      #expect(r.stderr.contains(Self.badWord), "\(words): \(text(r))")
    }

    #expect(try configText(sbd) == before)
    #expect(try shown(sbd) == ["openShell": true])
  }

  /// `updateSettings` refuses to rewrite a config.json that isn't a JSON object. sbd keeps the old setting, because
  /// it saves before it applies.
  @Test func aConfigThatIsNotAnObjectIsNotRewritten() throws {
    let sbd = try Instance()
    try "[]".write(toFile: sbd.home.config, atomically: true, encoding: .utf8)

    let r = try sbd.run(["open-shell", "off"])

    #expect(r.status != 0, "\(text(r))")
    #expect(try configText(sbd) == "[]")
    #expect(try sbd.client.call("open-shell") == ["openShell": true])
  }
}
