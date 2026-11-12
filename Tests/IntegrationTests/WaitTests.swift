import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct WaitTests {
  static let hourMs: Int64 = 3600 * 1000

  /// A session whose first turn has ended.
  func idleSession(_ sbd: Instance, name: String = "t") throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    return s
  }

  /// A session whose stub waits `seconds` after SIGTERM before it exits.
  func lingeringSession(_ sbd: Instance, seconds: Int) throws -> SessionSummary {
    let s = try sbd.new(prompt: "linger \(seconds)")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "I'll linger \(seconds) s when I stop." }
    return s
  }

  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  @Test func aFreeTextWaitIsAManualWait() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    let waiting = try decode(sbd.sb("wait", "--json", s.id, "CI", "on", "#12"))
    #expect(waiting.state == .waiting)
    #expect(waiting.reason.hasPrefix("CI on #12 (recheck "))
    #expect(waiting.waits.map(\.kind) == [.manual])
    #expect(waiting.waits.map(\.by) == [.you])
    let cleared = try decode(sbd.sb("wait", "--json", s.id, "--clear"))
    #expect(cleared.waits.isEmpty)
    #expect(cleared.state != .waiting)
  }

  /// Los Angeles skips 02:00 to 03:00 on 2090-03-12.
  @Test func aDateWaitUntilATimeTheZoneSkipsWaitsUntilTheTimeAfterTheSkip() throws {
    let sbd = try Instance()
    sbd.stopSbd()
    sbd.sbdEnvironment["TZ"] = "America/Los_Angeles"
    try sbd.startSbd()
    let s = try idleSession(sbd)
    let waiting = try decode(sbd.sb("wait", "--json", s.id, "--kind", "date", "--until", "2090-03-12 02:30"))
    #expect(waiting.reason == "until 2090-03-12 03:30")
  }

  @Test func aDateWaitStopsTheSessionAndResumesItWhenTheClockPassesIt() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    let waiting = try decode(
      sbd.sb("wait", "--json", s.id, "--kind", "date", "--until", "1h", "--note", "check the dashboard"))
    #expect(waiting.state == .waiting)
    #expect(waiting.reason.hasPrefix("until "))
    // idleStopSeconds is 600, so only the open wait stops it this soon.
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(2 * WaitTests.hourMs)
    let resumed = try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }
    #expect(resumed.lastReply?.hasSuffix(": the time came. Your note: check the dashboard.") == true)
    #expect(resumed.waits.isEmpty)
    #expect(sbd.stubArgs().last?.hasPrefix("--resume \(s.claudeSessionId) ") == true)
    #expect(try sbd.events(s.id).map(\.kind).contains("wait-resolved"))
  }

  @Test func aWaitResolvedWhileClaudeExitsStillResumesTheSession() throws {
    let sbd = try Instance()
    // `send` waits up to 5 s for an exiting claude, so a 7 s exit outlasts it.
    let s = try lingeringSession(sbd, seconds: 7)
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1190")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    // The stub runs for 7 s after the stop, so the resolution meets a claude that is exiting.
    #expect(try sbd.get(s.id).claudePid != nil)
    try sbd.sb("wait", s.id, "--resolve", "#1190 merged")
    try sbd.waitFor(s.id, "the resumed turn", timeout: 30) {
      $0.lastReply == "Done: Switchboard: #1190 to merge: #1190 merged."
    }
  }

  @Test
  func aDateWaitThatPassesWhileClaudeExitsStillResumesTheSession() throws {
    let sbd = try Instance()
    let s = try lingeringSession(sbd, seconds: 3)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(2 * WaitTests.hourMs)
    try sbd.waitFor(s.id, "the resumed turn", timeout: 30) {
      $0.lastReply?.hasPrefix("Done: Switchboard: until ") == true
    }
  }

  @Test func aClaudeThatIsExitingAfterItsSessionEndedStaysNotLive() throws {
    let sbd = try Instance()
    let s = try lingeringSession(sbd, seconds: 8)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    // A tick sees the exiting claude first. Then the clock passes the 10 s that a claude may run without a SessionStart.
    sleep(1)
    try sbd.advanceClock(15_000)
    sleep(1)
    #expect(try sbd.get(s.id).live == false)
    #expect(try sbd.get(s.id).claudePid != nil)
  }

  /// The clock resolves the wait. The session's own SessionEnd stays the last event that moves `lastActivity`.
  @Test func aDateWaitThatNotifiesKeepsTheLastActivity() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h", "--then", "notify")
    try sbd.waitFor("the stop's SessionEnd", timeout: 10) {
      try sbd.events(s.id).contains { $0.kind == "SessionEnd" }
    }
    let before = try sbd.get(s.id).lastActivity
    let wait = try #require(try sbd.events(s.id).last { $0.kind == "wait" })
    #expect(before >= wait.t)

    try sbd.advanceClock(2 * WaitTests.hourMs)
    let resolved = try sbd.waitFor(
      "the wait-resolved event", fetch: { try sbd.events(s.id).last { $0.kind == "wait-resolved" } },
      until: { _ in true })

    #expect(resolved.t > before)
    #expect(try sbd.get(s.id).lastActivity == before)
  }

  @Test func aDoneSessionsWaitsDontResumeIt() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.sb("done", s.id)
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(2 * WaitTests.hourMs)
    sleep(1)
    let after = try sbd.get(s.id)
    #expect(after.state == .done)
    #expect(after.waits.count == 1)
    #expect(sbd.stubArgs().count == 1)
  }

  @Test func refusesWordsThatTheFlagsWouldDrop() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let open = try decode(sbd.sb("wait", "--json", s.id, "--kind", "merge", "--target", "1190")).waits
    try sbd.sb("note", s.id, "stacked on #1190")
    let note = try #require(try sbd.get(s.id).notes.first)
    for args in [
      ["wait", s.id, "--resolve", "the", "checks", "passed"], ["wait", s.id, "--clear", "now"],
      ["wait", s.id, "--kind", "ci", "--note", "merge", "when", "green"], ["note", s.id, "--rm", note.id, "now"],
    ] {
      #expect(throws: TestError.self) { try sbd.sb(args) }
    }
    #expect(try sbd.get(s.id).waits == open)
    #expect(try sbd.get(s.id).notes == [note])
  }

  @Test func refusesNumbersTooLargeForAnInt() throws {
    let sbd = try Instance()
    #expect(throws: APIError.self) { try sbd.client.call("clock", ["advance": 1e19]) }
    try sbd.advanceClock(9_000_000_000_000_000_000)
    #expect(throws: APIError.self) { try sbd.advanceClock(9_000_000_000_000_000_000) }
    _ = try sbd.client.call("events", ["limit": 1e19, "since": 1e19])
    #expect(try sbd.client.call("ping")["pid"] != nil)
  }

  @Test func aSessionWaitResumesWhenTheOtherSessionIsDone() throws {
    let sbd = try Instance()
    let a = try idleSession(sbd, name: "a")
    let b = try idleSession(sbd, name: "b")
    #expect(throws: TestError.self) { try sbd.sb("wait", a.id, "--kind", "session", "--target", "a") }
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b")
    #expect(try sbd.get(a.id).reason == "b to reach Done")
    try sbd.sb("done", b.id)
    try sbd.waitFor(a.id, "the resumed turn") { $0.lastReply == "Done: Switchboard: b to reach Done: it did." }
    #expect(try sbd.get(a.id).waits.isEmpty)
  }

  @Test func aManualWaitReturnsToNeedsYouOnItsRecheckDate() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "manual", "--note", "ask Alex", "--until", "1d")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(25 * WaitTests.hourMs)
    let due = try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }
    #expect(due.reason == "ask Alex: time to recheck")
    #expect(due.waits.isEmpty)
    #expect(!due.live)
    #expect(sbd.stubArgs().count == 1)
  }

  @Test func aPollerResolvesACIWaitAndTheSessionResumes() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    let set = try decode(
      sbd.sb(
        "wait", "--json", s.id, "--kind", "ci", "--target", "https://github.com/PostHog/posthog/pull/1204", "--note",
        "merge when green"))
    let wait = try #require(set.waits.first)
    #expect(wait.pr == Wait.PullRequest(repository: "PostHog/posthog", number: 1204))
    #expect(set.reason == "CI on PostHog/posthog#1204 (merge when green)")
    // Service.resolveWait, the interface that pollers use, sends this request.
    _ = try sbd.client.call(
      "resolve-wait", ["session": .string(s.id), "wait": .string(wait.id), "outcome": "the checks passed"])
    try sbd.waitFor(s.id, "the resumed turn") {
      $0.lastReply == "Done: Switchboard: CI on PostHog/posthog#1204: the checks passed. Your note: merge when green."
    }
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func aWaitThatNotifiesMovesTheSessionToNeedsYouWithoutResumingIt() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "review", "--target", "1204", "--who", "alex", "--then", "notify")
    let after = try decode(sbd.sb("wait", "--json", s.id, "--resolve", "alex approved"))
    #expect(after.state == .needsYou)
    #expect(after.reason == "a review from alex on #1204: alex approved")
    #expect(after.waits.isEmpty)
    #expect(try sbd.events(s.id).filter { $0.kind == "UserPromptSubmit" }.count == 1)
    try sbd.sb("send", s.id, "offer it")
    try sbd.waitFor(s.id, "the reply to the next prompt") { $0.state == .canContinue }
  }

  @Test func aWaitFromInsideASessionIsSetByClaude() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", "--kind", "bot-review", "--who", "ReviewHog", env: ["SB_SESSION_ID": s.id, "CLAUDECODE": "1"])
    let after = try sbd.get(s.id)
    let wait = try #require(after.waits.first)
    #expect(wait.kind == .botReview)
    #expect(wait.by == .claude)
    #expect(wait.pr == nil)
    #expect(after.reason == "ReviewHog's review on the session's PR")
  }

  @Test func addsListsAndRemovesNotes() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    try sbd.sb("note", s.id, "rebased", "onto", "#1190")
    try sbd.sb("note", s.id, "ask Alex about the cache", env: ["CLAUDECODE": "1"])
    let notes = try sbd.get(s.id).notes
    #expect(notes.map(\.text) == ["rebased onto #1190", "ask Alex about the cache"])
    #expect(notes.map(\.by) == [.you, .claude])
    #expect(try sbd.sb("note", s.id).contains("rebased onto #1190 (you, "))
    try sbd.sb("note", s.id, "--rm", notes[0].id)
    #expect(try sbd.get(s.id).notes.map(\.text) == ["ask Alex about the cache"])
    #expect(throws: TestError.self) { try sbd.sb("note", s.id, "--rm", "nnope") }
  }

  @Test func keepsWaitsAndNotesAcrossARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "#1190")
    try sbd.sb("note", s.id, "stacked on #1190")
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.state == .waiting)
    #expect(after.reason == "#1190 to merge")
    #expect(after.notes.map(\.text) == ["stacked on #1190"])
  }

  @Test func turnsAV01WaitNoteIntoAManualWait() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "old")
    sbd.stopSbd()
    do {
      let store = try Store(path: sbd.home.database)
      var session = try #require(try store.sessions().first)
      session.waitNote = "CI on #12"
      try store.save(session)
    }
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.waits.map(\.kind) == [.manual])
    #expect(after.waits.map(\.note) == ["CI on #12"])
    #expect(after.reason.hasPrefix("CI on #12 (recheck "))
  }

  // MARK: To-dos

  /// The line of the output that names the id.
  func line(_ output: String, naming id: String) -> String? {
    output.split(separator: "\n").map(String.init).first { $0.contains(id) }
  }

  @Test func noteTodoAddsAToDoByTheUserOrByClaude() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    try sbd.sb("note", s.id, "--todo", "tell Alex in #flags that the fix shipped")
    try sbd.sb(["note", s.id, "--todo", "close the incident"], env: ["CLAUDECODE": "1"])

    let notes = try sbd.get(s.id).notes
    #expect(notes.map(\.text) == ["tell Alex in #flags that the fix shipped", "close the incident"])
    #expect(notes.map(\.kind) == [.todo, .todo])
    #expect(notes.map(\.by) == [.you, .claude])
    #expect(notes.allSatisfy { $0.isOpenTodo })
    #expect(try sbd.get(s.id).openTodos.map(\.id) == notes.map(\.id))
    #expect(try sbd.events(s.id).filter { $0.kind == "note" }.count == 2)
  }

  @Test func aNoteWithoutKindIsAPlainNote() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    try sbd.sb("note", s.id, "stacked on #1190")

    let note = try #require(try sbd.get(s.id).notes.first)
    #expect((note.kind ?? .note) == .note)
    #expect(!note.isOpenTodo)
    #expect(try sbd.get(s.id).openTodos.isEmpty)
  }

  @Test func lsCountsTheOpenToDos() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    #expect(try !sbd.sb("ls").contains("to-do"))

    _ = try sbd.addTodo(s.id, "tell Alex")
    #expect(try sbd.sb("ls").contains("[1 to-do]"))

    _ = try sbd.addTodo(s.id, "close the incident")
    #expect(try sbd.sb("ls").contains("[2 to-dos]"))
  }

  /// Claude can write a note whose text holds terminal escapes. `sb note` prints them escaped.
  @Test func noteListEscapesTheText() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    _ = try sbd.addTodo(s.id, "done\u{1b}[2Kremoved", by: .claude)

    let text = try sbd.sb("note", s.id)

    #expect(text.contains("done\\u{1b}[2Kremoved"), Comment(rawValue: text))
    #expect(!text.contains("\u{1b}"), Comment(rawValue: text))
  }

  @Test func noteRefusesAnUnknownKind() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let message = failure(sbd, "note", ["session": .string(s.id), "text": "tell Alex", "kind": "chore"])

    #expect(message != "no error")
    #expect(try sbd.get(s.id).notes.isEmpty)
  }

  @Test func noteResolveResolvesAToDoAndKeepsTheRecord() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags")
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped", by: .claude)

    try sbd.sb("note", s.id, "--resolve", todo.id)

    let after = try #require(try sbd.storedNote(s.id, todo.id))
    #expect(after.kind == .todo)
    #expect(after.by == .claude)
    #expect(after.resolved?.by == .you)
    #expect(after.resolved?.how == "resolved")
    #expect(after.resolved.map { $0.t >= todo.t } == true)
    #expect(!after.isOpenTodo)
    #expect(try sbd.get(s.id).openTodos.isEmpty)
    let event = try #require(try sbd.events(s.id).last { $0.kind == "note-resolved" })
    #expect(event.data["note"]?.string == todo.id || event.data["note"]?["id"]?.string == todo.id)
    let rows = try sbd.resolvedTodos()
    #expect(rows.count == 1)
    #expect(rows.first?["session"]?.string == s.id)
    #expect(rows.first?["name"]?.string == "flags")
    #expect(rows.first?["note"]?.string == todo.id)
    #expect(rows.first?["text"]?.string == todo.text)
    #expect(rows.first?["how"]?.string == "resolved")
  }

  @Test func resolveNoteByClaudeRefusesAndResolvesNothing() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    let message = failure(
      sbd, "resolve-note", ["session": .string(s.id), "note": .string(todo.id), "by": "claude"])

    #expect(message != "no error")
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
    #expect(try !sbd.events(s.id).contains { $0.kind == "note-resolved" })
  }

  @Test func noteResolveInsideClaudeCodeExitsWithAnError() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    let r = try sbd.run(["note", s.id, "--resolve", todo.id], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  @Test func resolveNoteRefusesANoteThatIsNotAnOpenToDo() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let plain = try sbd.addPlainNote(s.id, "stacked on #1190")
    let resolved = try sbd.addTodo(s.id, "update the runbook")
    try sbd.resolveTodo(s.id, resolved.id)
    let other = try sbd.new(name: "other")
    let elsewhere = try sbd.addTodo(other.id, "ping Ana")
    let before = try sbd.get(s.id).notes
    let rowsBefore = try sbd.resolvedTodoIds()
    // shortId never uses 0. Therefore n00000 names no note.
    let ids: [(String, String)] = [
      ("a plain note", plain.id), ("a resolved to-do", resolved.id), ("an unknown id", "n00000"),
      ("another session's to-do", elsewhere.id),
    ]

    for (what, id) in ids {
      let message = failure(sbd, "resolve-note", ["session": .string(s.id), "note": .string(id), "by": "you"])

      #expect(message != "no error", "\(what)")
      #expect(try sbd.get(s.id).notes == before, "\(what)")
      #expect(try sbd.isOpenTodo(other.id, elsewhere.id), "\(what)")
      #expect(try sbd.resolvedTodoIds() == rowsBefore, "\(what)")
    }
  }

  @Test func removeNoteRefusesAnOpenToDo() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    let r = try sbd.run(["note", s.id, "--rm", todo.id])
    let message = failure(sbd, "remove-note", ["session": .string(s.id), "note": .string(todo.id)])

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(todo.id) is an open to-do"), Comment(rawValue: r.stderr))
    #expect(r.stderr.contains("sb note \(s.id) --resolve \(todo.id)"), Comment(rawValue: r.stderr))
    #expect(message.contains("\(todo.id) is an open to-do"), Comment(rawValue: message))
    #expect(try sbd.isOpenTodo(s.id, todo.id))
    #expect(try !sbd.events(s.id).contains { $0.kind == "note-removed" })
  }

  @Test func removeNoteRemovesAPlainNoteAndAResolvedToDo() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let plain = try sbd.addPlainNote(s.id, "stacked on #1190")
    let todo = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    try sbd.resolveTodo(s.id, todo.id)

    try sbd.sb("note", s.id, "--rm", plain.id)
    try sbd.sb("note", s.id, "--rm", todo.id)

    #expect(try sbd.get(s.id).notes.isEmpty)
    #expect(try sbd.resolvedTodoIds() == [todo.id])
  }

  @Test func noteListsOpenToDosFirstThenPlainNotesThenResolvedToDos() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let resolved = try sbd.addTodo(s.id, "update the runbook")
    let plain = try sbd.addPlainNote(s.id, "stacked on #1190")
    let open = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")
    try sbd.resolveTodo(s.id, resolved.id)

    let output = try sbd.sb("note", s.id)

    let order = [open, plain, resolved].map { output.range(of: $0.id)?.lowerBound }
    #expect(order.allSatisfy { $0 != nil }, Comment(rawValue: output))
    #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted(), Comment(rawValue: output))
    #expect(line(output, naming: open.id)?.contains("to-do") == true, Comment(rawValue: output))
    #expect(line(output, naming: open.id)?.contains("resolved") == false, Comment(rawValue: output))
    #expect(line(output, naming: plain.id)?.contains("to-do") == false, Comment(rawValue: output))
    #expect(line(output, naming: resolved.id)?.contains("to-do, resolved") == true, Comment(rawValue: output))
  }

  @Test func getMarksEachToDo() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let plain = try sbd.addPlainNote(s.id, "stacked on #1190")
    let open = try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    let output = try sbd.sb("get", s.id)

    #expect(line(output, naming: open.id)?.contains("to-do") == true, Comment(rawValue: output))
    #expect(line(output, naming: plain.id)?.contains("to-do") == false, Comment(rawValue: output))
  }

  @Test func noteResolvedListsTheRecordsNewestFirstAndHonorsTheLimit() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    var todos: [Note] = []
    for text in ["update the runbook", "close the incident", "tell Alex in #flags that the fix shipped"] {
      let todo = try sbd.addTodo(s.id, text)
      try sbd.resolveTodo(s.id, todo.id)
      try sbd.advanceClock(60_000)
      todos.append(todo)
    }
    let newestFirst = todos.reversed().map(\.id)

    let all = try sbd.resolvedTodos()
    let limited = try #require(
      JSON.parse(try sbd.sb("note", "--resolved", "--limit", "2", "--json"))?.array)
    let text = try sbd.sb("note", "--resolved")

    #expect(all.compactMap { $0["note"]?.string } == newestFirst)
    #expect(try sbd.resolvedTodos(limit: 2).compactMap { $0["note"]?.string } == Array(newestFirst.prefix(2)))
    #expect(limited.compactMap { $0["note"]?.string } == Array(newestFirst.prefix(2)))
    for todo in todos { #expect(text.contains(todo.text), Comment(rawValue: text)) }
  }

  @Test func theClockMovesOnlyInATestInstance() throws {
    let sbd = try Instance(testClock: false)
    #expect(throws: APIError.self) { try sbd.advanceClock(1000) }
  }

  @Test func theClockPassesTheIdleStopWithoutSleeping() throws {
    let sbd = try Instance(idleStopSeconds: 900)
    let s = try idleSession(sbd)
    try sbd.waitFor(s.id, "claude's pid") { $0.claudePid != nil }
    try sbd.advanceClock(16 * 60 * 1000)
    try sbd.waitFor(s.id, "the idle stop", timeout: 5) { !$0.live }
  }
}

