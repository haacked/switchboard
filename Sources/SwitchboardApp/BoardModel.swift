import AppKit
import Combine
import Foundation
import SwitchboardCore
import UserNotifications

/// The views that the detail pane shows while no session is selected.
enum MainView: CaseIterable {
  case inbox
  case board
  case issues
  case loops

  var title: String {
    switch self {
    case .inbox: "Inbox"
    case .board: "Board"
    case .issues: "Issues"
    case .loops: "Loops"
    }
  }

  var symbol: String {
    switch self {
    case .inbox: "tray"
    case .board: "square.grid.3x3"
    case .issues: "smallcircle.filled.circle"
    case .loops: "clock.arrow.circlepath"
    }
  }

  /// The key that, with ⌘, shows the view from the Session menu.
  var shortcutKey: Character {
    switch self {
    case .inbox: "1"
    case .board: "2"
    case .issues: "3"
    case .loops: "4"
    }
  }
}

/// The app's view of sbd. It polls `ls` once a second, because sbd keeps
/// state in memory and answers in a few milliseconds.
@MainActor
final class BoardModel: ObservableObject {
  /// The sessions that the filter shows and sbd's removal job does not hold. Every list, count, badge,
  /// and action target reads this. A lookup of a session that a shown session
  /// names, such as a card's asker or a parent, reads `allSessions` or
  /// `allBoard`, because that session may be hidden.
  var sessions: [SessionSummary] {
    let filter = filter
    return allSessions.filter { !$0.isBeingRemoved && filter.shows($0) }
  }
  /// Every session that sbd lists, whatever the filter says, including the sessions that the removal job holds.
  @Published private(set) var allSessions: [SessionSummary] = []
  /// What every list, count, and action target filters by. The installed app saves its org and group keys. Its
  /// `knownGroups` comes from sbd's last `group-ls` answer, so a local change such as a delete does not change
  /// it before sbd confirms the change.
  @Published var filter: SessionFilter {
    didSet {
      guard filter != oldValue else { return }
      if filter.org != oldValue.org { viewSettingsStore?.set(filter.org.keys.sorted(), forKey: Self.orgFilterKey) }
      if filter.group != oldValue.group {
        viewSettingsStore?.set(filter.group.keys.sorted(), forKey: Self.groupFilterKey)
      }
      clearHiddenSelectionAndUpdateBadge()
    }
  }
  /// The GitHub orgs whose sessions the app shows.
  var orgFilter: OrgFilter {
    get { filter.org }
    set { filter.org = newValue }
  }
  /// The groups whose sessions the app shows.
  var groupFilter: GroupFilter {
    get { filter.group }
    set { filter.group = newValue }
  }
  /// The groups that the user made while the group filter was on, with how many more `group-ls` answers may lack
  /// them before they leave the filter. An answer read before the creation lacks them, and it must not drop them.
  /// An answer that lists a group, or the last one allowed to lack it, ends its exemption.
  private var unlistedNewGroups: [String: Int] = [:]
  @Published var showingFilter = false
  /// Decides when a session tile's hover card shows. Tests replace it.
  var hoverCard: HoverCard<String>?
  /// Decides when a reference's hover card shows. Tests replace it.
  var referenceCard: HoverCard<ReferenceCardID>?
  let references: ReferenceStore
  /// Why sbd can't be reached, or nil while it answers.
  @Published var unreachable: String?
  /// The last failed action, shown until the next one succeeds.
  @Published var actionError: String?
  /// Selecting a session that the filter hides changes the filter to show it. The filter change runs inside
  /// the navigation, so it records nothing of its own. Every change ends a multi-selection.
  @Published var selection: String? {
    didSet {
      if !multiSelection.isEmpty { multiSelection = [] }
      navigate { if let selection, selection != oldValue { showHidden(selection) } }
    }
  }
  /// The sessions that the sidebar selects with ⌘-click or ⇧-click, or the Board with a click or a rectangle:
  /// two or more ids, or none. While the Board shows, it can also hold one id. `selection` stays the one
  /// session that history records, and stays nil while the Board shows a selection. `sidebarSelection` sets it.
  @Published var multiSelection: Set<String> = [] {
    didSet { if multiSelection.isEmpty { boardSelectionAnchor = nil } }
  }
  /// The card that a Board ⇧-click extends the selection from: the last card clicked or ⌘-clicked.
  var boardSelectionAnchor: String?
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
  /// The Delete All sheet's confirmation, or nil while the sheet doesn't ask.
  @Published var doneRemoval: DoneRemoval?
  /// The branches that sbd's removal job kept after it forgot their sessions, read with `removal-notices` in a
  /// refresh after an `ls` that listed a held session, while a notice shows, and every 5 s.
  @Published var removalNotices: [RemovalNotice] = []
  /// The failed removals whose Retry or Keep is on its way to sbd, and the queued ones whose Undo is.
  @Published var answeringRemovals: Set<String> = []
  var showingDoneRemoval: Bool { doneRemoval != nil }
  /// The quick-ask panel's state, or nil while it is closed.
  @Published var quickAsk: QuickAskState?
  /// The New Loop… or Edit… sheet's opening, or nil while it is closed. A save closes it once sbd accepts the loop.
  @Published var loopEditor: LoopEditorRequest? {
    didSet {
      loopEditorOpening += 1
      loopEditorError = nil
    }
  }
  /// sbd's refusal of the open loop editor's last save.
  @Published var loopEditorError: String?
  /// Changes on every open and close of the loop editor, so a late save answer can tell a reopened editor from its own.
  private(set) var loopEditorOpening = 0
  /// A loop editor's save is on its way to sbd, so a second Save would add a second loop.
  @Published var savingLoop = false
  var presentingSheet: Bool {
    newSession != nil || showingImport || showingSearch || showingDoneRemoval || showingIssueSetup || quickAsk != nil
      || pickingSnoozeTime != nil || pickingPauseTime != nil || loopEditor != nil
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
  /// The Board card that a click, the arrow keys, or Next and Previous Session last moved to.
  @Published var boardFocus: String?
  /// Counts the focus moves that scroll the Board to the focused card: the arrow keys and Next and Previous
  /// Session. A click moves the focus without a scroll, which would put another card under a double click's
  /// second click.
  @Published var boardJumps = 0
  /// Counts ⌘L presses and session steps. The list that `listFocusTarget` names takes keyboard focus on each one.
  @Published var listFocusRequests = 0
  /// The session whose Claude terminal takes keyboard focus when it shows. The terminal clears it.
  @Published var terminalFocus: String?
  /// The session whose empty Message Claude field shows under its terminal. A field with a draft always shows.
  @Published var revealedMessageField: String?
  /// The session whose Message Claude field takes keyboard focus when it shows. The field clears it.
  @Published var messageFieldFocus: String?
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
  /// transcripts, by session id. `hook` is the `lastReply` that the read was for.
  @Published var replies: [String: (hook: String?, text: String)] = [:]
  /// The newest events of the sessions whose card details the Inbox showed,
  /// oldest first, by session id.
  @Published var recentEvents: [String: [Event]] = [:]
  /// The transcript steps that lead up to each session's Inbox item, by session id.
  @Published var itemContexts: [String: ItemContext] = [:]
  /// Each Manager conversation's last messages, by session id, read while its status strip shows.
  @Published var chatLogs: [String: [ChatMessage]] = [:]
  /// Each Manager conversation's last `manager-mcp` answer, by session id, read while its pane shows.
  @Published var mcpAnswers: [String: ManagerMCPAnswer] = [:]
  /// The commands that each session's claude takes after `/`, by session id, read when a message field's list opens.
  @Published var slashCommands: [String: [SlashCommand]] = [:]
  /// The work-skill command that each Manager conversation's or the operator's pane holds back, by session id.
  @Published var workSkillOffers: [String: WorkSkillOffer] = [:]
  /// The watch on each offer's draft, which closes the offer when the user edits the draft.
  var workSkillOfferWatches: [String: AnyCancellable] = [:]
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
  /// Sessions whose snooze or unsnooze is on its way to sbd.
  @Published var snoozing: Set<String> = []
  /// The session whose snooze end the Pick a Time… sheet asks for.
  @Published var pickingSnoozeTime: String?
  /// The session whose pause end the Pick a Time… sheet of the Pause menu asks for.
  @Published var pickingPauseTime: String?
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
  /// Sessions whose wake is on its way to sbd, so a burst of keys sends one request at a time. No view reads it.
  private(set) var waking: Set<String> = []
  /// Group suggestions whose Accept or Decline is on its way to sbd. Their
  /// rows stay disabled until sbd replies, so a second click can't answer again.
  @Published var answeringSuggestions: Set<String> = []
  /// The plan rows, as `<plan> <row>`, whose follow-up sbd is making.
  @Published var followingUp: Set<String> = []
  /// Artifact plans whose Apply or Reject is on its way to sbd. Their buttons
  /// stay disabled until sbd replies, so a second click can't answer again.
  @Published var answeringArtifacts: Set<String> = []
  /// The artifacts, as `<group> <url>`, that "Use as plan" is attaching. Their buttons stay disabled until sbd
  /// replies, so a second click can't ask the group's chat to read the artifact again.
  @Published var usingAsPlan: Set<String> = []
  /// The decision requests that wait for sbd: `<session>/<number>` for an
  /// answer, `<session>/ask` for a question, and `<session>/submit` and `<session>/discard`.
  @Published var deciding: Set<String> = []
  /// sbd's refusal of the last decision request, by session. The card shows it.
  @Published var decisionErrors: [String: String] = [:]
  /// The step that each session's step view shows, by session id, with the ref of the list that the step belongs
  /// to. Nil shows the first unanswered decision.
  @Published private(set) var decisionSteps: [String: DecisionStepEntry] = [:]
  /// sbd's refusal of the last Clear wait, by session. The wait panel shows it.
  @Published var waitErrors: [String: String] = [:]
  /// The waits, as `<session>/<wait>`, whose Clear wait sbd has not answered. Their buttons stay disabled, so a
  /// second click can't send it again.
  @Published var clearingWaits: Set<String> = []
  /// The reply keys of the drafts whose `draft-post` sbd has not answered.
  @Published var postingDrafts: Set<String> = []
  /// The reply keys of the drafts whose `draft-check` sbd has not answered.
  @Published var checkingDrafts: Set<String> = []
  /// sbd's refusal of a draft's last post or check, by reply key.
  @Published var draftErrors: [String: String] = [:]
  /// Whether the sidebar shows the archived Manager conversations.
  @Published var showingArchive = false
  /// The sidebar sections that the user collapsed. Follow-ups that haven't
  /// started can number in the hundreds, so their section starts collapsed.
  @Published var collapsed: Set<AttentionState> = [.notStarted]
  /// Follow-ups that wait to start, from `followup-ls`. `ls` also lists the
  /// ones whose trigger fired. They change only through actions and
  /// triggers, so the app reads them every 5 s.
  var followups: [SessionSummary] { allFollowups.filter(filter.shows) }
  /// Every follow-up that waits to start, whatever the org filter says.
  @Published private(set) var allFollowups: [SessionSummary] = []
  /// The names of every session that `ls`, `followup-ls`, or `removed-ls`
  /// listed while the app runs, whatever the org filter says.
  @Published private(set) var sessionNames = SessionNames.empty
  /// Each id that `ls` or `followup-ls` listed, with its last name. An id
  /// that leaves both lists keeps its name, so its mentions do not flicker
  /// back to the id before `removed-ls` lists it.
  private var listedNames: [String: String] = [:]
  /// The names from `removed-ls`. A later read that leaves an id out does not remove it.
  private var tombstones: [String: String] = [:]
  /// The next refresh reads `removed-ls`. It starts true, and an id that
  /// leaves `ls` sets it. A read that fails sets it again. So does a read
  /// that `apply` drops because `ls` failed.
  private(set) var readRemovedNext = true
  /// The ids and names that `updateSessionNames` last built the directory from.
  private var lastListed: [(id: String, name: String)] = []
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
  /// Whether the Issues list leaves out the backlog issues and shows only their count. The installed app saves it.
  @Published var hidesBacklog: Bool {
    didSet { if hidesBacklog != oldValue { viewSettingsStore?.set(hidesBacklog, forKey: Self.hidesBacklogKey) } }
  }
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
  /// The loop that the user last moved to in the Loops view, by schedule id.
  @Published var loopFocus: String?
  /// Counts moves in the Loops view. Each one scrolls to the current loop.
  @Published var loopJumps = 0
  /// The Loops view's order. The installed app saves it in its view settings.
  @Published var loopSort: LoopSort {
    didSet { if loopSort != oldValue { viewSettingsStore?.set(loopSort.rawValue, forKey: Self.loopSortKey) } }
  }
  /// The session whose loops the Loops view lists, by id. Nil lists every shown session's loops.
  @Published var loopSessionFilter: String?
  /// The Operator's work, newest first, as the Loops view's Background Activity lists it.
  @Published var backgroundActivity: [BackgroundActivity.Entry] = []
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
  /// A move of one session to another account that waits for the user to confirm it.
  @Published var confirmingAccountMove: SessionAccountMove?
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
  /// The undo manager that Edit > Undo reads for the session menu's actions. Tests replace it.
  var actionUndoManager: () -> UndoManager? = { NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager }
  /// Posts the notification that a session needs the user. Tests replace it.
  lazy var notifier: @MainActor (SessionSummary) -> Void = { [weak self] s in self?.notify(s) }
  /// Sends a quick ask to sbd. Tests replace it.
  lazy var ask: @Sendable (String, CallCancel) throws -> JSON = { [client = self.client] question, cancel in
    try client.call("quick-ask", ["question": .string(question)], timeout: QuickAsk.clientTimeout, cancel: cancel)
  }
  /// Quick asks run apart from `worker`, because one can take a minute and `worker` runs one action at a time.
  let quickAskWork = DispatchQueue(label: "switchboard.quick-ask")
  /// Cancels the running quick ask. Only the ask that holds this token may show its result.
  var quickAskCancel: CallCancel?
  /// Polls run apart from actions, because an action such as `open` or `new`
  /// can take seconds.
  private let poller = DispatchQueue(label: "switchboard.poll")
  /// Issue reads and Starts, which wait on GitHub, gh, or git. They run here so the session list and other
  /// actions do not wait behind them.
  let issueWork = DispatchQueue(label: "switchboard.issues", attributes: .concurrent)
  /// Item-context and reply reads, which can take seconds for a long or remote transcript. They run apart from the
  /// poll. The queue is serial, so two reads for one session answer in the order the user asked for them.
  private let contextWork = DispatchQueue(label: "switchboard.context")
  private let worker = DispatchQueue(label: "switchboard.actions")
  /// Undo's `rm-cancel` must reach sbd before the removals' `notBefore`, so it does not wait behind a slow action
  /// on `worker`, such as the header's `rm --worktree`.
  let undos = DispatchQueue(label: "switchboard.undo")
  /// Merges wait on gh for up to 120 s, and review requests for up to 60 s.
  /// They run apart from other actions and from each other.
  private let merges = DispatchQueue(label: "switchboard.merges", attributes: .concurrent)
  /// A plan apply waits for sbd's GitHub poll and then writes to GitHub, so
  /// it runs apart from other actions too. An artifact attach runs here because
  /// it can wait for the group's chat to start.
  private let planWrites = DispatchQueue(label: "switchboard.plan-writes", attributes: .concurrent)
  private var timer: Timer?
  /// Whether Switchboard is the active app. A chat's replies count as read only while it is. Tests replace it.
  var isAppActive: () -> Bool = { NSApp.isActive }
  /// The last `chat-read` sent, so each refresh doesn't send it again.
  var lastChatRead: (session: String, replies: Int)?
  /// Each session as the last refresh listed it.
  private var lastSeen: [String: SessionSummary] = [:]
  /// The session that `create` or `openManager` selected before a refresh
  /// listed it.
  private(set) var pendingSelection: String?
  /// The link target that `focus` named before a refresh listed its session,
  /// the successful refreshes that have not listed it, and the selection when
  /// it started. It waits for `focusRefreshLimit` refreshes. Selecting another
  /// session ends it.
  private var focusWait: (target: SessionLink.Target, misses: Int, selection: String?)?
  var pendingFocus: SessionLink.Target? { focusWait?.target }
  private static let focusRefreshLimit = 3
  private var loaded = false
  private var followupsRead = Date.distantPast
  /// Whether the next refresh reads `followup-ls` and the other lists that it reads every 5 s.
  var followupsDue: Bool { Date().timeIntervalSince(followupsRead) >= 5 }
  /// sbd reads the usage every few minutes, so the app asks once a minute.
  private var usageRead = Date.distantPast

  static let orgFilterKey = "orgFilter"
  static let groupFilterKey = "groupFilter"
  static let hidesBacklogKey = "issuesHideBacklog"
  static let loopSortKey = "loopsSort"
  /// Where the org filter, the group filter, and the other saved view settings are saved. It is nil outside the
  /// installed app, so a debug or test run never saves a setting that changes a later run.
  private let viewSettingsStore: UserDefaults?

  /// Takes the client so that tests can't reach the user's sbd by default.
  /// Without `draftsFolder`, the message drafts last only while the model does.
  /// Each filter starts from `viewSettingsStore` when it holds one, else from `orgFilter` or `groupFilter`.
  init(
    client: Client, draftsFolder: String? = nil, viewSettingsStore: UserDefaults? = nil,
    orgFilter: OrgFilter = OrgFilter(), groupFilter: GroupFilter = GroupFilter()
  ) {
    self.client = client
    references = ReferenceStore()
    messageDrafts = MessageDrafts(folder: draftsFolder)
    self.viewSettingsStore = viewSettingsStore
    filter = SessionFilter(
      org: viewSettingsStore?.stringArray(forKey: Self.orgFilterKey).map { OrgFilter(keys: $0) } ?? orgFilter,
      group: viewSettingsStore?.stringArray(forKey: Self.groupFilterKey).map { GroupFilter(keys: $0) } ?? groupFilter)
    hidesBacklog = viewSettingsStore?.bool(forKey: Self.hidesBacklogKey) ?? false
    loopSort = viewSettingsStore?.string(forKey: Self.loopSortKey).flatMap(LoopSort.init) ?? .status
    makeHoverCards()
  }

  /// Clears a selection that the filter hides or the removal job holds, drops those sessions from the
  /// multi-selection, closes the hover card of a session that is no longer shown, and counts the shown sessions
  /// in the Dock badge. The current history entry follows what the window shows, because a refresh can change
  /// the Inbox's first item.
  private func clearHiddenSelectionAndUpdateBadge() {
    let listed = shownIDs
    navigate(.replace) {
      // Clearing `selection` ends the multi-selection and can show the Board, so both are read first.
      let multi = multiSelection.intersection(listed)
      let onBoard = visibleView == .board
      if let id = selection, id != pendingSelection, !listed.contains(id) { selection = nil }
      keepMultiSelection(multi, onBoard: onBoard)
    }
    hoverCard?.sessionsChanged(shown: listed)
    if NSApp != nil { NSApp.dockTile.badgeLabel = needsUser.isEmpty ? nil : "\(needsUser.count)" }
  }

  /// Changes the session before sbd lists the change.
  func update(_ id: String, _ change: (inout SessionSummary) -> Void) {
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

  /// `allBoard` without the sessions that sbd's removal job holds.
  var listedBoard: [SessionSummary] { allBoard.filter { !$0.isBeingRemoved } }

  /// The ids of the sessions and follow-ups that the filter shows.
  var shownIDs: Set<String> { Set(board.map(\.id)) }

  /// The ids that Delete All may remove. Under an org filter, a session whose org sbd hasn't read yet shows but
  /// isn't removable, because its org may be one that the filter hides. Under a group filter, no session is
  /// removable before sbd's first `group-ls` answer, because a session's group may be one that sbd deleted.
  var removableIDs: Set<String> {
    let filter = filter
    return Set(listedBoard.filter(filter.surelyShows).map(\.id))
  }

  /// The org filter's menu rows, counted over the sessions that the group filter shows and the removal job does
  /// not hold. A row's count is then how many sessions checking it adds.
  var orgEntries: [FilterEntry] {
    orgFilter.entries(listedBoard.filter(filter.groupShows))
  }

  /// The group filter's menu rows, counted over the sessions that the org filter shows and the removal job does
  /// not hold.
  var groupEntries: [FilterEntry] {
    groupFilter.entries(listedBoard.filter(orgFilter.shows), groups: groups, known: filter.knownGroups)
  }

  /// The groups that the Board shows: the ones that the group filter selects, and under an org filter, only
  /// those that are empty or have a member that the filter shows.
  var shownGroups: [GroupSummary] {
    let filter = filter
    guard !filter.isAll else { return groups }
    let shown = filter.org.isAll ? [] : shownIDs
    return groups.filter { g in
      (filter.group.isAll || filter.group.keys.contains(g.id))
        && (filter.org.isAll || g.sessions.isEmpty || g.sessions.contains(where: shown.contains))
    }
  }

  /// True when the filters hide every work session that sbd lists. The Manager always shows, so only work
  /// sessions count.
  var filterHidesAllWork: Bool {
    !filter.isAll && workBoard.isEmpty && listedBoard.contains { $0.kind == .work }
  }

  /// Sets both filters to show every session.
  func showAll() {
    filter = SessionFilter(knownGroups: filter.knownGroups)
  }

  /// Takes sbd's `group-ls` answer. A selected group that the answer lacks leaves the filter, unless the user
  /// just made it and no answer has listed it yet. The filter widens to keep the selected session in sight when
  /// the answer moves it out of the selected groups, as a merge or a delete does.
  func applyGroups(_ listed: [GroupSummary]) {
    if groups != listed { groups = listed }
    let next = filter(after: listed, sessions: allBoard)
    let ids = Set(listed.map(\.id))
    unlistedNewGroups = unlistedNewGroups.filter { !ids.contains($0.key) && $0.value > 1 }.mapValues { $0 - 1 }
    if next != filter { filter = next }
  }

  /// The filter once it takes sbd's `group-ls` answer `listed`, widened to keep the selected session in sight
  /// as `sessions` lists it. A session that the removal job holds never widens it.
  func filter(after listed: [GroupSummary], sessions: [SessionSummary]) -> SessionFilter {
    let ids = Set(listed.map(\.id))
    var next = filter
    next.knownGroups = ids
    next.group = filter.group.pruned(known: ids.union(unlistedNewGroups.keys))
    if let id = selection, let s = sessions.first(where: { $0.id == id && !$0.isBeingRemoved }) {
      next = widened(next, toShow: s)
    }
    return next
  }

  /// Adds the group that sbd's answer names to a group filter that is on, so the group that the user just made
  /// stays in sight.
  func showAnsweredGroup(_ answer: JSON) {
    guard !groupFilter.isAll, let id = answer["id"]?.string else { return }
    if filter.knownGroups?.contains(id) != true { unlistedNewGroups[id] = 2 }
    groupFilter.insert(id)
  }

  /// The group suggestions whose sessions the filter all shows, so accepting
  /// one never moves a hidden session.
  var shownSuggestions: [GroupSuggestion] {
    guard !filter.isAll else { return suggestions }
    let shown = shownIDs
    return suggestions.filter { $0.sessions.allSatisfy(shown.contains) }
  }

  /// How many sessions and follow-ups the filter hides.
  var hiddenCount: Int { listedBoard.count - board.count }
  /// How many hidden sessions would be in the Inbox.
  var hiddenNeedingYou: Int { listedBoard.filter(Triage.needsYou).count - board.filter(Triage.needsYou).count }

  /// Changes the filter to show the session when it hides it, so a session
  /// that the app opens never stays out of sight.
  func showHidden(_ id: String) {
    // An insert of a key that the filter already holds still publishes. `apply` calls this every second.
    guard let s = listedBoard.first(where: { $0.id == id }) else { return }
    let next = widened(filter, toShow: s)
    if next != filter { filter = next }
  }

  /// `filter` with the keys added that it needs to show the listed session `id`.
  private func widened(_ filter: SessionFilter, toShow s: SessionSummary) -> SessionFilter {
    guard !filter.isAll, !filter.shows(s) else { return filter }
    var next = filter
    if !filter.org.shows(s), let key = OrgFilter.key(of: s) { next.org.insert(key) }
    if !filter.groupShows(s), let key = filter.groupKey(of: s) { next.group.insert(key) }
    return next
  }

  /// The Manager and a group chat count only while a prompt blocks them. The
  /// toolbar star fills and turns the Needs you color while the Manager needs you.
  var needsUser: [SessionSummary] { sessions.filter(Triage.needsYou) }

  /// The Manager conversations, newest activity first, as `sb manager ls` lists them.
  var managers: [SessionSummary] {
    sessions.filter { $0.kind == .manager }.sorted(by: Manager.newestFirst)
  }

  /// The Manager conversation that the toolbar star names while one waits on the user.
  var waitingManager: SessionSummary? { managers.first { ChatMark($0).needsMeReason != nil } }

  /// The operator. It reads every listed session, because the filter can hide the operator.
  var operatorSession: SessionSummary? { Self.operatorSession(in: allSessions) }

  /// The operator among `sessions`, or nil before sbd first creates it. With more than one, it is the oldest, as in
  /// sbd.
  static func operatorSession(in sessions: [SessionSummary]) -> SessionSummary? {
    sessions.filter { !$0.isBeingRemoved && $0.kind == .operator }.min {
      ($0.created ?? 0, $0.id) < ($1.created ?? 0, $1.id)
    }
  }

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
  /// It reads every listed session, because the group filter can hide the chat.
  func chat(of group: String) -> SessionSummary? {
    allSessions.first { !$0.isBeingRemoved && $0.kind == .chat && $0.chat == group }
  }

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

  /// The count that the view picker shows next to `view`'s title.
  func viewCount(_ view: MainView, now: Int64) -> Int {
    switch view {
    case .inbox: triage.count
    case .board: 0
    case .issues: issueCount
    case .loops: loopAttentionCount(now: now)
    }
  }

  /// The repo label of each session in the sidebar. The Inbox uses the same
  /// labels. A session therefore shows the same repo in both lists.
  var repoLabels: [String: String] { RepoLabels.labels(board) }

  /// The sessions and the follow-ups that wait to start, as the filter shows them.
  var board: [SessionSummary] { listedBoard.filter(filter.shows) }

  var selected: SessionSummary? { board.first { $0.id == selection } }

  /// True while the sidebar has no rows and sbd answers. It is false when the filters hide every work session,
  /// because the sidebar then shows `FilterHidesAll` instead.
  var sidebarIsEmpty: Bool {
    sidebarGroups.isEmpty && managers.isEmpty && unreachable == nil && !filterHidesAllWork
  }

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
    referenceCard?.closeOnEvents()
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
    let readFollowups = followups || followupsDue
    if readFollowups { followupsRead = Date() }
    let readUsage = Date().timeIntervalSince(usageRead) >= 60
    if readUsage { usageRead = Date() }
    let readNotices = readFollowups || !removalNotices.isEmpty || allSessions.contains(where: \.isBeingRemoved)
    let readRemoved = takeRemovedRead()
    poller.async {
      let (result, more) = Self.read(
        sessions: client.sessions,
        followups: readFollowups ? { try client.call("followup-ls", as: [SessionSummary].self) } : nil)
      let accounts = readFollowups ? try? client.accounts() : nil
      let groups = try? client.call("group-ls", as: GroupList.self).groups
      let notices = readNotices ? try? client.call("removal-notices", as: [RemovalNotice].self) : nil
      let suggestions = readFollowups ? try? client.call("group-suggest", as: [GroupSuggestion].self) : nil
      let proposals = readFollowups ? try? client.call("plan-proposals", as: [PlanProposal].self) : nil
      let issues = readFollowups ? try? client.call("issues", as: IssueList.self) : nil
      let usage = readUsage ? try? client.usage() : nil
      let removed = readRemoved ? try? client.call("removed-ls", as: [RemovedSession].self) : nil
      Task { @MainActor in
        if let accounts, self.accounts != accounts { self.accounts = accounts }
        if let suggestions, self.suggestions != suggestions { self.suggestions = suggestions }
        if let proposals, self.planProposals != proposals { self.planProposals = proposals }
        if let issues, self.issueList != issues { self.issueList = issues }
        if let usage, self.usage != usage { self.usage = usage }
        if let notices, self.removalNotices != notices { self.removalNotices = notices }
        self.apply(result, followups: more, groups: groups, removed: removed, readRemoved: readRemoved)
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

  /// Returns whether this refresh reads `removed-ls`, and clears `readRemovedNext`.
  func takeRemovedRead() -> Bool {
    defer { readRemovedNext = false }
    return readRemovedNext
  }

  /// A nil `followups`, `groups`, or `removed` means the refresh did not read that list.
  /// `readRemoved` says whether it tried to read `removed-ls`.
  func apply(
    _ result: Result<[SessionSummary], Error>, followups more: [SessionSummary]?, groups: [GroupSummary]? = nil,
    removed: [RemovedSession]? = nil, readRemoved: Bool = false
  ) {
    if readRemoved, removed == nil || (try? result.get()) == nil { readRemovedNext = true }
    switch result {
    case .success(let list):
      // Assigning a @Published property republishes even an equal value. A
      // refresh every second would redraw the views each time.
      if unreachable != nil { unreachable = nil }
      if let more, allFollowups != more { allFollowups = more }
      if !Set(allSessions.map(\.id)).isSubset(of: list.map(\.id)) { readRemovedNext = true }
      // Before the notifications, so that a body naming a session from this refresh resolves.
      updateSessionNames(list + allFollowups, removed: removed)
      // Only shown sessions notify. The last seen sessions cover every session.
      // Widening the filter later therefore sends nothing for a change that happened while the session was hidden.
      let filterAfter = groups.map { filter(after: $0, sessions: list) } ?? filter
      if loaded { sessionsToNotify(list, filter: filterAfter).forEach(notifier) }
      // A hidden session keeps its drafts.
      let open = Set(list.flatMap { $0.cards.map(\.id) })
      drafts = drafts.filter { open.contains($0.key) }
      messageDrafts.prune(
        keeping: Set(list.map(MessageDrafts.key)).union(MessageDrafts.decisionKeys(list))
          .union(MessageDrafts.replyKeys(list)).union(MessageDrafts.operatorAnswerKeys(list)))
      let ids = Set(list.map(\.id))
      if decisionSteps.keys.contains(where: { !ids.contains($0) }) {
        decisionSteps = decisionSteps.filter { ids.contains($0.key) }
      }
      if !sameShown(allSessions, list) { allSessions = list }
      // After the new list, so that the filter change reads each session's group from the same poll as the groups.
      if let groups { applyGroups(groups) }
      // A filter change that hides the selection clears it in `filter.didSet`.
      // A selected session that is hidden here therefore had no known org until this refresh.
      if let id = selection { showHidden(id) }
      if let id = pendingSelection, allBoard.contains(where: { $0.id == id }) { pendingSelection = nil }
      resolvePendingFocus()
      clearHiddenSelectionAndUpdateBadge()
      // A follow-up that fires appears in `ls` as Needs you. The last seen sessions
      // include the follow-ups, so that change from Not started notifies.
      lastSeen = Dictionary(uniqueKeysWithValues: allBoard.map { ($0.id, $0) })
      loaded = true
      markSelectedChatRead()
    case .failure(let error):
      let problem = "\(error)"
      if unreachable != problem { unreachable = problem }
    }
  }

  private func updateSessionNames(_ listed: [SessionSummary], removed: [RemovedSession]?) {
    let unchanged =
      removed == nil && listed.count == lastListed.count
      && zip(listed, lastListed).allSatisfy { $0.id == $1.id && $0.name == $1.name }
    if unchanged { return }
    lastListed = listed.map { ($0.id, $0.name) }
    let live = Dictionary(listed.map { ($0.id, $0.name) }) { first, _ in first }
    listedNames.merge(live) { _, new in new }
    for r in removed ?? [] { tombstones[r.id] = r.name }
    let names = SessionNames(live: live, removed: listedNames.merging(tombstones) { _, tombstone in tombstone })
    if sessionNames != names { sessionNames = names }
  }

  /// The shown sessions that just entered the Inbox. A chat can need the user
  /// before its item reaches the Inbox. This therefore compares each session
  /// with its place in the last refresh's Inbox, not with its last state.
  /// `filter` is the filter as it will be after this refresh, and defaults to the current one.
  func sessionsToNotify(_ list: [SessionSummary], filter: SessionFilter? = nil) -> [SessionSummary] {
    let filter = filter ?? self.filter
    return list.filter { s in
      guard Triage.needsYou(s), !s.isBeingRemoved, let last = lastSeen[s.id], !Triage.needsYou(last),
        filter.shows(s)
      else { return false }
      // A follow-up that starts passes through Needs you until its first
      // prompt. Only a follow-up that fired and is still unstarted notifies.
      return last.state != .notStarted || s.waitsToStart
    }
  }

  /// The session's Inbox line, with names in place of ids. The menu bar and the notification both show it.
  func inboxLine(_ s: SessionSummary) -> String { sessionNames.replacingIDs(in: s.inboxTitle) }

  private func notify(_ s: SessionSummary) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = "\(inboxName(s)) needs you"
    content.body = inboxLine(s)
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

  /// Registers `handler` as the undo of an action named `name` on `actionUndoManager`. An answer from sbd arrives
  /// outside any event, so no undo group is open then. This opens one, because an undo manager that doesn't group
  /// by event refuses a registration outside a group. An undo or a redo has its own group open. The undo manager
  /// holds the model weakly.
  func registerUndo(named name: String, _ handler: @escaping @MainActor (BoardModel) -> Void) {
    guard let undo = actionUndoManager() else { return }
    let opens = undo.groupingLevel == 0
    if opens { undo.beginUndoGrouping() }
    undo.registerUndo(withTarget: self) { model in MainActor.assumeIsolated { handler(model) } }
    undo.setActionName(name)
    if opens { undo.endUndoGrouping() }
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

  /// Selects the operator. sbd creates it when none exists, and resumes a stopped one.
  func openOperator() {
    perform("operator", [:]) { value in
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
  /// Starts claude in a stopped session after a key or a click in its terminal. It sends `open`, not `resume`.
  /// sbd launches on `open` only while claude is stopped, so the keys that arrive before the summary shows
  /// claude starting do nothing. A second `resume` would fail with "already running".
  func wake(_ id: String) {
    guard waking.insert(id).inserted else { return }
    perform("open", ["session": .string(id)], finally: { self.waking.remove(id) })
  }
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
  static let stopHelp =
    "Stop claude now. It resumes when you click or type in its terminal, send it a message, or open the session again."
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
    groups[index].descriptionBy = nil
    if let clean {
      perform("group-describe", ["group": .string(id), "text": .string(clean)])
    } else {
      perform("group-describe", ["group": .string(id), "clear": true])
    }
    return true
  }
  /// The ids, in the given order, that `moveToGroup` would move to `group`: each names a work session on the
  /// Board that is not already in that lane. None qualify when sbd didn't list `group`.
  func movableIDs(_ ids: [String], to group: String?) -> [String] {
    let known = Set(groups.map(\.id))
    guard group.map(known.contains) ?? true else { return [] }
    let work = Dictionary(workBoard.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    return ids.filter { id in
      guard let session = work[id], seen.insert(id).inserted else { return false }
      return BoardRows.group(of: session, known: known) != group
    }
  }

  /// Moves work sessions to a group, or to no group when `group` is nil, in one request. The Board shows the
  /// cards in their new lane before sbd answers. Only the ids that `movableIDs` returns move. It returns whether
  /// it sent the move.
  @discardableResult
  func moveToGroup(_ ids: [String], _ group: String?) -> Bool {
    let moving = movableIDs(ids, to: group)
    guard !moving.isEmpty else { return false }
    for id in moving { update(id) { $0.group = group } }
    for id in moving { showHidden(id) }
    var args: [String: JSON] = ["sessions": .array(moving.map { .string($0) })]
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
    answer(id, in: \.answeringSuggestions, "group-suggest", [key: .string(id)], answered: showAnsweredGroup) {
      $0.suggestions.removeAll { $0.id == id }
    }
  }

  /// Sends an answer to an item once. `answering` holds the item's id until
  /// sbd replies. `remove` takes the item out of its list when sbd takes the
  /// answer. `answered` then gets sbd's answer.
  func answer(
    _ id: String, in answering: ReferenceWritableKeyPath<BoardModel, Set<String>>, _ op: String,
    _ args: [String: JSON], on queue: DispatchQueue? = nil, answered: ((JSON) -> Void)? = nil,
    remove: @escaping (BoardModel) -> Void
  ) {
    guard self[keyPath: answering].insert(id).inserted else { return }
    perform(
      op, args, on: queue,
      then: { result in
        remove(self)
        answered?(result)
      }, finally: { self[keyPath: answering].remove(id) })
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

  /// Attaches the artifact as a plan of the group. The group's chat reads it, which may start the chat. The
  /// request can wait on that start, so it runs on `planWrites`. `then` lists the plan on the group unless a
  /// refresh already did, so the row shows "Plan" as soon as its button turns back on.
  func useArtifactAsPlan(url: String, group: String) {
    let key = usingAsPlanKey(url: url, group: group)
    guard usingAsPlan.insert(key).inserted else { return }
    perform(
      "plan-attach", ["doc": .string(url), "group": .string(group)], on: planWrites,
      then: { result in
        guard let doc = try? JSONCoding.convert(result, to: PlanDocument.self),
          let g = self.groups.firstIndex(where: { $0.id == group }),
          self.groups[g].plans?.contains(where: { $0.id == doc.id }) != true
        else { return }
        self.groups[g].plans = (self.groups[g].plans ?? []) + [PlanSummary(doc)]
      },
      finally: { self.usingAsPlan.remove(key) })
  }

  func isUsingAsPlan(url: String, group: String) -> Bool {
    usingAsPlan.contains(usingAsPlanKey(url: url, group: group))
  }

  private func usingAsPlanKey(url: String, group: String) -> String { "\(group) \(url)" }

  private func followUpKey(plan: String, row: String) -> String { "\(plan) \(row)" }

  /// `sent` runs only when sbd accepted the message. A second send to the
  /// same session does nothing until sbd answers the first. Each image is a
  /// file name and the image's bytes. `ref` names the Inbox item that the
  /// message answers. `runHere` lets a work skill's command past a Manager's gate once.
  func send(
    _ id: String, _ text: String, images: [(name: String, data: Data)] = [], ref: String? = nil,
    runHere: Bool = false, sent: (() -> Void)? = nil
  ) {
    guard sending.insert(id).inserted else { return }
    var args: [String: JSON] = ["session": .string(id), "text": .string(text)]
    if let ref { args["ref"] = .string(ref) }
    if runHere { args["runHere"] = true }
    if !images.isEmpty { args["images"] = .array(images.map { Attachments.json(name: $0.name, data: $0.data) }) }
    perform("send", args, then: { _ in sent?() }, finally: { self.sending.remove(id) })
  }

  /// Opens the window when the user has closed it. The always-present menu bar item sets this.
  var showWindow: (() -> Void)?

  /// Selects the listed session as a sidebar click does and brings its window forward. A closed window opens
  /// first. A session that the app does not list is left alone.
  func reveal(_ id: String) {
    guard let session = summary(id) else { return }
    showInSidebar(session)
    showWindow?()
  }

  /// Reveals the session that an in-app session link names. It returns
  /// whether the URL has the app's scheme. A link that names no listed
  /// session sets the error banner at once, without a wait for a refresh.
  /// Every `switchboard:` URL counts as handled, so that Launch Services never
  /// hands the app's own link to another copy of the app.
  func openSessionLink(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == SessionLink.scheme else { return false }
    guard let target = SessionLink.target(from: url) else {
      actionError = Self.cantOpen(url)
      return true
    }
    let outcome = linkOutcome(target)
    if case .reveal(let s) = outcome {
      reveal(s.id)
    } else {
      actionError = outcome.error(for: target)
    }
    return true
  }

  /// Focuses the session that a URL from another app or from `sb focus` names.
  func openExternalLink(_ url: URL) {
    guard let target = SessionLink.target(from: url) else {
      actionError = Self.cantOpen(url)
      // The error banner shows only in the window.
      showWindow?()
      return
    }
    focus(target)
  }

  /// Closes the search panel, the quick-ask panel, and Recent Places, then shows the session as a
  /// sidebar click does. A session that no refresh has listed yet, such as one
  /// that `sb new` just made or any session at a cold launch, is focused when
  /// a refresh lists it.
  func focus(_ target: SessionLink.Target) {
    showingSearch = false
    closeQuickAsk()
    showingRecentPlaces = false
    focusWait = nil
    if !settleFocus(target) {
      focusWait = (target, 0, selection)
      // An unstarted follow-up shows only in `followup-ls`. A refresh reads
      // that list every 5 s, which can be after the wait gives up.
      followupsRead = .distantPast
      // A closed window has not started the refreshes that list the session.
      showWindow?()
    }
  }

  /// Reveals the session when a refresh lists it, or reports a removed one or
  /// a name that more than one session has. It returns false while the
  /// session can still appear.
  private func settleFocus(_ target: SessionLink.Target) -> Bool {
    switch linkOutcome(target) {
    case .reveal(let s):
      reveal(s.id)
    case .error(let text):
      actionError = text
      showWindow?()
    case .notListed:
      return false
    }
    return true
  }

  enum LinkOutcome {
    case reveal(SessionSummary)
    case error(String)
    /// No listed session matches, and a later refresh could list one.
    case notListed

    /// The error banner for `target`, or nil when the link reveals a session.
    func error(for target: SessionLink.Target) -> String? {
      switch self {
      case .reveal: nil
      case .error(let text): text
      case .notListed: BoardModel.unknownLinkError(target)
      }
    }
  }

  /// What a link target comes to against every listed session and follow-up,
  /// whatever the org filter says.
  func linkOutcome(_ target: SessionLink.Target) -> LinkOutcome {
    let sessions = allBoard
    switch SessionLink.resolve(target, in: sessions.lazy.map { (id: $0.id, name: $0.name) }) {
    case .session(let id):
      return sessions.first { $0.id == id }.map(LinkOutcome.reveal) ?? .notListed
    case .ambiguous(let count):
      return .error("\"\(Self.shown(target.text))\" names \(count) sessions. Use the session's id link.")
    case .unknown:
      guard case .id(let id) = target, sessionNames.entry(id)?.removed == true else { return .notListed }
      return .error("Session \(id) was removed")
    }
  }

  private func resolvePendingFocus() {
    guard let wait = focusWait else { return }
    focusWait = nil
    // The user picked another session while the focus waited.
    if selection != nil && selection != wait.selection { return }
    if settleFocus(wait.target) { return }
    if wait.misses + 1 >= Self.focusRefreshLimit {
      actionError = Self.unknownLinkError(wait.target)
    } else {
      focusWait = (wait.target, wait.misses + 1, wait.selection)
    }
  }

  private static func cantOpen(_ url: URL) -> String { "Switchboard can't open \(url.absoluteString)" }

  nonisolated static func unknownLinkError(_ target: SessionLink.Target) -> String {
    switch target {
    case .id: "Switchboard has no session \(target.text)"
    case .name: "Switchboard has no session named \"\(shown(target.text))\""
    }
  }

  /// A link's name with each format character, such as a bidi override or a
  /// zero-width space, written as its code point. The raw character would
  /// make the banner show text other than the name that the link holds.
  nonisolated static func shown(_ name: String) -> String {
    var text = ""
    for scalar in name.unicodeScalars {
      if scalar.properties.generalCategory == .format {
        text += String(format: "<U+%04X>", scalar.value)
      } else {
        text.unicodeScalars.append(scalar)
      }
    }
    return text
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
        let failed = (sent.deliveries ?? []).compactMap { d in
          d.error.map { "\(self.sessionNames.name(d.session)): \($0)" }
        }
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
    } else {
      stepInboxPast(id)
    }
    perform(
      "ack", args,
      then: { if undo { self.storeLastSeen(id, reply: $0) } },
      finally: { self.acknowledging.remove(id) })
  }

  /// Stores sbd's reply to a request by which the user put the session's item
  /// back in the Inbox. The next refresh then doesn't notify about the item.
  func storeLastSeen(_ id: String, reply: JSON) {
    if let s = try? JSONCoding.convert(reply, to: SessionSummary.self) { lastSeen[id] = s }
  }

  /// Moves the Inbox's focus to the next item when `id` is the current one,
  /// because the user set that item aside.
  func stepInboxPast(_ id: String) {
    guard currentInboxItem == id else { return }
    navigate(.replace) { moveInbox(by: 1) }
    // A field in the item that scrolls away would keep the keystrokes. A
    // session's terminal outside the Inbox keeps them.
    if visibleView == .inbox { NSApp.keyWindow?.makeFirstResponder(nil) }
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

  /// The step set for the list with `ref`. A list with another ref has no step, so a new list starts on its first
  /// unanswered decision.
  func decisionStep(session: String, ref: String) -> DecisionStep? {
    decisionSteps[session].flatMap { $0.ref == ref ? $0.step : nil }
  }

  /// Sets the step for the list with `ref`. A write for a list that the session no longer shows is dropped, because
  /// `DecisionStepView` sets the step after sbd accepts an answer, and the list can change in the meantime.
  func setDecisionStep(_ step: DecisionStep?, session: String, ref: String) {
    guard allSessions.first(where: { $0.id == session })?.stepList?.ref == ref else { return }
    let entry = step.map { DecisionStepEntry(ref: ref, step: $0) }
    if decisionSteps[session] != entry { decisionSteps[session] = entry }
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

  /// Asks the session about one decision of the list whose ref the user saw. `asked` runs once sbd accepts the
  /// question. sbd takes one question per session at a time, so a second ask waits for the first whatever its decision.
  func askDecision(_ session: String, ref: String, number: Int, text: String, asked: (() -> Void)? = nil) {
    let args: [String: JSON] = [
      "session": .string(session), "ref": .string(ref), "number": .number(Double(number)), "text": .string(text),
    ]
    decide(session, "decision-ask", args, key: "\(session)/ask", then: asked)
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

  /// Reads the session's newest events of `kind`, with their whole payloads, off the main thread.
  func events(_ session: String, kind: String) async -> [Event] {
    let client = client
    return await Task.detached {
      (try? client.call(
        "events", ["session": .string(session), "kinds": [.string(kind)], "full": true], as: [Event].self)) ?? []
    }.value
  }

  /// Reads the session's chat messages from its transcript, which can be large, so off the main thread.
  func loadChatLog(_ session: String) {
    let send = send
    poller.async {
      let messages = try? JSONCoding.convert(
        send("chat-log", ["session": .string(session)]), to: [ChatMessage].self)
      Task { @MainActor in
        if let messages, self.chatLogs[session] != messages {
          self.chatLogs[session] = messages
        }
      }
    }
  }

  /// Reads the commands that the session's claude takes after `/`. A failed read keeps the stored rows, which the
  /// message field shows while sbd answers. `then` gets the rows that sbd answered, or nil when the read failed.
  func loadSlashCommands(_ session: String, then: (([SlashCommand]?) -> Void)? = nil) {
    let send = send
    poller.async {
      let commands = try? JSONCoding.convert(
        send("slash-commands", ["session": .string(session)])["commands"], to: [SlashCommand].self)
      Task { @MainActor in
        if let commands, self.slashCommands[session] != commands { self.slashCommands[session] = commands }
        then?(commands)
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
  /// so off the main thread. The text belongs to the session's `lastReply` at the time of the call.
  func loadReply(_ session: SessionSummary) {
    let send = send
    let (id, hook) = (session.id, session.lastReply)
    contextWork.async {
      let text = try? send("reply", ["session": .string(id)])["reply"]?.string
      Task { @MainActor in
        guard let text, self.replies[id].map({ $0.hook != hook || $0.text != text }) ?? true else { return }
        self.replies[id] = (hook, text)
      }
    }
  }

  /// The session's last reply: the transcript's text when it was read for the current `lastReply`, and
  /// `lastReply` otherwise.
  func reply(for session: SessionSummary) -> String? {
    guard let read = replies[session.id], read.hook == session.lastReply else { return session.lastReply }
    return read.text
  }

  /// Asks sbd to drop one wait of the session. A refusal shows in the wait panel, not in the error banner.
  func clearWait(_ session: String, wait: String) {
    let key = Self.clearingWaitKey(session, wait)
    guard clearingWaits.insert(key).inserted else { return }
    perform(
      "clear-wait", ["session": .string(session), "wait": .string(wait)],
      then: { _ in self.waitErrors[session] = nil },
      failed: { self.waitErrors[session] = "\($0)" },
      finally: { self.clearingWaits.remove(key) })
  }

  /// Whether sbd has not yet answered the Clear wait of this wait.
  func isClearingWait(_ session: String, _ wait: String) -> Bool {
    clearingWaits.contains(Self.clearingWaitKey(session, wait))
  }

  private static func clearingWaitKey(_ session: String, _ wait: String) -> String { "\(session)/\(wait)" }

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

  /// The draft of the Inbox field on `session`. On an Operator question it is the answer's own draft, which the
  /// session view and the chat pane never show. The answer is dropped, not sent to claude, once the question closes.
  func inboxDraft(for session: SessionSummary) -> MessageField.Draft {
    guard MessageField.Draft.answersOperator(ref: session.triage?.ref) else { return messageDraft(for: session) }
    return messageDrafts.draft(for: MessageDrafts.operatorAnswerKey(session: session.id))
  }

  /// What the user typed as the Other answer to one decision and has not sent.
  func otherAnswerDraft(session: String, ref: String, decision: Int) -> MessageField.Draft {
    messageDrafts.draft(for: MessageDrafts.otherAnswerKey(session: session, ref: ref, decision: decision))
  }

  /// What the user typed as a question about one decision and has not asked.
  func askDraft(session: String, ref: String, decision: Int) -> MessageField.Draft {
    messageDrafts.draft(for: MessageDrafts.askKey(session: session, ref: ref, decision: decision))
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

  /// The scope of a one-session delete. A Done session keeps the `done` scope, so sbd refuses it when it left
  /// Done after the dialog opened. Any other work session, such as an Inbox item, takes the `work` scope.
  nonisolated static func deleteScope(_ s: SessionSummary) -> RemovalScope { s.isRemovableDone ? .done : .work }

  /// Hands a session to sbd's removal job, which deletes everything `deletePlan` names after the
  /// safety checks of `rm`. The request runs on `worker`, in order with the other actions.
  func deleteSession(_ s: SessionSummary, resolve: [String] = []) {
    guard deleting.insert(s.id).inserted else { return }
    queueRemovals([s.id], scope: Self.deleteScope(s), resolve: resolve, finally: { self.deleting.remove(s.id) })
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
  /// returns preselects it, because the sheet's `repos` request waits behind `new` on `worker`. Once sbd creates
  /// the session, it empties the draft of `clearingDraft`'s session unless the user changed it from that text.
  func create(_ args: NewSession, clearingDraft: (session: String, text: String)? = nil) {
    guard let json = try? JSON(encoding: args).object else { return }
    if let repo = knownRepos?.first(where: { $0.path == args.path }) { moveToFront(repo) }
    perform("new", json) { value in
      if let id = value["id"]?.string { self.selectUnlisted(id) }
      if let clearingDraft { self.clearDraft(of: clearingDraft.session, ifStill: clearingDraft.text) }
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
  var name: String { ClaudeAccount(folder: folder).name }
}
