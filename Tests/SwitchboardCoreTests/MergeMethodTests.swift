import Foundation
import Testing

@testable import SwitchboardCore

/// A PR that every ready-to-merge condition passes, in a repository whose
/// merge method the poller read: no `.trunk` folder and no merge queue, so
/// sbd merges it with a merge commit.
private func landablePR(
  draft: Bool = false, base: String = "main", mergeable: Mergeable? = .mergeable,
  reviewDecision: ReviewDecision? = .approved, verdicts: [Review] = [sampleVerdict("alice", "APPROVED")],
  checks: String? = "SUCCESS", queue: TrunkQueueState? = nil, reviewRequests: [String]? = [],
  trunkConfig: Bool? = false, mergeQueue: Bool? = false, inMergeQueue: Bool? = false
) -> PullRequest {
  var pr = samplePR(
    draft: draft, base: base, mergeable: mergeable, reviewDecision: reviewDecision, verdicts: verdicts,
    checks: checks, queue: queue, reviewRequests: reviewRequests)
  pr.trunkConfig = trunkConfig
  pr.mergeQueue = mergeQueue
  pr.inMergeQueue = inMergeQueue
  pr.reviewDecisionRead = true
  return pr
}

/// A PR whose repository merges by `method`.
private func landablePR(_ method: MergeMethod) -> PullRequest {
  switch method {
  case .merge: landablePR()
  case .mergeQueue: landablePR(mergeQueue: true)
  case .trunk: landablePR(trunkConfig: true)
  case .unknown: landablePR(trunkConfig: nil, mergeQueue: nil)
  }
}

private func methodFacts(_ method: MergeMethod, edit: (inout PullRequest) -> Void = { _ in }, then: [Event] = [])
  throws -> SessionFacts
{
  var pr = landablePR(method)
  edit(&pr)
  return try prFacts(pr, then: then)
}

