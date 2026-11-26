import SwiftUI
import SwitchboardCore

extension BoardModel {
  /// True while `key` holds a value. Dismissing the sheet or dialog sets `key` to nil.
  fileprivate func isPresent<T>(_ key: ReferenceWritableKeyPath<BoardModel, T?>) -> Binding<Bool> {
    Binding(get: { self[keyPath: key] != nil }, set: { if !$0 { self[keyPath: key] = nil } })
  }
}

extension AttentionState {
  var color: Color {
    switch self {
    case .needsYou: .orange
    case .readyToMerge: .mint
    case .canContinue: .blue
    case .readyForReview: .indigo
    case .waiting: .purple
    case .working: .green
    case .done: .gray
    case .stale: .brown
    case .notStarted: .teal
    }
  }
}

extension PRStatus {
  /// Review states are blue, not orange, because orange is the Needs you color on the Board.
  var color: Color {
    switch self {
    case .approved: .green
    case .changesRequested: .red
    case .reviewRequired, .notApproved: .blue
    case .merged: .purple
    case .draft, .closed: .gray
    }
  }
}

/// The state's title in a capsule of its color.
struct StateBadge: View {
  let state: AttentionState

  var body: some View {
    Text(state.title).pill(state.color, size: .regular)
  }
}

struct ContentView: View {
  static let windowMinWidth: CGFloat = 900
  static let sidebarMinWidth: CGFloat = 240
  static let sidebarIdealWidth: CGFloat = 300

  /// A view picker segment's label, such as `Inbox 5`. A zero count does not show.
  static func viewLabel(_ name: String, _ count: Int) -> String { count > 0 ? "\(name) \(count)" : name }

  @EnvironmentObject var model: BoardModel
  @State private var sidebar = SidebarFit(ruleHidLastRun: UserDefaults.standard.bool(forKey: SidebarFit.autoHiddenKey))
  @State private var windowWidth: CGFloat = 0

  private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(get: { sidebar.visibility }, set: { sidebar.userSet($0) })
  }

  /// Shows or hides the sidebar for the window's width and the detail column's view. The change does not animate. A
  /// view switch in a narrow window therefore does not slide the sidebar each time.
  private func fitSidebar() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      sidebar.update(windowWidth: windowWidth, isListDetail: model.showsListDetail)
    }
  }

  private var confirmingCleanupOffer: CleanupOffer? {
    model.board.first { $0.id == model.confirmingCleanup }.flatMap(CleanupOffer.init)
  }

  private var isShowingDoneRemoval: Binding<Bool> {
    Binding(get: { model.showingDoneRemoval }, set: { if !$0 { model.doneRemoval = nil } })
  }

  private var isShowingQuickAsk: Binding<Bool> {
    Binding(get: { model.quickAsk != nil }, set: { if !$0 { model.closeQuickAsk() } })
  }

  var body: some View {
    let column = model.detailColumn
    let deleteConfirmation = model.confirmingDelete.map(DeleteConfirmation.init)
    return NavigationSplitView(columnVisibility: sidebarVisibility) {
      Sidebar()
        .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: Self.sidebarIdealWidth, max: 420)
    } detail: {
      VStack(spacing: 0) {
        if let problem = model.unreachable {
          ServiceBanner(problem: problem)
        }
        if let error = model.actionError {
          WarningBanner(error) { Button("Dismiss") { model.actionError = nil } }
        }
        switch column {
        case .multiSelection: MultiSelectionView()
        case .followup(let s, let f): FollowupView(session: s, followup: f).id(s.id)
        case .docket(let s, let d): DocketView(session: s, docket: d).id(s.id)
        case .session(let s): SessionView(session: s).id(s.id)
        case .main(.inbox): InboxView()
        case .main(.board): BoardView()
        case .main(.issues): IssuesView()
        case .main(.loops): LoopsView()
        }
      }
      // The delete dialog is on the split view. Two dialogs on one view can hide each other.
      .confirmationDialog(
        confirmingCleanupOffer?.title ?? "Clean up this session?", isPresented: model.isPresent(\.confirmingCleanup),
        presenting: confirmingCleanupOffer
      ) { offer in
        Button("Clean Up", role: .destructive) { model.cleanup(offer.session) }
      } message: { offer in
        Text(model.sessionNames.replacingIDs(in: offer.message))
      }
      // A session view sets `shownSession` when it appears. `isSession` covers the frame before that.
      .mainToolbar(showsSessionItems: model.shownSession != nil || column.isSession)
    }
    .removingToolbarTitle()
    // The rule reads only whether the window is narrower than `collapseBelow`. Wider widths need no update.
    .onGeometryChange(for: CGFloat.self) {
      min($0.size.width, SidebarFit.collapseBelow)
    } action: {
      windowWidth = $0
      fitSidebar()
    }
    .onChange(of: model.showsListDetail) { fitSidebar() }
    .onChange(of: sidebar.autoHidden) { UserDefaults.standard.set($1, forKey: SidebarFit.autoHiddenKey) }
    .confirmationDialog(
      deleteConfirmation?.title ?? "Delete this session?", isPresented: model.isPresent(\.confirmingDelete),
      presenting: deleteConfirmation
    ) { confirmation in
      Button(confirmation.button, role: .destructive) { confirmation.confirm(model) }
    } message: { confirmation in
      Text(model.sessionNames.replacingIDs(in: confirmation.message))
    }
    .sheet(item: $model.newSession) {
      NewSessionView(request: $0).environmentObject(model)
    }
    .sheet(isPresented: $model.showingImport) {
      ImportView().environmentObject(model)
    }
    .sheet(isPresented: $model.showingSearch) {
      SessionSearchView().environmentObject(model)
    }
    .sheet(isPresented: isShowingQuickAsk) {
      QuickAskView().environmentObject(model)
    }
    .sheet(isPresented: isShowingDoneRemoval) {
      DoneRemovalSheet().environmentObject(model).inlineLinks(model)
    }
    .sheet(isPresented: model.isPresent(\.pickingSnoozeTime)) {
      if let id = model.pickingSnoozeTime {
        UntilPicker(
          session: id, verb: "Snooze", apply: { model.snooze(id, until: $0) },
          close: { model.pickingSnoozeTime = nil }
        ).environmentObject(model)
      }
    }
    .sheet(isPresented: model.isPresent(\.pickingPauseTime)) {
      if let id = model.pickingPauseTime {
        UntilPicker(
          session: id, verb: "Pause", apply: { model.pause(id, until: $0) },
          close: { model.pickingPauseTime = nil }
        ).environmentObject(model)
      }
    }
    .sheet(isPresented: model.isPresent(\.editingNotes)) {
      if let id = model.editingNotes {
        NotesSheet(id: id) { model.editingNotes = nil }.environmentObject(model)
      }
    }
    .sheet(isPresented: model.isPresent(\.shortcutsOverlay)) {
      if let request = model.shortcutsOverlay {
        ShortcutsOverlay(request: request).environmentObject(model)
      }
    }
    .sheet(isPresented: model.isPresent(\.renaming)) {
      if let id = model.renaming {
        RenameSheet(id: id) { model.renaming = nil }.environmentObject(model)
      }
    }
    .sheet(isPresented: model.isPresent(\.loopEditor)) {
      if let request = model.loopEditor {
        LoopEditor(
          request: request, schedule: model.editedSchedule(request),
          choices: LoopEditor.sessionChoices(model.sessions, operatorID: model.operatorSession?.id)
        )
        .environmentObject(model)
      }
    }
    .sheet(isPresented: model.isPresent(\.loopOutput)) {
      if let output = model.loopOutput {
        LoopOutputSheet(output: output, schedule: model.schedule(output.schedule))
          .environmentObject(model)
      }
    }
    .inlineLinks(model)
  }
}

