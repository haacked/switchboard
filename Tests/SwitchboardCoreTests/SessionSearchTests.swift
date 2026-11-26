import Testing

@testable import SwitchboardCore

private func session(
  _ id: String, name: String? = nil, repo: String? = nil, branch: String? = nil, pr: PRSummary? = nil,
  issues: [Int] = [], group: String? = nil, reason: String = "", notes: [String] = [], lastActivity: Int64 = 0,
  earlierPRs: [Int] = []
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: name ?? id, cwd: repo ?? "/tmp", repo: repo, branch: branch, claudeSessionId: id, state: .working,
    reason: reason, since: 0, lastActivity: lastActivity, live: true, claudePid: nil, attached: false, lastReply: nil,
    waits: [], notes: notes.enumerated().map { Note(id: "n\($0.offset)", text: $0.element, by: .you, t: 0) }, pr: pr)
  s.issues = issues.isEmpty ? nil : issues.map { SessionIssue(repo: "o/r", number: $0, via: .set) }
  s.earlierPRs = earlierPRs.isEmpty ? nil : earlierPRs
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

private func ids(
  _ sessions: [SessionSummary], _ query: String, transcripts: [String: SessionSearch.Transcript] = [:]
) -> [String] {
  SessionSearch.rank(sessions, query: query, transcripts: transcripts).map(\.id)
}

