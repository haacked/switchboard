import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelAcknowledge {
  @Test func acknowledgeSendsAckWithTheSession() async {
    let sent = await firstRequest { $0.acknowledge("a") }

    #expect(sent.op == "ack")
    #expect(sent.args == ["session": "a"])
  }

  @Test func undoSendsAckWithUndo() async {
    let sent = await firstRequest { $0.acknowledge("a", undo: true) }

    #expect(sent.op == "ack")
    #expect(sent.args == ["session": "a", "undo": true])
  }

  @Test func ignoresASecondAcknowledgeWhileTheFirstRuns() {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }
    model.acknowledge("a")
    model.acknowledge("a", undo: true)
    #expect(model.acknowledging == ["a"])
    for _ in 0..<100 where sent.value == 0 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sent.value == 1)
  }

  @Test func acknowledgingOneSessionLeavesAnotherFree() {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }
    model.acknowledge("a")
    model.acknowledge("b")
    #expect(model.acknowledging == ["a", "b"])
    for _ in 0..<100 where sent.value < 2 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sent.value == 2)
  }

  @Test func theAcknowledgingSetEmptiesWhenTheRequestFinishes() async throws {
    let model = offlineModel()
    model.send = { _, _ in .null }

    model.acknowledge("a")
    for _ in 0..<100 where !model.acknowledging.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.acknowledging.isEmpty)
  }

  @Test func theAcknowledgingSetEmptiesWhenTheRequestFails() async throws {
    struct Refused: Error {}
    let model = offlineModel()
    model.send = { _, _ in throw Refused() }

    model.acknowledge("a")
    for _ in 0..<100 where !model.acknowledging.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.acknowledging.isEmpty)
  }

  func inboxModel(focus: String) -> BoardModel {
    let model = appliedModel([needsItem("a"), needsItem("b"), needsItem("c")])
    model.send = { _, _ in .null }
    model.show(.inbox)
    model.inboxFocus = focus
    return model
  }

  @Test func acknowledgingTheCurrentItemFocusesTheNextOne() {
    let model = inboxModel(focus: "b")
    model.acknowledge("b")
    #expect(model.inboxFocus == "c")
  }

  @Test func acknowledgingAnotherItemLeavesTheFocus() {
    let model = inboxModel(focus: "b")
    model.acknowledge("c")
    #expect(model.inboxFocus == "b")
  }

  @Test func undoLeavesTheFocus() {
    let model = inboxModel(focus: "b")
    model.acknowledge("b", undo: true)
    #expect(model.inboxFocus == "b")
  }

  @Test func acknowledgeTargetIsTheCurrentInboxItemWhileTheInboxShows() {
    #expect(inboxModel(focus: "b").acknowledgeTarget?.id == "b")
  }

  /// A selection shows the session's terminals in place of the Inbox.
  @Test func acknowledgeTargetIsTheSelectionOutsideTheInbox() {
    let model = inboxModel(focus: "b")
    model.selection = "a"
    #expect(model.acknowledgeTarget?.id == "a")
  }

  @Test func undoDoesNotNotifyAboutTheRestoredItem() async throws {
    var acked = needsItem("a", state: .waiting)
    acked.acknowledged = true
    let model = appliedModel([acked])
    let restored = try JSON(encoding: needsItem("a"))
    model.send = { _, _ in restored }

    model.acknowledge("a", undo: true)
    for _ in 0..<100 where !model.acknowledging.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.sessionsToNotify([needsItem("a")]).isEmpty)
  }
}

/// Whether the Inbox makes Acknowledge the item's primary button.
@Suite struct InformationalItems {
  func item(
    state: AttentionState = .needsYou, kind: TriageKind = .info, options: [TriageOption] = [], card: Bool = false,
    openPrompt: Bool = false, triage: Bool = true
  ) throws -> SessionSummary {
    var s = needsItem("a", state: state)
    s.triage = triage ? TriageItem(title: "Done", kind: kind, summary: "", options: options, source: .summary) : nil
    s.openPrompt = openPrompt
    if card {
      let json: JSON = [
        "id": 3, "session": "a", "kind": "permission", "tool": "Bash", "summary": "`ls`", "input": [:],
        "questions": [], "since": 0, "deferred": false, "hookClosed": false,
      ]
      s.cards = [try JSONCoding.convert(json, to: Card.self)]
    }
    return s
  }

  static let option = TriageOption(label: "Go", message: "go")

  @Test func needsYouInfoItemIsInformational() throws {
    #expect(try item().isInformational)
  }

  @Test(arguments: [TriageKind.decision, .question, .approval, .review, .action])
  func needsYouItemWithNoOptionsIsInformational(_ kind: TriageKind) throws {
    #expect(try item(kind: kind).isInformational)
  }

  /// An item with options has its own primary button, so Acknowledge stays quiet.
  @Test(arguments: [TriageKind.decision, .question, .approval, .review, .action, .info])
  func itemWithOptionsIsNotInformational(_ kind: TriageKind) throws {
    #expect(try !item(kind: kind, options: [InformationalItems.option]).isInformational)
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .needsYou })
  func itemOutsideNeedsYouIsNotInformational(_ state: AttentionState) throws {
    #expect(try !item(state: state).isInformational)
  }

  @Test func sessionWithACardIsNotInformational() throws {
    #expect(try !item(card: true).isInformational)
  }

  @Test func sessionWithAnOpenDialogIsNotInformational() throws {
    #expect(try !item(openPrompt: true).isInformational)
  }

  @Test func sessionWithoutATriageItemIsNotInformational() throws {
    #expect(try !item(triage: false).isInformational)
  }

  /// The step view's Next and Submit take ⇧⌘Return, so Acknowledge stays quiet.
  @Test func itemWithDecisionsToStepThroughIsNotInformational() throws {
    var s = try item(kind: .decision)
    let yesNo = [PendingDecision.Option(label: "Yes"), PendingDecision.Option(label: "No")]
    s.triage?.decisions = [1, 2].map {
      PendingDecision(number: $0, header: "H\($0)", question: "Q\($0)?", options: yesNo)
    }

    #expect(!s.isInformational)
  }
}
