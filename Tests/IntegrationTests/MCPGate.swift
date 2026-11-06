import Foundation
import SwitchboardCore
import Testing

/// A file that keeps Fixtures/mcp-stub from listening while it exists. sbd
/// waits only 10 s, counted from the server's start, for a starting server to
/// listen. A fixed `--delay` can pass that window on a loaded machine, so a
/// test that needs a starting server opens the gate itself.
final class MCPGate {
  let path: String
  /// The stub writes its pid here once Python has started, and then waits
  /// for the gate to open.
  var ready: String { path + ".ready" }
  private let folder: String

  init(open: Bool = false) throws {
    var template = Array("/tmp/sbg.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    folder = String(cString: dir)
    path = "\(folder)/gate"
    if !open { close() }
  }

  deinit { try? FileManager.default.removeItem(atPath: folder) }

  /// Makes the next start of the stub wait. It removes the ready file, so
  /// that only a stub that starts after this call can write it again.
  func close() {
    FileManager.default.createFile(atPath: path, contents: nil)
    try? FileManager.default.removeItem(atPath: ready)
  }

  func open() throws { try FileManager.default.removeItem(atPath: path) }

  /// The pid that the waiting stub wrote, or nil before it wrote one.
  func waitingPid() -> Int? {
    (try? String(contentsOfFile: ready, encoding: .utf8)).flatMap { Int($0) }
  }

  /// Sends the request while the gate holds the stub, opens the gate as
  /// `open(_:after:sentAt:)` does, and returns the request's result.
  @discardableResult
  func open<T>(_ sbd: Instance, during request: @escaping () throws -> T) throws -> T {
    let sent = Date()
    return try open(sbd, after: .detached(request), sentAt: sent)
  }

  /// Opens the gate once the stub waits at it and the request has run for
  /// 0.5 s since `sent`, so that the request reaches sbd's wait for the
  /// server first. It fails when the request returned before the gate
  /// opened. A request that launches claude has to wait for a starting
  /// server, so an early return means that sbd launched claude without it.
  func open<T>(_ sbd: Instance, after outcome: Outcome<T>, sentAt sent: Date) throws -> T {
    try sbd.waitFor("the MCP stub to wait at its gate", timeout: 30) { waitingPid() != nil }
    let left = 0.5 - Date().timeIntervalSince(sent)
    if left > 0 { usleep(useconds_t(left * 1_000_000)) }
    if let early = outcome.result {
      throw TestError(description: "the request returned before the MCP server listened: \(early)")
    }
    try open()
    guard outcome.done.wait(timeout: .now() + 30) == .success, let result = outcome.result else {
      throw TestError(description: "the request didn't return in 30 s after the gate opened")
    }
    return try result.get()
  }
}

extension Outcome {
  /// Runs the body on a thread of its own, because the global queue gets no
  /// thread while the parallel tests block every thread of Swift's
  /// cooperative pool.
  static func detached(_ body: @escaping () throws -> T) -> Outcome<T> {
    let outcome = Outcome<T>()
    Thread.detachNewThread {
      outcome.result = Result { try body() }
      outcome.done.signal()
    }
    return outcome
  }
}

extension Instance {
  /// Closes the gate before it kills the server, so the stub that sbd starts
  /// next waits at the gate.
  @discardableResult
  func restartServer(_ server: MCPServerStatus, behind gate: MCPGate) throws -> MCPServerStatus {
    gate.close()
    return try restartServer(server)
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPGateTests {
  @Test func aGatedServerDoesNotListenUntilTheGateOpens() throws {
    let gate = try MCPGate()
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", gate: gate)]])
    let starting = try sbd.waitForServer("slow", "the server to start") { $0.state == .starting && $0.pid != nil }
    try sbd.waitFor("the stub to wait at its gate", timeout: 30) { gate.waitingPid() == starting.pid }
    // The tick that `clock` runs checks the port.
    try sbd.advanceClock(1)
    #expect(try sbd.mcpServers().first?.state == .starting)
    try gate.open()
    #expect(try sbd.waitForRunning("slow").pid == starting.pid)
  }

  @Test func aRestartBehindTheGateWaitsAgain() throws {
    let gate = try MCPGate(open: true)
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", gate: gate)]])
    let first = try sbd.waitForRunning("slow")
    #expect(gate.waitingPid() == first.pid)
    let restarted = try sbd.restartServer(first, behind: gate)
    #expect(restarted.pid != first.pid)
    try sbd.waitFor("the restarted stub to wait at its gate", timeout: 30) { gate.waitingPid() == restarted.pid }
    try sbd.advanceClock(1)
    #expect(try sbd.mcpServers().first?.state == .starting)
    try gate.open()
    #expect(try sbd.waitForRunning("slow").pid == restarted.pid)
  }
}
