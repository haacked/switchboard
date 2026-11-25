import Foundation
import SwiftUI
import Testing

@testable import SwitchboardApp
@testable import SwitchboardCore

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
    #expect(AppShortcut.primaryAction.binding == KeyboardShortcut(.return, modifiers: [.command, .shift]))
    #expect(AppShortcut.primaryAction.binding != KeyboardShortcut(.return, modifiers: [.command]))
    #expect(AppShortcut.primaryAction.binding != KeyboardShortcut(.return, modifiers: []))
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

  /// The two options of a Ready to merge card with PR #98, as `Attention.readyToMerge` builds them.
  @Test func theReadyToMergeOptionsReadDifferentlyAndEachNameThePR() {
    let merge = TriageOption(label: "Merge #98", action: .merge, recommended: true)
    let acknowledge = TriageOption(label: "Acknowledge", action: .dismiss)

    #expect(merge.accessibilityLabel(pr: 98) == "Merge #98")
    #expect(acknowledge.accessibilityLabel(pr: 98) == "Acknowledge, #98")
  }

  /// An option that acts on the PR names it once, after its visible label.
  /// Only a merge says "merge". "#980" holds the text "#98" but names another PR.
  @Test(arguments: [
    (TriageAction.dismiss, "Acknowledge", "Acknowledge, #98"),
    (.dismiss, "Acknowledge #98", "Acknowledge #98"),
    (.dismiss, "Acknowledge #980", "Acknowledge #980, #98"),
    (.dismiss, "Acknowledge PR98", "Acknowledge PR98, #98"),
    (.requestReview, "Request review", "Request review, #98"),
    (.merge, "Acknowledge PR98", "Acknowledge PR98, merge #98"),
    (.merge, "Done with #98", "Done with #98"),
  ])
  func anOptionThatActsOnThePRNamesIt(_ action: TriageAction, _ text: String, _ expected: String) {
    #expect(TriageOption(label: text, action: action).accessibilityLabel(pr: 98) == expected)
  }

  @Test(arguments: [TriageAction.dismiss, .requestReview])
  func anOptionThatActsOnThePRWithoutAPRReadsAsItsLabel(_ action: TriageAction) {
    #expect(TriageOption(label: "Acknowledge", action: action).accessibilityLabel(pr: nil) == "Acknowledge")
  }

  @Test(arguments: TriageAction.allCases.filter { !$0.needsClick })
  func anOptionThatDoesNotActOnThePRReadsExactlyAsItsLabel(_ action: TriageAction) {
    #expect(TriageOption(label: "Skip", action: action).accessibilityLabel(pr: 98) == "Skip")
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
    #expect(
      TriageOption(label: "Skip", action: .done).accessibilityHint(mergeMethod: method) == "Marks the session done")
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func anEnqueueHintSaysItAddsThePRToTheQueue(_ method: MergeMethod) {
    let option = TriageOption(label: "Enqueue #42", action: .merge)

    #expect(option.accessibilityHint(mergeMethod: method) == "Adds the PR to its merge queue")
  }
}

/// How the Summary section lays out the item's summary and callouts.
@Suite struct DecisionCardSummaryLayout {
  static let callouts = [Callout(kind: .warning, title: "CI is red", body: "The lint job fails.")]
  static let summary = "Two review items are open.\nThe parser changed."

  func layout(
    summary: String = DecisionCardSummaryLayout.summary, callouts: [Callout] = DecisionCardSummaryLayout.callouts,
    listOpen: Bool
  )
    -> DecisionCard.SummaryLayout
  {
    DecisionCard.summaryLayout(summary: summary, callouts: callouts, listOpen: listOpen)
  }

  /// The step view moves the callouts into Details, so the Summary keeps only its first line.
  @Test func anOpenDecisionListShowsTheFirstLine() {
    #expect(layout(listOpen: true) == .firstLine)
  }

  @Test func anOpenDecisionListShowsTheFirstLineOfAnEmptySummary() {
    #expect(layout(summary: "", callouts: [], listOpen: true) == .firstLine)
  }

