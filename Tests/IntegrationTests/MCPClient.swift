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
