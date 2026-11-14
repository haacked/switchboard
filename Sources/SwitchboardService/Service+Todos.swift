import Foundation
import SwitchboardCore

/// The session's open to-dos that a delete did not resolve. Its description
/// is the refusal that names each one.
struct OpenTodoError: Error, CustomStringConvertible {
  let session: String
  /// The open to-dos that the delete left unresolved.
  let unresolved: [Note]
  /// Every open to-do of the session, which the suggested command resolves.
  let open: [Note]
  /// `sb rm`, or `sb followup rm` for a follow-up that hasn't started.
  let command: String
  /// The flags of the refused `rm`, such as `--worktree`. The suggested
  /// command repeats them.
  var flags: [String] = []
  /// What `rm` already did when the check failed late, such as "Kept s1". It
  /// replaces the session as the subject of the refusal.
  var kept: String?
  /// The sentence that names a branch the late `rm` failed to delete, such
  /// as " It kept main: …". It ends the refusal.
  var stayed = ""

  var list: String { unresolved.map { "\($0.id) \"\(oneLine($0.text, max: .max))\"" }.joined(separator: "; ") }

  static func resolveHint(_ session: String, _ note: String) -> String {
    "Resolve it with sb note \(session) --resolve \(note)"
  }

  var hint: String {
    let resolve =
      unresolved.count == 1
      ? Self.resolveHint(session, unresolved[0].id)
      : "Resolve each with sb note \(session) --resolve <id>"
    let remove = ([command, session] + flags + open.flatMap { ["--resolve", $0.id] }).joined(separator: " ")
    return "\(resolve), or remove the session with \(remove). sb cleanup removes only the worktree."
  }

  var description: String {
    let subject = kept.map { "\($0), because it" } ?? session
    return "\(subject) has an open to-do: \(list). \(hint)\(stayed)"
  }
}

extension Service {
  /// The note ids of the `resolve` argument of `rm` and `followup-rm`: the
  /// open to-dos that the user resolves with the delete. It throws for a
  /// non-empty list that a request by Claude sends.
  func resolveArgument(_ args: JSON) throws -> Set<String> {
    guard let value = args["resolve"], value != .null else { return [] }
    guard let items = value.array else { throw APIError("resolve is a list of note ids") }
    let ids = items.compactMap(\.string)
    guard ids.count == items.count else { throw APIError("resolve is a list of note ids") }
    if !ids.isEmpty { try refuseClaudeResolving(args) }
    return Set(ids)
  }

  /// Throws unless the user sent the request. A missing `by` means the user.
  func refuseClaudeResolving(_ args: JSON) throws {
    guard try Author(parsing: args["by"]?.string) == .you else { throw APIError("Only you can resolve a to-do.") }
  }

  /// Throws unless `resolving` names exactly the session's open to-dos.
  /// Returns the `resolved_todos` rows that a delete that resolves them
  /// writes. It changes nothing. It runs on the state queue.
  @discardableResult
  func checkTodos(_ id: String, resolving: Set<String>) throws -> [ResolvedTodo] {
    guard let entry = entries[id] else { throw APIError("no session \(id)") }
    let open = entry.session.openTodos
    if let stray = resolving.sorted().first(where: { ref in !open.contains { $0.id == ref } }) {
      throw APIError("\(stray) is not an open to-do of \(id).")
    }
    let unresolved = open.filter { !resolving.contains($0.id) }
    guard unresolved.isEmpty else {
      let command = entry.session.waitsToStart ? "sb followup rm" : "sb rm"
      throw OpenTodoError(session: id, unresolved: unresolved, open: open, command: command)
    }
    let resolution = Note.Resolution(t: nowMs(), by: .you, how: "resolved and deleted the session")
    return open.map {
      ResolvedTodo(
        session: entry.session, branch: entry.branch, note: $0, pr: entry.facts.pr?.number, resolution: resolution)
    }
  }

  /// The one function that deletes a session record. It refuses unless
  /// `resolving` names exactly the session's open to-dos. It records each of
  /// them in `resolved_todos` in the same transaction as the delete. A
  /// failed delete leaves them open. For a session on a host, the same
  /// transaction records it in `removed_host_sessions`, so the spool cut may
  /// remove its leftover lines. It runs on the state queue.
  func forgetSession(_ id: String, resolving: Set<String>) throws {
    // Only a merged PR leaves marks. Other removals skip the summary.
    let removed = entries[id]?.facts.pr?.state == .merged ? summary(id) : nil
    try store.delete(session: id, resolving: checkTodos(id, resolving: resolving), onHost: entries[id]?.session.host)
    if let removed { markAddressedIssues(removed) }
    entries[id] = nil
    slashListings[id] = nil
    hostEvents[id] = nil
    pruneDeclinedSuggestions()
  }

  /// Resolves an open to-do as the user, and records it in `resolved_todos`.
  func resolveNote(_ id: String, _ args: JSON) throws {
    try refuseClaudeResolving(args)
    guard var session = entries[id]?.session else { throw APIError("no session \(id)") }
    let noteId = args["note"]?.string ?? ""
    guard let index = session.notes?.firstIndex(where: { $0.id == noteId }), let note = session.notes?[index],
      note.isOpenTodo
    else {
      throw APIError("\(id) has no open to-do \(noteId)")
    }
    let resolution = Note.Resolution(t: nowMs(), by: .you, how: "resolved")
    session.notes?[index].resolved = resolution
    try store.save(
      session,
      resolving: ResolvedTodo(
        session: session, branch: entries[id]?.branch, note: note, pr: entries[id]?.facts.pr?.number,
        resolution: resolution))
    entries[id]?.session = session
    record(id, "note-resolved", ["note": .string(noteId)])
  }

  /// The `resolved_todos` rows, newest first. `limit` defaults to 50.
  func resolvedTodos(_ args: JSON) throws -> JSON {
    var limit = 50
    if let value = args["limit"] {
      guard let n = value.int, n > 0 else { throw APIError("limit is a positive whole number") }
      limit = n
    }
    return try JSON(encoding: store.resolvedTodos(limit: limit))
  }
}
