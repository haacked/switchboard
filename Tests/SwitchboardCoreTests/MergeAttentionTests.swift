import Foundation
import Testing

@testable import SwitchboardCore

/// A PR that every ready-to-merge condition passes: open, not a draft,
/// mergeable, its checks passed, no review required, and a repository that
/// the poller read has no `.trunk` folder.
private func readyPR(
  draft: Bool = false, headSha: String = samplePRHead, base: String = "main", defaultBranch: String? = "main",
  mergeable: Mergeable? = .mergeable, reviewDecision: ReviewDecision? = nil, verdicts: [Review] = [],
  checks: String? = "SUCCESS", mergedBase: Int? = nil, queue: TrunkQueueState? = nil, reviewRequests: [String]? = nil,
  trunkConfig: Bool? = false
) -> PullRequest {
  var pr = samplePR(
    draft: draft, headSha: headSha, base: base, defaultBranch: defaultBranch, mergeable: mergeable,
    reviewDecision: reviewDecision, verdicts: verdicts, checks: checks, mergedBase: mergedBase, queue: queue,
    reviewRequests: reviewRequests)
  pr.trunkConfig = trunkConfig
  return pr
}

func mergeEvent(_ t: Int64, head: String, _ result: String, error: String? = nil) -> Event {
  var fields: [String: JSON] = ["head": .string(head), "result": .string(result)]
  if let error { fields["error"] = .string(error) }
  return event("merge", t, fields)
}

/// An acknowledgment of the Ready to merge verdict with `reason`.
private func ackEvent(_ t: Int64, _ reason: String, head: String) throws -> Event {
  let data = try JSON(encoding: Acknowledgment(state: .readyToMerge, reason: reason, head: head))
  return event("ack", t, data.object ?? [:])
}

func dependenciesEvent(_ t: Int64, _ deps: [Dependency]) throws -> Event {
  event("dependencies", t, ["dependencies": try JSON(encoding: deps)])
}

private let trunkBotComment = PRComment(
  id: "IC_trunk", author: TrunkComments.author, createdAt: "2026-10-25T00:00:00Z", body: "<!-- Trunk Merge -->")

private let now: Int64 = 10

private func verdict(_ facts: SessionFacts, _ s: Session = session()) -> Verdict {
  Attention.shown(Attention.evaluate(s, facts, now: now), facts)
}

/// The suites nest under one name, so `--filter MergeAttentionTests` runs them all.
@Suite struct MergeAttentionTests {}

extension MergeAttentionTests {
  @Suite struct ReadyToMergeState {
    @Test func readyToMergeComesRightAfterNeedsYou() {
      let all = AttentionState.allCases

      #expect(all.firstIndex(of: .readyToMerge) == all.firstIndex(of: .needsYou)! + 1)
    }

    @Test func readyToMergeIsTitledReadyToMerge() {
      #expect(AttentionState.readyToMerge.title == "Ready to merge")
    }

    @Test func readyToMergeEncodesAsSnakeCase() {
      #expect(AttentionState.readyToMerge.rawValue == "ready_to_merge")
    }
  }
}

extension MergeAttentionTests {
  @Suite struct MergeFacts {
    @Test func mergeEventSetsTheMergeAttempt() {
      let f = facts([mergeEvent(1, head: "abc", "failed", error: "not mergeable")])

      #expect(f.merge == MergeAttempt(head: "abc", result: .failed, error: "not mergeable"))
    }

    @Test func laterMergeEventReplacesTheEarlierOne() {
      let f = facts([mergeEvent(1, head: "abc", "failed", error: "boom"), mergeEvent(2, head: "abc", "merged")])

      #expect(f.merge == MergeAttempt(head: "abc", result: .merged))
    }

    /// An event that sbd recorded before Acknowledge can hold `dismissed`, which MergeAttempt does not decode.
    @Test func dismissedMergeEventNoLongerDecodes() {
      let f = facts([mergeEvent(1, head: "abc", "dismissed")])

      #expect(f.merge == nil)
    }
  }
}

extension MergeAttentionTests {
  @Suite struct MergeAttention {
    @Test func readyPRIsReadyToMerge() throws {
      let f = try prFacts(readyPR())

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    @Test func prWhoseDefaultBranchDidNotLoadIsReadyToMerge() throws {
      let f = try prFacts(readyPR(defaultBranch: nil))

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test(arguments: [
      ([sampleVerdict("alice", "APPROVED")], "#42 is ready to merge, approved by alice"),
      (
        [sampleVerdict("bob", "APPROVED"), sampleVerdict("alice", "APPROVED")],
        "#42 is ready to merge, approved by alice and bob"
      ),
    ])
    func approvedReadyPRNamesItsApprovers(_ verdicts: [Review], _ reason: String) throws {
      let f = try prFacts(readyPR(reviewDecision: .approved, verdicts: verdicts))

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: reason))
    }

