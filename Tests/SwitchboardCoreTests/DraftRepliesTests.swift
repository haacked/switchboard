import Foundation
import Testing

@testable import SwitchboardCore

/// A review comment on samplePR's PR, acme/widgets#42.
private let commentURL = "https://github.com/acme/widgets/pull/42#discussion_r1001"
/// The ref of the item that `drafted` builds: the summary event's id is 2.
private let cardRef = "summary:2"

/// samplePR's PR as a draft whose checks run, so no rule decides the
/// session's state and the session's card stays its item.
private func quietPR() -> PullRequest { samplePR(draft: true, checks: "PENDING") }

private let resolvedComment = ResolvedTarget(
  target: ReplyTarget(repo: "acme/widgets", pr: 42, kind: .reviewComment, id: 1001), root: 1001, author: "ann",
  path: "a.swift", line: 3, excerpt: "Why not use a guard?", url: commentURL)

private func inboxDraft(replyTo: String?, number: Int = 1) -> InboxDraft {
  var draft = InboxDraft(TriageDraft(label: "Reply to ann", text: "Good catch, fixed."), number: number)
  draft.replyTo = replyTo
  return draft
}

/// The `draft_target` event that sbd records once it resolved the draft, or
/// failed to: `result` holds `resolved`, `refused`, or `error`.
private func targetEvent(_ id: Int64, ref: String = cardRef, number: Int = 1, _ result: [String: JSON]) -> Event {
  var data: [String: JSON] = ["ref": .string(ref), "number": .number(Double(number))]
  data.merge(result) { $1 }
  return Event(id: id, session: "s1", t: id, kind: "draft_target", data: .object(data))
}

private func resolvedEvent(_ id: Int64, ref: String = cardRef, _ target: ResolvedTarget = resolvedComment) throws
  -> Event
{
  targetEvent(id, ref: ref, ["resolved": try JSON(encoding: target)])
}

/// A turn that ended in prose with the session's card, whose one draft
/// replies to `replyTo`, then `more` events, on `pr`.
private func drafted(
  replyTo: String? = commentURL, pr: PullRequest? = quietPR(), _ more: [Event] = []
) throws -> SessionFacts {
  var card = sessionCard
  card.drafts = [TriageDraft(label: "Reply to ann", text: "Good catch, fixed.", replyTo: replyTo)]
  var f = facts(
    [event("UserPromptSubmit", 0, ["prompt": "go"]), try summaryEvent(2, 1, card), stop(3, 2, proseQuestion)] + more)
  f.pr = pr
  return f
}

/// The `post` of the item's first draft.
private func firstPost(_ f: SessionFacts) throws -> DraftPost {
  let item = try #require(itemOf(f))
  try #require(item.source == .session)
  return try #require(item.drafts.first).post
}

@Suite struct DraftRepliesTests {
  // MARK: Each branch of the state's order

  @Test func aDraftWithoutReplyToIsCopyOnlyWithoutAReason() {
    let post = DraftReplies.state(inboxDraft(replyTo: nil), ref: cardRef, pr: quietPR(), facts: DraftReplyFacts())

    #expect(post == .copyOnly(reason: nil))
  }

  @Test(arguments: [
    "https://github.com/acme/widgets/pull/42", "http://github.com/acme/widgets/pull/42#discussion_r1001",
    "https://github.com/acme/widgets/pull/42#discussion_r0", "null", "",
  ])
  func aReplyToThatDoesNotParseIsCopyOnlyWithAReason(_ url: String) {
    let post = DraftReplies.state(inboxDraft(replyTo: url), ref: cardRef, pr: quietPR(), facts: DraftReplyFacts())

    guard case .copyOnly(let reason) = post else {
      Issue.record("\(post) is not copyOnly")
      return
    }
    #expect(!(reason ?? "").isEmpty)
  }

  @Test func aTargetBeforeThePollerReadThePRIsCopyOnly() {
    let post = DraftReplies.state(inboxDraft(replyTo: commentURL), ref: cardRef, pr: nil, facts: DraftReplyFacts())

    #expect(post == .copyOnly(reason: "sbd hasn't read this session's PR yet"))
  }

  @Test(arguments: [
    ("https://github.com/acme/gadgets/pull/42#discussion_r1001", "acme/gadgets#42"),
    ("https://github.com/acme/widgets/pull/43#discussion_r1001", "acme/widgets#43"),
  ])
  func aTargetOnAnotherPRIsCopyOnlyAndNamesBoth(_ url: String, _ named: String) {
    let post = DraftReplies.state(inboxDraft(replyTo: url), ref: cardRef, pr: quietPR(), facts: DraftReplyFacts())

    #expect(post == .copyOnly(reason: "it replies on \(named), and the session's PR is acme/widgets#42"))
  }

