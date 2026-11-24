import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelNotes {
  @Test func addsATodoByYou() async {
    let sent = await firstRequest { $0.addNote("s1", text: "tell Alex in #flags", todo: true) }

    #expect(sent.op == "note")
    #expect(sent.args == ["session": "s1", "text": "tell Alex in #flags", "kind": "todo", "by": "you"])
  }

  @Test func addsAPlainNoteByYou() async {
    let sent = await firstRequest { $0.addNote("s1", text: "the flag is on in EU", todo: false) }

    #expect(sent.op == "note")
    #expect(sent.args == ["session": "s1", "text": "the flag is on in EU", "kind": "note", "by": "you"])
  }

  @Test func resolvesATodoAsYou() async {
    let sent = await firstRequest { $0.resolveNote("s1", note: "nk2p4") }

    #expect(sent.op == "resolve-note")
    #expect(sent.args == ["session": "s1", "note": "nk2p4", "by": "you"])
  }
}

/// The delete requests carry the open to-dos that the dialog showed.
/// A to-do added after the dialog opened therefore still makes sbd refuse.
@MainActor
@Suite struct DeletingSessionsWithTodos {
  func session(_ notes: [Note], state: AttentionState = .done) -> SessionSummary {
    var s = notedSession(notes, state: state)
    s.pr = try! JSONDecoder().decode(
      PRSummary.self,
      from: Data(
        """
        {"number":7,"url":"https://github.com/o/r/pull/7","repo":"o/r","title":"Fix","state":"MERGED","status":"Merged"}
        """.utf8))
    return s
  }

  let mixed = [
    noteFixture("n1", "plain"), todoFixture("n2", "done already", resolved: true),
    todoFixture("n3", "tell Alex in #flags"), todoFixture("n4", "bump the SDK"),
  ]

  // MARK: The trash confirmation

  @Test func trashRequestResolvesTheShownTodos() {
    let s = session(mixed)

    let request = BoardModel.queueRequest([s.id], scope: .done, resolve: TodoDeletion(s).ids)

    #expect(request["resolve"] == ["n3", "n4"])
  }

