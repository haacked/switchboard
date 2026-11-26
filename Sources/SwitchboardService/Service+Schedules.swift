import Foundation
import SwitchboardCore

/// Schedules: prompts that sbd sends to a session on an interval, and scripts that sbd runs in its folder.
extension Service {
  /// The `schedule`, `schedules`, `remove-schedule`, `pause-schedule`,
  /// `edit-schedule`, `run-schedule`, and `schedule-pending` requests. Each takes an optional
  /// `group` and `caller`, which a scoped MCP server sends. With `group`, a
  /// request acts only on the group's sessions and on the caller. It runs on
  /// the state queue, so the scope check and the change happen in one step.
  /// `origin` and `caller` sent the request, which decides whether it may add
  /// or edit a schedule with a top-up gate, or a script. It runs after `install` of a fresh
  /// snapshot when it adds a gate or a script, or edits a gated schedule or a script.
  func scheduleRequest(_ op: String, _ args: JSON, origin: RequestOrigin, caller: Caller) throws -> JSON {
    switch op {
    case "schedule": return try addSchedule(args, origin: origin, caller: caller)
    case "schedules": return try listSchedules(args)
    case "remove-schedule": return try removeSchedule(args)
    case "pause-schedule": return try pauseSchedule(args)
    case "edit-schedule": return try editSchedule(args, origin: origin, caller: caller)
    case "run-schedule": return try runSchedule(args)
    case "schedule-pending": return try JSON(encoding: scriptProposalStatus(args))
    default: throw APIError("unknown request \(op)")
    }
  }

  /// Stores the schedule, or opens a `script` card on the session that proposes a script, as `scriptAuthority`
  /// decides.
  private func addSchedule(_ args: JSON, origin: RequestOrigin, caller: Caller) throws -> JSON {
    let (id, schedule, authority) = try newSchedule(args, origin: origin, caller: caller)
    if case .propose(let proposer) = authority {
      return try openScriptProposal(
        from: proposer, target: id, schedule: schedule, before: nil, reason: args["reason"]?.string)
    }
    return try storeNewSchedule(id, schedule)
  }

  /// The schedule that an add with `args` stores on the session that `args` names, after every check of the add.
  /// It returns who sent a script, as `scriptAuthority` decides, and nil for another runner. With `approved`, the
  /// user approved a card that holds the values, so no caller check runs.
  func newSchedule(_ args: JSON, origin: RequestOrigin, caller: Caller, approved: Bool = false) throws -> (
    id: String, schedule: Schedule, authority: ScriptAuthority?
  ) {
    let id: String
    do {
      id = try lookup(args)
    } catch  where args["group"] == nil && args["session"]?.string == Manager.operatorName {
      // The Manager guide schedules loops on the operator by name, so an unscoped request creates it as `sb wait` does.
      id = try ensureOperator()
    }
    try requireInScope(id, args: args)
    let session = entries[id]!.session
    try refuseNotStarted(session)
    let open = session.allSchedules
    guard open.count < Schedule.maxPerSession else {
      throw APIError(
        "\(id) has \(Schedule.maxPerSession) schedules, the most a session can have. Remove one with: sb schedule rm <id>"
      )
    }
    var request = try JSONCoding.convert(args, to: ScheduleRequest.self)
    let runner = try Schedule.Runner(parsing: request.runner)
    if runner != .session, session.host != nil {
      throw APIError("--headless and --script run only for a session on this Mac")
    }
    let authority =
      runner == .script && !approved ? try scriptAuthority(args, origin: origin, caller: caller) : nil
    if runner == .headless {
      try checkHeadlessCaller(id, args, origin: origin, caller: caller)
      if request.account == nil, let refusal = codexLaunchRefusal(id) { throw APIError(refusal) }
      request.account = try request.account.map(headlessAccountFolder)
    }
    let group = try request.gate.flatMap { try topupGroup($0, args, origin: origin, caller: caller) }
    let taken = entries.values.flatMap(\.session.allSchedules).map(\.id)
    let schedule = try request.makeSchedule(id: shortId("r", taken: taken), now: nowMs(), group: group)
    if let duplicate = Schedule.duplicate(of: schedule, in: open) { throw APIError(duplicate) }
    return (id, schedule, authority)
  }

