import Foundation
import SwitchboardCore

/// sbd's state and operations. Every change runs on `queue`, so requests,
/// hooks, and the stop rule see one consistent state. Work that takes long,
/// such as git, a process snapshot, or a paste, runs off that queue, because
/// claude waits on each hook that sbd handles there.
public final class Service {
  public let home: Home
  let config: Config
  let store: Store
  let host: TerminalHost
  let sbPath: String
  let git: String
  let queue = DispatchQueue(label: "sbd.state")
  /// Each paste waits 300 ms before its Enter, so pastes run here, in order.
  let pasteQueue = DispatchQueue(label: "sbd.paste")

  struct Entry {
    var session: Session
    var facts = SessionFacts()
    /// Messages for a session whose turn runs or whose claude is starting.
    /// Each end of a turn, each SessionStart, and sbd's start pastes the oldest one.
    var pending: [QueuedMessage] = []
    /// When the tick first saw a running claude that no SessionStart reported.
    var unreportedSince: Int64?
    /// When sbd last pasted a message or launched claude with a prompt. Until
    /// that prompt's UserPromptSubmit arrives, the session counts as busy, so
    /// a second message waits instead of landing in the first one's turn.
    var inFlight: Int64?
    /// The text of the last message that a draft in claude's prompt box
    /// held. The log names each held message once.
    var heldText: String?
    /// Counts the calls to `deliverPending`. Only the newest call's timer
    /// pastes, so a held message keeps one retry timer however many messages
    /// queue behind it.
    var deliveryGeneration = 0
    /// When the tick last saw a background job under claude. A job sends no
    /// hooks while it runs, so the idle wait counts from here too.
    var lastJobSeen: Int64 = 0
    /// The time that the idle wait counts from.
    var idleSince: Int64 { max(facts.lastActivity, lastJobSeen) }
    /// The branch that sbd shows: the folder's checked-out branch once the poller reads one.
    /// Cleanup and branch deletion read `session.branch` instead.
    var branch: String? { facts.branch ?? session.branch }
    /// How many events `facts` includes.
    var events = 0
    var turnProbe = TurnProbe()
    /// When the tick last saw a terminal on the Claude pane.
    var lastOnScreen: Int64 = 0
    /// The Stop event of the last turn whose summary this sbd started or
    /// skipped. A turn gets one attempt per run of sbd, so a restart retries
    /// a summary that failed.
    var summaryAttempt: Int64 = 0
    /// The PR and head commit whose merge brief this sbd last started or
    /// skipped, as `#N@sha`. A head gets one call per run of sbd.
    var mergeBriefAttempt: String?
    /// Whether the budget skipped the brief of `mergeBriefAttempt`.
    var mergeBriefSkipped = false
    /// When a start of claude queued behind the live cap.
    var queuedSince: Int64?
    /// Set when a running claude's MCP servers changed. `applyMCPChanges`
    /// relaunches claude once it can take the change.
    var mcpRelaunch: MCPRelaunch?

    /// Whether a message is queued for the session or on its way.
    func messageWaiting(now: Int64) -> Bool {
      !pending.isEmpty || inFlight.map { now - $0 < Service.inFlightMs } == true
    }

    var dialogs = DialogWatch()
  }

  /// A message on its way to claude.
  struct QueuedMessage {
    var text: String
    /// The message's `sent` event, or nil for a message that sbd restored
    /// from the log. A paste checks that the log still holds it.
    var sent: Event?
  }

  /// How long a message counts as in flight without its UserPromptSubmit.
  static let inFlightMs: Int64 = 10_000
  /// How long sbd keeps a lookup that found no repo before it reads the folder again.
  static let checkoutRetryMs: Int64 = 60_000

  var entries: [String: Entry] = [:]
  /// The follow-ups that `followup start` is starting.
  var starting: Set<String> = []
  /// The sessions whose PR `merge` is merging.
  var merging: Set<String> = []
  /// The sessions whose PR `review` is asking gh to request a review of.
  var requestingReview: Set<String> = []
  /// The drafts whose reply target a gh read is resolving, or whose unknown
  /// post a gh read is looking for, each as its session id and its
  /// `DraftReplies.key`.
  var resolvingDrafts: Set<String> = []
  /// The drafts that `draft-post` is posting, keyed as `resolvingDrafts` is.
  var postingDrafts: Set<String> = []
  /// The unknown posts that the tick doesn't look for, keyed as
  /// `resolvingDrafts` is: those that it already looked for in this run,
  /// and those that this run posted.
  var checkedUnknown: Set<String> = []
  /// gh's login, which the look for an unknown post's reply reads.
  var ghLogin: String?
  /// The sessions whose decision list `decision-submit` is sending.
  var submittingDecisions: Set<String> = []
  var snapshot = Snapshot()
  /// The main checkout of each session folder that a lookup read, or nil for
  /// a folder in no git repo, with the time of the lookup. A folder stays in
  /// its repo, and sbd keeps a checkout that it found. A folder outside git
  /// can become a repo. sbd reads such a folder again after `checkoutRetryMs`.
  var checkouts: [String: (path: String?, readMs: Int64)] = [:]
  /// The folders whose checkout a lookup off the queue is reading.
  var checkoutLookups: Set<String> = []
  /// The owner/name that the origin remote of each checkout names on GitHub,
  /// or nil when it names none, with the time of the lookup. sbd reads a
  /// checkout without one again after `checkoutRetryMs`.
  var repositories: [String: (repository: String?, readMs: Int64)] = [:]
  /// The checkouts whose origin a lookup off the queue is reading.
  var repositoryLookups: Set<String> = []
  /// The PermissionRequest hooks that wait for an answer, by card id.
  var held: [Int64: HeldRequest] = [:]
  let triageJobs: OperationQueue = {
    let jobs = OperationQueue()
    jobs.name = "sbd.triage"
    jobs.maxConcurrentOperationCount = 2
    return jobs
  }()
  /// Runs the gh reads of draft reply targets.
  let ghJobs: OperationQueue = {
    let jobs = OperationQueue()
    jobs.name = "sbd.gh"
    jobs.maxConcurrentOperationCount = 2
    return jobs
  }()
  var mcp: [SharedServer] = []
  /// The ssh link of each remote host that has one, by host name.
  let hostLinks: [String: HostLink]
  /// The Claude sessions that `claude agents` listed, by Claude session id.
  var remembered: [String: ClaudeSession] = [:]
  var github: GitHubPoller?
  var usageReader: UsageReader?
  /// Why the Trunk poller couldn't read trunk, such as a missing login.
  var trunkProblem: String?
  /// The account that `sb account use` chose, or nil before the first use.
  var chosenAccount: String?
  var parentNotices = ParentNotices()
  /// Whether `sb autocontinue on` is in force.
  var autoContinueOn = false
  /// The most claude processes that may run at once. `sb live --set` changes it.
  var liveCap: Int
  var quota: any QuotaBudget = UnlimitedBudget()
  var groups: [String: SessionGroup] = [:]
  var plans: [String: PlanDocument] = [:]
  /// The plans whose update turn is running.
  var planUpdatesRunning: Set<String> = []
  /// Runs the update turns that the poller starts, one at a time.
  let planJobs: OperationQueue = {
    let jobs = OperationQueue()
    jobs.name = "sbd.plans"
    jobs.maxConcurrentOperationCount = 1
    return jobs
  }()
  var docketPoll = DocketPoll()
  let keeper: SnapshotKeeper

  /// The panes and processes from one tmux and ps pass.
  struct Snapshot {
    var panes: [String: PaneRow] = [:]
    /// The claude process in each session's Claude pane, by session id.
    var claudePids: [String: Int] = [:]
    var children: [Int: [ProcessRow]] = [:]
    var taken: Int64 = 0
  }

  /// Where a session's claude is, from the snapshot.
  enum ClaudeState: Equatable {
    case running(Int)
    /// The pane's login shell is loading, before it starts claude. claude
    /// also stays in this state for a moment while it exits.
    case starting
    /// The Claude pane is dead or missing.
    case stopped
  }

  public init(home: Home, sbPath: String) throws {
    self.home = home
    self.config = home.loadConfig()
    self.store = try Store(path: home.database)
    self.host = try TerminalHost(home: home, config: config)
    self.sbPath = sbPath
    self.keeper = SnapshotKeeper(path: home.database, every: config.snapshotEvery)
    self.liveCap = config.liveCap
    self.hostLinks = Service.makeHostLinks(config: config, home: home)
    guard let git = findExecutable("git") else { throw APIError("can't find git") }
    self.git = git
  }

  public var tickSeconds: Double { config.tickSeconds }

  /// Loads the sessions, rebuilds their facts and queued messages from the
  /// event log, and writes the hook settings that every session's claude gets.
  /// It records `delivered` or `delivery_unknown` for each message whose
  /// paste may have reached claude. Its last step queues the pastes of each
  /// running claude's queued messages on the state queue.
  public func load() throws {
    try writeClaudeSettings()
    loadChosenAccount()
    loadAutoContinue()
    try store.pruneSnapshots()
    var uncertain: [String: [String]] = [:]
    for session in try store.sessions() {
      let session = try upgraded(session)
      let replay = try replayed(session)
      var e = Entry(session: session)
      e.facts = replay.facts
      e.pending = replay.pending.map { QueuedMessage(text: $0) }
      e.events = replay.events
      entries[session.id] = e
      if !replay.uncertain.isEmpty { uncertain[session.id] = replay.uncertain }
    }
    for s in try store.claudeSessions() { remembered[s.id] = s }
    for g in try store.groups() { groups[g.id] = g }
    for p in try store.plans() { plans[p.id] = p }
    pruneDeclinedSuggestions()
    snapshot = buildSnapshot() ?? Snapshot()
    for (id, texts) in uncertain { try settleUncertain(id, texts) }
    markInterruptedPosts()
    seedParentMarks(now: nowMs())
    try? refreshManagerGuide()
    try? refreshChatGuides()
    // A summary that was running when sbd stopped never finished.
    for (id, e) in entries {
      let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
      startSummaries(id, verdict)
      resolveDraftTargets(id, verdict)
    }
    try startMCPServers()
    github = GitHubPoller(service: self, settings: config.github, depot: config.depot, trunk: config.trunk)
    let reader = UsageReader(service: self, settings: config.usage)
    usageReader = reader
    quota = reader
    // The deliveries change `entries` on the state queue, so they start after load's own changes.
    queue.async { [self] in
      for id in entries.keys {
        if case .running = claudeState(id) { deliverPending(id, after: 0) }
      }
    }
  }

  // MARK: Requests

  static let actsOnProcesses: Set<String> = [
    "send", "send-group", "stop", "resume", "open", "terminals", "shell", "resolve-wait", "answer", "account-move",
    "dependency-resolved",
  ]
  static let launches: Set<String> = ["send", "resume", "open", "resolve-wait", "answer", "dependency-resolved"]

