import Testing

@testable import SwitchboardCore

@Suite struct AttachCommand {
  let terminals = Terminals(tmux: "tmux", socket: "/s", claude: "c", shell: "s")

  @Test func attachesToTheClaudePaneByExactName() {
    #expect(terminals.attachCommand(.claude) == ["tmux", "-S", "/s", "attach-session", "-t", "=c"])
  }

  @Test func attachesToTheShellPaneByExactName() {
    #expect(terminals.attachCommand(.shell) == ["tmux", "-S", "/s", "attach-session", "-t", "=s"])
  }
}