private func transcript(_ messages: [String]) -> SessionSearch.Transcript { SessionSearch.Transcript(messages) }

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
    (.pr, false), (.issue, false), (.prTitle, false), (.reason, false), (.note, false), (.transcript, false),
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
      case .transcript: session("s")
      }
    let transcripts = field == .transcript ? ["s": transcript([text])] : [:]
    let query = field == .pr || field == .issue ? "27" : "fkt"

    #expect(ids([target, session("other")], query, transcripts: transcripts) == (allowed ? ["s"] : []))
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

  /// The row shows only the current PR's number.
  @Test(arguments: [
    ("135173", SessionSearch.Hit(field: .pr, text: "135173")),
    ("#135173", SessionSearch.Hit(field: .pr, text: "135173")),
    ("136787", nil), ("#136787", nil),
  ])
  func aMatchOnAnEarlierPRGivesAPRHint(_ query: String, _ hint: SessionSearch.Hit?) throws {
    let sessions = [session("s", pr: pr(136787), earlierPRs: [135173]), session("other", pr: pr(136788))]

    let result = try #require(SessionSearch.rank(sessions, query: query).first)

    #expect(result.id == "s")
    #expect(result.hint == hint)
  }

  @Test func anEarlierPRMatchesASessionWithNoCurrentPR() {
    let sessions = [session("s", earlierPRs: [135173, 136787]), session("other", pr: pr(136788))]

    #expect(ids(sessions, "136787") == ["s"])
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

  // MARK: Transcripts

  @Test func theTranscriptFieldIsHiddenFromTheRowAndTitledTranscript() {
    #expect(!SessionSearch.Field.transcript.shownOnRow)
    #expect(SessionSearch.Field.transcript.title == "Transcript")
  }

  /// Every transcript match scores substring (40) at weight 1, whether the message is the term or holds it inside a
  /// word.
  @Test(arguments: [("kafka", 40), ("Ask about notkafka lag", 40)])
  func aTranscriptMatchScoresSubstringAtWeightOne(_ message: String, _ score: Int) throws {
    let sessions = [session("s"), session("other")]

    let result = try #require(
      SessionSearch.rank(sessions, query: "kafka", transcripts: ["s": transcript([message])]).first)

    #expect(result.id == "s")
    #expect(result.score == score)
  }

  @Test func aTermFoundOnlyInATranscriptFindsTheSession() {
    let sessions = [session("s", name: "cache plan"), session("other", name: "deploy")]
    let transcripts = ["s": transcript(["How do I tune the Kafka consumer?", "Raise the batch size."])]

    #expect(ids(sessions, "kafka", transcripts: transcripts) == ["s"])
  }

  @Test(arguments: [("Résumé parser", "resume"), ("resume parser", "RÉSUMÉ"), ("RESUME", "résumé")])
  func aTranscriptMatchIgnoresCaseAndDiacritics(_ message: String, _ query: String) {
    let sessions = [session("s"), session("other")]

    #expect(ids(sessions, query, transcripts: ["s": transcript([message])]) == ["s"])
  }

  /// Each field's weakest hit beats a transcript hit of 40: a name subsequence (200), a reason substring
  /// (200), a note substring (160), and a group subsequence (140). The transcript's session has the newer
  /// activity, so only the score can put it last.
  @Test(arguments: [
    session("other", name: "k-a-f-k-a", lastActivity: 1),
    session("other", reason: "xkafkax", lastActivity: 1),
    session("other", notes: ["xkafkax"], lastActivity: 1),
    session("other", group: "k-a-f-k-a", lastActivity: 1),
  ])
  func aMatchInAnyOtherFieldOutranksATranscriptMatch(_ other: SessionSummary) {
    let sessions = [session("t", lastActivity: 9), other]

    #expect(ids(sessions, "kafka", transcripts: ["t": transcript(["kafka"])]) == ["other", "t"])
  }

  @Test func termsMayMatchTheNameAndTheTranscript() {
    let sessions = [
      session("both", name: "cache plan"), session("nameOnly", name: "cache keys"),
      session("transcriptOnly", name: "deploy"),
    ]
    let transcripts = [
      "both": transcript(["Check the Kafka lag first."]), "transcriptOnly": transcript(["Kafka is slow today."]),
    ]

    #expect(ids(sessions, "cache kafka", transcripts: transcripts) == ["both"])
  }

  @Test func aTranscriptTermAndATermThatMatchesNothingGiveNoResults() {
    let sessions = [session("s", name: "cache plan")]

    #expect(ids(sessions, "kafka zzz", transcripts: ["s": transcript(["Kafka lag"])]).isEmpty)
  }

  @Test func aNameTermAndATranscriptTermGiveATranscriptHint() throws {
    let sessions = [session("s", name: "cache plan")]

    let result = try #require(
      SessionSearch.rank(sessions, query: "cache kafka", transcripts: ["s": transcript(["Check the Kafka lag."])])
        .first)

    #expect(result.hint?.field == .transcript)
  }

  /// The note also holds the term and scores higher, so the hint names the note.
  @Test func aNoteMatchHidesATranscriptMatchOfTheSameTerm() throws {
    let sessions = [session("s", notes: ["Ask about the kafka lag"])]

    let result = try #require(
      SessionSearch.rank(sessions, query: "kafka", transcripts: ["s": transcript(["kafka"])]).first)

    #expect(result.hint == SessionSearch.Hit(field: .note, text: "Ask about the kafka lag"))
  }

  @Test func theHintComesFromTheFirstMatchingMessage() throws {
    let sessions = [session("s")]
    let transcripts = ["s": transcript(["No match here", "Ask about notkafka lag", "kafka"])]

    let result = try #require(SessionSearch.rank(sessions, query: "kafka", transcripts: transcripts).first)

    #expect(result.hint == SessionSearch.Hit(field: .transcript, text: "Ask about notkafka lag"))
  }

  @Test func aTranscriptForASessionThatIsNotListedIsIgnored() {
    let sessions = [session("a", name: "cache plan"), session("b", name: "deploy")]

    #expect(ids(sessions, "kafka", transcripts: ["gone": transcript(["kafka"])]).isEmpty)
    #expect(
      SessionSearch.rank(sessions, query: "cache", transcripts: ["gone": transcript(["cache"])])
        == SessionSearch.rank(sessions, query: "cache"))
  }

  @Test(arguments: ["", "kafka", "badge", "zzz"])
  func transcriptsThatMatchNoTermChangeNothing(_ query: String) {
    let sessions = [
      session("a", name: "kafka-retry", lastActivity: 3), session("b", name: "queue-badge", lastActivity: 2),
    ]
    let transcripts = ["a": transcript(["Unrelated words"]), "b": transcript(["Nothing here", "Or here"])]

    #expect(
      SessionSearch.rank(sessions, query: query, transcripts: transcripts) == SessionSearch.rank(sessions, query: query)
    )
  }

  // MARK: Transcript hint window

  /// Words of several lengths, so a window that starts mid-word shows.
  static let filler = String(repeating: "alpha be gamma delta epsilon zeta ", count: 20)

  private func hint(_ message: String, query: String = "kafka") throws -> SessionSearch.Hit {
    try #require(
      SessionSearch.rank([session("s")], query: query, transcripts: ["s": transcript([message])]).first?.hint)
  }

  @Test func aMatchDeepInALongMessageShowsTheTermInTheFirst90Characters() throws {
    let message = Self.filler + "the Kafka retry plan needs review " + Self.filler
    try #require(message.distance(from: message.startIndex, to: message.range(of: "Kafka")!.lowerBound) > 500)

    let hint = try self.hint(message)

    #expect(hint.field == .transcript)
    #expect(hint.text.prefix(90).contains("Kafka"))
  }

  @Test func aWindowThatCutsTheStartBeginsWithAnEllipsisAtAWordBoundary() throws {
    let message = Self.filler + "the Kafka retry plan needs review"

    let hint = try self.hint(message)

    #expect(hint.text.hasPrefix("…"))
    let shown = String(hint.text.dropFirst())
    let start = try #require(message.range(of: shown)?.lowerBound)
    let before = message[message.index(before: start)]
    #expect(!before.isLetter && !before.isNumber, "\(hint.text)")
    #expect(shown.first.map { !$0.isWhitespace } ?? false, "\(hint.text)")
  }

  /// "Up to about 30 characters before the match" leaves room for the word that the boundary keeps.
  @Test func aWindowShowsOnlyAShortStretchBeforeTheMatch() throws {
    let message = Self.filler + "the Kafka retry plan needs review"

    let hint = try self.hint(message)

    let offset = try #require(hint.text.range(of: "Kafka")).lowerBound
    #expect(hint.text.distance(from: hint.text.startIndex, to: offset) <= 40, "\(hint.text)")
  }

  @Test func aMatchAtTheStartOfTheMessageShowsTheMessageFromItsStart() throws {
    let message = "Kafka retry plan: " + Self.filler

    let hint = try self.hint(message)

    #expect(hint.text.hasPrefix("Kafka retry plan"))
  }

  @Test func aMatchNearTheStartIsNotCut() throws {
    let message = "Please look at the Kafka lag before " + Self.filler

    let hint = try self.hint(message)

    #expect(hint.text.hasPrefix("Please look at the Kafka"))
  }

  /// The window comes from the unfolded message, so it shows the message's own spelling of the term.
  @Test(arguments: [("résumé", "resume"), ("KAFKA", "kafka"), ("kafka", "KAFKA"), ("Ångström", "angstrom")])
  func aDeepMatchWithADifferentCaseOrDiacriticShowsTheMessagesSpelling(_ spelled: String, _ query: String) throws {
    let message = Self.filler + "check the \(spelled) parser " + Self.filler

    let hint = try self.hint(message, query: query)

    #expect(hint.text.prefix(90).contains(spelled), "\(hint.text)")
  }

  /// Folding can change a string's length, as ß to ss and the ﬁ ligature to fi. A window placed by an index into
  /// the folded text would then point at the wrong place in the message.
  @Test(arguments: ["Straße ", "ﬁle "])
  func aDeepMatchAfterCharactersThatFoldToADifferentLengthShowsTheTerm(_ word: String) throws {
    let message = String(repeating: word, count: 120) + "the Kafka retry plan " + Self.filler
    try #require(
      message.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).count != message.count)

    let hint = try self.hint(message)

    #expect(hint.text.prefix(90).contains("Kafka"), "\(hint.text)")
  }

  /// "off" matches part of the folded "ffi" of the ligature in "oﬃce", which a search of the message itself does not
  /// find. The hint then shows the folded text around the match.
  @Test func aMatchInsideALigatureShowsTheFoldedTextAroundIt() throws {
    let message = String(repeating: "alpha beta ", count: 60) + "oﬃce"

    let hint = try self.hint(message, query: "off")

    #expect(hint.text.prefix(90).contains("office"), "\(hint.text)")
  }
}
