import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelChats {
  @Test func theSidebarLeavesOutAChatWhateverItsState() {
    for state in [AttentionState.working, .needsYou, .done] {
      let model = appliedModel([chatItem("c", group: "g1", state: state), needsItem("a", state: state)])

      let ids = model.sidebarGroups.flatMap { $0.rows.map(\.id) }

      #expect(ids == ["a"])
    }
  }

  @Test func theBoardsWorkSessionsLeaveOutChatsAndTheManager() {
    let model = appliedModel([
      chatItem("c", group: "g1"), needsItem("m", manager: true), needsItem("a"),
    ])

    #expect(model.workBoard.map(\.id) == ["a"])
  }

  @Test func theInboxAndTheBadgeLeaveOutAChatWithOnlyAReply() {
    let model = appliedModel([chatItem("c", group: "g1"), needsItem("a")])

    #expect(model.triage.map(\.id) == ["a"])
    #expect(model.needsUser.map(\.id) == ["a"])
  }

  @Test func chatOfAGroupFindsThatGroupsChatOnly() {
    let model = appliedModel([chatItem("c1", group: "g1"), chatItem("c2", group: "g2"), needsItem("a")])

    #expect(model.chat(of: "g1")?.id == "c1")
    #expect(model.chat(of: "g2")?.id == "c2")
    #expect(model.chat(of: "g3") == nil)
  }

  @Test func openChatStartsAGroupsFirstChatWithTheGroup() async {
    let sent = await firstRequest { $0.openChat("g1") }

    #expect(sent.op == "chat")
    #expect(sent.args == ["group": "g1"])
  }

  @Test func loadChatLogAsksForTheSessionsLog() async {
    let sent = await firstRequest { $0.loadChatLog("c") }

    #expect(sent.op == "chat-log")
    #expect(sent.args == ["session": "c"])
  }

  @Test func loadChatLogStoresSbdsAnswer() async throws {
    let model = offlineModel()
    let log = [ChatMessage(role: .user, text: "How is it going?", t: 100)]
    let answer = try JSONCoding.convert(log, to: JSON.self)
    model.send = { op, _ in op == "chat-log" ? answer : .null }

    model.loadChatLog("m")
    await settle { model.chatLogs["m"] != nil }

    #expect(model.chatLogs["m"] == log)
  }

  @Test func aFailedChatLogReadKeepsTheStoredLog() async {
    let model = offlineModel()
    let log = [ChatMessage(role: .user, text: "How is it going?", t: 100)]
    model.chatLogs["m"] = log
    let read = Counter()
    model.send = { _, _ in
      read.increment()
      throw Boom()
    }

    model.loadChatLog("m")
    await settle { read.value > 0 }
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(model.chatLogs["m"] == log)
  }

  @Test func loadBlockSourcesAsksForClaudesMessagesOnly() async {
    let sent = await firstRequest { $0.loadBlockSources("w") { _ in } }

    #expect(sent.op == "chat-log")
    #expect(
      sent.args == ["session": "w", "role": "assistant", "limit": .number(Double(BoardModel.blockSourceMessageCount))])
  }

  @Test func loadChatLogAsksForAManagerConversationsLog() async {
    let sent = await firstRequest { $0.loadChatLog("m") }

    #expect(sent.op == "chat-log")
    #expect(sent.args == ["session": "m"])
  }

  @Test func openChatSelectsAChatThatExistsWithoutAskingSbd() {
    let model = appliedModel([chatItem("c", group: "g1"), needsItem("a")])
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }

    model.openChat("g1")

    #expect(model.selection == "c")
    Thread.sleep(forTimeInterval: 0.2)
    #expect(sent.value == 0)
  }

  // MARK: A chat's blocking prompts

  @Test(arguments: [Card.Kind.permission, .question, .trust])
  func aChatsBlockingCardReachesTheInboxBadgeAndMenuBar(_ kind: Card.Kind) throws {
    let model = appliedModel([try chatCard("c", group: "g1", kind: kind), needsItem("a")])

    #expect(model.triage.map(\.id) == ["c", "a"])
    #expect(Set(model.needsUser.map(\.id)) == ["c", "a"])
  }

  @Test func aChatsSendCardStaysOut() throws {
    let model = appliedModel([try chatCard("c", group: "g1", kind: .send), needsItem("a")])

    #expect(model.triage.map(\.id) == ["a"])
    #expect(model.needsUser.map(\.id) == ["a"])
  }

  @Test func aChatCardNotifiesWhenTheChatMovesFromAReplyToTheCard() throws {
    let model = appliedModel([chatItem("c", group: "g1"), needsItem("a")])

    let next = [try chatCard("c", group: "g1"), needsItem("a")]

    #expect(model.sessionsToNotify(next).map(\.id) == ["c"])
  }

  @Test func aChatCardDoesNotNotifyTwice() throws {
    let model = appliedModel([chatItem("c", group: "g1")])
    let first = [try chatCard("c", group: "g1", card: 1)]
    try #require(model.sessionsToNotify(first).map(\.id) == ["c"])
    model.apply(.success(first), followups: nil)

    let second = [try chatCard("c", group: "g1", card: 2)]

    #expect(model.sessionsToNotify(first).isEmpty)
    #expect(model.sessionsToNotify(second).isEmpty)
  }

  @Test func aChatMovingFromACardToAReplyDoesNotNotify() throws {
    let model = appliedModel([try chatCard("c", group: "g1")])

    let next = [chatItem("c", group: "g1")]

    #expect(model.sessionsToNotify(next).isEmpty)
  }

  @Test func nextNeedingYouVisitsAChatCard() throws {
    let model = appliedModel([try chatCard("c", group: "g1"), needsItem("a")])
    model.show(.inbox)
    var inbox: Set<String?> = []
    for _ in 0..<2 {
      model.selectNextNeedingYou()
      inbox.insert(model.currentInboxItem)
    }
    model.show(.board)
    var board: Set<String?> = []
    for _ in 0..<2 {
      model.selectNextNeedingYou()
      board.insert(model.selection)
    }

    #expect(inbox == ["c", "a"])
    #expect(board == ["c", "a"])
  }

  @Test func revealingAChatItemSelectsTheChat() throws {
    let model = appliedModel([try chatCard("c", group: "g1"), needsItem("a")])
    let item = try #require(model.triage.first)

    model.reveal(item.id)

    #expect(model.selection == "c")
    #expect(model.selected?.chat == "g1")
  }

  /// A chat whose name is not the default name of its group's current name reads as the group's chat, then its own
  /// name.
  @Test func aChatsInboxNameStartsWithItsGroupsCurrentName() throws {
    let model = appliedModel([try chatCard("c", group: "g1")])
    let chat = try #require(model.triage.first)
    model.groups = [GroupSummary(SessionGroup(id: "g1", name: "Billing", description: nil, created: 0), sessions: [])]
    #expect(model.inboxName(chat) == "Billing chat: \(chat.name)")

    model.groups = [GroupSummary(SessionGroup(id: "g2", name: "Flags", description: nil, created: 0), sessions: [])]
    #expect(model.inboxName(chat) == chat.name)
  }
}

