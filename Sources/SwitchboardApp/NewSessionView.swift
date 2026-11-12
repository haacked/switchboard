import AppKit
import SwiftUI
import SwitchboardCore

/// One opening of the New Session sheet. Each opening has a new id, so the sheet starts from a new form.
struct NewSessionRequest: Identifiable, Equatable {
  let id = UUID()
  /// The id of the group that the sheet starts with.
  var group: String?
}

/// The new session sheet: a repository, a branch for a new worktree, and an optional first prompt.
struct NewSessionView: View {
  /// See SessionViewState for why this isn't `@State`.
  final class Form: ObservableObject {
    @Published private(set) var repo: KnownRepo?
    /// The user chose `repo`, so a newer list does not replace it.
    private(set) var picked = false
    @Published var branch = ""
    @Published var name = ""
    @Published var prompt = ""
    /// The folder of the chosen account, or empty for the active one.
    @Published var account = ""
    /// The id of the group that the session joins, or nil for none.
    @Published var group: String?

    init(group: String? = nil) {
      self.group = group
    }

    func pick(_ repo: KnownRepo?) {
      self.repo = repo
      picked = true
    }

    /// Selects the most recently used repository of `repos` until the user picks one. The sheet first
    /// offers the list that the app kept from its last opening, then the list that sbd answers.
    func offer(_ repos: [KnownRepo]?) {
      if !picked { repo = repos?.first }
    }

    /// What Start sends, or nil before a repository is chosen. The branch goes only with a worktree.
    func request(worktree: Bool) -> NewSession? {
      guard let repo else { return nil }
      func optional(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
      }
      return NewSession(
        path: repo.path, branch: worktree ? optional(branch) : nil, name: optional(name), worktree: worktree,
        prompt: optional(prompt), account: optional(account), group: group)
    }
  }

  @EnvironmentObject var model: BoardModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage("createWorktree") private var createWorktree = false
  @StateObject private var form: Form

  init(request: NewSessionRequest) {
    _form = StateObject(wrappedValue: Form(group: request.group))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Session").font(.title2.bold())
      SwiftUI.Form {
        LabeledContent("Repository") {
          RepoPicker(selection: Binding(get: { form.repo }, set: { form.pick($0) }))
        }
        Toggle("Create a worktree", isOn: $createWorktree)
          .help("Start in a new worktree of the repository")
        if createWorktree {
          TextField("Branch", text: $form.branch, prompt: Text("optional: made from the name when blank"))
        }
        TextField("Name", text: $form.name, prompt: Text("optional: the branch or folder name"))
        if model.accounts.count > 1 {
          Picker("Account", selection: $form.account) {
            Text("Active (\(model.activeAccount?.name ?? "default"))").tag("")
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
          start()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(form.repo == nil)
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      form.offer(model.knownRepos)
      model.loadRepos()
    }
    .onChange(of: model.knownRepos) { form.offer(model.knownRepos) }
  }

  private func start() {
    if let session = form.request(worktree: createWorktree) { model.create(session) }
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