private let otherBotComment = PRComment(id: "IC_gh", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:00Z")

private let now: Int64 = 10

private func verdict(_ facts: SessionFacts, _ s: Session = session()) -> Verdict {
  Attention.evaluate(s, facts, now: now)
}

private let unknownSuffix = "; can't tell how acme/widgets merges, so merge it on GitHub"

/// One way a PR fails a ready-to-merge condition.
enum ReadyToMergeBlocker: String, CaseIterable, Sendable {
  case reviewRequired, changesRequested, reviewRequestOpenWithoutADecision, olderChangeRequestWithoutADecision
  case draft, stackedOnAnotherBranch, inTheMergeQueue, inTrunksQueue
  case checksPending, checksExpected, checksFailed, checksErrored, noChecks
  case mergeabilityUnknown, mergeabilityNotRead, conflicting

  func apply(_ pr: inout PullRequest) {
    switch self {
    case .reviewRequired: pr.reviewDecision = .reviewRequired
    case .changesRequested: pr.reviewDecision = .changesRequested
    case .reviewRequestOpenWithoutADecision:
      pr.reviewDecision = nil
      pr.verdicts = []
      pr.reviewRequests = ["bob"]
    case .olderChangeRequestWithoutADecision:
      pr.reviewDecision = nil
      pr.verdicts = [sampleVerdict("bob", "CHANGES_REQUESTED", on: "older")]
    case .draft: pr.draft = true
    case .stackedOnAnotherBranch: pr.base = "haacked/parent"
    case .inTheMergeQueue: pr.inMergeQueue = true
    case .inTrunksQueue: pr.queue = .testing
    case .checksPending: pr.checks = "PENDING"
    case .checksExpected: pr.checks = "EXPECTED"
    case .checksFailed: pr.checks = "FAILURE"
    case .checksErrored: pr.checks = "ERROR"
    case .noChecks: pr.checks = nil
    case .mergeabilityUnknown: pr.mergeable = .unknown
    case .mergeabilityNotRead: pr.mergeable = nil
    case .conflicting: pr.mergeable = .conflicting
    }
  }
}

/// The suites nest under one name, so `--filter MergeMethodTests` runs them all.
@Suite struct MergeMethodTests {}

extension MergeMethodTests {
  @Suite struct ReviewSatisfied {
    @Test(arguments: [
      ("approved", samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")])),
      ("approved without verdicts", samplePR(reviewDecision: .approved)),
      (
        "approved with another review request open",
        samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], reviewRequests: ["bob"])
      ),
      ("no decision, requests not read", samplePR(reviewDecision: nil, reviewRequests: nil, reviewDecisionRead: true)),
      ("no decision, nobody asked", samplePR(reviewDecision: nil, reviewRequests: [], reviewDecisionRead: true)),
      (
        "no decision, approved",
        samplePR(reviewDecision: nil, verdicts: [sampleVerdict("alice", "APPROVED")], reviewDecisionRead: true)
      ),
    ])
    func reviewIsSatisfied(_ label: String, _ pr: PullRequest) {
      #expect(pr.reviewSatisfied, "\(label)")
    }

    @Test(arguments: [
      ("review required", samplePR(reviewDecision: .reviewRequired)),
      (
        "review required with an approval",
        samplePR(reviewDecision: .reviewRequired, verdicts: [sampleVerdict("alice", "APPROVED")])
      ),
      ("review required, nobody asked", samplePR(reviewDecision: .reviewRequired, reviewRequests: [])),
      ("changes requested", samplePR(reviewDecision: .changesRequested)),
      (
        "changes requested with an approval",
        samplePR(reviewDecision: .changesRequested, verdicts: [sampleVerdict("bob", "APPROVED")])
      ),
      (
        "approved with a change request that still stands",
        samplePR(
          reviewDecision: .approved,
          verdicts: [sampleVerdict("alice", "APPROVED"), sampleVerdict("bob", "CHANGES_REQUESTED", on: "older")])
      ),
      ("decision not read", samplePR(reviewDecision: nil, reviewRequests: [])),
      ("no decision, a review request open", samplePR(reviewDecision: nil, reviewRequests: ["bob"])),
      (
        "no decision, approved, a review request open",
        samplePR(reviewDecision: nil, verdicts: [sampleVerdict("alice", "APPROVED")], reviewRequests: ["bob"])
      ),
      (
        "no decision, changes requested",
        samplePR(reviewDecision: nil, verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)])
      ),
      (
        "no decision, changes requested on an older commit",
        samplePR(reviewDecision: nil, verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: "older")])
      ),
      (
        "no decision, approved and changes requested",
        samplePR(
          reviewDecision: nil,
          verdicts: [sampleVerdict("alice", "APPROVED"), sampleVerdict("bob", "CHANGES_REQUESTED")])
      ),
    ])
    func reviewIsNotSatisfied(_ label: String, _ pr: PullRequest) {
      #expect(!pr.reviewSatisfied, "\(label)")
    }
  }
}

extension MergeMethodTests {
  @Suite struct MergeQueueParsing {
    @Test(arguments: ["isMergeQueueEnabled", "isInMergeQueue"])
    func statusQueryAsksForTheMergeQueueFields(_ field: String) {
      #expect(GitHub.statusQuery.contains(field))
    }

    @Test(arguments: [true, false])
    func readsWhetherTheBranchMergesThroughAQueue(_ enabled: Bool) throws {
      let node = try editedNode(18303, ["isMergeQueueEnabled": .bool(enabled)])

      #expect(GitHub.parsePR(node)?.pr.mergeQueue == enabled)
    }

    @Test(arguments: [true, false])
    func readsWhetherThePRIsInTheQueue(_ queued: Bool) throws {
      let node = try editedNode(18303, ["isInMergeQueue": .bool(queued)])

      #expect(GitHub.parsePR(node)?.pr.inMergeQueue == queued)
    }

