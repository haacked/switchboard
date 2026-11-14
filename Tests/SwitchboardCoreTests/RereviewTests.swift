import Foundation
import Testing

@testable import SwitchboardCore

/// The PR author's login. The times follow PostHog/posthog#135140, where mariusandra requested changes at
/// 08:53:58 and the author answered each thread at 18:07:49 and 18:07:51.
private let prAuthor = "jzhu13"
private let changeRequest = "2026-11-14T08:53:58Z"
private let firstReply = "2026-11-14T18:07:49Z"
private let secondReply = "2026-11-14T18:07:51Z"
private let beforeRequest = "2026-11-14T08:00:00Z"
private let afterReplies = "2026-11-14T19:00:00Z"
private let secondRoundReply = "2026-11-14T20:00:00Z"

/// A reviewer's last verdict that requests changes, on the head commit.
private func changesVerdict(_ login: String, at time: String? = changeRequest, bot: Bool? = nil) -> Review {
  Review(author: login, state: "CHANGES_REQUESTED", submittedAt: time, commit: samplePRHead, bot: bot)
}

/// An entry of GitHub's `reviews(last: 20)`.
private func entry(_ login: String, _ state: String, at time: String?) -> Review {
  Review(author: login, state: state, submittedAt: time)
}

/// The author's thread reply, which GitHub records as a COMMENTED review by the author.
private func reply(at time: String = firstReply, by login: String = prAuthor) -> Review {
  entry(login, "COMMENTED", at: time)
}

/// An open PR whose checks passed, whose base branch requires review, and that GitHub would put In review
/// once its change requests were gone. `edit` changes the fields that the arguments leave alone.
private func reviewedPR(
  author: String? = prAuthor, verdicts: [Review], reviews: [Review],
  reviewDecision: ReviewDecision? = .changesRequested, edit: (inout PullRequest) -> Void = { _ in }
) -> PullRequest {
  var pr = samplePR(
    reviewDecision: reviewDecision, verdicts: verdicts, reviews: reviews, checks: "SUCCESS", reviewDecisionRead: true)
  pr.author = author
  edit(&pr)
  return pr
}

/// mariusandra requested changes, and the author replied after that.
private func answeredPR(edit: (inout PullRequest) -> Void = { _ in }) -> PullRequest {
  reviewedPR(
    verdicts: [changesVerdict("mariusandra")],
    reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply()], edit: edit)
}

/// The same PR as GitHub would see it without its change requests: the change-requesting verdicts are
/// gone, and a CHANGES_REQUESTED decision reads as REVIEW_REQUIRED. The test builds this copy itself, so
/// the parity check does not reuse the code under test.
private func withoutChangeRequests(_ pr: PullRequest) -> PullRequest {
  var copy = pr
  copy.verdicts.removeAll(where: \.requestsChanges)
  if copy.reviewDecision == .changesRequested { copy.reviewDecision = .reviewRequired }
  return copy
}

private func replyTime(_ time: String) -> Int64 { Transcript.milliseconds(time)! }

struct RereviewCase: Sendable, CustomTestStringConvertible {
  let name: String
  let pr: PullRequest
  /// The reviewers that the re-review names, or nil when the PR has no re-review.
  let reviewers: [String]?

  var testDescription: String { name }
}

