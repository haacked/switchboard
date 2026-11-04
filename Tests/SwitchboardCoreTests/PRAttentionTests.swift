import Foundation
import Testing

@testable import SwitchboardCore

private func prEvent(_ t: Int64, _ pr: PullRequest?, comments: [PRComment] = []) throws -> Event {
  event("pr", t, ["pr": try pr.map { try JSON(encoding: $0) } ?? .null, "comments": try JSON(encoding: comments)])
}

private func worktreeEvent(_ t: Int64, dirty: Int) -> Event {
  event("worktree", t, ["dirty": .number(Double(dirty))])
}

private func goneEvent(_ t: Int64) -> Event {
  event("worktree", t, ["dirty": .null, "gone": true])
}

private func trunkComment(_ id: String = "IC_trunk") -> PRComment {
  PRComment(id: id, author: "trunk-io[bot]", createdAt: "2026-10-25T00:00:00Z", body: "<!-- Trunk Merge -->")
}

/// The facts of a session whose turn ended with `reply`, then got its PR.
/// `then` holds the events that arrive after the PR, such as a prompt that starts a turn.
func prFacts(
  _ pr: PullRequest?, comments: [PRComment] = [], dirty: Int? = nil, gone: Bool = false, reply: String = "Pushed.",
  then: [Event] = []
) throws -> SessionFacts {
  var events = [
    event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": .string(reply)]),
    try prEvent(2, pr, comments: comments),
  ]
  if let dirty { events.append(worktreeEvent(3, dirty: dirty)) }
  if gone { events.append(goneEvent(3)) }
  return facts(events + then)
}

private let runningTurn = [event("UserPromptSubmit", 4, ["prompt": "keep going"])]
private let readTheReply = Verdict(state: .needsYou, reason: "read its last reply and decide what's next")

@Suite struct PRFacts {
  @Test func prEventSetsThePR() throws {
    let f = facts([try prEvent(1, samplePR(reviewDecision: .approved), comments: [trunkComment()])])

    #expect(f.pr == samplePR(reviewDecision: .approved))
  }

  @Test func prEventSetsTheComments() throws {
    let f = facts([try prEvent(1, samplePR(), comments: [trunkComment("IC_1"), trunkComment("IC_2")])])

    #expect(f.prComments == [trunkComment("IC_1"), trunkComment("IC_2")])
  }

  @Test func prEventWithoutAPRClearsThePR() throws {
    let f = facts([try prEvent(1, samplePR(), comments: [trunkComment()]), event("pr", 2, ["pr": .null])])

    #expect(f.pr == nil)
  }

  @Test func prEventWithoutCommentsKeepsTheComments() throws {
    let f = facts([
      try prEvent(1, samplePR(), comments: [trunkComment()]),
      event("pr", 2, ["pr": try JSON(encoding: samplePR(checks: "SUCCESS"))]),
    ])

    #expect(f.prComments == [trunkComment()])
  }

  @Test func prEventWithoutAPRClearsTheComments() throws {
    let f = facts([try prEvent(1, samplePR(), comments: [trunkComment()]), event("pr", 2, ["pr": .null])])

    #expect(f.prComments.isEmpty)
  }

  @Test func worktreeEventSetsTheDirtyCount() {
    let f = facts([worktreeEvent(1, dirty: 2)])

    #expect(f.dirty == 2)
  }
}

@Suite struct PRAttention {
  static let now: Int64 = 10
  static let finished: [(PRState, String)] = [(.merged, "merged"), (.closed, "closed")]