  /// A recorded resolution for this ref and number would otherwise make it
  /// ready. The PR check still comes first.
  @Test func aTargetOnAnotherPRIsCopyOnlyEvenWithAResolution() {
    let facts = DraftReplyFacts(targets: ["\(cardRef)/1": .resolved(resolvedComment)])
    let url = "https://github.com/acme/widgets/pull/43#discussion_r1001"

    let post = DraftReplies.state(inboxDraft(replyTo: url), ref: cardRef, pr: quietPR(), facts: facts)

    guard case .copyOnly = post else {
      Issue.record("\(post) is not copyOnly")
      return
    }
  }

  @Test func aTargetWhoseRepoDiffersOnlyInCaseIsChecked() {
    let url = "https://github.com/Acme/Widgets/pull/42#discussion_r1001"

    let post = DraftReplies.state(inboxDraft(replyTo: url), ref: cardRef, pr: quietPR(), facts: DraftReplyFacts())

    #expect(post == .checking)
  }

  @Test func aTargetWithoutAResolutionIsChecking() {
    let post = DraftReplies.state(
      inboxDraft(replyTo: commentURL), ref: cardRef, pr: quietPR(), facts: DraftReplyFacts())

    #expect(post == .checking)
  }

  @Test func aFailedResolutionIsUnresolvedWithItsError() {
    let error = "GitHub has no comment 1001, or gh can't see it"
    let facts = DraftReplyFacts(targets: ["\(cardRef)/1": .failed(error)])

    let post = DraftReplies.state(inboxDraft(replyTo: commentURL), ref: cardRef, pr: quietPR(), facts: facts)

    #expect(post == .unresolved(error: error))
  }

  @Test func aRefusedResolutionIsCopyOnlyWithItsReason() {
    let reason = "GitHub reports a reply chain deeper than one, so sbd can't find the thread's root"
    let facts = DraftReplyFacts(targets: ["\(cardRef)/1": .refused(reason)])

    let post = DraftReplies.state(inboxDraft(replyTo: commentURL), ref: cardRef, pr: quietPR(), facts: facts)

    #expect(post == .copyOnly(reason: reason))
  }

  @Test func aResolvedTargetIsReady() {
    let facts = DraftReplyFacts(targets: ["\(cardRef)/1": .resolved(resolvedComment)])

    let post = DraftReplies.state(inboxDraft(replyTo: commentURL), ref: cardRef, pr: quietPR(), facts: facts)

    #expect(post == .ready(resolvedComment))
  }

  /// A resolution under the draft's key that names another comment than
  /// the draft's `replyTo` is not this draft's resolution.
  @Test func aResolutionOfAnotherCommentLeavesTheDraftChecking() {
    var other = resolvedComment
    other.target.id = 1002
    let facts = DraftReplyFacts(targets: ["\(cardRef)/1": .resolved(other)])

    let post = DraftReplies.state(inboxDraft(replyTo: commentURL), ref: cardRef, pr: quietPR(), facts: facts)

    #expect(post == .checking)
  }

  /// A resolution names one (ref, number), so it says nothing about a draft
  /// of another card or another draft of the same card.
  @Test(arguments: [("summary:9", 1), (cardRef, 2)])
  func aResolutionOfAnotherDraftLeavesThisOneChecking(_ ref: String, _ number: Int) {
    let facts = DraftReplyFacts(targets: ["\(ref)/\(number)": .resolved(resolvedComment)])

    let post = DraftReplies.state(inboxDraft(replyTo: commentURL), ref: cardRef, pr: quietPR(), facts: facts)

    #expect(post == .checking)
  }

  // MARK: Facts from events, through the item

  @Test func theSessionsDraftIsCheckingUntilARecordedResolution() throws {
    #expect(try firstPost(try drafted()) == .checking)
  }

  @Test func aResolvedEventMakesTheDraftReady() throws {
    let f = try drafted([try resolvedEvent(4)])

    #expect(try firstPost(f) == .ready(resolvedComment))
  }

  @Test func aFailedEventMakesTheDraftUnresolved() throws {
    let error = "GitHub has no comment 1001, or gh can't see it"

    let f = try drafted([targetEvent(4, ["error": .string(error)])])

    #expect(try firstPost(f) == .unresolved(error: error))
  }

  @Test func aRefusedEventMakesTheDraftCopyOnly() throws {
    let reason = "GitHub places comment 1001 on acme/widgets#1"

    let f = try drafted([targetEvent(4, ["refused": .string(reason)])])

    #expect(try firstPost(f) == .copyOnly(reason: reason))
  }

