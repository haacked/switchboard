import Foundation
import SwitchboardCore
import Testing

extension Instance {
  static let mcpStub = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/mcp-stub").path

  /// A config.json entry that runs Fixtures/mcp-stub.
  static func stubServer(_ name: String, type: String = "http", delay: Double? = nil) -> JSON {
    var args: [JSON] = [.string(name), "{port}"]
    if let delay { args += ["--delay", .string("\(delay)")] }
    return ["type": .string(type), "command": .string(mcpStub), "args": .array(args)]
  }

  func mcpServers() throws -> [MCPServerStatus] { try client.call("mcp", as: [MCPServerStatus].self) }

  /// Waits for the server to match, and returns it.
  @discardableResult
  func waitForServer(_ name: String, _ what: String, timeout: Double = 15, _ match: (MCPServerStatus) -> Bool) throws
    -> MCPServerStatus
  {
    try waitFor(what, timeout: timeout, fetch: { try mcpServers().first { $0.name == name } }, until: match)
  }

  /// Stops the session's claude and waits for tmux to show its pane dead,
  /// which comes a moment after the session stops being live. A server
  /// killed after this restarts in a tick whose snapshot has the dead pane.
  func stopClaude(_ id: String) throws {
    try sb("stop", id)
    let tmux = try #require(findExecutable("tmux"))
    try waitFor("the Claude pane to die") {
      try runCommand(tmux, ["-S", home.tmuxSocket, "display", "-p", "-t", "=\(id)-claude:", "#{pane_dead}"]).stdout
        == "1\n"
    }
  }

  func waitForRunning(_ name: String) throws -> MCPServerStatus {
    try waitForServer(name, "\(name) to accept connections") { $0.state == .running && $0.pid != nil }
  }

  /// Replaces mcpServers in config.json, which sbd reads when it starts.
  func setMCPServers(_ servers: JSON) throws {
    var config = JSON.parse(try String(contentsOfFile: home.config, encoding: .utf8))?.object ?? [:]
    config["mcpServers"] = servers
    try JSON.object(config).text.write(toFile: home.config, atomically: true, encoding: .utf8)
  }
}

