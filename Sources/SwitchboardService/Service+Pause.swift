import Foundation
import SwitchboardCore

extension Service {
  /// The line that a dead Claude pane shows while the session isn't paused.
  static let stoppedPaneMessage =
    "Claude stopped. Switchboard resumes it when you open the session or send it a message."

  /// The tick stops a paused session's claude at most this often.
  static let pauseStopMs: Int64 = 5_000

  /// The line that a dead Claude pane shows while the session is paused.
  static func pausedPaneMessage(_ pause: Pause) -> String {
    "\(pause.line). Resume the session to start claude again."
  }

  /// Pauses the session or each session of the group that the request names. One session returns its summary.
  /// A group returns a `PauseReport`. The condition is read once, before anything is paused.
  func pauseRequest(_ args: JSON) throws -> JSON {
    let target = try pauseTarget(args)
    let (by, from) = try asker(args)
    let reason = try Pause.cleanReason(args["reason"]?.string)
    let message = args["message"]?.string.flatMap(nonBlank)
    let now = nowMs()
    let condition = try args["until"]?.string.map { try Pause.parseUntil($0, now: now) }
    if let condition { try requireConditionInScope(condition, args) }
    let pauseOne = { (id: String) in
      try self.pause(id, by: by, from: from, reason: reason, message: message, condition: condition, now: now)
    }
    switch target {
    case .session(let id):
      try pauseOne(id)
      return try JSON(encoding: summary(id))
    case .group(let group):
      return try JSON(encoding: pauseGroup(group, condition: condition, now: now, pauseOne))
    }
  }

  /// Pauses each work session of the group that has started, isn't marked done, and isn't paused. It refuses a
  /// condition that names a session of the group, because that session would be paused too and never reach
  /// the state.
  private func pauseGroup(
    _ group: String, condition: WaitRequest?, now: Int64, _ pauseOne: (String) throws -> Void
  ) throws -> PauseReport {
    if let condition {
      // The group's id is never a session's, so this checks the condition without the waiter's own refusal.
      let check = try condition.makeWait(id: "w", waiter: group, now: now, findSession: waitTarget)
      if let other = check.session, members(group).workMembers.contains(where: { $0.id == other.id }) {
        throw APIError(
          "--until names \(other.name) (\(other.id)), which is in group \(groups[group]!.name). The group pause would pause it too, so it would never reach the state"
        )
      }
    }
    return groupReport(group, done: .paused, skip: \.groupPauseSkip, pauseOne)
  }

  /// One row for each work session of the group. `skip` gives a member's row without acting on it. `act` runs on
  /// each other member, whose row is then `done`, or `failed` with the error that `act` threw.
  private func groupReport(
    _ group: String, done: PauseRow.Result, skip: (Session) -> PauseRow.Result?, _ act: (String) throws -> Void
  ) -> PauseReport {
    let rows = members(group).workMembers.map { s -> PauseRow in
      if let result = skip(s) { return PauseRow(session: s.id, name: s.name, result: result) }
      do {
        try act(s.id)
        return PauseRow(session: s.id, name: s.name, result: done)
      } catch {
        return PauseRow(session: s.id, name: s.name, result: .failed, error: "\(error)")
      }
    }
    return PauseReport(group: group, name: groups[group]!.name, sessions: rows)
  }

  /// The request's `by`, and `from`, the session whose Claude sent it. A sender that sbd no longer knows goes
  /// unrecorded.
  private func asker(_ args: JSON) throws -> (by: Author, from: String?) {
    (try Author(parsing: args["by"]?.string), try? lookup(["session": args["from"] ?? .null]))
  }

