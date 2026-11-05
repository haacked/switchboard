import Foundation
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct DecisionCardPrimary {
  func item(_ options: [TriageOption], source: TriageSource = .session) -> TriageItem {
    TriageItem(title: "Pick how to land #98", kind: .decision, summary: "s", options: options, source: source)
  }

  @Test func theRecommendedOptionIsPrimaryEvenWhenItIsNotFirst() {
    let options = [
      TriageOption(label: "Merge as is", action: .merge),
      TriageOption(label: "Fix items 3 and 5", action: .send, message: "Fix them.", recommended: true),
      TriageOption(label: "Skip", action: .done),
    ]

    #expect(item(options).primary?.label == "Fix items 3 and 5")
  }

  @Test(arguments: [TriageAction.send, .merge, .wait, .done, .reply])
  func theOnlyOptionIsPrimaryWithoutARecommendation(_ action: TriageAction) {
    #expect(item([TriageOption(label: "Go", action: action)]).primary?.label == "Go")
  }

  @Test func severalOptionsWithoutARecommendationHaveNoPrimary() {
    let options = [TriageOption(label: "A", action: .send), TriageOption(label: "B", action: .done)]

    #expect(item(options).primary == nil)
  }

  @Test func theFirstOfTwoRecommendedOptionsIsPrimary() {
    let options = [
      TriageOption(label: "A", action: .send, recommended: true),
      TriageOption(label: "B", action: .done, recommended: true),
    ]

    #expect(item(options).primary?.label == "A")
  }

  @Test func anItemWithoutOptionsHasNoPrimary() {
    #expect(item([]).primary == nil)
  }

  /// ⌘Return sends the message field, and a bare Return could merge by accident.
  @Test func thePrimaryShortcutIsCommandShiftReturn() {
    #expect(OptionButton.primaryShortcut == KeyboardShortcut(.return, modifiers: [.command, .shift]))
    #expect(OptionButton.primaryShortcut != KeyboardShortcut(.return, modifiers: [.command]))
    #expect(OptionButton.primaryShortcut != KeyboardShortcut(.return, modifiers: []))
  }
}

@Suite struct DecisionCardAccessibility {
  @Test func aRuleMergeOptionReadsAsItsLabel() {
    let option = TriageOption(label: "Merge #98", action: .merge, recommended: true)

    #expect(option.accessibilityLabel(pr: 98) == "Merge #98")
  }

  @Test func aMergeOptionWhoseLabelOmitsThePRNamesIt() {
    let label = TriageOption(label: "Merge as is", action: .merge).accessibilityLabel(pr: 98)

    #expect(label.contains("Merge as is"))
    #expect(label.contains("#98"))
  }

  /// "#980" holds the text "#98" but names another PR.
  @Test(arguments: ["Merge #980", "Merge #9801", "Merge PR98"])
  func aMergeOptionThatNamesAnotherNumberStillNamesThePR(_ text: String) {
    let label = TriageOption(label: text, action: .merge).accessibilityLabel(pr: 98)

    #expect(label.range(of: "#98(?![0-9])", options: .regularExpression) != nil, "\(label)")
  }

  @Test func aMergeOptionWithoutAPRReadsAsItsLabel() {
    #expect(TriageOption(label: "Merge as is", action: .merge).accessibilityLabel(pr: nil) == "Merge as is")
  }

  @Test(arguments: [TriageAction.send, .reply, .dismiss, .wait, .done, .allow, .deny, .answer])
  func everyButtonReadsItsLabel(_ action: TriageAction) {
    let label = TriageOption(label: "Wait for CI on #98", action: action).accessibilityLabel(pr: 98)

    #expect(label.contains("Wait for CI on #98"))
  }

  /// VoiceOver tells the buttons of one card apart by their labels.
  @Test func theSpecExamplesButtonsReadDifferently() {
    let options = [
      TriageOption(label: "Fix items 3 and 5, then merge", action: .send, message: "Fix.", recommended: true),
      TriageOption(label: "Merge as is", action: .merge),
      TriageOption(label: "Wait for CI", action: .wait),
      TriageOption(label: "Skip", action: .done),
      TriageOption(label: "Something else", action: .reply),
    ]

    let labels = options.map { $0.accessibilityLabel(pr: 98) }

    #expect(Set(labels).count == labels.count)
    #expect(labels.allSatisfy { !$0.isEmpty })
  }
}

@Suite struct DecisionCardEffect {
  /// A session writes the label, so a merge labeled like a reply still shows that it merges.
  @Test(arguments: [TriageAction.merge, .wait, .done, .dismiss])
  func aButtonThatSendsNothingShowsWhatItDoes(_ action: TriageAction) {
    #expect(TriageOption(label: "Fix items 3 and 5", action: action).showsEffect)
  }

  @Test func aSendOfAnotherTextShowsTheText() {
    #expect(TriageOption(label: "Go on", action: .send, message: "Go on, then push.").showsEffect)
  }

  @Test(arguments: [nil, "Go on"])
  func aSendOfItsOwnLabelShowsNothingMore(_ message: String?) {
    #expect(!TriageOption(label: "Go on", action: .send, message: message).showsEffect)
  }

  @Test(arguments: ["Items 3 and 5 stay open.", "Items 3 and 5 stay open"])
  func theHintReadsTheDetailThenTheEffect(_ detail: String) {
    let option = TriageOption(label: "Merge as is", detail: detail, action: .merge)

    #expect(option.accessibilityHint(mergeMethod: .merge) == "Items 3 and 5 stay open. Merges the PR")
  }

  @Test func aDetailThatEndsInAQuestionGetsNoPeriod() {
    let option = TriageOption(label: "Merge as is", detail: "Leave items 3 and 5?", action: .merge)

    #expect(option.accessibilityHint(mergeMethod: .merge) == "Leave items 3 and 5? Merges the PR")
  }

  @Test(arguments: [nil, MergeMethod.trunk])
  func aHintWithoutADetailIsTheEffect(_ method: MergeMethod?) {
    #expect(TriageOption(label: "Skip", action: .done).accessibilityHint(mergeMethod: method) == "Marks the session done")
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func anEnqueueHintSaysItAddsThePRToTheQueue(_ method: MergeMethod) {
    let option = TriageOption(label: "Enqueue #42", action: .merge)

    #expect(option.accessibilityHint(mergeMethod: method) == "Adds the PR to its merge queue")
  }
}
