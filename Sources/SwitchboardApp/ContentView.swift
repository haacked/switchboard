import SwiftUI
import SwitchboardCore

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
    Text(state.title)
      .font(.caption.bold())
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(state.color.opacity(0.18)))
      .foregroundStyle(state.color)
  }
}

func ago(_ ms: Int64, now: Int64 = nowMs()) -> String {
  let s = max(0, (now - ms) / 1000)
  if s < 60 { return "\(s)s" }
  if s < 3600 { return "\(s / 60)m" }
  if s < 86400 { return "\(s / 3600)h" }
  return "\(s / 86400)d"
}

struct ContentView: View {
  static let windowMinWidth: CGFloat = 900
  static let sidebarMinWidth: CGFloat = 240

  @EnvironmentObject var model: BoardModel

  private var viewChoice: Binding<MainView?> {
    Binding(
      get: { model.selected == nil ? model.mainView : nil },
      set: { if let view = $0 { model.show(view) } })
  }

  private var isConfirmingDelete: Binding<Bool> {
    Binding(get: { model.confirmingDelete != nil }, set: { if !$0 { model.confirmingDelete = nil } })
  }

  private var confirmingCleanupOffer: CleanupOffer? {
    model.board.first { $0.id == model.confirmingCleanup }.flatMap(CleanupOffer.init)
  }

  private var isShowingDoneRemoval: Binding<Bool> {
    Binding(get: { model.doneRemoval != nil }, set: { if !$0 { model.doneRemoval = nil } })
  }

  private var isConfirmingCleanup: Binding<Bool> {
    Binding(get: { model.confirmingCleanup != nil }, set: { if !$0 { model.confirmingCleanup = nil } })
  }

  var body: some View {
    NavigationSplitView {
      Sidebar()
        .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: 300, max: 420)
    } detail: {
      VStack(spacing: 0) {
        if let problem = model.unreachable {
          ServiceBanner(problem: problem)
        }
        if let error = model.actionError {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).lineLimit(2).textSelection(.enabled)
            Spacer()
            Button("Dismiss") { model.actionError = nil }
          }
          .padding(8)
          .background(.orange.opacity(0.12))
        }
        if let s = model.selected, let f = s.followup, f.started == nil {
          FollowupView(session: s, followup: f).id(s.id)
        } else if let s = model.selected, let d = s.docket {
          DocketView(session: s, docket: d).id(s.id)
        } else if let s = model.selected, let group = s.chat {
          ChatView(session: s, group: group).id(s.id)
        } else if let s = model.selected {
          SessionView(session: s).id(s.id)
        } else {
          switch model.mainView {
          case .inbox: InboxView()
          case .board: BoardView()
          }
        }
      }
      // The delete dialog is on the split view. Two dialogs on one view can hide each other.
      .confirmationDialog(
        confirmingCleanupOffer?.title ?? "Clean up this session?", isPresented: isConfirmingCleanup,
        presenting: confirmingCleanupOffer
      ) { offer in
        Button("Clean Up", role: .destructive) { model.cleanup(offer.session) }
      } message: { offer in
        Text(offer.message)
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) { NavHistoryControls() }
      ToolbarItem(placement: .navigation) {
        // No segment is selected while a session shows.
        Picker("View", selection: viewChoice) {
          Text("Inbox (\(model.triage.count))").tag(MainView?.some(.inbox))
          Text("Board").tag(MainView?.some(.board))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Show the Inbox (⌘1) or the Board (⌘2)")
      }
      ToolbarItem(placement: .navigation) { OrgFilterMenu() }
      ToolbarItem { ManagerButton() }
      ToolbarItem { AccountMenu() }
      ToolbarItem {
        Button {
          model.showingImport = true
        } label: {
          Label("Import Sessions", systemImage: "square.and.arrow.down")
        }
        .help("Import Claude sessions that run outside Switchboard (⇧⌘I)")
      }
      ToolbarItem {
        Button {
          model.showingNew = true
        } label: {
          Label("New Session", systemImage: "plus")
        }
        .help("Start a session (⌘N)")
      }
    }
    .confirmationDialog(
      "Delete \(model.confirmingDelete?.name ?? "this session")?", isPresented: isConfirmingDelete,
      presenting: model.confirmingDelete.map { ($0, TodoDeletion($0)) }
    ) { session, todos in
      Button(todos.button("Delete"), role: .destructive) { model.deleteDone(session, resolve: todos.ids) }
    } message: { session, todos in
      Text(todos.message(before: BoardModel.deletePlan(session).message))
    }
    .sheet(isPresented: $model.showingNew) {
      NewSessionView().environmentObject(model)
    }
    .sheet(isPresented: $model.showingImport) {
      ImportView().environmentObject(model)
    }
    .sheet(isPresented: $model.showingSearch) {
      SessionSearchView().environmentObject(model)
    }
    .sheet(isPresented: isShowingDoneRemoval) {
      if let state = model.doneRemoval { DoneRemovalSheet(state: state).environmentObject(model) }
    }
  }
}

