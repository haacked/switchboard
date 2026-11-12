import Foundation
import SwitchboardCore

/// A file that gets one JSON object per line for each call. Only a test instance writes one.
struct MachineLog: Sendable {
  let path: String

  /// Appends the call's name and its arguments as one line. Each line is one `write` to a file opened for
  /// appending, so lines from several threads and several logs of one file stay whole.
  func append(_ call: String, _ arguments: [String: JSON] = [:]) {
    var fields = arguments
    fields["call"] = .string(call)
    let line = Array((JSON.object(fields).text + "\n").utf8)
    let file = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard file >= 0 else { return logLine("can't open \(path): \(String(cString: strerror(errno)))") }
    defer { close(file) }
    if write(file, line, line.count) != line.count { logLine("can't write \(call) to \(path)") }
  }
}

/// A machine that appends each call to a file before it passes the call to `base`.
struct LoggedMachine: Machine {
  private let base: any Machine
  private let log: MachineLog

  init(_ base: any Machine, log: MachineLog) {
    self.base = base
    self.log = log
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    var fields: [String: JSON] = ["executable": .string(executable), "args": .array(args.map(JSON.string))]
    if let env { fields["env"] = .object(env.mapValues(JSON.string)) }
    if let timeout, timeout.isFinite { fields["timeout"] = .number(timeout) }
    log.append("run", fields)
    return try base.run(executable, args, env: env, input: input, timeout: timeout)
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    var fields: [String: JSON] = ["path": .string(path), "offset": .number(Double(offset))]
    if let count { fields["count"] = .number(Double(count)) }
    log.append("read", fields)
    return base.read(path, from: offset, count: count)
  }

  func size(_ path: String) -> UInt64? {
    log.append("size", ["path": .string(path)])
    return base.size(path)
  }

  func exists(_ path: String) -> Bool {
    log.append("exists", ["path": .string(path)])
    return base.exists(path)
  }

  func isFolder(_ path: String) -> Bool {
    log.append("isFolder", ["path": .string(path)])
    return base.isFolder(path)
  }

  func modified(_ path: String) -> Date? {
    log.append("modified", ["path": .string(path)])
    return base.modified(path)
  }

  func list(_ folder: String) -> [String] {
    log.append("list", ["folder": .string(folder)])
    return base.list(folder)
  }

  func createFolder(_ path: String) throws {
    log.append("createFolder", ["path": .string(path)])
    try base.createFolder(path)
  }

  func signal(_ pid: Int, _ signal: Int32) {
    log.append("signal", ["pid": .number(Double(pid)), "number": .number(Double(signal))])
    base.signal(pid, signal)
  }
}
