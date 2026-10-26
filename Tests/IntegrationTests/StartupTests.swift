import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct StartupTests {
  @Test func aMessageSentWhileClaudeStartsArrivesAfterItsPrompt() throws {
    let sbd = try Instance(shell: Instance.slowShell)
    let s = try sbd.new()
    #expect(try sbd.sb("send", s.id, "while it starts") == "queued\n")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: while it starts" }
  }
}
