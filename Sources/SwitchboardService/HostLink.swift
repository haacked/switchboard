import Foundation
import SwitchboardCore

/// The one ssh connection to a remote host: an `ssh -M` master whose own session is the host's
/// `RemoteShell`. Nothing opens it until `connect()`. While it is wanted, it tries again after
/// each failure, on the schedule of `retryDelayMs`.
///
/// Before an attempt starts ssh, it removes a socket file that a dead master left at the
/// control path. It unlinks only a Unix socket file that no open socket is bound to, that is
/// a direct child of `$SB_HOME/ssh`, at the path that `ssh -G` printed for the destination, and
/// only while `$SB_HOME/ssh` is a folder and not a symlink. It opens that folder once, and
/// every one of these checks and the unlink go through that descriptor. In every other case
/// the attempt fails and deletes nothing.
final class HostLink: @unchecked Sendable {
  struct Status {
    var state: LinkState
    /// The clock time when the link entered `state`.
    var since: Int64
    /// Failures in a row. A successful attempt keeps the count, so a host that drops each
    /// connection at once still backs off. `connect()` and `disconnect()` reset it.
    var failures: Int
    var retryAt: Int64?
    var error: String?
    /// How many times the link has become `connected`. It names one connection.
    var connection = 0
  }

  /// An attempt fails when this long passes before the handshake and the control socket check.
  static let attemptLimitMs: Int64 = 60_000
  /// A connection that stayed up this long starts a new run of failures when it closes.
  static let stableMs: Int64 = 60_000
  /// How long `ssh -G` and `ssh -O check` may take.
  private static let helperSeconds = 30.0
  /// How long an attempt waits for the last ssh process to exit.
  private static let exitSeconds = 5.0
  private static let options = [
    "ControlPersist=no", "ServerAliveInterval=10", "ServerAliveCountMax=6", "ForwardAgent=yes", "BatchMode=yes",
  ]

  let config: HostConfig
  let destination: String
  private let ssh: String
  private let home: Home
  private let now: @Sendable () -> Int64

  /// Guards `current`, `generation`, and `open`.
  private let lock = NSLock()
  private var current: Status
  /// Names the attempt or connection that may change the link's state. Every change of state
  /// but the one to `connected` raises it, so a result from an older attempt is dropped.
  private var generation = 0
  /// The shell of the current attempt or connection.
  private var open: RemoteShell?

  /// Runs the attempts one at a time, so the state lock never waits for ssh.
  private let queue: DispatchQueue
  /// The shell that the last attempt started, and its control path. Only `queue` reads and
  /// writes them.
  private var started: RemoteShell?
  private var controlPath: String?
  /// The control path of the current connection. The lock guards it.
  private var connectedControlPath: String?

  init(config: HostConfig, destination: String, ssh: String, home: Home, now: @escaping @Sendable () -> Int64) {
    self.config = config
    self.destination = destination
    self.ssh = ssh
    self.home = home
    self.now = now
    current = Status(state: .disconnected, since: now(), failures: 0)
    queue = DispatchQueue(label: "HostLink.\(config.name)")
  }

  var status: Status { lock.withLock { current } }

  /// The host's machine. Its commands fail at once while the link is not `connected`.
  var machine: SSHMachine { SSHMachine { [self] in try shell() } }

  /// The host's machine with a local deadline `slack` seconds after each command's timeout. It reports each
  /// command that got no answer to `check`.
  func machine(slack: Double, check: AnswerCheck?) -> SSHMachine {
    SSHMachine(shell: { [self] in try shell() }, deadlineSlack: slack, check: check)
  }

  /// The ControlPath of the current connection's ssh master, or nil while the link is not `connected`.
  var resolvedControlPath: String? { lock.withLock { current.state == .connected ? connectedControlPath : nil } }