/// A chat of group `group` with `lastActivity`, which orders the group's conversations. `archived` is the flag that
/// sbd sets from its clock.
func groupConversation(
  _ id: String, group: String = "g1", lastActivity: Int64, created: Int64? = nil, done: Bool = false,
  archived: Bool? = nil, unread: Int = 0, state: AttentionState = .needsYou
) -> SessionSummary {
  var s = chatItem(id, group: group, state: done ? .done : state)
  s.triage = nil
  s.lastActivity = lastActivity
  s.created = created ?? lastActivity
  s.markedDone = done
  s.activity = ChatActivity(replies: 1, unread: unread, lastMessageAt: lastActivity, archived: archived)
  return s
}

/// Several conversations in one group chat (Decisions 3 and 9 to 11).
@MainActor
@Suite struct BoardModelChatTests {
  // MARK: The group's most recent conversation

  @Test func chatOfAGroupIsItsNewestConversation() {
    let model = appliedModel([
      groupConversation("old", lastActivity: 10), groupConversation("new", lastActivity: 20), needsItem("a"),
    ])

    #expect(model.chat(of: "g1")?.id == "new")
  }

  @Test func chatOfAGroupSkipsAConversationThatIsDone() {
    let model = appliedModel([
      groupConversation("finished", lastActivity: 20, done: true), groupConversation("live", lastActivity: 10),
    ])

    #expect(model.chat(of: "g1")?.id == "live")
  }

