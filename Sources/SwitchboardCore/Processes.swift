import Foundation
import os

public struct CommandResult: Sendable {
  public var status: Int32
  public var stdout: String
  public var stderr: String
  /// True when `runCommand` sent SIGTERM because the timeout passed, or when
  /// the program's output stayed open more than a second past the timeout. A
  /// program that handles SIGTERM can then exit with any status. A child of
  /// the program can keep the output open, and `stdout` and `stderr` then
  /// hold only what arrived before `runCommand` stopped reading.
  public var timedOut: Bool

  public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
  }
}

extension String {
  /// Whether the text holds a NUL byte, which a program's argument or
  /// environment value can't carry.
  public var hasNul: Bool { utf8.contains(0) }
}

extension CommandResult {
  /// The trimmed error text, else the exit status.
  public var problem: String {
    let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "exit status \(status)" : text
  }
}

/// Runs a program and waits for it. `env` replaces the environment when set.
/// With `timeout`, the program gets SIGTERM after that many seconds. An
/// argument or environment value with a NUL throws.
@discardableResult
public func runCommand(
  _ executable: String, _ args: [String], env: [String: String]? = nil, input: Data? = nil, timeout: Double? = nil,
  cwd: String? = nil
) throws -> CommandResult {
  // Process raises an Objective-C exception for a NUL. Swift can't catch it, so it would end the program.
  if ([executable] + args + (env.map { Array($0.keys) + Array($0.values) } ?? [])).contains(where: \.hasNul) {
    throw APIError(
      "\((executable as NSString).lastPathComponent) can't run with a NUL character in its arguments or environment")
  }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: executable)
  p.arguments = args
  if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
  if let env { p.environment = env }
  let out = Pipe()
  let err = Pipe()
  p.standardOutput = out
  p.standardError = err
  let stdin = input.map { _ in Pipe() }
  p.standardInput = stdin ?? FileHandle.nullDevice
  try p.run()
  let deadline = timeout.map { DispatchTime.now() + $0 }
  let timedOut = OSAllocatedUnfairLock(initialState: false)
  let kill = DispatchWorkItem {
    if p.isRunning {
      timedOut.withLock { $0 = true }
      p.terminate()
    }
  }
  defer { kill.cancel() }
  if let deadline { DispatchQueue(label: "runCommand.timeout").asyncAfter(deadline: deadline, execute: kill) }
  if let stdin, let input {
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
  }
  // Reads both pipes while the program runs, so a full pipe can't stall it.
  let group = DispatchGroup()
  let outData = Drain(out, label: "runCommand.stdout", group)
  let errData = Drain(err, label: "runCommand.stderr", group)
  p.waitUntilExit()
  if let deadline {
    // A child that outlives the program can keep the pipes open for as long as it runs.
    if group.wait(timeout: max(deadline, .now()) + 1) == .timedOut {
      timedOut.withLock { $0 = true }
      outData.stop()
      errData.stop()
    }
  } else {
    group.wait()
  }
  return CommandResult(
    status: p.terminationStatus, stdout: String(decoding: outData.bytes, as: UTF8.self),
    stderr: String(decoding: errData.bytes, as: UTF8.self), timedOut: timedOut.withLock { $0 })
}

/// Reads a pipe to its end on a queue of its own. A global queue gets no thread while a caller waits in
/// `runCommand` on every thread of Swift's cooperative pool, as parallel tests do.
private final class Drain: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: (bytes: Data(), stopped: false))

  init(_ pipe: Pipe, label: String, _ group: DispatchGroup) {
    group.enter()
    DispatchQueue(label: label).async { [state] in
      let reader = pipe.fileHandleForReading
      // `availableData` returns each chunk as it arrives. `read(upToCount:)` waits for the whole count.
      while case let chunk = reader.availableData, !chunk.isEmpty {
        let stopped = state.withLock { s in
          if !s.stopped { s.bytes.append(chunk) }
          return s.stopped
        }
        if stopped { break }
      }
      // Closing the read end gives a child that still writes SIGPIPE, so it can't fill memory or hold the thread.
      try? reader.close()
      group.leave()
    }
  }

  var bytes: Data { state.withLock { $0.bytes } }

  /// Stops collecting. The reader drops the chunk it waits for and closes the pipe when that chunk arrives.
  func stop() { state.withLock { $0.stopped = true } }
}

