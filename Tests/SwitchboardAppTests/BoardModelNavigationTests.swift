import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A working session that has no Inbox item, as after the user answered it.
private func outsideTheInbox(_ id: String) -> SessionSummary {
  var s = needsItem(id, state: .working)
  s.triage = nil
  return s
}

/// A follow-up that has not started. It shows in the sidebar's Not started section.
private func followupWaitingToStart(_ id: String) -> SessionSummary {
  var s = needsItem(id, state: .notStarted)
  s.followup = Followup(prompt: "p")
  s.cwd = ""
  return s
}

private func child(_ id: String, of parent: String, state: AttentionState = .working) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.parent = parent
  return s
}

@Suite struct KeyboardNavModelTests {
  // MARK: sidebarOrder

  @MainActor
  @Suite struct SidebarOrder {
    @Test func theManagerComesFirst() {
      let model = appliedModel([needsItem("a", state: .working), needsItem("m", manager: true, state: .working)])

      #expect(model.sidebarOrder == ["m", "a"])
    }

    @Test func rowsFollowTheSidebarGroupsInStateOrder() {
      let model = appliedModel([
        needsItem("w", state: .working), needsItem("n", state: .needsYou), needsItem("c", state: .canContinue),
      ])

      #expect(model.sidebarOrder == ["n", "c", "w"])
    }

    @Test func aChildComesRightAfterItsParent() {
      let model = appliedModel([needsItem("p", state: .working), needsItem("q", state: .working), child("c", of: "p")])

      #expect(model.sidebarOrder == ["p", "c", "q"])
    }

    @Test func aCollapsedSectionsRowsAreLeftOut() {
      let model = appliedModel([needsItem("a", state: .working)], followups: [followupWaitingToStart("f")])

      #expect(model.collapsed.contains(.notStarted))
      #expect(model.sidebarOrder == ["a"])
    }

    @Test func anExpandedNotStartedSectionsRowsAreIn() {
      let model = appliedModel([needsItem("a", state: .working)], followups: [followupWaitingToStart("f")])

      model.collapsed.remove(.notStarted)

      #expect(model.sidebarOrder == ["a", "f"])
    }

    /// The Manager's section can't collapse, so collapsing the section of its state keeps it.
    @Test func theManagerStaysWhenTheSectionOfItsStateIsCollapsed() {
      let model = appliedModel([needsItem("m", manager: true, state: .working), needsItem("a", state: .working)])

      model.collapsed = [.working]

      #expect(model.sidebarOrder == ["m"])
    }

    @Test func aGroupChatIsLeftOut() {
      let model = appliedModel([chatItem("chat", group: "g1"), needsItem("a")])

      #expect(model.sidebarOrder == ["a"])
    }
  }

  // MARK: selectAdjacentSession with a selection

  @MainActor
  @Suite struct AdjacentSession {
    /// The Manager, four rows in three sections, a group chat, and a collapsed follow-up.
    func model() -> BoardModel {
      appliedModel(
        [
          needsItem("m", manager: true, state: .working), needsItem("n", state: .needsYou),
          needsItem("w1", state: .working), child("w2", of: "w1"), needsItem("d", state: .done),
          chatItem("chat", group: "g1"),
        ], followups: [followupWaitingToStart("f")])
    }

    @Test func nextGoesToTheFollowingRowInSidebarOrder() throws {
      let model = model()
      let order = model.sidebarOrder
      try #require(order.count >= 3)
      model.selection = order[1]

      model.selectAdjacentSession(by: 1)

      #expect(model.selection == order[2])
    }

    @Test func previousGoesToTheRowBeforeInSidebarOrder() throws {
      let model = model()
      let order = model.sidebarOrder
      try #require(order.count >= 3)
      model.selection = order[1]

      model.selectAdjacentSession(by: -1)

      #expect(model.selection == order[0])
    }

    /// The collapsed follow-up after the last row is skipped.
    @Test func nextFromTheLastRowWrapsToTheFirst() throws {
      let model = model()
      let order = model.sidebarOrder
      model.selection = try #require(order.last)

      model.selectAdjacentSession(by: 1)

      #expect(model.selection == order.first)
    }

