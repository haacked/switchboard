import Foundation
import Testing

@testable import SwitchboardCore

let samplePRHead = "head1"

func samplePR(
  state: PRState = .open, draft: Bool = false, headSha: String = samplePRHead, base: String = "main",
  defaultBranch: String? = "main", mergeable: Mergeable? = .mergeable, reviewDecision: ReviewDecision? = nil,
  verdicts: [Review] = [], reviews: [Review] = [], checks: String? = nil, mergedBase: Int? = nil,
  queue: TrunkQueueState? = nil, reviewRequests: [String]? = nil, reviewDecisionRead: Bool? = nil
) -> PullRequest {
  PullRequest(
    id: "PR_42", number: 42, url: "https://github.com/acme/widgets/pull/42", repo: "acme/widgets", state: state,
    draft: draft, head: "feature", headSha: headSha, base: base, defaultBranch: defaultBranch, mergeable: mergeable,
    reviewDecision: reviewDecision, verdicts: verdicts, reviews: reviews, checks: checks, mergedBase: mergedBase,
    queue: queue, reviewRequests: reviewRequests, reviewDecisionRead: reviewDecisionRead)
}

/// What `Attention.evaluate` gives for samplePR's session, whose PR #42 has
/// no title, when its other rules give Waiting. `waiting` is that verdict's
/// reason, and nil when the review request gave it.
func sampleReadyForReview(
  _ waiting: String? = nil, review: String = "review required", checks: String = "no checks"
) -> Verdict {
  Verdict(state: .readyForReview, reason: "#42; \(review), \(checks)" + (waiting.map { "; \($0)" } ?? ""))
}

func sampleVerdict(_ author: String, _ state: String, on commit: String? = nil) -> Review {
  Review(author: author, state: state, submittedAt: "2026-10-25T00:00:00Z", commit: commit)
}

@Suite struct PullRequestTests {
  @Test(arguments: [
    (samplePR(state: .merged, reviewDecision: .approved), "Merged"),
    (samplePR(state: .merged, draft: true), "Merged"),
    (samplePR(state: .closed, reviewDecision: .approved), "Closed"),
    (samplePR(state: .closed, draft: true), "Closed"),
    (samplePR(draft: true, reviewDecision: .approved), "Draft"),
    (samplePR(reviewDecision: .approved), "Approved"),
    (samplePR(reviewDecision: .changesRequested), "Changes requested"),
    (samplePR(reviewDecision: .reviewRequired), "Review required"),
    (samplePR(reviewDecision: .reviewRequired, verdicts: [sampleVerdict("alice", "APPROVED")]), "Review required"),
    (samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED")]), "Approved"),
  ])
  func statusFollowsTheStateThenTheReviewDecision(_ pr: PullRequest, _ status: String) {
    #expect(pr.status.rawValue == status)
  }

  @Test(arguments: [
    ([sampleVerdict("alice", "APPROVED"), sampleVerdict("bob", "CHANGES_REQUESTED")], "Changes requested"),
    ([sampleVerdict("bob", "CHANGES_REQUESTED"), sampleVerdict("alice", "APPROVED")], "Changes requested"),
    ([sampleVerdict("alice", "APPROVED")], "Approved"),
    ([sampleVerdict("alice", "DISMISSED"), sampleVerdict("bob", "APPROVED")], "Approved"),
    ([sampleVerdict("alice", "DISMISSED")], "Not approved"),
    ([sampleVerdict("alice", "COMMENTED")], "Not approved"),
    ([], "Not approved"),
  ])
  func statusWithoutAReviewDecisionFollowsTheVerdicts(_ verdicts: [Review], _ status: String) {
    #expect(samplePR(reviewDecision: nil, verdicts: verdicts).status.rawValue == status)
  }

  @Test func approversAreTheSortedAuthorsOfApprovals() {
    let p = samplePR(verdicts: [
      sampleVerdict("carol", "APPROVED"), sampleVerdict("bob", "CHANGES_REQUESTED"), sampleVerdict("alice", "APPROVED"),
      sampleVerdict("dave", "DISMISSED"), sampleVerdict("erin", "COMMENTED"),
    ])

    #expect(p.approvers == ["alice", "carol"])
  }

  @Test func changesRequestedByAreTheSortedAuthorsOfChangeRequests() {
    let p = samplePR(verdicts: [
      sampleVerdict("zed", "CHANGES_REQUESTED"), sampleVerdict("alice", "APPROVED"),
      sampleVerdict("bob", "CHANGES_REQUESTED"),
      sampleVerdict("dave", "DISMISSED"),
    ])

    #expect(p.changesRequestedBy == ["bob", "zed"])
  }

  @Test func reviewsThatAreNotVerdictsNameNoApprover() {
    let p = samplePR(reviews: [sampleVerdict("alice", "APPROVED"), sampleVerdict("bob", "CHANGES_REQUESTED")])

    #expect(p.approvers.isEmpty)
    #expect(p.changesRequestedBy.isEmpty)
  }

  @Test(arguments: [
    (samplePR(checks: "PENDING"), true),
    (samplePR(checks: "EXPECTED"), true),
    (samplePR(mergeable: .unknown, checks: "SUCCESS"), true),
    (samplePR(mergeable: .unknown, checks: nil), true),
    (samplePR(draft: true, checks: "PENDING"), true),
    (samplePR(checks: "SUCCESS"), false),
    (samplePR(checks: "FAILURE"), false),
    (samplePR(checks: "ERROR"), false),
    (samplePR(mergeable: .conflicting, checks: "SUCCESS"), false),
    (samplePR(checks: nil), false),
    (samplePR(mergeable: nil, checks: "SUCCESS"), false),
    (samplePR(mergeable: nil, checks: nil), false),
    (samplePR(state: .merged, mergeable: .unknown, checks: "PENDING"), false),
    (samplePR(state: .closed, checks: "EXPECTED"), false),
    (samplePR(state: .closed, mergeable: .unknown), false),
  ])
  func isPendingOnlyWhileAnOpenPRWillChange(_ pr: PullRequest, _ pending: Bool) {
    #expect(pr.isPending == pending)
  }
}

@Suite struct PullRequestNeedsReview {
  @Test(arguments: [
    (ReviewDecision?.some(.reviewRequired), Bool?.some(true), Bool?.some(true)),
    (.reviewRequired, nil, true),
    (.changesRequested, true, true),
    (.changesRequested, nil, true),
    (.approved, true, false),
    (.approved, nil, false),
    (nil, true, false),
    (nil, nil, nil),
  ])
  func needsReviewFollowsTheDecisionAndWhetherThePollReadIt(
    _ decision: ReviewDecision?, _ read: Bool?, _ expected: Bool?
  ) {
    #expect(samplePR(reviewDecision: decision, reviewDecisionRead: read).needsReview == expected)
  }