  func storeNewSchedule(_ id: String, _ schedule: Schedule) throws -> JSON {
    try update(id) { $0.addSchedule(schedule) }
    record(id, "schedule", ["schedule": try JSON(encoding: schedule)])
    return try JSON(encoding: scheduleRow(id, schedule))
  }

  /// The group that a top-up's gate names, after the checks of `checkTopupCaller`. It returns nil when the gate
  /// names no group, which `makeSchedule` refuses.
  private func topupGroup(_ gate: ScheduleRequest.Gate, _ args: JSON, origin: RequestOrigin, caller: Caller) throws
    -> (id: String, name: String)?
  {
    try checkTopupCaller(args, origin: origin, caller: caller)
    guard let ref = gate.group, !ref.isEmpty else { return nil }
    let id = try lookupGroup(["group": .string(ref)])
    return (id, groups[id]?.name ?? id)
  }

  /// Refuses a request that adds or edits a top-up when the sender may not arm actions, because sbd arms actions
  /// for a top-up in process. A request scoped to a group is refused too.
  private func checkTopupCaller(_ args: JSON, origin: RequestOrigin, caller: Caller) throws {
    if args["group"] != nil {
      throw APIError("a group chat can't add or edit a top-up, because sbd starts sessions and arms actions for it")
    }
    try checkActionCaller(
      args, origin: origin, caller: caller, command: "sb schedule", option: "topup", arms: "a top-up", notFrom: nil)
  }

  /// Who stores a script schedule or changes a script's command or timeout.
  enum ScriptAuthority: Equatable {
    /// The user, from a terminal outside every session.
    case user
    /// sbd's own code.
    case sbd
    /// The Manager conversation with this id, from its panes or its runs.
    case manager(String)
    /// The session with this id, whose request the user approves through a card.
    case propose(String)

    var storesDirectly: Bool {
      if case .propose = self { false } else { true }
    }
  }

  /// The start of sbd's refusal for a caller that may neither store a script nor propose one.
  static let scriptRefusal = "only you or a Manager conversation can add a script schedule"

  /// Who sent a request that would store a script or change a script's command or timeout. `.inProcess` is sbd. A
  /// client's ancestry decides the rest, as the other `scriptAuthority` says. It runs on the state queue, after
  /// `install` of a fresh snapshot.
  func scriptAuthority(_ args: JSON, origin: RequestOrigin, caller: Caller) throws -> ScriptAuthority {
    try scriptAuthority(args, origin: origin, ancestry: caller.ancestry(command: "sb schedule --script"))
  }

  /// Who sent a request from a client with `ancestry`, which must reach launchd, because a walk that stopped early
  /// may have missed a pane. A request from a host is refused before `ancestry` is read, and nil ancestry is sbd's
  /// own code. A client below no session's pane or run and outside sbd's tmux server is the user, when
  /// the request claims no `caller` and has no `group` scope. A client below exactly one session is that session,
  /// when the request claims no other `caller`: a Manager conversation without a group scope stores, the Operator is
  /// refused, and any other session proposes. Every other shape is refused. It runs on the state queue, after
  /// `install` of a fresh snapshot.
  func scriptAuthority(
    _ args: JSON, origin: RequestOrigin, ancestry readAncestry: @autoclosure () throws -> Set<Int>?
  ) throws -> ScriptAuthority {
    try refuseScriptFromHost(origin)
    guard let ancestry = try readAncestry() else { return .sbd }
    guard ancestry.contains(1) else {
      throw APIError(
        "sbd can't follow the process that sent the request up to launchd, so it can't tell whether the request comes from a session. Run it again"
      )
    }
    let claimed = args["caller"]?.string
    let place = callerPlace(ancestry)
    guard place.inside.count <= 1 else {
      throw APIError(
        "\(Self.scriptRefusal), and the request runs inside \(place.inside.map { mention($0) }.joined(separator: " and "))"
      )
    }
    guard let inside = place.inside.first else {
      if place.inServer {
        throw APIError("\(Self.scriptRefusal), and the request runs in sbd's tmux server, where the sessions run")
      }
      if let claimed { throw APIError("\(Self.scriptRefusal), and the request names \(claimed) but runs outside it") }
      if args["group"] != nil { throw APIError("\(Self.scriptRefusal), and the request comes from a group chat") }
      return .user
    }
    if let claimed, claimed != inside {
      throw APIError("\(Self.scriptRefusal), and the request names \(claimed) but runs inside \(mention(inside))")
    }
    guard let kind = entries[inside]?.session.kind else {
      throw APIError("\(Self.scriptRefusal), and the request runs inside \(inside), which sbd no longer has")
    }
    if kind == .operator {
      throw APIError("the Operator can't add a script schedule or change a script's command or timeout")
    }
    return kind == .manager && args["group"] == nil ? .manager(inside) : .propose(inside)
  }

