import AppKit
import SwitchboardCore
import Testing
import os

@testable import SwitchboardApp

/// A Manager conversation as sbd lists it: read and idle unless the arguments say otherwise. `archived` is the
/// flag that sbd sets from its clock.
private func conversation(
  _ id: String, lastActivity: Int64 = 10, pinned: Bool? = nil, archived: Bool? = nil, replies: Int = 1,
  unread: Int = 0, state: AttentionState = .needsYou, name: String? = nil, lastReply: String? = "Done."
) -> SessionSummary {
  var s = needsItem(id, manager: true, state: state)
  s.triage = nil
  s.name = name ?? id
  s.lastActivity = lastActivity
  s.lastReply = lastReply
  s.pinned = pinned
  s.activity = ChatActivity(replies: replies, unread: unread, lastMessageAt: lastActivity, archived: archived)
  return s
}

/// Infra (g1) and Web (g2), as sbd's `group-ls` lists them.
private let listedGroups = [
  GroupSummary(SessionGroup(id: "g1", name: "Infra", created: 0), sessions: []),
  GroupSummary(SessionGroup(id: "g2", name: "Web", created: 0), sessions: []),
]

@MainActor
private func groupedModel(_ list: [SessionSummary]) -> BoardModel {
  let model = appliedModel(list)
  model.applyGroups(listedGroups)
  return model
}

@MainActor
@Suite struct BoardModelConversations {
  // MARK: The sidebar's groups

  @Test func theSidebarListsPinnedThenActiveThenArchivedEachNewestFirst() {
    let model = appliedModel([
      conversation("a1", lastActivity: 30), conversation("p1", lastActivity: 5, pinned: true),
      conversation("z1", lastActivity: 2, archived: true), conversation("a2", lastActivity: 40),
      conversation("p2", lastActivity: 8, pinned: true), conversation("z2", lastActivity: 3, archived: true),
      needsItem("w"),
    ])

    #expect(model.conversations.pinned.map(\.id) == ["p2", "p1"])
    #expect(model.conversations.active.map(\.id) == ["a2", "a1"])
    #expect(model.conversations.archived.map(\.id) == ["z2", "z1"])
  }

  /// The sidebar orders chats by recency like conversations. It ignores `Chat.Order`'s done-first rule.
  @Test func chatsAndConversationsInterleaveNewestFirstWithinPinnedActiveAndArchived() {
    let model = appliedModel([
      conversation("pm", lastActivity: 5, pinned: true), groupConversation("pc", lastActivity: 8, pinned: true),
      conversation("am", lastActivity: 30), groupConversation("ac", lastActivity: 40),
      conversation("am2", lastActivity: 20),
      groupConversation("zc", lastActivity: 3, archived: true), conversation("zm", lastActivity: 2, archived: true),
      groupConversation("zc2", lastActivity: 1, archived: true),
    ])

    #expect(model.conversations.pinned.map(\.id) == ["pc", "pm"])
    #expect(model.conversations.active.map(\.id) == ["ac", "am", "am2"])
    #expect(model.conversations.archived.map(\.id) == ["zc", "zm", "zc2"])
  }

  @Test func aChatMarkedDoneKeepsItsRecencyPlace() {
    var done = groupConversation("done", lastActivity: 40)
    done.markedDone = true
    let model = appliedModel([done, groupConversation("open", lastActivity: 10), conversation("m", lastActivity: 20)])

    #expect(model.conversations.active.map(\.id) == ["done", "m", "open"])
  }

  @Test func sidebarConversationsHoldsChatsAndConversationsNewestFirst() {
    let model = appliedModel([
      conversation("m", lastActivity: 20), groupConversation("c", lastActivity: 30), needsItem("w"), operatorItem(),
    ])

    #expect(model.sidebarConversations.map(\.id) == ["c", "m"])
  }

  @Test func theArchiveStartsCollapsed() {
    #expect(offlineModel().showingArchive == false)
  }

  // MARK: Next and Previous Session

  @Test func theSidebarOrderLeavesOutArchivedRowsWhileTheArchiveIsCollapsed() {
    let model = appliedModel([
      conversation("p", lastActivity: 5, pinned: true), conversation("a", lastActivity: 30),
      conversation("z", lastActivity: 2, archived: true), needsItem("w", state: .working),
    ])

    #expect(model.sidebarOrder == ["p", "a", "w"])
  }

