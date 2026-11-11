import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

@Suite struct TerminalHostTests {
  @Test func readsTmuxsOwnNoServerReportsAsNoServer() {
    #expect(TerminalHost.isNoServer(APIError("tmux list-panes: no server running on /tmp/s")))
    #expect(
      TerminalHost.isNoServer(APIError("tmux list-panes: error connecting to /tmp/s (No such file or directory)")))
  }

  @Test(.enabled(if: findExecutable("tmux") != nil))
  func readsTheErrorThatARealTmuxPrintsForAMissingSocketAsNoServer() throws {
    let tmux = try #require(findExecutable("tmux"))
    let socket = "/tmp/sb-\(getpid())-none/s"
    let r = try runCommand(tmux, ["-S", socket, "list-panes", "-a"])
    #expect(r.status != 0)
    // TerminalHost.run reports a failed tmux command in this form.
    let error = APIError("tmux list-panes: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    #expect(TerminalHost.isNoServer(error))
  }

  @Test func doesNotReadOtherFailuresAsNoServer() {
    #expect(!TerminalHost.isNoServer(APIError("tmux list-panes: error connecting to /tmp/s (Permission denied)")))
    // Starting tmux failed, as with a missing binary. tmux never ran, so it reported nothing about a server.
    #expect(!TerminalHost.isNoServer(APIError("tmux list-panes: /tmp/tmux.conf: No such file or directory")))
    #expect(!TerminalHost.isNoServer(CocoaError(.fileNoSuchFile)))
    #expect(!TerminalHost.isNoServer(APIError("The file doesn't exist: No such file or directory")))
  }

  @Test func readsOnlyANewSessionDuplicateAsADuplicateSession() {
    #expect(TerminalHost.isDuplicateSession(APIError("tmux new-session: duplicate session: a")))
    #expect(!TerminalHost.isDuplicateSession(APIError("tmux new-session: no server running on /tmp/s")))
    #expect(!TerminalHost.isDuplicateSession(APIError("tmux respawn-pane: duplicate session: a")))
    #expect(!TerminalHost.isDuplicateSession(CocoaError(.fileNoSuchFile)))
  }
}

@Suite struct TerminalHostCreateTests {
  private func host() throws -> TerminalHost {
    var template = Array("/tmp/sbh.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    return try TerminalHost(home: Home(path: dir), config: Config())
  }

  private func stop(_ host: TerminalHost) {
    _ = try? host.run(["kill-server"])
    try? FileManager.default.removeItem(atPath: (host.socket as NSString).deletingLastPathComponent)
  }

  private func waitUntil(_ what: String, _ ok: () -> Bool) throws {
    for _ in 0..<100 {
      if ok() { return }
      usleep(100_000)
    }
    throw APIError("timed out waiting for \(what)")
  }

  @Test(.enabled(if: findExecutable("tmux") != nil), .timeLimit(.minutes(1)))
  func createLeavesARunningPaneRunning() throws {
    let host = try host()
    defer { stop(host) }
    try host.create("a", cwd: "/tmp", env: [:], command: "sleep 60")
    let pid = try #require(try host.checkedPanes()["a"]).pid
    try host.create("a", cwd: "/tmp", env: [:], command: "sleep 60")
    #expect((try? host.checkedPanes())?["a"]?.pid == pid)
  }

  @Test(.enabled(if: findExecutable("tmux") != nil), .timeLimit(.minutes(1)))
  func createStartsADeadPaneAgain() throws {
    let host = try host()
    defer { stop(host) }
    try host.create("a", cwd: "/tmp", env: [:], command: "true")
    try waitUntil("the pane to exit") { (try? host.checkedPanes())?["a"]?.dead == true }
    try host.create("a", cwd: "/tmp", env: [:], command: "sleep 60")
    #expect((try? host.checkedPanes())?["a"]?.dead == false)
  }
}

/// Records each command instead of running it. A command with the argument `failing` exits 1.
private final class RecordingMachine: Machine, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(executable: String, args: [String], env: [String: String]?, input: Data?)] = []

  var commands: [(executable: String, args: [String], env: [String: String]?, input: Data?)] {
    lock.withLock { recorded }
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    lock.withLock { recorded.append((executable, args, env, input)) }
    return args.contains("failing")
      ? CommandResult(status: 1, stdout: "", stderr: "no such command\n")
      : CommandResult(status: 0, stdout: "out", stderr: "")
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? { nil }
  func size(_ path: String) -> UInt64? { nil }
  func exists(_ path: String) -> Bool { false }
  func isFolder(_ path: String) -> Bool { false }
  func modified(_ path: String) -> Date? { nil }
  func list(_ folder: String) -> [String] { [] }
  func createFolder(_ path: String) throws {}
  func signal(_ pid: Int, _ signal: Int32) {}
}

@Suite struct TerminalHostMachineTests {
  @Test func runsEveryTmuxCommandOnItsMachine() throws {
    var template = Array("/tmp/sbh.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var config = Config()
    config.tmux = "/bin/sh"
    let machine = RecordingMachine()
    let host = try TerminalHost(home: Home(path: dir), config: config, machine: machine)
    let before = machine.commands.count

    #expect(try host.run(["load-buffer", "-"], input: Data("hi".utf8)) == "out")

    let command = try #require(machine.commands.last)
    #expect(machine.commands.count == before + 1)
    #expect(command.executable == "/bin/sh")
    #expect(command.args == ["-S", "\(dir)/tmux.sock", "-f", "\(dir)/tmux.conf", "load-buffer", "-"])
    #expect(command.env?["TERM"] == "xterm-256color")
    #expect(command.input == Data("hi".utf8))
  }

  @Test func reportsWhatTheMachinesTmuxPrintedWhenItFails() throws {
    var template = Array("/tmp/sbh.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var config = Config()
    config.tmux = "/bin/sh"
    let host = try TerminalHost(home: Home(path: dir), config: config, machine: RecordingMachine())

    let error = #expect(throws: APIError.self) { try host.run(["failing"]) }
    #expect(error?.description == "tmux failing: no such command")
  }
}
