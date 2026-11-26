import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// Four sessions in the Inbox and the sidebar.
@MainActor
private func fourSessions() -> BoardModel { appliedModel(["a", "b", "c", "d"].map { needsItem($0) }) }

/// The four sessions and `w`, a working session with no Inbox item. The Board's grid holds all five cards.
@MainActor
private func boardSessions() -> BoardModel {
  var outside = needsItem("w", state: .working)
  outside.triage = nil
  let model = appliedModel(["a", "b", "c", "d"].map { needsItem($0) } + [outside])
  model.boardGrid = BoardGrid(lanes: [[["a", "b"], ["c"]], [["d"], ["w"]]])
  return model
}

/// The sidebar's `List(selection:)` binding. It shows `multiSelection` while that holds two or more ids, and the
/// set of `selection` otherwise.
@MainActor
@Suite struct MultiSelectionBinding {
  @Test func oneIDSetsTheSelection() {
    let model = fourSessions()

    model.sidebarSelection.wrappedValue = ["b"]

    #expect(model.selection == "b")
  }

  @Test func oneIDClearsTheMultiSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = ["c"]

    #expect(model.multiSelection.isEmpty)
  }

  /// The selection does not change, so a clear that runs only when `selection` changes misses this case.
  @Test func theSelectedIDAloneClearsTheMultiSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = ["a"]

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == "a")
  }

  @Test func noIDClearsTheMultiSelectionAndTheSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = []

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == nil)
  }

  @Test func twoIDsSetTheMultiSelection() {
    let model = fourSessions()

    model.sidebarSelection.wrappedValue = ["a", "b"]

    #expect(model.multiSelection == ["a", "b"])
  }

  @Test func twoIDsLeaveTheSelectionAlone() {
    let model = fourSessions()
    model.selection = "a"

    model.sidebarSelection.wrappedValue = ["a", "b"]

    #expect(model.selection == "a")
  }

  @Test func threeIDsReplaceAnEarlierMultiSelection() {
    let model = fourSessions()
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = ["b", "c", "d"]

    #expect(model.multiSelection == ["b", "c", "d"])
  }

  @Test func theBindingShowsTheMultiSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b", "c"]

    #expect(model.sidebarSelection.wrappedValue == ["a", "b", "c"])
  }

  @Test func theBindingShowsTheSelectionWithoutAMultiSelection() {
    let model = fourSessions()
    model.selection = "a"

    #expect(model.sidebarSelection.wrappedValue == ["a"])
  }

  @Test func theBindingIsEmptyWithNothingSelected() {
    #expect(fourSessions().sidebarSelection.wrappedValue.isEmpty)
  }

  /// Navigation history records only `selection`.
  @Test func multiSelectingAddsNoHistoryEntry() throws {
    let model = fourSessions()
    model.selection = "a"
    let before = model.history.entries.count

    model.sidebarSelection.wrappedValue = ["a", "b"]

    try #require(model.multiSelection == ["a", "b"])
    #expect(model.history.entries.count == before)
    #expect(model.history.current == NavLocation(place: .session("a"), terminal: false))
  }
}

/// Every path that changes `selection`, other than the sidebar binding, ends a multi-selection.
@MainActor
@Suite struct MultiSelectionSources {
  enum Source: String, CaseIterable, Sendable {
    case plainSelection, search, notification, keyboardStep, back, mainView, boardCard, createdSession

    /// Arranges `model` with `a` selected and a multi-selection of `a` and `b`, then changes the selection.
    @MainActor func run(_ model: BoardModel) {
      if self == .back {
        model.selection = "c"
      }
      model.selection = "a"
      model.multiSelection = ["a", "b"]
      switch self {
      case .plainSelection: model.selection = "c"
      case .search: model.openFromSearch("c")
      case .notification: model.reveal("c")
      case .keyboardStep: model.selectAdjacentSession(by: 1)
      case .back: model.goBack()
      case .mainView: model.show(.board)
      case .boardCard: model.openFromBoard("c")
      case .createdSession: model.selectUnlisted("new")
      }
    }
  }