  @Test(arguments: PRAttention.finished)
  func finishedPRInACleanFolderIsDone(_ state: PRState, _ word: String) throws {
    let f = try prFacts(samplePR(state: state), dirty: 0)

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .done, reason: "#42 \(word); archive the worktree"))
  }

  @Test func mergedPRInACleanFolderIsDoneWhileATurnRuns() throws {
    let f = try prFacts(samplePR(state: .merged), dirty: 0, then: runningTurn)

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .done, reason: "#42 merged; archive the worktree once it stops"))
  }

  @Test func openPermissionWinsOverAMergedPR() throws {
    let f = try prFacts(
      samplePR(state: .merged), dirty: 0,
      then: runningTurn + [event("PermissionRequest", 5, tool("Bash", ["command": "rm -rf build"]))])

    #expect(
      Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: "approve `rm -rf build`"))
  }

  @Test func openQuestionWinsOverAMergedPR() throws {
    let input: [String: JSON] = ["questions": [["question": "Which fruit?"]]]
    let f = try prFacts(
      samplePR(state: .merged), dirty: 0,
      then: runningTurn + [event("PreToolUse", 5, tool("AskUserQuestion", input, id: "q"))])

    #expect(
      Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: "answer: Which fruit?"))
  }

  @Test(arguments: [0, 2])
  func openWaitWinsOverAMergedPR(_ dirty: Int) throws {
    let f = try prFacts(samplePR(state: .merged), dirty: dirty)

    #expect(
      Attention.evaluate(session(wait: "the deploy of #42"), f, now: Self.now)
        == Verdict(state: .waiting, reason: "the deploy of #42"))
  }

  @Test(arguments: [0, 2])
  func waitOutcomeWinsOverAMergedPR(_ dirty: Int) throws {
    let wait = waitOn(.deploy, pr: pr1204, environment: "prod", then: .notify)
    let f = try prFacts(samplePR(state: .merged), dirty: dirty, then: [resolved(wait, "it deployed", 4)])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "#1204 to reach prod: it deployed"))
  }

  @Test(arguments: PRAttention.finished)
  func finishedPRWithUncommittedChangesNeedsYou(_ state: PRState, _ word: String) throws {
    let f = try prFacts(samplePR(state: state), dirty: 2)

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "#42 \(word); commit or discard the uncommitted changes"))
  }

  @Test(arguments: PRAttention.finished)
  func finishedPRWithUncommittedChangesKeepsARunningTurnWorking(_ state: PRState, _ word: String) throws {
    let f = try prFacts(samplePR(state: state), dirty: 2, then: runningTurn)

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .working)
  }

  @Test(arguments: PRAttention.finished)
  func finishedPRWithAMissingFolderIsDone(_ state: PRState, _ word: String) throws {
    let f = try prFacts(samplePR(state: state), gone: true)

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .done, reason: "#42 \(word); its folder is gone"))
  }

  @Test func mergedPRWithAMissingFolderIsDoneWhileATurnRuns() throws {
    let f = try prFacts(samplePR(state: .merged), gone: true, then: runningTurn)

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .done)
  }

  @Test(arguments: [0, 2])
  func openWaitWinsOverAMergedPRWithAMissingFolder(_ dirty: Int) throws {
    let f = try prFacts(samplePR(state: .merged), dirty: dirty, gone: true)

    #expect(
      Attention.evaluate(session(wait: "the deploy of #42"), f, now: Self.now)
        == Verdict(state: .waiting, reason: "the deploy of #42"))
  }

  @Test func waitOutcomeWinsOverAMergedPRWithAMissingFolder() throws {
    let wait = waitOn(.deploy, pr: pr1204, environment: "prod", then: .notify)
    let f = try prFacts(samplePR(state: .merged), gone: true, then: [resolved(wait, "it deployed", 4)])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "#1204 to reach prod: it deployed"))
  }

  @Test func openPRWithAMissingFolderIsNotDone() throws {
    let f = try prFacts(samplePR(state: .open), gone: true)

    #expect(Attention.evaluate(session(), f, now: Self.now).state != .done)
  }

  @Test func laterCountOfTheFolderClearsTheMissingFlag() throws {
    let f = try prFacts(samplePR(state: .merged), gone: true, then: [worktreeEvent(5, dirty: 2)])

    #expect(f.folderGone == false)
    #expect(Attention.evaluate(session(), f, now: Self.now).state == .needsYou)
  }

  @Test(arguments: PRAttention.finished)
  func finishedPRWithUncountedChangesFiresNoRule(_ state: PRState, _ word: String) throws {
    let f = try prFacts(samplePR(state: state, mergeable: .conflicting), dirty: nil)

    #expect(Attention.evaluate(session(), f, now: Self.now) == readTheReply)
  }

  @Test(arguments: PRAttention.finished)
  func finishedPRWithUncountedChangesLeavesARunningTurnWorking(_ state: PRState, _ word: String) throws {
    let f = try prFacts(samplePR(state: state), dirty: nil, then: runningTurn)

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .working)
  }

  @Test(arguments: [
    (samplePR(base: "haacked/parent", mergedBase: 41), "retarget #42; its base #41 merged"),
    (samplePR(mergeable: .conflicting), "rebase; #42 conflicts with its base"),
    (
      samplePR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)]),
      "address the changes that alice requested on #42"
    ),
    (
      samplePR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: nil)]),
      "address the changes that alice requested on #42"
    ),
    (
      samplePR(verdicts: [
        sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead),
        sampleVerdict("bob", "CHANGES_REQUESTED", on: samplePRHead),
      ]
      ),
      "address the changes that alice and bob requested on #42"
    ),
    (samplePR(reviewDecision: .changesRequested), "address the requested changes on #42"),
    (
      samplePR(reviewDecision: .changesRequested, verdicts: [sampleVerdict("bob", "APPROVED", on: samplePRHead)]),
      "address the requested changes on #42"
    ),
    (
      samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")]),
      "merge #42, approved by alice"
    ),
    (samplePR(reviewDecision: nil, verdicts: [sampleVerdict("alice", "APPROVED")]), "merge #42, approved by alice"),
    (
      samplePR(
        reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED"), sampleVerdict("bob", "APPROVED")]),
      "merge #42, approved by alice and bob"
    ),
    (
      samplePR(
        reviewDecision: .approved,
        verdicts: [
          sampleVerdict("alice", "APPROVED"), sampleVerdict("bob", "APPROVED"), sampleVerdict("carol", "APPROVED"),
        ]),
      "merge #42, approved by alice and bob and carol"
    ),
    (samplePR(reviewDecision: .approved), "merge #42"),
  ])
  func openPRNeedsYou(_ pr: PullRequest, _ reason: String) throws {
    let f = try prFacts(pr)

    #expect(Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: reason))
  }

  @Test(arguments: [
    ([sampleVerdict("stamphog", "APPROVED")], "enqueue #42, approved by stamphog"),
    ([sampleVerdict("alice", "APPROVED"), sampleVerdict("bob", "APPROVED")], "enqueue #42, approved by alice and bob"),
    ([], "enqueue #42"),
  ])
  func approvedPRThatTrunkManagesIsEnqueued(_ verdicts: [Review], _ reason: String) throws {
    let comments = [
      PRComment(id: "IC_gh", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:00Z"), trunkComment(),
    ]
    let f = try prFacts(samplePR(reviewDecision: .approved, verdicts: verdicts), comments: comments)

    #expect(Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: reason))
  }

  @Test func approvedPRWhoseQueueStatusDidNotLoadNeedsAQueueCheck() throws {
    let p = samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], queue: .unknown)
    let f = try prFacts(p, comments: [trunkComment()])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "check whether Trunk queued #42; its queue status did not load"))
  }

  @Test(arguments: [samplePR(queue: .removed), samplePR(reviewDecision: .approved, queue: .removed)])
  func prThatTrunkRemovedNeedsYou(_ pr: PullRequest) throws {
    let f = try prFacts(pr, comments: [trunkComment()])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "find out why Trunk removed #42 from its queue"))
  }

  @Test func approvedPRWithOnlyOtherCommentsIsMerged() throws {
    let comments = [
      PRComment(id: "IC_gh", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:00Z"),
      PRComment(
        id: "IC_dp", author: "deployment-status-posthog[bot]", createdAt: "2026-10-24T00:00:00Z", body: "deployed"),
    ]
    let f = try prFacts(
      samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")]), comments: comments)

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "merge #42, approved by alice"))
  }

  @Test(arguments: [
    samplePR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: "older")]),
    samplePR(reviewDecision: .changesRequested, verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: "older")]),
    samplePR(
      reviewDecision: .changesRequested,
      verdicts: [
        sampleVerdict("alice", "CHANGES_REQUESTED", on: "older"),
        sampleVerdict("bob", "CHANGES_REQUESTED", on: "oldest"),
      ]),
    samplePR(draft: true, reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")]),
    samplePR(reviewDecision: .reviewRequired),
    samplePR(
      reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], queue: .testing),
    samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], queue: .merged),
    samplePR(),
  ])
  func openPRWithNothingToDoFiresNoRule(_ pr: PullRequest) throws {
    let f = try prFacts(pr, comments: [trunkComment()])

    #expect(Attention.evaluate(session(), f, now: Self.now) == readTheReply)
  }

  @Test func currentChangeRequestNamesOnlyItsReviewer() throws {
    let p = samplePR(verdicts: [
      sampleVerdict("alice", "CHANGES_REQUESTED", on: "older"),
      sampleVerdict("bob", "CHANGES_REQUESTED", on: samplePRHead),
    ])

    let v = Attention.evaluate(session(), try prFacts(p), now: Self.now)

    #expect(v == Verdict(state: .needsYou, reason: "address the changes that bob requested on #42"))
  }

  static let everyRule = samplePR(
    base: "haacked/parent", mergeable: .conflicting, reviewDecision: .approved,
    verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead), sampleVerdict("bob", "APPROVED")],
    mergedBase: 41)

  @Test(arguments: [
    (PRAttention.everyRule, "retarget #42; its base #41 merged"),
    (
      samplePR(mergeable: .conflicting, reviewDecision: .approved, verdicts: PRAttention.everyRule.verdicts),
      "rebase; #42 conflicts with its base"
    ),
    (
      samplePR(reviewDecision: .approved, verdicts: PRAttention.everyRule.verdicts),
      "address the changes that alice requested on #42"
    ),
  ])
  func earlierRuleWins(_ pr: PullRequest, _ reason: String) throws {
    let f = try prFacts(pr)

    #expect(Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: reason))
  }

  @Test func openPRRuleWinsOverStale() throws {
    let f = try prFacts(samplePR(mergeable: .conflicting))

    #expect(
      Attention.evaluate(session(), f, now: Attention.staleAfterMs + 10)
        == Verdict(state: .needsYou, reason: "rebase; #42 conflicts with its base"))
  }

  @Test func openPRRuleWinsOverARunningJob() throws {
    let f = try prFacts(samplePR(mergeable: .conflicting), then: [event("job", 3, ["count": 1])])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "rebase; #42 conflicts with its base"))
  }

  @Test func openPRRuleWinsOverAnOffer() throws {
    let f = try prFacts(samplePR(mergeable: .conflicting), reply: "Want me to push?")

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "rebase; #42 conflicts with its base"))
  }

  @Test func openWaitWinsOverAConflictingPR() throws {
    let f = try prFacts(samplePR(mergeable: .conflicting))

    #expect(
      Attention.evaluate(session(wait: "CI on #42"), f, now: Self.now) == Verdict(state: .waiting, reason: "CI on #42"))
  }

  @Test func runningTurnWinsOverAConflictingPR() throws {
    let f = try prFacts(samplePR(mergeable: .conflicting), then: runningTurn)

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .working)
  }

  @Test func sessionWithoutAPromptStillNeedsOne() throws {
    let f = facts([event("SessionStart", 0), try prEvent(1, samplePR(mergeable: .conflicting))])

    #expect(
      Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: "give it a first prompt"))
  }

  // The recorded PRs, with the comments that the poller would read bodies for.

  @Test(arguments: [
    (18303, "merge #18303, approved by stamphog"),
    (20992, "merge #20992, approved by gewenyu99"),
    (1209, readTheReply.reason),
    (122953, readTheReply.reason),
  ])
  func recordedOpenPR(_ number: Int, _ reason: String) throws {
    let node = try #require(GitHubFixtures.statusNode(number))
    let parsed = try #require(GitHub.parsePR(node))
    let f = try prFacts(parsed.pr, comments: parsed.comments.filter { GitHub.bodyAuthors.contains($0.author) })

    #expect(Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: reason))
  }

  @Test(arguments: [(122179, "#122179 merged; archive the worktree"), (121847, "#121847 closed; archive the worktree")])
  func recordedFinishedPR(_ number: Int, _ reason: String) throws {
    let node = try #require(GitHubFixtures.statusNode(number))
    let parsed = try #require(GitHub.parsePR(node))
    let f = try prFacts(parsed.pr, dirty: 0)

    #expect(Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .done, reason: reason))
  }
}