/// An orange strip across the pane with a warning and an optional button at its end.
struct WarningBanner<Action: View>: View {
  let text: String
  @ViewBuilder let action: () -> Action

  init(_ text: String, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
    self.text = text
    self.action = action
  }

  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      InlineText(plain: text).lineLimit(2).textSelection(.enabled)
      Spacer()
      action()
    }
    .padding(8)
    .background(.orange.opacity(0.12))
  }
}

extension View {
  /// The window title takes about 190 pt of the toolbar. Without it, a 1024 pt wide window shows the
  /// three-segment picker and more of the toolbar's buttons before the overflow menu. macOS 14 keeps the title.
  @ViewBuilder func removingToolbarTitle() -> some View {
    if #available(macOS 15, *) { toolbar(removing: .title) } else { self }
  }
}

struct Sidebar: View {
  @EnvironmentObject var model: BoardModel
  @FocusState private var focused: Bool

  var body: some View {
    let repos = model.repoLabels
    let activeAccount = model.activeAccountFolder
    let removableSelection = model.showsMultiSelection ? model.removableSelectionCount : 0
    let groups = model.sidebarGroups
    List(selection: model.sidebarSelection) {
      ConversationsSection(activeAccount: activeAccount, removableSelection: removableSelection)
      if groups.isEmpty && model.filterHidesAllWork { FilterHidesAll() }
      if groups.isEmpty && model.sidebarQueryHidesAll { ContentUnavailableView.search(text: model.sidebarQuery) }
      ForEach(groups) { group in
        let state = group.state
        Section(isExpanded: expanded(state)) {
          ForEach(group.rows) { row in
            HStack(spacing: 4) {
              SessionRow(
                session: row.session, activeAccount: activeAccount, repo: repos[row.id], hoverCard: model.hoverCard
              )
              .clickAnchor(row.id)
              NotesButton(session: row.session)
              if CleanupOffer.canCleanUp(row.session) { CleanupButton(session: row.session) }
              if row.session.isRemovableDone { DeleteButton(session: row.session) }
            }
            .highlightRing(row.session.isHighlighted, cornerRadius: 4, outset: 2)
            .padding(.leading, CGFloat(row.depth) * 14).tag(row.id)
            .contextMenu { SessionMenuItems(session: row.session, removableSelection: removableSelection) }
          }
        } header: {
          HStack {
            Text(state.title)
            Spacer()
            if state == .done { DeleteAllDoneButton() }
            Text("\(group.rows.count)").foregroundStyle(.secondary)
          }
        }
      }
    }
    .focused($focused)
    .onKeyPress(keys: [.return]) { press in
      guard NavKey.action(press.key, modifiers: press.modifiers) == .open, model.selection != nil else {
        return .ignored
      }
      model.focusTerminal()
      return .handled
    }
    .onKeyPress(keys: [.delete]) { press in
      guard SelectionKey.action(press.key, modifiers: press.modifiers) == .delete, model.showsMultiSelection,
        removableSelection > 0, !model.showingDoneRemoval
      else { return .ignored }
      model.checkSelectionRemoval()
      return .handled
    }
    .takesListFocus(.sidebar, $focused, model: model)
    .confirmationDialog(
      accountSwitchTitle, isPresented: model.isPresent(\.switchingAccount), presenting: model.switchingAccount
    ) { change in
      if change.switches {
        Button("New Sessions Only") { model.confirmAccountSwitch(change, move: false) }
      }
      if !change.plan.moved.isEmpty {
        let n = change.plan.moved.count
        let s = n == 1 ? "" : "s"
        Button(change.switches ? "Also Move \(n) Existing Session\(s)" : "Move \(n) Session\(s)") {
          model.confirmAccountSwitch(change, move: true)
        }
      }
    } message: { change in
      Text(accountSwitchMessage(change))
    }
    .confirmationDialog(
      model.confirmingAccountMove?.title ?? "", isPresented: model.isPresent(\.confirmingAccountMove),
      presenting: model.confirmingAccountMove
    ) { move in
      Button(move.button) { model.confirmAccountMove(move) }
      Button("Cancel", role: .cancel) {}
    } message: { move in
      Text(move.message)
    }
    // The overlay comes before the bottom safe area inset, so the empty state fills only the space above it and
    // never covers New Group.
    .overlay {
      if model.sidebarIsEmpty {
        ContentUnavailableView {
          Label("No sessions", systemImage: "rectangle.stack")
        } description: {
          Text("Start a session, or import ones that are already running.")
        } actions: {
          // Side by side, the two buttons overflow the sidebar at its minimum width.
          VStack {
            Button("Start a Session…") { model.openNewSession() }
            Button("Import Sessions…") { model.showingImport = true }
          }
        }
        .padding(.horizontal)
      }
    }
    // A toolbar search field would push New Session into the overflow menu at the minimum window width.
    .searchable(text: $model.sidebarQuery, placement: .sidebar, prompt: "Search Sessions")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        FilterBar()
        Button {
          model.startNewGroup()
        } label: {
          Label("New Group", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .help(AppShortcut.newGroup.help("Create an empty group on the Board"))
        .accessibilityIdentifier("sidebar-new-group")
        RemovalStatusView()
      }
    }
  }

