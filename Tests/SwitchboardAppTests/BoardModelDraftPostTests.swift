import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A model whose `send` holds each request until `release` is signaled, and counts the requests.
@MainActor
private func heldModel() -> (BoardModel, DispatchSemaphore, Counter) {
  let model = offlineModel()
  let release = DispatchSemaphore(value: 0)
  let requests = Counter()
  model.send = { _, _ in
    requests.increment()
    release.wait()
    return .null
  }
  return (model, release, requests)
}

/// A session whose Inbox item is its own card under `ref`, with one draft per state in `posts`, numbered from 1.
private func withDrafts(_ id: String, ref: String = "summary:1", _ posts: [DraftPost]) -> SessionSummary {
  var s = needsItem(id)
  let drafts = posts.enumerated().map { i, post in targetedDraft(post, number: i + 1, text: "Draft \(i + 1)") }
  s.triage = TriageItem(
    title: "Reply to ann", kind: .review, summary: "", drafts: drafts, source: .session, ref: ref)
  return s
}

private let sessionText = "Good catch, fixed in the next commit."

@MainActor
@Suite struct BoardModelDraftPostTests {
  let key = MessageDrafts.replyKey(session: "a", ref: "summary:1", number: 1)

  // MARK: The request

  @Test func aPostSendsDraftPostWithTheSessionRefNumberAndEditedText() async {
    let sent = await firstRequest { $0.postDraft("a", ref: "summary:1", number: 2, text: "Thanks, fixed in abc123.") }

    #expect(sent.op == "draft-post")
    #expect(sent.args == ["session": "a", "ref": "summary:1", "draft": 2, "text": "Thanks, fixed in abc123."])
  }

  /// `sb draft post` sends the item's ref, the draft's number, and the text as given, and sbd trims it. The app
  /// must send the same arguments for the same draft, so it passes the text through unchanged too.
  @Test(arguments: [
    "Thanks, fixed.",
    "@path/to/file reads as a file under -F",
    "a=b and body=c",
    "line one\nline two\n\nline four",
    "CRLF line\r\nnext line",
    "Unicode 👋🏽 é ü",
    "\n\n  surrounded by blank lines  \n\n",
  ])
  func thePostsArgumentsEqualTheDraftPostContractThatSbSends(_ text: String) async {
    let item = withDrafts("s1", ref: "summary:3", [.ready(replyTarget), .ready(replyTarget)]).triage!
    let draft = item.drafts[1]
    let expected: [String: JSON] = [
      "session": .string("s1"), "ref": .string(item.ref), "draft": .number(Double(draft.number)),
      "text": .string(text),
    ]

    let sent = await firstRequest { $0.postDraft("s1", ref: item.ref, number: draft.number, text: text) }

    #expect(sent.op == "draft-post")
    #expect(sent.args == expected)
  }

  @Test func checkAgainSendsDraftCheckWithTheSessionAndNumberOnly() async {
    let sent = await firstRequest { $0.checkDraft("s1", ref: "summary:3", number: 2) }

    #expect(sent.op == "draft-check")
    #expect(sent.args == ["session": "s1", "draft": 2])
  }

  // MARK: A refusal

