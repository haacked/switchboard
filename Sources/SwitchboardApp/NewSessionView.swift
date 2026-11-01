import AppKit
import SwiftUI
import SwitchboardCore

/// The new session sheet: a folder, or a repo and a branch for a new
/// worktree, and an optional first prompt.
struct NewSessionView: View {
  /// See SessionViewState for why this isn't `@State`.
  final class Form: ObservableObject {
    @Published var branch = ""
    @Published var name = ""
    @Published var prompt = ""
    /// The folder of the chosen account, or empty for the active one.
    @Published var account = ""
  }

  @EnvironmentObject var model: BoardModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage("lastFolder") private var folder = NSHomeDirectory()
  @AppStorage("createWorktree") private var createWorktree = false
  @StateObject private var form = Form()

  /// Whether the folder or one of its parents holds a `.git`.
  private var folderIsRepo: Bool {
    var url = URL(fileURLWithPath: folder.expandingTilde).standardizedFileURL
    while url.path != "/" {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
      url.deleteLastPathComponent()
    }
    return false
  }

  var body: some View {
    let isRepo = folderIsRepo
    let makesWorktree = createWorktree && isRepo
    return VStack(alignment: .leading, spacing: 12) {
      Text("New Session").font(.title2.bold())
      SwiftUI.Form {
        HStack {
          TextField("Folder", text: $folder)
          Button("Choose…", action: choose)
        }
        Toggle("Create a worktree", isOn: Binding(get: { makesWorktree }, set: { createWorktree = $0 }))
          .disabled(!isRepo)
          .help(isRepo ? "Start in a new worktree of the folder's repo" : "The folder isn't in a git repo")
        if makesWorktree {
          TextField("Branch", text: $form.branch, prompt: Text("optional: made from the name when blank"))
        }
        TextField("Name", text: $form.name, prompt: Text("optional: the branch or folder name"))
        if model.accounts.count > 1 {
          Picker("Account", selection: $form.account) {
            Text("Active (\(model.accounts.first(where: \.active)?.name ?? "default"))").tag("")
            ForEach(model.accounts) { Text($0.name).tag($0.folder) }
          }
        }
        VStack(alignment: .leading) {
          Text("First prompt")
          TextEditor(text: $form.prompt)
            .font(.body.monospaced())
            .frame(minHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Start") {
          start(worktree: makesWorktree)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(folder.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  private func choose() {
    if let path = chooseFolder(at: folder) { folder = path }
  }

  private func start(worktree: Bool) {
    func optional(_ s: String) -> String? {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    model.create(
      NewSession(
        path: folder.expandingTilde, branch: worktree ? optional(form.branch) : nil, name: optional(form.name),
        worktree: worktree,
        prompt: optional(form.prompt), account: optional(form.account)))
  }
}

/// Asks for a folder, or returns nil when the user cancels.
func chooseFolder(message: String? = nil, at start: String? = nil) -> String? {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  if let message { panel.message = message }
  if let start { panel.directoryURL = URL(fileURLWithPath: start.expandingTilde) }
  return panel.runModal() == .OK ? panel.url?.path : nil
}
