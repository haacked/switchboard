import Foundation
import Testing

@testable import SwitchboardCore

/// A Manager conversation's summary as sbd builds it. The defaults give an idle, read, unpinned conversation
/// whose last activity was at `lastActivity`.
private func conversation(
  _ id: String = "m1", lastActivity: Int64 = 1_000_000, created: Int64? = 500, state: AttentionState = .needsYou,
  pinned: Bool? = nil, activity: ChatActivity? = ChatActivity(replies: 2, unread: 0, lastMessageAt: 1_000_000),
  cards: [Card] = [], openPrompt: Bool = false
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp/manager", repo: nil, branch: nil, claudeSessionId: id, state: state,
    reason: "read its last reply and decide what's next", since: 0, lastActivity: lastActivity, live: false,
    claudePid: nil, attached: false, lastReply: "Done.", waits: [], notes: [], cards: cards, openPrompt: openPrompt)
  s.kind = .manager
  s.manager = true
  s.created = created
  s.pinned = pinned
  s.activity = activity
  return s
}

/// A send card, which waits on the user to send or cancel a group message.
private func sendCard() -> Card {
  let json: JSON = [
    "id": 1, "session": "m1", "kind": "send", "tool": "send_group", "summary": "`Rebase.` to Flags", "input": [:],
    "questions": [], "since": 0, "deferred": false, "hookClosed": false,
    "send": ["group": "g1", "groupName": "Flags", "text": "Rebase.", "targets": [], "expires": 0],
  ]
  return try! JSONCoding.convert(json, to: Card.self)
}

/// A conversation listed with sbd's archive flag, as the app reads it.
private func listed(_ id: String, lastActivity: Int64, pinned: Bool? = nil, archived: Bool? = nil) -> SessionSummary {
  conversation(
    id, lastActivity: lastActivity, pinned: pinned,
    activity: ChatActivity(replies: 1, unread: 0, lastMessageAt: lastActivity, archived: archived))
}

private let quietSince: Int64 = 1_000_000

@Suite struct ConversationRules {
  @Test func theArchiveWaitIsThreeDays() {
    #expect(Conversations.archiveAfterMs == 3 * 24 * 3600 * 1000)
  }

  // MARK: isArchived

  @Test func anIdleReadConversationIsArchivedAtExactlyTheArchiveWait() {
    let s = conversation(lastActivity: quietSince)

    #expect(Conversations.isArchived(s, now: quietSince + Conversations.archiveAfterMs))
  }

  @Test func anIdleReadConversationIsNotArchivedOneMillisecondBefore() {
    let s = conversation(lastActivity: quietSince)

    #expect(!Conversations.isArchived(s, now: quietSince + Conversations.archiveAfterMs - 1))
  }

  @Test(arguments: [AttentionState.needsYou, .done, .canContinue, .waiting])
  func anIdleConversationIsArchivedWhateverItsQuietState(_ state: AttentionState) {
    let s = conversation(lastActivity: quietSince, state: state)

    #expect(Conversations.isArchived(s, now: quietSince + Conversations.archiveAfterMs))
  }

  @Test func aPinnedOldConversationIsNotArchived() {
    let s = conversation(lastActivity: quietSince, pinned: true)

    #expect(!Conversations.isArchived(s, now: quietSince + 10 * Conversations.archiveAfterMs))
  }

  @Test func anExplicitlyUnpinnedOldConversationIsArchived() {
    let s = conversation(lastActivity: quietSince, pinned: false)

    #expect(Conversations.isArchived(s, now: quietSince + Conversations.archiveAfterMs))
  }

  @Test func anUnreadOldConversationIsNotArchived() {
    let s = conversation(
      lastActivity: quietSince, activity: ChatActivity(replies: 2, unread: 1, lastMessageAt: quietSince))

    #expect(!Conversations.isArchived(s, now: quietSince + 10 * Conversations.archiveAfterMs))
  }

  @Test func anOldConversationWithASendCardIsNotArchived() {
    let s = conversation(lastActivity: quietSince, cards: [sendCard()])

    #expect(!Conversations.isArchived(s, now: quietSince + 10 * Conversations.archiveAfterMs))
  }

  @Test func anOldConversationWithAnOpenPromptIsNotArchived() {
    let s = conversation(lastActivity: quietSince, openPrompt: true)

    #expect(!Conversations.isArchived(s, now: quietSince + 10 * Conversations.archiveAfterMs))
  }

  @Test func aWorkingOldConversationIsNotArchived() {
    let s = conversation(lastActivity: quietSince, state: .working)

    #expect(!Conversations.isArchived(s, now: quietSince + 10 * Conversations.archiveAfterMs))
  }

