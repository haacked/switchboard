import Foundation
import Testing

@testable import SwitchboardCore

private let own = "acme/widgets"

private func ref(_ number: Int, _ repo: String? = own) -> IssueRef { IssueRef(repo: repo, number: number) }

private func closing(_ body: String) -> [IssueRef]? { Issues.closingRefs(inBody: body, repo: own) }

/// `samplePR()` (acme/widgets#42) with the closing refs that its body gave.
private func pr(closes: [IssueRef]? = nil, repo: String = own, number: Int = 42) -> PullRequest {
  var pr = samplePR()
  pr.repo = repo
  pr.number = number
  pr.closesIssues = closes
  return pr
}

private func issueURL(_ repo: String, _ number: Int) -> String { "https://github.com/\(repo)/issues/\(number)" }

/// Repos that a stored `pr` event or session row can carry, and that no
/// issue link may be built from.
private let badRepos = [
  "../../x", "a/b/c", "javascript:x", "", "./x", "x/..", "../x", "x/.", "a/", "/b", "acme/widgets\n",
]

@Suite struct IssueRefParsing {
  @Test(arguments: [
    ("123", IssueRef(repo: nil, number: 123)),
    ("#123", IssueRef(repo: nil, number: 123)),
    ("PostHog/posthog#123", IssueRef(repo: "PostHog/posthog", number: 123)),
    ("PostHog/posthog.com#20992", IssueRef(repo: "PostHog/posthog.com", number: 20992)),
    ("https://github.com/PostHog/posthog/issues/123", IssueRef(repo: "PostHog/posthog", number: 123)),
    ("https://github.com/PostHog/posthog/issues/123/", IssueRef(repo: "PostHog/posthog", number: 123)),
    ("https://github.com/PostHog/posthog/issues/123/timeline", IssueRef(repo: "PostHog/posthog", number: 123)),
    ("https://github.com/PostHog/posthog/issues/123#issuecomment-1", IssueRef(repo: "PostHog/posthog", number: 123)),
    ("https://github.com/PostHog/posthog/issues/123?q=1", IssueRef(repo: "PostHog/posthog", number: 123)),
    ("999999999", IssueRef(repo: nil, number: 999_999_999)),
  ])
  func readsEachAcceptedForm(_ text: String, _ expected: IssueRef) {
    #expect(IssueRef(parsing: text) == expected)
  }

  @Test(arguments: [
    "https://github.com/PostHog/posthog/pull/123",
    "https://github.com/PostHog/posthog/pull/123/files",
    "https://gitlab.com/PostHog/posthog/issues/123",
    "https://github.com.evil.com/PostHog/posthog/issues/123",
    "https://github.com/PostHog/issues/123",
    "https://github.com/PostHog/posthog/issues/",
    "https://github.com/PostHog/posthog/issues/abc",
    "file:///tmp/PostHog/posthog/issues/123",
    "owner#1",
    "a/b/c#1",
    "/b#1",
    "a/#1",
    "#0",
    "0",
    "#-1",
    "-1",
    "#1a",
    "1a",
    "#",
    "#1234567890",
    "1234567890",
    "#99999999999999999999999",
    "nonsense",
    "",
  ])
  func rejectsEverythingElse(_ text: String) {
    #expect(IssueRef(parsing: text) == nil)
  }

  @Test func refRoundTrips() throws {
    let r = ref(174, "PostHog/posthog")

    #expect(try JSONCoding.decode(IssueRef.self, from: try JSON(encoding: r).text) == r)
  }
}

@Suite struct IssueClosingKeywords {
  static let keywords = ["close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved"]

  /// Each keyword in lower, title, upper, and alternating case, such as `ClOsEs`.
  static let casedKeywords = keywords.flatMap { word in
    [
      word, word.capitalized, word.uppercased(),
      String(word.enumerated().map { $0.offset.isMultiple(of: 2) ? Character($0.element.uppercased()) : $0.element }),
    ]
  }

