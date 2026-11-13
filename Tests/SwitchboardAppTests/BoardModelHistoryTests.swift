import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func at(_ place: NavLocation.Place, terminal: Bool = false) -> NavLocation {
  NavLocation(place: place, terminal: terminal)
}

private func sessions(_ ids: [String]) -> [SessionSummary] { ids.map { needsItem($0) } }

/// A working session with no Inbox item.
private func workingOutsideTheInbox(_ id: String) -> SessionSummary {
  var s = needsItem(id, state: .working)
  s.triage = nil
  return s
}

/// Three sessions in the Inbox.
@MainActor
private func threeSessions() -> BoardModel { appliedModel(sessions(["a", "b", "c"])) }

/// A PostHog session, a haacked one, and another PostHog one, under All Orgs.
@MainActor
private func twoOrgs() -> BoardModel {
  let model = orgFilterModel(OrgFilter())
  model.apply(
    .success([
      orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard"),
      orgSession("ph2", "PostHog/posthog-js"),
    ]), followups: nil)
  return model
}

/// Shows the Board, selects `first`, `middle`, and `last`, and goes back to `middle`. The entries end
/// `[Board, first, middle, last]` with the cursor on `middle`. Clearing the selection there shows the Board,
/// which differs from both neighbors, so a replace at `middle` merges nothing and keeps the count.
@MainActor
private func selectBetween(_ model: BoardModel, _ first: String, _ middle: String, _ last: String) throws {
  model.show(.board)
  model.selection = first
  model.selection = middle
  model.selection = last
  model.goBack()
  try #require(model.selection == middle)
  try #require(model.canGoForward)
}

@MainActor
@Suite struct BoardModelHistoryTests {
  // MARK: Each user navigation adds one entry

