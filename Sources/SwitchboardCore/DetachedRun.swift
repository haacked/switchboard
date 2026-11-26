import Foundation

/// Runs a headless or script schedule's process. The child leads a new POSIX session, so a signal to its process
/// group reaches every process that it starts, except one that starts a session of its own.
public enum DetachedRun {
  /// How a run ended.
  public struct Result: Equatable, Sendable {
    /// The exit status. Nil when the process ended on a signal.
    public var exit: Int32?
    /// From the start to the end of the run, in ms.
    public var ms: Int64
    /// The last line of the output that isn't blank, without control characters, at most `tailMax` characters.
    /// Nil when the run printed nothing.
    public var tail: String?
    /// Why sbd ended the run. Nil when the child exited on its own.
    public var reason: Reason?
  }

  /// Why sbd ended a run.
  public enum Reason: Equatable, Sendable { case timedOut, cancelled }

  /// The most bytes of output that the log keeps.
  public static let logCap = 1 << 20
  /// The log's last line when the output passed `logCap`.
  public static let cutMarker = "[output cut at 1 MiB]"
  public static let tailMax = 200
  /// How many of the output's last bytes `tail` reads.
  private static let tailBytes = 8192

  /// Runs `executable` with `arguments` and exactly the environment `env`, in `folder`, with stdin from
  /// /dev/null and stdout and stderr in the file `log`. The log keeps the first `logCap` bytes, and the run keeps
  /// reading past them, so a child never blocks on a full pipe.
  ///
  /// After `timeout` seconds, or within 100 ms of `cancelled` returning true, the run sends SIGTERM to the process
  /// group, and SIGKILL `killGrace` seconds later. When the child exits on its own, the processes it left in its
  /// group get the same signals, so no process of the run outlives it. A process that holds the output open from a
  /// session of its own doesn't hold the run past the group's end.
  ///
  /// The child starts stopped, and it continues only after `onStart` returns with its pid. A caller that records the
  /// pid in `onStart` has it recorded before the child runs any code.
  ///
  /// It throws only when the child never starts: a NUL in an argument or in the environment, a log that can't be
  /// opened, or a program or folder that can't be used.
  public static func run(
    executable: String, arguments: [String], env: [String: String], folder: String, log: String, timeout: Double,
    killGrace: Double = 5, cancelled: () -> Bool = { false }, onStart: (pid_t) -> Void = { _ in }
  ) throws -> Result {
    try refuseNul(executable: executable, arguments: arguments, env: env)
    let logFd = open(log, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard logFd >= 0 else { throw APIError("can't open the log \(log): \(String(cString: strerror(errno)))") }
    defer { close(logFd) }
    var pipeFds: [Int32] = [0, 0]
    guard pipe(&pipeFds) == 0 else { throw APIError("can't make a pipe: \(String(cString: strerror(errno)))") }
    let (readFd, writeFd) = (pipeFds[0], pipeFds[1])
    defer { close(readFd) }
    // Another thread of sbd can spawn a process before POSIX_SPAWN_CLOEXEC_DEFAULT applies to this spawn.
    _ = fcntl(readFd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(writeFd, F_SETFD, FD_CLOEXEC)
    let started = DispatchTime.now()
    let pid: pid_t
    do {
      defer { close(writeFd) }
      pid = try spawn(executable, arguments, env: env, folder: folder, output: writeFd)
    }
    onStart(pid)
    kill(pid, SIGCONT)
    var output = Output(logFd: logFd)
    let ended = watch(
      pid, readFd: readFd, timeout: timeout, killGrace: killGrace, cancelled: cancelled, output: &output)
    output.finish()
    let ms = Int64((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
    return Result(exit: ended.status.flatMap(exitStatus), ms: ms, tail: output.tail, reason: ended.reason)
  }

  /// Starts the child as the leader of a new session, with every signal at its default action and none blocked,
  /// because sbd ignores SIGPIPE and an ignored signal stays ignored across exec. Only stdin, stdout, and stderr
  /// reach the child, so it inherits none of sbd's files or sockets.
  private static func spawn(
    _ executable: String, _ arguments: [String], env: [String: String], folder: String, output: Int32
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, output, 1)
    posix_spawn_file_actions_adddup2(&actions, output, 2)
    // chdir(2) would change the folder of every thread of sbd.
    posix_spawn_file_actions_addchdir_np(&actions, folder)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(
      &attr,
      Int16(
        POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_START_SUSPENDED))
    var all = ~sigset_t(0)
    var none = sigset_t(0)
    posix_spawnattr_setsigdefault(&attr, &all)
    posix_spawnattr_setsigmask(&attr, &none)
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
    guard status == 0 else {
      throw APIError("can't start \(executable) in \(folder): \(String(cString: strerror(status)))")
    }
    return pid
  }

  /// Reads the output until the child has exited and its group is gone, and signals the group on a timeout, a
  /// cancel, or the child's exit. It returns the child's wait status, nil when it can't be read, and why sbd ended
  /// the run, nil when the child exited on its own.
  private static func watch(
    _ pid: pid_t, readFd: Int32, timeout: Double, killGrace: Double, cancelled: () -> Bool, output: inout Output
  ) -> (status: Int32?, reason: Reason?) {
    let start = DispatchTime.now().uptimeNanoseconds
    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
    var chunk = [UInt8](repeating: 0, count: 65536)
    var eof = false
    var exited = false
    var status: Int32?
    var reason: Reason?
    var termAt: Double?
    var killAt: Double?
    func terminate(_ now: Double) {
      guard termAt == nil else { return }
      termAt = now
      killpg(pid, SIGTERM)
    }
    while true {
      if eof {
        usleep(50_000)
      } else {
        var fd = pollfd(fd: readFd, events: Int16(POLLIN), revents: 0)
        if poll(&fd, 1, 50) > 0 {
          let count = read(readFd, &chunk, chunk.count)
          if count > 0 {
            output.append(chunk, count: count)
          } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
            eof = true
          }
        }
      }
      let now = elapsed()
      if !exited {
        var raw: Int32 = 0
        let waited = waitpid(pid, &raw, WNOHANG)
        if waited == pid || (waited < 0 && errno == ECHILD) {
          exited = true
          status = waited == pid ? raw : nil
          // Processes that the child left in its group end with it.
          terminate(now)
        } else if reason == nil, cancelled() {
          reason = .cancelled
          terminate(now)
        } else if reason == nil, now >= timeout {
          reason = .timedOut
          terminate(now)
        }
      }
      if let termAt, killAt == nil, now >= termAt + killGrace {
        killAt = now
        killpg(pid, SIGKILL)
      }
      guard exited else { continue }
      if !groupExists(pid) {
        // A process in a session of its own can hold the pipe open, so the read takes only what is buffered.
        drain(readFd, &chunk, &output)
        return (status, reason)
      }
      if let killAt, now >= killAt + 2 { return (status, reason) }
    }
  }

  /// Whether a process is still in the group. The child was reaped, so the group's id can't belong to another
  /// group while one of its processes is alive.
  private static func groupExists(_ pgid: pid_t) -> Bool {
    killpg(pgid, 0) == 0 || errno == EPERM
  }

  /// Reads what the pipe holds now, without waiting for more.
  private static func drain(_ readFd: Int32, _ chunk: inout [UInt8], _ output: inout Output) {
    while true {
      var fd = pollfd(fd: readFd, events: Int16(POLLIN), revents: 0)
      guard poll(&fd, 1, 0) > 0 else { return }
      let count = read(readFd, &chunk, chunk.count)
      guard count > 0 else { return }
      output.append(chunk, count: count)
    }
  }

  /// The exit status that a wait status holds, or nil when the process ended on a signal.
  private static func exitStatus(_ status: Int32) -> Int32? {
    status & 0x7f == 0 ? (status >> 8) & 0xff : nil
  }

  /// The log file and the output's last bytes.
  private struct Output {
    let logFd: Int32
    var written = 0
    var cut = false
    var lastByte: UInt8 = UInt8(ascii: "\n")
    var writable = true
    var last: [UInt8] = []

    init(logFd: Int32) { self.logFd = logFd }

    mutating func append(_ chunk: [UInt8], count: Int) {
      if count >= DetachedRun.tailBytes {
        last = Array(chunk[(count - DetachedRun.tailBytes)..<count])
      } else {
        last += chunk[0..<count]
        if last.count > DetachedRun.tailBytes { last.removeFirst(last.count - DetachedRun.tailBytes) }
      }
      let keep = min(count, DetachedRun.logCap - written)
      if keep < count { cut = true }
      guard keep > 0 else { return }
      write(chunk[0..<keep])
      written += keep
      lastByte = chunk[keep - 1]
    }

    /// Ends a cut log with the marker on a line of its own.
    mutating func finish() {
      guard cut else { return }
      write(Array(DetachedRun.markerLine(after: lastByte))[...])
    }

    /// A log that can't be written stops growing, and the run goes on.
    private mutating func write(_ bytes: ArraySlice<UInt8>) {
      guard writable else { return }
      bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let n = Darwin.write(logFd, buffer.baseAddress! + offset, buffer.count - offset)
          if n < 0, errno == EINTR { continue }
          guard n > 0 else {
            writable = false
            return
          }
          offset += n
        }
      }
    }

    var tail: String? {
      guard
        let line = stripTerminalCodes(String(decoding: last, as: UTF8.self)).split(whereSeparator: \.isNewline)
          .lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty })
      else { return nil }
      return truncated(line, max: DetachedRun.tailMax)
    }
  }

  /// True when the log ends with the cut marker, so the output passed `logCap`.
  public static func isCut(_ log: String) -> Bool { log.hasSuffix("\(cutMarker)\n") }

  /// The first `logCap` bytes of `data`, and the cut marker on a line of its own when `data` is longer.
  public static func capped(_ data: Data) -> Data {
    guard data.count > logCap else { return data }
    let kept = data.prefix(logCap)
    return kept + markerLine(after: kept.last ?? UInt8(ascii: "\n"))
  }

  /// The cut marker on a line of its own, after output whose last byte is `last`.
  private static func markerLine(after last: UInt8) -> Data {
    Data(((last == UInt8(ascii: "\n") ? "" : "\n") + cutMarker + "\n").utf8)
  }

  /// The first line of the text that isn't blank, cleaned and cut as `Result.tail` is, or nil when every line is blank.
  public static func firstLine(_ text: String) -> String? {
    SwitchboardCore.firstLine(stripTerminalCodes(text)).map { truncated($0, max: tailMax) }
  }
}