    @Test func previousFromTheFirstRowWrapsToTheLast() throws {
      let model = model()
      let order = model.sidebarOrder
      model.selection = try #require(order.first)

      model.selectAdjacentSession(by: -1)

      #expect(model.selection == order.last)
    }

    /// A group chat has no sidebar row, and a row in a collapsed section is hidden.
    @Test(arguments: ["chat", "f"])
    func nextFromASelectionOutsideTheOrderGoesToTheFirstRow(_ selection: String) {
      let model = model()
      model.selection = selection

      model.selectAdjacentSession(by: 1)

      #expect(model.selection == model.sidebarOrder.first)
    }

    @Test(arguments: ["chat", "f"])
    func previousFromASelectionOutsideTheOrderGoesToTheLastRow(_ selection: String) {
      let model = model()
      model.selection = selection

      model.selectAdjacentSession(by: -1)

      #expect(model.selection == model.sidebarOrder.last)
    }

    @Test(arguments: [1, -1])
    func withNoSessionsASelectionStays(step: Int) {
      let model = offlineModel()
      model.selection = "x"

      model.selectAdjacentSession(by: step)

      #expect(model.selection == "x")
    }

    @Test(arguments: [1, -1], [MainView.inbox, .board])
    func withNoSessionsTheInboxAndBoardStayEmpty(step: Int, view: MainView) {
      let model = offlineModel()
      model.show(view)

      model.selectAdjacentSession(by: step)

      #expect(model.selection == nil)
      #expect(model.inboxFocus == nil)
      #expect(model.boardFocus == nil)
    }
  }

  // MARK: selectAdjacentSession in the Inbox and on the Board

  @MainActor
  @Suite struct AdjacentInMainView {
    func inbox(focus: String) -> BoardModel {
      let model = appliedModel([needsItem("a"), needsItem("b"), needsItem("c")])
      model.show(.inbox)
      model.inboxFocus = focus
      return model
    }

    /// Reading order: a, b, c, d.
    func board(focus: String?) -> BoardModel {
      let model = appliedModel([needsItem("a"), needsItem("b"), needsItem("c"), needsItem("d")])
      model.show(.board)
      model.boardGrid = BoardGrid(lanes: [[["a"], ["b", "c"]], [[], ["d"]]])
      model.boardFocus = focus
      return model
    }

    @Test func nextInTheInboxMovesTheCurrentItem() {
      let model = inbox(focus: "a")

      model.selectAdjacentSession(by: 1)

      #expect(model.currentInboxItem == "b")
    }

    @Test func nextFromTheLastInboxItemWrapsToTheFirst() {
      let model = inbox(focus: "c")

      model.selectAdjacentSession(by: 1)

      #expect(model.currentInboxItem == "a")
    }

    @Test func previousFromTheFirstInboxItemWrapsToTheLast() {
      let model = inbox(focus: "a")

      model.selectAdjacentSession(by: -1)

      #expect(model.currentInboxItem == "c")
    }

    @Test(arguments: [1, -1])
    func movingInTheInboxLeavesTheSelectionNil(step: Int) {
      let model = inbox(focus: "b")

      model.selectAdjacentSession(by: step)

      #expect(model.selection == nil)
      #expect(model.visibleView == .inbox)
    }

    @Test(arguments: [("a", "b"), ("b", "c"), ("c", "d")])
    func nextOnTheBoardFollowsTheReadingOrderAcrossCellsAndLanes(_ from: String, _ to: String) {
      let model = board(focus: from)

      model.selectAdjacentSession(by: 1)

      #expect(model.boardFocus == to)
    }

    @Test func nextFromTheLastBoardCardWrapsToTheFirst() {
      let model = board(focus: "d")

      model.selectAdjacentSession(by: 1)

      #expect(model.boardFocus == "a")
    }

    @Test func previousFromTheFirstBoardCardWrapsToTheLast() {
      let model = board(focus: "a")

      model.selectAdjacentSession(by: -1)

      #expect(model.boardFocus == "d")
    }

    /// A focus id that the poll removed leaves the ring on the first card, so the step moves on from it.
    @Test func nextFromAStaleBoardFocusMovesFromTheFirstCard() {
      let model = board(focus: "gone")

      model.selectAdjacentSession(by: 1)

      #expect(model.boardFocus == "b")
    }

