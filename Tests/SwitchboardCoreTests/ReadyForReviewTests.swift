import Foundation
import Testing

@testable import SwitchboardCore

/// A PR that waits on ann's review: open, not a draft, mergeable, its checks
/// passed, no verdict, and GitHub requires a review.
private func reviewPR(
  state: PRState = .open, draft: Bool = false, reviewDecision: ReviewDecision? = .reviewRequired,
  verdicts: [Review] = [], checks: String? = "SUCCESS", queue: TrunkQueueState? = nil,
  reviewRequests: [String]? = ["ann"]
) -> PullRequest {
  var pr = samplePR(
    state: state, draft: draft, reviewDecision: reviewDecision, verdicts: verdicts, checks: checks, queue: queue,
    reviewRequests: reviewRequests)
  pr.title = "Fix"
  return pr
}

private let unreadyPRs = [
  ("draft", reviewPR(draft: true)), ("merged", reviewPR(state: .merged)), ("closed", reviewPR(state: .closed)),
]

/// An open PR in the same repo that holds the session's PR through a
/// `Depends on` line.
private let openDependency = Dependency(via: .body, repo: "acme/widgets", number: 41, state: .open)

private let now: Int64 = 10

private func verdict(_ facts: SessionFacts, _ s: Session = session()) -> Verdict {
  Attention.evaluate(s, facts, now: now)
}

/// The suites nest under one name, so `--filter ReadyForReview` runs them all.
@Suite struct ReadyForReviewTests {}

extension ReadyForReviewTests {
  @Suite struct ReadyForReviewState {
    @Test func statesComeInTheBoardsColumnOrder() {
      #expect(
        AttentionState.allCases == [
          .needsYou, .readyToMerge, .canContinue, .readyForReview, .waiting, .working, .done, .stale, .notStarted,
        ])
    }

    @Test func readyForReviewIsTitledReadyForReview() {
      #expect(AttentionState.readyForReview.title == "Ready for review")
    }

    @Test func readyForReviewDecodesFromSnakeCase() throws {
      let decoded = try JSONCoding.convert(JSON.string("ready_for_review"), to: AttentionState.self)

      #expect(decoded == .readyForReview)
    }

    @Test func readyForReviewDoesNotNeedTheUser() {
      #expect(!AttentionState.readyForReview.needsUser)
    }

    @Test func inboxDoesNotListReadyForReview() {
      #expect(!AttentionState.inbox.contains(.readyForReview))
    }
  }
}

extension ReadyForReviewTests {
  @Suite struct ReadyForReviewSummary {
    @Test func summaryCarriesTheRequestedReviewers() {
      let summary = PRSummary(reviewPR(reviewRequests: ["ann", "bob"]))

      #expect(summary.reviewRequests == ["ann", "bob"])
    }

    @Test func summaryOfAPRWhoseReviewRequestsWereNotReadHasNone() {
      let summary = PRSummary(reviewPR(reviewRequests: nil))

      #expect(summary.reviewRequests == nil)
    }
  }
}

extension ReadyForReviewTests {
  @Suite struct ReadySinceFacts {
    @Test(arguments: [
      ("review requested", reviewPR()),
      ("no review requested", reviewPR(reviewDecision: nil, reviewRequests: [])),
      ("review requests not read", reviewPR(reviewRequests: nil)),
      ("approved", reviewPR(reviewDecision: .approved, verdicts: [sampleVerdict("ann", "APPROVED")])),
      ("checks failed", reviewPR(checks: "FAILURE")),
    ])
    func anyOpenReadyPRSetsReadySince(_ label: String, _ pr: PullRequest) throws {
      let f = facts([try prEvent(5, pr)])

      #expect(f.readySince == 5, "\(label)")
    }

    @Test(arguments: unreadyPRs)
    func prEventWithAnUnreadyPRLeavesReadySinceUnset(_ label: String, _ pr: PullRequest) throws {
      let f = facts([try prEvent(5, pr)])

      #expect(f.readySince == nil, "\(label)")
    }

    @Test func noPREventLeavesReadySinceUnset() {
      let f = facts([
        event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "ok"]),
      ])