  @Test(arguments: casedKeywords)
  func eachKeywordInAnyCaseGivesItsRef(_ keyword: String) {
    #expect(closing("\(keyword) #5") == [ref(5)])
  }

  @Test(arguments: keywords)
  func eachKeywordTakesAnOptionalColon(_ keyword: String) {
    #expect(closing("\(keyword.capitalized): #5") == [ref(5)])
  }

  @Test(arguments: [
    ("Fixes #5", [ref(5)]),
    ("Fixes #5.", [ref(5)]),
    ("Fixes  #5", [ref(5)]),
    ("Fixes\t#5", [ref(5)]),
    ("(fixes #5)", [ref(5)]),
    ("- Fixes #5", [ref(5)]),
    ("This fixes #5 in the cache.", [ref(5)]),
    ("Fixes PostHog/charts#9", [ref(9, "PostHog/charts")]),
    ("Fixes PostHog/posthog.com#20992", [ref(20992, "PostHog/posthog.com")]),
    ("Fixes https://github.com/PostHog/charts/issues/9", [ref(9, "PostHog/charts")]),
    ("Fixes https://github.com/PostHog/charts/issues/9/", [ref(9, "PostHog/charts")]),
    ("Fixes https://github.com/PostHog/charts/issues/9/timeline", [ref(9, "PostHog/charts")]),
    ("Fixes https://github.com/PostHog/charts/issues/9#issuecomment-123", [ref(9, "PostHog/charts")]),
    ("Fixes https://github.com/PostHog/charts/issues/9?q=1", [ref(9, "PostHog/charts")]),
    ("Fixes #999999999", [ref(999_999_999)]),
  ])
  func keywordGivesTheRefInEachForm(_ body: String, _ expected: [IssueRef]) {
    #expect(closing(body) == expected)
  }

  @Test(arguments: [
    "Fixes https://github.com/PostHog/charts/pull/9",
    "Fixes https://gitlab.com/PostHog/charts/issues/9",
    "Fixes https://github.com.evil.com/PostHog/charts/issues/9",
    "Fixes https://evil.com/https://github.com/PostHog/charts/issues/9",
    "Fixes a/b/c#3",
    "prefixes #3",
    "unfixed #3",
    "2fixes #3",
    "fixesx #3",
    "fixes#3",
    "Fixes:#3",
    "fixes the #12 bug",
    "Fixes #0",
    "Fixes #1234567890",
    "Fixes #99999999999999999999999",
    "Fixes",
    "Fixes #",
    "See #3",
    "",
  ])
  func textThatIsNotAKeywordAndARefGivesNothing(_ body: String) {
    #expect(closing(body) == nil)
  }

  @Test func onlyTheRefRightAfterTheKeywordCounts() {
    #expect(closing("Fixes #1, #2") == [ref(1)])
  }

  @Test func eachKeywordGivesItsOwnRef() {
    #expect(closing("Fixes #1 and fixes #2") == [ref(1), ref(2)])
  }

  @Test func refsKeepTheBodysOrder() {
    #expect(closing("Closes #9\nFixes PostHog/charts#2\nResolves #3") == [ref(9), ref(2, "PostHog/charts"), ref(3)])
  }

  @Test func repeatsCollapseToTheFirst() {
    #expect(closing("Fixes #1\nFixes #2\nCloses #1") == [ref(1), ref(2)])
  }

  @Test(arguments: [
    "Fixes #5\nCloses acme/widgets#5",
    "Fixes #5\nCloses ACME/Widgets#5",
    "Fixes #5\nCloses https://github.com/acme/widgets/issues/5",
  ])
  func aRefToThePRsRepoRepeatsTheShortForm(_ body: String) {
    #expect(closing(body)?.map(\.number) == [5])
  }

  @Test func repeatsThatDifferOnlyInTheRepoCaseCollapseToTheFirstSpelling() {
    #expect(closing("Fixes PostHog/Charts#9\nCloses posthog/charts#9") == [ref(9, "PostHog/Charts")])
  }

