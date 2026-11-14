import SwiftUI
import SwitchboardCore

/// The sidebar's Manager conversations.
struct ConversationsSection: View {
  @EnvironmentObject var model: BoardModel
  let activeAccount: String

  var body: some View {
    if !model.managers.isEmpty {
      Section {
        ForEach(model.managers) { manager in
          SessionRow(session: manager, activeAccount: activeAccount, hoverCard: model.hoverCard).tag(manager.id)
        }
      } header: {
        HStack {
          Text("Manager")
          Spacer()
          Button {
            model.openManager(new: true)
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .help("Start a Manager conversation")
          .accessibilityLabel("New Manager conversation")
        }
      }
    }
  }
}