  private var accountSwitchTitle: String {
    guard let change = model.switchingAccount else { return "Switch accounts?" }
    return change.switches ? "Switch to \(change.name)?" : "Move sessions to \(change.name)?"
  }

  private func accountSwitchMessage(_ change: AccountSwitch) -> String {
    var lines = change.switches ? ["New sessions use \(change.name) either way."] : []
    if !change.plan.moved.isEmpty { lines.append(AccountMove.consequences) }
    let blocked = change.plan.blocked
    if !blocked.isEmpty {
      lines.append("Stays on its account: " + blocked.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ") + ".")
    }
    return lines.joined(separator: "\n\n")
  }

  private func expanded(_ state: AttentionState) -> Binding<Bool> {
    Binding(
      get: { !model.collapsed.contains(state) },
      set: { if $0 { model.collapsed.remove(state) } else { model.collapsed.insert(state) } })
  }
}

/// Asks to delete a Done session with its worktree and branch. The dialog is on ContentView.
struct DeleteButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    let summary = BoardModel.deletePlan(session).summary
    Button {
      model.confirmingDelete = session
    } label: {
      Image(systemName: "trash")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(model.deleting.contains(session.id))
    .accessibilityLabel("Delete \(session.name): \(summary)")
    .help("Delete \(summary)…")
  }
}

/// Opens the most recent Manager conversation, or starts the first one. The
/// icon turns the Needs you color and fills while a conversation needs you,
/// because the Inbox and the Dock badge leave the conversations out.
struct ManagerButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let managers = model.managers
    let icon = ManagerIcon(managers)
    Button {
      model.openManager()
    } label: {
      Label("Manager", systemImage: icon.systemImage)
        .foregroundStyle(icon.color)
    }
    .accessibilityValue(icon.value)
    .help(tooltip(icon, managers))
  }

  private func tooltip(_ icon: ManagerIcon, _ managers: [SessionSummary]) -> String {
    switch icon {
    case .needsMe:
      guard let waiting = model.waitingManager, let reason = ChatMark(waiting).needsMeReason else {
        return AppShortcut.openManager.help("A Manager conversation needs you")
      }
      return AppShortcut.openManager.help("\(waiting.name) needs you: \(reason)")
    case .unread: return AppShortcut.openManager.help("A Manager conversation has unread replies")
    case .outline:
      return managers.isEmpty
        ? AppShortcut.openManager.help("Start a session that manages the others through sb")
        : AppShortcut.openManager.help("Open the latest Manager conversation")
    }
  }
}

/// How the toolbar's Manager icon looks: orange while a conversation waits on
/// the user, blue while one has unread replies, and an outline otherwise.
enum ManagerIcon: Equatable {
  case needsMe, unread, outline

  init(_ managers: [SessionSummary]) {
    let marks = managers.map(ChatMark.init)
    if marks.contains(where: { $0.needsMeReason != nil }) {
      self = .needsMe
    } else if marks.contains(where: { if case .unread = $0 { true } else { false } }) {
      self = .unread
    } else {
      self = .outline
    }
  }

  var systemImage: String {
    self == .outline ? "person.crop.circle.badge.checkmark" : "person.crop.circle.fill.badge.checkmark"
  }

  var color: Color {
    switch self {
    case .needsMe: AttentionState.needsYou.color
    case .unread: .accentColor
    case .outline: .primary
    }
  }

  var value: String {
    switch self {
    case .needsMe: AttentionState.needsYou.title
    case .unread: "Unread replies"
    case .outline: ""
    }
  }
}

extension PRSummary {
  var numberLabel: String { "#\(number)" }
  var tooltip: String { "\(status.rawValue)\(queuePhrase.map { ", \($0)" } ?? "") · \(repo): \(title)" }
}