  /// Refuses a request that adds a headless schedule to a Manager conversation or the Operator, or changes such a
  /// schedule's prompt, account, or model, unless a Manager conversation, the Operator, or the user sent it. The run
  /// gets the coordinator's switchboard MCP server and its permission mode, so it can arm actions unattended. It runs
  /// on the state queue, after `install` of a fresh snapshot.
  private func checkHeadlessCaller(_ id: String, _ args: JSON, origin: RequestOrigin, caller: Caller) throws {
    guard isKind(id, in: [.manager, .operator]) else { return }
    try checkActionCaller(
      args, origin: origin, caller: caller, command: "sb schedule", option: "headless",
      arms: "a headless schedule on \(mention(id))", notFrom: nil)
  }

  /// The folder of the Claude account that a headless schedule's `ref` names. It refuses a Codex account. An empty
  /// `ref` comes back as it is: an add refuses it, and an edit reads it as a reset to the session's account.
  private func headlessAccountFolder(_ ref: String) throws -> String {
    let name = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? ref : try resolveClaudeAccount(name).folder
  }

  private func refuseScriptFromHost(_ origin: RequestOrigin) throws {
    guard case .mac = origin else {
      throw APIError("a script schedule can't come from a host, because sbd runs it on this Mac")
    }
  }

  private func listSchedules(_ args: JSON) throws -> JSON {
    let only = try args["session"].map { _ in try lookup(args) }
    let sessions = try entries.values.map(\.session)
      .filter { s in only == nil || only == s.id }
      .filter { try inScope($0.id, args: args) }
    let rows: [ScheduleRow] = sessions.flatMap { s in s.allSchedules.map { scheduleRow(s.id, $0) } }
    func order(_ r: ScheduleRow) -> (Int, Int64, String) {
      (r.schedule.paused == true ? 1 : 0, r.schedule.next, r.schedule.id)
    }
    return try JSON(encoding: rows.sorted { order($0) < order($1) })
  }

  /// Removes the schedule. It cancels a headless or script schedule's run in flight and deletes its logs.
  private func removeSchedule(_ args: JSON) throws -> JSON {
    let (id, schedule) = try ownedSchedule(args)
    try update(id) { $0.removeSchedule(schedule.id) }
    if schedule.isDetached {
      cancelRun(schedule.id)
      try? FileManager.default.removeItem(atPath: runLogFolder(id, schedule.id))
    }
    record(id, "schedule-removed", ["schedule": try JSON(encoding: schedule)])
    return try JSON(encoding: scheduleRow(id, schedule))
  }