  @Test func chatOfAGroupIsItsNewestDoneConversationWhenEveryOneIsDone() {
    let model = appliedModel([
      groupConversation("older", lastActivity: 10, done: true),
      groupConversation("newer", lastActivity: 20, done: true),
    ])

    #expect(model.chat(of: "g1")?.id == "newer")
  }

  @Test func chatOfAGroupBreaksAnActivityTieByTheNewestCreated() {
    let model = appliedModel([
      groupConversation("early", lastActivity: 10, created: 1), groupConversation("late", lastActivity: 10, created: 5),
    ])

    #expect(model.chat(of: "g1")?.id == "late")
  }

  @Test func chatOfAGroupBreaksAFullTieById() {
    let model = appliedModel([
      groupConversation("b", lastActivity: 10, created: 1), groupConversation("a", lastActivity: 10, created: 1),
      groupConversation("c", lastActivity: 10, created: 1),
    ])

    #expect(model.chat(of: "g1")?.id == "a")
  }

  @Test func openChatSelectsTheGroupsMostRecentConversationWithoutAskingSbd() {
    let model = appliedModel([
      groupConversation("old", lastActivity: 20), groupConversation("new", lastActivity: 30),
      groupConversation("finished", lastActivity: 40, done: true), needsItem("a"),
    ])
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }

    model.openChat("g1")

