import Foundation
import Testing

@testable import SwitchboardCore

/// A recorded PR node with some top-level fields replaced.
private func editedNode(_ number: Int, _ fields: [String: JSON]) throws -> JSON {
  var node = try #require(GitHubFixtures.statusNode(number)?.object)
  for (key, value) in fields { node[key] = value }
  return .object(node)
}

/// One node of a branch lookup's pullRequests.
private func pull(_ id: String, _ state: String, _ owner: String?) -> JSON {
  ["id": .string(id), "state": .string(state), "headRepositoryOwner": owner.map { ["login": .string($0)] } ?? .null]
}

/// The node id that `parseLookup` gives each key of a response with `data`.
private func lookup(_ data: JSON, _ keys: [PRKey]) -> [String?] {
  let found = GitHub.parseLookup(["data": data], keys)
  return keys.map { found[$0] ?? nil }
}

private func baseRef(tip: String, merged: [JSON]) -> JSON {
  ["target": ["oid": .string(tip)], "associatedPullRequests": ["nodes": .array(merged)]]
}

private func commentNode(_ id: String, _ author: String?, _ createdAt: String) -> JSON {
  [
    "id": .string(id), "author": author.map { ["login": .string($0)] } ?? .null, "createdAt": .string(createdAt),
    "lastEditedAt": .null, "includesCreatedEdit": false,
  ]
}

@Suite struct GitHubParsing {
  @Test(arguments: GitHubFixtures.statusPRs)
  func parsesEachRecordedPR(_ expected: PullRequest) throws {
    let node = try #require(GitHubFixtures.statusNode(expected.number))

    let parsed = try #require(GitHub.parsePR(node))

    #expect(parsed.pr == expected)
  }

  @Test(arguments: GitHubFixtures.statusPRs.map(\.number))
  func parsesEachRecordedPRsCommentsOldestFirstWithoutDuplicates(_ number: Int) throws {
    let node = try #require(GitHubFixtures.statusNode(number))

    let parsed = try #require(GitHub.parsePR(node))

    #expect(parsed.comments == GitHubFixtures.statusComments[number])
  }

  @Test(arguments: [
    (JSON.object(["id": "TREE_1"]), Bool?.some(true)), (JSON.null, Bool?.some(false)),
  ])
  func readsWhetherTheRepositoryHasATrunkFolder(_ object: JSON, _ expected: Bool?) throws {
    let node = try editedNode(
      18303,
      ["repository": ["nameWithOwner": "PostHog/charts", "defaultBranchRef": ["name": "main"], "trunkConfig": object]])

    #expect(GitHub.parsePR(node)?.pr.trunkConfig == expected)
  }

  @Test(arguments: [JSON.null, "REVIEW_REQUIRED", "CHANGES_REQUESTED", "APPROVED"])
  func readsTheReviewDecisionWhenTheKeyIsPresent(_ decision: JSON) throws {
    let node = try editedNode(18303, ["reviewDecision": decision])

    #expect(GitHub.parsePR(node)?.pr.reviewDecisionRead == true)
  }

  @Test func nullReviewDecisionMeansThePRNeedsNoReview() throws {
    let node = try editedNode(18303, ["reviewDecision": .null])

    #expect(GitHub.parsePR(node)?.pr.needsReview == false)
  }

  /// A response without the key, or with a decision that ReviewDecision
  /// does not know, leaves the decision unread.
  @Test(arguments: [nil, "SOMETHING_NEW"] as [JSON?])
  func aMissingOrUnknownReviewDecisionLeavesItUnread(_ decision: JSON?) throws {
    var node = try #require(GitHubFixtures.statusNode(18303)?.object)
    node["reviewDecision"] = decision

    let pr = try #require(GitHub.parsePR(.object(node))).pr

    #expect(pr.reviewDecisionRead == nil)
    #expect(pr.needsReview == nil)
  }

  @Test func aResponseWithoutTheTrunkFolderLeavesItUnread() throws {
    let node = try editedNode(
      18303, ["repository": ["nameWithOwner": "PostHog/charts", "defaultBranchRef": ["name": "main"]]])

    #expect(GitHub.parsePR(node)?.pr.trunkConfig == nil)
  }

