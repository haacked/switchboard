import AppKit
import SwiftUI
import SwitchboardCore

/// The read state of group chats and Manager conversations.
extension BoardModel {
  /// The sidebar's Manager conversations: pinned, then active, then archived.
  var conversations: (pinned: [SessionSummary], active: [SessionSummary], archived: [SessionSummary]) {
    Conversations.sidebar(managers)
  }

  /// The conversations in the sidebar's order. The archived ones count only while the archive shows.
  var conversationOrder: [SessionSummary] {
    let c = conversations
    return c.pinned + c.active + (showingArchive ? c.archived : [])
  }

  func setPinned(_ id: String, _ pinned: Bool) {
    perform("manager-pin", ["session": .string(id), "pinned": .bool(pinned)])
  }

  /// What the group's Chat button shows.
  func chatMark(of group: String) -> ChatMark { ChatMark(chat(of: group)) }

  /// The reply count to mark read for a chat or a conversation whose pane
  /// shows, or nil when nothing should be marked: the app is not active, the
  /// session is a work session, or no reply is unread.
  static func readThrough(_ s: SessionSummary, appActive: Bool) -> Int? {
    guard appActive, s.kind.showsAsChat, let activity = s.activity, activity.unread > 0 else { return nil }
    return activity.replies
  }

  /// Marks the selected chat's or conversation's replies read, up to the
  /// replies that this refresh listed. The detail pane shows the chat for
  /// that selection. A reply that arrives later stays unread.
  func markSelectedChatRead() {
    guard let s = selected, let replies = BoardModel.readThrough(s, appActive: isAppActive()) else { return }
    if let last = lastChatRead, last.session == s.id, last.replies == replies { return }
    lastChatRead = (s.id, replies)
    perform(
      ChatActivity.readEvent, ["session": .string(s.id), "replies": .number(Double(replies))],
      failed: { NSLog("chat-read \(s.id): \($0)") })
  }
}

/// How the toolbar star looks: orange while a conversation waits on the
/// user, blue while one has unread replies, and an outline otherwise.
enum ManagerStar: Equatable {
  case needsMe, unread, outline

  init(_ managers: [SessionSummary]) {
    let marks = managers.map(ChatMark.init)
    if marks.contains(where: { $0.needsMeReason != nil }) {
      self = .needsMe
    } else if marks.contains(where: { if case .unread = $0 { true } else { false } }) {
      self = .unread
    } else {
      self = .outline
    }
  }
}

extension ManagerStar {
  var color: Color {
    switch self {
    case .needsMe: AttentionState.needsYou.color
    case .unread: .accentColor
    case .outline: .primary
    }
  }

  var value: String {
    switch self {
    case .needsMe: AttentionState.needsYou.title
    case .unread: "Unread replies"
    case .outline: ""
    }
  }
}
