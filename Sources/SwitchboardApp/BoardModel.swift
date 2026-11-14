import AppKit
import Foundation
import SwitchboardCore
import UserNotifications

/// The views that the detail pane shows while no session is selected.
enum MainView {
  case inbox
  case board
  case issues
}

/// The app's view of sbd. It polls `ls` once a second, because sbd keeps
/// state in memory and answers in a few milliseconds.
@MainActor
final class BoardModel: ObservableObject {
  /// The sessions that the org filter shows. Every list, count, badge, and
  /// action target reads this. A lookup of a session that a shown session
  /// names, such as a card's asker or a parent, reads `allSessions` or
  /// `allBoard`, because that session may be hidden.
  var sessions: [SessionSummary] { allSessions.filter(orgFilter.shows) }
  /// Every session that sbd lists, whatever the org filter says.
  @Published private(set) var allSessions: [SessionSummary] = []
  /// The GitHub orgs whose sessions the app shows. The installed app saves it.
  @Published var orgFilter: OrgFilter {
    didSet {
      guard orgFilter != oldValue else { return }
      orgFilterStore?.set(orgFilter.keys.sorted(), forKey: Self.orgFilterKey)
      clearHiddenSelectionAndUpdateBadge()
    }
  }
  @Published var showingOrgFilter = false
  /// Decides when a session tile's hover card shows. Tests replace it.
  var hoverCard: HoverCard?
  /// Why sbd can't be reached, or nil while it answers.
  @Published var unreachable: String?
  /// The last failed action, shown until the next one succeeds.
  @Published var actionError: String?
  /// Selecting a session that the org filter hides adds its org to the filter. The filter change runs inside
  /// the navigation, so it records nothing of its own.
  @Published var selection: String? {
    didSet { navigate { if let selection, selection != oldValue { showOrg(of: selection) } } }
  }
  /// The New Session sheet's opening, or nil while it is closed.
  @Published var newSession: NewSessionRequest?
  @Published var showingImport = false
  /// The repositories that the New Session sheet offers, most recently used first. It is nil until sbd answers.
  @Published var knownRepos: [KnownRepo]?
  @Published var showingSearch = false
  /// The Done session whose delete the confirmation dialog in ContentView asks about, as the
  /// board showed it when the user asked. The dialog's message and request both read this value.
  @Published var confirmingDelete: SessionSummary?
  /// The ids of the Done sessions whose delete is running.
  @Published var deleting: Set<String> = []
  /// The id of the session whose cleanup the confirmation dialog in ContentView asks about.
  @Published var confirmingCleanup: String?
  /// The ids of the sessions whose cleanup is running.
  @Published var cleaningUp: Set<String> = []
  /// The Delete All sheet's state, or nil while it is closed.
  @Published var doneRemoval: DoneRemoval?
  var presentingSheet: Bool {
    newSession != nil || showingImport || showingSearch || doneRemoval != nil || showingIssueSetup
  }
  func openNewSession(group: String? = nil, parent: String? = nil) {
    newSession = NewSessionRequest(group: group, parent: parent)
  }
  /// The view that the detail pane shows while no session is selected.
  @Published var mainView = MainView.inbox {
    didSet { navigate() }
  }
  /// The Inbox item that the user last moved to.
  @Published var inboxFocus: String? {
    didSet { navigate() }
  }
  /// Counts ⌘J presses in the Inbox. Each one scrolls to the current item,
  /// even when ⌘J lands on the item it reached last time.
  @Published var inboxJumps = 0
  /// The Board card that the arrow keys or Next and Previous Session last moved to.
  @Published var boardFocus: String?
  /// Counts ⌘L presses and session steps. The list that `listFocusTarget` names takes keyboard focus on each one.
  @Published var listFocusRequests = 0
  /// The session whose Claude terminal takes keyboard focus when it shows. The terminal clears it.
  @Published var terminalFocus: String?
  /// The Board's open cards as it last drew them. BoardView keeps it current. The Session menu's ⌘T state and
  /// the Board's ring read it, so a change redraws them.
  @Published var boardGrid = BoardGrid(lanes: [])
  /// The right pane of the Inbox shows the session's terminals instead of its summary.
  @Published var showingTerminal = false {
    didSet { navigate() }
  }
  /// The places the user went, for Back, Forward, and Recent Places. Only `BoardModel+History` changes it.
  @Published var history = NavHistory(start: NavLocation(place: .inbox(nil), terminal: false))
  @Published var showingRecentPlaces = false
  var navigating = false
  /// The last reply of the sessions the Inbox showed, read from their
  /// transcripts, by session id.
  @Published var replies: [String: String] = [:]
  /// The newest events of the sessions whose card details the Inbox showed,
  /// oldest first, by session id.
  @Published var recentEvents: [String: [Event]] = [:]
  /// The transcript steps that lead up to each session's Inbox item, by session id.
  @Published var itemContexts: [String: ItemContext] = [:]
  /// Each chat's last messages, by session id, read while its pane shows.
  @Published var chatLogs: [String: [ChatMessage]] = [:]
  /// Each Manager conversation's last `manager-mcp` answer, by session id, read while its pane shows.
  @Published var mcpAnswers: [String: ManagerMCPAnswer] = [:]
  /// The commands that each session's claude takes after `/`, by session id, read when a message field's list opens.
  @Published var slashCommands: [String: [SlashCommand]] = [:]
  /// Options whose click is on its way to sbd, as "<session>/<number>".
  @Published var choosing: Set<String> = []
  /// Cards whose answer is on its way to sbd. Their views stay disabled
  /// until sbd replies, so a second click can't answer again.
  @Published var answering: Set<Int64> = []
  /// sbd's refusal of the last answer of each card, by card id. The card shows it.
  @Published var cardErrors: [Int64: String] = [:]
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
  /// Sessions whose Start Now is on its way to sbd. Their Start Now buttons
  /// stay disabled until sbd replies, so a second click can't report that
  /// the first one already started claude.
  @Published var startingNow: Set<String> = []
  /// Group suggestions whose Accept or Decline is on its way to sbd. Their
  /// rows stay disabled until sbd replies, so a second click can't answer again.
  @Published var answeringSuggestions: Set<String> = []
  /// The plan rows, as `<plan> <row>`, whose follow-up sbd is making.
  @Published var followingUp: Set<String> = []
  /// Artifact plans whose Apply or Reject is on its way to sbd. Their buttons
  /// stay disabled until sbd replies, so a second click can't answer again.
  @Published var answeringArtifacts: Set<String> = []
  /// The decision requests that wait for sbd: `<session>/<number>` for an
  /// answer, and `<session>/submit` and `<session>/discard`.
  @Published var deciding: Set<String> = []
  /// sbd's refusal of the last decision request, by session. The card shows it.
  @Published var decisionErrors: [String: String] = [:]
  /// The reply keys of the drafts whose `draft-post` sbd has not answered.
  @Published var postingDrafts: Set<String> = []
  /// The reply keys of the drafts whose `draft-check` sbd has not answered.
  @Published var checkingDrafts: Set<String> = []
  /// sbd's refusal of a draft's last post or check, by reply key.
  @Published var draftErrors: [String: String] = [:]
  /// The sidebar sections that the user collapsed. Follow-ups that haven't
  /// started can number in the hundreds, so their section starts collapsed.
  @Published var collapsed: Set<AttentionState> = [.notStarted]
  /// Follow-ups that wait to start, from `followup-ls`. `ls` also lists the
  /// ones whose trigger fired. They change only through actions and
  /// triggers, so the app reads them every 5 s.
  var followups: [SessionSummary] { allFollowups.filter(orgFilter.shows) }
  /// Every follow-up that waits to start, whatever the org filter says.
  @Published private(set) var allFollowups: [SessionSummary] = []
  /// The groups, read every 5 s with the follow-ups.
  @Published var groups: [GroupSummary] = []
  /// True while the Board's new group name field is open.
  @Published var namingGroup = false
  /// The group whose delete the Board's confirmation dialog asks about.
  @Published var confirmingGroupDelete: GroupSummary?
  /// The group suggestions, read with the follow-ups.
  @Published var suggestions: [GroupSuggestion] = []
  /// The plan updates and new plan rows that wait for the user, read with the follow-ups.
  @Published var planProposals: [PlanProposal] = []
  /// The open issues from the configured sources, read with the follow-ups. nil until the first read.
  @Published var issueList: IssueList?
  /// The issue that the user last moved to in the Issues view, by id.
  @Published var issueFocus: String?
  /// Counts moves in the Issues view. Each one scrolls to the current issue.
  @Published var issueJumps = 0
  @Published var issueScope = IssueScope.team
  @Published var issueSort = IssueSort.updated
  /// Whether the Issues list has a section per repository instead of a section per bucket.
  @Published var issuesByRepo = false
  /// The Issues sections that the user collapsed, by section id.
  @Published var collapsedIssueSections: Set<String> = IssueSection.collapsedAtFirst
  /// The issues whose Start is on its way to sbd.
  @Published var startingIssues: Set<String> = []
  /// sbd's refusal of the last Start, by issue id. The issue's pane shows it.
  @Published var issueErrors: [String: String] = [:]
  /// The session that the last Start made, while the Issues view's notice offers to open it.
  @Published var startedIssue: StartedIssue?
  /// The group that the user picked for an issue's Start, by issue id. nil inside picks No Group. An issue with no
  /// entry starts in `KnownRepos.preferredGroup`.
  @Published var issueGroupPicks: [String: String?] = [:]
  @Published var showingIssueSetup = false
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
  @Published var showingAccounts = false
  /// The sessions that could move to the active account, read when the
  /// account menu opens.
  @Published var movable: AccountMove?
  /// What the user picked or typed on each open card, by card id. The Inbox
  /// and the session view show the same draft.
  private var drafts: [Int64: CardView.Draft] = [:]
  /// What the user typed in each message field and has not sent.
  private let messageDrafts: MessageDrafts