struct SessionRow: View {
  let session: SessionSummary
  /// The active account's folder. The hover card names the session's account only when it differs.
  let activeAccount: String
  var repo: String? = nil
  var hoverCard: HoverCard<String>? = nil
  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(session.state.color)
        .frame(width: 8, height: 8)
        .opacity(session.live ? 1 : 0.35)
        .padding(.top, 5)
        .help(
          session.waitsToStart
            ? "not started"
            : !session.runsClaude ? "docket review" : session.live ? "claude is running" : "claude is stopped")
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(session.name).fontWeight(.medium).lineLimit(1)
          if let pause = session.pause {
            Image(systemName: "pause.circle").font(.caption).foregroundStyle(.secondary)
              .help(pause.line).accessibilityLabel("Paused")
          }
          Spacer()
          if session.hasNewReply { NewReplyMark() }
          IssueBadge(session: session)
          if let pr = session.pr, let url = pr.link {
            HStack(spacing: 3) {
              PRLink(text: pr.numberLabel, url: url)
                .font(.caption)
                .fixedSize()
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(pr.status.color))
                .help(pr.tooltip)
                .accessibilityValue(pr.status.rawValue)
              if let owners = pr.codeOwners { CodeOwnerShield(status: owners) }
            }
          }
          Text(ago(session.since)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        // The sidebar can be too narrow for the badge beside the PR number.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let pr = session.pr { QueueBadge(pr: pr) }
          if let until = session.snoozedUntil { SnoozeMark(until: until) }
          subtitle
        }
        CleanupNote(session: session)
        BranchSwitchNote(session: session)
      }
    }
    .padding(.vertical, 2)
    .hoverCard(session, activeAccount: activeAccount, card: hoverCard)
    .highlightAccessibility(session.isHighlighted)
  }

  /// Text truncates at its end. The reason therefore truncates before the repo does.
  private var subtitle: some View {
    let parts = [repo, session.reason].compactMap { $0 }
    return Text(verbatim: parts.joined(separator: " · "))
      .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      .accessibilityLabel(Text(verbatim: parts.joined(separator: ", ")))
  }
}

struct ServiceBanner: View {
  @EnvironmentObject var model: BoardModel
  let problem: String

  var body: some View {
    HStack {
      Image(systemName: "bolt.horizontal.circle").foregroundStyle(.red)
      VStack(alignment: .leading) {
        Text("sbd isn't answering").fontWeight(.medium)
        Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      if BoardModel.sbPath != nil {
        Button("Start sbd") { model.installService() }
          .help("Install sbd as a launchd agent with `sb service install`")
      }
    }
    .padding(10)
    .background(.red.opacity(0.08))
  }
}

/// How the board's lanes split the sessions.
enum BoardLanes: String, CaseIterable {
  case repo, group

  static let storageKey = "boardLanes"

  var title: String { self == .repo ? "Repo" : "Group" }
}

/// The board: a lane per repo or per group, and a column for each of
/// `MergeBoard.columns`. Done sessions and merged PRs collapse into a footer.
struct BoardView: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(BoardLanes.storageKey) private var laneKind = BoardLanes.repo
  @FocusState private var focused: Bool
  @State private var boardGeometry = BoardGeometry()
  static let contentSpace = "board-content"
  static let columnWidth: CGFloat = 200
  /// Five columns at this width fit beside a sidebar of `ContentView.sidebarIdealWidth` in a 1024 pt window.
  /// A wider sidebar leaves too little room. The Board then scrolls sideways.
  static let minColumnWidth: CGFloat = 120
  static let maxColumnWidth: CGFloat = 280
  static let columnSpacing: CGFloat = 12
  static let boardPadding = Design.listInset
  static var legacyScrollerWidth: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

  /// How wide each column draws in a Board `width` points wide with `columns` columns. The columns fill the width
  /// that a legacy vertical scroller leaves, kept between `minColumnWidth` and `maxColumnWidth`. A Board too narrow
  /// for every column at the minimum scrolls sideways.
  static func fittedColumnWidth(available width: CGFloat, columns: Int) -> CGFloat {
    guard columns > 0 else { return minColumnWidth }
    // Overlay scrollers take no width. The Board reserves the legacy width anyway, so a mouse plugged in later
    // does not make it scroll sideways.
    let room = width - legacyScrollerWidth - 2 * boardPadding - rowWidth(columnWidth: 0, columns: columns)
    return min(max(room / CGFloat(columns), minColumnWidth), maxColumnWidth)
  }

  /// How wide a lane's row of `columns` columns draws, each `columnWidth` wide.
  static func rowWidth(columnWidth: CGFloat, columns: Int) -> CGFloat {
    CGFloat(columns) * columnWidth + columnSpacing * CGFloat(max(columns - 1, 0))
  }

  /// Makes the same moves as a drag, because keyboard and VoiceOver users
  /// can't start a drag. It also offers Ungrouped when the Board hides the
  /// Ungrouped lane. On a selected card it moves the whole selection.
  /// `laneGroups` maps each card to the group of its lane.
  private func moveMenu(_ id: String, laneGroups: [String: String?]) -> some View {
    let ids = model.boardActionIDs(for: id)
    let allIn = { (group: String?) in ids.allSatisfy { laneGroups[$0] == .some(group) } }
    return Menu(ids.count > 1 ? "Move \(ids.count) Sessions to Group" : "Move to Group") {
      ForEach(model.groups, id: \.id) { g in
        Button(g.name) { model.moveToGroup(ids, g.id) }.disabled(allIn(g.id))
      }
      Divider()
      Button(BoardRows.ungroupedTitle) { model.moveToGroup(ids, nil) }.disabled(allIn(nil))
    }
  }

  var body: some View {
    // The arrow keys' grid and the drawn cards both come from this one value, so they always agree.
    let layout = model.boardLayout(lanes: laneKind)
    cards(layout)
      .onChange(of: layout.grid, initial: true) {
        model.boardGrid = layout.grid
        boardGeometry.keepFrames(Set((layout.cards + layout.done).map(\.id)))
      }
  }