    @Test func previousFromAStaleBoardFocusGoesToTheLastCard() {
      let model = board(focus: "gone")

      model.selectAdjacentSession(by: -1)

      #expect(model.boardFocus == "d")
    }

    @Test(arguments: [1, -1])
    func movingOnTheBoardLeavesTheSelectionNil(step: Int) {
      let model = board(focus: "b")

      model.selectAdjacentSession(by: step)

      #expect(model.selection == nil)
      #expect(model.visibleView == .board)
    }

    enum Place: CaseIterable { case sidebar, inbox, board }

    @Test(arguments: Place.allCases)
    func eachCallAsksForListFocus(_ place: Place) {
      let model = board(focus: "a")
      switch place {
      case .sidebar: model.selection = "b"
      case .inbox: model.show(.inbox)
      case .board: break
      }
      let requests = model.listFocusRequests

      model.selectAdjacentSession(by: 1)
      model.selectAdjacentSession(by: -1)

      #expect(model.listFocusRequests == requests + 2)
    }
  }

  // MARK: moveInbox

  @MainActor
  @Suite struct MoveInbox {
    func model(focus: String) -> BoardModel {
      let model = appliedModel([needsItem("a"), needsItem("b"), needsItem("c")])
      model.show(.inbox)
      model.inboxFocus = focus
      return model
    }

    @Test func withoutWrapNextStaysOnTheLastItem() {
      let model = model(focus: "c")

      model.moveInbox(by: 1, wrap: false)

      #expect(model.currentInboxItem == "c")
    }

    @Test func withoutWrapPreviousStaysOnTheFirstItem() {
      let model = model(focus: "a")

      model.moveInbox(by: -1, wrap: false)

      #expect(model.currentInboxItem == "a")
    }

    @Test func byDefaultNextFromTheLastItemWraps() {
      let model = model(focus: "c")

      model.moveInbox(by: 1)

      #expect(model.currentInboxItem == "a")
    }

    /// `moveInbox` before it called `ListStep`: the index of `currentInboxItem`, which falls back to the first
    /// item, stepped around the end of the list. It returns the new `inboxFocus` and how much `inboxJumps` grew.
    func oldMoveInbox(_ model: BoardModel, by step: Int) -> (focus: String?, jumps: Int) {
      let list = model.triage
      guard !list.isEmpty else { return (model.inboxFocus, 0) }
      let i = list.firstIndex { $0.id == model.currentInboxItem } ?? (step > 0 ? -1 : 0)
      return (list[((i + step) % list.count + list.count) % list.count].id, 1)
    }

    /// The focus is nil, each item, an id no session has, or a session that left the Inbox.
    @Test(arguments: 0...5, [1, -1])
    func wrapPicksWhatTheOldFormulaPicked(count: Int, step: Int) {
      let ids = (0..<count).map { "i\($0)" }

      let focuses: [String?] = [nil, "gone", "out"] + ids.map { Optional($0) }
      for focus in focuses {
        let model = appliedModel(ids.map { needsItem($0) } + [outsideTheInbox("out")])
        model.show(.inbox)
        model.inboxFocus = focus
        let expected = oldMoveInbox(model, by: step)
        let jumps = model.inboxJumps

        model.moveInbox(by: step)

        #expect(model.inboxFocus == expected.focus, "focus \(String(describing: focus))")
        #expect(model.inboxJumps == jumps + expected.jumps, "focus \(String(describing: focus))")
      }
    }
  }

  // MARK: moveBoardFocus and currentBoardCard

  @MainActor
  @Suite struct BoardFocus {
    /// Reading order: a, b, c, d.
    func model(focus: String?) -> BoardModel {
      let model = appliedModel([needsItem("a"), needsItem("b"), needsItem("c"), needsItem("d")])
      model.show(.board)
      model.boardGrid = BoardGrid(lanes: [[["a"], ["b", "c"]], [[], ["d"]]])
      model.boardFocus = focus
      return model
    }

    @Test func downMovesDownTheStack() {
      let model = model(focus: "b")

      model.moveBoardFocus(.down)

      #expect(model.boardFocus == "c")
    }

