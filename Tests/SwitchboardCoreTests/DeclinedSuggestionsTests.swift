import Testing

@testable import SwitchboardCore

/// The decisions about `declined_suggestions`, which group suggestions share with plan row suggestions.
@Suite struct DeclinedSuggestionsTests {
  /// The ids that pruning deletes. sbd has the groups g1 and g2 and the session s1 unless a test says otherwise.
  func pruned(_ declined: Set<String>, groups: Set<String> = ["g1", "g2"], sessions: Set<String> = ["s1"])
    -> Set<String>
  {
    Set(DeclinedSuggestions.prunable(declined: declined, groups: groups, sessions: sessions))
  }

  func listed(_ declined: Set<String>) -> Set<String> { Set(DeclinedSuggestions.groupSuggestionIDs(declined)) }

  /// A plan row's id is its plan's id, a colon, and the row's link. The last
  /// three have `prefix`, `merge`, and `dependency` as the plan's id.
  static let planRows = [
    "pab2cd:posthog/posthog#12", "pab2cd:PostHog/posthog#122953", "prefix:posthog/posthog#12",
    "prefix:PostHog/requests-for-comments-internal#1209", "merge:posthog/posthog#12", "dependency:posthog/posthog#12",
  ]

  // MARK: word

  @Test(arguments: ["word:each", "word:evaluations", "word:a:b", "word:", "word:g1", "word:s1:g1"])
  func everyWordIdIsDeleted(_ id: String) {
    #expect(pruned([id]) == [id])
  }

  @Test(arguments: ["word", "words:each", "Word:each", "keyword:each", " word:each"])
  func anIdThatOnlyLooksLikeAWordIdIsKept(_ id: String) {
    #expect(pruned([id], groups: [], sessions: []).isEmpty)
  }

  // MARK: merge

  @Test func aMergeOfTwoLiveGroupsIsKept() {
    #expect(pruned(["merge:g1:g2"]).isEmpty)
  }

  @Test(arguments: [["g1"], ["g2"], []] as [Set<String>])
  func aMergeIsDeletedWhenEitherGroupIsGone(_ live: Set<String>) {
    #expect(pruned(["merge:g1:g2"], groups: live) == ["merge:g1:g2"])
  }

  /// A session with a group's id does not keep the group alive.
  @Test func aMergeIsDeletedWhenItsGroupIdIsOnlyASessionsId() {
    #expect(pruned(["merge:g1:g2"], groups: ["g1"], sessions: ["g2"]) == ["merge:g1:g2"])
  }

  // MARK: dependency

  @Test func aDependencyJoinOfALiveSessionAndALiveGroupIsKept() {
    #expect(pruned(["dependency:s1:g1"]).isEmpty)
  }

  @Test func aDependencyJoinIsDeletedWhenItsSessionIsGone() {
    #expect(pruned(["dependency:s1:g1"], sessions: ["s2"]) == ["dependency:s1:g1"])
  }

  @Test func aDependencyJoinIsDeletedWhenItsGroupIsGone() {
    #expect(pruned(["dependency:s1:g1"], groups: ["g2"]) == ["dependency:s1:g1"])
  }

  /// The first field after the kind is the session, and the second is the group.
  @Test func aDependencyJoinIsDeletedWhenItsFieldsAreLiveOnlyInTheOtherSet() {
    #expect(pruned(["dependency:s1:g1"], groups: ["s1"], sessions: ["g1"]) == ["dependency:s1:g1"])
  }

  // MARK: prefix

  @Test(arguments: ["prefix:flag-evaluations:g1", "prefix:billing:g1", "prefix:v2-api-cache:g1"])
  func aPrefixJoinToALiveGroupIsKept(_ id: String) {
    #expect(pruned([id]).isEmpty)
  }

  @Test(arguments: ["prefix:flag-evaluations:g1", "prefix:billing:g1", "prefix:v2-api-cache:g1"])
  func aPrefixJoinIsDeletedWhenItsGroupIsGone(_ id: String) {
    #expect(pruned([id], groups: ["g2"]) == [id])
  }

  /// A new group from a prefix names no group. A live suggestion can produce
  /// the two-word id again, and the one-word id is out of scope.
  @Test(arguments: ["prefix:flag-evaluations", "prefix:billing", "prefix:g1", "prefix:gone"])
  func aPrefixIdWithoutAGroupIsKept(_ id: String) {
    #expect(pruned([id], groups: [], sessions: []).isEmpty)
  }

  /// A slug holds only letters, digits, and `-`.
  @Test(arguments: [
    "prefix:posthog/posthog#12:gone", "prefix:flag_evaluations:gone", "prefix:flag evaluations:gone",
    "prefix:flag.evaluations:gone", "prefix:flag-evaluations#1:gone",
  ])
  func aPrefixIdWhoseSecondFieldIsNotASlugIsKept(_ id: String) {
    #expect(pruned([id], groups: [], sessions: []).isEmpty)
  }

  // MARK: scope

  /// A scope's text may hold a colon, so its last field may be text and not a group.
  @Test(arguments: ["scope:a:b", "scope:x:gone", "scope:flags", "scope:api/flags:gone", "scope:a:b:gone", "scope:"])
  func aScopeIdIsKept(_ id: String) {
    #expect(pruned([id], groups: [], sessions: []).isEmpty)
  }

  // MARK: Plan rows and unrecognized ids

  @Test(arguments: planRows)
  func aPlanRowIdIsKept(_ id: String) {
    #expect(pruned([id], groups: [], sessions: []).isEmpty)
  }

