import AppKit
import SwitchboardCore
import Testing

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

  @Test func theConversationsListLeavesOutGroupChatsAndWorkSessions() {
    var c = chatItem("c", group: "g1")
    c.activity = ChatActivity(replies: 1, unread: 0)
    let model = appliedModel([conversation("m"), c, needsItem("w")])

    let ids = model.conversations.pinned + model.conversations.active + model.conversations.archived

    #expect(ids.map(\.id) == ["m"])
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

  // MARK: Rows

  @Test(arguments: [
    ("First line\nSecond line", "First line"),
    ("\n\nAfter blank lines\nmore", "After blank lines"),
    ("Only line", "Only line"),
  ])
  func theRowPreviewIsTheFirstNonEmptyLineOfTheLastReply(_ reply: String, _ preview: String) {
    #expect(ConversationRow.preview(reply) == preview)
  }

  @Test(arguments: [nil, "", "\n\n"] as [String?])
  func aConversationWithNoReplyTextHasNoPreview(_ reply: String?) {
    #expect(ConversationRow.preview(reply) == nil)
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

  // MARK: The toolbar star

  @Test func theStarIsNeedsMeForAConversationWithASendCard() throws {
    let model = appliedModel([try carded(conversation("m"), kind: .send), conversation("n", unread: 1)])

    #expect(ManagerStar(model.managers) == .needsMe)
  }

  @Test(arguments: [Card.Kind.permission, .question, .trust, .send])
  func theStarIsNeedsMeForEveryCardKind(_ kind: Card.Kind) throws {
    let model = appliedModel([try carded(conversation("m"), kind: kind)])

    #expect(ManagerStar(model.managers) == .needsMe)
  }

  @Test func theStarIsUnreadForAConversationWithUnreadReplies() {
    let model = appliedModel([conversation("m", unread: 1), conversation("n")])

    #expect(ManagerStar(model.managers) == .unread)
  }

  /// A conversation goes to Needs you on a plain reply. Once the user read it, the star is an outline.
  @Test func theStarIsAnOutlineForAReadConversationInNeedsYouFromAReply() {
    let model = appliedModel([conversation("m", state: .needsYou)])

    #expect(ManagerStar(model.managers) == .outline)
  }

  @Test func theStarIsAnOutlineWithoutConversations() {
    #expect(ManagerStar(appliedModel([needsItem("a")]).managers) == .outline)
  }

  /// The star and each row read `ChatMark`, so they agree.
  @Test func theStarFollowsTheMarksOfTheConversations() throws {
    let shapes: [SessionSummary] = [
      conversation("m"), conversation("m", unread: 2), conversation("m", unread: 2, state: .working),
      conversation("m", state: .working), try carded(conversation("m"), kind: .send),
      try carded(conversation("m", unread: 2), kind: .permission),
    ]
    for s in shapes {
      let expected: ManagerStar
      switch ChatMark(s) {
      case .needsMe: expected = .needsMe
      case .unread: expected = .unread
      case .none, .working, .idle: expected = .outline
      }

      #expect(ManagerStar([s]) == expected, "\(ChatMark(s))")
    }
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
}
