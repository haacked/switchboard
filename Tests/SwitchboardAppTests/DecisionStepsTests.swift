import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A yes-or-no decision.
private func decision(_ number: Int, options: [String] = ["Yes", "No"]) -> PendingDecision {
  PendingDecision(
    number: number, header: "Header \(number)", question: "Question \(number)?",
    options: options.map { PendingDecision.Option(label: $0) })
}

/// A list of yes-or-no decisions with the given numbers, where each decision in `answered` has the answer Yes.
private func list(_ numbers: [Int], answered: [Int] = []) -> DecisionList {
  DecisionList(
    decisions: numbers.map { decision($0) }, ref: "session:1",
    answers: answered.map { DecisionAnswer(number: $0, labels: ["Yes"]) })
}

// MARK: Which step Next, Back, and an answer go to

@Suite struct DecisionStepsNavigation {
  /// The reply's own numbers need not run 1, 2, 3, so Next follows the list's order.
  @Test(arguments: [([1, 2, 3], 1, 2), ([1, 2, 3], 2, 3), ([3, 7, 9], 7, 9), ([2, 5], 2, 5)])
  func nextGoesToTheFollowingDecisionInListOrder(_ numbers: [Int], _ from: Int, _ to: Int) {
    #expect(DecisionSteps(list(numbers)).next(from: .decision(from)) == .decision(to))
  }

  /// The card opens on the first unanswered decision, or on Review once every decision has an answer.
  @Test func resolveWithNoStepOpensOnTheFirstUnansweredDecision() {
    #expect(DecisionSteps(list([1, 2, 3], answered: [1])).resolve(nil) == .decision(2))
    #expect(DecisionSteps(list([1, 2], answered: [1, 2])).resolve(nil) == .review)
  }

  /// A step that names a decision the list lacks, as after the list's ref changes, falls back the same way.
  @Test func resolveOfADecisionTheListLacksOpensOnTheFirstUnansweredDecision() {
    #expect(DecisionSteps(list([1, 2, 3])).resolve(.decision(9)) == .decision(1))
    #expect(DecisionSteps(list([1, 2, 3])).resolve(.decision(2)) == .decision(2))
  }

  @Test func nextFromTheLastDecisionGoesToReview() {
    #expect(DecisionSteps(list([1, 2, 3])).next(from: .decision(3)) == .review)
  }

  /// Next steps through every decision. Only an option pick jumps over answered ones.
  @Test func nextGoesToTheFollowingDecisionEvenWhenItIsAnswered() {
    #expect(DecisionSteps(list([1, 2, 3], answered: [2])).next(from: .decision(1)) == .decision(2))
  }

  @Test func nextOnReviewStaysOnReview() {
    #expect(DecisionSteps(list([1, 2, 3])).next(from: .review) == .review)
  }

  @Test func previousGoesToTheDecisionBeforeInListOrder() {
    #expect(DecisionSteps(list([3, 7, 9])).previous(from: .decision(9)) == .decision(7))
  }

  @Test func previousOnTheFirstDecisionStaysThere() {
    #expect(DecisionSteps(list([1, 2, 3])).previous(from: .decision(1)) == .decision(1))
  }

  @Test func previousOnReviewGoesToTheLastDecision() {
    #expect(DecisionSteps(list([1, 2, 3])).previous(from: .review) == .decision(3))
  }

  @Test func aPickGoesToTheNextUnansweredDecisionAndPassesAnsweredOnes() {
    let steps = DecisionSteps(list([1, 2, 3, 4], answered: [2, 3]))

    #expect(steps.step(afterAnswering: 1, with: .options([1])) == .decision(4))
  }

  /// The list doesn't hold the pick yet, because sbd hasn't answered. The
  /// picked decision still counts as answered.
  @Test func aPickOnTheLastUnansweredDecisionGoesToReview() {
    let steps = DecisionSteps(list([1, 2, 3], answered: [1, 3]))

    #expect(steps.step(afterAnswering: 2, with: .options([2])) == .review)
  }

  /// The plan says "the next unanswered decision" and doesn't say what
  /// follows the last one. This test takes it to wrap to an earlier
  /// unanswered decision before Review.
  @Test func aPickWithOnlyAnEarlierDecisionUnansweredGoesBackToIt() {
    let steps = DecisionSteps(list([1, 2, 3], answered: [3]))

    #expect(steps.step(afterAnswering: 2, with: .options([1])) == .decision(1))
  }

  @Test(arguments: [DecisionReply.text("Call it task"), .skip])
  func aTypedAnswerOrASkipStaysOnItsDecision(_ reply: DecisionReply) {
    let steps = DecisionSteps(list([1, 2, 3]))

    #expect(steps.step(afterAnswering: 2, with: reply) == .decision(2))
  }
}

// MARK: Keys