/// The text in single quotes, for a command that a POSIX shell runs. It is correct for every
/// byte but NUL. It works on Unicode scalars, because a `'` and a combining mark after it are
/// one character, which a search for the character `'` does not find.
public func shellQuote(_ text: String) -> String {
  var quoted = String.UnicodeScalarView()
  quoted.append("'")
  for scalar in text.unicodeScalars {
    if scalar == "'" { quoted.append(contentsOf: "'\\''".unicodeScalars) } else { quoted.append(scalar) }
  }
  quoted.append("'")
  return String(quoted)
}

/// The text as one shell word: bare when it holds only letters, digits,
/// `.`, `_`, and `-`, and in single quotes otherwise.
public func shellWord(_ text: String) -> String {
  text.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil ? text : shellQuote(text)
}

/// The full path of `name`. A name with a slash is checked as given. A name
/// without one is looked up on PATH, then in ~/.local/bin, where claude
/// installs itself, then in Homebrew's and the system's bin folders. sbd runs
/// under launchd, whose PATH holds only the system's folders.
public func findExecutable(_ name: String) -> String? {
  if name.contains("/") {
    let path = name.expandingTilde
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }
  let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
  let fallbacks = ["~/.local/bin".expandingTilde, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
  for dir in path.split(separator: ":").map(String.init) + fallbacks {
    let full = "\(dir)/\(name)"
    if FileManager.default.isExecutableFile(atPath: full) { return full }
  }
  return nil
}

/// A program in the same folder as this one, as sb and sbd sit together both
/// in a build folder and in the app bundle. It follows a symlink to this
/// program first, such as ~/.local/bin/sb.
public func siblingExecutable(_ name: String) -> String {
  ownExecutable().deletingLastPathComponent().appendingPathComponent(name).path
}

/// This program's file, after following a symlink to it such as ~/.local/bin/sb.
public func ownExecutable() -> URL {
  (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
}

public enum Processes {
  /// The text of a C string that the kernel stores in a fixed-size char tuple, such as `vip_path` or `p_comm`. The
  /// tuple must hold a NUL byte, because the read stops only at the first NUL.
  public static func pathString<T>(_ tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
  }

  /// Whether the number can name one process. A pid below 1 names a process
  /// group, and a pid above `Int32.max` names no process.
  public static func isValidPid(_ pid: Int) -> Bool { pid >= 1 && pid <= Int(Int32.max) }

  /// Whether a process with the pid exists. EPERM means it exists and belongs
  /// to another user.
  public static func exists(_ pid: Int) -> Bool {
    guard isValidPid(pid) else { return false }
    return kill(pid_t(pid), 0) == 0 || errno == EPERM
  }

  /// The pid and each of its parents up to launchd, read live from the kernel.
  /// It is nil when the pid is not valid or names no process. The walk stops
  /// at a parent that the kernel can't read, which happens when that parent
  /// exits between two reads.
  public static func ancestors(of pid: Int) -> Set<Int>? {
    guard isValidPid(pid), let first = parent(of: pid) else { return nil }
    var found: Set<Int> = [pid]
    var next = first
    while next > 0, found.insert(next).inserted, let up = parent(of: next) {
      next = up
    }
    return found
  }

  /// The start time of the process, in microseconds since the epoch, as `ProcessTable` reads it. It is nil when no
  /// process has the pid. A pid that exited and was reused names a process with another start time.
  public static func startTime(of pid: Int) -> Int64? {
    guard isValidPid(pid) else { return nil }
    return info(of: pid_t(pid)).map(ProcessTable.startTime)
  }

  /// The parent pid from sysctl, which reads processes of every user, as `ps` does.
  private static func parent(of pid: Int) -> Int? {
    info(of: pid_t(pid)).map { Int($0.kp_eproc.e_ppid) }
  }

  /// The process's entry in the kernel's process table, which `sysctl` reads for every user's process. It is nil when
  /// no process has the pid.
  static func info(of pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
  }

  /// Waits up to `seconds` for every pid to exit. Returns the pids that still exist.
  public static func waitForExit(_ pids: Set<Int>, seconds: TimeInterval) -> Set<Int> {
    let deadline = Date().addingTimeInterval(seconds)
    var alive = pids.filter(exists)
    while !alive.isEmpty, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      alive = alive.filter(exists)
    }
    return alive
  }
}
