import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// An exchange as sbd reports it in `decisions.exchanges`.
func decisionExchange(
  _ askId: String, about number: Int, text: String = "why not B?", reply: String? = nil, error: String? = nil,
  pending: Bool
) -> DecisionExchange {
  DecisionExchange(askId: askId, number: number, text: text, reply: reply, error: error, pending: pending)
}

/// An open list of decisions 1 to 3 under `session:1` with `exchanges`.
private func list(_ exchanges: [DecisionExchange] = [], numbers: [Int] = [1, 2, 3]) -> DecisionList {
  DecisionList(decisions: numbers.map(yesNoDecision), ref: "session:1", exchanges: exchanges)
}

private func answered(_ askId: String, about number: Int) -> DecisionExchange {
  decisionExchange(askId, about: number, reply: "Because \(askId).", pending: false)
}

private func pending(_ askId: String, about number: Int) -> DecisionExchange {
  decisionExchange(askId, about: number, pending: true)
}

private func failed(_ askId: String, about number: Int) -> DecisionExchange {
  decisionExchange(askId, about: number, error: "The turn ended without an answer.", pending: false)
}

// MARK: Ask drafts

@MainActor
@Suite struct DecisionAskDrafts {
  @Test func theAskKeyNamesTheSessionTheListAndTheDecision() {
    #expect(MessageDrafts.askKey(session: "s1", ref: "summary:3", decision: 2) == "decision:s1/summary:3/2/ask")
  }

  /// The thread field and the Other answer field of one decision keep separate text.
  @Test func theAskKeyDiffersFromTheOtherAnswerKey() {
    #expect(
      MessageDrafts.askKey(session: "s1", ref: "summary:3", decision: 2)
        != MessageDrafts.otherAnswerKey(session: "s1", ref: "summary:3", decision: 2))
  }

  @Test func theAskDraftAndTheOtherAnswerDraftAreSeparate() {
    let model = appliedModel([listed("a")])
    model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text = "Call it task"

    #expect(model.askDraft(session: "a", ref: "summary:1", decision: 2).text.isEmpty)
  }

  @Test func eachDecisionKeepsItsOwnAskDraft() {
    let model = appliedModel([listed("a")])
    model.askDraft(session: "a", ref: "summary:1", decision: 2).text = "why not B?"

    #expect(model.askDraft(session: "a", ref: "summary:1", decision: 3).text.isEmpty)
  }

  @Test func aRefreshKeepsTheAskDraftWhileItsListShows() {
    let model = appliedModel([listed("a"), listed("b")])
    model.askDraft(session: "a", ref: "summary:1", decision: 2).text = "why not B?"

    model.apply(.success([listed("a")]), followups: nil)

    #expect(model.askDraft(session: "a", ref: "summary:1", decision: 2).text == "why not B?")
  }

  /// The open list, not the item, names the key once the first answer or ask opens it. A clarifying turn's item
  /// can differ from the list, so the open list must keep the draft.
  @Test func aRefreshKeepsTheAskDraftOfTheOpenList() throws {
    var s = listed("a", ref: "summary:2")
    s.decisions = list([pending("q-1", about: 1)])
    let model = appliedModel([s])
    model.askDraft(session: "a", ref: "session:1", decision: 2).text = "why not B?"

    model.apply(.success([s]), followups: nil)

    #expect(model.askDraft(session: "a", ref: "session:1", decision: 2).text == "why not B?")
  }

  @Test func aRefreshDropsTheAskDraftOnceItsSessionLeaves() {
    let model = appliedModel([listed("a"), listed("b")])
    model.askDraft(session: "b", ref: "summary:1", decision: 2).text = "why not B?"

    model.apply(.success([listed("a")]), followups: nil)

    #expect(model.askDraft(session: "b", ref: "summary:1", decision: 2).text.isEmpty)
  }

  /// A later list's decision 2 asks something else, so the old question must not open in its field.
  @Test func aRefreshDropsTheAskDraftOfAListThatNoLongerShows() {
    let model = appliedModel([listed("a", ref: "summary:1")])
    model.askDraft(session: "a", ref: "summary:1", decision: 2).text = "why not B?"

    model.apply(.success([listed("a", ref: "summary:2")]), followups: nil)

    #expect(model.askDraft(session: "a", ref: "summary:2", decision: 2).text.isEmpty)
    #expect(model.askDraft(session: "a", ref: "summary:1", decision: 2).text.isEmpty)
  }

  @Test func anUnsentQuestionSurvivesARelaunch() async {
    let folder = "\(NSTemporaryDirectory())decision-ask-drafts-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: folder) }
    _ = NSApplication.shared
    let client = offlineClient()
    let first = BoardModel(client: client, draftsFolder: folder)
    first.askDraft(session: "a", ref: "summary:1", decision: 2).text = "why not B?"
    await settle {
      (try? String(contentsOfFile: "\(folder)/drafts.json", encoding: .utf8))?.contains("why not B?") == true
    }

    let relaunched = BoardModel(client: client, draftsFolder: folder)

    #expect(relaunched.askDraft(session: "a", ref: "summary:1", decision: 2).text == "why not B?")
  }
}