  private let client: Client
  /// Sends one request to sbd. Tests replace it.
  lazy var send: @Sendable (String, [String: JSON]) throws -> JSON = { [client = self.client] op, args in
    try client.call(op, args, timeout: 300)
  }
  /// Polls run apart from actions, because an action such as `open` or `new`
  /// can take seconds.
  private let poller = DispatchQueue(label: "switchboard.poll")
  /// Issue reads and Starts, which wait on GitHub, gh, or git. They run here so the session list and other
  /// actions do not wait behind them.
  let issueWork = DispatchQueue(label: "switchboard.issues", attributes: .concurrent)
  /// Item-context reads, which can take seconds for a long or remote transcript. They run apart from the poll.
  /// The queue is serial, so two reads for one session answer in the order the user asked for them.
  private let contextWork = DispatchQueue(label: "switchboard.context")
  private let worker = DispatchQueue(label: "switchboard.actions")
  /// Merges wait on gh for up to 120 s, and review requests for up to 60 s.
  /// They run apart from other actions and from each other.
  private let merges = DispatchQueue(label: "switchboard.merges", attributes: .concurrent)
  /// A plan apply waits for sbd's GitHub poll and then writes to GitHub, so
  /// it runs apart from other actions too.
  private let planWrites = DispatchQueue(label: "switchboard.plan-writes", attributes: .concurrent)
  private var timer: Timer?
  /// Each session as the last refresh listed it.
  private var lastSeen: [String: SessionSummary] = [:]
  /// The session that `create` or `openManager` selected before a refresh
  /// listed it.
  private(set) var pendingSelection: String?
  private var loaded = false
  private var followupsRead = Date.distantPast
  /// sbd reads the usage every few minutes, so the app asks once a minute.
  private var usageRead = Date.distantPast