  @Test(arguments: [
    "Fixes #174\r\nCloses PostHog/charts#9\r\n",
    "Fixes #174\nCloses PostHog/charts#9\n",
  ])
  func lineEndsDoNotMatter(_ body: String) {
    #expect(closing(body) == [ref(174), ref(9, "PostHog/charts")])
  }

  @Test(arguments: [
    "<!-- Closes #123 -->",
    "<!--\nFixes #1\n-->",
    "<!--\r\nFixes #1\r\n-->",
    "```\nFixes #1\n```",
    "~~~\nFixes #1\n~~~",
    "```swift\nFixes #1\n```",
    "```\r\nFixes #1\r\n```",
  ])
  func refInACommentOrFenceGivesNothing(_ body: String) {
    #expect(closing(body) == nil)
  }

  @Test(arguments: [
    "<!-- Fixes #1 -->\nFixes #2",
    "<!--\nFixes #1\n-->\nFixes #2",
    "<!-- Fixes #1 --> Fixes #2",
    "```\nFixes #1\n```\nFixes #2",
    "~~~\nFixes #1\n~~~\nFixes #2",
    "```\r\nFixes #1\r\n```\r\nFixes #2",
  ])
  func refAfterAClosedCommentOrFenceCounts(_ body: String) {
    #expect(closing(body) == [ref(2)])
  }

  @Test(arguments: [
    "Fixes #2\n<!-- Fixes #1\nFixes #3",
    "Fixes #2\n```\nFixes #1\nFixes #3",
    "Fixes #2\n~~~\nFixes #1\nFixes #3",
  ])
  func unclosedCommentOrFenceHidesTheRestOfTheBody(_ body: String) {
    #expect(closing(body) == [ref(2)])
  }

  @Test func thePlanExampleGivesBothRefsAndSkipsTheComment() {
    #expect(
      closing("Fixes #174\r\nCloses PostHog/charts#9\r\n<!-- Fixes #1 -->") == [ref(174), ref(9, "PostHog/charts")])
  }
}

@Suite struct BranchIssueNumber {
  @Test(arguments: [
    ("haacked/123-fix-cache", 123),
    ("123-fix", 123),
    ("haacked/174-issue-in-tile", 174),
    ("a/b/123-x", 123),
    ("haacked/123-Fix", 123),
    ("haacked/999999999-x", 999_999_999),
  ])
  func leadingNumberOfTheLastSegmentIsTheIssue(_ branch: String, _ expected: Int) {
    #expect(Issues.branchNumber(branch, prNumber: nil) == expected)
  }

  @Test(arguments: [
    "haacked/fix-123",
    "haacked/123",
    "123",
    "release/2026-11-10",
    "2026-11-10-notes",
    "haacked/v2-thing",
    "1.2-fix",
    "haacked/1.2-fix",
    "haacked/0-x",
    "haacked/1234567890-x",
    "haacked/99999999999999999999-x",
    "haacked/123abc",
    "haacked/123_fix",
    "haacked/123-",
    "haacked/123--x",
    "haacked/123-é",
    "haacked/١٢٣-x",
    "123-x/fix",
    "haacked/",
    "main",
    "",
  ])
  func branchWithoutALeadingIssueNumberGivesNothing(_ branch: String) {
    #expect(Issues.branchNumber(branch, prNumber: nil) == nil)
  }

  @Test func detachedHeadGivesNothing() {
    #expect(Issues.branchNumber(nil, prNumber: nil) == nil)
  }

  @Test func branchThatNamesItsOwnPRGivesNothing() {
    #expect(Issues.branchNumber("haacked/122896-stacked", prNumber: 122896) == nil)
  }

  @Test func branchWhoseNumberDiffersFromThePRsGivesTheNumber() {
    #expect(Issues.branchNumber("haacked/123-fix-cache", prNumber: 122896) == 123)
  }
}

