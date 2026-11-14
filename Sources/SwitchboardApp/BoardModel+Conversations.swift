import AppKit
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
    // `selected` filters every session, so the cheap checks run first.
    guard selection != nil, isAppActive(), let s = selected, let replies = BoardModel.readThrough(s, appActive: true)
    else { return }
    if let last = lastChatRead, last.session == s.id, last.replies == replies { return }
    lastChatRead = (s.id, replies)
    perform(
      ChatActivity.readEvent, ["session": .string(s.id), "replies": .number(Double(replies))],
      failed: { NSLog("chat-read \(s.id): \($0)") })
  }
}
