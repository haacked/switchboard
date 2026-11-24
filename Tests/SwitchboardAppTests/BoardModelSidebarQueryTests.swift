import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A work session named `name`. `needsItem` names a session after its id, so these tests set the name apart from
/// the id. `SessionSearch` matches names, branches, and repo labels by subsequence, so each test picks names whose
/// letters a query for another session does not contain in order.
private func work(
  _ id: String, name: String, state: AttentionState = .working, parent: String? = nil, branch: String? = nil,
  repo: String? = nil, lastActivity: Int64 = 0
) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.name = name
  s.parent = parent
  s.branch = branch
  if let repo {
    s.repo = repo
    s.cwd = repo
  }
  s.lastActivity = lastActivity
  return s
}

@MainActor
@Suite struct BoardModelSidebarQuery {
  /// The sidebar as "state: id, >child" lines.
  func shown(_ model: BoardModel) -> [String] {
    model.sidebarGroups.map { group in
      "\(group.state): " + group.rows.map { String(repeating: ">", count: $0.depth) + $0.id }.joined(separator: ",")
    }
  }

  func model(_ sessions: [SessionSummary], query: String) -> BoardModel {
    let model = appliedModel(sessions)
    model.sidebarQuery = query
    return model
  }

  /// Three states, a parent with a child, and `lastActivity` values in an order other than the board's. A query
  /// with no terms makes `SessionSearch.rank` sort by `lastActivity`, so an implementation that took its rows in
  /// rank order would change this sidebar.
  var mixed: [SessionSummary] {
    [
      work("n1", name: "billing", state: .needsYou, lastActivity: 1),
      work("w1", name: "login", lastActivity: 2),
      work("w2", name: "queue-badge", parent: "w1", lastActivity: 5),
      work("w3", name: "widgets", lastActivity: 3),
      work("d1", name: "docs", state: .done, lastActivity: 4),
    ]
  }

  // MARK: Empty query

  @Test func theQueryStartsEmpty() {
    #expect(appliedModel(mixed).sidebarQuery == "")
  }

  @Test(arguments: ["", " ", "   ", "\t", " \n ", "\t \n"])
  func anEmptyOrWhitespaceQueryLeavesTheSidebarUnchanged(_ query: String) {
    let unfiltered = shown(appliedModel(mixed))

    let filtered = shown(model(mixed, query: query))

    #expect(filtered == unfiltered)
  }

  @Test(arguments: ["", "   ", "\t \n"])
  func anEmptyOrWhitespaceQueryDoesNotHideAll(_ query: String) {
    #expect(!model(mixed, query: query).sidebarQueryHidesAll)
  }

  // MARK: Matches

  @Test func aNameMatchKeepsOnlyThatSession() {
    let model = model(
      [work("a", name: "login"), work("b", name: "billing"), work("c", name: "queue-badge")], query: "login")

    #expect(shown(model) == ["working: a"])
  }

  @Test(arguments: ["LOGIN", "Login", "  login  ", "lógin"])
  func theQueryFoldsCaseDiacriticsAndOuterWhitespace(_ query: String) {
    let model = model([work("a", name: "login"), work("b", name: "billing")], query: query)

    #expect(shown(model) == ["working: a"])
  }

  @Test func aBranchMatchKeepsTheSession() {
    let model = model(
      [
        work("a", name: "alpha", branch: "haacked/398-sidebar-search"),
        work("b", name: "billing", branch: "haacked/fix-crash"),
      ], query: "sidebar")

    #expect(shown(model) == ["working: a"])
  }

  @Test func aRepoMatchKeepsTheSession() {
    let model = model(
      [
        work("a", name: "alpha", repo: "/Users/me/dev/acme/widgets"),
        work("b", name: "billing", repo: "/Users/me/dev/acme/queue"),
      ], query: "widgets")

    #expect(shown(model) == ["working: a"])
  }

  /// Every term must match, as in the search panel.
  @Test func everyTermOfTheQueryMustMatch() {
    let model = model(
      [
        work("a", name: "login", branch: "haacked/sidebar"),
        work("b", name: "login", branch: "haacked/crash"),
      ], query: "login sidebar")

    #expect(shown(model) == ["working: a"])
  }

  @Test func matchesInSeveralStatesKeepStateOrder() {
    let model = model(
      [
        work("w", name: "login-working"), work("x", name: "billing"),
        work("n", name: "login-needs", state: .needsYou), work("d", name: "login-done", state: .done),
      ], query: "login")

    #expect(shown(model) == ["needsYou: n", "working: w", "done: d"])
  }

  @Test func aStateWithNoMatchIsLeftOut() {
    let model = model(
      [work("n", name: "billing", state: .needsYou), work("w", name: "login")], query: "login")

    #expect(model.sidebarGroups.map(\.state) == [.working])
  }