@Suite struct ShownIssues {
  @Test func overrideReplacesTheBodyAndTheBranch() {
    let shown = Issues.shown(
      set: ref(5, "PostHog/charts"), pr: pr(closes: [ref(174)]), branch: "haacked/123-fix-cache")

    #expect(shown == [SessionIssue(repo: "PostHog/charts", number: 5, via: .set, url: issueURL("PostHog/charts", 5))])
  }

  @Test func overrideWithoutARepoTakesThePRsRepo() {
    let shown = Issues.shown(set: ref(5, nil), pr: pr(), branch: nil)

    #expect(shown == [SessionIssue(repo: own, number: 5, via: .set, url: issueURL(own, 5))])
  }

  @Test func overrideWithoutARepoOrAPRHasNoLink() {
    let shown = Issues.shown(set: ref(5, nil), pr: nil, branch: "haacked/123-fix-cache")

    #expect(shown == [SessionIssue(repo: nil, number: 5, via: .set, url: nil)])
  }

  @Test func bodyRefsBeatTheBranch() {
    let shown = Issues.shown(
      set: nil, pr: pr(closes: [ref(174), ref(9, "PostHog/charts")]), branch: "haacked/123-fix-cache")

    #expect(
      shown == [
        SessionIssue(repo: own, number: 174, via: .body, url: issueURL(own, 174)),
        SessionIssue(repo: "PostHog/charts", number: 9, via: .body, url: issueURL("PostHog/charts", 9)),
      ])
  }

  @Test func branchWithAPRTakesItsRepoAndLink() {
    let shown = Issues.shown(set: nil, pr: pr(), branch: "haacked/123-fix-cache")

    #expect(shown == [SessionIssue(repo: own, number: 123, via: .branch, url: issueURL(own, 123))])
  }

  @Test func branchWithoutAPRHasNoLink() {
    let shown = Issues.shown(set: nil, pr: nil, branch: "haacked/123-fix-cache")

    #expect(shown == [SessionIssue(repo: nil, number: 123, via: .branch, url: nil)])
  }

  /// A `pr` event that an older or a buggy sbd recorded can hold an empty list.
  @Test func emptyBodyRefsFallBackToTheBranch() {
    let shown = Issues.shown(set: nil, pr: pr(closes: []), branch: "haacked/123-fix-cache")

    #expect(shown?.map(\.via) == [.branch])
  }

  @Test func branchThatNamesThePRGivesNothing() {
    #expect(Issues.shown(set: nil, pr: pr(number: 123), branch: "haacked/123-fix-cache") == nil)
  }

  @Test(arguments: [nil, "main", "haacked/fix-cache"] as [String?])
  func noSourceGivesNothing(_ branch: String?) {
    #expect(Issues.shown(set: nil, pr: nil, branch: branch) == nil)
    #expect(Issues.shown(set: nil, pr: pr(), branch: branch) == nil)
  }

  @Test(arguments: badRepos)
  func bodyRefWhoseRepoIsNotAnOwnerAndNameKeepsItsNumberWithoutALink(_ repo: String) throws {
    let shown = try #require(Issues.shown(set: nil, pr: pr(closes: [ref(3, repo)]), branch: nil))

    #expect(shown.map(\.number) == [3])
    #expect(shown.map(\.via) == [.body])
    #expect(shown.allSatisfy { $0.url == nil && $0.link == nil })
  }

  /// A `pr` event's JSON can carry any repo, because any local process can record one.
  @Test(arguments: badRepos)
  func bodyRefDecodedFromAPREventWithABadRepoHasNoLink(_ repo: String) throws {
    var object = try #require(try JSON(encoding: samplePR()).object)
    object["closesIssues"] = [["repo": .string(repo), "number": 3]]
    let decoded = try JSONCoding.decode(PullRequest.self, from: JSON.object(object).text)

    let shown = try #require(Issues.shown(set: nil, pr: decoded, branch: nil))

    #expect(shown.map(\.number) == [3])
    #expect(shown.allSatisfy { $0.url == nil })
  }

  @Test(arguments: badRepos)
  func overrideWhoseRepoIsNotAnOwnerAndNameHasNoLink(_ repo: String) throws {
    let shown = try #require(Issues.shown(set: ref(5, repo), pr: pr(), branch: nil))

    #expect(shown.map(\.number) == [5])
    #expect(shown.map(\.via) == [.set])
    #expect(shown.allSatisfy { $0.url == nil })
  }

  @Test(arguments: badRepos)
  func overrideWithoutARepoOnAPRWithABadRepoHasNoLink(_ repo: String) throws {
    let shown = try #require(Issues.shown(set: ref(5, nil), pr: pr(repo: repo), branch: nil))

    #expect(shown.map(\.number) == [5])
    #expect(shown.allSatisfy { $0.url == nil })
  }

  @Test(arguments: badRepos)
  func branchIssueOnAPRWithABadRepoHasNoLink(_ repo: String) throws {
    let shown = try #require(Issues.shown(set: nil, pr: pr(repo: repo), branch: "haacked/123-fix-cache"))

    #expect(shown.map(\.number) == [123])
    #expect(shown.allSatisfy { $0.url == nil })
  }
}