    @Test func aResponseWithoutTheMergeQueueFieldsLeavesThemUnread() throws {
      let node = try editedNode(18303, ["isMergeQueueEnabled": nil, "isInMergeQueue": nil])

      let pr = try #require(GitHub.parsePR(node)?.pr)

      #expect(pr.mergeQueue == nil)
      #expect(pr.inMergeQueue == nil)
    }

    @Test func prEventKeepsTheMergeQueueFields() throws {
      let f = facts([try prEvent(1, landablePR(mergeQueue: true, inMergeQueue: true))])

      #expect(f.pr?.mergeQueue == true)
      #expect(f.pr?.inMergeQueue == true)
    }
  }
}

extension MergeMethodTests {
  @Suite struct MergeMethodEncoding {
    @Test(arguments: [
      (MergeMethod.merge, "merge"), (.mergeQueue, "merge_queue"), (.trunk, "trunk"), (.unknown, "unknown"),
    ])
    func encodesAsSnakeCase(_ method: MergeMethod, _ text: String) throws {
      #expect(try JSON(encoding: method) == .string(text))
    }

    @Test func decodesMergeQueueFromSnakeCase() throws {
      #expect(try JSONCoding.convert(JSON.string("merge_queue"), to: MergeMethod.self) == .mergeQueue)
    }
  }
}

extension MergeMethodTests {
  @Suite struct MergeMethodFacts {
    @Test(arguments: [
      ("trunk folder", landablePR(trunkConfig: true), [PRComment](), MergeMethod.trunk),
      ("trunk folder and a merge queue", landablePR(trunkConfig: true, mergeQueue: true), [], .trunk),
      ("trunk folder, merge queue unread", landablePR(trunkConfig: true, mergeQueue: nil), [], .trunk),
      ("trunk comment", landablePR(), [otherBotComment, trunkComment()], .trunk),
      ("trunk comment, nothing else read", landablePR(trunkConfig: nil, mergeQueue: nil), [trunkComment()], .trunk),
      ("trunk comment and a merge queue", landablePR(mergeQueue: true), [trunkComment()], .trunk),
      ("trunk queue state", landablePR(queue: .testing), [], .trunk),
      ("trunk queue state that did not load", landablePR(queue: .unknown), [], .trunk),
      (
        "trunk queue state, nothing else read", landablePR(queue: .queued, trunkConfig: nil, mergeQueue: nil), [],
        .trunk
      ),
      ("merge queue", landablePR(mergeQueue: true), [], .mergeQueue),
      ("merge queue, trunk folder unread", landablePR(trunkConfig: nil, mergeQueue: true), [], .mergeQueue),
      ("neither", landablePR(), [], .merge),
      ("neither, other bot comments", landablePR(), [otherBotComment], .merge),
      ("trunk folder unread", landablePR(trunkConfig: nil), [], .unknown),
      ("merge queue unread", landablePR(mergeQueue: nil), [], .unknown),
      ("nothing read", landablePR(trunkConfig: nil, mergeQueue: nil), [], .unknown),
    ])
    func mergeMethodFollowsWhatThePollerRead(
      _ label: String, _ pr: PullRequest, _ comments: [PRComment], _ method: MergeMethod
    ) throws {
      let f = try prFacts(pr, comments: comments)

      #expect(f.mergeMethod == method, "\(label)")
    }
  }
}

extension MergeMethodTests {
  @Suite struct ReadyToMergeOptions {
    @Test(arguments: [
      (MergeMethod.merge, "Merge #42"), (.mergeQueue, "Enqueue #42"), (.trunk, "Enqueue #42"),
    ])
    func readyPROffersItsMethodsMergeOption(_ method: MergeMethod, _ label: String) throws {
      let f = try methodFacts(method)

      let v = verdict(f)

      #expect(v.state == .readyToMerge)
      #expect(v.options.map(\.label) == [label, "Dismiss"])
    }