      #expect(f.readySince == nil)
    }

    @Test(arguments: [
      ("other checks", reviewPR(checks: "PENDING")),
      ("other reviewers", reviewPR(reviewRequests: ["bob"])),
    ])
    func laterReadyPREventKeepsTheFirstTime(_ label: String, _ later: PullRequest) throws {
      let f = facts([try prEvent(5, reviewPR()), try prEvent(9, later)])

      #expect(f.readySince == 5, "\(label)")
    }

    @Test(arguments: unreadyPRs)
    func prEventWithAnUnreadyPRClearsReadySince(_ label: String, _ pr: PullRequest) throws {
      let f = facts([try prEvent(5, reviewPR()), try prEvent(9, pr)])

      #expect(f.readySince == nil, "\(label)")
    }

    @Test(arguments: [("null", ["pr": JSON.null]), ("missing", [:])])
    func prEventWithoutAPRClearsReadySince(_ label: String, _ fields: [String: JSON]) throws {
      let f = facts([try prEvent(5, reviewPR()), event("pr", 9, fields)])

      #expect(f.readySince == nil, "\(label)")
    }

    @Test func readyPRAfterADraftCountsFromItsOwnEvent() throws {
      let f = facts([try prEvent(5, reviewPR()), try prEvent(7, reviewPR(draft: true)), try prEvent(9, reviewPR())])

      #expect(f.readySince == 9)
    }

    @Test func draftThatBecomesReadyCountsFromTheReadyEvent() throws {
      let f = facts([try prEvent(5, reviewPR(draft: true)), try prEvent(9, reviewPR())])

      #expect(f.readySince == 9)
    }

    @Test func eventsOtherThanPRKeepReadySince() throws {
      let f = facts([
        try prEvent(5, reviewPR()), event("UserPromptSubmit", 6, ["prompt": "go"]),
        event("Stop", 7, ["last_assistant_message": "Pushed."]), event("worktree", 8, ["dirty": .number(0)]),
        try dependenciesEvent(9, []),
      ])

      #expect(f.readySince == 5)
    }
  }
}

extension ReadyForReviewTests {
  @Suite struct ReadyForReviewRule {
    @Test func prThatWaitsOnAReviewIsReadyForReview() throws {
      let f = try prFacts(reviewPR())

      #expect(
        verdict(f) == Verdict(state: .readyForReview, reason: "#42 Fix; review requested from ann, checks success"))
    }

    @Test(arguments: [
      (reviewPR(reviewRequests: ["ann", "bob"]), "#42 Fix; review requested from ann and bob, checks success"),
      (
        reviewPR(verdicts: [sampleVerdict("ann", "APPROVED")], reviewRequests: ["bob"]),
        "#42 Fix; approved by ann; review requested from bob, checks success"
      ),
      (reviewPR(checks: "PENDING"), "#42 Fix; review requested from ann, checks pending"),
      (reviewPR(checks: nil), "#42 Fix; review requested from ann, no checks"),
    ])
    func reasonNamesTheReviewsAndTheChecks(_ pr: PullRequest, _ reason: String) throws {
      let f = try prFacts(pr)

      #expect(verdict(f) == Verdict(state: .readyForReview, reason: reason))
    }

    /// The change request is on an older commit, so `openPR` does not ask
    /// the user to address it, and the PR waits on bob's second review.
    @Test func reasonNamesWhoRequestedChangesBeforeTheReviewRequests() throws {
      let pr = reviewPR(
        reviewDecision: .changesRequested, verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED", on: "older")],
        reviewRequests: ["bob"])
      let f = try prFacts(pr)

      let v = verdict(f)

      #expect(v.state == .readyForReview)
      #expect(v.reason.hasPrefix("#42 Fix; changes requested by bob; review requested from bob"))
    }

    @Test func prThatWaitsOnAReviewStaysReadyForReviewAfterTheStaleInterval() throws {
      let f = try prFacts(reviewPR())

      #expect(Attention.evaluate(session(), f, now: Attention.staleAfterMs + 10).state == .readyForReview)
    }

    @Test func trunkSubmittedPRThatIsNotYetQueuedIsReadyForReview() throws {
      let f = try prFacts(reviewPR(queue: .submitted))

      #expect(verdict(f, session(wait: "CI on #42")).state == .readyForReview)
    }
  }
}

