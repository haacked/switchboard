import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct StartupTests {
  /// `hold-start` keeps the stub before its SessionStart for as long as the test needs, so the send always
  /// arrives while claude starts, however slowly the runner creates the session.
  @Test func aMessageSentWhileClaudeStartsArrivesAfterItsPrompt() throws {
    let sbd = try Instance()
    sbd.hold("hold-start")
    let s = try sbd.new()
    #expect(try sbd.sb("send", s.id, "while it starts") == "queued\n")
    try sbd.release("hold-start")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: while it starts" }
  }
}
