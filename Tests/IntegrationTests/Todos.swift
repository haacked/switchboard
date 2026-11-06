import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// Adds a to-do to the session through the `note` request and returns it.
  @discardableResult
  func addTodo(_ session: String, _ text: String, by: Author = .you) throws -> Note {
    let s = try client.call(
      "note",
      ["session": .string(session), "text": .string(text), "by": .string(by.rawValue), "kind": "todo"],
      as: SessionSummary.self)
    return try #require(s.notes.last { $0.text == text })
  }

  /// Adds a plain note to the session through the `note` request and returns it.
  @discardableResult
  func addPlainNote(_ session: String, _ text: String) throws -> Note {
    let s = try client.call("note", ["session": .string(session), "text": .string(text)], as: SessionSummary.self)
    return try #require(s.notes.last { $0.text == text })
  }

  /// Resolves the to-do as the user through the `resolve-note` request.
  @discardableResult
  func resolveTodo(_ session: String, _ note: String) throws -> SessionSummary {
    try client.call(
      "resolve-note", ["session": .string(session), "note": .string(note), "by": "you"], as: SessionSummary.self)
  }

  /// The session's note with the id, or nil when the session or the note is gone.
  func storedNote(_ session: String, _ note: String) throws -> Note? {
    try get(session).notes.first { $0.id == note }
  }

  /// Whether the session still holds the note as an open to-do.
  func isOpenTodo(_ session: String, _ note: String) throws -> Bool {
    try storedNote(session, note)?.isOpenTodo == true
  }

  /// The rows of the `resolved_todos` table, newest first, as the `resolved-todos` request returns them.
  func resolvedTodos(limit: Int? = nil) throws -> [JSON] {
    var args: [String: JSON] = [:]
    if let limit { args["limit"] = .number(Double(limit)) }
    let result = try client.call("resolved-todos", args)
    return try #require(result.array, Comment(rawValue: "resolved-todos returned \(result.text)"))
  }

  /// The ids of the notes in the `resolved_todos` rows.
  func resolvedTodoIds() throws -> [String] { try resolvedTodos().compactMap { $0["note"]?.string } }
}
