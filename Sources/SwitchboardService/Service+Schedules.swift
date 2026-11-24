import Foundation
import SwitchboardCore

/// Schedules: prompts that sbd sends to a session on an interval.
extension Service {
  /// The `schedule`, `schedules`, `remove-schedule`, `pause-schedule`,
  /// `edit-schedule`, and `run-schedule` requests. Each takes an optional
  /// `group` and `caller`, which a scoped MCP server sends. With `group`, a
  /// request acts only on the group's sessions and on the caller. It runs on
  /// the state queue, so the scope check and the change happen in one step.
  /// `origin` and `caller` sent the request, which decides whether it may add
  /// or edit a schedule with a top-up gate. It runs after `install` of a fresh
  /// snapshot when it adds a gate or edits a schedule.
  func scheduleRequest(_ op: String, _ args: JSON, origin: RequestOrigin, caller: Caller) throws -> JSON {
    switch op {
    case "schedule": return try addSchedule(args, origin: origin, caller: caller)
    case "schedules": return try listSchedules(args)
    case "remove-schedule": return try removeSchedule(args)
    case "pause-schedule": return try pauseSchedule(args)
    case "edit-schedule": return try editSchedule(args, origin: origin, caller: caller)
    case "run-schedule": return try runSchedule(args)
    default: throw APIError("unknown request \(op)")
    }
  }

