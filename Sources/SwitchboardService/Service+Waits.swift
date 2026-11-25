import Foundation
import SwitchboardCore

/// Waits, notes, and the test clock. `plans/waits-notes.md` in the notes repo
/// describes them.
extension Service {
  /// The `wait`, `clear-wait`, and `resolve-wait` requests. `resolve-wait`
  /// acts on processes, so `handle` settles the session and takes a new
  /// snapshot first, as for `send`. A `clear-wait` or `resolve-wait` that names
  /// a conversation also reaches the waits that it handed to the operator. The
  /// answer to `clear-wait` adds `cleared`, the ids of the waits it cleared. `caller` sent the request, which
  /// decides whether a `wait` may arm an action. A `resolve-wait` from a client is never met, so a client can't
  /// start an action. Only sbd's poller says that a condition was met, through `resolveWait`.
  func waitRequest(_ op: String, _ args: JSON, origin: RequestOrigin = .mac, caller: Caller) throws -> JSON {
    let id = try lookup(args)
    switch op {
    case "wait":
      return try JSON(encoding: summary(setWait(args, waiter: id, from: origin, caller: caller), for: origin))
    case "clear-wait":
      let cleared = try clearWaits(id, args["wait"]?.string)
      var answer = try JSON(encoding: summary(id, for: origin)).object ?? [:]
      answer["cleared"] = .array(cleared.map(JSON.string))
      return .object(answer)
    case "resolve-wait":
      guard let outcome = args["outcome"]?.string, !outcome.isEmpty else {
        throw APIError("resolve-wait needs an outcome that says what happened")
      }
      guard args["met"] == nil else { throw APIError("only sbd says whether a wait's condition was met") }
      try resolve(
        id, waitId: args["wait"]?.string, outcome: outcome, changedAt: args["changedAt"]?.int.map(Int64.init),
        met: false)
    default:
      throw APIError("unknown request \(op)")
    }
    return try JSON(encoding: summary(id, for: origin))
  }

  /// Builds the wait that `args` describe for the session `named`, and stores
  /// it. When `handsOff` allows it, the operator holds the wait instead, and
  /// `handedFrom` names `named`. The first such wait creates the operator.
  /// `here` in `args` keeps the wait on `named`. It records the `wait` event
  /// on the session that holds the wait, with `from` for a handed-off wait,
  /// and returns the id of that session. The caller holds the state queue.
  /// A wait from a host must pass `requireGitHubWait`. A wait with an action must pass `armAction`. A merge wait must
  /// land on the operator, because only the operator approves a merge. A reply wait without a target takes the
  /// session's one Slack thread. A reply wait needs the Slack poll on.
  func setWait(_ args: JSON, waiter named: String, from origin: RequestOrigin, caller: Caller) throws -> String {
    let session = entries[named]!.session
    try refuseNotStarted(session)
    var request = try JSONCoding.convert(args, to: WaitRequest.self)
    if request.kind == Wait.Kind.reply.rawValue && request.target == nil { request.target = try replyTarget(of: named) }
    // The checks run against `named`, so a conversation still can't wait on itself.
    var wait = try request.makeWait(id: "", waiter: named, now: nowMs(), findSession: waitTarget)
    if wait.kind == .reply && !slackPollOn { throw slackPollOff }
    if case .remote(let host) = origin { try requireGitHubWait(wait, on: named, from: host) }
    if wait.action != nil { try armAction(&wait, args, origin: origin, caller: caller) }
    if wait.kind == .ci && wait.pr == nil {
      wait.headSha = try? checkedOutBranch(session, at: site(of: named)).tip
    }
    var waiter = named
    let op = operatorID()
    let hands = handsOff(wait, namedSession: session, here: args["here"]?.bool == true, operatorID: op)
    if wait.action?.kind == .merge, !hands, session.kind != .operator {
      throw APIError(
        "then merge goes only on a wait that the operator holds, because only the operator approves the merge. Set it "
          + "without --here, from a Manager conversation, or on \(Manager.operatorName)")
    }
    if hands {
      waiter = try op ?? ensureOperator()
      wait.handedFrom = Wait.SessionTarget(id: named, name: session.name)
    }
    let open = entries[waiter]!.session.waits ?? []
    wait.id = shortId("w", taken: waitIds(waiter))
    wait = config.recheck.stamped(wait)
    try update(waiter) { $0.waits = open + [wait] }
    record(waiter, "wait", try waitEventData(wait))
    return waiter
  }

