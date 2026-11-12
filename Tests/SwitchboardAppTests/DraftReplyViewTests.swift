import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The review comment that the test drafts reply to.
let replyTarget = ResolvedTarget(
  target: ReplyTarget(repo: "PostHog/charts", pr: 18303, kind: .reviewComment, id: 1001), root: 1001,
  author: "ann", path: "a.swift", line: 3, excerpt: "NOT over AND",
  url: "https://github.com/PostHog/charts/pull/18303#discussion_r1001")

/// A draft of a session's card that replies to `replyTarget`, in state `post`.
func targetedDraft(
  _ post: DraftPost, number: Int = 1, text: String = "Good catch, fixed in the next commit.",
  replyTo: String? = "https://github.com/PostHog/charts/pull/18303#discussion_r1001"
) -> InboxDraft {
  InboxDraft(TriageDraft(label: "Reply to ann", text: text, replyTo: replyTo), number: number, post: post)
}

/// One example of each `DraftPost` state.
let everyDraftPost: [DraftPost] = [
  .copyOnly(reason: nil),
  .copyOnly(reason: "it replies on PostHog/other#1, and the session's PR is PostHog/charts#18303"),
  .checking,
  .unresolved(error: "GitHub has no comment 1001, or gh can't see it"),
  .ready(replyTarget),
  .posting(replyTarget),
  .unknown(replyTarget, error: "sbd restarted while it was posting"),
  .failed(replyTarget, error: "GitHub refused gh's login. Run `gh auth login`, then post again."),
  .posted(replyTarget, url: "https://github.com/PostHog/charts/pull/18303#discussion_r2002", text: "Thanks, fixed."),
]

@MainActor
@Suite struct DraftReplyViewTests {
  // MARK: mode(for:) for each state

  @Test func aCopyOnlyDraftWithoutAReasonIsCopyOnlyWithNoReason() {
    #expect(DraftReplyView.mode(for: targetedDraft(.copyOnly(reason: nil))) == .copyOnly(reason: nil))
  }

  @Test func aCopyOnlyDraftWithAReasonKeepsTheReason() {
    let reason = "sbd hasn't read this session's PR yet"

    #expect(DraftReplyView.mode(for: targetedDraft(.copyOnly(reason: reason))) == .copyOnly(reason: reason))
  }

  @Test func aCheckingDraftIsChecking() {
    #expect(DraftReplyView.mode(for: targetedDraft(.checking)) == .checking)
  }

  @Test func anUnresolvedDraftCarriesGhsError() {
    let error = "GitHub has no comment 1001, or gh can't see it"

    #expect(DraftReplyView.mode(for: targetedDraft(.unresolved(error: error))) == .unresolved(error: error))
  }

  @Test func aReadyDraftIsEditableWithoutAnError() {
    #expect(DraftReplyView.mode(for: targetedDraft(.ready(replyTarget))) == .editable(error: nil))
  }

  @Test func aFailedDraftIsEditableWithItsError() {
    let error = "GitHub refused gh's login. Run `gh auth login`, then post again."

    #expect(DraftReplyView.mode(for: targetedDraft(.failed(replyTarget, error: error))) == .editable(error: error))
  }

  @Test func aPostingDraftIsPosting() {
    #expect(DraftReplyView.mode(for: targetedDraft(.posting(replyTarget))) == .posting)
  }

  /// The thread link lets the user look on GitHub while sbd can't tell whether the reply went.
  @Test func anUnknownDraftCarriesTheErrorAndTheThreadLink() {
    let error = "sbd restarted while it was posting"

    let mode = DraftReplyView.mode(for: targetedDraft(.unknown(replyTarget, error: error)))

    #expect(mode == .unknown(error: error, thread: replyTarget.url))
  }

  /// The posted text can differ from the session's draft, because the user edits it before posting.
  @Test func aPostedDraftCarriesThePostedTextAndItsLink() {
    let url = "https://github.com/PostHog/charts/pull/18303#discussion_r2002"
    let draft = targetedDraft(.posted(replyTarget, url: url, text: "Thanks, fixed."), text: "Good catch.")

    #expect(DraftReplyView.mode(for: draft) == .posted(text: "Thanks, fixed.", url: url))
  }

  // MARK: What each mode shows

  @Test func aCopyOnlyDraftWithoutAReasonShowsNoCaption() {
    #expect(DraftReplyView.mode(for: targetedDraft(.copyOnly(reason: nil))).caption == nil)
  }

  @Test func aCopyOnlyDraftWithAReasonShowsItAsTheCaption() {
    let reason = "it replies on PostHog/other#1, and the session's PR is PostHog/charts#18303"

    #expect(DraftReplyView.mode(for: targetedDraft(.copyOnly(reason: reason))).caption == reason)
  }

  @Test func aPostedDraftShowsNoPostButton() {
    let draft = targetedDraft(
      .posted(replyTarget, url: "https://github.com/PostHog/charts/pull/18303#discussion_r2002", text: "Thanks."))

    #expect(!DraftReplyView.mode(for: draft).showsPostButton)
  }