@Suite struct DecisionStepsKeys {
  /// Every combination of Command, Option, and Control, with and without Shift, that has at least one of the three.
  static let commandOptionOrControl: [EventModifiers] = ReturnKeyTests.allModifiers.filter {
    !$0.isDisjoint(with: [.command, .option, .control])
  }

  static let tableKeys: [(KeyEquivalent, DecisionKeyAction)] = [
    (KeyEquivalent("]"), .next), (.rightArrow, .next), (KeyEquivalent("["), .previous), (.leftArrow, .previous),
    (KeyEquivalent("o"), .focusOther), (KeyEquivalent("s"), .skip), (KeyEquivalent("r"), .review),
  ]

  private func action(
    _ key: KeyEquivalent, _ modifiers: EventModifiers = [], onReview: Bool = false, options: Int = 3
  ) -> DecisionKeyAction? {
    DecisionSteps.keyAction(key, modifiers: modifiers, onReview: onReview, options: onReview ? 0 : options)
  }

  @Test(arguments: tableKeys)
  func aKeyFromTheTableDoesItsAction(_ key: KeyEquivalent, _ expected: DecisionKeyAction) {
    #expect(action(key) == expected)
  }

  @Test(arguments: 1...5)
  func aDigitPicksThatOption(_ n: Int) {
    #expect(action(KeyEquivalent(Character(String(n))), options: 5) == .pick(n))
  }

  /// A digit with no option behind it does nothing rather than send an answer that sbd refuses.
  @Test(arguments: ["0", "3", "9"])
  func aDigitWithoutThatOptionIsLeftAlone(_ digit: String) {
    #expect(action(KeyEquivalent(Character(digit)), options: 2) == nil)
  }

  @Test func digitsOnReviewAreLeftAlone() {
    #expect(action(KeyEquivalent("1"), onReview: true) == nil)
  }

  @Test func commandShiftReturnGoesToTheNextStepOnADecision() {
    #expect(action(.return, [.command, .shift]) == .next)
  }

  @Test func commandShiftReturnSubmitsOnReview() {
    #expect(action(.return, [.command, .shift], onReview: true) == .submit)
  }

  /// Only ⇧⌘Return submits, so a bare Return or ⌘Return can't send the answers by accident.
  @Test(arguments: [EventModifiers(), .command, .shift, [.command, .option, .shift]])
  func returnWithoutExactlyCommandShiftIsLeftAlone(_ modifiers: EventModifiers) {
    #expect(action(.return, modifiers, onReview: true) == nil)
  }

  /// j and k move through the Inbox list.
  @Test(arguments: ["j", "k"])
  func theInboxKeysAreLeftToTheInbox(_ key: String) {
    #expect(action(KeyEquivalent(Character(key))) == nil)
  }

  /// ⌘J moves to the next Inbox item, and ⌘1 and ⌘R belong to the menus.
  @Test(
    arguments: [KeyEquivalent("]"), .rightArrow, KeyEquivalent("1"), KeyEquivalent("s"), KeyEquivalent("r")],
    commandOptionOrControl)
  func aTableKeyWithCommandOptionOrControlIsLeftAlone(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    #expect(action(key, modifiers) == nil)
  }

  @Test func capsLockChangesNothing() {
    #expect(action(KeyEquivalent("s"), .capsLock) == .skip)
  }
}

// MARK: Other answer drafts

/// A session whose item shows decisions 1 to 3 under `ref`.
private func listed(_ id: String, ref: String = "summary:1") -> SessionSummary {
  var s = needsItem(id)
  s.triage?.ref = ref
  s.triage?.decisions = list([1, 2, 3]).decisions
  return s
}