  @ViewBuilder
  private func cards(_ layout: BoardLayout) -> some View {
    let ring = focused ? model.currentBoardCard : nil
    let removableSelection = model.showsMultiSelection ? model.removableSelectionCount : 0
    // A repo lane has no group, like the Ungrouped lane, so a drop there would ungroup the card.
    let drops = laneKind == .group
    let laneGroups: [String: String?] =
      drops
      ? Dictionary(
        layout.lanes.flatMap { lane in lane.cells.joined().map { ($0.id, lane.group?.id) } },
        uniquingKeysWith: { first, _ in first })
      : [:]
    // The new group's name field is in the lanes header, so naming a group keeps the header up.
    let empty = layout.lanes.isEmpty && layout.done.isEmpty && !(model.namingGroup && laneKind == .group)
    if empty && model.filterHidesAllWork {
      FilterHidesAll().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if empty {
      ContentUnavailableView {
        Label("No sessions", systemImage: MainView.board.symbol)
      } description: {
        Text("Start a session to see it here.")
      } actions: {
        Button("New Session…") { model.openNewSession() }
        Button("New Group") { model.startNewGroup() }
      }
    } else {
      GeometryReader { geometry in
        let fittedWidth = Self.fittedColumnWidth(available: geometry.size.width, columns: layout.columns.count)
        let rowWidth = Self.rowWidth(columnWidth: fittedWidth, columns: layout.columns.count)
        ScrollViewReader { proxy in
          ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
              Section {
                ForEach(layout.lanes) { lane in
                  Divider()
                  VStack(alignment: .leading, spacing: 8) {
                    LaneHeader(title: lane.title, group: lane.group, count: lane.cells.joined().count)
                      .frame(width: rowWidth, alignment: .leading)
                      .modifier(
                        BoardFrameReport(
                          record: { boardGeometry.recordLaneHeader(lane.id, $0) },
                          drop: { boardGeometry.dropLaneHeader(lane.id, ifStill: $0) }))
                    HStack(alignment: .top, spacing: Self.columnSpacing) {
                      ForEach(Array(zip(layout.columns, lane.cells)), id: \.0) { _, stack in
                        VStack(spacing: 8) {
                          ForEach(stack) { s in
                            BoardCard(
                              session: s, keyboardFocused: s.id == ring, boardActive: focused, draggable: drops
                            ) {
                              focused = true
                            }
                            .contextMenu {
                              if drops {
                                SessionMenuItems(session: s, removableSelection: removableSelection) {
                                  moveMenu(s.id, laneGroups: laneGroups)
                                }
                              } else {
                                SessionMenuItems(session: s, removableSelection: removableSelection)
                              }
                            }
                            .id(s.id)
                          }
                        }
                        .frame(width: fittedWidth, alignment: .top)
                      }
                    }
                  }
                  .modifier(LaneDrop(enabled: drops, group: lane.group?.id))
                  .accessibilityElement(children: .contain)
                  .accessibilityLabel(lane.title)
                  .accessibilityIdentifier("board-row-\(lane.id)")
                }
                DoneFooter(sessions: layout.done, boardActive: focused) { focused = true }
              } header: {
                VStack(alignment: .leading, spacing: 8) {
                  WrappingRow(spacing: Self.columnSpacing) {
                    Picker("Lanes", selection: $laneKind) {
                      ForEach(BoardLanes.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Show a lane per repo or per group")
                    // The header stays pinned, so the name field shows without a scroll.
                    if laneKind == .group { NewGroupRow() }
                    GroupSuggestionButton()
                  }
                  .frame(width: rowWidth, alignment: .leading)
                  HStack(alignment: .center, spacing: Self.columnSpacing) {
                    ForEach(layout.columns, id: \.self) { column in
                      HStack(spacing: 4) {
                        Text(column.title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                          .lineLimit(1)
                        if column == .inReview { NudgeAllMenu(sessions: layout.cards) }
                      }
                      .frame(width: fittedWidth, alignment: .leading)
                    }
                  }
                }
                .padding(.vertical, 4)
                .background(.background)
                .onGeometryChange(for: CGRect.self) {
                  $0.frame(in: .named(Self.contentSpace))
                } action: {
                  boardGeometry.header = $0
                }
              }
            }
            .padding(Self.boardPadding)
            // Empty space under and right of the lanes takes clicks and drags too.
            .frame(
              minWidth: geometry.size.width - Self.legacyScrollerWidth, minHeight: geometry.size.height,
              alignment: .topLeading
            )
            .contentShape(Rectangle())
            .background {
              // SwiftUI sends a click on a platform view to that view, not to the Board's gestures. The anchor
              // covers all empty space, so without this no click or drag there would reach a gesture.
              BoardScrollAnchor(geometry: boardGeometry).allowsHitTesting(false)
            }
            .modifier(BoardMarqueeSelection(geometry: boardGeometry) { focused = true })
            .coordinateSpace(name: Self.contentSpace)
            .environment(\.boardGeometry, boardGeometry)
          }
          // macOS hides overlay scrollers until a scroll, so nothing would show that more columns sit to the right.
          .scrollIndicators(.visible)
          .defaultScrollAnchor(.topLeading)
          .focusable()
          .focused($focused)
          .focusEffectDisabled()
          .onKeyPress(
            keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, .space, .delete],
            phases: [.down, .repeat]
          ) { press in
            // SwiftUI offers a key to this handler before a text field inside the Board. The new group's name
            // field and a lane's description field keep their own arrows, Return, Escape, and Space.
            if NSApp.keyWindow?.firstResponder is NSText { return .ignored }
            if let handled = selectionKey(press, removable: removableSelection) { return handled }
            switch NavKey.action(press.key, modifiers: press.modifiers) {
            case .move(let direction): model.moveBoardFocus(direction)
            case .open:
              guard let id = model.currentBoardCard else { return .ignored }
              model.openFromBoard(id)
            case nil: return .ignored
            }
            return .handled
          }
          .takesListFocus(.board, $focused, model: model)
          // ⇧⌘G shows the Board with the new group's name field, which closes when it loses focus while empty.
          .onAppear { if !model.namingGroup { focused = true } }
          .onChange(of: model.boardJumps, initial: true) {
            if let id = model.boardFocus { proxy.scrollTo(id, reduceMotion: reduceMotion) }
          }
        }
      }
      .groupDeleteDialog(model)
    }
  }
}

/// Moves a card dropped on a group lane into `group`, or out of its group
/// on the Ungrouped lane, where `group` is nil. The lane under the drag
/// shows a tint. The drop area covers the whole lane, so an empty group's
/// lane also takes cards.
private struct LaneDrop: ViewModifier {
  @EnvironmentObject var model: BoardModel
  let enabled: Bool
  let group: String?
  @State private var targeted = false

