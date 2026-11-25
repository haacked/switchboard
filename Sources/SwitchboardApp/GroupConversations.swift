import SwiftUI
import SwitchboardCore

/// Where a group chat lists its conversations: a column on the leading side of the chat's view when the view has
/// room for it beside the terminals, else a Conversations menu in the chat's header. The column takes its room
/// before the side panel does.
enum GroupConversationsColumn {
  static let width: CGFloat = 200

  /// True when `width` holds the column beside content that needs `beside` points.
  static func fits(width: CGFloat, beside: CGFloat) -> Bool { width >= beside + Self.width }
}

/// A group chat's conversations, listed as the sidebar lists the Manager conversations. A click on a row selects
/// that conversation.
struct GroupConversationsColumnView: View {
  @EnvironmentObject var model: BoardModel
  let group: String

  var body: some View {
    List(selection: selection) {
      ConversationListSection(
        title: "Conversations", sessions: model.chats(of: group), activeAccount: model.activeAccountFolder,
        newHelp: "Start another conversation in this group's chat", newLabel: "New conversation in this group",
        removableSelection: nil, archive: archive
      ) {
        model.newChat(group)
      }
    }
    .listStyle(.sidebar)
    .frame(width: GroupConversationsColumn.width)
  }

  /// A click selects one conversation. The column has no multi-selection, and a click on empty space keeps the
  /// selection, because an empty selection would close this chat's view.
  private var selection: Binding<Set<String>> {
    Binding(
      get: { Set(model.selection.map { [$0] } ?? []) },
      set: { ids in
        if ids.count == 1, let id = ids.first { model.selection = id }
      })
  }

  private var archive: Binding<Bool> {
    Binding(
      get: { model.shownChatArchives.contains(group) },
      set: { open in
        if open {
          model.shownChatArchives.insert(group)
        } else {
          model.shownChatArchives.remove(group)
        }
      })
  }
}

/// The chat header's menu of the group's conversations, which shows in place of the column while the column does
/// not fit.
struct GroupConversationsMenu: View {
  @EnvironmentObject var model: BoardModel
  let group: String
  /// The conversation that the view shows.
  let current: String

  var body: some View {
    Menu("Conversations") {
      ForEach(model.chats(of: group)) { s in
        Button {
          model.selection = s.id
        } label: {
          if s.id == current { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
        }
      }
      Divider()
      Button("New Conversation") { model.newChat(group) }
    }
    .fixedSize()
    .help("Switch to another conversation of this group's chat, or start one")
  }
}

/// The Rename sheet of a conversation, which a row's context menu opens. It closes when the session goes away.
struct RenameSheet: View {
  @EnvironmentObject var model: BoardModel
  let id: String
  let close: () -> Void
  @State private var name = ""

  var body: some View {
    if let session = model.summary(id) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Rename \(session.name)").font(.headline)
        TextField("Name", text: $name)
          .frame(width: 320)
          .onSubmit(save)
        HStack {
          Spacer()
          Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
          Button("Rename", action: save)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(20)
      .onAppear { name = session.name }
    } else {
      Color.clear.frame(width: 1, height: 1).onAppear(perform: close)
    }
  }

  private func save() {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    model.rename(id, to: name)
    close()
  }
}
