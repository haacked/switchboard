import SwiftUI
import SwitchboardCore

/// The Chat button in a group lane's label. It shows the state of the
/// group's chat, and its help names the time of the last message.
struct GroupChatButton: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary

  var body: some View {
    let chat = model.chat(of: group.id)
    let mark = ChatMark(chat)
    let text = ChatButtonText(mark, lastMessageAt: chat?.activity?.lastMessageAt)
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
  var label: String
  var help: String
  var value: String

  init(_ mark: ChatMark, lastMessageAt: Int64?, now: Int64 = nowMs()) {
    guard mark != .none else {
      self.init(label: "Start chat", help: "Start a chat that manages this group's sessions", value: "No chat")
      return
    }
    let last = lastMessageAt.map { " Last message \(ago($0, now: now)) ago." } ?? ""
    let value = ChatButtonText.value(mark)
    self.init(label: "Chat", help: "Open this group's chat. \(value).\(last)", value: value)
  }

  private init(label: String, help: String, value: String) {
    self.label = label
    self.help = help
    self.value = value
  }

  /// What the mark says, for VoiceOver and the help text.
  static func value(_ mark: ChatMark) -> String {
    switch mark {
    case .none: "No chat"
    case .needsMe(let reason): "Needs you: \(reason)"
    case .unread(let n, let working):
      (n == 1 ? "1 unread reply" : "\(n) unread replies") + (working ? ", working" : "")
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
        .font(.caption2.bold())
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(Capsule().fill(AttentionState.needsYou.color.opacity(0.18)))
        .foregroundStyle(AttentionState.needsYou.color)
    case .unread(let n, let working):
      if working { progress }
      Text("\(n)")
        .font(.caption2.bold()).monospacedDigit()
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(Color.accentColor))
        .foregroundStyle(.white)
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
