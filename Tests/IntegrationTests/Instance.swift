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

  let home: Home
  let client: Client
  private var process: Process?

  /// The folder is under /tmp, because a Unix socket path can't exceed 103
  /// bytes. The stop rule runs every 0.2 s, so idle stops come quickly.
  init(idleStopSeconds: Int = 600) throws {
    var template = Array("/tmp/sbt.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    home = Home(path: String(cString: dir))
    let config: JSON = [
      "claude": .string(Instance.stub), "idleStopSeconds": .number(Double(idleStopSeconds)), "tickSeconds": 0.2,
      "worktreeRoot": .string("\(home.path)/worktrees"),
    ]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
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

  /// Runs sb with this instance's SB_HOME.
  @discardableResult
  func sb(_ args: String...) throws -> String {
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = home.path
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

  /// Waits for the session to match, and returns it.
  @discardableResult
  func waitFor(_ id: String, _ what: String, timeout: Double = 15, _ match: (SessionSummary) -> Bool) throws
    -> SessionSummary
  {
    var last: SessionSummary?
    try waitFor(what, timeout: timeout) {
      last = try? get(id)
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

  func events(_ id: String) throws -> [Event] {
    try client.call("events", ["session": .string(id), "since": 0, "limit": 10_000], as: [Event].self)
  }
}