  /// Pauses one session. It refuses a session that hasn't started, a session that pauses itself, Claude pausing
  /// a Manager conversation or a group chat, and a session on a host that sbd can't read. A second pause replaces
  /// who paused, the reason, the condition, and the message, and keeps `since`.
  private func pause(
    _ id: String, by: Author, from: String?, reason: String?, message: String?, condition: WaitRequest?, now: Int64
  ) throws {
    let session = entries[id]!.session
    try refuseNotStarted(session)
    if from == id {
      throw APIError(
        "\(id) can't pause itself, because the pause stops the claude that runs this command. To wait on something, use sb wait"
      )
    }
    if by == .claude, let label = session.kind.label { throw APIError("only the user can pause \(label)") }
    try requireRead(id)
    let until = try condition.map {
      try $0.makeWait(id: shortId("w", taken: waitIds(id)), waiter: id, now: now, findSession: waitTarget)
    }
    let pause = Pause(
      by: by, from: from.map(pauser), reason: reason, since: session.pause?.since ?? now, until: until,
      message: message)
    try update(id) { $0.pause = pause }
    entries[id]?.queuedSince = nil
    entries[id]?.queuedTrigger = nil
    entries[id]?.jumpedAt = nil
    entries[id]?.mcpRelaunch = nil
    entries[id]?.resumeLaunch = nil
    // tmux writes the dead message when claude exits, so it is set before the stop.
    setClaudeDeadMessage(id, Service.pausedPaneMessage(pause))
    record(id, "paused", try JSON(encoding: pause))
    // A starting claude has no pid to stop yet. The tick stops it once it has one.
    if case .running = claudeState(id) { enforcePause(id, now: nowMs()) }
  }

  /// What a `pause` or `resume` request names.
  enum PauseTarget {
    case session(String)
    case group(String)
  }

  /// The session or group that the request names, checked against the request's `scope`. `group` names a group.
  /// `session` names a session, and names a group only when no session matches it. sbd refuses a ref
  /// that matches a session and also names a group, unless it is the session's whole id.
  func pauseTarget(_ args: JSON) throws -> PauseTarget {
    let target: PauseTarget
    if args["group"] != nil {
      guard args["session"] == nil else { throw APIError("name a session or a group, not both") }
      target = .group(try lookupGroup(args))
    } else if let ref = args["session"]?.string, entries[ref] == nil, !ref.isEmpty {
      let namesSession = entries.values.contains { refMatches(ref, ($0.session.id, $0.session.name)) }
      let namesGroup = groups.values.contains { refMatches(ref, ($0.id, $0.name)) }
      if namesSession && namesGroup {
        throw APIError("\(ref) names a session and a group. Use the session's id, or --group")
      }
      target = namesGroup ? .group(try lookupGroup(["group": .string(ref)])) : .session(try lookup(args))
    } else {
      target = .session(try lookup(args))
    }
    try requireInScope(target, args)
    return target
  }

  /// A scoped MCP server sends `scope`, its group, and `caller`, its own session. Such a request may act only on
  /// a session in that group, on the caller itself, or on that group.
  func requireInScope(_ target: PauseTarget, _ args: JSON) throws {
    guard let scope = try scope(args) else { return }
    let name = groups[scope]?.name ?? scope
    switch target {
    case .session(let id):
      guard inScope(id, scope, args) else { throw APIError("\(id) is not in group \(name)") }
    case .group(let id):
      guard id == scope else { throw APIError("\(groups[id]!.name) is not group \(name)") }
    }
  }

  private func scope(_ args: JSON) throws -> String? {
    guard let value = args["scope"], value != .null else { return nil }
    guard let scope = value.string else { throw APIError("scope is a group id") }
    return scope
  }

  private func inScope(_ id: String, _ scope: String, _ args: JSON) -> Bool {
    entries[id]?.session.group == scope || id == args["caller"]?.string
  }

  /// A scoped request's condition may name only a session in the scope's group, or the caller. A ref that
  /// matches no session gets the same refusal, so a group chat can't learn which names exist outside its group.
  private func requireConditionInScope(_ condition: WaitRequest, _ args: JSON) throws {
    guard condition.kind == Wait.Kind.session.rawValue, let ref = condition.target, let scope = try scope(args)
    else { return }
    guard let other = try? lookup(["session": .string(ref)]), inScope(other, scope, args) else {
      throw APIError("--until \(ref) is not in group \(groups[scope]?.name ?? scope)")
    }
  }