    @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk])
    func mergeOptionMergesAndIsRecommended(_ method: MergeMethod) throws {
      let f = try methodFacts(method)

      let option = try #require(verdict(f).options.first)

      #expect(option.action == .merge)
      #expect(option.recommended)
    }

    @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk, .unknown])
    func readyPRAlwaysOffersDismiss(_ method: MergeMethod) throws {
      let f = try methodFacts(method)

      #expect(verdict(f).options.contains { $0.label == "Dismiss" && $0.action == .dismiss })
    }

    @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk])
    func reasonNamesTheApprovers(_ method: MergeMethod) throws {
      let f = try methodFacts(method)

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge, approved by alice"))
    }

    @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk])
    func reasonWithoutApproversIsJustReady(_ method: MergeMethod) throws {
      let f = try methodFacts(method) {
        $0.reviewDecision = nil
        $0.verdicts = []
      }

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    @Test func undeterminedMethodIsReadyToMergeWithoutAMergeOption() throws {
      let f = try methodFacts(.unknown)

      let v = verdict(f)

      #expect(v.state == .readyToMerge)
      #expect(!v.options.contains { $0.action == .merge })
    }

    @Test func undeterminedMethodOffersOnlyDismiss() throws {
      let f = try methodFacts(.unknown)

      #expect(verdict(f).options.map(\.label) == ["Dismiss"])
    }

    @Test func undeterminedMethodsReasonSendsTheUserToGitHub() throws {
      let f = try methodFacts(.unknown)

      #expect(
        verdict(f)
          == Verdict(state: .readyToMerge, reason: "#42 is ready to merge, approved by alice" + unknownSuffix))
    }

    @Test func undeterminedMethodsReasonWithoutApprovers() throws {
      let f = try methodFacts(.unknown) {
        $0.reviewDecision = nil
        $0.verdicts = []
      }

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge" + unknownSuffix))
    }
  }
}

extension MergeMethodTests {
  /// Trunk and merge-queue repositories reach Ready to merge now, so each
  /// condition is checked against every method.
  @Suite struct ReadyToMergeConditions {
    static let methods: [MergeMethod] = [.merge, .mergeQueue, .trunk, .unknown]

    @Test(arguments: methods)
    func approvedPRWithAnotherReviewRequestOpenIsReadyToMerge(_ method: MergeMethod) throws {
      let f = try methodFacts(method) { $0.reviewRequests = ["bob"] }

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test(arguments: methods)
    func prWithoutADecisionThatNobodyWasAskedToReviewIsReadyToMerge(_ method: MergeMethod) throws {
      let f = try methodFacts(method) {
        $0.reviewDecision = nil
        $0.verdicts = []
        $0.reviewRequests = nil
      }

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test(arguments: methods, [Bool?.none, false])
    func prThatIsNotInTheMergeQueueIsReadyToMerge(_ method: MergeMethod, _ inMergeQueue: Bool?) throws {
      let f = try methodFacts(method) { $0.inMergeQueue = inMergeQueue }

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test(arguments: methods, ReadyToMergeBlocker.allCases)
    func prThatCannotLandIsNotReadyToMerge(_ method: MergeMethod, _ blocker: ReadyToMergeBlocker) throws {
      let f = try methodFacts(method, edit: blocker.apply)

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test(arguments: methods)
    func prThatADependencyHoldsIsNotReadyToMerge(_ method: MergeMethod) throws {
      let dependency = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .open)
      let f = try methodFacts(method, then: [try dependenciesEvent(3, [dependency])])

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test(arguments: methods)
    func prDismissedAtItsHeadIsNotReadyToMerge(_ method: MergeMethod) throws {
      let f = try methodFacts(method, then: [mergeEvent(3, head: samplePRHead, "dismissed")])

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test(arguments: [PRState.merged, .closed], methods)
    func finishedPRIsNotReadyToMerge(_ state: PRState, _ method: MergeMethod) throws {
      let f = try methodFacts(method) { $0.state = state }

      #expect(verdict(f).state != .readyToMerge)
    }
  }
}

extension MergeMethodTests {
  @Suite struct ConflictedPR {
    @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk, .unknown])
    func conflictedPRAsksForARebase(_ method: MergeMethod) throws {
      let f = try methodFacts(method) { $0.mergeable = .conflicting }

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "rebase; #42 conflicts with main"))
    }

    @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk, .unknown])
    func conflictedPROffersARebaseAndNoMerge(_ method: MergeMethod) throws {
      let f = try methodFacts(method) { $0.mergeable = .conflicting }

      let v = verdict(f)

      #expect(v.options.map(\.label) == ["Rebase"])
      #expect(!v.options.contains { $0.action == .merge })
    }
  }
}