  /// The sidebar filters its rows and keeps their order. It does not sort them by match score or by activity.
  @Test func matchedRowsKeepTheirBoardOrder() {
    let model = model(
      [
        work("a", name: "my-login-page", lastActivity: 1), work("b", name: "billing", lastActivity: 9),
        work("c", name: "login", lastActivity: 2),
      ], query: "login")

    #expect(shown(model) == ["working: a,c"])
  }

  /// The sidebar keeps exactly the work sessions that the search panel's ranking keeps, for each kind of query
  /// that the ranking reads.
  @Test(arguments: ["login", "LOGIN", "lgn", "sidebar", "widgets", "#12", "12", "login sidebar", "zzz"])
  func theSidebarKeepsTheSessionsThatSessionSearchMatches(_ query: String) {
    var withPR = work("p", name: "billing")
    withPR.pr = PRSummary(
      PullRequest(id: "PR_12", number: 12, url: "https://github.com/o/r/pull/12", repo: "o/r", title: ""))
    let sessions = [
      work("a", name: "login", branch: "haacked/sidebar"),
      work("b", name: "queue-badge", repo: "/Users/me/dev/acme/widgets"),
      withPR,
      work("c", name: "docs", state: .done),
    ]
    let model = model(sessions, query: query)

    let kept = Set(model.sidebarGroups.flatMap { $0.rows.map(\.id) })

    #expect(kept == Set(SessionSearch.rank(model.workBoard, query: query).map(\.id)))
  }

  // MARK: No match

  @Test func aQueryThatMatchesNothingLeavesNoGroups() {
    let model = model(mixed, query: "zzz")

    #expect(model.sidebarGroups.isEmpty)
  }

  @Test func aQueryThatMatchesNothingHidesAll() {
    #expect(model(mixed, query: "zzz").sidebarQueryHidesAll)
  }

  /// The sidebar shows its "No sessions match" row, not the empty sidebar.
  @Test func aQueryThatMatchesNothingDoesNotMakeTheSidebarEmpty() {
    #expect(!model(mixed, query: "zzz").sidebarIsEmpty)
  }

  @Test func aQueryThatMatchesSomethingDoesNotHideAll() {
    #expect(!model(mixed, query: "login").sidebarQueryHidesAll)
  }

  @Test func withNoSessionsAQueryDoesNotHideAll() {
    #expect(!model([], query: "zzz").sidebarQueryHidesAll)
  }

  @Test func withNoSessionsAQueryLeavesTheSidebarEmpty() {
    #expect(model([], query: "zzz").sidebarIsEmpty)
  }

  @Test func withOnlyAManagerAQueryDoesNotHideAll() {
    #expect(!model([needsItem("m", manager: true, state: .working)], query: "zzz").sidebarQueryHidesAll)
  }

  /// The org filter hides every work session, so the sidebar shows the filter's message and the query hides
  /// nothing more.
  @Test func whenTheFilterHidesAllWorkAQueryDoesNotHideAll() throws {
    let model = orgFilterModel(OrgFilter(keys: ["acme"]))
    model.apply(.success([orgSession("a", "haacked/a"), orgSession("b", "haacked/b")]), followups: nil)
    try #require(model.filterHidesAllWork)

    model.sidebarQuery = "zzz"

    #expect(!model.sidebarQueryHidesAll)
  }

  /// A group chat is not a work session, so a query that matches only the chat still hides every work row.
  @Test func aQueryThatMatchesOnlyAGroupChatHidesAll() {
    var chat = chatItem("chat", group: "g1")
    chat.name = "login"
    let model = model([chat, work("a", name: "billing")], query: "login")

    #expect(model.sidebarQueryHidesAll)
  }

  // MARK: Parents and children

  @Test func aMatchingChildOfAHiddenParentIsTopLevel() {
    let model = model([work("p", name: "billing"), work("c", name: "login", parent: "p")], query: "login")

    #expect(shown(model) == ["working: c"])
  }

  @Test func aMatchingChildOfAMatchingParentStaysNested() {
    let model = model(
      [work("p", name: "login"), work("c", name: "login-tests", parent: "p"), work("x", name: "billing")],
      query: "login")

    #expect(shown(model) == ["working: p,>c"])
  }

  @Test func aHiddenChildOfAMatchingParentIsLeftOut() {
    let model = model([work("p", name: "login"), work("c", name: "billing", parent: "p")], query: "login")

    #expect(shown(model) == ["working: p"])
  }

  /// The grandchild's own parent is hidden, so it moves to the top level beside its grandparent.
  @Test func aMatchingGrandchildOfAHiddenParentIsTopLevel() {
    let model = model(
      [
        work("g", name: "login"), work("p", name: "billing", parent: "g"),
        work("c", name: "login-tests", parent: "p"),
      ], query: "login")

    #expect(shown(model) == ["working: g,c"])
  }

