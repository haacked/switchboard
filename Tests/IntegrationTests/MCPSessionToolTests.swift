import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPSessionToolTests: MCPToolServerSuite {
  @Test func listSessionsAndGetSessionReturnTheSessions() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let mcp = try MCPClient(sbd)

    let listed = try mcp.call("list_sessions").decode([SessionBrief].self)
    let got = try mcp.call("get_session", ["session": "bravo"]).decode(SessionBrief.self)

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

  /// An idle session in group Flags, a server for the group or for every session, and the `events` arguments
  /// that read the session's events from that server.
  func eventsServer(_ sbd: Instance, scoped: Bool) throws -> (SessionSummary, MCPClient, [String: JSON]) {
    let s = try idle(sbd, name: "alpha")
    let group = try addGroup(sbd, "Flags", s.id)
    let mcp = try MCPClient(sbd, group: scoped ? group.id : nil)
    return (s, mcp, scoped ? [:] : ["session": .string(s.id)])
  }

  @Test(arguments: [false, true]) func eventsWithoutALimitListsTheNewest20(scoped: Bool) throws {
    let sbd = try Instance()
    let (s, mcp, args) = try eventsServer(sbd, scoped: scoped)
    for i in 0..<25 { try sbd.addPlainNote(s.id, "note \(i)") }
    let newest = try sbd.events(s.id).suffix(20).map(\.id)

    let events = try mcp.call("events", args).decode([Event].self)

    #expect(events.map(\.id) == Array(newest))
  }

  @Test(arguments: [false, true]) func eventsPassesKindsThrough(scoped: Bool) throws {
    let sbd = try Instance()
    let (s, mcp, args) = try eventsServer(sbd, scoped: scoped)
    try sbd.addPlainNote(s.id, "one")
    try sbd.addPlainNote(s.id, "two")
    try sbd.postProbe(s.id)
    let notes = try sbd.events(s.id).filter { $0.kind == "note" }.map(\.id)

    let events = try mcp.call("events", args.merging(["kinds": ["note"]]) { $1 }).decode([Event].self)

    #expect(events.map(\.id) == notes)
  }

  @Test(arguments: [false, true]) func eventsPassesFullThrough(scoped: Bool) throws {
    let sbd = try Instance()
    let (s, mcp, args) = try eventsServer(sbd, scoped: scoped)
    let response: JSON = ["stdout": "hello", "stderr": "", "interrupted": false]
    try sbd.postHook(
      s.id, "PostToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_full", "tool_response": response])
    let read = { (extra: [String: JSON]) throws -> JSON? in
      try mcp.call("events", args.merging(extra) { $1 }).decode([Event].self)
        .last { $0.data["tool_use_id"] == "toolu_full" }?.data["tool_response"]
    }

    let full = try read(["kinds": ["PostToolUse"], "full": true])
    let slim = try read(["kinds": ["PostToolUse"]])

    #expect(full == response)
    #expect(slim?.string != nil, "\(slim?.text ?? "nil")")
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

  /// sbd accepts `then: caller`, so set_wait is what refuses it.
  @Test func setWaitRefusesThenCaller() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "alpha")
    let mcp = try MCPClient(sbd)

    let result = try mcp.call(
      "set_wait", ["session": .string(s.id), "kind": "manual", "note": "x", "then": "caller"])

    #expect(result.isError)
    #expect(result.text.contains("not caller"))
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

  // MARK: Artifacts

  @Test func getSessionCarriesTheSessionsArtifacts() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    try sbd.postArtifactHook(s.id)
    let mcp = try MCPClient(sbd)

    let got = try #require(try mcp.call("get_session", ["session": .string(s.id), "full": true]).json)

    #expect(got["artifacts"]?.array?.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(got["artifacts"]?.array?.first?["title"]?.string == "Delta Rates")
  }

  @Test func listSessionsCarriesEachSessionsArtifacts() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    try sbd.postArtifactHook(a.id)
    let mcp = try MCPClient(sbd)

    let listed = try #require(try mcp.call("list_sessions", ["full": true]).json?.array)

    let alpha = try #require(listed.first { $0["id"]?.string == a.id })
    let bravo = try #require(listed.first { $0["id"]?.string == b.id })
    #expect(alpha["artifacts"]?.array?.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(bravo["artifacts"] == nil)
  }

  @Test(arguments: ["list_sessions", "get_session"])
  func theSessionToolsDescriptionsNameArtifacts(_ name: String) throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == name })

    #expect(tool["description"]?.string?.contains("artifacts") == true, "\(tool["description"]?.string ?? "")")
  }

  @Test(arguments: ["list_sessions", "get_session"])
  func theSessionToolsSchemasTakeFull(_ name: String) throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == name })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["full"]?["type"]?.string == "boolean")
  }

  // MARK: Links

  @Test func getSessionWithFullCarriesTheSessionsLinks() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    let mcp = try MCPClient(sbd)

    let got = try #require(try mcp.call("get_session", ["session": .string(s.id), "full": true]).json)

    let links = try #require(got["links"]?.array)
    #expect(links.compactMap { $0["url"]?.string } == [SlackExample.root])
    #expect(links.first?["kind"]?.string == "slack")
    #expect(links.first?["by"]?.string == "found")
    #expect(links.first?["thread"]?.string == SlackExample.rootTs)
  }

  @Test func listSessionsWithFullCarriesLinksOnTheRightSessionOnly() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    try sbd.postSlackSend(a.id, link: SlackExample.dm, channel: SlackExample.dmChannel, ts: SlackExample.replyTs)
    let mcp = try MCPClient(sbd)

    let listed = try #require(try mcp.call("list_sessions", ["full": true]).json?.array)

    let alpha = try #require(listed.first { $0["id"]?.string == a.id })
    let bravo = try #require(listed.first { $0["id"]?.string == b.id })
    #expect(alpha["links"]?.array?.compactMap { $0["url"]?.string } == [SlackExample.dm])
    #expect(bravo["links"] == nil)
  }

  @Test func theBriefFormsCarryNoLinks() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    let mcp = try MCPClient(sbd)

    let got = try #require(try mcp.call("get_session", ["session": .string(s.id)]).json)
    let listed = try #require(try mcp.call("list_sessions").json?.array)

    #expect(try sbd.sessionLinks(s.id) != nil)
    #expect(got["links"] == nil)
    #expect(!listed.isEmpty)
    #expect(listed.allSatisfy { $0["links"] == nil })
  }

  static let rfc = "https://example.com/rfcs/flag-evaluations"

  @Test func addLinkAddsToTheCallersSessionAsClaude() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let other = try sbd.new(name: "bravo")
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("add_link", ["url": .string(Self.rfc), "title": "Flag RFC"])

    #expect(!result.isError, "\(result.text)")
    let links = try #require(try sbd.sessionLinks(s.id))
    #expect(links.compactMap { $0["url"]?.string } == [Self.rfc])
    #expect(links.first?["by"]?.string == "claude")
    #expect(links.first?["title"]?.string == "Flag RFC")
    #expect(links.first?["id"]?.string?.hasPrefix("l") == true)
    #expect(try sbd.sessionLinks(other.id) == nil)
  }

  @Test func addLinkWithoutACallerIsAnError() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("add_link", ["url": .string(Self.rfc)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("add_link works only in a session that Switchboard started"), "\(result.text)")
    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  @Test func removeLinkWithoutACallerIsAnError() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    try sbd.sb("link", "add", s.id, Self.rfc, env: inside(s.id))
    let id = try #require(try sbd.sessionLinks(s.id)?.first?["id"]?.string)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("remove_link", ["link": .string(id)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("remove_link works only in a session that Switchboard started"), "\(result.text)")
    #expect(try sbd.sessionLinks(s.id)?.count == 1)
  }

  @Test func removeLinkRemovesClaudesLinkAndRefusesYours() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd, env: inside(s.id))
    _ = try mcp.call("add_link", ["url": "https://example.com/docs/cache-design"])
    try sbd.sb("link", "add", s.id, Self.rfc)
    let links = try #require(try sbd.sessionLinks(s.id))
    let claudes = try #require(links.first { $0["by"]?.string == "claude" }?["id"]?.string)
    let yours = try #require(links.first { $0["by"]?.string == "you" }?["id"]?.string)

    let refused = try mcp.call("remove_link", ["link": .string(yours)])
    let removed = try mcp.call("remove_link", ["link": .string(claudes)])

    #expect(refused.isError, "\(refused.text)")
    #expect(refused.text.contains("Only you can remove a link you added"), "\(refused.text)")
    #expect(!removed.isError, "\(removed.text)")
    #expect(try sbd.sessionLinks(s.id)?.compactMap { $0["id"]?.string } == [yours])
  }

  @Test func removeLinkRefusesAFoundLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    let before = try #require(try sbd.sessionLinks(s.id))
    let id = try #require(before.first?["id"]?.string)
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("remove_link", ["link": .string(id)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("Only you can hide a link that Switchboard found"), "\(result.text)")
    #expect(try sbd.sessionLinks(s.id) == before)
  }

  /// The tool reads no `session`, so an extra one never reaches another session.
  @Test func addLinkWithASessionArgumentNeverChangesThatSession() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let other = try sbd.new(name: "bravo")
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let named = try mcp.call("add_link", ["url": .string(Self.rfc), "session": .string(other.id)])
    let asOther = try mcp.call(
      "add_link",
      ["url": "https://example.com/docs/cache-design", "session": .string(other.id), "caller": .string(other.id)])

    #expect(!named.isError, "\(named.text)")
    #expect(!asOther.isError, "\(asOther.text)")
    #expect(
      try sbd.sessionLinks(s.id)?.compactMap { $0["url"]?.string }
        == [Self.rfc, "https://example.com/docs/cache-design"])
    #expect(try sbd.sessionLinks(other.id) == nil)
  }

  /// Both tools act on the caller's session, so neither can name another.
  @Test func theLinkToolsTakeNoSession() throws {
    let sbd = try Instance()
    let tools = try MCPClient(sbd).tools()

    for (name, required) in [("add_link", "url"), ("remove_link", "link")] {
      let tool = try #require(tools.first { $0["name"]?.string == name }, "\(name)")
      let properties = try #require(tool["inputSchema"]?["properties"]?.object)
      #expect(properties["session"] == nil, "\(name): \(properties.keys)")
      #expect(properties["caller"] == nil, "\(name): \(properties.keys)")
      #expect(properties[required] != nil, "\(name): \(properties.keys)")
      #expect(tool["inputSchema"]?["required"]?.array?.compactMap(\.string) == [required])
    }
  }

  @Test(arguments: [("list_sessions", "artifacts, and links"), ("get_session", "artifacts and links")])
  func theSessionToolsDescriptionsNameLinks(_ name: String, _ phrase: String) throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == name })

    #expect(tool["description"]?.string?.contains(phrase) == true, "\(tool["description"]?.string ?? "")")
  }
}
