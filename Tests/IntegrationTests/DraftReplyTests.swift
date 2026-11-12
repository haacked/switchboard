import Foundation
import SwitchboardCore
import Testing

/// PostHog/charts#18303, which the fixture records for MergeTests.branch.
private let pullURL = "https://github.com/PostHog/charts/pull/18303"
/// How GitHub's REST answers name #18303.
private let apiPull = "https://api.github.com/repos/PostHog/charts/pulls/18303"
private let apiIssue = "https://api.github.com/repos/PostHog/charts/issues/18303"

private let draftText = "Good catch. The NOT now wraps the whole AND, fixed in abc123."

/// A session's card with one draft that replies to `replyTo`.
func replyCard(_ replyTo: String, label: String = "Reply to ann", text: String = draftText) -> String {
  JSON.object([
    "summary": "Drafted a reply to ann's review comment.\nPost it when it reads right.",
    "drafts": [["label": .string(label), "text": .string(text), "replyTo": .string(replyTo)]],
  ]).text
}

/// A review comment as `GET repos/{o}/{r}/pulls/comments/{id}` answers it.
func reviewCommentJSON(
  _ id: Int64, on pullRequest: String = apiPull, by login: String = "ann", body: String = "Why not use a guard?",
  path: String = "a.swift", line: Int = 3, inReplyTo: Int64? = nil
) -> JSON {
  var comment: [String: JSON] = [
    "id": .number(Double(id)), "pull_request_url": .string(pullRequest), "user": ["login": .string(login)],
    "path": .string(path), "line": .number(Double(line)), "body": .string(body),
    "html_url": .string("\(pullURL)#discussion_r\(id)"),
  ]
  if let inReplyTo { comment["in_reply_to_id"] = .number(Double(inReplyTo)) }
  return .object(comment)
}

/// An issue comment as `GET repos/{o}/{r}/issues/comments/{id}` answers it.
func issueCommentJSON(_ id: Int64, on issue: String = apiIssue, by login: String = "bob") -> JSON {
  [
    "id": .number(Double(id)), "issue_url": .string(issue), "user": ["login": .string(login)],
    "body": "Can this land before Friday?", "html_url": .string("\(pullURL)#issuecomment-\(id)"),
  ]
}

/// A review as `GET repos/{o}/{r}/pulls/{n}/reviews/{id}` answers it.
func reviewJSON(_ id: Int64, on pullRequest: String = apiPull, by login: String = "carol") -> JSON {
  [
    "id": .number(Double(id)), "pull_request_url": .string(pullRequest), "user": ["login": .string(login)],
    "body": "Looks close. One question inline.", "state": "COMMENTED",
    "html_url": .string("\(pullURL)#pullrequestreview-\(id)"),
  ]
}

extension FakeGitHub {
  /// Makes #18303 a draft whose checks run. No PR rule then gives the
  /// session an item of its own, and the PR is neither Ready to merge nor
  /// waiting on a review.
  func pinQuietDraft() {
    change(MergeTests.number) { $0["isDraft"] = true }
    checks(MergeTests.number, "PENDING")
  }
}

/// A session on #18303's branch, whose PR the poller has read, with `card`
/// as the card it wrote. It returns once the card is the session's item.
@discardableResult
func sessionWithCard(_ github: FakeGitHub, _ sbd: Instance, card: String) throws -> SessionSummary {
  github.pinQuietDraft()
  let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
  try sbd.poll()
  try sbd.setSummary(s.id, card)
  return try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }
}

extension Instance {
  /// The drafts of the session's item, as `sb get --json` prints them.
  func draftsJSON(_ id: String) throws -> [JSON] {
    try getJSON(id)["triage"]?["message"]?["summary"]?["drafts"]?.array ?? []
  }

  /// The `post` of the session's draft with the 1-based `number`.
  func draftPost(_ id: String, _ number: Int = 1) throws -> JSON? {
    let drafts = try draftsJSON(id)
    return drafts.indices.contains(number - 1) ? drafts[number - 1]["post"] : nil
  }

  /// Waits until the draft's `post` has a state other than `checking`, and returns it.
  @discardableResult
  func settledPost(_ id: String, _ number: Int = 1) throws -> JSON {
    try waitFor(
      "draft \(number)'s target state to settle", fetch: { try draftPost(id, number) },
      until: { ($0["state"]?.string).map { $0 != "checking" } ?? false })
  }