  /// A `pr` event that an older sbd recorded has no `reviewDecisionRead`.
  @Test func prFromAnOlderSbdHasAnUnreadDecision() throws {
    var object = try #require(try JSON(encoding: samplePR(reviewDecision: nil)).object)
    object["reviewDecisionRead"] = nil

    let decoded = try JSONCoding.convert(JSON.object(object), to: PullRequest.self)

    #expect(decoded.needsReview == nil)
  }

  @Test func reviewDecisionReadSurvivesAnEventRoundTrip() throws {
    let original = samplePR(reviewDecision: nil, reviewDecisionRead: true)

    let decoded = try JSONCoding.convert(try JSON(encoding: original), to: PullRequest.self)

    #expect(decoded.reviewDecisionRead == true)
  }
}

@Suite struct PRSummaryQueueWords {
  @Test(arguments: [
    (TrunkQueueState.submitted, "Submitted"),
    (.pending, "Waiting"),
    (.testing, "Testing"),
    (.passed, "Passed"),
    (.failing, "Failing"),
    (.queued, "Queued"),
    (.removed, "Removed"),
  ])
  func namesEachTrunkState(_ queue: TrunkQueueState, _ word: String) {
    #expect(PRSummary(samplePR(reviewDecision: .approved, queue: queue)).queueWord == word)
  }

  @Test(arguments: [TrunkQueueState.unknown, .merged])
  func namesNoTrunkStateThatHoldsNothing(_ queue: TrunkQueueState) {
    #expect(PRSummary(samplePR(queue: queue)).queueWord == nil)
  }

  @Test(arguments: [nil, TrunkQueueState.unknown])
  func namesGitHubsMergeQueue(_ queue: TrunkQueueState?) {
    var pr = samplePR(reviewDecision: .approved, queue: queue)
    pr.inMergeQueue = true

    #expect(PRSummary(pr).queueWord == "Queued")
    #expect(PRSummary(pr).line == "#42 Approved, in the merge queue")
  }

  @Test(arguments: [
    samplePR(state: .merged, queue: .testing), samplePR(state: .closed, queue: .removed),
    samplePR(draft: true, queue: .submitted),
    {
      var pr = samplePR(draft: true)
      pr.inMergeQueue = true
      return pr
    }(),
  ])
  func namesNoQueueOnATileForAPRThatCannotBeQueued(_ pr: PullRequest) {
    #expect(PRSummary(pr).queueWord == nil)
  }

  @Test func keepsTrunksLastStateInTheLineOfAClosedPR() {
    var pr = samplePR(state: .closed, queue: .removed)
    pr.queueLabel = "Cancelled"

    #expect(PRSummary(pr).line == "#42 Closed, Trunk cancelled")
  }

  @Test func prefersTrunksOwnLabelInThePhrase() {
    var pr = samplePR(reviewDecision: .approved, queue: .removed)
    pr.queueLabel = "Cancelled"

    #expect(PRSummary(pr).queueWord == "Removed")
    #expect(PRSummary(pr).queuePhrase == "Trunk cancelled")
    #expect(PRSummary(pr).line == "#42 Approved, Trunk cancelled")
  }
}