    #expect(model.selection == "new")
    Thread.sleep(forTimeInterval: 0.2)
    #expect(sent.value == 0)
  }

  // MARK: The archive

  /// The group column has its own archive. Revealing an archived chat leaves the sidebar's Manager archive closed.
  @Test func showingAnArchivedChatLeavesTheManagersArchiveClosed() {
    let chat = groupConversation("z", lastActivity: 2, archived: true)
    let model = appliedModel([groupConversation("a", lastActivity: 30), chat, needsItem("w", state: .working)])

    model.showInSidebar(chat)

    #expect(model.selection == "z")
    #expect(!model.showingArchive)
  }

  // MARK: chats(of:)

  /// The app orders a group's conversations as sbd's `chats(of:)` does, so the Board's Chat button opens the
  /// conversation that `sb chat <group>` reaches.
  @Test func chatsOfAGroupListNewestActivityFirstThenNewestCreated() {
    let model = appliedModel([
      groupConversation("old", lastActivity: 5, created: 0), groupConversation("new", lastActivity: 9, created: 0),
      groupConversation("later", lastActivity: 5, created: 3),
      groupConversation("other", group: "g2", lastActivity: 99),
    ])

    #expect(model.chats(of: "g1").map(\.id) == ["new", "later", "old"])
  }

  @Test func aDoneChatListsAfterEveryChatThatIsNotDone() {
    let model = appliedModel([
      groupConversation("done", lastActivity: 9, done: true), groupConversation("live", lastActivity: 1),
    ])

    #expect(model.chats(of: "g1").map(\.id) == ["live", "done"])
  }

  @Test func chatsWithEqualActivityAndCreationListById() {
    let model = appliedModel([
      groupConversation("b", lastActivity: 5, created: 1), groupConversation("a", lastActivity: 5, created: 1),
      groupConversation("c", lastActivity: 5, created: 1),
    ])

    #expect(model.chats(of: "g1").map(\.id) == ["a", "b", "c"])
  }

  @Test func chatsOfAGroupLeaveOutOtherKindsOfSession() {
    let model = appliedModel([
      groupConversation("c", lastActivity: 1), needsItem("m", manager: true), operatorItem(), needsItem("w"),
    ])

    #expect(model.chats(of: "g1").map(\.id) == ["c"])
  }

  @Test func chatsOfAGroupLeaveOutAChatBeingRemoved() {
    var removed = groupConversation("gone", lastActivity: 9)
    removed.removal = Removal(
      requested: 0, notBefore: 0, worktree: false, branch: false, remoteBranch: false, resolve: [])
    let model = appliedModel([removed, groupConversation("kept", lastActivity: 1)])

    #expect(model.chats(of: "g1").map(\.id) == ["kept"])
  }

  @Test func chatsOfAGroupWithNoChatAreEmpty() {
    #expect(appliedModel([groupConversation("c", group: "g2", lastActivity: 1)]).chats(of: "g1").isEmpty)
  }

  /// `chat(of:)` is the first of `chats(of:)` for every order that decides it.
  @Test func chatOfAGroupIsTheFirstOfItsChats() {
    let lists: [[SessionSummary]] = [
      [groupConversation("old", lastActivity: 10), groupConversation("new", lastActivity: 20)],
      [groupConversation("live", lastActivity: 10), groupConversation("finished", lastActivity: 20, done: true)],
      [
        groupConversation("early", lastActivity: 10, created: 1),
        groupConversation("late", lastActivity: 10, created: 5),
      ],
      [groupConversation("b", lastActivity: 10, created: 1), groupConversation("a", lastActivity: 10, created: 1)],
      [],
    ]
    for list in lists {
      let model = appliedModel(list)

      #expect(model.chat(of: "g1")?.id == model.chats(of: "g1").first?.id, "\(list.map(\.id))")
    }
  }

  // MARK: A refresh that moves only lastActivity

  /// sbd bumps `lastActivity` on every hook event, and it orders a group's conversations, so a refresh that moves
  /// only one chat's `lastActivity` ahead makes that chat the group's most recent.
  @Test func aRefreshThatMovesOnlyAChatsActivityAheadMakesItTheGroupsChat() throws {
    let old = groupConversation("old", lastActivity: 10)
    let new = groupConversation("new", lastActivity: 20)
    let model = appliedModel([old, new])
    try #require(model.chat(of: "g1")?.id == "new")
    var moved = old
    moved.lastActivity = 30

    model.apply(.success([moved, new]), followups: nil)

    #expect(model.chat(of: "g1")?.id == "old")
    #expect(model.chats(of: "g1").map(\.id) == ["old", "new"])
  }

  @Test func aRefreshThatMovesOnlyAManagerConversationsActivityAheadReordersTheSidebar() throws {
    var older = needsItem("older", manager: true)
    older.lastActivity = 10
    var newer = needsItem("newer", manager: true)
    newer.lastActivity = 20
    let model = appliedModel([older, newer])
    try #require(model.conversations.active.map(\.id) == ["newer", "older"])
    var moved = older
    moved.lastActivity = 30

    model.apply(.success([moved, newer]), followups: nil)

    #expect(model.conversations.active.map(\.id) == ["older", "newer"])
  }

  /// A refresh that moves only a work session's `lastActivity` leaves the list as it was, so the views don't redraw
  /// on each of its hook events.
  @Test func aRefreshThatMovesOnlyAWorkSessionsActivityKeepsTheList() {
    var work = needsItem("w")
    work.lastActivity = 10
    let model = appliedModel([work])
    var moved = work
    moved.lastActivity = 30

    model.apply(.success([moved]), followups: nil)

    #expect(model.allSessions.first?.lastActivity == 10)
  }

  // MARK: New conversation

  @Test func newChatSendsChatWithTheGroupAndNew() async {
    let sent = await firstRequest { $0.newChat("g1") }

    #expect(sent.op == "chat")
    #expect(sent.args == ["group": "g1", "new": true])
  }

  /// Unlike `openChat`, a group that has a conversation still asks sbd for another.
  @Test func newChatAsksSbdWhenTheGroupHasAConversation() async {
    let (model, sent) = recordingModel([groupConversation("c1", lastActivity: 10)])

    model.newChat("g1")
    await sent.wait(for: "chat")

    #expect(sent.value.first { $0.op == "chat" }?.args == ["group": "g1", "new": true])
  }

  @Test func newChatSelectsTheConversationThatSbdStarted() async throws {
    let model = appliedModel([groupConversation("c1", lastActivity: 10)])
    model.selection = "c1"
    let answer = try JSON(encoding: groupConversation("c2", lastActivity: 20))
    model.send = { op, _ in op == "chat" ? answer : .null }

    model.newChat("g1")
    await settle { model.selection == "c2" }

    #expect(model.selection == "c2")
  }

  // MARK: Rename (Decision 10)

  @Test func renameSendsRenameWithTheSessionAndTheName() async {
    let sent = await firstRequest { $0.rename("c1", to: "Billing plan") }

    #expect(sent.op == "rename")
    #expect(sent.args == ["session": "c1", "name": "Billing plan"])
  }

  @Test func renameTrimsTheName() async {
    let sent = await firstRequest { $0.rename("c1", to: "  Billing plan \n") }

    #expect(sent.args["name"] == "Billing plan")
  }

  /// sbd refuses an empty name. The app sends nothing for a name of only white space.
  @Test(arguments: ["", "   ", "\n\t"])
  func renameWithABlankNameSendsNothing(_ name: String) async {
    let (model, sent) = recordingModel([groupConversation("c1", lastActivity: 10)])

    model.rename("c1", to: name)
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(sent.value.isEmpty)
  }

  // MARK: The group column's archive

  @Test func theGroupColumnsArchiveStartsClosed() {
    #expect(offlineModel().shownChatArchives.isEmpty)
  }

  @Test func showingAnArchivedChatOpensItsGroupsColumnArchive() {
    let chat = groupConversation("z", lastActivity: 2, archived: true)
    let model = appliedModel([groupConversation("a", lastActivity: 30), chat])

    model.showInSidebar(chat)

    #expect(model.shownChatArchives == ["g1"])
  }

  @Test func openingAnArchivedChatFromSearchOpensItsGroupsColumnArchive() {
    let model = appliedModel([
      groupConversation("a", lastActivity: 30), groupConversation("z", lastActivity: 2, archived: true),
    ])

    model.openFromSearch("z")

    #expect(model.shownChatArchives == ["g1"])
  }

  /// The Board's Chat button opens the group's most recent conversation even when it is archived, so its row shows.
  @Test func openChatOnAnArchivedChatOpensItsGroupsColumnArchive() {
    let model = appliedModel([groupConversation("z", lastActivity: 2, archived: true)])

    model.openChat("g1")

    #expect(model.selection == "z")
    #expect(model.shownChatArchives == ["g1"])
    #expect(!model.showingArchive)
  }

  @Test func showingAnActiveChatLeavesTheGroupColumnsArchiveClosed() {
    let chat = groupConversation("a", lastActivity: 30)
    let model = appliedModel([chat, groupConversation("z", lastActivity: 2, archived: true)])

    model.showInSidebar(chat)

    #expect(model.shownChatArchives.isEmpty)
  }

  @Test func showingAnArchivedManagerConversationLeavesTheGroupColumnsArchiveClosed() {
    var manager = needsItem("m", manager: true)
    manager.activity = ChatActivity(replies: 1, unread: 0, lastMessageAt: 2, archived: true)
    let model = appliedModel([manager, groupConversation("z", lastActivity: 2, archived: true)])

    model.showInSidebar(manager)

    #expect(model.showingArchive)
    #expect(model.shownChatArchives.isEmpty)
  }

  /// Opening a group column's archive leaves the sidebar's Manager archive, and the order that Next Session reads,
  /// alone.
  @Test func openingAGroupColumnsArchiveLeavesTheSidebarsArchiveClosed() {
    var manager = needsItem("m", manager: true)
    manager.activity = ChatActivity(replies: 1, unread: 0, lastMessageAt: 2, archived: true)
    let model = appliedModel([manager, groupConversation("z", lastActivity: 2, archived: true)])
    let order = model.sidebarOrder

    model.shownChatArchives.insert("g1")

    #expect(!model.showingArchive)
    #expect(model.sidebarOrder == order)
  }

  @Test func openingAnArchivedChatFromSearchLeavesTheManagersArchiveClosed() {
    let model = appliedModel([
      groupConversation("a", lastActivity: 30), groupConversation("z", lastActivity: 2, archived: true),
      needsItem("w", state: .working),
    ])

    model.openFromSearch("z")

    #expect(model.selection == "z")
    #expect(!model.showingArchive)
  }

  @Test func theOpenRenameSheetCountsAsASheet() {
    let model = offlineModel()
    #expect(!model.presentingSheet)
    model.renaming = "s1"
    #expect(model.presentingSheet)
  }
}