@Suite(.timeLimit(.minutes(2))) struct MCPTests {
  @Test func sessionsReachTheSharedServersOverHTTPAndSSE() throws {
    let sbd = try Instance(config: [
      "mcpServers": [
        "grafana": Instance.stubServer("grafana"), "posthog-db": Instance.stubServer("posthog-db", type: "sse"),
      ]
    ])
    let s = try sbd.new(prompt: "mcp grafana")
    let grafana = try sbd.waitForRunning("grafana")
    try sbd.waitFor(s.id, "the call to grafana") { $0.lastReply == "MCP grafana: grafana \(grafana.pid!)" }
    #expect(
      sbd.stubArgs().first
        == "--session-id \(s.claudeSessionId) --settings \(sbd.home.claudeSettings) --mcp-config \(sbd.home.mcpConfig) -- mcp grafana"
    )
    #expect(try sbd.events(s.id).first { $0.kind == "started" }?.data["mcp"] == ["grafana", "posthog-db"])

    try sbd.sb("send", s.id, "mcp posthog-db")
    let db = try sbd.waitForRunning("posthog-db")
    try sbd.waitFor(s.id, "the call to posthog-db") { $0.lastReply == "MCP posthog-db: posthog-db \(db.pid!)" }
    #expect(grafana.type == .http && grafana.url.hasSuffix("/mcp"))
    #expect(db.type == .sse && db.url.hasSuffix("/sse"))
    let config = JSON.parse(try String(contentsOfFile: sbd.home.mcpConfig, encoding: .utf8))
    #expect(config?["mcpServers"]?["posthog-db"] == ["type": "sse", "url": .string(db.url)])
    #expect(try sbd.sb("mcp").contains("posthog-db"))
    #expect(
      try JSONCoding.decode([MCPServerStatus].self, from: sbd.sb("mcp", "--json")).map(\.name) == [
        "grafana", "posthog-db",
      ])
  }

  @Test func aLaunchWaitsForAServerThatIsStarting() throws {
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", delay: 1.5)]])
    let s = try sbd.new(prompt: "mcp slow")
    try sbd.waitFor(s.id, "the call to slow") { $0.lastReply?.hasPrefix("MCP slow: slow ") == true }
    #expect(try sbd.events(s.id).first { $0.kind == "started" }?.data["mcp"] == ["slow"])
  }

  @Test func aSendToALiveSessionDoesNotWaitForAStartingServer() throws {
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", delay: 4)]])
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    let slow = try sbd.waitForRunning("slow")
    kill(pid_t(slow.pid!), SIGKILL)
    try sbd.waitForServer("slow", "the restarted server") { $0.state == .starting && $0.restarts == 1 }
    let start = Date()
    try sbd.sb("send", s.id, "while it starts")
    #expect(Date().timeIntervalSince(start) < 2)
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: while it starts" }
  }

  @Test func aSendThatResumesASessionWaitsForAStartingServer() throws {
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", delay: 3)]])
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    let slow = try sbd.waitForRunning("slow")
    try sbd.stopClaude(s.id)
    kill(pid_t(slow.pid!), SIGKILL)
    try sbd.waitForServer("slow", "the restarted server") { $0.state == .starting && $0.restarts == 1 }
    try sbd.sb("send", s.id, "mcp slow")
    let restarted = try sbd.waitForRunning("slow")
    try sbd.waitFor(s.id, "the call to slow") { $0.lastReply == "MCP slow: slow \(restarted.pid!)" }
    #expect(try sbd.events(s.id).last { $0.kind == "resumed" }?.data["mcp"] == ["slow"])
  }

  @Test func aWaitThatResumesASessionWaitsForAStartingServer() throws {
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", delay: 3)]])
    let a = try sbd.new(prompt: "hello", name: "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    try sbd.waitFor(a.id, "a's first reply") { $0.lastReply == "Done: hello" }
    try sbd.waitFor(b.id, "b's first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b")
    try sbd.waitFor(a.id, "the stop", timeout: 10) { !$0.live }
    let slow = try sbd.waitForRunning("slow")
    kill(pid_t(slow.pid!), SIGKILL)
    try sbd.waitForServer("slow", "the restarted server") { $0.state == .starting && $0.restarts == 1 }
    // `done` doesn't launch claude itself. The tick resolves the wait and launches it.
    try sbd.sb("done", b.id)
    try sbd.waitFor(a.id, "the resumed turn") { $0.lastReply == "Done: Switchboard: b to reach Done: it did." }
    #expect(try sbd.events(a.id).last { $0.kind == "resumed" }?.data["mcp"] == ["slow"])
  }

  @Test func aLaunchStopsWaitingForAServerThatStartedMoreThanTenSecondsAgo() throws {
    let sbd = try Instance(config: ["mcpServers": ["stuck": Instance.stubServer("stuck", delay: 60)]])
    try sbd.waitForServer("stuck", "the server to start") { $0.state == .starting }
    try sbd.advanceClock(11_000)
    let start = Date()
    let s = try sbd.new(prompt: "hello")
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(try sbd.events(s.id).first { $0.kind == "started" }?.data["mcp"] == [])
  }

  @Test func terminalsDoNotWaitForAStartingServerWhenTheyLeaveClaudeStopped() throws {
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", delay: 4)]])
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    let slow = try sbd.waitForRunning("slow")
    try sbd.stopClaude(s.id)
    kill(pid_t(slow.pid!), SIGKILL)
    try sbd.waitForServer("slow", "the restarted server") { $0.state == .starting && $0.restarts == 1 }
    let start = Date()
    _ = try sbd.client.terminals(s.id)
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(try !sbd.get(s.id).live)
  }

  @Test func restartsAServerThatExitsOnTheSamePort() throws {
    let sbd = try Instance(config: ["mcpServers": ["grafana": Instance.stubServer("grafana")]])
    let first = try sbd.waitForRunning("grafana")
    kill(pid_t(first.pid!), SIGKILL)
    let second = try sbd.waitForServer("grafana", "the restarted server") {
      $0.state == .running && $0.pid != nil && $0.pid != first.pid
    }
    #expect(second.restarts == 1)
    #expect(second.url == first.url)
    #expect(second.lastExit == "signal kill")
    let s = try sbd.new(prompt: "mcp grafana")
    try sbd.waitFor(s.id, "the call to the restarted server") { $0.lastReply == "MCP grafana: grafana \(second.pid!)" }
  }

  @Test func backsOffAServerThatKeepsExiting() throws {
    let sbd = try Instance(config: [
      "mcpServers": [
        "broken": ["type": "http", "command": "/bin/sh", "args": ["-c", "echo cannot start on {port}; exit 3"]]
      ]
    ])
    let broken = try sbd.waitForServer("broken", "two restarts") { $0.restarts >= 2 }
    #expect(broken.lastExit == "status 3")
    #expect(broken.lastOutput == ["cannot start on \(try #require(URLComponents(string: broken.url)?.port))"])
    let start = Date()
    let s = try sbd.new(prompt: "hello")
    #expect(Date().timeIntervalSince(start) < 5)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    #expect(try sbd.events(s.id).first { $0.kind == "started" }?.data["mcp"] == [])
    sleep(2)
    // Restarts wait 0, 1, 2, then 4 s. After about 4 s there have been 3 restarts, not one per tick.
    #expect(try sbd.mcpServers().first!.restarts <= 4)
  }

  @Test func backsOffAServerThatSbdCantStart() throws {
    let sbd = try Instance(config: ["mcpServers": ["grafana": Instance.stubServer("grafana")]])
    try sbd.waitForRunning("grafana")
    sbd.stopSbd()
    try runCommand(try #require(findExecutable("tmux")), ["-S", sbd.home.tmuxSocket, "kill-server"])
    // sbd can't write the launcher script into a folder that it can't write to.
    chmod(sbd.home.mcpFolder, 0o500)
    defer { chmod(sbd.home.mcpFolder, 0o700) }
    try sbd.startSbd()
    let failed = try sbd.waitForServer("grafana", "a failed start") { $0.lastExit?.hasPrefix("can't start") == true }
    #expect(failed.state == .exited)
    sleep(3)
    #expect((1...4).contains(try sbd.mcpServers().first!.restarts))
    chmod(sbd.home.mcpFolder, 0o700)
    try sbd.waitForRunning("grafana")
  }

  @Test func keepsServersAcrossARestartOfSbdUnlessTheirConfigChanged() throws {
    let sbd = try Instance(config: [
      "mcpServers": [
        "kept": Instance.stubServer("kept"), "changed": Instance.stubServer("changed"),
        "removed": Instance.stubServer("removed"),
      ]
    ])
    let kept = try sbd.waitForRunning("kept")
    let changed = try sbd.waitForRunning("changed")
    let removed = try sbd.waitForRunning("removed")
    sbd.stopSbd()
    try sbd.setMCPServers(["kept": Instance.stubServer("kept"), "changed": Instance.stubServer("changed", delay: 0.1)])
    try sbd.startSbd()
    let keptAfter = try sbd.waitForRunning("kept")
    let changedAfter = try sbd.waitForRunning("changed")
    #expect(keptAfter.pid == kept.pid)
    #expect(keptAfter.url == kept.url)
    #expect(changedAfter.pid != changed.pid)
    #expect(changedAfter.url == changed.url)
    #expect(try sbd.mcpServers().map(\.name) == ["changed", "kept"])
    try sbd.waitFor("the removed server to exit") { kill(pid_t(removed.pid!), 0) != 0 }
  }
}