  /// The ids of the session's open waits and of its pause condition, which a new wait or condition doesn't reuse.
  func waitIds(_ id: String) -> [String] {
    entries[id]?.session.resolvableWaits.map(\.id) ?? []
  }

  /// The session that a `session` wait or a pause condition names, by id, prefix, or name.
  func waitTarget(_ ref: String) throws -> Wait.SessionTarget {
    let other = try lookup(["session": .string(ref)])
    return Wait.SessionTarget(id: other, name: entries[other]!.session.name)
  }

  /// The session's pause condition when `waitId` names it.
  func pauseCondition(_ id: String, _ waitId: String?) -> Wait? {
    guard let waitId, let until = entries[id]?.session.pause?.until, until.id == waitId else { return nil }
    return until
  }

  /// Resumes the session when `wait` is its pause condition, and returns whether it was. A met condition records
  /// no `wait-resolved`, because the condition isn't one of the session's waits.
  func resumeOnCondition(_ id: String, _ wait: Wait, outcome: String) throws -> Bool {
    guard pauseCondition(id, wait.id) != nil else { return false }
    try unpause(id, outcome: outcome, message: nil, trigger: .wait, by: nil, from: nil)
    return true
  }

  /// Refuses a request that names the pause condition as a wait to clear. Only a resume or the condition ends it.
  func refuseCondition(_ id: String, _ waitId: String) throws {
    guard pauseCondition(id, waitId) != nil else { return }
    throw APIError(
      "\(waitId) is the condition that resumes \(id), not a wait. Resume it with: sb resume \(id), or pause it again without --until"
    )
  }

  /// Stops the paused session's running claude, at most once every `pauseStopMs`. A claude that reported
  /// SessionEnd is already exiting, so it gets no second stop. A claude that has sent no hook since its launch
  /// never read its launch prompt, so the prompt goes to the front of the held messages before the stop.
  func enforcePause(_ id: String, now: Int64) {
    guard let e = entries[id], !e.facts.exiting, now - (e.pauseStopAt ?? 0) >= Service.pauseStopMs else { return }
    entries[id]?.pauseStopAt = now
    holdUnreadLaunchPrompt(id, e)
    do { try stop(id, reason: "paused") } catch { logLine("can't stop paused \(id): \(error)") }
  }

  private func holdUnreadLaunchPrompt(_ id: String, _ e: Entry) {
    guard !e.facts.hookSinceLaunch,
      // `closeTrust` puts the prompt back when a trust card is open.
      e.facts.trustCard == nil,
      let prompt = e.facts.lastLaunchPrompt, !prompt.isEmpty,
      !e.pending.contains(where: { $0.text == prompt })
    else { return }
    do {
      try queueFirst(id, prompt, by: .you, from: nil, extra: ["held": true])
    } catch {
      logLine("can't hold the launch prompt of paused \(id): \(error)")
    }
  }

  /// Puts the message at the front of the session's queue and records a `first` `sent` event, so a restart of
  /// sbd rebuilds the same order.
  private func queueFirst(_ id: String, _ text: String, by: MessageAuthor, from: String?, extra: [String: JSON] = [:])
    throws
  {
    let sent = try recordSent(id, text, .queued, by: by, from: from, extra: extra.merging(["first": true]) { $1 })
    entries[id]?.pending.insert(QueuedMessage(text: text, sent: sent), at: 0)
  }

