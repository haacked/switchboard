import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct ChatTests {
  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func addGroup(_ sbd: Instance, _ name: String, _ sessions: String...) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + sessions))
  }

  /// Opens the group's chat, and creates it the first time.
  func chat(_ sbd: Instance, _ group: String) throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb("chat", group, "--json"))
  }

  /// Sends a turn to the group's chat, as a script does. It returns the whole JSON reply.
  func send(_ sbd: Instance, _ group: String, _ text: String) throws -> JSON {
    try decode(JSON.self, sbd.sb("chat", group, "--send", text, "--json"))
  }

  /// The group's chat after its turn for `text` ended.
  @discardableResult
  func replied(_ sbd: Instance, _ group: String, _ text: String) throws -> SessionSummary {
    let id = try #require(try send(sbd, group, text)["id"]?.string)
    return try sbd.waitFor(id, "the reply to \(text)") { $0.lastReply == "Done: \(text)" }
  }

  func chatFolder(_ sbd: Instance, _ group: GroupSummary) -> String { "\(sbd.home.path)/chats/\(group.id)" }

  func ls(_ sbd: Instance) throws -> [SessionSummary] { try decode([SessionSummary].self, sbd.sb("ls", "--json")) }

  func triaged(_ sbd: Instance) throws -> [String] {
    try sbd.client.call("triage", as: [SessionSummary].self).map(\.id)
  }

  /// The switchboard server in the --mcp-config of each launch of the session's claude, oldest first.
  func launchConfigs(_ sbd: Instance, _ s: SessionSummary) -> [JSON?] {
    sbd.stubArgs().filter { $0.contains(s.claudeSessionId) }.map(MCPToolServerTests.switchboardConfig(in:))
  }

  func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

  // MARK: The task's definition of done

  @Test func theChatsServerRefusesASessionOutsideTheGroupAndTheChatResumesAfterItStops() throws {
    let sbd = try Instance()
    let member = try sbd.new(name: "member")
    let outside = try sbd.new(name: "outside")
    let flags = try addGroup(sbd, "Flags", member.id)
    let c = try chat(sbd, "Flags")
    try sbd.waitFor(c.id, "the stub") { $0.live }
    let config = try #require(launchConfigs(sbd, c).first ?? nil)
    let mcp = try MCPClient(server: try #require(config["mcpServers"]?["switchboard"]))

    let refused = try mcp.call("get_session", ["session": .string(outside.id)])
    let allowed = try mcp.call("get_session", ["session": .string(member.id)])

    #expect(refused.isError)
    #expect(refused.text.contains("is not in group"))
    #expect(try allowed.decode(SessionSummary.self).id == member.id)

    try replied(sbd, flags.id, "hello")
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the stop") { !$0.live }

    let again = try chat(sbd, "Flags")

    #expect(again.id == c.id)
    try sbd.waitFor(c.id, "the resume") { $0.live }
    #expect(sbd.stubArgs().contains { $0.contains("--resume \(c.claudeSessionId)") })
    let configs = launchConfigs(sbd, c)
    #expect(configs.count == 2)
    for config in configs {
      #expect(config?["mcpServers"]?["switchboard"]?["args"] == ["mcp-server", "--group", .string(flags.id)])
    }
  }

  @Test func theChatsServerReachesTheChatItself() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let c = try chat(sbd, "Flags")
    try sbd.waitFor(c.id, "the stub") { $0.live }
    let config = try #require(launchConfigs(sbd, c).first ?? nil)
    let mcp = try MCPClient(server: try #require(config["mcpServers"]?["switchboard"]))

    let set = try mcp.call("set_wait", ["note": "the deploy"])
    let cleared = try mcp.call("clear_wait", [:])
    let noted = try mcp.call("add_note", ["session": .string(c.id), "text": "watching"])

    #expect(!set.isError)
    #expect(try set.decode(SessionSummary.self).waits.count == 1)
    #expect(!cleared.isError)
    #expect(try cleared.decode(SessionSummary.self).waits.isEmpty)
    #expect(!noted.isError)
    #expect(try sbd.get(c.id).notes.map(\.text) == ["watching"])
  }

  // MARK: The session and its folder

  @Test func aGroupMessageFromTheChatWaitsOnACardOnTheChatAndSendsNothing() throws {
    let sbd = try Instance()
    let member = try sbd.new(name: "member")
    _ = try addGroup(sbd, "Flags", member.id)
    let c = try chat(sbd, "Flags")
    try sbd.waitFor(c.id, "the stub") { $0.live }
    let config = try #require(launchConfigs(sbd, c).first ?? nil)
    let mcp = try MCPClient(server: try #require(config["mcpServers"]?["switchboard"]))

    let result = try mcp.call("send_group", ["text": "rebase on main"])

    #expect(!result.isError)
    #expect(try sbd.get(c.id).cards.map(\.kind) == [.send])
    #expect(try sbd.get(member.id).cards.isEmpty)
    #expect(try triaged(sbd).contains(c.id) == false)
    #expect(try sbd.get(c.id).triage == nil)
  }

  @Test func chatCreatesASessionNamedForTheGroupInItsFolderWithTheGuide() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")

    let c = try chat(sbd, "Flags")

    #expect(c.name == "Flags chat")
    #expect(c.cwd == chatFolder(sbd, flags))
    #expect(isDirectory("\(c.cwd)/.git"))
    #expect(try String(contentsOfFile: "\(c.cwd)/CLAUDE.md", encoding: .utf8) == Chat.guide)
    try sbd.waitFor(c.id, "the stub") { $0.live }
  }

  @Test func theChatBelongsToNoGroupAndHasNoBranch() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")

    let c = try chat(sbd, "Flags")

    #expect(c.chat == flags.id)
    #expect(c.group == nil)
    #expect(c.branch == nil)
    #expect(try decode(GroupList.self, sbd.sb("group", "ls", "--json")).groups.first?.sessions == [])
  }

  @Test func chatOpensTheSameSessionAfterThat() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let first = try chat(sbd, "Flags")
    try sbd.waitFor(first.id, "the stub") { $0.live }

    let second = try chat(sbd, flags.id)

    #expect(second.id == first.id)
    #expect(try ls(sbd).filter { $0.chat == flags.id }.count == 1)
  }

  @Test func sbdKeepsTheChatGuideCurrentAtEachStart() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let c = try chat(sbd, "Flags")
    let path = "\(c.cwd)/CLAUDE.md"
    try "stale".write(toFile: path, atomically: true, encoding: .utf8)

    try sbd.restart(setting: "tickSeconds", to: 0.2)

    #expect(try String(contentsOfFile: path, encoding: .utf8) == Chat.guide)
  }

  @Test func chatForAGroupThatDoesNotExistFailsAndMakesNoSession() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")

    let result = try sbd.run("chat", "Nowhere", "--json")

    #expect(result.status != 0)
    #expect(try ls(sbd).isEmpty)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: "\(sbd.home.path)/chats")) ?? []).isEmpty)
  }

  // MARK: Registration

  @Test func theChatsConfigRunsSbScopedToItsGroupAgainstThisHome() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let c = try chat(sbd, "Flags")
    try sbd.waitFor(c.id, "the stub") { $0.live }

    let config = try #require(launchConfigs(sbd, c).first ?? nil)

    let servers = try #require(config["mcpServers"]?.object)
    #expect(servers.keys.sorted() == ["switchboard"])
    let server = try #require(servers["switchboard"])
    #expect(server["command"]?.string.map(resolved) == resolved("\(Instance.bin)/sb"))
    #expect(server["args"] == ["mcp-server", "--group", .string(flags.id)])
    #expect(server["env"]?["SB_HOME"]?.string.map(resolved) == resolved(sbd.home.path))
    #expect(server["env"]?["SB_SESSION_ID"]?.string == c.id)
  }

  // MARK: --send

  @Test func sendCreatesTheChatWithTheTextAsItsFirstPrompt() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")

    let c = try replied(sbd, "Flags", "hello")

    #expect(c.name == "Flags chat")
    #expect(sbd.stubArgs().contains { $0.contains(c.claudeSessionId) && $0.hasSuffix("-- hello") })
  }

  @Test func trailingWordsAreTheTextLikeSend() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let c = try replied(sbd, "Flags", "hello")

    let reply = try decode(JSON.self, sbd.sb("chat", "--json", "Flags", "second", "turn"))

    #expect(reply["id"]?.string == c.id)
    try sbd.waitFor(c.id, "the second reply") { $0.lastReply == "Done: second turn" }
  }

  @Test func sendToAnExistingChatDeliversTheTextAndReturnsHowItWent() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let c = try replied(sbd, "Flags", "hello")

    let reply = try send(sbd, "Flags", "second")

    #expect(reply["id"]?.string == c.id)
    #expect(["pasted", "queued"].contains(reply["delivery"]?.string))
    try sbd.waitFor(c.id, "the second reply") { $0.lastReply == "Done: second" }
  }

  // MARK: Kind, groups, triage

  @Test func lsNamesEachSessionsKind() throws {
    let sbd = try Instance()
    let work = try sbd.new(name: "work")
    let flags = try addGroup(sbd, "Flags", work.id)
    let m = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    let c = try chat(sbd, flags.id)

    let kinds = Dictionary(uniqueKeysWithValues: try ls(sbd).map { ($0.id, $0.kind) })

    #expect(kinds == [work.id: .work, m.id: .manager, c.id: .chat])
  }

  /// How a command can name the chat: its id, a prefix of its id, or its name.
  enum ChatName: CaseIterable { case id, idPrefix, name }

  func name(_ c: SessionSummary, _ how: ChatName) -> String {
    switch how {
    case .id: c.id
    case .idPrefix: String(c.id.prefix(4))
    case .name: c.name
    }
  }

  @Test(arguments: ChatName.allCases) func groupMoveRefusesTheChatHoweverItIsNamed(_ how: ChatName) throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    _ = try addGroup(sbd, "Billing")
    let c = try chat(sbd, flags.id)

    let moved = try sbd.run(["group", "move", "--json", name(c, how), "--to", "Billing"])

    #expect(moved.status != 0)
    #expect(try sbd.get(c.id).group == nil)
  }

  @Test func groupAddLeavesTheChatOutOfTheGroup() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let c = try chat(sbd, "Flags")

    _ = try sbd.run(["group", "add", "--json", "Billing", c.id])

    #expect(try sbd.get(c.id).group == nil)
  }

  @Test func theChatsReplyStaysOutOfTriage() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let c = try replied(sbd, "Flags", "hello")
    let other = try sbd.new(prompt: "hello", name: "other")
    try sbd.waitFor(other.id, "the other reply") { $0.lastReply == "Done: hello" }

    let triage = try triaged(sbd)

    #expect(triage == [other.id])
    #expect(try sbd.get(c.id).triage == nil)
  }

  @Test func aChatsPermissionPromptIsInTriageAndChooseAllowsIt() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let id = try #require(try send(sbd, "Flags", "perm touch x")["id"]?.string)
    try sbd.waitFor(id, "the card") { !$0.cards.isEmpty }

    let triage = try triaged(sbd)
    let item = try #require(try sbd.get(id).triage)
    let result = try JSON.parse(sbd.sb("choose", "--json", id, "allow"))

    #expect(triage == [id])
    #expect(item.source == .card)
    #expect(item.title == "Approve `touch x`")
    #expect(Array(item.options.map(\.label).prefix(2)) == ["Allow", "Deny"])
    #expect(result?["delivery"]?.string == "hook")
    try sbd.waitFor(id, "the command's reply") { $0.lastReply == "Ran touch x" }
    #expect(try !triaged(sbd).contains(id))
  }

  /// The item names the permission card behind the group message's card, so
  /// Allow answers the prompt and sends no message.
  @Test func chooseAllowsAChatsPromptBehindItsGroupMessageAndSendsNothing() throws {
    let sbd = try Instance()
    let member = try sbd.new(name: "member")
    _ = try addGroup(sbd, "Flags", member.id)
    let c = try chat(sbd, "Flags")
    try sbd.waitFor(c.id, "the stub") { $0.live }
    let config = try #require(launchConfigs(sbd, c).first ?? nil)
    let mcp = try MCPClient(server: try #require(config["mcpServers"]?["switchboard"]))
    #expect(!(try mcp.call("send_group", ["text": "rebase on main"])).isError)
    _ = try send(sbd, "Flags", "perm touch x")
    try sbd.waitFor(c.id, "the permission card") { $0.cards.map(\.kind) == [.send, .permission] }

    let item = try #require(try sbd.get(c.id).triage)
    let result = try JSON.parse(sbd.sb("choose", "--json", c.id, "allow"))

    #expect(item.title == "Approve `touch x`")
    #expect(result?["delivery"]?.string == "hook")
    try sbd.waitFor(c.id, "the command's reply") { $0.lastReply == "Ran touch x" }
    #expect(try sbd.get(c.id).cards.map(\.kind) == [.send])
    #expect(try sbd.events(c.id).contains { $0.kind == "send_decided" } == false)
    #expect(try sbd.get(member.id).cards.isEmpty)
  }

  @Test func aChatsQuestionIsInTriageAndChooseAnswersIt() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let id = try #require(try send(sbd, "Flags", "pick fruit")["id"]?.string)
    try sbd.waitFor(id, "the card") { !$0.cards.isEmpty }

    let triage = try triaged(sbd)
    let item = try #require(try sbd.get(id).triage)
    try sbd.sb("choose", id, "1")

    #expect(triage == [id])
    #expect(item.source == .card)
    #expect(item.options.map(\.label) == ["apple", "cherry"])
    let after = try sbd.waitFor(id, "the answer") { $0.lastReply?.hasPrefix("Picked:") == true }
    #expect(after.lastReply == #"Picked: {"Which fruit?":"apple"}"#)
    #expect(try !triaged(sbd).contains(id))
  }

  @Test func aChatsQuestionReplyStaysOutOfTriage() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let id = try #require(try send(sbd, "Flags", "ask")["id"]?.string)
    let asked = try sbd.waitFor(id, "the reply") { $0.lastReply == "Which database should I use, Postgres or SQLite?" }

    let triage = try triaged(sbd)

    #expect(asked.state == .needsYou)
    #expect(!triage.contains(id))
    #expect(try sbd.get(id).triage == nil)
  }

  /// A chat with a card is in Needs you, so auto-continue never takes it up.
  @Test func aChatWithACardStaysOutOfAutoContinue() throws {
    let sbd = try Instance(config: ["autoContinue": ["quietSeconds": 60]])
    _ = try addGroup(sbd, "Flags")
    try sbd.sb("autocontinue", "on")
    let id = try #require(try send(sbd, "Flags", "perm touch x")["id"]?.string)
    try sbd.waitFor(id, "the card") { !$0.cards.isEmpty }

    try sbd.advanceClock(61_000)

    #expect(try sbd.autoContinueStatus().sessions.allSatisfy { $0.session != id || $0.blocker != nil })
    #expect(try sbd.autoContinues(id).isEmpty)
    #expect(try sbd.sbdMessages(id).isEmpty)
    #expect(try sbd.get(id).cards.count == 1)
  }

  /// A chat whose reply offers a next step reaches Claude can continue, where
  /// the status names why auto-continue holds it back.
  @Test func aChatThatClaudeCanContinueIsHeldBackAsAGroupChat() throws {
    let sbd = try Instance(config: ["autoContinue": ["quietSeconds": 60]])
    _ = try addGroup(sbd, "Flags")
    try sbd.sb("autocontinue", "on")
    let id = try #require(try send(sbd, "Flags", "offer")["id"]?.string)
    try sbd.waitFor(id, "the offer") { $0.state == .canContinue }

    try sbd.advanceClock(61_000)

    #expect(try sbd.blocker(id) == "a group chat")
    #expect(try sbd.autoContinues(id).isEmpty)
  }

  // MARK: Removing the group

  /// Starts a session from inside the chat, as `sb new` in the chat's terminal would.
  func childOf(_ sbd: Instance, _ chat: SessionSummary, name: String) throws -> SessionSummary {
    try decode(
      SessionSummary.self,
      sbd.sb("new", "--json", "--name", name, sbd.work, env: ["SB_SESSION_ID": chat.id, "CLAUDECODE": "1"]))
  }

  @Test func aSessionTheChatStartsJoinsTheChatsGroupUntilTheGroupIsGone() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let c = try chat(sbd, "Flags")

    let child = try childOf(sbd, c, name: "child")
    try sbd.sb("group", "rm", "Flags")
    let orphan = try childOf(sbd, c, name: "orphan")

    #expect(child.group == flags.id)
    #expect(child.parent == c.id)
    #expect(orphan.group == nil)
  }

  @Test func groupRmMarksTheChatDoneAndKeepsItsFolder() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let c = try replied(sbd, "Flags", "hello")

    try sbd.sb("group", "rm", "Flags")

    #expect(try sbd.get(c.id).markedDone)
    #expect(isDirectory(chatFolder(sbd, flags)))
  }

  @Test func acceptingAMergeMarksTheAbsorbedGroupsChatDoneAndLeavesTheSurvivorsChat() throws {
    let groups = GroupTests()
    let l = try groups.linkedGroups()
    let absorbed = try chat(l.sbd, l.docs.id)
    let survivor = try chat(l.sbd, l.flags.id)

    _ = try groups.accept(l.sbd, groups.mergeId(l.flags, l.docs))

    #expect(try l.sbd.get(absorbed.id).markedDone)
    #expect(try !l.sbd.get(survivor.id).markedDone)
  }

  // MARK: --log

  @Test func logReturnsEachTurnsMessagesOldestFirst() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    try replied(sbd, "Flags", "hello")
    try replied(sbd, "Flags", "second")

    let log = try decode([ChatMessage].self, sbd.sb("chat", "Flags", "--log", "--json"))

    #expect(
      log.map { "\($0.role): \($0.text)" } == [
        "user: hello", "assistant: Done: hello", "user: second", "assistant: Done: second",
      ])
  }

  @Test func chatLogWithALimitReturnsTheLastMessages() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    try replied(sbd, "Flags", "hello")
    try replied(sbd, "Flags", "second")

    let log = try sbd.client.call(
      "chat-log", ["group": .string(flags.id), "limit": 2], as: [ChatMessage].self)

    #expect(log.map(\.text) == ["second", "Done: second"])
  }

  @Test(arguments: ChatName.allCases) func chatLogNamingTheChatSessionReadsWhatChatLogForTheGroupReads(
    _ how: ChatName
  ) throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let c = try replied(sbd, "Flags", "hello")

    let bySession = try sbd.client.call("chat-log", ["session": .string(name(c, how))], as: [ChatMessage].self)
    let byGroup = try sbd.client.call("chat-log", ["group": .string(flags.id)], as: [ChatMessage].self)

    #expect(bySession.map { "\($0.role): \($0.text)" } == ["user: hello", "assistant: Done: hello"])
    #expect(bySession == byGroup)
  }
}