  @Test(arguments: Source.allCases)
  func aSelectionChangeClearsTheMultiSelection(_ source: Source) {
    let model = fourSessions()

    source.run(model)

    #expect(model.multiSelection.isEmpty, "\(source.rawValue)")
  }

  /// The paths off the Board. A Board selection must not outlive the Board, because the sidebar would highlight
  /// rows that the detail pane does not show.
  enum BoardSource: String, CaseIterable, Sendable {
    case inbox, issues, board, inboxCard, sessionCard, search, notification, back, forward, recentPlace,
      nextNeedingYou, sidebarRow, plainSelection, createdSession

    /// Shows the Board with `ids` selected on it and history to go back or forward to session `c`.
    @MainActor func arrange(_ model: BoardModel, selecting ids: Set<String>) {
      if self == .back { model.selection = "c" }
      model.show(.board)
      if self == .forward {
        model.selection = "c"
        model.goBack()
      }
      model.multiSelection = ids
    }

    @MainActor func leave(_ model: BoardModel) {
      switch self {
      case .inbox: model.show(.inbox)
      case .issues: model.show(.issues)
      case .board: model.show(.board)
      case .inboxCard: model.openFromBoard("c")
      case .sessionCard: model.openFromBoard("w")
      case .search: model.openFromSearch("c")
      case .notification: model.reveal("c")
      case .back: model.goBack()
      case .forward: model.goForward()
      case .recentPlace: model.go(to: NavLocation(place: .session("c"), terminal: false))
      case .nextNeedingYou: model.selectNextNeedingYou()
      case .sidebarRow: model.sidebarSelection.wrappedValue = ["c"]
      case .plainSelection: model.selection = "c"
      case .createdSession: model.selectUnlisted("new")
      }
    }
  }

  @Test(arguments: BoardSource.allCases, [["a"], ["a", "b"]] as [Set<String>])
  func aPathOffTheBoardClearsTheBoardSelection(_ source: BoardSource, _ ids: Set<String>) throws {
    let model = boardSessions()
    source.arrange(model, selecting: ids)
    try #require(model.visibleView == .board)
    try #require(model.multiSelection == ids)

    source.leave(model)

    #expect(model.multiSelection.isEmpty, "\(source.rawValue)")
  }

  /// Next and Previous Session move the Board's focus ring and stay on the Board.
  @Test(arguments: [1, -1], [["a"], ["a", "b"]] as [Set<String>])
  func aKeyboardStepOnTheBoardMovesTheFocusRingAndKeepsTheSelection(_ step: Int, _ ids: Set<String>) {
    let model = boardSessions()
    model.show(.board)
    model.multiSelection = ids
    let jumps = model.boardJumps

    model.selectAdjacentSession(by: step)

    #expect(model.visibleView == .board)
    #expect(model.multiSelection == ids)
    // The reading order is a, b, c, d, w, and the ring starts on a.
    #expect(model.boardFocus == (step == 1 ? "b" : "w"))
    #expect(model.boardJumps == jumps + 1)
  }
}

/// A Board selection is `multiSelection` while the Board shows with no session selected. It can hold one id,
/// and the Board shows it in place of the multi-selection pane.
@MainActor
@Suite struct MultiSelectionOnBoard {
  /// The four sessions with `view` showing, `selection` selected, and `multi` multi-selected.
  func model(_ view: MainView, selection: String?, multi: Set<String>) -> BoardModel {
    let model = appliedModel(["a", "b", "c", "d"].map { removalSession($0, nil) })
    model.show(view)
    if let selection { model.selection = selection }
    model.multiSelection = multi
    return model
  }

  @Test func theBindingShowsABoardSelectionOfTwoCards() {
    let model = model(.board, selection: nil, multi: ["a", "b"])

    #expect(model.sidebarSelection.wrappedValue == ["a", "b"])
  }

