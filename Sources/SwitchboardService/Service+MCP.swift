import Foundation
import SwitchboardCore

/// A shared MCP server. It runs in a tmux session named mcp-<name> on sbd's
/// tmux server, so it keeps running when sbd exits. A restart of sbd
/// therefore doesn't cut live sessions off from it.
struct SharedServer {
  let name: String
  let config: MCPServer
  let port: Int
  /// When sbd last started the server, or found it running at load.
  var started: Int64 = 0
  /// The port accepted a connection after `started`.
  var listening = false
  var restarts = 0
  /// Exits in a row that each came less than a minute after their start.
  var exitsInARow = 0
  /// Set from an exit until sbd starts the server again.
  var restartAt: Int64?
  var lastExit: String?
  var lastOutput: [String]?

  var pane: String { Service.mcpPanePrefix + name }
}

extension Service {
  static let mcpPanePrefix = "mcp-"

  /// The requests that can start claude in an existing session. `new` always
  /// starts claude, so it waits once its folder exists.
  static let waitsForMCP = launches.union(["terminals"])

  /// How long a launch waits for a server that started and doesn't accept
  /// connections yet.
  static let mcpStartMs: Int64 = 10_000

  var mcpArgs: [String] { mcp.isEmpty ? [] : ["--mcp-config", home.mcpConfig] }

  /// The servers that a claude launched now connects to.
  var mcpListening: JSON { .array(mcp.filter(\.listening).map { .string($0.name) }) }

  /// Writes the --mcp-config file and starts each server whose tmux session
  /// is missing, dead, or runs an older launcher script. A server that still
  /// runs from before keeps running. It stops the servers that config.json no
  /// longer lists. `load` calls it after taking its snapshot. `mcp` keeps the
  /// same servers in the same order for the life of sbd, so an index names
  /// the same server.
  func startMCPServers() throws {
    let problems = MCPServer.problems(config.mcpServers)
    for (name, problem) in problems.sorted(by: { $0.key < $1.key }) {
      logLine("skipping MCP server \(name): \(problem)")
    }
    let valid = config.mcpServers.filter { problems[$0.key] == nil }
    let written = (try? String(contentsOfFile: home.mcpConfig, encoding: .utf8)).flatMap(JSON.parse)
    // A server keeps its port from the last run while it still runs there.
    // Otherwise it keeps the port only if no other program took it, such as
    // while the Mac restarted.
    let ports = MCPServer.assignPorts(
      valid, previous: written.map(MCPServer.ports(inClaudeConfig:)) ?? [:],
      canKeep: { name, port in mcpPaneAlive(Service.mcpPanePrefix + name) || LocalPort.canBind(port) },
      freePort: LocalPort.free)
    mcp = ports.keys.sorted().map { SharedServer(name: $0, config: valid[$0]!, port: ports[$0]!) }
    let panes = Set(mcp.map(\.pane))
    for pane in snapshot.panes.keys where pane.hasPrefix(Service.mcpPanePrefix) && !panes.contains(pane) {
      host.kill(pane)
    }
    guard !mcp.isEmpty else {
      try? FileManager.default.removeItem(atPath: home.mcpConfig)
      return
    }
    try MCPServer.claudeConfig(valid, ports: ports).text.write(
      toFile: home.mcpConfig, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: home.mcpFolder, withIntermediateDirectories: true)
    let now = nowMs()
    for i in mcp.indices {
      let server = mcp[i]
      if mcpPaneAlive(server.pane),
        (try? String(contentsOfFile: mcpScriptPath(server), encoding: .utf8)) == mcpScript(server)
      {
        mcp[i].started = now
        logLine("MCP server \(server.name) still runs")
      } else {
        runMCPServer(i, now: now)
      }
    }
  }

  /// Notes each server whose port began to accept connections and each that
  /// exited, and starts an exited server again once its delay has passed.
  /// `tick` calls it.
  func superviseMCPServers(now: Int64) {
    for i in mcp.indices {
      let server = mcp[i]
      if mcpPaneAlive(server.pane) {
        mcp[i].restartAt = nil
        if !server.listening && LocalPort.accepts(server.port) { markListening(i, run: server.started) }
        continue
      }
      if server.restartAt == nil {
        let gone = snapshot.panes[server.pane] == nil
        scheduleRestart(
          i, exit: gone ? "its tmux session is gone" : host.exitText(server.pane) ?? "unknown",
          output: gone ? nil : host.lastLines(server.pane, 5), now: now)
      }
      if let at = mcp[i].restartAt, now >= at {
        mcp[i].restarts += 1
        runMCPServer(i, now: now)
      }
    }
  }

  /// Waits up to `mcpStartMs` for each server that started less than
  /// `mcpStartMs` ago and doesn't accept connections yet. claude connects to
  /// its MCP servers only when it starts. A session that starts before a
  /// server listens lacks that server until it stops and resumes. With a
  /// request, it waits only when the request can start claude in the session
  /// it names. It runs off the state queue.
  func awaitMCPServers(for request: Request? = nil) {
    if let request {
      // A follow-up that waits to start refuses every request that starts claude.
      let id: String? = queue.sync {
        guard mcpStarting(now: nowMs()), let id = try? lookup(request.args), entries[id]!.session.runsClaude
        else { return nil }
        return id
      }
      guard let id else { return }
      // This asks tmux, because the tick's snapshot can still show a Claude
      // pane that has died since. `terminals` starts claude only in a missing
      // pane. The other requests start it in a dead or missing pane.
      let dead = host.isDead(paneName(id, .claude))
      guard request.op == "terminals" ? dead == nil : dead != false else { return }
    }
    let deadline = Date().addingTimeInterval(Double(Service.mcpStartMs) / 1000)
    while Date() < deadline {
      let starting: [(index: Int, port: Int, run: Int64)] = queue.sync {
        let now = nowMs()
        return mcp.indices.filter { isStarting(mcp[$0], now: now) }.map { ($0, mcp[$0].port, mcp[$0].started) }
      }
      if starting.isEmpty { return }
      let open = starting.filter { LocalPort.accepts($0.port) }
      if !open.isEmpty { queue.sync { open.forEach { markListening($0.index, run: $0.run) } } }
      if open.count == starting.count { return }
      usleep(50_000)
    }
  }