  /// Asks the current connection's ssh master to forward the socket at `remote` on the host to the socket at
  /// `local` on this Mac. The forward lasts as long as the connection. It throws ssh's text when the master
  /// or the host refuses, and for a path that holds a colon, which ssh reads as the end of the path.
  func forward(remote: String, local: String) throws {
    guard let path = resolvedControlPath else {
      throw APIError("\(config.name) is not connected, so sbd can't forward its socket")
    }
    for end in [remote, local] where end.contains(":") || !end.hasPrefix("/") {
      throw APIError("ssh can't forward the socket \(end): its path must be absolute and hold no colon")
    }
    let r = try runCommand(
      ssh,
      ["-T", "-O", "forward", "-R", "\(remote):\(local)", "-o", Self.controlPathOption(path), "--", destination],
      timeout: Self.helperSeconds)
    guard r.status == 0 else { throw Self.failure("the socket forward to \(config.name)", r) }
  }

  /// The open shell. It throws unless the link is `connected`.
  func shell() throws -> RemoteShell {
    try lock.withLock {
      guard current.state == .connected, let open else {
        throw APIError("\(config.name) is not connected: its link is \(current.state.rawValue)")
      }
      return open
    }
  }

  /// Marks the link wanted and starts an attempt. It changes nothing on a link that is
  /// `connecting` or `connected`.
  func connect() {
    lock.withLock {
      switch current.state {
      case .connecting, .connected: return
      case .unreachable: current.failures = 0
      case .disconnected: break
      }
      begin(at: now())
    }
  }

  /// Ends ssh, fails a command in flight, and drops the retry.
  func disconnect() {
    let shell: RemoteShell? = lock.withLock {
      guard current.state != .disconnected else { return nil }
      generation += 1
      current = Status(state: .disconnected, since: now(), failures: 0, connection: current.connection)
      defer { open = nil }
      return open
    }
    shell?.close()
  }

  /// Starts the next attempt when its time has come, and fails an attempt that is late.
  func poll(now: Int64) {
    var timedOut = false
    let shell: RemoteShell? = lock.withLock {
      switch current.state {
      case .unreachable:
        if let retryAt = current.retryAt, now >= retryAt { begin(at: now) }
        return nil
      case .connecting where now - current.since >= Self.attemptLimitMs:
        timedOut = true
        return failed("the host did not answer within \(Self.attemptLimitMs / 1000) s", at: now)
      case .connecting, .connected, .disconnected:
        return nil
      }
    }
    if timedOut { logLine("host \(config.name): the attempt timed out") }
    shell?.close()
  }

  /// The caller holds the lock.
  private func begin(at time: Int64) {
    generation += 1
    current.state = .connecting
    current.since = time
    current.retryAt = nil
    current.error = nil
    let attempt = generation
    queue.async { self.run(attempt) }
  }

  /// Moves the link to `unreachable` and returns the shell to close. The caller holds the lock
  /// and closes the shell after it unlocks, because `close()` reports back to the link.
  private func failed(_ reason: String, at time: Int64) -> RemoteShell? {
    let stayedUp = current.state == .connected && time - current.since >= Self.stableMs
    current.failures = stayedUp ? 1 : current.failures + 1
    current.state = .unreachable
    current.since = time
    current.retryAt = time + retryDelayMs(failuresInARow: current.failures)
    current.error = reason
    generation += 1
    defer { open = nil }
    return open
  }

  /// Fails the attempt or connection, unless the link has moved on from it.
  private func fail(_ attempt: Int, _ reason: String) {
    var current = false
    let shell: RemoteShell? = lock.withLock {
      current = attempt == generation
      return current ? failed(reason, at: now()) : nil
    }
    if current { logLine("host \(config.name): \(reason)") }
    shell?.close()
  }

  private func isCurrent(_ attempt: Int) -> Bool { lock.withLock { attempt == generation } }

  /// One attempt, on `queue`: the ControlPath steps, then ssh. `onReady` and `onClose` can run
  /// on any thread, also before `RemoteShell.init` returns.
  private func run(_ attempt: Int) {
    do {
      if let last = started {
        try waitForExit(last)
        started = nil
      }
      guard isCurrent(attempt) else { return }
      var program = stat()
      guard ssh.hasPrefix("/"), stat(ssh, &program) == 0, program.st_mode & S_IFMT == S_IFREG, access(ssh, X_OK) == 0
      else { throw APIError("ssh not found: \(ssh)") }
      let folder = try openSshFolder()
      defer { close(folder) }
      let socket = try resolveControlPath(inFolder: folder)
      guard isCurrent(attempt) else { return }
      let path = "\(home.sshFolder)/\(socket)"
      try Self.removeStaleSocket(socket, inFolder: folder, path: path)
      let shell = try RemoteShell(
        executable: ssh,
        arguments: ["-M", "-T", "-o", Self.controlPathOption(path)] + Self.options.flatMap { ["-o", $0] }
          + ["--", destination, "exec", "/bin/sh"],
        environment: nil,
        onReady: { [weak self] _ in self?.queue.async { self?.checkControlSocket(attempt) } },
        onClose: { [weak self] reason in self?.fail(attempt, reason) })
      started = shell
      controlPath = path
      let current = lock.withLock {
        if attempt == generation { open = shell }
        return attempt == generation
      }
      if !current { shell.close() }
    } catch {
      fail(attempt, "\(error)")
    }
  }

