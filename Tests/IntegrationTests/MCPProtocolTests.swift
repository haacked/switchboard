import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPProtocolTests: MCPToolServerSuite {
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

  // MARK: The Manager's registration

  func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

  /// The --mcp-config that the Manager's claude got at its launch.
  func managerConfig(_ sbd: Instance) throws -> JSON {
    let m = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    try sbd.waitFor(m.id, "the stub") { $0.live }
    let launch = try #require(sbd.stubArgs().first { $0.contains(m.claudeSessionId) })
    return try #require(MCPToolServerTests.switchboardConfig(in: launch))
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
