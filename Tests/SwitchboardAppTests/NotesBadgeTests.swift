import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A plain note, or a to-do when `kind` is `.todo`. A nil `kind` is a row that an older sbd stored.
func noteFixture(_ id: String, _ text: String, kind: Note.Kind? = .note, resolved: Bool = false, t: Int64 = 0) -> Note {
  var n = Note(id: id, text: text, by: .you, t: t, kind: kind)
  if resolved { n.resolved = Note.Resolution(t: t + 1, by: .you, how: "resolved") }
  return n
}

func todoFixture(_ id: String, _ text: String, resolved: Bool = false) -> Note {
  noteFixture(id, text, kind: .todo, resolved: resolved)
}

func notedSession(_ notes: [Note], state: AttentionState = .done, id: String = "s1") -> SessionSummary {
  SessionSummary(
    id: id, name: "fix", cwd: "/worktrees/posthog/haacked/fix", repo: "/repos/posthog", branch: "haacked/fix",
    claudeSessionId: "c", state: state, reason: "", since: 0, lastActivity: 0, live: false, claudePid: nil,
    attached: false, lastReply: nil, waits: [], notes: notes)
}

@Suite struct NotesBadgeVisibility {
  @Test func hidesTheIconWhenTheSessionHasNoNotes() {
    #expect(NotesBadge(notedSession([])) == nil)
  }

  @Test(arguments: [
    [noteFixture("n1", "plain")],
    [noteFixture("n1", "stored by an older sbd", kind: nil)],
    [todoFixture("n1", "done already", resolved: true)],
    [noteFixture("n1", "plain"), todoFixture("n2", "done already", resolved: true)],
  ])
  func dimsTheIconWithoutAnOpenTodoEvenOnADoneSession(_ notes: [Note]) throws {
    let badge = try #require(NotesBadge(notedSession(notes, state: .done)))

    #expect(badge.tone == .dimmed)
  }

  @Test(arguments: AttentionState.allCases)
  func dimsTheIconWithOnlyPlainNotesInEveryState(_ state: AttentionState) throws {
    let badge = try #require(NotesBadge(notedSession([noteFixture("n1", "plain")], state: state)))

    #expect(badge.tone == .dimmed)
  }

  @Test(arguments: AttentionState.allCases)
  func usesTheNeedsYouColorOnlyWhenADoneSessionHasAnOpenTodo(_ state: AttentionState) throws {
    let badge = try #require(NotesBadge(notedSession([todoFixture("n1", "tell Alex in #flags")], state: state)))

    #expect(badge.tone == (state == .done ? .needsYou : .secondary))
  }

  @Test func keepsAStaleSessionsOpenTodoSecondary() throws {
    let badge = try #require(NotesBadge(notedSession([todoFixture("n1", "tell Alex in #flags")], state: .stale)))

    #expect(badge.tone == .secondary)
  }
}

@Suite struct NotesBadgeCount {
  @Test(arguments: [AttentionState.done, .working])
  func showsNoCountForOneOpenTodo(_ state: AttentionState) throws {
    let badge = try #require(NotesBadge(notedSession([todoFixture("n1", "tell Alex in #flags")], state: state)))

    #expect(badge.count == nil)
  }

  @Test(arguments: [AttentionState.done, .working])
  func countsTwoOpenTodos(_ state: AttentionState) throws {
    let badge = try #require(
      NotesBadge(
        notedSession([todoFixture("n1", "tell Alex in #flags"), todoFixture("n2", "bump the SDK")], state: state)))

    #expect(badge.count == 2)
  }

  @Test func countsOnlyOpenTodosNotPlainNotesOrResolvedTodos() throws {
    let notes = [
      noteFixture("n1", "plain"), noteFixture("n2", "another"), todoFixture("n3", "done already", resolved: true),
      todoFixture("n4", "tell Alex in #flags"),
    ]

    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.count == nil)
  }

  @Test func showsNoCountWithoutAnOpenTodo() throws {
    let badge = try #require(NotesBadge(notedSession([noteFixture("n1", "plain"), noteFixture("n2", "another")])))

    #expect(badge.count == nil)
  }
}

@Suite struct NotesBadgeHover {
  @Test func showsTheOnlyOpenTodosText() throws {
    let badge = try #require(NotesBadge(notedSession([todoFixture("n1", "tell Alex in #flags")])))

    #expect(badge.help == "tell Alex in #flags")
  }

  @Test func ignoresPlainNotesAndResolvedTodosBesideOneOpenTodo() throws {
    let notes = [
      noteFixture("n1", "plain"), todoFixture("n2", "done already", resolved: true),
      todoFixture("n3", "tell Alex in #flags"),
    ]

    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.help == "tell Alex in #flags")
  }

  @Test(arguments: [(2, "and 1 more"), (3, "and 2 more")])
  func showsTheFirstOpenTodoAndHowManyMore(_ open: Int, _ more: String) throws {
    let todos = (1...open).map { todoFixture("n\($0)", "task \($0)") }

    let badge = try #require(NotesBadge(notedSession(todos)))

    #expect(badge.help.hasPrefix("task 1"))
    #expect(badge.help.contains(more))
    #expect(!badge.help.contains("task 2"))
  }

  @Test func countsTheNotesWithoutAnOpenTodo() throws {
    let notes = [noteFixture("n1", "plain"), todoFixture("n2", "done already", resolved: true)]

    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.help == "2 notes")
  }

  @Test func saysOneNoteForASingleNote() throws {
    let badge = try #require(NotesBadge(notedSession([noteFixture("n1", "plain")])))

    #expect(badge.help == "1 note")
  }
}

