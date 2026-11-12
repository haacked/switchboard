import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelSuggestions {
  @Test func acceptSendsGroupSuggestWithTheId() async {
    let sent = await firstRequest { $0.acceptSuggestion("merge:g1:g2") }

    #expect(sent.op == "group-suggest")
    #expect(sent.args == ["accept": "merge:g1:g2"])
  }

  @Test func declineSendsGroupSuggestWithTheId() async {
    let sent = await firstRequest { $0.declineSuggestion("dependency:s1:g1") }

    #expect(sent.op == "group-suggest")
    #expect(sent.args == ["decline": "dependency:s1:g1"])
  }

  func suggestion(_ id: String) -> GroupSuggestion {
    GroupSuggestion(id: id, name: "Flags", group: nil, sessions: ["a", "b"], reason: "branches start with \(id)")
  }

  @Test func aDeclineThatSbdTakesRemovesTheRowFromTheSuggestions() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    model.suggestions = ["prefix:flag-evaluations", "prefix:billing-retry"].map(suggestion)

    model.declineSuggestion("prefix:flag-evaluations")
    await settle { model.suggestions.count == 1 }

    #expect(model.suggestions.map(\.id) == ["prefix:billing-retry"])
  }

  @Test func aDeclineThatSbdRefusesKeepsTheRow() async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("no suggestion prefix:flag-evaluations") }
    model.suggestions = ["prefix:flag-evaluations", "prefix:billing-retry"].map(suggestion)

    model.declineSuggestion("prefix:flag-evaluations")
    await settle { model.actionError != nil }

    #expect(model.actionError != nil)
    #expect(model.suggestions.map(\.id) == ["prefix:flag-evaluations", "prefix:billing-retry"])
  }

  @Test func theSuggestionButtonHasNoLabelWithoutSuggestions() {
    #expect(GroupSuggestionButton.label(count: 0) == nil)
  }

  @Test func theSuggestionButtonsLabelCountsOneSuggestion() throws {
    let label = try #require(GroupSuggestionButton.label(count: 1))

    #expect(label.contains("1"))
    #expect(label.hasSuffix("suggestion"))
  }

  @Test func theSuggestionButtonsLabelCountsThreeSuggestions() throws {
    let label = try #require(GroupSuggestionButton.label(count: 3))

    #expect(label.contains("3"))
    #expect(label.hasSuffix("suggestions"))
  }

  @Test func mergeSendsMergeWithTheSession() async {
    let sent = await firstRequest { $0.merge("a") }

    #expect(sent.op == "merge")
    #expect(sent.args == ["session": "a"])
  }

  @Test(arguments: [true, false]) func setShellOpenSendsShellWithTheSession(open: Bool) async {
    let sent = await firstRequest { $0.setShellOpen("a", open) }

    #expect(sent.op == "shell")
    #expect(sent.args == ["session": "a", "open": .bool(open)])
  }

  @Test func ignoresASecondMergeWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.merge("a")
      model.merge("a")
      #expect(model.merging == ["a"])
    }
    #expect(sent.count == 1)
  }

  @Test func chooseSendsTheTypedTextOfAReplyOption() async {
    let sent = await firstRequest { $0.choose("a", ref: "summary:1", option: 2, action: .reply, text: "Use SQLite.") }

    #expect(sent.op == "choose")
    #expect(sent.args == ["session": "a", "option": "2", "ref": "summary:1", "text": "Use SQLite."])
  }

  @Test func chooseSendsTheTickedOptionsAsAList() async {
    let sent = await firstRequest { $0.choose("a", ref: "summary:1", picks: ["1", "3"]) }

    #expect(sent.op == "choose")
    #expect(sent.args == ["session": "a", "options": ["1", "3"], "ref": "summary:1"])
  }

  @Test func ignoresASecondSubmitWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.choose("a", ref: "summary:1", picks: ["1"])
      model.choose("a", ref: "summary:1", picks: ["1"])
      #expect(model.choosing == ["a/picks"])
    }
    #expect(sent.count == 1)
  }

  @Test func submitWithNoPicksSendsNothing() async {
    let sent = await firstRequest { model in
      model.choose("a", ref: "summary:1", picks: [])
      #expect(model.choosing.isEmpty)
      model.choose("a", ref: "summary:1", picks: ["2"])
    }
    #expect(sent.count == 1)
    #expect(sent.args == ["session": "a", "options": ["2"], "ref": "summary:1"])
  }

  @Test func ignoresACardsMergeWhileAMergeRuns() async {
    let sent = await firstRequest { model in
      model.merge("a")
      model.choose("a", ref: "summary:1", option: 2, action: .dismiss)
      #expect(model.merging == ["a"])
      #expect(model.choosing.isEmpty)
    }
    #expect(sent.count == 1)
  }

  @Test func ignoresASecondAnswerWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.acceptSuggestion("merge:g1:g2")
      model.declineSuggestion("merge:g1:g2")
      #expect(model.answeringSuggestions == ["merge:g1:g2"])
    }
    #expect(sent.count == 1)
  }
}