  private func pauseSchedule(_ args: JSON) throws -> JSON {
    let (id, found) = try ownedSchedule(args)
    var schedule = found
    let pausing = args["paused"]?.bool ?? true
    guard pausing != (schedule.paused == true) else { return try JSON(encoding: scheduleRow(id, schedule)) }
    if pausing {
      schedule.paused = true
    } else {
      schedule.next = try Schedule.next(after: nowMs(), every: schedule.every)
      schedule.paused = nil
    }
    try changeSchedule(id, schedule.id) { $0 = schedule }
    record(id, pausing ? "schedule-paused" : "schedule-resumed", ["schedule": try JSON(encoding: schedule)])
    return try JSON(encoding: scheduleRow(id, schedule))
  }

  /// True when the schedule that `args` names has a gate, or runs headless or as a script, so its edit can run a
  /// caller check. It runs on the state queue.
  func editChecksCaller(_ args: JSON) -> Bool {
    guard let schedule = (try? ownedSchedule(args))?.schedule else { return false }
    return schedule.gate != nil || schedule.isDetached
  }

  /// Changes the interval, the prompt or command, the timeout, a headless schedule's account or model, or several.
  /// It sends nothing: a next run that the edit makes due fires through `fireDueSchedules`. A schedule's runner
  /// never changes. A change to a script's command or timeout needs the authority of `scriptAuthority`, and a
  /// session that may only propose gets a `script` card that holds the whole edit. A change to a coordinator's
  /// headless prompt, account, or model needs the authority of `checkHeadlessCaller`. A change to the interval alone
  /// needs neither, because the interval changes when the run happens and not what runs. A script without a timeout
  /// of its own runs for 10 minutes, or for the interval when that is shorter. An interval edit that would lengthen that default, from a
  /// caller without script authority, stores the timeout before the edit.
  private func editSchedule(_ args: JSON, origin: RequestOrigin, caller: Caller) throws -> JSON {
    let (id, found) = try ownedSchedule(args)
    if found.gate != nil { try checkTopupCaller(args, origin: origin, caller: caller) }
    var request = try JSONCoding.convert(args, to: ScheduleRequest.self)
    let runner = found.runsAs
    if request.runner != nil, try Schedule.Runner(parsing: request.runner) != runner {
      throw APIError(
        "schedule \(found.id) runs as \(runner.rawValue), and a schedule's runner can't change. Add a new schedule instead"
      )
    }
    let authority =
      runner == .script && (request.prompt != nil || request.timeout != nil)
      ? try scriptAuthority(args, origin: origin, caller: caller) : nil
    if runner == .headless {
      if request.prompt != nil || request.account != nil || request.model != nil {
        try checkHeadlessCaller(id, args, origin: origin, caller: caller)
      }
      request.account = try request.account.map(headlessAccountFolder)
    }
    var schedule = try found.edited(
      every: request.every, prompt: request.prompt, account: request.account, model: request.model,
      timeout: request.timeout, now: nowMs())
    if runner == .script, request.every != nil, request.timeout == nil, found.timeout == nil,
      Schedule.defaultTimeout(.script, every: schedule.every) > found.runTimeout
    {
      let sender = authority ?? (try? scriptAuthority(args, origin: origin, caller: caller))
      if sender?.storesDirectly != true { schedule.timeout = found.runTimeout }
    }
    guard schedule != found else { return try JSON(encoding: scheduleRow(id, found)) }
    if case .propose(let proposer) = authority {
      return try openScriptProposal(
        from: proposer, target: id, schedule: schedule, before: found, reason: args["reason"]?.string)
    }
    return try storeEdit(id, schedule, before: found)
  }

  func storeEdit(_ id: String, _ schedule: Schedule, before found: Schedule) throws -> JSON {
    try changeSchedule(id, schedule.id) { $0 = schedule }
    record(id, "schedule-edited", ["schedule": try eventJSON(schedule), "before": try eventJSON(found)])
    return try JSON(encoding: scheduleRow(id, schedule))
  }