@Suite struct NotesBadgeAccessibility {
  @Test func namesEveryOpenTodo() throws {
    let notes = [
      todoFixture("n1", "tell Alex in #flags"), noteFixture("n2", "plain"), todoFixture("n3", "bump the SDK"),
    ]

    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.accessibilityLabel == "2 open to-dos: tell Alex in #flags; bump the SDK")
  }

  @Test func namesASingleOpenTodo() throws {
    let badge = try #require(NotesBadge(notedSession([todoFixture("n1", "tell Alex in #flags")])))

    #expect(badge.accessibilityLabel == "1 open to-do: tell Alex in #flags")
  }

  @Test func leavesOutResolvedTodos() throws {
    let notes = [todoFixture("n1", "done already", resolved: true), todoFixture("n2", "tell Alex in #flags")]

    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(!badge.accessibilityLabel.contains("done already"))
  }

  @Test func countsTheNotesWithoutAnOpenTodo() throws {
    let badge = try #require(NotesBadge(notedSession([noteFixture("n1", "plain"), noteFixture("n2", "another")])))

    #expect(badge.accessibilityLabel.contains("2 notes"))
    #expect(!badge.accessibilityLabel.contains("to-do"))
  }
}

@Suite struct NotesBadgePopover {
  /// Added in this order, so that each kind is interleaved with the others.
  let notes = [
    noteFixture("p1", "plain one"),
    todoFixture("r1", "resolved one", resolved: true),
    todoFixture("o1", "open one"),
    noteFixture("p2", "stored by an older sbd", kind: nil),
    todoFixture("r2", "resolved two", resolved: true),
    todoFixture("o2", "open two"),
  ]

  @Test func listsOpenTodosFirstInTheOrderTheyWereAdded() throws {
    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.open.map(\.id) == ["o1", "o2"])
  }

  @Test func listsPlainNotesSecondIncludingRowsWithoutAKind() throws {
    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.plain.map(\.id) == ["p1", "p2"])
  }

  @Test func listsResolvedTodosLast() throws {
    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.resolved.map(\.id) == ["r1", "r2"])
  }

  @Test func listsEveryNoteExactlyOnce() throws {
    let badge = try #require(NotesBadge(notedSession(notes)))

    let listed: [Note] = badge.open + badge.plain + badge.resolved
    #expect(listed.map(\.id) == ["o1", "o2", "p1", "p2", "r1", "r2"])
  }

  @Test func titlesTheCollapsedRowWithTheResolvedCount() throws {
    let badge = try #require(NotesBadge(notedSession(notes)))

    #expect(badge.resolvedTitle == "2 resolved")
  }
}

/// What the trash confirmation and the session view's Remove dialog say about open to-dos.
@Suite struct TodoDeletionText {
  @Test func keepsTheButtonTitleWithoutAnOpenTodo() {
    let notes = [noteFixture("n1", "plain"), todoFixture("n2", "done already", resolved: true)]

    let deletion = TodoDeletion(notedSession(notes))

    #expect(deletion.button("Delete") == "Delete")
    #expect(deletion.button("Remove Session") == "Remove Session")
  }

  @Test func namesOneTodoInTheButton() {
    let deletion = TodoDeletion(notedSession([todoFixture("n1", "tell Alex in #flags")]))

    #expect(deletion.button("Delete") == "Resolve 1 To-do and Delete")
    #expect(deletion.button("Remove Session") == "Resolve 1 To-do and Delete")
  }

  @Test func namesTwoTodosInTheButton() {
    let deletion = TodoDeletion(
      notedSession([todoFixture("n1", "tell Alex in #flags"), todoFixture("n2", "bump the SDK")]))

    #expect(deletion.button("Delete") == "Resolve 2 To-dos and Delete")
  }

  @Test func listsEachOpenTodoInTheMessage() throws {
    let deletion = TodoDeletion(
      notedSession([todoFixture("n1", "tell Alex in #flags"), todoFixture("n2", "bump the SDK")]))

    let message = try #require(deletion.message)

    #expect(message.contains("tell Alex in #flags"))
    #expect(message.contains("bump the SDK"))
  }

  @Test func leavesPlainNotesAndResolvedTodosOutOfTheMessage() throws {
    let notes = [
      noteFixture("n1", "plain"), todoFixture("n2", "done already", resolved: true),
      todoFixture("n3", "tell Alex in #flags"),
    ]

    let message = try #require(TodoDeletion(notedSession(notes)).message)

    #expect(!message.contains("plain"))
    #expect(!message.contains("done already"))
  }

  @Test func hasNoMessageWithoutAnOpenTodo() {
    let notes = [noteFixture("n1", "plain"), todoFixture("n2", "done already", resolved: true)]

    #expect(TodoDeletion(notedSession(notes)).message == nil)
  }

  @Test func resolvesExactlyTheTodosTheMessageLists() throws {
    let notes = [
      todoFixture("n1", "tell Alex in #flags"), noteFixture("n2", "plain"),
      todoFixture("n3", "done already", resolved: true),
      todoFixture("n4", "bump the SDK"),
    ]

    let deletion = TodoDeletion(notedSession(notes))

    let message = try #require(deletion.message)
    let listed = notes.filter { message.contains($0.text) }.map(\.id)
    #expect(deletion.ids == listed)
    #expect(deletion.ids == ["n1", "n4"])
  }
}
