import SwiftUI
import SwitchboardCore

/// The Chat button in a group lane's label, which opens the group's most recent conversation. Its mark sums up
/// every conversation of the group, and its help names the time of the last message.
struct GroupChatButton: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary

  var body: some View {
    let chats = model.chats(of: group.id)
    let mark = ChatMark(chats: chats)
    let text = ChatButtonText(mark, lastMessageAt: ChatMark.lastMessageAt(chats))
    Button {
      model.openChat(group.id)
    } label: {
      HStack(spacing: 3) {
        Text(text.label)
        ChatMarkView(mark: mark)
      }
    }
    .buttonStyle(.link).font(.caption)
    .help(text.help)
    .accessibilityLabel(text.label)
    .accessibilityValue(text.value)
    .accessibilityIdentifier("board-chat-\(group.id)")
  }
}

/// The words of a group's Chat button for each `ChatMark`.
struct ChatButtonText: Equatable {
  let label: String
  let help: String
  let value: String

  init(_ mark: ChatMark, lastMessageAt: Int64?, now: Int64 = nowMs()) {
    value = ChatButtonText.value(mark)
    if mark == .none {
      label = "Start chat"
      help = "Start a chat that manages this group's sessions"
    } else {
      label = "Chat"
      help = "Open this group's chat. \(value).\(lastMessageAt.map { " Last message \(ago($0, now: now)) ago." } ?? "")"
    }
  }

  /// What the mark says, for VoiceOver and the help text.
  static func value(_ mark: ChatMark) -> String {
    switch mark {
    case .none: "No chat"
    case .needsMe(let reason): "Needs you: \(reason)"
    case .unread(let n, let working): ChatActivity.unreadText(n) + (working ? ", working" : "")
    case .working: "Working"
    case .idle: "No unread replies"
    }
  }
}

/// The small mark beside a chat's name: the Needs you capsule, the unread
/// count, a progress mark during a turn, or a dot for a chat that exists.
struct ChatMarkView: View {
  let mark: ChatMark

  var body: some View {
    switch mark {
    case .none:
      EmptyView()
    case .needsMe:
      Image(systemName: "exclamationmark")
        .pill(AttentionState.needsYou.color)
    case .unread(let n, let working):
      if working { progress }
      Text("\(n)").monospacedDigit()
        .pill(.accentColor, filled: true)
    case .working:
      progress
    case .idle:
      Circle().fill(.secondary).frame(width: 5, height: 5)
    }
  }

  private var progress: some View {
    ProgressView().controlSize(.mini)
  }
}