  @Test(arguments: [
    "merge:g1", "merge:g1:g2:g3", "merge", "merge:", "dependency:s1", "dependency:s1:g1:g2", "dependency",
    "prefix:flag-evaluations:g1:g2", "prefix", "",
  ])
  func anIdWithTheWrongNumberOfFieldsIsKept(_ id: String) {
    #expect(pruned([id], groups: [], sessions: []).isEmpty)
  }

  @Test(arguments: [
    "issue:12:gone", "unknown:gone", "mergex:gone:gone", "Merge:gone:gone", "DEPENDENCY:gone:gone", ":gone:gone",
    "gone", "pab2cd", " merge:gone:gone",
  ])
  func anIdOfAnUnknownKindIsKept(_ id: String) {
    #expect(pruned([id], groups: [], sessions: []).isEmpty)
  }

  @Test func emptyLiveSetsDeleteOnlyWhatTheRulesAllow() {
    let deleted: Set<String> = ["word:each", "merge:g1:g2", "dependency:s1:g1", "prefix:flag-evaluations:g1"]
    let kept: Set<String> = [
      "prefix:flag-evaluations", "scope:flags", "scope:a:b", "scope:x:g1", "merge:g1", "merge:g1:g2:g3", "",
      "unknown:g1", "prefix:posthog/posthog#12:g1",
    ]

    let found = pruned(deleted.union(kept).union(Self.planRows), groups: [], sessions: [])

    #expect(found == deleted)
  }

  @Test func eachIdIsJudgedOnItsOwn() {
    let found = pruned(
      [
        "merge:g1:g2", "merge:g1:g9", "dependency:s1:g1", "dependency:s9:g1", "prefix:flag-evaluations:g2", "word:each",
      ],
      groups: ["g1", "g2"], sessions: ["s1"])

    #expect(found == ["merge:g1:g9", "dependency:s9:g1", "word:each"])
  }

  @Test func noDeclinedIdsDeleteNothing() {
    #expect(pruned([]).isEmpty)
  }

  // MARK: The ids a live suggestion can produce

  /// One suggestion of each shape that `GroupSuggestions` makes: a merge, a
  /// join from a dependency, a join and a new group from a prefix, and a
  /// join and a new group from a scope whose text holds `/` and `:`.
  func everySuggestionShape() -> (candidates: [GroupSuggestions.Candidate], groups: [SessionGroup]) {
    func session(
      _ id: String, branch: String? = nil, title: String? = nil, group: String? = nil, pr: Int? = nil,
      to: (session: String, pr: Int)? = nil
    ) -> GroupSuggestions.Candidate {
      GroupSuggestions.Candidate(
        id: id, branch: branch, prTitle: title, group: group, placedByHand: false,
        repo: pr == nil ? nil : "PostHog/posthog", pr: pr,
        dependencies: to.map {
          [Dependency(via: .stack, repo: "PostHog/posthog", number: $0.pr, state: .open, session: $0.session)]
        } ?? [])
    }
    return (
      [
        session("a", group: "g1", pr: 1, to: ("b", 2)), session("b", group: "g2", pr: 2),
        session("u", pr: 3, to: ("m", 4)), session("m", group: "g3", pr: 4),
        session("pm", branch: "haacked/flag-evaluations-cache", group: "g4"),
        session("pc", branch: "haacked/flag-evaluations-perf"),
        session("n1", branch: "haacked/billing-retry-one"), session("n2", branch: "haacked/billing-retry-two"),
        session("sm", title: "feat(api/flags): one", group: "g5"), session("sc", title: "fix(api/flags): two"),
        session("t1", title: "feat(core:cache): one"), session("t2", title: "fix(core:cache): two"),
      ],
      ["g1", "g2", "g3", "g4", "g5"].enumerated().map {
        SessionGroup(id: $0.element, name: "Group \($0.offset)", notes: [], created: Int64($0.offset))
      }
    )
  }

  func everySuggestionId() -> Set<String> {
    let (candidates, groups) = everySuggestionShape()
    return Set(GroupSuggestions.make(candidates: candidates, groups: groups, limit: 100).map(\.id))
  }

  @Test func theScenarioHoldsEveryShapeOfSuggestionId() {
    #expect(
      everySuggestionId() == [
        "merge:g1:g2", "dependency:u:g3", "prefix:flag-evaluations:g4", "prefix:billing-retry", "scope:api/flags:g5",
        "scope:core:cache",
      ])
  }

  @Test func pruningKeepsEveryIdThatALiveSuggestionProduces() {
    let (candidates, groups) = everySuggestionShape()

    let found = pruned(everySuggestionId(), groups: Set(groups.map(\.id)), sessions: Set(candidates.map(\.id)))

    #expect(found.isEmpty)
  }

  @Test func everyIdThatASuggestionProducesIsListedAsAGroupSuggestion() {
    let ids = everySuggestionId()

    #expect(listed(ids) == ids)
  }

  // MARK: Listing

  @Test(arguments: planRows + ["", "unknown:g1", "pab2cd"])
  func anIdThatIsNotAGroupSuggestionIsNotListed(_ id: String) {
    #expect(listed([id]).isEmpty)
  }

  @Test func aPlanRowIdIsLeftOutOfTheListAmongGroupSuggestionIds() {
    let group: Set<String> = ["merge:g1:g2", "dependency:s1:g1", "prefix:flag-evaluations", "scope:flags"]

    #expect(listed(group.union(Self.planRows)) == group)
  }

  @Test func theListIsSorted() {
    let ids = DeclinedSuggestions.groupSuggestionIDs([
      "scope:flags", "merge:g1:g2", "prefix:flag-evaluations", "dependency:s1:g1",
    ])

    #expect(Array(ids) == ["dependency:s1:g1", "merge:g1:g2", "prefix:flag-evaluations", "scope:flags"])
  }
}
