import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct MCPServerTests {
  @Test func decodesWithDefaults() throws {
    let c = try JSONCoding.decode(
      Config.self,
      from: #"{"mcpServers": {"db": {"type": "sse", "command": "/bin/db", "args": ["--port", "{port}"]}}}"#)
    let db = try #require(c.mcpServers["db"])
    #expect(db.type == .sse)
    #expect(db.command == "/bin/db")
    #expect(db.args == ["--port", "{port}"])
    #expect(db.env.isEmpty)
    #expect(db.port == nil)
    #expect(try JSONCoding.decode(Config.self, from: "{}").mcpServers.isEmpty)
  }

  @Test func skipsAServerThatDoesntDecodeAndKeepsTheRestOfTheConfig() throws {
    let c = try JSONCoding.decode(
      Config.self,
      from: #"""
        {"env": {"CLAUDE_CONFIG_DIR": "/x"}, "mcpServers": {
          "db": {"type": "sse", "command": "/bin/db"},
          "fs": {"type": "stdio", "command": "/bin/fs"},
          "bare": {"command": "/bin/bare"}}}
        """#)
    #expect(c.env == ["CLAUDE_CONFIG_DIR": "/x"])
    #expect(Array(c.mcpServers.keys) == ["db"])
  }

  @Test func urlUsesTheTransportsPathUnlessOneIsSet() {
    #expect(MCPServer(type: .http, command: "x").url(port: 4100) == "http://127.0.0.1:4100/mcp")
    #expect(MCPServer(type: .sse, command: "x").url(port: 4100) == "http://127.0.0.1:4100/sse")
    #expect(MCPServer(type: .http, command: "x", path: "/rpc").url(port: 4100) == "http://127.0.0.1:4100/rpc")
  }

  @Test func commandLineFillsInThePortAndQuotes() {
    let server = MCPServer(
      type: .http, command: "~/bin/grafana", args: ["-address", "127.0.0.1:{port}", "it's"],
      env: ["REGION": "us", "BIN": "~/go/bin/x", "LISTEN": "{port}"])
    let home = NSHomeDirectory()
    #expect(
      server.commandLine(port: 4100)
        == "exec env 'BIN=\(home)/go/bin/x' 'LISTEN=4100' 'REGION=us' '\(home)/bin/grafana' '-address' '127.0.0.1:4100' 'it'\\''s'"
    )
    #expect(MCPServer(type: .sse, command: "/bin/db").commandLine(port: 1) == "exec '/bin/db'")
  }

  @Test func refusesAServerThatCantLearnItsPort() {
    let problems = MCPServer.problems([
      "none": MCPServer(type: .sse, command: "/bin/db"),
      "args": MCPServer(type: .sse, command: "/bin/db", args: ["{port}"]),
      "env": MCPServer(type: .sse, command: "/bin/db", env: ["PORT": "{port}"]),
      "fixed": MCPServer(type: .sse, command: "/bin/db", port: 4100),
    ])
    #expect(Array(problems.keys) == ["none"])
  }

  @Test func refusesAPortOutsideTheTCPRange() {
    let problems = MCPServer.problems([
      "zero": MCPServer(type: .sse, command: "x", port: 0), "big": MCPServer(type: .sse, command: "x", port: 80800),
      "negative": MCPServer(type: .sse, command: "x", port: -1),
      "top": MCPServer(type: .sse, command: "x", port: 65535),
    ])
    #expect(Set(problems.keys) == ["zero", "big", "negative"])
  }

  @Test func refusesASecondServerWithTheSameFixedPort() {
    let problems = MCPServer.problems([
      "a": MCPServer(type: .sse, command: "x", port: 4100), "b": MCPServer(type: .sse, command: "x", port: 4100),
      "c": MCPServer(type: .sse, command: "x", port: 4200),
    ])
    #expect(problems == ["b": "its port 4100 is also the port of a"])
  }

  @Test func refusesANameThatTmuxOrClaudeWouldChange() {
    let names = ["grafana-eu_2", "", "a.b", "a:b", "a b", "a/b"]
    let problems = MCPServer.problems(
      Dictionary(uniqueKeysWithValues: names.map { ($0, MCPServer(type: .sse, command: "x", args: ["{port}"])) }))
    #expect(Set(problems.keys) == Set(names.dropFirst()))
  }

  @Test func restartDelayDoublesUpToAMinute() {
    #expect((1...9).map(MCPServer.restartDelayMs) == [0, 1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000])
    #expect(MCPServer.restartDelayMs(exitsInARow: 1000) == 60000)
  }

  @Test func claudeConfigListsEachServersTypeAndURL() {
    let servers = ["a": MCPServer(type: .http, command: "x"), "b": MCPServer(type: .sse, command: "y")]
    let config = MCPServer.claudeConfig(servers, ports: ["a": 4100, "b": 4200])
    #expect(
      config
        == [
          "mcpServers": [
            "a": ["type": "http", "url": "http://127.0.0.1:4100/mcp"],
            "b": ["type": "sse", "url": "http://127.0.0.1:4200/sse"],
          ]
        ])
    #expect(MCPServer.ports(inClaudeConfig: config) == ["a": 4100, "b": 4200])
    #expect(MCPServer.ports(inClaudeConfig: ["mcpServers": ["c": ["url": "not a url"]]]).isEmpty)
  }

  @Test func assignsTheConfiguredPortThenThePreviousOneThenAFreeOne() {
    let servers = [
      "fixed": MCPServer(type: .http, command: "x", port: 4100),
      "kept": MCPServer(type: .http, command: "x", args: ["{port}"]),
      "new": MCPServer(type: .http, command: "x", args: ["{port}"]),
      // Its previous port is now another server's configured port.
      "moved": MCPServer(type: .http, command: "x", args: ["{port}"]),
      // canKeep refuses its previous port, as when another program holds it.
      "taken": MCPServer(type: .http, command: "x", args: ["{port}"]),
    ]
    var free = [4300, 4100, 4301, 4302].makeIterator()
    let ports = MCPServer.assignPorts(
      servers, previous: ["fixed": 4000, "kept": 4200, "moved": 4100, "taken": 4400],
      canKeep: { name, _ in name != "taken" }, freePort: { free.next() })
    #expect(ports == ["fixed": 4100, "kept": 4200, "moved": 4300, "new": 4301, "taken": 4302])
  }
}