  /// The last step of an attempt, on `queue`, after the handshake. A master that found its
  /// control path taken runs without a control socket, and this refuses it.
  private func checkControlSocket(_ attempt: Int) {
    guard isCurrent(attempt), let controlPath else { return }
    do {
      let r = try runCommand(
        ssh, ["-T", "-O", "check", "-o", Self.controlPathOption(controlPath), "--", destination],
        timeout: Self.helperSeconds)
      guard r.status == 0 else { throw Self.failure("the control socket check", r) }
    } catch {
      fail(attempt, "\(error)")
      return
    }
    lock.withLock {
      guard attempt == generation, current.state == .connecting else { return }
      current.state = .connected
      current.since = now()
      current.connection += 1
      connectedControlPath = controlPath
    }
  }

  /// An ssh master removes its control socket when it exits. A master that still runs could
  /// therefore remove the socket of the next one, so the next attempt waits for it. `close()`
  /// sends it SIGTERM a second after it closes its stdin.
  private func waitForExit(_ shell: RemoteShell) throws {
    shell.close()
    let deadline = Date().addingTimeInterval(Self.exitSeconds)
    while shell.isRunning {
      if Date() >= deadline { throw APIError("the last ssh process, pid \(shell.pid), has not exited") }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  /// Creates `$SB_HOME/ssh` when it is missing and opens it. The caller closes the descriptor.
  private func openSshFolder() throws -> Int32 {
    let folder = home.sshFolder
    if folder.contains("%") {
      throw APIError("ssh reads a % in a control path as a token, and \(folder) holds one. Move Switchboard's folder")
    }
    if mkdir(folder, 0o700) != 0, errno != EEXIST {
      throw APIError("can't create \(folder): \(UnixSocket.errnoText())")
    }
    let descriptor = Darwin.open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw APIError("\(folder) must be a folder and not a link: \(UnixSocket.errnoText())")
    }
    return descriptor
  }

  /// The name of the destination's control socket in the open `$SB_HOME/ssh`, from `ssh -G`.
  private func resolveControlPath(inFolder descriptor: Int32) throws -> String {
    let folder = home.sshFolder
    let r = try runCommand(
      ssh, ["-T", "-G", "-o", Self.controlPathOption("\(folder)/%C"), "--", destination], timeout: Self.helperSeconds)
    guard r.status == 0 else { throw Self.failure("ssh -G", r) }
    return try Self.controlSocketName(inConfig: r.stdout, sshFolder: folder) { parent in
      var opened = stat()
      var named = stat()
      return fstat(descriptor, &opened) == 0 && lstat(parent, &named) == 0 && opened.st_dev == named.st_dev
        && opened.st_ino == named.st_ino
    }
  }

  /// The `-o` value that sets the control path. ssh splits the value into words as it splits a
  /// line of its config file, so a path with any character outside the plain set goes in
  /// double quotes.
  static func controlPathOption(_ path: String) -> String {
    let plain = path.utf8.allSatisfy { ($0 < 128 && isalnum(Int32($0)) != 0) || "/._%-".utf8.contains($0) }
    if plain { return "ControlPath=\(path)" }
    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "ControlPath=\"\(escaped)\""
  }

  /// The file name of the control path that `ssh -G` printed. It throws unless the output has
  /// one `controlpath` line, with no `%` left in it, that names a direct child of the ssh
  /// folder. `isSshFolder` says whether a path names that folder. ssh prints the folder in
  /// decomposed Unicode, so the link compares the folders themselves. The split is on the `/`
  /// byte, because a `/` before a combining mark is not the character `/`.
  static func controlSocketName(
    inConfig output: String, sshFolder: String, isSshFolder: (String) -> Bool
  ) throws -> String {
    let key = Array("controlpath ".utf8)
    let lines = output.utf8.split(separator: UInt8(ascii: "\n")).filter { $0.starts(with: key) }
    guard lines.count == 1, let path = lines.first?.dropFirst(key.count) else {
      throw APIError("ssh -G printed \(lines.isEmpty ? "no" : "more than one") controlpath line")
    }
    let text = String(decoding: path, as: UTF8.self)
    if path.contains(UInt8(ascii: "%")) { throw APIError("ssh left a % in the control path \(text)") }
    guard path.first == UInt8(ascii: "/"), let slash = path.lastIndex(of: UInt8(ascii: "/")) else {
      throw APIError("the control path \(text) is not a file in \(sshFolder)")
    }
    let parent = path[..<slash]
    let name = path[path.index(after: slash)...]
    guard !name.isEmpty, !name.elementsEqual(".".utf8), !name.elementsEqual("..".utf8),
      isSshFolder(String(decoding: parent, as: UTF8.self))
    else {
      throw APIError("the control path \(text) is not a file in \(sshFolder)")
    }
    return String(decoding: name, as: UTF8.self)
  }

  /// Unlinks a stale socket named `name` in the open folder. `path` is the name that messages
  /// show. Every step goes through the descriptor, so the folder cannot change between the
  /// checks and the unlink.
  static func removeStaleSocket(_ name: String, inFolder descriptor: Int32, path: String) throws {
    var info = stat()
    guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw APIError("can't read \(path): \(UnixSocket.errnoText())")
    }
    guard info.st_mode & S_IFMT == S_IFSOCK else { throw APIError("\(path) exists and is not a socket") }
    switch hasOpenSocket(name, inFolder: descriptor) {
    case .some(false): break
    case .some(true): throw APIError("an ssh master that still runs has the control socket \(path)")
    case nil: throw APIError("can't tell whether an ssh master still has the control socket \(path)")
    }
    guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else {
      throw APIError("can't remove \(path): \(UnixSocket.errnoText())")
    }
  }

