import AppKit
import SwiftUI
import SwitchboardCore

/// The import sheet: the Claude sessions outside Switchboard, grouped by repo.
/// It lists the sessions in a linked worktree, and a button lists every
/// session. A session that a claude runs now can't be selected, and its row
/// says where it runs. The list reloads when the app becomes active, as it
/// does after the user exits claude in another terminal.
struct ImportView: View {
  /// See SessionViewState for why this isn't `@State`.
  final class Form: ObservableObject {
    @Published var list: ImportList?
    @Published var all = false
    @Published var selected: Set<String> = []
    @Published var error: String?
    /// Why the last import left sessions out, or why it failed.
    @Published var problems: [String] = []
    @Published var busy = false
    /// Closing the sheet doesn't stop an import. Cancel stays disabled until
    /// the import ends.
    @Published var importing = false
  }

  @EnvironmentObject var model: BoardModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var form = Form()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Import Sessions").font(.title2.bold())
        Spacer()
        Button {
          form.problems = []
          load()
        } label: {
          Label("Reload", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r")
        .disabled(form.busy)
      }
      Text(
        "Claude sessions that run outside Switchboard. A session imports once no claude runs it, so exit claude in its terminal or stop its background job first."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      content
      ForEach(form.problems, id: \.self) { problem in
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
      HStack {
        if let list = form.list, form.all || list.hidden > 0 {
          Button(form.all ? "Show Worktree Sessions Only" : "Show All \(list.sessions.count + list.hidden) Sessions") {
            form.all.toggle()
            load()
          }
          .disabled(form.busy)
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(form.importing)
        Button(form.selected.count > 1 ? "Import \(form.selected.count) Sessions" : "Import", action: importSelected)
          .keyboardShortcut(.defaultAction)
          .disabled(form.selected.isEmpty || form.busy)
      }
    }
    .padding(20)
    .frame(width: 760, height: 600)
    .onAppear(perform: load)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      form.problems = []
      load()
    }
  }

  @ViewBuilder private var content: some View {
    if let error = form.error {
      Text("Can't list the sessions: \(error)")
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let list = form.list, list.sessions.isEmpty {
      Text(list.hidden > 0 ? "No Claude sessions in a worktree to import" : "No Claude sessions to import")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if form.list == nil {
      ProgressView("Listing Claude sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List {
        ForEach(form.list?.groups ?? [], id: \.title) { group in
          Section {
            ForEach(group.sessions) { s in
              ImportRow(session: s, selected: selection(s))
            }
          } header: {
            let selectable = group.sessions.filter { !$0.running }.map(\.id)
            let allSelected = !selectable.isEmpty && selectable.allSatisfy(form.selected.contains)
            let label = allSelected ? "Deselect All" : "Select All"
            HStack {
              Text(group.title)
              Spacer()
              Button(label) {
                if allSelected {
                  form.selected.subtract(selectable)
                } else {
                  form.selected.formUnion(selectable)
                }
              }
              .buttonStyle(.link)
              .disabled(selectable.isEmpty)
              .accessibilityLabel("\(label) in \(group.title)")
            }
          }
        }
      }
      .listStyle(.inset(alternatesRowBackgrounds: true))
    }
  }

  private func selection(_ s: ClaudeSession) -> Binding<Bool> {
    Binding(
      get: { form.selected.contains(s.id) },
      set: { on in
        if on { form.selected.insert(s.id) } else { form.selected.remove(s.id) }
      })
  }

  /// Lists the sessions, unless a listing or an import is already running.
  private func load() {
    guard !form.busy else { return }
    let all = form.all
    let model = model
    form.busy = true
    Task {
      let result = await Task.detached { model.importable(all: all) }.value
      form.busy = false
      switch result {
      case .success(let list):
        form.list = list
        form.error = nil
        form.selected.formIntersection(list.sessions.filter { !$0.running }.map(\.id))
      case .failure(let error):
        form.error = "\(error)"
      }
    }
  }

  private func importSelected() {
    let refs = form.list?.sessions.map(\.id).filter(form.selected.contains) ?? []
    let model = model
    form.busy = true
    form.importing = true
    Task {
      let result = await Task.detached { model.importSessions(refs) }.value
      form.busy = false
      form.importing = false
      model.refresh()
      switch result {
      case .success(let r):
        if let first = r.imported.first { model.selection = first.id }
        form.problems = r.refused.map(\.reason)
        if r.refused.isEmpty {
          dismiss()
        } else {
          form.selected = []
          load()
        }
      case .failure(let error):
        form.problems = ["\(error)"]
      }
    }
  }
}

struct ImportRow: View {
  let session: ClaudeSession
  @Binding var selected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Toggle("Import \(session.title)", isOn: $selected)
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(session.running)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(session.title).fontWeight(.medium).lineLimit(1)
          Spacer()
          Text((session.account as NSString).abbreviatingWithTildeInPath)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("\(session.summary) · \((session.cwd as NSString).abbreviatingWithTildeInPath)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if let runs = session.whereItRuns("It") {
          Text(runs).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
      }
    }
    .padding(.vertical, 2)
    .opacity(session.running ? 0.75 : 1)
    .contentShape(Rectangle())
    .onTapGesture { if !session.running { selected.toggle() } }
  }
}