  /// Waits until the draft's `post` has the state, and returns it.
  @discardableResult
  func waitForPost(_ id: String, _ state: String, _ number: Int = 1) throws -> JSON {
    try waitFor(
      "draft \(number) to be \(state)", fetch: { try draftPost(id, number) },
      until: { $0["state"]?.string == state })
  }

  /// Lets a call that `ghGate` holds go on when the stub waits on the FIFO,
  /// without blocking when it doesn't, and removes the FIFO.
  func releaseGhGate(_ gate: String) {
    let fd = open(gate, O_WRONLY | O_NONBLOCK)
    if fd >= 0 {
      _ = "go\n".withCString { write(fd, $0, 3) }
      close(fd)
    }
    try? FileManager.default.removeItem(atPath: gate)
  }
}

/// A session's card can name the GitHub comment that a draft replies to.
/// sbd checks the target with gh and shows each draft's state through
/// `sb get --json`, `sb triage`, and `sb draft check`. Nothing posts.
@Suite(.blocking(timeLimit: .seconds(120))) struct DraftReplyTests {
  static let commentPath = "repos/PostHog/charts/pulls/comments/1001"

  // MARK: Targets that reach ready

  @Test func aReviewCommentTargetIsReadyWithItsAuthorAndExcerpt() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "ready", "\(post)")
    let target = try #require(post["target"])
    #expect(target["kind"]?.string == "reviewComment")
    #expect(target["repo"]?.string == "PostHog/charts")
    #expect(target["pr"]?.int == 18303)
    #expect(target["id"]?.int == 1001)
    #expect(target["root"]?.int == 1001)
    #expect(target["author"]?.string == "ann")
    #expect(target["path"]?.string == "a.swift")
    #expect(target["line"]?.int == 3)
    #expect(target["excerpt"]?.string == "Why not use a guard?")
    #expect(target["url"]?.string == "\(pullURL)#discussion_r1001")
  }

  @Test func theItemCarriesTheDraftsNumberAndReplyTo() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))

    let draft = try #require(try sbd.draftsJSON(s.id).first)
    #expect(draft["number"]?.int == 1)
    #expect(draft["replyTo"]?.string == "\(pullURL)#discussion_r1001")
    #expect(draft["text"]?.string == draftText)
  }

  /// A reply in a review thread answers the thread, so the post goes to its root.
  @Test func aReplyCommentTargetIsReadyWithItsParentAsTheRoot() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    try sbd.ghRoute(
      "GET", "repos/PostHog/charts/pulls/comments/1002",
      json: reviewCommentJSON(1002, by: "dan", body: "Agreed, a guard reads better.", inReplyTo: 1001))

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)/files#r1002"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "ready", "\(post)")
    #expect(post["target"]?["id"]?.int == 1002)
    #expect(post["target"]?["root"]?.int == 1001)
  }

  @Test func anIssueCommentTargetIsReady() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", "repos/PostHog/charts/issues/comments/2001", json: issueCommentJSON(2001))

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#issuecomment-2001"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "ready", "\(post)")
    #expect(post["target"]?["kind"]?.string == "issueComment")
    #expect(post["target"]?["author"]?.string == "bob")
  }

  @Test func aReviewTargetIsReady() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", "repos/PostHog/charts/pulls/18303/reviews/3001", json: reviewJSON(3001))

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#pullrequestreview-3001"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "ready", "\(post)")
    #expect(post["target"]?["kind"]?.string == "review")
    #expect(post["target"]?["author"]?.string == "carol")
  }

  /// The repo in the URL and the session's PR differ only in case, which GitHub ignores.
  @Test func aTargetWhoseRepoDiffersOnlyInCaseIsReady() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", "repos/posthog/CHARTS/pulls/comments/1001", json: reviewCommentJSON(1001))
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))

    let s = try sessionWithCard(
      github, sbd, card: replyCard("https://github.com/posthog/CHARTS/pull/18303#discussion_r1001"))

    #expect(try sbd.settledPost(s.id)["state"]?.string == "ready")
  }

  // MARK: Failures that `sb draft check` retries

  @Test func aCommentThatGitHubDoesNotFindIsUnresolvedAndCheckAgainResolvesIt() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))

    let failed = try sbd.settledPost(s.id)

    #expect(failed["state"]?.string == "unresolved", "\(failed)")
    #expect(failed["error"]?.string?.contains("or gh can't see it") == true, "\(failed)")
    #expect(failed["error"]?.string?.contains("1001") == true, "\(failed)")
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    let printed = try #require(JSON.parse(try sbd.sb("draft", "check", s.id, "1", "--json")))
    #expect(printed["message"]?["summary"]?["drafts"]?.array?.first?["post"]?["state"]?.string == "ready", "\(printed)")
    #expect(try sbd.draftPost(s.id)?["state"]?.string == "ready")
  }

  @Test func aRefusedLoginIsUnresolvedAndCheckAgainResolvesIt() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRouteFails("GET", Self.commentPath, stderr: "gh: Bad credentials (HTTP 401)\n")
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))

    let failed = try sbd.settledPost(s.id)

    #expect(failed["state"]?.string == "unresolved", "\(failed)")
    #expect(failed["error"]?.string?.contains("gh auth login") == true, "\(failed)")
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    try sbd.sb("draft", "check", s.id, "1")
    #expect(try sbd.draftPost(s.id)?["state"]?.string == "ready")
  }

  @Test func aNetworkFailureIsUnresolvedWithGhsText() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let text = "error connecting to api.github.com"
    try sbd.ghRouteFails("GET", Self.commentPath, stderr: "\(text)\n")

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))

    let failed = try sbd.settledPost(s.id)
    #expect(failed["state"]?.string == "unresolved", "\(failed)")
    #expect(failed["error"]?.string?.contains(text) == true, "\(failed)")
  }

  /// gh exits 0 with an answer that is not a whole comment, so Check again can read it later.
  @Test(arguments: [
    "not json", #"{"id": 1001, "pull_request_url": "\#(apiPull)", "html_url": "\#(pullURL)#discussion_r1001"}"#,
  ])
  func anAnswerThatIsNotACommentIsUnresolved(_ answer: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, text: answer)

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "unresolved", "\(post)")
  }

  /// A tick while gh reads the comment starts no second read.
  @Test func theTickStartsNoSecondReadWhileOneRuns() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    let gate = try sbd.ghGate("GET", Self.commentPath)
    defer { sbd.releaseGhGate(gate) }
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))
    try sbd.waitFor("gh to read the comment") { !sbd.ghCalls("api \(Self.commentPath)").isEmpty }

    // sbd ticks once a second.
    Thread.sleep(forTimeInterval: 3)
    try sbd.openGhGate(gate)

    try sbd.waitForPost(s.id, "ready")
    #expect(sbd.ghCalls("api \(Self.commentPath)").count == 1, "\(sbd.ghCalls())")
  }

  /// Only `sb draft check` retries a failed resolution. The tick does not.
  @Test func theTickDoesNotRetryAFailedResolution() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))
    try sbd.waitForPost(s.id, "unresolved")

    // sbd ticks once a second.
    Thread.sleep(forTimeInterval: 3)

    #expect(sbd.ghCalls("api \(Self.commentPath)").count == 1, "\(sbd.ghCalls())")
  }

  /// The card arrives before the poller has read the session's PR, so sbd
  /// can't yet tell whether the target is on it.
  @Test func aCardSetBeforeThePollerReadThePRIsCopyOnlyUntilThePoll() throws {
    let github = try FakeGitHub()
    github.pinQuietDraft()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.setSummary(s.id, replyCard("\(pullURL)#discussion_r1001"))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let before = try sbd.settledPost(s.id)
    try sbd.poll()

    #expect(before["state"]?.string == "copyOnly", "\(before)")
    #expect(before["reason"]?.string == "sbd hasn't read this session's PR yet", "\(before)")
    try sbd.waitForPost(s.id, "ready")
  }

  // MARK: sb triage

  @Test func triagePrintsTheDraftsNumberLabelAndPostCommand() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))
    try sbd.waitForPost(s.id, "ready")

    let text = try sbd.sb("triage")

    #expect(text.contains("Draft 1: Reply to ann"), "\(text)")
    #expect(text.contains("Replies to @ann on a.swift line 3. Post it: sb draft post \(s.id) 1"), "\(text)")
  }

  @Test func triagePrintsCheckingWhileGhReadsTheComment() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    let gate = try sbd.ghGate("GET", Self.commentPath)
    defer { sbd.releaseGhGate(gate) }
    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1001"))
    try sbd.waitFor("gh to read the comment") { !sbd.ghCalls("api \(Self.commentPath)").isEmpty }

    let text = try sbd.sb("triage")

    #expect(text.contains("Checking the comment on GitHub…"), "\(text)")
    try sbd.openGhGate(gate)
    try sbd.waitForPost(s.id, "ready")
  }

  @Test func triagePrintsTheCopyOnlyReason() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try sessionWithCard(
      github, sbd, card: replyCard("https://github.com/PostHog/other/pull/18303#discussion_r1001"))
    let reason = try #require(try sbd.settledPost(s.id)["reason"]?.string)

    let text = try sbd.sb("triage")

    #expect(text.contains("Copy only: \(reason)"), "\(text)")
  }

  @Test func summaryHelpDocumentsReplyTo() throws {
    let sbd = try Instance()

    let help = try sbd.sb("summary", "help")

    #expect(help.contains("replyTo"))
  }

  // MARK: Guard (a): only the session's own card names a target

  /// The model's summary reads reply text that can quote PR comments, so a
  /// target it names could come from quoted text. sbd drops it, so no gh call
  /// runs even though the target would resolve.
  @Test func aSummarizerDraftWithReplyToIsCopyOnlyAndCallsNoGh() throws {
    let github = try FakeGitHub()
    github.pinQuietDraft()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    try "Here's a reply you can post:\n\n\(draftText)\n".write(
      toFile: "\(sbd.home.path)/drafted.md", atomically: true, encoding: .utf8)
    let answer: JSON = [
      "title": "Post the reply", "kind": "info", "summary": "It drafted a reply to ann.", "options": [],
      "drafts": [
        [
          "label": "Reply to ann", "text": .string(draftText),
          "replyTo": .string("\(pullURL)#discussion_r1001"),
        ]
      ],
    ]
    try answer.text.write(toFile: "\(sbd.home.path)/summary-answer.json", atomically: true, encoding: .utf8)

    try sbd.sb("send", s.id, "reply drafted")

    let drafts = try sbd.waitFor(
      "the model's draft", fetch: { try sbd.draftsJSON(s.id) },
      until: { $0.first?["text"]?.string == draftText })
    #expect(try sbd.get(s.id).triage?.source == .summary)
    #expect(drafts.first?["replyTo"] == nil, "\(drafts)")
    #expect(drafts.first?["post"]?["state"]?.string == "copyOnly", "\(drafts)")
    #expect(drafts.first?["post"]?["reason"] == nil, "\(drafts)")
    Thread.sleep(forTimeInterval: 3)
    #expect(sbd.ghCalls("api").isEmpty, "\(sbd.ghCalls())")
  }

  // MARK: Guard (b): the URL parses to one kind and id

  @Test(arguments: [
    "http://github.com/PostHog/charts/pull/18303#discussion_r1001",
    "https://github.example.com/PostHog/charts/pull/18303#discussion_r1001",
    "https://github.com/PostHog/charts/pull/18303",
    "https://github.com/PostHog/charts/pull/18303#discussion_r0",
    "https://github.com/PostHog/charts/pull/18303#discussion_r1001x",
    "https://github.com/PostHog/charts/pull/18303?w=1#discussion_r1001",
    "https://github.com/PostHog/charts/issues/18303#issuecomment-1001",
  ])
  func aTargetThatDoesNotParseIsCopyOnlyAndCallsNoGh(_ url: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try sessionWithCard(github, sbd, card: replyCard(url))

    let post = try sbd.settledPost(s.id)

    #expect(post["state"]?.string == "copyOnly", "\(post)")
    let reason = post["reason"]?.string ?? ""
    #expect(!reason.isEmpty, "\(post)")
    Thread.sleep(forTimeInterval: 2)
    #expect(sbd.ghCalls("api").isEmpty, "\(sbd.ghCalls())")
  }

  // MARK: Guard (c): the target names the session's current PR

  @Test(arguments: [
    ("https://github.com/PostHog/other/pull/18303#discussion_r1001", "PostHog/other#18303"),
    ("https://github.com/PostHog/charts/pull/1#discussion_r1001", "PostHog/charts#1"),
  ])
  func aTargetOnAnotherPRIsCopyOnlyAndCallsNoGh(_ url: String, _ named: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    let s = try sessionWithCard(github, sbd, card: replyCard(url))

    let post = try sbd.settledPost(s.id)

    #expect(post["state"]?.string == "copyOnly", "\(post)")
    #expect(
      post["reason"]?.string == "it replies on \(named), and the session's PR is PostHog/charts#18303", "\(post)")
    Thread.sleep(forTimeInterval: 2)
    #expect(sbd.ghCalls("api").isEmpty, "\(sbd.ghCalls())")
  }

  // MARK: Guard (d): GitHub places the comment on the session's PR

  /// The URL says #18303, and GitHub says the comment is on another PR or in another repo.
  @Test(arguments: [
    (
      "discussion_r1001", "repos/PostHog/charts/pulls/comments/1001",
      reviewCommentJSON(1001, on: "https://api.github.com/repos/PostHog/charts/pulls/1")
    ),
    (
      "discussion_r1001", "repos/PostHog/charts/pulls/comments/1001",
      reviewCommentJSON(1001, on: "https://api.github.com/repos/PostHog/other/pulls/18303")
    ),
    (
      "discussion_r1001", "repos/PostHog/charts/pulls/comments/1001",
      reviewCommentJSON(1001, on: "https://api.github.com/repos/PostHog/charts/pulls/183030")
    ),
    (
      "issuecomment-2001", "repos/PostHog/charts/issues/comments/2001",
      issueCommentJSON(2001, on: "https://api.github.com/repos/PostHog/charts/issues/7")
    ),
    (
      "pullrequestreview-3001", "repos/PostHog/charts/pulls/18303/reviews/3001",
      reviewJSON(3001, on: "https://api.github.com/repos/PostHog/charts/pulls/2")
    ),
  ])
  func aCommentThatGitHubPlacesElsewhereIsCopyOnly(_ fragment: String, _ path: String, _ answer: JSON) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", path, json: answer)

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#\(fragment)"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "copyOnly", "\(post)")
    let reason = post["reason"]?.string ?? ""
    #expect(!reason.isEmpty, "\(post)")
  }

  // MARK: Guard (e): a review comment reply goes to its thread's root

  @Test func aReplyWhoseParentIsAlsoAReplyIsCopyOnly() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    try sbd.ghRoute("GET", "repos/PostHog/charts/pulls/comments/1002", json: reviewCommentJSON(1002, inReplyTo: 1001))
    try sbd.ghRoute("GET", "repos/PostHog/charts/pulls/comments/1003", json: reviewCommentJSON(1003, inReplyTo: 1002))

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1003"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "copyOnly", "\(post)")
    #expect(post["reason"]?.string?.contains("deeper than one") == true, "\(post)")
  }

  @Test func aReplyWhoseRootIsOnAnotherPRIsCopyOnly() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute(
      "GET", Self.commentPath, json: reviewCommentJSON(1001, on: "https://api.github.com/repos/PostHog/charts/pulls/1"))
    try sbd.ghRoute("GET", "repos/PostHog/charts/pulls/comments/1002", json: reviewCommentJSON(1002, inReplyTo: 1001))

    let s = try sessionWithCard(github, sbd, card: replyCard("\(pullURL)#discussion_r1002"))

    let post = try sbd.settledPost(s.id)
    #expect(post["state"]?.string == "copyOnly", "\(post)")
  }

  // MARK: Parity: sb get --json and sb triage show the same state

  enum Shown: String, CaseIterable, CustomTestStringConvertible {
    case ready, copyOnly, checking
    var testDescription: String { rawValue }
  }

  /// The line that `sb triage` prints for the draft's `post` in `sb get --json`.
  static func expectedLine(_ post: JSON, session: String) throws -> String {
    switch post["state"]?.string {
    case "ready":
      let t = try #require(post["target"])
      let author = try #require(t["author"]?.string)
      let path = try #require(t["path"]?.string)
      let line = try #require(t["line"]?.int)
      return "Replies to @\(author) on \(path) line \(line). Post it: sb draft post \(session) 1"
    case "copyOnly":
      return "Copy only: \(try #require(post["reason"]?.string))"
    case "checking":
      return "Checking the comment on GitHub…"
    default:
      throw TestError(description: "no triage line for \(post)")
    }
  }

  @Test(arguments: Shown.allCases)
  func getJSONAndTriageShowTheSameState(_ shown: Shown) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withReplyStub(github)
    try sbd.ghRoute("GET", Self.commentPath, json: reviewCommentJSON(1001))
    let gate = shown == .checking ? try sbd.ghGate("GET", Self.commentPath) : nil
    defer { gate.map(sbd.releaseGhGate) }
    let url =
      shown == .copyOnly
      ? "https://github.com/PostHog/other/pull/18303#discussion_r1001" : "\(pullURL)#discussion_r1001"
    let s = try sessionWithCard(github, sbd, card: replyCard(url))
    if gate != nil {
      try sbd.waitFor("gh to read the comment") { !sbd.ghCalls("api \(Self.commentPath)").isEmpty }
    } else {
      try sbd.settledPost(s.id)
    }

    let post = try #require(try sbd.draftPost(s.id))
    let text = try sbd.sb("triage")

    #expect(post["state"]?.string == shown.rawValue, "\(post)")
    #expect(text.contains(try Self.expectedLine(post, session: s.id)), "\(text)")
  }
}
