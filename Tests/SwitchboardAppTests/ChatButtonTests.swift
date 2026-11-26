import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The label, help text, and accessibility value of a group lane's Chat button, which one function builds from
/// the chat's `ChatMark`.
@Suite struct ChatButtonLabels {
  static let now: Int64 = 1_800_000_000_000

  func text(_ mark: ChatMark) -> ChatButtonText {
    var last: Int64?
    if case .idle(let t) = mark { last = t }
    return ChatButtonText(mark, lastMessageAt: last, now: Self.now)
  }

  @Test func withoutAChatTheButtonOffersToStartOne() {
    #expect(text(.none).label == "Start chat")
  }

  @Test(arguments: [
    ChatMark.idle(lastMessageAt: now - 5 * 60_000), .idle(lastMessageAt: nil), .unread(3, working: false),
    .unread(2, working: true), .working, .needsMe("approve `touch x`"),
  ])
  func aChatsButtonReadsChat(_ mark: ChatMark) {
    #expect(text(mark).label == "Chat")
  }

  @Test func anIdleChatsHelpNamesTheLastMessageTime() {
    let help = text(.idle(lastMessageAt: Self.now - 5 * 60_000)).help

    #expect(help.contains("Open this group's chat"), "\(help)")
    #expect(help.contains("Last message 5m ago"), "\(help)")
  }

  @Test func aChatWithNoMessageNamesNoLastMessage() {
    let help = text(.idle(lastMessageAt: nil)).help

    #expect(help.contains("Open this group's chat"), "\(help)")
    #expect(!help.contains("Last message"), "\(help)")
  }

  @Test func unreadRepliesAreInTheAccessibilityValue() {
    #expect(text(.unread(3, working: false)).value.contains("3 unread"))
  }

  @Test func needsMeNamesTheReasonInTheHelp() {
    let help = text(.needsMe("confirm `Rebase.` to Flags")).help

    #expect(help.contains("confirm `Rebase.` to Flags"), "\(help)")
  }

  @Test func workingIsInTheAccessibilityValue() {
    #expect(text(.working).value.contains("Working"))
  }

  @Test func unreadWhileWorkingNamesBoth() {
    let value = text(.unread(2, working: true)).value

    #expect(value.contains("2 unread"), "\(value)")
    #expect(value.localizedCaseInsensitiveContains("working"), "\(value)")
  }

  @Test func unreadWhileIdleDoesNotSayWorking() {
    let value = text(.unread(2, working: false)).value

    #expect(!value.localizedCaseInsensitiveContains("working"), "\(value)")
  }

  /// Each state sets an accessibility value, so VoiceOver tells the states apart.
  @Test(arguments: [
    ChatMark.none, .idle(lastMessageAt: now - 5 * 60_000), .unread(3, working: false), .unread(2, working: true),
    .working, .needsMe("approve `touch x`"),
  ])
  func everyStateSetsAnAccessibilityValue(_ mark: ChatMark) {
    #expect(!text(mark).value.isEmpty)
  }

  @Test func needsMeAndUnreadDiffer() {
    #expect(
      text(.needsMe("approve `touch x`")).value != text(.unread(1, working: false)).value)
  }
}

/// The mark of a group's Chat button on the Board, which sums up every conversation of the group (Decision 11):
/// needs-you wins, then the summed unread count, which says working when any conversation is working, then working,
/// then idle.
@MainActor
@Suite struct ChatButtonTests {
  func conversation(_ id: String, unread: Int = 0, state: AttentionState = .needsYou, lastActivity: Int64 = 10)
    -> SessionSummary
  {
    groupConversation(id, lastActivity: lastActivity, unread: unread, state: state)
  }

  @Test func aGroupWithNoConversationIsNone() {
    #expect(ChatMark(chats: []) == .none)
  }

  /// With one conversation, the button shows what that conversation's row shows.
  @Test func oneConversationsMarkIsItsOwnMark() throws {
    let shapes = [
      conversation("c"), conversation("c", unread: 2), conversation("c", state: .working),
      conversation("c", unread: 2, state: .working), try carded(conversation("c"), kind: .send),
      try carded(conversation("c", unread: 2), kind: .permission),
    ]
    for s in shapes {
      #expect(ChatMark(chats: [s]) == ChatMark(s), "\(ChatMark(s))")
    }
  }

  @Test func needsMeWinsOverUnreadAndWorking() throws {
    let waiting = try carded(conversation("c3", lastActivity: 5), kind: .permission)

    let mark = ChatMark(chats: [
      conversation("c1", unread: 3, lastActivity: 30), conversation("c2", state: .working, lastActivity: 20), waiting,
    ])

    #expect(mark == ChatMark(waiting))
  }

  @Test func unreadCountsAddUpAcrossConversations() {
    let mark = ChatMark(chats: [conversation("c1", unread: 2), conversation("c2", unread: 3)])

    #expect(mark == .unread(5, working: false))
  }

  @Test func unreadSaysWorkingWhenAnyConversationIsWorking() {
    let mark = ChatMark(chats: [conversation("c1", unread: 2), conversation("c2", state: .working)])

    #expect(mark == .unread(2, working: true))
  }

  @Test func workingWithNothingUnreadIsWorking() {
    let mark = ChatMark(chats: [conversation("c1"), conversation("c2", state: .working)])

    #expect(mark == .working)
  }

  @Test func conversationsWithNothingToShowAreIdle() {
    let mark = ChatMark(chats: [conversation("c1"), conversation("c2")])

    guard case .idle = mark else {
      Issue.record("\(mark)")
      return
    }
  }

  @Test func idleConversationsCarryTheNewestMessageTime() {
    let mark = ChatMark(chats: [
      conversation("c1", lastActivity: 20), conversation("c2", lastActivity: 30), conversation("c3", lastActivity: 10),
    ])

    #expect(mark == .idle(lastMessageAt: 30))
  }

  @Test func theBoardButtonReadsOnlyItsGroupsConversations() {
    let model = appliedModel([
      conversation("c1", unread: 1), conversation("c2", unread: 1),
      groupConversation("other", group: "g2", lastActivity: 10, unread: 4),
    ])

    #expect(ChatMark(chats: model.chats(of: "g1")) == .unread(2, working: false))
  }
}