  /// Refuses an action that the sender may not arm or that its subject can't take, and sets the subject of
  /// `rm-worktree` on a merge wait.
  ///
  /// `checkActionCaller` decides who may arm an action. A session never arms a merge on itself. A subject on a host
  /// is refused. A merge needs the subject's PR in a repository that `operator.mergeRepos` lists. It runs on the state
  /// queue, after `install` of a fresh snapshot.
  private func armAction(_ wait: inout Wait, _ args: JSON, origin: RequestOrigin, caller: Caller) throws {
    guard let action = wait.action?.kind else { return }
    let then = "then \(action.rawValue)"
    try checkActionCaller(
      args, origin: origin, caller: caller, command: "sb wait", option: then, arms: action.rawValue,
      notFrom: action == .merge ? wait.session?.id : nil)
    if action == .rmWorktree, wait.kind == .merge, let pr = wait.pr, let repository = pr.repository {
      let id = try sessionByPR(["pr": .number(Double(pr.number)), "repository": .string(repository)])
      wait.subject = Wait.SessionTarget(id: id, name: entries[id]!.session.name)
    }
    guard let subject = wait.actionSubject?.id else { return }
    guard let e = entries[subject] else { throw APIError("\(then) acts on \(subject), which sbd no longer has") }
    if let host = e.session.host {
      throw APIError("\(then) acts only on a session on this Mac, and \(e.session.name) runs on \(host)")
    }
    guard action == .merge else { return }
    guard let pr = e.facts.pr else { throw APIError("\(e.session.name) has no PR yet, so sbd has nothing to merge") }
    guard operatorSettings.mergesIn(pr.repo) else {
      throw APIError(
        "sbd merges only in the repositories that operator.mergeRepos in \(home.config) lists, and it doesn't list "
          + "\(pr.repo). The user merges #\(pr.number) from the Inbox")
    }
  }

  /// Refuses a request that arms an action when the sender may not arm it.
  ///
  /// Only a Manager conversation, the Operator, or the user may arm an action, and both signals of the sender must
  /// allow it: the client's ancestry reaches no other session's pane and no part of sbd's tmux server outside the
  /// panes, and the request's `caller`, when it has one, names a Manager conversation or the Operator. A request from
  /// a host is refused. A request from inside the session `notFrom`, or one whose `caller` names it, is refused. The
  /// refusals name `command`, its `option`, and the action it `arms`. It runs on the state queue, after `install` of
  /// a fresh snapshot.
  func checkActionCaller(
    _ args: JSON, origin: RequestOrigin, caller: Caller, command: String, option: String, arms: String,
    notFrom subject: String?
  ) throws {
    guard case .mac = origin else {
      throw APIError("\(option) can't come from a host, because actions run on this Mac")
    }
    let ancestry = try caller.ancestry(command: "\(command) --\(option)")
    let claimed = args["caller"]?.string
    if let subject, claimed == subject || ancestry.map({ isInside(subject, $0) }) == true {
      throw APIError("a session can't arm \(arms) on itself")
    }
    let refusal = "only a Manager conversation, the Operator, or you can arm \(arms)"
    let mayArm = { (id: String) in [SessionKind.manager, .operator].contains(self.entries[id]?.session.kind) }
    if let claimed, !mayArm(claimed) {
      throw APIError("\(refusal), and the request comes from \(entries[claimed] == nil ? claimed : mention(claimed))")
    }
    if let ancestry {
      let place = callerPlace(ancestry)
      if let other = place.inside.first(where: { !mayArm($0) }) {
        throw APIError("\(refusal), and `\(command)` runs inside \(mention(other))")
      }
      if place.inside.isEmpty && place.inServer {
        throw APIError("\(refusal), and `\(command)` runs in sbd's tmux server, where the sessions run")
      }
    }
  }

