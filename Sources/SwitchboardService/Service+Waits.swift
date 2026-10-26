import Foundation
import SwitchboardCore

/// Waits, notes, and the test clock. `plans/waits-notes.md` in the notes repo
/// describes them.
extension Service {
  /// How long a session with an open wait sits idle before sbd stops it.
  static let waitingStopMs: Int64 = 2_000

  /// The `wait`, `clear-wait`, and `resolve-wait` requests. `resolve-wait`
  /// acts on processes, so `handle` settles the session and takes a new
  /// snapshot first, as for `send`.
  func waitRequest(_ op: String, _ args: JSON) throws -> JSON {
    let id = try lookup(args)
    let open = entries[id]?.session.waits ?? []
    switch op {
    case "wait":
      let request = try JSONCoding.convert(args, to: WaitRequest.self)
      let wait = try request.makeWait(id: shortId("w", taken: open.map(\.id)), waiter: id, now: nowMs()) { ref in
        let other = try lookup(["session": .string(ref)])
        return Wait.SessionTarget(id: other, name: entries[other]!.session.name)
      }
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
    return try JSON(encoding: summary(id))
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
      guard let outcome = wait.resolution(now: now, stateOf: { entries[$0]?.facts.lastState }) else { continue }
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
    if wait.then == .resume { _ = try send(id, wait.message(outcome: outcome)) }
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

  /// How long the session sits idle before sbd stops it. A session with an
  /// open wait has nothing to do until the wait resolves, so it stops soon
  /// after its turn.
  func idleStopMs(_ id: String) -> Int64 {
    let idle = Int64(config.idleStopSeconds) * 1000
    return (entries[id]?.session.waits ?? []).isEmpty ? idle : min(idle, Service.waitingStopMs)
  }

  /// v0.1 stored a free-text wait in `waitNote`. This turns it into a manual
  /// wait.
  func upgraded(_ session: Session) throws -> Session {
    guard let note = session.waitNote else { return session }
    var s = session
    s.waitNote = nil
    s.waits = (s.waits ?? []) + [Wait(id: shortId("w"), kind: .manual, note: note, created: s.created, then: .notify)]
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

  func noteRequest(_ op: String, _ args: JSON) throws -> JSON {
    let id = try lookup(args)
    let notes = entries[id]?.session.notes ?? []
    switch op {
    case "note":
      guard let text = args["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        throw APIError("note needs text")
      }
      let note = Note(
        id: shortId("n", taken: notes.map(\.id)), text: text, by: try Author(parsing: args["by"]?.string), t: nowMs())
      try update(id) { $0.notes = notes + [note] }
      record(id, "note", ["note": try JSON(encoding: note)])
    case "remove-note":
      let noteId = args["note"]?.string ?? ""
      guard notes.contains(where: { $0.id == noteId }) else { throw APIError("\(id) has no note \(noteId)") }
      try update(id) { $0.notes = notes.filter { $0.id != noteId } }
      record(id, "note-removed", ["note": .string(noteId)])
    default:
      throw APIError("unknown request \(op)")
    }
    return try JSON(encoding: summary(id))
  }
}
