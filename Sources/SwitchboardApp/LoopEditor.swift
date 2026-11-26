import SwiftUI
import SwitchboardCore

/// What the loop editor sheet opens for: a new loop, or the loop with this schedule id.
enum LoopEditorRequest: Equatable, Sendable {
  case new
  case edit(String)
}

/// The New Loop… and Edit… sheet: a session and how the loop runs (new loops only), an interval, and a prompt or a
/// command. A headless loop also takes an account and a model, and a headless or script loop takes a timeout.
struct LoopEditor: View {
  /// A session that a new loop can run on.
  struct Choice: Equatable {
    /// The session id, or `Manager.operatorName` when there is no operator yet. sbd's `schedule` creates the
    /// operator for that name.
    let session: String
    let name: String
  }

  /// The sheet's fields, and what Save sends.
  struct Form {
    /// The loop being edited, or nil for a new loop.
    let original: Schedule?
    /// The chosen session id. It is nil for an edit, which can't move a loop to another session.
    var session: String?
    /// How the loop runs. An edit keeps its loop's runner, whatever is set here.
    var runner: Schedule.Runner {
      get { original?.runsAs ?? newRunner }
      set { newRunner = newValue }
    }
    /// A new loop's choice of runner.
    private var newRunner: Schedule.Runner
    var interval: String
    var prompt: String
    /// A script's command.
    var command: String
    /// A headless loop's account by name, or empty for the session's.
    var account: String
    /// A headless loop's model, or empty for the session's.
    var model: String
    /// A headless or script loop's timeout, or empty for the default.
    var timeout: String

    init(new choices: [Choice]) {
      original = nil
      session = choices.first?.session
      newRunner = .session
      interval = ""
      prompt = ""
      command = ""
      account = ""
      model = ""
      timeout = ""
    }

    init(editing schedule: Schedule) {
      original = schedule
      session = nil
      newRunner = schedule.runsAs
      interval = Schedule.intervalText(schedule.every)
      prompt = schedule.runsAs == .script ? "" : schedule.prompt
      command = schedule.runsAs == .script ? schedule.prompt : ""
      account = schedule.account.map(Account.name(ofFolder:)) ?? ""
      model = schedule.model ?? ""
      timeout = schedule.timeout.map(Schedule.intervalText) ?? ""
    }

