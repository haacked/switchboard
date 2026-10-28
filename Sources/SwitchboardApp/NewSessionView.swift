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
  }

  @EnvironmentObject var model: BoardModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage("lastFolder") private var folder = NSHomeDirectory()
  @StateObject private var form = Form()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Session").font(.title2.bold())
      SwiftUI.Form {
        HStack {
          TextField("Folder", text: $folder)
          Button("Choose…", action: choose)
        }
        TextField("Branch", text: $form.branch, prompt: Text("optional: makes a worktree of the folder's repo"))
        TextField("Name", text: $form.name, prompt: Text("optional: the branch or folder name"))
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
          start()
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

  private func start() {
    func optional(_ s: String) -> String? {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    model.create(
      NewSession(
        path: folder.expandingTilde, branch: optional(form.branch), name: optional(form.name),
        prompt: optional(form.prompt)))
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
