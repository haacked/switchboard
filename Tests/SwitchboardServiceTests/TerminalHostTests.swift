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
}

@Suite struct TerminalHostCreateTests {
  private func host() throws -> TerminalHost {
    var template = Array("/tmp/sbh.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    return try TerminalHost(home: Home(path: dir), config: Config())
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
    defer { _ = try? host.run(["kill-server"]) }
    try host.create("a", cwd: "/tmp", env: [:], command: "sleep 60")
    let pid = try #require(try host.checkedPanes()["a"]).pid
    try host.create("a", cwd: "/tmp", env: [:], command: "sleep 60")
    #expect((try? host.checkedPanes())?["a"]?.pid == pid)
  }

  @Test(.enabled(if: findExecutable("tmux") != nil), .timeLimit(.minutes(1)))
  func createStartsADeadPaneAgain() throws {
    let host = try host()
    defer { _ = try? host.run(["kill-server"]) }
    try host.create("a", cwd: "/tmp", env: [:], command: "true")
    try waitUntil("the pane to exit") { (try? host.checkedPanes())?["a"]?.dead == true }
    try host.create("a", cwd: "/tmp", env: [:], command: "sleep 60")
    #expect((try? host.checkedPanes())?["a"]?.dead == false)
  }
}