extension MergeMethodTests {
  /// A null review decision means "no review required" only when the poll
  /// read it. An older event or an unrecognized decision string keeps the PR
  /// out of Ready to merge.
  @Suite struct UnreadReviewDecision {
    @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk])
    func prWhoseReviewDecisionWasNotReadIsNotReadyToMerge(_ method: MergeMethod) throws {
      let f = try methodFacts(method) {
        $0.reviewDecision = nil
        $0.reviewDecisionRead = nil
        $0.verdicts = []
      }

      #expect(verdict(f).state != .readyToMerge)
      #expect(!verdict(f).options.contains { $0.action == .merge })
    }

    @Test func unrecognizedReviewDecisionIsNotReadyToMerge() throws {
      var node = try #require(GitHubFixtures.statusNode(18303)?.object)
      node["reviewDecision"] = "SOMETHING_NEW"
      node["isMergeQueueEnabled"] = false
      let parsed = try #require(GitHub.parsePR(.object(node)))

      #expect(parsed.pr.reviewDecisionRead == nil)
      #expect(!parsed.pr.reviewSatisfied)
    }
  }
}

extension MergeMethodTests {
  /// An approved PR that can't land yet waits on GitHub or needs the user,
  /// and never moves into Ready for review.
  @Suite struct ApprovedButNotLandable {
    static let methods: [MergeMethod] = [.merge, .mergeQueue, .trunk, .unknown]

    @Test(arguments: methods, ["PENDING", "EXPECTED"])
    func approvedPRWhoseChecksRunWaits(_ method: MergeMethod, _ checks: String) throws {
      let f = try methodFacts(method) { $0.checks = checks }

      #expect(verdict(f) == Verdict(state: .waiting, reason: "checks running on #42; #42 approved"))
    }

    @Test func approvedPRWithoutADecisionWhoseChecksRunWaits() throws {
      let f = try methodFacts(.merge) {
        $0.reviewDecision = nil
        $0.checks = "PENDING"
      }

      #expect(verdict(f) == Verdict(state: .waiting, reason: "checks running on #42; #42 needs no review"))
    }

    @Test(arguments: methods)
    func approvedPRWhoseMergeabilityGitHubStillComputesWaits(_ method: MergeMethod) throws {
      let f = try methodFacts(method) { $0.mergeable = .unknown }

      #expect(
        verdict(f)
          == Verdict(state: .waiting, reason: "GitHub is still checking whether #42 can merge; #42 approved"))
    }

    /// GitHub still asks bob for a review, which alone would put the PR in
    /// Ready for review.
    @Test(arguments: ["PENDING", "EXPECTED"])
    func approvedPRWhoseChecksRunWithAReviewRequestOpenWaits(_ checks: String) throws {
      let f = try methodFacts(.merge) {
        $0.checks = checks
        $0.reviewRequests = ["bob"]
      }

      #expect(verdict(f) == Verdict(state: .waiting, reason: "checks running on #42; #42 approved"))
    }