  /// The path of the log of one of the schedule's runs, with the run's number and time. `run` 1, or no `run`, is the
  /// newest run. It runs on the state queue.
  func scheduleLogPath(_ args: JSON) throws -> (path: String, run: Int, schedule: String, t: Int64) {
    let (id, schedule) = try ownedSchedule(args)
    guard schedule.isDetached else {
      throw APIError("schedule \(schedule.id) sends its prompt into the session, so it keeps no log")
    }
    let n = args["run"]?.int ?? 1
    let history = schedule.history
    guard n >= 1, n <= history.count else {
      throw APIError(
        history.isEmpty
          ? "schedule \(schedule.id) has not run yet"
          : "schedule \(schedule.id) has \(history.count) runs, so it has no run \(n)")
    }
    let t = history[n - 1].t
    return ("\(runLogFolder(id, schedule.id))/\(t).log", n, schedule.id, t)
  }

  /// The log at `scheduleLogPath`'s path, with the run's time and whether the run's output passed the log's cap. It
  /// runs off the state queue, because a log can hold a mebibyte.
  static func scheduleLog(_ log: (path: String, run: Int, schedule: String, t: Int64)) throws -> JSON {
    guard let data = FileManager.default.contents(atPath: log.path) else {
      throw APIError("run \(log.run) of schedule \(log.schedule) has no log")
    }
    let text = String(decoding: data, as: UTF8.self)
    return ["text": .string(text), "truncated": .bool(DetachedRun.isCut(text)), "t": .number(Double(log.t))]
  }

  /// Run now: makes the schedule due and sends nothing. The next tick fires it
  /// through `fireDueSchedules`, so a busy session gets the prompt once it is
  /// free. It refuses a paused schedule and a session that the tick skips.
  private func runSchedule(_ args: JSON) throws -> JSON {
    let (id, found) = try ownedSchedule(args)
    switch found.runBlocker(hold: entries[id]!.session.scheduleHold) {
    case .paused: throw APIError("schedule \(found.id) is paused. Resume it first")
    case .held(let hold): throw APIError("\(found.id) can't run, because \(hold)")
    case nil: break
    }
    let now = nowMs()
    guard found.next > now else { return try JSON(encoding: scheduleRow(id, found)) }
    var schedule = found
    schedule.next = now
    try changeSchedule(id, schedule.id) { $0.next = now }
    record(id, "schedule-run-requested", ["schedule": try eventJSON(schedule)])
    return try JSON(encoding: scheduleRow(id, schedule))
  }

  /// Sends each due schedule's prompt to its session when the session is
  /// free. A schedule whose session is busy stays due and runs once when the
  /// session is free. The tick calls it after it resolves due waits. A
  /// session marked done or paused keeps its schedules and runs none of them.
  /// A schedule that comes due during the pause stays due and runs once after
  /// the resume message. A session that the removal job holds runs none of
  /// them either, because the job may be stopping its claude. Its schedules
  /// stay due, so Undo lets them run.
  ///
  /// A headless or script run starts on `scheduleRunQueue` only while fewer than `Schedule.maxRunning` runs are in
  /// flight, and a schedule whose run is in flight stays due, as a top-up does. A session with a run in flight sends
  /// none of its prompts, which stay due and run once the run ends.
  ///
  /// A schedule with a gate checks the gate first. A closed gate sends
  /// nothing, so its check runs while the session is busy. A short group
  /// starts a top-up on `topupQueue` without waiting for the session either.
  /// An open gate sends the fallback message only when the session is free.
  /// A failed top-up sends its fallback only when the session is free, and
  /// otherwise saves the failed check and sends nothing. A schedule whose
  /// top-up is running stays due and runs no check.
  func fireDueSchedules(now: Int64) {
    let ids = entries.compactMap { id, e in
      e.session.scheduleHold == nil && e.session.allSchedules.contains { $0.isDue(now: now) } ? id : nil
    }
    // A pass arms and clears no action wait, so it reads the action waits once, at the first gate.
    var subjects: ActionSubjects?
    for id in ids.sorted() {
      guard let session = entries[id]?.session else { continue }
      let due = session.allSchedules.filter { $0.isDue(now: now) }
        .sorted { ($0.next, $0.id) < ($1.next, $1.id) }
      for schedule in due where !topupsInFlight.contains(schedule.id) && runsInFlight[schedule.id] == nil {
        fireDue(id, schedule, subjects: &subjects, now: now)
      }
    }
  }

