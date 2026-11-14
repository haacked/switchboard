import Foundation
import SwitchboardCore

/// A `cli` request from a host's `sb`: the argv to run this Mac's `sb` with, the folder on the box that `sb` ran
/// in, and the box's `SB_SESSION_ID`, `CLAUDECODE`, and stdin.
struct HostCLIRequest: Equatable {
  var argv: [String]
  var cwd: String
  var session: String?
  var claudecode: String?
  var stdin: Data

  static let keys: Set<String> = ["argv", "cwd", "session", "claudecode", "stdin"]
  static let maxWords = 1_000
  static let maxArgvBytes = 1024 * 1024
  static let maxCwdBytes = 4_096
  static let maxSessionBytes = 64
  static let maxClaudecodeBytes = 16
  static let maxStdinBytes = 16 * 1024 * 1024

  /// The request in `args`. It throws for a key outside `keys`, an argv that is empty, holds more than
  /// `maxWords` words or more than `maxArgvBytes` bytes, or holds a NUL, a `cwd` that is not absolute, holds a NUL
  /// or a newline, or passes `maxCwdBytes` bytes, a `session` that is not 1 to 64 of `[A-Za-z0-9_-]`, a
  /// `claudecode` over `maxClaudecodeBytes` bytes or with a control character, and a `stdin` that is not base64
  /// or decodes to more than `maxStdinBytes` bytes.
  static func parse(_ args: JSON) throws -> HostCLIRequest {
    guard let fields = args.object else { throw APIError("cli takes an object of arguments") }
    let unread = Set(fields.keys).subtracting(keys)
    guard unread.isEmpty else { throw APIError("cli doesn't take \(unread.sorted().joined(separator: ", "))") }

    guard let words = fields["argv"]?.array, !words.isEmpty else { throw APIError("cli needs argv, a list of words") }
    guard words.count <= maxWords else { throw APIError("cli takes at most \(maxWords) words of argv") }
    let argv = try words.map { word -> String in
      guard let text = word.string else { throw APIError("each word of argv is a string") }
      guard !text.hasNul else { throw APIError("a word of argv holds a NUL") }
      return text
    }
    guard argv.reduce(0, { $0 + $1.utf8.count }) <= maxArgvBytes else {
      throw APIError("cli takes at most \(maxArgvBytes) bytes of argv")
    }

    guard let cwd = fields["cwd"]?.string, cwd.hasPrefix("/"), !cwd.hasNul, !cwd.contains("\n"),
      cwd.utf8.count <= maxCwdBytes
    else {
      throw APIError("cli needs cwd, an absolute path on one line of at most \(maxCwdBytes) bytes")
    }

    let session = try optionalString(fields, "session")
    if let session {
      guard (1...maxSessionBytes).contains(session.utf8.count),
        session.utf8.allSatisfy({ $0.isASCIILetterOrDigit || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") })
      else { throw APIError("cli's session is 1 to \(maxSessionBytes) letters, digits, _, and -") }
    }

    let claudecode = try optionalString(fields, "claudecode")
    if let claudecode {
      guard claudecode.utf8.count <= maxClaudecodeBytes,
        !claudecode.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      else { throw APIError("cli's claudecode is at most \(maxClaudecodeBytes) bytes with no control character") }
    }

    var stdin = Data()
    if let encoded = try optionalString(fields, "stdin") {
      // The encoded length bounds the decoded one, so a huge field fails before it is decoded.
      guard encoded.utf8.count <= (maxStdinBytes + 2) / 3 * 4, let decoded = Data(base64Encoded: encoded),
        decoded.count <= maxStdinBytes
      else { throw APIError("cli's stdin is base64 of at most \(maxStdinBytes) bytes") }
      stdin = decoded
    }
    return HostCLIRequest(argv: argv, cwd: cwd, session: session, claudecode: claudecode, stdin: stdin)
  }

  private static func optionalString(_ fields: [String: JSON], _ key: String) throws -> String? {
    guard let value = fields[key] else { return nil }
    guard let text = value.string else { throw APIError("cli's \(key) is a string") }
    return text
  }
}

extension UInt8 {
  fileprivate var isASCIILetterOrDigit: Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(self) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(self)
      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self)
  }
}

