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
