import SwiftUI
import SwitchboardCore

extension AttentionState {
  var color: Color {
    switch self {
    case .needsYou: .orange
    case .readyToMerge: .mint
    case .canContinue: .blue
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

func ago(_ ms: Int64) -> String {
  let s = max(0, (nowMs() - ms) / 1000)
  if s < 60 { return "\(s)s" }
  if s < 3600 { return "\(s / 60)m" }
  if s < 86400 { return "\(s / 3600)h" }
  return "\(s / 86400)d"
}

struct ContentView: View {
  @EnvironmentObject var model: BoardModel

  private var viewChoice: Binding<MainView?> {
    Binding(
      get: { model.selected == nil ? model.mainView : nil },
      set: { if let view = $0 { model.show(view) } })
  }

  private var confirmingDeleteSession: SessionSummary? { model.board.first { $0.id == model.confirmingDelete } }

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
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
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
      ToolbarItem { ManagerButton() }
      ToolbarItem { UsageMenu() }
      ToolbarItem {
        if let active = model.accounts.first(where: \.active), model.accounts.count > 1 {
          Menu {
            Picker("Account", selection: Binding(get: { active.folder }, set: model.useAccount)) {
              ForEach(model.accounts) { account in
                Text("\(account.name) (\(account.sessions))").tag(account.folder)
              }
            }
            .pickerStyle(.inline)
          } label: {
            Label("Account: \(active.name)", systemImage: "person.crop.circle")
              .labelStyle(.titleAndIcon)
          }
          .help("The Claude account for new sessions without a parent. Spawned sessions use their parent's.")
        }
      }
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
      "Delete \(confirmingDeleteSession?.name ?? "this session")?", isPresented: isConfirmingDelete,
      presenting: confirmingDeleteSession
    ) { session in
      Button("Delete", role: .destructive) { model.deleteDone(session) }
    } message: { session in
      Text(BoardModel.deletePlan(session).message)
    }
    .sheet(isPresented: $model.showingNew) {
      NewSessionView().environmentObject(model)
    }
    .sheet(isPresented: $model.showingImport) {
      ImportView().environmentObject(model)
    }
    .sheet(isPresented: isShowingDoneRemoval) {
      if let state = model.doneRemoval { DoneRemovalSheet(state: state).environmentObject(model) }
    }
  }
}

struct Sidebar: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let repos = model.repoLabels
    List(selection: $model.selection) {
      if let manager = model.manager {
        Section {
          SessionRow(session: manager).tag(manager.id)
        } header: {
          Text("Manager")
        }
      }
      ForEach(model.sidebarGroups) { group in
        let state = group.state
        Section(isExpanded: expanded(state)) {
          ForEach(group.rows) { row in
            HStack(spacing: 4) {
              SessionRow(session: row.session, repo: repos[row.id])
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
                  model.confirmingDelete = row.id
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
    .confirmationDialog(
      "Switch to \(model.switchingAccount?.name ?? "this account")?", isPresented: isSwitchingAccount,
      presenting: model.switchingAccount
    ) { change in
      Button("New Sessions Only") { model.confirmAccountSwitch(change, move: false) }
      if !change.plan.moved.isEmpty {
        let n = change.plan.moved.count
        Button("Also Move \(n) Existing Session\(n == 1 ? "" : "s")") { model.confirmAccountSwitch(change, move: true) }
      }
    } message: { change in
      Text(accountSwitchMessage(change))
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

  private func accountSwitchMessage(_ change: AccountSwitch) -> String {
    var lines = ["New sessions use \(change.name) either way."]
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
      model.confirmingDelete = session.id
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

/// Opens the Manager, or starts it. The star turns the Needs you color and
/// fills while the Manager needs you, because the Inbox and the Dock badge
/// leave it out.
struct ManagerButton: View {
  @EnvironmentObject var model: BoardModel

  private var needsYou: Bool { model.manager?.state == .needsYou }

  private var tooltip: String {
    guard let manager = model.manager else { return "Start a session that manages the others through sb (⇧⌘M)" }
    return needsYou ? "The Manager needs you: \(manager.reason) (⇧⌘M)" : "Open the Manager (⇧⌘M)"
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
  var tooltip: String { "\(status.rawValue) · \(repo): \(title)" }
}

struct SessionRow: View {
  let session: SessionSummary
  var repo: String? = nil
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
          if let pr = session.pr, let url = pr.link {
            Link(destination: url) { Text(verbatim: "#\(pr.number)") }
              .font(.caption)
              .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(pr.status.color))
              .help(pr.tooltip)
              .accessibilityValue(pr.status.rawValue)
          }
          Text(ago(session.since)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        subtitle
        CleanupNote(session: session)
      }
    }
    .padding(.vertical, 2)
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

/// The board: a row per group, with Ungrouped last, and a column per state
/// that has sessions. Each session is a card in its group's row.
struct BoardView: View {
  @EnvironmentObject var model: BoardModel
  static let labelWidth: CGFloat = 140
  static let columnWidth: CGFloat = 240

  var body: some View {
    let board = model.workBoard
    let columns = AttentionState.allCases.filter { state in board.contains { $0.state == state } }
    if columns.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "square.grid.3x3").font(.system(size: 40)).foregroundStyle(.secondary)
        Text("Start a session to see it here").foregroundStyle(.secondary)
        Button("New Session…") { model.showingNew = true }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
          Section {
            ForEach(BoardRows.make(sessions: board, groups: model.groups)) { row in
              Divider()
              HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(row.title).fontWeight(.semibold).lineLimit(2)
                  Text(row.sessions.count == 1 ? "1 session" : "\(row.sessions.count) sessions")
                    .font(.caption).foregroundStyle(.secondary)
                  if let group = row.group {
                    Button("Chat") { model.openChat(group) }
                      .buttonStyle(.link).font(.caption)
                      .help(
                        model.chat(of: group) == nil
                          ? "Start a chat that manages this group's sessions" : "Open this group's chat")
                  }
                  let plans = model.groups.first { $0.id == row.group }?.plans ?? []
                  PlanFollowupList(plans: plans)
                  PlanArtifactList(plans: plans)
                }
                .frame(width: Self.labelWidth, alignment: .leading)
                ForEach(columns, id: \.self) { state in
                  VStack(spacing: 8) {
                    ForEach(row.sessions.filter { $0.state == state }) { s in BoardCard(session: s) }
                  }
                  .frame(width: Self.columnWidth, alignment: .top)
                }
              }
              .accessibilityElement(children: .contain)
              .accessibilityLabel(row.title)
              .accessibilityIdentifier("board-row-\(row.id)")
            }
          } header: {
            HStack(alignment: .top, spacing: 12) {
              Spacer().frame(width: Self.labelWidth)
              ForEach(columns, id: \.self) { state in
                HStack {
                  Text(state.title.uppercased()).font(.caption.bold()).foregroundStyle(state.color)
                  Spacer()
                  if state == .done { DeleteAllDoneButton() }
                }
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
      .safeAreaInset(edge: .top, spacing: 0) {
        if !model.suggestions.isEmpty {
          VStack(spacing: 0) {
            GroupSuggestionList()
            Divider()
          }
          .background(.background)
        }
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

/// The group suggestions above the board, each with Accept and Decline.
struct GroupSuggestionList: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let names = Dictionary(model.board.map { ($0.id, $0.name) }) { first, _ in first }
    let name = { (id: String) in names[id] ?? id }
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(model.suggestions) { s in
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

struct BoardCard: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    let s = session
    ZStack(alignment: .bottomTrailing) {
      Button {
        model.openFromBoard(s.id)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(s.name).fontWeight(.medium).lineLimit(1)
            Spacer()
            if let pr = s.pr {
              Text(verbatim: "#\(pr.number)")
                .font(.caption.bold())
                .foregroundStyle(pr.status.color)
                .help(pr.tooltip)
            }
          }
          Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
          CleanupNote(session: s)
          MergeNote(session: s)
          Text(
            "\(s.waitsToStart ? "not started" : !s.runsClaude ? "docket review" : s.live ? "running" : "stopped") · \(ago(s.since))\(s.acknowledged == true ? " · acknowledged" : "")"
          )
          .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(s.state.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(s.state.color.opacity(0.3)))
      }
      .buttonStyle(.plain)
      .accessibilityValue(s.state.title)
      HStack(spacing: 4) {
        if s.state == .readyToMerge { MergeButton(session: s) }
        if CleanupOffer.canCleanUp(s) { CleanupButton(session: s) }
        if s.isRemovableDone { DeleteButton(session: s) }
      }
      .padding(6)
    }
  }
}
