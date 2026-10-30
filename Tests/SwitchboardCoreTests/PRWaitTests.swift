import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct PRWaitTests {
  /// Reviews are dated around the wait, which was set at `set`.
  static let set = epochMs(2030, 6, 15, 12, 0, zone: utc)
  static let before = "2030-06-15T11:59:59Z"
  static let after = "2030-06-15T12:00:01Z"

  func wait(_ kind: Wait.Kind, who: String? = nil) -> Wait {
    var w = waitOn(kind, who: who)
    w.created = PRWaitTests.set
    return w
  }

  func pr(
    _ state: PRState = .open, checks: String? = nil, draft: Bool = false, reviewDecision: ReviewDecision? = nil,
    verdicts: [Review] = [], reviews: [Review] = []
  ) -> PullRequest {
    PullRequest(
      id: "PR_1", number: 7, url: "", repo: "a/b", state: state, draft: draft, reviewDecision: reviewDecision,
      verdicts: verdicts, reviews: reviews, checks: checks)
  }

  func review(_ author: String, _ state: String, _ at: String, bot: Bool? = nil) -> Review {
    Review(author: author, state: state, submittedAt: at, bot: bot)
  }

  @Test func aCIWaitResolvesOnATerminalRollup() {
    let ci = wait(.ci)
    #expect(ci.resolution(of: pr(checks: "SUCCESS")) == "the checks passed")
    #expect(ci.resolution(of: pr(checks: "FAILURE")) == "the checks failed")
    #expect(ci.resolution(of: pr(checks: "ERROR")) == "the checks failed")
    for open in ["PENDING", "EXPECTED", nil] { #expect(ci.resolution(of: pr(checks: open)) == nil) }
  }

  @Test func aWaitOnAPRThatEndedResolvesInsteadOfWaitingForever() {
    #expect(wait(.ci).resolution(of: pr(.merged)) == "the PR merged first")
    #expect(wait(.ci).resolution(of: pr(.closed, checks: "PENDING")) == "the PR closed first")
    #expect(wait(.review, who: "alex").resolution(of: pr(.closed)) == "the PR closed first")
    #expect(wait(.botReview).resolution(of: pr(.merged)) == "the PR merged first")
    #expect(wait(.approval).resolution(of: pr(.merged)) == "the PR merged first")
    #expect(wait(.ci).resolution(of: pr(.merged, checks: "SUCCESS")) == "the checks passed")
  }

  @Test func aMergeWaitResolvesWhenThePRMergesOrCloses() {
    #expect(wait(.merge).resolution(of: pr()) == nil)
    #expect(wait(.merge).resolution(of: pr(.merged)) == "it merged")
    #expect(wait(.merge).resolution(of: pr(.closed)) == "it closed without merging")
  }

  @Test func aReviewWaitNeedsAReviewByWhoAfterTheWaitWasSet() {
    let w = wait(.review, who: "Alex")
    #expect(w.resolution(of: pr(reviews: [review("alex", "APPROVED", PRWaitTests.before)])) == nil)
    #expect(w.resolution(of: pr(reviews: [review("sam", "APPROVED", PRWaitTests.after)])) == nil)
    #expect(w.resolution(of: pr(reviews: [review("alex", "DISMISSED", PRWaitTests.after)])) == nil)
    #expect(w.resolution(of: pr(reviews: [review("alex", "PENDING", PRWaitTests.after)])) == nil)
    #expect(w.resolution(of: pr(reviews: [review("alex", "APPROVED", PRWaitTests.after)])) == "alex approved")
    #expect(
      w.resolution(of: pr(reviews: [review("alex", "CHANGES_REQUESTED", PRWaitTests.after)]))
        == "alex requested changes"
    )
    #expect(w.resolution(of: pr(reviews: [review("alex", "COMMENTED", PRWaitTests.after)])) == "alex reviewed")
  }

  @Test func aReviewWaitReportsTheNewestReviewAfterTheWaitWasSet() {
    let reviews = [
      review("alex", "CHANGES_REQUESTED", PRWaitTests.after), review("alex", "APPROVED", "2030-06-15T12:30:00Z"),
    ]
    #expect(wait(.review, who: "alex").resolution(of: pr(reviews: reviews)) == "alex approved")
  }

  @Test func aBotReviewWaitMatchesTheBotWithOrWithoutItsSuffix() {
    let copilot = pr(reviews: [review("copilot-pull-request-reviewer", "COMMENTED", PRWaitTests.after, bot: true)])
    #expect(wait(.botReview, who: "copilot-pull-request-reviewer[bot]").resolution(of: copilot) != nil)
    #expect(wait(.botReview, who: "Copilot-Pull-Request-Reviewer").resolution(of: copilot) != nil)
    #expect(wait(.botReview, who: "greptile").resolution(of: copilot) == nil)
    #expect(wait(.botReview).resolution(of: copilot) == "copilot-pull-request-reviewer reviewed")
  }

  @Test func aBotReviewWaitWithoutWhoIgnoresPeopleAndOldReviews() {
    let w = wait(.botReview)
    #expect(w.resolution(of: pr(reviews: [review("alex", "APPROVED", PRWaitTests.after)])) == nil)
    #expect(w.resolution(of: pr(reviews: [review("greptile", "COMMENTED", PRWaitTests.before, bot: true)])) == nil)
  }

  @Test func anApprovalWaitResolvesWhileTheApprovalStands() {
    let alex = [review("alex", "APPROVED", PRWaitTests.before)]
    #expect(wait(.approval, who: "alex").resolution(of: pr(verdicts: alex)) == "alex approved")
    #expect(wait(.approval, who: "sam").resolution(of: pr(verdicts: alex)) == nil)
    #expect(
      wait(.approval, who: "alex").resolution(of: pr(verdicts: [review("alex", "CHANGES_REQUESTED", "x")])) == nil)
    #expect(wait(.approval).resolution(of: pr(reviewDecision: .approved, verdicts: alex)) == "approved by alex")
    #expect(wait(.approval).resolution(of: pr(reviewDecision: .approved)) == "the PR is approved")
    #expect(wait(.approval).resolution(of: pr(reviewDecision: .reviewRequired)) == nil)
    #expect(wait(.approval).resolution(of: pr(draft: true, reviewDecision: .approved, verdicts: alex)) == nil)
  }

  @Test func theKindsForOtherPollersStayOpen() {
    for kind in [Wait.Kind.queue, .deploy, .date, .manual, .session] {
      #expect(wait(kind).resolution(of: pr(.merged, checks: "SUCCESS")) == nil)
    }
  }
}
