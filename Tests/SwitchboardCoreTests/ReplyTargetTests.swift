import Foundation
import Testing

@testable import SwitchboardCore

/// samplePR's PR, acme/widgets#42, as a github.com URL.
private let widgets42 = "https://github.com/acme/widgets/pull/42"
/// How GitHub's REST answers name samplePR's PR.
private let apiPull42 = "https://api.github.com/repos/acme/widgets/pulls/42"
private let apiIssue42 = "https://api.github.com/repos/acme/widgets/issues/42"
/// An id above Int32's range, as GitHub's comment ids are.
private let bigId: Int64 = 2_512_345_678

private func target(_ kind: ReplyTarget.Kind, id: Int64 = bigId, repo: String = "acme/widgets", pr: Int = 42)
  -> ReplyTarget
{
  ReplyTarget(repo: repo, pr: pr, kind: kind, id: id)
}

/// A review comment as `GET repos/{o}/{r}/pulls/comments/{id}` answers it.
private func reviewComment(
  _ id: Int64 = bigId, on pullRequest: JSON = .string(apiPull42), inReplyTo: JSON? = nil, line: JSON = 12,
  originalLine: JSON = .null, body: String = "NOT over AND changes the result.", login: String = "mariusandra"
) -> JSON {
  var comment: [String: JSON] = [
    "id": .number(Double(id)), "user": ["login": .string(login)], "path": "posthog/hogql/x.py", "line": line,
    "original_line": originalLine, "body": .string(body), "html_url": .string("\(widgets42)#discussion_r\(id)"),
  ]
  if pullRequest != .null { comment["pull_request_url"] = pullRequest }
  if let inReplyTo { comment["in_reply_to_id"] = inReplyTo }
  return .object(comment)
}

private func issueComment(_ id: Int64 = bigId, on issue: String = apiIssue42) -> JSON {
  [
    "id": .number(Double(id)), "issue_url": .string(issue), "user": ["login": "bob"],
    "body": "Can this land before Friday?", "html_url": .string("\(widgets42)#issuecomment-\(id)"),
  ]
}

private func review(_ id: Int64 = bigId, on pullRequest: String = apiPull42) -> JSON {
  [
    "id": .number(Double(id)), "pull_request_url": .string(pullRequest), "user": ["login": "carol"],
    "body": "One question inline.", "state": "COMMENTED", "html_url": .string("\(widgets42)#pullrequestreview-\(id)"),
  ]
}

private func resolvedTarget(_ kind: ReplyTarget.Kind, root: Int64 = bigId) -> ResolvedTarget {
  ResolvedTarget(
    target: target(kind), root: root, author: "mariusandra", path: "posthog/hogql/x.py", line: 12,
    excerpt: "NOT over AND changes the result.", url: "\(widgets42)#discussion_r\(root)")
}

@Suite struct ReplyTargetTests {
  // MARK: Parsing

  /// Each path form with each fragment: `{"", /files, /changes}` times the four fragments.
  @Test(
    arguments: ["", "/files", "/changes"],
    [
      ("discussion_r", ReplyTarget.Kind.reviewComment), ("r", .reviewComment), ("issuecomment-", .issueComment),
      ("pullrequestreview-", .review),
    ])
  func everyAcceptedFormParsesToItsKindAndId(_ suffix: String, _ fragment: (String, ReplyTarget.Kind)) throws {
    let url = "\(widgets42)\(suffix)#\(fragment.0)\(bigId)"

    let parsed = try ReplyTarget.parse(url)

    #expect(parsed == ReplyTarget(repo: "acme/widgets", pr: 42, kind: fragment.1, id: bigId))
  }

  @Test func theSpecsExampleParses() throws {
    let parsed = try ReplyTarget.parse("https://github.com/PostHog/posthog/pull/133282#discussion_r2512345678")

    #expect(parsed == ReplyTarget(repo: "PostHog/posthog", pr: 133282, kind: .reviewComment, id: 2_512_345_678))
  }

  @Test func theRepoKeepsItsCase() throws {
    #expect(try ReplyTarget.parse("https://github.com/PostHog/Charts/pull/7#r1").repo == "PostHog/Charts")
  }