/// The environment and the sandbox of the `sb` that sbd runs for a host's `cli` request.
enum HostCLI {
  /// The subprocess's whole environment. Nothing of sbd's environment is in it. `SB_HOME` makes `sb` a client of
  /// the host's socket, and `SB_CLI_HOST` puts `sb` in host mode.
  static func environment(hostHome: String, host: String, cwd: String, session: String?, claudecode: String?)
    -> [String: String]
  {
    var env = [
      "SB_HOME": hostHome, "HOME": hostHome, "SB_CLI_HOST": host, "SB_CLI_CWD": cwd, "PATH": "/usr/bin:/bin",
      "LANG": "en_US.UTF-8",
    ]
    env["SB_SESSION_ID"] = session
    env["CLAUDECODE"] = claudecode
    return env
  }

  /// The sandbox profile of the subprocess. It denies by default and allows only the exec of `sb`, reads of
  /// `sb`'s folder, and a connect to the host's socket, beyond the system rules that any process needs to start.
  /// It names real paths, because a rule that names a path through a link matches nothing. It throws for a path
  /// that does not exist, for a real path that holds `"`, `\`, or a control character, which a string literal of
  /// the profile can't hold as typed, and for an `sb` whose folder holds the user's home or the host's socket,
  /// because the read rule would then cover the user's files or sbd's state. `home` is the user's home.
  static func profile(
    sb: String, socket: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
  ) throws -> String {
    let program = try literalPath(sb)
    let folder = try literalPath((program as NSString).deletingLastPathComponent)
    let hostSocket = try literalPath(socket)
    let home = resolvedPath(home)
    let inside = folder.hasSuffix("/") ? folder : folder + "/"
    if let held = [hostSocket, home].compactMap({ $0 }).first(where: { $0 == folder || $0.hasPrefix(inside) }) {
      throw APIError("sb's sandbox would let sb read \(held), because sb's folder \(folder) holds it")
    }
    return """
      (version 1)
      (deny default)
      (import "system.sb")
      (allow process-exec (literal "\(program)"))
      (allow file-read* (subpath "\(folder)"))
      (allow network-outbound (literal "\(hostSocket)"))
      """
  }

  /// The path with every link resolved, or nil when it names nothing.
  static func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// The real path, checked for a string literal of the profile.
  private static func literalPath(_ path: String) throws -> String {
    guard let real = resolvedPath(path) else {
      throw APIError("can't find \(path) for sb's sandbox: \(UnixSocket.errnoText())")
    }
    guard
      !real.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.properties.generalCategory == .control })
    else {
      throw APIError(
        "sb's sandbox can't name \(real.debugDescription), which holds a quote, a backslash, or a control character")
    }
    return real
  }
}

/// What the `sb` of a `cli` request printed and its exit status.
struct HostCLIOutput: Equatable {
  var status: Int32
  var stdout: Data
  var stderr: Data
}

/// Runs `sandbox-exec -p <profile> <program> <argv…>` for a host's `cli` request. A run ends at its deadline,
/// when `cancelled` says so, or when either stream passes `streamCap` bytes: the program gets SIGTERM, then
/// SIGKILL after `killGraceSeconds`, and the run answers status 1 with the reason after what the program wrote
/// to stderr. Each host has `slotsPerHost` runs at once. A run frees its slot on every way out of `run`.
final class HostCLIRunner: @unchecked Sendable {
  static let slotsPerHost = 8
  static let streamCap = 16 * 1024 * 1024
  static let killGraceSeconds = 2.0
  static let defaultDeadline: TimeInterval = 600

  let program: String
  let sandboxExec: String
  let deadline: TimeInterval
  private let lock = NSLock()
  private var running: [String: Int] = [:]

  init(program: String, sandboxExec: String = "/usr/bin/sandbox-exec", deadline: TimeInterval = defaultDeadline) {
    self.program = program
    self.sandboxExec = sandboxExec
    self.deadline = deadline
  }