  @Test func trashRequestKeepsTheQueueFieldsBesideResolve() {
    let request = BoardModel.queueRequest([session(mixed).id], scope: .done, resolve: ["n3", "n4"])

    #expect(
      request == [
        "scope": "done", "targets": ["s1"], "worktree": true, "remote_branch": true, "resolve": ["n3", "n4"],
      ])
  }

  @Test func trashRequestResolvesOnlyTheIdsTheDialogShowed() {
    let current = session([
      todoFixture("n3", "tell Alex in #flags"), todoFixture("n5", "added after the dialog opened"),
    ])

    let request = BoardModel.queueRequest([current.id], scope: .done, resolve: ["n3"])

    #expect(request["resolve"] == ["n3"])
  }

  @Test(arguments: [
    [Note](),
    [noteFixture("n1", "plain")],
    [noteFixture("n1", "stored by an older sbd", kind: nil)],
    [todoFixture("n2", "done already", resolved: true)],
  ])
  func trashRequestHasNoResolveWithoutAnOpenTodo(_ notes: [Note]) {
    let s = session(notes)

    let request = BoardModel.queueRequest([s.id], scope: .done, resolve: TodoDeletion(s).ids)

    #expect(request["resolve"] == nil)
  }

  @Test func deleteSessionSendsTheShownTodos() async {
    let s = session(mixed)

    let sent = await firstRequest { $0.deleteSession(s, resolve: ["n3", "n4"]) }

    #expect(sent.op == "rm-queue")
    #expect(sent.args["resolve"] == ["n3", "n4"])
  }

  @Test func deleteSessionSendsOnlyTheShownTodosWhenTheBoardHasANewerOne() async {
    let shown = session([todoFixture("n3", "tell Alex in #flags")])
    let newer = session([todoFixture("n3", "tell Alex in #flags"), todoFixture("n5", "added after the dialog opened")])

    let sent = await firstRequest { model in
      model.apply(.success([newer]), followups: nil)
      model.deleteSession(shown, resolve: TodoDeletion(shown).ids)
    }

    #expect(sent.args["resolve"] == ["n3"])
  }

  @Test func trashDialogKeepsTheTodosItShowedWhenTheBoardGetsANewerOne() {
    let shown = session([todoFixture("n3", "tell Alex in #flags")])
    let model = appliedModel([shown])
    model.confirmingDelete = shown

    model.apply(
      .success([
        session([todoFixture("n3", "tell Alex in #flags"), todoFixture("n5", "added after the dialog opened")])
      ]),
      followups: nil)

    #expect(model.confirmingDelete.map { TodoDeletion($0).ids } == ["n3"])
  }

  @Test func deleteSessionWithTodosIgnoresASecondDeleteWhileTheFirstRuns() async {
    let s = session(mixed)

    let sent = await firstRequest { model in
      model.deleteSession(s, resolve: ["n3", "n4"])
      model.deleteSession(s, resolve: ["n3", "n4"])
      #expect(model.deleting == [s.id])
    }

    #expect(sent.count == 1)
  }

  @Test func deleteSessionSendsNoResolveWithoutAnOpenTodo() async {
    let s = session([noteFixture("n1", "plain")])

    let sent = await firstRequest { $0.deleteSession(s, resolve: []) }

    #expect(sent.op == "rm-queue")
    #expect(sent.args["resolve"] == nil)
  }

  // MARK: The session view's Remove dialog

  @Test func removeWithTheWorktreeSendsTheShownTodos() async {
    let sent = await firstRequest { $0.delete("s1", branch: true, resolve: ["n3", "n4"]) }

    #expect(sent.op == "rm")
    #expect(sent.args == ["session": "s1", "worktree": true, "branch": true, "resolve": ["n3", "n4"]])
  }

  @Test func removeWithTheWorktreeSendsNoResolveWithoutAnOpenTodo() async {
    let sent = await firstRequest { $0.delete("s1", branch: false, resolve: []) }

    #expect(sent.args == ["session": "s1", "worktree": true, "branch": false])
  }

  @Test func removeWithoutTheWorktreeSendsTheShownTodos() async {
    let sent = await firstRequest { $0.remove("s1", resolve: ["n3"]) }

    #expect(sent.op == "rm")
    #expect(sent.args == ["session": "s1", "resolve": ["n3"]])
  }

  @Test func removeWithoutTheWorktreeSendsNoResolveWithoutAnOpenTodo() async {
    let sent = await firstRequest { $0.remove("s1", resolve: []) }

    #expect(sent.args == ["session": "s1"])
  }

  @Test func removeOfAFollowupThatHasNotStartedSendsTheShownTodos() async {
    var followup = notedSession([todoFixture("n3", "tell Alex in #flags")], state: .notStarted, id: "f1")
    followup.followup = Followup(prompt: "p")

    let sent = await firstRequest { model in
      model.apply(.success([]), followups: [followup])
      model.remove("f1", resolve: ["n3"])
    }

    #expect(sent.op == "followup-rm")
    #expect(sent.args == ["session": "f1", "resolve": ["n3"]])
  }
}

@MainActor
@Suite struct NotesSheetClosing {
  @Test func theSheetClosesWhenItsSessionIsGone() async {
    let model = offlineModel()
    model.editingNotes = "gone"
    let sheet = NotesSheet(id: "gone") { model.editingNotes = nil }.environmentObject(model)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: sheet)
    window.contentView?.layoutSubtreeIfNeeded()

    await settle { model.editingNotes == nil }

    #expect(model.editingNotes == nil)
    withExtendedLifetime(window) {}
  }

  @Test func aLongListScrollsInsideABoundedSheet() {
    let model = offlineModel()
    let todos = (0..<100).map { todoFixture("n\($0)", "to-do number \($0)") }
    model.apply(.success([notedSession(todos)]), followups: nil)
    let host = NSHostingView(rootView: NotesSheet(id: "s1") {}.environmentObject(model))

    #expect(host.fittingSize.height < NotesSheet.maxListHeight + 150)
  }
}
