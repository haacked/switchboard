import Testing

@testable import SwitchboardCore

private func session(
  _ id: String, name: String? = nil, repo: String? = nil, branch: String? = nil, pr: PRSummary? = nil,
  issues: [Int] = [], group: String? = nil, reason: String = "", notes: [String] = [], lastActivity: Int64 = 0
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: name ?? id, cwd: repo ?? "/tmp", repo: repo, branch: branch, claudeSessionId: id, state: .working,
    reason: reason, since: 0, lastActivity: lastActivity, live: true, claudePid: nil, attached: false, lastReply: nil,
    waits: [], notes: notes.enumerated().map { Note(id: "n\($0.offset)", text: $0.element, by: .you, t: 0) }, pr: pr)
  s.issues = issues.isEmpty ? nil : issues.map { SessionIssue(repo: "o/r", number: $0, via: .set) }
  s.group = group.map { _ in "g1" }
  s.groupName = group
  return s
}

/// The repo `o/r` gives the label `r`, which no query term in these tests matches.
private func pr(_ number: Int, repo: String = "o/r", title: String = "") -> PRSummary {
  PRSummary(
    PullRequest(
      id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo, title: title))
}

private func ids(_ sessions: [SessionSummary], _ query: String) -> [String] {
  SessionSearch.rank(sessions, query: query).map(\.id)
}

@Suite struct SessionSearchTests {

  // MARK: tier

  struct TierCase: Sendable, CustomTestStringConvertible {
    var term: String
    var text: String
    var subsequence = true
    var tier: Int?
    var testDescription: String { "\(term) in \(text) (subsequence \(subsequence))" }
  }

  @Test(arguments: [
    TierCase(term: "kafka", text: "kafka", tier: 100),
    TierCase(term: "kafka", text: "kafka", subsequence: false, tier: 100),
    TierCase(term: "kafka", text: "kafka-retry", tier: 80),
    TierCase(term: "kafka", text: "fix/kafka", tier: 60),
    TierCase(term: "kafka", text: "fix-kafka", tier: 60),
    TierCase(term: "kafka", text: "fix_kafka", tier: 60),
    TierCase(term: "kafka", text: "fix kafka", tier: 60),
    TierCase(term: "kafka", text: "fix.kafka", tier: 60),
    TierCase(term: "kafka", text: "xkafka-kafka", tier: 60),
    TierCase(term: "afka", text: "kafka", tier: 40),
    TierCase(term: "kafka", text: "2kafka", tier: 40),
    TierCase(term: "kr", text: "kafka-retry", tier: 20),
  ])
  func aTermGetsTheHighestTierThatApplies(_ c: TierCase) {
    #expect(SessionSearch.tier(c.term, in: c.text, subsequence: c.subsequence) == c.tier)
  }

  @Test(arguments: [
    TierCase(term: "zz", text: "kafka"),
    TierCase(term: "kafkas", text: "kafka"),
    TierCase(term: "rk", text: "kafka-retry"),
    TierCase(term: "kr", text: "kafka-retry", subsequence: false),
  ])
  func aTermWithNoTierGivesNil(_ c: TierCase) {
    #expect(SessionSearch.tier(c.term, in: c.text, subsequence: c.subsequence) == nil)
  }

  // MARK: Matching

  @Test(arguments: [("Résumé draft", "resume"), ("resume draft", "Résumé"), ("RESUME", "résumé")])
  func matchingIgnoresCaseAndDiacritics(_ name: String, _ query: String) {
    let sessions = [session("s", name: name), session("other")]

    #expect(ids(sessions, query) == ["s"])
  }

  @Test func everyTermMustMatch() {
    let sessions = [
      session("a", name: "kafka-retry"), session("b", name: "kafka-lag"), session("c", name: "retry-loop"),
    ]

    #expect(ids(sessions, "kafka retry") == ["a"])
  }

  @Test func aTermThatMatchesNothingGivesNoResults() {
    let sessions = [session("a", name: "kafka-retry"), session("b", name: "kafka-lag")]

    #expect(ids(sessions, "kafka zzz").isEmpty)
  }