  /// The data of a `wait` or `wait-resolved` event, with `from` naming the
  /// conversation that handed the wait to the operator.
  private func waitEventData(_ wait: Wait, _ extra: [String: JSON] = [:]) throws -> JSON {
    var data = extra
    data["wait"] = try JSON(encoding: wait)
    if let from = wait.handedFrom { data["from"] = .string(from.id) }
    return .object(data)
  }

  /// The operator's id and the waits on it that the conversation `id` handed
  /// off, or nil when no operator exists. With `quiet`, it does not log more than one operator. The summary of
  /// every conversation passes `quiet`, because each `ls` builds those summaries.
  func handedOff(from id: String, quiet: Bool = false) -> (holder: String, waits: [Wait])? {
    guard let op = operatorID(quiet: quiet), op != id else { return nil }
    return (op, (entries[op]?.session.waits ?? []).filter { $0.handedFrom?.id == id })
  }

  /// Clears the waits of `id` and the waits that it handed off, or only the
  /// one that `waitId` names. It returns the ids it cleared.
  private func clearWaits(_ id: String, _ waitId: String?) throws -> [String] {
    if let waitId {
      let (holder, wait) = try openWait(id, waitId)
      try drop([wait.id], from: holder, handedFrom: holder == id ? nil : id)
      return [wait.id]
    }
    let own = (entries[id]?.session.waits ?? []).map(\.id)
    try drop(own, from: id, handedFrom: nil)
    guard let handed = handedOff(from: id) else { return own }
    let ids = handed.waits.map(\.id)
    try drop(ids, from: handed.holder, handedFrom: id)
    return own + ids
  }

  /// Removes the waits `ids` from `holder` and records `wait-cleared`.
  private func drop(_ ids: [String], from holder: String, handedFrom: String?) throws {
    guard !ids.isEmpty else { return }
    try update(holder) { $0.waits = ($0.waits ?? []).filter { !ids.contains($0.id) } }
    var data: [String: JSON] = ["waits": .array(ids.map(JSON.string))]
    if let handedFrom { data["from"] = .string(handedFrom) }
    record(holder, "wait-cleared", .object(data))
  }

  /// The open waits of these kinds, with their sessions. A poller calls it on
  /// each pass.
  func openWaits(_ kinds: Set<Wait.Kind>) -> [(session: Session, wait: Wait)] {
    queue.sync { waitsToResolve().filter { kinds.contains($0.wait.kind) } }
  }

  /// The open waits that may resolve. A wait whose action runs waits for the run to end, which resolves it.
  private func waitsToResolve() -> [(session: Session, wait: Wait)] {
    waitHolders().flatMap { s in
      s.resolvableWaits.filter { $0.actionStatus?.kind != .running }.map { (session: s, wait: $0) }
    }
  }

  /// Arms `--kind session --target <target> --state <state>`, with `--then <action>` when it has one, on `holder`, in
  /// process. `state` is an `AttentionState` raw value. It runs on the state queue.
  func armSessionWait(holder: String, target: String, state: String, then action: WaitAction.Kind? = nil) throws {
    var args: [String: JSON] = [
      "session": .string(holder), "kind": .string(Wait.Kind.session.rawValue), "target": .string(target),
      "state": .string(state), "by": .string(Author.claude.rawValue),
    ]
    if let action { args["then"] = .string(action.rawValue) }
    _ = try waitRequest("wait", .object(args), caller: .inProcess)
  }

  /// The sessions whose waits sbd resolves, by id. A session marked done keeps its waits, and they don't resume it.
  /// It runs on the state queue.
  func waitHolders() -> [Session] {
    entries.keys.sorted().compactMap { entries[$0]?.session }.filter { !$0.done }
  }