@MainActor
@Suite struct DecisionDrafts {
  @Test func theOtherAnswerKeyNamesTheSessionTheListAndTheDecision() {
    #expect(
      MessageDrafts.otherAnswerKey(session: "s1", ref: "summary:3", decision: 2) == "decision:s1/summary:3/2/other")
  }

  @Test func aRefreshKeepsTheOtherAnswerDraftWhileItsListShows() {
    let model = appliedModel([listed("a"), listed("b")])
    model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text = "Call it task"

    model.apply(.success([listed("a")]), followups: nil)

    #expect(model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text == "Call it task")
  }

  @Test func aRefreshDropsTheOtherAnswerDraftOnceItsSessionLeaves() {
    let model = appliedModel([listed("a"), listed("b")])
    model.otherAnswerDraft(session: "b", ref: "summary:1", decision: 2).text = "Call it task"

    model.apply(.success([listed("a")]), followups: nil)

    #expect(model.otherAnswerDraft(session: "b", ref: "summary:1", decision: 2).text.isEmpty)
  }

  /// A later list's decision 2 asks a different question, so it must not open with the old list's text.
  @Test func aRefreshDropsTheOtherAnswerDraftOfAListThatNoLongerShows() {
    let model = appliedModel([listed("a", ref: "summary:1")])
    model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text = "maybe SQLite"

    model.apply(.success([listed("a", ref: "summary:2")]), followups: nil)

    #expect(model.otherAnswerDraft(session: "a", ref: "summary:2", decision: 2).text.isEmpty)
    #expect(model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text.isEmpty)
  }

  /// A session in a group keeps its message draft under `group:<id>`, so a draft under its bare id is stale.
  @Test func aRefreshDropsTheBareIdDraftOfASessionInAGroup() {
    var chat = listed("a")
    chat.chat = "g1"
    let model = appliedModel([chat])
    model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text = "Call it task"
    model.messageDraft(for: chat).text = "to the group"
    model.messageDraft(for: needsItem("a")).text = "stale"

    model.apply(.success([chat]), followups: nil)

    #expect(model.messageDraft(for: needsItem("a")).text.isEmpty)
    #expect(model.messageDraft(for: chat).text == "to the group")
    #expect(model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text == "Call it task")
  }

  @Test func anUnsentOtherAnswerSurvivesARelaunch() async throws {
    let folder = "\(NSTemporaryDirectory())decision-drafts-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: folder) }
    _ = NSApplication.shared
    let client = offlineClient()
    let first = BoardModel(client: client, draftsFolder: folder)
    first.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text = "Call it task"
    await settle {
      (try? String(contentsOfFile: "\(folder)/drafts.json", encoding: .utf8))?.contains("Call it task") == true
    }

    let relaunched = BoardModel(client: client, draftsFolder: folder)

    #expect(relaunched.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text == "Call it task")
  }
}

// MARK: Requests to sbd

@MainActor
@Suite struct BoardModelDecisions {
  @Test func aPickSendsDecisionAnswerWithTheOptionNumbersAndTheRefTheUserSaw() async {
    let sent = await firstRequest { $0.answerDecision("a", ref: "session:3", number: 2, .options([1, 3])) }

    #expect(sent.op == "decision-answer")
    #expect(sent.args == ["session": "a", "ref": "session:3", "number": 2, "options": ["1", "3"]])
  }

  @Test func aTypedAnswerSendsItsText() async {
    let sent = await firstRequest { $0.answerDecision("a", ref: "session:3", number: 2, .text("Call it task")) }

    #expect(sent.args == ["session": "a", "ref": "session:3", "number": 2, "text": "Call it task"])
  }

  @Test func aSkipSendsSkip() async {
    let sent = await firstRequest { $0.answerDecision("a", ref: "session:3", number: 2, .skip) }

    #expect(sent.args == ["session": "a", "ref": "session:3", "number": 2, "skip": true])
  }

  @Test func answeredRunsOnceSbdAcceptsTheAnswer() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let answered = Counter()

    model.answerDecision("a", ref: "session:3", number: 1, .skip) { answered.increment() }
    await settle { answered.value > 0 }