    /// The ring shows on the first card, so ↓ moves on from it, as j does from the Inbox's first item.
    @Test(arguments: [nil, "gone"] as [String?])
    func downFromAStaleFocusMovesFromTheFirstCard(_ focus: String?) {
      let model = model(focus: focus)

      model.moveBoardFocus(.down)

      #expect(model.boardFocus == "d")
    }

    @Test(arguments: [nil, "gone"] as [String?])
    func upFromAStaleFocusStaysOnTheFirstCard(_ focus: String?) {
      let model = model(focus: focus)

      model.moveBoardFocus(.up)

      #expect(model.boardFocus == "a")
    }

    @Test func currentBoardCardIsTheFocusWhileTheGridHasIt() {
      #expect(model(focus: "c").currentBoardCard == "c")
    }

    @Test(arguments: [nil, "gone"] as [String?])
    func currentBoardCardFallsBackToTheFirstCard(_ focus: String?) {
      #expect(model(focus: focus).currentBoardCard == "a")
    }

    @Test func currentBoardCardIsNilOnAnEmptyBoard() {
      let model = offlineModel()
      model.show(.board)
      model.boardFocus = "gone"

      #expect(model.currentBoardCard == nil)
    }
  }

  // MARK: listFocusTarget and requestListFocus

  @MainActor
  @Suite struct ListFocusRequests {
    @Test func aSelectionTargetsTheSidebar() {
      let model = appliedModel([needsItem("a")])
      model.show(.board)
      model.selection = "a"

      #expect(model.listFocusTarget == .sidebar)
    }

    @Test(arguments: [(MainView.inbox, ListFocus.inbox), (.board, .board)])
    func noSelectionTargetsTheMainView(_ view: MainView, _ target: ListFocus) {
      let model = appliedModel([needsItem("a")])
      model.show(view)

      #expect(model.listFocusTarget == target)
    }

    @Test func requestListFocusBumpsTheCount() {
      let model = offlineModel()
      let requests = model.listFocusRequests

      model.requestListFocus()

      #expect(model.listFocusRequests == requests + 1)
    }
  }

  // MARK: focusTerminal

  @MainActor
  @Suite struct FocusTerminal {
    /// Where the command finds its target.
    enum Place: CaseIterable { case selection, inboxTerminalOff, inboxTerminalOn, board }

    /// Sessions that have no Claude terminal.
    enum NoTerminals: CaseIterable {
      case unstartedFollowup, unstartedFollowupWithFolder, docketRow, cleanedUp

      func session(_ id: String) -> SessionSummary {
        switch self {
        case .unstartedFollowup:
          return followupWaitingToStart(id)
        case .unstartedFollowupWithFolder:
          var s = needsItem(id)
          s.followup = Followup(prompt: "p")
          return s
        case .docketRow:
          var s = needsItem(id)
          s.cwd = ""
          s.docket = DocketSummary(
            DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1"), DocketStatus())
          return s
        case .cleanedUp:
          var s = needsItem(id, state: .done)
          s.cleanup = CleanupStatus(state: .removed)
          return s
        }
      }
    }

    /// Everything the command may change.
    struct Snapshot: Equatable {
      var selection: String?
      var terminalFocus: String?
      var mainView: MainView
      var showingTerminal: Bool
      var inboxFocus: String?
      var boardFocus: String?

      @MainActor init(_ model: BoardModel) {
        selection = model.selection
        terminalFocus = model.terminalFocus
        mainView = model.mainView
        showingTerminal = model.showingTerminal
        inboxFocus = model.inboxFocus
        boardFocus = model.boardFocus
      }
    }

    /// A model whose only session is `target` and whose `place` names it. The session is in the Inbox list.
    func model(_ target: SessionSummary, at place: Place) throws -> BoardModel {
      let model = appliedModel([target, needsItem("other")])
      switch place {
      case .selection:
        model.selection = target.id
      case .inboxTerminalOff, .inboxTerminalOn:
        model.show(.inbox)
        model.inboxFocus = target.id
        model.showingTerminal = place == .inboxTerminalOn
        try #require(model.currentInboxItem == target.id)
      case .board:
        model.show(.board)
        model.boardGrid = BoardGrid(lanes: [[["other"], [target.id]]])
        model.boardFocus = target.id
        try #require(model.currentBoardCard == target.id)
      }
      return model
    }