  @Test(arguments: [DraftPost.copyOnly(reason: nil), .copyOnly(reason: "it has no fragment")])
  func aCopyOnlyDraftShowsNoPostButton(_ post: DraftPost) {
    #expect(!DraftReplyView.mode(for: targetedDraft(post)).showsPostButton)
  }

  @Test func aReadyDraftShowsThePostButton() {
    #expect(DraftReplyView.mode(for: targetedDraft(.ready(replyTarget))).showsPostButton)
  }

  /// sbd's `draft-post` accepts only `ready` and `failed`, so the button agrees with sbd.
  @Test(arguments: everyDraftPost)
  func postIsOnOnlyForAReadyOrFailedDraft(_ post: DraftPost) {
    let postable: Bool
    switch post {
    case .ready, .failed: postable = true
    default: postable = false
    }

    #expect(DraftReplyView.mode(for: targetedDraft(post)).canPost == postable)
  }

  @Test(arguments: everyDraftPost)
  func checkAgainShowsOnlyForAnUnknownOrUnresolvedDraft(_ post: DraftPost) {
    let checks: Bool
    switch post {
    case .unknown, .unresolved: checks = true
    default: checks = false
    }

    #expect(DraftReplyView.mode(for: targetedDraft(post)).checksAgain == checks)
  }

  /// A posting or unknown draft keeps the field read-only, so the text on screen is what sbd sent.
  @Test(arguments: everyDraftPost)
  func theFieldIsEditableOnlyWhileTheDraftCanStillPost(_ post: DraftPost) {
    let editable: Bool
    switch post {
    case .checking, .unresolved, .ready, .failed: editable = true
    default: editable = false
    }

    #expect(DraftReplyView.mode(for: targetedDraft(post)).fieldEditable == editable)
  }

  @Test(arguments: everyDraftPost)
  func everyModeButCopyOnlyAndPostedShowsTheUsersText(_ post: DraftPost) {
    let shows: Bool
    switch post {
    case .copyOnly, .posted: shows = false
    default: shows = true
    }

    #expect(DraftReplyView.mode(for: targetedDraft(post)).showsUserText == shows)
  }

  // MARK: The app's own post

  /// sbd's `posting` state arrives one refresh after the press, so the app's request locks the field first.
  @Test(arguments: [DraftPost.ready(replyTarget), .failed(replyTarget, error: "HTTP 422")])
  func theAppsOwnPostLocksAPostableDraft(_ post: DraftPost) {
    #expect(DraftReplyView.mode(for: targetedDraft(post), posting: true) == .posting)
  }

  /// A refresh can bring sbd's outcome before the app's request ends.
  @Test func theAppsOwnPostLeavesAnOutcomeThatSbdRecorded() {
    let url = "https://github.com/PostHog/charts/pull/18303#discussion_r2002"
    let posted = targetedDraft(.posted(replyTarget, url: url, text: "Thanks."))
    let unknown = targetedDraft(.unknown(replyTarget, error: "HTTP 502"))

    #expect(DraftReplyView.mode(for: posted, posting: true) == .posted(text: "Thanks.", url: url))
    #expect(DraftReplyView.mode(for: unknown, posting: true) == .unknown(error: "HTTP 502", thread: replyTarget.url))
  }

  @Test(arguments: ["", "\n\n", "  \r\n  ", "\r\n\r\n"])
  func postIsOffWhileTheFieldHasOnlyBlankLines(_ text: String) {
    #expect(!DraftReplyView.postEnabled(.editable(error: nil), text: text))
  }

  @Test func postIsOnForAPostableDraftWithText() {
    #expect(DraftReplyView.postEnabled(.editable(error: nil), text: "a"))
  }

  @Test func postIsOffForADraftThatCantPostWhateverItsText() {
    #expect(!DraftReplyView.postEnabled(.checking, text: "a"))
  }

  // MARK: Which drafts get a Post button

  /// Only the session's own card names a target. A summarizer draft could carry a target copied from quoted text.
  @Test func aSessionCardsDraftWithATargetUsesTheReplyView() {
    let draft = targetedDraft(.ready(replyTarget))
    let item = TriageItem(title: "Reply", kind: .review, summary: "", drafts: [draft], source: .session)

    #expect(DraftsSection.usesReplyView(draft, in: item))
  }

  @Test func aSessionCardsDraftWithoutATargetUsesTheCopyView() {
    let draft = targetedDraft(.copyOnly(reason: nil), replyTo: nil)
    let item = TriageItem(title: "Reply", kind: .review, summary: "", drafts: [draft], source: .session)

    #expect(!DraftsSection.usesReplyView(draft, in: item))
  }

  @Test(arguments: [TriageSource.card, .rule, .summary, .fallback])
  func aDraftWithATargetOnAnItemThatIsNotTheSessionsCardUsesTheCopyView(_ source: TriageSource) {
    let draft = targetedDraft(.ready(replyTarget))
    let item = TriageItem(title: "Reply", kind: .review, summary: "", drafts: [draft], source: source)

    #expect(!DraftsSection.usesReplyView(draft, in: item))
  }
}