  @Test func theSidebarOrderIncludesArchivedRowsWhileTheArchiveIsOpen() {
    let model = appliedModel([
      conversation("p", lastActivity: 5, pinned: true), conversation("a", lastActivity: 30),
      conversation("z", lastActivity: 2, archived: true), needsItem("w", state: .working),
    ])

    model.showingArchive = true

    #expect(model.sidebarOrder == ["p", "a", "z", "w"])
  }

  @Test func nextSessionSkipsArchivedRowsWhileTheArchiveIsCollapsed() {
    let model = appliedModel([
      conversation("a", lastActivity: 30), conversation("z", lastActivity: 2, archived: true),
      needsItem("w", state: .working),
    ])
    model.selection = "a"

    model.selectAdjacentSession(by: 1)

    #expect(model.selection == "w")
  }

  @Test func nextSessionVisitsArchivedRowsWhileTheArchiveIsOpen() {
    let model = appliedModel([
      conversation("a", lastActivity: 30), conversation("z", lastActivity: 2, archived: true),
      needsItem("w", state: .working),
    ])
    model.showingArchive = true
    model.selection = "a"

    model.selectAdjacentSession(by: 1)

    #expect(model.selection == "z")
  }

  @Test func aPinnedChatLeadsTheSidebarOrder() {
    let model = appliedModel([
      conversation("m", lastActivity: 30), groupConversation("c", lastActivity: 1, pinned: true),
      needsItem("w", state: .working),
    ])

    #expect(model.sidebarOrder == ["c", "m", "w"])
  }

  @Test func theOrdersLeaveOutAnArchivedChatWhileTheArchiveIsCollapsed() {
    let model = appliedModel([
      conversation("a", lastActivity: 30), groupConversation("z", lastActivity: 2, archived: true),
      needsItem("w", state: .working),
    ])

    #expect(model.conversationOrder.map(\.id) == ["a"])
    #expect(model.sidebarOrder == ["a", "w"])
  }

  @Test func theOrdersIncludeAnArchivedChatWhileTheArchiveIsOpen() {
    let model = appliedModel([
      conversation("a", lastActivity: 30), groupConversation("z", lastActivity: 2, archived: true),
      needsItem("w", state: .working),
    ])

    model.showingArchive = true

    #expect(model.conversationOrder.map(\.id) == ["a", "z"])
    #expect(model.sidebarOrder == ["a", "z", "w"])
  }

  @Test func nextSessionStepsFromAConversationToAChat() {
    let model = appliedModel([
      conversation("m", lastActivity: 30), groupConversation("c", lastActivity: 20), needsItem("w", state: .working),
    ])
    model.selection = "m"

    model.selectAdjacentSession(by: 1)

    #expect(model.selection == "c")
  }

  // MARK: The empty sidebar

  @Test(arguments: [nil, true] as [Bool?])
  func theSidebarIsNotEmptyWithOnlyAChat(_ archived: Bool?) throws {
    try #require(appliedModel([]).sidebarIsEmpty)

    #expect(!appliedModel([groupConversation("c", archived: archived)]).sidebarIsEmpty)
  }

  // MARK: Row titles

  @Test func aChatRowIsTitledWithItsGroupAndName() {
    let c = groupConversation("c", group: "g1", name: "Deploy plan")
    let model = groupedModel([c])

    #expect(model.conversationTitle(c) == "Infra chat: Deploy plan")
  }

  @Test func aChatOfAGroupThatSbdDoesNotListIsTitledWithItsName() {
    let c = groupConversation("c", group: "gone", name: "Deploy plan")
    let model = groupedModel([c])

    #expect(model.conversationTitle(c) == "Deploy plan")
  }

  /// The sidebar names a conversation without the Inbox's "Manager: " prefix.
  @Test func aConversationRowIsTitledWithItsBareName() {
    let m = conversation("m", name: "Cache key plan")
    let model = groupedModel([m])

    #expect(model.conversationTitle(m) == "Cache key plan")
  }

  // MARK: The group filter

