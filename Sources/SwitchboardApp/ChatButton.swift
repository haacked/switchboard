import SwiftUI
import SwitchboardCore

/// The Chat button in a group lane's label.
struct GroupChatButton: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary

  var body: some View {
    Button("Chat") { model.openChat(group.id) }
      .buttonStyle(.link).font(.caption)
      .help(
        model.chat(of: group.id) == nil
          ? "Start a chat that manages this group's sessions" : "Open this group's chat")
  }
}
