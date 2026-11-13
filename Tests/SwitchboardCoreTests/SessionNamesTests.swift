import Testing

@testable import SwitchboardCore

@Suite struct SessionNamesTests {
  @Test func mentionPutsTheNameFirst() {
    #expect(sessionMention(name: "zsh-startup-for-switchboard", id: "seb4ec") == "zsh-startup-for-switchboard (seb4ec)")
  }
}