    @Test(arguments: methods, ["FAILURE", "ERROR"])
    func approvedPRWhoseChecksFailedNeedsYou(_ method: MergeMethod, _ checks: String) throws {
      let f = try methodFacts(method) { $0.checks = checks }

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "fix the checks on #42; approved by alice"))
    }

    @Test func approvedPRWhoseChecksFailedNamesEachApprover() throws {
      let f = try methodFacts(.merge) {
        $0.checks = "FAILURE"
        $0.verdicts = [sampleVerdict("bob", "APPROVED"), sampleVerdict("alice", "APPROVED")]
      }

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "fix the checks on #42; approved by alice and bob"))
    }

    @Test(arguments: ["FAILURE", "ERROR"])
    func approvedPRWhoseChecksFailedOffersToFixThem(_ checks: String) throws {
      let f = try methodFacts(.merge) { $0.checks = checks }

      let option = try #require(verdict(f).options.first)

      #expect(option.label == "Fix the checks")
      #expect(option.action == .send)
    }

    @Test(arguments: methods)
    func approvedPRWhoseChecksFailedOffersNoMerge(_ method: MergeMethod) throws {
      let f = try methodFacts(method) { $0.checks = "FAILURE" }

      #expect(!verdict(f).options.contains { $0.action == .merge })
    }

    @Test(arguments: methods)
    func prInTheMergeQueueWaits(_ method: MergeMethod) throws {
      let f = try methodFacts(method) { $0.inMergeQueue = true }

      #expect(verdict(f) == Verdict(state: .waiting, reason: "#42 is in the merge queue; #42 approved"))
    }

    @Test func prInTheMergeQueueWithAReviewRequestOpenWaits() throws {
      let f = try methodFacts(.mergeQueue) {
        $0.inMergeQueue = true
        $0.reviewRequests = ["bob"]
      }

      #expect(verdict(f) == Verdict(state: .waiting, reason: "#42 is in the merge queue; #42 approved"))
    }

    @Test func prInTheMergeQueueWithAWaitShowsTheWait() throws {
      let f = try methodFacts(.mergeQueue) { $0.inMergeQueue = true }

      #expect(
        verdict(f, session(wait: "the merge queue for #42"))
          == Verdict(state: .waiting, reason: "the merge queue for #42; #42 approved"))
    }
  }
}

extension MergeMethodTests {
  /// A session whose PR's review is satisfied never moves into Ready for
  /// review. A Waiting session with such a PR stays Waiting.
  @Suite struct ReadyForReviewPrecedence {
    @Test(arguments: [
      ("approved, ready to land", landablePR()),
      ("approved, checks pending", landablePR(checks: "PENDING")),
      ("approved, checks failed", landablePR(checks: "FAILURE")),
      ("approved, a review request open", landablePR(reviewRequests: ["bob"])),
      ("approved, in the merge queue", landablePR(mergeQueue: true, inMergeQueue: true)),
      ("no decision, nobody asked", landablePR(reviewDecision: nil, verdicts: [], reviewRequests: [])),
      ("no decision, requests not read", landablePR(reviewDecision: nil, verdicts: [], reviewRequests: nil)),
      ("no decision, no checks", landablePR(reviewDecision: nil, verdicts: [], checks: nil)),
      ("no decision, approved", landablePR(reviewDecision: nil)),
    ])
    func waitingSessionWithASatisfiedReviewStaysWaiting(_ label: String, _ pr: PullRequest) throws {
      let f = try prFacts(pr)

      #expect(verdict(f, session(wait: "the deploy of #42")).state == .waiting, "\(label)")
    }

    @Test(arguments: [
      ("approved", landablePR()),
      ("no decision, nobody asked", landablePR(reviewDecision: nil, verdicts: [], reviewRequests: [])),
    ])
    func sessionThatADependencyHoldsWithASatisfiedReviewStaysWaiting(_ label: String, _ pr: PullRequest) throws {
      let dependency = Dependency(via: .body, repo: "acme/widgets", number: 41, state: .open)
      let f = try prFacts(pr, then: [try dependenciesEvent(3, [dependency])])

      #expect(verdict(f).state == .waiting, "\(label)")
    }

