import Foundation
import SwitchboardCore
import Testing

/// PostHog/charts#18303, which the fixture records for MergeTests.branch.
private let pullURL = "https://github.com/PostHog/charts/pull/18303"
private let commentURL = "\(pullURL)#discussion_r1001"
private let commentPath = "repos/PostHog/charts/pulls/comments/1001"
/// Where a reply in review comment 1001's thread goes.
private let replyPath = "repos/PostHog/charts/pulls/18303/comments/1001/replies"
/// Where a reply to an issue comment or a review goes, as a new PR conversation comment.
private let conversationPath = "repos/PostHog/charts/issues/18303/comments"
/// The review comments of #18303, which a check of a review comment reply lists.
private let reviewCommentsPath = "repos/PostHog/charts/pulls/18303/comments"

private let draftText = "Good catch. The NOT now wraps the whole AND, fixed in abc123."
/// The login that `gh api user` gives.
private let viewer = "octo-me"
/// The comment that the stub's POST creates.
private let postedURL = "\(pullURL)#discussion_r5001"
private let noticeLead =
  "Switchboard: the user posted these replies that you drafted. Don't draft or post them again."
private let loginRefusal = "GitHub refused gh's login. Run `gh auth login`, then post again"

/// What GitHub answers to a POST that created comment `id`.
private func createdJSON(_ id: Int64 = 5001, url: String = postedURL, body: String = draftText) -> JSON {
  ["id": .number(Double(id)), "html_url": .string(url), "body": .string(body), "user": ["login": .string(viewer)]]
}

/// A review comment in #18303's list, one per line as `--jq '.[] | @json'` prints it.
private func listedReply(
  _ id: Int64, by login: String = viewer, body: String = draftText, inReplyTo: Int64? = 1001
) -> JSON {
  var comment: [String: JSON] = [
    "id": .number(Double(id)), "user": ["login": .string(login)], "body": .string(body),
    "html_url": .string("\(pullURL)#discussion_r\(id)"),
    "pull_request_url": "https://api.github.com/repos/PostHog/charts/pulls/18303",
    "created_at": "2026-11-12T10:00:00Z",
  ]
  if let inReplyTo { comment["in_reply_to_id"] = .number(Double(inReplyTo)) }
  return .object(comment)
}

/// An issue comment in #18303's conversation list.
private func listedComment(_ id: Int64, by login: String = viewer, body: String = draftText) -> JSON {
  [
    "id": .number(Double(id)), "user": ["login": .string(login)], "body": .string(body),
    "html_url": .string("\(pullURL)#issuecomment-\(id)"),
    "issue_url": "https://api.github.com/repos/PostHog/charts/issues/18303", "created_at": "2026-11-12T10:00:00Z",
  ]
}

/// A session whose one draft replies to `replyTo` and has reached `ready`.
/// The POST has no route yet.
@discardableResult
private func readySession(
  _ github: FakeGitHub, _ sbd: Instance, replyTo: String = commentURL, text: String = draftText
) throws -> SessionSummary {
  try sbd.ghRoute("GET", commentPath, json: reviewCommentJSON(1001))
  let s = try sessionWithCard(github, sbd, card: replyCard(replyTo, text: text))
  try sbd.waitForPost(s.id, "ready")
  return s
}

/// Runs `body` on a queue of its own. The returned function waits for it
/// and gives its result, or nil when it threw or took two minutes.
private func inBackground(_ body: @escaping () throws -> CommandResult) -> () -> CommandResult? {
  let done = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: CommandResult?
  DispatchQueue(label: "DraftPostTests.background").async {
    result = try? body()
    done.signal()
  }
  return {
    guard done.wait(timeout: .now() + 120) == .success else { return nil }
    return result
  }
}

/// The additionalContext of each hook answer that the session's claude got, oldest first.
private func contexts(_ sbd: Instance, _ s: SessionSummary) -> [String] {
  sbd.hookOutputs(s.claudeSessionId).compactMap { $0["hookSpecificOutput"]?["additionalContext"]?.string }
}

/// A command that sends `request` to sbd's socket with perl and prints the
/// answer line. It skips sb, so sb's own CLAUDECODE check can't refuse it.
private func socketClient(_ request: JSON) -> String {
  let client = [
    #"$s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "connect: $!\n";"#,
    #"print $s "$ARGV[1]\n";"#,
    "print scalar <$s>",
  ].joined(separator: " ")
  return "perl -MIO::Socket::UNIX -e \(shellQuote(client)) \"$SB_HOME/sbd.sock\" \(shellQuote(request.text))"
}

extension Instance {
  /// The POSTs that the stub received, oldest first.
  fileprivate func posts() -> [String] { ghCalls("api -X POST") }

  /// The session's `draft_posting` events.
  fileprivate func postingEvents(_ id: String) throws -> [Event] {
    try events(id).filter { $0.kind == "draft_posting" }
  }

