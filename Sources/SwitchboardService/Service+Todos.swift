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

  /// Each unresolved to-do's id and its text in quotes.
  var list: String { unresolved.map { "\($0.id) \"\(oneLine($0.text, max: .max))\"" }.joined(separator: "; ") }

  var hint: String {
    let resolve =
      unresolved.count == 1
      ? "Resolve it with sb note \(session) --resolve \(unresolved[0].id)"
      : "Resolve each with sb note \(session) --resolve <id>"
    let remove = ([command, session] + open.flatMap { ["--resolve", $0.id] }).joined(separator: " ")
    return "\(resolve), or remove the session with \(remove). sb cleanup removes only the worktree."
  }

  var description: String { "\(session) has an open to-do: \(list). \(hint)" }
}

extension Service {
  /// The note ids of the `resolve` argument of `rm` and `followup-rm`: the
  /// open to-dos that the user resolves with the delete.
  func resolveArgument(_ args: JSON) throws -> Set<String> {
    guard let value = args["resolve"], value != .null else { return [] }
    guard let items = value.array else { throw APIError("resolve is a list of note ids") }
    let ids = items.compactMap(\.string)
    guard ids.count == items.count else { throw APIError("resolve is a list of note ids") }
    return Set(ids)
  }

  /// Throws unless `resolving` names exactly the session's open to-dos. It
  /// changes nothing. It runs on the state queue.
  func checkTodos(_ id: String, resolving: Set<String>) throws {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    let open = session.openTodos
    if let stray = resolving.sorted().first(where: { ref in !open.contains { $0.id == ref } }) {
      throw APIError("\(stray) is not an open to-do of \(id).")
    }
    let unresolved = open.filter { !resolving.contains($0.id) }
    guard unresolved.isEmpty else {
      let command = session.waitsToStart ? "sb followup rm" : "sb rm"
      throw OpenTodoError(session: id, unresolved: unresolved, open: open, command: command)
    }
  }

  /// The `resolved_todos` rows that a delete that resolves these to-dos writes.
  func deletionRecords(_ id: String, resolving: Set<String>) -> [ResolvedTodo] {
    guard let entry = entries[id] else { return [] }
    let resolution = Note.Resolution(t: nowMs(), by: .you, how: "resolved and deleted the session")
    return entry.session.openTodos.filter { resolving.contains($0.id) }.map {
      ResolvedTodo(session: entry.session, note: $0, pr: entry.facts.pr?.number, resolution: resolution)
    }
  }

  /// The one function that deletes a session record. It refuses unless
  /// `resolving` names exactly the session's open to-dos. It records each of
  /// them in `resolved_todos` in the same transaction as the delete, so a
  /// failed delete leaves them open. It runs on the state queue.
  func forgetSession(_ id: String, resolving: Set<String>) throws {
    try checkTodos(id, resolving: resolving)
    try store.delete(session: id, resolving: deletionRecords(id, resolving: resolving))
    entries[id] = nil
  }

  /// Resolves an open to-do as the user, and records it in `resolved_todos`.
  func resolveNote(_ id: String, _ args: JSON) throws {
    guard try Author(parsing: args["by"]?.string) == .you else { throw APIError("Only you can resolve a to-do.") }
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
      resolving: ResolvedTodo(session: session, note: note, pr: entries[id]?.facts.pr?.number, resolution: resolution))
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

  /// Throws for a `kind` of `todo`, which a group's note can't have, and for an unknown kind.
  func refuseGroupTodo(_ args: JSON) throws {
    if try Note.Kind(parsing: args["kind"]?.string) == .todo {
      throw APIError("To-dos belong on sessions, not groups.")
    }
  }
}