  @Test func theLatestDraftTargetWins() throws {
    let f = try drafted([
      targetEvent(4, ["error": "GitHub has no comment 1001, or gh can't see it"]), try resolvedEvent(5),
    ])

    #expect(try firstPost(f) == .ready(resolvedComment))
  }

  @Test func aLaterFailureReplacesAnEarlierResolution() throws {
    let f = try drafted([try resolvedEvent(4), targetEvent(5, ["error": "gh: Bad credentials (HTTP 401)"])])

    guard case .unresolved = try firstPost(f) else {
      Issue.record("the later failure did not win")
      return
    }
  }

  @Test func aResolutionOfAnEarlierCardDoesNotReachANewCard() throws {
    let f = try drafted([try resolvedEvent(4, ref: "summary:1")])

    #expect(try firstPost(f) == .checking)
  }

  @Test(arguments: [
    samplePR(draft: true, checks: "PENDING").with(number: 7),
    samplePR(draft: true, checks: "PENDING").with(repo: "acme/gadgets"),
  ])
  func aPRChangeAfterResolutionTurnsReadyIntoCopyOnly(_ newPR: PullRequest) throws {
    var f = try drafted([try resolvedEvent(4)])
    try #require(try firstPost(f) == .ready(resolvedComment))

    f.pr = newPR

    guard case .copyOnly(let reason) = try firstPost(f) else {
      Issue.record("a PR change left the draft ready")
      return
    }
    #expect(reason?.contains("acme/widgets#42") == true)
  }

  @Test func aPRThatDropsOutAfterResolutionTurnsReadyIntoCopyOnly() throws {
    var f = try drafted([try resolvedEvent(4)])

    f.pr = nil

    #expect(try firstPost(f) == .copyOnly(reason: "sbd hasn't read this session's PR yet"))
  }

  @Test func aDraftWithoutReplyToStaysCopyOnlyWithAResolutionForItsKey() throws {
    let f = try drafted(replyTo: nil, [try resolvedEvent(4)])

    #expect(try firstPost(f) == .copyOnly(reason: nil))
  }

  // MARK: Guard (a): only the session's own card carries a target

  /// A `triage` event that holds a draft with `replyTo`, as an older or
  /// tampered summary might, still gives a copy-only draft.
  @Test func aSummarizerItemIsCopyOnlyEvenWithReplyToAndAResolution() throws {
    let triage = Event(
      id: 4, session: "s1", t: 100, kind: "triage",
      data: [
        "stop": 3, "title": "Post the reply", "kind": "info", "summary": "It drafted one.", "options": [],
        "drafts": [["label": "Reply to ann", "text": "Good catch, fixed.", "replyTo": .string(commentURL)]],
      ])
    var f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(3, 2, "Post this:\n\nGood catch, fixed."), triage,
      try resolvedEvent(5, ref: "stop:3"),
    ])
    f.pr = quietPR()

    let item = try #require(itemOf(f))

    #expect(item.source == .summary)
    #expect(item.drafts.map(\.post) == [DraftPost.copyOnly(reason: nil)])
  }

  // MARK: Coding

  static let states: [DraftPost] = [
    .copyOnly(reason: nil), .copyOnly(reason: "sbd hasn't read this session's PR yet"), .checking,
    .unresolved(error: "GitHub has no comment 1001, or gh can't see it"), .ready(resolvedComment),
  ]

  @Test(arguments: states)
  func eachStateRoundTrips(_ post: DraftPost) throws {
    #expect(try JSONCoding.convert(try JSON(encoding: post), to: DraftPost.self) == post)
  }

  @Test(arguments: zip(states, ["copyOnly", "copyOnly", "checking", "unresolved", "ready"]))
  func eachStateEncodesItsName(_ post: DraftPost, _ name: String) throws {
    #expect(try JSON(encoding: post)["state"]?.string == name)
  }

  @Test func copyOnlyWithoutAReasonHasNoReasonKey() throws {
    let json = try JSON(encoding: DraftPost.copyOnly(reason: nil))

    #expect(json == ["state": "copyOnly"])
  }

  @Test func copyOnlyCarriesItsReason() throws {
    let json = try JSON(encoding: DraftPost.copyOnly(reason: "it replies on acme/gadgets#42"))

    #expect(json["reason"]?.string == "it replies on acme/gadgets#42")
  }

  @Test func unresolvedCarriesItsError() throws {
    let json = try JSON(encoding: DraftPost.unresolved(error: "gh: Bad credentials (HTTP 401)"))

    #expect(json["error"]?.string == "gh: Bad credentials (HTTP 401)")
  }

  /// `target` is flat: the reply target's fields sit beside the resolution's.
  @Test func readyCarriesTheFlatTarget() throws {
    let json = try JSON(encoding: DraftPost.ready(resolvedComment))

    let target = try #require(json["target"])
    #expect(target["kind"]?.string == "reviewComment")
    #expect(target["repo"]?.string == "acme/widgets")
    #expect(target["pr"]?.int == 42)
    #expect(target["id"]?.int == 1001)
    #expect(target["root"]?.int == 1001)
    #expect(target["author"]?.string == "ann")
    #expect(target["path"]?.string == "a.swift")
    #expect(target["line"]?.int == 3)
    #expect(target["excerpt"]?.string == "Why not use a guard?")
    #expect(target["url"]?.string == commentURL)
  }

  @Test func aTargetWithoutAPathOrLineLeavesThemOut() throws {
    let review = ResolvedTarget(
      target: ReplyTarget(repo: "acme/widgets", pr: 42, kind: .review, id: 3001), root: 3001, author: "carol",
      path: nil, line: nil, excerpt: "One question inline.",
      url: "https://github.com/acme/widgets/pull/42#pullrequestreview-3001")

    let target = try #require(try JSON(encoding: DraftPost.ready(review))["target"])

    #expect(target["path"] == nil)
    #expect(target["line"] == nil)
  }

  // MARK: The item's JSON

  @Test func theItemsDraftsCarryTheirNumberReplyToAndPost() throws {
    let item = try #require(itemOf(try drafted([try resolvedEvent(4)])))

    let draft = try #require(try JSON(encoding: item)["message"]?["summary"]?["drafts"]?.array?.first)

    #expect(draft["number"]?.int == 1)
    #expect(draft["replyTo"]?.string == commentURL)
    #expect(draft["post"]?["state"]?.string == "ready")
  }

  @Test func anItemRoundTripsItsDraftsTargetsAndStates() throws {
    let item = try #require(itemOf(try drafted([try resolvedEvent(4)])))

    let decoded = try JSONCoding.convert(try JSON(encoding: item), to: TriageItem.self)

    #expect(decoded == item)
  }
}