  /// Resumes the session or each paused session of the group that the request names, with the request's
  /// message, else each pause's own. A session that isn't paused launches as `sb resume` always did, with the
  /// message as its prompt. A group skips a session that isn't paused.
  func resumeRequest(_ args: JSON, origin: RequestOrigin = .mac) throws -> JSON {
    let target = try pauseTarget(args)
    let message = args["message"]?.string
    let prompt = args["prompt"]?.string
    if message != nil && prompt != nil { throw APIError("resume takes a message or a prompt, not both") }
    let text = (message ?? prompt).flatMap(nonBlank)
    let (by, from) = try asker(args)
    let resumeOne = { (id: String) in
      let other = from == id ? nil : from
      try self.unpause(id, outcome: nil, message: text, trigger: other == nil ? .resume : .session, by: by, from: other)
    }
    switch target {
    case .session(let id):
      if entries[id]!.session.pause != nil {
        // The user or the Manager set the pause on this Mac, so a host can't end it.
        if case .remote(let host) = origin {
          throw APIError("\(entries[id]!.session.name) is paused, and \(host) can't resume it")
        }
        try resumeOne(id)
      } else {
        try launch(id, prompt: text, by: MessageAuthor(by), trigger: .resume)
      }
      return try JSON(encoding: summary(id, for: origin))
    case .group(let group):
      return try JSON(encoding: groupReport(group, done: .resumed, skip: \.groupResumeSkip, resumeOne))
    }
  }

  /// Ends the session's pause and sends the resume message ahead of the held messages. `outcome` says why it
  /// resumes, and `message` replaces the pause's text. `by` is nil when sbd resumes the session on its own. A host
  /// that sbd can't read keeps the pause. A folder that is gone ends the pause, then throws the folder's error
  /// before anything is sent, so a gone folder never keeps a pause. A session that is being deleted keeps its pause,
  /// so a met condition resumes it after an Undo.
  func unpause(
    _ id: String, outcome: String?, message: String?, trigger: LaunchTrigger, by: Author?, from: String?
  ) throws {
    guard let session = entries[id]?.session, let pause = session.pause else { throw APIError("\(id) isn't paused") }
    if let refusal = beingDeletedRefusal(id) { throw refusal }
    try requireRead(id)
    var folderGone: FolderGone?
    do {
      try requireFolder(session)
    } catch let gone as FolderGone {
      folderGone = gone
    }
    let now = nowMs()
    try update(id) { s in
      s.pause = nil
      // A date wait and a manual wait carry their own times.
      s.waits = s.waits?.map { w in
        guard w.kind != .date, w.kind != .manual else { return w }
        var fresh = w
        fresh.recheck = nil
        return config.recheck.stamped(fresh, from: now)
      }
    }
    entries[id]?.pauseStopAt = nil
    var data: [String: JSON] = ["pause": try JSON(encoding: pause), "by": .string(by?.rawValue ?? "sbd")]
    if let outcome { data["outcome"] = .string(outcome) }
    if let from { data["from"] = .string(from) }
    record(id, "unpaused", .object(data))
    setClaudeDeadMessage(id, Service.stoppedPaneMessage)
    if let folderGone { throw folderGone }
    let text = pause.resumeText(outcome: outcome, override: message)
    let author = MessageAuthor(by)
    if claudeState(id) == .stopped, entries[id]!.pending.isEmpty {
      _ = try send(id, text, by: author, trigger: trigger, from: from)
      return
    }
    try queueFirst(id, text, by: author, from: from)
    if claudeState(id) == .stopped {
      try launch(id, prompt: nil, trigger: trigger)
    } else {
      entries[id]?.resumeLaunch = trigger
      // The stop's event cleared `live`, so a claude that the pause stopped takes no paste.
      deliverPending(id, after: 0)
    }
  }

  /// The session that paused another, with a chat named by its group.
  private func pauser(_ id: String) -> Pause.Pauser {
    let s = entries[id]!.session
    return Pause.Pauser(id: id, name: s.chat.flatMap { groups[$0]?.name } ?? s.name, kind: s.kind)
  }

  /// Sets the line that the session's Claude pane shows once claude exits. A session with no Claude pane has
  /// none to set.
  func setClaudeDeadMessage(_ id: String, _ message: String) {
    guard paneRow(id, .claude) != nil else { return }
    do {
      try site(of: id).terminals().setDeadMessage(paneName(id, .claude), message)
    } catch {
      logLine("can't set the dead message of \(id): \(error)")
    }
  }
}

private func nonBlank(_ text: String) -> String? {
  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
}