  /// Runs the program under the profile with exactly `environment`, in `cwd`, with `stdin`. It throws, and runs
  /// nothing, when the host's slots are taken. It throws when `sandbox-exec` is missing, can't read the profile
  /// (exit 65), or can't run the program (exit 71 with nothing on stdout), so the program never runs without
  /// its sandbox.
  func run(
    host: String, profile: String, argv: [String], environment: [String: String], cwd: String, stdin: Data,
    cancelled: @escaping () -> Bool
  ) throws -> HostCLIOutput {
    try run(
      host: host, profile: profile, argv: argv, environment: environment, cwd: cwd, stdin: stdin,
      cancelled: cancelled
    ) { $0 }
  }

  /// Runs the program as the other `run` does, then passes its output to `finish` while the run still holds its
  /// slot. A caller that sends the output in `finish` keeps the slot until the send ends, so a client that never
  /// reads its answers holds at most `slotsPerHost` of them.
  func run<T>(
    host: String, profile: String, argv: [String], environment: [String: String], cwd: String, stdin: Data,
    cancelled: @escaping () -> Bool, finish: (HostCLIOutput) throws -> T
  ) throws -> T {
    try takeSlot(host)
    defer { freeSlot(host) }
    return try finish(
      try output(
        host: host, profile: profile, argv: argv, environment: environment, cwd: cwd, stdin: stdin, cancelled: cancelled
      ))
  }

  private func output(
    host: String, profile: String, argv: [String], environment: [String: String], cwd: String, stdin: Data,
    cancelled: @escaping () -> Bool
  ) throws -> HostCLIOutput {
    let noSandbox = APIError("sbd can't run sb for \(host) without its sandbox")
    guard FileManager.default.isExecutableFile(atPath: sandboxExec) else { throw noSandbox }
    // The profile allows the exec of the real path only. An exec through a link reads the link, which it denies.
    let arguments = ["-p", profile, HostCLI.resolvedPath(program) ?? program] + argv
    // Process raises an Objective-C exception for a NUL, which would end sbd.
    guard !(arguments + Array(environment.keys) + Array(environment.values) + [cwd]).contains(where: \.hasNul) else {
      throw APIError("sb can't run for \(host) with a NUL in its arguments or environment")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sandboxExec)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do { try process.run() } catch { throw APIError("sbd can't run sb for \(host): \(error)") }
    var run = Run(process: process, stdin: stdin, input: input, output: output, errors: errors)
    let reason = run.wait(seconds: deadline, cancelled: cancelled, host: host)
    if let reason {
      if let last = run.stderr.last, last != UInt8(ascii: "\n") { run.stderr.append(UInt8(ascii: "\n")) }
      run.stderr.append(Data("sb: \(reason)\n".utf8))
      return HostCLIOutput(status: 1, stdout: run.stdout, stderr: run.stderr)
    }
    let status =
      process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    if status == 65 || (status == 71 && run.stdout.isEmpty) { throw noSandbox }
    return HostCLIOutput(status: status, stdout: run.stdout, stderr: run.stderr)
  }

  private func takeSlot(_ host: String) throws {
    try lock.withLock {
      guard running[host, default: 0] < Self.slotsPerHost else {
        throw APIError("too many sb commands from \(host) are running")
      }
      running[host, default: 0] += 1
    }
  }

  private func freeSlot(_ host: String) {
    lock.withLock { running[host, default: 1] -= 1 }
  }

  /// One running program and its three pipes. A single loop polls the pipes, the clock, and `cancelled`, so no
  /// stream is read past its cap and no thread waits on a pipe that a killed program left open.
  private struct Run {
    let process: Process
    let stdin: Data
    var written = 0
    var stdout = Data()
    var stderr = Data()
    var fds: [Int32]

    init(process: Process, stdin: Data, input: Pipe, output: Pipe, errors: Pipe) {
      self.process = process
      self.stdin = stdin
      fds = [output, errors, input].map { pipe in
        let handle = pipe === input ? pipe.fileHandleForWriting : pipe.fileHandleForReading
        let fd = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        try? handle.close()
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // A write to a program that exited fails with EPIPE instead of raising SIGPIPE.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return fd
      }
      if stdin.isEmpty { closeFD(2) }
    }