// MARK: Placement by width

@Suite struct DecisionThreadPlacement {
  /// The narrowest step that holds the options at their minimum width and the thread beside them.
  static let threshold = DecisionThread.optionsMinWidth + DecisionThread.width

  @Test func aStepExactlyWideEnoughShowsTheThreadBeside() {
    #expect(DecisionThread.placement(width: Self.threshold) == .beside)
  }

  /// Beside would squeeze the options below their minimum, so the thread goes under them.
  @Test func aStepOnePointTooNarrowShowsTheThreadUnder() {
    #expect(DecisionThread.placement(width: Self.threshold - 1) == .under)
  }

  @Test func aWideStepShowsTheThreadBeside() {
    #expect(DecisionThread.placement(width: Self.threshold + 400) == .beside)
  }

  /// The plan's narrow snapshot draws at 340 pt.
  @Test func aStepAt340PointsShowsTheThreadUnder() {
    #expect(DecisionThread.placement(width: 340) == .under)
  }

  @Test func aStepWithNoWidthShowsTheThreadUnder() {
    #expect(DecisionThread.placement(width: 0) == .under)
  }
}

// MARK: Exchanges per decision

@Suite struct DecisionThreadExchanges {
  @Test func aDecisionsExchangesAreOnlyTheOnesAboutIt() throws {
    let l = list([answered("q-1", about: 2), answered("q-2", about: 1), pending("q-3", about: 2)])

    #expect(l.exchanges(about: 2).map(\.askId) == ["q-1", "q-3"])
  }

  @Test func aDecisionsExchangesKeepTheListsOrder() throws {
    let l = list([answered("q-9", about: 3), answered("q-1", about: 3), answered("q-5", about: 3)])

    #expect(l.exchanges(about: 3).map(\.askId) == ["q-9", "q-1", "q-5"])
  }

  @Test func aDecisionWithoutQuestionsHasNoExchanges() throws {
    let l = list([answered("q-1", about: 2)])

    #expect(l.exchanges(about: 1).isEmpty)
  }

  /// The reply's numbers need not run 1, 2, 3, so the helper matches the decision's number, not its position.
  @Test func exchangesMatchTheDecisionsNumberNotItsPosition() throws {
    let l = list([answered("q-1", about: 7), answered("q-2", about: 2)], numbers: [3, 7, 9])

    #expect(l.exchanges(about: 7).map(\.askId) == ["q-1"])
  }
}

// MARK: The dot strip

@Suite struct DecisionThreadDots {
  @Test func aDecisionWithoutQuestionsHasNoMark() throws {
    #expect(list([answered("q-1", about: 2)]).threadMarks[1] == nil)
  }

  @Test func aDecisionWithAnAnsweredQuestionShowsASpeechMark() throws {
    #expect(list([answered("q-1", about: 2)]).threadMarks[2] == .asked)
  }

  /// A question that ended without a reply is still a question the user asked, and its error shows in the thread.
  @Test func aDecisionWhoseOnlyQuestionFailedShowsASpeechMark() throws {
    #expect(list([failed("q-1", about: 2)]).threadMarks[2] == .asked)
  }

  @Test func theDecisionWithThePendingQuestionShowsASpinner() throws {
    #expect(list([pending("q-1", about: 2)]).threadMarks[2] == .answering)
  }

  /// The spinner wins over the speech mark while the decision's newest question waits.
  @Test func aDecisionWithAnAnsweredAndAPendingQuestionShowsASpinner() throws {
    #expect(list([answered("q-1", about: 2), pending("q-2", about: 2)]).threadMarks[2] == .answering)
  }

  @Test func onlyTheDecisionAskedAboutShowsTheSpinner() throws {
    let l = list([answered("q-1", about: 1), pending("q-2", about: 2)])

    #expect(l.threadMarks[1] == .asked)
    #expect(l.threadMarks[3] == nil)
  }
}

// MARK: Controls while an ask is pending

/// The two reasons that turn controls off while an ask is pending: sbd's refusal of an answer, Submit, and
/// Discard, and the Ask field's own.
enum PendingAskReason: CaseIterable, Sendable {
  case listChange, ask

  func of(_ list: DecisionList) -> String? { self == .listChange ? list.pendingAskReason : list.askOffReason }
}

@Suite struct DecisionThreadPendingAsk {
  /// sbd's refusal of submit, answer, and discard while an ask is pending.
  static func refusal(_ number: Int) -> String { "Wait for the answer to your question about decision \(number)" }