  /// Resolves an open wait and runs its `then`, through the `resolve-wait`
  /// request. `outcome` says what happened in words, such as "the checks
  /// passed". `changedAt` is when that happened on GitHub or Trunk, in ms,
  /// when the poller knows it. `met` says whether the change the wait asked
  /// for happened. A poller calls it from its own queue. A met action wait only starts its action or leaves it as
  /// it is, which sends nothing, so it skips the settle and the fresh snapshot that a message needs.
  func resolveWait(session: String, wait: String, outcome: String, changedAt: Int64?, met: Bool) throws
    -> SessionSummary
  {
    let started = try queue.sync { () throws -> SessionSummary? in
      guard met, pauseCondition(session, wait) == nil, (try? openWait(session, wait))?.wait.action != nil else {
        return nil
      }
      if let refusal = removalRefusal(session) { throw refusal }
      try resolve(session, waitId: wait, outcome: outcome, changedAt: changedAt, met: true)
      return summary(session)
    }
    if let started { return started }
    var args: [String: JSON] = ["session": .string(session), "wait": .string(wait), "outcome": .string(outcome)]
    if let changedAt { args["changedAt"] = .number(Double(changedAt)) }
    let request = Request(op: "resolve-wait", args: .object(args))
    let result = try prepared(request, origin: .mac) {
      let id = try lookup(request.args)
      try resolve(id, waitId: wait, outcome: outcome, changedAt: changedAt, met: met)
      return try JSON(encoding: summary(id))
    }
    return try JSONCoding.convert(result, to: SessionSummary.self)
  }

  /// Resolves the pause condition of `id` that `waitId` names, or else the open wait that `openWait` finds.
  private func resolve(_ id: String, waitId: String?, outcome: String, changedAt: Int64?, met: Bool) throws {
    if let until = pauseCondition(id, waitId) {
      try resolve(id, until, outcome: outcome, changedAt: changedAt, met: met)
    } else {
      let (holder, wait) = try openWait(id, waitId)
      try resolve(holder, wait, outcome: outcome, changedAt: changedAt, met: met)
    }
  }

  /// Resolves the waits that sbd watches itself: dates, rechecks, other
  /// sessions' states, and Slack replies in the rows that the poll stored.
  /// `tick` calls it after it records each session's state.
  func resolveDueWaits(now: Int64) {
    for (session, wait) in waitsToResolve() {
      guard
        let settlement = wait.settlement(now: now, stateOf: lastState)
          ?? wait.settlement(thread: { slackThreads[$0] })
      else { continue }
      do {
        try resolve(
          session.id, wait, outcome: settlement.outcome, changedAt: settlement.changedAt, met: settlement.met)
      } catch {
        logLine("can't resolve wait \(wait.id) of \(session.id): \(error)")
      }
    }
  }

  /// Sends the message of a `resume` wait, then removes the wait. A failed
  /// send leaves the wait open, so the next tick or the poller tries again.
  /// A met action wait starts its action and stays, unless its action waits for an answer, a retry, or a run.
  ///
  /// An unmet outcome resolves a held or questioned action wait with a message that says sbd did not run the action.
  /// A running action refuses both, because its run resolves the wait.
  private func resolve(_ id: String, _ wait: Wait, outcome: String, changedAt: Int64? = nil, met: Bool) throws {
    if try resumeOnCondition(id, wait, outcome: outcome) { return }
    if let action = wait.action {
      if wait.actionStatus?.kind == .running {
        throw APIError("sbd is running the \(action.kind.rawValue) action of wait \(wait.id), which resolves it")
      }
      if met {
        if wait.actionStatus?.retries(now: nowMs(), subjectSince: subjectSince(of: wait)) ?? true {
          try startAction(id, wait)
        }
        return
      }
    }
    if wait.then == .resume {
      _ = try send(
        id, wait.message(outcome: outcome, met: met), by: .sbd, trigger: .wait, extra: handedFromData(id, wait))
    }
    var extra: [String: JSON] = ["outcome": .string(outcome)]
    if let changedAt { extra["changedAt"] = .number(Double(changedAt)) }
    try closeWait(id, wait, extra: extra)
  }

  /// Removes the wait from `holder` and records `wait-resolved` with `extra`.
  func closeWait(_ holder: String, _ wait: Wait, extra: [String: JSON]) throws {
    try update(holder) { $0.waits = ($0.waits ?? []).filter { $0.id != wait.id } }
    record(holder, "wait-resolved", try waitEventData(wait, extra))
  }

