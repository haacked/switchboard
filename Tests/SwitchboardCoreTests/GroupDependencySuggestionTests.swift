import Testing

@testable import SwitchboardCore

private let posthog = "PostHog/posthog"

@Suite struct GroupDependencySuggestionTests {
  typealias Candidate = GroupSuggestions.Candidate

  /// A session whose own PR is `posthog#pr`, or in `repo` when given.
  func session(
    _ id: String, group: String? = nil, byHand: Bool = false, pr: Int? = nil, repo: String = posthog,
    edges: [Dependency] = [], branch: String? = nil
  ) -> Candidate {
    Candidate(
      id: id, branch: branch, prTitle: nil, group: group, placedByHand: byHand, repo: pr == nil ? nil : repo, pr: pr,
      dependencies: edges)
  }

  /// An edge to PR `number`, which `session` works on.
  func edge(to session: String?, _ number: Int, repo: String = posthog, via: Dependency.Via = .stack) -> Dependency {
    Dependency(via: via, repo: repo, number: number, state: .open, session: session)
  }

  func group(_ id: String, _ name: String, created: Int64 = 0) -> SessionGroup {
    SessionGroup(id: id, name: name, notes: [], created: created)
  }

  func suggest(_ candidates: [Candidate], groups: [SessionGroup] = [], declined: Set<String> = [])
    -> [GroupSuggestion]
  {
    GroupSuggestions.make(candidates: candidates, groups: groups, declined: declined)
  }

  /// Flags is older than Cache.
  var flagsAndCache: [SessionGroup] { [group("g1", "Flags", created: 1), group("g2", "Cache", created: 2)] }

  func merges(_ found: [GroupSuggestion]) -> [GroupSuggestion] { found.filter { $0.merge != nil } }

  // MARK: Merge across groups

