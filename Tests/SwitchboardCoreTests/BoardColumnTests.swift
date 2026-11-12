import Foundation
import Testing

@testable import SwitchboardCore

/// samplePR with `edit` applied, for the fields that samplePR takes no argument for.
private func pr(_ base: PullRequest = samplePR(), _ edit: (inout PullRequest) -> Void) -> PullRequest {
  var pr = base
  edit(&pr)
  return pr
}

/// A PR that alice approved, whose review lets it merge, and whose checks passed.
private func approvedPR(
  headSha: String = samplePRHead, base: String = "main", mergeable: Mergeable? = .mergeable,
  checks: String? = "SUCCESS", queue: TrunkQueueState? = nil
) -> PullRequest {
  samplePR(
    headSha: headSha, base: base, mergeable: mergeable, reviewDecision: .approved,
    verdicts: [sampleVerdict("alice", "APPROVED")], checks: checks, queue: queue, reviewDecisionRead: true)
}

/// A PR whose base branch requires a review that nobody gave yet, and that asks alice for it.
private func awaitingReviewPR(
  headSha: String = samplePRHead, mergeable: Mergeable? = .mergeable, checks: String? = "SUCCESS"
) -> PullRequest {
  samplePR(
    headSha: headSha, mergeable: mergeable, reviewDecision: .reviewRequired, checks: checks, reviewRequests: ["alice"],
    reviewDecisionRead: true)
}

/// A PR on which `logins` requested changes.
private func changesRequestedPR(_ logins: [String] = ["alex"]) -> PullRequest {
  samplePR(
    reviewDecision: .changesRequested, verdicts: logins.map { sampleVerdict($0, "CHANGES_REQUESTED") },
    checks: "SUCCESS", reviewDecisionRead: true)
}

/// A PR in Trunk's queue in `queue`, as `trunk merge status` reads it when `label` and `text` are set.
private func trunkPR(_ queue: TrunkQueueState, label: String? = nil, text: String? = nil) -> PullRequest {
  pr(approvedPR(queue: queue)) {
    $0.queueLabel = label
    $0.queueText = text
  }
}

private func depotRun(on head: String = samplePRHead) -> DepotRun {
  DepotRun(id: "run1", headSha: head, status: "failed", jobs: 3, failed: [DepotRun.Job(name: "tests")])
}

private func dependency(_ number: Int = 7, state: PRState? = .open, session: String? = nil) -> Dependency {
  Dependency(via: .body, repo: "acme/widgets", number: number, state: state, session: session)
}

/// An open wait of `kind`, set at `created`.
private func wait(_ kind: Wait.Kind, created: Int64 = 20, id: String = "w1", note: String? = nil) -> Wait {
  Wait(
    id: id, kind: kind,
    session: kind == .session ? Wait.SessionTarget(id: "s2", name: "flag-cache") : nil,
    state: kind == .session ? .done : nil,
    who: [.review, .botReview, .approval].contains(kind) ? "alex" : nil,
    until: [.date, .manual].contains(kind) ? 9_000 : nil,
    note: note ?? (kind == .manual ? "ask Alex" : nil), created: created)
}

/// A `pr` event for each time and PR, in order.
private func prEvents(_ prs: [(Int64, PullRequest?)]) throws -> [Event] {
  try prs.map { try prEvent($0.0, $0.1) }
}

/// The placement of a session in `state` since `stateSince`, after `events`.
private func place(
  _ state: AttentionState, acknowledged: Bool = false, events: [Event] = [], stateSince: Int64 = 50,
  waits: [Wait] = [], created: Int64 = 0
) -> BoardPlacement {
  BoardColumn.place(
    state: state, acknowledged: acknowledged, stateSince: stateSince, waits: waits, facts: facts(events),
    created: created)
}

/// The placement that sbd shows for a session with `waits` after `events`,
/// from the verdict that `Attention.shown` gives.
private func shownPlace(_ events: [Event], waits: [Wait] = []) -> BoardPlacement {
  var s = session()
  if !waits.isEmpty { s.waits = waits }
  let f = facts(events)
  let v = Attention.shown(Attention.evaluate(s, f, now: 100), f)
  return BoardColumn.place(
    state: v.state, acknowledged: v.acknowledged, stateSince: 50, waits: waits, facts: f, created: 0)
}

/// The `ack` event at `t` for the Inbox item in `state` that a session shows after `events`.
private func ackOfShown(_ state: AttentionState, after events: [Event], at t: Int64) throws -> Event {
  let f = facts(events)
  let v = Attention.evaluate(session(), f, now: 100)
  try #require(v.state == state, "\(v)")
  let data = try JSON(encoding: Acknowledgment(v, f))
  return event("ack", t, data.object ?? [:])
}