  /// GitHub answers a field it couldn't resolve, such as for a token without
  /// Contents read, with null and an error. That null is not an answer.
  @Test(arguments: [
    (JSON.array([["path": ["nodes", 0, "repository", "trunkConfig"], "type": "FORBIDDEN"]]), Bool?.none),
    (JSON.array([["message": "Something went wrong"]]), Bool?.none),
    (JSON.array([["path": ["nodes", 1, "repository", "trunkConfig"], "type": "FORBIDDEN"]]), Bool?.some(false)),
  ])
  func aTrunkFolderThatGitHubFailedToReadIsUnread(_ errors: JSON, _ expected: Bool?) throws {
    let node = try editedNode(
      18303,
      ["repository": ["nameWithOwner": "PostHog/charts", "defaultBranchRef": ["name": "main"], "trunkConfig": .null]])
    let response: JSON = ["data": ["nodes": [node]], "errors": errors]

    let prs = GitHub.parseStatus(response, ["PR_kwDOJsIKrs8AAAABKhgNxg"]).prs

    #expect(prs.count == 1)
    #expect(prs.first?.pr.trunkConfig == expected)
  }

  @Test func commentsFromBothPagesAreMergedAndSortedByCreation() throws {
    let a = commentNode("IC_a", "alice", "2026-10-01T00:00:00Z")
    let b = commentNode("IC_b", "bob", "2026-10-02T00:00:00Z")
    let c = commentNode("IC_c", "carol", "2026-10-03T00:00:00Z")
    let d = commentNode("IC_d", "dave", "2026-10-04T00:00:00Z")
    let node = try editedNode(
      18303, ["firstComments": ["nodes": [b, a]], "lastComments": ["nodes": [d, b, c]]])

    let parsed = try #require(GitHub.parsePR(node))

    #expect(parsed.comments.map(\.id) == ["IC_a", "IC_b", "IC_c", "IC_d"])
  }

  @Test func deletedCommentAuthorIsGhost() throws {
    let node = try editedNode(
      18303,
      [
        "firstComments": ["nodes": [commentNode("IC_x", nil, "2026-10-01T00:00:00Z")]],
        "lastComments": ["nodes": []],
      ])

    let parsed = try #require(GitHub.parsePR(node))

    #expect(parsed.comments.map(\.author) == ["ghost"])
  }

