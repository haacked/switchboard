import Foundation
import Testing

@testable import SwitchboardCore

private let fixes: [JSON] = [
  ["label": "Fix item 3", "detail": "The nil check", "action": "send", "message": "Fix item 3."],
  ["label": "Fix item 5", "action": "send", "message": "Fix item 5."],
  ["label": "Rename the flag", "action": "send"],
]

private func multiCard(_ options: [JSON] = fixes) -> JSON {
  ["summary": "Three review items.\nPick the ones to fix.", "multiSelect": true, "options": .array(options)]
}

private func multiItem(_ options: [TriageOption]) -> TriageItem {
  TriageItem(title: "Pick fixes", kind: .decision, summary: "s", options: options, multiSelect: true, source: .session)
}

private let sendOptions = [
  TriageOption(label: "Fix item 3", action: .send, message: "Fix item 3."),
  TriageOption(label: "Fix item 5", action: .send, message: "Fix item 5."),
  TriageOption(label: "Rename the flag", action: .send, message: "Rename the flag"),
]

@Suite struct TriageMultiSelectCleaning {
  @Test func keepsMultiSelectAndEverySendOption() throws {
    let result = try cleaned(multiCard())

    #expect(result.card.multiSelect)
    #expect(result.card.options.map(\.label) == ["Fix item 3", "Fix item 5", "Rename the flag"])
    #expect(result.dropped.isEmpty)
  }

  @Test func aCardWithoutMultiSelectIsSingleChoice() throws {
    #expect(try cleaned(card(options: fixes)).card.multiSelect == false)
  }

  /// Only a message combines with other messages, so a ticked merge or wait would have no meaning.
  @Test(arguments: [
    ["label": "Merge", "action": "merge"] as JSON,
    ["label": "Skip", "action": "done"],
    ["label": "Other", "action": "reply"],
    ["label": "Later", "action": "wait", "wait": ["kind": "manual"]],
  ])
  func dropsAnOptionThatDoesNotSendAMessage(_ option: JSON) throws {
    let result = try cleaned(multiCard(fixes + [option]))

    #expect(result.card.options.count == fixes.count)
    #expect(result.dropped.count == 1)
    #expect(result.dropped.first?.contains("multiSelect") == true, "\(result.dropped)")
  }

  /// A `summary` event recorded before cards had multiSelect holds a single-choice card.
  @Test func anOlderEventDecodesAsSingleChoice() throws {
    let old: JSON = ["title": "t", "kind": "decision", "summary": "s", "options": []]

    #expect(try JSONCoding.convert(old, to: TriageSummary.self).multiSelect == false)
  }

  @Test func theItemKeepsTheCardsMultiSelect() throws {
    let summary = try cleaned(multiCard()).card
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), try summaryEvent(2, 1, summary), stop(3, 2, proseQuestion),
    ])

    #expect(item(f)?.multiSelect == true)
  }

  @Test func theHelpNamesMultiSelect() {
    #expect(TriageCard.instructions.contains("\"multiSelect\": true"))
  }

  /// The app wraps a long label, so the help no longer asks for a short one.
  @Test func theHelpNoLongerLimitsTheLabelToAButton() {
    #expect(!TriageCard.instructions.contains("up to 20 characters"))
    #expect(!TriageCard.instructions.contains("moves beside the button"))
  }
}

@Suite struct TriageMultiSelectPicks {
  @Test func picksKeepTheOptionsOrderWhateverTheOrderOfTheKeys() throws {
    let picks = try multiItem(sendOptions).picks(["3", "1"])

    #expect(picks.map(\.label) == ["Fix item 3", "Rename the flag"])
  }

  @Test func picksReadLabelsAndNumbers() throws {
    let picks = try multiItem(sendOptions).picks(["fix item 5", "1"])

    #expect(picks.map(\.label) == ["Fix item 3", "Fix item 5"])
  }

  @Test func aKeyNamedTwiceCountsOnce() throws {
    let picks = try multiItem(sendOptions).picks(["2", "Fix item 5"])

    #expect(picks.map(\.label) == ["Fix item 5"])
  }

  @Test func noPicksAreRefused() {
    #expect(throws: APIError.self) { try multiItem(sendOptions).picks([]) }
    #expect(throws: APIError.self) { try multiItem(sendOptions).picks(["", "  "]) }
  }

  @Test func anUnknownKeyIsRefused() {
    #expect(throws: APIError.self) { try multiItem(sendOptions).picks(["1", "7"]) }
  }

  @Test func aSingleChoiceItemRefusesSeveralPicks() {
    var item = multiItem(sendOptions)
    item.multiSelect = false

    #expect(throws: APIError.self) { try item.picks(["1", "2"]) }
  }

  /// A PR rule adds its merge option after the session's card. A merge can't be ticked.
  @Test func anOptionThatCantBeTickedIsRefused() {
    let item = multiItem(sendOptions + [TriageOption(label: "Merge #98", action: .merge)])

    #expect(throws: APIError.self) { try item.picks(["1", "4"]) }
  }

  @Test(arguments: [TriageAction.send, .answer])
  func sendAndAnswerOptionsCanBeTicked(_ action: TriageAction) {
    #expect(TriageOption(label: "a", action: action).isCheckable)
  }

  @Test(arguments: [TriageAction.reply, .merge, .dismiss, .wait, .done, .allow, .deny, .allowAutoMode])
  func otherOptionsCantBeTicked(_ action: TriageAction) {
    #expect(!TriageOption(label: "a", action: action).isCheckable)
  }
}

@Suite struct TriageMultiSelectMessage {
  @Test func onePickSendsItsOwnMessage() {
    #expect(Triage.message(for: [sendOptions[0]]) == "Fix item 3.")
  }

  @Test func severalPicksSendOneMessageThatListsEachMessage() {
    #expect(Triage.message(for: sendOptions) == "- Fix item 3.\n- Fix item 5.\n- Rename the flag")
  }

  @Test func aPickWithoutAMessageSendsItsLabel() {
    let picks = [TriageOption(label: "Fix item 3", action: .send), TriageOption(label: "Fix item 5", action: .send)]

    #expect(Triage.message(for: picks) == "- Fix item 3\n- Fix item 5")
  }

  /// `Card.match` reads a multi-select answer as labels separated by commas.
  @Test func answerPicksJoinTheirLabelsWithCommas() {
    let picks = [
      TriageOption(label: "red", action: .answer, message: "red"),
      TriageOption(label: "Blue", action: .answer, message: "Blue"),
    ]

    #expect(Triage.message(for: picks) == "red, Blue")
  }
}

@Suite struct TriageMultiSelectQuestion {
  static let colors: JSON = [
    "questions": [
      [
        "question": "Which colors?", "header": "Colors", "multiSelect": true,
        "options": [["label": "red", "description": "Warm"], ["label": "Blue"], ["label": "green"]],
      ]
    ]
  ]

  /// `sb choose` can then answer the question with several of its options.
  @Test func aHeldMultiSelectQuestionOffersItsOptionsAsTickable() throws {
    let item = try #require(itemOf(facts(promptTurn(ask(Self.colors), ask(Self.colors, id: nil)))))

    #expect(item.multiSelect)
    #expect(item.options.map(\.label) == ["red", "Blue", "green"])
    #expect(item.options.map(\.action) == [.answer, .answer, .answer])
    #expect(item.options.first?.detail == "Warm")
  }

  @Test func severalQuestionsStillOfferNoOptions() throws {
    let item = try #require(itemOf(facts(questionTurn())))

    #expect(item.options.isEmpty)
    #expect(!item.multiSelect)
  }
}