  private func addSchedule(_ args: JSON, origin: RequestOrigin, caller: Caller) throws -> JSON {
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
    let open = session.schedules ?? []
    guard open.count < Schedule.maxPerSession else {
      throw APIError(
        "\(id) has \(Schedule.maxPerSession) schedules, the most a session can have. Remove one with: sb schedule rm <id>"
      )
    }
    let request = try JSONCoding.convert(args, to: ScheduleRequest.self)
    let group = try request.gate.flatMap { try topupGroup($0, args, origin: origin, caller: caller) }
    let taken = entries.values.flatMap { $0.session.schedules ?? [] }.map(\.id)
    let schedule = try request.makeSchedule(id: shortId("r", taken: taken), now: nowMs(), group: group)
    if let duplicate = Schedule.duplicate(of: schedule, in: open) { throw APIError(duplicate) }
    try update(id) { $0.schedules = open + [schedule] }
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

  private func listSchedules(_ args: JSON) throws -> JSON {
    let only = try args["session"].map { _ in try lookup(args) }
    let sessions = try entries.values.map(\.session)
      .filter { s in only == nil || only == s.id }
      .filter { try inScope($0.id, args: args) }
    let rows: [ScheduleRow] = sessions.flatMap { s in (s.schedules ?? []).map { scheduleRow(s.id, $0) } }
    func order(_ r: ScheduleRow) -> (Int, Int64, String) {
      (r.schedule.paused == true ? 1 : 0, r.schedule.next, r.schedule.id)
    }
    return try JSON(encoding: rows.sorted { order($0) < order($1) })
  }

  private func removeSchedule(_ args: JSON) throws -> JSON {
    let (id, schedule) = try ownedSchedule(args)
    try update(id) { s in
      let rest = (s.schedules ?? []).filter { $0.id != schedule.id }
      s.schedules = rest.isEmpty ? nil : rest
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

  /// True when the schedule that `args` names has a gate, so its edit runs the caller check. It runs on the state
  /// queue.
  func editsGatedSchedule(_ args: JSON) -> Bool {
    (try? ownedSchedule(args))?.schedule.gate != nil
  }

  /// Changes the interval, the prompt, or both. It sends nothing: a next run
  /// that the edit makes due fires through `fireDueSchedules`.
  private func editSchedule(_ args: JSON, origin: RequestOrigin, caller: Caller) throws -> JSON {
    let (id, found) = try ownedSchedule(args)
    if found.gate != nil { try checkTopupCaller(args, origin: origin, caller: caller) }
    let request = try JSONCoding.convert(args, to: ScheduleRequest.self)
    let schedule = try found.edited(every: request.every, prompt: request.prompt, now: nowMs())
    guard schedule != found else { return try JSON(encoding: scheduleRow(id, found)) }
    try changeSchedule(id, schedule.id) { $0 = schedule }
    record(id, "schedule-edited", ["schedule": try eventJSON(schedule), "before": try eventJSON(found)])
    return try JSON(encoding: scheduleRow(id, schedule))
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
  /// A schedule with a gate checks the gate first. A closed gate sends
  /// nothing, so its check runs while the session is busy. A short group
  /// starts a top-up on `topupQueue` without waiting for the session either.
  /// An open gate sends the fallback message only when the session is free.
  /// A failed top-up sends its fallback only when the session is free, and
  /// otherwise saves the failed check and sends nothing. A schedule whose
  /// top-up is running stays due and runs no check.
  func fireDueSchedules(now: Int64) {
    let ids = entries.compactMap { id, e in
      e.session.scheduleHold == nil && e.session.schedules?.contains { $0.isDue(now: now) } == true ? id : nil
    }
    // A pass arms and clears no action wait, so it reads the action waits once, at the first gate.
    var subjects: ActionSubjects?
    for id in ids.sorted() {
      guard let session = entries[id]?.session else { continue }
      let due = (session.schedules ?? []).filter { $0.isDue(now: now) }
        .sorted { ($0.next, $0.id) < ($1.next, $1.id) }
      for schedule in due where !topupsInFlight.contains(schedule.id) {
        var opened: (gate: Schedule.Gate, status: QueueStatus)?
        if let gate = schedule.gate {
          let found = subjects ?? actionSubjects()
          subjects = found
          let status = QueueStatus.compute(queueRows(subjects: found, gate: gate), gate: gate)
          switch status.decision {
          case .gated:
            recordGated(id, schedule, status: status, now: now)
            continue
          case .topup(let k):
            dispatchTopup(id, schedule, status: status, k: k, now: now)
            continue
          case .open:
            opened = (gate, status)
          }
        }
        // A run makes the session busy, so the guard runs again before each schedule.
        guard let e = entries[id],
          Schedule.blocker(facts: e.facts, process: promptProcess(id), messageWaiting: messageWaiting(e, now: now))
            == nil
        else { continue }
        let text = opened.map { $0.gate.fallbackMessage(status: $0.status, prompt: schedule.prompt) } ?? schedule.prompt
        let check = opened.map { Schedule.Gate.Check(.prompted, status: $0.status, now: now) }
        fire(id, schedule, text: text, check: check, now: now)
      }
    }
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

  /// Saves the schedule's next run, sets it on `schedule`, and returns how many due times the run skips. It returns
  /// nil when the next run can't be saved.
  func saveNextRun(_ id: String, _ schedule: inout Schedule, now: Int64) -> Int? {
    let (next, skipped) = schedule.fired(at: now)
    do {
      try changeSchedule(id, schedule.id) { $0.next = next }
    } catch {
      logLine("can't run schedule \(schedule.id) of \(id), because its next run can't be saved: \(error)")
      return nil
    }
    schedule.next = next
    return skipped
  }

  /// Sends `text` to the session, then saves the run on `schedule` and records a `schedule-ran` event. A gated
  /// schedule's `check` is saved as the gate's last check in the same save, as failed when the send fails.
  func sendAndRecord(
    _ id: String, _ schedule: Schedule, text: String, skipped: Int, check: Schedule.Gate.Check? = nil, now: Int64
  ) {
    var ran = schedule
    let run: Schedule.Run
    do {
      let delivered = try deliver(id, text, by: .sbd, trigger: .schedule)
      run = Schedule.Run(t: now, outcome: .init(delivered.delivery), skipped: skipped, sent: delivered.sent.id)
    } catch {
      logLine("can't run schedule \(schedule.id) of \(id): \(error)")
      run = Schedule.Run(t: now, outcome: .failed, skipped: skipped, error: "\(error)")
    }
    var check = check
    if run.outcome == .failed {
      check?.result = .failed
      check?.error = run.error
    }
    let save = { (s: inout Schedule) in
      s.record(run)
      if let check { s.gate?.last = check }
    }
    save(&ran)
    do {
      try changeSchedule(id, schedule.id, save)
    } catch {
      logLine("can't save the run of schedule \(schedule.id) of \(id): \(error)")
    }
    var data: [String: JSON] = ["outcome": .string(run.outcome.rawValue), "skipped": .number(Double(skipped))]
    data["schedule"] = try? JSON(encoding: ran)
    if let error = run.error { data["error"] = .string(error) }
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
    try update(id) { s in
      s.schedules = s.schedules?.map { schedule in
        var schedule = schedule
        if schedule.id == scheduleId { change(&schedule) }
        return schedule
      }
    }
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
      s.schedules?.first { $0.id == ref }.map { (session: s.id, schedule: $0) }
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
