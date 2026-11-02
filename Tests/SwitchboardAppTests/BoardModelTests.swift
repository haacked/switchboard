import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelSelection {
  func summary(_ id: String, state: AttentionState = .needsYou) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.triage = TriageItem(title: "Pick one", kind: .decision, summary: "", source: .summary)
    return s
  }

  func model(_ ids: [String]) -> BoardModel {
    // apply() sets the Dock badge, which needs NSApp.
    _ = NSApplication.shared
    let model = BoardModel()
    model.apply(.success(ids.map { summary($0) }), followups: nil)
    return model
  }

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

  @Test func boardCardForAQueueSessionFocusesItInTheQueue() {
    let model = model(["a", "b"])
    model.show(.board)
    let jumps = model.queueJumps
    model.openFromBoard("b")
    #expect(model.selection == nil)
    #expect(model.visibleView == .queue)
    #expect(model.queueFocus == "b")
    #expect(model.queueJumps == jumps + 1)
  }

  @Test func boardCardForACanContinueSessionFocusesItInTheQueue() {
    let model = model(["a"])
    model.apply(.success([summary("a"), summary("c", state: .canContinue)]), followups: nil)
    model.show(.board)
    model.openFromBoard("c")
    #expect(model.selection == nil)
    #expect(model.visibleView == .queue)
    #expect(model.queueFocus == "c")
  }

  @Test func boardCardForAFollowupOnlySessionSelectsIt() {
    let model = model(["a"])
    model.apply(.success([summary("a")]), followups: [summary("f", state: .notStarted)])
    model.show(.board)
    let jumps = model.queueJumps
    model.openFromBoard("f")
    #expect(model.selection == "f")
    #expect(model.queueJumps == jumps)
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
    #expect(model.currentQueueItem == "c")
    #expect(model.visibleView == .queue)
  }

  @Test func boardCardForASessionOutsideTheQueueSelectsIt() {
    for state in [AttentionState.working, .done, .stale] {
      let model = model(["a"])
      var outside = summary("r", state: state)
      outside.triage = nil
      model.apply(.success([summary("a"), outside]), followups: nil)
      model.show(.board)
      let jumps = model.queueJumps
      model.openFromBoard("r")
      #expect(model.selection == "r")
      #expect(model.visibleView == nil)
      #expect(model.queueJumps == jumps)
    }
  }

  @Test func nextNeedingYouWithAStaleSelectionActsAsWithNone() {
    let model = model(["a", "b"])
    model.show(.queue)
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    let jumps = model.queueJumps
    model.selectNextNeedingYou()
    #expect(model.selection == nil)
    #expect(model.queueJumps == jumps + 1)
  }
}

@MainActor
@Suite struct BoardModelVisibleView {
  @Test func isTheMainViewWhileNothingIsSelected() {
    let model = BoardModel()
    #expect(model.visibleView == .queue)
    model.show(.board)
    #expect(model.visibleView == .board)
  }

  @Test func isNilWhileASessionIsSelected() {
    let model = BoardModel()
    model.selection = "a"
    #expect(model.visibleView == nil)
  }

  @Test func showClearsTheSelection() {
    let model = BoardModel()
    model.selection = "a"
    model.show(.queue)
    #expect(model.selection == nil)
    #expect(model.visibleView == .queue)
  }
}

@MainActor
@Suite struct BoardModelRead {
  @Test func readsTheFollowupsBeforeTheSessions() {
    var order: [String] = []
    _ = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      },
      followups: {
        order.append("followup-ls")
        return []
      })
    #expect(order == ["followup-ls", "ls"])
  }

  @Test func readsOnlyTheSessionsWithoutAFollowupRead() {
    var order: [String] = []
    let (_, more) = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      }, followups: nil)
    #expect(order == ["ls"])
    #expect(more == nil)
  }
}

@MainActor
@Suite struct BoardModelSidebar {
  func summary(_ id: String, parent: String? = nil, manager: Bool? = nil, state: AttentionState = .working)
    -> SessionSummary
  {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.parent = parent
    s.manager = manager
    return s
  }

  func model(_ sessions: [SessionSummary]) -> BoardModel {
    _ = NSApplication.shared
    let model = BoardModel()
    model.apply(.success(sessions), followups: nil)
    return model
  }

  /// The sidebar as "state: id, >child" lines.
  func shown(_ model: BoardModel) -> [String] {
    model.sidebarGroups.map { group in
      "\(group.state): " + group.rows.map { String(repeating: ">", count: $0.depth) + $0.id }.joined(separator: ",")
    }
  }

  @Test func aManagerChildIsTopLevel() {
    let model = model([summary("m", manager: true), summary("a", parent: "m"), summary("b", parent: "m")])
    #expect(shown(model) == ["working: a,b"])
  }

  @Test func aChildOfAnOrdinarySessionStillNests() {
    let model = model([summary("p"), summary("c", parent: "p")])
    #expect(shown(model) == ["working: p,>c"])
  }

  @Test func theManagerHasNoSidebarRow() {
    for state in [AttentionState.working, .needsYou, .done] {
      let model = model([summary("m", manager: true, state: state), summary("a", parent: "m")])
      let ids = model.sidebarGroups.flatMap { $0.rows.map(\.id) }
      #expect(!ids.contains("m"))
      #expect(ids == ["a"])
    }
  }

  @Test func aGrandchildOfTheManagerNestsUnderItsParent() {
    let model = model([summary("m", manager: true), summary("a", parent: "m"), summary("g", parent: "a")])
    #expect(shown(model) == ["working: a,>g"])
  }

  @Test func aManagerWithNoChildrenLeavesTheSidebarEmpty() {
    #expect(model([summary("m", manager: true)]).sidebarGroups.isEmpty)
  }

  @Test func theManagerStaysReachableThroughTheModel() {
    let model = model([summary("m", manager: true, state: .needsYou)])
    #expect(model.manager?.id == "m")
  }
}
