import Foundation

public struct CommandResult: Sendable {
  public var status: Int32
  public var stdout: String
  public var stderr: String
}

/// Runs a program and waits for it. `env` replaces the environment when set.
/// With `timeout`, the program gets SIGTERM after that many seconds.
@discardableResult
public func runCommand(
  _ executable: String, _ args: [String], env: [String: String]? = nil, input: Data? = nil, timeout: Double? = nil
) throws -> CommandResult {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: executable)
  p.arguments = args
  if let env { p.environment = env }
  let out = Pipe()
  let err = Pipe()
  p.standardOutput = out
  p.standardError = err
  let stdin = input.map { _ in Pipe() }
  p.standardInput = stdin ?? FileHandle.nullDevice
  try p.run()
  let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
  defer { kill.cancel() }
  if let timeout { DispatchQueue(label: "runCommand.timeout").asyncAfter(deadline: .now() + timeout, execute: kill) }
  if let stdin, let input {
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
  }
  // Reads both pipes before waiting, so a full pipe can't stall the program.
  // stdout is read on a queue of its own. A global queue gets no thread
  // while a caller waits here on every thread of Swift's cooperative pool,
  // as parallel tests do.
  var outData = Data()
  let group = DispatchGroup()
  group.enter()
  DispatchQueue(label: "runCommand.stdout").async {
    outData = out.fileHandleForReading.readDataToEndOfFile()
    group.leave()
  }
  let errData = err.fileHandleForReading.readDataToEndOfFile()
  group.wait()
  p.waitUntilExit()
  return CommandResult(
    status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
    stderr: String(decoding: errData, as: UTF8.self))
}

/// The text in single quotes, for a command that a POSIX shell runs.
public func shellQuote(_ text: String) -> String {
  "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
  let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
  return me.deletingLastPathComponent().appendingPathComponent(name).path
}

/// A process from `ps`.
public struct ProcessRow: Sendable {
  public var pid: Int
  public var ppid: Int
  public var pgid: Int
  public var command: String
}

public enum Processes {
  /// Every process, grouped by parent pid.
  public static func byParent() -> [Int: [ProcessRow]] {
    guard let r = try? runCommand("/bin/ps", ["-axo", "pid=,ppid=,pgid=,command="]) else { return [:] }
    let rows = r.stdout.split(separator: "\n").compactMap { line -> ProcessRow? in
      let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
      guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1]), let pgid = Int(parts[2]) else {
        return nil
      }
      return ProcessRow(pid: pid, ppid: ppid, pgid: pgid, command: parts.count > 3 ? String(parts[3]) : "")
    }
    return Dictionary(grouping: rows, by: \.ppid)
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