/// The events of a turn that ended with `reply`.
private func turn(_ reply: String) -> [Event] {
  [event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": .string(reply)])]
}

/// The placement of a session in `state` that got `pr` at t=10, then `dependencies` at t=11.
private func place(
  _ state: AttentionState, pr: PullRequest?, dependencies: [Dependency] = [], waits: [Wait] = [],
  stateSince: Int64 = 50
) throws -> BoardPlacement {
  var events = [try prEvent(10, pr)]
  if !dependencies.isEmpty { events.append(try dependenciesEvent(11, dependencies)) }
  return place(state, events: events, stateSince: stateSince, waits: waits)
}

/// The note that the `pr` events leave, each a time and a PR.
private func back(after prs: [(Int64, PullRequest?)]) throws -> BoardMove? {
  facts(try prEvents(prs)).boardBack
}

/// A reviewer as a bare login or slug, without `@` or the org.
private func bare(_ reviewer: String) -> String {
  String(reviewer.drop { $0 == "@" }.split(separator: "/").last ?? "")
}

/// The states that leave a PR's column to the PR, because no rule before the PR rules matches them.
private let idleStates: [AttentionState] = [.waiting, .needsYou, .readyToMerge, .readyForReview]

/// The suites nest under one name, so `--filter BoardColumnTests` runs them all.
@Suite struct BoardColumnTests {}

// MARK: Columns

extension BoardColumnTests {
  @Suite struct Columns {
    @Test func columnsRunLeftToRight() {
      #expect(BoardColumn.allCases == [.inProgress, .waiting, .inReview, .approved, .merging, .done])
    }

    @Test(arguments: [
      (BoardColumn.inProgress, "In progress"), (.waiting, "Waiting"), (.inReview, "In review"),
      (.approved, "Approved"), (.merging, "Merging"), (.done, "Done"),
    ])
    func eachColumnHasItsTitle(_ column: BoardColumn, _ title: String) {
      #expect(column.title == title)
    }

    @Test(arguments: [
      (BoardColumn.inProgress, "in_progress"), (.waiting, "waiting"), (.inReview, "in_review"),
      (.approved, "approved"), (.merging, "merging"), (.done, "done"),
    ])
    func eachColumnEncodesAsItsWireName(_ column: BoardColumn, _ raw: String) throws {
      #expect(try JSONCoding.encode(column) == "\"\(raw)\"")
    }

    @Test(arguments: [(BoardHolder.you, "you"), (.machine, "machine"), (.session, "session")])
    func eachHolderEncodesAsItsWireName(_ holder: BoardHolder, _ raw: String) throws {
      #expect(try JSONCoding.encode(holder) == "\"\(raw)\"")
    }
  }
}

// MARK: Rule 1: Done

extension BoardColumnTests {
  @Suite struct DoneRule {
    @Test(arguments: AttentionState.allCases)
    func mergedPRIsDoneInEveryState(_ state: AttentionState) throws {
      #expect(try place(state, pr: samplePR(state: .merged)).column == .done)
    }

    @Test(
      arguments: [
        ("no PR", nil), ("awaiting review", awaitingReviewPR()), ("approved", approvedPR()),
        ("in Trunk's queue", approvedPR(queue: .testing)), ("a draft", samplePR(draft: true)),
        ("closed", samplePR(state: .closed)),
      ] as [(String, PullRequest?)])
    func doneStateIsDoneWhateverThePR(_ label: String, _ pr: PullRequest?) throws {
      #expect(try place(.done, pr: pr).column == .done)
    }

    @Test(arguments: [
      ("merged while Trunk still shows it queued", samplePR(state: .merged, queue: .testing)),
      ("merged while GitHub's queue still shows it", pr(samplePR(state: .merged)) { $0.inMergeQueue = true }),
      ("merged with failed checks", samplePR(state: .merged, checks: "FAILURE")),
      ("merged with a conflict", samplePR(state: .merged, mergeable: .conflicting)),
    ])
    func mergedPRIsDoneWhateverElseItShows(_ label: String, _ pr: PullRequest) throws {
      #expect(try place(.waiting, pr: pr).column == .done)
    }
  }
}

// MARK: Rule 2: Merging

extension BoardColumnTests {
  @Suite struct MergingRule {
    /// A submitted PR waits for Trunk to add it, and Trunk holds it.
    @Test(arguments: [TrunkQueueState.submitted, .pending, .testing, .passed, .failing, .queued])
    func prThatTrunkHoldsIsMerging(_ queue: TrunkQueueState) throws {
      #expect(try place(.waiting, pr: approvedPR(queue: queue)).column == .merging)
    }

    /// A PR in the queue moves without Claude.
    @Test(
      arguments: [AttentionState.working, .notStarted],
      [
        ("in Trunk's queue", approvedPR(queue: .testing)),
        ("in GitHub's queue", pr(approvedPR()) { $0.inMergeQueue = true }),
      ])
    func mergingWinsOverWorking(_ state: AttentionState, _ c: (String, PullRequest)) throws {
      #expect(try place(state, pr: c.1).column == .merging)
    }

    @Test func prInGitHubsMergeQueueIsMerging() throws {
      #expect(try place(.waiting, pr: pr(approvedPR()) { $0.inMergeQueue = true }).column == .merging)
    }

    @Test(arguments: [TrunkQueueState.merged, .removed, .unknown])
    func prThatTrunkDoesNotHoldIsNotMerging(_ queue: TrunkQueueState) throws {
      #expect(try place(.waiting, pr: approvedPR(queue: queue)).column == .approved)
    }

    @Test func prOutOfGitHubsMergeQueueIsNotMerging() throws {
      #expect(try place(.waiting, pr: pr(approvedPR()) { $0.inMergeQueue = false }).column == .approved)
    }

    @Test(arguments: [
      ("Trunk shows it queued", samplePR(state: .closed, queue: .testing)),
      ("GitHub's queue shows it", pr(samplePR(state: .closed)) { $0.inMergeQueue = true }),
    ])
    func closedPRIsNotMerging(_ label: String, _ pr: PullRequest) throws {
      #expect(try place(.waiting, pr: pr).column == .waiting)
    }

    @Test(arguments: [
      ("Trunk queue with running checks", approvedPR(checks: "PENDING", queue: .testing)),
      ("Trunk queue with failed checks", approvedPR(checks: "FAILURE", queue: .failing)),
      ("Trunk queue awaiting review", pr(awaitingReviewPR()) { $0.queue = .pending }),
      ("Trunk queue with a conflict", approvedPR(mergeable: .conflicting, queue: .testing)),
      ("merge queue with failed checks", pr(approvedPR(checks: "FAILURE")) { $0.inMergeQueue = true }),
      ("merge queue with a conflict", pr(approvedPR(mergeable: .conflicting)) { $0.inMergeQueue = true }),
    ])
    func queueWinsOverChecksReviewAndConflicts(_ label: String, _ pr: PullRequest) throws {
      #expect(try place(.waiting, pr: pr).column == .merging)
    }

    /// Trunk drops a draft from its queue, and GitHub's queue holds no draft.
    @Test(arguments: [
      ("Trunk shows it queued", samplePR(draft: true, queue: .testing)),
      ("GitHub's queue shows it", pr(samplePR(draft: true)) { $0.inMergeQueue = true }),
    ])
    func draftIsNotMerging(_ label: String, _ pr: PullRequest) throws {
      #expect(try place(.waiting, pr: pr).column == .waiting)
    }

    @Test func mergingLineShowsTheQueueStateAndItsText() throws {
      let line = try place(.waiting, pr: trunkPR(.testing, label: "Testing", text: "Running the batch")).line

      #expect(line == "Trunk testing: Running the batch")
    }
  }
}

// MARK: Rule 3: In progress

/// PRs of every kind that rule 3 overrides when Claude works.
private let prsUnderAWorkingSession: [(String, PullRequest?)] = [
  ("no PR", nil), ("a draft", samplePR(draft: true)), ("closed", samplePR(state: .closed)),
  ("awaiting review", awaitingReviewPR()), ("approved", approvedPR()),
  ("approved with failed checks", approvedPR(checks: "FAILURE")),
  ("approved with a conflict", approvedPR(mergeable: .conflicting)),
  ("changes requested", changesRequestedPR()),
]

extension BoardColumnTests {
  @Suite struct InProgressRule {
    @Test(arguments: [AttentionState.working, .notStarted], prsUnderAWorkingSession)
    func workingOrNotStartedIsInProgress(_ state: AttentionState, _ c: (String, PullRequest?)) throws {
      #expect(try place(state, pr: c.1).column == .inProgress)
    }

    @Test(arguments: [AttentionState.working, .notStarted])
    func sessionWithoutEventsIsInProgressWhileWorkingOrNotStarted(_ state: AttentionState) {
      #expect(place(state).column == .inProgress)
    }
  }
}

// MARK: Rule 4: Approved

extension BoardColumnTests {
  @Suite struct ApprovedRule {
    @Test(
      arguments: idleStates,
      [
        ("approved", approvedPR()),
        ("approved with no checks", approvedPR(checks: nil)),
        ("approved while another request is open", pr(approvedPR()) { $0.reviewRequests = ["bob"] }),
        (
          "no review required and no request open",
          samplePR(checks: "SUCCESS", reviewRequests: [], reviewDecisionRead: true)
        ),
        (
          "a failed Depot run on an earlier head", pr(approvedPR(headSha: "head2")) { $0.depot = depotRun(on: "head1") }
        ),
      ] as [(String, PullRequest)])
    func openReadyPRThatReviewLetsMergeWithGreenChecksIsApproved(_ state: AttentionState, _ c: (String, PullRequest))
      throws
    {
      #expect(try place(state, pr: c.1).column == .approved)
    }

    /// GitHub recomputes mergeability after every push to the base.
    @Test(arguments: [Mergeable.unknown, nil])
    func unknownMergeabilityDoesNotBlockApproved(_ mergeable: Mergeable?) throws {
      #expect(try place(.waiting, pr: approvedPR(mergeable: mergeable)).column == .approved)
    }

    @Test(arguments: [
      ("checks pending", approvedPR(checks: "PENDING")),
      ("checks expected", approvedPR(checks: "EXPECTED")),
      ("checks failed", approvedPR(checks: "FAILURE")),
      ("checks errored", approvedPR(checks: "ERROR")),
      ("a Depot job failed on the head", pr(approvedPR(checks: nil)) { $0.depot = depotRun() }),
      ("conflicts with its base", approvedPR(mergeable: .conflicting)),
      ("a draft", pr(approvedPR()) { $0.draft = true }),
      (
        "approved, but someone's last verdict requests changes",
        pr(approvedPR()) { $0.verdicts = [sampleVerdict("bob", "CHANGES_REQUESTED")] }
      ),
    ])
    func approvedPRThatCannotMergeIsWaiting(_ label: String, _ pr: PullRequest) throws {
      #expect(try place(.waiting, pr: pr).column == .waiting)
    }

    @Test(arguments: ["PENDING", "EXPECTED"])
    func approvedPRWhoseChecksRunIsHeldByAMachine(_ checks: String) throws {
      let p = try place(.waiting, pr: approvedPR(checks: checks))

      #expect(p.column == .waiting && p.holder == .machine && p.line == "CI running")
    }

    @Test(arguments: [
      ("checks failed", approvedPR(checks: "FAILURE")),
      ("checks errored", approvedPR(checks: "ERROR")),
      ("conflicts with its base", approvedPR(mergeable: .conflicting)),
    ])
    func approvedPRWhoseChecksFailedOrThatConflictsIsHeldByYou(_ label: String, _ pr: PullRequest) throws {
      let p = try place(.waiting, pr: pr)

      #expect(p.column == .waiting && p.holder == .you)
    }

    @Test(arguments: [
      ("checks failed", approvedPR(checks: "FAILURE")),
      ("conflicts with its base", approvedPR(mergeable: .conflicting)),
    ])
    func approvedPRWhoseChecksFailedIsInProgressWhileClaudeWorks(_ label: String, _ pr: PullRequest) throws {
      #expect(try place(.working, pr: pr).column == .inProgress)
    }

    @Test func approvedLineNamesTheApprover() throws {
      #expect(try place(.waiting, pr: approvedPR()).line?.contains("alice") == true)
    }
  }
}

// MARK: Rule 5: In review

extension BoardColumnTests {
  @Suite struct InReviewRule {
    @Test(
      arguments: idleStates,
      [
        ("checks passed", awaitingReviewPR()),
        ("no checks", awaitingReviewPR(checks: nil)),
        ("checks pending", awaitingReviewPR(checks: "PENDING")),
        ("checks expected", awaitingReviewPR(checks: "EXPECTED")),
        ("mergeability unknown", awaitingReviewPR(mergeable: .unknown)),
      ] as [(String, PullRequest)])
    func openReadyPRThatAwaitsAReviewIsInReview(_ state: AttentionState, _ c: (String, PullRequest)) throws {
      #expect(try place(state, pr: c.1).column == .inReview)
    }

    @Test(arguments: [
      ("changes requested", changesRequestedPR()),
      ("checks failed", awaitingReviewPR(checks: "FAILURE")),
      ("checks errored", awaitingReviewPR(checks: "ERROR")),
      ("conflicts with its base", awaitingReviewPR(mergeable: .conflicting)),
      ("a draft", pr(awaitingReviewPR()) { $0.draft = true }),
      ("the poll did not read the review decision", samplePR(checks: "SUCCESS", reviewRequests: ["alice"])),
    ])
    func prThatGitHubDoesNotAskToReviewOrThatCannotBeReviewedIsWaiting(_ label: String, _ pr: PullRequest) throws {
      #expect(try place(.waiting, pr: pr).column == .waiting)
    }

    /// Kanban decision 6: someone was asked to read it.
    @Test(arguments: idleStates)
    func prWhoseBranchNeedsNoReviewButHasAnOpenRequestIsInReview(_ state: AttentionState) throws {
      let pr = samplePR(checks: "SUCCESS", reviewRequests: ["alice"], reviewDecisionRead: true)

      #expect(try place(state, pr: pr).column == .inReview)
    }

    @Test func failedDepotJobTakesAPROutOfReview() throws {
      #expect(try place(.waiting, pr: pr(awaitingReviewPR(checks: nil)) { $0.depot = depotRun() }).column == .waiting)
    }

    @Test func needsYouLeavesAPRInReviewInReview() throws {
      #expect(try place(.needsYou, pr: awaitingReviewPR()).column == .inReview)
    }

    /// Ready for review relabels Waiting, so the PR's fields pick the column.
    @Test func readyForReviewWithAnApprovedPRWhoseChecksRunIsWaiting() throws {
      #expect(try place(.readyForReview, pr: approvedPR(checks: "PENDING")).column == .waiting)
    }

    @Test(arguments: ["PENDING", "EXPECTED"])
    func runningChecksPutCIRunningAfterTheReviewers(_ checks: String) throws {
      let line = try #require(try place(.waiting, pr: awaitingReviewPR(checks: checks)).line)

      let reviewer = try #require(line.range(of: "alice"))
      let ci = try #require(line.range(of: "CI running"))
      #expect(reviewer.upperBound <= ci.lowerBound, "\(line)")
    }

    @Test func passedChecksLeaveCIRunningOutOfTheLine() throws {
      let line = try #require(try place(.waiting, pr: awaitingReviewPR()).line)

      #expect(!line.contains("CI running"), "\(line)")
    }

    @Test func inReviewLineNamesTheRequestedReviewer() throws {
      #expect(try place(.waiting, pr: awaitingReviewPR()).line?.contains("alice") == true)
    }
  }
}

// MARK: Reviewers

extension BoardColumnTests {
  @Suite struct Reviewers {
    /// The reviewers of an In review card whose PR asks `requests` and code owners `owners`.
    func reviewers(_ requests: [String], owners: [String]?) throws -> [String] {
      let p = try place(
        .waiting,
        pr: pr(awaitingReviewPR()) {
          $0.reviewRequests = requests
          $0.codeOwnerRequests = owners
        })
      try #require(p.column == .inReview)
      return p.reviewers ?? []
    }

    /// The code owner form carries the team's org, which a nudge needs.
    @Test func reviewerAskedBothWaysKeepsTheCodeOwnerForm() throws {
      #expect(try reviewers(["team-flags"], owners: ["@PostHog/team-flags"]) == ["@PostHog/team-flags"])
    }

    @Test(
      arguments: [
        ("requested people and teams", ["alice", "team-flags"], nil, ["alice", "team-flags"]),
        ("code owners", ["alice"], ["@bob", "@PostHog/team-flags"], ["alice", "bob", "team-flags"]),
        ("a person asked both ways", ["alice"], ["@alice"], ["alice"]),
        ("a team asked both ways", ["team-flags"], ["@PostHog/team-flags"], ["team-flags"]),
        ("the same code owner twice", ["alice"], ["@bob", "@bob"], ["alice", "bob"]),
      ] as [(String, [String], [String]?, Set<String>)])
    func reviewersAreTheRequestsAndCodeOwnersWithoutRepeats(
      _ label: String, _ requests: [String], _ owners: [String]?, _ expected: Set<String>
    ) throws {
      let found = try reviewers(requests, owners: owners)

      #expect(Set(found.map(bare)) == expected && found.count == expected.count, "\(found)")
    }
  }
}

// MARK: Rule 6 and the other collisions

extension BoardColumnTests {
  @Suite struct WaitingRule {
    @Test(
      arguments: [AttentionState.waiting, .needsYou, .canContinue, .stale],
      [("no PR", nil), ("a draft", samplePR(draft: true)), ("closed", samplePR(state: .closed))]
        as [(String, PullRequest?)])
    func draftClosedOrNoPRIsWaitingUnlessClaudeWorks(_ state: AttentionState, _ c: (String, PullRequest?)) throws {
      #expect(try place(state, pr: c.1).column == .waiting)
    }

    @Test(arguments: [AttentionState.needsYou, .canContinue, .stale])
    func needsYouCanContinueAndStaleWithoutAPRColumnAreHeldByYou(_ state: AttentionState) {
      let p = place(state)

      #expect(p.column == .waiting && p.holder == .you)
    }

    @Test func waitingLineSaysWhatTheSessionWaitsOn() {
      let line = place(.waiting, waits: [wait(.manual, note: "ask Alex about the flag")]).line

      #expect(line?.contains("ask Alex about the flag") == true, "\(line ?? "nil")")
    }
  }
}

// MARK: Holder

/// The holder that the oldest open wait of each kind gives.
private let holderOfWait: [(Wait.Kind, BoardHolder?)] = Wait.Kind.allCases.map { kind -> (Wait.Kind, BoardHolder?) in
  switch kind {
  case .session: return (kind, .session)
  case .manual: return (kind, .you)
  case .review, .approval: return (kind, nil)
  case .ci, .queue, .merge, .deploy, .date, .botReview: return (kind, .machine)
  }
}

extension BoardColumnTests {
  @Suite struct Holder {
    @Test(arguments: [AttentionState.needsYou, .readyToMerge, .canContinue, .stale])
    func inboxStatesAreHeldByYouEvenWithAMachineWait(_ state: AttentionState) {
      let p = place(state, waits: [wait(.ci)])

      #expect(p.column == .waiting && p.holder == .you)
    }

    @Test func acknowledgedItemIsHeldByYou() throws {
      let p = place(.waiting, acknowledged: true, waits: [wait(.ci)])

      #expect(p.holder == .you)
    }

    @Test func acknowledgedOfferIsHeldByYou() throws {
      let before = turn("Want me to push?")

      #expect(shownPlace(before + [try ackOfShown(.canContinue, after: before, at: 2)]).holder == .you)
    }

    /// sbd clears an acknowledgment only at a turn, an unack, or a new
    /// prompt, so it stays in the facts after its item leaves the Inbox.
    @Test(arguments: [
      ("checks rerun", AttentionState.readyToMerge, approvedPR(), approvedPR(checks: "PENDING")),
      ("checks rerun", .needsYou, approvedPR(checks: "FAILURE"), approvedPR(checks: "PENDING")),
      ("new commits", .needsYou, approvedPR(checks: "FAILURE"), approvedPR(headSha: "head2", checks: "PENDING")),
    ])
    func acknowledgmentOfAnItemThatLeftTheInboxDoesNotHoldIt(
      _ label: String, _ state: AttentionState, _ seen: PullRequest, _ later: PullRequest
    ) throws {
      let before = turn("Done.") + [try prEvent(10, seen)]
      let events = before + [try ackOfShown(state, after: before, at: 11), try prEvent(12, later)]
      try #require(facts(events).acknowledgment != nil)

      let p = shownPlace(events)

      #expect(p.column == .waiting && p.holder == .machine)
    }

    /// Without a PR, the acknowledgment's head and the PR's head are both nil.
    @Test(arguments: [Wait.Kind.date, .ci])
    func acknowledgedOfferThenAMachineWaitIsHeldByAMachine(_ kind: Wait.Kind) throws {
      let before = turn("Want me to push?")
      let events = before + [try ackOfShown(.canContinue, after: before, at: 2)]
      try #require(facts(events).acknowledgment != nil)

      #expect(shownPlace(events, waits: [wait(kind)]).holder == .machine)
    }

    @Test(arguments: [
      ("In progress", AttentionState.working, approvedPR(checks: "FAILURE")),
      ("In review", .needsYou, awaitingReviewPR()),
      ("Approved", .needsYou, approvedPR()),
      ("Merging", .needsYou, approvedPR(queue: .testing)),
      ("Done", .needsYou, samplePR(state: .merged)),
    ])
    func onlyAWaitingCardHasAHolder(_ label: String, _ state: AttentionState, _ pr: PullRequest) throws {
      let p = try place(state, pr: pr, waits: [wait(.ci)])

      #expect(p.column != .waiting && p.holder == nil)
    }

    /// Kanban decision 7: the app shows the session's reason there.
    @Test func inProgressCardHasNoLine() throws {
      #expect(try place(.working, pr: awaitingReviewPR()).line == nil)
    }

    @Test(arguments: holderOfWait)
    func oldestOpenWaitPicksTheHolderByItsKind(_ kind: Wait.Kind, _ holder: BoardHolder?) {
      let p = place(.waiting, waits: [wait(kind)])

      #expect(p.column == .waiting && p.holder == holder)
    }

    @Test func oldestWaitWinsWhenItComesLast() {
      let waits = [wait(.ci, created: 30, id: "w1"), wait(.manual, created: 10, id: "w2")]

      #expect(place(.waiting, waits: waits).holder == .you)
    }

    @Test func oldestWaitWinsWhenItComesInTheMiddle() {
      let waits = [
        wait(.manual, created: 30, id: "w1"), wait(.session, created: 10, id: "w2"), wait(.ci, created: 20, id: "w3"),
      ]

      #expect(place(.waiting, waits: waits).holder == .session)
    }

    /// `Wait.by` says who set the wait, not who holds it.
    @Test(arguments: [Author.you, .claude])
    func whoSetTheWaitDoesNotPickTheHolder(_ by: Author) {
      var w = wait(.ci)
      w.by = by

      #expect(place(.waiting, waits: [w]).holder == .machine)
    }

    @Test func dependencyThatASessionOwnsIsHeldByThatSession() throws {
      let p = try place(.waiting, pr: samplePR(draft: true), dependencies: [dependency(session: "s2")])

      #expect(p.column == .waiting && p.holder == .session)
    }

    @Test func dependencyThatNoSessionOwnsIsHeldByAMachine() throws {
      let p = try place(.waiting, pr: samplePR(draft: true), dependencies: [dependency()])

      #expect(p.holder == .machine)
    }

    @Test(arguments: [PRState.merged, .closed])
    func dependencyThatNoLongerHoldsGivesNoHolder(_ state: PRState) throws {
      let p = try place(.waiting, pr: samplePR(draft: true), dependencies: [dependency(state: state, session: "s2")])

      #expect(p.holder == nil)
    }

    @Test func runningBackgroundJobIsHeldByAMachine() {
      #expect(place(.waiting, events: [event("job", 5, ["count": 1])]).holder == .machine)
    }

    @Test(arguments: [
      ("checks failed", approvedPR(checks: "FAILURE"), "CI failed"),
      ("a Depot job failed while checks run", pr(approvedPR(checks: "PENDING")) { $0.depot = depotRun() }, "CI failed"),
      ("conflicts with its base", approvedPR(mergeable: .conflicting), "conflicts with main"),
      ("conflicts while checks run", approvedPR(mergeable: .conflicting, checks: "PENDING"), "conflicts with main"),
      ("changes requested", changesRequestedPR(), "changes requested by alex"),
    ])
    func prThatYouMustFixIsHeldByYou(_ label: String, _ pr: PullRequest, _ line: String) throws {
      let p = try place(.waiting, pr: pr)

      #expect(p.column == .waiting && p.holder == .you && p.line == line, "\(p)")
    }

    @Test(
      arguments: [("no PR", nil), ("a draft", samplePR(draft: true)), ("closed", samplePR(state: .closed))]
        as [(String, PullRequest?)])
    func waitingWithNothingToHoldItHasNoHolder(_ label: String, _ pr: PullRequest?) throws {
      #expect(try place(.waiting, pr: pr).holder == nil)
    }

    @Test func waitComesBeforeADependency() throws {
      let p = try place(
        .waiting, pr: samplePR(draft: true), dependencies: [dependency(session: "s2")], waits: [wait(.ci)])

      #expect(p.holder == .machine)
    }

    @Test func dependencyComesBeforeARunningJob() throws {
      let events = [
        try prEvent(10, samplePR(draft: true)), try dependenciesEvent(11, [dependency(session: "s2")]),
        event("job", 12, ["count": 1]),
      ]

      #expect(place(.waiting, events: events).holder == .session)
    }

    @Test func runningJobComesBeforeFailedChecks() throws {
      let events = [try prEvent(10, approvedPR(checks: "FAILURE")), event("job", 12, ["count": 1])]

      #expect(place(.waiting, events: events).holder == .machine)
    }
  }
}

// MARK: Since

extension BoardColumnTests {
  @Suite struct Since {
    @Test(arguments: [AttentionState.working, .notStarted])
    func inProgressCountsFromWhenTheSessionEnteredItsState(_ state: AttentionState) throws {
      #expect(try place(state, pr: awaitingReviewPR(), stateSince: 42).since == 42)
    }

    @Test func waitingWithoutAWaitCountsFromWhenTheSessionEnteredItsState() {
      #expect(place(.waiting, stateSince: 42).since == 42)
    }

    @Test func waitingCountsFromTheOldestOpenWait() {
      let waits = [
        wait(.ci, created: 30, id: "w1"), wait(.manual, created: 10, id: "w2"), wait(.date, created: 20, id: "w3"),
      ]

      #expect(place(.waiting, stateSince: 42, waits: waits).since == 10)
    }

    @Test(arguments: [("done state", AttentionState.done, nil), ("merged PR", .waiting, samplePR(state: .merged))])
    func doneCountsFromWhenTheSessionEnteredItsState(_ label: String, _ state: AttentionState, _ pr: PullRequest?)
      throws
    {
      #expect(try place(state, pr: pr, stateSince: 42).since == 42)
    }

    @Test func inReviewCountsFromThePREventThatPutThePRInReview() throws {
      let p = place(.waiting, events: try prEvents([(10, awaitingReviewPR()), (20, awaitingReviewPR())]))

      #expect(p.column == .inReview && p.since == 10)
    }

    @Test func newHeadInReviewKeepsTheTime() throws {
      let events = try prEvents([(10, awaitingReviewPR(headSha: "head1")), (20, awaitingReviewPR(headSha: "head2"))])

      #expect(place(.waiting, events: events).since == 10)
    }

    @Test func anotherPRInTheSameColumnCountsFromTheSwap() throws {
      let other = pr(awaitingReviewPR()) {
        $0.id = "PR_43"
        $0.number = 43
      }

      #expect(place(.waiting, events: try prEvents([(10, awaitingReviewPR()), (20, other)])).since == 20)
    }

    @Test func approvedCountsFromThePREventThatApprovedThePR() throws {
      let p = place(.waiting, events: try prEvents([(10, awaitingReviewPR()), (20, approvedPR()), (30, approvedPR())]))

      #expect(p.column == .approved && p.since == 20)
    }

    @Test func mergingCountsFromThePREventThatQueuedThePR() throws {
      let events = try prEvents([
        (10, approvedPR()), (20, approvedPR(queue: .pending)), (30, approvedPR(queue: .testing)),
      ])
      let p = place(.waiting, events: events)

      #expect(p.column == .merging && p.since == 20)
    }

    @Test func prThatReturnsToReviewCountsFromItsReturn() throws {
      let events = try prEvents([
        (10, awaitingReviewPR()), (20, awaitingReviewPR(checks: "FAILURE")), (30, awaitingReviewPR()),
      ])

      #expect(place(.waiting, events: events).since == 30)
    }

    /// The PR's time comes from `pr` events, so a turn in between leaves it.
    @Test func prThatWasApprovedDuringATurnCountsFromItsApproval() throws {
      let events =
        try prEvents([(10, approvedPR())]) + [
          event("UserPromptSubmit", 15, ["prompt": "go"]), event("Stop", 25),
        ]

      #expect(place(.waiting, events: events, stateSince: 25).since == 10)
    }

    @Test func turnLeavesTheBoardSinceAlone() throws {
      let events =
        try prEvents([(10, awaitingReviewPR())]) + [event("UserPromptSubmit", 15, ["prompt": "go"]), event("Stop", 25)]

      #expect(facts(events).boardSince == 10)
    }
  }
}

// MARK: Moving back

extension BoardColumnTests {
  @Suite struct MovingBack {
    @Test func trunkRemovalWithoutItsTextIsRemovedFromTheQueue() throws {
      let note = try back(after: [(10, trunkPR(.testing)), (20, trunkPR(.removed))])

      #expect(note == BoardMove(from: .merging, reason: "removed from the queue", at: 20))
    }

    @Test func trunkRemovalCarriesTheQueuesLabelAndText() throws {
      let removed = trunkPR(.removed, label: "Cancelled", text: "Cancelled by alex")

      let note = try #require(try back(after: [(10, trunkPR(.testing)), (20, removed)]))

      #expect(note.from == .merging)
      #expect(note.reason.hasPrefix("removed from the queue"), "\(note.reason)")
      #expect(note.reason.contains("Cancelled by alex"), "\(note.reason)")
    }

    /// Trunk removes a PR whose tests fail, and the removal is why it left.
    @Test func trunkRemovalWithFailedChecksIsARemoval() throws {
      let removed = pr(trunkPR(.removed)) { $0.checks = "FAILURE" }

      let note = try back(after: [(10, trunkPR(.testing)), (20, removed)])

      #expect(note?.from == .merging && note?.reason.hasPrefix("removed from the queue") == true)
    }

    /// The plan names no text for this case. "left the merge queue" is this test's choice.
    @Test func leavingGitHubsQueueWithoutAMergeIsANote() throws {
      let queued = pr(approvedPR()) { $0.inMergeQueue = true }
      let left = pr(approvedPR()) { $0.inMergeQueue = false }

      let note = try back(after: [(10, queued), (20, left)])

      #expect(note == BoardMove(from: .merging, reason: "left the merge queue", at: 20))
    }

    @Test func newHeadCommitThatRestartsChecksIsNewCommits() throws {
      let note = try back(after: [
        (10, approvedPR(headSha: "head1")), (20, approvedPR(headSha: "head2", checks: "PENDING")),
      ])

      #expect(note == BoardMove(from: .approved, reason: "new commits", at: 20))
    }

    @Test(arguments: [
      ("from Approved", approvedPR(), approvedPR(checks: "FAILURE"), BoardColumn.approved),
      ("from In review", awaitingReviewPR(), awaitingReviewPR(checks: "FAILURE"), .inReview),
    ])
    func failedChecksOnTheSameHeadAreCIFailed(
      _ label: String, _ before: PullRequest, _ after: PullRequest, _ from: BoardColumn
    ) throws {
      #expect(try back(after: [(10, before), (20, after)]) == BoardMove(from: from, reason: "CI failed", at: 20))
    }

    @Test func conflictWithTheBaseIsConflictsWithMain() throws {
      let note = try back(after: [(10, approvedPR()), (20, approvedPR(mergeable: .conflicting))])

      #expect(note == BoardMove(from: .approved, reason: "conflicts with main", at: 20))
    }

    @Test func changeRequestNamesTheReviewer() throws {
      let requested = pr(approvedPR()) {
        $0.reviewDecision = .changesRequested
        $0.verdicts = [sampleVerdict("alex", "CHANGES_REQUESTED")]
      }

      let note = try back(after: [(10, approvedPR()), (20, requested)])

      #expect(note == BoardMove(from: .approved, reason: "changes requested by alex", at: 20))
    }

    @Test(arguments: [
      ("from Approved", approvedPR(), BoardColumn.approved),
      ("from In review", awaitingReviewPR(), .inReview),
    ])
    func draftIsBackToDraft(_ label: String, _ before: PullRequest, _ from: BoardColumn) throws {
      let note = try back(after: [(10, before), (20, pr(before) { $0.draft = true })])

      #expect(note == BoardMove(from: from, reason: "back to draft", at: 20))
    }

    @Test func dismissedApprovalIsApprovalDismissed() throws {
      let dismissed = pr(approvedPR()) {
        $0.reviewDecision = .reviewRequired
        $0.verdicts = []
      }

      let note = try back(after: [(10, approvedPR()), (20, dismissed)])

      #expect(note == BoardMove(from: .approved, reason: "approval dismissed", at: 20))
    }

    @Test(
      arguments: [
        ("into review", [(10, samplePR(draft: true)), (20, awaitingReviewPR())]),
        ("review to approved", [(10, awaitingReviewPR()), (20, approvedPR())]),
        ("approved to merging", [(10, approvedPR()), (20, approvedPR(queue: .testing))]),
        ("merging to merged", [(10, approvedPR(queue: .testing)), (20, samplePR(state: .merged))]),
        ("approved to merged", [(10, approvedPR()), (20, samplePR(state: .merged))]),
        (
          "a new head that stays in review",
          [(10, awaitingReviewPR(headSha: "head1")), (20, awaitingReviewPR(headSha: "head2"))]
        ),
        ("a draft that stays a draft", [(10, samplePR(draft: true)), (20, samplePR(draft: true, checks: "FAILURE"))]),
      ] as [(String, [(Int64, PullRequest?)])])
    func moveForwardOrSidewaysMakesNoNote(_ label: String, _ prs: [(Int64, PullRequest?)]) throws {
      #expect(try back(after: prs) == nil)
    }

    /// Each of these lowers the rank for no reason that the plan lists.
    @Test(
      arguments: [
        ("checks run again on the same head", [(10, approvedPR()), (20, approvedPR(checks: "PENDING"))]),
        (
          "approved while checks run", [(10, awaitingReviewPR(checks: "PENDING")), (20, approvedPR(checks: "PENDING"))]
        ),
        ("Trunk merged it before GitHub shows the merge", [(10, trunkPR(.testing)), (20, trunkPR(.merged))]),
        ("Trunk's state became unreadable", [(10, trunkPR(.testing)), (20, trunkPR(.unknown))]),
        (
          "the poll did not read GitHub's queue",
          [(10, pr(approvedPR()) { $0.inMergeQueue = true }), (20, pr(approvedPR()) { $0.inMergeQueue = nil })]
        ),
        ("a PR in review closed", [(10, awaitingReviewPR()), (20, pr(awaitingReviewPR()) { $0.state = .closed })]),
      ] as [(String, [(Int64, PullRequest?)])])
    func moveBackWithoutAListedReasonMakesNoNote(_ label: String, _ prs: [(Int64, PullRequest?)]) throws {
      #expect(try back(after: prs) == nil)
    }

    @Test func failedDepotJobIsCIFailed() throws {
      let note = try back(after: [
        (10, approvedPR(checks: nil)), (20, pr(approvedPR(checks: nil)) { $0.depot = depotRun() }),
      ])

      #expect(note == BoardMove(from: .approved, reason: "CI failed", at: 20))
    }

    @Test func placementCarriesTheNote() throws {
      let events = try prEvents([(10, approvedPR()), (20, approvedPR(checks: "FAILURE"))])

      #expect(place(.waiting, events: events).back == BoardMove(from: .approved, reason: "CI failed", at: 20))
    }

    @Test func laterMoveBackReplacesTheNote() throws {
      let note = try back(after: [
        (10, approvedPR()), (20, awaitingReviewPR()), (30, awaitingReviewPR(checks: "FAILURE")),
      ])

      #expect(note == BoardMove(from: .inReview, reason: "CI failed", at: 30))
    }
  }
}

// MARK: Clearing the note

extension BoardColumnTests {
  @Suite struct ClearingTheNote {
    /// The PR left Approved at t=20 on new commits.
    let leftApproved: [(Int64, PullRequest?)] = [
      (10, approvedPR(headSha: "head1")), (20, approvedPR(headSha: "head2", checks: "PENDING")),
    ]

    @Test func noteClearsWhenThePRReachesTheColumnItLeft() throws {
      #expect(try back(after: leftApproved + [(30, approvedPR(headSha: "head2"))]) == nil)
    }

    @Test func noteClearsWhenThePRPassesTheColumnItLeft() throws {
      #expect(try back(after: leftApproved + [(30, approvedPR(headSha: "head2", queue: .testing))]) == nil)
    }

    @Test func noteStandsWhileThePRIsBelowTheColumnItLeft() throws {
      let note = try back(after: leftApproved + [(30, awaitingReviewPR(headSha: "head2"))])

      #expect(note == BoardMove(from: .approved, reason: "new commits", at: 20))
    }

    @Test func noteFromMergingStandsWhileThePRIsApproved() throws {
      let note = try back(after: [(10, trunkPR(.testing)), (20, trunkPR(.removed)), (30, approvedPR())])

      #expect(note == BoardMove(from: .merging, reason: "removed from the queue", at: 20))
    }

    @Test func noteClearsWhenThePRMerges() throws {
      #expect(try back(after: leftApproved + [(30, samplePR(state: .merged, headSha: "head2"))]) == nil)
    }

    @Test func noteClearsWhenTheSessionLosesItsPR() throws {
      #expect(try back(after: leftApproved + [(30, nil)]) == nil)
    }

    @Test func noteClearsWhenTheSessionsPRChangesToAnother() throws {
      let other = pr(samplePR(draft: true)) {
        $0.id = "PR_43"
        $0.number = 43
        $0.url = "https://github.com/acme/widgets/pull/43"
      }

      #expect(try back(after: leftApproved + [(30, other)]) == nil)
    }

    /// A new PR is not the old PR moving back, even when it ranks lower.
    @Test func switchingToALowerRankedPRMakesNoNote() throws {
      let other = pr(awaitingReviewPR()) {
        $0.id = "PR_43"
        $0.number = 43
        $0.url = "https://github.com/acme/widgets/pull/43"
      }

      #expect(try back(after: [(10, approvedPR()), (20, other)]) == nil)
    }

    @Test func turnThatStartsAndEndsMakesNoNote() throws {
      let events =
        try prEvents([(10, approvedPR())]) + [
          event("UserPromptSubmit", 20, ["prompt": "go"]), event("Stop", 30),
        ]

      #expect(facts(events).boardBack == nil)
    }

    @Test func turnLeavesAStandingNote() throws {
      let events =
        try prEvents(leftApproved) + [event("UserPromptSubmit", 30, ["prompt": "go"]), event("Stop", 40)]

      #expect(facts(events).boardBack == BoardMove(from: .approved, reason: "new commits", at: 20))
    }

    /// Moves between In progress and Waiting are not PR moves.
    @Test func turnOnAPRInReviewMakesNoNoteWhileThePlacementMoves() throws {
      let events =
        try prEvents([(10, awaitingReviewPR())]) + [
          event("UserPromptSubmit", 20, ["prompt": "go"])
        ]

      let p = place(.working, events: events)

      #expect(p.column == .inProgress && p.back == nil)
    }
  }
}

// MARK: Rebuilding

extension BoardColumnTests {
  @Suite struct Rebuilding {
    let events: [Event] = {
      var events = try! prEvents([
        (10, approvedPR(headSha: "head1")), (20, approvedPR(headSha: "head2", checks: "PENDING")),
      ])
      events.append(event("UserPromptSubmit", 30, ["prompt": "go"]))
      events.append(event("Stop", 40))
      return events
    }()

    @Test func replayRebuildsTheNote() {
      let replay = SessionReplay.replaying(events, session: session())

      #expect(replay.facts.boardBack == BoardMove(from: .approved, reason: "new commits", at: 20))
    }

    @Test func replayRebuildsTheBoardSince() {
      let replay = SessionReplay.replaying(events, session: session())

      #expect(replay.facts.boardSince == facts(events).boardSince)
    }

    /// A snapshot is the encoded replay, so the note survives a restart only if it encodes.
    @Test func snapshotKeepsTheNote() throws {
      let replay = SessionReplay.replaying(events, session: session())

      let decoded = try JSONCoding.decode(SessionReplay.self, from: try JSONCoding.encode(replay))

      #expect(decoded.facts.boardBack == replay.facts.boardBack && decoded.facts.boardBack != nil)
    }

    @Test func snapshotKeepsTheBoardSince() throws {
      let replay = SessionReplay.replaying(events, session: session())

      let decoded = try JSONCoding.decode(SessionReplay.self, from: try JSONCoding.encode(replay))

      #expect(decoded.facts.boardSince == replay.facts.boardSince && decoded.facts.boardSince != nil)
    }
  }
}

// MARK: PR summary

extension BoardColumnTests {
  @Suite struct Summary {
    @Test func prSummaryCarriesTheBaseBranch() {
      #expect(PRSummary(samplePR(base: "release-2")).base == "release-2")
    }
  }
}

// MARK: Merge board

/// A work session on the board, in `column` since `since`. A nil column
/// gives the session no placement.
private func boardSession(
  _ id: String, _ column: BoardColumn?, since: Int64 = 0, state: AttentionState = .waiting
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: "uuid-\(id)", state: state,
    reason: "", since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false, lastReply: nil, waits: [],
    notes: [])
  s.board = column.map { BoardPlacement(column: $0, since: since) }
  return s
}