    @Test func backgroundJobWithASatisfiedReviewIsNotReadyForReview() throws {
      let f = try prFacts(landablePR(checks: "PENDING"), then: [event("job", 3, ["count": 1])])

      #expect(verdict(f).state == .waiting)
    }

    /// The control case: a review that GitHub still requires keeps the
    /// session in Ready for review.
    @Test func waitingSessionWhosePRNeedsAReviewIsReadyForReview() throws {
      let pr = landablePR(reviewDecision: .reviewRequired, verdicts: [], reviewRequests: ["ann"])
      let f = try prFacts(pr)

      #expect(verdict(f, session(wait: "the deploy of #42")).state == .readyForReview)
    }
  }
}

extension MergeMethodTests {
  @Suite struct EnqueuedAttempt {
    @Test func enqueuedEncodesAsEnqueued() throws {
      #expect(MergeAttempt.Result.enqueued.rawValue == "enqueued")
    }

    @Test func mergeEventWithAnEnqueuedResultSetsTheAttempt() {
      let f = facts([mergeEvent(1, head: "abc", "enqueued")])

      #expect(f.merge == MergeAttempt(head: "abc", result: .enqueued))
    }

    @Test func enqueuedAttemptHasNoMergeError() throws {
      let f = try methodFacts(.trunk, then: [mergeEvent(3, head: samplePRHead, "enqueued")])

      #expect(f.mergeError == nil)
    }
  }
}

extension MergeMethodTests {
  @Suite struct SummaryFields {
    @Test(arguments: [ReviewDecision.approved, .reviewRequired, .changesRequested])
    func summaryCarriesTheReviewDecision(_ decision: ReviewDecision) {
      #expect(PRSummary(samplePR(reviewDecision: decision)).reviewDecision == decision)
    }

    @Test func summaryOfAPRWithoutADecisionHasNone() {
      #expect(PRSummary(samplePR(reviewDecision: nil)).reviewDecision == nil)
    }

    @Test func summaryListsTheApproversSorted() {
      let pr = samplePR(
        verdicts: [
          sampleVerdict("bob", "APPROVED"), sampleVerdict("carol", "CHANGES_REQUESTED"),
          sampleVerdict("alice", "APPROVED"),
        ])

      #expect(PRSummary(pr).approvers == ["alice", "bob"])
    }

    @Test func summaryOfAPRThatNobodyApprovedHasNoApprovers() {
      #expect(PRSummary(samplePR()).approvers == [])
    }

    @Test func approvedAtIsTheNewestApproval() {
      let pr = samplePR(
        verdicts: [
          Review(author: "alice", state: "APPROVED", submittedAt: "2026-10-25T10:00:00Z"),
          Review(author: "bob", state: "APPROVED", submittedAt: "2026-10-26T09:00:00Z"),
          Review(author: "carol", state: "CHANGES_REQUESTED", submittedAt: "2026-10-27T00:00:00Z"),
        ])

      #expect(PRSummary(pr).approvedAt == "2026-10-26T09:00:00Z")
    }

    @Test func approvedAtIsNilWithoutAnApproval() {
      let pr = samplePR(verdicts: [sampleVerdict("carol", "CHANGES_REQUESTED")])

      #expect(PRSummary(pr).approvedAt == nil)
    }

    @Test(arguments: [Bool?.none, false, true])
    func summaryCarriesWhetherThePRIsInTheMergeQueue(_ inMergeQueue: Bool?) {
      #expect(PRSummary(landablePR(inMergeQueue: inMergeQueue)).inMergeQueue == inMergeQueue)
    }

    @Test func summaryMadeFromThePRAloneHasNoMergeMethod() {
      #expect(PRSummary(landablePR(mergeQueue: true)).mergeMethod == nil)
    }

    @Test func summaryEncodesItsMergeMethodInSnakeCase() throws {
      var summary = PRSummary(landablePR())
      summary.mergeMethod = .mergeQueue

      #expect(try JSON(encoding: summary)["mergeMethod"] == .string("merge_queue"))
    }
  }
}
