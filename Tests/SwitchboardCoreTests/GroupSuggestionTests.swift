import Testing

@testable import SwitchboardCore

@Suite struct GroupSuggestionTests {
  typealias Candidate = GroupSuggestions.Candidate

  func session(
    _ id: String, branch: String? = nil, title: String? = nil, group: String? = nil, byHand: Bool = false,
    finished: Bool = false
  ) -> Candidate {
    Candidate(id: id, branch: branch, prTitle: title, group: group, placedByHand: byHand, finished: finished)
  }

  func group(_ id: String, _ name: String) -> SessionGroup {
    SessionGroup(id: id, name: name, notes: [], created: 0)
  }

  func suggest(
    _ candidates: [Candidate], groups: [SessionGroup] = [], declined: Set<String> = [],
    limit: Int = GroupSuggestions.defaultLimit
  ) -> [GroupSuggestion] {
    GroupSuggestions.make(candidates: candidates, groups: groups, declined: declined, limit: limit)
  }

  /// Two sessions in no group on `haacked/<prefix>-one` and `haacked/<prefix>-two`.
  func pair(_ prefix: String) -> [Candidate] {
    [session("\(prefix)-1", branch: "haacked/\(prefix)-one"), session("\(prefix)-2", branch: "haacked/\(prefix)-two")]
  }

  /// Four pairs whose prefixes have the same length, so the name decides their order.
  var fourPairs: [Candidate] { ["delta-team", "alpha-team", "gamma-team", "bravo-team"].flatMap(pair) }

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

  @Test func aPrefixLeavesOutTheLastWordOfTheBranch() {
    let found = suggest([
      session("a", branch: "haacked/flag-evaluations"), session("b", branch: "haacked/flag-evaluations-cache"),
    ])

    #expect(found.isEmpty)
  }

  @Test(arguments: ["haacked/board-alpha", "board-alpha", "haacked/board"])
  func aOneWordPrefixGivesNoSuggestion(_ branch: String) {
    let found = suggest([session("a", branch: branch), session("b", branch: "haacked/board-bravo")])

    #expect(found.isEmpty)
  }

  @Test func onlyTheSessionsThatShareTwoWordsGetANewGroup() {
    let found = suggest([
      session("a", branch: "haacked/board-alpha"), session("b", branch: "haacked/board-bravo"),
      session("c", branch: "haacked/flag-evaluations-cache"), session("d", branch: "haacked/flag-evaluations-perf"),
    ])

    #expect(found.map(\.id) == ["prefix:flag-evaluations"])
    #expect(found.first?.sessions == ["c", "d"])
  }