  /// A conversation and a chat of each group, with the filter showing only g1.
  func filteredModel() -> BoardModel {
    let model = orgFilterModel(groupFilter: GroupFilter(keys: ["g1"]))
    model.apply(
      .success([conversation("m"), groupConversation("c1", group: "g1"), groupConversation("c2", group: "g2")]),
      followups: nil)
    model.applyGroups(listedGroups)
    return model
  }

  /// `GroupFilter.key(of:)` keys a chat by its group. A Manager conversation has no key, so it always shows.
  @Test func aChatOfAHiddenGroupIsNotListed() {
    let model = filteredModel()

    let ids = model.conversations.pinned + model.conversations.active + model.conversations.archived

    #expect(Set(ids.map(\.id)) == ["m", "c1"])
    #expect(!model.sidebarOrder.contains("c2"))
  }

  /// Selecting a hidden chat, as a link or a notification does, widens the filter, so its row shows.
  @Test func selectingAChatOfAHiddenGroupWidensTheFilterAndListsIt() {
    let model = filteredModel()

    model.selection = "c2"

    #expect(model.selection == "c2")
    #expect(model.sidebarOrder.contains("c2"))
  }

  // MARK: Rows

  @Test(arguments: [
    ("First line\nSecond line", "First line"),
    ("\n\nAfter blank lines\nmore", "After blank lines"),
    ("   \nAfter spaces", "After spaces"),
    ("Only line", "Only line"),
  ])
  func theRowPreviewIsTheFirstNonEmptyLineOfTheLastReply(_ reply: String, _ preview: String) {
    #expect(firstLine(reply) == preview)
  }

  @Test(arguments: [nil, "", "\n\n", "   "] as [String?])
  func aConversationWithNoReplyTextHasNoPreview(_ reply: String?) {
    #expect(reply.flatMap(firstLine) == nil)
  }

  /// The row's dot shows unread replies, so the mark beside the title leaves out the unread count.
  @Test(arguments: [
    (ChatMark.unread(2, working: true), ChatMark?.some(.working)),
    (.unread(2, working: false), nil),
    (.working, .working),
    (.needsMe("approve"), .needsMe("approve")),
    (.idle(lastMessageAt: 1), nil),
    (.none, nil),
  ])
  func theRowShowsOnlyTheProgressOrNeedsMeMarkBesideTheTitle(_ mark: ChatMark, _ shown: ChatMark?) {
    #expect(ConversationRow.trailingMark(mark) == shown)
  }

  // MARK: Pin

  @Test func setPinnedSendsManagerPinWithTheSessionAndTrue() async {
    let sent = await firstRequest { $0.setPinned("m", true) }

    #expect(sent.op == "manager-pin")
    #expect(sent.args == ["session": "m", "pinned": true])
  }

  @Test func setPinnedSendsManagerPinWithFalseToUnpin() async {
    let sent = await firstRequest { $0.setPinned("m", false) }

    #expect(sent.op == "manager-pin")
    #expect(sent.args == ["session": "m", "pinned": false])
  }

  // MARK: The toolbar's Manager icon

  @Test func theIconIsNeedsMeForAConversationWithASendCard() throws {
    let model = appliedModel([try carded(conversation("m"), kind: .send), conversation("n", unread: 1)])

    #expect(ManagerIcon(model.managers) == .needsMe)
  }

  @Test(arguments: [Card.Kind.permission, .question, .trust, .send, .mcp])
  func theIconIsNeedsMeForEveryCardKind(_ kind: Card.Kind) throws {
    let model = appliedModel([try carded(conversation("m"), kind: kind)])

    #expect(ManagerIcon(model.managers) == .needsMe)
  }

  @Test func theIconIsUnreadForAConversationWithUnreadReplies() {
    let model = appliedModel([conversation("m", unread: 1), conversation("n")])

    #expect(ManagerIcon(model.managers) == .unread)
  }

  /// A conversation goes to Needs you on a plain reply. Once the user read it, the icon is an outline.
  @Test func theIconIsAnOutlineForAReadConversationInNeedsYouFromAReply() {
    let model = appliedModel([conversation("m", state: .needsYou)])

    #expect(ManagerIcon(model.managers) == .outline)
  }

