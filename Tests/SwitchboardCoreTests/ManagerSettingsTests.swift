import Foundation
import Testing

@testable import SwitchboardCore

/// config.json's `manager` section and the environment it gives a Manager conversation's claude.
@Suite struct ManagerSettingsTests {
  static let windowKey = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"

  /// The environment that the config's Manager settings give a pane whose environment was `env`.
  func applied(_ configJSON: String, to env: [String: String] = [:]) throws -> [String: String] {
    var env = env
    AutoCompact.apply(window: try JSONCoding.decode(Config.self, from: configJSON).manager.autoCompactWindow, to: &env)
    return env
  }

  @Test(arguments: ["{}", #"{"manager": {}}"#])
  func withoutAWindowTheConversationGets183k(_ configJSON: String) throws {
    #expect(try applied(configJSON) == [Self.windowKey: "183000"])
  }

  @Test func configSetsTheWindow() throws {
    #expect(try applied(#"{"manager": {"autoCompactWindow": 250000}}"#) == [Self.windowKey: "250000"])
  }

  @Test(arguments: [0, -1])
  func aWindowOfZeroOrLessSetsNothing(_ window: Int) throws {
    #expect(try applied(#"{"manager": {"autoCompactWindow": \#(window)}}"#).isEmpty)
  }

  @Test func theWindowReplacesTheSameVariableFromConfigEnv() throws {
    let env = try applied("{}", to: [Self.windowKey: "500000", "SB_SESSION_ID": "s"])

    #expect(env == [Self.windowKey: "183000", "SB_SESSION_ID": "s"])
  }

  @Test func zeroLeavesTheVariableFromConfigEnv() throws {
    let env = try applied(#"{"manager": {"autoCompactWindow": 0}}"#, to: [Self.windowKey: "500000"])

    #expect(env == [Self.windowKey: "500000"])
  }

  @Test func theSettingRoundTripsThroughConfig() throws {
    var config = Config()
    config.manager.autoCompactWindow = 200_000

    let decoded = try JSONCoding.decode(Config.self, from: try JSON(encoding: config).text)

    #expect(decoded.manager.autoCompactWindow == 200_000)
  }

  // MARK: Decoding

  @Test(arguments: ["{}", #"{"manager": {}}"#, #"{"manager": {"future": 1}}"#, #"{"model": "opus"}"#])
  func configWithoutAManagerModelRunsSonnet(_ text: String) throws {
    #expect(try JSONCoding.decode(Config.self, from: text).manager.model == "sonnet")
  }

  @Test func configReadsTheManagerModelApartFromTheGlobalModel() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"manager": {"model": "haiku"}}"#)

    #expect(c.manager.model == "haiku")
    #expect(c.model == "opus")
  }

  @Test(arguments: [#""""#, #"" ""#, #""-p""#, #""--model""#, #""a b""#, #"" haiku""#, "5", "true", "[]"])
  func aBadManagerModelFallsBackToSonnet(_ value: String) throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"manager": {"model": \#(value)}, "branchPrefix": "haacked/"}"#)

    #expect(c.manager.model == "sonnet")
    #expect(c.branchPrefix == "haacked/")
  }

  // MARK: Model names

  @Test(arguments: ["", " ", "a b", "a\tb", " haiku", "haiku\n", "a\u{00A0}b", "-p", "--model"])
  func aBadModelNameHasAProblem(_ model: String) {
    #expect(Manager.modelProblem(model) != nil)
  }

  @Test(arguments: ["sonnet", "opus", "claude-sonnet-5-5", "sonnet[1m]"])
  func aModelNameHasNoProblem(_ model: String) {
    #expect(Manager.modelProblem(model) == nil)
  }
}