  func body(content: Content) -> some View {
    if enabled {
      content
        .contentShape(Rectangle())
        .background {
          if targeted {
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.accentColor.opacity(0.12))
              .stroke(Color.accentColor.opacity(0.6))
              .padding(-6)
          }
        }
        .dropDestination(for: String.self) { ids, _ in
          model.dropBoardCards(ids, on: group)
        } isTargeted: {
          targeted = $0
        }
    } else {
      content
    }
  }
}

/// Passes the view's frame in `BoardView.contentSpace` to `record`. When the view goes away, it passes the last
/// frame it recorded to `drop`.
struct BoardFrameReport: ViewModifier {
  let record: (CGRect) -> Void
  let drop: (CGRect?) -> Void
  @State private var recordedFrame: CGRect?

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named(BoardView.contentSpace))
      } action: {
        recordedFrame = $0
        record($0)
      }
      .onDisappear { drop(recordedFrame) }
  }
}

/// A lane's header above its row of columns. A group lane also shows the group's
/// description, its chat, its links and notes, and its plans' Follow up rows and pending updates.
private struct LaneHeader: View {
  @EnvironmentObject var model: BoardModel
  let title: String
  let group: GroupSummary?
  let count: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      WrappingRow(spacing: 8) {
        Text(title).fontWeight(.semibold).lineLimit(1).accessibilityAddTraits(.isHeader)
        if let group {
          Button {
            model.openNewSession(group: group.id)
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .disabled(model.presentingSheet)
          .help("Start a session in \(group.name)")
          .accessibilityLabel("New session in \(group.name)")
          .accessibilityIdentifier("board-new-session-\(group.id)")
        }
        Text(count == 1 ? "1 session" : "\(count) sessions")
          .font(.caption).foregroundStyle(.secondary)
        if let group {
          GroupAccountMenu(group: group)
          GroupChatButton(group: group)
          Button("Delete") { model.requestDeleteGroup(group) }
            .buttonStyle(.link).font(.caption)
            .help(group.sessions.isEmpty ? "Delete this group" : "Delete this group and move its sessions to Ungrouped")
            .accessibilityLabel("Delete group \(group.name)")
          GroupPauseButtons(group: group)
          GroupArtifactsLink(group: group)
          GroupLinksLink(group: group)
          GroupNotesLink(group: group)
        }
      }
      if let group { GroupDescriptionView(group: group) }
      let plans = group?.plans ?? []
      PlanFollowupList(plans: plans)
      PlanArtifactList(plans: plans)
    }
    .contextMenu {
      if let group { Button("Delete Group…", role: .destructive) { model.requestDeleteGroup(group) } }
    }
  }
}

/// The Done sessions and the sessions whose PR merged, collapsed to one line.
private struct DoneFooter: View {
  let sessions: [SessionSummary]
  /// The Board has keyboard focus.
  let boardActive: Bool
  /// Gives the Board keyboard focus.
  let activate: () -> Void
  @State private var expanded = false

  private static let grid = [GridItem(.adaptive(minimum: BoardView.columnWidth), alignment: .top)]