  @Test func branchesThatShareOnlyTheirFirstOfThreeWordsGetNoSuggestion() {
    let found = suggest([
      session("a", branch: "haacked/board-header-button"), session("b", branch: "haacked/board-popover-width"),
    ])

    #expect(found.isEmpty)
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

  /// How two sessions can share a significant word and nothing else.
  static let sharedWord: [[(branch: String?, title: String?)]] = [
    [("haacked/tune-evaluations", nil), (nil, "speed up evaluations")],
    [("haacked/alpha-evaluations", nil), ("haacked/bravo-evaluations", nil)],
    [(nil, "speed up evaluations"), (nil, "cache evaluations")],
    [("haacked/tune-evaluations", "tune evaluations"), ("haacked/cache-evaluations", "cache evaluations")],
    [("haacked/alpha-evaluations-cache", nil), ("haacked/bravo-evaluations-perf", nil)],
  ]

  @Test(arguments: sharedWord.indices)
  func aSharedWordAloneGivesNoSuggestion(_ shape: Int) {
    let found = suggest(
      Self.sharedWord[shape].enumerated().map {
        session("s\($0.offset)", branch: $0.element.branch, title: $0.element.title)
      })

    #expect(found.isEmpty)
  }

  @Test(arguments: [
    "update", "remove", "with", "from", "into",
    // Fewer than 4 letters.
    "api",
    // A number.
    "1234",
  ])
  func aTwoWordPrefixOfInsignificantWordsGivesNoSuggestion(_ word: String) {
    let found = suggest([
      session("a", branch: "haacked/\(word)-a1-alpha"), session("b", branch: "haacked/\(word)-a1-bravo"),
    ])

    #expect(found.isEmpty)
  }

  @Test func aTwoWordPrefixWithOneSignificantWordGetsANewGroup() {
    let found = suggest([
      session("a", branch: "haacked/update-billing-alpha"), session("b", branch: "haacked/update-billing-bravo"),
    ])

    #expect(found.map(\.id) == ["prefix:update-billing"])
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

  /// No one-word prefix key exists, so neither a member's branch nor the group's name gives one.
  @Test(arguments: [true, false])
  func aOneWordPrefixDoesNotJoinAGroup(_ memberHasTheBranch: Bool) {
    let found = suggest(
      [
        session("m", branch: memberHasTheBranch ? "haacked/billing-alpha" : nil, group: "g1"),
        session("c", branch: "haacked/billing-retry"),
      ],
      groups: [group("g1", "Billing")])

    #expect(found.isEmpty)
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
    #expect(!found.isEmpty)
    #expect(ids.count == Set(ids).count)
  }

  /// The larger suggestion has the shorter key, so the key's length does not put it first.
  @Test func aSuggestionThatTouchesMoreSessionsRanksFirst() {
    let found = suggest([
      session("d", branch: "haacked/flag-evaluations-delta"), session("e", branch: "haacked/flag-evaluations-echo"),
      session("a", branch: "haacked/cache-tuning-alpha"), session("b", branch: "haacked/cache-tuning-bravo"),
      session("c", branch: "haacked/cache-tuning-charlie"),
    ])

    #expect(found.map(\.id) == ["prefix:cache-tuning", "prefix:flag-evaluations"])
  }

  /// The scope is longer than the prefix and sorts before it, so only the kind puts the prefix first.
  @Test func atTheSameSizeAPrefixRanksBeforeAScope() {
    let found = suggest([
      session("c", title: "feat(api-evaluations-cache): one"), session("d", title: "fix(api-evaluations-cache): two"),
      session("a", branch: "haacked/billing-retry-alpha"), session("b", branch: "haacked/billing-retry-bravo"),
    ])

    #expect(found.map(\.id) == ["prefix:billing-retry", "scope:api-evaluations-cache"])
  }

  /// The longer key sorts after the shorter one, so only its length puts it first.
  @Test func atTheSameSizeAndKindALongerKeyRanksFirst() {
    let found = suggest([
      session("c", branch: "haacked/flags-api-alpha"), session("d", branch: "haacked/flags-api-bravo"),
      session("a", branch: "haacked/zebra-evaluations-delta"), session("b", branch: "haacked/zebra-evaluations-echo"),
    ])

    #expect(found.map(\.id) == ["prefix:zebra-evaluations", "prefix:flags-api"])
  }

  @Test func atTheSameSizeKindAndLengthTheNameDecides() {
    let found = suggest([
      session("c", branch: "haacked/delta-team-one"), session("d", branch: "haacked/delta-team-two"),
      session("a", branch: "haacked/bravo-team-one"), session("b", branch: "haacked/bravo-team-two"),
    ])

    #expect(found.map(\.id) == ["prefix:bravo-team", "prefix:delta-team"])
  }

  @Test func theLongestSharedPrefixWinsOverItsShorterPrefixes() throws {
    let found = suggest([
      session("a", branch: "haacked/flag-evaluations-cache-ttl"),
      session("b", branch: "haacked/flag-evaluations-cache-size"),
    ])

    #expect(try #require(found.first).id == "prefix:flag-evaluations-cache")
  }

  /// The kinds of key that two sessions can share with the name of the group `flag-evals`.
  enum NamedKey: CaseIterable { case prefix, scope }

  @Test(arguments: NamedKey.allCases)
  func aKeyThatMatchesAGroupsNameJoinsItWhateverItsKind(_ kind: NamedKey) throws {
    let candidates =
      switch kind {
      case .prefix: [session("a", branch: "haacked/flag-evals-cache"), session("b", branch: "haacked/flag-evals-perf")]
      case .scope: [session("a", title: "feat(flag-evals): cache"), session("b", title: "fix(flag-evals): retry")]
      }

    let found = suggest(candidates, groups: [group("g1", "flag-evals")])

    let first = try #require(found.first)
    #expect(first.group == "g1")
    #expect(found.allSatisfy { $0.name != "flag-evals" || $0.group == "g1" })
  }

  @Test(arguments: ["api/flags", "flag_eval", "flag evals", "flag-evals"])
  func aScopeJoinsTheGroupNamedAfterItWhateverItsSeparators(_ scope: String) throws {
    let found = suggest(
      [session("a", title: "feat(\(scope)): one"), session("b", title: "fix(\(scope)): two")],
      groups: [group("g1", scope)])

    let join = try #require(found.first { $0.id.hasPrefix("scope:") })
    #expect(join.group == "g1")
  }

  // MARK: Finished sessions

  /// The key that the sessions share.
  enum SharedKey: CaseIterable { case prefix, scope }

  func sharing(_ key: SharedKey, _ id: String, group: String? = nil, finished: Bool = false) -> Candidate {
    switch key {
    case .prefix: session(id, branch: "haacked/flag-evaluations-\(id)", group: group, finished: finished)
    case .scope: session(id, title: "feat(flags): \(id)", group: group, finished: finished)
    }
  }

  @Test(arguments: SharedKey.allCases)
  func aFinishedSessionIsLeftOutOfANewGroup(_ key: SharedKey) {
    let found = suggest([sharing(key, "a"), sharing(key, "f", finished: true), sharing(key, "b")])

    #expect(found.map(\.sessions) == [["a", "b"]])
  }

  @Test(arguments: SharedKey.allCases)
  func twoFinishedSessionsGiveNoNewGroup(_ key: SharedKey) {
    let found = suggest([sharing(key, "a", finished: true), sharing(key, "b", finished: true)])

    #expect(found.isEmpty)
  }

  @Test(arguments: SharedKey.allCases)
  func aFinishedSessionDoesNotCountTowardTheTwoOfANewGroup(_ key: SharedKey) {
    let found = suggest([sharing(key, "a"), sharing(key, "f", finished: true)])

    #expect(found.isEmpty)
  }

  @Test(arguments: SharedKey.allCases)
  func aFinishedSessionGetsNoJoinFromAKey(_ key: SharedKey) {
    let found = suggest(
      [sharing(key, "m", group: "g1"), sharing(key, "f", finished: true)], groups: [group("g1", "Cache")])

    #expect(found.isEmpty)
  }

  /// The group's name matches no key, so only its finished member gives it the key.
  @Test(arguments: SharedKey.allCases)
  func aFinishedMemberStillGivesItsGroupKeys(_ key: SharedKey) throws {
    let found = suggest(
      [sharing(key, "m", group: "g1", finished: true), sharing(key, "c")], groups: [group("g1", "Cache")])

    let join = try #require(found.first)
    #expect(join.group == "g1")
    #expect(join.sessions == ["c"])
    #expect(found.count == 1)
  }

  // MARK: The cap

  @Test func atMostThreeSuggestionsComeBack() {
    let found = suggest(fourPairs)

    #expect(found.map(\.id) == ["prefix:alpha-team", "prefix:bravo-team", "prefix:delta-team"])
  }

  @Test func theFourthSuggestionAppearsOnceTheFirstIsDeclined() {
    let found = suggest(fourPairs, declined: ["prefix:alpha-team"])

    #expect(found.map(\.id) == ["prefix:bravo-team", "prefix:delta-team", "prefix:gamma-team"])
  }

  @Test func aLimitLargerThanTheListReturnsAll() {
    let found = suggest(fourPairs, limit: 10)

    #expect(
      found.map(\.id) == ["prefix:alpha-team", "prefix:bravo-team", "prefix:delta-team", "prefix:gamma-team"])
  }

  @Test func theCappedListIsTheStartOfTheFullRanking() {
    let candidates = fourPairs + [session("x", title: "feat(flags): one"), session("y", title: "fix(flags): two")]

    let full = suggest(candidates, limit: 10)

    #expect(full.count == 5)
    #expect(suggest(candidates) == Array(full.prefix(3)))
    #expect(suggest(candidates, limit: 1) == Array(full.prefix(1)))
  }
}
