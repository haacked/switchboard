import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A work session in `repository`, whose folder is shared by every session of that repository, placed in
/// `column` when it is not nil.
private func laid(
  _ id: String, _ column: BoardColumn?, repository: String = "PostHog/posthog", since: Int64 = 0,
  state: AttentionState = .waiting, group: String? = nil
) -> SessionSummary {
  var s = orgSession(id, repository, state: state, group: group)
  s.repo = "/r/\(repository)"
  s.board = column.map { BoardPlacement(column: $0, since: since) }
  return s
}

private func laneGroup(_ id: String, _ sessions: [String]) -> GroupSummary {
  GroupSummary(SessionGroup(id: id, name: id, created: 0), sessions: sessions)
}

private func ids(_ cells: [[SessionSummary]]) -> [[String]] { cells.map { $0.map(\.id) } }

/// One card in each column of one repo, plus a Done session and a session whose PR merged.
private let oneOfEach = [
  laid("prog", .inProgress, state: .working), laid("wait", .waiting), laid("rev", .inReview),
  laid("appr", .approved), laid("merg", .merging), laid("fin", nil, state: .done), laid("merged", .done),
]

/// Lanes, a filter, and the open cards that the filter shows.
private let gridShapes: [(String, BoardLanes, OrgFilter, Set<String>)] = [
  ("repo lanes", .repo, OrgFilter(), ["ph1", "ph2", "ph3", "hk1", "hk2"]),
  ("group lanes", .group, OrgFilter(), ["ph1", "ph2", "ph3", "hk1", "hk2"]),
  ("repo lanes, one org", .repo, posthogOnly, ["ph1", "ph2", "ph3"]),
  ("group lanes, one org", .group, posthogOnly, ["ph1", "ph2", "ph3"]),
]

@MainActor
@Suite struct BoardModelLayoutTests {
  // MARK: Columns

  @Test func theColumnsAreInProgressWaitingInReviewApprovedAndMerging() {
    let layout = appliedModel(oneOfEach).boardLayout(lanes: .repo)

    #expect(layout.columns == [.inProgress, .waiting, .inReview, .approved, .merging])
    #expect(layout.columns.map(\.title) == ["In progress", "Waiting", "In review", "Approved", "Merging"])
  }

  @Test(arguments: [BoardLanes.repo, .group])
  func doneIsNotAColumn(_ lanes: BoardLanes) {
    #expect(!appliedModel(oneOfEach).boardLayout(lanes: lanes).columns.contains(.done))
  }

  @Test func eachCardSitsInTheCellOfItsColumn() throws {
    let layout = appliedModel(oneOfEach).boardLayout(lanes: .repo)

    let lane = try #require(layout.lanes.first)
    #expect(layout.lanes.count == 1)
    #expect(ids(lane.cells) == [["prog"], ["wait"], ["rev"], ["appr"], ["merg"]])
  }

  @Test func everyLaneHasACellForEachColumnEvenWhenEmpty() {
    let layout = appliedModel([
      laid("a", .waiting, repository: "PostHog/posthog"), laid("b", .merging, repository: "haacked/switchboard"),
    ]).boardLayout(lanes: .repo)

    #expect(layout.lanes.count == 2)
    #expect(layout.lanes.allSatisfy { $0.cells.count == layout.columns.count })
  }

  /// `MergeBoard.column` puts a session without a placement, such as one that hasn't started, in In progress.
  @Test func aSessionWithoutAPlacementIsInProgress() throws {
    let layout = appliedModel([laid("new", nil, state: .notStarted)]).boardLayout(lanes: .repo)

    let lane = try #require(layout.lanes.first)
    #expect(ids(lane.cells) == [["new"], [], [], [], []])
  }