  @Test func aSummaryWithCalloutsShowsColumns() {
    #expect(layout(listOpen: false) == .columns)
  }

  @Test func aSummaryWithoutCalloutsStacks() {
    #expect(layout(callouts: [], listOpen: false) == .stack)
  }

  @Test func calloutsWithoutASummaryStack() {
    #expect(layout(summary: "", listOpen: false) == .stack)
  }

  @Test func anItemWithNeitherStacks() {
    #expect(layout(summary: "", callouts: [], listOpen: false) == .stack)
  }
}

/// "No summary yet. Details holds the last reply." shows only for a fallback
/// with no options and no summary.
@Suite struct DecisionCardMissingSummary {
  static let yesNo = [
    TriageOption(label: "Yes", action: .send, message: "Yes"),
    TriageOption(label: "No", action: .send, message: "No"),
  ]

  /// The item that the plan's example reply gives.
  static let example = TriageItem(
    title: "Delete the branch haacked/round-trip-drop-old-bounds-v2?", kind: .approval,
    summary:
      "The `haacked/round-trip-drop-old-bounds-v2` branch still exists on origin with the same commits. Do you want me to delete it?",
    options: yesNo, source: .fallback)

  @Test func theExampleShowsNoMissingSummaryLine() {
    #expect(!DecisionCard.showsMissingSummary(Self.example, reply: .none))
  }

  @Test func aFallbackWithAnEmptySummaryAndNoOptionsShowsTheLine() {
    let item = TriageItem(title: "Read its last reply", kind: .info, summary: "", source: .fallback)

    #expect(DecisionCard.showsMissingSummary(item, reply: .none))
  }

  @Test func aFallbackWithASummaryAndNoOptionsShowsNoLine() {
    let item = TriageItem(
      title: "Read its last reply", kind: .info, summary: "The flaky test is unrelated.", source: .fallback)

    #expect(!DecisionCard.showsMissingSummary(item, reply: .none))
  }

  @Test func aFallbackWithOptionsAndAnEmptySummaryShowsNoLine() {
    let item = TriageItem(title: "Push?", kind: .approval, summary: "", options: Self.yesNo, source: .fallback)

    #expect(!DecisionCard.showsMissingSummary(item, reply: .none))
  }

  @Test(arguments: [TriageSource.summary, .session, .rule, .card])
  func anItemThatIsNotAFallbackShowsNoLine(_ source: TriageSource) {
    let item = TriageItem(title: "Read the reply", kind: .info, summary: "", source: source)

    #expect(!DecisionCard.showsMissingSummary(item, reply: .none))
  }

  /// The message equals the label, so a button shows no "Sends:" line.
  @Test func yesAndNoShowNothingMore() {
    #expect(Self.yesNo.allSatisfy { !$0.showsEffect })
  }
}

/// A review comment target on `repo`#`pr` whose thread root is `root`.
private func target(
  repo: String = "PostHog/charts", pr: Int = 18303, kind: ReplyTarget.Kind = .reviewComment, root: Int64 = 1001
) -> ResolvedTarget {
  ResolvedTarget(
    target: ReplyTarget(repo: repo, pr: pr, kind: kind, id: root), root: root, author: "ann", path: "a.swift",
    line: 3, excerpt: "Why not use a guard?", url: "https://github.com/\(repo)/pull/\(pr)#discussion_r\(root)")
}

/// The open threads `roots`, read with their comments.
private func openThreads(_ roots: [Int64?]) -> MergeDetails {
  MergeDetails(
    threads: roots.count, threadsRead: roots.count, openThreads: roots.count,
    threadDetails: roots.map { reviewThread($0) })
}

/// A session's Ready to merge item on PostHog/charts#18303 with a draft in each state of `posts`, numbered from
/// 1, and the review of a PR with `details`, whose shown threads hold the drafts that answer them.
private func reviewItem(_ details: MergeDetails?, _ posts: [DraftPost], reviewed: Bool = true) -> TriageItem {
  let drafts = posts.enumerated().map { targetedDraft($1, number: $0 + 1) }
  var review = reviewed ? MergeReview(reviewedPR(details: details)) : nil
  review?.attach(drafts: drafts, repo: "PostHog/charts", number: 18303)
  return TriageItem(
    title: "Merge #18303", kind: .approval, summary: "Approved by stamphog.", drafts: drafts, review: review,
    source: .session)
}