  /// Checks a due schedule's gate, then sends its prompt, or starts its headless or script run, when the gate is open
  /// and the session is free. `subjects` holds the action waits that the pass read at its first gate.
  private func fireDue(_ id: String, _ schedule: Schedule, subjects: inout ActionSubjects?, now: Int64) {
    var opened: (gate: Schedule.Gate, status: QueueStatus)?
    if let gate = schedule.gate {
      let found = subjects ?? actionSubjects()
      subjects = found
      let status = QueueStatus.compute(queueRows(subjects: found, gate: gate), gate: gate)
      switch status.decision {
      case .gated:
        recordGated(id, schedule, status: status, now: now)
        return
      case .topup(let k):
        dispatchTopup(id, schedule, status: status, k: k, now: now)
        return
      case .open:
        opened = (gate, status)
      }
    }
    // A detached run waits for a free slot before the guard reads the session.
    if schedule.isDetached, runsInFlight.count >= Schedule.maxRunning { return }
    // A run makes the session busy, so the guard runs again before each schedule.
    guard let e = entries[id] else { return }
    if schedule.isDetached {
      guard
        Schedule.blocker(facts: e.facts, process: promptProcess(id), messageWaiting: messageWaiting(e, now: now))
          == nil, beingDeletedRefusal(id) == nil
      else { return }
      dispatchRun(id, schedule, now: now)
      return
    }
    guard pasteBlocker(id, e, now: now) == nil else { return }
    let text = opened.map { $0.gate.fallbackMessage(status: $0.status, prompt: schedule.prompt) } ?? schedule.prompt
    let check = opened.map { Schedule.Gate.Check(.prompted, status: $0.status, now: now) }
    fire(id, schedule, text: text, check: check, now: now)
  }

  /// Why sbd can't paste a schedule's prompt into the session now, or nil when it can. A headless or script run of the
  /// session holds the paste, so the session's claude never works in the folder while the run does.
  func pasteBlocker(_ id: String, _ e: Entry, now: Int64) -> String? {
    if runsInFlight.values.contains(where: { $0.session == id }) { return "a headless or script run is in flight" }
    return Schedule.blocker(facts: e.facts, process: promptProcess(id), messageWaiting: messageWaiting(e, now: now))
  }

  /// Saves the next run before the send and the result after it, so a crash
  /// between the two loses the run instead of sending it twice. A failed send
  /// waits for the next run instead of trying again on each tick.
  private func fire(_ id: String, _ schedule: Schedule, text: String, check: Schedule.Gate.Check?, now: Int64) {
    var ran = schedule
    guard let skipped = saveNextRun(id, &ran, now: now) else { return }
    sendAndRecord(id, ran, text: text, skipped: skipped, check: check, now: now)
  }

  /// A due time where the gate closed. It appends no run and sends nothing.
  private func recordGated(_ id: String, _ schedule: Schedule, status: QueueStatus, now: Int64) {
    let (next, _) = schedule.fired(at: now)
    let check = Schedule.Gate.Check(.gated, status: status, now: now)
    var gated = schedule
    let mark = { (s: inout Schedule) in
      s.next = next
      let pending = s.gate?.gated ?? 0
      s.gate?.gated = pending + 1
      s.gate?.last = check
    }
    mark(&gated)
    do {
      try changeSchedule(id, schedule.id, mark)
    } catch {
      logLine("can't save the gated check of schedule \(schedule.id) of \(id): \(error)")
      return
    }
    record(id, "schedule-gated", gateEventData(gated, status: status))
  }

  /// The `status` and `schedule` of a `schedule-gated` or `schedule-topup` event.
  func gateEventData(_ schedule: Schedule?, status: QueueStatus, _ extra: [String: JSON] = [:]) -> JSON {
    var data = extra
    data["status"] = .array(status.lines.map(JSON.string))
    data["schedule"] = schedule.flatMap { try? eventJSON($0) }
    return .object(data)
  }

