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
/// It differs from `LocalMachine` in these ways. A missing program returns status 126 or 127
/// where `LocalMachine` throws. A program that its timeout ends returns 143, or 137 after
/// SIGKILL, where `LocalMachine` returns 15. Under a set `env`, the program may also see `PWD`,
/// `SHLVL`, and `_`. `read` and `size` return nil for anything but a regular file.
struct SSHMachine: Machine {
  private static let fileTimeout = 30.0
  /// A local deadline this long after a command's timeout leaves the host time to answer.
  private static let deadlineSlack = 15.0

  /// Signal numbers differ between macOS and Linux, so the host gets a name and never a number.
  private static let signalNames: [Int32: String] = [
    SIGHUP: "HUP", SIGINT: "INT", SIGQUIT: "QUIT", SIGKILL: "KILL", SIGTERM: "TERM", SIGSTOP: "STOP",
    SIGCONT: "CONT", SIGUSR1: "USR1", SIGUSR2: "USR2",
  ]

  private let shell: @Sendable () throws -> RemoteShell

  /// The host's open shell. It throws when the host is not connected.
  init(shell: @escaping @Sendable () throws -> RemoteShell) {
    self.shell = shell
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    let r = try shell().run(
      [executable] + args, env: env, input: input, timeout: timeout,
      deadline: timeout.map { $0 + Self.deadlineSlack })
    return CommandResult(
      status: r.status, stdout: String(decoding: r.stdout, as: UTF8.self),
      stderr: String(decoding: r.stderr, as: UTF8.self))
  }

  private func fileCommand(_ command: [String]) throws -> RemoteResult {
    try shell().run(
      command, env: nil, input: nil, timeout: Self.fileTimeout, deadline: Self.fileTimeout + Self.deadlineSlack)
  }

  /// The command's stdout when it exits 0. It is nil for any other status and when the host
  /// is not connected, which it logs.
  private func output(_ what: String, _ command: [String]) -> Data? {
    do {
      let r = try fileCommand(command)
      return r.status == 0 ? r.stdout : nil
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
    return output(what, command(format)).flatMap { RemoteShellProtocol.parseStat(String(decoding: $0, as: UTF8.self)) }
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
    _ = output("signal", RemoteShellProtocol.signal(name: name, pid: pid))
  }
}
