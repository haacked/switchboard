import Testing

@testable import SwitchboardCore

@Suite struct GroupSuggestionTests {
  typealias Candidate = GroupSuggestions.Candidate

  func session(
    _ id: String, branch: String? = nil, title: String? = nil, group: String? = nil, byHand: Bool = false
  ) -> Candidate {
    Candidate(id: id, branch: branch, prTitle: title, group: group, placedByHand: byHand)
  }

  func group(_ id: String, _ name: String) -> SessionGroup {
    SessionGroup(id: id, name: name, notes: [], created: 0)
  }

  func suggest(_ candidates: [Candidate], groups: [SessionGroup] = []) -> [GroupSuggestion] {
    GroupSuggestions.make(candidates: candidates, groups: groups)
  }

  // MARK: Keys

  @Test func branchesThatShareAPrefixAfterTheOwnerGetANewGroup() throws {
    let found = suggest([
      session("a", branch: "haacked/flag-evaluations-cache"), session("b", branch: "haacked/flag-evaluations-perf"),
    ])

    let first = try #require(found.first)
    #expect(first.id == "prefix:flag-evaluations")
    #expect(first.name == "flag-evaluations")
    #expect(first.group == nil)
    #expect(Set(first.sessions) == ["a", "b"])
    #expect(first.reason == "branches start with flag-evaluations")
  }

  @Test func theOwnerPrefixIsNotPartOfTheKey() throws {
    let found = suggest([
      session("a", branch: "haacked/flag-evaluations-cache"), session("b", branch: "dmarticus/flag-evaluations-perf"),
    ])

    #expect(try #require(found.first).id == "prefix:flag-evaluations")
  }

  @Test(arguments: [
    "haacked/flag_evaluations_cache", "haacked/flag.evaluations.cache", "haacked/flag/evaluations/cache",
  ])
  func branchWordsSplitOnEachSeparator(_ branch: String) throws {
    let found = suggest([session("a", branch: branch), session("b", branch: "haacked/flag-evaluations-perf")])

    #expect(try #require(found.first).id == "prefix:flag-evaluations")
  }

  @Test func aPrefixLeavesOutTheLastWordOfTheBranch() throws {
    let found = suggest([session("a", branch: "haacked/cache"), session("b", branch: "haacked/cache-warmup")])

    #expect(!found.contains { $0.id.hasPrefix("prefix:") })
    #expect(try #require(found.first).id == "word:cache")
  }

  @Test func aPrefixOfOnlyInsignificantWordsGivesNoSuggestion() {
    let found = suggest([session("a", branch: "haacked/fix-a1-cache"), session("b", branch: "haacked/fix-a1-tests")])

    #expect(found.isEmpty)
  }

  @Test func prTitlesWithTheSameConventionalScopeGetANewGroup() throws {
    let found = suggest([
      session("a", title: "feat(flags): cache evaluations"), session("b", title: "fix(flags): retry payloads"),
    ])

    let first = try #require(found.first)
    #expect(first.id == "scope:flags")
    #expect(first.name == "flags")
    #expect(first.group == nil)
    #expect(Set(first.sessions) == ["a", "b"])
    #expect(first.reason == "PR titles have the scope flags")
  }

  @Test func aSignificantWordSharedByABranchAndAPRTitleGetsANewGroup() throws {
    let found = suggest([session("a", branch: "haacked/tune-evaluations"), session("b", title: "speed up evaluations")])

    let first = try #require(found.first)
    #expect(first.id == "word:evaluations")
    #expect(first.name == "evaluations")
    #expect(Set(first.sessions) == ["a", "b"])
    #expect(first.reason == "branches or PR titles share the word evaluations")
  }