  /// Sets the calling thread's working folder to the descriptor's folder, and with -1 back to
  /// the process's. The SDK's headers do not declare it. It is nil when the system has none.
  private static let setThreadFolder: (@convention(c) (Int32) -> Int32)? =
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_fchdir_np").map {
      unsafeBitCast($0, to: (@convention(c) (Int32) -> Int32).self)
    }

  /// Whether a process still has a socket open that is bound to the socket file `name` in the
  /// open folder. It is false only for a file whose socket is closed, as a dead master leaves
  /// one, and nil when the answer is unknown, which includes a file that is gone.
  ///
  /// It connects a datagram socket, because the kernel answers that from the file alone:
  /// ECONNREFUSED when no socket is bound to it, EPROTOTYPE when a stream socket is. A stream
  /// connect proves nothing, because a listener whose accept queue is full, and a socket that
  /// is bound and does not listen yet, also answer it with ECONNREFUSED.
  ///
  /// A connect takes a path and no folder descriptor. So the thread's working folder becomes
  /// the open folder for the length of the connect, and the connect names the file alone.
  static func hasOpenSocket(_ name: String, inFolder folder: Int32) -> Bool? {
    guard !name.utf8.contains(UInt8(ascii: "/")), let setThreadFolder else { return nil }
    let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    guard setThreadFolder(folder) == 0 else { return nil }
    defer { _ = setThreadFolder(-1) }
    var code: Int32 = 0
    let result = try? UnixSocket.withAddress(name) { address, length in
      let result = Darwin.connect(descriptor, address, length)
      code = errno
      return result
    }
    guard let result else { return nil }
    if result == 0 || code == EPROTOTYPE { return true }
    return code == ECONNREFUSED ? false : nil
  }

  private static func failure(_ what: String, _ r: CommandResult) -> APIError {
    let text = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return APIError(text.isEmpty ? "\(what) exited with status \(r.status)" : "\(what) failed: \(text)")
  }
}