/// A work session in a checkout whose origin is `repository`, showing a PR in `pr`.
private func laneSession(_ id: String, checkout: String, repository: String, pr: String?) -> SessionSummary {
  var s = boardSession(id, .inReview)
  s.checkout = checkout
  s.repository = repository
  s.pr = pr.map { PRSummary(PullRequest(id: "\($0)#1", number: 1, url: "https://github.com/\($0)/pull/1", repo: $0)) }
  return s
}

/// The posthog checkout's sessions, one of which shows a switchboard PR, and
/// a switchboard session.
private let foreignPRSessions = [
  laneSession("foreign", checkout: "/Users/me/dev/posthog", repository: "PostHog/posthog", pr: "haacked/switchboard"),
  laneSession("withPR", checkout: "/Users/me/dev/posthog", repository: "PostHog/posthog", pr: "PostHog/posthog"),
  laneSession("noPR", checkout: "/Users/me/dev/posthog", repository: "PostHog/posthog", pr: nil),
  laneSession(
    "switchboard", checkout: "/Users/me/dev/switchboard", repository: "haacked/switchboard", pr: "haacked/switchboard"),
]

private func permutations<T>(_ items: [T]) -> [[T]] {
  guard let first = items.first else { return [[]] }
  return permutations(Array(items.dropFirst())).flatMap { rest in
    (0...rest.count).map { i in
      var p = rest
      p.insert(first, at: i)
      return p
    }
  }
}

