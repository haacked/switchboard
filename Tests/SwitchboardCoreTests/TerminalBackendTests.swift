import Testing

@testable import SwitchboardCore

@Suite struct TerminalBackendChoice {
  @Test func defaultsToGhostty() {
    #expect(TerminalBackend.choose(environment: [:], ghosttyAvailable: true) == .init(backend: .ghostty, note: nil))
    #expect(
      TerminalBackend.choose(environment: ["SB_TERMINAL": ""], ghosttyAvailable: true)
        == .init(backend: .ghostty, note: nil))
  }

  @Test func theDefaultFallsBackToSwiftTermWhenTheBuildLacksGhostty() {
    let choice = TerminalBackend.choose(environment: [:], ghosttyAvailable: false)
    #expect(choice.backend == .swiftTerm)
    #expect(choice.note?.contains("bin/build-ghostty") == true)
  }

  @Test func ghosttyNeedsTheRequestAndTheLibrary() {
    let env = ["SB_TERMINAL": "ghostty"]
    #expect(TerminalBackend.choose(environment: env, ghosttyAvailable: true).backend == .ghostty)
    let missing = TerminalBackend.choose(environment: env, ghosttyAvailable: false)
    #expect(missing.backend == .swiftTerm)
    #expect(missing.note?.contains("bin/build-ghostty") == true)
  }

  @Test func swiftTermCanBeRequestedExplicitly() {
    for available in [true, false] {
      #expect(
        TerminalBackend.choose(environment: ["SB_TERMINAL": "SwiftTerm"], ghosttyAvailable: available)
          == .init(backend: .swiftTerm, note: nil))
    }
  }

  @Test func anUnknownNameFallsBackAndSaysSo() {
    let choice = TerminalBackend.choose(environment: ["SB_TERMINAL": "kitty"], ghosttyAvailable: true)
    #expect(choice.backend == .ghostty)
    #expect(choice.note?.contains("kitty") == true)
    let without = TerminalBackend.choose(environment: ["SB_TERMINAL": "kitty"], ghosttyAvailable: false)
    #expect(without.backend == .swiftTerm)
    #expect(without.note?.contains("kitty") == true)
  }
}

@Suite struct AttachCommandLine {
  @Test func quotesEachWord() {
    let terminals = Terminals(
      tmux: "/opt/homebrew/bin/tmux", socket: "/Users/a b/.sb/tmux.sock", claude: "sb-1", shell: "sb-1-sh")
    #expect(
      terminals.attachCommandLine(.shell)
        == "'/opt/homebrew/bin/tmux' '-S' '/Users/a b/.sb/tmux.sock' 'attach-session' '-t' '=sb-1-sh'")
  }

  @Test func matchesTheArgvForTheClaudePane() {
    let terminals = Terminals(tmux: "tmux", socket: "/s", claude: "c", shell: "s")
    #expect(terminals.attachCommand(.claude) == ["tmux", "-S", "/s", "attach-session", "-t", "=c"])
    #expect(terminals.attachCommandLine(.claude) == "'tmux' '-S' '/s' 'attach-session' '-t' '=c'")
  }
}
