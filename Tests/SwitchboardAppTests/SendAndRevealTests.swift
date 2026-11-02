import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

struct Boom: Error {}

@MainActor
@Suite struct BoardModelSend {
  /// Waits for the main-actor work that `perform` queues after the request ends.
  func settle(_ done: () -> Bool) async {
    for _ in 0..<300 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
  }

  @Test func doesNotReportASendThatFailed() async {
    _ = NSApplication.shared
    let model = BoardModel()
    model.send = { _, _ in throw Boom() }
    let sent = Counter()
    model.send("a", "hello") { sent.increment() }
    await settle { model.actionError != nil }
    #expect(model.actionError != nil)
    #expect(sent.value == 0)
  }

  @Test func reportsASendThatSucceeded() async {
    _ = NSApplication.shared
    let model = BoardModel()
    model.send = { _, _ in .null }
    let sent = Counter()
    model.send("a", "hello") { sent.increment() }
    await settle { sent.value > 0 }
    #expect(sent.value == 1)
  }
}

@MainActor
@Suite struct BoardModelReveal {
  @Test func selectsTheSessionAndOpensTheWindow() {
    let model = appliedModel([needsItem("a"), needsItem("b")])
    let opened = Counter()
    model.showWindow = { opened.increment() }
    model.reveal("b")
    #expect(model.selection == "b")
    #expect(opened.value == 1)
  }
}