  @Test func selectingASessionAddsOneEntry() {
    let model = threeSessions()
    let before = model.history.entries.count

    model.selection = "a"

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("a")))
    #expect(model.history.current == model.location)
  }

  /// `show` writes `selection` and then `mainView`. Without a batch, the first write would record the Inbox.
  @Test func showingTheBoardFromASelectedSessionAddsOneBoardEntry() {
    let model = threeSessions()
    model.selection = "a"
    let before = model.history.entries.count

    model.show(.board)

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.board))
    #expect(model.history.current == model.location)
  }

  @Test func backFromIssuesReturnsToTheBoardAndForwardReturnsToIssues() {
    let model = threeSessions()
    model.show(.board)
    model.show(.issues)
    #expect(model.history.current == at(.issues))
    #expect(model.label(for: at(.issues)) == "Issues")

    model.goBack()
    #expect(model.mainView == .board)

    model.goForward()
    #expect(model.mainView == .issues)
    #expect(model.history.current == model.location)
  }

  /// `openFromBoard` calls `show(.inbox)` and then writes `inboxFocus`. The nested batches record once.
  @Test func aBoardCardForAnInboxItemAddsOneInboxEntry() {
    let model = threeSessions()
    model.show(.board)
    let before = model.history.entries.count

    model.openFromBoard("b")

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.inbox("b")))
    #expect(model.history.current == model.location)
  }

  @Test func aBoardCardForASessionOutsideTheInboxAddsOneSessionEntry() {
    let model = appliedModel([needsItem("a"), workingOutsideTheInbox("r")])
    model.show(.board)
    let before = model.history.entries.count

    model.openFromBoard("r")

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("r")))
    #expect(model.history.current == model.location)
  }

  @Test func movingInTheInboxAddsAnEntry() throws {
    let model = threeSessions()
    let triage = model.triage.map(\.id)
    try #require(triage.count == 3)
    let before = model.history.entries.count

    model.moveInbox(by: 1)

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.inbox(triage[1])))
    #expect(model.history.current == model.location)
  }

  @Test func clickingAnInboxRowAddsAnEntry() throws {
    let model = threeSessions()
    let triage = model.triage.map(\.id)
    try #require(triage.count == 3)
    let before = model.history.entries.count

    model.inboxFocus = triage[2]

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.inbox(triage[2])))
    #expect(model.history.current == model.location)
  }

  /// The Inbox already shows its first item while the focus is nil, so the screen does not change.
  @Test func clickingTheFirstInboxItemWhileTheFocusIsNilAddsNoEntry() throws {
    let model = threeSessions()
    let first = try #require(model.triage.first?.id)
    #expect(model.inboxFocus == nil)
    let before = model.history.entries.count

    model.inboxFocus = first

    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.inbox(first)))
    #expect(model.history.current == model.location)
  }

  @Test func nextNeedingYouOutsideTheInboxAddsAnEntry() throws {
    let model = threeSessions()
    let needs = model.needsUser.map(\.id)
    try #require(needs.count == 3)
    model.selection = needs[0]
    let before = model.history.entries.count

    model.selectNextNeedingYou()

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session(needs[1])))
    #expect(model.history.current == model.location)
  }

  @Test func steppingToTheAdjacentSessionInTheSidebarAddsAnEntry() throws {
    let model = threeSessions()
    let order = model.sidebarOrder
    try #require(order.count == 3)
    model.selection = order[0]
    let before = model.history.entries.count

    model.selectAdjacentSession(by: 1)

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session(order[1])))
    #expect(model.history.current == model.location)
  }

  /// A step on the Board moves only `boardFocus`, which is not a place.
  @Test func steppingOnTheBoardAddsNoEntry() {
    let model = threeSessions()
    model.show(.board)
    model.boardGrid = BoardGrid(lanes: [[["a"], ["b"]]])
    model.boardFocus = "a"
    let before = model.history

    model.selectAdjacentSession(by: 1)

    #expect(model.boardFocus == "b")
    #expect(model.history == before)
    #expect(model.history.current == model.location)
  }

  @Test func focusingTheTerminalFromTheBoardAddsOneSessionEntry() throws {
    let model = threeSessions()
    model.show(.board)
    model.boardGrid = BoardGrid(lanes: [[["b"], ["a"]]])
    model.boardFocus = "a"
    try #require(model.currentBoardCard == "a")
    let before = model.history.entries.count

    model.focusTerminal()

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("a")))
    #expect(model.history.current == model.location)
  }

  @Test func openingFromSearchAddsAnEntry() {
    let model = threeSessions()
    let before = model.history.entries.count

    model.openFromSearch("b")

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("b")))
    #expect(model.history.current == model.location)
  }

  @Test func turningOnTheTerminalInTheInboxAddsAnEntry() throws {
    let model = threeSessions()
    let first = try #require(model.triage.first?.id)
    let before = model.history.entries.count

    model.showingTerminal = true

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.inbox(first), terminal: true))
    #expect(model.history.current == model.location)
  }

  @Test func revealingASessionAddsAnEntry() {
    let model = threeSessions()
    let before = model.history.entries.count

    model.reveal("b")

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("b")))
    #expect(model.history.current == model.location)
  }

  @Test func selectingAnUnlistedSessionAddsOneEntry() {
    let model = threeSessions()
    let before = model.history.entries.count

    model.selectUnlisted("new")

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("new")))
    #expect(model.history.current == model.location)
  }

  /// `resolve` counts the pending selection as available before a refresh lists it.
  @Test func backWorksFromAnUnlistedSelectionBeforeARefreshListsIt() {
    let model = threeSessions()
    model.selectUnlisted("new")

    #expect(model.canGoBack)
    model.goBack()

    #expect(model.selection == nil)
    #expect(model.visibleView == .inbox)
    #expect(model.history.current == model.location)
  }

  @Test func openingAListedChatAddsAnEntry() {
    let model = appliedModel([needsItem("a"), chatItem("c", group: "g1")])
    let before = model.history.entries.count

    model.openChat("g1")

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("c")))
    #expect(model.history.current == model.location)
  }

  @Test func startingANewGroupFromASelectedSessionAddsOneBoardEntry() {
    let model = threeSessions()
    model.selection = "a"
    let before = model.history.entries.count

    model.startNewGroup()

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.board))
    #expect(model.history.current == model.location)
  }

  // MARK: The terminal flag

  /// A work session always shows its terminals, so the flag changes nothing on screen.
  @Test func theTerminalToggleOnAWorkSessionAddsNoEntry() {
    let model = threeSessions()
    model.selection = "a"
    let before = model.history

    model.showingTerminal = true

    #expect(model.history == before)
    #expect(model.history.current == at(.session("a")))
    #expect(model.history.current == model.location)
  }

  @Test func theTerminalToggleOnAChatAddsAnEntry() {
    let model = appliedModel([needsItem("a"), chatItem("c", group: "g1")])
    model.selection = "c"
    let before = model.history.entries.count

    model.showingTerminal = true

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("c"), terminal: true))
    #expect(model.history.current == model.location)
  }

  @Test func backRestoresAChatsPreviousTerminalFlag() {
    let model = appliedModel([needsItem("a"), chatItem("c", group: "g1")])
    model.selection = "c"
    model.showingTerminal = true

    model.goBack()

    #expect(model.selection == "c")
    #expect(!model.showingTerminal)
    #expect(model.history.current == model.location)
  }

  @Test func theTerminalToggleOnAManagerAddsAnEntry() {
    let model = appliedModel([needsItem("a"), needsItem("m", manager: true)])
    model.selection = "m"
    let before = model.history.entries.count

    model.showingTerminal = true

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == at(.session("m"), terminal: true))
    #expect(model.history.current == model.location)
  }

  @Test func backRestoresAManagersPreviousTerminalFlag() {
    let model = appliedModel([needsItem("a"), needsItem("m", manager: true)])
    model.selection = "m"
    model.showingTerminal = true

    model.goBack()

    #expect(model.selection == "m")
    #expect(!model.showingTerminal)
    #expect(model.history.current == model.location)
  }

  /// The flag changes while the work session shows, so only the Manager's entry can turn it back on.
  @Test func forwardFromAWorkSessionToAManagerRestoresTheManagersTerminalFlag() throws {
    let model = appliedModel([needsItem("a"), needsItem("m", manager: true)])
    model.selection = "a"
    model.showingTerminal = true
    model.selection = "m"
    model.goBack()
    try #require(model.selection == "a")
    model.showingTerminal = false

    model.goForward()

    #expect(model.selection == "m")
    #expect(model.showingTerminal)
    #expect(model.history.current == at(.session("m"), terminal: true))
    #expect(model.history.current == model.location)
  }

  /// The flag changes while the work session shows, so only the Manager's entry can turn it back off.
  @Test func backFromAWorkSessionToAManagerRestoresTheManagersTerminalFlagOff() {
    let model = appliedModel([needsItem("a"), needsItem("m", manager: true)])
    model.selection = "m"
    model.selection = "a"
    model.showingTerminal = true

    model.goBack()

    #expect(model.selection == "m")
    #expect(!model.showingTerminal)
    #expect(model.history.current == at(.session("m")))
    #expect(model.history.current == model.location)
  }

  // MARK: Writes that are not navigations replace the current entry

  @Test func aRefreshThatDropsTheSelectedSessionReplacesItsEntry() throws {
    let model = threeSessions()
    try selectBetween(model, "c", "a", "b")
    let before = model.history.entries.count

    model.apply(.success(sessions(["b", "c"])), followups: nil)

    #expect(model.selection == nil)
    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.board))
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  @Test func forwardStillWorksAfterARefreshDropsTheSelectedSession() throws {
    let model = threeSessions()
    try selectBetween(model, "c", "a", "b")
    model.apply(.success(sessions(["b", "c"])), followups: nil)

    model.goForward()

    #expect(model.selection == "b")
    #expect(model.history.current == model.location)
  }

  @Test func aFilterThatHidesTheSelectionReplacesItsEntry() throws {
    let model = twoOrgs()
    try selectBetween(model, "ph1", "hk", "ph2")
    let before = model.history.entries.count

    model.orgFilter = posthogOnly

    #expect(model.selection == nil)
    #expect(model.orgFilter == posthogOnly)
    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.board))
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  @Test func removingTheSelectedSessionReplacesItsEntry() throws {
    let model = threeSessions()
    model.send = { _, _ in .null }
    try selectBetween(model, "c", "a", "b")
    let before = model.history.entries.count

    model.remove("a")

    #expect(model.selection == nil)
    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.board))
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  @Test func deletingTheSelectedDoneSessionReplacesItsEntry() async throws {
    let done = needsItem("d", state: .done)
    let model = appliedModel(sessions(["b", "c"]) + [done])
    model.send = { _, _ in .null }
    try selectBetween(model, "c", "d", "b")
    let before = model.history.entries.count

    model.deleteDone(done)
    await settle { model.selection == nil }

    #expect(model.selection == nil)
    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.board))
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  @Test func deletingTheSelectedSessionWithItsWorktreeReplacesItsEntry() async throws {
    let model = appliedModel(sessions(["b", "c"]) + [needsItem("d", state: .done)])
    model.send = { _, _ in .null }
    try selectBetween(model, "c", "d", "b")
    let before = model.history.entries.count

    model.delete("d", branch: true)
    await settle { model.selection == nil }

    #expect(model.selection == nil)
    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.board))
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  @Test func deleteAllDoneThatRemovesTheSelectedSessionReplacesItsEntry() async throws {
    let model = appliedModel(sessions(["b", "c"]) + [needsItem("d", state: .done)])
    model.send = { _, args in
      let id = args["targets"]?.array?.first?.string ?? ""
      return try JSON(encoding: DoneRemovalResult(removed: [id], skipped: [], partial: []))
    }
    try selectBetween(model, "c", "d", "b")
    let before = model.history.entries.count
    let plan = DoneRemovalPlan(
      remove: [.init(id: "d", name: "d", pr: nil, worktree: nil, branch: nil, remoteBranch: false)], skip: [])
    model.doneRemoval = .confirming(plan)

    model.removeDone(plan)
    await settle { if case .finished = model.doneRemoval { true } else { false } }

    #expect(model.selection == nil)
    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.board))
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  /// Acknowledge moves the Inbox to the next item on its own, so the move is not a navigation.
  @Test func acknowledgingTheCurrentInboxItemReplacesItsEntry() throws {
    let model = threeSessions()
    model.send = { _, _ in .null }
    let triage = model.triage.map(\.id)
    try #require(triage.count == 3)
    model.inboxFocus = triage[0]
    model.selection = triage[2]
    model.goBack()
    try #require(model.visibleView == .inbox)
    let before = model.history.entries.count

    model.acknowledge(triage[0])

    #expect(model.currentInboxItem == triage[1])
    #expect(model.history.entries.count == before)
    #expect(model.history.current == at(.inbox(triage[1])))
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  @Test func applyingTheSameListFiveTimesChangesNothing() {
    let model = threeSessions()
    model.selection = "a"
    model.selection = "b"
    model.goBack()
    let before = model.history

    for _ in 0..<5 { model.apply(.success(sessions(["a", "b", "c"])), followups: nil) }

    #expect(model.history == before)
    #expect(model.history.current == model.location)
  }

  /// The refresh changes the Inbox's current item without writing any of the four properties.
  @Test func aRefreshThatDropsTheFocusedInboxItemKeepsTheCurrentEntryInStep() throws {
    let model = threeSessions()
    let triage = model.triage.map(\.id)
    try #require(triage.count == 3)
    model.inboxFocus = triage[1]
    let before = model.history.entries.count

    model.apply(.success(sessions(triage.filter { $0 != triage[1] })), followups: nil)

    #expect(model.history.entries.count <= before)
    #expect(model.history.current == model.location)
  }

  // MARK: Restore

  @Test func backAndForwardLeaveTheCountUnchanged() {
    let model = threeSessions()
    model.selection = "a"
    model.selection = "b"
    let before = model.history.entries.count

    model.goBack()
    #expect(model.selection == "a")
    #expect(model.history.entries.count == before)

    model.goForward()
    #expect(model.selection == "b")
    #expect(model.history.entries.count == before)
    #expect(model.history.current == model.location)
  }

  /// The sidebar's `List` writes the restored selection back through its binding.
  @Test func aBindingEchoOfTheRestoredSelectionAddsNoEntry() {
    let model = threeSessions()
    model.selection = "a"
    model.selection = "b"
    model.goBack()
    let before = model.history

    model.selection = "a"

    #expect(model.history == before)
    #expect(model.canGoForward)
    #expect(model.history.current == model.location)
  }

  @Test func backToAnInboxEntryRestoresTheViewTheItemAndTheTerminalFlag() throws {
    let model = threeSessions()
    let triage = model.triage.map(\.id)
    try #require(triage.count == 3)
    model.inboxFocus = triage[1]
    model.showingTerminal = true
    model.show(.board)
    model.showingTerminal = false
    model.inboxFocus = triage[2]
    let jumps = model.inboxJumps

    model.goBack()

    #expect(model.selection == nil)
    #expect(model.mainView == .inbox)
    #expect(model.inboxFocus == triage[1])
    #expect(model.showingTerminal)
    #expect(model.inboxJumps == jumps + 1)
    #expect(model.history.current == at(.inbox(triage[1]), terminal: true))
    #expect(model.history.current == model.location)
  }

  @Test func backToAnInboxItemThatLeftTheListLandsOnTheFirstItem() throws {
    let model = threeSessions()
    let triage = model.triage.map(\.id)
    try #require(triage.count == 3)
    model.inboxFocus = triage[1]
    model.show(.board)
    model.apply(.success(sessions(triage.filter { $0 != triage[1] })), followups: nil)
    let first = try #require(model.triage.first?.id)

    model.goBack()

    #expect(model.visibleView == .inbox)
    #expect(model.currentInboxItem == first)
    #expect(model.location == at(.inbox(first)))
    #expect(model.history.current == model.location)
  }

  // MARK: The org filter

  /// Restoring a hidden session would widen the filter through `selection`'s `showOrg`.
  @Test func backSkipsASessionThatTheFilterHidesAndKeepsTheFilter() {
    let model = twoOrgs()
    model.selection = "ph1"
    model.selection = "hk"
    model.selection = "ph2"
    model.orgFilter = posthogOnly

    model.goBack()

    #expect(model.selection == "ph1")
    #expect(model.orgFilter == posthogOnly)
    #expect(model.history.current == model.location)
  }

  @Test func backReachesAHiddenSessionAfterTheFilterShowsItAgain() {
    let model = twoOrgs()
    model.selection = "ph1"
    model.selection = "hk"
    model.selection = "ph2"
    model.orgFilter = posthogOnly
    model.orgFilter = OrgFilter()

    model.goBack()

    #expect(model.selection == "hk")
    #expect(model.history.current == model.location)
  }

  /// Selecting a hidden session widens the filter inside `selection`'s write. The filter change must not
  /// overwrite the entry the user came from.
  @Test func selectingAHiddenSessionKeepsThePlaceBeforeIt() {
    let model = twoOrgs()
    model.selection = "ph1"
    model.orgFilter = posthogOnly

    model.selection = "hk"

    #expect(model.orgFilter.shows(orgSession("hk", "haacked/switchboard")))
    model.goBack()
    #expect(model.selection == "ph1")
    #expect(model.history.current == model.location)
  }

  @Test func recentPlacesLeaveOutASessionThatTheFilterHides() {
    let model = twoOrgs()
    model.selection = "ph1"
    model.selection = "hk"
    model.selection = "ph2"
    model.orgFilter = posthogOnly

    #expect(!model.recentPlaces.contains(at(.session("hk"))))
    #expect(model.recentPlaces.contains(at(.session("ph1"))))
    #expect(model.history.current == model.location)
  }

  // MARK: Recent places

  @Test func recentPlacesListTheNewestFirstWithoutTheCurrentPlace() throws {
    let model = threeSessions()
    let first = try #require(model.triage.first?.id)
    model.selection = "a"
    model.selection = "b"
    model.show(.board)

    #expect(model.recentPlaces == [at(.session("b")), at(.session("a")), at(.inbox(first))])
    #expect(model.history.current == model.location)
  }

  @Test func choosingARecentPlacePushesItAndDropsTheForwardEntries() {
    let model = threeSessions()
    model.selection = "a"
    model.selection = "b"
    model.selection = "c"
    model.goBack()
    model.goBack()
    let before = model.history.entries.count

    model.go(to: at(.session("c")))

    #expect(model.selection == "c")
    #expect(model.history.entries.count == before - 1)
    #expect(!model.canGoForward)
    #expect(model.history.current == model.location)
  }

  // MARK: The button state agrees with the action

  /// Histories in which Back or Forward must skip an entry it cannot show: a removed session or Inbox item, a
  /// session the org filter hides, or an entry equal to the current place. Each shape is built through the model
  /// and states whether Back and Forward have somewhere to go.
  enum HistoryShape: String, CaseIterable, Sendable {
    case launch, cursorAtTheEnd, cursorInTheMiddle, removedBehind, removedAhead, equalBehindAfterASession,
      equalBehindWithNothingElse, aXaWithXRemoved, filterHiddenBehind, filterShowsItAgain, removedInboxItemBehind,
      chatTerminalBehind, managerTerminalBehind, removedManagerTerminalBehind, unlistedSelection

    var canGoBack: Bool {
      switch self {
      case .launch, .equalBehindWithNothingElse, .aXaWithXRemoved: false
      default: true
      }
    }

    var canGoForward: Bool {
      switch self {
      case .cursorInTheMiddle, .removedAhead: true
      default: false
      }
    }

    @MainActor func build() throws -> BoardModel {
      switch self {
      case .launch:
        let model = threeSessions()
        model.inboxFocus = try #require(model.triage.first?.id)
        return model
      case .cursorAtTheEnd:
        let model = threeSessions()
        model.selection = "a"
        model.selection = "b"
        return model
      case .cursorInTheMiddle:
        let model = threeSessions()
        model.selection = "a"
        model.selection = "b"
        model.selection = "c"
        model.goBack()
        return model
      case .removedBehind:
        // Back from c skips b and lands on a.
        let model = threeSessions()
        model.selection = "a"
        model.selection = "b"
        model.selection = "c"
        model.apply(.success(sessions(["a", "c"])), followups: nil)
        return model
      case .removedAhead:
        // Forward from a skips b and lands on c.
        let model = threeSessions()
        model.selection = "a"
        model.selection = "b"
        model.selection = "c"
        model.goBack()
        model.goBack()
        model.apply(.success(sessions(["a", "c"])), followups: nil)
        return model
      case .equalBehindAfterASession:
        // The Inbox entry for the removed item resolves to the first item, which shows now. Back skips it
        // and the launch entry and lands on the selected session.
        let model = threeSessions()
        let triage = model.triage.map(\.id)
        model.selection = triage[2]
        model.show(.inbox)
        model.inboxFocus = triage[1]
        model.inboxFocus = triage[0]
        model.apply(.success(sessions(triage.filter { $0 != triage[1] })), followups: nil)
        return model
      case .equalBehindWithNothingElse:
        let model = threeSessions()
        let triage = model.triage.map(\.id)
        model.inboxFocus = triage[1]
        model.inboxFocus = triage[0]
        model.apply(.success(sessions(triage.filter { $0 != triage[1] })), followups: nil)
        return model
      case .aXaWithXRemoved:
        // The Inbox's first item, then x, then the first item again, with x removed.
        let model = appliedModel(sessions(["a", "b"]) + [workingOutsideTheInbox("x")])
        model.inboxFocus = try #require(model.triage.first?.id)
        model.selection = "x"
        model.show(.inbox)
        model.apply(.success(sessions(["a", "b"])), followups: nil)
        return model
      case .filterHiddenBehind:
        let model = twoOrgs()
        model.selection = "ph1"
        model.selection = "hk"
        model.selection = "ph2"
        model.orgFilter = posthogOnly
        return model
      case .filterShowsItAgain:
        let model = twoOrgs()
        model.selection = "ph1"
        model.selection = "hk"
        model.selection = "ph2"
        model.orgFilter = posthogOnly
        model.orgFilter = OrgFilter()
        return model
      case .removedInboxItemBehind:
        // The Inbox entry stays available and resolves to the first item.
        let model = threeSessions()
        let triage = model.triage.map(\.id)
        model.inboxFocus = triage[1]
        model.selection = triage[2]
        model.apply(.success(sessions(triage.filter { $0 != triage[1] })), followups: nil)
        return model
      case .chatTerminalBehind:
        let model = appliedModel([needsItem("a"), chatItem("c", group: "g1")])
        model.selection = "c"
        model.showingTerminal = true
        return model
      case .managerTerminalBehind:
        let model = appliedModel([needsItem("a"), needsItem("m", manager: true)])
        model.selection = "m"
        model.showingTerminal = true
        return model
      case .removedManagerTerminalBehind:
        // Back from a skips both of the removed Manager's entries and lands on the launch entry.
        let model = appliedModel([needsItem("a"), needsItem("m", manager: true)])
        model.selection = "m"
        model.showingTerminal = true
        model.selection = "a"
        model.apply(.success([needsItem("a")]), followups: nil)
        return model
      case .unlistedSelection:
        let model = threeSessions()
        model.selectUnlisted("new")
        return model
      }
    }
  }

  @Test(arguments: HistoryShape.allCases)
  func canGoBackIsTrueExactlyWhenGoBackChangesTheLocation(_ shape: HistoryShape) throws {
    let model = try shape.build()
    let can = model.canGoBack
    let before = model.location

    model.goBack()

    #expect(can == shape.canGoBack)
    #expect(can == (model.location != before))
    #expect(model.history.current == model.location)
  }

  @Test(arguments: HistoryShape.allCases)
  func canGoForwardIsTrueExactlyWhenGoForwardChangesTheLocation(_ shape: HistoryShape) throws {
    let model = try shape.build()
    let can = model.canGoForward
    let before = model.location

    model.goForward()

    #expect(can == shape.canGoForward)
    #expect(can == (model.location != before))
    #expect(model.history.current == model.location)
  }

  @Test(arguments: HistoryShape.allCases)
  func recentPlacesHasARowExactlyWhenBackOrForwardHasSomewhereToGo(_ shape: HistoryShape) throws {
    let model = try shape.build()

    #expect(model.hasRecentPlaces == (shape.canGoBack || shape.canGoForward))
  }
}
