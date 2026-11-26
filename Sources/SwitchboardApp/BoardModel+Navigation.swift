import AppKit
import SwitchboardCore

extension BoardModel {
  /// The sessions in the order the sidebar lists them: the conversations, then each section's rows. A
  /// collapsed section's rows are left out, because the sidebar hides them. So are the archived conversations
  /// while the archive is closed.
  var sidebarOrder: [String] {
    let rows = sidebarGroups.filter { !collapsed.contains($0.state) }.flatMap { $0.rows.map(\.id) }
    return conversationOrder.map(\.id) + rows
  }

  var listFocusTarget: ListFocus {
    switch visibleView {
    case nil: return .sidebar
    case .inbox: return .inbox
    case .board: return .board
    case .issues: return .issues
    case .loops: return .loops
    }
  }

  /// Asks the list that `listFocusTarget` names to take keyboard focus.
  func requestListFocus() { listFocusRequests += 1 }

  /// Closes the search panel and selects `id` as a sidebar click does, even when the session has an Inbox
  /// item.
  func openFromSearch(_ id: String) {
    showingSearch = false
    guard let session = board.first(where: { $0.id == id }) else { return }
    showInSidebar(session)
  }

  /// Selects the session as a sidebar click does and makes the sidebar show its row. A work session's collapsed
  /// section opens, and the search field clears when its query hides the session. The archive opens for an
  /// archived conversation.
  func showInSidebar(_ session: SessionSummary) {
    if session.kind == .work { collapsed.remove(session.state) }
    openArchive(of: session)
    selection = session.id
    // Setting `selection` widens a filter that hides the session. The query check has to read the widened filter.
    if session.kind == .work, sidebarQueryHides(session) { sidebarQuery = "" }
    // A list focus request would take keyboard focus from an open sheet's fields.
    if !presentingSheet { requestListFocus() }
  }

  /// Opens the Archive groups that list the conversation when it is archived: the sidebar's, and the group column's
  /// for a group chat.
  func openArchive(of session: SessionSummary) {
    guard session.activity?.archived == true, session.kind.isUserConversation else { return }
    showingArchive = true
    if session.kind == .chat, let group = session.chat { shownChatArchives.insert(group) }
  }

  /// The focused Board card while the Board still shows it, else the first card, as the Inbox falls back to
  /// its first item.
  var currentBoardCard: String? { boardFocus.flatMap { boardGrid.contains($0) ? $0 : nil } ?? boardGrid.first }

  func moveBoardFocus(_ direction: BoardDirection) {
    boardFocus = boardGrid.move(from: currentBoardCard, direction) ?? boardFocus
    boardJumps += 1
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
        boardJumps += 1
      }
    case .issues:
      moveIssue(by: step)
    case .loops:
      moveLoop(by: step)
    }
    requestListFocus()
  }

  /// The session whose Claude terminal ⌘T and Return go into: the selected session, else the current Inbox
  /// item or Board card. The Issues and Loops views draw no terminal.
  var terminalTarget: SessionSummary? {
    switch visibleView {
    case nil: return selected
    case .inbox:
      let id = currentInboxItem
      return sessions.first { $0.id == id }
    case .board:
      let id = currentBoardCard
      return board.first { $0.id == id }
    case .issues, .loops: return nil
    }
  }

  var canFocusTerminal: Bool { terminalTarget.map(showsClaudeTerminal) ?? false }

  /// Puts keyboard focus in the target session's Claude terminal. The Inbox keeps showing an item whose
  /// terminal shows in place. Any other target is selected first, so its terminal shows.
  func focusTerminal() {
    guard let target = terminalTarget, showsClaudeTerminal(target) else { return }
    if !inboxShowsTerminal(target) { selection = target.id }
    terminalFocus = target.id
  }

  /// Whether the Inbox shows `target`'s terminal in its right pane.
  private func inboxShowsTerminal(_ target: SessionSummary) -> Bool {
    visibleView == .inbox && TriageDetail.pane(for: target, showingTerminal: showingTerminal) == .terminal
  }

  /// Shows the current Inbox item's terminal in the Inbox's right pane and puts keyboard focus in it.
  func openInboxTerminal() {
    showingTerminal = true
    focusTerminal()
  }

  /// Shows the session's whole conversation: a conversation's own view, or another session's terminal in the Inbox.
  func openTranscript(_ session: SessionSummary) {
    switch session.transcriptTarget {
    case .session:
      selection = session.id
    case .terminal: openInboxTerminal()
    case nil: break
    }
  }

  /// Clears the terminal focus request while it still names `id`.
  func releaseTerminalFocus(_ id: String) {
    if terminalFocus == id { terminalFocus = nil }
  }

  /// The session whose terminal view shows now, where ⇧⌘E reveals the Message Claude field. The Board and an
  /// Inbox summary have no terminal view.
  var messageFieldTarget: SessionSummary? {
    guard let target = terminalTarget, target.docket == nil, showsClaudeTerminal(target) else { return nil }
    switch visibleView {
    case nil: return target
    case .inbox: return inboxShowsTerminal(target) ? target : nil
    case .board, .issues, .loops: return nil
    }
  }

  /// Shows the Message Claude field under the terminal of `id`, or of `messageFieldTarget`. With `focus`, it also
  /// puts keyboard focus in the field.
  func revealMessageField(_ id: String? = nil, focus: Bool = true) {
    guard let id = id ?? messageFieldTarget?.id else { return }
    revealedMessageField = id
    if focus { messageFieldFocus = id }
  }

  /// Hides the session's Message Claude field and returns keyboard focus to its Claude terminal.
  func hideMessageField(_ id: String) {
    forgetMessageField(id)
    // An error alone keeps the field showing.
    if let session = summary(id) { messageDraft(for: session).error = nil }
    terminalFocus = id
  }

  /// Hides the field after a send, unless the user typed more while the send was on its way.
  func hideMessageFieldIfEmpty(_ id: String, draft: MessageField.Draft) {
    if draft.isEmpty { hideMessageField(id) }
  }

  /// Clears the reveal and the focus request of the session's Message Claude field while they still name `id`.
  func forgetMessageField(_ id: String) {
    if revealedMessageField == id { revealedMessageField = nil }
    releaseMessageFieldFocus(id)
  }

  /// Clears the field focus request while it still names `id`.
  func releaseMessageFieldFocus(_ id: String) {
    if messageFieldFocus == id { messageFieldFocus = nil }
  }

  private func showsClaudeTerminal(_ session: SessionSummary) -> Bool {
    session.hasTerminals && !session.waitsToStart
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

/// Where "Open in transcript" shows a session's whole conversation.
enum TranscriptTarget: Equatable {
  /// The session's own view. The Inbox leaves out some of a conversation's cards, such as a group message that waits for the user.
  case session
  /// The terminal of the Inbox item.
  case terminal
}

extension SessionSummary {
  /// A conversation's own view, or the terminal of another session that runs claude.
  var transcriptTarget: TranscriptTarget? {
    guard runsClaude, !waitsToStart else { return nil }
    return kind.isConversation ? .session : .terminal
  }
}
