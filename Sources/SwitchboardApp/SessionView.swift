import SwiftUI
import SwitchboardCore

/// The session view's own state. The Command Line Tools have no SwiftUI
/// macro plugin, and `@State` is a macro in this SDK, so the views keep their
/// state in an ObservableObject.
final class SessionViewState: ObservableObject {
  @Published var terminals: Terminals?
  @Published var terminalsError: String?
  @Published var confirmingRemove = false
  @Published var deleteWorktree = false
  @Published var deleteBranch = false
}

/// One session: its state and actions, the Claude terminal and the shell side
/// by side, and a field that sends Claude a message.
struct SessionView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @StateObject private var ui = SessionViewState()

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if !session.cards.isEmpty {
        // A card with several questions would otherwise squeeze out the terminals.
        ScrollView {
          VStack(spacing: 8) {
            ForEach(session.cards) { CardView(card: $0, draft: model.draft(for: $0)) }
          }
          .padding(8)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        Divider()
      }
      if let terminals = ui.terminals {
        HSplitView {
          VStack(spacing: 0) {
            paneLabel("Claude")
            SessionTerminal(terminals: terminals, pane: .claude)
          }
          .frame(minWidth: 480, idealWidth: 760)
          VStack(spacing: 0) {
            paneLabel("Shell")
            SessionTerminal(terminals: terminals, pane: .shell)
          }
          .frame(minWidth: 240, idealWidth: 360)
        }
      } else if let error = ui.terminalsError {
        Text("Can't open the terminals: \(error)")
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView("Opening terminals…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      MessageField(session: session.id, shortcut: KeyboardShortcut(.return, modifiers: [.command]))
        .padding(8)
    }
    .task(id: session.id) {
      let id = session.id
      let model = model
      // Opening a session resumes a stopped claude. The selection has to rest
      // first, so moving through the sidebar resumes nothing on the way.
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled { return }
      model.open(id)
      // The terminals call can fail while sbd restarts, so it retries for 10 s.
      for _ in 0..<10 {
        switch await Task.detached(operation: { model.terminals(id) }).value {
        case .success(let terminals):
          ui.terminals = terminals
          return
        case .failure(let error):
          ui.terminalsError = "\(error)"
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if Task.isCancelled { return }
      }
    }
    .sheet(isPresented: $ui.confirmingRemove) { removeSheet }
  }

  /// A confirmation dialog can't hold toggles, so the options are in a sheet.
  private var removeSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Remove \(session.name)?").font(.headline)
      Text("This stops claude and closes both terminals. The conversation's transcript stays.")
      if session.repo != nil {
        Toggle(isOn: $ui.deleteWorktree) {
          Text("Delete the worktree \(session.cwd)")
        }
        .help("Refuses when the worktree has uncommitted files, or commits that are on no remote branch unless the PR is merged.")
        if let branch = session.branch {
          Toggle(isOn: $ui.deleteBranch) {
            Text("Delete the local branch \(branch)")
          }
          .padding(.leading, 20)
          .disabled(!ui.deleteWorktree)
          .help("Refuses unless the session's PR is merged and the branch has no commit after it.")
        }
        Text("A refusal removes nothing and shows the reason.").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("The folder stays.")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { ui.confirmingRemove = false }
          .keyboardShortcut(.cancelAction)
        Button("Remove Session", role: .destructive) {
          ui.confirmingRemove = false
          if ui.deleteWorktree {
            model.delete(session.id, branch: ui.deleteBranch && session.branch != nil)
          } else {
            model.remove(session.id)
          }
        }
      }
    }
    .padding(20)
    .frame(width: 460)
    .onDisappear {
      ui.deleteWorktree = false
      ui.deleteBranch = false
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(session.name).font(.title3.bold())
          StateBadge(state: session.state)
          Text(session.live ? "claude running" : "claude stopped")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(session.reason).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        if let pr = session.pr, let url = pr.link {
          Link(pr.line, destination: url).font(.caption).help("\(pr.repo): \(pr.title)")
        }
        Text([session.branch, session.cwd].compactMap { $0 }.joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Spacer()
      HStack {
        if session.live {
          Button("Stop") { model.stop(session.id) }
            .help("Stop claude now. It resumes when you send a message or open the session again.")
        } else {
          Button("Resume") { model.resume(session.id) }
        }
        Button(session.markedDone ? "Not Done" : "Done") { model.setDone(session.id, !session.markedDone) }
        Button(role: .destructive) {
          ui.confirmingRemove = true
        } label: {
          Image(systemName: "trash")
        }
        .help("Remove the session")
      }
    }
    .padding(12)
  }

  private func paneLabel(_ text: String) -> some View {
    Text(text)
      .font(.caption.bold())
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.bar)
  }
}