  static let orgFilterKey = "orgFilter"
  /// Where the org filter is saved. It is nil outside the installed app, so
  /// a debug or test run never saves a filter that hides a later run's sessions.
  private let orgFilterStore: UserDefaults?

  /// Takes the client so that tests can't reach the user's sbd by default.
  /// Without `draftsFolder`, the message drafts last only while the model does.
  /// The filter starts from `orgFilterStore` when it holds one, else from `orgFilter`.
  init(
    client: Client, draftsFolder: String? = nil, orgFilterStore: UserDefaults? = nil,
    orgFilter: OrgFilter = OrgFilter()
  ) {
    self.client = client
    messageDrafts = MessageDrafts(folder: draftsFolder)
    self.orgFilterStore = orgFilterStore
    self.orgFilter = orgFilterStore?.stringArray(forKey: Self.orgFilterKey).map { OrgFilter(keys: $0) } ?? orgFilter
    hoverCard = HoverCard.panel(for: self)
  }

  /// Clears a selection that the org filter hides, closes the hover card of a session that is no longer
  /// shown, and counts the shown sessions in the Dock badge. The current history entry follows what the window
  /// shows, because a refresh can change the Inbox's first item.
  private func clearHiddenSelectionAndUpdateBadge() {
    let listed = shownIDs
    navigate(.replace) { if let id = selection, id != pendingSelection, !listed.contains(id) { selection = nil } }
    hoverCard?.sessionsChanged(shown: listed)
    if NSApp != nil { NSApp.dockTile.badgeLabel = needsUser.isEmpty ? nil : "\(needsUser.count)" }
  }

  /// Changes the session before sbd lists the change.
  private func update(_ id: String, _ change: (inout SessionSummary) -> Void) {
    for i in allSessions.indices where allSessions[i].id == id { change(&allSessions[i]) }
    for i in allFollowups.indices where allFollowups[i].id == id { change(&allFollowups[i]) }
  }

  /// The sessions and the follow-ups that wait to start, whatever the org
  /// filter says. A follow-up whose trigger fired is in both lists until it
  /// starts. A follow-up that started since the last read of follow-ups is in
  /// both lists for up to 5 s. The board shows the copy from `ls`.
  var allBoard: [SessionSummary] {
    let ids = Set(allSessions.map(\.id))
    return allSessions + allFollowups.filter { !ids.contains($0.id) }
  }

  /// The ids of the sessions and follow-ups that the org filter shows.
  var shownIDs: Set<String> { Set(board.map(\.id)) }

  /// The ids that Delete All may remove. Under a filter, a session whose org
  /// sbd hasn't read yet shows but isn't removable, because its org may be one
  /// that the filter hides.
  var removableIDs: Set<String> {
    orgFilter.isAll ? shownIDs : Set(board.filter { OrgFilter.key(of: $0) != nil }.map(\.id))
  }

  /// The org filter's menu rows, counted over every session.
  var orgEntries: [OrgFilter.Entry] { orgFilter.entries(allBoard) }

  /// The groups that the Board shows: all of them under All Orgs, else each
  /// group that is empty or has a member that the filter shows.
  var shownGroups: [GroupSummary] {
    guard !orgFilter.isAll else { return groups }
    let shown = shownIDs
    return groups.filter { $0.sessions.isEmpty || $0.sessions.contains(where: shown.contains) }
  }

  /// The group suggestions whose sessions the filter all shows, so accepting
  /// one never moves a hidden session.
  var shownSuggestions: [GroupSuggestion] {
    guard !orgFilter.isAll else { return suggestions }
    let shown = shownIDs
    return suggestions.filter { $0.sessions.allSatisfy(shown.contains) }
  }

  /// How many sessions and follow-ups the org filter hides.
  var hiddenCount: Int { allBoard.count - board.count }
  /// How many hidden sessions would be in the Inbox.
  var hiddenNeedingYou: Int { allBoard.filter(Triage.needsYou).count - board.filter(Triage.needsYou).count }

  /// Adds the session's org to the filter when the filter hides it, so a
  /// session that the app opens never stays out of sight.
  func showOrg(of id: String) {
    // An insert of a key that the filter already holds still publishes. `apply` calls this every second.
    guard !orgFilter.isAll, let s = allBoard.first(where: { $0.id == id }), !orgFilter.shows(s),
      let key = OrgFilter.key(of: s)
    else { return }
    orgFilter.insert(key)
  }

  /// The Manager and a group chat count only while a prompt blocks them. The
  /// toolbar star fills and turns the Needs you color while the Manager needs you.
  var needsUser: [SessionSummary] { sessions.filter(Triage.needsYou) }

  /// The Manager conversations, newest activity first, as `sb manager ls` lists them.
  var managers: [SessionSummary] {
    sessions.filter { $0.kind == .manager }.sorted(by: Manager.newestFirst)
  }

  /// The Manager conversation that the toolbar star names while one needs you.
  var waitingManager: SessionSummary? { managers.first { $0.state == .needsYou } }

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

  /// The current name of the group that the chat manages, or nil for any other session.
  private func groupName(of s: SessionSummary) -> String? {
    guard let group = s.chat else { return nil }
    return groups.first { $0.id == group }?.name
  }

  /// How the Inbox, the menu bar, and a notification name the session.
  func inboxName(_ s: SessionSummary) -> String { Triage.inboxName(s, groupName: groupName(of: s)) }

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

  /// The sessions and the follow-ups that wait to start, as the org filter shows them.
  var board: [SessionSummary] { allBoard.filter(orgFilter.shows) }

  var selected: SessionSummary? { board.first { $0.id == selection } }

  /// True while the sidebar has no rows and sbd answers.
  var sidebarIsEmpty: Bool { sidebarGroups.isEmpty && managers.isEmpty && unreachable == nil }

  /// The main view while no session is selected, else nil.
  var visibleView: MainView? { selection == nil ? mainView : nil }