  @Test(arguments: PendingAskReason.allCases)
  func aPendingQuestionTurnsOffTheControlWithAReasonNamingItsDecision(_ reason: PendingAskReason) throws {
    let l = list([pending("q-1", about: 2)])

    #expect(reason.of(l)?.contains("decision 2") == true)
  }

  /// The step view shows sbd's own refusal, so the user reads the same reason whether the button or sbd stops them.
  @Test func submitAnswerAndDiscardShowSbdsRefusal() throws {
    let l = list([pending("q-1", about: 2)])

    #expect(l.pendingAskReason == Self.refusal(2))
  }

  @Test func askSaysTheSessionIsStillAnswering() throws {
    let l = list([pending("q-1", about: 2)])

    #expect(l.askOffReason == "The session is still answering your question about decision 2")
  }

  @Test(arguments: PendingAskReason.allCases)
  func aListWithoutQuestionsLeavesTheControlOn(_ reason: PendingAskReason) {
    #expect(reason.of(list()) == nil)
  }

  @Test(arguments: PendingAskReason.allCases)
  func answeredQuestionsLeaveTheControlOn(_ reason: PendingAskReason) throws {
    let l = list([answered("q-1", about: 1), answered("q-2", about: 3)])

    #expect(reason.of(l) == nil)
  }

  /// sbd closes an ask with an error when its turn ends without a Stop, so Submit works again.
  @Test(arguments: PendingAskReason.allCases)
  func aQuestionThatEndedWithAnErrorLeavesTheControlOn(_ reason: PendingAskReason) throws {
    #expect(reason.of(list([failed("q-1", about: 2)])) == nil)
  }

  /// The reason names the pending question's decision, not the first or the last exchange's.
  @Test(arguments: PendingAskReason.allCases)
  func theReasonNamesThePendingQuestionsDecisionAmongOthers(_ reason: PendingAskReason) throws {
    let l = list([answered("q-1", about: 3), pending("q-2", about: 2), answered("q-3", about: 1)])

    #expect(reason.of(l)?.contains("decision 2") == true)
    #expect(reason.of(l)?.contains("decision 3") == false)
    #expect(reason.of(l)?.contains("decision 1") == false)
  }

  /// The decision's number names it, as sbd's refusal does, not its position in the list.
  @Test func theReasonUsesTheDecisionsNumber() throws {
    let l = list([pending("q-1", about: 9)], numbers: [3, 7, 9])

    #expect(l.pendingAskReason == Self.refusal(9))
  }

  /// Every ask on the list holds every control, so a question about decision 3 also holds the answers to
  /// decision 1 and the Ask field on decision 1.
  @Test(arguments: PendingAskReason.allCases)
  func aPendingQuestionAboutAnotherDecisionStillTurnsOffTheControl(_ reason: PendingAskReason) throws {
    let l = list([pending("q-1", about: 3)])

    #expect(reason.of(l)?.contains("decision 3") == true)
  }

  /// sbd refuses an ask about a stale list, so Ask is off with the reason. The answers and Submit stay on.
  @Test func aStaleListTurnsOffAskOnly() {
    var l = list()
    l.stale = true

    #expect(l.askOffReason == "The session took a turn since these decisions. Send your question as a message instead")
    #expect(l.pendingAskReason == nil)
  }
}

// MARK: Requests to sbd

/// A model whose sbd accepts each request with `{askId}`, as `decision-ask` answers, after the test signals the
/// semaphore. The counter counts the requests that reach sbd.
@MainActor
private func heldAskModel() -> (BoardModel, DispatchSemaphore, Counter) {
  let model = offlineModel()
  let release = DispatchSemaphore(value: 0)
  let requests = Counter()
  model.send = { _, _ in
    requests.increment()
    release.wait()
    return .object(["askId": "q-1"])
  }
  return (model, release, requests)
}

/// A model whose sbd accepts each request with `{askId}`.
@MainActor
private func acceptingModel() -> BoardModel {
  let model = offlineModel()
  model.send = { _, _ in .object(["askId": "q-1"]) }
  return model
}

@MainActor
@Suite struct BoardModelAskDecision {
  @Test func askSendsDecisionAskWithTheSessionTheRefTheNumberAndTheText() async {
    let sent = await firstRequest { $0.askDecision("a", ref: "session:3", number: 2, text: "why not B?") }

    #expect(sent.op == "decision-ask")
    #expect(sent.args == ["session": "a", "ref": "session:3", "number": 2, "text": "why not B?"])
  }

  @Test func askedRunsOnceSbdAcceptsTheQuestion() async {
    let model = acceptingModel()
    let asked = Counter()

    model.askDecision("a", ref: "session:3", number: 2, text: "why not B?") { asked.increment() }
    await settle { asked.value > 0 }

    #expect(asked.value == 1)
  }

