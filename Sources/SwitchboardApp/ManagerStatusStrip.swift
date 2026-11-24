import SwiftUI
import SwitchboardCore

/// A Manager conversation's row under its header: links to the Inbox and the Board with their counts, and a
/// menu of the sessions that the conversation started and that changed since the user last wrote to it. A second
/// row suggests ending the conversation when sbd sends an end hint.
struct ManagerStatusStrip: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @State private var ending: ConversationRemovalText?

  var body: some View {
    let status = model.managerStatus(for: session)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Button("Needs you \(status.needsYou)") { model.show(.inbox) }
          .help("Show the Inbox")
        Button("Ready to merge \(status.readyToMerge)") { model.show(.board) }
          .help("Show the Board")
        Button("Working \(status.working)") { model.show(.board) }
          .help("Show the Board")
        if let changed = status.changed, !changed.isEmpty {
          Menu("\(changed.count) of your sessions changed") {
            ForEach(changed) { child in
              Button("\(child.name): \(child.state.title)") { model.selection = child.id }
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("The sessions that this conversation started and that changed since your last message")
        }
        Spacer()
      }
      if let hint = session.endHint { EndConversationHint(session: session, hint: hint, ending: $ending) }
    }
    .endConversationDialog($ending, session: session)
    .buttonStyle(.borderless)
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
    // `changed` reads the conversation's log. The task's id leaves out lastActivity, which every tool call changes.
    // The log reloads only when the reply or the state changes.
    .task(id: "\(session.lastReply?.count ?? 0)/\(session.state)/\(session.since)") { model.loadChatLog(session.id) }
  }
}
