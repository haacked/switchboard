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

  @Test func ignoresASecondSendWhileTheFirstIsPending() async {
    _ = NSApplication.shared
    let model = BoardModel()
    let requests = Counter()
    model.send = { _, _ in
      requests.increment()
      Thread.sleep(forTimeInterval: 0.2)
      return .null
    }
    let sent = Counter()
    model.send("a", "hello") { sent.increment() }
    model.send("a", "hello") { sent.increment() }
    #expect(model.sending == ["a"])
    await settle { sent.value > 0 }
    await settle { model.sending.isEmpty }
    #expect(requests.value == 1)
    #expect(sent.value == 1)
    #expect(model.sending.isEmpty)
  }

  @Test func allowsASendAfterAFailedOne() async {
    _ = NSApplication.shared
    let model = BoardModel()
    model.send = { _, _ in throw Boom() }
    model.send("a", "hello")
    await settle { model.actionError != nil }
    await settle { model.sending.isEmpty }
    #expect(model.sending.isEmpty)
  }
}

@MainActor
@Suite struct MessageDraft {
  @Test func clearsAnUnchangedDraft() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    draft.clear(ifStill: "hello")
    #expect(draft.text.isEmpty)
  }

  @Test func clearsADraftThatOnlyGainedTrailingWhitespace() {
    let draft = MessageField.Draft()
    draft.text = "hello \n"
    draft.clear(ifStill: "hello")
    #expect(draft.text.isEmpty)
  }

  @Test func keepsTextTypedAfterTheSend() {
    let draft = MessageField.Draft()
    draft.text = "hello again"
    draft.clear(ifStill: "hello")
    #expect(draft.text == "hello again")
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
