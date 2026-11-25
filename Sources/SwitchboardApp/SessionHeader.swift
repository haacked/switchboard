import SwiftUI
import SwitchboardCore

/// The top of a session view: the session's name, state, links, and folder, and its actions.
struct SessionHeader: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @ObservedObject var ui: SessionViewState
  @Binding var showsSidePanel: Bool
  let requestRemoval: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(session.name).font(.title3.bold())
            .contextMenu { CopyLinkMenuItem(session: session) }
          StateBadge(state: session.state)
          Text(session.live ? "claude running" : "claude stopped")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let mode = session.permissionMode {
            Text("\(PermissionMode.title(mode)) mode")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        InlineText(plain: session.reason).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        if let pr = session.pr, let url = pr.link {
          HStack(spacing: 4) {
            Link(pr.line, destination: url).font(.caption).help("\(pr.repo): \(pr.title)")
            if let owners = pr.codeOwners { CodeOwnerShield(status: owners) }
            if let count = pr.commitCount {
              Text("\(count) \(count == 1 ? "commit" : "commits")").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        IssueBadge(session: session)
        CleanupNote(session: session)
        BranchSwitchNote(session: session)
        // The title row wraps the session's name at 1024 pt when the account sits in it.
        HStack(spacing: 8) {
          SessionAccountControl(session: session)
          if session.kind.runsInManagerFolder { MCPServerMenu(session: session) }
          if session.kind == .manager { ManagerHeaderControls(session: session) }
          if let repo = RepoLabels.label(for: session) {
            Text(repo).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
              .help("The repo this session works in")
          }
          Text([session.branch, session.cwd].compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
      Spacer()
      HStack {
        ForEach(SessionActions.list(for: session), id: \.self) { button($0) }
      }
    }
    .padding(12)
  }

  @ViewBuilder private func button(_ action: SessionAction) -> some View {
    switch action {
    case .run(.resumePaused):
      Button("Resume") { model.resume(session.id) }
        .help(PauseBanner.resumeHelp)
    case .run(.stop):
      Button("Stop") { model.stop(session.id) }
        .help(BoardModel.stopHelp)
    case .run(.startNow):
      Button("Start Now") { model.startNow(session.id) }
        .disabled(model.startingNow.contains(session.id))
        .help(BoardModel.startNowHelp)
    case .run(.restart):
      Button("Resume") { model.resume(session.id) }
        .help("Restart claude in this session. It continues the conversation.")
    case .pause:
      PauseMenuItems(id: session.id)
        .fixedSize()
        .help("Stop claude until you resume it, or until a time you pick.")
    case .done(let marked):
      Button(marked ? "Not Done" : "Done") { model.setDone(session.id, !marked) }
        .help(
          marked
            ? "Mark the session not done. It returns to its own group on the board, and to the Inbox if it needs you or claude can continue."
            : "Mark the session done. It leaves the Inbox and moves to Done on the board.")
    case .notes:
      NotesButton(session: session, always: true)
    case .sidePanel:
      Button {
        showsSidePanel.toggle()
      } label: {
        Image(systemName: "sidebar.right")
      }
      .accessibilityLabel(showsSidePanel ? "Hide Waits and Notes" : "Show Waits and Notes")
      .disabled(!ui.sidePanelFits)
      .help(
        "Show or hide the session's waits, schedules, and notes beside the terminals. The panel hides itself, and this button is off, while the view is too narrow for it."
      )
    case .cleanUp:
      Button("Clean Up…") { model.confirmingCleanup = session.id }
        .disabled(model.cleaningUp.contains(session.id))
        .help("Delete the worktree and the local branch of the merged PR. The session stays in Done.")
    case .delete:
      Button(role: .destructive, action: requestRemoval) {
        Image(systemName: "trash")
      }
      .help("Remove the session. Asks you to confirm first.")
    }
  }
}
