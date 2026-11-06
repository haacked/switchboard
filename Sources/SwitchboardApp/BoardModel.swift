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
  /// The Delete All sheet's state, or nil while it is closed.
  @Published var doneRemoval: DoneRemoval?
  var presentingSheet: Bool { showingNew || showingImport || doneRemoval != nil }
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
  /// The newest events of the sessions whose card details the Inbox showed,
  /// oldest first, by session id.
  @Published var recentEvents: [String: [Event]] = [:]
  /// Each group chat's last messages, by group id, read while its pane shows.
  @Published var chatLogs: [String: [ChatMessage]] = [:]
  /// Options whose click is on its way to sbd, as "<session>/<number>".
  @Published var choosing: Set<String> = []
  /// Cards whose answer is on its way to sbd. Their views stay disabled
  /// until sbd replies, so a second click can't answer again.
  @Published var answering: Set<Int64> = []
  /// Sessions whose merge is on its way to sbd. Their buttons stay disabled
  /// until sbd replies, so a second click can't merge again.
  @Published var merging: Set<String> = []
  /// Sessions whose acknowledgment or its undo is on its way to sbd.
  @Published var acknowledging: Set<String> = []
  /// Follow-ups whose start is on its way to sbd. Their Start buttons stay
  /// disabled until sbd replies, because making a worktree can take seconds.
  @Published var starting: Set<String> = []
  /// Sessions whose message is on its way to sbd. Their Send buttons stay
  /// disabled until sbd replies, so a second press can't send it again.
  @Published var sending: Set<String> = []
  /// Group suggestions whose Accept or Decline is on its way to sbd. Their
  /// rows stay disabled until sbd replies, so a second click can't answer again.
  @Published var answeringSuggestions: Set<String> = []
  /// The plan rows, as `<plan> <row>`, whose follow-up sbd is making.
  @Published var followingUp: Set<String> = []
  /// Artifact plans whose Apply or Reject is on its way to sbd. Their buttons
  /// stay disabled until sbd replies, so a second click can't answer again.
  @Published var answeringArtifacts: Set<String> = []
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
  /// The plan updates and new plan rows that wait for the user, read with the follow-ups.
  @Published var planProposals: [PlanProposal] = []
  /// Plan proposals whose Apply or Reject is on its way to sbd. Applying
  /// writes to GitHub, so their buttons stay off until sbd replies.
  @Published var answeringProposals: Set<String> = []
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
  /// What the user typed in each message field and has not sent.
  private let messageDrafts: MessageDrafts

  let client: Client
  /// Sends one request to sbd. Tests replace it.
  lazy var send: @Sendable (String, [String: JSON]) throws -> JSON = { [client = self.client] op, args in
    try client.call(op, args, timeout: 300)
  }
  /// Polls run apart from actions, because an action such as `open` or `new`
  /// can take seconds.
  private let poller = DispatchQueue(label: "switchboard.poll")
  private let worker = DispatchQueue(label: "switchboard.actions")
  /// Merges wait on `gh pr merge` for up to 120 s each, so they run apart
  /// from other actions and from each other.
  private let merges = DispatchQueue(label: "switchboard.merges", attributes: .concurrent)
  /// A plan apply waits for sbd's GitHub poll and then writes to GitHub, so
  /// it runs apart from other actions too.
  private let planWrites = DispatchQueue(label: "switchboard.plan-writes", attributes: .concurrent)
  private var timer: Timer?
  private var knownStates: [String: AttentionState] = [:]
  /// The session that `create` or `openManager` selected before a refresh
  /// listed it.
  private var pendingSelection: String?
  private var loaded = false
  private var followupsRead = Date.distantPast
  /// sbd reads the usage every few minutes, so the app asks once a minute.
  private var usageRead = Date.distantPast

  /// Takes the client so that tests can't reach the user's sbd by default.
  /// Without `draftsFolder`, the message drafts last only while the model does.
  init(client: Client, draftsFolder: String? = nil) {
    self.client = client
    messageDrafts = MessageDrafts(folder: draftsFolder)
  }

  /// The Manager stays out of the Inbox, the Dock badge, and ⌘J. The toolbar
  /// star fills and turns the Needs you color while it needs you.
  var needsUser: [SessionSummary] { sessions.filter { $0.state.needsUser && Triage.mayHaveItem($0) } }

  var manager: SessionSummary? { sessions.first { $0.kind == .manager } }

  /// A state's sessions in the sidebar, each one followed by its children.
  struct SidebarGroup: Identifiable {
    var state: AttentionState
    var rows: [SessionTree.Row]
    var id: AttentionState { state }
  }

  /// The board without the Manager and the group chats, which belong to no
  /// group. The Manager has its own sidebar row. A group's Board row opens its chat.
  var workBoard: [SessionSummary] { board.filter { $0.kind == .work } }

  /// The group's chat, or nil before its first start.
  func chat(of group: String) -> SessionSummary? { sessions.first { $0.kind == .chat && $0.chat == group } }

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

  /// The repo label of each session in the sidebar. The Inbox uses the same
  /// labels. A session therefore shows the same repo in both lists.
  var repoLabels: [String: String] { RepoLabels.labels(board) }

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
      let proposals = readFollowups ? try? client.call("plan-proposals", as: [PlanProposal].self) : nil
      let usage = readUsage ? try? client.usage() : nil
      Task { @MainActor in
        if let accounts, self.accounts != accounts { self.accounts = accounts }
        if let groups, self.groups != groups { self.groups = groups }
        if let suggestions, self.suggestions != suggestions { self.suggestions = suggestions }
        if let proposals, self.planProposals != proposals { self.planProposals = proposals }
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
      messageDrafts.prune(keeping: Set(list.map(MessageDrafts.key)))
      if !sameShown(sessions, list) { sessions = list }
      let listed = Set(board.map(\.id))
      if let id = pendingSelection, listed.contains(id) { pendingSelection = nil }
      if let id = selection, id != pendingSelection, !listed.contains(id) { selection = nil }
      // A follow-up that fires appears in `ls` as Needs you. The known states
      // include the follow-ups, so that change from Not started notifies.
      knownStates = Dictionary(uniqueKeysWithValues: board.map { ($0.id, $0.state) })
      loaded = true
      NSApp.dockTile.badgeLabel = needsUser.isEmpty ? nil : "\(needsUser.count)"
    case .failure(let error):
      let problem = "\(error)"
      if unreachable != problem { unreachable = problem }
    }
  }

  /// The sessions that just started needing the user.
  func sessionsToNotify(_ list: [SessionSummary]) -> [SessionSummary] {
    list.filter { s in
      guard s.state.needsUser, Triage.mayHaveItem(s), let known = knownStates[s.id], !known.needsUser
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
    _ op: String, _ args: [String: JSON], on queue: DispatchQueue? = nil, then: ((JSON) -> Void)? = nil,
    finally: (() -> Void)? = nil
  ) {
    let send = send
    (queue ?? worker).async {
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
  /// Starts the session's shell pane, or ends it. sbd keeps a closed shell closed until this opens it.
  func setShellOpen(_ id: String, _ open: Bool) {
    perform("shell", ["session": .string(id), "open": .bool(open)])
  }
  func stop(_ id: String) { perform("stop", ["session": .string(id)]) }
  func resume(_ id: String) { perform("resume", ["session": .string(id)]) }
  func setDone(_ id: String, _ done: Bool) { perform("done", ["session": .string(id), "done": .bool(done)]) }
  /// Sets the group's description, or clears it when `text` is blank. The
  /// Board shows the new text before sbd answers. It returns false when it
  /// refuses the text, such as text over the length limit.
  @discardableResult
  func describeGroup(_ id: String, _ text: String) -> Bool {
    guard let index = groups.firstIndex(where: { $0.id == id }) else { return true }
    let clean: String?
    do {
      clean = try SessionGroup.cleanDescription(text)
    } catch {
      actionError = "\(error)"
      return false
    }
    guard clean != groups[index].description else { return true }
    groups[index].description = clean
    if let clean {
      perform("group-describe", ["group": .string(id), "text": .string(clean)])
    } else {
      perform("group-describe", ["group": .string(id), "clear": true])
    }
    return true
  }
  func acceptSuggestion(_ id: String) { answerSuggestion(id, "accept") }
  func declineSuggestion(_ id: String) { answerSuggestion(id, "decline") }

  /// `then` removes the row when sbd accepts the answer. `finally` runs
  /// before the refresh lists the suggestions again. The removal keeps the
  /// row's buttons from turning back on for a suggestion that sbd no longer has.
  private func answerSuggestion(_ id: String, _ key: String) {
    answer(id, in: \.answeringSuggestions, "group-suggest", [key: .string(id)]) {
      $0.suggestions.removeAll { $0.id == id }
    }
  }

  /// Sends an answer to an item once. `answering` holds the item's id until
  /// sbd replies. `remove` takes the item out of its list when sbd takes the
  /// answer.
  private func answer(
    _ id: String, in answering: ReferenceWritableKeyPath<BoardModel, Set<String>>, _ op: String,
    _ args: [String: JSON], on queue: DispatchQueue? = nil, remove: @escaping (BoardModel) -> Void
  ) {
    guard self[keyPath: answering].insert(id).inserted else { return }
    perform(op, args, on: queue, then: { _ in remove(self) }, finally: { self[keyPath: answering].remove(id) })
  }
  func applyProposal(_ id: String) { answerProposal(id, "plan-apply", on: planWrites) }
  func rejectProposal(_ id: String) { answerProposal(id, "plan-reject") }

  private func answerProposal(_ id: String, _ op: String, on queue: DispatchQueue? = nil) {
    answer(id, in: \.answeringProposals, op, ["proposal": .string(id)], on: queue) {
      $0.planProposals.removeAll { $0.id == id }
    }
  }

  /// Makes a follow-up from a plan row that reads Not started. The row's
  /// button stays off until sbd answers. `then` removes the row when sbd
  /// makes the follow-up, so its button does not turn back on before the
  /// refresh lists the plan again.
  func followUp(plan: String, row: String) {
    let key = followUpKey(plan: plan, row: row)
    guard followingUp.insert(key).inserted else { return }
    perform(
      "plan-followup", ["plan": .string(plan), "row": .string(row)],
      then: { _ in self.changePlan(plan) { $0.canFollowUp.removeAll { ($0.ref ?? $0.text) == row } } },
      finally: { self.followingUp.remove(key) })
  }

  /// Changes the plan's summary in each group that lists it, before the
  /// next refresh lists the plan again.
  private func changePlan(_ id: String, _ change: (inout PlanSummary) -> Void) {
    for g in groups.indices {
      guard let p = groups[g].plans?.firstIndex(where: { $0.id == id }) else { continue }
      change(&groups[g].plans![p])
    }
  }

  func isFollowingUp(plan: String, row: String) -> Bool { followingUp.contains(followUpKey(plan: plan, row: row)) }

  /// Applies or rejects an artifact plan's pending update. Apply asks the
  /// group's chat to publish it.
  func answerArtifact(plan: String, apply: Bool) {
    guard answeringArtifacts.insert(plan).inserted else { return }
    perform(
      apply ? "plan-artifact-apply" : "plan-artifact-reject", ["plan": .string(plan)],
      then: { result in
        guard let doc = try? JSONCoding.convert(result, to: PlanDocument.self) else { return }
        self.changePlan(plan) { $0 = PlanSummary(doc) }
      },
      finally: { self.answeringArtifacts.remove(plan) })
  }

  private func followUpKey(plan: String, row: String) -> String { "\(plan) \(row)" }

  /// `sent` runs only when sbd accepted the message. A second send to the
  /// same session does nothing until sbd answers the first. Each image is a
  /// file name and the image's bytes.
  func send(_ id: String, _ text: String, images: [(name: String, data: Data)] = [], sent: (() -> Void)? = nil) {
    guard sending.insert(id).inserted else { return }
    var args: [String: JSON] = ["session": .string(id), "text": .string(text)]
    if !images.isEmpty { args["images"] = .array(images.map { Attachments.json(name: $0.name, data: $0.data) }) }
    perform("send", args, then: { _ in sent?() }, finally: { self.sending.remove(id) })
  }

  /// Opens the window when the user has closed it. The always-present menu bar item sets this.
  var showWindow: (() -> Void)?

  /// Selects the session and brings its window forward, opening the window first when it is closed.
  func reveal(_ id: String) {
    selection = id
    showWindow?()
  }

  /// Answers a card: allow, deny with an optional message, or one answer per
  /// question. `autoMode` with allow also switches the session to auto mode.
  func answer(
    _ card: Card, behavior: String? = nil, message: String = "", answers: [String]? = nil, autoMode: Bool = false
  ) {
    guard answering.insert(card.id).inserted else { return }
    var args: [String: JSON] = ["session": .string(card.session), "card": .number(Double(card.id))]
    if let behavior { args["behavior"] = .string(behavior) }
    if autoMode { args["autoMode"] = true }
    if !message.isEmpty { args["message"] = .string(message) }
    if let answers { args["answers"] = .array(answers.map(JSON.string)) }
    // A sent group message succeeds even when some targets fail, so the
    // failures come back in its deliveries.
    perform(
      "answer", args,
      then: { result in
        guard card.kind == .send, let sent = try? JSONCoding.convert(result, to: GroupSend.self) else { return }
        let failed = (sent.deliveries ?? []).compactMap { d in d.error.map { "\(d.session): \($0)" } }
        if !failed.isEmpty { self.actionError = "send: \(failed.joined(separator: "; "))" }
      },
      finally: { self.answering.remove(card.id) })
  }

  func merge(_ id: String) {
    guard merging.insert(id).inserted else { return }
    perform("merge", ["session": .string(id)], on: merges, finally: { self.merging.remove(id) })
  }

  /// Takes the session's item out of the Inbox, or with `undo` puts it back.
  /// The Inbox moves its focus from an acknowledged item to the next one.
  func acknowledge(_ id: String, undo: Bool = false) {
    guard acknowledging.insert(id).inserted else { return }
    var args: [String: JSON] = ["session": .string(id)]
    if undo {
      args["undo"] = true
    } else if currentInboxItem == id {
      moveInbox(by: 1)
      // A field in the item that scrolls away would keep the keystrokes. A
      // session's terminal outside the Inbox keeps them.
      if visibleView == .inbox { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
    perform(
      "ack", args,
      then: { value in
        // The user put the item back, so the refresh must not notify about it.
        if undo, let s = try? JSONCoding.convert(value, to: SessionSummary.self) { self.knownStates[id] = s.state }
      },
      finally: { self.acknowledging.remove(id) })
  }

  /// The session that the Session menu's Acknowledge acts on: the current
  /// Inbox item while the Inbox shows, else the selected session.
  var acknowledgeTarget: SessionSummary? {
    visibleView == .inbox ? sessions.first { $0.id == currentInboxItem } : selected
  }

  /// Clicks the item's option. `text` is what the user typed for a reply option.
  func choose(_ session: String, ref: String, option number: Int, action: TriageAction, text: String? = nil) {
    let key = "\(session)/\(number)"
    // The Board's merge buttons read `merging`, so a merge from the card shows there too.
    let merge = action.isMerge
    if merge, merging.contains(session) { return }
    guard choosing.insert(key).inserted else { return }
    var args: [String: JSON] = ["session": .string(session), "option": .string(String(number)), "ref": .string(ref)]
    if let text { args["text"] = .string(text) }
    if merge { merging.insert(session) }
    // A merge runs gh for up to two minutes, so it does not hold the other actions back.
    perform(
      "choose", args, on: merge ? merges : nil,
      finally: {
        self.choosing.remove(key)
        if merge { self.merging.remove(session) }
      })
  }

  /// Submits a multi-select card's ticked options, by number, as one reply.
  func choose(_ session: String, ref: String, picks: [String]) {
    let key = "\(session)/picks"
    guard !picks.isEmpty, choosing.insert(key).inserted else { return }
    let args: [String: JSON] = [
      "session": .string(session), "options": .array(picks.map(JSON.string)), "ref": .string(ref),
    ]
    perform("choose", args, finally: { self.choosing.remove(key) })
  }

  /// Reads the session's newest events for its card's details.
  func loadEvents(_ session: String) {
    let client = client
    poller.async {
      let events = try? client.call(
        "events", ["session": .string(session), "limit": .number(Double(Self.recentEventCount))], as: [Event].self)
      Task { @MainActor in
        if let events, self.recentEvents[session] != events { self.recentEvents[session] = events }
      }
    }
  }

  static let recentEventCount = 10

  /// Reads the chat's messages from its transcript, which can be large, so off the main thread.
  func loadChatLog(_ group: String) {
    let client = client
    poller.async {
      let messages = try? client.call("chat-log", ["group": .string(group)], as: [ChatMessage].self)
      Task { @MainActor in
        // A failed first read shows an empty log, so the pane stops showing that it is loading.
        if let messages = messages ?? (self.chatLogs[group] == nil ? [] : nil), self.chatLogs[group] != messages {
          self.chatLogs[group] = messages
        }
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

  func messageDraft(for session: SessionSummary) -> MessageField.Draft {
    messageDrafts.draft(for: MessageDrafts.key(for: session))
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
        " The conversation's transcript stays. sbd refuses a worktree with uncommitted files or commits on no remote branch, a worktree that a tool other than Supacode locked, a branch that is not at the merged PR's head, and a branch checked out in another worktree. A refusal before anything stops deletes nothing. A branch that fails its check after the worktree is gone stays, and the session and worktree are deleted anyway."
      return text
    }

    static func list(_ parts: [String]) -> String {
      switch parts.count {
      case 0, 1: parts.joined()
      case 2: parts.joined(separator: " and ")
      default: parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
      }
    }
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

  /// Focuses the Inbox item `step` places after the current one, around the
  /// end of the list.
  func moveInbox(by step: Int) {
    let list = triage
    guard !list.isEmpty else { return }
    let i = list.firstIndex { $0.id == currentInboxItem } ?? (step > 0 ? -1 : 0)
    inboxFocus = list[((i + step) % list.count + list.count) % list.count].id
    inboxJumps += 1
  }

  /// Moves to the next Inbox item while the Inbox shows. Otherwise selects
  /// the next session that needs you, after the selected one.
  func selectNextNeedingYou() {
    let showingInbox = visibleView == .inbox
    let list = showingInbox ? triage : needsUser
    guard !list.isEmpty else { return }
    if showingInbox {
      moveInbox(by: 1)
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
