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

  @Test func doesNotReadOtherFailuresAsNoServer() {
    #expect(!TerminalHost.isNoServer(APIError("tmux list-panes: error connecting to /tmp/s (Permission denied)")))
    // Starting tmux failed, as with a missing binary. tmux never ran, so it reported nothing about a server.
    #expect(!TerminalHost.isNoServer(APIError("tmux list-panes: /tmp/tmux.conf: No such file or directory")))
    #expect(!TerminalHost.isNoServer(CocoaError(.fileNoSuchFile)))
    #expect(!TerminalHost.isNoServer(APIError("The file doesn't exist: No such file or directory")))
  }
}