  @Test(arguments: [
    // Another scheme or host, including GitHub Enterprise.
    "http://github.com/acme/widgets/pull/42#discussion_r1",
    "https://gist.github.com/acme/widgets/pull/42#discussion_r1",
    "https://github.example.com/acme/widgets/pull/42#discussion_r1",
    "https://www.github.com/acme/widgets/pull/42#discussion_r1",
    "https://api.github.com/acme/widgets/pull/42#discussion_r1",
    "github.com/acme/widgets/pull/42#discussion_r1",
    "https://ann@github.com/acme/widgets/pull/42#discussion_r1",
    "https://github.com:8443/acme/widgets/pull/42#discussion_r1",
    // No fragment, or one that names no comment.
    "https://github.com/acme/widgets/pull/42",
    "https://github.com/acme/widgets/pull/42#",
    "https://github.com/acme/widgets/pull/42#discussion_r",
    "https://github.com/acme/widgets/pull/42#r",
    "https://github.com/acme/widgets/pull/42#issuecomment-",
    "https://github.com/acme/widgets/pull/42#pullrequestreview-",
    "https://github.com/acme/widgets/pull/42#comment-1",
    "https://github.com/acme/widgets/pull/42#discussion-r1",
    // A zero, negative, non-numeric, or too large id.
    "https://github.com/acme/widgets/pull/42#discussion_r0",
    "https://github.com/acme/widgets/pull/42#r0",
    "https://github.com/acme/widgets/pull/42#issuecomment-0",
    "https://github.com/acme/widgets/pull/42#pullrequestreview-0",
    "https://github.com/acme/widgets/pull/42#discussion_r-5",
    "https://github.com/acme/widgets/pull/42#discussion_r12x",
    "https://github.com/acme/widgets/pull/42#discussion_r99999999999999999999",
    "https://github.com/acme/widgets/pull/42#discussion_r\u{0661}\u{0662}\u{0663}",
    // Text before or after the fragment's id.
    "https://github.com/acme/widgets/pull/42#discussion_r12-foo",
    "https://github.com/acme/widgets/pull/42#xdiscussion_r12",
    "https://github.com/acme/widgets/pull/42#issuecomment-1?x",
    "https://github.com/acme/widgets/pull/42#r%31",
    "https://github.com/acme/widgets/pull/42#r1#r2",
    // A query string.
    "https://github.com/acme/widgets/pull/42?w=1#discussion_r1",
    "https://github.com/acme/widgets/pull/42/files?diff=split#r1",
    // A path that is not a PR, or a PR number that is not a positive integer.
    "https://github.com/acme/widgets/issues/5#issuecomment-1",
    "https://github.com/acme/widgets/pull/0#discussion_r1",
    "https://github.com/acme/widgets/pull/abc#discussion_r1",
    "https://github.com/acme/widgets/pull/-5#discussion_r1",
    "https://github.com/acme/widgets/pull/42/commits#r1",
    "https://github.com/acme/widgets/pull/42/files/extra#r1",
    "https://github.com/acme/pull/42#r1",
    "https://github.com/acme/widgets/extra/pull/42#r1",
    "https://github.com/acme/wid%67ets/pull/42#r1",
    "https://github.com/acme/../pull/42#r1",
    "https://github.com/acme/widgets/pull/+42#r1",
    // Not a URL.
    "", "not a url", "#discussion_r1", "null",
  ])
  func everyRejectedFormThrowsWithAReason(_ url: String) {
    let error = #expect(throws: APIError.self) { try ReplyTarget.parse(url) }

    let reason = error?.description ?? ""
    #expect(!reason.isEmpty)
  }

  // MARK: The session's PR

  @Test(arguments: ["acme/widgets", "Acme/Widgets", "ACME/WIDGETS"])
  func matchesIgnoresTheRepositorysCase(_ repo: String) {
    #expect(target(.reviewComment, repo: repo).matches(samplePR()))
  }

  @Test(arguments: [("acme/gadgets", 42), ("other/widgets", 42), ("acme/widgets", 41), ("acme/widgets", 420)])
  func matchesRefusesAnotherRepoOrNumber(_ repo: String, _ number: Int) {
    #expect(!target(.reviewComment, repo: repo, pr: number).matches(samplePR()))
  }

  // MARK: gh arguments

  @Test(arguments: [
    (ReplyTarget.Kind.reviewComment, "repos/acme/widgets/pulls/comments/2512345678"),
    (.issueComment, "repos/acme/widgets/issues/comments/2512345678"),
    (.review, "repos/acme/widgets/pulls/42/reviews/2512345678"),
  ])
  func getPathNamesTheCommentForEachKind(_ kind: ReplyTarget.Kind, _ path: String) {
    #expect(target(kind).getPath == path)
  }

