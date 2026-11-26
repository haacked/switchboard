import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let twoTodos = [todoFixture("n3", "tell Alex in #flags"), todoFixture("n4", "bump the SDK")]

/// The delete dialog of a work session, and the `rm-queue` request that it sends.
@MainActor
@Suite struct DeleteConfirmationWork {
  @Test func theTitleNamesTheSession() {
    #expect(DeleteConfirmation(notedSession([], state: .done)).title == "Delete fix?")
  }

  @Test(arguments: [[Note](), twoTodos])
  func theMessageListsTheTodosBeforeTheDeletePlan(_ notes: [Note]) {
    let s = notedSession(notes, state: .done)

    #expect(DeleteConfirmation(s).message == TodoDeletion(s).message(before: BoardModel.deletePlan(s).message))
  }

  @Test func confirmingADoneSessionQueuesItWithTheDoneScope() async {
    let sent = await firstRequest { DeleteConfirmation(notedSession([], state: .done)).confirm($0) }

    #expect(sent.op == "rm-queue")
    #expect(sent.args["scope"] == "done")
    #expect(sent.args["targets"] == ["s1"])
  }

  @Test func confirmingANeedsYouSessionQueuesItWithTheWorkScope() async {
    let sent = await firstRequest { DeleteConfirmation(notedSession([], state: .needsYou)).confirm($0) }

    #expect(sent.op == "rm-queue")
    #expect(sent.args["scope"] == "work")
  }

  @Test func confirmingASessionWithTodosResolvesThem() async {
    let sent = await firstRequest { DeleteConfirmation(notedSession(twoTodos, state: .needsYou)).confirm($0) }

    #expect(sent.args["resolve"] == ["n3", "n4"])
  }

  /// `deleteSession` sends `resolve` only when it names a to-do.
  @Test func confirmingASessionWithoutTodosResolvesNothing() async {
    let sent = await firstRequest { DeleteConfirmation(notedSession([], state: .needsYou)).confirm($0) }

    #expect(sent.args["resolve"] == nil || sent.args["resolve"] == [])
  }
}

/// A Manager conversation's delete dialog lists what the delete drops and sends `manager-end` without `new`.
@MainActor
@Suite struct DeleteConfirmationConversation {
  @Test func theTextIsTheConversationsDeleteText() throws {
    let s = try EndFixtures.everything()

    let confirmation = DeleteConfirmation(s)
    let text = ConversationRemovalText(s, .delete)

    #expect(confirmation.title == text.title)
    #expect(confirmation.message == text.message)
    #expect(confirmation.button == text.button)
  }

  @Test func confirmingSendsManagerEndWithTheDropAndResolveIdsAndNoNewOrCaller() async throws {
    let confirmation = DeleteConfirmation(try EndFixtures.everything())

    let sent = await firstRequest { confirmation.confirm($0) }

    #expect(sent.op == "manager-end")
    #expect(sent.args == ["session": "m", "drop": ["w1", "w2", "p1", "s1"], "resolve": ["n1", "n2"]])
  }

  @Test func confirmingAConversationWithNothingOfItsOwnSendsOnlyTheSession() async {
    let sent = await firstRequest { DeleteConfirmation(EndFixtures.conversation()).confirm($0) }

    #expect(sent.op == "manager-end")
    #expect(sent.args["session"] == "m")
    #expect(sent.args["new"] == nil)
    #expect(sent.args["resolve"] == nil)
    #expect(sent.args["caller"] == nil)
    #expect(sent.args["drop"] == nil || sent.args["drop"] == [])
  }

  /// Risk 2: a wait or a to-do that lands while the dialog is open is not in the request, so sbd refuses it.
  @Test func theRequestNamesOnlyTheSnapshotsItemsWhenTheLiveSummaryGainsMore() async {
    let snapshot = EndFixtures.conversation(waits: [EndFixtures.mergeWait], notes: [EndFixtures.firstTodo])
    let (model, sent) = recordingModel([snapshot])
    model.confirmingDelete = snapshot
    let live = EndFixtures.conversation(
      waits: [EndFixtures.mergeWait, EndFixtures.dateWait], notes: [EndFixtures.firstTodo, EndFixtures.secondTodo])
    model.apply(.success([live]), followups: nil)

    DeleteConfirmation(model.confirmingDelete!).confirm(model)
    await sent.wait(for: "manager-end")

    let args = sent.value.first { $0.op == "manager-end" }?.args
    #expect(args?["drop"] == ["w1"])
    #expect(args?["resolve"] == ["n1"])
  }

}

/// Risk 1: a row offers Delete only when the request that its confirmation sends applies to the session's kind.
@MainActor
@Suite struct DeleteConfirmationKindParity {
  /// The op that each kind's Delete sends, or nil when the kind offers no Delete.
  nonisolated static let expectedOp: [(String, String?)] = [
    ("a", "rm-queue"), ("m", "manager-end"), ("c", "manager-end"), ("op", nil),
  ]

  @Test(arguments: expectedOp.indices)
  func theMenusDeleteAndTheConfirmationsRequestAgreeOnTheKind(_ i: Int) async throws {
    let (id, op) = Self.expectedOp[i]
    let s = try everyKindSession(id)

    let offersDelete = SessionMenu.actions(for: s, selectionCount: nil).contains(where: isDelete)

    #expect(offersDelete == (op != nil), "\(s.kind)")
    if let op {
      let sent = await firstRequest { DeleteConfirmation(s).confirm($0) }
      #expect(sent.op == op, "\(s.kind)")
    }
  }
}