  var body: some View {
    if !sessions.isEmpty {
      // A merged session can still have an Inbox item, such as its post-merge
      // steps. Its card stays visible while the rest collapse.
      let inInbox = sessions.filter { AttentionState.inbox.contains($0.state) }
      let collapsed = sessions.filter { !AttentionState.inbox.contains($0.state) }
      Divider()
      if !inInbox.isEmpty {
        LazyVGrid(columns: Self.grid, spacing: 8) {
          ForEach(inInbox) { s in BoardCard(session: s, boardActive: boardActive, activate: activate) }
        }
      }
      // Every Done session is outside the Inbox states, so Delete All has
      // nothing to delete when the collapsed list is empty.
      if !collapsed.isEmpty {
        DisclosureGroup(isExpanded: $expanded) {
          LazyVGrid(columns: Self.grid, spacing: 8) {
            ForEach(collapsed) { s in BoardCard(session: s, boardActive: boardActive, activate: activate) }
          }
          .padding(.top, 8)
        } label: {
          HStack {
            HStack {
              Text("Done and merged").fontWeight(.semibold)
              Text("\(collapsed.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            DeleteAllDoneButton()
          }
        }
        .accessibilityIdentifier("board-done")
      }
    }
  }
}

/// The plan rows of a group that read Not started and have no follow-up,
/// each with a button that makes one.
struct PlanFollowupList: View {
  @EnvironmentObject var model: BoardModel
  let plans: [PlanSummary]

  var body: some View {
    ForEach(plans) { plan in
      ForEach(plan.canFollowUp, id: \.text) { row in
        let ref = row.ref ?? row.text
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(row.label).font(.caption).lineLimit(2).help(row.text)
          Spacer(minLength: 0)
          Button("Follow up") { model.followUp(plan: plan.id, row: ref) }
            .controlSize(.small)
            .disabled(model.isFollowingUp(plan: plan.id, row: ref))
            .accessibilityLabel("Follow up: \(row.item ?? ref)")
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-row-\(plan.id)-\(ref)")
      }
    }
  }
}

/// A group's artifact plans: whether sbd's copy may be old, and a pending
/// update's diff with Apply and Reject.
struct PlanArtifactList: View {
  @EnvironmentObject var model: BoardModel
  /// The plan whose full diff the popover shows.
  @State private var diffShown: String?
  let plans: [PlanSummary]

  var body: some View {
    ForEach(plans.filter { $0.source.kind == .artifact }) { plan in
      VStack(alignment: .leading, spacing: 4) {
        if let error = plan.error {
          Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).help(error)
        }
        if plan.copyStale == true {
          Text(plan.read == nil ? "No copy of the artifact yet" : "Copy of the artifact may be old")
            .font(.caption).foregroundStyle(.orange)
            .help("sb plan artifact read \(plan.id) asks the chat to read it again")
        }
        if let proposal = plan.proposal {
          let diffText = proposal.diff.joined(separator: "\n")
          Text(proposal.rows.isEmpty ? "Status table update" : "Update to \(proposal.rows.count) rows")
            .font(.caption.bold())
          Text(diffText)
            .font(.caption.monospaced()).lineLimit(12).textSelection(.enabled)
          Button("Show changes") { diffShown = plan.id }
            .buttonStyle(.link).font(.caption)
            .popover(
              isPresented: Binding(get: { diffShown == plan.id }, set: { if !$0 { diffShown = nil } })
            ) {
              ScrollView([.vertical, .horizontal]) {
                Text(diffText)
                  .font(.caption.monospaced()).textSelection(.enabled).fixedSize().padding()
              }
              .frame(width: 640, height: 360)
            }
          // Reject stays available while publishing. A chat whose read or
          // publish fails never reports, and sbd refuses a new update until
          // the proposal goes.
          HStack {
            if proposal.state == .pending {
              Button("Apply") { model.answerArtifact(plan: plan.id, apply: true) }
            } else {
              Text("Publishing").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reject") { model.answerArtifact(plan: plan.id, apply: false) }
          }
          .controlSize(.small)
          .disabled(model.answeringArtifacts.contains(plan.id))
        }
      }
      .padding(.top, 4)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("plan-artifact-\(plan.id)")
    }
  }
}

/// Shows how many group suggestions wait, and opens them in a popover. It
/// draws nothing when there are none.
struct GroupSuggestionButton: View {
  @EnvironmentObject var model: BoardModel
  @State private var showing = false

  /// Such as `2 suggestions`, or nil when there are none.
  static func label(count: Int) -> String? {
    count > 0 ? "\(count) suggestion\(count == 1 ? "" : "s")" : nil
  }

  var body: some View {
    if let label = Self.label(count: model.shownSuggestions.count) {
      Button {
        showing = true
      } label: {
        Label(label, systemImage: "lightbulb")
      }
      .buttonStyle(.link)
      .help("Show the groups that Switchboard suggests")
      .accessibilityLabel("Group suggestions: \(model.shownSuggestions.count)")
      .accessibilityIdentifier("group-suggestions-button")
      .popover(isPresented: $showing, arrowEdge: .bottom) {
        GroupSuggestionList().frame(width: 420)
      }
      // GroupSuggestionButton keeps `showing` after the last suggestion
      // removes this button. Without the reset, the popover would open by
      // itself when the next suggestion arrives.
      .onDisappear { showing = false }
    }
  }
}

/// The group suggestions in the popover, each with Accept and Decline.
struct GroupSuggestionList: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let names = model.sessionNames
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(model.shownSuggestions) { s in
          let action = Triage.capitalized(s.action)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lightbulb").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text("\(action): \(s.sessions.map(names.name).joined(separator: ", "))")
                .fontWeight(.medium)
              // The ids stay in, so that `InlineText` draws each one as a linked name.
              InlineText(plain: [s.reason, s.staying()].compactMap { $0 }.joined(separator: ". "))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Accept") { model.acceptSuggestion(s.id) }
              .accessibilityLabel("Accept: \(action)")
            Button("Decline") { model.declineSuggestion(s.id) }
              .accessibilityLabel("Decline: \(action)")
          }
          .disabled(model.answeringSuggestions.contains(s.id))
          .accessibilityElement(children: .contain)
          .accessibilityLabel(action)
          .accessibilityIdentifier("suggestion-\(s.id)")
        }
      }
      .padding(10)
    }
    .frame(maxHeight: 160)
    .fixedSize(horizontal: false, vertical: true)
  }
}

extension SessionSummary {
  /// The card's line: the session's reason in In progress, where `place`
  /// leaves the line nil because it takes no reason, and wherever the
  /// placement has no line. Elsewhere it is what the card waits on, who
  /// approved it, or the queue's state.
  var boardLine: String { board.flatMap { $0.column == .inProgress ? nil : $0.line } ?? reason }

  /// sbd sets a holder only on Waiting.
  var holderBadge: BoardHolder? { board?.column == .waiting ? board?.holder : nil }

  var backNote: String? { board?.back?.text }

  /// Needs you is not a column, so its card keeps its column and gets an orange edge.
  var hasNeedsYouEdge: Bool { state == .needsYou }

  /// A paused card draws its text at this opacity, so it reads as greyed out.
  var boardCardOpacity: Double { pause == nil ? 1 : 0.45 }

  /// The color of the card's fill and edge. A paused card uses gray in place of its state's color.
  var boardCardTint: Color { pause == nil ? state.color : .gray }
}

extension BoardHolder {
  var badgeTitle: String {
    switch self {
    case .you: "you"
    case .machine: "a machine"
    case .session: "another session"
    }
  }
}

extension View {
  /// Small secondary text on one line in a gray capsule.
  func capsuleBadge() -> some View {
    lineLimit(1)
      .fixedSize()
      .pill(.secondary)
  }
}

/// Who holds a Waiting card, in a capsule.
struct HolderBadge: View {
  let holder: BoardHolder

  var body: some View {
    Text(holder.badgeTitle)
      .capsuleBadge()
      .help("Held by \(holder.badgeTitle)")
      .accessibilityLabel("Held by \(holder.badgeTitle)")
  }
}