  /// The `stateSince` of the session that the wait's action acts on.
  func subjectSince(of wait: Wait) -> Int64? {
    wait.actionSubject.flatMap { entries[$0.id]?.facts.stateSince }
  }

  /// The session that holds the wait, and the wait: the one with this id, or
  /// the only open wait when `waitId` is nil. An id that `id` doesn't hold
  /// can name a wait that `id` handed to the operator.
  func openWait(_ id: String, _ waitId: String?) throws -> (holder: String, wait: Wait) {
    let open = entries[id]?.session.waits ?? []
    if let waitId {
      if let wait = open.first(where: { $0.id == waitId }) { return (id, wait) }
      if let handed = handedOff(from: id), let wait = handed.waits.first(where: { $0.id == waitId }) {
        return (handed.holder, wait)
      }
      try refuseCondition(id, waitId)
      throw APIError("\(id) has no wait \(waitId)")
    }
    guard open.count == 1 else {
      throw APIError(open.isEmpty ? "\(id) has no open wait" : "\(id) has \(open.count) waits, so name one")
    }
    return (id, open[0])
  }

  /// v0.1 stored a free-text wait in `waitNote`. This turns it into a manual
  /// wait. A wait set before sbd stamped recheck times gets one that counts
  /// from now, so the first tick after an upgrade doesn't move every old wait
  /// to Needs you at once. A Manager from before Manager conversations loads
  /// only the switchboard MCP server from its next launch. `mcpScoped`
  /// records that switch, so a later change to the full setup stays.
  func upgraded(_ session: Session) throws -> Session {
    var s = session
    if let note = s.waitNote {
      s.waitNote = nil
      s.waits = (s.waits ?? []) + [Wait(id: shortId("w"), kind: .manual, note: note, created: s.created, then: .notify)]
    }
    let now = nowMs()
    s.waits = s.waits?.map { config.recheck.stamped($0, from: now) }
    if s.manager == true, s.mcpScoped != true {
      s.mcp = []
      s.mcpScoped = true
    }
    guard s != session else { return session }
    try store.save(s)
    return s
  }

  /// Reads the clock, and moves it forward in a test instance.
  func clockRequest(_ args: JSON) throws -> JSON {
    if let advance = args["advance"] {
      guard config.testClock else { throw APIError("the clock moves only when config.json sets testClock") }
      guard let ms = advance.int, ms > 0 else { throw APIError("advance is a positive whole number of ms") }
      try Clock.advance(by: Int64(ms))
    }
    return ["now": .number(Double(nowMs()))]
  }

  /// A note with an id that `notes` doesn't use. It throws for empty text and
  /// for an unknown kind. A plain note keeps `kind` nil.
  func makeNote(_ text: String?, by: String?, kind: String? = nil, after notes: [Note]) throws -> Note {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      throw APIError("note needs text")
    }
    let kind = try Note.Kind(parsing: kind)
    return Note(
      id: shortId("n", taken: notes.map(\.id)), text: text, by: try Author(parsing: by), t: nowMs(),
      kind: kind == .todo ? .todo : nil)
  }

  func noteRequest(_ op: String, _ args: JSON, origin: RequestOrigin = .mac) throws -> JSON {
    let id = try lookup(args)
    let notes = entries[id]?.session.notes ?? []
    switch op {
    case "note":
      let note = try makeNote(args["text"]?.string, by: args["by"]?.string, kind: args["kind"]?.string, after: notes)
      try update(id) { $0.notes = notes + [note] }
      record(id, "note", ["note": try JSON(encoding: note)])
    case "remove-note":
      let noteId = args["note"]?.string ?? ""
      guard let note = notes.first(where: { $0.id == noteId }) else { throw APIError("\(id) has no note \(noteId)") }
      guard !note.isOpenTodo else {
        throw APIError("\(noteId) is an open to-do. \(OpenTodoError.resolveHint(id, noteId)).")
      }
      try update(id) { $0.notes = notes.filter { $0.id != noteId } }
      record(id, "note-removed", ["note": .string(noteId)])
    case "resolve-note":
      try resolveNote(id, args)
    default:
      throw APIError("unknown request \(op)")
    }
    return try JSON(encoding: summary(id, for: origin))
  }
}