extension BoardColumnTests {
  @Suite struct Board {
    @Test func columnsAreEveryColumnBeforeDone() {
      #expect(MergeBoard.columns == [.inProgress, .waiting, .inReview, .approved, .merging])
    }

    @Test func doneSessionIsDone() {
      #expect(MergeBoard.isDone(boardSession("a", .inReview, state: .done)))
    }

    @Test func sessionInTheDoneColumnIsDone() {
      #expect(MergeBoard.isDone(boardSession("a", .done, state: .waiting)))
    }

    @Test(arguments: [BoardColumn?.none, .inProgress, .waiting, .inReview, .approved, .merging])
    func sessionThatIsNotDoneAndNotInDoneIsNotDone(_ column: BoardColumn?) {
      #expect(!MergeBoard.isDone(boardSession("a", column, state: .working)))
    }

    @Test func cardsKeepOnlyTheSessionsInTheColumn() {
      let sessions = [boardSession("a", .waiting), boardSession("b", .inReview), boardSession("c", .waiting)]

      #expect(MergeBoard.cards(sessions, in: .waiting).map(\.id) == ["a", "c"])
    }

    @Test func sessionWithoutAPlacementIsAnInProgressCard() {
      let sessions = [boardSession("a", nil), boardSession("b", .waiting)]

      #expect(MergeBoard.cards(sessions, in: .inProgress).map(\.id) == ["a"])
    }