  @Test(arguments: [
    "update", "remove", "with", "from", "into",
    // Fewer than 4 letters.
    "api",
    // A number.
    "1234",
  ])
  func aSharedInsignificantWordGivesNoSuggestion(_ word: String) {
    let found = suggest([
      session("a", branch: "haacked/\(word)-alpha", title: "\(word) alpha"),
      session("b", branch: "haacked/\(word)-bravo", title: "\(word) bravo"),
    ])

    #expect(found.isEmpty)
  }

  @Test func aSingleSessionGetsNoNewGroup() {
    #expect(suggest([session("a", branch: "haacked/flag-evaluations-cache", title: "feat(flags): cache")]).isEmpty)
  }

  // MARK: Joining a group

  @Test func aKeyThatAGroupHasSuggestsJoiningIt() throws {
    let found = suggest(
      [
        session("m", branch: "haacked/flag-evaluations-cache", group: "g1"),
        session("c", branch: "haacked/flag-evaluations-perf"),
      ],
      groups: [group("g1", "Flags")])

    let first = try #require(found.first)
    #expect(first.id == "prefix:flag-evaluations:g1")
    #expect(first.group == "g1")
    #expect(first.name == "Flags")
    #expect(first.sessions == ["c"])
  }

  @Test func aKeyThatAGroupHasGivesNoNewGroupEvenWhenCandidatesShareIt() {
    let found = suggest(
      [
        session("m", branch: "haacked/flag-evaluations-cache", group: "g1"),
        session("c1", branch: "haacked/flag-evaluations-perf"),
        session("c2", branch: "haacked/flag-evaluations-docs"),
      ],
      groups: [group("g1", "Flags")])

    let joins = found.filter { $0.sessions.contains("c1") || $0.sessions.contains("c2") }
    #expect(joins.allSatisfy { $0.group == "g1" })
    #expect(Set(joins.flatMap(\.sessions)) == ["c1", "c2"])
  }

  @Test func theSlugOfAGroupsNameIsAPrefixKeyOfTheGroup() throws {
    let found = suggest(
      [session("c", branch: "haacked/flag-evaluations-perf")], groups: [group("g1", "Flag evaluations")])

    let first = try #require(found.first)
    #expect(first.id == "prefix:flag-evaluations:g1")
    #expect(first.group == "g1")
    #expect(first.sessions == ["c"])
  }

  @Test func aJoinPicksTheGroupWithTheMostMembersThatHaveTheKey() throws {
    let found = suggest(
      [
        session("m1", branch: "haacked/flag-evaluations-a1", group: "small"),
        session("m2", branch: "haacked/flag-evaluations-b1", group: "big"),
        session("m3", branch: "haacked/flag-evaluations-c1", group: "big"),
        session("c", branch: "haacked/flag-evaluations-perf"),
      ],
      groups: [group("small", "Small"), group("big", "Big")])

    let join = try #require(found.first { $0.sessions.contains("c") })
    #expect(join.group == "big")
  }

  @Test func groupedSessionsAreNeverSuggested() {
    let found = suggest(
      [
        session("m1", branch: "haacked/flag-evaluations-cache", group: "g1"),
        session("m2", branch: "haacked/flag-evaluations-perf", group: "g2"),
      ],
      groups: [group("g1", "One"), group("g2", "Two")])

    #expect(found.isEmpty)
  }

  @Test func aSessionPlacedInUngroupedByHandIsNotACandidate() throws {
    let found = suggest([
      session("hand", branch: "haacked/flag-evaluations-docs", byHand: true),
      session("a", branch: "haacked/flag-evaluations-cache"), session("b", branch: "haacked/flag-evaluations-perf"),
    ])

    #expect(!found.contains { $0.sessions.contains("hand") })
    #expect(Set(try #require(found.first).sessions) == ["a", "b"])
  }

  @Test func aSessionPlacedInAGroupByHandStillGivesItsGroupKeys() throws {
    let found = suggest(
      [
        session("m", branch: "haacked/flag-evaluations-cache", group: "g1", byHand: true),
        session("c", branch: "haacked/flag-evaluations-perf"),
      ],
      groups: [group("g1", "Flags")])

    #expect(try #require(found.first).group == "g1")
  }

