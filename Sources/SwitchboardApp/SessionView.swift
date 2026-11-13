import SwiftUI
import SwitchboardCore

final class SessionViewState: ObservableObject {
  @Published var deleteWorktree = false
  @Published var deleteBranch = false
  @Published var removeOptions: RemoveOptions?
  /// The open to-dos when the user clicked remove. The remove confirmation shows while this is set.
  @Published var removal: TodoDeletion?
  /// Changes each time the shell pane attaches again, which makes SwiftUI create a new terminal.
  @Published var shellAttach = 0
  /// False while the view is too narrow to hold the side panel beside the terminals.
  @Published var sidePanelFits = true
}

/// One session: its state and actions, the Claude terminal and the shell side
/// by side, and a field that sends Claude a message.
struct SessionView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @StateObject private var ui = SessionViewState()
  @StateObject private var connection = TerminalConnection()
  @AppStorage("sessionSidePanel") private var showsSidePanel = true

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      CardList(cards: session.cards)
      GeometryReader { geometry in
        let fits = SidePanel.fits(width: geometry.size.width, beside: SessionView.terminalsMinWidth(session))
        HStack(spacing: 0) {
          terminalArea
          if showsSidePanel && fits {
            Divider()
            SidePanelView(session: session)
          }
        }
        .onChange(of: fits, initial: true) { if ui.sidePanelFits != fits { ui.sidePanelFits = fits } }
      }
      // A GeometryReader accepts any width. Without this, the layout above gives the terminals less than
      // their minimum widths, and the shell pane is laid out past the trailing edge.
      .frame(minWidth: SessionView.terminalsMinWidth(session))
      Divider()
      MessageField(
        session: session.id, draft: model.messageDraft(for: session),
        shortcut: KeyboardShortcut(.return, modifiers: [.command])
      )
      .padding(8)
    }
    // A request that no terminal took would otherwise take focus the next time this session shows.
    .onDisappear { [model, id = session.id] in model.releaseTerminalFocus(id) }
    .task(id: session.id) {
      // `open` refuses a session whose folder cleanup removed.
      if session.hasTerminals { await connection.connect(session.id, live: session.live) }
    }
    .sheet(item: $ui.removal) { removeSheet($0) }
  }

  /// The Claude terminal and the shell, or the text that stands in for them.
  @ViewBuilder private var terminalArea: some View {
    if !session.hasTerminals {
      Text("Cleanup removed this session's worktree, so it has no terminals.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let terminals = connection.terminals {
      HSplitView {
        VStack(spacing: 0) {
          paneLabel("Claude") {
            if session.shellClosed == true {
              Button("Open Shell") { model.setShellOpen(session.id, true) }
                .help("Start a shell in the session's folder beside the Claude terminal")
            }
          }
          TerminalPane(
            command: terminals.attachCommand(.claude), takesFocus: model.terminalFocus == session.id,
            onFocus: { [model, id = session.id] in model.releaseTerminalFocus(id) }, newlineOnShiftReturn: true,
            loadBlockSources: { [model, id = session.id] done in model.loadBlockSources(id, then: done) })
        }
        .frame(minWidth: SessionView.claudeMinWidth, idealWidth: 760)
        if session.shellClosed != true {
          VStack(spacing: 0) {
            paneLabel("Shell") {
              Button {
                model.setShellOpen(session.id, false)
              } label: {
                Image(systemName: "xmark")
              }
              .accessibilityLabel("Close Shell")
              .help("Close the shell. Typing exit or pressing Ctrl-D in it closes it too.")
            }
            TerminalPane(command: terminals.attachCommand(.shell), onExit: reattachShell)
          }
          .id(ui.shellAttach)
          .frame(minWidth: SessionView.shellMinWidth, idealWidth: 360)
        }
      }
    } else if let error = connection.error {
      Text("Can't open the terminals: \(error)")
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView("Opening terminals…").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  static let claudeMinWidth: CGFloat = 320
  static let shellMinWidth: CGFloat = 200

  /// The sum of the minimum widths of the terminal panes that `terminalArea` shows for `session`.
  static func terminalsMinWidth(_ session: SessionSummary) -> CGFloat {
    guard session.hasTerminals else { return 0 }
    return claudeMinWidth + (session.shellClosed == true ? 0 : shellMinWidth)
  }

  static let labelWidth: CGFloat = 44
  static let labelSpacing: CGFloat = 8
  static let labelPadding: CGFloat = 8

  /// The shell pane's tmux client exits when sbd ends the shell's tmux session. A shell that closed and
  /// opened again between two refreshes leaves `shellClosed` unchanged, so the pane attaches again
  /// while sbd still reports the shell open. The wait lets a closed shell reach the summary first.
  private func reattachShell() {
    let id = session.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [model, ui] in
      // The Inbox shows a session without selecting it, so this finds the session by its id.
      if let s = model.allBoard.first(where: { $0.id == id }), s.shellClosed != true { ui.shellAttach += 1 }
    }
  }

  /// A confirmation dialog can't hold toggles, so the options are in a sheet.
  private func removeSheet(_ todos: TodoDeletion) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Remove \(session.name)?").font(.headline)
      Text("This stops claude and closes both terminals. The conversation's transcript stays.")
      if let message = todos.message { InlineText(plain: message) }
      if session.repo != nil, let options = ui.removeOptions {
        Toggle(
          isOn: Binding(
            get: { ui.deleteWorktree },
            set: {
              ui.deleteWorktree = $0
              if !$0 { ui.deleteBranch = false }
            })
        ) {
          Text("Delete the worktree \(session.cwd)" + (options.worktreeNote.map { " (\($0))" } ?? ""))
        }
        .disabled(!options.worktreeEnabled)
        .help(
          "Refuses when the worktree has uncommitted files, or commits that are on no remote branch unless the PR is merged."
        )
        if let branch = session.branch {
          Toggle(isOn: $ui.deleteBranch) {
            Text("Delete the local branch \(branch)" + (options.branchNote.map { " (\($0))" } ?? ""))
          }
          .padding(.leading, 20)
          .disabled(!options.branchEnabled || !ui.deleteWorktree)
          .help("Refuses unless the session's PR is merged and the branch has no commit after it.")
        }
        Text(
          "A refusal removes nothing and shows the reason. If the branch fails its check again after the worktree is removed, the worktree and session are removed and the branch is kept."
        ).font(.caption).foregroundStyle(.secondary)
      } else {
        Text("The folder stays.")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { ui.removal = nil }
          .keyboardShortcut(.cancelAction)
        Button(todos.button("Remove Session"), role: .destructive) {
          ui.removal = nil
          if ui.deleteWorktree {
            model.delete(session.id, branch: ui.deleteBranch, resolve: todos.ids)
          } else {
            model.remove(session.id, resolve: todos.ids)
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
          }
        }
        IssueBadge(session: session)
        CleanupNote(session: session)
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
            .help("Restart claude in this session. It continues the conversation.")
        }
        Button(session.markedDone ? "Not Done" : "Done") { model.setDone(session.id, !session.markedDone) }
          .help(
            session.markedDone
              ? "Mark the session not done. It returns to its own group on the board, and to the Inbox if it needs you or claude can continue."
              : "Mark the session done. It leaves the Inbox and moves to Done on the board.")
        NotesButton(session: session, always: true)
        Button {
          showsSidePanel.toggle()
        } label: {
          Image(systemName: "sidebar.right")
        }
        .accessibilityLabel(showsSidePanel ? "Hide Waits and Notes" : "Show Waits and Notes")
        .disabled(!ui.sidePanelFits)
        .help(
          "Show or hide the session's waits and notes beside the terminals. The panel hides itself, and this button is off, while the view is too narrow for it."
        )
        if CleanupOffer.canCleanUp(session) {
          Button("Clean Up…") { model.confirmingCleanup = session.id }
            .disabled(model.cleaningUp.contains(session.id))
            .help("Delete the worktree and the local branch of the merged PR. The session stays in Done.")
        }
        Button(role: .destructive) {
          let todos = TodoDeletion(session)
          Task {
            let options = await RemoveOptions.load(session)
            ui.removeOptions = options
            ui.deleteWorktree = options.worktree
            ui.deleteBranch = options.branch
            ui.removal = todos
          }
        } label: {
          Image(systemName: "trash")
        }
        .help("Remove the session. Asks you to confirm first.")
      }
    }
    .padding(12)
  }

  /// The text has a fixed width, so a pane's button is at the same place in every view. The button sits
  /// next to the text, so it stays visible when a narrow column cuts off the end of the label.
  private func paneLabel(_ text: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
    HStack(spacing: SessionView.labelSpacing) {
      Text(text).font(.caption.bold()).foregroundStyle(.secondary)
        .frame(width: SessionView.labelWidth, alignment: .leading)
      trailing().buttonStyle(.borderless).font(.caption).controlSize(.small)
      Spacer()
    }
    .padding(.horizontal, SessionView.labelPadding)
    .padding(.vertical, 3)
    .background(.bar)
  }
}