    @Test func aSelectedSessionGetsTheTerminalFocus() throws {
      let model = try model(needsItem("a"), at: .selection)

      model.focusTerminal()

      #expect(model.terminalFocus == "a")
    }

    @Test func aSelectedSessionStaysSelected() throws {
      let model = try model(needsItem("a"), at: .selection)

      model.focusTerminal()

      #expect(model.selection == "a")
    }

    /// The Terminal toggle stays off, so the session's own view shows its terminal.
    @Test func theInboxWithTheTerminalToggleOffSelectsTheCurrentItem() throws {
      let model = try model(needsItem("a"), at: .inboxTerminalOff)

      model.focusTerminal()

      #expect(model.selection == "a")
      #expect(model.terminalFocus == "a")
      #expect(!model.showingTerminal)
    }

    /// The Inbox's right pane already shows the item's terminal.
    @Test func theInboxWithTheTerminalToggleOnFocusesThePaneInPlace() throws {
      let model = try model(needsItem("a"), at: .inboxTerminalOn)

      model.focusTerminal()

      #expect(model.terminalFocus == "a")
      #expect(model.selection == nil)
      #expect(model.visibleView == .inbox)
    }

    /// The card's session is in the Inbox list, so `openFromBoard` would show the Inbox instead.
    @Test func theBoardSelectsTheCurrentCard() throws {
      let model = try model(needsItem("a"), at: .board)

      model.focusTerminal()

      #expect(model.selection == "a")
      #expect(model.terminalFocus == "a")
    }

    @Test func theBoardWithNoFocusSelectsTheFirstCard() throws {
      let model = try model(needsItem("a"), at: .board)
      model.boardFocus = nil

      model.focusTerminal()

      #expect(model.selection == "other")
      #expect(model.terminalFocus == "other")
    }

    @Test(arguments: Place.allCases)
    func aSessionWithTerminalsCanTakeFocus(_ place: Place) throws {
      #expect(try model(needsItem("a"), at: place).canFocusTerminal)
    }

    @Test(arguments: NoTerminals.allCases, Place.allCases)
    func aSessionWithoutTerminalsChangesNothing(_ kind: NoTerminals, _ place: Place) throws {
      let session = kind.session("x")
      try #require(!session.hasTerminals || session.waitsToStart)
      let model = try model(session, at: place)
      let before = Snapshot(model)

      model.focusTerminal()

      #expect(Snapshot(model) == before)
    }

    @Test(arguments: NoTerminals.allCases, Place.allCases)
    func aSessionWithoutTerminalsCannotTakeFocus(_ kind: NoTerminals, _ place: Place) throws {
      let session = kind.session("x")
      try #require(!session.hasTerminals || session.waitsToStart)

      #expect(try !model(session, at: place).canFocusTerminal)
    }

    enum NoTarget: CaseIterable { case emptyInbox, emptyBoard, unlistedSelection, removedBoardCard }

    /// A model with nothing to focus: no item, no card, or an id that no session has.
    func model(_ shape: NoTarget) -> BoardModel {
      switch shape {
      case .emptyInbox:
        let model = offlineModel()
        model.show(.inbox)
        return model
      case .emptyBoard:
        let model = offlineModel()
        model.show(.board)
        return model
      case .unlistedSelection:
        let model = appliedModel([needsItem("a")])
        model.selectUnlisted("new")
        return model
      case .removedBoardCard:
        let model = appliedModel([needsItem("a")])
        model.show(.board)
        model.boardGrid = BoardGrid(lanes: [[["gone"]]])
        model.boardFocus = "gone"
        return model
      }
    }

    @Test(arguments: NoTarget.allCases)
    func noTargetCannotTakeFocus(_ shape: NoTarget) {
      #expect(!model(shape).canFocusTerminal)
    }

    @Test(arguments: NoTarget.allCases)
    func noTargetChangesNothing(_ shape: NoTarget) {
      let model = model(shape)
      let before = Snapshot(model)

      model.focusTerminal()

      #expect(Snapshot(model) == before)
    }
  }
}