  // MARK: Ranking

  @Test func eachSessionAppearsInAtMostOneSuggestion() {
    let found = suggest([
      session("a", branch: "haacked/flag-evaluations-cache", title: "feat(flags): cache evaluations"),
      session("b", branch: "haacked/flag-evaluations-perf", title: "feat(flags): faster evaluations"),
      session("c", branch: "haacked/cache-warmup", title: "feat(flags): warm the cache"),
      session("d", title: "speed up evaluations"),
    ])

    let ids = found.flatMap(\.sessions)
    #expect(ids.count == Set(ids).count)
  }

  @Test func aSuggestionThatTouchesMoreSessionsRanksFirst() {
    let found = suggest([
      session("d", branch: "haacked/cache-tuning-delta"), session("e", branch: "haacked/cache-tuning-echo"),
      session("a", branch: "haacked/alpha-evaluations"), session("b", branch: "haacked/bravo-evaluations"),
      session("c", branch: "haacked/charlie-evaluations"),
    ])

    #expect(found.prefix(2).map(\.id) == ["word:evaluations", "prefix:cache-tuning"])
  }

  @Test func atTheSameSizeAPrefixRanksBeforeAScope() {
    let found = suggest([
      session("c", title: "feat(flags): cache evaluations"), session("d", title: "fix(flags): retry payloads"),
      session("a", branch: "haacked/billing-alpha"), session("b", branch: "haacked/billing-bravo"),
    ])

    #expect(found.prefix(2).map(\.id) == ["prefix:billing", "scope:flags"])
  }

  @Test func atTheSameSizeAScopeRanksBeforeAWord() {
    let found = suggest([
      session("c", branch: "haacked/alpha-evaluations"), session("d", branch: "haacked/bravo-evaluations"),
      session("a", title: "feat(flags): cache"), session("b", title: "fix(flags): retry"),
    ])

    #expect(found.prefix(2).map(\.id) == ["scope:flags", "word:evaluations"])
  }

  @Test func atTheSameSizeAndKindALongerKeyRanksFirst() {
    let found = suggest([
      session("c", branch: "haacked/flags-alpha"), session("d", branch: "haacked/flags-bravo"),
      session("a", branch: "haacked/evaluations-cache-delta"), session("b", branch: "haacked/evaluations-cache-echo"),
    ])

    #expect(found.prefix(2).map(\.id) == ["prefix:evaluations-cache", "prefix:flags"])
  }

  @Test func atTheSameSizeKindAndLengthTheNameDecides() {
    let found = suggest([
      session("c", branch: "haacked/delta-one"), session("d", branch: "haacked/delta-two"),
      session("a", branch: "haacked/bravo-one"), session("b", branch: "haacked/bravo-two"),
    ])

    #expect(found.prefix(2).map(\.id) == ["prefix:bravo", "prefix:delta"])
  }

  @Test func theLongestSharedPrefixWinsOverItsShorterPrefixes() throws {
    let found = suggest([
      session("a", branch: "haacked/flag-evaluations-cache-ttl"),
      session("b", branch: "haacked/flag-evaluations-cache-size"),
    ])

    #expect(try #require(found.first).id == "prefix:flag-evaluations-cache")
  }

  @Test(arguments: [("feat(flags): cache", "fix(flags): retry"), ("Speed up flags", "Retry flags")])
  func aKeyThatMatchesAGroupsNameJoinsItWhateverItsKind(_ titles: (String, String)) throws {
    let found = suggest(
      [session("a", title: titles.0), session("b", title: titles.1)], groups: [group("g1", "flags")])

    let first = try #require(found.first)
    #expect(first.group == "g1")
    #expect(found.allSatisfy { $0.name != "flags" || $0.group == "g1" })
  }
}
