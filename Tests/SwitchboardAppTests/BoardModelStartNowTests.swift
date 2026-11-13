import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelStartNow {
  @Test func startNowSendsLiveNextWithTheSession() async {
    let sent = await firstRequest { $0.startNow("a") }

    #expect(sent.op == "live-next")
    #expect(sent.args == ["session": "a"])
  }
}
