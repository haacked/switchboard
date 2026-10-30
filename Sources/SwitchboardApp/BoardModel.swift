import AppKit
import Foundation
import SwitchboardCore
import UserNotifications

/// The app's view of sbd. It polls `ls` once a second, because sbd keeps
/// state in memory and answers in a few milliseconds.
@MainActor
final class BoardModel: ObservableObject {
  @Published var sessions: [SessionSummary] = []
  /// Why sbd can't be reached, or nil while it answers.
  @Published var unreachable: String?
  /// The last failed action, shown until the next one succeeds.
  @Published var actionError: String?
  @Published var selection: String?
  @Published var showingNew = false
  @Published var showingImport = false
  var presentingSheet: Bool { showingNew || showingImport }
  /// With no session selected, the detail shows the Board instead of the Queue.
  @Published var showingBoard = false
  /// The Queue item that the user last moved to.
  @Published var queueFocus: String?
  /// Counts ⌘J presses in the Queue. Each one scrolls to the current item,
  /// even when ⌘J lands on the item it reached last time.
  @Published var queueJumps = 0
  /// The right pane of the Queue shows the session's terminals instead of its summary.
  @Published var showingTerminal = false
  /// The last reply of the sessions the Queue showed, read from their
  /// transcripts, by session id.
  @Published var replies: [String: String] = [:]
  /// Options whose click is on its way to sbd, as "<session>/<number>".
  @Published var choosing: Set<String> = []
  /// Cards whose answer is on its way to sbd. Their views stay disabled
  /// until sbd replies, so a second click can't answer again.
  @Published var answering: Set<Int64> = []
  /// Follow-ups whose start is on its way to sbd. Their Start buttons stay
  /// disabled until sbd replies, because making a worktree can take seconds.
  @Published var starting: Set<String> = []
  /// The sidebar sections that the user collapsed. Follow-ups that haven't
  /// started can number in the hundreds, so their section starts collapsed.
  @Published var collapsed: Set<AttentionState> = [.notStarted]
  /// Follow-ups that wait to start, from `followup-ls`. `ls` also lists the
  /// ones whose trigger fired. They change only through actions and
  /// triggers, so the app reads them every 5 s.
  @Published var followups: [SessionSummary] = []
  /// What the user picked or typed on each open card, by card id. The Queue
  /// and the session view show the same draft.
  private var drafts: [Int64: CardView.Draft] = [:]

  let client = Client()
  /// Polls run apart from actions, because an action such as `open` or `new`
  /// can take seconds.
  private let poller = DispatchQueue(label: "switchboard.poll")
  private let worker = DispatchQueue(label: "switchboard.actions")
  private var timer: Timer?
  private var knownStates: [String: AttentionState] = [:]
  private var loaded = false
  private var followupsRead = Date.distantPast

  /// The Manager is pinned in the sidebar, so the Queue leaves it out.
  var needsYou: [SessionSummary] { sessions.filter { $0.state == .needsYou && $0.manager != true } }

  var manager: SessionSummary? { sessions.first { $0.manager == true } }

  /// The Manager, then the sessions it started and theirs, each under its parent.
  var managerTree: [SessionTree.Row] {
    manager.map { SessionTree.subtree(of: $0.id, in: sessions) } ?? []
  }

  var triage: [SessionSummary] { Triage.order(sessions) }

  /// The sessions and the follow-ups that wait to start. A follow-up whose
  /// trigger fired is in both lists until it starts. A follow-up that started
  /// since the last read of follow-ups is in both lists for up to 5 s. The
  /// board shows the copy from `ls`.
  var board: [SessionSummary] {
    let ids = Set(sessions.map(\.id))
    return sessions + followups.filter { !ids.contains($0.id) }
  }

  var selected: SessionSummary? { board.first { $0.id == selection } }

