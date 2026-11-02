import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct TriageDetailPane {
  func session(waitsToStart: Bool) -> SessionSummary {
    var s = needsItem("a")
    if waitsToStart { s.followup = Followup(prompt: "p") }
    return s
  }

  @Test func showsTheSummaryOfAnUnstartedFollowUpWhileTerminalIsOn() {
    let s = session(waitsToStart: true)
    #expect(s.waitsToStart)
    #expect(TriageDetail.pane(for: s, showingTerminal: true) == .summary)
  }

  @Test func showsTheTerminalOfAStartedFollowUpWhileTerminalIsOn() {
    var s = session(waitsToStart: true)
    s.followup?.started = 1
    #expect(!s.waitsToStart)
    #expect(TriageDetail.pane(for: s, showingTerminal: true) == .terminal)
  }

  @Test func showsTheTerminalOfAStartedSessionWhileTerminalIsOn() {
    #expect(TriageDetail.pane(for: session(waitsToStart: false), showingTerminal: true) == .terminal)
  }

  @Test func showsTheSummaryWhileTerminalIsOff() {
    #expect(TriageDetail.pane(for: session(waitsToStart: false), showingTerminal: false) == .summary)
  }
}