    /// Waits for the program to exit and both streams to end, and returns why sbd ended it, or nil when it
    /// exited on its own.
    mutating func wait(seconds: TimeInterval, cancelled: () -> Bool, host: String) -> String? {
      let deadline = Date().addingTimeInterval(seconds)
      var reason: String?
      var killAt: Date?
      var exitedAt: Date?
      defer { for index in fds.indices { closeFD(index) } }
      while true {
        if reason == nil {
          if Date() >= deadline {
            reason = "sbd stopped sb for \(host) after \(String(format: "%g", seconds)) s"
          } else if cancelled() {
            reason = "sbd stopped sb for \(host), because the box's sb closed its connection"
          }
          if reason != nil { killAt = terminate() }
        }
        if let at = killAt, Date() >= at, process.isRunning {
          kill(process.processIdentifier, SIGKILL)
          killAt = nil
        }
        if !process.isRunning {
          let now = Date()
          if exitedAt == nil { exitedAt = now }
          // A child that the program left behind can hold a stream open. The run doesn't wait on it for long.
          if fds[0] < 0 && fds[1] < 0 || now.timeIntervalSince(exitedAt!) > HostCLIRunner.killGraceSeconds {
            break
          }
        }
        if let overflow = pump(timeoutMs: 100), reason == nil {
          reason =
            "sbd stopped sb for \(host), because its \(overflow) passed \(HostCLIRunner.streamCap / 1024 / 1024) MiB"
          killAt = terminate()
        }
      }
      process.waitUntilExit()
      return reason
    }

    private func terminate() -> Date {
      if process.isRunning { kill(process.processIdentifier, SIGTERM) }
      return Date().addingTimeInterval(HostCLIRunner.killGraceSeconds)
    }

    /// Moves what is ready on the pipes, waiting up to the timeout. It returns the name of a stream that passed
    /// the cap, after it closes that stream.
    private mutating func pump(timeoutMs: Int32) -> String? {
      var polled = fds.enumerated().compactMap { index, fd -> pollfd? in
        guard fd >= 0 else { return nil }
        return pollfd(fd: fd, events: Int16(index == 2 ? POLLOUT : POLLIN), revents: 0)
      }
      guard !polled.isEmpty else {
        usleep(UInt32(timeoutMs) * 1000)
        return nil
      }
      guard poll(&polled, nfds_t(polled.count), timeoutMs) > 0 else { return nil }
      var overflow: String?
      for entry in polled where entry.revents != 0 {
        guard let index = fds.firstIndex(of: entry.fd) else { continue }
        if index == 2 {
          writeInput()
        } else if !read(index) {
          overflow = index == 0 ? "stdout" : "stderr"
        }
      }
      return overflow
    }

    /// Reads what the stream holds. It returns false, and closes the stream, when the stream passed the cap.
    private mutating func read(_ index: Int) -> Bool {
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while true {
        let n = Darwin.read(fds[index], &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
        if n <= 0 {
          closeFD(index)
          return true
        }
        let held = index == 0 ? stdout.count : stderr.count
        let kept = min(n, HostCLIRunner.streamCap - held)
        if index == 0 { stdout.append(contentsOf: buffer[..<kept]) } else { stderr.append(contentsOf: buffer[..<kept]) }
        if kept < n {
          closeFD(index)
          return false
        }
      }
    }

    private mutating func writeInput() {
      while written < stdin.count {
        let n = stdin.withUnsafeBytes { raw in
          Darwin.write(fds[2], raw.baseAddress! + written, min(raw.count - written, 65_536))
        }
        if n < 0 && errno == EINTR { continue }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
        if n <= 0 { break }
        written += n
      }
      closeFD(2)
    }

    private mutating func closeFD(_ index: Int) {
      guard fds[index] >= 0 else { return }
      close(fds[index])
      fds[index] = -1
    }
  }
}
