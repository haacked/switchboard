import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct NoteTests {
  func todo(_ id: String, _ text: String, resolved: Note.Resolution? = nil) -> Note {
    var note = Note(id: id, text: text, by: .you, t: 10)
    note.kind = .todo
    note.resolved = resolved
    return note
  }

  static let resolution = Note.Resolution(t: 20, by: .you, how: "resolved")

  // MARK: Rows written before to-dos

  @Test func aNoteRowWithoutKindOrResolvedDecodesAsAPlainNote() throws {
    let note = try JSONCoding.decode(Note.self, from: #"{"id": "n1", "text": "ask Alex", "by": "claude", "t": 10}"#)

    #expect(note == Note(id: "n1", text: "ask Alex", by: .claude, t: 10))
    #expect((note.kind ?? .note) == .note)
    #expect(note.resolved == nil)
    #expect(!note.isOpenTodo)
  }

  @Test func aSessionRowWhoseNotesLackKindAndResolvedHasNoOpenToDos() throws {
    let row = """
      {"claudeSessionId": "u1", "created": 5, "cwd": "/tmp/a", "done": false, "id": "s1", "name": "one",
       "started": true, "notes": [{"id": "n1", "text": "ask Alex", "by": "you", "t": 10},
       {"id": "n2", "text": "stacked on #1190", "by": "claude", "t": 11}]}
      """

    let s = try JSONCoding.decode(Session.self, from: row)

    #expect(s.notes?.map(\.text) == ["ask Alex", "stacked on #1190"])
    #expect(s.notes?.allSatisfy { ($0.kind ?? .note) == .note && $0.resolved == nil } == true)
    #expect(s.openTodos.isEmpty)
  }

  @Test func aGroupRowWhoseNotesLackKindAndResolvedDecodesAsPlainNotes() throws {
    let row = """
      {"id": "g1", "name": "Flags", "created": 5, "notes": [{"id": "n1", "text": "Ship by Friday", "by": "you", "t": 10}]}
      """

    let g = try JSONCoding.decode(SessionGroup.self, from: row)

    #expect(g.notes.map(\.isOpenTodo) == [false])
    #expect(g.notes.map { $0.kind ?? .note } == [.note])
  }

  @Test func aSessionRowWithoutNotesHasNoOpenToDos() throws {
    let row = """
      {"claudeSessionId": "u1", "created": 5, "cwd": "/tmp/a", "done": false, "id": "s1", "name": "one", "started": true}
      """

    #expect(try JSONCoding.decode(Session.self, from: row).openTodos.isEmpty)
  }

  // MARK: Kinds

  @Test func aToDoIsOpenUntilItIsResolved() {
    #expect(todo("n1", "tell Alex").isOpenTodo)
    #expect(!todo("n1", "tell Alex", resolved: Self.resolution).isOpenTodo)
  }

  @Test func aPlainNoteIsNeverAnOpenToDo() {
    var note = Note(id: "n1", text: "stacked on #1190", by: .you, t: 10)
    #expect(!note.isOpenTodo)
    note.kind = .note
    #expect(!note.isOpenTodo)
  }

  @Test func aToDoAndItsResolutionRoundTripThroughJSON() throws {
    let open = todo("n1", "tell Alex")
    let closed = todo(
      "n2", "close the incident", resolved: Note.Resolution(t: 20, by: .you, how: "resolved and deleted the session"))

    for note in [open, closed] {
      #expect(try JSONCoding.decode(Note.self, from: try JSON(encoding: note).text) == note)
    }
    let json = try JSON(encoding: closed)
    #expect(json["kind"]?.string == "todo")
    #expect(json["resolved"]?["t"]?.int == 20)
    #expect(json["resolved"]?["by"]?.string == "you")
    #expect(json["resolved"]?["how"]?.string == "resolved and deleted the session")
  }

  @Test func aSessionWithToDosRoundTripsThroughTheStore() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var s = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)
    s.notes = [
      Note(id: "n1", text: "stacked on #1190", by: .claude, t: 10), todo("n2", "tell Alex"),
      todo("n3", "close the incident", resolved: Self.resolution),
    ]
    do {
      let store = try Store(path: "\(dir)/sb.db")
      try store.save(s)
    }

    let stored = try Store(path: "\(dir)/sb.db").sessions()

    #expect(stored == [s])
    #expect(stored.first?.openTodos.map(\.id) == ["n2"])
  }

  // MARK: Open to-dos of a session

  @Test func openTodosListsOnlyTheOpenToDosInTheirOrder() {
    let notes = [
      todo("n1", "update the runbook", resolved: Self.resolution), Note(id: "n2", text: "plain", by: .you, t: 11),
      todo("n3", "tell Alex"), todo("n4", "close the incident"),
    ]
    var session = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)
    session.notes = notes
    let summary = SessionSummary(
      id: "s1", name: "one", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "u1", state: .done, reason: "",
      since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: notes)

    #expect(session.openTodos.map(\.id) == ["n3", "n4"])
    #expect(summary.openTodos.map(\.id) == ["n3", "n4"])
  }

  // MARK: Prompts

  static let todoRule = "A to-do note is a task for the user. Never do it, and never tell a session to do it."

  @Test func theManagerPromptSaysNeverToDoAToDo() {
    #expect(Manager.guide.contains(Self.todoRule))
  }

  @Test func theChatPromptSaysNeverToDoAToDo() {
    #expect(Chat.guide.contains(Self.todoRule))
  }
}
