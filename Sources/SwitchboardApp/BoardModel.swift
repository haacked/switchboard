import AppKit
import Foundation
import SwitchboardCore
import UserNotifications

/// The two views that the detail pane shows while no session is selected.
enum MainView {
  case inbox
  case board
}

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
  /// The id of the Done session whose delete the confirmation dialog in ContentView asks about.
  @Published var confirmingDelete: String?
  /// The ids of the Done sessions whose delete is running.
  @Published var deleting: Set<String> = []
  /// The id of the session whose cleanup the confirmation dialog in ContentView asks about.
  @Published var confirmingCleanup: String?
  /// The ids of the sessions whose cleanup is running.
  @Published var cleaningUp: Set<String> = []
  var presentingSheet: Bool { showingNew || showingImport }
  /// The view that the detail pane shows while no session is selected.
  @Published var mainView = MainView.inbox
  /// The Inbox item that the user last moved to.
  @Published var inboxFocus: String?
  /// Counts ⌘J presses in the Inbox. Each one scrolls to the current item,
  /// even when ⌘J lands on the item it reached last time.
  @Published var inboxJumps = 0
  /// The right pane of the Inbox shows the session's terminals instead of its summary.
  @Published var showingTerminal = false
  /// The last reply of the sessions the Inbox showed, read from their
  /// transcripts, by session id.
  @Published var replies: [String: String] = [:]
  /// Each group chat's last messages, by group id, read while its pane shows.
  @Published var chatLogs: [String: [ChatMessage]] = [:]
  /// Options whose click is on its way to sbd, as "<session>/<number>".
  @Published var choosing: Set<String> = []
  /// Cards whose answer is on its way to sbd. Their views stay disabled
  /// until sbd replies, so a second click can't answer again.
  @Published var answering: Set<Int64> = []
  /// Follow-ups whose start is on its way to sbd. Their Start buttons stay
  /// disabled until sbd replies, because making a worktree can take seconds.
  @Published var starting: Set<String> = []
  /// Sessions whose message is on its way to sbd. Their Send buttons stay
  /// disabled until sbd replies, so a second press can't send it again.
  @Published var sending: Set<String> = []
  /// Group suggestions whose Accept or Decline is on its way to sbd. Their
  /// rows stay disabled until sbd replies, so a second click can't answer again.
  @Published var answeringSuggestions: Set<String> = []
  /// The sidebar sections that the user collapsed. Follow-ups that haven't
  /// started can number in the hundreds, so their section starts collapsed.
  @Published var collapsed: Set<AttentionState> = [.notStarted]
  /// Follow-ups that wait to start, from `followup-ls`. `ls` also lists the
  /// ones whose trigger fired. They change only through actions and
  /// triggers, so the app reads them every 5 s.
  @Published var followups: [SessionSummary] = []
  /// The groups, read every 5 s with the follow-ups.
  @Published var groups: [GroupSummary] = []
  /// The group suggestions, read with the follow-ups.
  @Published var suggestions: [GroupSuggestion] = []
  /// The Claude accounts, read with the follow-ups.
  @Published var accounts: [AccountInfo] = []
  /// Each account's last usage reading.
  @Published var usage: [AccountUsage] = []
  /// A switch of the active account that waits for the user to say whether
  /// the sessions on the other accounts move too.
  @Published var switchingAccount: AccountSwitch?
  /// What the user picked or typed on each open card, by card id. The Inbox
  /// and the session view show the same draft.
  private var drafts: [Int64: CardView.Draft] = [:]

  let client = Client()
  /// Sends one request to sbd. Tests replace it.
  lazy var send: @Sendable (String, [String: JSON]) throws -> JSON = { [client = self.client] op, args in
    try client.call(op, args, timeout: 300)
  }
  /// Polls run apart from actions, because an action such as `open` or `new`
  /// can take seconds.
  private let poller = DispatchQueue(label: "switchboard.poll")
  private let worker = DispatchQueue(label: "switchboard.actions")
  private var timer: Timer?
  private var knownStates: [String: AttentionState] = [:]
  /// The session that `create` or `openManager` selected before a refresh
  /// listed it.
  private var pendingSelection: String?
  private var loaded = false
  private var followupsRead = Date.distantPast
  /// sbd reads the usage every few minutes, so the app asks once a minute.
  private var usageRead = Date.distantPast

  /// The Manager stays out of the Inbox, the Dock badge, and ⌘J. The toolbar
  /// star fills and turns the Needs you color while it needs you.
  var needsYou: [SessionSummary] { sessions.filter { $0.state == .needsYou && Triage.mayHaveItem($0) } }

  var manager: SessionSummary? { sessions.first { $0.manager == true } }

  /// A state's sessions in the sidebar, each one followed by its children.
  struct SidebarGroup: Identifiable {
    var state: AttentionState
    var rows: [SessionTree.Row]
    var id: AttentionState { state }
  }

  /// The board without the Manager and the group chats, which belong to no
  /// group. The Manager has its own sidebar row. A group's Board row opens its chat.
  var workBoard: [SessionSummary] { board.filter { $0.sessionKind == .work } }

  /// The group's chat, or nil before its first start.
  func chat(of group: String) -> SessionSummary? { sessions.first { $0.chat == group } }

  /// The sidebar's groups, in state order, without empty ones. The Manager has
  /// its own row above the groups, so a session it started is top level, like
  /// one with no parent. A session whose parent is another session nests under
  /// that parent while both are in the same group.
  var sidebarGroups: [SidebarGroup] {
    let listed = workBoard
    return AttentionState.allCases.compactMap { state in
      let group = listed.filter { $0.state == state }
      return group.isEmpty ? nil : SidebarGroup(state: state, rows: SessionTree.rows(group))
    }
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

  /// True while the sidebar has no rows and sbd answers.
  var sidebarIsEmpty: Bool { sidebarGroups.isEmpty && manager == nil && unreachable == nil }

  /// The Inbox or the Board while no session is selected, else nil.
  var visibleView: MainView? { selection == nil ? mainView : nil }

  /// The focused Inbox session while it exists, else the first item. A session
  /// that the user just answered leaves the list while it works, and the
  /// right pane stays on it to show its next reply.
  var currentInboxItem: String? {
    sessions.contains { $0.id == inboxFocus } ? inboxFocus : triage.first?.id
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
    let readUsage = Date().timeIntervalSince(usageRead) >= 60
    if readUsage { usageRead = Date() }
    poller.async {
      let (result, more) = Self.read(
        sessions: client.sessions,
        followups: readFollowups ? { try client.call("followup-ls", as: [SessionSummary].self) } : nil)
      let accounts = readFollowups ? try? client.accounts() : nil
      let groups = try? client.call("group-ls", as: GroupList.self).groups
      let suggestions = readFollowups ? try? client.call("group-suggest", as: [GroupSuggestion].self) : nil
      let usage = readUsage ? try? client.usage() : nil
      Task { @MainActor in
        if let accounts, self.accounts != accounts { self.accounts = accounts }
        if let groups, self.groups != groups { self.groups = groups }
        if let suggestions, self.suggestions != suggestions { self.suggestions = suggestions }
        if let usage, self.usage != usage { self.usage = usage }
        self.apply(result, followups: more)
      }
    }
  }

  /// Reads the follow-ups, then the sessions. sbd moves a follow-up from
  /// `followup-ls` to `ls` in one step, so this order lists it in at least one
  /// of the two.
  static func read(
    sessions: () throws -> [SessionSummary], followups: (() throws -> [SessionSummary])?
  ) -> (Result<[SessionSummary], Error>, [SessionSummary]?) {
    let more = followups.flatMap { try? $0() }
    return (Result { try sessions() }, more)
  }

  /// Whether two lists differ only in `lastActivity`, which sbd bumps on every
  /// hook event and the views never show. Publishing for it redraws the views
  /// and restarts a tooltip's hover delay.
  private func sameShown(_ a: [SessionSummary], _ b: [SessionSummary]) -> Bool {
    a.count == b.count
      && zip(a, b).allSatisfy { old, new in
        var old = old
        old.lastActivity = new.lastActivity
        return old == new
      }
  }

  func apply(_ result: Result<[SessionSummary], Error>, followups more: [SessionSummary]?) {
    switch result {
    case .success(let list):
      // Assigning a @Published property republishes even an equal value. A
      // refresh every second would redraw the views each time, and a redraw
      // resets the hover delay before a tooltip shows.
      if unreachable != nil { unreachable = nil }
      if let more, followups != more { followups = more }
      if loaded { sessionsToNotify(list).forEach(notify) }
      let open = Set(list.flatMap { $0.cards.map(\.id) })
      drafts = drafts.filter { open.contains($0.key) }
      if !sameShown(sessions, list) { sessions = list }
      let listed = Set(board.map(\.id))
      if let id = pendingSelection, listed.contains(id) { pendingSelection = nil }
      if let id = selection, id != pendingSelection, !listed.contains(id) { selection = nil }
      // A follow-up that fires appears in `ls` as Needs you. The known states
      // include the follow-ups, so that change from Not started notifies.
      knownStates = Dictionary(uniqueKeysWithValues: board.map { ($0.id, $0.state) })
      loaded = true
      NSApp.dockTile.badgeLabel = needsYou.isEmpty ? nil : "\(needsYou.count)"
    case .failure(let error):
      let problem = "\(error)"
      if unreachable != problem { unreachable = problem }
    }
  }

  /// The sessions that just started needing the user.
  func sessionsToNotify(_ list: [SessionSummary]) -> [SessionSummary] {
    list.filter { s in
      guard s.state == .needsYou, Triage.mayHaveItem(s), let known = knownStates[s.id], known != .needsYou
      else { return false }
      // A follow-up that starts passes through Needs you until its first
      // prompt. Only a follow-up that fired and is still unstarted notifies.
      return known != .notStarted || s.waitsToStart
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
    let send = send
    worker.async {
      let result = Result { try send(op, args) }
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

  /// Makes new sessions run under the account. When sessions on other
  /// accounts could move to it, this asks first.
  func useAccount(_ folder: String) {
    let client = client
    worker.async {
      let plan = try? client.moveSessions(to: folder, dryRun: true)
      Task { @MainActor in
        if let plan, !plan.moved.isEmpty {
          self.switchingAccount = AccountSwitch(folder: folder, plan: plan)
        } else {
          self.perform("account-use", ["account": .string(folder)])
        }
      }
    }
  }

  /// Makes the account the one for new sessions, and with `move` moves the
  /// sessions whose claude is stopped to it.
  func confirmAccountSwitch(_ change: AccountSwitch, move: Bool) {
    switchingAccount = nil
    perform("account-use", ["account": .string(change.folder)]) { _ in
      if move { self.perform("account-move", ["account": .string(change.folder)]) }
    }
  }

  /// Starts the Manager, or opens it, and selects it.
  func openManager() {
    perform("manager", [:]) { value in
      if let id = value["id"]?.string { self.selectUnlisted(id) }
    }
  }

  /// Selects the group's chat. The first time, it starts the chat. A chat
  /// that exists resumes only when the user sends it a message or shows its terminal.
  func openChat(_ group: String) {
    if let chat = chat(of: group) {
      selection = chat.id
      return
    }
    perform("chat", ["group": .string(group)]) { value in
      if let id = value["id"]?.string { self.selectUnlisted(id) }
    }
  }

  /// Selects a session that sbd just made, which the next refresh lists.
  func selectUnlisted(_ id: String) {
    selection = id
    pendingSelection = id
  }

  func open(_ id: String) { perform("open", ["session": .string(id)]) }
  func stop(_ id: String) { perform("stop", ["session": .string(id)]) }
  func resume(_ id: String) { perform("resume", ["session": .string(id)]) }
  func setDone(_ id: String, _ done: Bool) { perform("done", ["session": .string(id), "done": .bool(done)]) }
  func acceptSuggestion(_ id: String) { answerSuggestion(id, "accept") }
  func declineSuggestion(_ id: String) { answerSuggestion(id, "decline") }

  /// `then` removes the row when sbd accepts the answer. `finally` runs
  /// before the refresh lists the suggestions again. The removal keeps the
  /// row's buttons from turning back on for a suggestion that sbd no longer has.
  private func answerSuggestion(_ id: String, _ key: String) {
    guard answeringSuggestions.insert(id).inserted else { return }
    perform(
      "group-suggest", [key: .string(id)], then: { _ in self.suggestions.removeAll { $0.id == id } },
      finally: { self.answeringSuggestions.remove(id) })
  }
  /// `sent` runs only when sbd accepted the message. A second send to the
  /// same session does nothing until sbd answers the first.
  func send(_ id: String, _ text: String, sent: (() -> Void)? = nil) {
    guard sending.insert(id).inserted else { return }
    perform(
      "send", ["session": .string(id), "text": .string(text)], then: { _ in sent?() },
      finally: { self.sending.remove(id) })
  }

  /// Opens the window when the user has closed it. The always-present menu bar item sets this.
  var showWindow: (() -> Void)?

  /// Selects the session and brings its window forward, opening the window first when it is closed.
  func reveal(_ id: String) {
    selection = id
    showWindow?()
  }

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

  /// Reads the chat's messages from its transcript, which can be large, so off the main thread.
  func loadChatLog(_ group: String) {
    let client = client
    poller.async {
      let messages = try? client.call("chat-log", ["group": .string(group)], as: [ChatMessage].self)
      Task { @MainActor in
        if let messages, self.chatLogs[group] != messages { self.chatLogs[group] = messages }
      }
    }
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

  /// What the Done column's delete icon removes, for the confirmation.
  struct DeletePlan {
    var name: String
    /// The worktree's path, or nil when sbd made no worktree for the session.
    var worktree: String?
    /// The local branch, or nil when sbd made no worktree for the session or its PR is not merged.
    var branch: String?

    /// What the delete icon's label and tooltip say it removes.
    var summary: String {
      if branch != nil { return "the session, its worktree, and its branch" }
      return worktree != nil ? "the session and its worktree" : "the session"
    }

    var message: String {
      var parts = ["the session \(name)"]
      if let worktree { parts.append("its worktree \(worktree) (if it is still there)") }
      if let branch {
        parts.append("its local branch \(branch)")
        parts.append("the remote branch \(branch), only if it is still at the merged PR's head")
      }
      var text = "This stops claude, closes both terminals, and deletes " + Self.list(parts) + "."
      if worktree != nil && branch == nil { text += " The branch stays, because its PR is not merged." }
      text +=
        " The conversation's transcript stays. sbd refuses a worktree with uncommitted files or commits on no remote branch, a locked worktree, a branch that is not at the merged PR's head, and a branch checked out in another worktree. A refusal before anything stops deletes nothing. A branch that fails its check after the worktree is gone stays, and the session and worktree are deleted anyway."
      return text
    }

    private static func list(_ parts: [String]) -> String {
      switch parts.count {
      case 0, 1: parts.joined()
      case 2: parts.joined(separator: " and ")
      default: parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
      }
    }
  }

  /// The delete icon is for Done sessions that are not the Manager and not an unstarted follow-up.
  nonisolated static func canDelete(_ s: SessionSummary) -> Bool {
    s.state == .done && s.sessionKind == .work && !s.waitsToStart
  }

  nonisolated static func deletePlan(_ s: SessionSummary) -> DeletePlan {
    let merged = s.pr?.state == .merged
    let branch = s.repo != nil && merged ? s.branch : nil
    return DeletePlan(
      name: s.name, worktree: s.repo == nil ? nil : s.cwd, branch: branch)
  }

  /// The request that the icon sends: the same `rm` as the trash dialog, with the worktree, the
  /// branch, and the remote branch on. The branch is on only for a merged PR, because sbd
  /// refuses the whole delete for a branch with no merged PR.
  nonisolated static func deleteRequest(_ s: SessionSummary) -> [String: JSON] {
    let plan = deletePlan(s)
    return [
      "session": .string(s.id), "worktree": .bool(plan.worktree != nil), "branch": .bool(plan.branch != nil),
      "remote_branch": .bool(plan.branch != nil),
    ]
  }

  /// Deletes a Done session with everything `deletePlan` names. sbd runs the safety checks of `rm`.
  func deleteDone(_ s: SessionSummary) {
    guard deleting.insert(s.id).inserted else { return }
    perform(
      "rm", Self.deleteRequest(s),
      then: { _ in if self.selection == s.id { self.selection = nil } },
      finally: { self.deleting.remove(s.id) })
  }

  /// Removes the worktree and the local branch of a session whose PR merged.
  /// The session stays, so the selection stays too. sbd reruns every check
  /// first. A refusal shows in the banner.
  func cleanup(_ s: SessionSummary) {
    guard cleaningUp.insert(s.id).inserted else { return }
    perform("cleanup", ["session": .string(s.id)], finally: { self.cleaningUp.remove(s.id) })
  }

  /// Removes the session and its worktree. sbd refuses, and removes nothing,
  /// when the worktree has uncommitted files, has commits that are on no remote
  /// branch, or isn't one that sbd made. With `branch`, it also deletes the
  /// local branch, and sbd refuses unless the session's PR is merged. When the
  /// branch fails its check after the worktree is gone, sbd removes the session
  /// and keeps the branch. The error shows in the banner.
  func delete(_ id: String, branch: Bool = false) {
    perform("rm", ["session": .string(id), "worktree": .bool(true), "branch": .bool(branch)]) { _ in
      if self.selection == id { self.selection = nil }
    }
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
      if let id = value["id"]?.string { self.selectUnlisted(id) }
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

  nonisolated func importSessions(_ refs: [String], stop: [String]) -> Result<ImportResult, Error> {
    Result { try Client().importSessions(refs, stop: stop) }
  }

  /// Clears the selected session and shows the Inbox or the Board.
  func show(_ view: MainView) {
    selection = nil
    mainView = view
  }

  /// Opens a Board card. A session in the Inbox list is focused there and
  /// scrolled into view. Any other session opens directly, because the Inbox
  /// has no row for it.
  func openFromBoard(_ id: String) {
    guard triage.contains(where: { $0.id == id }) else {
      selection = id
      return
    }
    show(.inbox)
    inboxFocus = id
    inboxJumps += 1
  }

  /// Moves to the next Inbox item while the Inbox shows. Otherwise selects
  /// the next session that needs you, after the selected one.
  func selectNextNeedingYou() {
    let showingInbox = visibleView == .inbox
    let list = showingInbox ? triage : needsYou
    guard !list.isEmpty else { return }
    if showingInbox {
      let i = list.firstIndex { $0.id == currentInboxItem } ?? -1
      inboxFocus = list[(i + 1) % list.count].id
      inboxJumps += 1
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

/// An account switch that the user has not confirmed, with the sessions that
/// moving would and would not move.
struct AccountSwitch: Identifiable {
  var folder: String
  var plan: AccountMove
  var id: String { folder }
  var name: String { ClaudeAccount.name(folder) }
}