@Suite struct AwaitingReview {
  static let now: Int64 = 10
  static let alex = ["alex"]
  static let stale = Attention.staleAfterMs + 10
  static let commented = [Review(author: "alex", state: "COMMENTED")]
  static let waits = Verdict(state: .waiting, reason: "review of #42 by alex")

  private func verdict(_ pr: PullRequest, reply: String = "Opened the PR.") throws -> Verdict {
    Attention.evaluate(session(), try prFacts(pr, reply: reply), now: Self.now)
  }

  @Test func readyPRWithARequestedReviewerWaits() throws {
    #expect(try verdict(samplePR(reviewDecision: .reviewRequired, reviewRequests: Self.alex)) == Self.waits)
  }

  @Test func prWithNoRequiredReviewWaitsOnItsRequest() throws {
    #expect(try verdict(samplePR(reviewDecision: nil, reviewRequests: Self.alex)) == Self.waits)
  }

  @Test func botAndTeamReviewersAreNamedLikePeople() throws {
    let v = try verdict(samplePR(reviewRequests: ["copilot-pull-request-reviewer", "acme/flags"]))

    #expect(v == Verdict(state: .waiting, reason: "review of #42 by copilot-pull-request-reviewer and acme/flags"))
  }

  @Test func pendingChecksStillWait() throws {
    #expect(try verdict(samplePR(checks: "PENDING", reviewRequests: Self.alex)) == Self.waits)
    #expect(try verdict(samplePR(checks: "SUCCESS", reviewRequests: Self.alex)) == Self.waits)
  }