  /// A sidebar row that already showed as the only selected one would not open on a click.
  @Test func theBindingLeavesABoardSelectionOfOneCardOut() {
    let model = model(.board, selection: nil, multi: ["a"])

    #expect(model.sidebarSelection.wrappedValue.isEmpty)
  }

  // MARK: The detail pane

  struct PaneShape: Sendable, CustomTestStringConvertible {
    var testDescription: String
    var view: MainView
    var selection: String?
    var multi: Set<String>
    var pane: Bool
  }

  nonisolated static let paneShapes = [
    PaneShape(testDescription: "a session and two ids", view: .inbox, selection: "a", multi: ["a", "b"], pane: true),
    PaneShape(
      testDescription: "a session opened from the Board and two ids", view: .board, selection: "a",
      multi: ["a", "b"], pane: true),
    PaneShape(testDescription: "the Inbox and two ids", view: .inbox, selection: nil, multi: ["a", "b"], pane: true),
    PaneShape(testDescription: "Issues and two ids", view: .issues, selection: nil, multi: ["a", "b"], pane: true),
    PaneShape(testDescription: "a session and no ids", view: .inbox, selection: "a", multi: [], pane: false),
    PaneShape(testDescription: "the Inbox and no ids", view: .inbox, selection: nil, multi: [], pane: false),
    PaneShape(testDescription: "the Board and one id", view: .board, selection: nil, multi: ["a"], pane: false),
    PaneShape(testDescription: "the Board and two ids", view: .board, selection: nil, multi: ["a", "b"], pane: false),
  ]

  @Test(arguments: paneShapes)
  func theDetailPaneShowsTheMultiSelectionOnlyOffTheBoard(_ shape: PaneShape) {
    let model = model(shape.view, selection: shape.selection, multi: shape.multi)

    #expect(model.showsMultiSelectionPane == shape.pane)
  }

  /// Off the Board, the pane switch must not change what the detail pane shows.
  @Test(arguments: paneShapes.filter { $0.view != .board || $0.selection != nil })
  func offTheBoardThePaneShowsWhenTheMultiSelectionDoes(_ shape: PaneShape) throws {
    let model = model(shape.view, selection: shape.selection, multi: shape.multi)
    try #require(model.visibleView != .board)

    #expect(model.showsMultiSelectionPane == model.showsMultiSelection)
  }

  /// Delete N Sessions…, ⌘⌫, and the Session menu read `showsMultiSelection`.
  @Test(arguments: [(["a"], false), (["a", "b"], true)] as [(Set<String>, Bool)])
  func aBoardSelectionOfTwoOrMoreCardsCountsAsAMultiSelection(_ ids: Set<String>, _ expected: Bool) {
    let model = model(.board, selection: nil, multi: ids)

    #expect(model.showsMultiSelection == expected)
  }

  // MARK: Refreshes

  struct Outcome: Equatable, Sendable, CustomStringConvertible {
    var selection: String?
    var multi: Set<String>
    var view: MainView?
    var description: String {
      "selection \(selection ?? "nil"), multi \(multi.sorted()), view \(view.map { "\($0)" } ?? "nil")"
    }
  }

  struct RefreshShape: Sendable, CustomTestStringConvertible {
    var testDescription: String
    var view: MainView
    var selection: String?
    var multi: Set<String>
    /// The sessions that the refresh lists with a queued removal, which hides them.
    var held: Set<String>
    var after: Outcome
  }

