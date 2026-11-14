import Foundation
import SwitchboardCore
import Testing

/// The reply count, unread count, and last message time on each group chat's and Manager conversation's
/// summary, and the `chat-read` request that marks replies read. Only the user marks a chat read, so sbd refuses
/// every request that carries a `caller`. A chat or conversation with no `chat-read` event predates read state,
/// and sbd marks its replies read when it starts.
@Suite(.blocking(timeLimit: .seconds(120))) struct ChatReadTests {
  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  // MARK: Helpers from ChatTests

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

  func ls(_ sbd: Instance) throws -> [SessionSummary] { try decode([SessionSummary].self, sbd.sb("ls", "--json")) }

  // MARK: Helpers from ManagerConversationsTests

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  func newConversation(_ sbd: Instance, name: String? = nil, _ text: String? = nil) throws -> SessionSummary {
    var args = ["manager", "new", "--json"]
    if let name { args += ["--name", name] }
    if let text { args.append(text) }
    return try decode(SessionSummary.self, sbd.sb(args))
  }

  /// Sends `text` to the session and waits for the turn's reply.
  @discardableResult
  func turn(_ sbd: Instance, _ id: String, _ text: String) throws -> SessionSummary {
    try sbd.sb("send", id, text)
    return try sbd.waitFor(id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  /// A conversation whose first turn, for `text`, has ended.
  func idleConversation(_ sbd: Instance, name: String? = nil, _ text: String = "hello") throws -> SessionSummary {
    let c = try newConversation(sbd, name: name)
    try sbd.waitFor(c.id, "the stub") { $0.live }
    return try turn(sbd, c.id, text)
  }

  func conversations(_ sbd: Instance) throws -> [SessionSummary] {
    try decode([SessionSummary].self, sbd.sb("manager", "ls", "--json"))
  }

  // MARK: Read state

  /// The `replies` of each `chat-read` event of the session, oldest first. A read without a count is nil.
  func reads(_ sbd: Instance, _ id: String) throws -> [Int?] {
    try sbd.events(id).filter { $0.kind == ChatActivity.readEvent }.map { $0.data["replies"]?.int }
  }

  func activity(_ sbd: Instance, _ id: String) throws -> ChatActivity {
    try #require(try sbd.get(id).activity, "no activity on \(id)")
  }

  func unread(_ sbd: Instance, _ id: String) throws -> Int { try activity(sbd, id).unread }

  /// Waits until the session's summary counts `replies` replies.
  @discardableResult
  func waitForReplies(_ sbd: Instance, _ id: String, _ replies: Int) throws -> SessionSummary {
    try sbd.waitFor(id, "\(replies) replies") { $0.activity?.replies == replies }
  }

  func chatRead(_ sbd: Instance, _ args: [String: JSON]) throws -> SessionSummary {
    try JSONCoding.convert(sbd.client.call(ChatActivity.readEvent, args), to: SessionSummary.self)
  }

  /// A group "Flags" whose chat has replied to "one" and "two", and is idle.
  func chatWithTwoReplies(_ sbd: Instance) throws -> (group: GroupSummary, chat: SessionSummary) {
    let flags = try addGroup(sbd, "Flags")
    try replied(sbd, flags.id, "one")
    let c = try replied(sbd, flags.id, "two")
    return (flags, try waitForReplies(sbd, c.id, 2))
  }

  // MARK: Counts on the summary

  @Test func aChatThatRepliedTwiceShowsTwoUnreadRepliesAndTheLastMessageTime() throws {
    let sbd = try Instance()
    let (_, c) = try chatWithTwoReplies(sbd)
    let lastStop = try #require(try sbd.events(c.id).last { $0.kind == "Stop" })

    let listed = try #require(try ls(sbd).first { $0.id == c.id }?.activity)

    #expect(listed.replies == 2)
    #expect(listed.unread == 2)
    #expect((listed.lastMessageAt ?? 0) >= lastStop.t)
  }

  @Test func aWorkSessionsSummaryHasNoActivity() throws {
    let sbd = try Instance()
    let work = try sbd.idleSession(name: "work")

    #expect(try sbd.get(work.id).activity == nil)
    #expect(try ls(sbd).first { $0.id == work.id }?.activity == nil)
  }

  // MARK: Reading through sb

  @Test func chatReadMarksTheChatReadAndALaterReplyIsUnread() throws {
    let sbd = try Instance()
    let (flags, c) = try chatWithTwoReplies(sbd)

    let read = try decode(SessionSummary.self, sbd.sb("chat", flags.id, "--read", "--json"))
    try replied(sbd, flags.id, "three")
    try waitForReplies(sbd, c.id, 3)

    #expect(read.activity?.unread == 0)
    #expect(try unread(sbd, c.id) == 1)
  }

  @Test func managerReadMarksTheConversationReadAndALaterReplyIsUnread() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    try turn(sbd, c.id, "two")
    try waitForReplies(sbd, c.id, 2)

    let read = try decode(SessionSummary.self, sbd.sb("manager", c.id, "--read", "--json"))
    try turn(sbd, c.id, "three")
    try waitForReplies(sbd, c.id, 3)

    #expect(read.activity?.unread == 0)
    #expect(try unread(sbd, c.id) == 1)
  }

  @Test func managerLsAndGetTextNameTheUnreadCount() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)

    let line = try #require(try sbd.sb("manager", "ls").split(separator: "\n").first { $0.contains(c.id) })
    let got = try sbd.sb("get", c.id).lowercased()

    #expect(line.contains("1 unread"), "\(line)")
    #expect(got.contains("unread"), "\(got)")
    #expect(got.contains("last message"), "\(got)")
  }

  @Test func managerLsTextLeavesOutTheUnreadCountOnceRead() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    try sbd.sb("manager", c.id, "--read")

    let line = try #require(try sbd.sb("manager", "ls").split(separator: "\n").first { $0.contains(c.id) })

    #expect(!line.contains("unread"), "\(line)")
  }

  // MARK: The clamp: a read marks only what the reader saw

  /// The app passes the count of the summary it showed. A reply that landed after that summary stays unread.
  @Test func aReadOfOneAfterTwoRepliesLeavesOneUnread() throws {
    let sbd = try Instance()
    let (_, c) = try chatWithTwoReplies(sbd)

    let read = try chatRead(sbd, ["session": .string(c.id), "replies": 1])

    #expect(read.activity?.unread == 1)
    #expect(try unread(sbd, c.id) == 1)
  }

  @Test func aReadAboveTheReplyCountMarksOnlyTheRepliesThereAre() throws {
    let sbd = try Instance()
    let (flags, c) = try chatWithTwoReplies(sbd)

    let read = try chatRead(sbd, ["session": .string(c.id), "replies": 9])
    try replied(sbd, flags.id, "three")
    try waitForReplies(sbd, c.id, 3)

    #expect(read.activity?.unread == 0)
    #expect(try unread(sbd, c.id) == 1)
    #expect(try reads(sbd, c.id).last == 2)
  }

  @Test func aReadWithoutACountMarksEveryReplyRead() throws {
    let sbd = try Instance()
    let (_, c) = try chatWithTwoReplies(sbd)

    let read = try chatRead(sbd, ["session": .string(c.id)])

    #expect(read.activity?.unread == 0)
  }

  @Test func aSecondIdenticalReadRecordsNoEvent() throws {
    let sbd = try Instance()
    let (_, c) = try chatWithTwoReplies(sbd)

    _ = try chatRead(sbd, ["session": .string(c.id), "replies": 2])
    _ = try chatRead(sbd, ["session": .string(c.id), "replies": 2])

    #expect(try reads(sbd, c.id) == [0, 2])
  }

  @Test(arguments: [0, 1, 2])
  func aReadAtOrBelowTheReadCountRecordsNoEventAndLowersNothing(_ lower: Int) throws {
    let sbd = try Instance()
    let (_, c) = try chatWithTwoReplies(sbd)
    _ = try chatRead(sbd, ["session": .string(c.id), "replies": 2])

    let again = try chatRead(sbd, ["session": .string(c.id), "replies": .number(Double(lower))])

    #expect(again.activity?.unread == 0)
    #expect(try reads(sbd, c.id) == [0, 2])
  }

  @Test func aReadOfAChatWithNoNewReplyRecordsNoEvent() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let c = try chat(sbd, flags.id)

    _ = try chatRead(sbd, ["session": .string(c.id)])

    #expect(try reads(sbd, c.id) == [0])
  }

  /// A `replies` that is not a number is not the CLI's "no count". Reading it as "every reply" would hide replies
  /// that the reader never saw.
  @Test(arguments: [JSON.string("1"), .bool(true)])
  func aReadWithAMalformedCountHidesNoReply(_ replies: JSON) throws {
    let sbd = try Instance()
    let (_, c) = try chatWithTwoReplies(sbd)

    _ = try? sbd.client.call(ChatActivity.readEvent, ["session": .string(c.id), "replies": replies])

    #expect(try unread(sbd, c.id) == 2)
  }

  // MARK: Which sessions have read state

  @Test func chatReadOnAWorkSessionFailsAndNamesIt() throws {
    let sbd = try Instance()
    let work = try sbd.idleSession(name: "busywork")

    let error = failure(sbd, ChatActivity.readEvent, ["session": .string(work.id)])

    #expect(error.contains("busywork"), Comment(rawValue: error))
    #expect(error.contains("is not a Manager conversation or a group chat"), Comment(rawValue: error))
    #expect(try reads(sbd, work.id).isEmpty)
  }

  @Test func managerReadOfAWorkSessionFails() throws {
    let sbd = try Instance()
    let work = try sbd.idleSession(name: "busywork")

    let result = try sbd.run("manager", work.id, "--read", "--json")

    #expect(result.status != 0)
    #expect(try reads(sbd, work.id).isEmpty)
  }

  // MARK: Only the user reads a chat

  /// Where `sb chat <group> --read` runs: inside the chat itself, or inside a Manager conversation.
  enum Reader: CaseIterable { case theChatItself, aManagerConversation }

  /// The CLI sends `caller` from SB_SESSION_ID, so a session that runs it is refused.
  @Test(arguments: Reader.allCases)
  func chatReadInsideASessionFailsAndHidesNothing(_ reader: Reader) throws {
    let sbd = try Instance()
    let (flags, c) = try chatWithTwoReplies(sbd)
    let caller: String
    switch reader {
    case .theChatItself: caller = c.id
    case .aManagerConversation: caller = try newConversation(sbd).id
    }

    let result = try sbd.run(["chat", flags.id, "--read", "--json"], env: inside(caller))

    #expect(result.status != 0)
    #expect(try unread(sbd, c.id) == 2)
    #expect(try reads(sbd, c.id) == [0])
  }

  @Test func managerReadInsideTheConversationFailsAndHidesNothing() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)

    let result = try sbd.run(["manager", c.id, "--read", "--json"], env: inside(c.id))

    #expect(result.status != 0)
    #expect(try unread(sbd, c.id) == 1)
    #expect(try reads(sbd, c.id) == [0])
  }

  /// Every `caller` is refused, whichever session it names and whichever way the request names the chat.
  @Test func chatReadRefusesEveryCaller() throws {
    let sbd = try Instance()
    let (flags, c) = try chatWithTwoReplies(sbd)
    let m = try idleConversation(sbd)
    let work = try sbd.new(name: "work")
    let callers: [(String, String)] = [
      ("the chat itself", c.id), ("a Manager conversation", m.id), ("a work session", work.id),
      ("an unknown session", "szzzzz"), ("an empty id", ""),
    ]
    let targets: [(String, [String: JSON], String)] = [
      ("the chat by group", ["group": .string(flags.id)], c.id),
      ("the chat by session", ["session": .string(c.id)], c.id),
      ("the conversation by session", ["session": .string(m.id)], m.id),
      ("the conversation as manager", ["session": .string(m.id), "manager": true], m.id),
    ]
    let unreadBefore = [c.id: try unread(sbd, c.id), m.id: try unread(sbd, m.id)]
    try #require(unreadBefore[c.id] == 2)
    try #require(unreadBefore[m.id] == 1)

    for (who, caller) in callers {
      for (what, args, id) in targets {
        let error = failure(sbd, ChatActivity.readEvent, args.merging(["caller": .string(caller)]) { $1 })

        #expect(error != "no error", "\(who) reading \(what)")
        #expect(try unread(sbd, id) == unreadBefore[id], "\(who) reading \(what)")
      }
    }
    #expect(try reads(sbd, c.id) == [0])
    #expect(try reads(sbd, m.id) == [0])
  }

  // MARK: Naming the chat

  @Test func chatReadForAGroupWithNoChatFailsAndMakesNoSession() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")

    let result = try sbd.run("chat", "Flags", "--read", "--json")
    let request = failure(sbd, ChatActivity.readEvent, ["group": "Flags"])

    #expect(result.status != 0)
    #expect(request != "no error")
    #expect(try ls(sbd).isEmpty)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: "\(sbd.home.path)/chats")) ?? []).isEmpty)
  }

  @Test func chatReadForAGroupThatDoesNotExistFails() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")

    let result = try sbd.run("chat", "Nowhere", "--read", "--json")

    #expect(result.status != 0)
    #expect(try ls(sbd).isEmpty)
  }

  @Test func chatReadForAnUnknownSessionFails() throws {
    let sbd = try Instance()

    #expect(failure(sbd, ChatActivity.readEvent, ["session": "nope"]) != "no error")
  }

  @Test func chatReadForAnAmbiguousNameFailsAndReadsNeither() throws {
    let sbd = try Instance()
    let first = try idleConversation(sbd, name: "twin")
    let second = try idleConversation(sbd, name: "twin")

    let error = failure(sbd, ChatActivity.readEvent, ["session": "twin"])

    #expect(error != "no error")
    #expect(try unread(sbd, first.id) == 1)
    #expect(try unread(sbd, second.id) == 1)
  }

  /// How a request can name the chat session: its id, a prefix of its id, or its name.
  enum ChatName: CaseIterable { case id, idPrefix, name }

  @Test(arguments: ChatName.allCases)
  func chatReadNamingTheChatSessionReadsWhatChatReadForTheGroupReads(_ how: ChatName) throws {
    let sbd = try Instance()
    let (_, c) = try chatWithTwoReplies(sbd)
    let ref: String
    switch how {
    case .id: ref = c.id
    case .idPrefix: ref = String(c.id.prefix(4))
    case .name: ref = c.name
    }

    let read = try chatRead(sbd, ["session": .string(ref), "replies": 1])

    #expect(read.id == c.id)
    #expect(read.activity?.unread == 1)
  }

  @Test func chatReadByGroupReadsTheGroupsChat() throws {
    let sbd = try Instance()
    let (flags, c) = try chatWithTwoReplies(sbd)

    let read = try chatRead(sbd, ["group": .string(flags.id), "replies": 1])

    #expect(read.id == c.id)
    #expect(read.activity?.unread == 1)
  }

  @Test func chatReadNamingAConversationBySessionReadsIt() throws {
    let sbd = try Instance()
    let m = try idleConversation(sbd)

    let read = try chatRead(sbd, ["session": .string(m.id)])

    #expect(read.id == m.id)
    #expect(read.activity?.unread == 0)
  }

  // MARK: Reading is not activity

  @Test func readingTheOlderConversationLeavesTheOrderAndItsLastActivity() throws {
    let sbd = try Instance()
    let older = try idleConversation(sbd, name: "older")
    _ = try idleConversation(sbd, name: "newer")
    let before = try conversations(sbd)
    try #require(before.map(\.name) == ["newer", "older"])
    let olderBefore = try #require(before.first { $0.id == older.id })

    try sbd.sb("manager", older.id, "--read")

    let after = try conversations(sbd)
    let olderAfter = try #require(after.first { $0.id == older.id })
    #expect(after.map(\.id) == before.map(\.id))
    #expect(olderAfter.lastActivity == olderBefore.lastActivity)
    #expect(olderAfter.state == olderBefore.state)
    #expect(olderAfter.since == olderBefore.since)
    #expect(olderAfter.activity?.unread == 0)
  }

  @Test func aReadDuringATurnLeavesTheTurn() throws {
    let sbd = try Instance()
    let m = try idleConversation(sbd)
    try sbd.sb("send", m.id, "slow 30")
    // The stub's PreToolUse for the sleep is its last hook until the sleep ends.
    let working = try sbd.waitFor(m.id, "the sleep") { $0.state == .working && $0.reason.contains("sleep 30") }

    let read = try decode(SessionSummary.self, sbd.sb("manager", m.id, "--read", "--json"))

    #expect(read.state == .working)
    #expect(read.lastActivity == working.lastActivity)
    #expect(read.since == working.since)
    #expect(read.activity?.unread == 0)
  }

  // MARK: The baseline that create records

  /// Each way that a chat or a conversation starts.
  enum Creation: String, CaseIterable, CustomTestStringConvertible {
    case chat = "sb chat <group>"
    case chatSend = "sb chat <group> --send"
    case managerNew = "sb manager new"
    case managerNewText = "sb manager new <text>"
    case bareManager = "sb manager"
    var testDescription: String { rawValue }
  }

  /// Starts a session the `how` way and returns it once it has replied twice.
  func createWithTwoReplies(_ sbd: Instance, _ how: Creation) throws -> SessionSummary {
    let created: SessionSummary
    switch how {
    case .chat:
      let flags = try addGroup(sbd, "Flags")
      created = try chat(sbd, flags.id)
      try #require(try reads(sbd, created.id) == [0])
      try sbd.waitFor(created.id, "the stub") { $0.live }
      try replied(sbd, flags.id, "one")
      try replied(sbd, flags.id, "two")
    case .chatSend:
      let flags = try addGroup(sbd, "Flags")
      created = try replied(sbd, flags.id, "one")
      try #require(try reads(sbd, created.id) == [0])
      try replied(sbd, flags.id, "two")
    case .managerNew:
      created = try newConversation(sbd)
      try #require(try reads(sbd, created.id) == [0])
      try sbd.waitFor(created.id, "the stub") { $0.live }
      try turn(sbd, created.id, "one")
      try turn(sbd, created.id, "two")
    case .managerNewText:
      created = try newConversation(sbd, "one")
      try #require(try reads(sbd, created.id) == [0])
      try sbd.waitFor(created.id, "the first reply", timeout: 30) { $0.lastReply == "Done: one" }
      try turn(sbd, created.id, "two")
    case .bareManager:
      created = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
      try #require(try reads(sbd, created.id) == [0])
      try sbd.waitFor(created.id, "the stub") { $0.live }
      try turn(sbd, created.id, "one")
      try turn(sbd, created.id, "two")
    }
    return try waitForReplies(sbd, created.id, 2)
  }

  @Test(arguments: Creation.allCases)
  func createRecordsOneReadOfZero(_ how: Creation) throws {
    let sbd = try Instance()

    let s = try createWithTwoReplies(sbd, how)

    #expect(try reads(sbd, s.id) == [0])
    #expect(s.activity?.unread == 2)
  }

  @Test func aWorkSessionGetsNoBaselineRead() throws {
    let sbd = try Instance()

    let work = try sbd.new(name: "work")

    #expect(try reads(sbd, work.id).isEmpty)
  }

  @Test(arguments: Creation.allCases)
  func unreadSurvivesAnSbdRestart(_ how: Creation) throws {
    let sbd = try Instance()
    let s = try createWithTwoReplies(sbd, how)
    let before = try activity(sbd, s.id)
    try #require(before.unread == 2)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try activity(sbd, s.id) == before)
    #expect(try reads(sbd, s.id) == [0])
  }

  /// A restart builds facts from a snapshot plus the events after it, or from the whole log. Both keep a partly
  /// read chat's count.
  @Test(arguments: [true, false])
  func aPartlyReadChatKeepsItsUnreadAcrossARestart(snapshot: Bool) throws {
    let sbd = try Instance()
    let (flags, c) = try chatWithTwoReplies(sbd)
    try replied(sbd, flags.id, "three")
    try waitForReplies(sbd, c.id, 3)
    _ = try chatRead(sbd, ["session": .string(c.id), "replies": 1])
    let before = try activity(sbd, c.id)
    try #require(before.unread == 2)

    try restart(sbd, snapshot: snapshot, checking: [c.id])

    #expect(try activity(sbd, c.id) == before)
    #expect(try reads(sbd, c.id) == [0, 1])
  }

  /// A chat created with no reply yet still counts its first reply after a restart, because its baseline is 0.
  @Test(arguments: [true, false])
  func aChatRestartedBeforeItsFirstReplyCountsThatReplyUnread(snapshot: Bool) throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let c = try chat(sbd, flags.id)
    try sbd.waitFor(c.id, "the stub") { $0.live }
    try restart(sbd, snapshot: snapshot)

    try replied(sbd, flags.id, "one")
    try waitForReplies(sbd, c.id, 1)
    try restart(sbd, snapshot: snapshot, checking: [c.id])

    #expect(try unread(sbd, c.id) == 1)
    #expect(try reads(sbd, c.id) == [0])
  }

  /// Restarts sbd, from saved snapshots or from a full replay, and requires that it loaded each of `ids` that way.
  func restart(_ sbd: Instance, snapshot: Bool, checking ids: [String] = []) throws {
    if snapshot {
      try sbd.sb("snapshots", "--write")
      try sbd.restart(snapshotEvery: 500)
    } else {
      try sbd.restart(snapshotEvery: 0)
    }
    let loaded = try sbd.loaded()
    for id in ids {
      let how = loaded[id]?["loaded"]?.string ?? ""
      try #require(how.hasPrefix(snapshot ? "snapshot + " : "replay of "), "\(id) loaded by \(how)")
    }
  }

  // MARK: The store from before read state

  static let oldChatId = "sch4t1"
  static let oldManagerId = "s64qrh"

  /// Stores a group chat and a Manager conversation as an sbd from before read state stored them, each with
  /// `replies` replies and no `chat-read` event, and starts sbd again. It replaces the database that the first
  /// start wrote, so that start leaves no record in it.
  func seedOldStore(_ sbd: Instance, replies: Int) throws -> (group: String, chat: String, manager: String) {
    let now = try sbd.now()
    sbd.stopSbd()
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: sbd.home.database + suffix) }
    let group = SessionGroup(id: "g0ld01", name: "Flags", description: nil, created: now - 10_000)
    try FileManager.default.createDirectory(atPath: sbd.home.managerFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: sbd.home.chatFolder(group.id), withIntermediateDirectories: true)
    var chat = Session(
      id: Self.oldChatId, name: "Flags chat", cwd: sbd.home.chatFolder(group.id),
      claudeSessionId: UUID().uuidString.lowercased(), created: now - 9000)
    chat.chat = group.id
    var manager = Session(
      id: Self.oldManagerId, name: "Manager", cwd: sbd.home.managerFolder,
      claudeSessionId: UUID().uuidString.lowercased(), created: now - 9000)
    manager.manager = true
    do {
      let store = try Store(path: sbd.home.database)
      try store.save(group: group)
      for session in [chat, manager] {
        try store.save(session)
        try store.append(
          Event(session: session.id, t: now - 8000, kind: "created", data: ["cwd": .string(session.cwd)]))
        for i in 0..<replies {
          let t = now - 7000 + Int64(i) * 100
          try store.append(
            Event(session: session.id, t: t, kind: "UserPromptSubmit", data: ["prompt": .string("old \(i)")]))
          try store.append(
            Event(
              session: session.id, t: t + 50, kind: "Stop", data: ["last_assistant_message": .string("Done: old \(i)")])
          )
        }
      }
    }
    try sbd.startSbd()
    return (group.id, chat.id, manager.id)
  }

  @Test func anOldChatAndTheOldManagerStartWithNoUnreadReplies() throws {
    let sbd = try Instance()

    let old = try seedOldStore(sbd, replies: 2)

    for id in [old.chat, old.manager] {
      #expect(try activity(sbd, id).replies == 2, "\(id)")
      #expect(try unread(sbd, id) == 0, "\(id)")
      #expect(try reads(sbd, id) == [2], "\(id)")
    }
  }

  @Test(arguments: [true, false])
  func theMigrationRunsOnceAcrossRestarts(snapshot: Bool) throws {
    let sbd = try Instance()
    let old = try seedOldStore(sbd, replies: 2)

    try restart(sbd, snapshot: snapshot, checking: [old.chat, old.manager])

    for id in [old.chat, old.manager] {
      #expect(try unread(sbd, id) == 0, "\(id)")
      #expect(try reads(sbd, id) == [2], "\(id)")
    }
  }

  @Test func anOldChatsNextReplyIsUnread() throws {
    let sbd = try Instance()
    let old = try seedOldStore(sbd, replies: 2)

    try replied(sbd, old.group, "hello")
    try waitForReplies(sbd, old.chat, 3)

    #expect(try unread(sbd, old.chat) == 1)
  }

  @Test func theOldManagersNextReplyIsUnread() throws {
    let sbd = try Instance()
    let old = try seedOldStore(sbd, replies: 2)
    _ = try sbd.sb("manager", "Manager", "--json")
    try sbd.waitFor(old.manager, "the stub") { $0.live }

    try turn(sbd, old.manager, "hello")
    try waitForReplies(sbd, old.manager, 3)

    #expect(try unread(sbd, old.manager) == 1)
  }

  /// The migration records a read of 0 for a conversation with no replies. Without it, the restart would find
  /// no read and mark the new reply read.
  @Test(arguments: [true, false])
  func anOldConversationWithNoRepliesKeepsItsFirstReplyUnreadAcrossARestart(snapshot: Bool) throws {
    let sbd = try Instance()
    let old = try seedOldStore(sbd, replies: 0)
    try #require(try reads(sbd, old.manager) == [0])
    _ = try sbd.sb("manager", "Manager", "--json")
    try sbd.waitFor(old.manager, "the stub") { $0.live }
    try turn(sbd, old.manager, "hello")
    try waitForReplies(sbd, old.manager, 1)
    try #require(try unread(sbd, old.manager) == 1)

    try restart(sbd, snapshot: snapshot, checking: [old.manager])

    #expect(try unread(sbd, old.manager) == 1)
    #expect(try reads(sbd, old.manager) == [0])
  }

  @Test(arguments: [true, false])
  func anOldChatWithNoRepliesKeepsItsFirstReplyUnreadAcrossARestart(snapshot: Bool) throws {
    let sbd = try Instance()
    let old = try seedOldStore(sbd, replies: 0)
    try #require(try reads(sbd, old.chat) == [0])
    try replied(sbd, old.group, "hello")
    try waitForReplies(sbd, old.chat, 1)

    try restart(sbd, snapshot: snapshot, checking: [old.chat])

    #expect(try unread(sbd, old.chat) == 1)
    #expect(try reads(sbd, old.chat) == [0])
  }
}