@Suite struct IssueRepoCheck {
  @Test(arguments: ["PostHog/posthog", "PostHog/posthog.com", "a-b/c_d", "haacked/switchboard", "x/.github"])
  func ownerAndNameIsValid(_ repo: String) {
    #expect(Issues.validRepo(repo))
  }

  @Test(
    arguments: badRepos + ["a b/c", "a/b c", "a/b?c", "a/b#c", "https://github.com/a/b", ".", "..", "./..", "../.."])
  func anythingElseIsInvalid(_ repo: String) {
    #expect(!Issues.validRepo(repo))
  }
}

@Suite struct SessionIssueLink {
  @Test(arguments: [
    "file:///tmp/x", "http://github.com/acme/widgets/issues/1", "javascript:alert(1)", "",
    "github.com/acme/widgets/issues/1",
  ])
  func linkIsNilUnlessTheURLIsHttps(_ url: String) throws {
    let json: JSON = ["repo": .string(own), "number": 1, "via": "body", "url": .string(url)]

    let issue = try JSONCoding.convert(json, to: SessionIssue.self)

    #expect(issue.link == nil)
  }

  @Test func linkOpensTheIssuePage() throws {
    let issue = SessionIssue(repo: own, number: 1, via: .body, url: issueURL(own, 1))

    #expect(issue.link == URL(string: "https://github.com/acme/widgets/issues/1"))
  }

  @Test func issueWithoutAURLHasNoLink() {
    #expect(SessionIssue(repo: nil, number: 1, via: .branch, url: nil).link == nil)
  }

  @Test(arguments: [own, "ACME/Widgets"])
  func issueInThePRsRepoIsLabeledByNumber(_ prRepo: String) {
    #expect(SessionIssue(repo: own, number: 174, via: .body, url: nil).label(from: prRepo) == "#174")
  }

  @Test func issueWithoutARepoIsLabeledByNumber() {
    #expect(SessionIssue(repo: nil, number: 174, via: .branch, url: nil).label(from: own) == "#174")
    #expect(SessionIssue(repo: nil, number: 174, via: .branch, url: nil).label(from: nil) == "#174")
  }

  @Test func issueInAnotherRepoIsLabeledWithItsRepo() {
    #expect(
      SessionIssue(repo: "PostHog/charts", number: 9, via: .body, url: nil).label(from: own) == "PostHog/charts#9")
  }

  @Test func issueWithARepoAndNoPRIsLabeledWithItsRepo() {
    #expect(SessionIssue(repo: "PostHog/charts", number: 9, via: .set, url: nil).label(from: nil) == "PostHog/charts#9")
  }
}

