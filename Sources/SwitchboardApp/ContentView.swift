import SwiftUI
import SwitchboardCore

extension AttentionState {
  var color: Color {
    switch self {
    case .needsYou: .orange
    case .canContinue: .blue
    case .waiting: .purple
    case .working: .green
    case .done: .gray
    case .stale: .brown
    case .notStarted: .teal
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

  private var viewChoice: Binding<Bool?> {
    Binding(
      get: { model.selection == nil ? model.showingBoard : nil },
      set: { if let board = $0 { model.show(board: board) } })
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
        } else if let s = model.selected {
          SessionView(session: s).id(s.id)
        } else {
          if model.showingBoard { BoardView() } else { QueueView() }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        // No segment is selected while a session shows.
        Picker("View", selection: viewChoice) {
          Text("Queue (\(model.triage.count))").tag(Bool?.some(false))
          Text("Board").tag(Bool?.some(true))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Show the Queue (⌘1) or the Board (⌘2)")
      }
      ToolbarItem {
        if let active = model.accounts.first(where: \.active), model.accounts.count > 1 {
          Menu {
            ForEach(model.accounts) { account in
              Button {
                model.useAccount(account.folder)
              } label: {
                Text("\(account.name) (\(account.sessions))")
                if account.active { Image(systemName: "checkmark") }
              }
            }
          } label: {
            Label(active.name, systemImage: "person.crop.circle")
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
    .sheet(isPresented: $model.showingNew) {
      NewSessionView().environmentObject(model)
    }
    .sheet(isPresented: $model.showingImport) {
      ImportView().environmentObject(model)
    }
  }
}

struct Sidebar: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    List(selection: $model.selection) {
      ManagerSection()
      ForEach(AttentionState.allCases, id: \.self) { state in
        let group = model.board.filter { $0.state == state && $0.manager != true }
        if !group.isEmpty {
          Section(isExpanded: expanded(state)) {
            ForEach(SessionTree.rows(group)) { row in
              SessionRow(session: row.session).padding(.leading, CGFloat(row.depth) * 14).tag(row.id)
            }
          } header: {
            HStack {
              Text(state.title)
              Spacer()
              Text("\(group.count)").foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .overlay {
      if model.board.isEmpty && model.unreachable == nil {
        VStack(spacing: 8) {
          Text("No sessions").font(.headline)
          Button("Start a Session…") { model.showingNew = true }
          Button("Import Sessions…") { model.showingImport = true }
        }
      }
    }
  }

  private func expanded(_ state: AttentionState) -> Binding<Bool> {
    Binding(
      get: { !model.collapsed.contains(state) },
      set: { if $0 { model.collapsed.remove(state) } else { model.collapsed.insert(state) } })
  }
}

/// The pinned Manager and the sessions it started, each under its parent.
struct ManagerSection: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Section {
      if model.manager == nil {
        Button {
          model.openManager()
        } label: {
          Label("Start the Manager", systemImage: "star")
        }
        .buttonStyle(.plain)
        .help("Start a session that manages the others through sb")
      }
      ForEach(model.managerTree) { row in
        SessionRow(session: row.session, pinned: row.depth == 0)
          .padding(.leading, CGFloat(row.depth) * 14)
          .tag(row.id)
      }
    } header: {
      Text("Manager")
    }
  }
}

struct SessionRow: View {
  let session: SessionSummary
  var pinned = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(session.state.color)
        .frame(width: 8, height: 8)
        .opacity(session.live ? 1 : 0.35)
        .padding(.top, 5)
        .help(session.waitsToStart ? "not started" : session.live ? "claude is running" : "claude is stopped")
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          if pinned { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small) }
          Text(session.name).fontWeight(.medium).lineLimit(1)
          Spacer()
          Text(ago(session.since)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        Text(session.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(.vertical, 2)
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

/// The board: one column per state that has sessions, with a card for each.
struct BoardView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let columns = AttentionState.allCases.filter { state in model.board.contains { $0.state == state } }
    if columns.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "square.grid.3x3").font(.system(size: 40)).foregroundStyle(.secondary)
        Text("Start a session to see it here").foregroundStyle(.secondary)
        Button("New Session…") { model.showingNew = true }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(columns, id: \.self) { state in
            VStack(alignment: .leading, spacing: 8) {
              Text(state.title.uppercased()).font(.caption.bold()).foregroundStyle(state.color)
              ScrollView {
                LazyVStack(spacing: 8) {
                  ForEach(model.board.filter { $0.state == state }) { s in
                    Button {
                      model.selection = s.id
                    } label: {
                      VStack(alignment: .leading, spacing: 4) {
                        Text(s.name).fontWeight(.medium).lineLimit(1)
                        Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Text("\(s.waitsToStart ? "not started" : s.live ? "running" : "stopped") · \(ago(s.since))")
                          .font(.caption2).foregroundStyle(.tertiary)
                      }
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .padding(10)
                      .background(RoundedRectangle(cornerRadius: 8).fill(state.color.opacity(0.08)))
                      .overlay(RoundedRectangle(cornerRadius: 8).stroke(state.color.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
            }
            .frame(width: 240)
          }
        }
        .padding()
      }
    }
  }
}