  @Test func aCellListsTheLongestInTheColumnFirst() throws {
    let layout = appliedModel([
      laid("newer", .inReview, since: 300), laid("oldest", .inReview, since: 100),
      laid("middle", .inReview, since: 200),
    ]).boardLayout(lanes: .repo)

    let lane = try #require(layout.lanes.first)
    #expect(lane.cells[2].map(\.id) == ["oldest", "middle", "newer"])
  }

  // MARK: The Done footer

  @Test(arguments: [BoardLanes.repo, .group])
  func doneAndMergedSessionsGoToTheFooter(_ lanes: BoardLanes) {
    let layout = appliedModel(oneOfEach).boardLayout(lanes: lanes)

    #expect(Set(layout.done.map(\.id)) == ["fin", "merged"])
  }

  @Test(arguments: [BoardLanes.repo, .group])
  func doneAndMergedSessionsAreInNoLaneAndNotInTheGrid(_ lanes: BoardLanes) {
    let layout = appliedModel(oneOfEach).boardLayout(lanes: lanes)

    let drawn = Set(layout.lanes.flatMap { $0.cells.flatMap { $0.map(\.id) } })
    #expect(drawn == ["prog", "wait", "rev", "appr", "merg"])
    #expect(!layout.grid.contains("fin"))
    #expect(!layout.grid.contains("merged"))
  }

  /// A Done session whose PR's last placement was a PR column still goes to the footer.
  @Test func aDoneSessionWithAnOpenColumnPlacementGoesToTheFooter() {
    let layout = appliedModel([laid("a", .inReview, state: .done), laid("b", .waiting)]).boardLayout(lanes: .repo)

    #expect(layout.done.map(\.id) == ["a"])
    #expect(layout.grid.readingOrder == ["b"])
  }

  // MARK: Repo lanes

  @Test func repoLanesPutEachRepositoryInItsOwnLane() {
    let layout = appliedModel([
      laid("ph1", .waiting, repository: "PostHog/posthog"), laid("hk", .inReview, repository: "haacked/switchboard"),
      laid("ph2", .merging, repository: "PostHog/posthog"),
    ]).boardLayout(lanes: .repo)

    let lanes = layout.lanes.map { Set($0.cells.flatMap { $0.map(\.id) }) }
    #expect(lanes.count == 2)
    #expect(Set(lanes) == [["ph1", "ph2"], ["hk"]])
  }

  @Test func repoLanesAreOrderedByTitle() {
    let layout = appliedModel([
      laid("ph", .waiting, repository: "PostHog/posthog"), laid("hk", .waiting, repository: "haacked/switchboard"),
    ]).boardLayout(lanes: .repo)

    let titles = layout.lanes.map(\.title)
    #expect(titles.count == 2)
    #expect(titles == titles.sorted())
  }

  @Test func repoLanesHaveNoGroup() {
    let model = appliedModel([laid("a", .waiting, group: "g1")])
    model.groups = [laneGroup("g1", ["a"])]

    let lanes = model.boardLayout(lanes: .repo).lanes

    #expect(!lanes.isEmpty)
    #expect(lanes.allSatisfy { $0.group == nil })
  }

  // MARK: Group lanes

  @Test func groupLanesFollowTheGroupsOrderWithUngroupedLast() {
    let model = appliedModel([
      laid("a", .waiting, group: "g2"), laid("b", .inReview, group: "g1"), laid("u", .approved),
    ])
    model.groups = [laneGroup("g2", ["a"]), laneGroup("g1", ["b"])]

    let layout = model.boardLayout(lanes: .group)

    #expect(layout.lanes.map(\.title) == ["g2", "g1", BoardRows.ungroupedTitle])
    #expect(layout.lanes.map { $0.group?.id } == ["g2", "g1", nil])
  }

  @Test func aGroupLanesCardsSitInTheirColumns() throws {
    let model = appliedModel([laid("a", .waiting, group: "g1"), laid("b", .merging, group: "g1")])
    model.groups = [laneGroup("g1", ["a", "b"])]

    let lane = try #require(model.boardLayout(lanes: .group).lanes.first)

    #expect(ids(lane.cells) == [[], ["a"], [], [], ["b"]])
  }

