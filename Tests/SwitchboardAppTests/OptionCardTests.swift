import Foundation
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func item(_ options: [TriageOption], multiSelect: Bool = false, ref: String = "") -> TriageItem {
  TriageItem(
    title: "t", kind: .decision, summary: "s", options: options, multiSelect: multiSelect, source: .session, ref: ref)
}

private let fixes = [
  TriageOption(label: "Fix item 3", action: .send, message: "Fix item 3."),
  TriageOption(label: "Fix item 5", action: .send, message: "Fix item 5."),
  TriageOption(label: "Rename the flag", action: .send),
]

private let checks = TriageOption(label: "Fix the checks", action: .send)

@Suite struct OptionPicksState {
  @Test func nothingIsTickedAtFirst() {
    let picks = OptionPicks()

    #expect(!picks.contains(1))
    #expect(picks.keys.isEmpty)
  }

  @Test func aClickTicksAndASecondClickUnticks() {
    var picks = OptionPicks()

    picks.toggle(2, fixes[1])
    #expect(picks.contains(2))
    picks.toggle(2, fixes[1])
    #expect(!picks.contains(2))
  }

  @Test func theKeysFollowTheOptionsOrderNotTheClicks() {
    var picks = OptionPicks()
    picks.toggle(3, fixes[2])
    picks.toggle(1, fixes[0])

    #expect(picks.keys == ["1", "3"])
  }

  @Test func submitStaysOffUntilSomethingIsTicked() {
    var picks = OptionPicks()
    #expect(!picks.canSubmit)

    picks.toggle(1, fixes[0])
    #expect(picks.canSubmit)

    picks.toggle(1, fixes[0])
    #expect(!picks.canSubmit)
  }

  @Test func submitShowsTheMessageThatItSends() {
    var picks = OptionPicks()
    picks.toggle(3, fixes[2])
    picks.toggle(1, fixes[0])

    #expect(picks.effect(in: item(fixes, multiSelect: true)) == "Sends:\n- Fix item 3.\n- Rename the flag")
  }

  @Test func submitWithOnePickShowsThatPicksMessage() {
    var picks = OptionPicks()
    picks.toggle(2, fixes[1])

    #expect(picks.effect(in: item(fixes, multiSelect: true)) == "Sends: Fix item 5.")
  }

  @Test func submitWithoutPicksAsksForThem() {
    #expect(OptionPicks().effect(in: item(fixes, multiSelect: true)) == OptionPicks.prompt)
  }

  /// A new item, such as the session's next card, starts with nothing ticked.
  @Test func picksBelongToTheItemTheUserSaw() {
    var picks = OptionPicks(ref: "summary:1")
    picks.toggle(1, fixes[0])

    #expect(picks.on(item(fixes, multiSelect: true, ref: "summary:1")).canSubmit)
    #expect(!picks.on(item(fixes, multiSelect: true, ref: "summary:2")).canSubmit)
  }

  /// A rule can drop an option from the card without a change to its ref.
  @Test func aPickWhoseOptionLeftTheCardIsDropped() {
    var picks = OptionPicks(ref: "summary:1")
    picks.toggle(4, checks)
    #expect(picks.on(item(fixes + [checks], multiSelect: true, ref: "summary:1")).canSubmit)

    let after = picks.on(item(fixes, multiSelect: true, ref: "summary:1"))
    #expect(!after.canSubmit)
    #expect(after.keys.isEmpty)
  }

  /// A rule can put an option that runs on its own at a ticked number.
  @Test func aPickWhoseOptionCanNoLongerBeTickedIsDropped() {
    var picks = OptionPicks(ref: "summary:1")
    picks.toggle(1, fixes[0])
    picks.toggle(4, checks)
    let card = item(fixes + [TriageOption(label: "Merge #98", action: .merge)], multiSelect: true, ref: "summary:1")

    #expect(picks.on(card).keys == ["1"])
  }

  /// A rule can put another tickable option at a ticked number. The user did not tick that one.
  @Test func aPickWhoseNumberNowHoldsAnotherOptionIsDropped() {
    var picks = OptionPicks(ref: "summary:1")
    picks.toggle(4, checks)
    let card = item(fixes + [TriageOption(label: "Rebase", action: .send)], multiSelect: true, ref: "summary:1")

    let after = picks.on(card)
    #expect(!after.canSubmit)
    #expect(after.keys.isEmpty)
  }
}

@Suite struct OptionCardControls {
  @Test func aMultiSelectCardTicksItsSendOptions() {
    let card = item(fixes + [TriageOption(label: "Merge #98", action: .merge)], multiSelect: true)

    #expect(card.options.map(card.isTickable) == [true, true, true, false])
  }

  @Test func aSingleChoiceCardTicksNothing() {
    let card = item(fixes)

    #expect(card.options.allSatisfy { !card.isTickable($0) })
  }

  @Test func theRecommendedOptionOwnsTheShortcutOnASingleChoiceCard() {
    var options = fixes
    options[1].recommended = true

    #expect(OptionList.shortcutOwner(item(options)) == .option(1))
  }

  @Test func theOnlyOptionOwnsTheShortcut() {
    #expect(OptionList.shortcutOwner(item([fixes[0]])) == .option(0))
  }

  @Test func severalOptionsWithoutARecommendationLeaveTheShortcutUnowned() {
    #expect(OptionList.shortcutOwner(item(fixes)) == OptionList.ShortcutOwner.none)
  }

  /// One control per card answers ⌘⇧Return. On a multi-select card a
  /// recommended option is a checkbox, so Submit answers it.
  @Test func submitOwnsTheShortcutOnAMultiSelectCard() {
    var options = fixes
    options[0].recommended = true

    #expect(OptionList.shortcutOwner(item(options, multiSelect: true)) == .submit)
  }

  @Test func aMultiSelectCardWithNothingToTickFallsBackToTheRecommendedOption() {
    let options = [TriageOption(label: "Merge #98", action: .merge, recommended: true)]

    #expect(OptionList.shortcutOwner(item(options, multiSelect: true)) == .option(0))
  }
}

@Suite struct HeldQuestionClicks {
  static func question(multiSelect: Bool) -> Question {
    Question(
      question: "Which?", header: nil, options: [.init(label: "a"), .init(label: "b")], multiSelect: multiSelect)
  }

  @Test func oneSingleChoiceQuestionAnswersOnAClick() {
    #expect(CardView.answersOnClick([Self.question(multiSelect: false)]))
  }

  @Test func aMultiSelectQuestionWaitsForSubmit() {
    #expect(!CardView.answersOnClick([Self.question(multiSelect: true)]))
  }

  @Test func severalQuestionsWaitForSubmit() {
    #expect(!CardView.answersOnClick([Self.question(multiSelect: false), Self.question(multiSelect: false)]))
  }
}

@Suite struct AcknowledgeCardText {
  /// Acknowledge sits among options that send text, so it says that it sends nothing.
  @Test func acknowledgeSaysThatItSendsNothing() {
    #expect(AcknowledgeButton.detail(undo: false).hasPrefix("Sends nothing."))
  }

  @Test func undoSaysThatItPutsTheItemBack() {
    #expect(AcknowledgeButton.detail(undo: true).contains("back in the Inbox"))
  }
}