  @Test func withoutActivityAConversationIsNeverArchived() {
    let s = conversation(lastActivity: quietSince, activity: nil)

    #expect(!Conversations.isArchived(s, now: quietSince + 10 * Conversations.archiveAfterMs))
  }

  @Test func aLastActivityOfZeroFallsBackToCreatedAtTheBoundary() {
    let s = conversation(lastActivity: 0, created: quietSince)

    #expect(Conversations.isArchived(s, now: quietSince + Conversations.archiveAfterMs))
  }

  @Test func aLastActivityOfZeroFallsBackToCreatedOneMillisecondBefore() {
    let s = conversation(lastActivity: 0, created: quietSince)

    #expect(!Conversations.isArchived(s, now: quietSince + Conversations.archiveAfterMs - 1))
  }

  /// The archive reads `ChatMark`, so every mark but idle keeps a conversation out.
  @Test func anArchivedConversationsMarkIsIdle() {
    let shapes = [
      conversation(lastActivity: quietSince),
      conversation(lastActivity: quietSince, state: .working),
      conversation(lastActivity: quietSince, activity: ChatActivity(replies: 2, unread: 1)),
      conversation(lastActivity: quietSince, cards: [sendCard()]),
      conversation(lastActivity: quietSince, openPrompt: true),
    ]
    #expect(Conversations.isArchived(shapes[0], now: quietSince + 10 * Conversations.archiveAfterMs))

    for s in shapes where Conversations.isArchived(s, now: quietSince + 10 * Conversations.archiveAfterMs) {
      guard case .idle = ChatMark(s) else {
        Issue.record("archived with mark \(ChatMark(s))")
        continue
      }
    }
  }

  // MARK: sidebar

  @Test func theSidebarPutsPinnedConversationsFirstNewestFirst() {
    let list = [
      listed("a", lastActivity: 10), listed("p1", lastActivity: 5, pinned: true), listed("b", lastActivity: 30),
      listed("p2", lastActivity: 20, pinned: true),
    ]

    let sidebar = Conversations.sidebar(list)

    #expect(sidebar.pinned.map(\.id) == ["p2", "p1"])
    #expect(sidebar.active.map(\.id) == ["b", "a"])
    #expect(sidebar.archived.isEmpty)
  }

  @Test func theSidebarMovesAnArchivedConversationOutOfActive() {
    let list = [
      listed("a", lastActivity: 30), listed("old1", lastActivity: 2, archived: true),
      listed("old2", lastActivity: 4, archived: true), listed("b", lastActivity: 10, archived: false),
    ]

    let sidebar = Conversations.sidebar(list)

    #expect(sidebar.active.map(\.id) == ["a", "b"])
    #expect(sidebar.archived.map(\.id) == ["old2", "old1"])
  }

  @Test func theSidebarBreaksATieInLastActivityByCreated() {
    var first = listed("first", lastActivity: 10)
    first.created = 1
    var second = listed("second", lastActivity: 10)
    second.created = 2

    #expect(Conversations.sidebar([first, second]).active.map(\.id) == ["second", "first"])
  }

  @Test func aPinnedConversationNeverShowsUnderArchive() {
    let sidebar = Conversations.sidebar([listed("p", lastActivity: 1, pinned: true, archived: true)])

    #expect(sidebar.pinned.map(\.id) == ["p"])
    #expect(sidebar.archived.isEmpty)
  }

  @Test func aConversationWithoutActivityIsActive() {
    let sidebar = Conversations.sidebar([conversation("m", lastActivity: 1, activity: nil)])

    #expect(sidebar.active.map(\.id) == ["m"])
  }

  @Test func theSidebarKeepsEveryConversationOnce() {
    let list = [
      listed("a", lastActivity: 30), listed("p", lastActivity: 5, pinned: true),
      listed("z", lastActivity: 2, archived: true),
    ]

    let sidebar = Conversations.sidebar(list)

    #expect((sidebar.pinned + sidebar.active + sidebar.archived).map(\.id).sorted() == ["a", "p", "z"])
  }

  // MARK: Pinning is not activity

  @Test(arguments: ["pinned", "unpinned"])
  func aPinEventChangesNoFact(_ kind: String) {
    let events = [
      event("created", 1), event(ChatActivity.readEvent, 2, ["replies": 0]),
      event("UserPromptSubmit", 1000, ["prompt": "hello"]),
      event("Stop", 2000, ["last_assistant_message": "Done: hello"]),
    ]

    let after = facts(events + [event(kind, 9_000_000)])

    #expect(after == facts(events))
  }
}