  /// The focused Queue session while it exists, else the first item. A session
  /// that the user just answered leaves the list while it works, and the
  /// right pane stays on it to show its next reply.
  var currentQueueItem: String? {
    sessions.contains { $0.id == queueFocus } ? queueFocus : triage.first?.id
  }

  func start() {
    guard timer == nil else { return }
    if Bundle.main.bundleIdentifier != nil {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh(followups: Bool = false) {
    let client = client
    let readFollowups = followups || Date().timeIntervalSince(followupsRead) >= 5
    if readFollowups { followupsRead = Date() }
    poller.async {
      let result = Result { try client.sessions() }
      let more = readFollowups ? try? client.call("followup-ls", as: [SessionSummary].self) : nil
      Task { @MainActor in self.apply(result, followups: more) }
    }
  }

  private func apply(_ result: Result<[SessionSummary], Error>, followups more: [SessionSummary]?) {
    switch result {
    case .success(let list):
      unreachable = nil
      if let more, followups != more { followups = more }
      if loaded {
        for s in list where s.state == .needsYou && knownStates[s.id] != .needsYou && knownStates[s.id] != nil {
          // A follow-up that starts passes through Needs you until its first
          // prompt. Only a follow-up that fired and is still unstarted notifies.
          if knownStates[s.id] == .notStarted && !s.waitsToStart { continue }
          notify(s)
        }
      }
      let open = Set(list.flatMap { $0.cards.map(\.id) })
      drafts = drafts.filter { open.contains($0.key) }
      if sessions != list { sessions = list }
      // A follow-up that fires appears in `ls` as Needs you. The known states
      // include the follow-ups, so that change from Not started notifies.
      knownStates = Dictionary(uniqueKeysWithValues: board.map { ($0.id, $0.state) })
      loaded = true
      NSApp.dockTile.badgeLabel = needsYou.isEmpty ? nil : "\(needsYou.count)"
    case .failure(let error):
      unreachable = "\(error)"
    }
  }

  private func notify(_ s: SessionSummary) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = "\(s.name) needs you"
    content.body = s.triage?.title ?? s.reason
    content.userInfo = ["session": s.id]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "\(s.id)-\(s.since)", content: content, trigger: nil))
  }

  /// Runs a request off the main thread, then refreshes. `finally` runs
  /// whether the request succeeds or fails.
  func perform(
    _ op: String, _ args: [String: JSON], then: ((JSON) -> Void)? = nil, finally: (() -> Void)? = nil
  ) {
    let client = client
    worker.async {
      let result = Result { try client.call(op, args, timeout: 300) }
      Task { @MainActor in
        switch result {
        case .success(let value):
          self.actionError = nil
          then?(value)
        case .failure(let error):
          self.actionError = "\(op): \(error)"
        }
        finally?()
        self.refresh(followups: true)
      }
    }
  }

  /// Starts the Manager, or opens it, and selects it.
  func openManager() {
    perform("manager", [:]) { value in
      if let id = value["id"]?.string { self.selection = id }
    }
  }

  func open(_ id: String) { perform("open", ["session": .string(id)]) }
  func stop(_ id: String) { perform("stop", ["session": .string(id)]) }
  func resume(_ id: String) { perform("resume", ["session": .string(id)]) }
  func setDone(_ id: String, _ done: Bool) { perform("done", ["session": .string(id), "done": .bool(done)]) }
  func send(_ id: String, _ text: String) { perform("send", ["session": .string(id), "text": .string(text)]) }

  /// Answers a card: allow, deny with an optional message, or one answer per question.
  func answer(_ card: Card, behavior: String? = nil, message: String = "", answers: [String]? = nil) {
    guard answering.insert(card.id).inserted else { return }
    var args: [String: JSON] = ["session": .string(card.session), "card": .number(Double(card.id))]
    if let behavior { args["behavior"] = .string(behavior) }
    if !message.isEmpty { args["message"] = .string(message) }
    if let answers { args["answers"] = .array(answers.map(JSON.string)) }
    perform("answer", args, finally: { self.answering.remove(card.id) })
  }

  func choose(_ session: String, ref: String, option number: Int) {
    let key = "\(session)/\(number)"
    guard choosing.insert(key).inserted else { return }
    perform(
      "choose", ["session": .string(session), "option": .string(String(number)), "ref": .string(ref)],
      finally: { self.choosing.remove(key) })
  }

  /// Reads the session's last reply from its transcript, which can be large,
  /// so off the main thread.
  func loadReply(_ session: String) {
    let client = client
    poller.async {
      let text = try? client.call("reply", ["session": .string(session)])["reply"]?.string
      Task { @MainActor in
        if let text, self.replies[session] != text { self.replies[session] = text }
      }
    }
  }

  func draft(for card: Card) -> CardView.Draft {
    if let draft = drafts[card.id] { return draft }
    let draft = CardView.Draft()
    drafts[card.id] = draft
    return draft
  }
  /// A follow-up that hasn't started goes through `followup-rm`, which
  /// refuses it if it started since the board last read it.
  func remove(_ id: String) {
    let followup = board.first { $0.id == id }?.waitsToStart == true
    if selection == id { selection = nil }
    perform(followup ? "followup-rm" : "rm", ["session": .string(id)])
  }

  /// `path` is the checkout to start in, for a follow-up whose checkout sbd
  /// can't find.
  func startFollowup(_ id: String, path: String? = nil) {
    guard starting.insert(id).inserted else { return }
    var args: [String: JSON] = ["session": .string(id)]
    if let path { args["path"] = .string(path) }
    perform("followup-start", args, finally: { self.starting.remove(id) })
  }

  func create(_ args: NewSession) {
    guard let json = try? JSON(encoding: args).object else { return }
    perform("new", json) { value in
      if let id = value["id"]?.string { self.selection = id }
    }
  }

  /// Asks sbd for the session's tmux targets. It blocks, so it runs off the
  /// main thread.
  nonisolated func terminals(_ id: String) -> Result<Terminals, Error> {
    Result { try Client().terminals(id) }
  }

  /// The Claude sessions that the import sheet offers. It blocks, so it runs
  /// off the main thread.
  nonisolated func importable(all: Bool, repo: String?) -> Result<ImportList, Error> {
    Result { try Client().importable(all: all, repo: repo) }
  }

  nonisolated func importSessions(_ refs: [String]) -> Result<ImportResult, Error> {
    Result { try Client().importSessions(refs) }
  }

  /// Moves to the next Queue item while the Queue shows. Otherwise selects
  /// the next session that needs you, after the selected one.
  func selectNextNeedingYou() {
    let list = selection == nil && !showingBoard ? triage : needsYou
    guard !list.isEmpty else { return }
    if selection == nil && !showingBoard {
      let i = list.firstIndex { $0.id == currentQueueItem } ?? -1
      queueFocus = list[(i + 1) % list.count].id
      queueJumps += 1
      // A field in the item that scrolls away would keep the keystrokes.
      NSApp.keyWindow?.makeFirstResponder(nil)
    } else if let current = selection, let i = list.firstIndex(where: { $0.id == current }) {
      selection = list[(i + 1) % list.count].id
    } else {
      selection = list[0].id
    }
  }

  /// Starts sbd as a launchd agent with the `sb` that ships next to the app.
  func installService() {
    guard let sb = Self.sbPath else {
      actionError = "can't find sb next to the app"
      return
    }
    worker.async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: sb)
      p.arguments = ["service", "install"]
      let err = Pipe()
      p.standardError = err
      let result = Result { try p.run() }
      p.waitUntilExit()
      let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      Task { @MainActor in
        if case .failure(let e) = result { self.actionError = "\(e)" }
        if p.terminationStatus != 0 { self.actionError = message }
        self.refresh()
      }
    }
  }

  /// The sb binary in the app bundle, or next to the app's executable in a
  /// build folder.
  static var sbPath: String? {
    let path = siblingExecutable("sb")
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }
}
