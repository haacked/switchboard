import Foundation
import SwitchboardCore
import Testing

struct TestError: Error, CustomStringConvertible {
  let description: String
}

/// A private sbd for one test, with its own SB_HOME, tmux server, and stub
/// claude (Fixtures/claude-stub).
final class Instance {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  static let bin = ProcessInfo.processInfo.environment["SB_BIN_DIR"] ?? root.appendingPathComponent(".build/debug").path
  static let stub = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/claude-stub").path
  static let slowShell = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/slow-shell").path

  let home: Home
  let client: Client
  private var process: Process?

  /// The folder is under /tmp, because a Unix socket path can't exceed 103
  /// bytes. The stop rule runs every 0.2 s, so idle stops come quickly. The
  /// panes run /bin/sh by default, because a login shell with the user's
  /// setup can take 1.5 s to start, and the tests start dozens of panes at once.
  init(
    idleStopSeconds: Int = 600, testClock: Bool = true, shell: String = "/bin/sh", config extra: [String: JSON] = [:]
  ) throws {
    var template = Array("/tmp/sbt.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    home = Home(path: String(cString: dir))
    let config: [String: JSON] = [
      "claude": .string(Instance.stub), "idleStopSeconds": .number(Double(idleStopSeconds)), "tickSeconds": 0.2,
      "worktreeRoot": .string("\(home.path)/worktrees"), "testClock": .bool(testClock), "shell": .string(shell),
    ]
    try JSON.object(config.merging(extra) { $1 }).text.write(toFile: home.config, atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: home.log, contents: nil)
    client = Client(home: home)
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    try startSbd()
  }

  deinit {
    stopSbd()
    if let tmux = findExecutable("tmux") { _ = try? runCommand(tmux, ["-S", home.tmuxSocket, "kill-server"]) }
    try? FileManager.default.removeItem(atPath: home.path)
  }

  var work: String { "\(home.path)/work" }

  func startSbd() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sbd")
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = home.path
    p.environment = env
    let log = FileHandle(forWritingAtPath: home.log)!
    log.seekToEndOfFile()
    p.standardOutput = log
    p.standardError = log
    try p.run()
    process = p
    try waitFor("sbd answers", timeout: 10) { (try? client.call("ping", timeout: 1)) != nil }
  }

  func stopSbd() {
    guard let p = process else { return }
    p.terminate()
    p.waitUntilExit()
    process = nil
  }

  /// Runs sb with this instance's SB_HOME. CLAUDECODE and SB_SESSION_ID mark a
  /// command that Claude runs in a session, so they come only from `env`.
  @discardableResult
  func sb(_ args: String..., env extra: [String: String] = [:]) throws -> String {
    try sb(args, env: extra)
  }

  @discardableResult
  func sb(_ args: [String], env extra: [String: String] = [:]) throws -> String {
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = home.path
    env["CLAUDECODE"] = nil
    env["SB_SESSION_ID"] = nil
    env.merge(extra) { $1 }
    let r = try runCommand("\(Instance.bin)/sb", args, env: env)
    guard r.status == 0 else { throw TestError(description: "sb \(args.joined(separator: " ")) failed: \(r.stderr)") }
    return r.stdout
  }

  func new(prompt: String? = nil, name: String = "t") throws -> SessionSummary {
    var args: [String: JSON] = ["path": .string(work), "name": .string(name)]
    if let prompt { args["prompt"] = .string(prompt) }
    return try client.call("new", args, as: SessionSummary.self)
  }

  func get(_ id: String) throws -> SessionSummary { try client.session(id) }

  /// Attaches a control-mode tmux client to the session's Claude pane, which
  /// counts as a terminal that shows the session. It returns a function that
  /// detaches the client.
  func attach(_ id: String) throws -> () -> Void {
    let terminals = try client.terminals(id)
    let attached = Process()
    attached.executableURL = URL(fileURLWithPath: terminals.tmux)
    attached.arguments = ["-S", terminals.socket, "-C", "attach-session", "-t", "=\(terminals.claude)"]
    let input = Pipe()
    attached.standardInput = input
    attached.standardOutput = FileHandle.nullDevice
    try attached.run()
    return { input.fileHandleForWriting.write(Data("detach-client\n".utf8)) }
  }

  /// sbd runs a tick at the new time before it replies. The tick resolves
  /// due waits only when no shared MCP server is starting.
  func advanceClock(_ ms: Int64) throws {
    _ = try client.call("clock", ["advance": .number(Double(ms))])
  }

  /// The pid that the stub wrote to the file in SB_HOME, or nil before it wrote one.
  func stubPid(_ file: String) -> pid_t? {
    guard let text = try? String(contentsOfFile: "\(home.path)/\(file)", encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Waits for the session to match, and returns it.
  @discardableResult
  func waitFor(_ id: String, _ what: String, timeout: Double = 15, _ match: (SessionSummary) -> Bool) throws
    -> SessionSummary
  {
    try waitFor(what, timeout: timeout, fetch: { try get(id) }, until: match)
  }

  /// Waits until a fetched value matches, and returns it. A fetch that
  /// throws or returns nil counts as no match.
  func waitFor<T>(_ what: String, timeout: Double = 15, fetch: () throws -> T?, until match: (T) -> Bool) throws -> T {
    var last: T?
    try waitFor(what, timeout: timeout) {
      last = try? fetch()
      return last.map(match) ?? false
    }
    return last!
  }

  func waitFor(_ what: String, timeout: Double = 15, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if try condition() { return }
      usleep(100_000)
    }
    let log = (try? String(contentsOfFile: home.log, encoding: .utf8)) ?? ""
    throw TestError(description: "timed out waiting for \(what). sbd log:\n\(log)")
  }

  func stubArgs() -> [String] {
    ((try? String(contentsOfFile: "\(home.path)/stub-args.log", encoding: .utf8)) ?? "").split(separator: "\n").map(
      String.init)
  }

  func events(_ id: String, after: Int64 = 0) throws -> [Event] {
    try client.call(
      "events", ["session": .string(id), "since": .number(Double(after)), "limit": 10_000], as: [Event].self)
  }
}