extension PullRequest {
  fileprivate func with(number: Int? = nil, repo: String? = nil) -> PullRequest {
    var pr = self
    if let number { pr.number = number }
    if let repo { pr.repo = repo }
    return pr
  }
}

// MARK: - Stage 3: posting

/// The draft text of the card that `drafted` builds.
private let draftText = "Good catch, fixed."
/// The comment that a post created.
private let postedURL = "https://github.com/acme/widgets/pull/42#discussion_r5001"
private let noticeLead = "Switchboard: the user posted these replies that you drafted. Don't draft or post them again."
private let loginRefusal = "GitHub refused gh's login. Run `gh auth login`, then post again"

/// The `draft_posting` event that sbd records before gh runs.
private func postingEvent(
  _ id: Int64, ref: String = cardRef, number: Int = 1, target: ResolvedTarget = resolvedComment,
  text: String = draftText
) throws -> Event {
  Event(
    id: id, session: "s1", t: id, kind: "draft_posting",
    data: [
      "ref": .string(ref), "number": .number(Double(number)), "target": try JSON(encoding: target),
      "root": .number(Double(target.root)), "text": .string(text), "draftText": .string(draftText),
    ])
}

/// The `draft_posted` event that sbd records once GitHub created the comment.
private func postedEvent(
  _ id: Int64, ref: String = cardRef, number: Int = 1, target: ResolvedTarget = resolvedComment,
  url: String = postedURL, text: String = draftText
) throws -> Event {
  Event(
    id: id, session: "s1", t: id, kind: "draft_posted",
    data: [
      "ref": .string(ref), "number": .number(Double(number)), "target": try JSON(encoding: target),
      "url": .string(url), "id": 5001, "text": .string(text), "draftText": .string(draftText),
      "label": "Reply to ann",
    ])
}

/// A `draft_post_failed` or `draft_post_unknown` event.
private func outcomeEvent(_ id: Int64, _ kind: String, ref: String = cardRef, number: Int = 1, error: String) -> Event {
  Event(
    id: id, session: "s1", t: id, kind: kind,
    data: ["ref": .string(ref), "number": .number(Double(number)), "error": .string(error)])
}

private func result(_ status: Int32, stdout: String = "", stderr: String = "") -> CommandResult {
  CommandResult(status: status, stdout: stdout, stderr: stderr)
}

/// A comment as the check lists it from GitHub.
private func listed(
  _ id: Int64, by login: String = "me", body: String = draftText, inReplyTo: Int64? = 1001,
  createdAt: String = "2026-11-12T10:00:00Z"
) -> JSON {
  var comment: [String: JSON] = [
    "id": .number(Double(id)), "user": ["login": .string(login)], "body": .string(body),
    "html_url": .string("https://github.com/acme/widgets/pull/42#discussion_r\(id)"),
    "created_at": .string(createdAt),
  ]
  if let inReplyTo { comment["in_reply_to_id"] = .number(Double(inReplyTo)) }
  return .object(comment)
}

