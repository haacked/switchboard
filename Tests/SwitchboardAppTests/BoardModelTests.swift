import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A session whose triage item is a decision, or a card when `card` is true.
func needsItem(_ id: String, manager: Bool = false, state: AttentionState = .needsYou, card: Bool = false)
  -> SessionSummary
{
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
  s.triage = TriageItem(title: "Pick one", kind: .decision, summary: "", source: card ? .card : .summary)
  s.manager = manager ? true : nil
  return s
}

/// A model that has applied `list`. `apply` sets the Dock badge, which needs NSApp.
@MainActor
func appliedModel(_ list: [SessionSummary], followups: [SessionSummary]? = nil) -> BoardModel {
  _ = NSApplication.shared
  let model = BoardModel()
  model.apply(.success(list), followups: followups)
  return model
}

@MainActor
@Suite struct BoardModelSelection {
  func summary(_ id: String, state: AttentionState = .needsYou) -> SessionSummary {
    needsItem(id, state: state)
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
@Suite struct BoardModelManager {
  func model(_ list: [SessionSummary]) -> BoardModel {
    appliedModel(list)
  }

  @Test func theQueueLeavesOutTheManagerWhateverItsItemIs() {
    for state in [AttentionState.needsYou, .canContinue] {
      for card in [false, true] {
        let model = model([needsItem("m", manager: true, state: state, card: card), needsItem("a")])
        #expect(model.triage.map(\.id) == ["a"])
        #expect(model.currentQueueItem == "a")
      }
    }
  }

  @Test func theManagerAloneLeavesTheQueueEmpty() {
    let model = model([needsItem("m", manager: true, card: true)])
    #expect(model.triage.isEmpty)
    #expect(model.needsYou.isEmpty)
    #expect(model.currentQueueItem == nil)
  }

  @Test func nextNeedingYouSkipsTheManagerInTheQueueAndOutsideIt() {
    let model = model([needsItem("m", manager: true), needsItem("a"), needsItem("b")])
    model.show(.queue)
    var seen: [String?] = []
    for _ in 0..<4 {
      model.selectNextNeedingYou()
      seen.append(model.currentQueueItem)
    }
    #expect(seen == ["b", "a", "b", "a"])
    model.show(.board)
    seen = []
    for _ in 0..<4 {
      model.selectNextNeedingYou()
      seen.append(model.selection)
    }
    #expect(seen == ["a", "b", "a", "b"])
  }

  @Test func theManagerDoesNotNotifyWhenItStartsNeedingYou() {
    let model = model([needsItem("m", manager: true, state: .working), needsItem("a", state: .working)])
    let next = [needsItem("m", manager: true), needsItem("a")]
    #expect(model.sessionsToNotify(next).map(\.id) == ["a"])
  }

  @Test func aFollowupNotifiesOnlyWhileItWaitsToStart() {
    func followup(started: Bool) -> SessionSummary {
      var s = needsItem("f")
      s.followup = Followup(prompt: "p")
      if started { s.followup?.started = 1 }
      return s
    }
    let model = model([needsItem("f", state: .notStarted)])
    #expect(model.sessionsToNotify([followup(started: false)]).map(\.id) == ["f"])
    #expect(model.sessionsToNotify([followup(started: true)]).isEmpty)
  }

  @Test func aSessionSeenForTheFirstTimeDoesNotNotify() {
    let model = model([needsItem("a")])
    #expect(model.sessionsToNotify([needsItem("a"), needsItem("new")]).isEmpty)
  }
}

@MainActor
@Suite struct BoardModelSidebar {
  func summary(_ id: String, parent: String? = nil, manager: Bool = false, state: AttentionState = .working)
    -> SessionSummary
  {
    var s = needsItem(id, manager: manager, state: state)
    s.parent = parent
    return s
  }

  func model(_ sessions: [SessionSummary], followups: [SessionSummary]? = nil) -> BoardModel {
    appliedModel(sessions, followups: followups)
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

  @Test func aChildInAnotherStateIsTopLevelInItsOwnGroup() {
    let model = model([summary("p"), summary("c", parent: "p", state: .needsYou)])
    #expect(shown(model) == ["needsYou: c", "working: p"])
  }

  @Test func aFollowupThatHasNotStartedShowsInItsGroup() {
    let model = model([summary("a")], followups: [summary("f", state: .notStarted)])
    #expect(shown(model) == ["working: a", "notStarted: f"])
  }

  @Test func theManagerStaysSelectableWithoutASidebarRow() {
    let sessions = [summary("m", manager: true, state: .needsYou)]
    let model = model(sessions)
    model.selection = "m"
    model.apply(.success(sessions), followups: nil)
    #expect(model.manager?.id == "m")
    #expect(model.selection == "m")
    #expect(model.selected?.id == "m")
  }
}
