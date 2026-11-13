import AppKit
import SwiftUI
import SwitchboardCore

/// One opening of the New Session sheet. Each opening has a new id, so the sheet starts from a new form.
struct NewSessionRequest: Identifiable {
  let id = UUID()
  /// The id of the group that the sheet starts with.
  var group: String?
  /// The owner/name of the repository that the sheet starts with, as the Issues view's Edit the Prompt First sets it.
  var repo: String?
  var branch: String?
  var prompt: String?
  /// The issue that the session works on.
  var issue: IssueRef?
}

/// The new session sheet: a repository, a branch for a new worktree, and an optional first prompt.
struct NewSessionView: View {
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
    @Published private(set) var group: String?
    /// The owner/name that the sheet starts with, which wins over the group's preferred repository.
    private let repoName: String?
    /// The issue that the session works on.
    let issue: IssueRef?
    /// The last offer, which a group change selects from again.
    private var offered: (repos: [KnownRepo]?, sessions: [SessionSummary]) = (nil, [])

    convenience init(group: String? = nil) {
      self.init(NewSessionRequest(group: group))
    }

    init(_ request: NewSessionRequest) {
      group = request.group
      repoName = request.repo
      issue = request.issue
      branch = request.branch ?? ""
      prompt = request.prompt ?? ""
    }

    func pick(_ repo: KnownRepo?) {
      self.repo = repo
      picked = true
    }

    /// Selects the repository that `KnownRepos.preferred` names for the group until the user picks one. The
    /// sheet first offers the list that the app kept from its last opening, then the list that sbd answers.
    func offer(_ repos: [KnownRepo]?, sessions: [SessionSummary] = []) {
      offered = (repos, sessions)
      guard !picked else { return }
      let named = repoName.flatMap { name in repos?.first { $0.name.lowercased() == name.lowercased() } }
      repo = named ?? repos.flatMap { KnownRepos.preferred($0, group: group, sessions: sessions) }
    }

    func choose(group: String?) {
      self.group = group
      offer(offered.repos, sessions: offered.sessions)
    }

    /// The account folder of the chosen group, or nil when it names none.
    func groupAccount(_ groups: [GroupSummary]) -> String? {
      groups.first { $0.id == group }?.account
    }

    /// What Start sends, or nil before a repository is chosen. The branch goes only with a worktree. A group
    /// with an account gets no account, because sbd refuses one that differs from the group's.
    func request(worktree: Bool, groups: [GroupSummary]) -> NewSession? {
      guard let repo else { return nil }
      func optional(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
      }
      return NewSession(
        path: repo.path, branch: worktree ? optional(branch) : nil, name: optional(name), worktree: worktree,
        prompt: optional(prompt), account: groupAccount(groups) == nil ? optional(account) : nil, group: group,
        issue: issue)
    }
  }

  @EnvironmentObject var model: BoardModel
  @Environment(\.dismiss) private var dismiss
  /// The user's last choice of the toggle, which a later sheet starts from.
  @AppStorage("createWorktree") private var createWorktree = false
  @StateObject private var form: Form
  /// This sheet's toggle. A request that names a branch starts with it on and leaves the saved choice alone.
  @State private var worktree: Bool

  init(request: NewSessionRequest) {
    _form = StateObject(wrappedValue: Form(request))
    _worktree = State(initialValue: request.branch != nil || UserDefaults.standard.bool(forKey: "createWorktree"))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Session").font(.title2.bold())
      SwiftUI.Form {
        LabeledContent("Repository") {
          RepoPicker(selection: Binding(get: { form.repo }, set: { form.pick($0) }))
        }
        Toggle(
          "Create a worktree",
          isOn: Binding(
            get: { worktree },
            set: {
              worktree = $0
              createWorktree = $0
            })
        )
        .help("Start in a new worktree of the repository")
        if worktree {
          TextField("Branch", text: $form.branch, prompt: Text("optional: made from the name when blank"))
        }
        TextField("Name", text: $form.name, prompt: Text("optional: the branch or folder name"))
        if !model.groups.isEmpty || form.group != nil {
          Picker("Group", selection: Binding(get: { form.group }, set: { form.choose(group: $0) })) {
            Text("None").tag(String?.none)
            ForEach(model.groups) { Text($0.name).tag(Optional($0.id)) }
          }
        }
        if let account = form.groupAccount(model.groups) {
          Text(GroupAccountMenu.label(account, accounts: model.accounts, usage: model.usage))
            .help("This group runs its sessions under this account")
        } else if model.accounts.count > 1 {
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
      form.offer(model.knownRepos, sessions: model.allSessions)
      model.loadRepos()
    }
    .onChange(of: model.knownRepos) { form.offer(model.knownRepos, sessions: model.allSessions) }
  }

  private func start() {
    if let session = form.request(worktree: worktree, groups: model.groups) { model.create(session) }
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