/// Every input shape that the re-review guard must handle.
private let rereviewCases: [RereviewCase] = [
  RereviewCase(name: "the author replied after the one change request", pr: answeredPR(), reviewers: ["mariusandra"]),
  RereviewCase(
    name: "the author's login differs in case from the reply's",
    pr: reviewedPR(
      author: "JZhu13", verdicts: [changesVerdict("mariusandra")],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(by: "jzhu13")]),
    reviewers: ["mariusandra"]),
  RereviewCase(
    name: "two answered requesters come out sorted",
    pr: reviewedPR(
      verdicts: [changesVerdict("zoe"), changesVerdict("alice")],
      reviews: [
        entry("zoe", "CHANGES_REQUESTED", at: changeRequest), entry("alice", "CHANGES_REQUESTED", at: changeRequest),
        reply(),
      ]),
    reviewers: ["alice", "zoe"]),
  RereviewCase(
    name: "an answered bot requester counts",
    pr: reviewedPR(
      verdicts: [changesVerdict("chatgpt-codex-connector", bot: true)],
      reviews: [entry("chatgpt-codex-connector", "CHANGES_REQUESTED", at: changeRequest), reply()]),
    reviewers: ["chatgpt-codex-connector"]),
  RereviewCase(
    name: "a requester who later approved leaves only the answered requester",
    pr: reviewedPR(
      verdicts: [
        changesVerdict("alice"),
        Review(author: "bob", state: "APPROVED", submittedAt: afterReplies, commit: samplePRHead),
      ],
      reviews: [
        entry("alice", "CHANGES_REQUESTED", at: changeRequest), entry("bob", "CHANGES_REQUESTED", at: changeRequest),
        reply(), entry("bob", "APPROVED", at: afterReplies),
      ]),
    reviewers: ["alice"]),
  RereviewCase(
    name: "the requester's own pending review after the reply does not count",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [
        entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(),
        entry("mariusandra", "PENDING", at: afterReplies),
      ]),
    reviewers: ["mariusandra"]),

  RereviewCase(
    name: "the author is unknown",
    pr: reviewedPR(
      author: nil, verdicts: [changesVerdict("mariusandra")],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply()]),
    reviewers: nil),
  RereviewCase(
    name: "the author replied before the change request",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [reply(at: beforeRequest), entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest)]),
    reviewers: nil),
  RereviewCase(
    name: "the author replied in the same second as the change request",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(at: changeRequest)]),
    reviewers: nil),
  RereviewCase(
    name: "someone other than the author replied",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(by: "alice")]),
    reviewers: nil),
  RereviewCase(
    name: "the author's only later review is pending",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [
        entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), entry(prAuthor, "PENDING", at: firstReply),
      ]),
    reviewers: nil),
  RereviewCase(
    name: "the author's only later review is pending without a submit time",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), entry(prAuthor, "PENDING", at: nil)]),
    reviewers: nil),
  RereviewCase(
    name: "of two requesters only one was answered",
    pr: reviewedPR(
      verdicts: [changesVerdict("alice"), changesVerdict("bob", at: "2026-11-14T18:30:00Z")],
      reviews: [
        entry("alice", "CHANGES_REQUESTED", at: changeRequest), reply(),
        entry("bob", "CHANGES_REQUESTED", at: "2026-11-14T18:30:00Z"),
      ]),
    reviewers: nil),
  RereviewCase(
    name: "the requester commented again after the author's reply",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [
        entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(),
        entry("mariusandra", "COMMENTED", at: afterReplies),
      ]),
    reviewers: nil),
  RereviewCase(
    name: "the only requester later approved",
    pr: reviewedPR(
      verdicts: [Review(author: "mariusandra", state: "APPROVED", submittedAt: afterReplies, commit: samplePRHead)],
      reviews: [
        entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(),
        entry("mariusandra", "APPROVED", at: afterReplies),
      ],
      reviewDecision: .approved),
    reviewers: nil),
  RereviewCase(
    name: "GitHub's decision requests changes that no verdict names",
    pr: reviewedPR(verdicts: [], reviews: [reply()]),
    reviewers: nil),
  RereviewCase(
    name: "the requester's verdict has no submit time and no other review",
    pr: reviewedPR(verdicts: [changesVerdict("mariusandra", at: nil)], reviews: [reply()]),
    reviewers: nil),
  RereviewCase(
    name: "the requester's verdict has no submit time, though an earlier review of theirs has one",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra", at: nil)],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply()]),
    reviewers: nil),
  RereviewCase(
    name: "only the requester's verdict shows a change request after the reply",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra", at: afterReplies)],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply()]),
    reviewers: nil),
  RereviewCase(
    name: "the author replied again after the requester's second round",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [
        entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(),
        entry("mariusandra", "COMMENTED", at: afterReplies), reply(at: secondRoundReply),
      ]),
    reviewers: ["mariusandra"]),
  RereviewCase(
    name: "the author's reply has an unparseable time",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(at: "yesterday evening")]),
    reviewers: nil),
  RereviewCase(
    name: "the requester's verdict has an unparseable time",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra", at: "not a time")],
      reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply()]),
    reviewers: nil),
  RereviewCase(
    name: "one of the requester's reviews has an unparseable time",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: [
        entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(),
        entry("mariusandra", "COMMENTED", at: "2026-13-45T99:00:00Z"),
      ]),
    reviewers: nil),
  RereviewCase(name: "CI failed", pr: answeredPR { $0.checks = "FAILURE" }, reviewers: nil),
  RereviewCase(name: "CI errored", pr: answeredPR { $0.checks = "ERROR" }, reviewers: nil),
  RereviewCase(name: "the PR conflicts with its base", pr: answeredPR { $0.mergeable = .conflicting }, reviewers: nil),
  RereviewCase(name: "the PR is a draft", pr: answeredPR { $0.draft = true }, reviewers: nil),
  RereviewCase(name: "Trunk's queue holds the PR", pr: answeredPR { $0.queue = .testing }, reviewers: nil),
  RereviewCase(name: "GitHub's merge queue holds the PR", pr: answeredPR { $0.inMergeQueue = true }, reviewers: nil),
  RereviewCase(
    name: "the author's reply fell outside the last 20 reviews",
    pr: reviewedPR(
      verdicts: [changesVerdict("mariusandra")],
      reviews: (0..<20).map { i in
        entry("posthog-bot", "COMMENTED", at: String(format: "2026-11-14T10:%02d:00Z", i))
      }),
    reviewers: nil),
]

