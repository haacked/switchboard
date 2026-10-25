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
    }
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
        if let s = model.selected {
          SessionView(session: s).id(s.id)
        } else {
          BoardView()
        }
      }
    }
    .toolbar {
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
  }
}

struct Sidebar: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    List(selection: $model.selection) {
      ForEach(AttentionState.allCases, id: \.self) { state in
        let group = model.sessions.filter { $0.state == state }
        if !group.isEmpty {
          Section {
            ForEach(group) { s in SessionRow(session: s).tag(s.id) }
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
      if model.sessions.isEmpty && model.unreachable == nil {
        VStack(spacing: 8) {
          Text("No sessions").font(.headline)
          Button("Start a Session…") { model.showingNew = true }
        }
      }
    }
  }
}

struct SessionRow: View {
  let session: SessionSummary

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(session.state.color)
        .frame(width: 8, height: 8)
        .opacity(session.live ? 1 : 0.35)
        .padding(.top, 5)
        .help(session.live ? "claude is running" : "claude is stopped")
      VStack(alignment: .leading, spacing: 2) {
        HStack {
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
    let columns = AttentionState.allCases.filter { state in model.sessions.contains { $0.state == state } }
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
                VStack(spacing: 8) {
                  ForEach(model.sessions.filter { $0.state == state }) { s in
                    Button {
                      model.selection = s.id
                    } label: {
                      VStack(alignment: .leading, spacing: 4) {
                        Text(s.name).fontWeight(.medium).lineLimit(1)
                        Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Text("\(s.live ? "running" : "stopped") · \(ago(s.since))").font(.caption2).foregroundStyle(
                          .tertiary)
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