  @Test func aMatchingChildInAnotherStateShowsOnlyInItsOwnGroup() {
    let model = model(
      [work("p", name: "billing"), work("c", name: "login", state: .needsYou, parent: "p")], query: "login")

    #expect(shown(model) == ["needsYou: c"])
  }

  // MARK: Other views

  @Test func theQueryLeavesTheBoardUnchanged() {
    let before = appliedModel(mixed).board.map(\.id)

    let after = model(mixed, query: "login").board.map(\.id)

    #expect(after == before)
  }

  @Test func theQueryLeavesTheWorkBoardUnchanged() {
    let before = appliedModel(mixed).workBoard.map(\.id)

    let after = model(mixed, query: "login").workBoard.map(\.id)

    #expect(after == before)
  }

  @Test func theQueryLeavesTheInboxUnchanged() throws {
    let before = appliedModel(mixed).triage.map(\.id)
    try #require(before.count > 1)

    let after = model(mixed, query: "login").triage.map(\.id)

    #expect(after == before)
  }

  @Test func aQueryThatHidesAllLeavesTheInboxUnchanged() {
    let before = appliedModel(mixed).triage.map(\.id)

    let after = model(mixed, query: "zzz").triage.map(\.id)

    #expect(after == before)
  }

  // MARK: Keyboard navigation

  /// Three working sessions in board order. A query for `login` hides the middle one.
  var navigable: [SessionSummary] {
    [work("a", name: "login-one"), work("b", name: "billing"), work("c", name: "login-two")]
  }

  @Test func sidebarOrderLeavesOutHiddenRows() {
    let model = model(navigable, query: "login")

    #expect(model.sidebarOrder == ["a", "c"])
  }

  @Test func nextSkipsAHiddenRow() {
    let model = model(navigable, query: "login")
    model.selection = "a"

    model.selectAdjacentSession(by: 1)

    #expect(model.selection == "c")
  }

  @Test func previousSkipsAHiddenRow() {
    let model = model(navigable, query: "login")
    model.selection = "c"

    model.selectAdjacentSession(by: -1)

    #expect(model.selection == "a")
  }

  @Test func nextFromTheLastShownRowWrapsToTheFirstShownRow() {
    let model = model(
      [work("x", name: "billing"), work("a", name: "login-one"), work("c", name: "login-two")], query: "login")
    model.selection = "c"

    model.selectAdjacentSession(by: 1)

    #expect(model.selection == "a")
  }

  @Test func clearingTheQueryBringsBackTheHiddenRow() {
    let model = model(navigable, query: "login")
    model.sidebarQuery = ""
    model.selection = "a"

    model.selectAdjacentSession(by: 1)

    #expect(model.selection == "b")
  }

  // MARK: Multi-selection

  @Test func theMultiSelectionKeepsTheSessionsTheQueryHides() {
    let model = model(navigable, query: "login")
    model.multiSelection = ["a", "b", "c"]

    #expect(model.multiSelected.map(\.id) == ["a", "b", "c"])
    #expect(model.removableSelectionCount == 3)
  }

  @Test func aQueryThatHidesEverySelectedSessionKeepsTheMultiSelection() {
    let model = model(navigable, query: "zzz")
    model.multiSelection = ["a", "b"]

    #expect(model.multiSelected.map(\.id) == ["a", "b"])
    #expect(model.removableSelectionCount == 2)
  }

  // MARK: Showing a session

  @Test func openingASessionTheQueryHidesClearsTheQuery() {
    let model = model(navigable, query: "login")

    model.openFromSearch("b")

    #expect(model.sidebarQuery == "")
    #expect(model.selection == "b")
    #expect(model.sidebarOrder.contains("b"))
  }

  @Test func openingASessionTheQueryShowsKeepsTheQuery() {
    let model = model(navigable, query: "login")

    model.openFromSearch("c")

    #expect(model.sidebarQuery == "login")
    #expect(model.selection == "c")
  }

  /// The org filter and the query both hide the session. Revealing it widens the filter, and the query clears.
  @Test func revealingASessionThatTheFilterAndTheQueryHideClearsTheQuery() {
    let model = orgFilterModel(OrgFilter(keys: ["acme"]))
    var login = orgSession("a", "acme/a")
    login.name = "login"
    var billing = orgSession("b", "other/b")
    billing.name = "billing"
    model.apply(.success([login, billing]), followups: nil)
    model.sidebarQuery = "login"

    model.reveal("b")

    #expect(model.selection == "b")
    #expect(model.sidebarQuery == "")
    #expect(model.sidebarOrder.contains("b"))
  }
}