    @Test func doneSessionIsNoCard() {
      let sessions = [boardSession("a", .waiting, state: .done), boardSession("b", .waiting)]

      #expect(MergeBoard.cards(sessions, in: .waiting).map(\.id) == ["b"])
    }

    @Test func doneSessionWithoutAPlacementIsNoInProgressCard() {
      #expect(MergeBoard.cards([boardSession("a", nil, state: .done)], in: .inProgress).isEmpty)
    }

    @Test func sessionInTheDoneColumnIsNoCard() {
      #expect(MergeBoard.cards([boardSession("a", .done)], in: .done).isEmpty)
    }

    @Test func olderCardsComeFirst() {
      let sessions = [boardSession("a", .inReview, since: 5), boardSession("b", .inReview, since: 1)]

      #expect(MergeBoard.cards(sessions, in: .inReview).map(\.id) == ["b", "a"])
    }

    @Test func cardsOfTheSameAgeGoByID() {
      let sessions = [boardSession("b", .merging, since: 4), boardSession("a", .merging, since: 4)]

      #expect(MergeBoard.cards(sessions, in: .merging).map(\.id) == ["a", "b"])
    }

    @Test func lanesGroupSessionsByTheirLabel() {
      let sessions = [boardSession("a", .waiting), boardSession("b", .inReview), boardSession("c", .approved)]
      let labels = ["a": "posthog", "b": "widgets", "c": "posthog"]

      let lanes = MergeBoard.repoLanes(sessions, labels: labels)

      #expect(lanes.map { Set($0.sessions.map(\.id)) } == [["a", "c"], ["b"]])
    }