  @Test func theIconIsAnOutlineWithoutConversations() {
    #expect(ManagerIcon(appliedModel([needsItem("a")]).managers) == .outline)
  }

  /// The icon and each row read `ChatMark`, so they agree.
  @Test func theIconFollowsTheMarksOfTheConversations() throws {
    let shapes: [SessionSummary] = [
      conversation("m"), conversation("m", unread: 2), conversation("m", unread: 2, state: .working),
      conversation("m", state: .working), try carded(conversation("m"), kind: .send),
      try carded(conversation("m", unread: 2), kind: .permission),
    ]
    for s in shapes {
      let expected: ManagerIcon
      switch ChatMark(s) {
      case .needsMe: expected = .needsMe
      case .unread: expected = .unread
      case .none, .working, .idle: expected = .outline
      }

      #expect(ManagerIcon([s]) == expected, "\(ChatMark(s))")
    }
  }

  /// A misspelled symbol name draws an empty toolbar item.
  @Test(arguments: [ManagerIcon.needsMe, .unread, .outline])
  func theIconsSymbolExists(_ icon: ManagerIcon) {
    #expect(NSImage(systemSymbolName: icon.systemImage, accessibilityDescription: nil) != nil)
  }

  @Test func waitingManagerSkipsANeedsYouFromAReplyOnly() {
    let model = appliedModel([conversation("m", lastActivity: 30, state: .needsYou)])

    #expect(model.waitingManager == nil)
  }

  @Test func waitingManagerIsTheFirstConversationThatNeedsMe() throws {
    let model = appliedModel([
      conversation("replied", lastActivity: 30, unread: 1, state: .needsYou),
      try carded(conversation("carded", lastActivity: 20), kind: .send),
    ])

    #expect(model.waitingManager?.id == "carded")
  }

  // MARK: Search

  /// ⌘K searches the board, which holds every Manager conversation, archived ones included.
  @Test func searchFindsAnArchivedConversationByName() {
    let model = appliedModel([
      conversation("z", lastActivity: 2, archived: true, name: "Cache key plan"), conversation("a", lastActivity: 30),
      needsItem("w"),
    ])

    let found = SessionSearch.rank(model.board, query: "cache key")

    #expect(found.map(\.id).contains("z"))
  }

  @Test func openingAnArchivedConversationFromSearchOpensTheArchive() throws {
    let model = appliedModel([
      conversation("a", lastActivity: 30), conversation("z", lastActivity: 2, archived: true),
      needsItem("w", state: .working),
    ])
    try #require(!model.sidebarOrder.contains("z"))

    model.openFromSearch("z")

    #expect(model.selection == "z")
    #expect(model.showingArchive)
    #expect(model.sidebarOrder.contains("z"))
  }

  @Test func openingAnActiveChatFromSearchLeavesTheArchivesClosed() {
    let model = appliedModel([
      conversation("a", lastActivity: 30), groupConversation("c", group: "g1", lastActivity: 20),
    ])

    model.openFromSearch("c")

    #expect(model.selection == "c")
    #expect(!model.showingArchive)
    #expect(model.shownChatArchives.isEmpty)
  }

  @Test func openingAnArchivedConversationFromSearchLeavesTheGroupArchivesClosed() {
    let model = appliedModel([conversation("a", lastActivity: 30), conversation("z", lastActivity: 2, archived: true)])

    model.openFromSearch("z")

    #expect(model.shownChatArchives.isEmpty)
  }

  // MARK: The toolbar's Manager icon ignores chats

  @Test func managersLeavesOutChats() {
    let model = appliedModel([groupConversation("c", lastActivity: 30), conversation("m", lastActivity: 20)])

    #expect(model.managers.map(\.id) == ["m"])
  }
}

/// ⌘K reads the transcripts of archived Manager conversations with `chat-log` and keeps them by session id.
@MainActor
@Suite struct BoardModelConversationsTranscripts {
  /// A `send` that records every request and answers `chat-log` with one message that names the session and
  /// holds "kafka". A read of a session in `failing` throws.
  nonisolated func answering(_ sent: SentRequests, failing: Set<String> = [])
    -> @Sendable (String, [String: JSON]) throws -> JSON
  {
    { op, args in
      sent.append(op, args)
      guard op == "chat-log" else { return .null }
      let id = args["session"]?.string ?? ""
      if failing.contains(id) { throw Boom() }
      return try JSONCoding.convert(
        [
          ChatMessage(role: .user, text: "Start \(id)"),
          ChatMessage(role: .assistant, text: "Tune the kafka lag of \(id)."),
        ],
        to: JSON.self)
    }
  }

