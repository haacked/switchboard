import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

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

  @Test func theManagerIsPinnedAndNotInAStateGroup() {
    for state in [AttentionState.working, .needsYou, .done] {
      let model = model([summary("m", manager: true, state: state), summary("a", parent: "m")])
      #expect(model.managers.map(\.id) == ["m"])
      let ids = model.sidebarGroups.flatMap { $0.rows.map(\.id) }
      #expect(!ids.contains("m"))
      #expect(ids == ["a"])
    }
  }

  @Test func managerConversationsArePinnedNewestActivityFirst() {
    var old = summary("m1", manager: true)
    old.lastActivity = 1
    var recent = summary("m2", manager: true)
    recent.lastActivity = 2
    let model = model([old, recent, summary("a")])
    #expect(model.managers.map(\.id) == ["m2", "m1"])
    #expect(model.sidebarOrder == ["m2", "m1", "a"])
  }

  @Test func theStarOpensTheMostRecentConversationEvenWhenAnotherNeedsYou() async {
    var waiting = summary("m1", manager: true, state: .needsYou)
    waiting.lastActivity = 1
    let sent = await firstRequest {
      $0.apply(.success([waiting, summary("m2", manager: true)]), followups: nil)
      $0.openManager()
    }
    #expect(sent.op == "manager")
    #expect(sent.args["session"] == nil)
  }

  @Test func withoutAManagerThereIsNoPinnedRow() {
    #expect(model([summary("a")]).managers.isEmpty)
  }

  @Test func aGrandchildOfTheManagerNestsUnderItsParent() {
    let model = model([summary("m", manager: true), summary("a", parent: "m"), summary("g", parent: "a")])
    #expect(shown(model) == ["working: a,>g"])
  }

  @Test func aManagerWithNoChildrenLeavesTheGroupsEmptyButNotTheSidebar() {
    let model = model([summary("m", manager: true)])
    #expect(model.sidebarGroups.isEmpty)
    #expect(!model.sidebarIsEmpty)
  }

  @Test func withNoSessionsTheSidebarIsEmpty() {
    #expect(model([]).sidebarIsEmpty)
  }

  @Test func ordinarySessionsWithoutAManagerFillTheSidebar() {
    #expect(!model([summary("a")]).sidebarIsEmpty)
  }

  @Test func anUnreachableServiceIsNotAnEmptySidebar() {
    struct Down: Error {}
    let model = model([])
    model.apply(.failure(Down()), followups: nil)
    #expect(!model.sidebarIsEmpty)
  }

  @Test func aChildInAnotherStateIsTopLevelInItsOwnGroup() {
    let model = model([summary("p"), summary("c", parent: "p", state: .needsYou)])
    #expect(shown(model) == ["needsYou: c", "working: p"])
  }

  @Test func aFollowupThatHasNotStartedShowsInItsGroup() {
    let model = model([summary("a")], followups: [summary("f", state: .notStarted)])
    #expect(shown(model) == ["working: a", "notStarted: f"])
  }

  @Test func readyForReviewGroupSitsBetweenClaudeCanContinueAndWaiting() {
    let model = model([
      summary("w", state: .waiting), summary("r", state: .readyForReview), summary("c", state: .canContinue),
    ])
    #expect(shown(model) == ["canContinue: c", "readyForReview: r", "waiting: w"])
  }

  @Test func theManagerStaysSelectedAcrossARefresh() {
    let sessions = [summary("m", manager: true, state: .needsYou)]
    let model = model(sessions)
    model.selection = "m"
    model.apply(.success(sessions), followups: nil)
    #expect(model.managers.map(\.id) == ["m"])
    #expect(model.selection == "m")
    #expect(model.selected?.id == "m")
  }
}