  @Test func askedDoesNotRunWhenSbdRefusesTheQuestion() async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("a is working; ask when it stops") }
    let asked = Counter()

    model.askDecision("a", ref: "session:3", number: 2, text: "why not B?") { asked.increment() }
    await settle { model.decisionErrors["a"] != nil && model.deciding.isEmpty }

    #expect(asked.value == 0)
  }

  /// A refusal shows sbd's text on that session's step, as a refused answer does.
  @Test func sbdsRefusalShowsOnThatSessionsStep() async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("a is still answering your question about decision 1") }

    model.askDecision("a", ref: "session:3", number: 2, text: "why not B?")
    await settle { model.decisionErrors["a"] != nil }

    #expect(model.decisionErrors["a"]?.contains("still answering your question about decision 1") == true)
    #expect(model.decisionErrors["b"] == nil)
    #expect(model.actionError == nil)
  }

  @Test func anAcceptedQuestionClearsTheSessionsError() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    model.askDecision("a", ref: "session:3", number: 2, text: "why not B?")
    await settle { model.decisionErrors["a"] != nil && model.deciding.isEmpty }
    model.send = { _, _ in .object(["askId": "q-1"]) }

    model.askDecision("a", ref: "session:3", number: 2, text: "why not B?")
    await settle { model.decisionErrors["a"] == nil }

    #expect(model.decisionErrors["a"] == nil)
  }

  /// A double press of Ask sends one question. sbd would refuse the second as "still answering".
  @Test func aSecondAskWhileTheFirstRunsSendsNothing() async {
    let (model, release, requests) = heldAskModel()

    model.askDecision("a", ref: "session:3", number: 2, text: "why not B?")
    model.askDecision("a", ref: "session:3", number: 2, text: "why not B?")
    release.signal()
    release.signal()
    await settle { model.deciding.isEmpty }

    #expect(requests.value == 1)
  }
}

// MARK: The thread field, as in PR #136

@MainActor
@Suite struct DecisionThreadSubmit {
  private func submit(_ field: Field, to model: BoardModel) {
    DecisionThread.submit(field.binding, session: "a", ref: "session:3", decision: 2, to: model)
  }

  @Test func aRefusedQuestionKeepsTheTypedText() async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("a is working; ask when it stops") }
    let field = Field("why not B?")

    submit(field, to: model)
    await settle { model.decisionErrors["a"] != nil && model.deciding.isEmpty }

    #expect(model.decisionErrors["a"]?.contains("ask when it stops") == true)
    #expect(field.text == "why not B?")
  }

  @Test func anAcceptedQuestionClearsTheTypedText() async {
    let model = acceptingModel()
    let field = Field("  why not B?\n")

    submit(field, to: model)
    await settle { field.text.isEmpty }

    #expect(field.text.isEmpty)
  }

  /// The field keeps the text until sbd answers, so a slow sbd never shows an empty field for a question it
  /// may refuse.
  @Test func theFieldKeepsTheTextWhileSbdHasNotAnswered() async {
    let (model, release, requests) = heldAskModel()
    let field = Field("why not B?")

    submit(field, to: model)
    await settle { requests.value > 0 }

    #expect(field.text == "why not B?")
    release.signal()
    await settle { model.deciding.isEmpty }
  }

  @Test func theQuestionSendsTheTrimmedText() async {
    let sent = await firstRequest { model in
      submit(Field("  why not B?\n"), to: model)
    }

    #expect(sent.op == "decision-ask")
    #expect(sent.args["text"] == "why not B?")
  }

  @Test func textEditedWhileTheQuestionRunsSurvivesItsSuccess() async {
    let (model, release, _) = heldAskModel()
    let field = Field("why not B?")

    submit(field, to: model)
    field.text = "why not B? And what about C?"
    release.signal()
    await settle { model.deciding.isEmpty }

    #expect(model.deciding.isEmpty)
    #expect(model.decisionErrors["a"] == nil)
    #expect(field.text == "why not B? And what about C?")
  }

  /// Only the text changed, not what it trims to, so the field holds the question that sbd accepted.
  @Test func whitespaceAddedWhileTheQuestionRunsStillClearsTheField() async {
    let (model, release, _) = heldAskModel()
    let field = Field("why not B?")

    submit(field, to: model)
    field.text = "why not B?\n"
    release.signal()
    await settle { field.text.isEmpty }

    #expect(field.text.isEmpty)
  }

  /// The skip that follows shows that the blank text sent nothing first.
  @Test(arguments: ["", "  \n\t"])
  func blankTextSendsNothing(_ text: String) async {
    let sent = await firstRequest { model in
      submit(Field(text), to: model)
      model.answerDecision("a", ref: "session:3", number: 2, .skip)
    }

    #expect(sent.count == 1)
    #expect(sent.op == "decision-answer")
  }
}
