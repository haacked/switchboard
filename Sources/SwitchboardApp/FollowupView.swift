import SwiftUI
import SwitchboardCore

/// See SessionViewState for why this isn't `@State`.
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
        StartButton(session: session)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: [.command])
        if followup.repository != nil { StartButton(session: session, inFolder: true) }
        Button(session.markedDone ? "Not Done" : "Done") { model.setDone(session.id, !session.markedDone) }
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
            // A follow-up made from a file plan links the file's path.
            if let url = link.hasPrefix("/") ? URL(fileURLWithPath: link) : URL(string: link) {
              Link(link, destination: url).lineLimit(1)
            } else {
              Text(link)
            }
          }
        }
        if let parent = session.parent {
          GridRow {
            Text("Parent").foregroundStyle(.secondary)
            if let p = model.board.first(where: { $0.id == parent }) {
              Button(p.name) { model.selection = parent }.buttonStyle(.link)
            } else {
              Text("\(parent) (removed)").foregroundStyle(.secondary)
            }
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
      Button("Remove Follow-up", role: .destructive) { model.remove(session.id) }
    } message: {
      Text("An import of Followups.md won't add it again.")
    }
  }

  private func detail(_ label: String, _ value: String) -> some View { DetailRow(label: label, value: value) }
}

/// A label and a one-line value in a detail Grid.
struct DetailRow: View {
  let label: String
  let value: String

  var body: some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
    }
  }
}

/// Starts the follow-up in its repository's checkout. A follow-up with no
/// repository asks for the folder to start in.
struct StartButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  /// Asks for the folder even when the follow-up has a repository, for a
  /// checkout that sbd can't find.
  var inFolder = false

  var body: some View {
    let starting = model.starting.contains(session.id)
    let asksForFolder = inFolder || session.followup?.repository == nil
    Button(starting ? "Starting…" : asksForFolder ? "Start in…" : "Start") {
      if !asksForFolder {
        model.startFollowup(session.id)
      } else if let path = chooseFolder(message: "Choose the checkout to start the follow-up in") {
        model.startFollowup(session.id, path: path)
      }
    }
    .disabled(starting)
    .help("Make the worktree and start claude with the follow-up's prompt")
  }
}
