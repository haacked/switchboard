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

  @Test func ignoresASecondStartNowWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.startNow("a")
      model.startNow("a")
      #expect(model.startingNow == ["a"])
    }
    #expect(sent.count == 1)
  }

  @Test func aStartThatStillWaitsShowsWhy() async throws {
    let model = offlineModel()
    var start = LiveStatus.QueuedStart(session: "a", name: "alpha", since: 1)
    start.reason = "the cap of 1 is full and no idle session can stop"
    let reply = try JSON(encoding: LiveStatus(cap: 1, live: [], queued: [start]))
    model.send = { _, _ in reply }

    model.startNow("a")
    await settle { model.actionError != nil }

    #expect(model.actionError == "Start Now: the cap of 1 is full and no idle session can stop")
  }
}