/// Answered change requests on PRs in each state that decides `prColumn`, for the parity check.
private let parityShapes: [(String, PullRequest)] = [
  ("answered", answeredPR()),
  ("CI failed", answeredPR { $0.checks = "FAILURE" }),
  ("CI errored", answeredPR { $0.checks = "ERROR" }),
  ("CI running", answeredPR { $0.checks = "PENDING" }),
  ("CI expected", answeredPR { $0.checks = "EXPECTED" }),
  ("conflicting", answeredPR { $0.mergeable = .conflicting }),
  ("mergeability unknown", answeredPR { $0.mergeable = .unknown }),
  ("draft", answeredPR { $0.draft = true }),
  ("Trunk testing", answeredPR { $0.queue = .testing }),
  ("Trunk submitted", answeredPR { $0.queue = .submitted }),
  ("Trunk removed", answeredPR { $0.queue = .removed }),
  ("GitHub merge queue", answeredPR { $0.inMergeQueue = true }),
  ("closed", answeredPR { $0.state = .closed }),
  ("merged", answeredPR { $0.state = .merged }),
  (
    "no required review, re-requested",
    answeredPR {
      $0.reviewDecision = nil
      $0.reviewRequests = ["mariusandra"]
    }
  ),
  (
    "no required review, nobody asked",
    answeredPR {
      $0.reviewDecision = nil
      $0.reviewRequests = []
    }
  ),
  (
    "review decision not read",
    answeredPR {
      $0.reviewDecision = nil
      $0.reviewDecisionRead = nil
    }
  ),
]

/// The suites nest under one name, so `--filter RereviewTests` runs them all.
@Suite struct RereviewTests {}

// MARK: - The guard

extension RereviewTests {
  @Suite struct Guard {
    @Test(arguments: rereviewCases)
    func namesTheAnsweredRequestersOrIsNil(_ c: RereviewCase) {
      #expect(c.pr.rereview?.reviewers == c.reviewers)
    }

    @Test func theReviewersHaveNoAt() throws {
      let rereview = try #require(answeredPR().rereview)

      #expect(rereview.reviewers.allSatisfy { !$0.hasPrefix("@") })
    }

    @Test func repliedAtIsTheAuthorsReplyInMilliseconds() throws {
      let rereview = try #require(answeredPR().rereview)

      #expect(rereview.repliedAt == replyTime(firstReply))
    }