    @Test func lanesGoByTitle() {
      let sessions = [boardSession("a", .waiting), boardSession("b", .waiting)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "widgets", "b": "charts"])

      #expect(lanes.map(\.title) == ["charts", "widgets"])
    }

    @Test func sessionWithoutALabelGoesInOther() {
      let sessions = [boardSession("a", .waiting), boardSession("b", .waiting), boardSession("c", .waiting)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "posthog", "b": "widgets"])

      #expect(lanes.first { $0.title == "Other" }?.sessions.map(\.id) == ["c"])
    }

    @Test func otherLaneSortsByItsTitle() {
      let sessions = [boardSession("a", .waiting), boardSession("b", .waiting), boardSession("c", .waiting)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "posthog", "b": "widgets"])

      #expect(lanes.map(\.title) == ["Other", "posthog", "widgets"])
    }

    @Test func laneIDIsItsTitle() {
      let sessions = [boardSession("a", .waiting), boardSession("b", .waiting)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "posthog"])

      #expect(lanes.map(\.id) == lanes.map(\.title))
    }

    @Test func lanesLeaveOutDoneSessions() {
      let sessions = [
        boardSession("a", .waiting, state: .done), boardSession("b", .done), boardSession("c", .inReview),
      ]
      let labels = ["a": "charts", "b": "posthog", "c": "widgets"]

      let lanes = MergeBoard.repoLanes(sessions, labels: labels)

      #expect(lanes.map(\.title) == ["widgets"])
    }

    @Test func noSessionsGiveNoLanes() {
      #expect(MergeBoard.repoLanes([], labels: [:]).isEmpty)
    }

    @Test(arguments: permutations(foreignPRSessions))
    func lanesPutASessionWithAForeignPRInItsFoldersLaneWhateverTheOrder(_ sessions: [SessionSummary]) {
      let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

      let lanes = MergeBoard.repoLanes(sessions, labels: labels)

      #expect(lanes.map(\.title) == ["PostHog/posthog", "haacked/switchboard"])
      #expect(lanes.map { Set($0.sessions.map(\.id)) } == [["foreign", "withPR", "noPR"], ["switchboard"]])
    }
  }
}
