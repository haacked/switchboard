import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct OptionRowTitle {
  func row(_ label: String, _ action: TriageAction = .send, detail: String? = nil) -> OptionRow {
    OptionRow(option: TriageOption(label: label, detail: detail, action: action))
  }

  @Test func theButtonLabelLengthIsTwenty() {
    #expect(TriageCard.buttonLabelLength == 20)
  }

  @Test(arguments: ["Skip", "Merge as is", "Wait for CI", ""])
  func aShortLabelIsTheTitle(_ label: String) {
    #expect(row(label).title == label)
  }

  @Test(arguments: ["Skip", "Merge as is"])
  func aShortLabelMovesNothingBesideTheButton(_ label: String) {
    #expect(row(label).lead == nil)
  }

  /// A short label stays the title even when its action's verb differs.
  @Test func aShortLabelIsNotReplacedByTheVerb() {
    #expect(row("Skip", .done).title == "Skip")
  }

  @Test func aLabelOfExactlyTwentyCharactersIsTheTitle() {
    let label = "Merge after CI green"
    #expect(label.count == TriageCard.buttonLabelLength)

    let row = row(label, .merge)

    #expect(row.title == label)
    #expect(row.lead == nil)
  }

  @Test func aLabelOfTwentyOneCharactersFallsBackToTheVerb() {
    let label = "Merge after CI greens"
    #expect(label.count == TriageCard.buttonLabelLength + 1)

    let row = row(label, .merge)

    #expect(row.title == "Merge")
    #expect(row.lead == label)
  }

  /// A short label keeps its separator, because rule 1 applies before any split.
  @Test func aShortLabelWithASeparatorDoesNotSplit() {
    let row = row("Fix + merge: item 3")

    #expect(row.title == "Fix + merge: item 3")
    #expect(row.lead == nil)
  }
}

@Suite struct OptionRowSplit {
  func row(_ label: String, _ action: TriageAction = .send) -> OptionRow {
    OptionRow(option: TriageOption(label: label, action: action))
  }

  @Test func theSpecExampleSplitsAtTheColon() {
    let row = row("Fix + merge: fixes items 3 and 5")

    #expect(row.title == "Fix + merge")
    #expect(row.lead == "fixes items 3 and 5")
  }

  @Test(arguments: [": ", " — ", " – ", " - "])
  func eachSeparatorSplitsTheLabel(_ separator: String) {
    let row = row("Fix + merge\(separator)fixes items 3 and 5")

    #expect(row.title == "Fix + merge")
    #expect(row.lead == "fixes items 3 and 5")
  }

  /// The label splits at the separator that comes first in the text.
  @Test func theEarliestSeparatorWins() {
    let row = row("Option A - fix: then merge items 3 and 5")

    #expect(row.title == "Option A")
    #expect(row.lead == "fix: then merge items 3 and 5")
  }

  @Test func theHeadAndTheTailAreTrimmed() {
    let row = row("Fix + merge   :    fixes items 3 and 5  ")

    #expect(row.title == "Fix + merge")
    #expect(row.lead == "fixes items 3 and 5")
  }

  @Test func aHeadOfExactlyTwentyCharactersSplits() {
    let row = row("Merge after CI green: then close item 3", .merge)

    #expect(row.title == "Merge after CI green")
    #expect(row.lead == "then close item 3")
  }

  @Test func aHeadOfTwentyOneCharactersFallsBackToTheVerb() {
    let label = "Merge after CI greens: then close item 3"

    let row = row(label, .merge)

    #expect(row.title == "Merge")
    #expect(row.lead == label)
  }

  @Test func aSeparatorAfterCharacterTwentyFallsBackToTheVerb() {
    let label = "Fix items 3 and 5, then merge: or wait"

    let row = row(label)

    #expect(row.title == "Send")
    #expect(row.lead == label)
  }

  @Test(arguments: [": fixes items 3 and 5, then merge", "   : fixes items 3 and 5, then merge"])
  func anEmptyHeadFallsBackToTheVerb(_ label: String) {
    #expect(row(label).title == "Send")
  }

  @Test func anEmptyHeadKeepsTheWholeLabelBesideTheButton() {
    let label = ": fixes items 3 and 5, then merge"

    #expect(row(label).lead == label)
  }

  @Test(arguments: ["Fix + merge:           ", "Fix + merge —           "])
  func anEmptyTailFallsBackToTheVerb(_ label: String) {
    #expect(label.count > TriageCard.buttonLabelLength)

    let row = row(label)

    #expect(row.title == "Send")
    #expect(row.lead == label)
  }

  /// A colon or hyphen without the surrounding spaces is part of a word, not a separator.
  @Test(arguments: [
    "Run make test:unit before merging",
    "Wait until 10:30 then merge item 3",
    "Fix the follow-up items 3 and 5",
    "Fix items 3–5 and then merge it",
  ])
  func punctuationWithoutSpacesDoesNotSplit(_ label: String) {
    let row = row(label)

    #expect(row.title == "Send")
    #expect(row.lead == label)
  }
}

@Suite struct OptionRowVerb {
  @Test(
    arguments: zip(
      [TriageAction.send, .reply, .merge, .dismiss, .wait, .done, .allow, .deny, .answer],
      ["Send", "Reply", "Merge", "Dismiss", "Wait", "Done", "Allow", "Deny", "Answer"]
    ))
  func aLongLabelWithoutASplitShowsTheActionsVerb(_ action: TriageAction, _ verb: String) {
    let label = "Fix items 3 and 5, then merge"

    let row = OptionRow(option: TriageOption(label: label, action: action))

    #expect(row.title == verb)
    #expect(row.lead == label)
  }

