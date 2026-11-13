import Foundation
import SwitchboardCore

/// A host that sbd reaches through one `RemoteShell`. Each member runs as one framed command.
/// Paths go to the host as given, so `~` is not expanded.
///
/// When the host is not connected, `run` and `createFolder` throw, and the other members return
/// nil, false, or none. So a nil, false, or empty result is a fact about the host only when the
/// host's link is connected at the time of the call. A caller must check the link before it
/// decides anything from such a result.
///
/// A file member also returns nil, false, or none when its script ends with a status that the script
/// does not choose: the host's timeout ended it, or the host could not run it. The machine reports
/// that call to its `AnswerCheck` as a command that got no answer. It reports a `run` that a signal
/// ended the same way, because the host's timeout ends a program with a signal.
///
/// It differs from `LocalMachine` in these ways. A missing program returns status 126 or 127
/// where `LocalMachine` throws. A program that its timeout ends returns 143, or 137 after
/// SIGKILL, where `LocalMachine` returns 15. Under a set `env`, the program may also see `PWD`,
/// `SHLVL`, and `_`. `read` and `size` return nil for anything but a regular file.
struct SSHMachine: Machine {
  private static let fileTimeout = 30.0
  /// A local deadline this long after a command's timeout leaves the host time to answer.
  static let defaultDeadlineSlack = 15.0

  /// Signal numbers differ between macOS and Linux, so the host gets a name and never a number.
  private static let signalNames: [Int32: String] = [
    SIGHUP: "HUP", SIGINT: "INT", SIGQUIT: "QUIT", SIGKILL: "KILL", SIGTERM: "TERM", SIGSTOP: "STOP",
    SIGCONT: "CONT", SIGUSR1: "USR1", SIGUSR2: "USR2",
  ]

  /// The statuses that a shell gives a program that SIGKILL or SIGTERM ended.
  private static let signalStatuses: Set<Int32> = [137, 143]

  private let shell: @Sendable () throws -> RemoteShell
  private let deadlineSlack: Double
  private let check: AnswerCheck?

  /// `shell` returns the host's open shell, and throws when the host is not connected. `check` gets the error
  /// of each command that got no answer from the host.
  init(
    shell: @escaping @Sendable () throws -> RemoteShell, deadlineSlack: Double = SSHMachine.defaultDeadlineSlack,
    check: AnswerCheck? = nil
  ) {
    self.shell = shell
    self.deadlineSlack = deadlineSlack
    self.check = check
  }

  /// Sends one command. An error means that the host gave no answer.
  private func send(
    _ command: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> RemoteResult {
    do {
      return try shell().run(
        command, env: env, input: input, timeout: timeout, deadline: timeout.map { $0 + deadlineSlack })
    } catch {
      check?.missed(error)
      throw error
    }
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    let r = try send([executable] + args, env: env, input: input, timeout: timeout)
    if Self.signalStatuses.contains(r.status) {
      unanswered("\(executable) ended with status \(r.status), which a signal or its timeout gives")
    }
    return CommandResult(
      status: r.status, stdout: String(decoding: r.stdout, as: UTF8.self),
      stderr: String(decoding: r.stderr, as: UTF8.self))
  }

  private func unanswered(_ what: String) {
    logLine("host: \(what)")
    check?.missed(APIError(what))
  }

  private func fileCommand(_ command: [String]) throws -> RemoteResult {
    try send(command, env: nil, input: nil, timeout: Self.fileTimeout)
  }

  /// The command's stdout when it exits 0, and nil when it exits with `RemoteShellProtocol.noStatus`, which is
  /// how a file script answers no. Any other status is not the script's answer, and neither is a host that is
  /// not connected. The result is nil then too, and the check gets the call.
  private func output(_ what: String, _ command: [String]) -> Data? {
    do {
      let r = try fileCommand(command)
      if r.status == 0 { return r.stdout }
      if r.status != RemoteShellProtocol.noStatus { unanswered("\(what) ended with status \(r.status)") }
      return nil
    } catch {
      logLine("host: \(what) did not run: \(error)")
      return nil
    }
  }

  private func stat(_ what: String, _ command: (RemoteShellProtocol.StatFormat) -> [String]) -> (
    size: UInt64, modified: Date
  )? {
    // Before the handshake the format is unknown, and `run` then throws for every command.
    let format = (try? shell())?.ready?.stat ?? .bsd
    guard let text = output(what, command(format)) else { return nil }
    let parsed = RemoteShellProtocol.parseStat(String(decoding: text, as: UTF8.self))
    if parsed == nil { unanswered("\(what) printed no size and time") }
    return parsed
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    // GNU `head -c -N` prints all but the last N bytes.
    if let count, count < 0 { return nil }
    return output("read", RemoteShellProtocol.read(path, from: offset, count: count))
  }

  func size(_ path: String) -> UInt64? {
    stat("size") { RemoteShellProtocol.size(path, $0) }?.size
  }

  func exists(_ path: String) -> Bool {
    output("exists", RemoteShellProtocol.exists(path)) != nil
  }

  func isFolder(_ path: String) -> Bool {
    output("isFolder", RemoteShellProtocol.isFolder(path)) != nil
  }

  func modified(_ path: String) -> Date? {
    stat("modified") { RemoteShellProtocol.modified(path, $0) }?.modified
  }

  func list(_ folder: String) -> [String] {
    (output("list", RemoteShellProtocol.list(folder)) ?? Data())
      .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
  }

  func createFolder(_ path: String) throws {
    let r = try fileCommand(RemoteShellProtocol.createFolder(path))
    guard r.status == 0 else {
      let text = String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw APIError(text.isEmpty ? "mkdir on the host exited with status \(r.status)" : text)
    }
  }

  func signal(_ pid: Int, _ signal: Int32) {
    guard Processes.isValidPid(pid) else { return }
    guard let name = Self.signalNames[signal] else {
      logLine("host: signal \(signal) has no name that a host knows, so pid \(pid) got nothing")
      return
    }
    do {
      // The shell's `kill` exits 1 when it can't signal the process, which is its answer.
      let status = try fileCommand(RemoteShellProtocol.signal(name: name, pid: pid)).status
      if status > 1 { unanswered("signal ended with status \(status)") }
    } catch {
      logLine("host: signal did not run: \(error)")
    }
  }
}
