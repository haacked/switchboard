import Foundation
import SwitchboardCore

/// One-shot `claude -p` turns that sbd runs for itself, such as the triage
/// summary and the plan update.
extension Service {
  /// The environment of a turn under a Claude account. With `session`, the
  /// turn takes the session's pane environment and account. Without one, it
  /// takes `config.env`. `account` overrides either. The turn is not a
  /// session, so it gets no session id.
  func headlessEnv(session: String?, account: String?) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    if let session {
      env.merge(paneEnv(session)) { $1 }
    } else {
      for (key, value) in config.env { env[key] = value.expandingTilde }
      env["SB_HOME"] = home.path
    }
    env["SB_SESSION_ID"] = nil
    if let account { ClaudeAccount.apply(account, to: &env) }
    return env
  }

  /// Runs `claude` with the arguments and the input on stdin, in the folder,
  /// ends it after `timeout` seconds, and returns what it printed.
  func runHeadless(
    _ arguments: [String], input: String, env: [String: String], folder: String, timeout: Double
  ) throws -> String {
    guard let claude = findExecutable(config.claude) else { throw APIError("can't find \(config.claude)") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = arguments
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: folder)
    let stdin = Pipe()
    let stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = FileHandle.nullDevice
    try p.run()
    let timedOut = Flag()
    let limit = DispatchWorkItem {
      timedOut.set()
      p.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try? stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    limit.cancel()
    if timedOut.isSet { throw APIError("timed out after \(Int(timeout)) s") }
    guard p.terminationStatus == 0 else {
      throw APIError(
        "claude exited with status \(p.terminationStatus): \(oneLine(String(decoding: output, as: UTF8.self), max: 200))"
      )
    }
    return String(decoding: output, as: UTF8.self)
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}
