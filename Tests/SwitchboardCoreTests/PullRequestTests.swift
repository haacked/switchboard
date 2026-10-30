import Foundation
import Testing

@testable import SwitchboardCore

let samplePRHead = "head1"

func samplePR(
  state: PRState = .open, draft: Bool = false, headSha: String = samplePRHead, base: String = "main",
  defaultBranch: String? = "main", mergeable: Mergeable? = .mergeable, reviewDecision: ReviewDecision? = nil,
  verdicts: [Review] = [], reviews: [Review] = [], checks: String? = nil, mergedBase: Int? = nil,
  queue: TrunkQueueState? = nil
) -> PullRequest {
  PullRequest(
    id: "PR_42", number: 42, url: "https://github.com/acme/widgets/pull/42", repo: "acme/widgets", state: state,
    draft: draft, head: "feature", headSha: headSha, base: base, defaultBranch: defaultBranch, mergeable: mergeable,
    reviewDecision: reviewDecision, verdicts: verdicts, reviews: reviews, checks: checks, mergedBase: mergedBase,
    queue: queue)
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