  @Test func deletedReviewerIsGhostInVerdicts() throws {
    let node = try editedNode(
      18303,
      [
        "latestOpinionatedReviews": [
          "nodes": [
            ["author": .null, "state": "APPROVED", "submittedAt": "2026-10-01T00:00:00Z", "commit": ["oid": "abc"]]
          ]
        ]
      ])

    let parsed = try #require(GitHub.parsePR(node))

    #expect(
      parsed.pr.verdicts == [
        Review(author: "ghost", state: "APPROVED", submittedAt: "2026-10-01T00:00:00Z", commit: "abc")
      ])
  }

  @Test func deletedReviewerIsGhostInReviews() throws {
    let node = try editedNode(
      18303,
      ["reviews": ["nodes": [["author": .null, "state": "COMMENTED", "submittedAt": "2026-10-01T00:00:00Z"]]]])

    let parsed = try #require(GitHub.parsePR(node))

    #expect(parsed.pr.reviews == [Review(author: "ghost", state: "COMMENTED", submittedAt: "2026-10-01T00:00:00Z")])
  }

  @Test(arguments: [
    JSON.array([["commit": ["statusCheckRollup": .null]]]),
    JSON.array([]),
  ])
  func headCommitWithoutARollupHasNoChecks(_ commits: JSON) throws {
    let node = try editedNode(18303, ["commits": ["nodes": commits]])

    let parsed = try #require(GitHub.parsePR(node))

    #expect(parsed.pr.checks == nil)
  }

  @Test func reviewRequestsNameEachRequestedReviewer() throws {
    let requests: JSON = [
      "nodes": [
        ["requestedReviewer": ["__typename": "User", "login": "alex"]],
        ["requestedReviewer": ["__typename": "Bot", "login": "copilot-pull-request-reviewer"]],
        ["requestedReviewer": ["__typename": "Team", "slug": "flags"]],
        ["requestedReviewer": .null],
      ]
    ]
    let node = try editedNode(18303, ["reviewRequests": requests])

    #expect(try #require(GitHub.parsePR(node)).pr.reviewRequests == ["alex", "copilot-pull-request-reviewer", "flags"])
  }

  @Test func noReviewRequestsIsAnEmptyListAndAnAbsentFieldIsNil() throws {
    let none = try editedNode(18303, ["reviewRequests": ["nodes": []]])

    #expect(try #require(GitHub.parsePR(none)).pr.reviewRequests == [])
    #expect(try #require(GitHub.parsePR(try editedNode(18303, [:]))).pr.reviewRequests == nil)
  }

  @Test(
    arguments: [
      (
        [
          "baseRefName": "haacked/parent",
          "baseRef": baseRef(tip: "a1", merged: [["number": 122000, "headRefOid": "a1"]]),
        ], 122000
      ),
      // A long-lived base such as develop moves on after its PR merges.
      (
        ["baseRefName": "develop", "baseRef": baseRef(tip: "b2", merged: [["number": 122000, "headRefOid": "a1"]])], nil
      ),
      (["baseRefName": "haacked/parent", "baseRef": baseRef(tip: "a1", merged: [])], nil),
      (["baseRefName": "haacked/parent", "baseRef": .null], nil),
      (["baseRefName": "main", "baseRef": baseRef(tip: "a1", merged: [["number": 1, "headRefOid": "a1"]])], nil),
    ] as [([String: JSON], Int?)])
  func mergedBaseIsTheMergedPRAtTheTipOfANonDefaultBase(_ fields: [String: JSON], _ mergedBase: Int?) throws {
    let node = try editedNode(18303, fields)

    let parsed = try #require(GitHub.parseMergedBase(node))

    #expect(parsed.id == "PR_kwDOJsIKrs8AAAABKhgNxg")
    #expect(parsed.mergedBase == mergedBase)
    #expect(GitHub.parsePR(node)?.pr.mergedBase == nil)
  }

  @Test func parsedPRHasNoQueueStatus() throws {
    let node = try #require(GitHubFixtures.statusNode(122953))

    let parsed = try #require(GitHub.parsePR(node))

    #expect(parsed.pr.queue == nil)
  }

  @Test(arguments: [
    JSON.null,
    JSON.object([:]),
    try editedNode(18303, ["id": .null]),
    try editedNode(18303, ["number": .null]),
  ])
  func nodeThatIsNotAPRParsesToNil(_ node: JSON) {
    #expect(GitHub.parsePR(node) == nil)
  }

  @Test func nodeWithoutIdOrNumberKeysParsesToNil() throws {
    var withoutId = try #require(GitHubFixtures.statusNode(18303)?.object)
    withoutId["id"] = nil
    var withoutNumber = try #require(GitHubFixtures.statusNode(18303)?.object)
    withoutNumber["number"] = nil

    #expect(GitHub.parsePR(.object(withoutId)) == nil)
    #expect(GitHub.parsePR(.object(withoutNumber)) == nil)
  }

  @Test(arguments: GitHubFixtures.bodyNodes)
  func bodyResponseCommentMatchesTheStatusCommentWithItsBody(_ node: JSON) throws {
    let id = try #require(node["id"]?.string)
    var expected = try #require(GitHubFixtures.statusComments.values.joined().first { $0.id == id })
    expected.body = try #require(node["body"]?.string)

    #expect(GitHub.parseComment(node) == expected)
  }

  @Test func parsedBodyKeepsItsText() throws {
    let node = try #require(GitHubFixtures.bodyNodes.first { $0["id"]?.string == "IC_kwDODg-Tdc8AAAABei9jZw" })

    let comment = try #require(GitHub.parseComment(node))

    #expect(
      comment.body
        == "😎\u{2002}Merged successfully - "
        + "[details](https://app.trunk.io/posthog-inc/merge-queue/3921a8a3-abf7-42ff-b9cf-ef4fab8f3649/122179).")
  }

  @Test func commentWithoutABodyHasNilBody() throws {
    let node = try #require(GitHubFixtures.statusNode(122953)?["firstComments"]?["nodes"]?.array?.first)

    let comment = try #require(GitHub.parseComment(node))

    #expect(
      comment
        == PRComment(id: "IC_kwDODg-Tdc8AAAABfBZM8A", author: "trunk-io[bot]", createdAt: "2026-10-23T23:29:49Z"))
  }

  @Test(arguments: [("Bot", "trunk-io[bot]"), ("User", "trunk-io")])
  func onlyAnAppsCommentEndsInBot(_ type: String, _ author: String) throws {
    let node: JSON = [
      "id": "IC_t", "author": ["__typename": .string(type), "login": "trunk-io"], "createdAt": "2026-10-01T00:00:00Z",
    ]

    let comment = try #require(GitHub.parseComment(node))

    #expect(comment.author == author)
    #expect(GitHub.bodyAuthors.contains(comment.author) == (type == "Bot"))
  }

  @Test func editedCommentKeepsItsEditTime() throws {
    let node: JSON = [
      "id": "IC_e", "author": ["login": "trunk-io"], "createdAt": "2026-10-01T00:00:00Z",
      "lastEditedAt": "2026-10-02T00:00:00Z", "includesCreatedEdit": true, "body": "queued",
    ]

    let comment = try #require(GitHub.parseComment(node))

    #expect(
      comment
        == PRComment(
          id: "IC_e", author: "trunk-io", createdAt: "2026-10-01T00:00:00Z", editedAt: "2026-10-02T00:00:00Z",
          edited: true, body: "queued"))
  }

  @Test func commentByADeletedAccountIsByGhost() throws {
    let comment = try #require(GitHub.parseComment(commentNode("IC_g", nil, "2026-10-01T00:00:00Z")))

    #expect(comment.author == "ghost")
  }
}