  @Test(arguments: TriageAction.allCases)
  func everyActionsVerbFitsTheButton(_ action: TriageAction) {
    let title = OptionRow(option: TriageOption(label: "Fix items 3 and 5, then merge", action: action)).title

    #expect(!title.isEmpty)
    #expect(title.count <= TriageCard.buttonLabelLength)
  }
}

@Suite struct OptionRowTitleBound {
  static let longest = String(String(repeating: "Fix item 3 and 5 ", count: 5).prefix(TriageCard.labelLength))

  static let labels = [
    longest,
    String(repeating: "x", count: TriageCard.labelLength),
    "Fix items 3 and 5, then merge: or wait",
    "Fix items 3 and 5, then merge — or wait for CI to finish",
    "Merge after CI greens: then close item 3",
    "Merge after CI greens",
    ": fixes items 3 and 5, then merge",
    "Fix + merge:           ",
  ]

  @Test func theLongestLabelHasNoSeparator() {
    #expect(Self.longest.count == TriageCard.labelLength)
    #expect(![": ", " — ", " – ", " - "].contains { Self.longest.contains($0) })
  }

  @Test(arguments: labels, TriageAction.allCases)
  func theTitleNeverExceedsTwentyCharacters(_ label: String, _ action: TriageAction) {
    let title = OptionRow(option: TriageOption(label: label, action: action)).title

    #expect(title.count <= TriageCard.buttonLabelLength, "\(label) -> \(title)")
  }
}

@Suite struct OptionRowDescription {
  func row(_ label: String, detail: String?) -> OptionRow {
    OptionRow(option: TriageOption(label: label, detail: detail, action: .send))
  }

  @Test func theDescriptionJoinsTheLeadAndTheDetail() {
    let row = row("Fix + merge: fixes items 3 and 5", detail: "CI is green")

    #expect(row.description == "fixes items 3 and 5. CI is green")
  }

  @Test(arguments: [".", "?", "!"])
  func aLeadThatEndsASentenceGetsNoSecondPeriod(_ mark: String) {
    let row = row("Fix + merge: fixes items 3 and 5\(mark)", detail: "CI is green")

    #expect(row.description == "fixes items 3 and 5\(mark) CI is green")
  }

  @Test func aVerbFallbackLeadJoinsTheDetail() {
    let row = row("Fix items 3 and 5, then merge", detail: "Items 1 and 2 stay open")

    #expect(row.description == "Fix items 3 and 5, then merge. Items 1 and 2 stay open")
  }

  @Test func aShortLabelWithADetailDescribesTheDetail() {
    #expect(row("Merge as is", detail: "Items 3 and 5 stay open").description == "Items 3 and 5 stay open")
  }

  @Test func aLeadWithoutADetailDescribesTheLead() {
    #expect(row("Fix + merge: fixes items 3 and 5", detail: nil).description == "fixes items 3 and 5")
  }

  @Test func aShortLabelWithoutADetailHasNoDescription() {
    #expect(row("Merge as is", detail: nil).description == nil)
  }

  /// A question option's description can be empty.
  @Test func anEmptyDetailCountsAsNoDetail() {
    #expect(row("Merge as is", detail: "").description == nil)
    #expect(row("Fix + merge: fixes items 3 and 5", detail: "").description == "fixes items 3 and 5")
  }
}

@Suite struct OptionRowCard {
  static let options = [
    TriageOption(label: "Fix + merge: fixes items 3 and 5, then merges the PR", action: .send, recommended: true),
    TriageOption(label: "Merge as is, and leave items 3 and 5 open for later", action: .merge),
    TriageOption(label: "Wait for CI on #98 to finish before deciding anything", action: .wait),
    TriageOption(label: "Close the PR — the approach in #97 replaced this one", action: .dismiss),
    TriageOption(label: String(repeating: "x", count: TriageCard.labelLength), action: .done),
    TriageOption(label: "Write a reply that explains a different plan for 3 and 5", action: .reply),
  ]

  @Test func theCardHasTheMostOptionsACardAllows() {
    #expect(Self.options.count == TriageCard.maxOptions)
  }

  @Test func everyTitleOnAFullCardFitsTheButton() {
    let rows = Self.options.map(OptionRow.init)

    #expect(rows.allSatisfy { $0.title.count <= TriageCard.buttonLabelLength }, "\(rows.map(\.title))")
  }

  @Test func theRowsKeepTheOptionsOrder() {
    let rows = Self.options.map(OptionRow.init)

    #expect(rows.map(\.title) == ["Fix + merge", "Merge", "Wait", "Close the PR", "Done", "Reply"])
  }

  @Test func eachRowKeepsTheTextThatLeftTheButton() {
    let rows = Self.options.map(OptionRow.init)

    #expect(
      rows.map(\.lead) == [
        "fixes items 3 and 5, then merges the PR",
        Self.options[1].label,
        Self.options[2].label,
        "the approach in #97 replaced this one",
        Self.options[4].label,
        Self.options[5].label,
      ])
  }
}

@Suite struct OptionRowStacked {
  @Test(arguments: [0, 300, 419, 419.9] as [CGFloat])
  func aNarrowCardStacksTheDescriptionBelowTheButton(_ width: CGFloat) {
    #expect(OptionRow.stacked(width: width))
  }

  @Test(arguments: [420, 420.1, 600, 1200] as [CGFloat])
  func aWideCardPutsTheDescriptionBesideTheButton(_ width: CGFloat) {
    #expect(!OptionRow.stacked(width: width))
  }
}