  nonisolated static let refreshShapes = [
    RefreshShape(
      testDescription: "one card, all listed", view: .board, selection: nil, multi: ["a"], held: [],
      after: Outcome(selection: nil, multi: ["a"], view: .board)),
    RefreshShape(
      testDescription: "two cards, all listed", view: .board, selection: nil, multi: ["a", "b"], held: [],
      after: Outcome(selection: nil, multi: ["a", "b"], view: .board)),
    RefreshShape(
      testDescription: "two cards, an unselected session held", view: .board, selection: nil, multi: ["a", "b"],
      held: ["c"], after: Outcome(selection: nil, multi: ["a", "b"], view: .board)),
    RefreshShape(
      testDescription: "two cards, one held", view: .board, selection: nil, multi: ["a", "b"], held: ["b"],
      after: Outcome(selection: nil, multi: ["a"], view: .board)),
    RefreshShape(
      testDescription: "two cards, both held", view: .board, selection: nil, multi: ["a", "b"], held: ["a", "b"],
      after: Outcome(selection: nil, multi: [], view: .board)),
    RefreshShape(
      testDescription: "one card, held by the removal job", view: .board, selection: nil, multi: ["a"],
      held: ["a"], after: Outcome(selection: nil, multi: [], view: .board)),
    // Clearing the hidden selection shows the Board. The refresh must still treat the selection as the
    // sidebar's: a new session is selected and the pane keeps the rest.
    RefreshShape(
      testDescription: "a session opened from the Board, held, with a sidebar multi-selection", view: .board,
      selection: "a", multi: ["a", "b", "c"], held: ["a"], after: Outcome(selection: "b", multi: ["b", "c"], view: nil)
    ),
    RefreshShape(
      testDescription: "a session opened from the Board, its one partner held", view: .board, selection: "a",
      multi: ["a", "b"], held: ["b"], after: Outcome(selection: "a", multi: [], view: nil)),
    RefreshShape(
      testDescription: "a session over the Inbox, with a sidebar multi-selection", view: .inbox, selection: "a",
      multi: ["a", "b", "c"], held: ["b"], after: Outcome(selection: "a", multi: ["a", "c"], view: nil)),
    RefreshShape(
      testDescription: "a session over Issues, held, with a sidebar multi-selection", view: .issues, selection: "a",
      multi: ["a", "b", "c"], held: ["a"], after: Outcome(selection: "b", multi: ["b", "c"], view: nil)),
    RefreshShape(
      testDescription: "the Inbox with a sidebar multi-selection and no session", view: .inbox, selection: nil,
      multi: ["a", "b", "c"], held: ["c"], after: Outcome(selection: "a", multi: ["a", "b"], view: nil)),
  ]

  @Test(arguments: refreshShapes)
  func aRefreshKeepsABoardSelectionOnTheBoardAndASidebarSelectionAsBefore(_ shape: RefreshShape) {
    let model = model(shape.view, selection: shape.selection, multi: shape.multi)

    model.apply(
      .success(["a", "b", "c", "d"].map { removalSession($0, shape.held.contains($0) ? .queued : nil) }),
      followups: nil)

    #expect(Outcome(selection: model.selection, multi: model.multiSelection, view: model.visibleView) == shape.after)
  }

  @Test(
    arguments: [
      (["ph1"], ["ph1"]),
      (["ph1", "hk"], ["ph1"]),
      (["hk"], []),
    ] as [(Set<String>, Set<String>)])
  func aFilterChangeKeepsTheShownPartOfABoardSelectionOnTheBoard(_ ids: Set<String>, _ kept: Set<String>) {
    let model = orgFilterModel(OrgFilter())
    model.apply(
      .success([
        orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard"),
        orgSession("ph2", "PostHog/posthog-js"),
      ]), followups: nil)
    model.show(.board)
    model.multiSelection = ids

    model.orgFilter = posthogOnly

    #expect(
      Outcome(selection: model.selection, multi: model.multiSelection, view: model.visibleView)
        == Outcome(selection: nil, multi: kept, view: .board))
  }
}

/// sbd's removal job holds a session that the refresh lists with a queued or running removal. The app hides a
/// held session, so it leaves the multi-selection.
@MainActor
@Suite struct MultiSelectionRemovalJob {
  func refresh(_ model: BoardModel, holding held: [String: Removal.State]) {
    model.apply(.success(["a", "b", "c", "d"].map { removalSession($0, held[$0]) }), followups: nil)
  }

  func model(selection: String, multi: Set<String>) -> BoardModel {
    let model = appliedModel(["a", "b", "c", "d"].map { removalSession($0, nil) })
    model.selection = selection
    model.multiSelection = multi
    return model
  }

