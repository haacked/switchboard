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
