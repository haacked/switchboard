import Foundation
import SwitchboardCore
import Testing

/// `sb auto-mode` and the `auto-mode` op read and set config.json's `autoMode`. A set saves the key, applies to the
/// sessions created after it without a restart, and leaves the sessions that exist in their mode. Claude Code can't
/// set it.
@Suite(.blocking(timeLimit: .seconds(120))) struct AutoModeSettingTests {
  static let insideClaudeCode = "auto-mode on|off needs the user, so it doesn't run inside Claude Code"
  static let notABool = "auto mode is on or off"
  static let badWord = "auto-mode takes on or off"

  /// What `sb auto-mode --json` prints.
  func shown(_ sbd: Instance, env: [String: String] = [:]) throws -> JSON {
    try #require(JSON.parse(try sbd.sb(["auto-mode", "--json"], env: env)))
  }

  /// The stub's runs for the session: its launch with `--session-id` and each resume with `--resume`.
  func launches(_ sbd: Instance, _ id: String) throws -> [String] {
    let claudeSessionId = try sbd.get(id).claudeSessionId
    return sbd.stubArgs().filter { $0.contains(claudeSessionId) }
  }

  func configText(_ sbd: Instance) throws -> String {
    try String(contentsOfFile: sbd.home.config, encoding: .utf8)
  }

  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  // MARK: Reading

  @Test func aReadChangesNothingAndSaysWhatNewSessionsDo() throws {
    let sbd = try Instance()
    let before = try configText(sbd)

    #expect(try shown(sbd) == ["autoMode": false])
    #expect(try shown(sbd, env: ["CLAUDECODE": "1"]) == ["autoMode": false])
    #expect(try sbd.client.call("auto-mode") == ["autoMode": false])
    #expect(try configText(sbd) == before)
    let read = try sbd.sb("auto-mode")
    let set = try sbd.sb("auto-mode", "on")
    #expect(read.contains("New sessions start without auto mode."))
    #expect(!read.contains("Sessions that already exist keep their mode."))
    #expect(set.contains("New sessions start in auto mode."))
    #expect(set.contains("Sessions that already exist keep their mode."))
  }

  // MARK: A set applies to new sessions only

  @Test func aSetSavesAndAppliesToTheNextSessionWithoutARestart() throws {
    let sbd = try Instance()
    var config = try sbd.config()

    let printed = try #require(JSON.parse(try sbd.sb("auto-mode", "on", "--json")))

    #expect(printed == ["autoMode": true])
    config["autoMode"] = true
    #expect(try sbd.config() == config)
    let s = try sbd.new(prompt: "perm touch x")
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(sbd.stubArgs().first?.hasSuffix("--permission-mode auto -- perm touch x") == true)
    #expect(asked.permissionMode == "auto")

    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try shown(sbd) == ["autoMode": true])
  }

  @Test func offStopsPassingTheModeToNewSessionsOnly() throws {
    let sbd = try Instance(config: ["autoMode": true])
    let a = try sbd.idleSession(name: "a")
    #expect(try launches(sbd, a.id).first?.contains("--permission-mode auto") == true)

    let printed = try #require(JSON.parse(try sbd.sb("auto-mode", "off", "--json")))
    let b = try sbd.idleSession(name: "b")
    try AutoModeTests().resume(sbd, a.id, "again")

    #expect(printed == ["autoMode": false])
    let bRuns = try launches(sbd, b.id)
    #expect(bRuns.count == 1, "\(bRuns)")
    #expect(bRuns.allSatisfy { !$0.contains("--permission-mode") }, "\(bRuns)")
    #expect(try sbd.get(b.id).permissionMode == "default")
    let aRuns = try launches(sbd, a.id)
    #expect(aRuns.count == 2, "\(aRuns)")
    #expect(aRuns.last?.contains("--permission-mode auto") == true, "\(aRuns)")
    #expect(try sbd.get(a.id).permissionMode == "auto")
  }

  // MARK: Every creation path reads the setting

  /// `followup add` and `followup import` each create the follow-up's session, so both read the setting.
  @Test func anAddedAndAnImportedFollowupStartWithTheChangedSetting() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let notes = try Repos()
    let file = "\(notes.root)/Followups.md"
    try "# Followups\n\n## Open\n\n- [ ] 2026-10-26 · [acme/widgets] Fix the flag.\n"
      .write(toFile: file, atomically: true, encoding: .utf8)
    let sbd = try Instance(config: ["repoRoots": [.string(repos.root)]])

    try sbd.sb("auto-mode", "on")
    let added = try decode(sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache.")).id
    let imported = try JSONCoding.decode(JSON.self, from: try sbd.sb("followup", "import", "--json", "--file", file))
    let importedID = try #require(imported["imported"]?.array?.first?["id"]?.string)
    for id in [added, importedID] {
      try sbd.sb("followup", "start", id)
      try sbd.waitFor("claude to start") { try !launches(sbd, id).isEmpty }
      #expect(try launches(sbd, id).first?.contains("--permission-mode auto") == true, "\(id)")
    }
  }

  /// config.json leaves auto mode off, so only the set reaches the import.
  @Test func anImportedSessionStartsWithTheChangedSetting() throws {
    let sbd = try Instance(accounts: ["A"])
    let id = UUID().uuidString.lowercased()
    try sbd.writeAgents("A", [OperatorResetTests().agentRow(sbd, id, name: "unprompted")])

    try sbd.sb("auto-mode", "on")
    let s = try #require(try sbd.client.importSessions([id]).imported.first)
    #expect(try sbd.sb("send", s.id, "begin") == "resumed\n")
    try sbd.waitFor(s.id, "the first turn's reply") { $0.lastReply == "Done: begin" }

    let start = try #require(sbd.stubCalls().last { !$0.args.hasPrefix("agents") })
    #expect(start.args.hasSuffix("--permission-mode auto -- begin"))
  }

  // MARK: Refusals

  @Test func aSetInsideClaudeCodeIsRefused() throws {
    let sbd = try Instance()
    let before = try configText(sbd)

    for word in ["on", "off"] {
      let r = try sbd.run(["auto-mode", word], env: ["CLAUDECODE": "1"])
      #expect(r.status != 0, "\(word): \(text(r))")
      #expect(r.stderr.contains(Self.insideClaudeCode), "\(word): \(text(r))")
    }

    #expect(try configText(sbd) == before)
    #expect(try shown(sbd) == ["autoMode": false])
  }

  /// A value that is not a bool must fail, not read as `{}` and answer the current setting.
  @Test func aBadValueIsRefused() throws {
    let sbd = try Instance()
    let before = try configText(sbd)
    let values: [JSON] = ["yes", "true", "on", "", .number(1), .number(0), .null, [true], ["on": true]]

    for value in values {
      let error = try #require(throws: APIError.self, "\(value.text)") {
        try sbd.client.call("auto-mode", ["autoMode": value])
      }
      #expect(error.description.contains(Self.notABool), "\(value.text): \(error)")
    }
    for words in [["maybe"], ["yes"], ["true"], ["1"], ["ON"], ["enable"], ["status"], ["on", "off"]] {
      let r = try sbd.run(["auto-mode"] + words)
      #expect(r.status != 0, "\(words): \(text(r))")
      #expect(r.stderr.contains(Self.badWord), "\(words): \(text(r))")
    }

    #expect(try configText(sbd) == before)
    #expect(try shown(sbd) == ["autoMode": false])
  }

  /// `updateSettings` refuses to rewrite a config.json that isn't a JSON object. sbd keeps the old setting, because
  /// it saves before it applies.
  @Test func aConfigThatIsNotAnObjectIsNotRewritten() throws {
    let sbd = try Instance()
    try "[]".write(toFile: sbd.home.config, atomically: true, encoding: .utf8)

    let r = try sbd.run(["auto-mode", "on"])

    #expect(r.status != 0, "\(text(r))")
    #expect(try configText(sbd) == "[]")
    #expect(try sbd.client.call("auto-mode") == ["autoMode": false])
  }
}