/// Recheck times, and the outcomes of a session wait whose target can't reach the wanted state.
extension WaitTests {
  static let dayMs: Int64 = 24 * hourMs

  /// The real time in ms. A new sbd's clock reads it until a test moves the clock.
  static func wallMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  /// An idle session with a review wait on its own PR, whose claude has stopped.
  func stoppedWithAReviewWait(_ sbd: Instance) throws -> SessionSummary {
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "review", "--who", "alex")
    return try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
  }

  static let overdueReview = "a review from alex on the session's PR: still open after 1 d"

  @Test func aReviewWaitRechecksADayAfterItWasSet() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)

    let set = try decode(sbd.sb("wait", "--json", s.id, "--kind", "review", "--who", "alex"))

    let wait = try #require(set.waits.first)
    #expect(wait.recheck == wait.created + WaitTests.dayMs)
    #expect(try sbd.get(s.id).waits.first?.recheck == wait.recheck)
  }

  @Test(arguments: [
    ["--kind", "date", "--until", "1h"], ["--kind", "manual", "--note", "ask Alex", "--until", "1h"],
  ])
  func aWaitWithItsOwnTimeGetsNoRecheck(_ flags: [String]) throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)

    try sbd.sb(["wait", s.id] + flags)

    #expect(try sbd.get(s.id).waits.map(\.recheck) == [nil])
  }

  @Test func aReviewWaitPastItsRecheckNeedsYouAndStaysOpen() throws {
    let sbd = try Instance()
    let s = try stoppedWithAReviewWait(sbd)

    try sbd.advanceClock(25 * WaitTests.hourMs)

    let due = try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }
    #expect(due.reason == WaitTests.overdueReview)
    #expect(due.waits.map(\.kind) == [.review])
  }

  @Test func anOverdueWaitRecordsNoResolutionAndSendsNothing() throws {
    let sbd = try Instance()
    let s = try stoppedWithAReviewWait(sbd)
    let sent = try sbd.count("sent", of: s.id)
    let runs = sbd.stubArgs().count

    try sbd.advanceClock(25 * WaitTests.hourMs)

    try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }
    #expect(try sbd.count("wait-resolved", of: s.id) == 0)
    #expect(try sbd.count("sent", of: s.id) == sent)
    #expect(sbd.stubArgs().count == runs)
  }

  /// The poller's resolution of an overdue wait resumes the session as it would before the recheck time.
  @Test func anOverdueWaitThatResolvesResumesTheSession() throws {
    let sbd = try Instance()
    let s = try stoppedWithAReviewWait(sbd)
    try sbd.advanceClock(25 * WaitTests.hourMs)
    let due = try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }
    let wait = try #require(due.waits.first)

    _ = try sbd.client.call(
      "resolve-wait", ["session": .string(s.id), "wait": .string(wait.id), "outcome": "alex approved"])

    let resumed = try sbd.waitFor(s.id, "the resumed turn") {
      $0.lastReply == "Done: Switchboard: a review from alex on the session's PR: alex approved."
    }
    #expect(resumed.waits.isEmpty)
    #expect(try sbd.count("wait-resolved", of: s.id) == 1)
  }

  @Test func onlyTheOverdueOfTwoWaitsIsNamed() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "ci")
    try sbd.sb("wait", s.id, "--kind", "review", "--who", "alex")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }

    try sbd.advanceClock(3 * WaitTests.hourMs)

    let due = try sbd.waitFor(s.id, "the CI recheck") { $0.state == .needsYou }
    #expect(due.reason == "CI on the session's PR: still open after 2 h")
    #expect(due.waits.map(\.kind) == [.ci, .review])
  }

  @Test func waitsBeforeTheirRecheckStayWaitingWithTheirLines() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "ci")
    try sbd.sb("wait", s.id, "--kind", "review", "--who", "alex")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }

    try sbd.advanceClock(WaitTests.hourMs)

    let after = try sbd.get(s.id)
    #expect(after.state == .waiting)
    #expect(after.reason == "CI on the session's PR; a review from alex on the session's PR")
  }

  @Test func aManualWaitWithoutUntilRechecksAfterADay() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "manual", "--note", "ask Alex")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }

    try sbd.advanceClock(25 * WaitTests.hourMs)

    let due = try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }
    #expect(due.reason == "ask Alex: time to recheck")
    #expect(due.waits.isEmpty)
    #expect(sbd.stubArgs().count == 1)
  }

  @Test func aManualWaitWithoutUntilStaysOpenBeforeItsRecheck() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "manual", "--note", "ask Alex")

    try sbd.advanceClock(23 * WaitTests.hourMs)

    let after = try sbd.get(s.id)
    #expect(after.state == .waiting)
    #expect(after.waits.map(\.note) == ["ask Alex"])
  }

  @Test func recheckSecondsInTheConfigSetTheManualRecheck() throws {
    let sbd = try Instance(config: ["recheckSeconds": ["manual": 60]])
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "manual", "--note", "ask Alex")
    try sbd.advanceClock(30_000)
    #expect(try sbd.get(s.id).state == .waiting)

    try sbd.advanceClock(31_000)

    let due = try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }
    #expect(due.reason == "ask Alex: time to recheck")
    #expect(due.waits.isEmpty)
  }

  @Test func clearingAnOverdueWaitReturnsTheSessionToItsReply() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "offer it")
    try sbd.waitFor(s.id, "the offer") { $0.state == .canContinue }
    try sbd.sb("wait", s.id, "--kind", "ci")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(3 * WaitTests.hourMs)
    try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }

    let cleared = try decode(sbd.sb("wait", "--json", s.id, "--clear"))

    #expect(cleared.state == .canContinue)
    #expect(cleared.waits.isEmpty)
  }

  /// An overdue session wait still resolves, and resumes the waiter, when its target gets there.
  @Test func anOverdueSessionWaitResumesTheWaiterWhenTheTargetIsDone() throws {
    let sbd = try Instance(config: ["recheckSeconds": ["session": 60]])
    let a = try idleSession(sbd, name: "a")
    let b = try idleSession(sbd, name: "b")
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b")
    try sbd.advanceClock(61_000)
    let due = try sbd.waitFor(a.id, "the recheck") { $0.state == .needsYou }
    #expect(due.reason == "b to reach Done: still open after 1 min")
    #expect(due.waits.count == 1)

    try sbd.sb("done", b.id)

    let resumed = try sbd.waitFor(a.id, "the resumed turn") {
      $0.lastReply == "Done: Switchboard: b to reach Done: it did."
    }
    #expect(resumed.waits.isEmpty)
  }

  /// A session marked done keeps its waits, so its manual wait is not removed at its recheck.
  @Test func aDoneSessionKeepsItsManualWaitPastItsRecheck() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "manual", "--note", "ask Alex")
    try sbd.sb("done", s.id)

    try sbd.advanceClock(25 * WaitTests.hourMs)
    sleep(1)

    let after = try sbd.get(s.id)
    #expect(after.state == .done)
    #expect(after.waits.count == 1)
    #expect(try sbd.count("wait-resolved", of: s.id) == 0)
  }

  @Test func removingTheTargetOfASessionWaitResumesTheWaiter() throws {
    let sbd = try Instance()
    let a = try idleSession(sbd, name: "a")
    let b = try idleSession(sbd, name: "b")
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b")

    try sbd.sb("rm", b.id)

    let resumed = try sbd.waitFor(a.id, "the resumed turn") {
      $0.lastReply == "Done: Switchboard: b to reach Done: it was removed."
    }
    #expect(resumed.waits.isEmpty)
  }

  @Test func aSessionWaitForReadyForReviewEndsWhenTheTargetIsMarkedDone() throws {
    let sbd = try Instance()
    let a = try idleSession(sbd, name: "a")
    let b = try idleSession(sbd, name: "b")
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b", "--state", "ready_for_review")
    #expect(try sbd.get(a.id).reason == "b to reach Ready for review")

    try sbd.sb("done", b.id)

    let resumed = try sbd.waitFor(a.id, "the resumed turn") {
      $0.lastReply == "Done: Switchboard: b to reach Ready for review: it reached Done first."
    }
    #expect(resumed.waits.isEmpty)
  }

  /// The session recheck is raised above the 2 days that make the target Stale.
  @Test func aSessionWaitEndsWhenTheTargetGoesStale() throws {
    let sbd = try Instance(config: ["recheckSeconds": ["session": 432_000]])
    let a = try idleSession(sbd, name: "a")
    let b = try idleSession(sbd, name: "b")
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b")
    try sbd.sb("stop", b.id)
    // SessionEnd is a hook, so it is the target's last activity.
    try sbd.waitFor("b's SessionEnd", timeout: 10) { try sbd.events(b.id).contains { $0.kind == "SessionEnd" } }

    try sbd.advanceClock(2 * WaitTests.dayMs + WaitTests.hourMs)

    let resumed = try sbd.waitFor(a.id, "the resumed turn") {
      $0.lastReply == "Done: Switchboard: b to reach Done: it went stale."
    }
    #expect(resumed.waits.isEmpty)
  }

  // Waits that an older sbd stored get a recheck time that counts from the load.

  /// A session whose waits an older sbd stored without recheck times, and the
  /// span of real time in which the new sbd loaded them.
  func legacySession(_ sbd: Instance) throws -> (session: SessionSummary, loaded: ClosedRange<Int64>) {
    let s = try sbd.new(name: "old")
    sbd.stopSbd()
    let fiveDaysAgo = WaitTests.wallMs() - 5 * WaitTests.dayMs
    do {
      let store = try Store(path: sbd.home.database)
      var session = try #require(try store.sessions().first { $0.id == s.id })
      session.waits = [
        Wait(id: "wci", kind: .ci, created: fiveDaysAgo),
        Wait(id: "wmanual", kind: .manual, note: "ask Alex", created: fiveDaysAgo, then: .notify),
        Wait(id: "wdate", kind: .date, until: WaitTests.wallMs() + 10 * WaitTests.dayMs, created: fiveDaysAgo),
        Wait(
          id: "wuntil", kind: .manual, until: WaitTests.wallMs() + 10 * WaitTests.dayMs, note: "ask Ana",
          created: fiveDaysAgo, then: .notify),
      ]
      session.waitNote = "CI on #12"
      try store.save(session)
    }
    let before = WaitTests.wallMs()
    try sbd.startSbd()
    return (s, before...(try sbd.now()))
  }

  func storedWait(_ id: String, of s: SessionSummary, in sbd: Instance) throws -> Wait {
    try #require(try sbd.get(s.id).waits.first { $0.id == id })
  }

  @Test(arguments: [("wci", WaitTests.hourMs * 2), ("wmanual", WaitTests.dayMs)])
  func aLegacyWaitRechecksItsDefaultAfterTheLoad(_ id: String, _ defaultMs: Int64) throws {
    let sbd = try Instance()
    let (s, loaded) = try legacySession(sbd)

    let wait = try storedWait(id, of: s, in: sbd)
    // A manual wait gets its recheck time as its until.
    let recheck = try #require(wait.kind == .manual ? wait.until : wait.recheck)

    #expect(recheck >= loaded.lowerBound + defaultMs)
    #expect(recheck <= loaded.upperBound + defaultMs)
  }

  @Test(arguments: ["wdate", "wuntil"])
  func aLegacyWaitWithItsOwnTimeGetsNoRecheck(_ id: String) throws {
    let sbd = try Instance()
    let (s, _) = try legacySession(sbd)

    #expect(try storedWait(id, of: s, in: sbd).recheck == nil)
  }

  /// `upgraded` turns the v0.1 note into a manual wait and stamps it in the same load.
  @Test func aV01WaitNoteGetsARecheckInTheSameLoad() throws {
    let sbd = try Instance()
    let (s, loaded) = try legacySession(sbd)

    let converted = try #require(try sbd.get(s.id).waits.first { $0.note == "CI on #12" })

    let recheck = try #require(converted.until)
    #expect(recheck >= loaded.lowerBound + WaitTests.dayMs)
    #expect(recheck <= loaded.upperBound + WaitTests.dayMs)
  }

  @Test func legacyWaitsStayOpenAfterTheFirstTick() throws {
    let sbd = try Instance()
    let (s, _) = try legacySession(sbd)

    try sbd.advanceClock(1000)

    let after = try sbd.get(s.id)
    #expect(after.state == .waiting)
    #expect(after.waits.count == 5)
  }

  @Test func anotherStartKeepsTheRecheckTimes() throws {
    let sbd = try Instance()
    let (s, _) = try legacySession(sbd)
    let stamped = try sbd.get(s.id).waits

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.get(s.id).waits == stamped)
  }
}