    private var trimmedInterval: String { interval.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedInterval: Result<Int64, any Error> { Result { try Schedule.parseInterval(trimmedInterval) } }
    private var intervalMs: Int64? { try? parsedInterval.get() }
    /// The prompt or command that sbd stores, or nil when sbd refuses it.
    private var cleanText: String? { try? Schedule.cleanPrompt(runner == .script ? command : prompt, runner: runner) }
    private var trimmedAccount: String { account.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTimeout: String { timeout.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedTimeout: Result<Int64, any Error> { Result { try Schedule.parseTimeout(trimmedTimeout) } }

    /// Why the interval can't be read, or nil while it is readable or empty.
    var intervalError: String? {
      guard !trimmedInterval.isEmpty, case .failure(let error) = parsedInterval else { return nil }
      return "\(error)"
    }

    /// Why sbd would refuse the timeout: it can't be read, it is out of range, or it is longer than the interval. An
    /// empty field keeps the edited loop's timeout, or the default. A loop that runs in the session has none.
    var timeoutError: String? {
      guard runner != .session else { return nil }
      let ms: Int64?
      if trimmedTimeout.isEmpty {
        ms = original?.timeout
      } else {
        switch parsedTimeout {
        case .success(let parsed): ms = parsed
        case .failure(let error): return "\(error)"
        }
      }
      guard let ms, let every = intervalMs else { return nil }
      return Schedule.timeoutProblem(ms, every: every)
    }

    /// Why sbd would refuse a headless loop's model, because the model lands in claude's argv.
    var modelError: String? {
      guard runner == .headless, !trimmedModel.isEmpty else { return nil }
      do {
        _ = try Schedule.cleanModel(trimmedModel)
        return nil
      } catch {
        return "\(error)"
      }
    }

    /// The trimmed interval to send, or nil when it doesn't parse or has the edited loop's length.
    var changedInterval: String? {
      guard let ms = intervalMs, ms != original?.every else { return nil }
      return trimmedInterval
    }

    /// The clean prompt to send, or nil for a script, when sbd refuses it, or when it is the edited loop's prompt.
    var changedPrompt: String? {
      guard runner != .script, let text = cleanText, text != original?.prompt else { return nil }
      return text
    }

    /// The clean command to send as the prompt, or nil for a loop that is not a script, when sbd refuses it, or when
    /// it is the edited loop's command.
    var changedCommand: String? {
      guard runner == .script, let text = cleanText, text != original?.prompt else { return nil }
      return text
    }

    /// A headless loop's trimmed timeout or script's, or nil when it is empty, unreadable, or the edited loop's.
    var changedTimeout: String? {
      guard runner != .session, !trimmedTimeout.isEmpty, let ms = try? parsedTimeout.get(), ms != original?.timeout
      else { return nil }
      return trimmedTimeout
    }

    /// A headless loop's account name to send, or nil when it is the edited loop's. An edit sends an empty name to
    /// reset the account to the session's, and a new loop sends nothing for it.
    var changedAccount: String? {
      guard runner == .headless else { return nil }
      return changed(trimmedAccount, from: original?.account.map(Account.name(ofFolder:)))
    }

    /// A headless loop's model to send, as `changedAccount` decides.
    var changedModel: String? {
      guard runner == .headless else { return nil }
      return changed(trimmedModel, from: original?.model)
    }

    private func changed(_ value: String, from stored: String?) -> String? {
      if original == nil { return value.isEmpty ? nil : value }
      return value == (stored ?? "") ? nil : value
    }

    var canSave: Bool {
      guard intervalMs != nil, cleanText != nil, timeoutError == nil, modelError == nil else { return false }
      if original == nil { return session != nil }
      return changedInterval != nil || changedPrompt != nil || changedCommand != nil || changedTimeout != nil
        || changedAccount != nil || changedModel != nil
    }
  }

  /// The models that the model field suggests. Any other model name works too.
  static let modelSuggestions = ["sonnet", "opus", "haiku"]

  /// The accounts that a headless loop can run on, the session's first. A headless run starts claude, so a Codex
  /// account is left out.
  static func accountChoices(_ accounts: [AccountInfo], sessionFolder: String?) -> [AccountInfo] {
    let claude = accounts.filter { $0.agent == .claude }
    return claude.filter { $0.folder == sessionFolder } + claude.filter { $0.folder != sessionFolder }
  }

  /// The sessions that a new loop can run on: the operator first, then the Manager conversations, the group chats,
  /// and the work sessions, each by name. A session with no folder is left out, because sbd's `schedule` refuses
  /// it. With no operator, the first choice is `Manager.operatorName`.
  static func sessionChoices(_ sessions: [SessionSummary], operatorID: String?) -> [Choice] {
    let first =
      sessions.first { $0.id == operatorID }.map { Choice(session: $0.id, name: $0.nameWithHost) }
      ?? Choice(session: Manager.operatorName, name: Manager.operatorName)
    func rank(_ kind: SessionKind) -> Int {
      switch kind {
      case .operator: 0
      case .manager: 1
      case .chat: 2
      case .work: 3
      }
    }
    let rest =
      sessions
      .filter { !$0.cwd.isEmpty && $0.id != first.session && $0.kind != .operator }
      .sorted { a, b in
        rank(a.kind) != rank(b.kind) ? rank(a.kind) < rank(b.kind) : BoardModel.byName(a, b)
      }
    return [first] + rest.map { Choice(session: $0.id, name: $0.nameWithHost) }
  }

  @EnvironmentObject var model: BoardModel
  private let editing: Bool
  /// The choices are fixed when the sheet opens, so a newer `ls` answer can't take away the picked session.
  @State private var choices: [Choice]
  @State private var form: Form

  /// `schedule` is the loop that an edit opens with. It is nil for a new loop, and for an edit whose loop is gone.
  init(request: LoopEditorRequest, schedule: Schedule?, choices: [Choice]) {
    editing = request != .new
    _choices = State(initialValue: choices)
    _form = State(initialValue: schedule.map { Form(editing: $0) } ?? Form(new: choices))
  }

  /// The loop that the edit names no longer exists.
  private var missing: Bool { editing && form.original == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(editing ? "Edit Loop" : "New Loop").font(.title2.bold())
      if missing {
        Text("This loop no longer exists.").foregroundStyle(.secondary)
      } else {
        fields
      }
      if let error = model.loopEditorError {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.loopEditor = nil }
          .keyboardShortcut(.cancelAction)
          .clickAnchor("loop-editor-cancel")
        if !missing {
          Button("Save") { save() }
            .keyboardShortcut(.defaultAction)
            .disabled(!form.canSave || model.savingLoop)
        }
      }
    }
    .padding(20)
    .frame(width: 480)
    .announcesRefusal(model.loopEditorError)
  }