  @Test func termsMayMatchDifferentFields() {
    let sessions = [
      session(
        "both", name: "queue-badge", repo: "/Users/me/dev/haacked/switchboard", pr: pr(217, repo: "haacked/switchboard")
      ),
      session("repoOnly", repo: "/Users/me/dev/haacked/switchboard"),
      session("prOnly", repo: "/Users/me/dev/acme/widgets", pr: pr(217, repo: "acme/widgets")),
    ]

    #expect(ids(sessions, "switchboard 217") == ["both"])
  }

  /// The repo label scores exact (100 × 8) and the PR number exact (100 × 9). A session's score sums each term's
  /// best hit only, not every hit, so the label's hit hides the weaker hit in `pr.repo`.
  @Test func aSessionScoresTheSumOfEachTermsBestHit() throws {
    let sessions = [
      session(
        "both", name: "queue-badge", repo: "/Users/me/dev/haacked/switchboard", pr: pr(217, repo: "haacked/switchboard")
      ),
      session("other", repo: "/Users/me/dev/acme/widgets"),
    ]

    let result = try #require(SessionSearch.rank(sessions, query: "switchboard 217").first)

    #expect(result.score == 1700)
  }

  @Test func aHashNumberMatchesThePRExactly() {
    let sessions = [session("s", name: "queue-badge", pr: pr(217)), session("other", pr: pr(21))]

    let results = SessionSearch.rank(sessions, query: "#217")

    #expect(results.map(\.id) == ["s"])
    #expect(results.first?.score == 900)
  }

  @Test func aBareNumberMatchesThePRExactly() {
    let sessions = [session("s", name: "queue-badge", pr: pr(217)), session("other", pr: pr(21))]

    let results = SessionSearch.rank(sessions, query: "217")

    #expect(results.map(\.id) == ["s"])
    #expect(results.first?.score == 900)
  }

  @Test func aPRNumberOutranksANameThatContainsTheNumber() {
    let sessions = [
      session("a", name: "a2170", lastActivity: 2),
      session("b", name: "queue-badge", pr: pr(217), lastActivity: 1),
    ]

    #expect(ids(sessions, "#217") == ["b", "a"])
  }

  @Test(arguments: ["141", "#141"])
  func anIssueNumberMatches(_ query: String) {
    let sessions = [session("s", issues: [12, 141]), session("other", issues: [14])]

    #expect(ids(sessions, query) == ["s"])
  }

  @Test func aBranchMatches() {
    let sessions = [session("s", branch: "haacked/fix-kafka-retry"), session("other", branch: "main")]

    #expect(ids(sessions, "kafka") == ["s"])
  }

  @Test func aPRTitleMatches() {
    let sessions = [session("s", pr: pr(5, title: "Show the merge queue badge")), session("other", pr: pr(6))]

    #expect(ids(sessions, "merge") == ["s"])
  }

  @Test func aGroupNameMatches() {
    let sessions = [session("s", group: "Merge queue"), session("other")]

    #expect(ids(sessions, "merge") == ["s"])
  }

  @Test func aReasonMatches() {
    let sessions = [session("s", reason: "Waiting on the deploy"), session("other", reason: "Working")]

    #expect(ids(sessions, "deploy") == ["s"])
  }

  @Test func aNoteMatches() {
    let sessions = [session("s", notes: ["Unrelated", "Ask about the queue badge"]), session("other")]

    #expect(ids(sessions, "badge") == ["s"])
  }

  @Test func theRepoMatchesWhenEverySessionIsInOneRepo() {
    let folder = "/Users/me/dev/haacked/switchboard"
    let sessions = [session("s1", repo: folder), session("s2", repo: folder), session("none")]

    #expect(Set(ids(sessions, "switchboard")) == ["s1", "s2"])
  }

  @Test func aResultCarriesTheRepoLabelWhenEverySessionIsInOneRepo() throws {
    let sessions = [session("s", repo: "/Users/me/dev/haacked/switchboard")]

    let result = try #require(SessionSearch.rank(sessions, query: "").first)

    #expect(result.repo == "switchboard")
  }

  @Test func thePRsOwnerAndNameMatch() {
    let sessions = [
      session("s", pr: pr(1, repo: "haacked/switchboard")), session("other", repo: "/Users/me/dev/acme/widgets"),
    ]

    #expect(ids(sessions, "haacked/switchboard") == ["s"])
  }

