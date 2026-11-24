import Foundation
import SwitchboardCore

/// The session's open to-dos that a delete did not resolve. Its description
/// is the refusal that names each one.
struct OpenTodoError: Error, CustomStringConvertible {
  let session: String
  let name: String
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
    let subject = kept.map { "\($0), because it" } ?? sessionMention(name: name, id: session)
    return "\(subject) has an open to-do: \(list). \(hint)\(stayed)"
  }
}

extension Service {
  /// The note ids of the `resolve` argument of `rm` and `followup-rm`: the
  /// open to-dos that the user resolves with the delete. It throws for a
  /// non-empty list that a request by Claude sends.
  func resolveArgument(_ args: JSON) throws -> Set<String> {
    guard let value = args["resolve"], value != .null else { return [] }
    guard let ids = value.strings else { throw APIError("resolve is a list of note ids") }
    if !ids.isEmpty { try refuseClaudeResolving(args) }
    return Set(ids)
  }

  func refuseClaudeResolving(_ args: JSON) throws { try requireUser(args, "Only you can resolve a to-do.") }

  /// Throws unless `resolving` names exactly the session's open to-dos.
  /// Returns the `resolved_todos` rows that a delete that resolves them
  /// writes. It changes nothing. It runs on the state queue.
  @discardableResult
  func checkTodos(_ id: String, resolving: Set<String>) throws -> [ResolvedTodo] {
    guard let entry = entries[id] else { throw APIError("no session \(id)") }
    let open = entry.session.openTodos
    if let stray = resolving.sorted().first(where: { ref in !open.contains { $0.id == ref } }) {
      throw APIError("\(stray) is not an open to-do of \(mention(id)).")
    }
    let unresolved = entry.session.unresolvedTodos(resolving: resolving)
    guard unresolved.isEmpty else {
      let command = entry.session.waitsToStart ? "sb followup rm" : "sb rm"
      throw OpenTodoError(
        session: id, name: entry.session.name, unresolved: unresolved, open: open, command: command)
    }
    let resolution = Note.Resolution(t: nowMs(), by: .you, how: "resolved and deleted the session")
    return open.map {
      ResolvedTodo(
        session: entry.session, branch: entry.branch, note: $0, pr: entry.facts.pr?.number, resolution: resolution)
    }
  }

  /// What deleting the session writes. Both `forgetSession` and the `rm`
  /// path's `checkDeletable` get it here, so the check runs the statements
  /// that the delete runs. A session with artifacts whose artifact group
  /// exists adds them to that group's kept rows. It throws as `checkTodos`
  /// does. It runs on the state queue.
  func removal(_ id: String, resolving: Set<String>) throws -> SessionRemoval {
    let todos = try checkTodos(id, resolving: resolving)
    guard let entry = entries[id] else { throw APIError("no session \(id)") }
    let session = entry.session
    let group =
      entry.facts.artifacts.isEmpty
      ? nil : artifactGroup(of: session).flatMap { groups[$0] }.map { keepingArtifacts(of: [entry], in: $0) }
    return SessionRemoval(id: id, name: session.name, todos: todos, host: session.host, group: group)
  }

  /// Deletes a session record. It refuses unless `resolving` names exactly
  /// the session's open to-dos, with the `OpenTodoError` that the user sees.
  /// `Store.delete(session:)` refuses an unresolved open to-do too, for any
  /// caller. It records each resolved to-do in `resolved_todos` in the same
  /// transaction as the delete. A failed delete leaves them open. It refuses
  /// the operator while it has an open wait or report. It refuses a session
  /// whose worktree sits in the trash unchecked, as `trashRefusal` says. The same
  /// transaction records the session's name in `removed_sessions`, and
  /// `removedNames` gets it only after the delete commits. For a session on
  /// a host, the same transaction records it in `removed_host_sessions`, so
  /// the spool cut may remove its leftover lines. The same transaction saves
  /// the session's artifact group with the session's artifacts kept on it,
  /// and `groups` gets that record only after the delete commits. It runs on
  /// the state queue.
  func forgetSession(_ id: String, resolving: Set<String>) throws {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    try refuseOperatorRemoval(id)
    try refuseConversationRemoval(id)
    if let refusal = trashRefusal(id) { throw refusal }
    // Only a merged PR leaves marks. Other removals skip the summary.
    let removed = entries[id]?.facts.pr?.state == .merged ? summary(id) : nil
    let record = try removal(id, resolving: resolving)
    try store.delete(session: record)
    if let group = record.group { groups[group.id] = group }
    removedNames[id] = session.name
    if let removed { markAddressedIssues(removed) }
    entries[id] = nil
    forgetChild(id)
    slashListings[id] = nil
    hostEvents[id] = nil
    pruneDeclinedSuggestions()
    syncOperatorItems()
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