  private var fields: some View {
    SwiftUI.Form {
      if !editing {
        Picker("Session", selection: $form.session) {
          ForEach(choices, id: \.session) { Text($0.name).tag(Optional($0.session)) }
        }
        .help("The session that the loop belongs to")
        runnerChoice
      } else {
        LabeledContent("Runs", value: Self.runnerTitle(form.runner))
      }
      VStack(alignment: .leading, spacing: 2) {
        TextField("Every", text: $form.interval, prompt: Text("30m"))
          .help("One number and one unit, such as 30m, 2h, or 1d. The shortest is 1m.")
        if let error = form.intervalError { errorText(error) }
      }
      if form.runner == .headless { headlessFields }
      if form.runner != .session {
        VStack(alignment: .leading, spacing: 2) {
          TextField("Timeout", text: $form.timeout, prompt: Text(Self.defaultTimeoutText(form.runner)))
            .help("How long one run may take, 10s to 2h and no longer than the interval. Empty uses the default.")
            .clickAnchor("loop-editor-timeout")
          if let error = form.timeoutError { errorText(error) }
        }
      }
      if form.runner == .script {
        VStack(alignment: .leading) {
          Text("Command")
          TextEditor(text: $form.command)
            .font(.body.monospaced())
            .frame(minHeight: 80)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            .accessibilityLabel("Command")
            .clickAnchor("loop-editor-command")
          Text(
            "The command runs in the session's folder with your login shell. A command that runs a file there runs code that the session's Claude can edit."
          )
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        VStack(alignment: .leading) {
          Text("Prompt")
          TextEditor(text: $form.prompt)
            .font(.body.monospaced())
            .frame(minHeight: form.runner == .session ? 120 : 80)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            .accessibilityLabel("Prompt")
        }
      }
    }
  }

  /// A button for each runner. Buttons, not a segmented picker, so that each choice has a frame of its own.
  private var runnerChoice: some View {
    LabeledContent("Runs") {
      HStack(spacing: 4) {
        ForEach([Schedule.Runner.session, .headless, .script], id: \.self) { runner in
          let picked = form.runner == runner
          Button(Self.runnerTitle(runner)) { form.runner = runner }
            .buttonStyle(.bordered)
            .tint(picked ? Color.accentColor : nil)
            .fontWeight(picked ? .semibold : .regular)
            .help(Self.runnerHelp(runner))
            .accessibilityAddTraits(picked ? .isSelected : [])
            .clickAnchor("loop-editor-runner-\(runner.rawValue)")
        }
      }
    }
  }

  private var headlessFields: some View {
    let session =
      form.original.flatMap { model.owner(ofSchedule: $0.id)?.session }
      ?? model.allSessions.first { $0.id == form.session }
    let folder = session?.account
    let accounts = Self.accountChoices(model.accounts, sessionFolder: folder)
    return Group {
      Picker("Account", selection: $form.account) {
        Text("The session's account").tag("")
        // A stored account that sbd no longer lists stays selectable, so the picker shows it.
        if !form.account.isEmpty, !accounts.contains(where: { $0.name == form.account }) {
          Text(form.account).tag(form.account)
        }
        ForEach(accounts) { Text($0.name).tag($0.name) }
      }
      .help("The Claude account that each run uses")
      .clickAnchor("loop-editor-account")
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          TextField("Model", text: $form.model, prompt: Text("The session's model"))
            .help("The model of each run, such as haiku. Empty uses the session's model.")
          Menu("Suggestions") {
            ForEach(Self.modelSuggestions, id: \.self) { name in Button(name) { form.model = name } }
          }
          .fixedSize()
          .accessibilityLabel("Model suggestions")
        }
        if let error = form.modelError { errorText(error) }
      }
    }
  }

  /// The timeout that a loop of `runner` gets without one of its own, before the interval cuts it.
  static func defaultTimeoutText(_ runner: Schedule.Runner) -> String {
    Schedule.intervalText(Schedule.defaultTimeout(runner, every: .max))
  }

  private func errorText(_ error: String) -> some View {
    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
  }

  static func runnerTitle(_ runner: Schedule.Runner) -> String {
    switch runner {
    case .session: "In the session"
    case .headless: "Headless"
    case .script: "Script"
    }
  }

  private static func runnerHelp(_ runner: Schedule.Runner) -> String {
    switch runner {
    case .session: "Send the prompt into the session's conversation"
    case .headless:
      "Run the prompt as its own claude -p turn in the session's folder, on an account and a model you pick"
    case .script: "Run a shell command in the session's folder"
    }
  }

  private func save() {
    if let original = form.original {
      model.editSchedule(
        original.id, every: form.changedInterval, prompt: form.changedPrompt ?? form.changedCommand,
        account: form.changedAccount, model: form.changedModel, timeout: form.changedTimeout)
    } else if let session = form.session, let every = form.changedInterval,
      let text = form.changedPrompt ?? form.changedCommand
    {
      model.addSchedule(
        session: session, every: every, prompt: text, runner: form.runner, account: form.changedAccount,
        model: form.changedModel, timeout: form.changedTimeout)
    }
  }
}