struct BoardCard: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.boardGeometry) private var boardGeometry
  let session: SessionSummary
  /// The Board has keyboard focus on this card, so it draws a ring.
  var keyboardFocused = false
  /// The Board has keyboard focus, so a selected card draws the emphasized selection color.
  var boardActive = false
  /// A drag of the card moves it, or the Board selection it belongs to, onto a lane.
  var draggable = false
  /// Gives the Board keyboard focus, so Escape, Return, and Space reach it after a click.
  var activate: () -> Void = {}

  /// A card without a placement shows its state's time instead.
  private var statusLine: String {
    let s = session
    let process = s.waitsToStart ? "not started" : !s.runsClaude ? "docket review" : s.live ? "running" : "stopped"
    let parts = [
      s.board.map { "\($0.column.title) \(ago($0.since))" }, process, s.board == nil ? ago(s.since) : nil,
      s.acknowledged == true ? "acknowledged" : nil, s.requested == true ? "requested" : nil,
    ]
    return parts.compactMap { $0 }.joined(separator: " · ")
  }

  var body: some View {
    let s = session
    let selected = model.multiSelection.contains(s.id)
    let emphasized = selected && boardActive
    ZStack(alignment: .bottomTrailing) {
      Button {
        activate()
        model.clickBoardCard(s.id, BoardClick.current)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            if AttentionState.inbox.contains(s.state) {
              Circle().fill(s.state.color).frame(width: 8, height: 8).help(s.state.title)
            }
            Text(s.name).fontWeight(.medium).lineLimit(1)
            Spacer()
            IssueBadge(session: s, linked: false)
            if let pr = s.pr {
              HStack(spacing: 3) {
                Group {
                  if pr.link != nil {
                    Text(verbatim: pr.numberLabel).hidden()
                      .anchorPreference(key: PRLinkBounds.self, value: .bounds) { $0 }
                  } else {
                    Text(verbatim: pr.numberLabel)
                      .foregroundStyle(pr.status.color)
                      .help(pr.tooltip)
                  }
                }
                .font(.caption.bold())
                if let owners = pr.codeOwners { CodeOwnerShield(status: owners) }
              }
            }
          }
          InlineText(plain: s.boardLine, links: false).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          if let note = s.backNote {
            InlineText(plain: note, links: false).font(.caption2).foregroundStyle(.orange).lineLimit(2)
          }
          CleanupNote(session: s)
          BranchSwitchNote(session: s)
          MergeNote(session: s)
          // A Board column is too narrow for the badge beside the PR number.
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            if s.hasNewReply { NewReplyMark() }
            if let pr = s.pr { QueueBadge(pr: pr) }
            if let holder = s.holderBadge { HolderBadge(holder: holder) }
            if let until = s.snoozedUntil { SnoozeMark(until: until) }
            if let pause = s.pause { PausedBadge(pause: pause) }
            Text(statusLine)
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        .opacity(s.boardCardOpacity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(
              !selected
                ? s.boardCardTint.opacity(0.08)
                : Color(
                  nsColor: emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
            )
        )
        .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(
              s.hasNeedsYouEdge ? AttentionState.needsYou.color : s.boardCardTint.opacity(0.3),
              lineWidth: s.hasNeedsYouEdge ? 2 : 1)
        }
        .overlay {
          if keyboardFocused { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2) }
        }
        // The ring stays clear of the 2 pt Needs-you edge, which a 3 pt outset would touch.
        .highlightRing(s.isHighlighted, cornerRadius: 8, outset: 5)
        .modifier(CardDrag(id: s.id, enabled: draggable))
      }
      .buttonStyle(.plain)
      .hoverCard(
        s, activeAccount: model.activeAccountFolder, card: model.hoverCard, pinned: Snapshot.hoverSession == s.id
      )
      .accessibilityValue(s.state.title)
      .highlightAccessibility(s.isHighlighted)
      .accessibilityAddTraits(selected ? .isSelected : [])
      // VoiceOver's press is not a click, and opens the card as a double click does.
      .accessibilityAction { model.openFromBoard(s.id) }
      .clickAnchor("board-card-\(s.id)")
      .overlayPreferenceValue(PRLinkBounds.self) { bounds in
        if let bounds, let pr = s.pr, let url = pr.link {
          GeometryReader { proxy in
            let rect = proxy[bounds]
            PRLink(text: pr.numberLabel, url: url)
              .font(.caption.bold())
              .foregroundStyle(pr.status.color)
              .help(pr.tooltip)
              .accessibilityValue(pr.status.rawValue)
              .opacity(s.boardCardOpacity)
              .frame(width: rect.width, height: rect.height)
              .offset(x: rect.minX, y: rect.minY)
          }
        }
      }
      // The model republishes only when a session changes, so the timeline
      // shows Nudge once the 4 hours pass on a board where nothing else changes.
      TimelineView(.everyMinute) { _ in
        HStack(spacing: 4) {
          NotesButton(session: s)
          if s.pause != nil { ResumeButton(session: s) }
          if Nudge.shows(s, now: nowMs()) { NudgeButton(session: s) }
          if s.canMerge { MergeButton(session: s) }
          if let base = s.mergeBase { MergeBaseButton(session: s, base: base) }
          if CleanupOffer.canCleanUp(s) { CleanupButton(session: s) }
          if s.isRemovableDone { DeleteButton(session: s) }
        }
        .padding(6)
      }
    }
    .modifier(
      BoardFrameReport(
        record: { boardGeometry?.record(s.id, $0) }, drop: { boardGeometry?.dropFrame(s.id, ifStill: $0) })
    )
    // The ring draws 5 pt outside the card. The column's 8 pt spacing alone would let two rings overlap.
    .padding(.vertical, s.isHighlighted ? 2 : 0)
  }
}
