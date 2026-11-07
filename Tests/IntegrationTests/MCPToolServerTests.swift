import Foundation
import SwitchboardCore
import Testing

/// What a `tools/call` returned.
struct ToolResult {
  let isError: Bool
  let content: [JSON]

  var texts: [String] { content.compactMap { $0["text"]?.string } }
  var text: String { texts.joined(separator: "\n") }
  /// The first text that parses as JSON.
  var json: JSON? { texts.lazy.compactMap(JSON.parse).first }

  /// The JSON of a result that succeeded, as `type`.
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    guard !isError, let json else { throw TestError(description: "the tool failed: \(text)") }
    return try JSONCoding.convert(json, to: type)
  }
}

/// The lines that a process writes to one pipe.
final class Lines: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private var ended = false

  func read(_ handle: FileHandle) {
    handle.readabilityHandler = { [self] h in
      let data = h.availableData
      lock.withLock {
        if data.isEmpty { ended = true } else { buffer.append(data) }
      }
      if data.isEmpty { h.readabilityHandler = nil }
    }
  }

  /// Removes and returns the first whole line. `ended` is true once the pipe closed.
  func next() -> (line: String?, ended: Bool) {
    lock.withLock {
      guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return (nil, ended) }
      let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
      buffer.removeSubrange(buffer.startIndex...newline)
      return (line, ended)
    }
  }

  var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }
}

/// `sb mcp-server` in a process of its own. It writes one JSON-RPC message per
/// line to the server's stdin and reads one reply line per request. `init`
/// sends `initialize` and `notifications/initialized`, as Claude Code does.
final class MCPClient {
  /// A write to a server that exited fails with EPIPE instead of killing the test process.
  private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

  private let process = Process()
  private let input = Pipe()
  private let output = Lines()
  private let errors = Lines()
  private var nextId = 0
  /// The result of the `initialize` request.
  private(set) var initialized: JSON = .null

  /// Runs `sb mcp-server` against the instance's sbd.
  convenience init(_ sbd: Instance, group: String? = nil, env extra: [String: String] = [:], cwd: String? = nil)
    throws
  {
    let scope = group.map { ["--group", $0] } ?? []
    try self.init(command: "\(Instance.bin)/sb", args: ["mcp-server"] + scope, env: sbd.environment(extra), cwd: cwd)
  }

  /// Runs the server that an --mcp-config entry names, with its command,
  /// arguments, and environment, and none of the test process's sb variables.
  convenience init(server: JSON) throws {
    var env = ProcessInfo.processInfo.environment
    env["CLAUDECODE"] = nil
    env["SB_SESSION_ID"] = nil
    env["SB_HOME"] = nil
    for (key, value) in server["env"]?.object ?? [:] { env[key] = value.string }
    try self.init(
      command: try #require(server["command"]?.string), args: (server["args"]?.array ?? []).compactMap(\.string),
      env: env)
  }

  init(command: String, args: [String], env: [String: String], cwd: String? = nil) throws {
    _ = MCPClient.ignoreSIGPIPE
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.environment = env
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    process.standardInput = input
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    output.read(out.fileHandleForReading)
    errors.read(err.fileHandleForReading)
    try process.run()
    initialized = try result(
      "initialize",
      [
        "protocolVersion": "2025-06-18", "capabilities": [:],
        "clientInfo": ["name": "switchboard-tests", "version": "0"],
      ])
    try notify("notifications/initialized")
  }

  deinit {
    try? input.fileHandleForWriting.close()
    guard process.processIdentifier != 0 else { return }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
  }

  func send(_ message: JSON) throws { try sendLine(message.text) }

  func sendLine(_ line: String) throws {
    try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
  }

  /// The next line that the server writes. It throws when the server closes
  /// stdout or writes nothing for `timeout` seconds, so a hang fails the test.
  func readLine(timeout: Double = 30) throws -> String {
    let deadline = Date().addingTimeInterval(timeout * Instance.timeoutScale)
    while true {
      let (line, ended) = output.next()
      if let line { return line }
      if ended { throw TestError(description: "sb mcp-server closed stdout. stderr:\n\(errors.text)") }
      if Date() >= deadline {
        throw TestError(description: "sb mcp-server wrote no line in \(timeout) s. stderr:\n\(errors.text)")
      }
      usleep(10_000)
    }
  }

