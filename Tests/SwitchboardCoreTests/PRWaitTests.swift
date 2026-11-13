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

  /// An hour before the wait was set.
  static let since = PRWaitTests.set - 3_600_000
  static let beforeSince = "2030-06-15T10:59:59Z"
  static let atSince = "2030-06-15T11:00:00Z"
  static let betweenSinceAndSet = "2030-06-15T11:30:00Z"

  func wait(_ kind: Wait.Kind, who: String? = nil, since: Int64?) -> Wait {
    var w = wait(kind, who: who)
    w.since = since
    return w
  }

  func pr(
    _ state: PRState = .open, checks: String? = nil, draft: Bool = false, reviewDecision: ReviewDecision? = nil,
    verdicts: [Review] = [], reviews: [Review] = [], queue: TrunkQueueState? = nil,
    queueAt: Int64? = PRWaitTests.set + 1000
  ) -> PullRequest {
    var pr = PullRequest(
      id: "PR_1", number: 7, url: "", repo: "a/b", state: state, draft: draft, reviewDecision: reviewDecision,
      verdicts: verdicts, reviews: reviews, checks: checks, queue: queue)
    pr.queueAt = queue == nil ? nil : queueAt
    return pr
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
    for kind in [Wait.Kind.deploy, .date, .manual, .session] {
      #expect(wait(kind).resolution(of: pr(.merged, checks: "SUCCESS")) == nil)
    }
  }

  @Test func aQueueWaitResolvesWhenTheQueueLetsTheOpenPRGo() {
    let queue = wait(.queue)
    #expect(queue.resolution(of: pr(queue: .removed)) == "Trunk removed it from the queue")
    #expect(queue.resolution(of: pr(queue: .merged)) == "Trunk merged it")
    #expect(queue.resolution(of: pr(.merged)) == "it merged")
    #expect(queue.resolution(of: pr(.closed)) == "it closed without merging")
    #expect(queue.resolution(of: pr(.closed, queue: .removed)) == "it closed without merging")
  }

  @Test func aQueueWaitIgnoresAStatusFromBeforeItWasSet() {
    let queue = wait(.queue)
    for state in [TrunkQueueState.removed, .merged] {
      #expect(queue.resolution(of: pr(queue: state, queueAt: PRWaitTests.set - 1000)) == nil)
      #expect(queue.resolution(of: pr(queue: state, queueAt: PRWaitTests.set)) == nil)
      #expect(queue.resolution(of: pr(queue: state, queueAt: nil)) == nil)
    }
  }

  @Test func aQueueWaitStaysOpenWhileTrunkHoldsOrHasNotSeenThePR() {
    let queue = wait(.queue)
    for held in [TrunkQueueState.submitted, .pending, .testing, .passed, .failing, .queued, .unknown] {
      #expect(queue.resolution(of: pr(queue: held)) == nil)
    }
    #expect(queue.resolution(of: pr()) == nil)
  }

  @Test(arguments: [PRWaitTests.betweenSinceAndSet, PRWaitTests.before])
  func aReviewWaitWithSinceCountsAReviewFromBeforeItWasSet(_ at: String) {
    let w = wait(.review, who: "alex", since: PRWaitTests.since)
    #expect(w.resolution(of: pr(reviews: [review("alex", "APPROVED", at)])) == "alex approved")
  }

  @Test(arguments: [nil, "greptile-apps[bot]"], [PRWaitTests.betweenSinceAndSet, PRWaitTests.before])
  func aBotReviewWaitWithSinceCountsABotReviewFromBeforeItWasSet(_ who: String?, _ at: String) {
    let w = wait(.botReview, who: who, since: PRWaitTests.since)
    let reviews = [review("greptile-apps", "COMMENTED", at, bot: true)]
    #expect(w.resolution(of: pr(reviews: reviews)) == "greptile-apps reviewed")
  }

  @Test(arguments: [PRWaitTests.beforeSince, PRWaitTests.atSince, "2020-01-01T00:00:00Z"])
  func aReviewWaitWithSinceIgnoresAReviewAtOrBeforeSince(_ at: String) {
    #expect(
      wait(.review, who: "alex", since: PRWaitTests.since).resolution(of: pr(reviews: [review("alex", "APPROVED", at)]))
        == nil)
    #expect(
      wait(.botReview, since: PRWaitTests.since).resolution(
        of: pr(reviews: [review("greptile-apps", "COMMENTED", at, bot: true)])) == nil)
  }

  @Test func aBotReviewWaitWithSinceStillIgnoresPeople() {
    let w = wait(.botReview, since: PRWaitTests.since)
    #expect(w.resolution(of: pr(reviews: [review("alex", "APPROVED", PRWaitTests.betweenSinceAndSet)])) == nil)
  }

  @Test func aReviewWaitWithSinceReportsTheNewestReviewAfterSince() {
    let reviews = [
      review("alex", "APPROVED", PRWaitTests.beforeSince),
      review("alex", "CHANGES_REQUESTED", PRWaitTests.betweenSinceAndSet),
    ]
    #expect(
      wait(.review, who: "alex", since: PRWaitTests.since).resolution(of: pr(reviews: reviews))
        == "alex requested changes")
  }

  @Test(arguments: [TrunkQueueState.removed, .merged])
  func aQueueWaitWithSinceCountsAQueueChangeFromBeforeItWasSet(_ state: TrunkQueueState) {
    let w = wait(.queue, since: PRWaitTests.since)
    #expect(w.resolution(of: pr(queue: state, queueAt: PRWaitTests.since + 60_000)) != nil)
  }

  @Test(arguments: [TrunkQueueState.removed, .merged], [PRWaitTests.since - 1000, PRWaitTests.since])
  func aQueueWaitWithSinceIgnoresAQueueChangeAtOrBeforeSince(_ state: TrunkQueueState, _ at: Int64) {
    #expect(wait(.queue, since: PRWaitTests.since).resolution(of: pr(queue: state, queueAt: at)) == nil)
  }

  /// A wait whose `since` is its `created` reads the PR exactly as one with no `since`.
  @Test(arguments: [
    PRWaitTests.beforeSince, PRWaitTests.betweenSinceAndSet, PRWaitTests.before, "2030-06-15T12:00:00Z",
    PRWaitTests.after,
  ])
  func sinceAtCreatedAgreesWithNoSinceForReviews(_ at: String) {
    for (kind, who, bot) in [
      (Wait.Kind.review, "alex" as String?, false), (.botReview, nil, true), (.botReview, "greptile-apps", true),
    ] {
      let reviews = [review(who ?? "greptile-apps", "COMMENTED", at, bot: bot)]
      let plain = wait(kind, who: who).resolution(of: pr(reviews: reviews))
      #expect(wait(kind, who: who, since: PRWaitTests.set).resolution(of: pr(reviews: reviews)) == plain)
    }
  }

  @Test(arguments: [
    PRWaitTests.since - 1000, PRWaitTests.since + 60_000, PRWaitTests.set - 1, PRWaitTests.set, PRWaitTests.set + 1,
  ])
  func sinceAtCreatedAgreesWithNoSinceForTheQueue(_ at: Int64) {
    for state in [TrunkQueueState.removed, .merged] {
      let plain = wait(.queue).resolution(of: pr(queue: state, queueAt: at))
      #expect(wait(.queue, since: PRWaitTests.set).resolution(of: pr(queue: state, queueAt: at)) == plain)
    }
  }

  @Test(arguments: [Wait.Kind.ci, .approval, .merge])
  func sinceDoesNotChangeTheKindsThatIgnoreTime(_ kind: Wait.Kind) {
    let read = pr(
      checks: "PENDING", reviewDecision: .approved, verdicts: [review("alex", "APPROVED", PRWaitTests.beforeSince)])
    #expect(wait(kind, since: PRWaitTests.since).resolution(of: read) == wait(kind).resolution(of: read))
  }
}