  func model(_ list: [SessionSummary], _ sent: SentRequests, failing: Set<String> = []) -> BoardModel {
    let model = appliedModel(list)
    model.send = answering(sent, failing: failing)
    return model
  }

  func reads(_ sent: SentRequests) -> [[String: JSON]] { sent.value.filter { $0.op == "chat-log" }.map(\.args) }

  func readIDs(_ sent: SentRequests) -> [String] { reads(sent).compactMap { $0["session"]?.string } }

  @Test func readsAnArchivedConversationWithChatLogAndALimitOf50() async {
    let sent = SentRequests()
    let model = model([conversation("z", archived: true), needsItem("w")], sent)

    _ = await model.archivedTranscripts(for: model.board)

    #expect(reads(sent) == [["session": .string("z"), "limit": .number(50)]])
  }

  @Test func searchFindsAnArchivedConversationByItsTranscript() async {
    let sent = SentRequests()
    let model = model(
      [
        conversation("z", lastActivity: 2, archived: true, name: "Cache key plan"), conversation("a", lastActivity: 30),
      ],
      sent)

    let transcripts = await model.archivedTranscripts(for: model.board)

    #expect(SessionSearch.rank(model.board, query: "kafka", transcripts: transcripts).map(\.id) == ["z"])
  }

  enum Unsearched: String, CaseIterable, Sendable {
    case archivedChat, activeConversation, pinnedConversation, archivedWorkSession, archivedOperator

    var session: SessionSummary {
      switch self {
      case .archivedChat: return groupConversation("x", archived: true)
      case .activeConversation: return conversation("x")
      case .pinnedConversation: return conversation("x", pinned: true)
      case .archivedWorkSession:
        var s = needsItem("x", state: .done)
        s.activity = ChatActivity(replies: 1, unread: 0, lastMessageAt: 1, archived: true)
        return s
      case .archivedOperator:
        var s = operatorItem("x", state: .working)
        s.activity = ChatActivity(replies: 1, unread: 0, lastMessageAt: 1, archived: true)
        return s
      }
    }
  }

  /// ⌘K searches the transcripts of archived Manager conversations only.
  @Test(arguments: Unsearched.allCases)
  func aSessionThatIsNotAnArchivedConversationGetsNoRead(_ shape: Unsearched) async {
    let sent = SentRequests()
    let model = model([shape.session, conversation("z", lastActivity: 2, archived: true)], sent)

    let transcripts = await model.archivedTranscripts(for: model.board)

    #expect(readIDs(sent) == ["z"], "\(shape.rawValue)")
    #expect(transcripts["x"] == nil, "\(shape.rawValue)")
  }

  @Test func noArchivedConversationSendsNoRead() async {
    let sent = SentRequests()
    let model = model([conversation("a"), groupConversation("c", archived: true), needsItem("w")], sent)

    let transcripts = await model.archivedTranscripts(for: model.board)

    #expect(reads(sent).isEmpty)
    #expect(transcripts.isEmpty)
  }

  /// The reads cover the sessions that the panel froze, so a conversation that is not in them gets no read.
  @Test func readsOnlyTheSessionsItIsGiven() async {
    let sent = SentRequests()
    let model = model(
      [conversation("z1", lastActivity: 2, archived: true), conversation("z2", lastActivity: 3, archived: true)], sent)

    _ = await model.archivedTranscripts(for: model.board.filter { $0.id == "z1" })

    #expect(readIDs(sent) == ["z1"])
  }

  @Test func readsAtMostThe100NewestArchivedConversations() async {
    let sent = SentRequests()
    let list = (1...101).map { conversation("z\($0)", lastActivity: Int64($0), archived: true) }
    let model = model(list, sent)

    _ = await model.archivedTranscripts(for: model.board)

    #expect(reads(sent).count == 100)
    #expect(Set(readIDs(sent)) == Set((2...101).map { "z\($0)" }))
  }