  @Test func pushAfterRequestedChangesWaitsForTheReReview() throws {
    let stale = sampleVerdict("alex", "CHANGES_REQUESTED", on: "oldsha")
    let v = try verdict(
      samplePR(reviewDecision: .changesRequested, verdicts: [stale], reviewRequests: Self.alex))

    #expect(v == Self.waits)
  }

  @Test func draftPRNeedsYou() throws {
    #expect(try verdict(samplePR(draft: true, reviewRequests: Self.alex)) == readTheReply)
  }

  @Test func prWithNoRequestedReviewerNeedsYou() throws {
    #expect(try verdict(samplePR(reviewRequests: [])) == readTheReply)
  }

  @Test func prWithUnknownRequestsNeedsYou() throws {
    #expect(try verdict(samplePR(reviewRequests: nil)) == readTheReply)
  }

  @Test(arguments: ["FAILURE", "ERROR"])
  func failingChecksNeedYou(_ checks: String) throws {
    #expect(try verdict(samplePR(checks: checks, reviewRequests: Self.alex)) == readTheReply)
  }

  @Test func conflictNeedsYou() throws {
    let v = try verdict(samplePR(mergeable: .conflicting, reviewRequests: Self.alex))

    #expect(v == Verdict(state: .needsYou, reason: "rebase; #42 conflicts with its base"))
  }