  /// `27` is a subsequence of 217 but not a substring, so only a gapped match would find the PR or issue.
  @Test(arguments: [
    (SessionSearch.Field.name, true), (.branch, true), (.repo, true), (.group, true),
    (.pr, false), (.issue, false), (.prTitle, false), (.reason, false), (.note, false),
  ])
  func subsequenceFollowsTheField(_ field: SessionSearch.Field, _ allowed: Bool) {
    let text = "fix-kafka-timeout"
    let target =
      switch field {
      case .name: session("s", name: text)
      case .branch: session("s", branch: text)
      case .repo: session("s", repo: "/Users/me/dev/o/\(text)")
      case .group: session("s", group: text)
      case .pr: session("s", pr: pr(217))
      case .issue: session("s", issues: [217])
      case .prTitle: session("s", pr: pr(5, title: text))
      case .reason: session("s", reason: text)
      case .note: session("s", notes: [text])
      }
    let query = field == .pr || field == .issue ? "27" : "fkt"

    #expect(ids([target, session("other")], query) == (allowed ? ["s"] : []))
  }

  /// `capped` shortens the label to `…ong-repository-name-for-tests` for the row.
  @Test func aLongRepoNameMatchesByItsStart() throws {
    let folder = "/Users/me/dev/acme/a-very-long-repository-name-for-tests"
    let sessions = [session("s", repo: folder), session("other")]

    let result = try #require(SessionSearch.rank(sessions, query: "a-very").first)

    #expect(ids(sessions, "a-very") == ["s"])
    #expect(result.repo == "…ong-repository-name-for-tests")
    #expect(result.hint == SessionSearch.Hit(field: .repo, text: "a-very-long-repository-name-for-tests"))
  }

  @Test func sessionsWithoutBranchPRGroupOrNotesStillMatchByName() {
    let sessions = [session("s", name: "kafka-retry"), session("other")]

    #expect(ids(sessions, "kafka") == ["s"])
  }

  enum Kind: CaseIterable, Sendable {
    case manager, chat, docketRow, unstartedFollowup

    func summary(named name: String) -> SessionSummary {
      var s = session("target", name: name)
      switch self {
      case .manager:
        s.manager = true
        s.kind = .manager
      case .chat:
        s.chat = "g1"
        s.kind = .chat
      case .docketRow:
        s.cwd = ""
        s.docket = DocketSummary(
          DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1"), DocketStatus())
      case .unstartedFollowup:
        s.state = .notStarted
        s.followup = Followup(prompt: "p")
        s.cwd = ""
      }
      return s
    }
  }

  @Test(arguments: Kind.allCases)
  func everyKindIsSearched(_ kind: Kind) {
    let sessions = [kind.summary(named: "nightly-check"), session("other")]

    #expect(ids(sessions, "nightly") == ["target"])
  }

  // MARK: Number terms

  @Test func aHashFollowedByDigitsAndALetterKeepsItsHash() {
    let sessions = [session("pr", pr: pr(21)), session("name", name: "fix-21a")]

    #expect(ids(sessions, "#21a").isEmpty)
  }

  @Test func aLoneHashMatchesNothing() {
    let sessions = [session("a", name: "kafka-retry", pr: pr(21)), session("b", issues: [3])]

    #expect(ids(sessions, "#").isEmpty)
  }

  // MARK: Order

  @Test func aNamePrefixOutranksANoteSubstring() {
    let sessions = [
      session("a", name: "alpha", notes: ["notkafka lag"], lastActivity: 2),
      session("z", name: "kafka-retry", lastActivity: 1),
    ]

    #expect(ids(sessions, "kafka") == ["z", "a"])
  }

  @Test func equalScoresGoToTheMostRecentActivity() {
    let sessions = [
      session("a", name: "kafka-alpha", lastActivity: 1), session("b", name: "kafka-beta", lastActivity: 2),
    ]

    #expect(ids(sessions, "kafka") == ["b", "a"])
  }

  /// The raw names sort "Kafka beta" first, because uppercase sorts before lowercase. Folded, alpha comes first.
  @Test func thenByName() {
    let sessions = [
      session("a", name: "Kafka beta", lastActivity: 1), session("b", name: "kafka alpha", lastActivity: 1),
    ]

    #expect(ids(sessions, "kafka") == ["b", "a"])
  }

