import AppKit
import SwitchboardCore

extension BoardModel {
  /// The sessions in the order the sidebar lists them: the Manager conversations, then each section's rows. A
  /// collapsed section's rows are left out, because the sidebar hides them.
  var sidebarOrder: [String] {
    let rows = sidebarGroups.filter { !collapsed.contains($0.state) }.flatMap { $0.rows.map(\.id) }
    return managers.map(\.id) + rows
  }

  var listFocusTarget: ListFocus {
    switch visibleView {
    case nil: return .sidebar
    case .inbox: return .inbox
    case .board: return .board
    }
  }

  /// Asks the list that `listFocusTarget` names to take keyboard focus.
  func requestListFocus() { listFocusRequests += 1 }

  /// Closes the search panel and selects `id` as a sidebar click does, even when the session has an Inbox
  /// item. A work session's collapsed section opens, so the sidebar shows the selected row.
  func openFromSearch(_ id: String) {
    showingSearch = false
    guard let session = board.first(where: { $0.id == id }) else { return }
    if session.kind == .work { collapsed.remove(session.state) }
    selection = id
    requestListFocus()
  }

  /// The focused Board card while the Board still shows it, else the first card, as the Inbox falls back to
  /// its first item.
  var currentBoardCard: String? { boardFocus.flatMap { boardGrid.contains($0) ? $0 : nil } ?? boardGrid.first }

  func moveBoardFocus(_ direction: BoardDirection) {
    boardFocus = boardGrid.move(from: currentBoardCard, direction) ?? boardFocus
  }

  /// Steps to the next or previous session, around the ends, in the sidebar, the Inbox, or the Board,
  /// whichever shows. Then the list that shows takes keyboard focus, so the arrow keys move from there.
  func selectAdjacentSession(by step: Int) {
    switch visibleView {
    case nil:
      if let next = ListStep.step(sidebarOrder, from: selection, by: step, wrap: true) { selection = next }
    case .inbox:
      moveInbox(by: step)
    case .board:
      if let next = ListStep.step(boardGrid.readingOrder, from: currentBoardCard, by: step, wrap: true) {
        boardFocus = next
      }
    }
    requestListFocus()
  }

  /// The session whose Claude terminal ⌘T and Return go into: the selected session, else the current Inbox
  /// item or Board card.
  var terminalTarget: SessionSummary? {
    switch visibleView {
    case nil: return selected
    case .inbox:
      let id = currentInboxItem
      return sessions.first { $0.id == id }
    case .board:
      let id = currentBoardCard
      return board.first { $0.id == id }
    }
  }

  var canFocusTerminal: Bool { terminalTarget.map(showsClaudeTerminal) ?? false }

  /// Puts keyboard focus in the target session's Claude terminal. The Inbox keeps showing an item whose
  /// terminal shows in place. Any other target is selected first, so its terminal shows.
  func focusTerminal() {
    guard let target = terminalTarget, showsClaudeTerminal(target) else { return }
    let inPlace =
      visibleView == .inbox && TriageDetail.pane(for: target, showingTerminal: showingTerminal) == .terminal
    if !inPlace { selection = target.id }
    terminalFocus = target.id
  }

  /// Clears the terminal focus request while it still names `id`.
  func releaseTerminalFocus(_ id: String) {
    if terminalFocus == id { terminalFocus = nil }
  }

  /// A chat shows its terminal only while the Terminal toggle is on. A request for a hidden terminal would
  /// take focus later, when the user turns the toggle on.
  private func showsClaudeTerminal(_ session: SessionSummary) -> Bool {
    session.hasTerminals && !session.waitsToStart && (!hasChatPane(session) || showingTerminal)
  }
}

/// What the Board draws: a lane per repo or group with a cell for each of
/// `columns`, and the Done footer. `grid` holds the ids of the cells' cards,
/// so the arrow keys reach exactly the drawn cards.
struct BoardLayout {
  struct Lane: Identifiable {
    var id: String
    var title: String
    var group: GroupSummary?
    var cells: [[SessionSummary]]
  }

  var columns: [BoardColumn]
  var lanes: [Lane]
  var done: [SessionSummary]
  var grid: BoardGrid
}

extension BoardModel {
  func boardLayout(lanes kind: BoardLanes) -> BoardLayout {
    let board = workBoard
    let open = board.filter { !MergeBoard.isDone($0) }
    let rows: [(id: String, title: String, group: GroupSummary?, sessions: [SessionSummary])]
    switch kind {
    case .repo:
      rows = MergeBoard.repoLanes(open, labels: RepoLabels.labels(board, evenForOneRepo: true, fullName: true)).map {
        ("repo-\($0.id)", $0.title, nil, $0.sessions)
      }
    case .group:
      rows = BoardRows.make(sessions: open, groups: shownGroups).map { row in
        (row.id, row.title, groups.first { $0.id == row.group }, row.sessions)
      }
    }
    let lanes = rows.map { row in
      BoardLayout.Lane(
        id: row.id, title: row.title, group: row.group,
        cells: MergeBoard.columns.map { MergeBoard.cards(row.sessions, in: $0) })
    }
    return BoardLayout(
      columns: MergeBoard.columns, lanes: lanes, done: board.filter(MergeBoard.isDone),
      grid: BoardGrid(lanes: lanes.map { $0.cells.map { $0.map(\.id) } }))
  }
}
