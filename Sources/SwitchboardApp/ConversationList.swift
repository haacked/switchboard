import SwiftUI
import SwitchboardCore

/// The sidebar's Manager conversations: pinned first, then the others newest
/// activity first, then a closed Archive group.
struct ConversationsSection: View {
  @EnvironmentObject var model: BoardModel
  let activeAccount: String

  var body: some View {
    if !model.managers.isEmpty {
      let c = model.conversations
      Section {
        ForEach(c.pinned + c.active) { row($0) }
        if !c.archived.isEmpty {
          DisclosureGroup(isExpanded: $model.showingArchive) {
            ForEach(c.archived) { row($0) }
          } label: {
            Text("Archive (\(c.archived.count))").foregroundStyle(.secondary)
          }
          .help("Conversations idle for \(Conversations.archiveAfterMs / 86_400_000) days that need nothing")
        }
      } header: {
        HStack {
          Text("Conversations")
          Spacer()
          Button {
            model.openManager(new: true)
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .help("Start a Manager conversation (⌥⌘N)")
          .accessibilityLabel("New Manager conversation")
        }
      }
    }
  }

  private func row(_ s: SessionSummary) -> some View {
    ConversationRow(session: s, activeAccount: activeAccount, hoverCard: model.hoverCard).tag(s.id)
      .contextMenu {
        Button(s.pinned == true ? "Unpin" : "Pin") { model.setPinned(s.id, s.pinned != true) }
      }
  }
}

/// A Manager conversation's sidebar row: its title, the time of its last
/// message, a preview of Claude's last reply, its mark, and a pin.
struct ConversationRow: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let activeAccount: String
  var hoverCard: HoverCard? = nil

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
          Text(session.name).fontWeight(unread ? .semibold : .medium).lineLimit(1)
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
          .accessibilityLabel(pinned ? "Unpin \(session.name)" : "Pin \(session.name)")
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
