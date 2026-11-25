import Foundation
import SwitchboardCore
import Testing

/// Several conversations in one group chat. Each is a session of kind `chat` whose `chat` is the group's id, in
/// the group's chat folder. `sb chat <group>` opens or sends to the group's most recent conversation that is not
/// done. `--new` starts another conversation, `--ls` lists them newest first, `--session` names one, and `--end`
/// removes one through `manager-end`.
@Suite(.blocking(timeLimit: .seconds(120))) struct ChatConversationsTests {
  let chats = ChatTests()
  let ends = ConversationEndTests()
  let descriptions = GroupDescriptionTests()
  let lists = ConversationListTests()
  let groups = GroupTests()

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// Starts a conversation in the group with `sb chat <group> --new`, and requires that it is a session that did not
  /// exist before.
  func newChat(_ sbd: Instance, _ group: String, name: String? = nil, _ text: String? = nil) throws -> SessionSummary {
    var args = ["chat", group, "--new", "--json"]
    if let name { args += ["--name", name] }
    if let text { args.append(text) }
    let before = Set(try chats.ls(sbd).map(\.id))
    let started = try decode(SessionSummary.self, sbd.sb(args))
    try #require(!before.contains(started.id), "sb chat --new answered with \(started.name), which existed before")
    return started
  }

  /// A new conversation in the group whose first turn, for `text`, has ended. It sends `text` with `sb send`, so
  /// each conversation's activity is later than the one made before it.
  func idleChat(_ sbd: Instance, _ group: String, name: String? = nil, _ text: String = "hello") throws
    -> SessionSummary
  {
    let c = try newChat(sbd, group, name: name)
    try sbd.waitFor(c.id, "the stub") { $0.live }
    try sbd.sb("send", c.id, text)
    return try sbd.waitFor(c.id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  /// The group's conversations as `sb chat <group> --ls --json` lists them.
  func listed(_ sbd: Instance, _ group: String) throws -> [SessionSummary] {
    try decode([SessionSummary].self, sbd.sb("chat", group, "--ls", "--json"))
  }

  /// The texts that sbd sent to the session.
  func sent(_ sbd: Instance, _ id: String) throws -> [String] { try groups.sent(sbd, id) }

  func chatLog(_ sbd: Instance, _ args: [String: JSON]) throws -> [String] {
    try sbd.client.call("chat-log", args, as: [ChatMessage].self).map { "\($0.role): \($0.text)" }
  }

  func strings(_ value: JSON?) -> [String] { value?.array?.compactMap(\.string) ?? [] }

  // MARK: Several conversations

  @Test func newTwiceGivesTwoChatSessionsOfTheGroupInItsFolder() throws {
    let sbd = try Instance()
    let flags = try chats.addGroup(sbd, "Flags")

    let first = try newChat(sbd, "Flags")
    let second = try newChat(sbd, "Flags")

    try #require(first.id != second.id)
    for c in [first, second] {
      #expect(c.kind == .chat)
      #expect(c.chat == flags.id)
      #expect(c.group == nil)
      #expect(c.cwd == chats.chatFolder(sbd, flags))
    }
    #expect(first.claudeSessionId != second.claudeSessionId)
    #expect(try chats.ls(sbd).filter { $0.chat == flags.id }.count == 2)
  }

  @Test func newOnAGroupThatHasAChatAddsAConversationBesideIt() throws {
    let sbd = try Instance()
    let flags = try chats.addGroup(sbd, "Flags")
    let original = try chats.chat(sbd, "Flags")

    let added = try newChat(sbd, "Flags")

    #expect(added.id != original.id)
    #expect(added.chat == flags.id)
    #expect(try sbd.get(original.id).markedDone == false)
  }

  @Test func lsListsTheGroupsConversationsNewestFirst() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let first = try idleChat(sbd, "Flags", name: "first")
    let second = try idleChat(sbd, "Flags", name: "second")

    let listed = try listed(sbd, "Flags")

    #expect(listed.map(\.id) == [second.id, first.id])
  }

  @Test func lsListsNoOtherGroupsChatAndNoOtherKindOfSession() throws {
    let sbd = try Instance()
    let work = try sbd.new(name: "work")
    _ = try chats.addGroup(sbd, "Flags", work.id)
    _ = try chats.addGroup(sbd, "Billing")
    let mine = try newChat(sbd, "Flags")
    let billing = try chats.chat(sbd, "Billing")
    let manager = try decode(SessionSummary.self, sbd.sb("manager", "new", "--json"))

    let listed = try listed(sbd, "Flags").map(\.id)

    #expect(listed == [mine.id])
    #expect(!listed.contains(billing.id))
    #expect(!listed.contains(manager.id))
    #expect(!listed.contains(work.id))
  }

  @Test func managerLsListsNoGroupChatConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try newChat(sbd, "Flags")

    let listed = try decode([SessionSummary].self, sbd.sb("manager", "ls", "--json")).map(\.id)

    #expect(!listed.contains(c.id))
  }

  @Test func bareChatOpensTheMostRecentConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let first = try idleChat(sbd, "Flags", name: "first")
    let second = try idleChat(sbd, "Flags", name: "second")
    try #require(first.id != second.id)

    let opened = try chats.chat(sbd, "Flags")

    #expect(opened.id == second.id)
  }

  @Test func chatWithTextSendsToTheMostRecentConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let first = try idleChat(sbd, "Flags", name: "first")
    let second = try idleChat(sbd, "Flags", name: "second")

    let reply = try decode(JSON.self, sbd.sb("chat", "--json", "Flags", "next", "turn"))

    #expect(reply["id"]?.string == second.id)
    try sbd.waitFor(second.id, "the reply") { $0.lastReply == "Done: next turn" }
    #expect(try sbd.get(first.id).lastReply == "Done: hello")
  }

  /// Decision 3: the group's chat is its most recent conversation that is not done.
  @Test func bareChatSkipsAConversationThatIsDone() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let first = try idleChat(sbd, "Flags", name: "first")
    let second = try idleChat(sbd, "Flags", name: "second")
    try sbd.sb("done", second.id)

    let opened = try chats.chat(sbd, "Flags")

    #expect(opened.id == first.id)
  }

  // MARK: --session

  @Test(arguments: ManagerConversationsTests.SessionRef.allCases)
  func sessionWithTextSendsToThatConversation(_ how: ManagerConversationsTests.SessionRef) throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let older = try idleChat(sbd, "Flags", name: "Cache work")
    let newer = try idleChat(sbd, "Flags", name: "Docs work")
    try #require(older.id != newer.id)

    let reply = try decode(
      JSON.self,
      sbd.sb("chat", "--json", "Flags", "--session", ManagerConversationsTests().ref(older, how), "second", "turn"))

    #expect(reply["id"]?.string == older.id)
    try sbd.waitFor(older.id, "the second reply") { $0.lastReply == "Done: second turn" }
    #expect(try sbd.get(newer.id).lastReply == "Done: hello")
  }

  @Test func sessionWithoutTextOpensThatConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let older = try idleChat(sbd, "Flags", name: "Cache work")
    _ = try idleChat(sbd, "Flags", name: "Docs work")

    let opened = try decode(SessionSummary.self, sbd.sb("chat", "Flags", "--session", older.id, "--json"))

    #expect(opened.id == older.id)
  }

  /// A session that `--session` may not name: it is not a chat of the group that the command names.
  enum Outsider: CaseIterable { case otherGroupsChat, work, managerConversation, theOperator }

  func outsider(_ sbd: Instance, _ kind: Outsider) throws -> SessionSummary {
    switch kind {
    case .otherGroupsChat:
      _ = try chats.addGroup(sbd, "Billing")
      return try chats.replied(sbd, "Billing", "hello")
    case .work: return try sbd.idleSession(name: "Payroll keys")
    case .managerConversation:
      let m = try decode(SessionSummary.self, sbd.sb("manager", "new", "--json", "--name", "Cache work"))
      return try sbd.waitFor(m.id, "the stub") { $0.live }
    case .theOperator: return try OperatorTests().idleOperator(sbd)
    }
  }

  @Test(arguments: Outsider.allCases, [ChatTests.ChatName.id, .name])
  func sessionRefusesASessionThatIsNotAChatOfTheGroup(_ kind: Outsider, _ how: ChatTests.ChatName) throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let mine = try idleChat(sbd, "Flags", name: "mine")
    let other = try outsider(sbd, kind)
    let text = "rebase on main"

    let refused = try sbd.run(["chat", "Flags", "--session", chats.name(other, how), text])

    #expect(refused.status != 0, Comment(rawValue: refused.stdout))
    #expect(try !sent(sbd, other.id).contains(text))
    #expect(try !sent(sbd, mine.id).contains(text))
    #expect(try listed(sbd, "Flags").map(\.id) == [mine.id])
  }

  @Test(arguments: Outsider.allCases)
  func sessionWithoutTextRefusesASessionThatIsNotAChatOfTheGroup(_ kind: Outsider) throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    _ = try newChat(sbd, "Flags", name: "mine")
    let other = try outsider(sbd, kind)

    let refused = try sbd.run(["chat", "Flags", "--session", other.id, "--json"])

    #expect(refused.status != 0, Comment(rawValue: refused.stdout))
  }

  // MARK: Names (Decision 4)

  @Test func theGroupsFirstChatKeepsTheGroupChatNameAfterItsFirstPrompt() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try chats.chat(sbd, "Flags")
    try sbd.waitFor(c.id, "the stub") { $0.live }

    try sbd.sb("send", c.id, "Fix the cache")

    try sbd.waitFor(c.id, "the reply") { $0.lastReply == "Done: Fix the cache" }
    #expect(try sbd.get(c.id).name == "Flags chat")
  }

  @Test func newWithoutANameOrAPromptIsUntitled() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    _ = try chats.chat(sbd, "Flags")

    let c = try newChat(sbd, "Flags")

    #expect(c.name == Manager.untitled)
    #expect(try sbd.get(c.id).name == Manager.untitled)
  }

  @Test func anUntitledConversationIsNamedByItsFirstPrompt() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    _ = try chats.chat(sbd, "Flags")
    let c = try newChat(sbd, "Flags")
    try sbd.waitFor(c.id, "the stub") { $0.live }

    try sbd.sb("send", c.id, "Fix the cache")

    try sbd.waitFor(c.id, "the name from the first prompt", timeout: 30) { $0.name == "Fix the cache" }
    #expect(try sbd.events(c.id).contains { $0.kind == "renamed" })
  }

  @Test func newWithTextIsNamedForTheFirstLineOfTheText() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    _ = try chats.chat(sbd, "Flags")

    let c = try newChat(sbd, "Flags", "Fix the cache\nThen open a PR")

    #expect(c.name == "Fix the cache")
  }

  @Test func newWithTextSendsTheTextAsTheFirstPrompt() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    _ = try chats.chat(sbd, "Flags")

    let c = try newChat(sbd, "Flags", "hello")

    try sbd.waitFor(c.id, "the reply", timeout: 30) { $0.lastReply == "Done: hello" }
  }

  @Test func nameWinsOverThePromptAndStaysAfterTheFirstTurn() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    _ = try chats.chat(sbd, "Flags")

    let c = try newChat(sbd, "Flags", name: "Cache work", "hello")

    #expect(c.name == "Cache work")
    try sbd.waitFor(c.id, "the reply", timeout: 30) { $0.lastReply == "Done: hello" }
    #expect(try sbd.get(c.id).name == "Cache work")
  }

  @Test func nameWithoutAPromptNamesTheConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")

    let c = try newChat(sbd, "Flags", name: "Cache work")

    #expect(c.name == "Cache work")
  }

  // MARK: Removing the group

  @Test func groupRmMarksEveryConversationDone() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let first = try idleChat(sbd, "Flags", name: "first")
    let second = try idleChat(sbd, "Flags", name: "second")

    try sbd.sb("group", "rm", "Flags")

    #expect(try sbd.get(first.id).markedDone)
    #expect(try sbd.get(second.id).markedDone)
  }

  // MARK: The group's description (Decision 7)

  @Test func describeTellsEveryLiveConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let first = try newChat(sbd, "Flags", name: "first")
    let second = try newChat(sbd, "Flags", name: "second")
    for c in [first, second] { try sbd.waitFor(c.id, "the stub") { $0.live } }

    _ = try descriptions.describe(sbd, "Flags", "Ship the cache first.")

    try descriptions.waitForMessage(sbd, first, holding: "Ship the cache first.")
    try descriptions.waitForMessage(sbd, second, holding: "Ship the cache first.")
  }

  @Test func describeSendsNothingToAConversationThatIsDone() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let done = try idleChat(sbd, "Flags", name: "done")
    let live = try idleChat(sbd, "Flags", name: "live")
    try sbd.sb("done", done.id)

    _ = try descriptions.describe(sbd, "Flags", "Ship the cache first.")

    try descriptions.waitForMessage(sbd, live, holding: "Ship the cache first.")
    #expect(try !sent(sbd, done.id).contains { $0.contains("Ship the cache first.") })
  }

  // MARK: Pin and archive

  @Test func managerPinPinsAChatAndTheSummaryCarriesThePin() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try newChat(sbd, "Flags")

    let pinned = try sbd.client.call(
      "manager-pin", ["session": .string(c.id), "pinned": true], as: SessionSummary.self)

    #expect(pinned.pinned == true)
    #expect(try sbd.get(c.id).pinned == true)
    #expect(try listed(sbd, "Flags").first { $0.id == c.id }?.pinned == true)
  }

  @Test func managerPinUnpinsAChat() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try newChat(sbd, "Flags")
    _ = try sbd.client.call("manager-pin", ["session": .string(c.id), "pinned": true])

    let unpinned = try sbd.client.call(
      "manager-pin", ["session": .string(c.id), "pinned": false], as: SessionSummary.self)

    #expect(unpinned.pinned != true)
    #expect(try sbd.get(c.id).pinned != true)
  }

  /// A session that `manager-pin` refuses, because it is not a user's conversation.
  enum NotPinnable: CaseIterable { case work, theOperator }

  @Test(arguments: NotPinnable.allCases) func managerPinStillRefusesASessionThatIsNotAConversation(_ kind: NotPinnable)
    throws
  {
    let sbd = try Instance()
    let s =
      switch kind {
      case .work: try sbd.new(name: "work")
      case .theOperator: try OperatorTests().openOperator(sbd)
      }

    let error = failure(sbd, "manager-pin", ["session": .string(s.id), "pinned": true])

    #expect(error != "no error")
    #expect(try sbd.get(s.id).pinned != true)
  }

  /// Moves sbd's clock to `offset` ms past the latest `lastActivity` of the sessions.
  func advance(_ sbd: Instance, pastActivityOf ids: [String], by offset: Int64) throws {
    let latest = try ids.map { try sbd.get($0).lastActivity }.max() ?? 0
    let step = latest + offset - (try sbd.now())
    try #require(step > 0, "the clock is already past the target")
    try sbd.advanceClock(step)
  }

  /// A chat conversation is archived by the same rule as a Manager conversation.
  @Test func anIdleReadChatIsArchivedAfterTheArchiveWait() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "idle")
    _ = try sbd.client.call(ChatActivity.readEvent, ["session": .string(c.id)])
    try lists.stopAndSettle(sbd, c.id)

    try advance(sbd, pastActivityOf: [c.id], by: Conversations.archiveAfterMs + 1)

    #expect(try sbd.get(c.id).activity?.archived == true)
    #expect(try listed(sbd, "Flags").first { $0.id == c.id }?.activity?.archived == true)
  }

  @Test func aPinnedChatIsNotArchived() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "idle")
    _ = try sbd.client.call(ChatActivity.readEvent, ["session": .string(c.id)])
    _ = try sbd.client.call("manager-pin", ["session": .string(c.id), "pinned": true])
    try lists.stopAndSettle(sbd, c.id)

    try advance(sbd, pastActivityOf: [c.id], by: Conversations.archiveAfterMs + 1)

    #expect(try sbd.get(c.id).activity?.archived != true)
  }

  // MARK: Removing a conversation (Decision 6)

  @Test func managerEndRemovesAChatAndLeavesTheGroupsOtherConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let kept = try idleChat(sbd, "Flags", name: "kept")
    let ended = try idleChat(sbd, "Flags", name: "ended")

    let answer = try sbd.client.call("manager-end", ["session": .string(ended.id)])

    #expect(answer["ended"]?.string == ended.id, "\(answer.text)")
    #expect(answer["started"] == nil, "\(answer.text)")
    #expect(try !sbd.client.sessions().map(\.id).contains(ended.id))
    #expect(try listed(sbd, "Flags").map(\.id) == [kept.id])
  }

  @Test func chatEndRemovesTheConversation() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let kept = try idleChat(sbd, "Flags", name: "kept")
    let ended = try idleChat(sbd, "Flags", name: "ended")

    let answer = try #require(JSON.parse(try sbd.sb("chat", "Flags", "--end", ended.id, "--json")))

    #expect(answer["ended"]?.string == ended.id, "\(answer.text)")
    #expect(try listed(sbd, "Flags").map(\.id) == [kept.id])
  }

  @Test func chatEndRefusesAChatOfAnotherGroup() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    _ = try chats.addGroup(sbd, "Billing")
    _ = try newChat(sbd, "Flags")
    let billing = try chats.replied(sbd, "Billing", "hello")

    let refused = try sbd.run(["chat", "Flags", "--end", billing.id])

    #expect(refused.status != 0, Comment(rawValue: refused.stdout))
    #expect(try sbd.client.sessions().map(\.id).contains(billing.id))
  }

  /// The session whose id the request names as its caller.
  enum Caller: CaseIterable { case itself, anotherChatOfTheGroup, work }

  @Test(arguments: Caller.allCases) func managerEndOnAChatRefusesACaller(_ kind: Caller) throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let target = try idleChat(sbd, "Flags", name: "target")
    let from: SessionSummary
    switch kind {
    case .itself: from = target
    case .anotherChatOfTheGroup: from = try idleChat(sbd, "Flags", name: "other")
    case .work: from = try sbd.idleSession(name: "work")
    }

    let error = failure(sbd, "manager-end", ["session": .string(target.id), "caller": .string(from.id)])

    #expect(error != "no error")
    #expect(try sbd.client.sessions().map(\.id).contains(target.id))
    _ = try sbd.client.call("manager-end", ["session": .string(target.id)])
    #expect(try !sbd.client.sessions().map(\.id).contains(target.id), "the same request without caller did not end it")
  }

  @Test func chatEndRefusesACommandFromASessionsShell() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")

    let refused = try sbd.run(["chat", "Flags", "--end", c.id], env: ["SB_SESSION_ID": c.id])

    #expect(refused.status != 0, Comment(rawValue: refused.stdout))
    #expect(try sbd.client.sessions().map(\.id).contains(c.id))
  }

  @Test func chatEndRefusesInsideClaudeCode() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")

    let refused = try sbd.run(["chat", "Flags", "--end", c.id], env: ["CLAUDECODE": "1"])

    #expect(refused.status != 0, Comment(rawValue: refused.stdout))
    #expect(try sbd.client.sessions().map(\.id).contains(c.id))
  }

  @Test func anOwnWaitRefusesTheEndAndTheRefusalNamesSbChatEnd() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")
    let wait = try ends.typedWait(sbd, c)

    let refused = try sbd.run(["chat", "Flags", "--end", c.id])

    #expect(refused.status != 0, Comment(rawValue: refused.stdout))
    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("sb chat"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("--end"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("--drop \(wait)"), Comment(rawValue: refused.stderr))
    #expect(!refused.stderr.contains("sb manager end"), Comment(rawValue: refused.stderr))
    #expect(try sbd.get(c.id).waits.map(\.id) == [wait])

    let answer = try #require(
      JSON.parse(try sbd.sb("chat", "Flags", "--end", c.id, "--drop", wait, "--json")))

    #expect(strings(answer["dropped"]) == [wait], "\(answer.text)")
    #expect(try !sbd.client.sessions().map(\.id).contains(c.id))
  }

  @Test func aScheduleRefusesTheEndUntilDropNamesIt() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")
    let schedule = try ends.scheduleId(sbd, c)

    let refused = failure(sbd, "manager-end", ["session": .string(c.id)])

    #expect(refused.contains(schedule), Comment(rawValue: refused))
    #expect(refused.contains("sb chat"), Comment(rawValue: refused))
    #expect(try sbd.client.sessions().map(\.id).contains(c.id))
    let answer = try sbd.client.call("manager-end", ["session": .string(c.id), "drop": [.string(schedule)]])
    #expect(strings(answer["dropped"]) == [schedule], "\(answer.text)")
  }

  @Test func rmRefusesAChatWithAnOwnWaitAndNamesSbChatEnd() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")
    let wait = try ends.typedWait(sbd, c)

    let refused = try sbd.run(["rm", c.id])

    #expect(refused.status != 0, Comment(rawValue: refused.stdout))
    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("sb chat"), Comment(rawValue: refused.stderr))
    #expect(!refused.stderr.contains("sb manager end"), Comment(rawValue: refused.stderr))
    #expect(try sbd.get(c.id).waits.map(\.id) == [wait])
  }

  @Test func rmAndManagerEndGiveTheSameRefusalForAChat() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")
    let wait = try ends.typedWait(sbd, c)

    let viaRm = failure(sbd, "rm", ["session": .string(c.id)])
    let viaEnd = failure(sbd, "manager-end", ["session": .string(c.id)])

    #expect(viaRm.contains(wait), Comment(rawValue: viaRm))
    #expect(viaEnd == viaRm)
  }

  @Test func endWithNewStartsAnUntitledChatInTheSameGroup() throws {
    let sbd = try Instance()
    let flags = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")

    let answer = try sbd.client.call("manager-end", ["session": .string(c.id), "new": true])

    let fresh = try sbd.get(try ends.started(answer))
    #expect(fresh.kind == .chat)
    #expect(fresh.chat == flags.id)
    #expect(fresh.name == Manager.untitled)
    #expect(fresh.cwd == chats.chatFolder(sbd, flags))
    #expect(try listed(sbd, "Flags").map(\.id) == [fresh.id])
  }

  @Test func chatEndWithNewAndANameNamesTheNewChat() throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")

    let answer = try #require(
      JSON.parse(try sbd.sb("chat", "Flags", "--end", c.id, "--new", "--name", "Next steps", "--json")))

    #expect(try sbd.get(try ends.started(answer)).name == "Next steps")
  }

  @Test(arguments: [true, false]) func endWithNewCarriesThePinOver(_ pinned: Bool) throws {
    let sbd = try Instance()
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")
    if pinned { _ = try sbd.client.call("manager-pin", ["session": .string(c.id), "pinned": true]) }

    let answer = try sbd.client.call("manager-end", ["session": .string(c.id), "new": true])

    let isPinned = try sbd.get(try ends.started(answer)).pinned == true
    #expect(isPinned == pinned)
  }

  @Test func endWithNewCarriesTheAccountOverAndNotTheDefault() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    _ = try chats.addGroup(sbd, "Flags")
    let c = try idleChat(sbd, "Flags", name: "target")
    try #require(c.account == sbd.account("A"))
    try sbd.sb("account", "use", "B", "--new-only")

    let answer = try sbd.client.call("manager-end", ["session": .string(c.id), "new": true])

    #expect(try sbd.get(try ends.started(answer)).account == sbd.account("A"))
  }

  // MARK: chat-log by group

  @Test func chatLogForTheGroupReadsTheMostRecentConversation() throws {
    let sbd = try Instance()
    let flags = try chats.addGroup(sbd, "Flags")
    _ = try idleChat(sbd, "Flags", name: "first", "hello")
    _ = try idleChat(sbd, "Flags", name: "second", "second")

    let log = try chatLog(sbd, ["group": .string(flags.id)])

    #expect(log == ["user: second", "assistant: Done: second"])
  }

  /// `chat-log` by group, `sb chat` without a session, and the first row of `--ls` name the same conversation.
  @Test func theGroupsChatIsTheFirstConversationThatLsLists() throws {
    let sbd = try Instance()
    let flags = try chats.addGroup(sbd, "Flags")
    _ = try idleChat(sbd, "Flags", name: "first", "hello")
    _ = try idleChat(sbd, "Flags", name: "second", "second")
    let first = try #require(try listed(sbd, "Flags").first)

    let byGroup = try chatLog(sbd, ["group": .string(flags.id)])
    let bySession = try chatLog(sbd, ["session": .string(first.id)])
    let opened = try chats.chat(sbd, "Flags")

    #expect(byGroup == bySession)
    #expect(opened.id == first.id)
  }

  @Test func chatLogForTheGroupSkipsAConversationThatIsDone() throws {
    let sbd = try Instance()
    let flags = try chats.addGroup(sbd, "Flags")
    _ = try idleChat(sbd, "Flags", name: "first", "hello")
    let second = try idleChat(sbd, "Flags", name: "second", "second")
    try sbd.sb("done", second.id)

    let log = try chatLog(sbd, ["group": .string(flags.id)])

    #expect(log == ["user: hello", "assistant: Done: hello"])
  }

  // MARK: Help

  @Test func helpDocumentsEachChatFlag() throws {
    let sbd = try Instance()

    let usage = try sbd.sb("help")

    let chatLines = usage.split(separator: "\n").filter { $0.contains("chat <group>") }.joined(separator: "\n")
    for flag in ["--new", "--ls", "--session", "--end"] {
      #expect(chatLines.contains(flag), "\(flag) in \(chatLines)")
    }
  }
}