  @Test func aRefusalKeepsTheEditedText() async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("a has a new item since you looked. Look again") }
    let field = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText)
    field.text = "Thanks, fixed in abc123."

    model.postDraft("a", ref: "summary:1", number: 1, text: field.text)
    await settle { model.draftErrors[key] != nil && model.postingDrafts.isEmpty }

    #expect(field.text == "Thanks, fixed in abc123.")
    #expect(model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText).text == field.text)
  }

  @Test func aRefusalSetsThatDraftsErrorAndNotTheWindowsBanner() async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("a has a new item since you looked. Look again") }
    let other = MessageDrafts.replyKey(session: "a", ref: "summary:1", number: 2)

    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks.")
    await settle { model.draftErrors[key] != nil }

    let error = model.draftErrors[key] ?? ""
    #expect(error.contains("a has a new item since you looked"))
    #expect(model.draftErrors[other] == nil)
    #expect(model.actionError == nil)
  }

  @Test func anAcceptedPostClearsThatDraftsError() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks.")
    await settle { model.draftErrors[key] != nil && model.postingDrafts.isEmpty }
    model.send = { _, _ in .null }

    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks.")
    await settle { model.draftErrors[key] == nil && model.postingDrafts.isEmpty }

    #expect(model.draftErrors[key] == nil)
  }

  // MARK: A success

  /// Once the draft is posted, its edited text has nothing left to post. A later appearance shows the session's
  /// text again, whether the model empties the field or forgets it.
  @Test func aSuccessClearsTheStoredText() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText).text = "Thanks, fixed."

    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks, fixed.")
    await settle {
      model.postingDrafts.isEmpty
        && model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "").text != "Thanks, fixed."
    }

    #expect(model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "").text != "Thanks, fixed.")
  }

  @Test func aSuccessLeavesOtherDraftsTextAlone() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    model.replyDraft(session: "a", ref: "summary:1", number: 2, initial: sessionText).text = "Second, edited."

    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks.")
    await settle { model.postingDrafts.isEmpty }

    #expect(model.replyDraft(session: "a", ref: "summary:1", number: 2, initial: sessionText).text == "Second, edited.")
  }

  // MARK: A double press

  @Test func thePostingSetHoldsTheDraftWhileSbdPosts() async {
    let (model, release, requests) = heldModel()

    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks.")
    await settle { requests.value == 1 }
    let held = model.postingDrafts.contains(key)
    release.signal()
    await settle { model.postingDrafts.isEmpty }

    #expect(held)
    #expect(model.postingDrafts.isEmpty)
  }

  @Test func aSecondCheckAgainWaitsForTheFirstAnswer() async {
    let (model, release, requests) = heldModel()

    model.checkDraft("a", ref: "summary:1", number: 1)
    model.checkDraft("a", ref: "summary:1", number: 1)
    await settle { requests.value >= 1 }
    let held = model.checkingDrafts.contains(key)
    release.signal()
    release.signal()
    await settle { model.checkingDrafts.isEmpty }
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(held)
    #expect(requests.value == 1)
  }

  @Test func aDoublePressSendsOneRequest() async {
    let (model, release, requests) = heldModel()

    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks.")
    model.postDraft("a", ref: "summary:1", number: 1, text: "Thanks.")
    // A second signal keeps a second request from holding its thread forever if the guard fails.
    release.signal()
    release.signal()
    await settle { model.postingDrafts.isEmpty }
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(requests.value == 1)
  }

  @Test func postsOfTwoDraftsEachGoOut() async {
    let (model, release, requests) = heldModel()

    model.postDraft("a", ref: "summary:1", number: 1, text: "First.")
    model.postDraft("a", ref: "summary:1", number: 2, text: "Second.")
    release.signal()
    release.signal()
    await settle { model.postingDrafts.isEmpty && requests.value == 2 }

    #expect(requests.value == 2)
  }

  // MARK: replyDraft(session:ref:number:initial:)

  @Test func theReplyKeyNamesTheSessionTheRefAndTheNumber() {
    #expect(MessageDrafts.replyKey(session: "s1", ref: "summary:3", number: 2) == "reply:s1/summary:3/2")
  }

  @Test func aNewReplyDraftStartsWithTheSessionsText() {
    let model = offlineModel()

    let field = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText)

    #expect(field.text == sessionText)
  }

  @Test func anEditedReplyDraftKeepsTheEditOverTheSessionsText() {
    let model = offlineModel()
    model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText).text = "Edited."

    let field = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText)

    #expect(field.text == "Edited.")
  }

  /// An empty field is filled again on its next appearance, so Post never sends an empty reply by accident.
  @Test func anEmptiedReplyDraftStartsAgainWithTheSessionsText() {
    let model = offlineModel()
    model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText).text = ""

    let field = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText)

    #expect(field.text == sessionText)
  }

  /// SwiftUI rebuilds the view on each refresh, so the field must find the same object each time.
  @Test func theSameDraftReturnsTheSameObject() {
    let model = offlineModel()

    let first = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText)
    let second = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText)

    #expect(first === second)
  }

  @Test func aReplyDraftOfAnotherRefStartsWithItsOwnText() {
    let model = offlineModel()
    model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText).text = "Edited."

    let field = model.replyDraft(session: "a", ref: "summary:2", number: 1, initial: "The new card's draft.")

    #expect(field.text == "The new card's draft.")
  }

  @Test func anEditedReplyDraftSurvivesARelaunch() async {
    let folder = "\(NSTemporaryDirectory())reply-drafts-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: folder) }
    _ = NSApplication.shared
    let client = Client(home: Home(path: NSTemporaryDirectory() + "no-sbd-" + UUID().uuidString))
    let first = BoardModel(client: client, draftsFolder: folder)
    first.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText).text = "Edited before quit."
    await settle {
      (try? String(contentsOfFile: "\(folder)/drafts.json", encoding: .utf8))?.contains("Edited before quit") == true
    }

    let relaunched = BoardModel(client: client, draftsFolder: folder)

    let field = relaunched.replyDraft(session: "a", ref: "summary:1", number: 1, initial: sessionText)
    #expect(field.text == "Edited before quit.")
  }

  // MARK: Pruning on refresh

  /// Every state that can still post, or that shows the user's text, keeps the field.
  @Test(arguments: [
    DraftPost.checking, .unresolved(error: "gh timed out"), .ready(replyTarget), .posting(replyTarget),
    .unknown(replyTarget, error: "HTTP 502"), .failed(replyTarget, error: "HTTP 422"),
  ])
  func aRefreshKeepsTheTextOfADraftThatStillShows(_ post: DraftPost) {
    let model = appliedModel([withDrafts("a", [post])])
    let field = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1")
    field.text = "Edited."

    model.apply(.success([withDrafts("a", [post])]), followups: nil)

    #expect(model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1") === field)
    #expect(field.text == "Edited.")
  }

  @Test func aRefreshDropsTheTextOfAPostedDraft() {
    let model = appliedModel([withDrafts("a", [.ready(replyTarget)])])
    let field = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1")
    field.text = "Edited."
    let posted = DraftPost.posted(
      replyTarget, url: "https://github.com/PostHog/charts/pull/18303#discussion_r2002", text: "Edited.")

    model.apply(.success([withDrafts("a", [posted])]), followups: nil)

    let after = model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1")
    #expect(after !== field)
    #expect(after.text == "Draft 1")
  }

  @Test func aRefreshDropsTheTextOfADraftWhoseSessionLeft() {
    let model = appliedModel([withDrafts("a", [.ready(replyTarget)]), withDrafts("b", [.ready(replyTarget)])])
    model.replyDraft(session: "b", ref: "summary:1", number: 1, initial: "Draft 1").text = "Edited."

    model.apply(.success([withDrafts("a", [.ready(replyTarget)])]), followups: nil)

    #expect(model.replyDraft(session: "b", ref: "summary:1", number: 1, initial: "Draft 1").text == "Draft 1")
  }

  /// A new card is a new ref, so its draft 1 may answer another comment.
  @Test func aRefreshDropsTheTextOfADraftWhoseItemHasANewRef() {
    let model = appliedModel([withDrafts("a", ref: "summary:1", [.ready(replyTarget)])])
    model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1").text = "Edited."

    model.apply(.success([withDrafts("a", ref: "summary:2", [.ready(replyTarget)])]), followups: nil)

    #expect(model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1").text == "Draft 1")
  }

  @Test func aRefreshDropsTheTextOfADraftThatTheItemNoLongerHas() {
    let model = appliedModel([withDrafts("a", [.ready(replyTarget), .ready(replyTarget)])])
    model.replyDraft(session: "a", ref: "summary:1", number: 2, initial: "Draft 2").text = "Edited."

    model.apply(.success([withDrafts("a", [.ready(replyTarget)])]), followups: nil)

    #expect(model.replyDraft(session: "a", ref: "summary:1", number: 2, initial: "Draft 2").text == "Draft 2")
  }

  /// The reply keys join the message and Other answer keys, so a prune keeps all three kinds.
  @Test func aRefreshKeepsTheSessionsMessageDraftAndOtherAnswerBesideItsReplyDraft() {
    var s = withDrafts("a", [.ready(replyTarget)])
    s.triage?.decisions = [1, 2].map {
      PendingDecision(
        number: $0, header: "Header \($0)", question: "Question \($0)?",
        options: [PendingDecision.Option(label: "Yes"), PendingDecision.Option(label: "No")])
    }
    let model = appliedModel([s])
    model.messageDraft(for: s).text = "message"
    model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text = "other"
    model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1").text = "Edited."

    model.apply(.success([s]), followups: nil)

    #expect(model.messageDraft(for: s).text == "message")
    #expect(model.otherAnswerDraft(session: "a", ref: "summary:1", decision: 2).text == "other")
    #expect(model.replyDraft(session: "a", ref: "summary:1", number: 1, initial: "Draft 1").text == "Edited.")
  }
}
