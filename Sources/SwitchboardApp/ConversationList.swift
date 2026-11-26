import SwiftUI
import SwitchboardCore

/// The sidebar's Manager conversations and group chats. The header shows with no conversations, because its button
/// is the sidebar's way to start a Manager conversation.
struct ConversationsSection: View {
  @EnvironmentObject var model: BoardModel
  let activeAccount: String
  /// The number of multi-selected sessions that the row's Delete item deletes.
  let removableSelection: Int

  var body: some View {
    ConversationListSection(
      title: "Conversations", sessions: model.sidebarConversations, activeAccount: activeAccount,
      newHelp: AppShortcut.newConversation.help("Start a Manager conversation"), newLabel: "New Manager conversation",
      removableSelection: removableSelection, archive: $model.showingArchive, rowTitle: model.conversationTitle
    ) {
      model.openManager(new: true)
    }
  }
}

/// A list of conversations: pinned first, then the others newest activity first, then a closed Archive group. Its
/// header holds the title and a button that starts a conversation.
struct ConversationListSection: View {
  @EnvironmentObject var model: BoardModel
  let title: String
  let sessions: [SessionSummary]
  let activeAccount: String
  /// The help text of the header's new-conversation button.
  let newHelp: String
  /// The accessibility label of the header's new-conversation button.
  let newLabel: String
  /// The number of multi-selected sessions that the row's Delete item deletes, or nil for a list outside the
  /// sidebar, whose rows are never in its multi-selection.
  let removableSelection: Int?
  /// Whether the Archive group is open.
  @Binding var archive: Bool
  /// The title of a conversation's row.
  var rowTitle: (SessionSummary) -> String = \.name
  let new: () -> Void

  var body: some View {
    let c = Conversations.sidebar(sessions)
    Section {
      ForEach(c.pinned + c.active) { row($0) }
      if !c.archived.isEmpty {
        DisclosureGroup(isExpanded: $archive) {
          ForEach(c.archived) { row($0) }
        } label: {
          CountedTitle(title: "Archive", count: c.archived.count).foregroundStyle(.secondary)
        }
        .help("Conversations idle for \(Conversations.archiveAfterMs / 86_400_000) days that need nothing")
      }
    } header: {
      HStack {
        Text(title)
        Spacer()
        Button(action: new) {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help(newHelp)
        .accessibilityLabel(newLabel)
      }
    }
  }

  private func row(_ s: SessionSummary) -> some View {
    ConversationRow(session: s, title: rowTitle(s), activeAccount: activeAccount, hoverCard: model.hoverCard)
      .clickAnchor(s.id)
      .tag(s.id)
      .contextMenu {
        SessionMenuItems(session: s, removableSelection: removableSelection) {
          Button(s.pinned == true ? "Unpin" : "Pin") { model.setPinned(s.id, s.pinned != true) }
        }
      }
  }
}

/// A conversation's row in the sidebar or in a group chat's column: its title, the time of its last
/// message, a preview of Claude's last reply, its mark, and a pin.
struct ConversationRow: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let title: String
  let activeAccount: String
  var hoverCard: HoverCard<String>? = nil

  var body: some View {
    let mark = ChatMark(session)
    let unread = (session.activity?.unread ?? 0) > 0
    let pinned = session.pinned == true
    HStack(alignment: .top, spacing: 6) {
      Circle()
        .fill(Color.accentColor)
        .frame(width: 8, height: 8)
        .opacity(unread ? 1 : 0)
        .padding(.top, 5)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(title).fontWeight(unread ? .semibold : .medium).lineLimit(1)
            .accessibilityValue(ChatButtonText.value(mark))
          Spacer(minLength: 4)
          if let shown = ConversationRow.trailingMark(mark) { ChatMarkView(mark: shown) }
          Text(ago(session.activity?.lastMessageAt ?? session.lastActivity))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
          Button {
            model.setPinned(session.id, !pinned)
          } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(pinned ? .primary : .tertiary)
          .help(pinned ? "Unpin this conversation" : "Pin this conversation to the top")
          .accessibilityLabel(pinned ? "Unpin \(title)" : "Pin \(title)")
        }
        if let preview = session.lastReply.flatMap(firstLine) {
          Text(verbatim: preview).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
      }
    }
    .padding(.vertical, 2)
    .hoverCard(session, activeAccount: activeAccount, card: hoverCard)
  }

  /// The mark beside the title. The dot shows unread replies, so an unread
  /// conversation shows only the progress mark of a running turn.
  static func trailingMark(_ mark: ChatMark) -> ChatMark? {
    switch mark {
    case .needsMe, .working: mark
    case .unread(_, let working): working ? .working : nil
    case .none, .idle: nil
    }
  }
}