struct Sidebar: View {
  @EnvironmentObject var model: BoardModel
  @FocusState private var focused: Bool

  var body: some View {
    let repos = model.repoLabels
    let activeAccount = model.activeAccountFolder
    List(selection: $model.selection) {
      if !model.managers.isEmpty {
        Section {
          ForEach(model.managers) { manager in
            SessionRow(session: manager, activeAccount: activeAccount, hoverCard: model.hoverCard).tag(manager.id)
          }
        } header: {
          HStack {
            Text("Manager")
            Spacer()
            Button {
              model.openManager(new: true)
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Start a Manager conversation")
            .accessibilityLabel("New Manager conversation")
          }
        }
      }
      ForEach(model.sidebarGroups) { group in
        let state = group.state
        Section(isExpanded: expanded(state)) {
          ForEach(group.rows) { row in
            HStack(spacing: 4) {
              SessionRow(
                session: row.session, activeAccount: activeAccount, repo: repos[row.id], hoverCard: model.hoverCard)
              NotesButton(session: row.session)
              if CleanupOffer.canCleanUp(row.session) { CleanupButton(session: row.session) }
              if row.session.isRemovableDone { DeleteButton(session: row.session) }
            }
            .padding(.leading, CGFloat(row.depth) * 14).tag(row.id)
            .contextMenu {
              if CleanupOffer.canCleanUp(row.session) {
                Button("Clean Up: Delete the Worktree and Branch…") { model.confirmingCleanup = row.id }
                  .disabled(model.cleaningUp.contains(row.id))
              }
              if row.session.isRemovableDone {
                Button("Delete \(BoardModel.deletePlan(row.session).summary)…", role: .destructive) {
                  model.confirmingDelete = row.session
                }
              }
            }
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
    .takesListFocus(.sidebar, $focused, model: model)
    .confirmationDialog(
      accountSwitchTitle, isPresented: isSwitchingAccount, presenting: model.switchingAccount
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
    // A sixth toolbar item pushes New Session into the overflow menu at the minimum window width, so search
    // sits here. It looks like a search field, and the panel holds the real one.
    .safeAreaInset(edge: .top) {
      Button {
        model.showingSearch = true
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
          Text("Search Sessions")
          Spacer(minLength: 4)
          Text("⌘K")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .padding(.top, 4)
      .help("Find a session by name, repo, branch, PR, issue, group, reason, or note (⌘K)")
      .accessibilityLabel("Search Sessions")
      .accessibilityIdentifier("sidebar-search")
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        OrgFilterBar()
        Button {
          model.startNewGroup()
        } label: {
          Label("New Group", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .help("Create an empty group on the Board (⇧⌘G)")
        .accessibilityIdentifier("sidebar-new-group")
      }
    }
    .overlay {
      if model.sidebarIsEmpty {
        VStack(spacing: 8) {
          Text("No sessions").font(.headline)
          Button("Start a Session…") { model.showingNew = true }
          Button("Import Sessions…") { model.showingImport = true }
        }
      }
    }
  }

  private var isSwitchingAccount: Binding<Bool> {
    Binding(get: { model.switchingAccount != nil }, set: { if !$0 { model.switchingAccount = nil } })
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
/// star turns the Needs you color and fills while a conversation needs you,
/// because the Inbox and the Dock badge leave the conversations out.
struct ManagerButton: View {
  @EnvironmentObject var model: BoardModel

  private var waiting: SessionSummary? { model.waitingManager }
  private var needsYou: Bool { waiting != nil }

  private var tooltip: String {
    if let waiting { return "\(waiting.name) needs you: \(waiting.reason) (⇧⌘M)" }
    return model.managers.isEmpty
      ? "Start a session that manages the others through sb (⇧⌘M)" : "Open the latest Manager conversation (⇧⌘M)"
  }

  var body: some View {
    Button {
      model.openManager()
    } label: {
      Label("Manager", systemImage: needsYou ? "star.fill" : "star")
        .foregroundStyle(needsYou ? AttentionState.needsYou.color : .primary)
    }
    .accessibilityValue(needsYou ? AttentionState.needsYou.title : "")
    .help(tooltip)
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
  var hoverCard: HoverCard? = nil
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
          Spacer()
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
          subtitle
        }
        CleanupNote(session: session)
      }
    }
    .padding(.vertical, 2)
    .hoverCard(session, activeAccount: activeAccount, card: hoverCard)
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
  @AppStorage(BoardLanes.storageKey) private var laneKind = BoardLanes.repo
  @FocusState private var focused: Bool
  static let labelWidth: CGFloat = 140
  static let columnWidth: CGFloat = 200

  /// Makes the same moves as a drag, because keyboard and VoiceOver users
  /// can't start a drag. It also offers Ungrouped when the Board hides the
  /// Ungrouped lane.
  private func moveMenu(_ id: String, from current: String?) -> some View {
    Menu("Move to Group") {
      ForEach(model.groups, id: \.id) { g in
        Button(g.name) { model.moveToGroup(id, g.id) }.disabled(g.id == current)
      }
      Divider()
      Button(BoardRows.ungroupedTitle) { model.moveToGroup(id, nil) }.disabled(current == nil)
    }
  }

  var body: some View {
    // The arrow keys' grid and the drawn cards both come from this one value, so they always agree.
    let layout = model.boardLayout(lanes: laneKind)
    cards(layout)
      .onChange(of: layout.grid, initial: true) { model.boardGrid = layout.grid }
  }

  @ViewBuilder
  private func cards(_ layout: BoardLayout) -> some View {
    let ring = focused ? model.currentBoardCard : nil
    // A repo lane has no group, like the Ungrouped lane, so a drop there would ungroup the card.
    let drops = laneKind == .group
    if layout.lanes.isEmpty && layout.done.isEmpty && !(model.namingGroup && laneKind == .group) {
      VStack(spacing: 12) {
        Image(systemName: "square.grid.3x3").font(.system(size: 40)).foregroundStyle(.secondary)
        Text("Start a session to see it here").foregroundStyle(.secondary)
        Button("New Session…") { model.showingNew = true }
        Button("New Group") { model.startNewGroup() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
            Section {
              ForEach(layout.lanes) { lane in
                Divider()
                HStack(alignment: .top, spacing: 12) {
                  LaneLabel(title: lane.title, group: lane.group, count: lane.cells.joined().count)
                    .frame(width: Self.labelWidth, alignment: .leading)
                  ForEach(Array(zip(layout.columns, lane.cells)), id: \.0) { _, stack in
                    VStack(spacing: 8) {
                      ForEach(stack) { s in
                        Group {
                          if drops {
                            BoardCard(session: s, keyboardFocused: s.id == ring).draggable(s.id)
                              .contextMenu { moveMenu(s.id, from: lane.group?.id) }
                          } else {
                            BoardCard(session: s, keyboardFocused: s.id == ring)
                          }
                        }
                        .id(s.id)
                      }
                    }
                    .frame(width: Self.columnWidth, alignment: .top)
                  }
                }
                .modifier(LaneDrop(enabled: drops, group: lane.group?.id))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(lane.title)
                .accessibilityIdentifier("board-row-\(lane.id)")
              }
              DoneFooter(sessions: layout.done)
            } header: {
              HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                  Picker("Lanes", selection: $laneKind) {
                    ForEach(BoardLanes.allCases, id: \.self) { Text($0.title).tag($0) }
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
                  .help("Show a lane per repo or per group")
                  // The header stays pinned, so the name field shows without a scroll.
                  if laneKind == .group { NewGroupRow() }
                  GroupSuggestionButton()
                }
                .frame(width: Self.labelWidth)
                ForEach(layout.columns, id: \.self) { column in
                  Text(column.title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                    .frame(width: Self.columnWidth, alignment: .leading)
                }
              }
              .padding(.vertical, 4)
              .background(.background)
            }
          }
          .padding()
        }
        .defaultScrollAnchor(.topLeading)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
          // SwiftUI offers a key to this handler before a text field inside the Board. The new group's name
          // field and a lane's description field keep their own arrows and Return.
          if NSApp.keyWindow?.firstResponder is NSText { return .ignored }
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
        .onChange(of: model.boardFocus) {
          if let id = model.boardFocus { withAnimation { proxy.scrollTo(id) } }
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
          ids.map { model.moveToGroup($0, group) }.contains(true)
        } isTargeted: {
          targeted = $0
        }
    } else {
      content
    }
  }
}

/// A lane's label column. A group lane also shows the group's description,
/// its chat, and its plans' Follow up rows and pending updates.
private struct LaneLabel: View {
  @EnvironmentObject var model: BoardModel
  let title: String
  let group: GroupSummary?
  let count: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).fontWeight(.semibold).lineLimit(2)
      if let group {
        GroupDescriptionView(group: group)
        GroupAccountMenu(group: group)
      }
      Text(count == 1 ? "1 session" : "\(count) sessions")
        .font(.caption).foregroundStyle(.secondary)
      if let group {
        HStack {
          Button("Chat") { model.openChat(group.id) }
            .buttonStyle(.link).font(.caption)
            .help(
              model.chat(of: group.id) == nil
                ? "Start a chat that manages this group's sessions" : "Open this group's chat")
          Button("Delete") { model.requestDeleteGroup(group) }
            .buttonStyle(.link).font(.caption)
            .help(group.sessions.isEmpty ? "Delete this group" : "Delete this group and move its sessions to Ungrouped")
            .accessibilityLabel("Delete group \(group.name)")
        }
      }
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
          ForEach(inInbox) { s in BoardCard(session: s) }
        }
      }
      // Every Done session is outside the Inbox states, so Delete All has
      // nothing to delete when the collapsed list is empty.
      if !collapsed.isEmpty {
        DisclosureGroup(isExpanded: $expanded) {
          LazyVGrid(columns: Self.grid, spacing: 8) {
            ForEach(collapsed) { s in BoardCard(session: s) }
          }
          .padding(.top, 8)
        } label: {
          HStack {
            Text("Done and merged (\(collapsed.count))").fontWeight(.semibold)
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
    let names = Dictionary(model.allBoard.map { ($0.id, $0.name) }) { first, _ in first }
    let name = { (id: String) in names[id] ?? id }
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(model.shownSuggestions) { s in
          let action = Triage.capitalized(s.action)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lightbulb").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text("\(action): \(s.sessions.map(name).joined(separator: ", "))")
                .fontWeight(.medium)
              Text([s.reason, s.staying(name)].compactMap { $0 }.joined(separator: ". "))
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

/// Who holds a Waiting card, in a capsule.
struct HolderBadge: View {
  let holder: BoardHolder

  var body: some View {
    Text(holder.badgeTitle)
      .font(.caption2.bold())
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.secondary.opacity(0.15)))
      .foregroundStyle(.secondary)
      .help("Held by \(holder.badgeTitle)")
      .accessibilityLabel("Held by \(holder.badgeTitle)")
  }
}

struct BoardCard: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  /// The Board has keyboard focus on this card, so it draws a ring.
  var keyboardFocused = false

  /// A card without a placement shows its state's time instead.
  private var statusLine: String {
    let s = session
    let process = s.waitsToStart ? "not started" : !s.runsClaude ? "docket review" : s.live ? "running" : "stopped"
    let parts = [
      s.board.map { "\($0.column.title) \(ago($0.since))" }, process, s.board == nil ? ago(s.since) : nil,
      s.acknowledged == true ? "acknowledged" : nil,
    ]
    return parts.compactMap { $0 }.joined(separator: " · ")
  }

  var body: some View {
    let s = session
    ZStack(alignment: .bottomTrailing) {
      Button {
        model.openFromBoard(s.id)
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
          Text(s.boardLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          if let note = s.backNote {
            Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(2)
          }
          CleanupNote(session: s)
          MergeNote(session: s)
          // A Board column is too narrow for the badge beside the PR number.
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let pr = s.pr { QueueBadge(pr: pr) }
            if let holder = s.holderBadge { HolderBadge(holder: holder) }
            Text(statusLine)
              .font(.caption2).foregroundStyle(.tertiary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(s.state.color.opacity(0.08)))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(
              s.hasNeedsYouEdge ? AttentionState.needsYou.color : s.state.color.opacity(0.3),
              lineWidth: s.hasNeedsYouEdge ? 2 : 1)
        }
        .overlay {
          if keyboardFocused { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2) }
        }
      }
      .buttonStyle(.plain)
      .hoverCard(
        s, activeAccount: model.activeAccountFolder, card: model.hoverCard, pinned: Snapshot.hoverSession == s.id
      )
      .accessibilityValue(s.state.title)
      .accessibilityAddTraits(keyboardFocused ? .isSelected : [])
      .overlayPreferenceValue(PRLinkBounds.self) { bounds in
        if let bounds, let pr = s.pr, let url = pr.link {
          GeometryReader { proxy in
            let rect = proxy[bounds]
            PRLink(text: pr.numberLabel, url: url)
              .font(.caption.bold())
              .foregroundStyle(pr.status.color)
              .help(pr.tooltip)
              .accessibilityValue(pr.status.rawValue)
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
          if Nudge.shows(s, now: nowMs()) { NudgeButton(session: s) }
          if s.canMerge { MergeButton(session: s) }
          if let base = s.mergeBase { MergeBaseButton(session: s, base: base) }
          if CleanupOffer.canCleanUp(s) { CleanupButton(session: s) }
          if s.isRemovableDone { DeleteButton(session: s) }
        }
        .padding(6)
      }
    }
  }
}
