import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPSessionToolTests: MCPToolServerSuite {
  @Test func listSessionsAndGetSessionReturnTheSessions() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let mcp = try MCPClient(sbd)

    let listed = try mcp.call("list_sessions").decode([SessionSummary].self)
    let got = try mcp.call("get_session", ["session": "bravo"]).decode(SessionSummary.self)

    #expect(Set(listed.map(\.id)) == [a.id, b.id])
    #expect(got.id == b.id)
    #expect(got.name == "bravo")
  }

  @Test func readReplyReturnsTheLastReply() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "alpha")
    let mcp = try MCPClient(sbd)

    let reply = try mcp.call("read_reply", ["session": .string(s.id)])

    #expect(!reply.isError)
    #expect(reply.json?["session"]?.string == s.id)
    #expect(reply.json?["reply"]?.string == "Done: hello")
  }

  @Test func triageReturnsTheSessionsThatSbdTriages() throws {
    let sbd = try Instance()
    let a = try idle(sbd, name: "alpha")
    let b = try idle(sbd, name: "bravo")
    let expected = try sbd.waitFor("both in triage", fetch: { try triaged(sbd) }) { Set($0) == [a.id, b.id] }
    let mcp = try MCPClient(sbd)

    let listed = try mcp.call("triage").decode([SessionSummary].self)

    #expect(listed.map(\.id) == expected)
  }

  @Test func eventsReturnsTheSessionsEventsAfterSince() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let other = try sbd.new(name: "bravo")
    let last = try #require(try sbd.events(s.id).map(\.id).max())
    try sbd.sb("send", s.id, "after the mark")
    try sbd.sb("send", other.id, "elsewhere")
    let mcp = try MCPClient(sbd)

    let events = try mcp.call(
      "events", ["session": .string(s.id), "since": .number(Double(last)), "limit": 1000]
    ).decode([Event].self)

    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.session == s.id && $0.id > last })
    #expect(events.contains { $0.kind == "sent" && $0.data["text"]?.string == "after the mark" })
  }

  @Test func eventsHonorsTheLimit() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    try sbd.sb("send", s.id, "one")
    try sbd.sb("send", s.id, "two")
    let mcp = try MCPClient(sbd)

    let events = try mcp.call("events", ["session": .string(s.id), "since": 0, "limit": 2]).decode([Event].self)

    #expect(events.count == 2)
  }

  @Test func sendDeliversTheText() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("send", ["session": .string(s.id), "text": "Rebase on main."])

    #expect(!result.isError)
    #expect(result.json?["delivery"]?.string != nil)
    #expect(try sent(sbd, s.id) == ["Rebase on main."])
  }

  @Test func spawnRecordsTheCallerAsItsParent() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    let mcp = try MCPClient(sbd, env: inside(parent.id))

    let kid = try mcp.call("spawn", try spawnArgs(sbd, "kid")).decode(SessionSummary.self)

    #expect(kid.name == "kid")
    #expect(kid.parent == parent.id)
    #expect(try sbd.get(kid.id).parent == parent.id)
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }
  }

  @Test func spawnResolvesARelativeRepositoryAgainstTheServersFolder() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo("widgets")
    let mcp = try MCPClient(sbd, cwd: sbd.home.path)

    let absolute = try mcp.call(
      "spawn", ["repository": .string(repo), "branch": "b1", "name": "b1", "prompt": "hello"]
    ).decode(SessionSummary.self)
    let relative = try mcp.call(
      "spawn", ["repository": "./widgets", "branch": "b2", "name": "b2", "prompt": "hello"]
    ).decode(SessionSummary.self)

    #expect(relative.repo != nil)
    #expect(relative.repo == absolute.repo)
  }

  @Test func spawnWithoutACallerHasNoParent() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let s = try mcp.call("spawn", try spawnArgs(sbd, "loner")).decode(SessionSummary.self)

    #expect(s.parent == nil)

    // The tool passes `host` on, so a host that config.json doesn't hold fails instead of starting on this Mac.
    let elsewhere = try mcp.call("spawn", try spawnArgs(sbd, "elsewhere").merging(["host": "nope"]) { $1 })
    #expect(elsewhere.isError, "\(elsewhere.text)")
    #expect(elsewhere.text.contains("nope"), "\(elsewhere.text)")
  }

  @Test func spawnInsideAGroupedCallerJoinsTheCallersGroup() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    let g = try addGroup(sbd, "Flags", parent.id)
    let mcp = try MCPClient(sbd, env: inside(parent.id))

    let kid = try mcp.call("spawn", try spawnArgs(sbd, "kid")).decode(SessionSummary.self)

    #expect(kid.group == g.id)
  }

  @Test func setWaitWithoutASessionWaitsOnTheCallerByClaude() throws {
    let sbd = try Instance()
    let caller = try idle(sbd, name: "caller")
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let waiting = try mcp.call("set_wait", ["note": "CI on #12"]).decode(SessionSummary.self)

    #expect(waiting.id == caller.id)
    #expect(waiting.state == .waiting)
    #expect(waiting.waits.map(\.kind) == [.manual])
    #expect(waiting.waits.map(\.by) == [.claude])
    #expect(try sbd.get(caller.id).waits.map(\.note) == ["CI on #12"])
  }

  @Test func setWaitOnANamedSessionLeavesTheCallerAlone() throws {
    let sbd = try Instance()
    let caller = try idle(sbd, name: "caller")
    let s = try idle(sbd, name: "alpha")
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let waiting = try mcp.call("set_wait", ["session": .string(s.id), "note": "CI on #12"]).decode(SessionSummary.self)

    #expect(waiting.id == s.id)
    #expect(waiting.waits.map(\.by) == [.claude])
    #expect(try sbd.get(caller.id).waits.isEmpty)
  }

  @Test func setWaitPassesTheTypedFieldsAndTheClockResolvesTheWait() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "alpha")
    let mcp = try MCPClient(sbd)

    let waiting = try mcp.call(
      "set_wait",
      ["session": .string(s.id), "kind": "date", "until": "1h", "note": "check the dashboard", "then": "notify"]
    ).decode(SessionSummary.self)

    let wait = try #require(waiting.waits.first)
    #expect(wait.kind == .date)
    #expect(wait.until != nil)
    #expect(wait.note == "check the dashboard")
    #expect(wait.then == .notify)
    #expect(wait.by == .claude)
    try sbd.advanceClock(2 * MCPToolServerTests.hourMs)
    try sbd.waitFor(s.id, "the wait to resolve") { $0.waits.isEmpty }
    #expect(try sbd.events(s.id).map(\.kind).contains("wait-resolved"))
  }

  @Test func setWaitReturnsSbdsErrorForAFieldTheKindDoesntTake() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "alpha")
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("set_wait", ["session": .string(s.id), "kind": "date", "who": "ana"])

    #expect(result.isError)
    #expect(result.text.contains("doesn't take who"))
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func clearWaitRemovesOneWaitOrAll() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "alpha")
    let first = try decode(SessionSummary.self, sbd.sb("wait", "--json", s.id, "--kind", "merge", "--target", "1190"))
      .waits[0]
    _ = try sbd.sb("wait", s.id, "--kind", "ci", "--target", "1191")
    let mcp = try MCPClient(sbd)

    let one = try mcp.call("clear_wait", ["session": .string(s.id), "wait": .string(first.id)])
      .decode(SessionSummary.self)
    let all = try mcp.call("clear_wait", ["session": .string(s.id)]).decode(SessionSummary.self)

    #expect(one.waits.count == 1)
    #expect(!one.waits.contains { $0.id == first.id })
    #expect(all.waits.isEmpty)
  }

  @Test func addNoteAddsANoteByClaude() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let noted = try mcp.call("add_note", ["session": .string(s.id), "text": "Ask Ana first."]).decode(
      SessionSummary.self)

    #expect(noted.notes.map(\.text) == ["Ask Ana first."])
    #expect(noted.notes.map(\.by) == [.claude])
  }

  @Test func addNoteWithTodoAddsAToDoByClaude() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let noted = try mcp.call(
      "add_note", ["session": .string(s.id), "text": "Tell Alex in #flags that the fix shipped.", "todo": true]
    ).decode(SessionSummary.self)

    let todo = try #require(noted.notes.first)
    #expect(todo.kind == .todo)
    #expect(todo.by == .claude)
    #expect(todo.isOpenTodo)
    #expect(try sbd.get(s.id).openTodos.map(\.id) == [todo.id])
  }

  @Test func addNoteWithoutTodoAddsAPlainNote() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let noted = try mcp.call("add_note", ["session": .string(s.id), "text": "Ask Ana first.", "todo": false])
      .decode(SessionSummary.self)

    #expect(noted.notes.map(\.isOpenTodo) == [false])
    #expect(try sbd.get(s.id).openTodos.isEmpty)
  }

  @Test func addNotesSchemaTakesTodo() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "add_note" })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["todo"]?["type"]?.string == "boolean")
  }
}