    @Test func repliedAtIsTheNewestOfSeveralReplies() throws {
      let pr = reviewedPR(
        verdicts: [changesVerdict("mariusandra")],
        reviews: [
          entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(at: firstReply), reply(at: secondReply),
        ])

      let rereview = try #require(pr.rereview)

      #expect(rereview.repliedAt == replyTime(secondReply))
    }

    @Test func repliedAtIsTheReplyAfterTheRequestersSecondRound() throws {
      let pr = reviewedPR(
        verdicts: [changesVerdict("mariusandra")],
        reviews: [
          entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(),
          entry("mariusandra", "COMMENTED", at: afterReplies), reply(at: secondRoundReply),
        ])

      let rereview = try #require(pr.rereview)

      #expect(rereview.repliedAt == replyTime(secondRoundReply))
    }

    @Test func aLaterPendingReviewByTheAuthorDoesNotMoveRepliedAt() throws {
      let pr = reviewedPR(
        verdicts: [changesVerdict("mariusandra")],
        reviews: [
          entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest), reply(at: firstReply),
          entry(prAuthor, "PENDING", at: afterReplies),
        ])

      let rereview = try #require(pr.rereview)

      #expect(rereview.repliedAt == replyTime(firstReply))
    }

    /// The column does not change, so an answered change request still sits in Waiting.
    @Test func anAnsweredChangeRequestStaysOutOfInReview() {
      #expect(BoardColumn.prColumn(answeredPR()) == nil)
    }
  }
}

// MARK: - Parity with prColumn

extension RereviewTests {
  /// The PR has a re-review exactly when `prColumn` would put it In review without its
  /// change requests, for PRs whose change requests the author answered.
  @Suite struct ColumnParity {
    @Test(arguments: parityShapes)
    func aReReviewExistsExactlyWhenThePRWouldBeInReviewWithoutItsChangeRequests(_ name: String, _ pr: PullRequest) {
      let inReviewWithout = BoardColumn.prColumn(withoutChangeRequests(pr)) == .inReview

      #expect((pr.rereview != nil) == inReviewWithout, "\(name)")
    }

    /// Guards against a parity table in which every shape lands on the same side.
    @Test func theShapesCoverBothSides() {
      let sides = Set(parityShapes.map { BoardColumn.prColumn(withoutChangeRequests($0.1)) == .inReview })

      #expect(sides == [true, false])
    }
  }
}

// MARK: - wantsNudgeDetails

extension RereviewTests {
  @Suite struct WantsNudgeDetails {
    @Test func anInReviewPRWantsThem() {
      let pr = samplePR(
        reviewDecision: .reviewRequired, checks: "SUCCESS", reviewRequests: ["alice"], reviewDecisionRead: true)

      #expect(BoardColumn.prColumn(pr) == .inReview)
      #expect(BoardColumn.wantsNudgeDetails(pr))
    }

    /// The re-review nudge quotes no gist or size.
    @Test func aPRWithAReReviewDoesNotWantThem() {
      let pr = answeredPR()

      #expect(pr.rereview != nil)
      #expect(!BoardColumn.wantsNudgeDetails(pr))
    }

    @Test func aReadyToMergePRDoesNotWantThem() {
      let pr = samplePR(
        reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED", on: samplePRHead)], checks: "SUCCESS",
        reviewDecisionRead: true)

      #expect(BoardColumn.prColumn(pr) == .approved)
      #expect(!BoardColumn.wantsNudgeDetails(pr))
    }

    @Test func aWaitingPRWithAnUnansweredChangeRequestDoesNotWantThem() {
      let pr = reviewedPR(
        verdicts: [changesVerdict("mariusandra")],
        reviews: [entry("mariusandra", "CHANGES_REQUESTED", at: changeRequest)])

      #expect(pr.rereview == nil)
      #expect(!BoardColumn.wantsNudgeDetails(pr))
    }

    @Test func aWaitingPRWithFailedChecksDoesNotWantThem() {
      let pr = samplePR(
        reviewDecision: .reviewRequired, checks: "FAILURE", reviewRequests: ["alice"], reviewDecisionRead: true)

      #expect(!BoardColumn.wantsNudgeDetails(pr))
    }
  }
}