  /// Sends a request and returns the whole reply message.
  @discardableResult
  func request(_ method: String, _ params: JSON = [:], id: JSON? = nil) throws -> JSON {
    nextId += 1
    try send(["jsonrpc": "2.0", "id": id ?? .number(Double(nextId)), "method": .string(method), "params": params])
    let line = try readLine()
    guard let reply = JSON.parse(line) else { throw TestError(description: "the reply is not JSON: \(line)") }
    return reply
  }

  /// The reply's result. It throws on a JSON-RPC error.
  func result(_ method: String, _ params: JSON = [:]) throws -> JSON {
    let reply = try request(method, params)
    guard let result = reply["result"] else { throw TestError(description: "\(method) failed: \(reply.text)") }
    return result
  }

  func notify(_ method: String) throws {
    try send(["jsonrpc": "2.0", "method": .string(method)])
  }

  func tools() throws -> [JSON] { try result("tools/list")["tools"]?.array ?? [] }

  func toolNames() throws -> [String] { try tools().compactMap { $0["name"]?.string } }

  func call(_ tool: String, _ args: [String: JSON] = [:]) throws -> ToolResult {
    let result = try result("tools/call", ["name": .string(tool), "arguments": .object(args)])
    return ToolResult(isError: result["isError"]?.bool ?? false, content: result["content"]?.array ?? [])
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPToolServerTests {
  static let allTools: Set<String> = [
    "list_sessions", "get_session", "read_reply", "triage", "events", "send", "send_group", "spawn", "set_wait",
    "clear_wait", "add_note", "list_groups", "add_group", "remove_group", "move_to_group", "add_group_note",
    "suggest_groups", "plan_artifact",
  ]
  /// The tools that a scoped server leaves out.
  static let unscopedOnly: Set<String> = ["add_group", "remove_group", "suggest_groups"]
  static let hourMs: Int64 = 3600 * 1000

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  func addGroup(_ sbd: Instance, _ name: String, _ sessions: String...) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + sessions))
  }

  func groupList(_ sbd: Instance) throws -> GroupList { try decode(GroupList.self, sbd.sb("group", "ls", "--json")) }

  /// Arguments of a spawn on a new branch named `name` in a new repo.
  func spawnArgs(_ sbd: Instance, _ name: String) throws -> [String: JSON] {
    ["repository": .string(try sbd.makeRepo()), "branch": .string(name), "name": .string(name), "prompt": "hello"]
  }

  /// The text of each message that reached the session.
  func sent(_ sbd: Instance, _ id: String) throws -> [String] {
    try sbd.events(id).filter { $0.kind == "sent" }.compactMap { $0.data["text"]?.string }
  }

  /// A session whose first turn has ended with a reply.
  func idle(_ sbd: Instance, name: String) throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    return s
  }

  func triaged(_ sbd: Instance) throws -> [String] {
    try sbd.client.call("triage", as: [SessionSummary].self).map(\.id)
  }

  func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

  // MARK: Protocol

  @Test func initializeNamesTheServerAndSaysSessionTextIsData() throws {
    let sbd = try Instance()

    let mcp = try MCPClient(sbd)

    let result = mcp.initialized
    #expect(result["protocolVersion"]?.string?.isEmpty == false)
    #expect(result["capabilities"]?["tools"] != nil)
    #expect(result["serverInfo"]?["name"] == "switchboard")
    let instructions = try #require(result["instructions"]?.string)
    #expect(instructions.contains("data"))
    #expect(instructions.contains("not instructions"))
  }

  @Test func toolsListHasTheEighteenToolsByTheirExactNames() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let names = try mcp.toolNames()

    #expect(names.count == 18)
    #expect(Set(names) == MCPToolServerTests.allTools)
  }

  @Test func everyToolDescriptionSaysSessionTextIsData() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tools = try mcp.tools()

    #expect(!tools.isEmpty)
    for tool in tools {
      let name = tool["name"]?.string ?? "?"
      #expect(tool["description"]?.string?.contains("data") == true, "\(name)")
      #expect(tool["inputSchema"]?["type"] == "object", "\(name)")
    }
  }

  @Test(arguments: [JSON.number(41), JSON.string("ping-41")]) func aPingIsAnsweredWithItsOwnId(_ id: JSON) throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let reply = try mcp.request("ping", id: id)

    #expect(reply["jsonrpc"] == "2.0")
    #expect(reply["id"] == id)
    #expect(reply["result"] == [:])
  }

  @Test func anUnknownMethodGetsMethodNotFound() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let reply = try mcp.request("resources/list", id: 9)

    #expect(reply["id"] == 9)
    #expect(reply["result"] == nil)
    #expect(reply["error"]?["code"] == -32601)
  }

  @Test func aCallToAnUnknownToolGetsInvalidParams() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let reply = try mcp.request("tools/call", ["name": "nosuch", "arguments": [:]], id: 5)

    #expect(reply["id"] == 5)
    #expect(reply["result"] == nil)
    #expect(reply["error"]?["code"] == -32602)
  }

  @Test func aLineThatIsNotJSONGetsAParseErrorWithANullId() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    try mcp.sendLine("not json")
    let reply = try #require(JSON.parse(try mcp.readLine()))

    #expect(reply["id"] == JSON.null)
    #expect(reply["error"]?["code"] == -32700)
    #expect(try mcp.toolNames().count == MCPToolServerTests.allTools.count)
  }

  @Test(arguments: ["notifications/initialized", "notifications/cancelled", "nothing/known"])
  func aNotificationGetsNoReply(_ method: String) throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    try mcp.notify(method)
    let reply = try mcp.request("ping", id: 77)

    #expect(reply["id"] == 77)
  }

  @Test func aToolResultIsTextThatHoldsTheJSONThatSbPrints() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try sbd.new(name: "loose")
    _ = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("list_groups")

    #expect(!result.isError)
    #expect(result.content.first?["type"] == "text")
    #expect(result.json == JSON.parse(try sbd.sb("group", "ls", "--json")))
  }

  @Test func aToolThatNamesAnUnknownSessionReturnsSbdsError() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("get_session", ["session": "nosuch"])

    #expect(result.isError)
    #expect(result.text.contains("no session nosuch"))
  }

  // MARK: Session tools

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

  // MARK: Group tools

  @Test func addGroupCreatesAGroupWithItsSessionsAndNote() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let g = try mcp.call(
      "add_group", ["name": "Flags", "sessions": [.string(a.id)], "note": "Ship by Friday"]
    ).decode(GroupSummary.self)

    #expect(g.name == "Flags")
    #expect(g.sessions == [a.id])
    #expect(g.notes.map(\.text) == ["Ship by Friday"])
    #expect(try sbd.get(a.id).group == g.id)
  }

  @Test func listGroupsReturnsTheGroupList() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let loose = try sbd.new(name: "loose")
    let g = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd)

    let groups = try mcp.call("list_groups").decode(GroupList.self)

    #expect(groups.groups.map(\.id) == [g.id])
    #expect(groups.ungrouped == [loose.id])
  }

  @Test func moveToGroupMovesSessionsInAndOut() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try addGroup(sbd, "Flags")
    let mcp = try MCPClient(sbd)

    let moved = try mcp.call("move_to_group", ["sessions": [.string(a.id)], "group": "Flags"]).decode(
      [SessionSummary].self)
    let out = try mcp.call("move_to_group", ["sessions": [.string(a.id)], "ungrouped": true]).decode(
      [SessionSummary].self)

    #expect(moved.map(\.group) == [g.id])
    #expect(out.map(\.group) == [nil])
    #expect(try sbd.get(a.id).group == nil)
  }

  @Test func addGroupNoteAddsANoteToTheGroup() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let mcp = try MCPClient(sbd)

    let noted = try mcp.call("add_group_note", ["group": "Flags", "text": "Ask Ana first."]).decode(
      GroupSummary.self)

    #expect(noted.id == g.id)
    #expect(try groupList(sbd).groups.first?.notes.map(\.text) == ["Ask Ana first."])
  }

  @Test func removeGroupDeletesTheGroupAndLeavesItsMembersUngrouped() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd)

    let removed = try mcp.call("remove_group", ["group": "Flags"])

    #expect(!removed.isError)
    #expect(removed.json?["removed"]?.string == g.id)
    #expect(try groupList(sbd).groups.isEmpty)
    #expect(try sbd.get(a.id).group == nil)
  }

  @Test func suggestGroupsListsTheSuggestionsAndAcceptCreatesTheGroup() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let a = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "haacked/flag-evaluations-cache"], as: SessionSummary.self)
    let b = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "haacked/flag-evaluations-perf"], as: SessionSummary.self)
    let mcp = try MCPClient(sbd)

    let found = try mcp.call("suggest_groups").decode([GroupSuggestion].self)
    let first = try #require(found.first)
    let accepted = try mcp.call("suggest_groups", ["accept": .string(first.id)]).decode(GroupSummary.self)

    #expect(Set(first.sessions) == [a.id, b.id])
    #expect(Set(accepted.sessions) == [a.id, b.id])
    #expect(try sbd.get(a.id).group == accepted.id)
  }

  // MARK: send_group

  /// The id of the card that a `send_group` call with text opens.
  func openPending(_ mcp: MCPClient, _ args: [String: JSON] = ["group": "Flags", "text": "Rebase on main."]) throws
    -> Int64
  {
    try #require(try mcp.call("send_group", args).decode(GroupSend.self).pending)
  }

  func answer(_ sbd: Instance, _ session: String, _ card: Int64, allow: Bool) throws {
    _ = try sbd.client.call(
      "answer",
      ["session": .string(session), "card": .number(Double(card)), "behavior": .string(allow ? "allow" : "deny")])
  }

  @Test func sendGroupOpensAPendingCardAndSendsNothing() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try addGroup(sbd, "Flags", a.id, b.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."])

    let pending = try result.decode(GroupSend.self)
    #expect(pending.group == g.id)
    #expect(!pending.sent)
    #expect(pending.decision == .pending)
    #expect(Set(pending.targets.map(\.id)) == [a.id, b.id])
    #expect(Set(pending.targets.map(\.name)) == ["alpha", "bravo"])
    let card = try #require(pending.pending)
    #expect(try sbd.get(caller.id).cards.map(\.id) == [card])
    #expect(try sbd.get(caller.id).cards.map(\.kind) == [.send])
    #expect(try sent(sbd, a.id).isEmpty)
    #expect(try sent(sbd, b.id).isEmpty)
  }

  @Test func sendGroupTellsClaudeHowToReadTheDecision() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."])

    let instruction = try #require(result.json?["instruction"]?.string)
    #expect(instruction.contains("Switchboard"))
    #expect(instruction.contains("pending"))
  }

  @Test func sendGroupWithPendingReportsPendingBeforeADecision() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))
    let card = try openPending(mcp)

    let result = try mcp.call("send_group", ["pending": .number(Double(card)), "timeout": 0]).decode(GroupSend.self)

    #expect(result.pending == card)
    #expect(result.decision == .pending)
    #expect(!result.sent)
  }

  @Test(arguments: [true, false]) func sendGroupWithPendingReportsTheDecisionAfterAnAnswer(allow: Bool) throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try addGroup(sbd, "Flags", a.id, b.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))
    let card = try openPending(mcp)
    try answer(sbd, caller.id, card, allow: allow)

    let result = try mcp.call("send_group", ["pending": .number(Double(card)), "timeout": 0]).decode(GroupSend.self)

    #expect(result.decision == (allow ? .sent : .cancelled))
    #expect(result.sent == allow)
    #expect(Set((result.deliveries ?? []).map(\.session)) == (allow ? [a.id, b.id] : []))
    #expect(try sent(sbd, a.id) == (allow ? ["Rebase on main."] : []))
    #expect(try sent(sbd, b.id) == (allow ? ["Rebase on main."] : []))
  }

  /// The SB_SESSION_ID of a server that has no calling session.
  enum NoCaller: CaseIterable { case unset, empty, unknown }

  @Test(arguments: NoCaller.allCases) func sendGroupWithoutACallingSessionRefuses(_ caller: NoCaller) throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", a.id)
    let env: [String: String] =
      switch caller {
      case .unset: [:]
      case .empty: ["SB_SESSION_ID": "", "CLAUDECODE": "1"]
      case .unknown: inside("snope1")
      }
    let mcp = try MCPClient(sbd, env: env)

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."])

    #expect(result.isError)
    #expect(try sbd.cards().isEmpty)
    #expect(try sent(sbd, a.id).isEmpty)
  }

  /// The `targets` that the old confirmation step passed.
  enum OldTargets: CaseIterable { case listed, empty, withTheCaller }

  @Test(arguments: OldTargets.allCases) func sendGroupWithTargetsSendsNothing(_ shape: OldTargets) throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", caller.id, a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))
    let targets: [JSON] =
      switch shape {
      case .listed: [.string(a.id)]
      case .empty: []
      case .withTheCaller: [.string(caller.id), .string(a.id)]
      }

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main.", "targets": .array(targets)])

    #expect(result.isError || (try? result.decode(GroupSend.self))?.sent == false)
    #expect(try sent(sbd, a.id).isEmpty)
    #expect(try sent(sbd, caller.id).isEmpty)
  }

  @Test func sendGroupsSchemaTakesPendingAndNotTargets() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "send_group" })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["pending"] != nil)
    #expect(properties["timeout"] != nil)
    #expect(properties["text"] != nil)
    #expect(properties["targets"] == nil)
  }

  @Test func sendGroupLeavesOutTheCaller() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", caller.id, a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let pending = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."]).decode(GroupSend.self)
    try answer(sbd, caller.id, try #require(pending.pending), allow: true)

    #expect(pending.targets.map(\.id) == [a.id])
    #expect(try sent(sbd, a.id) == ["Rebase on main."])
    #expect(try sent(sbd, caller.id).isEmpty)
  }

  // MARK: Group scope

  /// Flags holds `member`. Billing holds `outside`. `loose` is in no group.
  struct Scope {
    let group: GroupSummary
    let other: GroupSummary
    let member: SessionSummary
    let outside: SessionSummary
    let loose: SessionSummary
  }

  func scope(_ sbd: Instance) throws -> Scope {
    let member = try sbd.new(name: "member")
    let outside = try sbd.new(name: "outside")
    let loose = try sbd.new(name: "loose")
    return Scope(
      group: try addGroup(sbd, "Flags", member.id), other: try addGroup(sbd, "Billing", outside.id), member: member,
      outside: outside, loose: loose)
  }

  /// How a command can name a session or a group: its id, a prefix of its id, or its name.
  enum Naming: CaseIterable { case id, idPrefix, name }

  func name(_ id: String, _ name: String, _ how: Naming) -> String {
    switch how {
    case .id: id
    case .idPrefix: String(id.prefix(4))
    case .name: name
    }
  }

  @Test(arguments: Naming.allCases) func aScopeNamesItsGroupByIdIdPrefixOrName(_ how: Naming) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: name(s.group.id, s.group.name, how))

    let groups = try mcp.call("list_groups").decode(GroupList.self)

    #expect(groups.groups.map(\.id) == [s.group.id])
  }

  /// A scope that names no group, and one that names two.
  enum BadScope: CaseIterable { case unknown, sharedPrefix }

  @Test(arguments: BadScope.allCases) func aScopeThatNamesNoSingleGroupListsNoSessions(_ bad: BadScope) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let key = bad == .unknown ? "Nowhere" : s.group.id.commonPrefix(with: s.other.id)

    let result = try? MCPClient(sbd, group: key).call("list_sessions")

    #expect(result == nil || result?.isError == true)
  }

  @Test(arguments: Naming.allCases) func aScopedGetSessionRefusesAnOutsideSessionHoweverItIsNamed(_ how: Naming)
    throws
  {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("get_session", ["session": .string(name(s.outside.id, s.outside.name, how))])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
  }

  @Test func aScopedGetSessionRefusesAnUngroupedSession() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("get_session", ["session": .string(s.loose.id)])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
  }

  @Test func aScopedGetSessionReturnsAMember() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let got = try mcp.call("get_session", ["session": .string(s.member.name)]).decode(SessionSummary.self)

    #expect(got.id == s.member.id)
  }

  @Test func aScopedSendReachesAMemberNamedByName() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("send", ["session": .string(s.member.name), "text": "Rebase on main."])

    #expect(!result.isError)
    #expect(try sent(sbd, s.member.id) == ["Rebase on main."])
  }

  @Test func aScopedServerRefusesASessionThatLeftTheGroupAfterItStarted() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)
    try sbd.sb("group", "move", s.member.id, "--ungrouped")

    let result = try mcp.call("send", ["session": .string(s.member.id), "text": "hi"])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
    #expect(try sent(sbd, s.member.id).isEmpty)
  }

  @Test func aScopedServerFailsOnceItsGroupIsRemoved() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)
    try sbd.sb("group", "rm", s.group.id)

    let result = try mcp.call("list_sessions")

    #expect(result.isError)
    #expect(result.text.contains("is gone"))
  }

  /// Each tool that names a session, with arguments that name `session`.
  enum SessionTool: String, CaseIterable {
    case getSession = "get_session"
    case readReply = "read_reply"
    case events
    case send
    case setWait = "set_wait"
    case clearWait = "clear_wait"
    case addNote = "add_note"
    case moveToGroup = "move_to_group"

    func args(_ session: String) -> [String: JSON] {
      switch self {
      case .getSession, .readReply, .events, .clearWait: ["session": .string(session)]
      case .send, .addNote: ["session": .string(session), "text": "Rebase on main."]
      case .setWait: ["session": .string(session), "note": "CI on #12"]
      case .moveToGroup: ["sessions": [.string(session)], "ungrouped": true]
      }
    }
  }

  @Test(arguments: SessionTool.allCases) func aScopedToolRefusesAnOutsideSessionAndLeavesItAlone(_ tool: SessionTool)
    throws
  {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(tool.rawValue, tool.args(s.outside.id))

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
    let after = try sbd.get(s.outside.id)
    #expect(after.group == s.other.id)
    #expect(after.notes.isEmpty)
    #expect(after.waits.isEmpty)
    #expect(try sent(sbd, s.outside.id).isEmpty)
  }

  @Test func aScopedMoveRefusesAListThatHoldsAnOutsideSession() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(
      "move_to_group", ["sessions": [.string(s.member.id), .string(s.outside.id)], "ungrouped": true])

    #expect(result.isError)
    #expect(try sbd.get(s.member.id).group == s.group.id)
    #expect(try sbd.get(s.outside.id).group == s.other.id)
  }

  @Test func aScopedMoveMovesAMemberToUngrouped() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let moved = try mcp.call("move_to_group", ["sessions": [.string(s.member.id)], "ungrouped": true]).decode(
      [SessionSummary].self)

    #expect(moved.map(\.group) == [nil])
    #expect(try sbd.get(s.member.id).group == nil)
  }

  @Test func aScopedMoveRefusesToMoveAMemberIntoAnotherGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("move_to_group", ["sessions": [.string(s.member.id)], "group": .string(s.other.id)])

    #expect(result.isError)
    #expect(try sbd.get(s.member.id).group == s.group.id)
  }

  @Test func aScopedListSessionsReturnsOnlyTheGroupsSessions() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let listed = try mcp.call("list_sessions").decode([SessionSummary].self)

    #expect(listed.map(\.id) == [s.member.id])
  }

  @Test func aScopedEventsReturnsOnlyTheGroupsEvents() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    try sbd.sb("send", s.member.id, "inside")
    try sbd.sb("send", s.outside.id, "outside")
    try sbd.sb("send", s.loose.id, "loose")
    let mcp = try MCPClient(sbd, group: s.group.id)

    let events = try mcp.call("events", ["since": 0, "limit": 10_000]).decode([Event].self)

    #expect(events.contains { $0.session == s.member.id && $0.kind == "sent" })
    #expect(events.allSatisfy { $0.session == s.member.id })
  }

  @Test func aScopedEventsMergesTheMembersAndKeepsTheOldestOrTheNewest() throws {
    let sbd = try Instance()
    // Idle sessions and notes, which sbd records before it answers, keep
    // events from arriving between the server's reads of each member.
    let first = try idle(sbd, name: "first")
    let second = try idle(sbd, name: "second")
    let outside = try idle(sbd, name: "outside")
    let group = try addGroup(sbd, "Flags", first.id, second.id)
    for text in ["one", "two"] {
      try sbd.sb("note", first.id, text)
      try sbd.sb("note", second.id, text)
    }
    try sbd.sb("note", outside.id, "outside")
    let mcp = try MCPClient(sbd, group: group.id)

    let all = try mcp.call("events", ["since": 0, "limit": 10_000]).decode([Event].self)
    let oldest = try mcp.call("events", ["since": 0, "limit": 2]).decode([Event].self)
    let newest = try mcp.call("events", ["limit": 2]).decode([Event].self)
    let groupIDs = try (sbd.events(first.id) + sbd.events(second.id)).map(\.id).sorted()

    #expect(Set(all.map(\.session)) == [first.id, second.id])
    #expect(all.map(\.id) == all.map(\.id).sorted())
    #expect(oldest.map(\.id) == Array(groupIDs.prefix(2)))
    #expect(newest.map(\.id) == Array(groupIDs.suffix(2)))
  }

  @Test(arguments: [false, true]) func aScopedEventsReadsANegativeLimitAsNoLimit(_ withSince: Bool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    try sbd.sb("send", s.member.id, "inside")
    let mcp = try MCPClient(sbd, group: s.group.id)
    var args: [String: JSON] = ["limit": -1]
    if withSince { args["since"] = 0 }

    let events = try mcp.call("events", args).decode([Event].self)

    #expect(events.contains { $0.session == s.member.id && $0.kind == "sent" })
  }

  @Test func aScopedTriageReturnsOnlyTheGroupsSessions() throws {
    let sbd = try Instance()
    let member = try idle(sbd, name: "member")
    let outside = try idle(sbd, name: "outside")
    let g = try addGroup(sbd, "Flags", member.id)
    try sbd.waitFor("both in triage", fetch: { try triaged(sbd) }) { Set($0) == [member.id, outside.id] }
    let mcp = try MCPClient(sbd, group: g.id)

    let listed = try mcp.call("triage").decode([SessionSummary].self)

    #expect(listed.map(\.id) == [member.id])
  }

  @Test func aScopedToolsListLeavesOutTheToolsThatSpanGroups() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let names = try mcp.toolNames()

    #expect(names.count == 15)
    #expect(Set(names) == MCPToolServerTests.allTools.subtracting(MCPToolServerTests.unscopedOnly))
  }

  /// The tools that a scope leaves out, with arguments that would succeed without one.
  enum GroupWideTool: String, CaseIterable {
    case addGroup = "add_group"
    case removeGroup = "remove_group"
    case suggestGroups = "suggest_groups"

    func args(_ s: Scope) -> [String: JSON] {
      switch self {
      case .addGroup: ["name": "Fresh", "sessions": [.string(s.member.id)]]
      case .removeGroup: ["group": .string(s.group.id)]
      case .suggestGroups: [:]
      }
    }
  }

  @Test(arguments: GroupWideTool.allCases) func aScopedServerRefusesAToolThatSpansGroups(_ tool: GroupWideTool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let before = try groupList(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(tool.rawValue, tool.args(s))

    #expect(result.isError)
    #expect(try groupList(sbd) == before)
  }

  @Test func aScopedSpawnLandsInTheGroupEvenWhenTheCallerIsInAnother() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.outside.id))

    let kid = try mcp.call("spawn", try spawnArgs(sbd, "kid")).decode(SessionSummary.self)

    #expect(kid.parent == s.outside.id)
    #expect(try sbd.get(kid.id).group == s.group.id)
  }

  @Test func aScopedSpawnWithoutACallerLandsInTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let kid = try mcp.call("spawn", try spawnArgs(sbd, "kid")).decode(SessionSummary.self)

    #expect(try sbd.get(kid.id).group == s.group.id)
  }

  @Test func aSpawnThatNamesAnUnknownGroupMakesNoWorktree() throws {
    let sbd = try Instance()
    var args = try spawnArgs(sbd, "kid")
    args["group"] = "nosuch"
    let repo = try #require(args["repository"]?.string)

    #expect(throws: (any Error).self) { try sbd.client.call("spawn", args) }

    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.git(repo, "branch", "--list", "kid").isEmpty)
    #expect(try sbd.git(repo, "worktree", "list").split(separator: "\n").count == 1)
  }

  @Test func aScopedFollowupSpawnLandsInTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.outside.id))
    // A follow-up keeps the repo's owner/name, so the repo needs a github.com remote.
    let repo = try Repos.create("\(sbd.home.path)/widgets", origin: "https://github.com/acme/widgets.git")
    let args: [String: JSON] = [
      "repository": .string(repo), "branch": "later", "prompt": "Clean up.", "followup": true,
    ]

    let later = try mcp.call("spawn", args).decode(SessionSummary.self)

    #expect(later.state == AttentionState.notStarted)
    #expect(later.parent == s.outside.id)
    #expect(try sbd.client.call("get", ["session": .string(later.id)], as: SessionSummary.self).group == s.group.id)
  }

  @Test func aScopedListGroupsReturnsOnlyTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let groups = try mcp.call("list_groups").decode(GroupList.self)

    #expect(groups.groups.map(\.id) == [s.group.id])
    #expect(!groups.ungrouped.contains(s.loose.id))
    #expect(!groups.ungrouped.contains(s.outside.id))
  }

  @Test func aScopedSendGroupDefaultsToTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.loose.id))

    let pending = try mcp.call("send_group", ["text": "Rebase on main."]).decode(GroupSend.self)

    #expect(pending.group == s.group.id)
    #expect(pending.targets.map(\.id) == [s.member.id])
    #expect(pending.pending != nil)
    #expect(!pending.sent)
    #expect(try sent(sbd, s.member.id).isEmpty)
    #expect(try sent(sbd, s.outside.id).isEmpty)
  }

  @Test(arguments: [false, true]) func aScopedSendGroupRefusesAnotherGroup(withTargets: Bool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.loose.id))
    var args: [String: JSON] = ["group": .string(s.other.name), "text": "Rebase on main."]
    if withTargets { args["targets"] = [.string(s.outside.id)] }

    let result = try mcp.call("send_group", args)

    #expect(result.isError)
    #expect(try sbd.cards().isEmpty)
    #expect(try sent(sbd, s.outside.id).isEmpty)
  }

  @Test func aScopedSendGroupRefusesToReadAnotherGroupsMessage() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let card = try openPending(
      MCPClient(sbd, env: inside(s.loose.id)), ["group": .string(s.other.name), "text": "Rebase on main."])
    let scoped = try MCPClient(sbd, group: s.group.id, env: inside(s.loose.id))

    let result = try scoped.call("send_group", ["pending": .number(Double(card)), "timeout": 0])

    #expect(result.isError)
    #expect(result.json?["targets"] == nil)
  }

  @Test func aScopedAddGroupNoteDefaultsToTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let noted = try mcp.call("add_group_note", ["text": "Ask Ana first."]).decode(GroupSummary.self)

    #expect(noted.id == s.group.id)
    #expect(noted.notes.map(\.text) == ["Ask Ana first."])
  }

  @Test(arguments: Naming.allCases) func aScopedAddGroupNoteRefusesAnotherGroup(_ how: Naming) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(
      "add_group_note", ["group": .string(name(s.other.id, s.other.name, how)), "text": "Ask Ana first."])

    #expect(result.isError)
    #expect(try groupList(sbd).groups.first { $0.id == s.other.id }?.notes.isEmpty == true)
  }

  @Test func aScopedSetWaitWithoutASessionWaitsOnACallerOutsideTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.outside.id))

    let waiting = try mcp.call("set_wait", ["note": "CI on #12"]).decode(SessionSummary.self)

    #expect(waiting.id == s.outside.id)
    #expect(try sbd.get(s.outside.id).waits.map(\.by) == [.claude])
  }

  @Test func aScopedSetWaitRefusesATargetOutsideTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(
      "set_wait", ["session": .string(s.member.id), "kind": "session", "target": .string(s.outside.name)])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
    #expect(try sbd.get(s.member.id).waits.isEmpty)
  }

  @Test func aScopedSetWaitWaitsOnAMemberTargetNamedByName() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let peer = try sbd.new(name: "peer")
    try sbd.sb("group", "move", peer.id, "--to", s.group.id)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("set_wait", ["session": .string(s.member.id), "kind": "session", "target": "peer"])

    #expect(!result.isError)
    #expect(try sbd.get(s.member.id).waits.compactMap(\.session?.id) == [peer.id])
  }

  // MARK: The Manager's registration

  /// The --mcp-config that the Manager's claude got at its launch.
  func managerConfig(_ sbd: Instance) throws -> JSON {
    let m = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    try sbd.waitFor(m.id, "the stub") { $0.live }
    let launch = try #require(sbd.stubArgs().first { $0.contains(m.claudeSessionId) })
    return try #require(MCPToolServerTests.switchboardConfig(in: launch))
  }

  /// The JSON object after `--mcp-config ` that names the switchboard server.
  /// The stub joins its arguments with spaces. The config is compact JSON
  /// with no braces in its strings.
  static func switchboardConfig(in launch: String) -> JSON? {
    guard let start = launch.range(of: #"--mcp-config {"mcpServers":{"switchboard""#) else { return nil }
    let text = launch[launch.index(start.lowerBound, offsetBy: "--mcp-config ".count)...]
    var depth = 0
    for i in text.indices {
      if text[i] == "{" { depth += 1 }
      if text[i] == "}" { depth -= 1 }
      if depth == 0 { return JSON.parse(String(text[...i])) }
    }
    return nil
  }

  @Test func managerConfigListsOneStdioServerThatRunsSbAgainstThisHome() throws {
    let sbd = try Instance()

    let config = try managerConfig(sbd)
    let m = try decode(SessionSummary.self, sbd.sb("get", "--json", "Manager"))

    let servers = try #require(config["mcpServers"]?.object)
    #expect(servers.keys.sorted() == ["switchboard"])
    let server = try #require(servers["switchboard"])
    #expect(server["type"] == nil || server["type"] == "stdio")
    #expect(server["command"]?.string.map(resolved) == resolved("\(Instance.bin)/sb"))
    #expect(server["args"] == ["mcp-server"])
    #expect(server["env"]?["SB_HOME"]?.string.map(resolved) == resolved(sbd.home.path))
    #expect(server["env"]?["SB_SESSION_ID"]?.string == m.id)
  }

  @Test func theServerThatManagerConfigNamesListsThisHomesSessions() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(server: try #require(try managerConfig(sbd)["mcpServers"]?["switchboard"]))

    let listed = try mcp.call("list_sessions").decode([SessionSummary].self)

    #expect(listed.contains { $0.id == s.id })
  }
}