  /// Whether any server started less than `mcpStartMs` ago and doesn't
  /// accept connections yet. While one does, `tick` doesn't launch claude
  /// itself, as `awaitMCPServers` makes a request's launch wait.
  func mcpStarting(now: Int64) -> Bool { mcp.contains { isStarting($0, now: now) } }

  func mcpStatus() -> [MCPServerStatus] {
    mcp.map { s in
      MCPServerStatus(
        name: s.name, type: s.config.type, url: s.config.url(port: s.port), state: mcpState(s),
        pid: snapshot.panes[s.pane].flatMap { !$0.dead && $0.pid > 0 ? $0.pid : nil }, restarts: s.restarts,
        restartAt: s.restartAt, lastExit: s.lastExit, lastOutput: s.lastOutput)
    }
  }

  private func mcpPaneAlive(_ pane: String) -> Bool { snapshot.panes[pane]?.dead == false }

  private func mcpState(_ server: SharedServer) -> MCPServerStatus.State {
    if server.restartAt != nil || !mcpPaneAlive(server.pane) { return .exited }
    return server.listening ? .running : .starting
  }

  private func isStarting(_ server: SharedServer, now: Int64) -> Bool {
    mcpState(server) == .starting && now - server.started < Service.mcpStartMs
  }

  private func mcpScriptPath(_ server: SharedServer) -> String { "\(home.mcpFolder)/\(server.name).sh" }

  private func mcpScript(_ server: SharedServer) -> String {
    "# Written by sbd. The tmux session \(server.pane) runs it to start the shared MCP server \(server.name).\n"
      + server.config.commandLine(port: server.port) + "\n"
  }

  /// Writes the server's launcher script and runs it in the server's tmux
  /// session. A failed start counts as a start and an exit, so a start that
  /// keeps failing backs off.
  private func runMCPServer(_ i: Int, now: Int64) {
    let server = mcp[i]
    mcp[i].started = now
    let command = "/bin/sh \(shellQuote(mcpScriptPath(server)))"
    do {
      try mcpScript(server).write(toFile: mcpScriptPath(server), atomically: true, encoding: .utf8)
      switch snapshot.panes[server.pane] {
      case let row? where row.dead:
        // Without this, the next exit's output would include this run's.
        host.clearHistory(server.pane)
        try host.respawn(server.pane, cwd: NSHomeDirectory(), env: [:], command: command)
      case .some:
        host.kill(server.pane)
        fallthrough
      case nil:
        try host.create(server.pane, cwd: NSHomeDirectory(), env: [:], command: command)
      }
    } catch {
      logLine("can't start MCP server \(server.name): \(error)")
      scheduleRestart(i, exit: "can't start: \(error)", output: nil, now: now)
      return
    }
    markStarting(server.pane)
    mcp[i].listening = false
    mcp[i].restartAt = nil
  }

  /// `run` is the `started` time of the run whose port accepted, so a probe
  /// that a restart overtook marks nothing.
  private func markListening(_ i: Int, run: Int64) {
    guard !mcp[i].listening, mcp[i].started == run else { return }
    mcp[i].listening = true
    logLine("MCP server \(mcp[i].name) accepts connections on port \(mcp[i].port)")
  }

  private func scheduleRestart(_ i: Int, exit: String, output: [String]?, now: Int64) {
    let server = mcp[i]
    let exits = now - server.started < 60_000 ? server.exitsInARow + 1 : 1
    let delay = MCPServer.restartDelayMs(exitsInARow: exits)
    mcp[i].exitsInARow = exits
    mcp[i].restartAt = now + delay
    mcp[i].listening = false
    mcp[i].lastExit = exit
    mcp[i].lastOutput = output
    logLine("MCP server \(server.name) exited (\(exit)). sbd starts it again in \(delay / 1000) s")
  }
}

/// TCP ports on 127.0.0.1.
enum LocalPort {
  /// Whether a connection to the port succeeds within 0.2 s.
  static func accepts(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var addr = loopback(port)
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if rc == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, 200) == 1 else { return false }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
    return error == 0
  }

  /// Whether a server could listen on the port now. It sets SO_REUSEADDR, as
  /// servers do, so a port that only closed connections hold counts as free.
  static func canBind(_ port: Int) -> Bool { withBoundSocket(port, reuseAddress: true) { _ in true } ?? false }

  /// A port that the OS picks among those that no socket holds now.
  static func free() -> Int? {
    withBoundSocket(0, reuseAddress: false) { fd in
      var addr = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let named = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
      }
      return named ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
  }

  /// Binds a new socket to 127.0.0.1 at the port and passes it to `body`, or
  /// returns nil when the bind fails. It closes the socket afterward.
  private static func withBoundSocket<T>(_ port: Int, reuseAddress: Bool, _ body: (Int32) -> T?) -> T? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    if reuseAddress {
      var on: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    }
    var addr = loopback(port)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    return bound ? body(fd) : nil
  }

  private static func loopback(_ port: Int) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(exactly: port) ?? 0).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
  }
}