  /// The sessions that an action wait will merge, and the sessions that one will remove.
  typealias ActionSubjects = (merging: Set<String>, removing: Set<String>)

  /// A row for each session, with the facts that `QueueStatus.compute` reads. `compute` picks the gate's rows from
  /// them. `subjects` is what `actionSubjects` returned. It runs on the state queue.
  func queueRows(subjects: ActionSubjects, gate: Schedule.Gate) -> [QueueStatus.Row] {
    let now = nowMs()
    return entries.values.map { e in
      let s = e.session
      let checkout = checkout(s)
      // `repository` starts the lookup that `repositoryKnown` waits for, so it runs first.
      let repository = repository(of: e, checkout: checkout, gate: gate)
      return QueueStatus.Row(
        id: s.id, name: s.name, kind: s.kind, group: s.group, repository: repository,
        repositoryRead: repositoryKnown(s, checkout: checkout), markedDone: s.done, paused: Pause.blocker(s) != nil,
        removing: s.removal?.holdsSession == true,
        state: Attention.evaluate(s, e.facts, now: now, stateOf: lastState).state, unreadHost: e.facts.unread != nil,
        prMerged: e.facts.pr?.state == .merged, hasMergeAction: subjects.merging.contains(s.id),
        hasRemovalAction: subjects.removing.contains(s.id), started: !s.waitsToStart,
        startWaitingForSlot: e.queuedSince != nil && !e.pending.isEmpty)
    }.sorted { $0.id < $1.id }
  }

  /// The repository of the session as a gate reads it. That is the gate's repository when the session's PR, issue
  /// link, or follow-up is in it, and otherwise the owner/name of the origin of `checkout`, the session's checkout. A
  /// follow-up that hasn't started has no checkout, so it has only its follow-up's repository. It runs on the state
  /// queue.
  func repository(of e: Entry, checkout: String?, gate: Schedule.Gate) -> String? {
    let s = e.session
    if s.waitsToStart { return s.followup?.repository }
    // A fork's checkout names the fork as its origin, while sbd starts sessions there for the upstream repository.
    let origin = checkout.flatMap { repository($0, of: s) }
    let named = [e.facts.pr?.repo, s.issue?.repo, s.followup?.repository].compactMap { $0 }
    return named.contains { Dependencies.sameRepo($0, gate.repo) } ? gate.repo : origin
  }

  /// The subjects of the action waits of `waitHolders`. It runs on the state queue.
  func actionSubjects() -> ActionSubjects {
    var merging = Set<String>()
    var removing = Set<String>()
    for holder in waitHolders() {
      for wait in holder.waits ?? [] {
        guard let action = wait.action?.kind, let subject = wait.actionSubject?.id else { continue }
        switch action {
        case .merge: merging.insert(subject)
        case .rmWorktree, .rm: removing.insert(subject)
        case .report: break
        }
      }
    }
    return (merging, removing)
  }

  /// Saves the schedule's next run, and with `running` the start of a headless or script run at `now`, sets them on
  /// `schedule`, and returns how many due times the run skips. It returns nil when the save fails.
  func saveNextRun(_ id: String, _ schedule: inout Schedule, now: Int64, running: Bool = false) -> Int? {
    let (next, skipped) = schedule.fired(at: now)
    let mark = { (s: inout Schedule) in
      s.next = next
      if running { s.running = now }
    }
    do {
      try changeSchedule(id, schedule.id, mark)
    } catch {
      logLine("can't run schedule \(schedule.id) of \(id), because its next run can't be saved: \(error)")
      return nil
    }
    mark(&schedule)
    return skipped
  }

  /// Sends `text` to the session, then records the run through `recordRun`.
  func sendAndRecord(
    _ id: String, _ schedule: Schedule, text: String, skipped: Int, check: Schedule.Gate.Check? = nil, now: Int64
  ) {
    let run: Schedule.Run
    do {
      let delivered = try deliver(id, text, by: .sbd, trigger: .schedule)
      run = Schedule.Run(t: now, outcome: .init(delivered.delivery), skipped: skipped, sent: delivered.sent.id)
    } catch {
      logLine("can't run schedule \(schedule.id) of \(id): \(error)")
      run = Schedule.Run(t: now, outcome: .failed, skipped: skipped, error: "\(error)")
    }
    recordRun(id, schedule, run: run, check: check)
  }

