import AppKit
import Combine
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The step view's current step lives in `BoardModel`, keyed by session id with the ref of the list it belongs to.
/// Selecting another Inbox item or opening the session therefore keeps it, and only a new list resets it.
@MainActor
@Suite struct BoardModelDecisionStep {
  /// The step that the view shows for `id`, read under the ref of the list that the model's session shows now, as
  /// `TriageDetail` reads it.
  func step(_ model: BoardModel, _ id: String) -> DecisionStep? {
    guard let ref = model.sessions.first(where: { $0.id == id })?.stepList?.ref else { return nil }
    return model.decisionStep(session: id, ref: ref)
  }

  /// Decision 1 is what `DecisionSteps.resolve(nil)` opens on, so the tests set decision 3 or Review to tell a
  /// stored step from no step.
  @Test(arguments: [DecisionStep.decision(3), .review])
  func aSetStepReadsBack(_ set: DecisionStep) {
    let model = appliedModel([listed("a")])

    model.setDecisionStep(set, session: "a", ref: "summary:1")

    #expect(step(model, "a") == set)
  }

  @Test func aSessionWithoutASetStepHasNone() {
    let model = appliedModel([listed("a")])

    #expect(step(model, "a") == nil)
  }

  @Test func theStepSurvivesTheInboxSelectionMovingAwayAndBack() {
    let model = appliedModel([listed("a"), listed("b")])
    model.inboxFocus = "a"
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")

    model.inboxFocus = "b"
    model.inboxFocus = "a"

    #expect(step(model, "a") == .decision(3))
  }

  /// The pane's Open button selects the session in the sidebar, and Back returns to the Inbox.
  @Test func theStepSurvivesOpeningTheSessionAndComingBack() {
    let model = appliedModel([listed("a")])
    model.setDecisionStep(.review, session: "a", ref: "summary:1")

    model.selection = "a"
    model.selection = nil

    #expect(step(model, "a") == .review)
  }

  /// sbd's poll applies the same list every second.
  @Test func theStepSurvivesARefreshWithTheSameList() {
    let model = appliedModel([listed("a")])
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")

    model.apply(.success([listed("a")]), followups: nil)

    #expect(step(model, "a") == .decision(3))
  }

  @Test func aNewListRefResetsTheStep() {
    let model = appliedModel([listed("a", ref: "summary:1")])
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")

    model.apply(.success([listed("a", ref: "session:2")]), followups: nil)

    #expect(step(model, "a") == nil)
  }

  @Test func theOldListsStepDoesNotReturnOnALaterRefresh() {
    let model = appliedModel([listed("a", ref: "summary:1")])
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")
    model.apply(.success([listed("a", ref: "session:2")]), followups: nil)

    model.apply(.success([listed("a", ref: "session:2")]), followups: nil)

    #expect(step(model, "a") == nil)
  }

  /// The reset clears the old list's step only. A step that the user picks in the new list stays.
  @Test func aStepSetInTheNewListSurvivesARefresh() {
    let model = appliedModel([listed("a", ref: "summary:1")])
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")
    model.apply(.success([listed("a", ref: "session:2")]), followups: nil)

    model.setDecisionStep(.decision(2), session: "a", ref: "session:2")
    model.apply(.success([listed("a", ref: "session:2")]), followups: nil)

    #expect(step(model, "a") == .decision(2))
  }

  /// `DecisionStepView` sets the step after sbd accepts an answer. When the list's ref changed while the answer
  /// ran, that late write names the old list and must not move the new list off its first unanswered decision.
  @Test func aLateWriteForTheOldListLeavesTheNewListsStepUnset() {
    let model = appliedModel([listed("a", ref: "summary:1")])
    model.apply(.success([listed("a", ref: "session:2")]), followups: nil)

    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")

    #expect(step(model, "a") == nil)
  }

  @Test func aLateWriteForTheOldListKeepsAStepSetInTheNewList() {
    let model = appliedModel([listed("a", ref: "summary:1")])
    model.apply(.success([listed("a", ref: "session:2")]), followups: nil)
    model.setDecisionStep(.decision(2), session: "a", ref: "session:2")

    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")

    #expect(step(model, "a") == .decision(2))
  }

  @Test func aStepForOneSessionLeavesAnotherSessionsStepUnset() {
    let model = appliedModel([listed("a"), listed("b")])

    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")

    #expect(step(model, "b") == nil)
  }

  @Test func eachSessionKeepsItsOwnStep() {
    let model = appliedModel([listed("a"), listed("b")])
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")
    model.setDecisionStep(.review, session: "b", ref: "summary:1")

    model.setDecisionStep(.decision(2), session: "b", ref: "summary:1")

    #expect(step(model, "a") == .decision(3))
  }

  /// The step view binds to the model, so a new step must redraw it.
  @Test func settingTheStepPublishes() {
    let model = appliedModel([listed("a")])
    var published = 0
    let subscription = model.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }

    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")

    #expect(published > 0)
  }

  /// A publish redraws every view, and the poll applies the same list every second.
  @Test func aRefreshWithTheSameListAndAStoredStepDoesNotPublish() {
    let model = appliedModel([listed("a"), listed("b", ref: "session:4")])
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")
    model.setDecisionStep(.review, session: "b", ref: "session:4")
    var published = 0
    let subscription = model.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }

    model.apply(.success([listed("a"), listed("b", ref: "session:4")]), followups: nil)

    #expect(published == 0)
  }

  /// A refresh drops the step of a session that is gone, so the model doesn't keep the steps of deleted sessions.
  @Test func aRefreshDropsTheStepOfARemovedSession() {
    let model = appliedModel([listed("a"), listed("b")])
    model.setDecisionStep(.decision(3), session: "a", ref: "summary:1")
    model.setDecisionStep(.review, session: "b", ref: "summary:1")

    model.apply(.success([listed("b")]), followups: nil)

    #expect(model.decisionSteps["a"] == nil)
    #expect(model.decisionSteps["b"] == DecisionStepEntry(ref: "summary:1", step: .review))
  }
}
