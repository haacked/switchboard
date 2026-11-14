import Foundation
import SwitchboardCore

/// Waits, notes, and the test clock. `plans/waits-notes.md` in the notes repo
/// describes them.
extension Service {
  /// The `wait`, `clear-wait`, and `resolve-wait` requests. `resolve-wait`
  /// acts on processes, so `handle` settles the session and takes a new
  /// snapshot first, as for `send`.
  func waitRequest(_ op: String, _ args: JSON, origin: RequestOrigin = .mac) throws -> JSON {
    let id = try lookup(args)
    let open = entries[id]?.session.waits ?? []
    switch op {
    case "wait":
      try refuseNotStarted(entries[id]!.session)
      let request = try JSONCoding.convert(args, to: WaitRequest.self)
      var wait = try request.makeWait(id: shortId("w", taken: open.map(\.id)), waiter: id, now: nowMs()) { ref in
        let other = try lookup(["session": .string(ref)])
        return Wait.SessionTarget(id: other, name: entries[other]!.session.name)
      }
      if case .remote(let host) = origin { try requireGitHubWait(wait, on: id, from: host) }
      if wait.kind == .ci && wait.pr == nil {
        wait.headSha = try? checkedOutBranch(entries[id]!.session, at: site(of: id)).tip
      }
      wait = config.recheck.stamped(wait)
      try update(id) { $0.waits = open + [wait] }
      record(id, "wait", ["wait": try JSON(encoding: wait)])
    case "clear-wait":
      let cleared = try args["wait"]?.string.map { [try openWait(id, $0).id] } ?? open.map(\.id)
      if !cleared.isEmpty {
        try update(id) { $0.waits = open.filter { !cleared.contains($0.id) } }
        record(id, "wait-cleared", ["waits": .array(cleared.map(JSON.string))])
      }
    case "resolve-wait":
      guard let outcome = args["outcome"]?.string, !outcome.isEmpty else {
        throw APIError("resolve-wait needs an outcome that says what happened")
      }
      try resolve(id, try openWait(id, args["wait"]?.string), outcome: outcome)
    default:
      throw APIError("unknown request \(op)")
    }
    return try JSON(encoding: summary(id, for: origin))
  }

  /// The open waits of these kinds, with their sessions. A poller calls it on
  /// each pass.
  func openWaits(_ kinds: Set<Wait.Kind>) -> [(session: Session, wait: Wait)] {
    queue.sync { waitsToResolve().filter { kinds.contains($0.wait.kind) } }
  }

  /// The open waits that may resolve. A session marked done keeps its waits,
  /// and they don't resume it.
  private func waitsToResolve() -> [(session: Session, wait: Wait)] {
    entries.keys.sorted().compactMap { entries[$0]?.session }.filter { !$0.done }.flatMap { s in
      (s.waits ?? []).map { (session: s, wait: $0) }
    }
  }

  /// Resolves an open wait and runs its `then`, through the `resolve-wait`
  /// request. `outcome` says what happened in words, such as "the checks
  /// passed". A poller calls it from its own queue.
  func resolveWait(session: String, wait: String, outcome: String) throws -> SessionSummary {
    let args: JSON = ["session": .string(session), "wait": .string(wait), "outcome": .string(outcome)]
    let response = handle(Request(op: "resolve-wait", args: args))
    guard response.ok, let result = response.result else { throw APIError(response.error ?? "resolve-wait failed") }
    return try JSONCoding.convert(result, to: SessionSummary.self)
  }

  /// Resolves the waits that sbd watches itself: dates, rechecks, and other
  /// sessions' states. `tick` calls it after it records each session's state.
  func resolveDueWaits(now: Int64) {
    for (session, wait) in waitsToResolve() {
      guard let outcome = wait.resolution(now: now, stateOf: lastState) else { continue }
      do {
        try resolve(session.id, wait, outcome: outcome)
      } catch {
        logLine("can't resolve wait \(wait.id) of \(session.id): \(error)")
      }
    }
  }

  /// Sends the message of a `resume` wait, then removes the wait. A failed
  /// send leaves the wait open, so the next tick or the poller tries again.
  private func resolve(_ id: String, _ wait: Wait, outcome: String) throws {
    if wait.then == .resume { _ = try send(id, wait.message(outcome: outcome), byUser: false, trigger: .wait) }
    try update(id) { $0.waits = ($0.waits ?? []).filter { $0.id != wait.id } }
    record(id, "wait-resolved", ["wait": try JSON(encoding: wait), "outcome": .string(outcome)])
  }

  /// The wait with this id, or the only open wait when `waitId` is nil.
  private func openWait(_ id: String, _ waitId: String?) throws -> Wait {
    let open = entries[id]?.session.waits ?? []
    if let waitId {
      guard let wait = open.first(where: { $0.id == waitId }) else { throw APIError("\(id) has no wait \(waitId)") }
      return wait
    }
    guard open.count == 1 else {
      throw APIError(open.isEmpty ? "\(id) has no open wait" : "\(id) has \(open.count) waits, so name one")
    }
    return open[0]
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