    @Test func readyPRWithoutAReviewDecisionButWithAnApprovalNamesTheApprover() throws {
      let f = try prFacts(readyPR(reviewDecision: nil, verdicts: [sampleVerdict("alice", "APPROVED")]))

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge, approved by alice"))
    }

    @Test(arguments: [
      ("draft", readyPR(draft: true)),
      ("conflicting", readyPR(mergeable: .conflicting)),
      ("mergeability unknown", readyPR(mergeable: .unknown)),
      ("mergeability not read", readyPR(mergeable: nil)),
      ("checks failed", readyPR(checks: "FAILURE")),
      ("checks errored", readyPR(checks: "ERROR")),
      ("checks pending", readyPR(checks: "PENDING")),
      ("checks expected", readyPR(checks: "EXPECTED")),
      ("no checks", readyPR(checks: nil)),
      ("review required", readyPR(reviewDecision: .reviewRequired)),
      ("changes requested", readyPR(reviewDecision: .changesRequested)),
      (
        "changes requested on the head without a decision",
        readyPR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)])
      ),
      (
        "changes requested on an older commit without a decision",
        readyPR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: "older")])
      ),
      ("merged base", readyPR(base: "haacked/parent", mergedBase: 41)),
      ("stacked on another branch", readyPR(base: "haacked/parent")),
      ("review requested", readyPR(reviewRequests: ["alice"])),
    ])
    func prThatCannotMergeIsNotReadyToMerge(_ label: String, _ pr: PullRequest) throws {
      let f = try prFacts(pr)

      #expect(verdict(f).state != .readyToMerge, "\(label)")
    }

    @Test(arguments: [
      TrunkQueueState.submitted, .pending, .testing, .passed, .failing, .queued, .merged, .removed, .unknown,
    ])
    func prWithATrunkQueueStateIsNotReadyToMerge(_ queue: TrunkQueueState) throws {
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], queue: queue))

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test func prWithATrunkCommentAmongOtherCommentsIsNotReadyToMerge() throws {
      let comments = [
        PRComment(id: "IC_gh", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:00Z"), trunkBotComment,
      ]
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")]), comments: comments)

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "enqueue #42, approved by alice"))
    }

    /// A busy PR in a Trunk repository: Trunk's comment is outside the
    /// comments the poller reads, so only the repository's `.trunk` folder
    /// shows the queue.
    @Test func prInARepositoryWithATrunkFolderIsNotReadyToMerge() throws {
      let comments = (0..<25).map {
        PRComment(id: "IC_\($0)", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:\(10 + $0)Z")
      }
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], trunkConfig: true),
        comments: comments)

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "enqueue #42, approved by alice"))
    }

    @Test func prWhoseTrunkFolderWasNotReadIsNotReadyToMerge() throws {
      let f = try prFacts(readyPR(trunkConfig: nil))

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test func prWithOnlyOtherBotCommentsIsReadyToMerge() throws {
      let comments = [PRComment(id: "IC_gh", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:00Z")]
      let f = try prFacts(readyPR(), comments: comments)

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test(arguments: [PRState.merged, .closed])
    func finishedPRIsNotReadyToMerge(_ state: PRState) throws {
      var pr = readyPR()
      pr.state = state
      let f = try prFacts(pr, dirty: 0)

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test(arguments: [
      Dependency(via: .body, repo: "acme/widgets", number: 7, state: .open),
      Dependency(via: .body, repo: "acme/widgets", number: 7, state: nil),
      Dependency(via: .stack, repo: "acme/widgets", number: 7, state: .open),
      Dependency(via: .body, repo: "acme/widgets", number: 7, deploy: true, state: .merged, deployed: false),
    ])
    func prThatADependencyHoldsIsNotReadyToMerge(_ dependency: Dependency) throws {
      let f = try prFacts(readyPR(), then: [try dependenciesEvent(3, [dependency])])

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test func prWhoseDependenciesResolvedIsReadyToMerge() throws {
      let resolved = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .merged)
      let f = try prFacts(readyPR(), then: [try dependenciesEvent(3, [resolved])])

      #expect(verdict(f).state == .readyToMerge)
    }

    // An idle session only

    @Test func readyPRWhileATurnRunsIsWorking() throws {
      let f = try prFacts(readyPR(), then: [event("UserPromptSubmit", 4, ["prompt": "keep going"])])

      #expect(verdict(f).state == .working)
    }

    @Test func readyPRWithAnOpenPermissionNeedsYou() throws {
      let f = try prFacts(
        readyPR(),
        then: [
          event("UserPromptSubmit", 4, ["prompt": "keep going"]),
          event("PermissionRequest", 5, tool("Bash", ["command": "rm -rf build"])),
        ])

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "approve `rm -rf build`"))
    }

    @Test func readyPRWithAnOpenQuestionNeedsYou() throws {
      let input: [String: JSON] = ["questions": [["question": "Which fruit?"]]]
      let f = try prFacts(
        readyPR(),
        then: [
          event("UserPromptSubmit", 4, ["prompt": "keep going"]),
          event("PreToolUse", 5, tool("AskUserQuestion", input, id: "q")),
        ])

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "answer: Which fruit?"))
    }

    @Test func readyPRWithAnOpenWaitIsReadyForReview() throws {
      let f = try prFacts(readyPR(reviewDecision: .reviewRequired))

      #expect(
        verdict(f, session(wait: "the deploy of #42"))
          == sampleReadyForReview("the deploy of #42", checks: "checks success"))
    }

    @Test func readyPRStaysReadyToMergeAfterTheStaleInterval() throws {
      let f = try prFacts(readyPR())

      #expect(Attention.evaluate(session(), f, now: Attention.staleAfterMs + 10).state == .readyToMerge)
    }

    // Conflict reason

    @Test(arguments: [("main", "rebase; #42 conflicts with main"), ("develop", "rebase; #42 conflicts with develop")])
    func conflictReasonNamesTheBaseBranch(_ base: String, _ reason: String) throws {
      let f = try prFacts(readyPR(base: base, mergeable: .conflicting))

      #expect(verdict(f) == Verdict(state: .needsYou, reason: reason))
    }

    // Merge attempts

    @Test func oldDismissedEventAtTheHeadLeavesThePRReadyToMerge() throws {
      let f = try prFacts(readyPR(), then: [mergeEvent(3, head: samplePRHead, "dismissed")])

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    // Acknowledgments

    @Test func acknowledgedApprovedPRIsWaitingWithItsReason() throws {
      let reason = "#42 is ready to merge, approved by alice"
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")]),
        then: [try ackEvent(3, reason, head: samplePRHead)])

      let v = verdict(f)

      #expect(v == Verdict(state: .waiting, reason: reason))
      #expect(v.acknowledged)
    }

    @Test func pushAfterAnAcknowledgmentMakesThePRReadyAgain() throws {
      let f = try prFacts(
        readyPR(),
        then: [
          try ackEvent(3, "#42 is ready to merge", head: samplePRHead),
          event("pr", 4, ["pr": try JSON(encoding: readyPR(headSha: "pushed"))]),
        ])

      let v = verdict(f)

      #expect(v.state == .readyToMerge)
      #expect(!v.acknowledged)
    }

    @Test func acknowledgmentStaysAcrossPollsOfTheSameHead() throws {
      var retitled = readyPR()
      retitled.title = "a new title"
      let f = try prFacts(
        readyPR(),
        then: [
          try ackEvent(3, "#42 is ready to merge", head: samplePRHead),
          event("pr", 4, ["pr": try JSON(encoding: retitled)]),
        ])

      #expect(verdict(f).acknowledged)
    }

    @Test func newTurnAfterAnAcknowledgmentMakesThePRReadyAgain() throws {
      let f = try prFacts(
        readyPR(),
        then: [
          try ackEvent(3, "#42 is ready to merge", head: samplePRHead),
          event("UserPromptSubmit", 4, ["prompt": "one more thing"]),
          event("Stop", 5, ["last_assistant_message": "Pushed."]),
        ])

      let v = verdict(f)

      #expect(v.state == .readyToMerge)
      #expect(!v.acknowledged)
    }

    @Test func failedAttemptAtTheHeadStaysReadyToMerge() throws {
      let f = try prFacts(
        readyPR(), then: [mergeEvent(3, head: samplePRHead, "failed", error: "Pull request is not mergeable")])

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    @Test func mergedAttemptAtTheHeadIsNotReadyToMerge() throws {
      let f = try prFacts(readyPR(), then: [mergeEvent(3, head: samplePRHead, "merged")])

      #expect(verdict(f) == Verdict(state: .waiting, reason: "#42 merged; GitHub has not reported it yet"))
    }

    @Test func mergedAttemptAtAnOlderHeadIsReadyToMerge() throws {
      let f = try prFacts(readyPR(), then: [mergeEvent(3, head: "older", "merged")])

      #expect(verdict(f).state == .readyToMerge)
    }
  }
}
