import SwiftUI
import SwitchboardCore

/// A session's actions as window toolbar items, which show while its session view does. `SessionView` observes the
/// model and builds these items again on each change, so the buttons read the model without observing it themselves.
struct SessionToolbarItems: ToolbarContent {
  let model: BoardModel
  let session: SessionSummary
  let sidePanelFits: Bool
  @Binding var showsSidePanel: Bool
  let requestRemoval: () -> Void

  var body: some ToolbarContent {
    let actions = SessionActions.list(for: session)
    ToolbarItemGroup {
      ForEach(actions.filter(\.changesStatus), id: \.self) { button($0) }
    }
    ToolbarItemGroup {
      ForEach(actions.filter { !$0.changesStatus }, id: \.self) { button($0) }
    }
  }

  @ViewBuilder private func button(_ action: SessionAction) -> some View {
    switch action {
    case .run(.resumePaused):
      Button("Resume", systemImage: "play.circle") { model.resume(session.id) }
        .help(PauseBanner.resumeHelp)
    case .run(.stop):
      Button("Stop Claude", systemImage: "stop.circle") { model.stop(session.id) }
        .help(AppShortcut.stopClaude.help(BoardModel.stopHelp))
    case .run(.startNow):
      Button("Start Now", systemImage: "play.circle") { model.startNow(session.id) }
        .disabled(model.startingNow.contains(session.id))
        .help(BoardModel.startNowHelp)
    case .run(.restart):
      Button("Resume Claude", systemImage: "arrow.clockwise.circle") { model.resume(session.id) }
        .help(AppShortcut.resumeClaude.help("Restart claude in this session. It continues the conversation."))
    case .pause:
      PauseMenuItems(id: session.id, systemImage: "pause.circle")
        .help("Stop claude until you resume it, or until a time you pick.")
    case .done(let marked):
      Button(
        marked ? "Mark Not Done" : "Mark Done",
        systemImage: marked ? "arrow.uturn.backward.circle" : "checkmark.circle"
      ) { model.setDone(session.id, !marked) }
      .help(
        AppShortcut.markDone.help(
          marked
            ? "Mark the session not done. It returns to its own group on the board, and to the Inbox if it needs you or claude can continue."
            : "Mark the session done. It leaves the Inbox and moves to Done on the board."))
    case .sidePanel:
      Toggle(isOn: $showsSidePanel) {
        Label("Side Panel", systemImage: "sidebar.right")
      }
      .accessibilityLabel(showsSidePanel ? "Hide Waits and Notes" : "Show Waits and Notes")
      .disabled(!sidePanelFits)
      .help(
        "Show or hide the session's waits, schedules, and notes beside the terminals. The panel hides itself, and this button is off, while the view is too narrow for it."
      )
    case .cleanUp:
      Button("Clean Up…", systemImage: "sparkles") { model.confirmingCleanup = session.id }
        .disabled(model.cleaningUp.contains(session.id))
        .help("Delete the worktree and the local branch of the merged PR. The session stays in Done.")
    case .delete:
      Button("Remove Session…", systemImage: "trash", role: .destructive, action: requestRemoval)
        .help("Remove the session. Asks you to confirm first.")
    }
  }
}

extension SessionAction {
  /// Run, Pause, and Done change whether claude runs or whether the session counts as done. The toolbar groups them.
  fileprivate var changesStatus: Bool {
    switch self {
    case .run, .pause, .done: true
    case .sidePanel, .cleanUp, .delete: false
    }
  }
}