  @Test func changesRequestedOnTheCurrentCommitNeedYou() throws {
    let current = sampleVerdict("alex", "CHANGES_REQUESTED", on: samplePRHead)
    let v = try verdict(samplePR(reviewDecision: .changesRequested, verdicts: [current], reviewRequests: Self.alex))

    #expect(v == Verdict(state: .needsYou, reason: "address the changes that alex requested on #42"))
  }

  @Test func approvedPRNeedsYou() throws {
    let v = try verdict(
      samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alex", "APPROVED")], reviewRequests: Self.alex))

    #expect(v == Verdict(state: .needsYou, reason: "merge #42, approved by alex"))
  }

  @Test func mergedBaseNeedsYou() throws {
    let v = try verdict(samplePR(mergedBase: 40, reviewRequests: Self.alex))

    #expect(v == Verdict(state: .needsYou, reason: "retarget #42; its base #40 merged"))
  }

  @Test func queuedPRDoesNotWaitOnAReview() throws {
    #expect(try verdict(samplePR(queue: .pending, reviewRequests: Self.alex)) == readTheReply)
  }

  @Test func removedFromTheQueueNeedsYou() throws {
    let v = try verdict(samplePR(queue: .removed, reviewRequests: Self.alex))

    #expect(v == Verdict(state: .needsYou, reason: "find out why Trunk removed #42 from its queue"))
  }

  @Test func mergedPRDoesNotWait() throws {
    let f = try prFacts(samplePR(state: .merged, reviewRequests: Self.alex), dirty: 0)

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .done)
  }