    #expect(answered.value == 1)
  }

  @Test func answeredDoesNotRunWhenSbdRefusesTheAnswer() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    let answered = Counter()

    model.answerDecision("a", ref: "session:3", number: 1, .skip) { answered.increment() }
    await settle { model.decisionErrors["a"] != nil }

    #expect(answered.value == 0)
  }

  @Test func submitSendsDecisionSubmitWithoutStale() async {
    let sent = await firstRequest { $0.submitDecisions("a") }

    #expect(sent.op == "decision-submit")
    #expect(sent.args["session"] == "a")
    #expect(sent.args["stale"]?.bool != true)
  }

  /// The card asks first, and only the user's yes sends `stale`.
  @Test func submitOfAStaleListSendsStale() async {
    let sent = await firstRequest { $0.submitDecisions("a", stale: true) }

    #expect(sent.op == "decision-submit")
    #expect(sent.args["stale"] == true)
  }

  @Test func discardSendsDecisionDiscard() async {
    let sent = await firstRequest { $0.discardDecisions("a") }

    #expect(sent.op == "decision-discard")
    #expect(sent.args == ["session": "a"])
  }

  @Test func resendSendsDecisionResend() async {
    let sent = await firstRequest { $0.resendDecisions("a") }

    #expect(sent.op == "decision-resend")
    #expect(sent.args == ["session": "a"])
  }

  enum Request: String, CaseIterable, CustomStringConvertible {
    case answer, submit, discard, resend
    var description: String { rawValue }

    @MainActor func run(on model: BoardModel, _ session: String) {
      switch self {
      case .answer: model.answerDecision(session, ref: "session:3", number: 1, .skip)
      case .submit: model.submitDecisions(session)
      case .discard: model.discardDecisions(session)
      case .resend: model.resendDecisions(session)
      }
    }
  }

  @Test(arguments: Request.allCases)
  func sbdsRefusalShowsOnThatSessionsCard(_ request: Request) async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("a has a new item since you looked. Look again") }

    request.run(on: model, "a")
    await settle { model.decisionErrors["a"] != nil }

    #expect(model.decisionErrors["a"]?.contains("a has a new item since you looked") == true)
    #expect(model.decisionErrors["b"] == nil)
    #expect(model.actionError == nil)
  }

  @Test func anAcceptedRequestClearsTheSessionsError() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    model.answerDecision("a", ref: "session:3", number: 1, .skip)
    await settle { model.decisionErrors["a"] != nil }
    model.send = { _, _ in .null }

    model.answerDecision("a", ref: "session:3", number: 1, .skip)
    await settle { model.decisionErrors["a"] == nil }

    #expect(model.decisionErrors["a"] == nil)
  }

  /// A double click on Submit sends one request. Answers to different decisions each go out, because "Use the
  /// recommendation" sends one per decision.
  @Test func aSecondRequestWithTheSameKeyWaitsForTheFirst() async {
    let (model, release, requests) = heldModel()

    model.submitDecisions("a")
    model.submitDecisions("a")
    model.answerDecision("a", ref: "session:3", number: 1, .skip)
    model.answerDecision("a", ref: "session:3", number: 2, .skip)
    for _ in 0..<3 { release.signal() }
    await settle { model.deciding.isEmpty }

    #expect(model.deciding.isEmpty)
    #expect(requests.value == 3)
  }

  /// A second tick on a multi-select decision builds its pick set from the list on screen, so the list that sbd
  /// returns shows before the next refresh lands.
  @Test func anAcceptedAnswerShowsTheListThatSbdReturns() async throws {
    let model = appliedModel([listed("a", ref: "session:1")])
    let answered = list([1, 2, 3], answered: [1])
    let reply = try JSON(encoding: answered)
    model.send = { _, _ in reply }

    model.answerDecision("a", ref: "session:1", number: 1, .options([1]))
    await settle { model.sessions.first?.decisions != nil }

    #expect(model.sessions.first?.decisions == answered)
  }
}

// MARK: The Other answer field, as in PR #136

@MainActor
@Suite struct OtherAnswerSubmit {
  private func submit(_ field: Field, to model: BoardModel) {
    OtherAnswer.submit(field.binding, session: "a", ref: "session:3", decision: 2, to: model)
  }

  @Test func aRefusedAnswerKeepsTheTypedText() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    let field = Field("Call it task")

    submit(field, to: model)
    await settle { model.decisionErrors["a"] != nil && model.deciding.isEmpty }

    #expect(model.decisionErrors["a"] != nil)
    #expect(field.text == "Call it task")
  }

  @Test func anAcceptedAnswerClearsTheTypedText() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let field = Field("  Call it task\n")

    submit(field, to: model)
    await settle { field.text.isEmpty }

    #expect(field.text.isEmpty)
  }

  @Test func theAnswerSendsTheTrimmedText() async {
    let sent = await firstRequest { model in
      submit(Field("  Call it task\n"), to: model)
    }

    #expect(sent.args["text"] == "Call it task")
  }

  @Test func textEditedWhileTheAnswerRunsSurvivesItsSuccess() async {
    let (model, release, _) = heldModel()
    let field = Field("Call it task")

    submit(field, to: model)
    field.text = "Call it task, or chore"
    release.signal()
    await settle { model.deciding.isEmpty }

    #expect(model.deciding.isEmpty)
    #expect(model.decisionErrors["a"] == nil)
    #expect(field.text == "Call it task, or chore")
  }

  /// The skip that follows shows that the blank text sent nothing first.
  @Test(arguments: ["", "  \n\t"])
  func blankTextSendsNothing(_ text: String) async {
    let sent = await firstRequest { model in
      submit(Field(text), to: model)
      model.answerDecision("a", ref: "session:3", number: 2, .skip)
    }

    #expect(sent.count == 1)
    #expect(sent.args["skip"] == true)
  }
}

// MARK: The card after Submit

@Suite struct SentDecisions {
  /// A session whose item has three decisions and whose list sbd closed when it sent the answers.
  private func sent() -> SessionSummary {
    var s = needsItem("a")
    s.triage?.ref = "session:1"
    s.triage?.decisions = list([1, 2, 3]).decisions
    s.decisionsSent = true
    return s
  }

  /// The item keeps its decisions until the prompt lands, and sbd says that it sent them.
  @Test func theItemWhoseAnswersSbdSentHasNoSteps() {
    #expect(sent().stepList == nil)
  }

  @Test func aNewItemAfterTheSubmitShowsItsSteps() {
    var next = sent()
    next.decisionsSent = nil
    next.triage?.ref = "session:2"

    #expect(next.stepList?.ref == "session:2")
  }
}
