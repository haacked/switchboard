import SwiftUI
import SwitchboardCore

final class FollowupViewState: ObservableObject {
  @Published var confirmingRemove = false
}

/// A follow-up that hasn't started: its prompt, where it came from, and the
/// button that makes its worktree and starts claude.
struct FollowupView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let followup: Followup
  @StateObject private var ui = FollowupViewState()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(session.name).font(.title3.bold()).textSelection(.enabled)
            StateBadge(state: session.state)
          }
          Text(session.reason).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Start") { model.startFollowup(session.id) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: [.command])
          .help("Make the worktree and start claude with this prompt")
        Button(session.state == .done ? "Not Done" : "Done") { model.setDone(session.id, session.state != .done) }
        Button(role: .destructive) {
          ui.confirmingRemove = true
        } label: {
          Image(systemName: "trash")
        }
        .help("Remove the follow-up")
      }
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        detail("Repository", followup.repository ?? "none")
        if let branch = followup.sourceBranch { detail("Came up on", branch) }
        if let branch = session.branch { detail("Branch", branch) }
        if let pending = followup.trigger.pending { detail("Trigger", pending) }
        if let link = followup.link {
          GridRow {
            Text("Link").foregroundStyle(.secondary)
            if let url = URL(string: link) { Link(link, destination: url).lineLimit(1) } else { Text(link) }
          }
        }
        if let parent = session.parent {
          GridRow {
            Text("Parent").foregroundStyle(.secondary)
            Button(model.board.first { $0.id == parent }?.name ?? parent) { model.selection = parent }
              .buttonStyle(.link)
          }
        }
        if let created = session.created { detail("Added", ago(created) + " ago") }
      }
      .font(.callout)
      Divider()
      ScrollView {
        Text(followup.prompt)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .confirmationDialog("Remove \(session.name)?", isPresented: $ui.confirmingRemove) {
      Button("Remove Follow-up", role: .destructive) { model.removeFollowup(session.id) }
    } message: {
      Text("An import of Followups.md won't add it again.")
    }
  }

  private func detail(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
    }
  }
}

extension BoardModel {
  func expanded(_ state: AttentionState) -> Binding<Bool> {
    Binding(
      get: { !self.collapsed.contains(state) },
      set: { if $0 { self.collapsed.remove(state) } else { self.collapsed.insert(state) } })
  }

  func startFollowup(_ id: String) { perform("followup-start", ["session": .string(id)]) }

  func removeFollowup(_ id: String) {
    if selection == id { selection = nil }
    perform("followup-rm", ["session": .string(id)])
  }
}