  /// The focused Inbox session while it exists, else the first item. A session
  /// that the user just answered leaves the list while it works, and the
  /// right pane stays on it to show its next reply.
  var currentInboxItem: String? {
    sessions.contains { $0.id == inboxFocus } ? inboxFocus : triage.first?.id
  }

  func start() {
    guard timer == nil else { return }
    hoverCard?.closeOnEvents()
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
      let issues = readFollowups ? try? client.call("issues", as: IssueList.self) : nil
      let usage = readUsage ? try? client.usage() : nil
      Task { @MainActor in
        if let accounts, self.accounts != accounts { self.accounts = accounts }
        if let groups, self.groups != groups { self.groups = groups }
        if let suggestions, self.suggestions != suggestions { self.suggestions = suggestions }
        if let proposals, self.planProposals != proposals { self.planProposals = proposals }
        if let issues, self.issueList != issues { self.issueList = issues }
        if let usage, self.usage != usage { self.usage = usage }
        self.apply(result, followups: more)
      }
    }
  }

  /// Reads the follow-ups, then the sessions. sbd moves a follow-up from
  /// `followup-ls` to `ls` in one step, so this order lists it in at least one
  /// of the two.
  nonisolated static func read(
    sessions: () throws -> [SessionSummary], followups: (() throws -> [SessionSummary])?
  ) -> (Result<[SessionSummary], Error>, [SessionSummary]?) {
    let more = followups.flatMap { try? $0() }
    return (Result { try sessions() }, more)
  }

  /// Whether two lists differ only in `lastActivity`, which sbd bumps on every
  /// hook event. Publishing for it would redraw every view each second. The
  /// hover card shows `lastActivity`, so its "active" time can lag until
  /// another shown field changes.
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
      // refresh every second would redraw the views each time.
      if unreachable != nil { unreachable = nil }
      if let more, allFollowups != more { allFollowups = more }
      // Only shown sessions notify. The last seen sessions cover every session.
      // Widening the filter later therefore sends nothing for a change that happened while the session was hidden.
      if loaded { sessionsToNotify(list).forEach(notify) }
      // A hidden session keeps its drafts.
      let open = Set(list.flatMap { $0.cards.map(\.id) })
      drafts = drafts.filter { open.contains($0.key) }
      messageDrafts.prune(
        keeping: Set(list.map(MessageDrafts.key)).union(MessageDrafts.otherAnswerKeys(list))
          .union(MessageDrafts.replyKeys(list)))
      if !sameShown(allSessions, list) { allSessions = list }
      // A filter change that hides the selection clears it in `orgFilter.didSet`.
      // A selected session that is hidden here therefore had no known org until this refresh.
      if let id = selection { showOrg(of: id) }
      if let id = pendingSelection, allBoard.contains(where: { $0.id == id }) { pendingSelection = nil }
      clearHiddenSelectionAndUpdateBadge()
      // A follow-up that fires appears in `ls` as Needs you. The last seen sessions
      // include the follow-ups, so that change from Not started notifies.
      lastSeen = Dictionary(uniqueKeysWithValues: allBoard.map { ($0.id, $0) })
      loaded = true
    case .failure(let error):
      let problem = "\(error)"
      if unreachable != problem { unreachable = problem }
    }
  }

  /// The shown sessions that just entered the Inbox. A chat can need the user
  /// before its item reaches the Inbox. This therefore compares each session
  /// with its place in the last refresh's Inbox, not with its last state.
  func sessionsToNotify(_ list: [SessionSummary]) -> [SessionSummary] {
    list.filter { s in
      guard Triage.needsYou(s), let last = lastSeen[s.id], !Triage.needsYou(last), orgFilter.shows(s)
      else { return false }
      // A follow-up that starts passes through Needs you until its first
      // prompt. Only a follow-up that fired and is still unstarted notifies.
      return last.state != .notStarted || s.waitsToStart
    }
  }

  private func notify(_ s: SessionSummary) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = "\(inboxName(s)) needs you"
    content.body = s.triage?.title ?? s.reason
    content.userInfo = ["session": s.id]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "\(s.id)-\(s.since)", content: content, trigger: nil))
  }

  /// Runs a request off the main thread, then refreshes. `finally` runs
  /// whether the request succeeds or fails. `failed` takes sbd's refusal in
  /// place of the window's error banner.
  func perform(
    _ op: String, _ args: [String: JSON], on queue: DispatchQueue? = nil, then: ((JSON) -> Void)? = nil,
    failed: ((Error) -> Void)? = nil, finally: (() -> Void)? = nil
  ) {
    let send = send
    (queue ?? worker).async {
      let result = Result { try send(op, args) }
      Task { @MainActor in
        switch result {
        case .success(let value):
          if failed == nil { self.actionError = nil }
          then?(value)
        case .failure(let error):
          if let failed { failed(error) } else { self.actionError = "\(op): \(error)" }
        }
        finally?()
        self.refresh(followups: true)
      }
    }
  }

  /// The account that new sessions without a parent use.
  var activeAccount: AccountInfo? { accounts.first(where: \.active) }

  /// The active account's folder. It is the default folder until the accounts load.
  var activeAccountFolder: String { activeAccount?.folder ?? ClaudeAccount.defaultFolder }

  /// Closes the account menu and makes new sessions run under the account.
  /// When sessions on other accounts could move to it, this asks first.
  func useAccount(_ folder: String) {
    showingAccounts = false
    planMove(to: folder) { plan in
      if let plan, !plan.moved.isEmpty {
        self.switchingAccount = AccountSwitch(folder: folder, plan: plan, switches: true)
      } else {
        self.perform("account-use", ["account": .string(folder)])
      }
    }
  }

  /// The account that the account menu offers to move sessions to: the active
  /// one, when a session runs under another account. A signed-out account
  /// gets no offer, because a moved session's next resume would ask for /login.
  var moveTarget: AccountInfo? {
    guard let active = activeAccount, usage.first(where: { $0.folder == active.folder })?.signedOut != true,
      accounts.contains(where: { !$0.active && $0.sessions > 0 })
    else { return nil }
    return active
  }

  /// Reads which stopped sessions on other accounts could move to `moveTarget`.
  func readMovable() {
    movable = nil
    guard let target = moveTarget else { return }
    planMove(to: target.folder) { self.movable = $0 }
  }

  private func planMove(to folder: String, then: @escaping @MainActor (AccountMove?) -> Void) {
    let send = send
    worker.async {
      let plan = try? JSONCoding.convert(
        send("account-move", ["account": .string(folder), "dryRun": .bool(true)]), to: AccountMove.self)
      Task { @MainActor in then(plan) }
    }
  }

  /// Asks sbd to read every account's usage now, so an account that has just
  /// signed in can be chosen without waiting for the next timed read.
  func rereadUsage() {
    let client = client
    DispatchQueue.global(qos: .userInitiated).async {
      guard let usage = try? client.usage(refresh: true) else { return }
      Task { @MainActor in if self.usage != usage { self.usage = usage } }
    }
  }

  /// Closes the account menu and asks whether to move the sessions in `plan`
  /// to the active account.
  func offerMove(_ plan: AccountMove) {
    showingAccounts = false
    switchingAccount = AccountSwitch(folder: plan.account, plan: plan, switches: false)
  }

  /// Makes the account the one for new sessions when the change switches,
  /// and with `move` moves the sessions whose claude is stopped to it.
  func confirmAccountSwitch(_ change: AccountSwitch, move: Bool) {
    switchingAccount = nil
    let moveSessions = { if move { self.perform("account-move", ["account": .string(change.folder)]) } }
    if change.switches {
      perform("account-use", ["account": .string(change.folder)]) { _ in moveSessions() }
    } else {
      moveSessions()
    }
  }

  /// Opens the most recent Manager conversation, or starts the first one, and
  /// selects it. With `new`, it starts a conversation, which its first prompt names.
  func openManager(new: Bool = false) {
    perform("manager", new ? ["new": true] : [:]) { value in
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
    navigate {
      pendingSelection = id
      selection = id
    }
  }

  /// Starts the session's shell pane, or ends it. sbd keeps a closed shell closed until this opens it.
  func setShellOpen(_ id: String, _ open: Bool) {
    perform("shell", ["session": .string(id), "open": .bool(open)])
  }
  func stop(_ id: String) { perform("stop", ["session": .string(id)]) }
  func resume(_ id: String) { perform("resume", ["session": .string(id)]) }
  /// Starts a queued session now. When the live cap is full, sbd stops the
  /// lowest-priority idle session to make room. When the start still waits,
  /// the error banner shows why.
  func startNow(_ id: String) {
    guard startingNow.insert(id).inserted else { return }
    perform(
      "live-next", ["session": .string(id)],
      then: { result in
        guard let status = try? JSONCoding.convert(result, to: LiveStatus.self),
          let start = status.queued.first(where: { $0.session == id })
        else { return }
        self.actionError = "Start Now: \(start.reason ?? "the start still waits for a slot")"
      },
      finally: { self.startingNow.remove(id) })
  }
  static let startNowHelp =
    "Start claude now. When the live cap is full, sbd stops the lowest-priority idle session to make room."
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
  /// Moves a work session to a group, or to no group when `group` is nil.
  /// The Board shows the card in its new lane before sbd answers. It sends
  /// nothing for an id that names no work session on the Board, for a group
  /// that sbd didn't list, or when the session is already in that lane. It
  /// returns whether it sent the move.
  @discardableResult
  func moveToGroup(_ id: String, _ group: String?) -> Bool {
    let known = Set(groups.map(\.id))
    guard let session = workBoard.first(where: { $0.id == id }), group.map(known.contains) ?? true,
      BoardRows.group(of: session, known: known) != group
    else { return false }
    update(id) { $0.group = group }
    var args: [String: JSON] = ["sessions": [.string(id)]]
    if let group { args["group"] = .string(group) } else { args["ungrouped"] = true }
    perform("group-move", args)
    return true
  }
  /// Sets the account that the group's sessions run under, or clears it when
  /// `folder` is nil.
  func setGroupAccount(_ id: String, _ folder: String?) {
    if let folder {
      perform("group-account", ["group": .string(id), "account": .string(folder)])
    } else {
      perform("group-account", ["group": .string(id), "clear": true])
    }
  }

  /// The group's work sessions that move to the account at their next launch.
  /// A follow-up that hasn't started has no conversation to move.
  /// sbd moves every member, so this lists the ones that the org filter hides too.
  func groupAccountMoves(group: String, folder: String) -> [SessionSummary] {
    allSessions.filter { $0.group == group && $0.kind == .work && !$0.cwd.isEmpty && $0.account != folder }
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
  /// file name and the image's bytes. `ref` names the Inbox item that the
  /// message answers.
  func send(
    _ id: String, _ text: String, images: [(name: String, data: Data)] = [], ref: String? = nil,
    sent: (() -> Void)? = nil
  ) {
    guard sending.insert(id).inserted else { return }
    var args: [String: JSON] = ["session": .string(id), "text": .string(text)]
    if let ref { args["ref"] = .string(ref) }
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
  /// question. `extra` with allow also applies that extra, such as auto mode.
  func answer(
    _ card: Card, behavior: String? = nil, message: String = "", answers: [String]? = nil, extra: AllowExtra? = nil
  ) {
    guard answering.insert(card.id).inserted else { return }
    // A second refusal with the same text then still announces itself.
    cardErrors[card.id] = nil
    var args: [String: JSON] = ["session": .string(card.session), "card": .number(Double(card.id))]
    if let behavior { args["behavior"] = .string(behavior) }
    if let extra { args[extra.argument] = true }
    if !message.isEmpty { args["message"] = .string(message) }
    if let answers { args["answers"] = .array(answers.map(JSON.string)) }
    // A sent group message succeeds even when some targets fail, so the
    // failures come back in its deliveries.
    perform(
      "answer", args,
      then: { result in
        self.actionError = nil
        guard card.kind == .send, let sent = try? JSONCoding.convert(result, to: GroupSend.self) else { return }
        let failed = (sent.deliveries ?? []).compactMap { d in d.error.map { "\(d.session): \($0)" } }
        if !failed.isEmpty { self.actionError = "send: \(failed.joined(separator: "; "))" }
      },
      failed: { self.cardErrors[card.id] = "\($0)" },
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
      navigate(.replace) { moveInbox(by: 1) }
      // A field in the item that scrolls away would keep the keystrokes. A
      // session's terminal outside the Inbox keeps them.
      if visibleView == .inbox { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
    perform(
      "ack", args,
      then: { value in
        // The user put the item back, so the refresh must not notify about it.
        if undo, let s = try? JSONCoding.convert(value, to: SessionSummary.self) { self.lastSeen[id] = s }
      },
      finally: { self.acknowledging.remove(id) })
  }

  /// The session that the Session menu's Acknowledge acts on: the current
  /// Inbox item while the Inbox shows, else the selected session.
  var acknowledgeTarget: SessionSummary? {
    visibleView == .inbox ? sessions.first { $0.id == currentInboxItem } : selected
  }

  /// Clicks the item's option. `text` is what the user typed for a reply
  /// option, or the reviewers, separated by commas, for a review request.
  /// `sent` runs once sbd accepts the choice.
  func choose(
    _ session: String, ref: String, option number: Int, action: TriageAction, text: String? = nil,
    sent: (() -> Void)? = nil
  ) {
    let key = "\(session)/\(number)"
    // The Board's merge buttons read `merging`, so a merge from the card shows there too.
    let merge = action.isMerge
    if merge, merging.contains(session) { return }
    guard choosing.insert(key).inserted else { return }
    var args: [String: JSON] = ["session": .string(session), "option": .string(String(number)), "ref": .string(ref)]
    if let text { args["text"] = .string(text) }
    if merge { merging.insert(session) }
    perform(
      "choose", args, on: action.waitsOnGh ? merges : nil, then: { _ in sent?() },
      finally: {
        self.choosing.remove(key)
        if merge { self.merging.remove(session) }
      })
  }

  /// The reviewers that sbd suggests for the session's PR. sbd asks GitHub
  /// with gh, which can take seconds. The request runs off the action queue.
  func reviewSuggestions(_ session: String) async throws -> [ReviewerSuggestion] {
    let send = send
    return try await withCheckedThrowingContinuation { done in
      DispatchQueue.global(qos: .userInitiated).async {
        done.resume(
          with: Result {
            let result = try send("review", ["session": .string(session)])
            return try JSONCoding.convert(result["suggestions"] ?? [], to: [ReviewerSuggestion].self)
          })
      }
    }
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

  /// Answers one decision of the list whose ref the user saw. `answered`
  /// runs once sbd accepts the answer.
  func answerDecision(
    _ session: String, ref: String, number: Int, _ reply: DecisionReply, answered: (() -> Void)? = nil
  ) {
    var args: [String: JSON] = ["session": .string(session), "ref": .string(ref), "number": .number(Double(number))]
    switch reply {
    case .options(let picks): args["options"] = .array(picks.map { .string(String($0)) })
    case .text(let text): args["text"] = .string(text)
    case .skip: args["skip"] = true
    }
    decide(session, "decision-answer", args, key: "\(session)/\(number)", then: answered)
  }

  /// Sends the answers. `stale` sends a list that a turn made stale, which the card asks about first.
  func submitDecisions(_ session: String, stale: Bool = false) {
    var args: [String: JSON] = ["session": .string(session)]
    if stale { args["stale"] = true }
    decide(session, "decision-submit", args, key: "\(session)/submit")
  }

  /// Sends the submitted answers again, which sbd allows only while it can't tell whether they arrived.
  func resendDecisions(_ session: String) {
    decide(session, "decision-resend", ["session": .string(session)], key: "\(session)/resend")
  }

  func discardDecisions(_ session: String) {
    decide(session, "decision-discard", ["session": .string(session)], key: "\(session)/discard")
  }

  /// A second request with the same key does nothing until sbd answers the first.
  private func decide(
    _ session: String, _ op: String, _ args: [String: JSON], key: String, then: (() -> Void)? = nil
  ) {
    guard deciding.insert(key).inserted else { return }
    perform(
      op, args,
      then: { value in
        self.decisionErrors[session] = nil
        // sbd answers with the updated list. A pick made before the next refresh lands builds on it.
        if op == "decision-answer", let list = try? JSONCoding.convert(value, to: DecisionList.self) {
          self.update(session) { $0.decisions = list }
        }
        then?()
      },
      failed: { self.decisionErrors[session] = "\($0)" },
      finally: { self.deciding.remove(key) })
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

  nonisolated static let recentEventCount = 10

  /// Reads the transcript steps that lead up to the session's Inbox item, with `steps` steps before it. A failed
  /// read stores nothing, so the card's details show the last reply.
  func loadItemContext(_ session: String, steps: Int) {
    let send = send
    contextWork.async {
      let context = try? JSONCoding.convert(
        send("item-context", ["session": .string(session), "steps": .number(Double(steps))]), to: ItemContext.self)
      Task { @MainActor in
        if let context, self.itemContexts[session] != context { self.itemContexts[session] = context }
      }
    }
  }

  /// Reads the session's events of `kind` among the newest that sbd returns by default, off the main thread.
  func events(_ session: String, kind: String) async -> [Event] {
    let client = client
    return await Task.detached {
      ((try? client.call("events", ["session": .string(session)], as: [Event].self)) ?? []).filter { $0.kind == kind }
    }.value
  }

  /// Reads the session's chat messages from its transcript, which can be large, so off the main thread.
  func loadChatLog(_ session: String) {
    let send = send
    poller.async {
      let messages = try? JSONCoding.convert(
        send("chat-log", ["session": .string(session)]), to: [ChatMessage].self)
      Task { @MainActor in
        // A failed first read shows an empty log, so the pane stops showing that it is loading.
        if let messages = messages ?? (self.chatLogs[session] == nil ? [] : nil), self.chatLogs[session] != messages {
          self.chatLogs[session] = messages
        }
      }
    }
  }

  /// Reads the commands that the session's claude takes after `/`. A failed read keeps the stored rows, which the
  /// message field shows while sbd answers.
  func loadSlashCommands(_ session: String) {
    let send = send
    poller.async {
      let commands = try? JSONCoding.convert(
        send("slash-commands", ["session": .string(session)])["commands"], to: [SlashCommand].self)
      Task { @MainActor in
        if let commands, self.slashCommands[session] != commands { self.slashCommands[session] = commands }
      }
    }
  }

  /// Reads which MCP servers the conversation can load. A failed read keeps the last answer and shows no error.
  func loadMCPServers(_ session: String) {
    let send = send
    poller.async {
      guard let answer = try? send("manager-mcp", ["session": .string(session)]) else { return }
      Task { @MainActor in self.storeMCPAnswer(answer, for: session) }
    }
  }

  enum MCPChange {
    case add(String)
    case remove(String)
    case all, none

    var args: [String: JSON] {
      switch self {
      case .add(let name): ["add": [.string(name)]]
      case .remove(let name): ["rm": [.string(name)]]
      case .all: ["all": true]
      case .none: ["none": true]
      }
    }
  }

  func changeMCPServers(_ session: String, _ change: MCPChange) {
    perform("manager-mcp", change.args.merging(["session": .string(session)]) { $1 }) {
      self.storeMCPAnswer($0, for: session)
    }
  }

  private func storeMCPAnswer(_ value: JSON, for session: String) {
    if let answer = try? JSONCoding.convert(value, to: ManagerMCPAnswer.self), mcpAnswers[session] != answer {
      mcpAnswers[session] = answer
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

  /// Reads the blocks of the session's recent assistant messages for the copy buttons in its Claude terminal.
  /// A failed read gives no blocks, so a quote's button copies the screen's text.
  func loadBlockSources(_ session: String, then done: @escaping @MainActor @Sendable (BlockSources) -> Void) {
    let send = send
    poller.async {
      let messages = try? JSONCoding.convert(
        send(
          "chat-log",
          [
            "session": .string(session), "role": .string(ChatMessage.Role.assistant.rawValue),
            "limit": .number(Double(Self.blockSourceMessageCount)),
          ]),
        to: [ChatMessage].self)
      let sources = BlockSources(messages: (messages ?? []).reversed().map(\.text))
      Task { @MainActor in done(sources) }
    }
  }

  /// The transcript messages that the copy buttons match against. The count includes user messages, so fewer
  /// assistant messages come back.
  nonisolated static let blockSourceMessageCount = 20

  func messageDraft(for session: SessionSummary) -> MessageField.Draft {
    messageDrafts.draft(for: MessageDrafts.key(for: session))
  }

  /// What the user typed as the Other answer to one decision and has not sent.
  func otherAnswerDraft(session: String, ref: String, decision: Int) -> MessageField.Draft {
    messageDrafts.draft(for: MessageDrafts.otherAnswerKey(session: session, ref: ref, decision: decision))
  }

  /// The user's edit of a draft reply. An empty field starts again with `initial`, the session's text.
  func replyDraft(session: String, ref: String, number: Int, initial: String) -> MessageField.Draft {
    let field = replyField(session: session, ref: ref, number: number)
    if field.text.isEmpty { field.text = initial }
    return field
  }

  /// The user's edit of a draft reply, as it is. A view reads it here and fills an empty one on appearance, so
  /// that emptying the field doesn't refill it on the next refresh.
  func replyField(session: String, ref: String, number: Int) -> MessageField.Draft {
    messageDrafts.draft(for: MessageDrafts.replyKey(session: session, ref: ref, number: number))
  }

  /// Posts `text` as the reply of the item's draft `number`. sbd trims it, so the app sends the same text that
  /// `sb draft post` would. A second press does nothing until sbd answers the first.
  func postDraft(_ session: String, ref: String, number: Int, text: String) {
    let key = MessageDrafts.replyKey(session: session, ref: ref, number: number)
    guard postingDrafts.insert(key).inserted else { return }
    let args: [String: JSON] = [
      "session": .string(session), "ref": .string(ref), "draft": .number(Double(number)), "text": .string(text),
    ]
    perform(
      "draft-post", args, on: merges,
      then: { _ in
        self.draftErrors[key] = nil
        let field = self.replyField(session: session, ref: ref, number: number)
        if field.text == text { field.text = "" }
      },
      failed: { self.draftErrors[key] = "\($0)" },
      finally: { self.postingDrafts.remove(key) })
  }

  /// Asks sbd to read the draft's GitHub comment again, or to look for the reply of a post whose outcome it
  /// doesn't know. `draft-check` takes no ref. The ref only names the draft's error. A second press does nothing
  /// until sbd answers the first.
  func checkDraft(_ session: String, ref: String, number: Int) {
    let key = MessageDrafts.replyKey(session: session, ref: ref, number: number)
    guard checkingDrafts.insert(key).inserted else { return }
    perform(
      "draft-check", ["session": .string(session), "draft": .number(Double(number))], on: merges,
      then: { _ in self.draftErrors[key] = nil },
      failed: { self.draftErrors[key] = "\($0)" },
      finally: { self.checkingDrafts.remove(key) })
  }

  func draft(for card: Card) -> CardView.Draft {
    if let draft = drafts[card.id] { return draft }
    let draft = CardView.Draft()
    drafts[card.id] = draft
    return draft
  }
  /// A follow-up that hasn't started goes through `followup-rm`, which
  /// refuses it if it started since the board last read it. `resolve` holds the
  /// ids of the open to-dos that the confirmation showed.
  func remove(_ id: String, resolve: [String] = []) {
    let followup = board.first { $0.id == id }?.waitsToStart == true
    deselect([id])
    perform(followup ? "followup-rm" : "rm", Self.resolving(["session": .string(id)], resolve))
  }

  /// `args` with `resolve` set to `ids`. An empty `ids` adds no key.
  nonisolated static func resolving(_ args: [String: JSON], _ ids: [String]) -> [String: JSON] {
    var args = args
    if !ids.isEmpty { args["resolve"] = .array(ids.map(JSON.string)) }
    return args
  }

  func addNote(_ id: String, text: String, todo: Bool, added: (() -> Void)? = nil) {
    perform(
      "note",
      [
        "session": .string(id), "text": .string(text), "kind": .string((todo ? Note.Kind.todo : .note).rawValue),
        "by": .string(Author.you.rawValue),
      ],
      then: { _ in added?() })
  }

  func resolveNote(_ id: String, note: String) {
    perform("resolve-note", ["session": .string(id), "note": .string(note), "by": .string(Author.you.rawValue)])
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
      var text = "This stops claude, closes both terminals, and deletes " + englishList(parts) + "."
      if worktree != nil && branch == nil { text += " The branch stays, because its PR is not merged." }
      text +=
        " The conversation's transcript stays. sbd refuses a worktree with uncommitted files or commits on no remote branch, a worktree that a tool other than Supacode locked, a branch that is not at the merged PR's head, and a branch checked out in another worktree. A refusal before anything stops deletes nothing. A branch that fails its check after the worktree is gone stays, and the session and worktree are deleted anyway."
      return text
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
  nonisolated static func deleteRequest(_ s: SessionSummary, resolve: [String] = []) -> [String: JSON] {
    let plan = deletePlan(s)
    return resolving(
      [
        "session": .string(s.id), "worktree": .bool(plan.worktree != nil), "branch": .bool(plan.branch != nil),
        "remote_branch": .bool(plan.branch != nil),
      ], resolve)
  }

  /// Deletes a Done session with everything `deletePlan` names. sbd runs the safety checks of `rm`.
  func deleteDone(_ s: SessionSummary, resolve: [String] = []) {
    guard deleting.insert(s.id).inserted else { return }
    perform(
      "rm", Self.deleteRequest(s, resolve: resolve),
      then: { _ in self.deselect([s.id]) },
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
  func delete(_ id: String, branch: Bool = false, resolve: [String] = []) {
    let args: [String: JSON] = ["session": .string(id), "worktree": .bool(true), "branch": .bool(branch)]
    perform("rm", Self.resolving(args, resolve)) { _ in
      self.deselect([id])
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

  /// Puts the session's repository first in `knownRepos` at once. A New Session sheet opened before `new`
  /// returns preselects it, because the sheet's `repos` request waits behind `new` on `worker`.
  func create(_ args: NewSession) {
    guard let json = try? JSON(encoding: args).object else { return }
    if let repo = knownRepos?.first(where: { $0.path == args.path }) { moveToFront(repo) }
    perform("new", json) { value in
      if let id = value["id"]?.string { self.selectUnlisted(id) }
    }
  }

  func loadRepos() {
    perform(
      "repos", [:],
      then: { self.knownRepos = (try? JSONCoding.convert($0, to: [KnownRepo].self)) ?? [] },
      failed: { _ in self.knownRepos = self.knownRepos ?? [] })
  }

  /// Asks sbd to add the repository that holds `path` and puts it first in `knownRepos`.
  func addRepo(_ path: String, then: @escaping (Result<KnownRepo, Error>) -> Void) {
    perform(
      "repo-add", ["path": .string(path.expandingTilde)],
      then: { value in
        let result = Result { try JSONCoding.convert(value, to: KnownRepo.self) }
        if let repo = try? result.get() { self.moveToFront(repo) }
        then(result)
      },
      failed: { then(.failure($0)) })
  }

  /// Puts `repo` first in `knownRepos` and drops any other row with its path.
  private func moveToFront(_ repo: KnownRepo) {
    knownRepos = [repo] + (knownRepos ?? []).filter { $0.path != repo.path }
  }

  /// The Claude sessions that the import sheet offers. It blocks, so it runs
  /// off the main thread.
  nonisolated func importable(all: Bool, repo: String?) -> Result<ImportList, Error> {
    Result { try client.importable(all: all, repo: repo) }
  }

  nonisolated func importSessions(_ refs: [String], stop: [String]) -> Result<ImportResult, Error> {
    Result { try client.importSessions(refs, stop: stop) }
  }

  /// Clears the selected session and shows a main view.
  func show(_ view: MainView) {
    navigate {
      selection = nil
      mainView = view
    }
  }

  /// Opens a Board card. A session in the Inbox list is focused there and
  /// scrolled into view. Any other session opens directly, because the Inbox
  /// has no row for it.
  func openFromBoard(_ id: String) {
    guard triage.contains(where: { $0.id == id }) else {
      selection = id
      return
    }
    navigate {
      show(.inbox)
      inboxFocus = id
    }
    inboxJumps += 1
  }

  /// Focuses the Inbox item `step` places after the current one. With `wrap`,
  /// the step goes around the end of the list, else it stops there.
  func moveInbox(by step: Int, wrap: Bool = true) {
    guard let next = ListStep.step(triage.map(\.id), from: currentInboxItem, by: step, wrap: wrap) else { return }
    inboxFocus = next
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
  /// False when the change only moves sessions to the active account.
  var switches: Bool
  var id: String { folder }
  var name: String { ClaudeAccount.name(folder) }
}