  /// An empty group keeps its lane, so the user can drag a card into it.
  @Test func anEmptyGroupKeepsItsLane() {
    let model = appliedModel([laid("u", .waiting)])
    model.groups = [laneGroup("empty", [])]

    let layout = model.boardLayout(lanes: .group)

    #expect(layout.lanes.map(\.title) == ["empty", BoardRows.ungroupedTitle])
  }

  // MARK: Sessions that get no card

  @Test(arguments: [BoardLanes.repo, .group])
  func theManagerAndGroupChatsGetNoCard(_ lanes: BoardLanes) {
    var manager = needsItem("m", manager: true, state: .working)
    manager.board = BoardPlacement(column: .inProgress, since: 0)
    let model = appliedModel([manager, chatItem("chat", group: "g1"), laid("a", .waiting)])
    model.groups = [laneGroup("g1", [])]

    let layout = model.boardLayout(lanes: lanes)

    #expect(layout.grid.readingOrder == ["a"])
    #expect(!layout.done.contains { $0.id == "m" || $0.id == "chat" })
  }

  // MARK: The org filter

  @Test(arguments: [BoardLanes.repo, .group])
  func theOrgFilterHidesASessionFromTheLanesTheFooterAndTheGrid(_ lanes: BoardLanes) {
    let model = orgFilterModel(posthogOnly)
    model.apply(
      .success([
        laid("ph", .waiting, repository: "PostHog/posthog"), laid("hk", .waiting, repository: "haacked/switchboard"),
        laid("hkDone", nil, repository: "haacked/switchboard", state: .done),
      ]), followups: nil)

    let layout = model.boardLayout(lanes: lanes)

    #expect(layout.grid.readingOrder == ["ph"])
    #expect(layout.done.isEmpty)
  }

  // MARK: The keyboard grid

  /// The arrow keys move over `grid`, and BoardView draws `cells`. Both come from the layout, so the keys
  /// reach exactly the drawn cards, in the drawn places.
  @Test(arguments: gridShapes)
  func theGridIsTheDrawnCardsIds(_ name: String, _ lanes: BoardLanes, _ filter: OrgFilter, _ shown: Set<String>) {
    let model = orgFilterModel(filter)
    model.apply(
      .success([
        laid("ph1", .inProgress, repository: "PostHog/posthog", state: .working, group: "g1"),
        laid("ph2", .inReview, repository: "PostHog/posthog", since: 5, group: "g1"),
        laid("ph3", .inReview, repository: "PostHog/posthog", since: 1),
        laid("hk1", .approved, repository: "haacked/switchboard", group: "g2"),
        laid("hk2", .merging, repository: "haacked/switchboard"),
        laid("done", nil, repository: "PostHog/posthog", state: .done, group: "g1"),
      ]), followups: nil)
    model.groups = [laneGroup("g1", ["ph1", "ph2", "done"]), laneGroup("g2", ["hk1"])]

    let layout = model.boardLayout(lanes: lanes)

    #expect(layout.grid == BoardGrid(lanes: layout.lanes.map { ids($0.cells) }), "\(name)")
    #expect(Set(layout.grid.readingOrder) == shown, "\(name)")
  }

  @Test func theGridReadsLaneByLaneInColumnOrder() {
    let layout = appliedModel(oneOfEach.reversed()).boardLayout(lanes: .repo)

    #expect(layout.grid.readingOrder == ["prog", "wait", "rev", "appr", "merg"])
  }

  @Test func rightMovesFromInProgressToWaitingInTheSameLane() {
    let layout = appliedModel(oneOfEach).boardLayout(lanes: .repo)

    #expect(layout.grid.move(from: "prog", .right) == "wait")
    #expect(layout.grid.move(from: "appr", .right) == "merg")
    #expect(layout.grid.move(from: "merg", .right) == "merg")
  }
}