@Suite struct IssueCoding {
  @Test(arguments: [(SessionIssue.Via.set, "set"), (.body, "body"), (.branch, "branch")])
  func viaEncodesAsItsName(_ via: SessionIssue.Via, _ name: String) throws {
    let json = try JSON(encoding: SessionIssue(repo: own, number: 1, via: via, url: nil))

    #expect(json["via"]?.string == name)
  }

  @Test(arguments: [
    SessionIssue(repo: own, number: 174, via: .body, url: issueURL(own, 174)),
    SessionIssue(repo: nil, number: 123, via: .branch, url: nil),
    SessionIssue(repo: "PostHog/charts", number: 5, via: .set, url: issueURL("PostHog/charts", 5)),
  ])
  func sessionIssueRoundTrips(_ issue: SessionIssue) throws {
    #expect(try JSONCoding.decode(SessionIssue.self, from: try JSON(encoding: issue).text) == issue)
  }

  @Test func linkAndLabelAreNotEncoded() throws {
    let json = try JSON(encoding: SessionIssue(repo: own, number: 174, via: .body, url: issueURL(own, 174)))

    #expect(Set(try #require(json.object).keys) == ["repo", "number", "via", "url"])
  }

  @Test func pullRequestKeepsItsClosesIssues() throws {
    let p = pr(closes: [ref(174), ref(9, "PostHog/charts")])

    let decoded = try JSONCoding.decode(PullRequest.self, from: try JSON(encoding: p).text)

    #expect(decoded.closesIssues == [ref(174), ref(9, "PostHog/charts")])
  }

  /// A PR without refs encodes as it did before, so the first poll after an
  /// upgrade records no new `pr` event for it.
  @Test func pullRequestWithoutClosingRefsOmitsTheField() throws {
    #expect(try JSON(encoding: samplePR())["closesIssues"] == nil)
  }

  @Test func pullRequestThatAnOlderSbdRecordedHasNoClosesIssues() throws {
    var object = try #require(try JSON(encoding: pr(closes: [ref(174)])).object)
    object["closesIssues"] = nil

    let decoded = try JSONCoding.decode(PullRequest.self, from: JSON.object(object).text)

    #expect(decoded.closesIssues == nil)
  }

  @Test func pullRequestInitTakesClosesIssuesLast() {
    let p = PullRequest(id: "PR_1", number: 1, url: "u", repo: own, closesIssues: [ref(2)])

    #expect(p.closesIssues == [ref(2)])
  }

  @Test func aSessionThatAnOlderSbdStoredHasNoIssue() throws {
    let json = #"{"id":"s1","name":"one","cwd":"/a","claudeSessionId":"u1","created":5,"started":true,"done":false}"#

    #expect(try JSONCoding.decode(Session.self, from: json).issue == nil)
  }

  @Test func sessionKeepsItsIssue() throws {
    var s = Session(id: "s1", name: "one", cwd: "/a", claudeSessionId: "u1", created: 5)
    s.issue = ref(5, "PostHog/charts")

    let decoded = try JSONCoding.decode(Session.self, from: try JSON(encoding: s).text)

    #expect(decoded.issue == ref(5, "PostHog/charts"))
  }

  @Test func aSummaryFromAnOlderSbdHasNoIssues() throws {
    var object = try #require(try JSON(encoding: issueSummary()).object)
    object["issues"] = nil

    let decoded = try JSONCoding.decode(SessionSummary.self, from: JSON.object(object).text)

    #expect(decoded.issues == nil)
  }

  @Test func summaryWithoutIssuesOmitsTheField() throws {
    #expect(try JSON(encoding: issueSummary())["issues"] == nil)
  }

  @Test func summaryCarriesItsIssues() throws {
    var s = issueSummary()
    s.issues = [SessionIssue(repo: own, number: 174, via: .body, url: issueURL(own, 174))]

    let decoded = try JSONCoding.decode(SessionSummary.self, from: try JSON(encoding: s).text)

    #expect(decoded.issues == s.issues)
  }
}

private func issueSummary() -> SessionSummary {
  SessionSummary(
    id: "s1", name: "s1", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "s1", state: .working, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
}
