import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelSelection {
  func summary(_ id: String, state: AttentionState = .needsYou) -> SessionSummary {
    needsItem(id, state: state)
  }

  func model(_ ids: [String]) -> BoardModel { appliedModel(ids.map { summary($0) }) }

  @Test func clearsASelectionWhoseSessionWasRemoved() {
    let model = model(["a", "b"])
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func keepsASelectionWhoseSessionRemains() {
    let model = model(["a", "b"])
    model.selection = "a"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "a")
  }

  @Test func keepsAnUnlistedSelectionThatCreateJustMade() {
    let model = model(["a"])
    model.selectUnlisted("new")
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "new")
  }

  @Test func clearsACreatedSelectionOnceItWasListedAndRemoved() {
    let model = model(["a"])
    model.selectUnlisted("new")
    model.apply(.success([summary("a"), summary("new")]), followups: nil)
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func clearsASelectionThatWasNeverListed() {
    // A click on the notification of a session that sbd has since removed.
    let model = model(["a"])
    model.selection = "gone"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func keepsAFollowupSelectionWhileTheFollowupListStillHoldsIt() {
    let model = model(["a"])
    model.apply(.success([summary("a")]), followups: [summary("f", state: .notStarted)])
    model.selection = "f"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "f")
  }

  @Test func boardCardForAnInboxSessionFocusesItInTheInbox() {
    let model = model(["a", "b"])
    model.show(.board)
    let jumps = model.inboxJumps
    model.openFromBoard("b")
    #expect(model.selection == nil)
    #expect(model.visibleView == .inbox)
    #expect(model.inboxFocus == "b")
    #expect(model.inboxJumps == jumps + 1)
  }

  @Test func boardCardForACanContinueSessionFocusesItInTheInbox() {
    let model = model(["a"])
    model.apply(.success([summary("a"), summary("c", state: .canContinue)]), followups: nil)
    model.show(.board)
    model.openFromBoard("c")
    #expect(model.selection == nil)
    #expect(model.visibleView == .inbox)
    #expect(model.inboxFocus == "c")
  }

  @Test func boardCardForAFollowupOnlySessionSelectsIt() {
    let model = model(["a"])
    model.apply(.success([summary("a")]), followups: [summary("f", state: .notStarted)])
    model.show(.board)
    let jumps = model.inboxJumps
    model.openFromBoard("f")
    #expect(model.selection == "f")
    #expect(model.inboxJumps == jumps)
  }

  @Test func boardCardForAnUnlistedIdSelectsItUntilThePollClearsIt() {
    let model = model(["a"])
    model.show(.board)
    model.openFromBoard("gone")
    #expect(model.selection == "gone")
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func nextNeedingYouAfterABoardCardMovesOnFromTheClickedItem() {
    let model = model(["a", "b", "c"])
    model.show(.board)
    model.openFromBoard("b")
    model.selectNextNeedingYou()
    #expect(model.currentInboxItem == "c")
    #expect(model.visibleView == .inbox)
  }

  @Test func movingUpFromTheFirstItemWrapsToTheLast() {
    let model = model(["a", "b", "c"])
    model.show(.inbox)
    model.moveInbox(by: -1)
    #expect(model.currentInboxItem == "c")
    model.moveInbox(by: -1)
    #expect(model.currentInboxItem == "b")
  }

  @Test func boardCardForASessionOutsideTheInboxSelectsIt() {
    for state in [AttentionState.working, .done, .stale] {
      let model = model(["a"])
      var outside = summary("r", state: state)
      outside.triage = nil
      model.apply(.success([summary("a"), outside]), followups: nil)
      model.show(.board)
      let jumps = model.inboxJumps
      model.openFromBoard("r")
      #expect(model.selection == "r")
      #expect(model.visibleView == nil)
      #expect(model.inboxJumps == jumps)
    }
  }

  @Test func nextNeedingYouWithAStaleSelectionActsAsWithNone() {
    let model = model(["a", "b"])
    model.show(.inbox)
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    let jumps = model.inboxJumps
    model.selectNextNeedingYou()
    #expect(model.selection == nil)
    #expect(model.inboxJumps == jumps + 1)
  }
}

@MainActor
@Suite struct BoardModelVisibleView {
  @Test func isTheMainViewWhileNothingIsSelected() {
    let model = offlineModel()
    #expect(model.visibleView == .inbox)
    model.show(.board)
    #expect(model.visibleView == .board)
  }

  @Test func isNilWhileASessionIsSelected() {
    let model = offlineModel()
    model.selection = "a"
    #expect(model.visibleView == nil)
  }

  @Test func showClearsTheSelection() {
    let model = offlineModel()
    model.selection = "a"
    model.show(.inbox)
    #expect(model.selection == nil)
    #expect(model.visibleView == .inbox)
  }
}