  /// `hookGone` reports whether the client closed its connection, which a
  /// held PermissionRequest checks while it waits. `caller` lets a request
  /// that stops a session's panes refuse a client inside that session.
  public func handle(_ request: Request, caller: Caller = .inProcess, hookGone: @escaping () -> Bool = { false })
    -> Response
  {
    do {
      switch request.op {
      case "hook":
        return try handleHook(request.args, hookGone: hookGone)
      case "new":
        return try .success(JSON(encoding: newSession(JSONCoding.convert(request.args, to: NewSession.self))))
      case "spawn":
        return try .success(JSON(encoding: spawn(request.args)))
      case "repos":
        return try .success(JSON(encoding: knownRepos()))
      case "repo-add":
        return try .success(JSON(encoding: addRepo(request.args)))
      case "manager":
        return managerRequest(request.args)
      case "chat":
        return chatRequest(request.args)
      case "chat-log":
        return .success(try chatLog(request.args))
      case "rm":
        return .success(try remove(request.args, caller: caller))
      case "cleanup":
        return .success(try cleanup(request.args, caller: caller))
      case "rm-done":
        return .success(try removeDone(request.args, caller: caller))
      case "merge":
        return .success(try mergeRequest(request.args))
      case "review":
        return .success(try reviewRequest(request.args))
      case "draft-post", "draft-check":
        return .success(try draftReplyRequest(request.op, request.args, caller: caller))
      // An advance runs a tick before the reply, so the stop rule sees the
      // new time. `tick` takes the state queue itself, so `clock` runs here
      // and not in `dispatch`.
      case "clock":
        let now = try queue.sync { try clockRequest(request.args) }
        if request.args["advance"] != nil { tick() }
        return .success(now)
      case "followup-add", "followup-ls", "followup-start", "followup-rm", "followup-import", "pr-merged":
        return .success(try followupRequest(request.op, request.args))
      case "importable":
        let all = request.args["all"]?.bool ?? false
        return .success(try JSON(encoding: importList(all: all, repo: request.args["repo"]?.string)))
      case "import":
        return .success(try JSON(encoding: importSessions(request.args)))
      case "triage", "choose", "reply", "summary-set":
        return try triageRequest(request.op, request.args)
      case "decisions", "decision-answer", "decision-submit", "decision-resend", "decision-discard":
        return try decisionRequest(request.op, request.args)
      case "plan-attach", "plan-update":
        return .success(try planDocumentRequest(request.op, request.args))
      case "plan-propose", "plan-apply":
        return .success(try planProposalDocumentRequest(request.op, request.args))
      case "plan-artifact-read", "plan-artifact-rewrite", "plan-artifact-apply":
        return .success(try artifactTurnRequest(request.op, request.args))
      case "plan-followup":
        // `planFollowup` takes the state queue itself.
        return .success(try JSON(encoding: planFollowup(request.args)))
      case "poll":
        // A poll waits on GitHub, so it runs off the state queue.
        return .success(github?.poll(all: request.args["all"]?.bool ?? false) ?? [:])
      case "docket-start":
        return .success(try JSON(encoding: startDocket(request.args)))
      case "usage":
        // `usage` runs off the state queue. The reader takes that queue itself
        // to list the accounts, and a refresh waits on the network.
        return .success(try JSON(encoding: usageRequest(request.args)))
      case "send" where request.args["images"] != nil:
        return try sendWithImages(request, hookGone: hookGone)
      case "account-use", "account-move", "group-account":
        try requireSignedIn(request.args)
      default:
        break
      }
      return try .success(prepared(request) { try dispatch(request.op, request.args) })
    } catch {
      return .failure("\(error)")
    }
  }

  /// Takes the steps that `request` needs before it acts, then runs `body`
  /// on the state queue.
  func prepared(_ request: Request, _ body: () throws -> JSON) throws -> JSON {
    if Service.launches.contains(request.op), let id = try? queue.sync(execute: { try lookup(request.args) }) {
      settle(id)
    }
    if Service.waitsForMCP.contains(request.op) { awaitMCPServers(for: request) }
    // A group send has no session argument. It waits for every server that is starting.
    // A request from inside Claude only opens a card, so it sends nothing and waits for nothing.
    if request.op == "send-group", request.args["confirmed"]?.bool == true, request.args["from"] == nil {
      awaitMCPServers()
    }
    if request.op == "answer", request.args["behavior"]?.string == "allow",
      queue.sync(execute: { answersGroupMessage(request.args) })
    {
      awaitMCPServers()
    }
    // A request that acts on claude decides from the current processes,
    // so it takes a new snapshot. Other requests use the tick's.
    let fresh = Service.actsOnProcesses.contains(request.op) ? buildSnapshot() : nil
    return try queue.sync {
      if let fresh { install(fresh) }
      return try body()
    }
  }

