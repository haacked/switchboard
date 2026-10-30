import Foundation
import Testing

@testable import SwitchboardCore

private func prEvent(_ t: Int64, _ pr: PullRequest?, comments: [PRComment] = []) throws -> Event {
  event("pr", t, ["pr": try pr.map { try JSON(encoding: $0) } ?? .null, "comments": try JSON(encoding: comments)])
}

private func worktreeEvent(_ t: Int64, dirty: Int) -> Event {
  event("worktree", t, ["dirty": .number(Double(dirty))])
}

private func trunkComment(_ id: String = "IC_trunk") -> PRComment {
  PRComment(id: id, author: "trunk-io[bot]", createdAt: "2026-10-25T00:00:00Z", body: "<!-- Trunk Merge -->")
}

/// The facts of a session whose turn ended with `reply`, then got its PR.
/// `then` holds the events that arrive after the PR, such as a prompt that starts a turn.
private func prFacts(
  _ pr: PullRequest?, comments: [PRComment] = [], dirty: Int? = nil, reply: String = "Pushed.", then: [Event] = []
) throws -> SessionFacts {
  var events = [
    event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": .string(reply)]),
    try prEvent(2, pr, comments: comments),
  ]
  if let dirty { events.append(worktreeEvent(3, dirty: dirty)) }
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