/// The drafts that the panel draws in its thread rows, or none when the card hides the panel.
private func panelDrafts(_ item: TriageItem, listOpen: Bool) -> [InboxDraft] {
  guard DecisionCard.showsReview(item, listOpen: listOpen) else { return [] }
  return (item.review?.threads?.shown ?? []).flatMap { MergeReviewPanel.drafts($0, in: item) }
}

/// The drafts that the Drafts section shows beside the panel.
private func sectionDrafts(_ item: TriageItem, listOpen: Bool) -> [InboxDraft] {
  DecisionCard.sectionDrafts(item, held: DecisionCard.heldDrafts(item, listOpen: listOpen))
}

/// A Ready to merge item and how it places its drafts.
struct DraftPlacement: Sendable, CustomTestStringConvertible {
  var label: String
  var item: TriageItem

  var testDescription: String { label }
}

private let draftPlacements: [DraftPlacement] = [
  DraftPlacement(label: "no review", item: reviewItem(openThreads([1001]), everyDraftPost, reviewed: false)),
  DraftPlacement(label: "details not read", item: reviewItem(nil, everyDraftPost)),
  DraftPlacement(label: "no open threads", item: reviewItem(greenReviewDetails, [.ready(replyTarget)])),
  DraftPlacement(label: "one thread, one draft", item: reviewItem(openThreads([1001]), [.ready(replyTarget)])),
  DraftPlacement(
    label: "one thread, two drafts",
    item: reviewItem(openThreads([1001]), [.ready(replyTarget), .failed(replyTarget, error: "refused")])),
  DraftPlacement(
    label: "two threads",
    item: reviewItem(openThreads([1001, 1002]), [.ready(target(root: 1002)), .ready(replyTarget), .checking])),
  DraftPlacement(label: "every draft state", item: reviewItem(openThreads([1001]), everyDraftPost)),
  DraftPlacement(
    label: "targets that are not the thread",
    item: reviewItem(
      openThreads([1001]),
      [
        .ready(target(repo: "PostHog/other")), .ready(target(pr: 18304)), .ready(target(kind: .issueComment)),
        .ready(target(kind: .review)), .ready(target(root: 1002)),
      ])),
  DraftPlacement(label: "a thread whose URL did not parse", item: reviewItem(openThreads([nil]), everyDraftPost)),
]

@Suite struct DecisionCardReview {
  // MARK: The panel's place

  @Test func aReadyItemWithAReviewShowsThePanel() {
    #expect(DecisionCard.showsReview(reviewItem(greenReviewDetails, []), listOpen: false))
  }

  @Test func anItemWithoutAReviewShowsNoPanel() {
    #expect(!DecisionCard.showsReview(reviewItem(greenReviewDetails, [], reviewed: false), listOpen: false))
  }

  /// The step view takes the card while a decision list is open.
  @Test func anOpenDecisionListHidesThePanel() {
    #expect(!DecisionCard.showsReview(reviewItem(greenReviewDetails, []), listOpen: true))
  }

  // MARK: Each draft shows once

  @Test(arguments: draftPlacements, [false, true])
  func thePanelAndTheDraftsSectionTogetherShowEachDraftOnce(_ placement: DraftPlacement, _ listOpen: Bool) {
    let item = placement.item

    let shown = panelDrafts(item, listOpen: listOpen) + sectionDrafts(item, listOpen: listOpen)

    #expect(shown.map(\.number).sorted() == item.drafts.map(\.number).sorted())
  }

  @Test func aDraftThatAnswersAShownThreadLeavesTheDraftsSection() {
    let item = reviewItem(openThreads([1001]), [.ready(replyTarget), .checking])

    #expect(panelDrafts(item, listOpen: false).map(\.number) == [1])
    #expect(sectionDrafts(item, listOpen: false).map(\.number) == [2])
  }