  @Test(arguments: [Removal.State.queued, .running])
  func aHeldSessionLeavesTheMultiSelection(_ state: Removal.State) {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["b": state])

    #expect(model.multiSelection == ["a", "c"])
  }

  /// The refresh clears a held `selection`. That clear must not empty the rest of the multi-selection.
  @Test func aHeldSelectedSessionLeavesTheOthersSelected() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["a": .queued])

    #expect(model.multiSelection == ["b", "c"])
    #expect(model.selection != "a")
  }

  @Test func aSessionWhoseRemovalFailedStaysInTheMultiSelection() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["b": .failed])

    #expect(model.multiSelection == ["a", "b", "c"])
  }

  /// One id left is a single selection, as the binding's set with one id makes it.
  @Test func aMultiSelectionThatDropsToOneIDEnds() {
    let model = model(selection: "a", multi: ["a", "b"])

    refresh(model, holding: ["b": .queued])

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == "a")
    #expect(model.sidebarSelection.wrappedValue == ["a"])
  }

  /// The detail pane shows the multi-selection, and history and the Session menu still have a session.
  @Test func aHeldSelectedSessionPassesTheSelectionToARemainingID() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["a": .queued])

    #expect(model.selection == "b")
    #expect(model.multiSelection == ["b", "c"])
    #expect(model.visibleView == nil)
  }

  @Test func theRemainingIDBecomesTheSelectionWhenTheSelectedSessionIsHeld() {
    let model = model(selection: "a", multi: ["a", "b"])

    refresh(model, holding: ["a": .queued])

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == "b")
  }

  @Test func theBindingNeverShowsAHeldSession() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["a": .queued, "b": .running])

    #expect(model.sidebarSelection.wrappedValue.isDisjoint(with: ["a", "b"]))
  }

  /// A session that the org filter hides can't be in the selection.
  @Test func aSessionThatTheOrgFilterHidesLeavesTheMultiSelection() {
    let model = orgFilterModel(OrgFilter())
    model.apply(
      .success([
        orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard"),
        orgSession("ph2", "PostHog/posthog-js"),
      ]), followups: nil)
    model.selection = "ph1"
    model.multiSelection = ["ph1", "hk", "ph2"]

    model.orgFilter = posthogOnly

    #expect(model.multiSelection == ["ph1", "ph2"])
  }
}

/// Delete N Sessions…, which MultiSelectionView's button, the selected row's context menu, and ⌘⌫ in the sidebar
/// all call as `checkSelectionRemoval()`. It asks sbd for a work-scope plan and shows it in the Delete All sheet.
@MainActor
@Suite struct MultiSelectionDelete {
  /// A Waiting session, a working one, and a Done one.
  nonisolated static let list = [
    needsItem("w", state: .waiting), needsItem("k", state: .working), needsItem("d", state: .done),
  ]
  nonisolated static let plan = RemovalPlan(remove: ["w", "k", "d"].map(removalItem), skip: [])

  func multiSelected(_ sent: SentRequests, _ list: [SessionSummary] = list, plan: RemovalPlan = plan) -> BoardModel {
    let model = appliedModel(list)
    model.send = recordingSend(sent, plan: plan)
    model.selection = list[0].id
    model.multiSelection = Set(list.map(\.id))
    return model
  }

  func confirming(_ model: BoardModel) async -> RemovalPlan? {
    await settle { if case .confirming = model.doneRemoval { true } else { false } }
    guard case .confirming(let shown, _) = model.doneRemoval else { return nil }
    return shown
  }

  // MARK: The plan

  @Test func asksSbdForAPlanWithRmPlan() async {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    #expect(sent.ops.first == "rm-plan")
  }