extension ReadyForReviewTests {
  /// A Waiting verdict that a wait or a dependency gave keeps its reason
  /// after the PR's.
  @Suite struct ReadyForReviewWaitReason {
    @Test(arguments: [
      (reviewPR(), "review requested from ann"),
      (reviewPR(reviewRequests: []), "review required"),
      (reviewPR(reviewDecision: nil, reviewRequests: []), "no review requested"),
      (reviewPR(reviewDecision: nil, reviewRequests: nil), "no review requested"),
    ])
    func waitsReasonFollowsThePRsReason(_ pr: PullRequest, _ reviews: String) throws {
      let f = try prFacts(pr)

      #expect(
        verdict(f, session(wait: "CI on #42"))
          == Verdict(state: .readyForReview, reason: "#42 Fix; \(reviews), checks success; CI on #42"))
    }

    @Test func dependencysReasonFollowsThePRsReason() throws {
      let f = try prFacts(
        reviewPR(reviewDecision: nil, reviewRequests: []), then: [try dependenciesEvent(3, [openDependency])])

      #expect(
        verdict(f)
          == Verdict(state: .readyForReview, reason: "#42 Fix; no review requested, checks success; waits on #41"))
    }

    @Test func backgroundJobWithAReadyPRIsReadyForReview() throws {
      let f = try prFacts(reviewPR(reviewRequests: []), then: [event("job", 3, ["count": 1])])

      #expect(verdict(f).state == .readyForReview)
    }
  }
}

extension ReadyForReviewTests {
  /// Only a Waiting verdict moves to Ready for review, and only for an open,
  /// ready PR that Trunk has not queued and sbd has not merged.
  @Suite struct ReadyForReviewPrecedence {
    @Test(arguments: unreadyPRs)
    func unreadyPRStaysWaiting(_ label: String, _ pr: PullRequest) throws {
      let f = try prFacts(pr)

      #expect(verdict(f, session(wait: "CI on #42")) == Verdict(state: .waiting, reason: "CI on #42"), "\(label)")
    }

    @Test(arguments: [TrunkQueueState.pending, .testing, .passed, .failing, .queued])
    func prInTrunksQueueStaysWaiting(_ queue: TrunkQueueState) throws {
      let f = try prFacts(reviewPR(queue: queue))

      #expect(verdict(f, session(wait: "CI on #42")) == Verdict(state: .waiting, reason: "CI on #42"))
    }

    @Test(arguments: [(String?.none, "#42 merged; GitHub has not reported it yet"), ("CI on #42", "CI on #42")])
    func prThatSbdMergedStaysWaiting(_ wait: String?, _ reason: String) throws {
      let f = try prFacts(reviewPR(), then: [mergeEvent(3, head: samplePRHead, "merged")])

      #expect(verdict(f, session(wait: wait)) == Verdict(state: .waiting, reason: reason))
    }

    @Test func prWithoutAPRStaysWaiting() throws {
      let f = try prFacts(nil)

      #expect(verdict(f, session(wait: "CI on #42")) == Verdict(state: .waiting, reason: "CI on #42"))
    }

    @Test(arguments: [nil, "CI on #42"])
    func sessionWithARunningTurnIsWorking(_ wait: String?) throws {
      let f = try prFacts(reviewPR(), then: [event("UserPromptSubmit", 4, ["prompt": "keep going"])])

      #expect(verdict(f, session(wait: wait)).state == .working)
    }

    @Test func sessionWhoseLastReplyAsksAQuestionNeedsYou() throws {
      let f = try prFacts(reviewPR(), reply: "Which base should it target?")

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "answer: Which base should it target?"))
    }

    @Test(arguments: [nil, "CI on #42"])
    func sessionWithACardNeedsYou(_ wait: String?) throws {
      var f = try prFacts(reviewPR())
      f.cards = [Card(event("PermissionRequest", 3, tool("Bash", ["command": "ls"])))]

      #expect(verdict(f, session(wait: wait)).state == .needsYou)
    }

    @Test func prThatCanMergeIsReadyToMerge() throws {
      var pr = reviewPR(reviewDecision: nil, reviewRequests: [])
      pr.trunkConfig = false
      let f = try prFacts(pr)

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    @Test func sessionThatOffersANextStepCanContinue() throws {
      let f = try prFacts(reviewPR(), reply: "Want me to push the fix?")

      #expect(verdict(f) == Verdict(state: .canContinue, reason: "offered: Want me to push the fix?"))
    }

    @Test(arguments: [nil, "CI on #42"])
    func sessionMarkedDoneIsDone(_ wait: String?) throws {
      let f = try prFacts(reviewPR())

      #expect(verdict(f, session(done: true, wait: wait)).state == .done)
    }
  }
}