  /// The panel is hidden, so a draft that a thread holds would otherwise show nowhere.
  @Test func anOpenDecisionListKeepsEveryDraftInTheDraftsSection() {
    let item = reviewItem(openThreads([1001]), [.ready(replyTarget), .checking])
    #expect(item.review?.draftNumbers == [1])

    #expect(sectionDrafts(item, listOpen: true) == item.drafts)
  }

  @Test func anItemWithoutAReviewKeepsEveryDraftInTheDraftsSection() {
    let item = reviewItem(openThreads([1001]), everyDraftPost, reviewed: false)

    #expect(sectionDrafts(item, listOpen: false) == item.drafts)
  }

  @Test func theDraftsSectionKeepsTheItemsOrder() {
    let item = reviewItem(openThreads([1001]), [.checking, .ready(replyTarget), .copyOnly(reason: nil), .checking])

    #expect(sectionDrafts(item, listOpen: false).map(\.number) == [1, 3, 4])
  }

  /// A thread row draws its drafts as reply fields, as the Drafts section draws the same drafts.
  @Test func everyDraftThatAThreadHoldsIsAReplyDraft() {
    let item = reviewItem(openThreads([1001]), everyDraftPost)
    let held = panelDrafts(item, listOpen: false)
    #expect(!held.isEmpty)

    #expect(held.allSatisfy { DraftsSection.usesReplyView($0, in: item) })
  }

  // MARK: The merge option under amber

  /// The item that sbd's rule gives the session whose PR is `pr`.
  private func readyItem(_ pr: PullRequest) -> TriageItem {
    var facts = SessionFacts()
    facts.pr = pr
    return Triage.ruleItem(Attention.readyToMerge(pr, facts))
  }

  /// No option is primary, so every option draws as a secondary button and no key merges.
  @Test(arguments: panelShapes)
  func onlyAnAllGreenReviewLeavesTheMergeOptionOnTheShortcut(_ shape: PanelShape) {
    let item = readyItem(shape.pr)

    #expect(item.review?.amber == shape.amber)
    #expect((OptionList.shortcutOwner(item) == .option(0)) == shape.amber.isEmpty)
    #expect((item.primaryIndex == nil) == !shape.amber.isEmpty)
  }

  @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk])
  func anAmberReviewLeavesNoKeyToMerge(_ method: MergeMethod) {
    let pr = reviewedPR(details: openThreads([1001]), method: method)

    let item = readyItem(pr)

    #expect(OptionList.shortcutOwner(item) == .none)
    #expect(item.primary == nil)
  }

  @Test(arguments: [
    (MergeMethod.merge, "Merge #18303 anyway"), (.mergeQueue, "Enqueue #18303 anyway"),
    (.trunk, "Enqueue #18303 anyway"),
  ])
  func anAmberReviewLabelsTheMergeOptionAnyway(_ method: MergeMethod, _ label: String) throws {
    let item = readyItem(reviewedPR(details: openThreads([1001]), method: method))

    let merge = try #require(item.options.first { $0.action == .merge })

    #expect(merge.label == label)
    #expect(!merge.recommended)
  }

  @Test(arguments: [MergeMethod.merge, .mergeQueue])
  func anAllGreenReviewKeepsTheMergeOptionOnTheShortcut(_ method: MergeMethod) {
    let item = readyItem(reviewedPR(method: method))

    #expect(OptionList.shortcutOwner(item) == .option(0))
    #expect(item.primary?.label == "\(method.verb) #18303")
  }

  /// The demoted label already names the PR, so VoiceOver reads it as it is.
  @Test func theDemotedOptionReadsAsItsLabel() {
    let option = TriageOption(
      label: "Enqueue #18303 anyway", detail: "#18303 has open review items", action: .merge)

    #expect(option.accessibilityLabel(pr: 18303) == "Enqueue #18303 anyway")
    #expect(
      option.accessibilityHint(mergeMethod: .mergeQueue)
        == "#18303 has open review items. Adds the PR to its merge queue")
  }
}