  @Test func thePlanTakesTheWorkScope() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    let args = try #require(sent.value.first?.args)
    #expect(args["scope"] == .string("work"))
  }

  @Test func thePlanTargetsTheSelectedSessions() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    let args = try #require(sent.value.first?.args)
    #expect(Set(args["targets"]?.array?.compactMap(\.string) ?? []) == ["w", "k", "d"])
  }

  /// The same `rm` arguments as the Done delete icon and Delete All: the worktree, and sbd adds the branch and
  /// the remote branch when the PR merged.
  @Test func thePlanAsksForTheWorktreeAndTheRemoteBranch() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    let args = try #require(sent.value.first?.args)
    #expect(args["worktree"] == .bool(true))
    #expect(args["remote_branch"] == .bool(true))
  }

  @Test func thePlanShowsInTheDeleteAllConfirmation() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    let shown = await confirming(model)

    #expect(shown == Self.plan)
    #expect(model.showingDoneRemoval)
  }

  // MARK: The confirmation

  @Test func confirmingSendsOneRmQueueWithThePlannedIDs() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }

    #expect(sent.queues.count == 1)
    #expect(Set(sent.queues.first?["targets"]?.array?.compactMap(\.string) ?? []) == ["w", "k", "d"])
  }

  /// `rm-queue` mirrors the plan's scope. With `done`, sbd would skip the Waiting and working sessions.
  @Test func confirmingQueuesWithTheWorkScope() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }

    let args = try #require(sent.queues.first)
    #expect(args["scope"] == .string("work"))
    #expect(args["worktree"] == .bool(true))
    #expect(args["remote_branch"] == .bool(true))
  }

  /// The work scope belongs to the multi-select confirmation alone.
  @Test func aLaterDeleteAllQueuesWithTheDoneScope() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let first = try #require(await confirming(model))
    model.removeDone(first)
    await settle { !sent.queues.isEmpty }

    model.checkDoneRemoval()
    let second = try #require(await confirming(model))
    model.removeDone(second)
    await settle { sent.queues.count >= 2 }

    #expect(sent.queues.count == 2)
    #expect(sent.queues.last?["scope"] == .string("done"))
  }

  @Test func confirmingAfterAFilterChangeThatHidesAPlannedIDNeverQueuesIt() async throws {
    let sent = SentRequests()
    let list = [orgSession("ph", "PostHog/posthog"), orgSession("hk", "haacked/switchboard")]
    let model = orgFilterModel(OrgFilter())
    model.apply(.success(list), followups: nil)
    model.send = recordingSend(sent, plan: RemovalPlan(remove: [removalItem("ph"), removalItem("hk")], skip: []))
    model.selection = "ph"
    model.multiSelection = ["ph", "hk"]
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.orgFilter = posthogOnly
    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }

    #expect(sent.queues.first?["targets"]?.array?.compactMap(\.string) == ["ph"])
    #expect(sent.queues.first?["scope"] == .string("work"))
  }

  /// sbd answers on a serial queue, so the reply to a cancelled check can arrive while a later check waits.
  @Test func aReplyToACancelledCheckNeverFillsTheNextOne() async throws {
    let sent = SentRequests()
    let gate = DispatchSemaphore(value: 0)
    let model = appliedModel(["a", "b", "c", "d"].map { needsItem($0) })
    model.send = { op, args in
      sent.append(op, args)
      if sent.value.count == 1 { gate.wait() }
      let targets = args["targets"]?.array?.compactMap(\.string) ?? []
      return try JSON(encoding: RemovalPlan(remove: targets.map(removalItem), skip: []))
    }
    model.selection = "a"
    model.multiSelection = ["a", "b"]
    model.checkSelectionRemoval()
    await settle { sent.value.count == 1 }

    model.doneRemoval = nil
    model.sidebarSelection.wrappedValue = ["c", "d"]
    model.checkSelectionRemoval()
    gate.signal()
    let shown = try #require(await confirming(model))

    #expect(Set(shown.remove.map(\.id)) == ["c", "d"])
  }

  @Test func confirmingClosesTheSheet() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.removeDone(shown)

    #expect(model.doneRemoval == nil)
  }

  /// The queued sessions leave the lists, and the multi-selection ends.
  @Test func theRefreshAfterTheQueueEndsTheMultiSelection() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))
    try #require(model.multiSelection == ["w", "k", "d"])

    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }
    model.apply(.success(Self.list.map { removalSession($0.id, .queued, state: $0.state) }), followups: nil)

    #expect(model.multiSelection.isEmpty)
  }

  // MARK: Conversations in the multi-selection

  /// A conversation row that the sidebar's multi-selection can hold beside a work session. A delete removes only
  /// work sessions, and sbd's plan skips the others.
  enum SelectedConversation: String, CaseIterable, Sendable {
    case chat, managerConversation, archivedChat

    var session: SessionSummary {
      switch self {
      case .chat:
        var s = chatItem("c", group: "g1", state: .working)
        s.activity = ChatActivity(replies: 1, unread: 0)
        return s
      case .managerConversation:
        var s = needsItem("c", manager: true, state: .working)
        s.activity = ChatActivity(replies: 1, unread: 0)
        return s
      case .archivedChat:
        var s = chatItem("c", group: "g1", state: .needsYou)
        s.triage = nil
        s.activity = ChatActivity(replies: 1, unread: 0, lastMessageAt: 1, archived: true)
        return s
      }
    }
  }

  func withConversation(_ row: SelectedConversation) -> BoardModel {
    let list = [needsItem("w", state: .waiting), row.session]
    let model = multiSelected(SentRequests(), list, plan: RemovalPlan(remove: ["w", "c"].map(removalItem), skip: []))
    model.showingArchive = true
    return model
  }

  @Test(arguments: SelectedConversation.allCases)
  func aConversationRowJoinsTheMultiSelectionButNotTheDelete(_ row: SelectedConversation) {
    let model = withConversation(row)

    #expect(Set(model.multiSelected.map(\.id)) == ["w", "c"], "\(row.rawValue)")
    #expect(model.removableSelectionCount == 1, "\(row.rawValue)")
  }

  @Test func aMultiSelectionOfOnlyChatsCountsNothingToDelete() {
    var c1 = chatItem("c1", group: "g1", state: .working)
    c1.activity = ChatActivity(replies: 1, unread: 0)
    var c2 = chatItem("c2", group: "g2", state: .working)
    c2.activity = ChatActivity(replies: 1, unread: 0)
    let model = multiSelected(SentRequests(), [c1, c2])

    #expect(Set(model.multiSelected.map(\.id)) == ["c1", "c2"])
    #expect(model.removableSelectionCount == 0)
  }
}

