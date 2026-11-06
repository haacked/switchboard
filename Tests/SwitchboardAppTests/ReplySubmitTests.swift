import Foundation
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
private final class Field {
  var text: String
  init(_ text: String) { self.text = text }
  var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
}

/// A model whose requests wait until the test signals the semaphore.
@MainActor
private func heldModel() -> (BoardModel, DispatchSemaphore) {
  let model = offlineModel()
  let release = DispatchSemaphore(value: 0)
  model.send = { _, _ in
    release.wait()
    return .null
  }
  return (model, release)
}

@MainActor
@Suite struct ReplySubmit {

  private func submit(_ field: Field, to model: BoardModel) {
    ReplyOption.submit(field.binding, session: "a", ref: "summary:1", option: 2, to: model)
  }

  @Test func failedChooseKeepsTheTypedText() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    let field = Field("Use SQLite.")

    submit(field, to: model)
    await settle { model.actionError != nil && model.choosing.isEmpty }

    #expect(model.actionError != nil)
    #expect(field.text == "Use SQLite.")
  }

  @Test func successfulChooseClearsTheTypedText() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let field = Field("  Use SQLite.\n")

    submit(field, to: model)
    await settle { field.text.isEmpty }

    #expect(field.text.isEmpty)
  }

  @Test func successfulChooseSendsTheTrimmedText() async {
    let sent = await firstRequest { model in
      submit(Field("  Use SQLite.\n"), to: model)
    }

    #expect(sent.args["text"] == "Use SQLite.")
  }

  @Test func textEditedWhileTheChooseRunsSurvivesItsSuccess() async {
    let (model, release) = heldModel()
    let field = Field("Use SQLite.")

    submit(field, to: model)
    field.text = "Use SQLite, and Postgres later."
    release.signal()
    await settle { model.choosing.isEmpty }

    #expect(model.actionError == nil)
    #expect(field.text == "Use SQLite, and Postgres later.")
  }

  @Test(arguments: ["", "  \n\t"])
  func blankTextSendsNothing(_ text: String) async {
    let sent = await firstRequest { model in
      submit(Field(text), to: model)
      #expect(model.choosing.isEmpty)
      model.choose("a", ref: "summary:1", option: 1, action: .dismiss)
    }

    #expect(sent.count == 1)
    #expect(sent.args["option"] == "1")
  }
}

@MainActor
@Suite struct BoardModelChooseSent {

  @Test func doesNotReportAChooseThatTheDuplicateGuardDropped() async {
    let (model, release) = heldModel()
    let first = Counter()
    let second = Counter()

    model.choose("a", ref: "summary:1", option: 2, action: .reply, text: "Yes") { first.increment() }
    model.choose("a", ref: "summary:1", option: 2, action: .reply, text: "Yes") { second.increment() }
    release.signal()
    await settle { model.choosing.isEmpty }

    #expect(first.value == 1)
    #expect(second.value == 0)
  }

  @Test func doesNotReportAChooseThatARunningMergeDropped() async {
    let (model, release) = heldModel()
    let sent = Counter()

    model.merge("a")
    model.choose("a", ref: "summary:1", option: 2, action: .merge) { sent.increment() }
    release.signal()
    await settle { model.merging.isEmpty }

    #expect(sent.value == 0)
  }
}
