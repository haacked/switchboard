import SwiftUI
import SwitchboardCore

/// A group's chat: its last messages and a field that sends it one. The
/// terminals are behind a toggle.
struct ChatView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    VStack(spacing: 0) {
      ChatHeader(session: session)
      Divider()
      if model.showingTerminal {
        SessionView(session: session)
      } else {
        ChatMessages(log: model.chatLogs[session.id])
        Divider()
        // The Inbox leaves out a chat's cards, such as a group message that waits for the user, so they show here.
        CardList(cards: session.cards)
        let proposals = session.chat.map { g in model.planProposals.filter { $0.group == g } } ?? []
        if !proposals.isEmpty { PlanProposalList(proposals: proposals) }
        MessageField(
          session: session.id, draft: model.messageDraft(for: session),
          shortcut: KeyboardShortcut(.return, modifiers: [.command])
        )
        .padding(8)
      }
    }
    // A tool call changes lastActivity, so the log reloads only when the reply or the state changes.
    .task(id: "\(session.lastReply?.count ?? 0)/\(session.state)/\(session.since)") { model.loadChatLog(session.id) }
  }
}

private struct ChatHeader: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    HStack(spacing: 8) {
      Text(session.name).fontWeight(.medium)
      StateBadge(state: session.state)
      Spacer()
      Toggle("Terminal", isOn: $model.showingTerminal)
        .toggleStyle(.button)
        .help("Show the chat's Claude terminal and shell in place of its messages")
    }
    .padding(10)
  }
}

/// The chat's messages, or a spinner while `log` is nil because the log has not loaded.
private struct ChatMessages: View {
  let log: [ChatMessage]?

  private var messages: [ChatMessage] { log ?? [] }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if log == nil {
            ProgressView().controlSize(.small)
          } else if messages.isEmpty {
            Text("No messages yet. Ask the chat about this group's sessions.").foregroundStyle(.secondary)
          }
          ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
            ChatBubble(message: message).id(index)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // The scroll follows the last message, because the count stops changing once the log is full.
      .onChange(of: messages.last, initial: true) { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
    }
  }
}

private struct ChatBubble: View {
  let message: ChatMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(message.role.label).font(.caption.bold()).foregroundStyle(.secondary)
      if message.role == .user {
        Text(message.text).textSelection(.enabled)
      } else {
        MarkdownView(text: message.text)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8).fill(message.role == .user ? Color.accentColor.opacity(0.08) : Color.clear))
  }
}