@Suite struct GitHubLookup {
  static let keys: [PRKey] = [
    .branch(repo: "acme-owner/widget-repo", branch: "feat/lookup", owner: "fork-owner"),
    .number(repo: "other-owner/gadget-repo", number: 4242),
    .branch(repo: "third-owner/thing-repo", branch: "fix/thing", owner: "third-owner"),
  ]

  /// The query without whitespace, so a check doesn't depend on its layout.
  func compact(_ query: String) -> String { query.filter { !$0.isWhitespace } }

  @Test func variablesCarryEachKeysValues() {
    let (_, variables) = GitHub.lookupQuery(Self.keys)

    #expect(
      variables == [
        "o0": "acme-owner", "n0": "widget-repo", "b0": "feat/lookup",
        "o1": "other-owner", "n1": "gadget-repo", "k1": 4242,
        "o2": "third-owner", "n2": "thing-repo", "b2": "fix/thing",
      ])
  }

  @Test(arguments: [
    "$o0:String!", "$n0:String!", "$b0:String!", "$o1:String!", "$n1:String!", "$k1:Int!", "$o2:String!", "$n2:String!",
    "$b2:String!",
  ])
  func queryDeclaresEachVariablesType(_ declaration: String) {
    let (query, _) = GitHub.lookupQuery(Self.keys)

    #expect(compact(query).contains(declaration))
  }

  @Test(arguments: [
    ("q0:repository(", ["owner:$o0", "name:$n0"]),
    ("q1:repository(", ["owner:$o1", "name:$n1"]),
    ("q2:repository(", ["owner:$o2", "name:$n2"]),
  ])
  func queryAliasesARepositoryPerKey(_ alias: String, _ arguments: [String]) {
    let text = compact(GitHub.lookupQuery(Self.keys).query)

    #expect(text.contains(alias))
    for argument in arguments { #expect(text.contains(argument)) }
  }

  @Test(arguments: ["$b0", "$b2"])
  func branchKeyAsksForTheNewestFivePRsFromTheBranch(_ branch: String) {
    let text = compact(GitHub.lookupQuery(Self.keys).query)

    #expect(
      text.contains(
        "pullRequests(headRefName:\(branch),first:5,orderBy:{field:CREATED_AT,direction:DESC})"
          + "{nodes{idstateheadRepositoryOwner{login}}}"))
  }

  @Test func numberKeyAsksForThePRsId() {
    let text = compact(GitHub.lookupQuery(Self.keys).query)

    #expect(text.contains("pullRequest(number:$k1){id}"))
  }

  @Test(arguments: ["acme-owner", "widget-repo", "feat/lookup", "other-owner", "gadget-repo", "4242", "fix/thing"])
  func queryTextHoldsNoKeyValue(_ value: String) {
    let (query, _) = GitHub.lookupQuery(Self.keys)

    #expect(!query.contains(value))
  }

  @Test(arguments: [#"a"b"#, "fix/a}b", #"x") { id } evil: viewer { login } #"#, #"feat/"quoted""#, #""}"#])
  func branchNameThatCouldEndAStringNeverReachesTheQueryText(_ branch: String) {
    let (query, variables) = GitHub.lookupQuery([.branch(repo: "acme-owner/widget-repo", branch: branch, owner: "x")])

    #expect(!query.contains(branch))
    #expect(!query.contains("\""))
    #expect(variables["b0"]?.string == branch)
  }

  static let branchKey = PRKey.branch(repo: "acme/widgets", branch: "feature", owner: "haacked")

  @Test(
    arguments: [
      ([pull("c1", "CLOSED", "haacked"), pull("o1", "OPEN", "haacked"), pull("o2", "OPEN", "haacked")], "o1"),
      ([pull("m1", "MERGED", "haacked"), pull("c1", "CLOSED", "haacked")], "m1"),
      ([pull("f1", "OPEN", "someone-else"), pull("m1", "MERGED", "haacked")], "m1"),
      ([pull("n1", "OPEN", nil), pull("c1", "CLOSED", "haacked")], "c1"),
      ([pull("f1", "OPEN", "someone-else")], nil),
      ([pull("n1", "OPEN", nil)], nil),
      ([], nil),
    ] as [([JSON], String?)])
  func branchKeyPrefersAnOpenPRFromTheOwnersRepository(_ pulls: [JSON], _ id: String?) {
    let data: JSON = ["q0": ["pullRequests": ["nodes": .array(pulls)]]]

    #expect(lookup(data, [Self.branchKey]) == [id])
  }

  @Test(arguments: [("haacked", "HAACKED"), ("Haacked", "haacked")])
  func branchOwnerMatchesWithoutRegardToCase(_ keyOwner: String, _ login: String) {
    let key = PRKey.branch(repo: "acme/widgets", branch: "feature", owner: keyOwner)
    let data: JSON = ["q0": ["pullRequests": ["nodes": [pull("o1", "OPEN", login)]]]]

    #expect(lookup(data, [key]) == ["o1"])
  }

  @Test(
    arguments: [
      (["q0": ["pullRequest": ["id": "PR_n"]]], "PR_n"),
      (["q0": ["pullRequest": .null]], nil),
      (["q0": .null], nil),
      ([:], nil),
    ] as [(JSON, String?)])
  func numberKeyReadsThePRsId(_ data: JSON, _ id: String?) {
    #expect(lookup(data, [.number(repo: "acme/widgets", number: 7)]) == [id])
  }

  @Test func branchKeyWithoutARepositoryHasNoPR() {
    #expect(lookup(["q0": .null], [Self.branchKey]) == [nil])
  }

  @Test func eachKeyReadsItsOwnAlias() {
    let data: JSON = [
      "q0": ["pullRequests": ["nodes": [pull("b0", "OPEN", "fork-owner")]]],
      "q1": ["pullRequest": .null],
      "q2": ["pullRequests": ["nodes": [pull("b2", "MERGED", "third-owner")]]],
    ]

    #expect(lookup(data, Self.keys) == ["b0", nil, "b2"])
  }

  @Test func aliasThatFailedIsLeftOutAndOneNotFoundHasNoPR() {
    let number = PRKey.number(repo: "acme/widgets", number: 7)
    let response: JSON = [
      "data": ["q0": .null, "q1": .null],
      "errors": [["type": "INTERNAL", "path": ["q0"]], ["type": "NOT_FOUND", "path": ["q1"]]],
    ]

    let found = GitHub.parseLookup(response, [Self.branchKey, number])

    #expect(found[Self.branchKey] == nil)
    #expect(found[number] == .some(nil))
  }

  @Test func emptyResponseHasAnEntryPerKey() {
    #expect(lookup([:], Self.keys) == [nil, nil, nil])
  }
}

@Suite struct GitHubPolling {
  @Test func pollIntervalsEndHalfATimerPeriodEarly() {
    var settings = GitHubSettings()
    settings.pollSeconds = 30
    settings.idlePollSeconds = 300

    #expect(settings.pendingMs == 15_000)
    #expect(settings.idleMs == 285_000)
  }

  @Test func pollIntervalsWithoutATimerAreExact() {
    var settings = GitHubSettings()
    settings.pollSeconds = 0
    settings.idlePollSeconds = 300

    #expect(settings.pendingMs == 0)
    #expect(settings.idleMs == 300_000)
  }

  @Test(arguments: [(0, [Int]()), (1, [1]), (20, [20]), (21, [20, 1]), (45, [20, 20, 5])])
  func chunksHoldAtMostTheChunkSize(_ count: Int, _ sizes: [Int]) {
    #expect(GitHub.chunks(Array(0..<count)).map(\.count) == sizes)
  }

  @Test func chunksKeepTheItemsInOrder() {
    let items = Array(0..<45)

    #expect(GitHub.chunks(items).flatMap { $0 } == items)
  }

  @Test(arguments: [([1, 2, 3, 4], [[1, 2], [3, 4]]), ([1, 2, 3, 4, 5], [[1, 2], [3, 4], [5]])])
  func chunksTakeAnExplicitSize(_ items: [Int], _ expected: [[Int]]) {
    #expect(GitHub.chunks(items, size: 2) == expected)
  }

  static let now: Int64 = 1_000_000_000

  func isDue(_ pr: PullRequest?, polledAgo elapsed: Int64?) -> Bool {
    GitHub.isDue(
      pr, lastPolled: elapsed.map { Self.now - $0 }, now: Self.now, pendingMs: 30_000, idleMs: 300_000)
  }

  @Test(arguments: [nil, 0, 1_000_000] as [Int64?])
  func prThatWasNeverReadIsDue(_ elapsed: Int64?) {
    #expect(isDue(nil, polledAgo: elapsed))
  }

  @Test func prThatWasNeverPolledIsDue() {
    #expect(isDue(samplePR(checks: "SUCCESS"), polledAgo: nil))
  }

  @Test(arguments: [(0, false), (29_999, false), (30_000, true), (30_001, true)] as [(Int64, Bool)])
  func pendingPRIsDueAfterThePendingInterval(_ elapsed: Int64, _ due: Bool) {
    #expect(isDue(samplePR(checks: "PENDING"), polledAgo: elapsed) == due)
  }

  @Test(arguments: [(30_000, false), (299_999, false), (300_000, true), (300_001, true)] as [(Int64, Bool)])
  func settledPRIsDueAfterTheIdleInterval(_ elapsed: Int64, _ due: Bool) {
    #expect(isDue(samplePR(checks: "SUCCESS"), polledAgo: elapsed) == due)
  }

  @Test(arguments: [(30_000, false), (300_000, true)] as [(Int64, Bool)])
  func mergedPRWithRunningChecksPollsAsSettled(_ elapsed: Int64, _ due: Bool) {
    #expect(isDue(samplePR(state: .merged, mergeable: .unknown, checks: "PENDING"), polledAgo: elapsed) == due)
  }
}

@Suite struct GitHubRemote {
  @Test(arguments: [
    "git@github.com:PostHog/posthog.git",
    "git@github.com:PostHog/posthog",
    "https://github.com/PostHog/posthog.git",
    "https://github.com/PostHog/posthog",
    "https://github.com/PostHog/posthog/",
    "https://user@github.com/PostHog/posthog.git",
    "ssh://git@github.com/PostHog/posthog.git",
    "ssh://git@github.com:22/PostHog/posthog.git",
    "ssh://git@ssh.github.com:443/PostHog/posthog.git",
    "https://GitHub.com/PostHog/posthog.git",
    "GIT@GITHUB.COM:PostHog/posthog.git",
  ])
  func githubRemoteGivesOwnerAndName(_ url: String) {
    #expect(GitHub.repo(remoteURL: url) == "PostHog/posthog")
  }

  @Test(arguments: [
    "https://gitlab.com/a/b.git",
    "/local/path/repo",
    "git@example.com:a/b.git",
    "",
    "https://github.com.example.com/a/b.git",
    "https://example.com/github.com/a/b.git",
    "git@github.com.example.com:a/b.git",
    "ssh://git@example.com/a/b.git",
    "https://notgithub.com/a/b.git",
    "/srv/me@github.com:a/b.git",
    "./me@github.com:a/b.git",
    "file:///srv/github.com/a/b.git",
    "https://github.com/a",
    "https://github.com/a/b/c",
    "git@github.com:",
  ])
  func otherRemoteGivesNil(_ url: String) {
    #expect(GitHub.repo(remoteURL: url) == nil)
  }
}

@Suite struct TranscriptPRLink {
  static func linkLine(_ number: Int) -> String {
    #"{"type":"pr-link","sessionId":"1e2aaefe-e22f-4e93-9446-f8d157928dfe","prNumber":\#(number),"#
      + #""prUrl":"https://github.com/PostHog/ops-platform/pull/\#(number)","prRepository":"PostHog/ops-platform","#
      + #""timestamp":"2026-08-25T23:59:58.451Z"}"#
  }

  static func link(_ number: Int) -> PRKey {
    .number(repo: "PostHog/ops-platform", number: number)
  }

  // Multi-byte text, so that a count of characters differs from a count of bytes.
  static let userLine = #"{"type":"user","message":{"content":"Résumé ✓ 日本語 😀"}}"#
  static let assistantLine = #"{"type":"assistant","message":{"content":"Ünïcödé ⚡️"}}"#

  @Test func recordedLineGivesItsLink() {
    let text = Self.userLine + "\n" + Self.linkLine(628) + "\n" + Self.assistantLine + "\n"

    #expect(GitHub.lastPRLink(in: Data(text.utf8)).key == Self.link(628))
  }

  @Test func consumedCountsTheBytesThroughTheLastNewline() {
    let text = Self.userLine + "\n" + Self.linkLine(628) + "\n" + Self.assistantLine + "\n"

    #expect(GitHub.lastPRLink(in: Data(text.utf8)).consumed == Data(text.utf8).count)
  }

  @Test func lastLinkWins() {
    let text = Self.linkLine(628) + "\n" + Self.userLine + "\n" + Self.linkLine(629) + "\n"

    #expect(GitHub.lastPRLink(in: Data(text.utf8)).key == Self.link(629))
  }

  @Test func trailingPartialLinkIsNotReturned() {
    let text = Self.userLine + "\n" + Self.linkLine(628) + "\n" + Self.linkLine(629)

    #expect(GitHub.lastPRLink(in: Data(text.utf8)).key == Self.link(628))
  }

  @Test func trailingPartialLineIsNotConsumed() {
    let complete = Self.userLine + "\n" + Self.linkLine(628) + "\n"

    let result = GitHub.lastPRLink(in: Data((complete + Self.linkLine(629)).utf8))

    #expect(result.consumed == Data(complete.utf8).count)
  }

  @Test(arguments: ["", TranscriptPRLink.linkLine(628), TranscriptPRLink.userLine])
  func dataWithoutANewlineGivesNothing(_ text: String) {
    let result = GitHub.lastPRLink(in: Data(text.utf8))

    #expect(result.key == nil)
    #expect(result.consumed == 0)
  }

  @Test func linesWithoutALinkAreConsumed() {
    let text = Self.userLine + "\n" + Self.assistantLine + "\n" + #"{"type":"assistant","#

    let result = GitHub.lastPRLink(in: Data(text.utf8))

    #expect(result.key == nil)
    #expect(result.consumed == Data((Self.userLine + "\n" + Self.assistantLine + "\n").utf8).count)
  }

  @Test(arguments: [
    #"{"type":"pr-link","prNumber":"#,
    "not json at all",
    #"{"type":"assistant","prNumber":700,"prUrl":"https://github.com/a/b/pull/700","prRepository":"a/b"}"#,
    #"["pr-link"]"#,
    #"{"type":"user","message":{"content":"what does \"pr-link\" mean?"}}"#,
    "",
  ])
  func lineThatIsNotALinkIsSkipped(_ line: String) {
    let text = Self.linkLine(628) + "\n" + line + "\n"

    #expect(GitHub.lastPRLink(in: Data(text.utf8)).key == Self.link(628))
  }
}

@Suite struct GitHubConfig {
  @Test func missingGitHubFieldsKeepTheirDefaults() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"github": {"pollSeconds": 0}}"#)

    #expect(c.github.pollSeconds == 0)
    #expect(c.github.gh == "gh")
    #expect(c.github.url == "https://api.github.com")
    #expect(c.github.idlePollSeconds == 300)
  }

  @Test func configWithoutGitHubUsesTheDefaultSettings() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"idleStopSeconds": 30}"#)

    #expect(c.github == GitHubSettings())
  }
}