  /// The reads run one at a time.
  @Test func readsRunOneAtATime() async {
    let model = appliedModel((1...5).map { conversation("z\($0)", lastActivity: Int64($0), archived: true) })
    let inFlight = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
    model.send = { op, _ in
      guard op == "chat-log" else { return .null }
      inFlight.withLock {
        $0.now += 1
        $0.most = max($0.most, $0.now)
      }
      Thread.sleep(forTimeInterval: 0.02)
      inFlight.withLock { $0.now -= 1 }
      return try JSONCoding.convert([ChatMessage(role: .user, text: "kafka")], to: JSON.self)
    }

    _ = await model.archivedTranscripts(for: model.board)

    #expect(inFlight.withLock { $0.most } == 1)
  }

  /// The reads stay off the refresh queue, so a slow read does not hold up the chat log that the open pane reads.
  @Test func aHeldReadDoesNotBlockTheChatLogOfTheOpenPane() async throws {
    let model = appliedModel([conversation("z", lastActivity: 2, archived: true), conversation("m", lastActivity: 9)])
    let release = DispatchSemaphore(value: 0)
    let held = Counter()
    let log = try JSONCoding.convert([ChatMessage(role: .user, text: "How is it going?")], to: JSON.self)
    model.send = { op, args in
      guard op == "chat-log" else { return .null }
      if args["limit"] != nil {
        held.increment()
        release.wait()
      }
      return log
    }
    let reading = Task { await model.archivedTranscripts(for: model.board) }
    await settle { held.value > 0 }
    try #require(held.value == 1)

    model.loadChatLog("m")
    await settle { model.chatLogs["m"] != nil }
    let loaded = model.chatLogs["m"] != nil
    release.signal()
    _ = await reading.value

    #expect(loaded)
  }

  // MARK: The cache

  @Test func aSecondOpenWithTheSameActivitySendsNoRead() async {
    let sent = SentRequests()
    let model = model([conversation("z", lastActivity: 2, archived: true)], sent)
    _ = await model.archivedTranscripts(for: model.board)
    let first = reads(sent).count

    let transcripts = await model.archivedTranscripts(for: model.board)

    #expect(reads(sent).count == first)
    #expect(SessionSearch.rank(model.board, query: "kafka", transcripts: transcripts).map(\.id) == ["z"])
  }

  @Test func aConversationWhoseActivityChangedIsReadAgain() async {
    let sent = SentRequests()
    let model = model(
      [conversation("z1", lastActivity: 2, archived: true), conversation("z2", lastActivity: 3, archived: true)], sent)
    _ = await model.archivedTranscripts(for: model.board)
    let first = reads(sent).count
    model.apply(
      .success([
        conversation("z1", lastActivity: 2, archived: true), conversation("z2", lastActivity: 9, archived: true),
      ]),
      followups: nil)

    _ = await model.archivedTranscripts(for: model.board)

    #expect(Array(readIDs(sent).dropFirst(first)) == ["z2"])
  }

  // MARK: A failed read

  @Test func aFailedReadLeavesTheOtherConversationsSearchable() async {
    let sent = SentRequests()
    let model = model(
      [conversation("a", lastActivity: 2, archived: true), conversation("b", lastActivity: 3, archived: true)], sent,
      failing: ["a"])

    let transcripts = await model.archivedTranscripts(for: model.board)

    #expect(Set(transcripts.keys) == ["b"])
    #expect(SessionSearch.rank(model.board, query: "kafka", transcripts: transcripts).map(\.id) == ["b"])
  }

  /// A failed read caches nothing, so the next open tries it again.
  @Test func aFailedReadIsTriedAgainOnTheNextOpen() async {
    let sent = SentRequests()
    let failing = model(
      [conversation("a", lastActivity: 2, archived: true), conversation("b", lastActivity: 3, archived: true)], sent,
      failing: ["a"])
    _ = await failing.archivedTranscripts(for: failing.board)
    let first = reads(sent).count
    failing.send = answering(sent)

    let transcripts = await failing.archivedTranscripts(for: failing.board)

    #expect(Array(readIDs(sent).dropFirst(first)) == ["a"])
    #expect(Set(transcripts.keys) == ["a", "b"])
  }
}
