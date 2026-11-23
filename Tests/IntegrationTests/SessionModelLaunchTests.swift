import Foundation
import SwitchboardCore
import Testing

/// The model that each new session launches with. A work session stores config.json's `model`, opus by default,
/// whoever creates it. sbd passes the stored model as `--model` at every launch. A Manager conversation and a group
/// chat store none and run `manager.model`. A session never takes the model of the session that spawned it. A model
/// that the caller names wins. A work session created before work sessions stored their model resumes with no
/// `--model`.
@Suite(.blocking(timeLimit: .seconds(120))) struct SessionModelLaunchTests {
  let models = ManagerModelTests()
  let conversations = ManagerConversationsTests()
  let chats = ChatTests()

  /// A new group and its chat, once the chat's claude runs.
  func liveChat(_ sbd: Instance) throws -> (group: GroupSummary, chat: SessionSummary) {
    let group = try chats.addGroup(sbd, "Flags")
    return (group, try GroupDescriptionTests().liveChat(sbd, group.id))
  }

  /// Runs `sb spawn` in the repo on a new branch, inside `parent` when one is given, and waits for the child's
  /// claude.
  func spawned(
    _ sbd: Instance, inside parent: String? = nil, repo: String, branch: String, _ extra: String...
  ) throws -> SessionSummary {
    let s = try SpawnTests().spawnCLI(
      sbd, ["--repo", repo, "--branch", branch, "--name", branch, "--prompt", "hello"] + extra,
      env: parent.map(conversations.inside) ?? [:])
    try sbd.waitFor(s.id, "\(branch)'s claude") { $0.live }
    return s
  }

  /// Calls the MCP `spawn` tool in the repo on a new branch and waits for the child's claude.
  func spawned(
    _ sbd: Instance, through mcp: MCPClient, repo: String, branch: String, model: String? = nil
  ) throws -> SessionSummary {
    var args: [String: JSON] = [
      "repository": .string(repo), "branch": .string(branch), "name": .string(branch), "prompt": "hello",
    ]
    if let model { args["model"] = .string(model) }
    let s = try mcp.call("spawn", args).decode(SessionSummary.self)
    try sbd.waitFor(s.id, "\(branch)'s claude") { $0.live }
    return s
  }

  // MARK: Work sessions

  @Test func aNewWorkSessionStartsOnTheConfigModel() throws {
    let sbd = try Instance(config: ["model": "haiku"])

    let s = try models.liveWorkSession(sbd)

    #expect(try models.launchModel(sbd, s.id) == "haiku")
  }

  @Test func aBadConfigModelFallsBackToOpus() throws {
    let sbd = try Instance(config: ["model": "-p"])

    let s = try models.liveWorkSession(sbd)

    #expect(try models.launchModel(sbd, s.id) == "opus")
    let log = (try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? ""
    #expect(log.contains("skipping model:"), "\(log)")
  }

  // MARK: No inheritance from the spawner

  @Test func aSessionThatAManagerConversationSpawnsDoesNotTakeItsModel() throws {
    let sbd = try Instance(config: ["manager": ["model": "haiku"]])
    let repo = try sbd.makeRepo()
    let m = try models.liveManager(sbd)

    let fromCLI = try spawned(sbd, inside: m.id, repo: repo, branch: "cli")
    let fromTool = try spawned(
      sbd, through: try MCPClient(sbd, env: conversations.inside(m.id)), repo: repo, branch: "tool")

    for kid in [fromCLI, fromTool] {
      #expect(kid.parent == m.id, "\(kid.name)")
      #expect(try models.launchModel(sbd, kid.id) == "opus", "\(kid.name)")
    }
    #expect(try models.launchModel(sbd, m.id) == "haiku")
  }

  @Test func aSessionThatAGroupChatSpawnsDoesNotTakeItsModel() throws {
    let sbd = try Instance(config: ["manager": ["model": "haiku"]])
    let repo = try sbd.makeRepo()
    let (group, chat) = try liveChat(sbd)

    let fromCLI = try spawned(sbd, inside: chat.id, repo: repo, branch: "cli")
    let fromTool = try spawned(
      sbd, through: try MCPClient(sbd, group: group.id, env: conversations.inside(chat.id)), repo: repo,
      branch: "tool")

    #expect(fromCLI.parent == chat.id)
    for kid in [fromCLI, fromTool] {
      #expect(try models.launchModel(sbd, kid.id) == "opus", "\(kid.name)")
    }
    #expect(try models.launchModel(sbd, chat.id) == "haiku")
  }

  // MARK: The caller's model

  @Test func aCallersModelWins() throws {
    let sbd = try Instance(config: ["model": "opus", "manager": ["model": "haiku"]])
    let repo = try sbd.makeRepo()
    let m = try models.liveManager(sbd)

    let new = try models.live(sbd, "new", "--name", "new", "--model", "sonnet", "--prompt", "hello", sbd.work)
    let fromTerminal = try spawned(sbd, repo: repo, branch: "terminal", "--model", "sonnet")
    let fromManager = try spawned(sbd, inside: m.id, repo: repo, branch: "manager", "--model", "sonnet")
    let fromTool = try spawned(
      sbd, through: try MCPClient(sbd, env: conversations.inside(m.id)), repo: repo, branch: "tool", model: "sonnet")
    let added = try chats.decode(
      SessionSummary.self,
      sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "--model", "sonnet", "Fix the cache."))
    let followup = try chats.decode(
      SessionSummary.self, sbd.sb("followup", "start", "--json", "--path", repo, added.id))
    try sbd.waitFor(followup.id, "the follow-up's claude") { $0.live }

    for s in [new, fromTerminal, fromManager, fromTool, followup] {
      #expect(try models.launchModel(sbd, s.id) == "sonnet", "\(s.name)")
    }
  }

  // MARK: Coordinators

  /// `ManagerModelTests` covers Manager conversations and the operator.
  @Test func aGroupChatRunsTheManagerModelAndFollowsAChange() throws {
    let sbd = try Instance(config: ["model": "opus", "manager": ["model": "haiku"]])
    let (group, chat) = try liveChat(sbd)
    #expect(try models.launchModel(sbd, chat.id) == "haiku")
    // A chat resumes only once its claude has saved a transcript, which the first turn writes.
    try chats.replied(sbd, group.id, "hello")

    try sbd.sb("manager", "model", "sonnet")
    try OperatorTests().resume(sbd, chat) { _ = try chats.chat(sbd, group.id) }

    #expect(try models.launchModel(sbd, chat.id) == "sonnet")
  }

  // MARK: Resume

  /// A work session created before work sessions stored their model has none in the store. It resumes on the
  /// model its transcript was saved on, so sbd passes no `--model`.
  @Test func aWorkSessionWithoutAStoredModelResumesWithoutOne() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession(name: "old")
    try #require(try models.launchModel(sbd, s.id) == "opus")
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live }
    sbd.stopSbd()
    do {
      let store = try Store(path: sbd.home.database)
      var session = try #require(try store.sessions().first { $0.id == s.id })
      session.model = nil
      try store.save(session)
    }
    try sbd.startSbd()
    let before = conversations.launches(sbd, s).count

    try sbd.sb("send", s.id, "again")

    let launched = try conversations.launch(sbd, s, after: before)
    try sbd.waitFor(s.id, "the resumed turn's reply") { $0.lastReply == "Done: again" }
    #expect(launched.hasPrefix("--resume \(s.claudeSessionId) "), "\(launched)")
    #expect(try models.launchModel(sbd, s.id) == nil)
  }

  @Test func aWorkSessionWithAStoredModelResumesOnIt() throws {
    let sbd = try Instance(config: ["model": "haiku"])
    let s = try sbd.idleSession(name: "pinned")
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live }
    try sbd.restart(setting: "model", to: "sonnet")
    let before = conversations.launches(sbd, s).count

    try sbd.sb("send", s.id, "again")

    let launched = try conversations.launch(sbd, s, after: before)
    try sbd.waitFor(s.id, "the resumed turn's reply") { $0.lastReply == "Done: again" }
    #expect(launched.hasPrefix("--resume \(s.claudeSessionId) "), "\(launched)")
    #expect(try models.launchModel(sbd, s.id) == "haiku")
  }
}