  @Test func anEdgeBetweenTwoGroupsSuggestsMergingThem() throws {
    let found = suggest(
      [
        session("a", group: "g1", pr: 122896, edges: [edge(to: "b", 122953)]),
        session("b", group: "g2", pr: 122953),
      ],
      groups: flagsAndCache)

    let merge = try #require(found.first)
    #expect(
      merge
        == GroupSuggestion(
          id: "merge:g1:g2", name: "Flags", group: "g1", sessions: ["b"], reason: "#122896 depends on #122953",
          merge: GroupSuggestion.Merge(group: "g2", name: "Cache"), stays: nil))
    #expect(merge.action == "merge Cache into Flags")
    #expect(merge.staying() == nil)
  }

  @Test func anEdgeInsideOneGroupSuggestsNothing() {
    let found = suggest(
      [session("a", group: "g1", pr: 1, edges: [edge(to: "b", 2)]), session("b", group: "g1", pr: 2)],
      groups: [group("g1", "Flags")])

    #expect(found.isEmpty)
  }

  @Test func anEdgeToAPRInAnotherRepoNamesItsRepoInTheReason() throws {
    let found = suggest(
      [
        session("a", group: "g1", pr: 1, edges: [edge(to: "b", 18303, repo: "PostHog/charts", via: .body)]),
        session("b", group: "g2", pr: 18303, repo: "PostHog/charts"),
      ],
      groups: [group("g1", "Flags", created: 1), group("g2", "Charts", created: 2)])

    #expect(try #require(found.first).reason == "#1 depends on PostHog/charts#18303")
  }

  // MARK: Which group survives

  @Test func theGroupWithMoreSessionsPlacedByHandSurvives() throws {
    // g1 is older and larger, but g2 holds a session placed by hand.
    let found = suggest(
      [
        session("a1", group: "g1", pr: 1, edges: [edge(to: "b", 3)]), session("a2", group: "g1"),
        session("a3", group: "g1"), session("b", group: "g2", pr: 3), session("h", group: "g2", byHand: true),
      ],
      groups: flagsAndCache)

    let merge = try #require(merges(found).first)
    #expect(merge.group == "g2")
    #expect(merge.name == "Cache")
    #expect(merge.sessions == ["a1", "a2", "a3"])
    #expect(merge.merge == GroupSuggestion.Merge(group: "g1", name: "Flags"))
  }

  @Test func atTheSameHandPlacedCountTheGroupWithMoreSessionsSurvives() throws {
    // Each group has one session placed by hand. gb is newer and has the larger id.
    let found = suggest(
      [
        session("a", group: "ga", pr: 1, edges: [edge(to: "b", 2)]), session("ha", group: "ga", byHand: true),
        session("b", group: "gb", pr: 2), session("b2", group: "gb"), session("hb", group: "gb", byHand: true),
      ],
      groups: [group("ga", "Flags", created: 1), group("gb", "Cache", created: 2)])

    let merge = try #require(merges(found).first)
    #expect(merge.group == "gb")
    #expect(merge.sessions == ["a"])
    #expect(merge.stays == ["ha"])
  }

  @Test func atTheSameHandPlacedCountAndSizeTheOlderGroupSurvives() throws {
    let found = suggest(
      [session("a", group: "ga", pr: 1, edges: [edge(to: "b", 2)]), session("b", group: "gb", pr: 2)],
      groups: [group("ga", "Flags", created: 2), group("gb", "Cache", created: 1)])

    let merge = try #require(merges(found).first)
    #expect(merge.group == "gb")
    #expect(merge.sessions == ["a"])
  }

  @Test func whenEverythingTiesTheSmallerIdSurvives() throws {
    let found = suggest(
      [session("a", group: "gb", pr: 1, edges: [edge(to: "b", 2)]), session("b", group: "ga", pr: 2)],
      groups: [group("gb", "Flags", created: 1), group("ga", "Cache", created: 1)])

    let merge = try #require(merges(found).first)
    #expect(merge.group == "ga")
    #expect(merge.name == "Cache")
    #expect(merge.sessions == ["a"])
  }

  /// Applies an accepted suggestion as sbd does: its sessions move to its group, placed by hand.
  func accept(_ suggestion: GroupSuggestion, _ candidates: [Candidate]) -> [Candidate] {
    candidates.map { c in
      guard suggestion.sessions.contains(c.id) else { return c }
      var moved = c
      moved.group = suggestion.group
      moved.placedByHand = true
      return moved
    }
  }

  @Test func afterAnAcceptedMergeThePairGetsNoSuggestion() throws {
    // Both groups hold a session that can move. The edge ends at h, which stays in g2.
    let groups = flagsAndCache
    let before = [
      session("a", group: "g1", byHand: true, pr: 1, edges: [edge(to: "h", 2)]), session("a2", group: "g1"),
      session("h", group: "g2", byHand: true, pr: 2), session("b", group: "g2"),
    ]
    let merge = try #require(merges(suggest(before, groups: groups)).first)
    #expect(merge.sessions == ["b"])

    let found = suggest(accept(merge, before), groups: groups)

    #expect(found.isEmpty)
  }

  // MARK: The merge id

  enum Direction: CaseIterable { case fromFirst, fromSecond }

  /// `gz` sorts after `ga`, so a pair id built in candidate order would differ.
  @Test(arguments: Direction.allCases, [false, true])
  func theMergeIdNamesTheGroupsInSortedOrderWhateverTheDirectionAndSurvivor(
    _ direction: Direction, _ gzSurvives: Bool
  ) throws {
    let zEdges = direction == .fromFirst ? [edge(to: "a", 2)] : []
    let aEdges = direction == .fromSecond ? [edge(to: "z", 1)] : []
    let candidates = [
      session("z", group: "gz", pr: 1, edges: zEdges), session("a", group: "ga", pr: 2, edges: aEdges),
      // The group with more sessions placed by hand survives.
      session("hand", group: gzSurvives ? "gz" : "ga", byHand: true),
    ]

    let found = suggest(candidates, groups: [group("gz", "Zulu", created: 1), group("ga", "Alpha", created: 2)])

    let merge = try #require(merges(found).first)
    #expect(merge.id == "merge:ga:gz")
    #expect(merge.group == (gzSurvives ? "gz" : "ga"))
  }

  // MARK: Reasons

  @Test func everyEdgeBetweenTheGroupsIsInTheReasonByDependentIdThenEdgeOrder() throws {
    let found = suggest(
      [
        session("b2", group: "g2", pr: 4, edges: [edge(to: "a", 1)]),
        session("a2", group: "g1", pr: 3, edges: [edge(to: "b", 2)]),
        session("a", group: "g1", pr: 1, edges: [edge(to: "b2", 4), edge(to: "b", 2, via: .body)]),
        session("b", group: "g2", pr: 2),
      ],
      groups: flagsAndCache)

    let all = merges(found)
    #expect(all.count == 1)
    #expect(
      try #require(all.first).reason
        == "#1 depends on #4, #1 depends on #2, #3 depends on #2, #4 depends on #1")
  }

  // MARK: Sessions placed by hand

  @Test func handPlacedSessionsOfTheAbsorbedGroupStaySortedAndDoNotMove() throws {
    // g1 has three sessions placed by hand and g2 has two, so g1 survives.
    let found = suggest(
      [
        session("a", group: "g1", byHand: true, pr: 1, edges: [edge(to: "b2", 3)]),
        session("x1", group: "g1", byHand: true), session("x2", group: "g1", byHand: true),
        session("b2", group: "g2", pr: 3),
        session("b1", group: "g2"), session("h1", group: "g2", byHand: true),
        session("h0", group: "g2", byHand: true),
      ],
      groups: flagsAndCache)

    let merge = try #require(merges(found).first)
    #expect(merge.group == "g1")
    #expect(merge.sessions == ["b1", "b2"])
    #expect(merge.stays == ["h0", "h1"])
  }

  @Test func anEdgeFromAHandPlacedSessionStillLinksItsGroup() throws {
    let found = suggest(
      [
        session("h", group: "g1", byHand: true, pr: 1, edges: [edge(to: "b", 2)]),
        session("b", group: "g2", pr: 2),
      ],
      groups: flagsAndCache)

    let merge = try #require(merges(found).first)
    #expect(merge.group == "g1")
    #expect(merge.sessions == ["b"])
    #expect(merge.stays == nil)
  }

  @Test func noMergeIsSuggestedWhenEverySessionWasPlacedByHand() {
    let found = suggest(
      [
        session("a", group: "g1", byHand: true, pr: 1, edges: [edge(to: "b", 2)]),
        session("b", group: "g2", byHand: true, pr: 2),
      ],
      groups: flagsAndCache)

    #expect(found.isEmpty)
  }

  // MARK: Joins from an edge

  @Test(arguments: [true, false])
  func anEdgeBetweenAnUngroupedSessionAndAGroupSuggestsJoiningIt(_ ungroupedDepends: Bool) throws {
    let found = suggest(
      [
        session("u", pr: 1, edges: ungroupedDepends ? [edge(to: "m", 2)] : []),
        session("m", group: "g1", pr: 2, edges: ungroupedDepends ? [] : [edge(to: "u", 1)]),
      ],
      groups: [group("g1", "Flags")])

    let join = try #require(found.first)
    #expect(join.id == "dependency:u:g1")
    #expect(join.name == "Flags")
    #expect(join.group == "g1")
    #expect(join.sessions == ["u"])
    #expect(join.merge == nil)
    #expect(join.reason == (ungroupedDepends ? "#1 depends on #2" : "#2 depends on #1"))
    #expect(join.action == "join Flags")
  }

  @Test func aJoinFollowsAnEdgeToASessionPlacedInItsGroupByHand() throws {
    let found = suggest(
      [session("u", pr: 1, edges: [edge(to: "m", 2)]), session("m", group: "g1", byHand: true, pr: 2)],
      groups: [group("g1", "Flags")])

    #expect(try #require(found.first).id == "dependency:u:g1")
  }

  @Test func aJoinToAGroupThatAMergeEmptiesGoesToTheKeptGroupAndKeepsTheMerge() throws {
    // Flags survives on a, placed by hand. The merge empties Cache, which u depends on.
    let before = [
      session("a", group: "g1", byHand: true, pr: 1, edges: [edge(to: "b", 2)]), session("b", group: "g2", pr: 2),
      session("u", pr: 3, edges: [edge(to: "b", 2)]),
    ]
    let found = suggest(before, groups: flagsAndCache)
    let join = try #require(found.first { $0.sessions == ["u"] })
    #expect(join.id == "dependency:u:g1")
    #expect(join.reason == "#3 depends on #2")

    let after = suggest(accept(join, before), groups: flagsAndCache)

    #expect(after.map(\.id) == ["merge:g1:g2"])
  }

  @Test func aJoinToASessionThatAMergeMovesGoesToTheKeptGroupWhenSomeoneStays() throws {
    // Cache keeps h, placed by hand. A join of u to Cache would tie the
    // hand-placed counts and make Cache the larger group, so Cache would
    // survive and the merge would have nothing left to move.
    let before = [
      session("a", group: "g1", byHand: true, pr: 1, edges: [edge(to: "b", 2)]),
      session("a2", group: "g1", byHand: true),
      session("b", group: "g2", pr: 2), session("h", group: "g2", byHand: true),
      session("u", pr: 3, edges: [edge(to: "b", 2)]),
    ]
    let found = suggest(before, groups: flagsAndCache)
    #expect(try #require(merges(found).first).stays == ["h"])
    let join = try #require(found.first { $0.sessions == ["u"] })
    #expect(join.id == "dependency:u:g1")

    let after = suggest(accept(join, before), groups: flagsAndCache)

    #expect(after.map(\.id) == ["merge:g1:g2"])
  }

  @Test func aJoinToASessionThatStaysAlsoGoesToTheKeptGroup() throws {
    // u depends on h, which stays in Cache. A join of u to Cache would still
    // make Cache the survivor and leave the merge nothing to move.
    let before = [
      session("a", group: "g1", byHand: true, pr: 1, edges: [edge(to: "b", 2)]),
      session("a2", group: "g1", byHand: true),
      session("b", group: "g2", pr: 2), session("h", group: "g2", byHand: true, pr: 4),
      session("u", pr: 3, edges: [edge(to: "h", 4)]),
    ]
    let join = try #require(suggest(before, groups: flagsAndCache).first { $0.sessions == ["u"] })
    #expect(join.id == "dependency:u:g1")

    let after = suggest(accept(join, before), groups: flagsAndCache)

    #expect(after.map(\.id) == ["merge:g1:g2"])
  }

  @Test func aKeyJoinToAMergedGroupGoesToTheKeptGroup() throws {
    let before = [
      session("a", group: "g1", byHand: true, pr: 1, edges: [edge(to: "b", 2)]),
      session("a2", group: "g1", byHand: true),
      session("b", group: "g2", pr: 2, branch: "haacked/flag-evaluations-cache"),
      session("h", group: "g2", byHand: true),
      session("u", branch: "haacked/flag-evaluations-perf"),
    ]
    let join = try #require(suggest(before, groups: flagsAndCache).first { $0.sessions == ["u"] })
    #expect(join.group == "g1")
    #expect(join.name == "Flags")

    let after = suggest(accept(join, before), groups: flagsAndCache)

    #expect(after.map(\.id) == ["merge:g1:g2"])
  }

  @Test func keptGroupsFollowAChainOfMerges() {
    func merge(_ keep: String, _ merged: String) -> GroupSuggestion {
      GroupSuggestion(
        id: "m", name: keep, group: keep, sessions: ["s"], reason: "", merge: .init(group: merged, name: merged))
    }

    let kept = GroupSuggestions.keptGroups([merge("g1", "g2"), merge("g3", "g1")])

    #expect(kept == ["g2": "g3", "g1": "g3"])
  }

  @Test func aJoinPicksTheGroupWithTheMostEdges() throws {
    let found = suggest(
      [
        session("u", pr: 1, edges: [edge(to: "m1", 2), edge(to: "m2", 3), edge(to: "m3", 4)]),
        session("m1", group: "ga", pr: 2), session("m2", group: "gb", pr: 3), session("m3", group: "gb", pr: 4),
      ],
      groups: [group("ga", "Alpha"), group("gb", "Bravo")])

    let join = try #require(found.first { $0.sessions == ["u"] })
    #expect(join.id == "dependency:u:gb")
    #expect(join.reason == "#1 depends on #3, #1 depends on #4")
  }

  @Test func atTheSameEdgeCountAJoinPicksTheGroupWhoseNameSortsFirst() throws {
    let found = suggest(
      [
        session("u", pr: 1, edges: [edge(to: "m1", 2), edge(to: "m2", 3)]),
        session("m1", group: "ga", pr: 2), session("m2", group: "gb", pr: 3),
      ],
      groups: [group("ga", "Zulu"), group("gb", "Alpha")])

    #expect(try #require(found.first { $0.sessions == ["u"] }).id == "dependency:u:gb")
  }

  @Test func anUngroupedSessionGetsOneJoinFromItsEdges() {
    let found = suggest(
      [
        session("u", pr: 1, edges: [edge(to: "m1", 2), edge(to: "m2", 3)]),
        session("m1", group: "ga", pr: 2), session("m2", group: "gb", pr: 3),
      ],
      groups: [group("ga", "Alpha"), group("gb", "Bravo")])

    #expect(found.filter { $0.sessions.contains("u") }.count == 1)
  }

  @Test(arguments: [true, false])
  func aSessionPlacedInUngroupedByHandGetsNoJoin(_ ungroupedDepends: Bool) {
    let found = suggest(
      [
        session("u", byHand: true, pr: 1, edges: ungroupedDepends ? [edge(to: "m", 2)] : []),
        session("m", group: "g1", pr: 2, edges: ungroupedDepends ? [] : [edge(to: "u", 1)]),
      ],
      groups: [group("g1", "Flags")])

    #expect(found.isEmpty)
  }

  @Test func twoUngroupedSessionsGetNoSuggestionFromTheirEdge() {
    let found = suggest([session("a", pr: 1, edges: [edge(to: "b", 2)]), session("b", pr: 2)])

    #expect(found.isEmpty)
  }

  @Test func twoUngroupedSessionsWithAnEdgeCanStillShareAKey() {
    let found = suggest([
      session("a", pr: 1, edges: [edge(to: "b", 2)], branch: "haacked/flag-evaluations-cache"),
      session("b", pr: 2, branch: "haacked/flag-evaluations-perf"),
    ])

    #expect(found.map(\.id) == ["prefix:flag-evaluations"])
  }

  @Test func aJoinFromAnEdgeTakesItsSessionAwayFromKeySuggestions() {
    let found = suggest(
      [
        session("m", group: "g1", pr: 2),
        session("u1", pr: 1, edges: [edge(to: "m", 2)], branch: "haacked/flag-evaluations-cache"),
        session("u2", branch: "haacked/flag-evaluations-perf"),
        session("u3", branch: "haacked/flag-evaluations-docs"),
      ],
      groups: [group("g1", "Billing")])

    #expect(found.first?.id == "dependency:u1:g1")
    #expect(found.filter { $0.sessions.contains("u1") }.count == 1)
    #expect(found.contains { $0.id == "prefix:flag-evaluations" && $0.sessions == ["u2", "u3"] })
  }

  // MARK: Order

  @Test func mergesComeFirstThenJoinsFromEdgesThenKeySuggestions() {
    let found = suggest(
      [
        // A merge of g1 and g2 that moves one session.
        session("a", group: "g1", pr: 1, edges: [edge(to: "b", 2)]), session("b", group: "g2", pr: 2),
        // A merge of g3 and g4 that moves two sessions.
        session("c", group: "g3", byHand: true, pr: 3, edges: [edge(to: "d1", 4)]),
        session("d1", group: "g4", pr: 4), session("d2", group: "g4"),
        // Joins from edges, listed by session id.
        session("u2", pr: 6, edges: [edge(to: "a", 1)]), session("u1", pr: 5, edges: [edge(to: "b", 2)]),
        // A new group from branch names.
        session("k1", branch: "haacked/flag-evaluations-cache"), session("k2", branch: "haacked/flag-evaluations-perf"),
      ],
      groups: [
        group("g1", "One", created: 1), group("g2", "Two", created: 2), group("g3", "Three", created: 3),
        group("g4", "Four", created: 4),
      ])

    #expect(found.prefix(2).map(\.id) == ["merge:g3:g4", "merge:g1:g2"])
    #expect(found.dropFirst(2).prefix(2).map { $0.sessions } == [["u1"], ["u2"]])
    #expect(found.dropFirst(4).first?.id == "prefix:flag-evaluations")
  }

  @Test func mergesThatMoveTheSameNumberOfSessionsAreOrderedById() {
    let found = suggest(
      [
        session("c", group: "g3", pr: 3, edges: [edge(to: "d", 4)]), session("d", group: "g4", pr: 4),
        session("a", group: "g1", pr: 1, edges: [edge(to: "b", 2)]), session("b", group: "g2", pr: 2),
      ],
      groups: [
        group("g1", "One", created: 1), group("g2", "Two", created: 2), group("g3", "Three", created: 3),
        group("g4", "Four", created: 4),
      ])

    #expect(found.map(\.id) == ["merge:g1:g2", "merge:g3:g4"])
  }

  // MARK: Declined ids

  /// One case per suggestion kind, with the id that `declined` names.
  enum DeclinedKind: String, CaseIterable {
    case merge, dependency, prefixJoin, newGroup
  }

  func scenario(_ kind: DeclinedKind) -> (candidates: [Candidate], groups: [SessionGroup], id: String) {
    let groups = flagsAndCache
    switch kind {
    case .merge:
      return (
        [session("a", group: "g1", pr: 1, edges: [edge(to: "b", 2)]), session("b", group: "g2", pr: 2)], groups,
        "merge:g1:g2"
      )
    case .dependency:
      return (
        [session("u", pr: 1, edges: [edge(to: "m", 2)]), session("m", group: "g1", pr: 2)], groups,
        "dependency:u:g1"
      )
    case .prefixJoin:
      return (
        [
          session("m", group: "g1", branch: "haacked/flag-evaluations-cache"),
          session("u", branch: "haacked/flag-evaluations-perf"),
        ], groups, "prefix:flag-evaluations:g1"
      )
    case .newGroup:
      return (
        [
          session("a", branch: "haacked/flag-evaluations-cache"), session("b", branch: "haacked/flag-evaluations-perf"),
        ],
        [], "prefix:flag-evaluations"
      )
    }
  }

  @Test(arguments: DeclinedKind.allCases)
  func aDeclinedIdIsNotSuggested(_ kind: DeclinedKind) {
    let (candidates, groups, id) = scenario(kind)
    #expect(suggest(candidates, groups: groups).contains { $0.id == id })

    let found = suggest(candidates, groups: groups, declined: [id])

    #expect(!found.contains { $0.id == id })
  }

  @Test func aDeclinedMergeLeavesNoOtherSuggestionForThePair() {
    let (candidates, groups, id) = scenario(.merge)

    #expect(suggest(candidates, groups: groups, declined: [id]).isEmpty)
  }

  @Test func aDeclinedJoinFromAnEdgeTriesTheSessionsNextGroup() throws {
    let found = suggest(
      [
        session("u", pr: 1, edges: [edge(to: "m1", 2), edge(to: "m2", 3), edge(to: "m3", 4)]),
        session("m1", group: "ga", pr: 2), session("m2", group: "gb", pr: 3), session("m3", group: "gb", pr: 4),
      ],
      groups: [group("ga", "Alpha"), group("gb", "Bravo")], declined: ["dependency:u:gb"])

    let join = try #require(found.first { $0.sessions == ["u"] })
    #expect(join.id == "dependency:u:ga")
    #expect(join.reason == "#1 depends on #2")
  }

  @Test func aSessionWhoseJoinFromAnEdgeWasDeclinedCanGetAKeySuggestion() {
    let found = suggest(
      [
        session("m", group: "g1", pr: 2),
        session("u1", pr: 1, edges: [edge(to: "m", 2)], branch: "haacked/flag-evaluations-cache"),
        session("u2", branch: "haacked/flag-evaluations-perf"),
      ],
      groups: [group("g1", "Billing")], declined: ["dependency:u1:g1"])

    #expect(found.contains { $0.id == "prefix:flag-evaluations" && $0.sessions == ["u1", "u2"] })
  }

  @Test func aDeclinedKeySuggestionLeavesItsSessionsForTheNextKey() {
    let found = suggest(
      [session("a", branch: "haacked/flag-evaluations-cache"), session("b", branch: "haacked/flag-evaluations-perf")],
      declined: ["prefix:flag-evaluations"])

    #expect(found.contains { $0.sessions == ["a", "b"] })
  }

  // MARK: Sessions that are not candidates

  @Test(arguments: ["manager", "gone", nil] as [String?])
  func anEdgeToASessionThatIsNotACandidateSuggestsNothing(_ target: String?) {
    let found = suggest(
      [
        session("a", group: "g1", pr: 1, edges: [edge(to: target, 2)]),
        session("u", pr: 3, edges: [edge(to: target, 2)]),
      ],
      groups: [group("g1", "Flags", created: 1)])

    #expect(found.isEmpty)
  }

  // MARK: Wording and notes

  @Test func stayingNamesEachSessionThatStays() {
    let one = GroupSuggestion(id: "m", name: "Flags", group: "g1", sessions: ["a"], reason: "", stays: ["b"])
    let two = GroupSuggestion(id: "m", name: "Flags", group: "g1", sessions: ["a"], reason: "", stays: ["b", "c"])

    #expect(one.staying() == "b stays, placed by hand")
    #expect(two.staying { $0.uppercased() } == "B, C stay, placed by hand")
  }

  @Test func absorbingAddsTheOtherGroupsNotesOldestFirstWithoutRepeatingAnId() {
    let kept = SessionGroup(
      id: "g1", name: "Flags", notes: [Note(id: "n1", text: "kept", by: .you, t: 10)], created: 1)
    let other = SessionGroup(
      id: "g2", name: "Cache",
      notes: [Note(id: "n1", text: "clash", by: .you, t: 5), Note(id: "n2", text: "later", by: .you, t: 20)],
      created: 2)

    let merged = kept.absorbing(other)

    #expect(merged.id == "g1")
    #expect(merged.name == "Flags")
    #expect(merged.notes.map(\.text) == ["clash", "kept", "later"])
    #expect(Set(merged.notes.map(\.id)).count == 3)
    #expect(merged.notes.first { $0.text == "kept" }?.id == "n1")
  }
}