  /// Saves `run` on `schedule`, ends a headless or script run's time in flight, and records a `schedule-ran` event. A
  /// gated schedule's `check` is saved as the gate's last check in the same save, as failed when the run failed.
  func recordRun(_ id: String, _ schedule: Schedule, run: Schedule.Run, check: Schedule.Gate.Check?) {
    var ran = schedule
    var check = check
    if run.outcome == .failed {
      check?.result = .failed
      check?.error = run.error
    }
    let save = { (s: inout Schedule) in
      s.record(run)
      s.running = nil
      if let check { s.gate?.last = check }
    }
    save(&ran)
    do {
      try changeSchedule(id, schedule.id, save)
    } catch {
      logLine("can't save the run of schedule \(schedule.id) of \(id): \(error)")
    }
    var data: [String: JSON] = ["outcome": .string(run.outcome.rawValue), "skipped": .number(Double(run.skipped))]
    data["schedule"] = try? JSON(encoding: ran)
    if let error = run.error { data["error"] = .string(error) }
    if let runner = schedule.runner { data["runner"] = .string(runner.rawValue) }
    if let exit = run.exit { data["exit"] = .number(Double(exit)) }
    if let tail = run.tail { data["tail"] = .string(tail) }
    record(id, "schedule-ran", .object(data))
  }

  /// The schedule without its run history, which neither an edit nor a Run Now request changes.
  private func eventJSON(_ schedule: Schedule) throws -> JSON {
    var schedule = schedule
    schedule.runs = nil
    return try JSON(encoding: schedule)
  }

  /// Changes one schedule of the session and saves the session's row.
  func changeSchedule(_ id: String, _ scheduleId: String, _ change: (inout Schedule) -> Void) throws {
    try update(id) { $0.changeSchedule(scheduleId, change) }
  }

  private func scheduleRow(_ id: String, _ schedule: Schedule) -> ScheduleRow {
    let session = entries[id]!.session
    return ScheduleRow(
      session: id, name: session.name, schedule: schedule,
      status: ScheduleStatus(schedule, hold: session.scheduleHold, now: nowMs()))
  }

  /// The schedule that the request's `schedule` names, with its session. It
  /// throws when `session` is given and doesn't own the schedule, and when
  /// the owner is outside the request's scope.
  private func ownedSchedule(_ args: JSON) throws -> (session: String, schedule: Schedule) {
    guard let ref = args["schedule"]?.string, !ref.isEmpty else { throw APIError("name a schedule") }
    let named = try args["session"].map { _ in try lookup(args) }
    let owner = entries.values.lazy.map(\.session).compactMap { s in
      s.schedule(ref).map { (session: s.id, schedule: $0) }
    }.first
    guard let owner, named == nil || named == owner.session else {
      throw APIError(named.map { "\($0) has no schedule \(ref)" } ?? "no schedule \(ref)")
    }
    try requireInScope(owner.session, args: args)
    return owner
  }

  /// Refuses a session outside the request's scope.
  func requireInScope(_ id: String, args: JSON) throws {
    guard try !inScope(id, args: args) else { return }
    let group = args["group"]?.string ?? ""
    throw APIError("\(id) is not in group \(groups[group]?.name ?? group)")
  }

  /// True when the request has no `group`, or when the session is in that
  /// group or is the `caller`. It throws for a `group` that isn't an id, so a
  /// malformed scope never reads as no scope.
  private func inScope(_ id: String, args: JSON) throws -> Bool {
    guard let value = args["group"] else { return true }
    guard let group = value.string, !group.isEmpty else { throw APIError("group is the id of a group") }
    return entries[id]?.session.group == group || id == args["caller"]?.string
  }
}