  @Test func postArgsForAReviewCommentReplyToTheThreadsRoot() {
    let args = resolvedTarget(.reviewComment, root: 1001).postArgs(body: "Thanks!")

    #expect(args == ["api", "-X", "POST", "repos/acme/widgets/pulls/42/comments/1001/replies", "-f", "body=Thanks!"])
  }

  @Test(arguments: [ReplyTarget.Kind.issueComment, .review])
  func postArgsForAnIssueCommentOrAReviewAddAConversationComment(_ kind: ReplyTarget.Kind) {
    let args = resolvedTarget(kind).postArgs(body: "Thanks!")

    #expect(args == ["api", "-X", "POST", "repos/acme/widgets/issues/42/comments", "-f", "body=Thanks!"])
  }

  /// `-F` reads `@path` as a file and turns true, false, null, and numbers
  /// into other types. `-f` sends each body as it is.
  @Test(
    arguments: [ReplyTarget.Kind.reviewComment, .issueComment, .review],
    ["@/etc/passwd", "a=b=c", "line one\nline two", "true", "null", "42", "emoji 👋🏽 and é", #"say "hi" \ bye"#])
  func postArgsSendTheBodyAsARawField(_ kind: ReplyTarget.Kind, _ body: String) {
    let args = resolvedTarget(kind).postArgs(body: body)

    #expect(!args.contains("-F"))
    #expect(!args.contains("--field"))
    #expect(Array(args.suffix(2)) == ["-f", "body=\(body)"])
  }

  // MARK: Resolution

  @Test func aReviewCommentOnTheTargetsPRResolvesWithItsFields() throws {
    let result = try ReplyTarget.resolution(of: target(.reviewComment), comment: reviewComment())

    #expect(result.rootToFetch == nil)
    let r = try #require(result.resolved)
    #expect(r.target == target(.reviewComment))
    #expect(r.root == bigId)
    #expect(r.author == "mariusandra")
    #expect(r.path == "posthog/hogql/x.py")
    #expect(r.line == 12)
    #expect(r.excerpt == "NOT over AND changes the result.")
    #expect(r.url == "\(widgets42)#discussion_r\(bigId)")
  }

  /// GitHub gives a comment on an outdated line no `line`, only `original_line`.
  @Test func aCommentWithoutALineUsesItsOriginalLine() throws {
    let comment = reviewComment(line: .null, originalLine: 7)

    let result = try ReplyTarget.resolution(of: target(.reviewComment), comment: comment)

    #expect(result.resolved?.line == 7)
  }

  @Test func theExcerptIsTheBodyOnOneLineOfAtMostTwoHundredCharacters() throws {
    let body = "First line.\n\nSecond line. " + String(repeating: "x", count: 300)

    let result = try ReplyTarget.resolution(of: target(.reviewComment), comment: reviewComment(body: body))

    let excerpt = try #require(result.resolved?.excerpt)
    #expect(!excerpt.contains("\n"))
    #expect(excerpt.count <= 200)
    #expect(excerpt.hasPrefix("First line. Second line."))
  }

  @Test func anIssueCommentOnTheTargetsPRResolves() throws {
    let result = try ReplyTarget.resolution(of: target(.issueComment), comment: issueComment())

    #expect(result.resolved?.author == "bob")
    #expect(result.rootToFetch == nil)
  }

  @Test func aReviewOnTheTargetsPRResolves() throws {
    let result = try ReplyTarget.resolution(of: target(.review), comment: review())

    #expect(result.resolved?.author == "carol")
    #expect(result.rootToFetch == nil)
  }

  /// GitHub places the repo in any case, and the target names it in another.
  @Test func resolutionIgnoresTheRepositorysCase() throws {
    let comment = reviewComment(on: "https://api.github.com/repos/ACME/Widgets/pulls/42")

    let result = try ReplyTarget.resolution(of: target(.reviewComment), comment: comment)

    #expect(result.resolved != nil)
  }

  /// A root comment's `in_reply_to_id` is missing or null, and both mean no parent.
  @Test(arguments: [nil, JSON.null])
  func aCommentWithoutAParentNeedsNoRoot(_ parent: JSON?) throws {
    let result = try ReplyTarget.resolution(of: target(.reviewComment), comment: reviewComment(inReplyTo: parent))

    #expect(result.rootToFetch == nil)
    #expect(result.resolved?.root == bigId)
  }

  @Test func aReplyYieldsItsParentAsTheRootToFetch() throws {
    let result = try ReplyTarget.resolution(of: target(.reviewComment), comment: reviewComment(inReplyTo: 1001))

    #expect(result.rootToFetch == 1001)
  }

  /// The URL says #42, and GitHub places the comment on another PR, in another
  /// repo.
  @Test(arguments: [
    "https://api.github.com/repos/acme/widgets/pulls/41",
    "https://api.github.com/repos/acme/widgets/pulls/420",
    "https://api.github.com/repos/acme/widgets/pulls/1",
    "https://api.github.com/repos/other/widgets/pulls/42",
    "https://api.github.com/repos/acme/widgets-old/pulls/42",
    "https://api.github.com/repos/xacme/widgets/pulls/42",
    "https://api.github.com/repos/acme/widgets/pulls/42/extra",
    "",
  ])
  func aReviewCommentThatGitHubPlacesElsewhereIsRefused(_ pullRequest: String) {
    #expect(throws: APIError.self) {
      try ReplyTarget.resolution(of: target(.reviewComment), comment: reviewComment(on: .string(pullRequest)))
    }
  }

  @Test func aReviewCommentWithoutAPullRequestURLIsRefused() {
    #expect(throws: APIError.self) {
      try ReplyTarget.resolution(of: target(.reviewComment), comment: reviewComment(on: .null))
    }
  }

