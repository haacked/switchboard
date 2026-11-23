import Foundation
import SwitchboardCore
import Testing

/// The model that a Manager conversation and a group chat run. sbd passes `--model` with config.json's
/// `manager.model`, which is sonnet by default. `sb manager model` shows and changes it. The operator and work
/// sessions don't take it.
@Suite(.blocking(timeLimit: .seconds(120))) struct ManagerModelTests {
  let conversationHelpers = ManagerConversationsTests()

  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  /// Runs `sb manager --json` and waits for the conversation's claude.
  func liveManager(_ sbd: Instance) throws -> SessionSummary {
    let m = try decode(sbd.sb("manager", "--json"))
    try sbd.waitFor(m.id, "the Manager's claude") { $0.live }
    return m
  }

  func live(_ sbd: Instance, _ args: String...) throws -> SessionSummary {
    let s = try decode(sbd.sb(args + ["--json"]))
    try sbd.waitFor(s.id, "\(args.joined(separator: " ")) claude") { $0.live }
    return s
  }

  func liveWorkSession(_ sbd: Instance) throws -> SessionSummary {
    try live(sbd, "new", "--name", "work", "--prompt", "hello", sbd.work)
  }

  /// The value of the `--model` in the session's latest launch, or nil when the launch has none. A launch with
  /// two `--model` flags fails the test.
  func launchModel(_ sbd: Instance, _ id: String) throws -> String? {
    let args = try conversationHelpers.scriptArgs(sbd, id)
    let flags = args.indices.filter { args[$0] == "--model" }
    try #require(flags.count <= 1, "more than one --model: \(args)")
    guard let i = flags.first else { return nil }
    try #require(i + 1 < args.count, "--model has no value: \(args)")
    return args[i + 1]
  }

  /// Stops the conversation with `sb stop` and opens it again with `sb manager`. It expects a resume.
  func relaunch(_ sbd: Instance, _ m: SessionSummary) throws {
    let before = conversationHelpers.launches(sbd, m).count
    try sbd.sb("stop", m.id)
    try sbd.waitFor(m.id, "the stop") { !$0.live }
    try sbd.sb("manager", "--json")
    let launched = try conversationHelpers.launch(sbd, m, after: before)
    try sbd.waitFor(m.id, "the resume") { $0.live }
    #expect(launched.hasPrefix("--resume \(m.claudeSessionId) "), "\(launched)")
  }

  /// What `sb manager model --json` prints.
  func shown(_ sbd: Instance, env: [String: String] = [:]) throws -> JSON {
    try #require(JSON.parse(try sbd.sb(["manager", "model", "--json"], env: env)))
  }

  @Test func aSetChangesTheNextLaunchOfEachConversationWithoutARestart() throws {
    let sbd = try Instance()
    var config = try sbd.config()
    try #require(config["manager"] == nil)
    let m = try liveManager(sbd)
    #expect(try launchModel(sbd, m.id) == "sonnet")
    #expect(try shown(sbd, env: ["CLAUDECODE": "1"]) == ["model": "sonnet"])

    let printed = try #require(JSON.parse(try sbd.sb("manager", "model", "haiku", "--json")))

    #expect(printed == ["model": "haiku"])
    #expect(try shown(sbd) == ["model": "haiku"])
    config["manager"] = ["model": "haiku"]
    #expect(try sbd.config() == config)
    try relaunch(sbd, m)
    #expect(try launchModel(sbd, m.id) == "haiku")
    let second = try live(sbd, "manager", "new")
    #expect(try launchModel(sbd, second.id) == "haiku")
    #expect(try launchModel(sbd, try liveWorkSession(sbd).id) == "opus")

    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try shown(sbd) == ["model": "haiku"])
  }

  /// The operator runs `operator.model`, and a work session runs config.json's global `model`.
  @Test func theManagerModelReachesOnlyManagerConversations() throws {
    let sbd = try Instance(config: ["model": "opus", "manager": ["model": "haiku"]])

    let m = try liveManager(sbd)
    let op = try live(sbd, "operator")
    let work = try liveWorkSession(sbd)

    #expect(try launchModel(sbd, m.id) == "haiku")
    #expect(try launchModel(sbd, op.id) == OperatorSettings.defaultModel)
    #expect(try launchModel(sbd, work.id) == "opus")
    #expect(try sbd.sb("manager", "model").contains("haiku"))
    #expect(try sbd.client.call("manager-model") == ["model": "haiku"])
  }

  @Test func theGlobalModelDoesNotReachAManagerConversation() throws {
    let sbd = try Instance(config: ["model": "opus"])
    let m = try liveManager(sbd)
    #expect(try launchModel(sbd, m.id) == "sonnet")

    try relaunch(sbd, m)

    #expect(try launchModel(sbd, m.id) == "sonnet")
  }

  @Test func theRequestKeepsTheOtherFieldsOfManager() throws {
    let sbd = try Instance(config: ["manager": ["model": "sonnet", "future": "keep"]])
    var config = try sbd.config()

    #expect(try sbd.client.call("manager-model", ["model": "haiku"]) == ["model": "haiku"])

    config["manager"] = ["model": "haiku", "future": "keep"]
    #expect(try sbd.config() == config)
  }

  @Test func aBadSetChangesNothing() throws {
    let sbd = try Instance()
    let config = try sbd.config()
    // `Args` reads a value that starts with `--` as a switch, so the command-line cases use one dash.
    let commands: [[String]] = [["-opus"], ["a b"], [""], ["hai", "ku"]]
    for words in commands {
      let r = try sbd.run(["manager", "model"] + words)
      #expect(r.status != 0, "\(words): \(text(r))")
    }
    let inside = try sbd.run(["manager", "model", "haiku"], env: ["CLAUDECODE": "1"])
    #expect(inside.status != 0, "\(text(inside))")
    let values: [JSON] = ["--opus", "a b", .number(1), ["name": "haiku"]]
    for value in values {
      #expect(throws: (any Error).self, "\(value.text)") { try sbd.client.call("manager-model", ["model": value]) }
    }

    #expect(try sbd.config() == config)
    #expect(try shown(sbd) == ["model": "sonnet"])

    // A save that fails leaves the model sbd launches with unchanged.
    try sbd.set("manager", to: "x")
    #expect(throws: (any Error).self) { try sbd.client.call("manager-model", ["model": "haiku"]) }
    #expect(try sbd.config()["manager"] == "x")
    #expect(try shown(sbd) == ["model": "sonnet"])
  }
}
