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