  @Test func thenById() {
    let sessions = [
      session("b", name: "kafka-retry", lastActivity: 1), session("a", name: "kafka-retry", lastActivity: 1),
    ]

    #expect(ids(sessions, "kafka") == ["a", "b"])
  }

  @Test(arguments: ["", "   ", " \t "])
  func anEmptyQueryListsEverySessionByRecentActivity(_ query: String) {
    let sessions = [
      session("old", lastActivity: 1), session("new", lastActivity: 3), session("b", name: "same", lastActivity: 2),
      session("a", name: "same", lastActivity: 2), session("first", name: "Alpha", lastActivity: 2),
    ]

    #expect(ids(sessions, query) == ["new", "first", "a", "b", "old"])
  }

  // MARK: Hint

  @Test func aNoteMatchGivesANoteHint() throws {
    let sessions = [session("s", name: "badge-colors", notes: ["Unrelated", "Ask about the Queue badge"])]

    let result = try #require(SessionSearch.rank(sessions, query: "queue").first)

    #expect(result.hint == SessionSearch.Hit(field: .note, text: "Ask about the Queue badge"))
  }

  @Test func aPRTitleMatchGivesAPRHint() throws {
    let sessions = [session("s", pr: pr(5, title: "Show the Merge queue badge"))]

    let result = try #require(SessionSearch.rank(sessions, query: "merge").first)

    #expect(result.hint == SessionSearch.Hit(field: .prTitle, text: "Show the Merge queue badge"))
  }

  /// The row's issue badge names only the first issue.
  @Test(arguments: [
    ("12", SessionSearch.Hit?.none), ("141", SessionSearch.Hit(field: .issue, text: "141")),
  ])
  func aMatchOnALaterIssueGivesAnIssueHint(_ query: String, _ hint: SessionSearch.Hit?) throws {
    let sessions = [session("s", issues: [12, 141])]

    let result = try #require(SessionSearch.rank(sessions, query: query).first)

    #expect(result.hint == hint)
  }

  /// The row shows the label `widgets`, not the PR's `acme/widgets`.
  @Test(arguments: [
    ("widgets", SessionSearch.Hit?.none), ("acme", SessionSearch.Hit(field: .repo, text: "acme/widgets")),
  ])
  func aMatchOnThePRsOwnerGivesARepoHint(_ query: String, _ hint: SessionSearch.Hit?) throws {
    let sessions = [session("s", pr: pr(1, repo: "acme/widgets"))]

    let result = try #require(SessionSearch.rank(sessions, query: query).first)

    #expect(result.hint == hint)
  }

  /// The note also holds the term, so only the best field's place on the row decides.
  @Test func aNameMatchGivesNoHint() throws {
    let sessions = [session("s", name: "queue-badge", notes: ["Check the queue colors"])]

    let result = try #require(SessionSearch.rank(sessions, query: "queue").first)

    #expect(result.hint == nil)
  }

  /// The note's weight is lower than the group's, so the hint follows the order of the terms, not their weights.
  @Test(arguments: [
    ("kafka retry lag", SessionSearch.Hit(field: .note, text: "Retry after the deploy")),
    ("kafka lag retry", SessionSearch.Hit(field: .group, text: "Lag team")),
  ])
  func theHintComesFromTheFirstTermWhoseBestFieldIsHidden(_ query: String, _ hint: SessionSearch.Hit) throws {
    let sessions = [session("s", name: "kafka-fix", group: "Lag team", notes: ["Retry after the deploy"])]

    let result = try #require(SessionSearch.rank(sessions, query: query).first)

    #expect(result.hint == hint)
  }

  /// The PR title and the group have the same weight, and `searchable` adds the PR title first.
  @Test func aTieBetweenFieldsGoesToTheEarlierField() throws {
    let sessions = [session("s", pr: pr(5, title: "Queue badge"), group: "Queue work")]

    let result = try #require(SessionSearch.rank(sessions, query: "queue").first)

    #expect(result.hint == SessionSearch.Hit(field: .prTitle, text: "Queue badge"))
  }
}
