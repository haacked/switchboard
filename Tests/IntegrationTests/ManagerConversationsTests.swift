import Foundation
import SwitchboardCore
import Testing

/// Several Manager conversations, each a session of kind `manager` in the
/// Manager folder. A new conversation starts with a digest of the board and
/// launches with only the switchboard MCP server. `sb manager mcp` changes
/// its servers, and each change relaunches claude with `--resume`.
@Suite(.blocking(timeLimit: .seconds(120))) struct ManagerConversationsTests {
  /// The key of a `sent` event's data that names the session that sent it.
  static let senderKey = "from"
  /// The key of `sb manager mcp <conv> --json` that lists the named servers.
  static let serversKey = "servers"

  static let sharedServers: [String: JSON] = [
    "mcpServers": ["grafana": Instance.stubServer("grafana"), "posthog-db": Instance.stubServer("posthog-db")]
  ]

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  /// Starts a conversation with `sb manager new`.
  func newConversation(_ sbd: Instance, name: String? = nil, _ text: String? = nil) throws -> SessionSummary {
    var args = ["manager", "new", "--json"]
    if let name { args += ["--name", name] }
    if let text { args.append(text) }
    return try decode(SessionSummary.self, sbd.sb(args))
  }

  /// A conversation whose first turn, for `text`, has ended. It sends `text`
  /// with `sb send`, so only `firstPromptStartsTheConversation` depends on the
  /// text that `sb manager new` takes.
  func idleConversation(_ sbd: Instance, name: String? = nil, _ text: String = "hello") throws -> SessionSummary {
    let c = try newConversation(sbd, name: name)
    try sbd.waitFor(c.id, "the stub") { $0.live }
    try sbd.sb("send", c.id, text)
    return try sbd.waitFor(c.id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  func conversations(_ sbd: Instance) throws -> [SessionSummary] {
    try decode([SessionSummary].self, sbd.sb("manager", "ls", "--json"))
  }

  /// Each launch of the session's claude, as the stub recorded its arguments, oldest first.
  func launches(_ sbd: Instance, _ s: SessionSummary) -> [String] {
    sbd.stubArgs().filter { $0.contains(s.claudeSessionId) }
  }

  /// Waits for a launch after the first `count` and returns it.
  @discardableResult
  func launch(_ sbd: Instance, _ s: SessionSummary, after count: Int, timeout: Double = 30) throws -> String {
    try sbd.waitFor("launch \(count + 1) of \(s.id)", timeout: timeout, fetch: { launches(sbd, s) }) {
      $0.count > count
    }[count]
  }

  /// The arguments in the session's claude.sh, which holds the latest launch. sh reads the quoting.
  func scriptArgs(_ sbd: Instance, _ id: String) throws -> [String] {
    let text = try String(contentsOfFile: "\(sbd.home.sessionFolder(id))/claude.sh", encoding: .utf8)
    let line = try #require(text.split(separator: "\n").last { !$0.hasPrefix("#") }.map(String.init))
    let r = try runCommand("/bin/sh", ["-c", #"eval "set -- $1"; printf '%s\0' "$@""#, "sh", line])
    try #require(r.status == 0, "sh could not read claude.sh: \(r.stderr)")
    return r.stdout.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
  }

  /// The config of each --mcp-config in the arguments. A value is inline JSON or the path of a file.
  func mcpConfigs(_ args: [String]) -> [JSON] {
    args.indices.dropLast().filter { args[$0] == "--mcp-config" }.compactMap { i in
      let value = args[i + 1]
      return JSON.parse(value) ?? (try? String(contentsOfFile: value, encoding: .utf8)).flatMap(JSON.parse)
    }
  }

  /// Every MCP server that the --mcp-config flags in the arguments name.
  func serverNames(_ args: [String]) -> Set<String> {
    Set(mcpConfigs(args).flatMap { $0["mcpServers"]?.object?.keys.map { $0 } ?? [] })
  }

  /// The server's entry in the --mcp-config flags of the arguments.
  func entry(_ args: [String], _ name: String) -> JSON? {
    mcpConfigs(args).lazy.compactMap { $0["mcpServers"]?[name] }.first
  }

  /// The shared server's entry in mcp-config.json.
  func sharedEntry(_ sbd: Instance, _ name: String) throws -> JSON {
    let text = try String(contentsOfFile: sbd.home.mcpConfig, encoding: .utf8)
    return try #require(JSON.parse(text)?["mcpServers"]?[name])
  }

  /// Requires a launch with `--strict-mcp-config` and only the switchboard server.
  func requireSwitchboardOnly(_ sbd: Instance, _ id: String) throws {
    let args = try scriptArgs(sbd, id)
    try #require(args.contains("--strict-mcp-config"), "\(args)")
    try #require(!args.contains(sbd.home.mcpConfig), "\(args)")
    try #require(serverNames(args) == ["switchboard"], "\(args)")
  }

  /// Runs `sb manager mcp` on the conversation and waits for the relaunch that applies it.
  @discardableResult
  func changeServers(_ sbd: Instance, _ c: SessionSummary, _ change: String...) throws -> [String] {
    let before = launches(sbd, c).count
    try sbd.sb(["manager", "mcp", c.id] + change)
    let launched = try launch(sbd, c, after: before)
    #expect(launched.hasPrefix("--resume \(c.claudeSessionId) "), "\(launched)")
    return try scriptArgs(sbd, c.id)
  }

  /// The account folder that the session's claude runs under.
  func accountFolder(_ sbd: Instance, _ s: SessionSummary) throws -> String {
    try #require(s.account ?? sbd.inheritedAccount)
  }

  /// Adds user-scope MCP servers to the account's Claude config, keeping what the file already holds.
  func addUserServers(_ folder: String, _ servers: [String: JSON]) throws {
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let path = "\(folder)/.claude.json"
    var config = (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(JSON.parse)?.object ?? [:]
    var existing = config["mcpServers"]?.object ?? [:]
    existing.merge(servers) { $1 }
    config["mcpServers"] = .object(existing)
    try JSON.object(config).text.write(toFile: path, atomically: true, encoding: .utf8)
  }

  static let userServer: JSON = ["type": "stdio", "command": "/bin/cat", "args": ["--notes"]]

  // MARK: Conversations

  @Test func newTwiceGivesTwoManagerSessionsInTheManagerFolder() throws {
    let sbd = try Instance()

    let first = try newConversation(sbd, "first question")
    let second = try newConversation(sbd, "second question")

    try #require(first.id != second.id)
    for c in [first, second] {
      #expect(c.kind == .manager)
      #expect(c.manager == true)
      #expect(c.cwd == sbd.home.managerFolder)
    }
    #expect(first.claudeSessionId != second.claudeSessionId)
    #expect(try String(contentsOfFile: "\(sbd.home.managerFolder)/CLAUDE.md", encoding: .utf8) == Manager.guide)
  }

  @Test func managerLsListsEveryConversationAndNoOtherSession() throws {
    let sbd = try Instance()
    let work = try sbd.new(name: "work")
    _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags", work.id))
    let chat = try decode(SessionSummary.self, sbd.sb("chat", "Flags", "--json"))
    let first = try newConversation(sbd, "first question")
    let second = try newConversation(sbd, "second question")
    try #require(first.id != second.id)

    let listed = try conversations(sbd)

    #expect(Set(listed.map(\.id)) == [first.id, second.id])
    #expect(!listed.contains { $0.id == work.id || $0.id == chat.id })
  }

  @Test func bareManagerOpensTheMostRecentConversation() throws {
    let sbd = try Instance()
    let first = try idleConversation(sbd, "first question")
    let second = try idleConversation(sbd, "second question")
    try #require(first.id != second.id)

    let opened = try decode(SessionSummary.self, sbd.sb("manager", "--json"))

    #expect(opened.id == second.id)
  }

  @Test func eachConversationResumesByItsOwnClaudeSession() throws {
    let sbd = try Instance()
    let first = try idleConversation(sbd, "first question")
    let second = try idleConversation(sbd, "second question")
    try #require(first.id != second.id)
    try sbd.stopClaude(first.id)
    try sbd.stopClaude(second.id)
    let before = launches(sbd, first).count

    let opened = try decode(SessionSummary.self, sbd.sb("manager", first.id, "--json"))

    #expect(opened.id == first.id)
    let launched = try launch(sbd, first, after: before)
    #expect(launched.hasPrefix("--resume \(first.claudeSessionId) "))
    #expect(!launched.contains(second.claudeSessionId))
    #expect(try sbd.get(second.id).live == false)
  }

  /// How a command names a conversation.
  enum Naming: CaseIterable { case id, name }

  @Test(arguments: Naming.allCases) func managerWithANameAndTextSendsToThatConversation(_ how: Naming) throws {
    let sbd = try Instance()
    let target = try idleConversation(sbd, name: "Cache work", "hello")
    let other = try idleConversation(sbd, name: "Docs work", "hello")
    try #require(target.id != other.id)

    let reply = try decode(
      JSON.self, sbd.sb("manager", how == .id ? target.id : target.name, "second", "turn", "--json"))

    #expect(reply["id"]?.string == target.id)
    try sbd.waitFor(target.id, "the second reply") { $0.lastReply == "Done: second turn" }
    #expect(try sbd.get(other.id).lastReply == "Done: hello")
  }

  @Test func managerLogReadsThatConversationsMessages() throws {
    let sbd = try Instance()
    let target = try idleConversation(sbd, name: "Cache work", "hello")
    _ = try idleConversation(sbd, name: "Docs work", "other")

    let log = try decode([ChatMessage].self, sbd.sb("manager", "Cache work", "--log", "--json"))

    #expect(log.map { "\($0.role): \($0.text)" } == ["user: hello", "assistant: Done: hello"])
    #expect(try sbd.get(target.id).lastReply == "Done: hello")
  }

  @Test func chatLogReadsAnySessionThatSessionNames() throws {
    let sbd = try Instance()
    let work = try sbd.new(prompt: "hello", name: "work")
    try sbd.waitFor(work.id, "its reply") { $0.lastReply == "Done: hello" }

    let log = try JSONCoding.convert(
      sbd.client.call("chat-log", ["session": .string(work.id)]), to: [ChatMessage].self)

    #expect(log.map { "\($0.role): \($0.text)" } == ["user: hello", "assistant: Done: hello"])
  }

  struct NameCase: Sendable, CustomTestStringConvertible {
    let label: String
    let name: String?
    let prompt: String
    let expected: String
    var testDescription: String { label }
  }

  static let nameCases: [NameCase] = [
    NameCase(label: "short prompt", name: nil, prompt: "hello", expected: "hello"),
    NameCase(
      label: "exactly 40 characters", name: nil, prompt: String(repeating: "a", count: 40),
      expected: String(repeating: "a", count: 40)),
    NameCase(
      label: "41 characters", name: nil, prompt: String(repeating: "abcdefghij", count: 4) + "k",
      expected: String(repeating: "abcdefghij", count: 4)),
    NameCase(label: "two lines", name: nil, prompt: "Fix the cache\nThen open a PR", expected: "Fix the cache"),
    NameCase(
      label: "multibyte at 40", name: nil, prompt: String(repeating: "a", count: 39) + "éz",
      expected: String(repeating: "a", count: 39) + "é"),
    NameCase(label: "--name wins", name: "Cache work", prompt: "hello", expected: "Cache work"),
  ]

  @Test(arguments: nameCases) func aConversationIsNamedForTheFirstLineOfItsFirstPrompt(_ c: NameCase) throws {
    let sbd = try Instance()

    let created = try newConversation(sbd, name: c.name, c.prompt)

    #expect(created.name == c.expected)
    #expect(try sbd.get(created.id).name == c.expected)
  }

  @Test func anUntitledConversationIsNamedByItsFirstPrompt() throws {
    let sbd = try Instance()

    let c = try idleConversation(sbd, "Fix the cache")

    #expect(c.name == "Fix the cache")
    #expect(try sbd.events(c.id).contains { $0.kind == "renamed" })
  }

  @Test func firstPromptStartsTheConversation() throws {
    let sbd = try Instance()

    let c = try newConversation(sbd, "hello")

    try sbd.waitFor(c.id, "the reply", timeout: 30) { $0.lastReply == "Done: hello" }
    #expect(launches(sbd, c).first?.hasSuffix("-- hello") == true, "\(launches(sbd, c))")
  }

  // MARK: MCP servers

  @Test func aNewConversationLaunchesWithOnlyTheSwitchboardServer() throws {
    let sbd = try Instance(config: Self.sharedServers)

    let c = try idleConversation(sbd)

    let args = try scriptArgs(sbd, c.id)
    #expect(args.contains("--strict-mcp-config"))
    #expect(!args.contains(sbd.home.mcpConfig))
    #expect(serverNames(args) == ["switchboard"])
    #expect(launches(sbd, c).allSatisfy { MCPToolServerTests.switchboardConfig(in: $0) != nil })
  }

  @Test func aSessionTheConversationSpawnsLaunchesWithTheFullSetup() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    let kid = try mcp.call(
      "spawn",
      ["repository": .string(try sbd.makeRepo()), "branch": "kid", "name": "kid", "prompt": "hello"]
    ).decode(SessionSummary.self)
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }

    let args = try scriptArgs(sbd, kid.id)
    #expect(!args.contains("--strict-mcp-config"))
    #expect(args.contains(sbd.home.mcpConfig))
  }

  @Test func addingASharedServerRelaunchesWithThatServersEntryOnly() throws {
    let sbd = try Instance(config: Self.sharedServers)
    _ = try sbd.waitForRunning("grafana")
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)

    let args = try changeServers(sbd, c, "add", "grafana")

    #expect(args.contains("--strict-mcp-config"))
    #expect(!args.contains(sbd.home.mcpConfig))
    #expect(serverNames(args) == ["grafana", "switchboard"])
    #expect(entry(args, "grafana") == (try sharedEntry(sbd, "grafana")))
    #expect(MCPToolServerTests.switchboardConfig(in: launches(sbd, c).last ?? "") != nil)
  }

  @Test func addingAUserScopeServerCopiesItsEntryFromTheAccountsClaudeConfig() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try addUserServers(try accountFolder(sbd, c), ["notes": Self.userServer])

    let args = try changeServers(sbd, c, "add", "notes")

    #expect(args.contains("--strict-mcp-config"))
    #expect(serverNames(args) == ["notes", "switchboard"])
    #expect(entry(args, "notes") == Self.userServer)
  }

  @Test func aSharedServerWinsOverAUserScopeServerOfTheSameName() throws {
    let sbd = try Instance(config: Self.sharedServers)
    _ = try sbd.waitForRunning("grafana")
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try addUserServers(try accountFolder(sbd, c), ["grafana": Self.userServer])

    let args = try changeServers(sbd, c, "add", "grafana")

    #expect(entry(args, "grafana") == (try sharedEntry(sbd, "grafana")))
  }

  @Test func aNameInNoConfigIsRefusedWithTheNamesThatExist() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try addUserServers(try accountFolder(sbd, c), ["notes": Self.userServer])
    let before = launches(sbd, c).count

    let refused = try sbd.run(["manager", "mcp", c.id, "add", "nosuch"])

    #expect(refused.status != 0)
    for name in ["nosuch", "grafana", "posthog-db", "notes"] {
      #expect(refused.stderr.contains(name), "\(refused.stderr)")
    }
    Thread.sleep(forTimeInterval: 1)
    #expect(launches(sbd, c).count == before)
    #expect(try serverNames(scriptArgs(sbd, c.id)) == ["switchboard"])
  }

  @Test func aRefusedNameLeavesTheOtherNamesOfTheSameChangeUnapplied() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    let before = launches(sbd, c).count

    let refused = try sbd.run(["manager", "mcp", c.id, "add", "grafana", "nosuch"])

    #expect(refused.status != 0)
    Thread.sleep(forTimeInterval: 1)
    #expect(launches(sbd, c).count == before)
    let shown = try decode(JSON.self, sbd.sb("manager", "mcp", c.id, "--json"))
    #expect(shown[Self.serversKey] == [], "\(shown.text)")
  }

  @Test func mcpWithNoChangeShowsTheConversationsServers() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try changeServers(sbd, c, "add", "grafana")

    let shown = try decode(JSON.self, sbd.sb("manager", "mcp", c.id, "--json"))

    #expect(shown[Self.serversKey] == ["grafana"], "\(shown.text)")
  }

  @Test func rmRemovesOneServerAndKeepsTheOthers() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try changeServers(sbd, c, "add", "grafana", "posthog-db")

    let args = try changeServers(sbd, c, "rm", "grafana")

    #expect(args.contains("--strict-mcp-config"))
    #expect(serverNames(args) == ["posthog-db", "switchboard"])
  }

  @Test func allLaunchesWithTheFullSetup() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)

    let args = try changeServers(sbd, c, "--all")

    #expect(!args.contains("--strict-mcp-config"))
    #expect(args.contains(sbd.home.mcpConfig))
    #expect(serverNames(args).isSuperset(of: ["switchboard", "grafana", "posthog-db"]))
  }

  @Test func noneReturnsToTheSwitchboardServerOnly() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    let all = try changeServers(sbd, c, "--all")
    try #require(!all.contains("--strict-mcp-config"))

    let args = try changeServers(sbd, c, "--none")

    #expect(args.contains("--strict-mcp-config"))
    #expect(!args.contains(sbd.home.mcpConfig))
    #expect(serverNames(args) == ["switchboard"])
  }

  @Test func aChangeDuringATurnAppliesAfterTheTurnEnds() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try sbd.sb("send", c.id, "slow 4")
    try sbd.waitFor(c.id, "the slow turn") { $0.state == .working }
    let before = launches(sbd, c).count

    try sbd.sb("manager", "mcp", c.id, "add", "grafana")

    Thread.sleep(forTimeInterval: 1)
    #expect(launches(sbd, c).count == before)
    #expect(try sbd.get(c.id).state == .working)
    try sbd.waitFor(c.id, "the end of the slow turn", timeout: 30) { $0.lastReply == "Slept 4 s." }
    let launched = try launch(sbd, c, after: before)
    #expect(launched.hasPrefix("--resume \(c.claudeSessionId) "))
    #expect(serverNames(try scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
    let stop = try #require(try sbd.events(c.id).last { $0.kind == "Stop" }?.t)
    let resumed = try #require(try sbd.events(c.id).last { $0.kind == "resumed" }?.t)
    #expect(resumed >= stop)
  }

  @Test func aConversationStoppedBeforeItsTurnEndsStaysStopped() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    // The stub finishes its sleep before it handles SIGTERM, so the turn is short.
    try sbd.sb("send", c.id, "slow 3")
    try sbd.waitFor(c.id, "the slow turn") { $0.state == .working }
    try sbd.sb("manager", "mcp", c.id, "add", "grafana")
    let before = launches(sbd, c).count

    try sbd.stopClaude(c.id)

    Thread.sleep(forTimeInterval: 1.5)
    #expect(launches(sbd, c).count == before)
    _ = try sbd.sb("manager", c.id, "--json")
    _ = try launch(sbd, c, after: before)
    #expect(serverNames(try scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
  }

  @Test func theSwitchboardNameIsNeverAdded() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    try addUserServers(try accountFolder(sbd, c), ["switchboard": Self.userServer])

    let refused = try sbd.run(["manager", "mcp", c.id, "add", "switchboard"])

    #expect(refused.status != 0)
    #expect(try serverNames(scriptArgs(sbd, c.id)) == ["switchboard"])
  }

  @Test func aChangeToAStoppedConversationAppliesAtItsNextLaunch() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try sbd.stopClaude(c.id)
    let before = launches(sbd, c).count

    try sbd.sb("manager", "mcp", c.id, "add", "grafana")
    _ = try sbd.sb("manager", c.id, "--json")

    let launched = try launch(sbd, c, after: before)
    #expect(launched.hasPrefix("--resume \(c.claudeSessionId) "))
    #expect(serverNames(try scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
  }

  @Test func aRepeatedNameInOneAddIsAddedOnce() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)

    let args = try changeServers(sbd, c, "add", "grafana", "grafana")

    #expect(serverNames(args) == ["grafana", "switchboard"])
    let shown = try decode(JSON.self, sbd.sb("manager", "mcp", c.id, "--json"))
    #expect(shown[Self.serversKey] == ["grafana"], "\(shown.text)")
  }

  @Test func aSecondChangeWhileClaudeExitsRelaunchesWithBoth() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    let before = launches(sbd, c).count

    try sbd.sb("manager", "mcp", c.id, "add", "grafana")
    try sbd.sb("manager", "mcp", c.id, "add", "posthog-db")

    _ = try launch(sbd, c, after: before)
    // Under load the second change can land after the first relaunch, which relaunches claude again.
    try sbd.waitFor("a launch with both servers and no relaunch due") {
      let shown = try decode(JSON.self, sbd.sb("manager", "mcp", c.id, "--json"))
      return try serverNames(scriptArgs(sbd, c.id)) == ["grafana", "posthog-db", "switchboard"]
        && shown["pending"]?.bool == false
    }
  }

  @Test func aChangeWaitsForARunningBackgroundJob() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    defer { if let job = sbd.stubPid("job.pid") { kill(job, SIGTERM) } }
    try sbd.sb("send", c.id, "background 100 held")
    try sbd.waitFor(c.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
    // The tick that this runs puts the job in sbd's process list.
    try sbd.advanceClock(1)
    let before = launches(sbd, c).count

    try sbd.sb("manager", "mcp", c.id, "add", "grafana")

    Thread.sleep(forTimeInterval: 1.5)
    #expect(launches(sbd, c).count == before)
    try sbd.endJob()
    _ = try launch(sbd, c, after: before)
    #expect(serverNames(try scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
  }

  /// The stub holds the launch before SessionStart until `hold-start` is
  /// removed. After 10 s the tick counts that claude as live, but its prompt
  /// hasn't arrived, so the change waits.
  @Test func aServerChangeWaitsForAClaudeThatIsStillStarting() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the stop") { $0.claudePid == nil }
    let hold = "\(sbd.home.path)/hold-start"
    FileManager.default.createFile(atPath: hold, contents: nil)
    let mark = try #require(try sbd.events(c.id).last?.id)
    try sbd.sb("send", c.id, "next")
    try sbd.waitFor(c.id, "the held claude") { $0.claudePid != nil }
    try sbd.advanceClock(1)
    try sbd.advanceClock(11_000)
    try sbd.waitFor("the 10 s fallback") { try sbd.events(c.id, after: mark).contains { $0.kind == "running" } }

    try sbd.sb("manager", "mcp", c.id, "add", "grafana")
    try sbd.advanceClock(1)
    sleep(1)

    #expect(try !sbd.events(c.id, after: mark).contains { $0.kind == "stopped" })
    try FileManager.default.removeItem(atPath: hold)
    try sbd.waitFor(c.id, "the reply to next", timeout: 30) { $0.lastReply == "Done: next" }
  }

  @Test func aSendDuringTheRelaunchLeavesALaterStopStopped() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    try sbd.sb("manager", "mcp", c.id, "add", "grafana")
    try sbd.waitFor(c.id, "the stop for the new servers") { !$0.live }

    try sbd.sb("send", c.id, "next")

    try sbd.waitFor(c.id, "the reply to next", timeout: 30) { $0.lastReply == "Done: next" }
    let shown = try decode(JSON.self, sbd.sb("manager", "mcp", c.id, "--json"))
    #expect(shown["pending"]?.bool == false, "\(shown.text)")
    #expect(serverNames(try scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
    let before = launches(sbd, c).count
    try sbd.stopClaude(c.id)
    Thread.sleep(forTimeInterval: 2)
    #expect(launches(sbd, c).count == before)
  }

  @Test func addAndRmAreRefusedOnAConversationWithTheFullSetup() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try changeServers(sbd, c, "--all")
    let before = launches(sbd, c).count

    for change in [["add", "grafana"], ["rm", "grafana"]] {
      let refused = try sbd.run(["manager", "mcp", c.id] + change)
      #expect(refused.status != 0)
      #expect(refused.stderr.contains("--none"), "\(refused.stderr)")
    }

    Thread.sleep(forTimeInterval: 1)
    #expect(launches(sbd, c).count == before)
    #expect(!(try scriptArgs(sbd, c.id)).contains("--strict-mcp-config"))
  }

  @Test func aChangeThatLeavesTheServersAsTheyWereDoesNotRelaunch() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    let before = launches(sbd, c).count

    try sbd.sb("manager", "mcp", c.id, "--none")
    try sbd.sb("manager", "mcp", c.id, "rm", "grafana")

    Thread.sleep(forTimeInterval: 1)
    #expect(launches(sbd, c).count == before)
  }

  @Test func twoChangesAtOnceAreRefused() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    try requireSwitchboardOnly(sbd, c.id)
    let before = launches(sbd, c).count

    let refused = try sbd.run(["manager", "mcp", c.id, "add", "grafana", "--all"])

    #expect(refused.status != 0)
    Thread.sleep(forTimeInterval: 1)
    #expect(launches(sbd, c).count == before)
    #expect(try serverNames(scriptArgs(sbd, c.id)) == ["switchboard"])
  }

  @Test func aServerNoConfigHoldsAnyMoreIsLeftOutAndRecorded() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let c = try idleConversation(sbd)
    let folder = try accountFolder(sbd, c)
    try addUserServers(folder, ["notes": Self.userServer])
    try changeServers(sbd, c, "add", "notes")
    let path = "\(folder)/.claude.json"
    var config = try #require(JSON.parse(try String(contentsOfFile: path, encoding: .utf8))?.object)
    config["mcpServers"] = [:]
    try JSON.object(config).text.write(toFile: path, atomically: true, encoding: .utf8)
    try sbd.stopClaude(c.id)
    let before = launches(sbd, c).count

    _ = try sbd.sb("manager", c.id, "--json")

    _ = try launch(sbd, c, after: before)
    #expect(serverNames(try scriptArgs(sbd, c.id)) == ["switchboard"])
    let missing = try sbd.events(c.id).last { $0.kind == "mcp-missing" }
    #expect(missing?.data["servers"] == ["notes"])
  }

  // MARK: The Manager from before conversations

  /// Stores a Manager session as the sbd before conversations stored it, with
  /// no server list and no record of the one-time switch, and starts sbd again.
  /// It replaces the database that the first start wrote, so that start leaves
  /// no record in it.
  func seedOldManager(_ sbd: Instance) throws -> SessionSummary {
    let now = try sbd.now()
    sbd.stopSbd()
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: sbd.home.database + suffix) }
    try FileManager.default.createDirectory(atPath: sbd.home.managerFolder, withIntermediateDirectories: true)
    var session = Session(
      id: "s64qrh", name: "Manager", cwd: sbd.home.managerFolder, claudeSessionId: UUID().uuidString.lowercased(),
      created: now)
    session.manager = true
    do {
      let store = try Store(path: sbd.home.database)
      try store.save(session)
    }
    try sbd.startSbd()
    return try sbd.get(session.id)
  }

  @Test func theOldManagerIsTheFirstConversationNamedManager() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let old = try seedOldManager(sbd)

    let listed = try conversations(sbd)
    let opened = try decode(SessionSummary.self, sbd.sb("manager", "Manager", "--json"))

    #expect(listed.map(\.id) == [old.id])
    #expect(listed.first?.name == "Manager")
    #expect(opened.id == old.id)
  }

  @Test func theOldManagersNextLaunchHasOnlyTheSwitchboardServer() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let old = try seedOldManager(sbd)

    _ = try sbd.sb("manager", "Manager", "--json")
    try launch(sbd, old, after: 0)

    let args = try scriptArgs(sbd, old.id)
    #expect(args.contains("--strict-mcp-config"))
    #expect(!args.contains(sbd.home.mcpConfig))
    #expect(serverNames(args) == ["switchboard"])
  }

  @Test func theOldManagerKeepsAllAcrossAnSbdRestart() throws {
    let sbd = try Instance(config: Self.sharedServers)
    let old = try seedOldManager(sbd)
    _ = try sbd.sb("manager", "Manager", "--json")
    try sbd.waitFor(old.id, "the stub") { $0.live }
    try sbd.sb("send", old.id, "hello")
    try sbd.waitFor(old.id, "the reply") { $0.lastReply == "Done: hello" }
    try requireSwitchboardOnly(sbd, old.id)
    let all = try changeServers(sbd, old, "--all")
    try #require(!all.contains("--strict-mcp-config"))

    try sbd.restart(setting: "tickSeconds", to: 0.2)
    try sbd.stopClaude(old.id)
    let before = launches(sbd, old).count
    _ = try sbd.sb("manager", "Manager", "--json")
    try launch(sbd, old, after: before)

    let args = try scriptArgs(sbd, old.id)
    #expect(!args.contains("--strict-mcp-config"))
    #expect(args.contains(sbd.home.mcpConfig))
  }

  // MARK: The digest at SessionStart

  /// The additionalContext of each SessionStart answer that the session's claude got, oldest first.
  func startContexts(_ sbd: Instance, _ s: SessionSummary) -> [String] {
    sbd.hookOutputs(s.claudeSessionId).compactMap {
      guard $0["hookSpecificOutput"]?["hookEventName"]?.string == "SessionStart" else { return nil }
      return $0["hookSpecificOutput"]?["additionalContext"]?.string
    }
  }

  /// Waits for the session's first SessionStart answer with additionalContext and returns its text.
  func startDigest(_ sbd: Instance, _ s: SessionSummary) throws -> String {
    try sbd.waitFor("the SessionStart digest of \(s.id)", fetch: { startContexts(sbd, s).first }) { _ in true }
  }

  static let inboxTitle = "Pick the cache key"

  @Test func aNewConversationsSessionStartGetsADigestOfEverySessionAndTheInbox() throws {
    let sbd = try Instance()
    try JSON.object([
      "title": .string(Self.inboxTitle), "kind": "info", "summary": "It finished.", "options": [],
    ]).text.write(toFile: "\(sbd.home.path)/summary-answer.json", atomically: true, encoding: .utf8)
    let waiting = try sbd.new(prompt: "hello", name: "waiting")
    try sbd.waitFor(waiting.id, "its Inbox item", timeout: 30) { $0.triage?.title == Self.inboxTitle }
    let busy = try sbd.new(prompt: "slow 30", name: "busy")
    try sbd.waitFor(busy.id, "its turn") { $0.state == .working }

    let other = try newConversation(sbd, name: "other")
    let c = try newConversation(sbd)

    let text = try startDigest(sbd, c)
    #expect(!text.contains(other.id), "\(text)")
    let lines = text.split(separator: "\n")
    // The Inbox title's line can name its session too, so it doesn't count as the session's line.
    let sessionLines = lines.filter { !$0.contains(Self.inboxTitle) }
    for s in [waiting, busy] {
      #expect(sessionLines.filter { $0.contains(s.id) }.count == 1, "\(s.name) in \(text)")
    }
    #expect(text.contains(Self.inboxTitle), "\(text)")
    #expect(startContexts(sbd, c).count == 1)
  }

  @Test func theStartDigestStaysOutOfTheConversationsMessages() throws {
    let sbd = try Instance()
    _ = try sbd.new(prompt: "hello", name: "other")
    let c = try idleConversation(sbd)
    let text = try startDigest(sbd, c)
    let start = try #require(try sbd.hooks(c.id).first { $0.kind == "SessionStart" })
    let path = try #require(start.data["transcript_path"]?.string)
    let attachments = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap {
      JSON.parse(String($0))?["attachment"]
    }
    try #require(
      attachments.contains {
        $0["type"]?.string == "hook_additional_context" && $0["content"]?.array?.contains(.string(text)) == true
      })

    let messages = Transcript.messages(path, limit: 50)
    let log = try decode([ChatMessage].self, sbd.sb("manager", c.id, "--log", "--json"))

    #expect(messages.map(\.text) == ["hello", "Done: hello"])
    #expect(log.map(\.text) == ["hello", "Done: hello"])
  }

  @Test func aResumedConversationGetsNoStartDigest() throws {
    let sbd = try Instance()
    _ = try sbd.new(prompt: "hello", name: "other")
    let c = try idleConversation(sbd)
    _ = try startDigest(sbd, c)
    try sbd.stopClaude(c.id)

    _ = try sbd.sb("manager", c.id, "--json")

    try sbd.waitFor("the resume's SessionStart") {
      try sbd.hooks(c.id).filter { $0.kind == "SessionStart" }.count == 2
    }
    Thread.sleep(forTimeInterval: 0.5)
    #expect(startContexts(sbd, c).count == 1)
  }

  enum OtherKind: CaseIterable { case work, chat }

  @Test(arguments: OtherKind.allCases) func aSessionOfAnotherKindGetsNoStartDigest(_ kind: OtherKind) throws {
    let sbd = try Instance()
    _ = try sbd.new(prompt: "hello", name: "other")

    let s: SessionSummary
    switch kind {
    case .work:
      s = try sbd.new(prompt: "hello", name: "work")
    case .chat:
      _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags"))
      let id = try #require(try decode(JSON.self, sbd.sb("chat", "Flags", "--send", "hello", "--json"))["id"]?.string)
      s = try sbd.get(id)
    }

    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" }
    #expect(try sbd.hooks(s.id).contains { $0.kind == "SessionStart" })
    #expect(startContexts(sbd, s).isEmpty)
  }

  // MARK: spawn with wait

  func spawnArgs(_ sbd: Instance, _ name: String) throws -> [String: JSON] {
    ["repository": .string(try sbd.makeRepo(name)), "branch": .string(name), "name": .string(name), "prompt": "hello"]
  }

  @Test func spawnsSchemaTakesWait() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let spawn = try #require(try mcp.tools().first { $0["name"]?.string == "spawn" })

    #expect(spawn["inputSchema"]?["properties"]?["wait"] != nil)
  }

  @Test func spawnWithWaitDoneSetsASessionWaitOnTheCaller() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))
    var args = try spawnArgs(sbd, "kid")
    args["wait"] = "done"

    let kid = try mcp.call("spawn", args).decode(SessionSummary.self)

    let waits = try sbd.get(c.id).waits
    #expect(waits.count == 1)
    let wait = try #require(waits.first)
    #expect(wait.kind == .session)
    #expect(wait.session?.id == kid.id)
    #expect(wait.state == .done)
    #expect(try sbd.get(kid.id).waits.isEmpty)
  }

  @Test func theChildReachingDoneResumesTheCallerOnce() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))
    var args = try spawnArgs(sbd, "kid")
    args["wait"] = "done"
    let kid = try mcp.call("spawn", args).decode(SessionSummary.self)
    try #require(try sbd.get(c.id).waits.count == 1)
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }

    try sbd.sb("done", kid.id)

    let resumed = try sbd.waitFor(c.id, "the resumed turn", timeout: 30) {
      $0.lastReply == "Done: Switchboard: kid to reach Done: it did."
    }
    #expect(resumed.waits.isEmpty)
    try sbd.sb("undone", kid.id)
    try sbd.sb("done", kid.id)
    Thread.sleep(forTimeInterval: 1)
    #expect(try sbd.sbdMessages(c.id).count == 1)
  }

  @Test func spawnWithoutWaitSetsNoWait() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    _ = try mcp.call("spawn", try spawnArgs(sbd, "kid")).decode(SessionSummary.self)

    #expect(try sbd.get(c.id).waits.isEmpty)
  }

  @Test func spawnWithAWaitStateThatDoesNotExistIsRefused() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))
    var args = try spawnArgs(sbd, "kid")
    args["wait"] = "soonish"
    let before = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array).count

    let result = try mcp.call("spawn", args)

    #expect(result.isError, "\(result.text)")
    #expect(try sbd.get(c.id).waits.isEmpty)
    #expect(try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array).count == before)
  }

  @Test func spawnWithAWaitOutsideASessionIsRefused() throws {
    let sbd = try Instance()
    let before = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array).count

    let refused = try sbd.run(["spawn", "--repo", "/nowhere", "--branch", "b", "--prompt", "p", "--wait", "done"])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("calling session"), "\(refused.stderr)")
    #expect(try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array).count == before)
  }

  // MARK: The sender of a message

  enum Channel: CaseIterable { case mcp, cli }

  /// Sends `text` to `target` from inside `from`, through the MCP `send` tool or `sb send`.
  func send(_ sbd: Instance, from: SessionSummary, to target: SessionSummary, _ text: String, by channel: Channel)
    throws
  {
    switch channel {
    case .mcp:
      let result = try MCPClient(sbd, env: inside(from.id)).call(
        "send", ["session": .string(target.id), "text": .string(text)])
      try #require(!result.isError, "\(result.text)")
    case .cli:
      try sbd.sb(["send", target.id, text], env: inside(from.id))
    }
  }

  func sentEvent(_ sbd: Instance, _ id: String, _ text: String) throws -> Event {
    try sbd.waitFor(
      "the sent event for \(text)",
      fetch: { try sbd.events(id).first { $0.kind == "sent" && $0.data["text"]?.string == text } }
    ) { _ in true }
  }

  @Test(arguments: Channel.allCases) func aMessageFromAConversationToAChildNamesTheConversation(_ channel: Channel)
    throws
  {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    let kid = try decode(
      SessionSummary.self,
      sbd.sb("new", "--json", "--name", "kid", "--prompt", "hello", sbd.work, env: inside(c.id)))
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }

    try send(sbd, from: c, to: kid, "rebase on main", by: channel)

    #expect(try sentEvent(sbd, kid.id, "rebase on main").data[Self.senderKey]?.string == c.id)
  }

  @Test func sbEventsShowsWhichConversationSentAMessage() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd, name: "Cache work", "hello")
    let kid = try sbd.new(prompt: "hello", name: "kid")
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }
    try send(sbd, from: c, to: kid, "rebase on main", by: .mcp)
    _ = try sentEvent(sbd, kid.id, "rebase on main")

    let lines = try sbd.sb("events", "--session", kid.id).split(separator: "\n")

    let line = try #require(lines.first { $0.contains(" sent ") && $0.contains("rebase on main") })
    #expect(line.contains(c.id) || line.contains("Cache work"), "\(line)")
  }

  @Test func aMessageTypedInATerminalNamesNoSender() throws {
    let sbd = try Instance()
    let kid = try sbd.new(prompt: "hello", name: "kid")
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }

    try sbd.sb("send", kid.id, "rebase on main")

    #expect(try sentEvent(sbd, kid.id, "rebase on main").data[Self.senderKey] == nil)
  }

  @Test func aMessageTypedInASessionsShellNamesNoSender() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    let kid = try sbd.new(prompt: "hello", name: "kid")
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }

    // A session's shell pane sets SB_SESSION_ID and leaves CLAUDECODE unset.
    try sbd.sb(["send", kid.id, "rebase on main"], env: ["SB_SESSION_ID": c.id])

    #expect(try sentEvent(sbd, kid.id, "rebase on main").data[Self.senderKey] == nil)
  }

  @Test func aMessageThatSbdSendsNamesNoSender() throws {
    let sbd = try Instance()
    let a = try sbd.new(prompt: "hello", name: "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    for s in [a, b] { try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" } }
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b")

    try sbd.sb("done", b.id)

    try sbd.waitFor(a.id, "the resumed turn", timeout: 30) {
      $0.lastReply == "Done: Switchboard: b to reach Done: it did."
    }
    let fromSbd = try sbd.sbdMessages(a.id)
    try #require(fromSbd.count == 1)
    #expect(fromSbd[0].data[Self.senderKey] == nil)
  }
}