@Suite struct MultiSelectionText {
  @Test(arguments: [(2, "2 sessions selected"), (5, "5 sessions selected")])
  func theDetailPaneNamesHowManySessionsAreSelected(_ count: Int, _ expected: String) {
    #expect(DoneRemovalText.selected(count) == expected)
  }

  @Test(arguments: [(1, "Delete 1 Session…"), (2, "Delete 2 Sessions…"), (5, "Delete 5 Sessions…")])
  func theDeleteButtonNamesHowManySessionsItDeletes(_ count: Int, _ expected: String) {
    #expect(DoneRemovalText.deleteSessions(count) == expected)
  }

  @Test func theDeleteButtonEndsWithAnEllipsisCharacter() {
    let text = DoneRemovalText.deleteSessions(2)

    #expect(text.hasSuffix("\u{2026}"))
    #expect(!text.contains("..."))
  }

  @Test func aWorkingSessionSaysItsClaudeStops() {
    #expect(DoneRemovalText.working(needsItem("k", state: .working)) == "claude is working and stops")
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .working })
  func aSessionThatIsNotWorkingSaysNothingAboutItsClaude(_ state: AttentionState) {
    #expect(DoneRemovalText.working(needsItem("s", state: state)) == nil)
  }

  /// A plan item whose session the board no longer lists.
  @Test func anUnlistedSessionSaysNothingAboutItsClaude() {
    #expect(DoneRemovalText.working(nil) == nil)
  }
}