  /// Runs `sb draft post <id> <number>` with the extra arguments, whatever its exit status.
  fileprivate func postDraft(_ id: String, _ number: Int = 1, _ extra: [String] = []) throws -> CommandResult {
    try run(["draft", "post", id, String(number)] + extra)
  }

  /// Whether the stub ran `gh api user`.
  fileprivate func askedForTheLogin() -> Bool {
    ghCalls("api").contains { $0.split(separator: " ").contains("user") }
  }

  /// Makes `gh api user` and the thread's list fail, as a network failure does.
  fileprivate func checksFail(list: String = reviewCommentsPath) throws {
    try ghRouteFails("GET", "user", stderr: "error connecting to api.github.com\n")
    try ghRouteFails("GET", list, stderr: "error connecting to api.github.com\n")
  }

  /// Makes `gh api user` give `viewer` and the thread's list hold `comments`.
  fileprivate func checksFind(_ comments: [JSON], list: String = reviewCommentsPath) throws {
    try ghRoute("GET", "user", text: "\(viewer)\n")
    try ghRoute("GET", list, lines: comments)
  }

  /// Waits until the draft's state is neither `posting` nor `unknown`, and returns its `post`.
  fileprivate func settledOutcome(_ id: String) throws -> JSON {
    try waitFor(
      "the draft's outcome to settle", timeout: 30, fetch: { try draftPost(id) },
      until: { !["posting", "unknown", nil].contains($0["state"]?.string) })
  }
}