  @Test func aReplyOnAnotherPRIsRefusedBeforeItsRootIsFetched() {
    let comment = reviewComment(on: "https://api.github.com/repos/acme/widgets/pulls/1", inReplyTo: 1001)

    #expect(throws: APIError.self) { try ReplyTarget.resolution(of: target(.reviewComment), comment: comment) }
  }

  @Test(arguments: [
    "https://api.github.com/repos/acme/widgets/issues/7",
    "https://api.github.com/repos/other/widgets/issues/42",
    "https://api.github.com/repos/acme/widgets/issues/420",
  ])
  func anIssueCommentOnAnotherIssueIsRefused(_ issue: String) {
    #expect(throws: APIError.self) {
      try ReplyTarget.resolution(of: target(.issueComment), comment: issueComment(on: issue))
    }
  }

  @Test(arguments: [
    "https://api.github.com/repos/acme/widgets/pulls/2",
    "https://api.github.com/repos/other/widgets/pulls/42",
  ])
  func aReviewOnAnotherPRIsRefused(_ pullRequest: String) {
    #expect(throws: APIError.self) {
      try ReplyTarget.resolution(of: target(.review), comment: review(on: pullRequest))
    }
  }

  // MARK: The thread's root

  @Test func theRootOfAReplyResolvesWithTheRootsId() throws {
    let child = reviewComment(inReplyTo: 1001)
    let rootComment = reviewComment(1001, login: "ann")

    let r = try ReplyTarget.root(of: target(.reviewComment), rootComment: rootComment, child: child)

    #expect(r.root == 1001)
    #expect(r.target == target(.reviewComment))
  }

  @Test func aRootThatIsItselfAReplyIsRefused() {
    let child = reviewComment(inReplyTo: 1001)
    let rootComment = reviewComment(1001, inReplyTo: 1000)

    let error = #expect(throws: APIError.self) {
      try ReplyTarget.root(of: target(.reviewComment), rootComment: rootComment, child: child)
    }

    #expect(error?.description.contains("deeper than one") == true)
  }

  @Test(arguments: [
    "https://api.github.com/repos/acme/widgets/pulls/1",
    "https://api.github.com/repos/other/widgets/pulls/42",
  ])
  func aRootOnAnotherPRIsRefused(_ pullRequest: String) {
    let child = reviewComment(inReplyTo: 1001)
    let rootComment = reviewComment(1001, on: .string(pullRequest))

    #expect(throws: APIError.self) {
      try ReplyTarget.root(of: target(.reviewComment), rootComment: rootComment, child: child)
    }
  }

  // MARK: Coding

  @Test(arguments: [ReplyTarget.Kind.reviewComment, .issueComment, .review])
  func aResolvedTargetRoundTrips(_ kind: ReplyTarget.Kind) throws {
    let r = resolvedTarget(kind)

    #expect(try JSONCoding.convert(try JSON(encoding: r), to: ResolvedTarget.self) == r)
  }
}