  @Test func questionForTheUserStaysInNeedsYou() throws {
    let v = try verdict(samplePR(reviewRequests: Self.alex), reply: "Which approach do you prefer?")

    #expect(v == Verdict(state: .needsYou, reason: "answer: Which approach do you prefer?"))
  }

  @Test func offerStaysInCanContinue() throws {
    let v = try verdict(samplePR(reviewRequests: Self.alex), reply: "Want me to push?")

    #expect(v.state == .canContinue)
  }

  @Test func newTurnWins() throws {
    let f = try prFacts(samplePR(reviewRequests: Self.alex), then: runningTurn)

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .working)
  }

  @Test func manualWaitIsNotReplacedByTheReviewWait() throws {
    let f = try prFacts(samplePR(reviewRequests: Self.alex))

    #expect(
      Attention.evaluate(session(wait: "run the app and look"), f, now: Self.now)
        == Verdict(state: .waiting, reason: "run the app and look"))
  }

  @Test func reviewSubmittedMovesTheSessionBackToNeedsYou() throws {
    let requested = try prFacts(samplePR(reviewRequests: Self.alex))
    let commented = try prFacts(samplePR(reviews: [Review(author: "alex", state: "COMMENTED")], reviewRequests: []))

    #expect(Attention.evaluate(session(), requested, now: Self.now) == Self.waits)
    #expect(Attention.evaluate(session(), commented, now: Self.now) == readTheReply)
  }

  @Test func waitsEvenWhenStale() throws {
    let f = try prFacts(samplePR(reviewRequests: Self.alex))

    #expect(Attention.evaluate(session(), f, now: Self.stale) == Self.waits)
  }

  @Test func answeredReviewNeedsYouEvenAfterTheSessionWentIdle() throws {
    let f = try prFacts(samplePR(reviews: Self.commented, reviewRequests: []))

    #expect(Attention.evaluate(session(), f, now: Self.stale) == readTheReply)
  }

  @Test func unreviewedPRWithNoRequestedReviewerNeedsYouEvenAfterTheSessionWentIdle() throws {
    let f = try prFacts(samplePR(reviews: [], reviewRequests: []))

    #expect(Attention.evaluate(session(), f, now: Self.stale) == readTheReply)
  }

  @Test(arguments: ["FAILURE", "ERROR"])
  func failingChecksNeedYouEvenAfterTheSessionWentIdle(_ checks: String) throws {
    let f = try prFacts(samplePR(checks: checks, reviewRequests: Self.alex))

    #expect(Attention.evaluate(session(), f, now: Self.stale) == readTheReply)
  }

  @Test func idleSessionStaysStaleWhenNoPRActionIsOutstanding() throws {
    let cases: [PullRequest] = [
      samplePR(draft: true, reviews: Self.commented, reviewRequests: []),
      samplePR(draft: true, checks: "FAILURE"),
      samplePR(reviews: [], queue: .pending, reviewRequests: []),
      samplePR(reviews: Self.commented, reviewRequests: nil),
    ]
    for pr in cases {
      let f = try prFacts(pr)
      #expect(Attention.evaluate(session(), f, now: Self.stale).state == .stale)
    }
  }
}