/// `sb draft post` posts a `ready` or `failed` draft once, from a caller
/// outside every session. The item records the outcome, sbd checks an
/// unknown outcome, and the session hears about the post on its next prompt.
@Suite(.blocking(timeLimit: .seconds(180))) struct DraftPostTests {
  // MARK: A post

  @Test func postPrintsTheNewCommentsURL() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    let out = try sbd.sb("draft", "post", s.id, "1")

    #expect(out.contains("Posted: \(postedURL)"), "\(out)")
  }

  @Test func postSendsTheDraftsTextToTheThreadsReplies() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    try sbd.sb("draft", "post", s.id, "1")

    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
    #expect(sbd.posts().first?.hasPrefix("api -X POST \(replyPath) -f body=") == true, "\(sbd.ghCalls())")
    #expect(sbd.ghBodies() == [draftText])
  }

  @Test func aPostedDraftShowsItsURLAndText() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    try sbd.sb("draft", "post", s.id, "1")

    let post = try sbd.waitForPost(s.id, "posted")
    #expect(post["url"]?.string == postedURL, "\(post)")
    #expect(post["text"]?.string == draftText, "\(post)")
    #expect(post["target"]?["root"]?.int == 1001, "\(post)")
  }

  /// A reply in a review thread goes to the thread's root, 1001, not to the reply the card named.
  @Test func aPostToAReplyCommentGoesToItsThreadsRoot() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", commentPath, json: reviewCommentJSON(1001))
    try sbd.ghRoute(
      "GET", "repos/PostHog/charts/pulls/comments/1002", json: reviewCommentJSON(1002, by: "dan", inReplyTo: 1001))
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)/files#r1002", text: draftText))
    try sbd.waitForPost(s.id, "ready")
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    try sbd.sb("draft", "post", s.id, "1")

    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
    #expect(sbd.posts().first?.hasPrefix("api -X POST \(replyPath) ") == true, "\(sbd.ghCalls())")
  }

  @Test(arguments: [
    ("issuecomment-2001", "repos/PostHog/charts/issues/comments/2001", issueCommentJSON(2001)),
    ("pullrequestreview-3001", "repos/PostHog/charts/pulls/18303/reviews/3001", reviewJSON(3001)),
  ])
  func aReplyToAnIssueCommentOrAReviewIsANewConversationComment(
    _ fragment: String, _ path: String, _ answer: JSON
  ) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", path, json: answer)
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#\(fragment)", text: draftText))
    try sbd.waitForPost(s.id, "ready")
    let created = "\(pullURL)#issuecomment-6001"
    try sbd.ghRoute("POST", conversationPath, json: createdJSON(6001, url: created))

    let out = try sbd.sb("draft", "post", s.id, "1")

    #expect(out.contains("Posted: \(created)"), "\(out)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
    #expect(sbd.posts().first?.hasPrefix("api -X POST \(conversationPath) ") == true, "\(sbd.ghCalls())")
    #expect(sbd.ghBodies() == [draftText])
  }

  /// Posted state lives in the session's log, so a restarted sbd still shows it and still refuses a second post.
  @Test func aPostedDraftStaysPostedAfterARestart() throws {
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    try sbd.sb("draft", "post", s.id, "1")

    sbd.stopSbd()
    try sbd.startSbd()

    let post = try sbd.waitForPost(s.id, "posted")
    #expect(post["url"]?.string == postedURL, "\(post)")
    let again = try sbd.postDraft(s.id)
    #expect(again.status != 0, "\(again.stdout)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  // MARK: Risk 4: the body reaches GitHub as the user wrote it

  /// `-F` would read `@path` as a file and turn true, null, and numbers into
  /// JSON values. A shell would split or expand the text.
  @Test(arguments: [
    "@/etc/hosts", "a=b, and body=x", "true", "null", "42", "Line one\n\nLine two\n  - an indented item",
    "Thanks — ✅ 日本語 👍🏽", "  Leading spaces stay.", "It costs $HOME and `whoami`; 'quoted' \"too\"",
  ])
  func theBodyEqualsTheTextByteForByte(_ body: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON(body: body))

    let r = try sbd.postDraft(s.id, 1, ["--text", body])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(sbd.ghBodies() == [body])
    #expect(sbd.posts().first?.contains(" -f body=") == true, "\(sbd.ghCalls())")
    #expect(sbd.posts().first?.contains(" -F ") == false, "\(sbd.ghCalls())")
  }

  @Test func theBodyComesFromStdinWithTextDash() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    let body = "From stdin, with @mentions and = signs.\nA second line."
    try sbd.ghRoute("POST", replyPath, json: createdJSON(body: body))

    let r = try runCommand(
      "\(Instance.bin)/sb", ["draft", "post", s.id, "1", "--text", "-"], env: sbd.environment(),
      input: Data(body.utf8))

    #expect(r.status == 0, "\(r.stderr)")
    #expect(sbd.ghBodies() == [body])
  }

  @Test func leadingAndTrailingBlankLinesAreTrimmed() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON(body: "Hello there."))

    let r = try sbd.postDraft(s.id, 1, ["--text", "\n\nHello there.\n\n"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(sbd.ghBodies() == ["Hello there."])
  }

  /// gh can't take an argument with a NUL, and Foundation's Process would
  /// end sbd on one after it recorded the attempt. sbd refuses the text
  /// first and keeps running.
  @Test func aBodyWithANulFromStdinIsRefusedAndSbdKeepsRunning() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    let r = try runCommand(
      "\(Instance.bin)/sb", ["draft", "post", s.id, "1", "--text", "-"], env: sbd.environment(),
      input: Data("Good catch.\u{0}Fixed.".utf8))

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("NUL"), "\(r.stderr)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
    let next = try sbd.postDraft(s.id)
    #expect(next.status == 0, "\(next.stderr)")
    #expect(sbd.ghBodies() == [draftText])
  }

  @Test func aBodyOfExactlyTheMaximumLengthPosts() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    let body = String(repeating: "x", count: TriageDrafts.maxLength)
    try sbd.ghRoute("POST", replyPath, json: createdJSON(body: body))

    let r = try sbd.postDraft(s.id, 1, ["--text", body])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(sbd.ghBodies() == [body])
  }

  @Test func aBodyOneCharacterOverTheMaximumIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    let r = try sbd.postDraft(s.id, 1, ["--text", String(repeating: "x", count: TriageDrafts.maxLength + 1)])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  @Test(arguments: ["\n\n", "   ", ""])
  func aBlankBodyIsRefused(_ body: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    let r = try sbd.postDraft(s.id, 1, ["--text", body])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  // MARK: Risk 2: a draft posts at most once

  @Test func aSecondPostOfTheSameDraftIsRefusedWithTheURL() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    try sbd.sb("draft", "post", s.id, "1")

    let second = try sbd.postDraft(s.id)

    #expect(second.status != 0, "\(second.stdout)")
    #expect(second.stderr.contains("already posted at \(postedURL)"), "\(second.stderr)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  /// The gate holds the first POST, so the second request arrives while the first one runs.
  @Test func aSecondPostWhileTheFirstRunsIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let gate = try sbd.ghGate("POST", replyPath)
    defer { sbd.releaseGhGate(gate) }
    let first = inBackground { try sbd.postDraft(s.id) }
    try sbd.waitFor("the first POST") { !sbd.posts().isEmpty }

    let second = try sbd.postDraft(s.id)
    try sbd.openGhGate(gate)

    #expect(second.status != 0, "\(second.stdout)")
    #expect(second.stderr.contains("already posting"), "\(second.stderr)")
    let firstResult = try #require(first())
    #expect(firstResult.status == 0, "\(firstResult.stderr)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  /// sbd records `draft_posting` before gh runs, so a crash during the POST leaves a record of the attempt.
  @Test func theDraftIsPostingWhileGhRuns() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let gate = try sbd.ghGate("POST", replyPath)
    defer { sbd.releaseGhGate(gate) }
    let first = inBackground { try sbd.postDraft(s.id) }
    try sbd.waitFor("the POST") { !sbd.posts().isEmpty }

    let post = try sbd.draftPost(s.id)
    let recorded = try sbd.postingEvents(s.id)
    try sbd.openGhGate(gate)

    #expect(post?["state"]?.string == "posting", "\(String(describing: post))")
    #expect(recorded.count == 1)
    _ = first()
  }

  /// A failed store refuses the post, so gh never runs without a record of the attempt.
  @Test func aPostWhoseAttemptCantBeStoredIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    let r = try sbd.whileTheLogIsLocked { try sbd.postDraft(s.id) }

    #expect(r.status != 0, "\(r.stdout)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  // MARK: Definite failures, which the user may post again

  @Test func aRefusedLoginIsFailedWithTheLoginStep() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRouteFails("POST", replyPath, stderr: "gh: Bad credentials (HTTP 401)\n")

    let r = try sbd.postDraft(s.id)

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains(loginRefusal), "\(r.stderr)")
    let post = try sbd.waitForPost(s.id, "failed")
    #expect(post["error"]?.string?.contains(loginRefusal) == true, "\(post)")
  }

  enum Definite: String, CaseIterable, CustomTestStringConvertible {
    case unauthorized, forbidden, notFound, unprocessable, notLoggedIn
    var testDescription: String { rawValue }

    var stderr: String {
      switch self {
      case .unauthorized: "gh: Bad credentials (HTTP 401)\n"
      case .forbidden: "gh: Resource not accessible by integration (HTTP 403)\n"
      case .notFound: "gh: Not Found (HTTP 404)\n"
      case .unprocessable: "gh: Validation Failed (HTTP 422)\n"
      case .notLoggedIn:
        "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n"
      }
    }

    var status: Int32 { self == .notLoggedIn ? 4 : 1 }
  }

  @Test(arguments: Definite.allCases)
  func aDefiniteFailureIsFailedAndTheDraftCanBePostedAgain(_ failure: Definite) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRouteFails("POST", replyPath, stderr: failure.stderr, status: failure.status)
    let r = try sbd.postDraft(s.id)
    #expect(r.status != 0, "\(r.stdout)")
    try sbd.waitForPost(s.id, "failed")

    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let again = try sbd.postDraft(s.id)

    #expect(again.status == 0, "\(again.stderr)")
    #expect(again.stdout.contains("Posted: \(postedURL)"), "\(again.stdout)")
    #expect(sbd.posts().count == 2, "\(sbd.ghCalls())")
    try sbd.waitForPost(s.id, "posted")
  }

  @Test func aDeletedThreadSaysSo() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRouteFails("POST", replyPath, stderr: "gh: Not Found (HTTP 404)\n")

    _ = try sbd.postDraft(s.id)

    let post = try sbd.waitForPost(s.id, "failed")
    #expect(post["error"]?.string?.contains("the thread is gone from GitHub") == true, "\(post)")
  }

  // MARK: Unknown outcomes, which a check settles

  enum Unclear: String, CaseIterable, CustomTestStringConvertible {
    case badGateway, serverError, connectionReset, garbage
    var testDescription: String { rawValue }

    func route(_ sbd: Instance) throws {
      switch self {
      case .badGateway: try sbd.ghRouteFails("POST", replyPath, stderr: "gh: Bad Gateway (HTTP 502)\n")
      case .serverError: try sbd.ghRouteFails("POST", replyPath, stderr: "gh: Server Error (HTTP 500)\n")
      case .connectionReset:
        try sbd.ghRouteFails(
          "POST", replyPath,
          stderr:
            "Post \"https://api.github.com/\(replyPath)\": read tcp 10.0.0.2:50000->140.82.112.6:443: read: connection reset by peer\n"
        )
      case .garbage: try sbd.ghRoute("POST", replyPath, text: "<html>upstream timed out</html>")
      }
    }
  }

  /// The reply may be on GitHub, so a second POST could duplicate it. A check settles it first.
  @Test(arguments: Unclear.allCases)
  func anUnclearOutcomeIsUnknownAndRefusesAnotherPost(_ outcome: Unclear) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.checksFail()
    try outcome.route(sbd)

    let r = try sbd.postDraft(s.id)

    #expect(r.status != 0, "\(r.stdout)")
    try sbd.waitForPost(s.id, "unknown")
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let again = try sbd.postDraft(s.id)
    #expect(again.status != 0, "\(again.stdout)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  /// sbd's gh timeout for a post is 60 s. The stub sleeps past it.
  @Test func aPostThatOutlastsTheTimeoutIsUnknown() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.checksFail()
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    try sbd.ghRouteSleeps("POST", replyPath, seconds: 62)

    let r = try sbd.postDraft(s.id)

    #expect(r.status != 0, "\(r.stdout)")
    try sbd.waitForPost(s.id, "unknown")
    try sbd.ghRouteSleeps("POST", replyPath, seconds: nil)
    let again = try sbd.postDraft(s.id)
    #expect(again.status != 0, "\(again.stdout)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  /// The tick may check an unknown outcome once on its own. The checks fail
  /// until the test waited out that check, so `sb draft check` settles it.
  private func unknownSession(_ github: FakeGitHub, _ sbd: Instance) throws -> SessionSummary {
    let s = try readySession(github, sbd)
    try sbd.checksFail()
    try sbd.ghRouteFails("POST", replyPath, stderr: "gh: Bad Gateway (HTTP 502)\n")
    _ = try sbd.postDraft(s.id)
    try sbd.waitForPost(s.id, "unknown")
    Thread.sleep(forTimeInterval: 3)
    return s
  }

  @Test func checkAgainFindsTheReplyAndMarksItPosted() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try unknownSession(github, sbd)
    try sbd.checksFind([listedReply(4001, by: "ann", body: "Unrelated."), listedReply(5001)])

    _ = try sbd.run(["draft", "check", s.id, "1"])

    let post = try sbd.settledOutcome(s.id)
    #expect(post["state"]?.string == "posted", "\(post)")
    #expect(post["url"]?.string == postedURL, "\(post)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  @Test func checkAgainOfAnIssueCommentReplyListsTheConversation() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", "repos/PostHog/charts/issues/comments/2001", json: issueCommentJSON(2001))
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#issuecomment-2001", text: draftText))
    try sbd.waitForPost(s.id, "ready")
    try sbd.checksFail(list: conversationPath)
    try sbd.ghRouteFails("POST", conversationPath, stderr: "gh: Bad Gateway (HTTP 502)\n")
    _ = try sbd.postDraft(s.id)
    try sbd.waitForPost(s.id, "unknown")
    Thread.sleep(forTimeInterval: 3)
    try sbd.checksFind([listedComment(6001)], list: conversationPath)

    _ = try sbd.run(["draft", "check", s.id, "1"])

    let post = try sbd.settledOutcome(s.id)
    #expect(post["state"]?.string == "posted", "\(post)")
    #expect(post["url"]?.string == "\(pullURL)#issuecomment-6001", "\(post)")
  }

  /// A reply by someone else, in another thread, or with other text is not the user's reply.
  @Test func checkAgainWithoutAMatchMarksItFailedAndTheNextPostWorks() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try unknownSession(github, sbd)
    try sbd.checksFind([
      listedReply(4001, by: "ann"), listedReply(4002, inReplyTo: 9999), listedReply(4003, body: "Another reply."),
    ])

    _ = try sbd.run(["draft", "check", s.id, "1"])

    let post = try sbd.settledOutcome(s.id)
    #expect(post["state"]?.string == "failed", "\(post)")
    #expect(post["error"]?.string?.contains("no such reply") == true, "\(post)")
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let again = try sbd.postDraft(s.id)
    #expect(again.status == 0, "\(again.stderr)")
    #expect(sbd.posts().count == 2, "\(sbd.ghCalls())")
  }

  @Test func aCheckThatErrsLeavesTheOutcomeUnknown() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try unknownSession(github, sbd)

    _ = try sbd.run(["draft", "check", s.id, "1"])

    #expect(try sbd.draftPost(s.id)?["state"]?.string == "unknown")
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let again = try sbd.postDraft(s.id)
    #expect(again.status != 0, "\(again.stdout)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  /// sbd crashes between `draft_posting` and the outcome. The restarted sbd
  /// can't know whether GitHub got the reply, so it marks the draft unknown
  /// and its tick checks the thread.
  @Test func aRestartDuringAPostLeavesItUnknownAndTheTickChecksIt() throws {
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let gate = try sbd.ghGate("POST", replyPath)
    defer { sbd.releaseGhGate(gate) }
    let first = inBackground { try sbd.postDraft(s.id) }
    try sbd.waitFor("the POST") { !sbd.posts().isEmpty }
    try sbd.waitFor("draft_posting") { try !sbd.postingEvents(s.id).isEmpty }
    let userGate = try sbd.ghGate("GET", "user")
    defer { sbd.releaseGhGate(userGate) }
    sbd.killSbd()
    sbd.releaseGhGate(gate)
    _ = first()

    try sbd.startSbd()

    let unknown = try sbd.waitForPost(s.id, "unknown")
    #expect(unknown["error"]?.string?.contains("sbd restarted while it was posting") == true, "\(unknown)")
    let refused = try sbd.postDraft(s.id)
    #expect(refused.status != 0, "\(refused.stdout)")
    try sbd.waitFor("the tick to check the thread") { sbd.askedForTheLogin() }
    try sbd.checksFind([listedReply(5001)])
    try sbd.openGhGate(userGate)
    let post = try sbd.settledOutcome(s.id)
    #expect(post["state"]?.string == "posted", "\(post)")
    #expect(post["url"]?.string == postedURL, "\(post)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  // MARK: Parity: the tick and `sb draft check` settle an unknown outcome alike

  @Test(arguments: [true, false])
  func theTickAndCheckAgainReachTheSameState(_ found: Bool) throws {
    let thread = found ? [listedReply(5001)] : [listedReply(5001, body: "Another reply.")]
    let checkedHub = try FakeGitHub()
    let checking = try Instance.withReplyStub(checkedHub)
    let a = try unknownSession(checkedHub, checking)
    try checking.checksFind(thread)
    _ = try checking.run(["draft", "check", a.id, "1"])
    let checked = try checking.settledOutcome(a.id)

    let tickedHub = try FakeGitHub()
    defer { withExtendedLifetime(tickedHub) {} }
    let ticking = try Instance.withReplyStub(tickedHub)
    let b = try readySession(tickedHub, ticking)
    try ticking.ghRoute("POST", replyPath, json: createdJSON())
    let gate = try ticking.ghGate("POST", replyPath)
    defer { ticking.releaseGhGate(gate) }
    let first = inBackground { try ticking.postDraft(b.id) }
    try ticking.waitFor("the POST") { !ticking.posts().isEmpty }
    try ticking.waitFor("draft_posting") { try !ticking.postingEvents(b.id).isEmpty }
    ticking.killSbd()
    ticking.releaseGhGate(gate)
    _ = first()
    try ticking.checksFind(thread)
    try ticking.startSbd()
    let ticked = try ticking.settledOutcome(b.id)

    #expect(checked["state"]?.string == (found ? "posted" : "failed"), "\(checked)")
    #expect(ticked["state"] == checked["state"], "tick: \(ticked), check: \(checked)")
    #expect(ticked["url"] == checked["url"], "tick: \(ticked), check: \(checked)")
  }

  // MARK: The duplicate rule across cards

  /// A new card is a new ref. The log already holds a post with the same
  /// root and the same draft text, so the draft shows that post.
  @Test func aNewCardWithTheSameDraftShowsPostedAndRefusesAPost() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    try sbd.sb("draft", "post", s.id, "1", "--text", "An edited reply.")
    let oldRef = try #require(try sbd.get(s.id).triage?.ref)

    try sbd.setSummary(s.id, replyCard(commentURL, text: draftText))
    try sbd.waitFor(s.id, "the new card") { $0.triage?.ref != oldRef && $0.triage?.source == .session }

    let post = try sbd.waitForPost(s.id, "posted")
    #expect(post["url"]?.string == postedURL, "\(post)")
    let r = try sbd.postDraft(s.id)
    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("already posted at \(postedURL)"), "\(r.stderr)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  @Test func aNewCardWithOtherTextForTheSameTargetPosts() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    try sbd.sb("draft", "post", s.id, "1")
    let oldRef = try #require(try sbd.get(s.id).triage?.ref)

    try sbd.setSummary(s.id, replyCard(commentURL, text: "A follow-up: the tests pass now."))
    try sbd.waitFor(s.id, "the new card") { $0.triage?.ref != oldRef && $0.triage?.source == .session }

    try sbd.waitForPost(s.id, "ready")
    try sbd.ghRoute("POST", replyPath, json: createdJSON(5002, url: "\(pullURL)#discussion_r5002"))
    let r = try sbd.postDraft(s.id)
    #expect(r.status == 0, "\(r.stderr)")
    #expect(sbd.posts().count == 2, "\(sbd.ghCalls())")
  }

  /// The first card's POST may have reached GitHub. A new card with the same
  /// text and target must not post again until a check settles the first.
  @Test func aNewCardWithTheSameDraftAsAnUnknownPostIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try unknownSession(github, sbd)
    let oldRef = try #require(try sbd.get(s.id).triage?.ref)

    try sbd.setSummary(s.id, replyCard(commentURL, text: draftText))
    try sbd.waitFor(s.id, "the new card") { $0.triage?.ref != oldRef && $0.triage?.source == .session }
    try sbd.settledPost(s.id)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let r = try sbd.postDraft(s.id)

    #expect(r.status != 0, "\(r.stdout)")
    #expect(sbd.posts().count == 1, "\(sbd.ghCalls())")
  }

  // MARK: Refusals before any POST

  enum NotPostable: String, CaseIterable, CustomTestStringConvertible {
    case noTarget, copyOnly, unresolved, checking
    var testDescription: String { rawValue }
  }

  @Test(arguments: NotPostable.allCases)
  func aDraftThatIsNotReadyIsRefused(_ state: NotPostable) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let card: String
    var gate: String?
    defer { gate.map(sbd.releaseGhGate) }
    switch state {
    case .noTarget:
      card = JSON.object(["summary": "Drafted a note.\nSend it.", "drafts": [["text": .string(draftText)]]]).text
    case .copyOnly:
      card = replyCard("https://github.com/PostHog/other/pull/18303#discussion_r1001", text: draftText)
    case .unresolved:
      card = replyCard(commentURL, text: draftText)
    case .checking:
      try sbd.ghRoute("GET", commentPath, json: reviewCommentJSON(1001))
      gate = try sbd.ghGate("GET", commentPath)
      card = replyCard(commentURL, text: draftText)
    }
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let s = try sessionWithCard(github, sbd, card: card)
    if state == .checking {
      try sbd.waitFor("gh to read the comment") { !sbd.ghCalls("api \(commentPath)").isEmpty }
    } else {
      try sbd.settledPost(s.id)
    }

    let r = try sbd.postDraft(s.id)

    #expect(r.status != 0, "\(r.stdout)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  @Test func aDraftNumberThatTheItemDoesNotHaveIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    let r = try sbd.postDraft(s.id, 2)

    #expect(r.status != 0, "\(r.stdout)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
  }

  /// The caller names the item it saw. A new card since then is another item.
  @Test func aStaleRefIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let ref = try #require(try sbd.get(s.id).triage?.ref)
    try sbd.setSummary(s.id, replyCard(commentURL, text: draftText))
    try sbd.waitFor(s.id, "the new card") { $0.triage?.ref != ref && $0.triage?.source == .session }

    do {
      _ = try sbd.client.call(
        "draft-post", ["session": .string(s.id), "ref": .string(ref), "draft": 1, "text": .string(draftText)],
        timeout: 60)
      Issue.record("draft-post accepted the stale ref \(ref)")
    } catch {
      #expect("\(error)".contains("has a new item since you looked. Look again"), "\(error)")
    }
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  // MARK: Risk 3: only the user's press posts

  @Test func sbRefusesToPostInsideClaudeCode() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())

    let r = try sbd.run(["draft", "post", s.id, "1"], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(!r.stderr.isEmpty)
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  /// The client runs in the session's own shell pane. It skips sb, so only sbd's caller check can refuse it.
  @Test func sbdRefusesAPostFromTheSessionsShellPane() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let ref = try #require(try sbd.get(s.id).triage?.ref)
    let terminals = try sbd.client.terminals(s.id)
    // A tick installs a snapshot that holds the shell pane's pid.
    try sbd.advanceClock(1)
    let request: JSON = [
      "op": "draft-post",
      "args": ["session": .string(s.id), "ref": .string(ref), "draft": 1, "text": .string(draftText)],
    ]
    try sbd.writeScript("inside-post", socketClient(request))

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/inside-post.sh\"")
    let r = try sbd.scriptResult("inside-post")

    let response = try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    #expect(response["ok"]?.bool == false, "\(response)")
    let error = response["error"]?.string ?? ""
    #expect(error.contains("`sb draft post` runs inside \(s.id)"), "\(response)")
    #expect(error.contains("Posting needs your click"), "\(response)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  /// Another session's Claude runs the client as a tool call, which would post this session's draft.
  @Test func sbdRefusesAPostFromAnotherSessionsClaudePane() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let ref = try #require(try sbd.get(s.id).triage?.ref)
    let other = try sbd.new(prompt: "hello", name: "other")
    try sbd.waitFor(other.id, "the other session's reply") { $0.lastReply == "Done: hello" }
    // A tick installs a snapshot that holds the other session's Claude pane.
    try sbd.advanceClock(1)
    let request: JSON = [
      "op": "draft-post",
      "args": ["session": .string(s.id), "ref": .string(ref), "draft": 1, "text": .string(draftText)],
    ]
    try sbd.writeScript("inside-post", socketClient(request))

    try sbd.sb("send", other.id, "run inside-post")
    let r = try sbd.scriptResult("inside-post")

    let response = try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    #expect(response["ok"]?.bool == false, "\(response)")
    let error = response["error"]?.string ?? ""
    #expect(error.contains("`sb draft post` runs inside \(other.id)"), "\(response)")
    #expect(error.contains("Posting needs your click"), "\(response)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  /// A session that runs `tmux new-session` starts the client below sbd's
  /// tmux server, outside every pane that sbd names for a session. The test
  /// asks the server for the same thing.
  @Test func sbdRefusesAPostFromAWindowThatASessionOpened() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let ref = try #require(try sbd.get(s.id).triage?.ref)
    let terminals = try sbd.client.terminals(s.id)
    let request: JSON = [
      "op": "draft-post",
      "args": ["session": .string(s.id), "ref": .string(ref), "draft": 1, "text": .string(draftText)],
    ]
    try sbd.writeScript("opened-post", socketClient(request))

    let opened = try runCommand(
      terminals.tmux,
      [
        "-S", terminals.socket, "new-session", "-d", "-s", "opened-by-a-session", "-e", "SB_HOME=\(sbd.home.path)",
        "sh \"$SB_HOME/opened-post.sh\"",
      ])
    try #require(opened.status == 0, "\(opened.stderr)")
    let r = try sbd.scriptResult("opened-post")

    let response = try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    #expect(response["ok"]?.bool == false, "\(response)")
    let error = response["error"]?.string ?? ""
    #expect(error.contains("`sb draft post` runs in sbd's tmux server"), "\(response)")
    #expect(error.contains("Posting needs your click"), "\(response)")
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  /// No card option posts. An unknown action such as `post` is dropped, and
  /// `choose` can't name a draft.
  @Test func noCardOptionPostsADraft() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", commentPath, json: reviewCommentJSON(1001))
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    let card = JSON.object([
      "summary": "Drafted a reply to ann.\nPost it when it reads right.",
      "options": [["label": "Post the reply", "action": "post"], ["label": "Skip", "action": "done"]],
      "drafts": [["label": "Reply to ann", "text": .string(draftText), "replyTo": .string(commentURL)]],
    ]).text
    let s = try sessionWithCard(github, sbd, card: card)
    try sbd.waitForPost(s.id, "ready")

    let options = try sbd.get(s.id).triage?.options.map(\.label) ?? []
    let byLabel = try sbd.run(["choose", s.id, "Post the reply"])
    let byDraft = try sbd.run(["choose", s.id, "Reply to ann"])

    #expect(!options.contains("Post the reply"), "\(options)")
    #expect(byLabel.status != 0, "\(byLabel.stdout)")
    #expect(byDraft.status != 0, "\(byDraft.stdout)")
    Thread.sleep(forTimeInterval: 1)
    #expect(sbd.posts().isEmpty, "\(sbd.ghCalls())")
    #expect(try sbd.postingEvents(s.id).isEmpty)
  }

  @Test func noMCPToolNamesADraftOp() throws {
    let sbd = try Instance.withReplyStub(try FakeGitHub())
    let mcp = try MCPClient(sbd)

    let tools = try mcp.tools()

    try #require(!tools.isEmpty)
    for tool in tools {
      let name = tool["name"]?.string ?? ""
      let description = tool["description"]?.string ?? ""
      #expect(!name.lowercased().contains("draft"), "\(name)")
      for op in ["draft-post", "draft_post", "draft-check", "draft_check", "draft post", "draft check"] {
        #expect(!description.contains(op), "\(name): \(description)")
      }
    }
  }

  // MARK: Risk 6: the session hears about the post once

  @Test func theNextPromptCarriesTheNoticeOnce() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    try sbd.sb("draft", "post", s.id, "1")
    let before = contexts(sbd, s).count

    try sbd.sb("send", s.id, "next")
    try sbd.waitFor(s.id, "the reply to next", timeout: 30) { $0.lastReply == "Done: next" }

    let notices = contexts(sbd, s).dropFirst(before).filter { $0.contains(noticeLead) }
    #expect(notices.count == 1, "\(contexts(sbd, s))")
    let notice = notices.first ?? ""
    #expect(notice.contains(postedURL), "\(notice)")
    #expect(notice.contains("Reply to ann"), "\(notice)")
    #expect(!notice.contains("the user edited it"), "\(notice)")
    #expect(try sbd.events(s.id).contains { $0.kind == "replies_heard" })
    let heard = contexts(sbd, s).count

    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the reply to again", timeout: 30) { $0.lastReply == "Done: again" }

    let later = contexts(sbd, s).dropFirst(heard)
    #expect(later.allSatisfy { !$0.contains(noticeLead) }, "\(Array(later))")
  }

  @Test func theNoticeCarriesTheEditedText() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    let edited = "Good catch. I reworded the NOT handling and added a test."
    try sbd.ghRoute("POST", replyPath, json: createdJSON(body: edited))
    try sbd.sb("draft", "post", s.id, "1", "--text", edited)
    let before = contexts(sbd, s).count

    try sbd.sb("send", s.id, "next")
    try sbd.waitFor(s.id, "the reply to next", timeout: 30) { $0.lastReply == "Done: next" }

    let notice = contexts(sbd, s).dropFirst(before).first { $0.contains(noticeLead) } ?? ""
    #expect(notice.contains("the user edited it:"), "\(notice)")
    #expect(notice.contains(edited), "\(notice)")
  }

  /// `sb send` to a stopped session starts claude with the prompt. The
  /// notice may come with SessionStart or with UserPromptSubmit, once.
  @Test func aResumedSessionHearsTheNoticeOnce() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try readySession(github, sbd)
    try sbd.ghRoute("POST", replyPath, json: createdJSON())
    try sbd.sb("draft", "post", s.id, "1")
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil && !$0.live }
    let before = contexts(sbd, s).count

    try sbd.sb("send", s.id, "next")
    try sbd.waitFor(s.id, "the reply to next", timeout: 30) { $0.lastReply == "Done: next" }

    let notices = contexts(sbd, s).dropFirst(before).filter { $0.contains(noticeLead) }
    #expect(notices.count == 1, "\(contexts(sbd, s))")
    #expect(notices.first?.contains(postedURL) == true, "\(notices)")
  }
}