/// The `state` name that a `post` encodes.
private func stateName(_ post: DraftPost) throws -> String? {
  try JSON(encoding: post)["state"]?.string
}

/// One attempt event, in the order a test lists them.
enum AttemptStep: String, Sendable, CustomTestStringConvertible {
  case posting, posted, failed, unknown
  var testDescription: String { rawValue }
}

/// The events of `steps`, numbered after the resolution, which is event 4.
private func attemptEvents(_ steps: [AttemptStep]) throws -> [Event] {
  try steps.enumerated().map { i, step in
    let id = Int64(5 + i)
    switch step {
    case .posting: return try postingEvent(id)
    case .posted: return try postedEvent(id)
    case .failed: return outcomeEvent(id, "draft_post_failed", error: loginRefusal)
    case .unknown: return outcomeEvent(id, "draft_post_unknown", error: "sbd restarted while it was posting")
    }
  }
}

extension DraftRepliesTests {
  // MARK: The outcome of a POST

  @Test func aCreatedCommentIsPostedWithItsURLAndId() {
    let r = result(0, stdout: #"{"id": 5001, "html_url": "\#(postedURL)", "body": "Good catch, fixed."}"#)

    guard case .posted(let url, let id) = DraftReplies.outcome(r) else {
      Issue.record("\(DraftReplies.outcome(r)) is not posted")
      return
    }
    #expect(url == postedURL)
    #expect(id == 5001)
  }

  /// gh exited 0, so GitHub may have created the comment, but sbd can't read which.
  @Test(arguments: [
    "", "not json", "<html>upstream timed out</html>", "[]", #"{"id": 5001}"#, #"{"html_url": "\#(postedURL)"}"#,
  ])
  func exitZeroWithoutACreatedCommentIsUnknown(_ stdout: String) {
    let outcome = DraftReplies.outcome(result(0, stdout: stdout))

    guard case .unknown = outcome else {
      Issue.record("\(outcome) is not unknown")
      return
    }
  }

  /// GitHub answered with a 4xx, or gh has no login, so no comment exists and the user may post again.
  @Test(
    arguments: [
      ("gh: Bad credentials (HTTP 401)\n", 1),
      ("gh: Resource not accessible by integration (HTTP 403)\n", 1),
      ("gh: Not Found (HTTP 404)\n", 1),
      ("gh: Validation Failed (HTTP 422)\n", 1),
      (
        "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n",
        4
      ),
    ] as [(String, Int32)])
  func aDefiniteRefusalIsFailed(_ stderr: String, _ status: Int32) {
    let outcome = DraftReplies.outcome(result(status, stderr: stderr))

    guard case .failed = outcome else {
      Issue.record("\(outcome) is not failed")
      return
    }
  }

  /// The reply may be on GitHub. A timeout's SIGTERM gives status 15 and no stderr.
  @Test(
    arguments: [
      ("gh: Bad Gateway (HTTP 502)\n", 1),
      ("gh: Server Error (HTTP 500)\n", 1),
      ("", 15),
      (
        "Post \"https://api.github.com/repos/acme/widgets/pulls/42/comments/1001/replies\": read tcp 10.0.0.2:50000->140.82.112.6:443: read: connection reset by peer\n",
        1
      ),
      ("error connecting to api.github.com\n", 1),
    ] as [(String, Int32)])
  func anUnclearFailureIsUnknown(_ stderr: String, _ status: Int32) {
    let outcome = DraftReplies.outcome(result(status, stderr: stderr))

    guard case .unknown = outcome else {
      Issue.record("\(outcome) is not unknown")
      return
    }
  }

  @Test func aRefusedLoginAsksForGhAuthLogin() {
    let outcome = DraftReplies.outcome(result(1, stderr: "gh: Bad credentials (HTTP 401)\n"))

    guard case .failed(let message) = outcome else {
      Issue.record("\(outcome) is not failed")
      return
    }
    #expect(message.contains(loginRefusal), "\(message)")
  }

  // MARK: The body that a post sends

  @Test(arguments: [
    ("\n\nHello there.\n\n", "Hello there."), ("\r\n\r\nHi\r\n", "Hi"), ("a\r\n\r\nb\r\n", "a\r\n\r\nb"),
    ("  Leading spaces stay.", "  Leading spaces stay."), (" \n\t\nLine one\n  - item\n \n", "Line one\n  - item"),
    ("   ", ""), ("\r\n", ""),
  ])
  func theBodyDropsOnlyLeadingAndTrailingBlankLines(_ text: String, _ body: String) {
    #expect(TriageDrafts.trimBlankLines(text) == body)
  }

  // MARK: plainError

  @Test func plainErrorOf401AsksForGhAuthLogin() {
    let message = DraftReplies.plainError("gh: Bad credentials (HTTP 401)\n")

    #expect(message.contains(loginRefusal), "\(message)")
  }

  @Test func plainErrorOf404SaysTheThreadIsGone() {
    let message = DraftReplies.plainError("gh: Not Found (HTTP 404)\n")

    #expect(message.contains("the thread is gone from GitHub"), "\(message)")
  }

  @Test func plainErrorOf422GivesGitHubsMessage() {
    let message = DraftReplies.plainError("gh: Validation Failed (HTTP 422)\n")

    #expect(message.contains("Validation Failed"), "\(message)")
  }

  @Test func plainErrorOfAnyOtherFailureGivesGhsText() {
    let message = DraftReplies.plainError("gh: Resource not accessible by integration (HTTP 403)\n")

    #expect(message.contains("Resource not accessible by integration"), "\(message)")
  }

  // MARK: matchingReply

  @Test func matchingReplyFindsTheUsersReplyInTheThread() throws {
    let comments = [listed(4001, by: "ann", body: "Why not use a guard?", inReplyTo: nil), listed(5001)]

    let match = try #require(DraftReplies.matchingReply(in: comments, root: 1001, login: "me", text: draftText))

    #expect(match.url == "https://github.com/acme/widgets/pull/42#discussion_r5001")
    #expect(match.id == 5001)
  }

  @Test(arguments: ["Good catch,\r\nfixed.\r\n", "Good catch,\nfixed.  \n\n"])
  func matchingReplyIgnoresCRLFAndTrailingWhitespace(_ body: String) {
    let comments = [listed(5001, body: body)]

    let match = DraftReplies.matchingReply(in: comments, root: 1001, login: "me", text: "Good catch,\nfixed.")

    #expect(match?.id == 5001)
  }

  @Test func matchingReplyIgnoresAnotherAuthor() {
    let comments = [listed(5001, by: "ann")]

    #expect(DraftReplies.matchingReply(in: comments, root: 1001, login: "me", text: draftText) == nil)
  }

  @Test func matchingReplyIgnoresAnotherThread() {
    let comments = [listed(5001, inReplyTo: 9999)]

    #expect(DraftReplies.matchingReply(in: comments, root: 1001, login: "me", text: draftText) == nil)
  }

  /// The thread's root replies to nothing, so it is not a reply in the thread, even with the same author and text.
  @Test func matchingReplyIgnoresTheThreadsRoot() {
    let comments = [listed(1001, inReplyTo: nil)]

    #expect(DraftReplies.matchingReply(in: comments, root: 1001, login: "me", text: draftText) == nil)
  }

  @Test func matchingReplyIgnoresAnotherBody() {
    let comments = [listed(5001, body: "Good catch, fixed in the next commit.")]

    #expect(DraftReplies.matchingReply(in: comments, root: 1001, login: "me", text: draftText) == nil)
  }

  @Test func matchingReplyTakesTheNewestOfTwoMatches() {
    let comments = [
      listed(5001, createdAt: "2026-11-01T10:00:00Z"), listed(5002, createdAt: "2026-11-12T10:00:00Z"),
    ]

    #expect(DraftReplies.matchingReply(in: comments, root: 1001, login: "me", text: draftText)?.id == 5002)
  }

  /// A reply to an issue comment or a review is a PR conversation comment, which has no thread.
  @Test func matchingReplyWithoutARootMatchesAConversationComment() {
    let comments = [listed(6001, inReplyTo: nil)]

    #expect(DraftReplies.matchingReply(in: comments, root: nil, login: "me", text: draftText)?.id == 6001)
  }

  // MARK: Folding the attempt events

  @Test func aPostingEventMakesTheDraftPostingWithItsTarget() throws {
    let f = try drafted([try resolvedEvent(4), try postingEvent(5)])

    guard case .posting(let target) = try firstPost(f) else {
      Issue.record("\(try firstPost(f)) is not posting")
      return
    }
    #expect(target == resolvedComment)
  }

  @Test func aPostedEventMakesTheDraftPostedWithItsURLAndText() throws {
    let edited = "Good catch, fixed in abc123."
    let f = try drafted([try resolvedEvent(4), try postingEvent(5, text: edited), try postedEvent(6, text: edited)])

    guard case .posted(let target, let url, let text) = try firstPost(f) else {
      Issue.record("\(try firstPost(f)) is not posted")
      return
    }
    #expect(target.root == 1001)
    #expect(url == postedURL)
    #expect(text == edited)
  }

  @Test(arguments: [("draft_post_failed", "failed"), ("draft_post_unknown", "unknown")])
  func aFailedOrUnknownEventCarriesItsError(_ kind: String, _ state: String) throws {
    let f = try drafted([try resolvedEvent(4), try postingEvent(5), outcomeEvent(6, kind, error: "gh: oops")])

    let post = try firstPost(f)

    #expect(try stateName(post) == state)
    #expect(try JSON(encoding: post)["error"]?.string == "gh: oops")
  }

  @Test(
    arguments: [
      ([.posting], "posting"),
      ([.posting, .posted], "posted"),
      ([.posting, .failed], "failed"),
      ([.posting, .unknown], "unknown"),
      ([.posting, .unknown, .posted], "posted"),
      ([.posting, .unknown, .failed], "failed"),
      ([.posting, .failed, .posting], "posting"),
      ([.posting, .failed, .posting, .posted], "posted"),
      ([.posting, .failed, .posting, .unknown], "unknown"),
    ] as [([AttemptStep], String)])
  func eachEventOrderFoldsToTheLatestAttempt(_ steps: [AttemptStep], _ expected: String) throws {
    let f = try drafted([try resolvedEvent(4)] + (try attemptEvents(steps)))

    #expect(try stateName(try firstPost(f)) == expected)
  }

  /// An attempt names one (ref, number), so it says nothing about another card's draft or another draft.
  @Test(arguments: [("summary:9", 1), (cardRef, 2)])
  func anAttemptOnAnotherDraftLeavesThisOneReady(_ ref: String, _ number: Int) throws {
    let f = try drafted([
      try resolvedEvent(4), try postingEvent(5, ref: ref, number: number),
      outcomeEvent(6, "draft_post_unknown", ref: ref, number: number, error: "gh: oops"),
    ])

    #expect(try firstPost(f) == .ready(resolvedComment))
  }

  // MARK: Recorded attempts outrank the live checks

  @Test(
    arguments: [[.posting], [.posting, .posted], [.posting, .unknown], [.posting, .failed]] as [[AttemptStep]],
    [
      nil, samplePR(draft: true, checks: "PENDING").with(number: 7),
      samplePR(draft: true, checks: "PENDING").with(repo: "acme/gadgets"),
    ] as [PullRequest?])
  func anAttemptKeepsItsStateWhenThePRChanges(_ steps: [AttemptStep], _ newPR: PullRequest?) throws {
    var f = try drafted([try resolvedEvent(4)] + (try attemptEvents(steps)))
    let before = try firstPost(f)

    f.pr = newPR

    #expect(try firstPost(f) == before)
    #expect(try stateName(before) == steps.last?.rawValue)
  }

  @Test func aPostedLinkSurvivesThePRDroppingOut() throws {
    var f = try drafted([try resolvedEvent(4), try postingEvent(5), try postedEvent(6)])

    f.pr = nil

    guard case .posted(_, let url, _) = try firstPost(f) else {
      Issue.record("\(try firstPost(f)) is not posted")
      return
    }
    #expect(url == postedURL)
  }

  // MARK: The duplicate rule across cards

  /// The first card's draft posted `postedText`. A second card, which has a
  /// new ref, then has one draft with `text` that replies to `replyTo`, which
  /// gh resolved to `resolved`.
  private func redrafted(
    text: String = draftText, replyTo: String = commentURL, resolved: ResolvedTarget = resolvedComment,
    postedText: String = "An edited reply."
  ) throws -> SessionFacts {
    var f = try drafted([
      try resolvedEvent(4), try postingEvent(5, text: postedText), try postedEvent(6, text: postedText),
    ])
    var card = sessionCard
    card.drafts = [TriageDraft(label: "Reply to ann", text: text, replyTo: replyTo)]
    f.apply(try summaryEvent(7, 7, card))
    f.apply(try resolvedEvent(8, ref: "summary:7", resolved))
    return f
  }

  @Test func aNewCardWithTheSameTextAndTargetShowsTheEarlierPost() throws {
    let f = try redrafted()
    try #require(itemOf(f)?.ref == "summary:7")

    guard case .posted(_, let url, _) = try firstPost(f) else {
      Issue.record("\(try firstPost(f)) is not posted")
      return
    }
    #expect(url == postedURL)
  }

  /// The second card names a reply in the same thread, so the post would go to the same root.
  @Test func aNewCardThatNamesAReplyInTheSameThreadShowsTheEarlierPost() throws {
    let reply = ResolvedTarget(
      target: ReplyTarget(repo: "acme/widgets", pr: 42, kind: .reviewComment, id: 1002), root: 1001, author: "dan",
      path: "a.swift", line: 3, excerpt: "Agreed.", url: "https://github.com/acme/widgets/pull/42#discussion_r1002")

    let f = try redrafted(replyTo: "https://github.com/acme/widgets/pull/42#discussion_r1002", resolved: reply)

    #expect(try stateName(try firstPost(f)) == "posted")
  }

  @Test func aNewCardWithOtherTextForTheSameTargetIsReady() throws {
    let f = try redrafted(text: "A follow-up: the tests pass now.")

    #expect(try firstPost(f) == .ready(resolvedComment))
  }

  @Test func aNewCardWithTheSameTextForAnotherThreadIsReady() throws {
    let other = ResolvedTarget(
      target: ReplyTarget(repo: "acme/widgets", pr: 42, kind: .reviewComment, id: 1003), root: 1003, author: "ann",
      path: "b.swift", line: 9, excerpt: "And here?", url: "https://github.com/acme/widgets/pull/42#discussion_r1003")

    let f = try redrafted(replyTo: "https://github.com/acme/widgets/pull/42#discussion_r1003", resolved: other)

    #expect(try firstPost(f) == .ready(other))
  }

  // MARK: The notice to the session

  private func noticeAfterPosting(_ text: String) throws -> String {
    let f = try drafted([try resolvedEvent(4), try postingEvent(5, text: text), try postedEvent(6, text: text)])
    return DraftReplies.notice(f.draftReplies.posted)
  }

  @Test func theNoticeLeadsWithWhatTheUserDid() throws {
    #expect(try noticeAfterPosting(draftText).hasPrefix(noticeLead))
  }

  @Test func theNoticeNamesTheRepliesLabelAndURL() throws {
    let notice = try noticeAfterPosting(draftText)

    #expect(notice.contains("Reply to ann"), "\(notice)")
    #expect(notice.contains(postedURL), "\(notice)")
  }

  @Test func theNoticeOfAnUneditedReplyDoesNotRepeatItsText() throws {
    let notice = try noticeAfterPosting(draftText)

    #expect(!notice.contains("the user edited it"), "\(notice)")
  }

  @Test func theNoticeOfAnEditedReplyCarriesThePostedText() throws {
    let edited = "Good catch. I reworded the NOT handling and added a test."

    let notice = try noticeAfterPosting(edited)

    #expect(notice.contains("the user edited it:"), "\(notice)")
    #expect(notice.contains(edited), "\(notice)")
  }

  @Test func theNoticeCutsAnEditedTextAt2000Characters() throws {
    let edited = String(repeating: "a", count: 2_000) + "ZQXJ the tail past the cut"

    let notice = try noticeAfterPosting(edited)

    #expect(notice.contains(String(repeating: "a", count: 1_990)), "\(notice.count)")
    #expect(!notice.contains("ZQXJ"), "\(notice.suffix(200))")
    #expect(notice.contains(postedURL), "\(notice.suffix(200))")
  }

  @Test func repliesHeardRecordsWhereTheSessionHeardThrough() throws {
    let f = try drafted([
      try resolvedEvent(4), try postingEvent(5), try postedEvent(6),
      Event(id: 7, session: "s1", t: 7, kind: "replies_heard", data: ["through": 6]),
    ])

    #expect(f.draftReplies.heardThrough == 6)
    #expect(f.draftReplies.posted.count == 1)
  }

  // MARK: Coding of the attempt states

  static let attemptStates: [DraftPost] = [
    .posting(resolvedComment), .unknown(resolvedComment, error: "sbd restarted while it was posting"),
    .failed(resolvedComment, error: loginRefusal), .posted(resolvedComment, url: postedURL, text: draftText),
  ]

  @Test(arguments: attemptStates)
  func eachAttemptStateRoundTrips(_ post: DraftPost) throws {
    #expect(try JSONCoding.convert(try JSON(encoding: post), to: DraftPost.self) == post)
  }

  @Test(arguments: zip(attemptStates, ["posting", "unknown", "failed", "posted"]))
  func eachAttemptStateEncodesItsName(_ post: DraftPost, _ name: String) throws {
    #expect(try stateName(post) == name)
  }

  @Test func postedCarriesItsURLTextAndTarget() throws {
    let json = try JSON(encoding: DraftPost.posted(resolvedComment, url: postedURL, text: draftText))

    #expect(json["url"]?.string == postedURL)
    #expect(json["text"]?.string == draftText)
    #expect(json["target"]?["root"]?.int == 1001)
  }

  @Test func failedCarriesItsErrorAndTarget() throws {
    let json = try JSON(encoding: DraftPost.failed(resolvedComment, error: loginRefusal))

    #expect(json["error"]?.string == loginRefusal)
    #expect(json["target"]?["id"]?.int == 1001)
  }
}