  private func dispatch(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "ping":
      var ping: [String: JSON] = [
        "pid": .number(Double(getpid())), "home": .string(home.path), "version": .string(Version.text),
      ]
      if let trunkProblem { ping["trunk"] = .string(trunkProblem) }
      return .object(ping)
    case "ls":
      return try JSON(encoding: summaries().filter { $0.state != .notStarted })
    case "get":
      return try JSON(encoding: summary(try lookup(args)))
    case "terminals":
      return try JSON(encoding: terminals(try lookup(args)))
    case "shell":
      return try shellRequest(args)
    case "open":
      let id = try lookup(args)
      if claudeState(id) == .stopped { try launch(id, prompt: nil) }
      return try JSON(encoding: summary(id))
    case "send":
      let id = try lookup(args)
      guard let text = args["text"]?.string, !text.isEmpty else { throw APIError("send needs text") }
      // A sender that sbd no longer knows, or the session itself, goes unrecorded.
      let from = (try? lookup(["session": args["from"] ?? .null])).flatMap { $0 == id ? nil : $0 }
      return ["delivery": .string(try send(id, text, from: from).rawValue)]
    case "dependency-resolved":
      return try dependencyResolved(args)
    case "stop":
      let id = try lookup(args)
      try stop(id, reason: "asked")
      return try JSON(encoding: summary(id))
    case "resume":
      let id = try lookup(args)
      try launch(id, prompt: args["prompt"]?.string)
      return try JSON(encoding: summary(id))
    case "done":
      let id = try lookup(args)
      let done = args["done"]?.bool ?? true
      try update(id) { $0.done = done }
      record(id, done ? "done" : "undone")
      return try JSON(encoding: summary(id))
    case "ack":
      return try acknowledgeRequest(args)
    case "wait", "clear-wait", "resolve-wait":
      return try waitRequest(op, args)
    case "note", "remove-note", "resolve-note":
      return try noteRequest(op, args)
    case "resolved-todos":
      return try resolvedTodos(args)
    case "manager-ls":
      return try JSON(encoding: managerList())
    case "manager-mcp":
      return try managerMCP(args)
    case "rename":
      let id = try lookup(args)
      guard let name = args["name"]?.string, !name.isEmpty else { throw APIError("rename needs a name") }
      try update(id) { $0.name = name }
      return try JSON(encoding: summary(id))
    case "issue":
      let id = try lookup(args)
      let session = entries[id]!.session
      guard session.kind == .work, session.runsClaude else {
        throw APIError("sb issue works only on a work session that has started")
      }
      let clear = args["clear"]?.bool == true
      let text = args["issue"]?.string
      guard clear != (text != nil) else { throw APIError("issue needs an issue or clear, not both") }
      let issue = try text.map { text in
        guard let ref = IssueRef(parsing: text) else {
          throw APIError("can't read \"\(text)\" as an issue. Use 123, #123, owner/name#123, or an issue URL.")
        }
        return ref
      }
      try update(id) { $0.issue = issue }
      return try JSON(encoding: summary(id))
    case "events":
      let session = try args["session"].map { _ in try lookup(args) }
      let sessions = try args["sessions"]?.array.map { try $0.map { try lookup(["session": $0]) } }
      let limit = args["limit"]?.int ?? Event.defaultLimit
      // Without `since`, the newest events, so `sb events` shows what just happened.
      if let since = args["since"]?.int {
        return try JSON(
          encoding: store.events(since: Int64(since), session: session, sessions: sessions, limit: limit))
      }
      return try JSON(encoding: store.events(session: session, sessions: sessions, limit: limit, newest: true))
    case "answer":
      return try answer(args)
    case "screen":
      let id = try lookup(args)
      let pane = Pane(rawValue: args["pane"]?.string ?? "claude") ?? .claude
      return .string(try host.screen(paneName(id, pane), colors: args["colors"]?.bool == true))
    case "accounts", "account-use", "account-move":
      return try accountRequest(op, args)
    case "mcp":
      return try JSON(encoding: mcpStatus())
    case "hosts", "host-connect", "host-disconnect":
      return try hostRequest(op, args)
    case "snapshots":
      return try snapshotRequest(args)
    case "autocontinue":
      return try autoContinueRequest(args)
    case "live":
      return try liveRequest(args)
    case "group-ls", "group-add", "group-rm", "group-move", "group-note", "group-describe", "group-account",
      "group-suggest",
      "send-group",
      "send-pending":
      return try groupRequest(op, args)
    case "plan-ls", "plan-get", "plan-detach", "plan-auto":
      return try planRequest(op, args)
    case "plan-proposals", "plan-reject":
      return try planProposalRequest(op, args)
    case "plan-artifact-reject", "plan-artifact-report":
      return try artifactRequest(op, args)
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// Finds a session by id, by unique id prefix, or by unique name.
  func lookup(_ args: JSON) throws -> String {
    guard let key = args["session"]?.string, !key.isEmpty else { throw APIError("name a session") }
    return try resolveRef(key, "session", entries.values.map { ($0.session.id, $0.session.name) })
  }

  // MARK: Hooks

  /// Records a hook event and returns it with what the hook prints, or nil
  /// for an unknown session. A UserPromptSubmit of a Manager or a chat prints
  /// the digest of its children, and the SessionStart of a new Manager
  /// conversation prints the digest of the whole board. sbd records each
  /// digest as a `digest` event. A work session's UserPromptSubmit prints
  /// the replies that the user posted from its drafts since it last heard.
  func hook(_ args: JSON) throws -> (event: Event, answer: JSON)? {
    guard let id = args["session"]?.string, let session = entries[id]?.session, let payload = args["payload"] else {
      return nil
    }
    let kind = payload["hook_event_name"]?.string ?? "unknown"
    // A job starts inside a turn, and the tick skips a running turn. The count
    // is recorded before the Stop, so the session never shows Needs you
    // between the Stop and the next tick.
    if kind == "Stop", case .running(let pid) = claudeState(id) {
      recordJobs(id, backgroundJobs(pid, in: Processes.byParent()))
    }
    let event = record(id, kind, payload)
    var answer: JSON = [:]
    switch kind {
    case "SessionStart":
      // `/clear` and `/resume` in the pane start another conversation, which
      // the next resume has to open.
      let current = payload["session_id"]?.string ?? session.claudeSessionId
      if current != session.claudeSessionId { try update(id) { $0.claudeSessionId = current } }
      // claude reads a launch's prompt after SessionStart, and a slow start
      // can outlast the in-flight window. The window starts again here.
      if entries[id]?.inFlight != nil { entries[id]?.inFlight = event.t }
      refreshSoon()
      // A message that arrived while claude was starting waits until claude
      // has drawn its prompt. 1.5 s covers the redraws that Phase 0 measured.
      deliverPending(id, after: 1.5)
      if let text = startDigest(id, source: payload["source"]?.string) {
        record(id, "digest", ["text": .string(text)])
        answer = ParentDigest.hookOutput(text, event: kind)
      }
    case "UserPromptSubmit":
      entries[id]?.inFlight = nil
      try nameConversation(id, prompt: payload["prompt"]?.string)
      let digestText = digest(id, now: event.t)
      if let digestText { record(id, "digest", ["text": .string(digestText)]) }
      let context = [digestText, repliesNotice(id)].compactMap { $0 }
      if !context.isEmpty { answer = ParentDigest.hookOutput(context.joined(separator: "\n\n"), event: kind) }
    case "Stop", "StopFailure":
      deliverPending(id, after: 0.5)
    case "Notification" where payload["notification_type"]?.string == "idle_prompt":
      deliverPending(id, after: 0.5)
    default:
      break
    }
    return (event, answer)
  }

  /// Appends an event to the log and folds it into the session's facts. It
  /// folds in an event that the store failed to keep too.
  @discardableResult
  func record(_ id: String, _ kind: String, _ data: JSON = [:]) -> Event {
    do {
      return try recordStored(id, kind, data)
    } catch {
      logLine("can't store \(kind) for \(id): \(error)")
      return fold(Event(session: id, t: nowMs(), kind: kind, data: data))
    }
  }

  /// Appends an event to the log and folds it into the session's facts. It
  /// throws, and changes nothing, when the store can't keep the event.
  @discardableResult
  func recordStored(_ id: String, _ kind: String, _ data: JSON = [:]) throws -> Event {
    fold(try store.append(Event(session: id, t: nowMs(), kind: kind, data: data)))
  }

  private func fold(_ event: Event) -> Event {
    let id = event.session
    if var e = entries[id] {
      e.facts.apply(event)
      let verdict = Attention.track(e.session, &e.facts, now: event.t, stateOf: lastState)
      e.events += 1
      entries[id] = e
      // A reply can decide the state after its turn ended, as when a
      // background job outlasts the turn or a PR rule stops applying.
      startSummaries(id, verdict)
      resolveDraftTargets(id, verdict)
    }
    releaseCards(id)
    return event
  }

  // MARK: Sessions

  /// The main checkout of the repo at `path` and the folder that a worktree of
  /// it on `branch` gets.
  func worktreeLocation(
    _ path: String, _ branch: String, on machine: any Machine
  ) throws -> (main: String, dir: String) {
    // The first worktree names the main checkout, whose folder name names the repo.
    let main = try worktreeEntries(path, on: machine).first?.path ?? path
    return (main, "\(config.worktreeRoot.expandingTilde)/\((main as NSString).lastPathComponent)/\(branch)")
  }

  /// Whether `branch` exists in the repo at `path`, or the folder for a worktree on it does.
  func branchOrFolderTaken(_ path: String, _ branch: String, on machine: any Machine = LocalMachine()) -> Bool {
    if branchExists(path, branch, on: machine) { return true }
    guard let location = try? worktreeLocation(path, branch, on: machine) else { return false }
    return machine.exists(location.dir)
  }

  /// The folder a new session runs in, its branch, and its repo. With a branch, the
  /// folder is a worktree of the repo at <worktreeRoot>/<repo>/<branch>,
  /// which this creates unless it exists. An existing one must have the
  /// branch checked out. The repo is the main checkout, or the passed path when that
  /// is the main checkout. It is nil without a branch.
  /// The folders and the repo are on `machine`.
  func prepareFolder(
    _ args: NewSession, on machine: any Machine = LocalMachine()
  ) throws -> (cwd: String, branch: String?, repo: String?) {
    let path = (args.path as NSString).standardizingPath
    guard machine.isFolder(path) else { throw APIError("no folder \(path)") }
    guard let branch = args.branch, !branch.isEmpty else {
      let current = try? gitOutput(path, ["branch", "--show-current"], on: machine)
      return (path, current?.isEmpty == false ? current : nil, nil)
    }
    let common = try gitOutput(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], on: machine)
    let (main, dir) = try worktreeLocation(path, branch, on: machine)
    // The path can be a linked worktree, which goes away. The main checkout stays.
    let repo = samePath(main, path) ? path : main
    if machine.exists(dir) {
      let other = try? gitOutput(dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"], on: machine)
      guard other == common else { throw APIError("\(dir) exists and is not a worktree of \(main)") }
      let current = (try? gitOutput(dir, ["branch", "--show-current"], on: machine)) ?? ""
      guard current == branch else {
        throw APIError("\(dir) has \(current.isEmpty ? "no branch" : current) checked out, not \(branch)")
      }
      return (dir, branch, repo)
    }
    let exists = branchExists(path, branch, on: machine)
    try machine.createFolder((dir as NSString).deletingLastPathComponent)
    _ = try gitOutput(
      path, exists ? ["worktree", "add", dir, branch] : ["worktree", "add", "-b", branch, dir, args.base ?? "HEAD"],
      on: machine)
    return (dir, branch, repo)
  }

  struct WorktreeEntry {
    var path: String
    var head: String?
    var branch: String?
    /// Set by `git worktree lock`, which tools such as Supacode use. `worktree remove` refuses it.
    var locked: Bool
    /// The lock is Supacode's, which `removeWorktree` asks Supacode to delete.
    var lockedBySupacode = false
  }

  func worktreeEntries(_ repo: String, on machine: any Machine = LocalMachine()) throws -> [WorktreeEntry] {
    var entries: [WorktreeEntry] = []
    for line in try gitOutput(repo, ["worktree", "list", "--porcelain", "-z"], on: machine).split(
      separator: "\0", omittingEmptySubsequences: true)
    {
      if line.hasPrefix("worktree ") {
        entries.append(
          WorktreeEntry(path: String(line.dropFirst("worktree ".count)), head: nil, branch: nil, locked: false))
      } else if line.hasPrefix("HEAD ") {
        entries[entries.count - 1].head = String(line.dropFirst("HEAD ".count))
      } else if line.hasPrefix("branch refs/heads/") {
        entries[entries.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
      } else if line == "locked" || line.hasPrefix("locked ") {
        entries[entries.count - 1].locked = true
        entries[entries.count - 1].lockedBySupacode = Self.isSupacodeLock(line.dropFirst("locked".count))
      }
    }
    return entries
  }

  /// The real path of the main checkout that holds the session's folder.
  /// The repo that `new` made the worktree from is that checkout. For any
  /// other folder, this returns nil until a lookup off the queue has read it.
  func checkout(_ s: Session) -> String? {
    if let repo = s.repo { return realPath(repo) ?? repo }
    // A follow-up that hasn't started has no folder. `git -C ""` would read sbd's own folder.
    guard !s.cwd.isEmpty else { return nil }
    if let known = checkouts[s.cwd],
      known.path != nil || !GitHub.elapsed(since: known.readMs, Self.checkoutRetryMs, now: nowMs())
    {
      return known.path
    }
    let cwd = s.cwd
    if checkoutLookups.insert(cwd).inserted {
      DispatchQueue.global().async { [self] in
        // The first worktree that git lists is the main checkout.
        let main = (try? worktreeEntries(cwd))?.first.flatMap { realPath($0.path) }
        queue.async { [self] in
          checkouts[cwd] = (main, nowMs())
          checkoutLookups.remove(cwd)
        }
      }
    }
    return nil
  }

  /// The owner/name that the origin remote of `checkout` names on GitHub.
  /// This returns nil until a lookup off the queue has read it.
  func repository(_ checkout: String, of s: Session) -> String? {
    if let known = repositories[checkout],
      known.repository != nil || !GitHub.elapsed(since: known.readMs, Self.checkoutRetryMs, now: nowMs())
    {
      return known.repository
    }
    if repositoryLookups.insert(checkout).inserted {
      let machine = machine(for: s)
      DispatchQueue.global().async { [self] in
        let url = try? gitOutput(checkout, ["config", "--get", "remote.origin.url"], on: machine)
        let repository = url.flatMap(GitHub.repo(remoteURL:))
        queue.async { [self] in
          repositories[checkout] = (repository, nowMs())
          repositoryLookups.remove(checkout)
        }
      }
    }
    return nil
  }

  /// Whether sbd has read the session's checkout and, when it has one, the
  /// checkout's origin remote.
  func repositoryRead(_ s: Session, checkout: String?) -> Bool {
    if let checkout { return repositories[checkout] != nil }
    return checkouts[s.cwd] != nil
  }

  func worktreeEntry(
    _ repo: String, at path: String, on machine: any Machine
  ) throws -> WorktreeEntry? {
    try worktreeEntries(repo, on: machine).first { samePath($0.path, path) }
  }

  func samePath(_ a: String, _ b: String) -> Bool {
    // A gone worktree may have lost its parent folders too, so the deepest folder that exists is resolved.
    let real = { (path: String) -> String in
      var url = URL(fileURLWithPath: path).standardizedFileURL
      var gone: [String] = []
      while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
        gone.insert(url.lastPathComponent, at: 0)
        url.deleteLastPathComponent()
      }
      return gone.reduce(url.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
    return real(a) == real(b)
  }

  func lockedError(_ path: String) -> APIError {
    APIError("\(path) is a locked worktree, so git won't remove it. Unlock it with `git worktree unlock` first.")
  }

  /// The machine that the session runs on. Every session runs on this Mac.
  func machine(for session: Session) -> any Machine { LocalMachine() }

  /// The machine of the session with the id, or this Mac when sbd has no such session. It runs on the state queue.
  func machine(of id: String) -> any Machine { entries[id].map { machine(for: $0.session) } ?? LocalMachine() }

  func branchExists(_ repo: String, _ branch: String, on machine: any Machine = LocalMachine()) -> Bool {
    (try? machine.run(git, ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]))?.status == 0
  }

  /// Whether `commit` is in origin/main of the repo that `dir` belongs to.
  func isInMain(_ dir: String, _ commit: String, on machine: any Machine) -> Bool {
    (try? machine.run(git, ["-C", dir, "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"]))?.status
      == 0
  }

  /// The trimmed output of git in `cwd` on the machine, or throws what git printed when it fails.
  func gitOutput(_ cwd: String, _ args: [String], on machine: any Machine = LocalMachine()) throws -> String {
    let r = try machine.run(git, ["-C", cwd] + args)
    guard r.status == 0 else {
      throw APIError("git \(args.joined(separator: " ")): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Makes the session's folder and worktree off the state queue, then creates the session and launches claude.
  func newSession(_ args: NewSession) throws -> SessionSummary {
    var args = args
    if args.worktree == true, (args.branch ?? "").isEmpty {
      let repo = (args.path as NSString).standardizingPath
      args.branch = NewSession.freeAutoBranch(
        prefix: config.branchPrefix, name: args.name,
        exists: { branchOrFolderTaken(repo, $0) })
    }
    // An unknown group, an unknown account, or an account that differs from
    // the group's fails here, before prepareFolder makes a worktree.
    try queue.sync {
      var probe = Session(id: "", name: "", cwd: "", branch: nil, claudeSessionId: "", model: nil, created: 0)
      probe.parent = args.parent.flatMap { try? lookup(["session": .string($0)]) }
      probe.group = try groupOfNew(args.group, parent: probe.parent)
      _ = try accountForNew(named: args.account, parent: probe.parent, for: probe)
    }
    let folder = try prepareFolder(args)
    awaitMCPServers()
    let summary = try queue.sync { try create(args, folder) }
    rememberRepo(folder.cwd, used: summary.created ?? nowMs())
    return summary
  }

  /// `configure` changes the session before its first launch.
  func create(
    _ args: NewSession, _ folder: (cwd: String, branch: String?, repo: String?),
    configure: (inout Session) -> Void = { _ in }
  ) throws -> SessionSummary {
    let id = shortId("s", taken: entries.keys)
    var session = Session(
      id: id, name: args.name ?? args.branch ?? (folder.cwd as NSString).lastPathComponent, cwd: folder.cwd,
      branch: folder.branch, claudeSessionId: UUID().uuidString.lowercased(), model: args.model ?? config.model,
      created: nowMs())
    session.repo = folder.repo
    session.parent = args.parent.flatMap { try? lookup(["session": .string($0)]) }
    session.group = try groupOfNew(args.group, parent: session.parent)
    session.autoMode = args.autoMode ?? config.autoMode
    configure(&session)
    // After `configure`, which sets a chat's group.
    session.claudeConfigDir =
      try accountForNew(named: args.account, parent: session.parent, for: session) ?? activeAccount
    entries[id] = Entry(session: session)
    try store.save(session)
    record(id, "created", ["cwd": .string(folder.cwd)])
    try host.create(paneName(id, .shell), cwd: folder.cwd, env: paneEnv(id))
    try launch(id, prompt: args.prompt)
    return summary(id)
  }

  func update(_ id: String, _ change: (inout Session) -> Void) throws {
    guard var session = entries[id]?.session else { throw APIError("no session \(id)") }
    change(&session)
    entries[id]?.session = session
    try store.save(session)
  }

  func paneName(_ id: String, _ pane: Pane) -> String { "\(id)-\(pane.rawValue)" }

  func paneEnv(_ id: String) -> [String: String] {
    var env = ["SB_SESSION_ID": id, "SB_HOME": home.path]
    // CLAUDE_CONFIG_DIR picks the Claude account. A session runs under the
    // account it recorded. A session without one, stored by an older sbd,
    // uses sbd's account unless config.env sets another.
    if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { env["CLAUDE_CONFIG_DIR"] = dir }
    for (key, value) in config.env { env[key] = value.expandingTilde }
    if let account = entries[id]?.session.claudeConfigDir { ClaudeAccount.apply(account, to: &env) }
    return env
  }

  /// The two panes' tmux targets. It starts a missing Claude pane, and a
  /// missing shell pane unless the shell is closed. It closes a shell pane
  /// whose shell exited. It leaves a dead Claude pane dead.
  private func terminals(_ id: String) throws -> Terminals {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    try requireFolder(session)
    let shell = paneName(id, .shell)
    if snapshot.panes[shell]?.dead == true { try closeShell(id) }
    if entries[id]?.session.shellClosed != true { try startShell(id) }
    if snapshot.panes[paneName(id, .claude)] == nil { try launch(id, prompt: nil) }
    return Terminals(tmux: host.tmux, socket: host.socket, claude: paneName(id, .claude), shell: shell)
  }

  /// Starts claude in the session's Claude pane. A launch resumes the
  /// conversation when its transcript exists, and starts it otherwise.
  /// `prompt` becomes the first prompt. The pane runs only claude, so the pane
  /// dies when claude exits. tmux keeps the dead pane's last screen until the
  /// next launch. It ignores the live cap. Callers use `launch` unless they
  /// have already found a free slot.
  func startClaude(_ id: String, prompt: String?) throws {
    _ = try requireStartable(id)
    moveToGroupAccount(id)
    trustOwnFolder(id)
    let session = entries[id]!.session
    let resume = hasTranscript(session)
    var args = [config.claude]
    args += resume ? ["--resume", session.claudeSessionId] : ["--session-id", session.claudeSessionId]
    args += ["--settings", home.claudeSettings]
    args += launchMCPArgs(id, session)
    if let model = session.model { args += ["--model", model] }
    args += config.claudeArgs
    // After claudeArgs, so that the session's mode wins over a global one.
    if session.autoMode == true { args += ["--permission-mode", PermissionMode.auto] }
    if !config.triage.systemPrompt.isEmpty { args += ["--append-system-prompt", config.triage.systemPrompt] }
    // `--` keeps a prompt that starts with a dash from reading as an option.
    if let prompt, !prompt.isEmpty { args += ["--", prompt] }
    let dir = home.sessionFolder(id)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let script =
      "# Written by sbd. The Claude pane sources it to start or resume claude.\n"
      + args.map(shellQuote).joined(separator: " ") + "\n"
    try script.write(toFile: "\(dir)/claude.sh", atomically: true, encoding: .utf8)
    // An interactive login shell gives claude the user's PATH and shell
    // functions.
    let command = "\(host.shell) -l -i -c 'source \"$SB_HOME/sessions/$SB_SESSION_ID/claude.sh\"'"
    let name = paneName(id, .claude)
    if snapshot.panes[name] != nil {
      try host.respawn(name, cwd: session.cwd, env: paneEnv(id), command: command)
    } else {
      try host.create(name, cwd: session.cwd, env: paneEnv(id), command: command)
      try host.setDeadMessage(
        name, "Claude stopped. Switchboard resumes it when you open the session or send it a message.")
    }
    markStarting(name)
    if !session.started { try update(id) { $0.started = true } }
    snapshot.claudePids[id] = nil
    // This launch reads the current MCP servers, so no relaunch for a change to them is still due.
    entries[id]?.mcpRelaunch = nil
    entries[id]?.unreportedSince = nil
    entries[id]?.inFlight = prompt?.isEmpty == false ? nowMs() : nil
    record(
      id, resume ? "resumed" : "started",
      [
        "prompt": prompt.map(JSON.string) ?? .null, "mcp": mcpListening,
        "permission_mode": session.autoMode == true ? .string(PermissionMode.auto) : .null,
      ])
  }

  /// Whether the session's conversation has a transcript. `--resume` fails
  /// without one. Claude writes none before the conversation's first prompt,
  /// so a claude that exits before one leaves a conversation that only
  /// `--session-id` can start. SessionStart names the transcript in the
  /// account that claude runs under. A shell profile or a wrapper can pick
  /// that account. Before a SessionStart for the conversation, as for an
  /// imported one, this looks in the account that the pane sets. A session
  /// that sbd never started claude for has none.
  private func hasTranscript(_ session: Session) -> Bool { transcriptFile(session) != nil }

  /// The session's transcript file, by the rules of `hasTranscript`.
  func transcriptFile(_ session: Session) -> String? {
    guard session.started else { return nil }
    if let path = entries[session.id]?.facts.transcriptPath,
      (path as NSString).lastPathComponent == "\(session.claudeSessionId).jsonl"
    {
      return machine(for: session).exists(path) ? path : nil
    }
    let account = claudeAccount(of: session.id)
    return Transcript.find(session.claudeSessionId, account: account, cwd: session.cwd, on: machine(for: session))
  }

  /// Whether claude sits at its prompt, ready for a paste: this launch's
  /// claude reported SessionStart at least 1.5 s ago, no turn runs, and no
  /// message is on its way. A claude that shows a dialog at startup, such as
  /// the workspace trust dialog, has not reported SessionStart.
  private func readyForPaste(_ id: String, now: Int64) -> Bool {
    guard let e = entries[id], e.facts.live, !e.facts.turnRunning, let start = e.facts.lastStart else { return false }
    if let launch = e.facts.lastLaunch, start < launch { return false }
    if let sent = e.inFlight, now - sent < Service.inFlightMs { return false }
    return now - start >= 1500
  }

  /// `byUser` is false for a message that sbd sends on its own, which can't
  /// answer a deferred question. With `launchesWithPrompt` false, a stopped
  /// claude starts without a prompt and gets the message as a paste, which
  /// checks that the log still holds the `sent` event. It throws, and pastes
  /// nothing, when the store can't keep the `sent` event.
  /// `from` is the session that sent the message, which the `sent` event records.
  func send(
    _ id: String, _ text: String, byUser: Bool = true, launchesWithPrompt: Bool = true, from: String? = nil
  ) throws -> Delivery {
    guard entries[id] != nil else { throw APIError("no session \(id)") }
    let now = nowMs()
    // Claude Code does not attach the images of a prompt that starts it, so
    // a message with images waits for a paste.
    let attaches = Attachments.split(text, folder: home.attachmentsFolder(id)) != nil
    if launchesWithPrompt, claudeState(id) == .stopped, entries[id]!.pending.isEmpty, !attaches, hasRoom() {
      // A missing folder is the usual reason startClaude throws, so the check comes before `sent` is stored.
      try requireFolder(entries[id]!.session)
      try recordSent(id, text, .resumed, byUser: byUser, from: from)
      try startClaude(id, prompt: text)
      return .resumed
    } else if case .running = claudeState(id), entries[id]!.pending.isEmpty, readyForPaste(id, now: now) {
      let sent = try recordSent(id, text, .pasted, byUser: byUser, from: from)
      paste(id, QueuedMessage(text: text, sent: sent))
      return .pasted
    } else {
      // A stopped session launches without a prompt when older messages wait,
      // the message has images, the live cap is full, or another start is
      // queued. Its messages arrive in order after SessionStart.
      if claudeState(id) == .stopped { try launch(id, prompt: nil) }
      try queueMessage(id, text, byUser: byUser, from: from)
      return .queued
    }
  }

  /// Adds the message to the session's queue. The `sent` event lets a
  /// restart of sbd rebuild the queue.
  func queueMessage(_ id: String, _ text: String, byUser: Bool, from: String? = nil) throws {
    let sent = try recordSent(id, text, .queued, byUser: byUser, from: from)
    entries[id]?.pending.append(QueuedMessage(text: text, sent: sent))
    deliverPending(id, after: 0.2)
  }

  @discardableResult
  private func recordSent(_ id: String, _ text: String, _ delivery: Delivery, byUser: Bool, from: String?) throws
    -> Event
  {
    var data: [String: JSON] = ["text": .string(text), "delivery": .string(delivery.rawValue)]
    if delivery == .pasted { data[Delivery.awaitsDeliveredKey] = true }
    if !byUser { data["by"] = "sbd" }
    if let from { data["from"] = .string(from) }
    return try recordStored(id, "sent", .object(data))
  }

  /// Pastes the oldest queued message after `delay`, if claude is ready for
  /// it. When claude is idle but its SessionStart is under 1.5 s old, or a
  /// message is still in flight, this tries again when that wait ends.
  /// Otherwise the next SessionStart or end of a turn tries again.
  func deliverPending(_ id: String, after delay: Double) {
    guard entries[id]?.pending.isEmpty == false else { return }
    entries[id]!.deliveryGeneration += 1
    let generation = entries[id]!.deliveryGeneration
    queue.asyncAfter(deadline: .now() + delay) { [self] in
      guard let e = entries[id], !e.pending.isEmpty, e.deliveryGeneration == generation else { return }
      let now = nowMs()
      guard readyForPaste(id, now: now) else {
        if e.facts.live, !e.facts.turnRunning, let start = e.facts.lastStart, start >= (e.facts.lastLaunch ?? 0) {
          let startWait = max(0, 1500 - (now - start))
          let flightWait = e.inFlight.map { max(0, Service.inFlightMs - (now - $0)) } ?? 0
          let wait = max(startWait, flightWait)
          if wait > 0 { deliverPending(id, after: Double(wait) / 1000 + 0.1) }
        }
        return
      }
      paste(id, entries[id]!.pending.removeFirst())
    }
  }

  /// Records `delivered` for each message whose paste started before sbd
  /// stopped and whose text the transcript holds in a user message after
  /// that paste started. It records `delivery_unknown` for the rest, which
  /// sbd leaves for the user instead of pasting them again.
  private func settleUncertain(_ id: String, _ texts: [String]) throws {
    var pastings = try store.events(session: id).filter { $0.kind == "pasting" }
    for text in texts {
      let pasting = pastings.lastIndex { $0.data["text"]?.string == text }.map { pastings.remove(at: $0) }
      // A paste that found no transcript started before claude wrote any of it.
      let path = pasting?.data["transcript"]?.string ?? entries[id].flatMap { transcriptFile($0.session) }
      let offset = UInt64(pasting?.data["transcript_bytes"]?.int ?? 0)
      let pasted = Attachments.split(text, folder: home.attachmentsFolder(id))?.text ?? text
      let machine = self.machine(of: id)
      let landed =
        pasting != nil
        && path.map { Transcript.hasUserMessage($0, holding: pasted, from: offset, on: machine) } == true
      record(id, landed ? "delivered" : "delivery_unknown", ["text": .string(text)])
    }
  }

  /// Pastes on the paste queue and marks the session busy until the prompt's
  /// UserPromptSubmit. `pasting` reaches the log before the paste starts, so
  /// a restart never pastes a message that may have arrived. `delivered`
  /// follows only a paste that succeeded. A failed paste records `requeued`
  /// and puts the message back at the front of the session's queue. A paste
  /// also submits text that the user left in claude's prompt box, so a
  /// message waits at the front of the queue, with no event, until the box
  /// shows empty.
  private func paste(_ id: String, _ message: QueuedMessage) {
    let text = message.text
    let name = paneName(id, .claude)
    let parts = Attachments.split(text, folder: home.attachmentsFolder(id))
    entries[id]?.inFlight = nowMs()
    pasteQueue.async { [self] in
      waitAtGate("hold-paste")
      guard (try? host.screen(name, colors: true)).map(ClaudeScreen.promptIsEmpty) == true else {
        queue.async { [self] in
          if entries[id]?.heldText != text {
            logLine("holds a message for \(id) until claude's prompt box shows empty")
            entries[id]?.heldText = text
          }
          requeue(id, message, after: 2)
        }
        return
      }
      guard queue.sync(execute: { startPaste(id, message) }) else { return }
      do {
        try host.paste(name, parts?.text ?? text, attachments: parts?.paths)
        waitAtGate("hold-delivered")
        queue.async { self.record(id, "delivered", ["text": .string(text)]) }
      } catch {
        logLine("can't paste into \(id): \(error)")
        queue.async {
          self.requeue(id, message)
          self.record(id, "requeued", ["text": .string(text)])
        }
      }
    }
  }

  /// Puts the message back at the front of the session's queue and tries again after `delay` seconds.
  private func requeue(_ id: String, _ message: QueuedMessage, after delay: Double = 1) {
    entries[id]?.inFlight = nil
    entries[id]?.pending.insert(message, at: 0)
    deliverPending(id, after: delay)
  }

  /// Checks that the log holds the message's `sent` event, then records
  /// `pasting` with the transcript's path and size, so that a restart looks
  /// for the message only in what claude wrote after it. A rolled-back
  /// transaction can leave a message without its `sent` event, and SQLite
  /// can give the event's id to a later row, so the check also compares the
  /// session, the time, the kind, and the text. It returns false and drops
  /// the message when the log lacks the `sent` event. It returns false and
  /// requeues the message when the store fails.
  private func startPaste(_ id: String, _ message: QueuedMessage) -> Bool {
    entries[id]?.heldText = nil
    var data: [String: JSON] = ["text": .string(message.text)]
    if let session = entries[id]?.session, let path = transcriptFile(session),
      let size = machine(for: session).size(path)
    {
      data["transcript"] = .string(path)
      data["transcript_bytes"] = .number(Double(size))
    }
    do {
      if let sent = message.sent {
        guard let row = try store.event(id: sent.id), row.session == id, row.t == sent.t, row.kind == "sent",
          row.data["text"] == sent.data["text"]
        else {
          logLine("drops a message for \(id), because the log lacks its sent event")
          entries[id]?.inFlight = nil
          return false
        }
      }
      try recordStored(id, "pasting", .object(data))
      return true
    } catch {
      logLine("can't start a paste into \(id): \(error)")
      requeue(id, message)
      return false
    }
  }

  /// Waits while the gate file exists in the home. Only a test instance has
  /// gates, and they run on the paste queue, never on the state queue.
  private func waitAtGate(_ gate: String) {
    guard config.testClock else { return }
    while FileManager.default.fileExists(atPath: "\(home.path)/\(gate)") { usleep(50_000) }
  }

  /// Defers the session's held questions first, so that their cards stay.
  func stop(_ id: String, reason: String) throws {
    guard case .running(let pid) = claudeState(id) else { throw APIError("\(id) is not running") }
    deferQuestions(id)
    machine(of: id).signal(pid, SIGTERM)
    record(id, "stopped", ["reason": .string(reason), "pid": .number(Double(pid))])
  }

  /// Stops claude, removes the worktree when asked, then closes the panes and
  /// forgets the session. A removal that asked for the worktree first checks
  /// that nothing is lost, and refuses before it stops anything. `branch`
  /// also deletes the local branch, and needs `worktree`. `remote_branch`
  /// also deletes the branch on its remote, and needs `branch`. git runs off
  /// the state queue, because removing a worktree with large ignored folders
  /// can take a while. A removal of the worktree closes the panes first, and
  /// runs the checks again once `finishPaneStop` returns. A refusal there, or
  /// a failed removal, leaves the session. A store that can't delete the
  /// session's record also refuses the removal before anything stops. After
  /// the worktree is gone, the session is forgotten whatever happens to the
  /// branch, because its folder is missing. The branch is checked again at
  /// that point. A failed check or delete keeps
  /// the branch and throws after the session is forgotten. The conversation's
  /// transcript stays in the account's projects folder, because Claude Code has
  /// no command that archives a local session. When the session's folder is
  /// gone, sbd skips the uncommitted-file check but still refuses a locked
  /// worktree and commits on the worktree's HEAD that are on no pushed branch.
  /// It removes that worktree's record from git and no other. The branch
  /// checks read the branch from the main repo, because the worktree is gone.
  /// The remote branch is deleted only after the local branch is, and only when
  /// it is at the merged PR's head. A remote branch at another commit stays and
  /// the call throws. Without a merged PR for the branch, the remote branch is
  /// left alone and the call succeeds. The call refuses a session with an open to-do
  /// before anything stops, unless `resolve` names each open to-do. A to-do
  /// that arrives later keeps the session, even after its worktree is gone.
  /// A removal of the worktree refuses a caller inside the session before
  /// anything stops, as `beginPaneStop` describes.
  func remove(_ args: JSON, caller: Caller) throws -> JSON {
    let resolving = try resolveArgument(args)
    let removesWorktree = args["worktree"]?.bool == true
    let removesBranch = args["branch"]?.bool == true
    let removesRemoteBranch = args["remote_branch"]?.bool == true
    guard removesWorktree || !removesBranch else {
      throw APIError("A branch checked out in a worktree can't be deleted. Remove the worktree too.")
    }
    guard removesBranch || !removesRemoteBranch else {
      throw APIError("The remote branch can't be deleted without the local branch. Delete the local branch too.")
    }
    let flags =
      (removesWorktree ? ["--worktree"] : []) + (removesBranch ? ["--delete-branch"] : [])
      + (removesRemoteBranch ? ["--delete-remote-branch"] : [])
    let command = "sb rm --worktree"
    let ancestry = removesWorktree ? try caller.ancestry(command: command) : nil
    do {
      let (session, pr, sharedWith): (Session, PullRequest?, String?) = try queue.sync {
        let id = try lookup(args)
        // The start would otherwise leave its new worktree behind.
        guard !starting.contains(id) else { throw APIError("\(id) is starting") }
        guard !merging.contains(id) else { throw APIError("\(id) is merging its PR") }
        try checkTodos(id, resolving: resolving)
        let entry = entries[id]!
        return (entry.session, entry.facts.pr, sharedSession(entry.session))
      }
      let machine = self.machine(for: session)
      let folderGone = !machine.exists(session.cwd)
      var (repo, branch, supacode) = try checkRemoval(
        session, pr: pr, sharedWith: sharedWith, folderGone: folderGone, worktree: removesWorktree,
        branch: removesBranch)
      // The branch's git config is deleted with the branch, so the remote is read first.
      // A local branch that is already gone still has its remote branch checked.
      let remoteTarget: (repo: String, remote: String, branch: String)? = {
        guard removesRemoteBranch, let repo, let name = branch?.name ?? session.branch else { return nil }
        return (repo, trackedRemote(repo, name, on: machine), name)
      }()
      let fresh = buildSnapshot()
      let stop: PaneStop? = try queue.sync {
        guard entries[session.id]?.session.cwd == session.cwd, !starting.contains(session.id),
          !merging.contains(session.id)
        else {
          throw APIError("\(session.id) changed while it was being removed")
        }
        // A record that can't be deleted after the worktree is gone would list the session with its folder missing.
        try store.checkDeletable(session: session.id, resolving: checkTodos(session.id, resolving: resolving))
        install(fresh)
        if removesWorktree { return try beginPaneStop(session.id, ancestry: ancestry, command: command) }
        if case .running(let pid) = claudeState(session.id) { machine.signal(pid, SIGTERM) }
        return nil
      }
      if let stop {
        try finishPaneStop(session, stop, command: command)
        (repo, branch, supacode) = try checkRemoval(
          session, pr: pr, sharedWith: sharedWith, folderGone: folderGone, worktree: removesWorktree,
          branch: removesBranch)
      }
      // Prune would also drop the records of other worktrees whose folders are missing. Git can't resolve a missing
      // folder's path through a symlink, so it gets the path that it lists for the worktree.
      if let repo {
        let listed = folderGone ? try worktreeEntry(repo, at: session.cwd, on: machine)?.path : session.cwd
        if let listed { try removeWorktree(repo, listed, on: machine) }
      }
      var branchRemoved = false
      var branchError: Error?
      if let repo, let branch {
        do {
          branchRemoved = try deleteBranch(repo, branch, pr: pr, inMain: supacode, on: machine)
        } catch {
          branchError = error
        }
      }
      var remoteRemoved = false
      var remoteError: Error?
      if let target = remoteTarget, branchError == nil, !branchExists(target.repo, target.branch, on: machine),
        let pr = mergedPR(pr, of: target.branch)
      {
        do {
          remoteRemoved = try deleteRemoteBranch(target.repo, target.remote, target.branch, pr: pr, on: machine)
        } catch {
          remoteError = error
        }
      }
      try queue.sync {
        // A follow-up can start between the two steps.
        guard !starting.contains(session.id), !merging.contains(session.id),
          entries[session.id]?.session.cwd == session.cwd
        else {
          throw APIError("\(session.id) changed while it was being removed")
        }
        // A to-do can arrive while the panes stop. The record stays. The refusal names what rm already removed.
        let removed = [
          repo != nil ? "the worktree" : nil, branchRemoved ? "the local branch" : nil,
          remoteRemoved ? "the remote branch" : nil,
        ].compactMap { $0 }
        let kept =
          removed.isEmpty
          ? "Kept \(session.id)" : "Removed \(englishList(removed)) of \(session.id) and kept the session"
        var stayed = ""
        if let branchError, let branch {
          stayed = " It kept \(branch.name): \(branchError)"
        } else if let remoteError {
          stayed = " It kept the remote branch: \(remoteError)"
        }
        do {
          try forgetSession(session.id, resolving: resolving)
        } catch var error as OpenTodoError {
          error.kept = kept
          error.stayed = stayed
          throw error
        } catch let error where !removed.isEmpty {
          throw APIError("\(kept): \(error)\(stayed)")
        }
        host.kill(paneName(session.id, .claude))
        host.kill(paneName(session.id, .shell))
        try detachPlans { $0.session == session.id }
      }
      try? FileManager.default.removeItem(atPath: home.sessionFolder(session.id))
      if let branchError, let branch {
        let remote = removesRemoteBranch ? " It also kept the remote branch." : ""
        throw APIError("Removed \(session.id) and its worktree, and kept \(branch.name): \(branchError)\(remote)")
      }
      if let remoteError {
        throw APIError(
          "Removed \(session.id), its worktree, and its local branch, and kept the remote branch: \(remoteError)")
      }
      return [
        "removed": .string(session.id), "worktree_removed": .bool(repo != nil), "branch_removed": .bool(branchRemoved),
        "remote_branch_removed": .bool(remoteRemoved),
      ]
    } catch var error as OpenTodoError {
      error.flags = flags
      throw error
    }
  }

  /// The checks that `rm` makes before it stops anything. Returns the repo
  /// when `worktree` is set, and with `branch` the branch to delete and its
  /// tip. The branch is nil when the folder and the branch are both gone, and
  /// when Supacode locked the worktree and origin/main doesn't contain the tip.
  /// `supacode` is true when Supacode locked the worktree.
  func checkRemoval(
    _ session: Session, pr: PullRequest?, sharedWith: String?, folderGone: Bool, worktree: Bool, branch: Bool
  ) throws -> (repo: String?, branch: (name: String, tip: String)?, supacode: Bool) {
    guard worktree else { return (nil, nil, false) }
    let merged = pr?.state == .merged
    if folderGone {
      let repo = try checkGoneWorktree(session, mergedPR: merged)
      return (repo, branch ? try checkGoneBranchIsMerged(repo, session, pr: pr) : nil, false)
    }
    let (repo, supacode) = try checkWorktreeIsLossless(
      session, mergedPR: merged, sharedWith: sharedWith, onlyBuildOutputIgnored: false)
    guard branch else { return (repo, nil, supacode) }
    return (repo, supacode ? try supacodeBranch(session, pr: pr) : try checkBranchIsMerged(session, pr: pr), supacode)
  }

  /// The session's repo, or throws when sbd made no worktree for the session. When the repo folder is
  /// gone, because the session started from a linked worktree that was later removed, this returns the
  /// one known main checkout that still lists the session's worktree.
  private func worktreeRepo(_ session: Session) throws -> String {
    guard let repo = session.repo else {
      throw APIError(
        "\(session.id) runs in \(session.cwd), and sbd didn't make a worktree for it. Remove the session without the worktree instead."
      )
    }
    let machine = self.machine(for: session)
    if machine.isFolder(repo) { return repo }
    let folders = queue.sync { entries.values.map(\.session).flatMap { [$0.repo, $0.cwd].compactMap { $0 } } }
    var mains: [String] = []
    var seen: [String] = []
    for folder in folders where machine.isFolder(folder) && !seen.contains(where: { samePath($0, folder) }) {
      guard let listed = try? worktreeEntries(folder, on: machine), let main = listed.first?.path else { continue }
      seen += listed.map(\.path)
      if listed.contains(where: { samePath($0.path, session.cwd) }) { mains.append(main) }
    }
    if mains.count == 1 { return mains[0] }
    if mains.count > 1 {
      throw APIError(
        "\(session.id)'s repo \(repo) is gone, and \(mains.joined(separator: " and ")) both list its worktree.")
    }
    throw APIError(
      "\(session.id)'s repo \(repo) is gone, and no known checkout lists \(session.cwd) as a worktree. Remove the session without the worktree instead."
    )
  }

  /// Returns the session's repo for a session whose folder is gone, or throws when sbd made no
  /// worktree for it, git keeps the worktree locked, or the worktree's HEAD has commits that are on
  /// no pushed branch. Removing the worktree's record drops the only ref to such commits.
  private func checkGoneWorktree(_ session: Session, mergedPR: Bool) throws -> String {
    let repo = try worktreeRepo(session)
    let machine = self.machine(for: session)
    guard let entry = try worktreeEntry(repo, at: session.cwd, on: machine) else { return repo }
    if entry.locked { throw lockedError(session.cwd) }
    // git lists the zero OID when the worktree's HEAD names a ref that no longer exists. Commits made there
    // survive only in the worktree's reflog, which goes with its record, so they can't be checked.
    guard let head = entry.head, !head.allSatisfy({ $0 == "0" }) else {
      throw APIError(
        "git lists no commit at the HEAD of the gone worktree \(session.cwd), so its commits can't be checked.")
    }
    try requireNoUnpushedCommits(
      in: repo, at: head, mergedPR: mergedPR, subject: "\(session.cwd) is gone, and its HEAD", on: machine)
    return repo
  }

  /// Throws when `rev` has commits on no remote branch. With a merged PR, local branches count too, because a
  /// squash merge leaves the commits on no remote branch and `worktree remove` keeps the branch.
  private func requireNoUnpushedCommits(
    in dir: String, at rev: String, mergedPR: Bool, subject: String, on machine: any Machine
  ) throws {
    let kept = mergedPR ? ["--remotes", "--branches"] : ["--remotes"]
    let unpushed = try gitOutput(dir, ["rev-list", "--count", rev, "--not"] + kept, on: machine)
    guard unpushed == "0" else {
      throw APIError(
        "\(subject) has commits that are not on a pushed branch and not in a merged PR (\(unpushed)). Push them first."
      )
    }
  }

  /// `checkBranchIsMerged` for a session whose folder is gone: the branch is read from the repo.
  /// A branch that is already gone leaves nothing to delete, so it returns nil.
  private func checkGoneBranchIsMerged(_ repo: String, _ session: Session, pr: PullRequest?) throws -> (
    name: String, tip: String
  )? {
    let machine = self.machine(for: session)
    guard let name = session.branch, branchExists(repo, name, on: machine) else { return nil }
    let branch = (name: name, tip: try gitOutput(repo, ["rev-parse", "refs/heads/\(name)"], on: machine))
    try recheckBranch(repo, branch.name, pr: pr, ignoring: session.cwd, on: machine)
    return branch
  }

  /// The remote that the branch tracks, or origin.
  private func trackedRemote(_ repo: String, _ branch: String, on machine: any Machine) -> String {
    let tracked = try? gitOutput(repo, ["config", "branch.\(branch).remote"], on: machine)
    return tracked.flatMap { $0.isEmpty ? nil : $0 } ?? "origin"
  }

  /// Deletes the branch from `remote` when the remote's tip is the
  /// head of the merged PR. Returns false when the remote has no such branch. The push names the
  /// tip it expects, so git refuses when the branch moved after the check.
  private func deleteRemoteBranch(
    _ repo: String, _ remote: String, _ branch: String, pr: PullRequest, on machine: any Machine
  ) throws -> Bool {
    let listed = try gitOutput(repo, ["ls-remote", "--heads", remote, "refs/heads/\(branch)"], on: machine)
    guard let tip = listed.split(whereSeparator: \.isWhitespace).first.map(String.init) else { return false }
    guard tip == pr.headSha else {
      throw APIError(
        "\(remote)/\(branch) is at \(tip.prefix(8)), not the merged PR's head \(pr.headSha.prefix(8)). Keep the remote branch."
      )
    }
    _ = try gitOutput(
      repo, ["push", remote, "--delete", "--force-with-lease=refs/heads/\(branch):\(tip)", branch], on: machine)
    return true
  }

  /// Returns the session's branch and its tip, or throws unless the worktree has the branch
  /// checked out and the tip is the head of the session's merged PR. A branch with no merged PR may
  /// hold the only copy of the work, and a commit made after the merge is in no PR.
  func checkBranchIsMerged(_ session: Session, pr: PullRequest?) throws -> (name: String, tip: String) {
    let (branch, tip) = try checkedOutBranch(session)
    try requireTip(tip, of: branch, inMerged: try requireMergedPR(pr, of: branch))
    return (branch, tip)
  }

  /// The PR, or throws unless it merged `branch`.
  func requireMergedPR(_ pr: PullRequest?, of branch: String) throws -> PullRequest {
    guard let pr = mergedPR(pr, of: branch) else {
      throw APIError("\(branch) has no merged PR, so it may hold the only copy of the work. Keep the branch.")
    }
    return pr
  }

  /// The session's branch and its tip, or throws unless the session's worktree has that branch checked out.
  func checkedOutBranch(_ session: Session) throws -> (name: String, tip: String) {
    let machine = self.machine(for: session)
    guard let branch = session.branch,
      try gitOutput(session.cwd, ["branch", "--show-current"], on: machine) == branch
    else {
      throw APIError("\(session.cwd) doesn't have the branch of \(session.id) checked out.")
    }
    return (branch, try gitOutput(session.cwd, ["rev-parse", "HEAD"], on: machine))
  }

  /// The PR when it merged `branch`, or nil.
  private func mergedPR(_ pr: PullRequest?, of branch: String) -> PullRequest? {
    guard let pr, pr.state == .merged, pr.head == branch else { return nil }
    return pr
  }

  private func requireTip(_ tip: String, of branch: String, inMerged pr: PullRequest) throws {
    guard tip == pr.headSha else {
      throw APIError("\(branch) has commits that are not in its merged PR \(pr.url). Keep the branch.")
    }
  }

  /// Runs the checks that `checkBranchIsMerged` made, now that the worktree is gone: the branch
  /// still exists, its tip is the head of the merged PR, and no worktree has it checked out.
  /// Deleting the ref of a checked-out branch breaks that worktree.
  /// A worktree at `path` does not count as having the branch checked out.
  func recheckBranch(
    _ repo: String, _ branch: String, pr: PullRequest?, ignoring path: String? = nil,
    on machine: any Machine
  ) throws {
    let pr = try requireMergedPR(pr, of: branch)
    guard branchExists(repo, branch, on: machine) else { throw APIError("\(branch) no longer exists.") }
    try requireTip(
      try gitOutput(repo, ["rev-parse", "refs/heads/\(branch)"], on: machine), of: branch, inMerged: pr)
    try requireNotCheckedOut(repo, branch, ignoring: path, on: machine)
  }

  /// Throws when a worktree other than the one at `path` has the branch checked out.
  /// Deleting the ref of a checked-out branch breaks that worktree.
  func requireNotCheckedOut(
    _ repo: String, _ branch: String, ignoring path: String? = nil, on machine: any Machine
  ) throws {
    let checkedOut = try worktreeEntries(repo, on: machine).contains { entry in
      entry.branch == branch && !(path.map { samePath(entry.path, $0) } ?? false)
    }
    guard !checkedOut else { throw APIError("\(branch) is checked out in a worktree.") }
  }

  /// Deletes the branch after `recheckBranch` passes. A squash merge leaves
  /// the branch's commits outside the base branch, so `branch -d` refuses.
  /// Passing the checked tip makes git refuse when a commit landed after the
  /// check.
  func deleteMergedBranch(
    _ repo: String, _ branch: (name: String, tip: String), pr: PullRequest?, on machine: any Machine
  ) throws {
    try recheckBranch(repo, branch.name, pr: pr, on: machine)
    try deleteBranchRef(repo, branch, on: machine)
  }

  /// Deletes the branch's ref at the checked tip, so git refuses when a commit landed after the check.
  func deleteBranchRef(_ repo: String, _ branch: (name: String, tip: String), on machine: any Machine) throws {
    _ = try gitOutput(repo, ["update-ref", "-d", "refs/heads/\(branch.name)", branch.tip], on: machine)
    // `update-ref` leaves the upstream settings that `branch -D` removes. A later branch of the same name would track the old one.
    _ = try? gitOutput(repo, ["config", "--remove-section", "branch.\(branch.name)"], on: machine)
  }

  /// Another session that runs in the session's folder.
  func sharedSession(_ session: Session) -> String? {
    entries.values.first { $0.session.id != session.id && $0.session.cwd == session.cwd }?.session.id
  }

  /// Returns the session's repo and whether Supacode locked the worktree, or
  /// throws unless the session's folder is a linked worktree of the repo that
  /// `new` made it from, no other session runs in it, git doesn't lock it
  /// unless the lock is Supacode's and sbd can find supacode, it has no
  /// uncommitted file and no file whose change git status
  /// skips, and HEAD is on a remote branch. With a merged PR, HEAD may instead
  /// be on a local branch, because a squash merge leaves the commits on no
  /// remote branch and `worktree remove` keeps the branch. `worktree remove`
  /// deletes ignored files. With `onlyBuildOutputIgnored`, an ignored file that
  /// is not build output or in `cleanupDeletes` also refuses. Any git failure
  /// refuses the removal.
  func checkWorktreeIsLossless(
    _ session: Session, mergedPR: Bool, sharedWith: String?, onlyBuildOutputIgnored: Bool
  ) throws -> (repo: String, supacode: Bool) {
    let repo = try worktreeRepo(session)
    if let sharedWith {
      throw APIError(
        "\(sharedWith) also runs in \(session.cwd). Remove that session first, or remove this one without the worktree."
      )
    }
    let machine = self.machine(for: session)
    guard
      let entry = try worktreeEntries(repo, on: machine).dropFirst().first(where: { samePath($0.path, session.cwd) })
    else {
      throw APIError("\(session.cwd) is not a worktree of \(repo)")
    }
    if entry.locked && !entry.lockedBySupacode { throw lockedError(session.cwd) }
    let status = try readStatus(session.cwd, listingIgnored: onlyBuildOutputIgnored, on: machine)
    guard status.changed == 0 else {
      throw APIError("\(session.cwd) has uncommitted files (\(status.changed)). Commit or discard them first.")
    }
    try requireNoHiddenChanges(session.cwd, on: machine)
    if onlyBuildOutputIgnored { try requireOnlyBuildOutputIgnored(session.cwd, ignored: status.ignored) }
    try requireNoUnpushedCommits(
      in: session.cwd, at: "HEAD", mergedPR: mergedPR, subject: session.cwd, on: machine)
    if entry.lockedBySupacode { _ = try supacodeExecutable() }
    return (repo, entry.lockedBySupacode)
  }

  /// Throws when a tracked file has git's assume-unchanged or skip-worktree
  /// flag, because `git status` doesn't list a change to such a file.
  private func requireNoHiddenChanges(_ cwd: String, on machine: any Machine) throws {
    let listed = try gitOutput(cwd, ["ls-files", "-v", "-z"], on: machine)
    let hidden = listed.split(separator: "\0").filter { $0.first.map { $0.isLowercase || $0 == "S" } ?? false }
      .map { String($0.dropFirst(2)) }
    guard hidden.isEmpty else {
      throw APIError(
        "\(cwd) has files that git status skips (\(hidden.count)): \(preview(hidden)). Clear their assume-unchanged or skip-worktree flag first."
      )
    }
  }

  /// The number of changed paths, and with `listingIgnored` the ignored
  /// paths, from one walk of the folder. Listing the ignored paths takes
  /// about three times as long in posthog/posthog. `matching` lists each
  /// ignored path without what is inside it, and `-z` leaves names unquoted.
  /// A rename or copy entry is followed by its source path, which has no
  /// status of its own.
  private func readStatus(
    _ cwd: String, listingIgnored: Bool, on machine: any Machine
  ) throws -> (changed: Int, ignored: [String]) {
    // The flag keeps status from taking the index lock while claude commits.
    let args = ["--no-optional-locks", "status", "--porcelain", "-z"] + (listingIgnored ? ["--ignored=matching"] : [])
    var fields = try gitOutput(cwd, args, on: machine).split(separator: "\0").makeIterator()
    var changed = 0
    var ignored: [String] = []
    while let field = fields.next() {
      if field.hasPrefix("!! ") {
        ignored.append(String(field.dropFirst(3)))
        continue
      }
      changed += 1
      if field.prefix(2).contains(where: { $0 == "R" || $0 == "C" }) { _ = fields.next() }
    }
    return (changed, ignored)
  }

  /// Throws when one of the folder's ignored paths is neither build output
  /// nor a name in `cleanupDeletes`.
  private func requireOnlyBuildOutputIgnored(_ cwd: String, ignored: [String]) throws {
    let also = Set(config.cleanupDeletes)
    let kept = ignored.filter { !BuildOutput.contains($0, also: also) }
    guard kept.isEmpty else {
      throw APIError(
        "\(cwd) has ignored files that no build makes again (\(kept.count)): \(preview(kept)). Move or delete them, or add their names to cleanupDeletes in config.json."
      )
    }
  }

  /// The first five paths, and an ellipsis when there are more.
  private func preview(_ paths: [String]) -> String {
    paths.prefix(5).joined(separator: ", ") + (paths.count > 5 ? ", …" : "")
  }

  // MARK: Processes and the stop rule

  /// Reads the panes and the processes. It reads no Service state, so it runs
  /// off the state queue. It returns nil when tmux can't list the panes. An
  /// empty list would make sbd start the panes that it already has.
  func buildSnapshot() -> Snapshot? { try? buildSnapshot(reading: host.checkedPanes) }

  /// The snapshot of the panes that `readPanes` returns and a new process
  /// list. It throws what `readPanes` throws.
  func buildSnapshot(reading readPanes: () throws -> [String: PaneRow]) rethrows -> Snapshot {
    var s = Snapshot()
    // A snapshot is as old as its first read. `install` uses this to drop
    // one that began before a launch.
    s.taken = nowMs()
    s.panes = try readPanes()
    s.children = Processes.byParent()
    let program = (config.claude as NSString).lastPathComponent
    for (name, pane) in s.panes where name.hasSuffix("-claude") && !pane.dead {
      if let pid = Service.findClaude(below: pane.pid, program: program, in: s.children) {
        s.claudePids[String(name.dropLast("-claude".count))] = pid
      }
    }
    return s
  }

  /// The process nearest the pane's shell whose command names the claude
  /// command. A forked child of claude keeps its command line, so the nearest
  /// one is claude itself.
  static func findClaude(below pane: Int, program: String, in children: [Int: [ProcessRow]]) -> Int? {
    var level = [pane]
    while !level.isEmpty {
      let kids = level.flatMap { children[$0] ?? [] }
      if let match = kids.first(where: { runs($0, program: program) }) { return match.pid }
      level = kids.map(\.pid)
    }
    return nil
  }

  /// Whether the command of the process names the claude command, in its
  /// first or second word.
  static func runs(_ row: ProcessRow, program: String) -> Bool {
    row.command.split(separator: " ").prefix(2).contains { ($0 as NSString).lastPathComponent == program }
  }

  /// Programs that run a script named in the second word of their command.
  private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "sh", "bash", "zsh"]

  /// Whether the process is claude itself: its command starts with the claude
  /// command, or with an interpreter that runs it. `runs` is looser, because
  /// any argument in the second word matches, such as `tail /tmp/claude`.
  /// Signals use this one.
  static func isClaude(_ row: ProcessRow, program: String) -> Bool {
    let words = row.command.split(separator: " ").map { ($0 as NSString).lastPathComponent }
    guard let first = words.first else { return false }
    return first == program || (interpreters.contains(first) && words.dropFirst().first == program)
  }

  /// Marks a pane that sbd just started as alive until the next snapshot, so
  /// a second request can't start it again. A snapshot that began before
  /// this can no longer replace it.
  func markStarting(_ name: String) {
    snapshot.panes[name] = PaneRow(pid: 0, dead: false, clients: snapshot.panes[name]?.clients ?? 0)
    snapshot.taken = nowMs()
  }

  /// Takes a newer snapshot, keeping what `markStarting` set since it was read.
  func install(_ s: Snapshot?) {
    if let s, s.taken >= snapshot.taken { snapshot = s }
  }

  /// Takes a snapshot off the state queue and installs it, without making
  /// the caller wait.
  private func refreshSoon() {
    DispatchQueue.global().async { [self] in
      let s = buildSnapshot()
      queue.async { self.install(s) }
    }
  }

  func claudeState(_ id: String) -> ClaudeState {
    guard let pane = snapshot.panes[paneName(id, .claude)], !pane.dead else { return .stopped }
    return snapshot.claudePids[id].map(ClaudeState.running) ?? .starting
  }

  /// Returns once the session's claude is live, or its Claude pane is dead
  /// or missing, or after 5 s. It checks one pane, without a snapshot.
  private func settle(_ id: String) {
    let name = paneName(id, .claude)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if queue.sync(execute: { entries[id]?.facts.live ?? true }) { return }
      guard let dead = host.isDead(name), !dead else { return }
      usleep(50_000)
    }
  }

  /// The number of background jobs. A job is a child of claude that leads its
  /// own process group, as a background Bash job does.
  func backgroundJobs(_ pid: Int, in children: [Int: [ProcessRow]]? = nil) -> Int {
    ((children ?? snapshot.children)[pid] ?? []).filter { $0.pgid == $0.pid }.count
  }

  /// Records the job count when it differs from the one in the session's facts.
  func recordJobs(_ id: String, _ count: Int) {
    if count != entries[id]?.facts.jobs { record(id, "job", ["count": .number(Double(count))]) }
  }

  /// Records each claude that exited or started without a hook, and stops
  /// idle sessions. sbd calls it every `tickSeconds`.
  public func tick() {
    let fresh = buildSnapshot()
    queue.sync {
      install(fresh)
      let now = nowMs()
      superviseMCPServers(now: now)
      superviseHosts(now: now)
      closeExitedShells()
      for id in entries.keys.sorted() {
        let live = entries[id]?.facts.live ?? false
        switch claudeState(id) {
        case .running(let pid):
          // SessionStart marks claude live. A claude that runs for 10 s with
          // no SessionStart, because its hook failed, counts as live too. A
          // claude whose SessionStart arrived and whose SessionEnd followed
          // is exiting, and stays not live.
          if live || entries[id]?.facts.startedSinceLaunch == true {
            entries[id]?.unreportedSince = nil
          } else if let since = entries[id]?.unreportedSince {
            if now - since > 10_000 {
              record(id, "running")
              entries[id]?.unreportedSince = nil
            }
          } else {
            entries[id]?.unreportedSince = now
          }
          let jobs = backgroundJobs(pid)
          if jobs > 0 { entries[id]?.lastJobSeen = now }
          // A running turn outranks the job rule. The tick records the count after the turn ends.
          if live, entries[id]?.facts.turnRunning == false { recordJobs(id, jobs) }
          if shouldStop(id, now: now, pid: pid) { try? stop(id, reason: "idle for \(idleStopMs(id) / 1000) s") }
        case .stopped:
          entries[id]?.unreportedSince = nil
          // Exit typed in the terminal, a stop, or a crash ends claude at the trust dialog.
          if let card = entries[id]?.facts.trustCard { closeTrust(card) }
          if live { record(id, "exited") }
          // A message sent while claude exited waits in `pending` for a launch.
          // A claude that dies before its SessionStart isn't launched again,
          // and these launches come at most every 5 s.
          if let e = entries[id], !e.pending.isEmpty, e.facts.startedSinceLaunch,
            now - (e.facts.lastLaunch ?? 0) >= 5_000, !mcpStarting(now: now)
          {
            try? launch(id, prompt: nil)
          }
        case .starting:
          entries[id]?.unreportedSince = nil
        }
        if var e = entries[id] {
          let verdict = Attention.track(e.session, &e.facts, now: now, stateOf: lastState)
          entries[id] = e
          startSummaries(id, verdict)
          resolveDraftTargets(id, verdict)
          checkUnknownPosts(id)
        }
      }
      runQueuedStarts(now: now)
      // A resolved `resume` wait can launch claude.
      if !mcpStarting(now: now) { resolveDueWaits(now: now) }
      deferDueQuestions(now: now)
      expireGroupMessages(now: now)
      readyDueFollowups(now: now)
      pollDocketsIfDue(now: now)
      notifyParents(now: now)
      applyMCPChanges(now: now)
      autoContinueSessions(now: now)
      compactSnapshots()
    }
    endIdleTurns()
    closeGoneDialogs()
    noteTrustDialogs()
  }

  func shouldStop(_ id: String, now: Int64, pid: Int) -> Bool {
    guard let e = entries[id], isQuiet(id, pid: pid, now: now) else { return false }
    // A background job's process exits up to 1.3 s before claude starts the
    // turn that reports it, so the wait starts again when the job exits.
    let idle = now - e.idleSince
    guard idle >= idleStopMs(id) else { return false }
    // A running subagent's tool calls fire hooks. A subagent with no event
    // for twice the idle time lost its SubagentStop, as when sbd was down.
    return e.facts.subagents.isEmpty || idle >= 2 * Int64(config.idleStopSeconds) * 1000
  }

  /// Whether the session's claude sits idle with nothing that a stop would
  /// lose: no turn, prompt, trust dialog, queued or in-flight message, or
  /// background job, and no terminal on screen. The idle stop and the live cap both need it.
  func isQuiet(_ id: String, pid: Int, now: Int64) -> Bool {
    guard let e = entries[id] else { return false }
    let f = e.facts
    return f.live && !f.turnRunning && f.openPermission == nil && f.openQuestion == nil
      && f.trustCard == nil && !e.messageWaiting(now: now) && !attached(id)
      && backgroundJobs(pid) == 0
  }

  // MARK: Summaries

  func summaries() -> [SessionSummary] {
    let rowFollowups = planRowFollowups()
    return entries.keys.map { summary($0, rowFollowups: rowFollowups) }.sorted {
      $0.state != $1.state ? $0.state < $1.state : $0.since < $1.since
    }
  }

  func summary(_ id: String, rowFollowups: PlanRowFollowups? = nil) -> SessionSummary {
    let e = entries[id]!
    let verdict = Attention.shown(Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState), e.facts)
    let s = e.session
    var out = SessionSummary(
      id: id, name: s.name, cwd: s.cwd, repo: s.repo, branch: e.branch,
      claudeSessionId: s.claudeSessionId, state: verdict.state, reason: verdict.reason, since: e.facts.stateSince,
      lastActivity: e.facts.lastActivity,
      live: e.facts.live, claudePid: snapshot.claudePids[id],
      attached: attached(id), lastReply: e.facts.lastReply,
      waits: s.waits ?? [], notes: s.notes ?? [], cards: e.facts.cards,
      openPrompt: e.facts.openPermission != nil || e.facts.openQuestion != nil, pr: e.facts.pr.map(PRSummary.init),
      markedDone: s.done)
    if s.kind == .work {
      out.checkout = checkout(s)
      out.repository = out.checkout.flatMap { repository($0, of: s) }
      if repositoryRead(s, checkout: out.checkout) { out.repositoryRead = true }
    }
    out.parent = s.parent
    out.manager = s.manager
    out.mcp = s.mcp
    out.kind = s.kind
    out.chat = s.chat
    if Triage.mayHaveItem(out) {
      let shown = Triage.itemAndDecisions(e.facts, verdict)
      out.triage = shown.item
      let details = Triage.details(for: out)
      out.triage?.details = details
      out.decisions = shown.decisions
      if shown.decisionsSent { out.decisionsSent = true }
    }
    out.decisionsDelivery = e.facts.decisionsDelivery
    out.followup = s.followup
    out.created = s.created
    out.account = s.claudeConfigDir
    out.cleanup = e.facts.cleanup
    out.group = s.group
    if let group = s.group.flatMap({ groups[$0] }) {
      out.groupName = group.name
      out.groupDescription = group.description
    }
    if !e.facts.dependencies.isEmpty { out.dependencies = e.facts.dependencies }
    out.plans = planSummaries(session: s, rowFollowups: rowFollowups)
    out.docket = s.docket.map { DocketSummary($0, e.facts.docket) }
    out.mergeError = e.facts.mergeError
    if verdict.acknowledged { out.acknowledged = true }
    out.permissionMode = e.facts.permissionMode
    out.pr?.mergeMethod = e.facts.mergeMethod
    if verdict.state == .readyToMerge, let since = e.facts.readyToMergeSince { out.since = since }
    if e.queuedSince != nil { out.reason = queuedReason }
    out.shellClosed = s.shellClosed
    // A follow-up has been Not started since it was added, which for an
    // imported one is the date of its line.
    if verdict.state == .notStarted { out.since = s.created }
    if verdict.state == .readyForReview, let ready = e.facts.readySince { out.since = ready }
    if s.kind == .work && s.docket == nil {
      out.board = BoardColumn.place(
        state: verdict.state, acknowledged: verdict.acknowledged, stateSince: out.since, waits: s.waits ?? [],
        facts: e.facts, created: s.created)
      if s.runsClaude { out.issues = Issues.shown(set: s.issue, pr: e.facts.pr, branch: e.branch) }
    }
    return out
  }

  // MARK: Settings

  /// Every hook runs `sb hook`, which forwards the payload to sbd. It exits 0
  /// with no output when sbd is down, so the session shows no hook errors.
  private func writeClaudeSettings() throws {
    var hooks: [String: JSON] = [:]
    for event in SessionFacts.hookKinds {
      let timeout: JSON = event == "PermissionRequest" ? .number(Double(Card.holdSeconds)) : 30
      let handler: JSON = ["type": "command", "command": .string("\(shellQuote(sbPath)) hook"), "timeout": timeout]
      hooks[event] = [["matcher": "", "hooks": [handler]]]
    }
    let text = JSON.object(["hooks": .object(hooks)]).text
    try text.write(toFile: home.claudeSettings, atomically: true, encoding: .utf8)
  }
}

extension SessionFacts {
  /// Whether the claude that the last launch started has reported its SessionStart.
  fileprivate var startedSinceLaunch: Bool { (lastStart ?? 0) >= (lastLaunch ?? 0) }

  /// Whether the claude that the last launch started has ended, so that its
  /// process is exiting.
  var exiting: Bool { !live && startedSinceLaunch }
}
