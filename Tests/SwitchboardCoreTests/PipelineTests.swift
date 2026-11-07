import Foundation
import Testing

@testable import SwitchboardCore

/// samplePR with `edit` applied, for the fields that samplePR takes no argument for.
private func pr(_ base: PullRequest = samplePR(), _ edit: (inout PullRequest) -> Void) -> PullRequest {
  var pr = base
  edit(&pr)
  return pr
}

/// A PR whose review lets it merge and whose checks passed.
private func approvedPR(
  headSha: String = samplePRHead, base: String = "main", mergeable: Mergeable? = .mergeable,
  checks: String? = "SUCCESS",
  queue: TrunkQueueState? = nil
) -> PullRequest {
  samplePR(
    headSha: headSha, base: base, mergeable: mergeable, reviewDecision: .approved, checks: checks, queue: queue,
    reviewDecisionRead: true)
}

/// A PR whose base branch requires a review that nobody gave yet.
private func awaitingReviewPR(headSha: String = samplePRHead, checks: String? = "SUCCESS") -> PullRequest {
  samplePR(headSha: headSha, reviewDecision: .reviewRequired, checks: checks, reviewDecisionRead: true)
}

private func depotRun(on head: String = samplePRHead, status: String = "failed", failed: [String] = ["tests"])
  -> DepotRun
{
  DepotRun(id: "run1", headSha: head, status: status, jobs: 3, failed: failed.map { DepotRun.Job(name: $0) })
}

private func withDepot(_ base: PullRequest, _ run: DepotRun) -> PullRequest { pr(base) { $0.depot = run } }

private func dependency(
  _ number: Int, repo: String = "acme/widgets", state: PRState?, deploy: Bool = false,
  deployed: Bool? = nil
) -> Dependency {
  Dependency(via: .body, repo: repo, number: number, deploy: deploy, state: state, deployed: deployed)
}

/// The pipeline of a session that got `pr` at t=1, then `dependencies` at t=2.
private func pipeline(_ pr: PullRequest?, dependencies: [Dependency] = [], created: Int64 = 0) throws -> Pipeline {
  var events = [try prEvent(1, pr)]
  if !dependencies.isEmpty { events.append(try dependenciesEvent(2, dependencies)) }
  return Pipeline(facts(events), created: created)
}

/// The pipeline after the `pr` events, each a time and a PR.
private func pipeline(after prs: [(Int64, PullRequest?)], created: Int64 = 0) throws -> Pipeline {
  Pipeline(facts(try prs.map { try prEvent($0.0, $0.1) }), created: created)
}

/// The suites nest under one name, so `--filter PipelineTests` runs them all.
@Suite struct PipelineTests {}

// MARK: Stage

extension PipelineTests {
  @Suite struct Stage {
    @Test func stagesRunInPipelineOrder() {
      #expect(PipelineStage.allCases == [.building, .ci, .review, .ready, .merging, .merged])
    }

    @Test(arguments: [
      (PipelineStage.building, "Building"), (.ci, "CI"), (.review, "Review"), (.ready, "Ready"),
      (.merging, "Merging"), (.merged, "Merged"),
    ])
    func eachStageHasItsTitle(_ stage: PipelineStage, _ title: String) {
      #expect(stage.title == title)
    }

    @Test(arguments: [
      (PipelineStage.building, "building"), (.ci, "ci"), (.review, "review"), (.ready, "ready"),
      (.merging, "merging"), (.merged, "merged"),
    ])
    func eachStageEncodesAsItsLowercaseName(_ stage: PipelineStage, _ raw: String) {
      #expect(stage.rawValue == raw)
    }

    @Test(
      arguments: [
        ("no PR", nil),
        ("closed", samplePR(state: .closed)),
        ("closed with failed checks", samplePR(state: .closed, checks: "FAILURE")),
        ("closed and approved", samplePR(state: .closed, reviewDecision: .approved, checks: "SUCCESS")),
        ("closed while Trunk shows it queued", samplePR(state: .closed, queue: .testing)),
        ("draft", samplePR(draft: true)),
        ("draft with running checks", samplePR(draft: true, checks: "PENDING")),
        ("draft with failed checks", samplePR(draft: true, checks: "FAILURE")),
        ("draft and approved", samplePR(draft: true, reviewDecision: .approved, checks: "SUCCESS")),
        ("draft while Trunk shows it queued", samplePR(draft: true, queue: .testing)),
        ("draft in GitHub's merge queue", pr(samplePR(draft: true)) { $0.inMergeQueue = true }),
      ] as [(String, PullRequest?)])
    func prThatIsMissingClosedOrADraftIsBuilding(_ label: String, _ pr: PullRequest?) {
      #expect(PipelineStage(pr) == .building)
    }

    @Test(arguments: [
      ("merged", samplePR(state: .merged)),
      ("merged with failed checks", samplePR(state: .merged, checks: "FAILURE")),
      ("merged while Trunk still shows it queued", samplePR(state: .merged, queue: .testing)),
      ("merged with a conflict", samplePR(state: .merged, mergeable: .conflicting)),
    ])
    func mergedPRIsMerged(_ label: String, _ pr: PullRequest) {
      #expect(PipelineStage(pr) == .merged)
    }

    /// A submitted PR was enqueued and waits for Trunk to add it, so it is merging too.
    @Test(arguments: [TrunkQueueState.submitted, .pending, .testing, .passed, .failing, .queued])
    func prInTrunksQueueIsMerging(_ queue: TrunkQueueState) {
      #expect(PipelineStage(approvedPR(queue: queue)) == .merging)
    }

    @Test(arguments: [TrunkQueueState.merged, .removed, .unknown])
    func prThatTrunkHasNotQueuedIsNotMerging(_ queue: TrunkQueueState) {
      #expect(PipelineStage(approvedPR(queue: queue)) == .ready)
    }

    @Test func prInGitHubsMergeQueueIsMerging() {
      #expect(PipelineStage(pr(approvedPR()) { $0.inMergeQueue = true }) == .merging)
    }

    @Test func prOutOfGitHubsMergeQueueIsNotMerging() {
      #expect(PipelineStage(pr(approvedPR()) { $0.inMergeQueue = false }) == .ready)
    }

    @Test(arguments: [
      ("Trunk queue with running checks", approvedPR(checks: "PENDING", queue: .testing)),
      ("Trunk queue with failed checks", approvedPR(checks: "FAILURE", queue: .failing)),
      ("Trunk queue awaiting review", pr(awaitingReviewPR()) { $0.queue = .pending }),
      ("merge queue with running checks", pr(approvedPR(checks: "EXPECTED")) { $0.inMergeQueue = true }),
      ("merge queue with failed checks", pr(approvedPR(checks: "FAILURE")) { $0.inMergeQueue = true }),
      ("merge queue with a conflict", pr(approvedPR(mergeable: .conflicting)) { $0.inMergeQueue = true }),
    ])
    func queueWinsOverChecksAndReview(_ label: String, _ pr: PullRequest) {
      #expect(PipelineStage(pr) == .merging)
    }

    @Test(arguments: ["PENDING", "EXPECTED", "FAILURE", "ERROR"])
    func runningOrFailedChecksAreCIEvenWhenApproved(_ checks: String) {
      #expect(PipelineStage(approvedPR(checks: checks)) == .ci)
    }

    @Test(arguments: ["PENDING", "EXPECTED", "FAILURE", "ERROR"])
    func runningOrFailedChecksAreCIWhileAwaitingReview(_ checks: String) {
      #expect(PipelineStage(awaitingReviewPR(checks: checks)) == .ci)
    }

    @Test(arguments: [
      ("a failed run, no rollup", withDepot(approvedPR(checks: nil), depotRun())),
      ("a running run with a failed job", withDepot(approvedPR(checks: nil), depotRun(status: "running"))),
      ("a failed run with no named job", withDepot(approvedPR(checks: nil), depotRun(failed: []))),
    ])
    func failedDepotRunOnTheHeadIsCI(_ label: String, _ pr: PullRequest) {
      #expect(PipelineStage(pr) == .ci)
    }

    /// `depotFailure` ignores a failed run once GitHub's rollup passed.
    @Test func failedDepotRunWhileTheRollupPassedIsNotCI() {
      #expect(PipelineStage(withDepot(approvedPR(checks: "SUCCESS"), depotRun())) == .ready)
    }

    @Test func failedDepotRunOnAnEarlierHeadIsNotCI() {
      let pr = withDepot(approvedPR(headSha: "head2"), depotRun(on: "head1"))

      #expect(PipelineStage(pr) == .ready)
    }

    @Test func finishedDepotRunOnTheHeadIsNotCI() {
      let pr = withDepot(approvedPR(checks: nil), depotRun(status: "finished", failed: []))

      #expect(PipelineStage(pr) == .ready)
    }

    @Test(arguments: [
      ("approved", approvedPR()),
      ("approved with no checks", approvedPR(checks: nil)),
      ("approved while another request is open", pr(approvedPR()) { $0.reviewRequests = ["bob"] }),
      (
        "no review required and no request open",
        samplePR(checks: "SUCCESS", reviewRequests: [], reviewDecisionRead: true)
      ),
      (
        "no review required with an approval",
        samplePR(
          verdicts: [sampleVerdict("alice", "APPROVED")], checks: "SUCCESS", reviewRequests: [],
          reviewDecisionRead: true)
      ),
    ])
    func satisfiedReviewIsReady(_ label: String, _ pr: PullRequest) {
      #expect(PipelineStage(pr) == .ready)
    }

    @Test(arguments: [
      ("review required", awaitingReviewPR()),
      ("review required with no checks", awaitingReviewPR(checks: nil)),
      ("changes requested", samplePR(reviewDecision: .changesRequested, checks: "SUCCESS", reviewDecisionRead: true)),
      (
        "approved, but someone's last verdict requests changes",
        samplePR(
          reviewDecision: .approved, verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED")], checks: "SUCCESS",
          reviewDecisionRead: true)
      ),
      (
        "no review required, but someone's last verdict requests changes",
        samplePR(
          verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED")], checks: "SUCCESS", reviewRequests: [],
          reviewDecisionRead: true)
      ),
      (
        "no review required, but a request is open",
        samplePR(checks: "SUCCESS", reviewRequests: ["alice"], reviewDecisionRead: true)
      ),
      ("the poll did not read the review decision", samplePR(checks: "SUCCESS", reviewDecisionRead: nil)),
    ])
    func unsatisfiedReviewIsReview(_ label: String, _ pr: PullRequest) {
      #expect(PipelineStage(pr) == .review)
    }

    @Test(arguments: [
      ("approved", approvedPR(mergeable: .conflicting), PipelineStage.ready),
      ("awaiting review", pr(awaitingReviewPR()) { $0.mergeable = .conflicting }, .review),
      ("checks failed", approvedPR(mergeable: .conflicting, checks: "FAILURE"), .ci),
    ])
    func conflictLeavesTheStageAlone(_ label: String, _ pr: PullRequest, _ stage: PipelineStage) {
      #expect(PipelineStage(pr) == stage)
    }
  }
}

// MARK: Blocker

extension PipelineTests {
  @Suite struct Blocker {
    @Test(arguments: [("main", "conflicts with main"), ("release-2", "conflicts with release-2")])
    func conflictNamesTheBaseBranch(_ base: String, _ blocker: String) throws {
      #expect(try pipeline(approvedPR(base: base, mergeable: .conflicting)).blocker == blocker)
    }

    @Test(arguments: [
      ("checks failed", approvedPR(checks: "FAILURE")),
      ("checks errored", approvedPR(checks: "ERROR")),
      ("a Depot job failed on the head", withDepot(approvedPR(checks: nil), depotRun())),
    ])
    func failedCIIsTheBlocker(_ label: String, _ pr: PullRequest) throws {
      #expect(try pipeline(pr).blocker == "CI failed")
    }

    @Test(arguments: [
      (["alice"], "changes requested by alice"),
      (["alice", "bob"], "changes requested by alice and bob"),
      (["alice", "bob", "carol"], "changes requested by alice and bob and carol"),
    ])
    func changeRequestsNameTheReviewers(_ logins: [String], _ blocker: String) throws {
      let pr = samplePR(
        reviewDecision: .changesRequested, verdicts: logins.map { sampleVerdict($0, "CHANGES_REQUESTED") },
        checks: "SUCCESS", reviewDecisionRead: true)

      #expect(try pipeline(pr).blocker == blocker)
    }

    @Test func changesRequestedDecisionWithoutAVerdictIsNoBlocker() throws {
      let pr = samplePR(reviewDecision: .changesRequested, checks: "SUCCESS", reviewDecisionRead: true)

      #expect(try pipeline(pr).blocker == nil)
    }

    @Test func approvalAfterAChangeRequestClearsTheBlocker() throws {
      let pr = samplePR(
        reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], checks: "SUCCESS",
        reviewDecisionRead: true)

      #expect(try pipeline(pr).blocker == nil)
    }

    @Test(arguments: [
      ("open, same repo", dependency(7, state: .open), "waits on #7"),
      ("not read yet", dependency(7, state: nil), "waits on #7"),
      ("same repo in another case", dependency(7, repo: "Acme/Widgets", state: .open), "waits on #7"),
      ("another repo", dependency(7, repo: "PostHog/posthog", state: .open), "waits on PostHog/posthog#7"),
      ("merged, not yet deployed", dependency(7, state: .merged, deploy: true, deployed: false), "waits on #7"),
    ])
    func holdingDependencyIsTheBlocker(_ label: String, _ dep: Dependency, _ blocker: String) throws {
      #expect(try pipeline(approvedPR(), dependencies: [dep]).blocker == blocker)
    }

    @Test(arguments: [
      ("merged", dependency(7, state: .merged)),
      ("closed", dependency(7, state: .closed)),
      ("merged and deployed", dependency(7, state: .merged, deploy: true, deployed: true)),
    ])
    func dependencyThatNoLongerHoldsIsNoBlocker(_ label: String, _ dep: Dependency) throws {
      #expect(try pipeline(approvedPR(), dependencies: [dep]).blocker == nil)
    }

    @Test func firstDependencyThatHoldsIsTheBlocker() throws {
      let deps = [dependency(7, state: .merged), dependency(8, state: .open), dependency(9, state: .open)]

      #expect(try pipeline(approvedPR(), dependencies: deps).blocker == "waits on #8")
    }

    @Test(arguments: [
      ("approved and checks passed", approvedPR()),
      ("checks running", approvedPR(checks: "PENDING")),
      ("awaiting review", awaitingReviewPR()),
      ("mergeability unknown", approvedPR(mergeable: .unknown)),
      ("mergeability not read", approvedPR(mergeable: nil)),
    ])
    func openPRWithNothingInTheWayHasNoBlocker(_ label: String, _ pr: PullRequest) throws {
      #expect(try pipeline(pr).blocker == nil)
    }

    @Test func conflictComesBeforeFailedCI() throws {
      #expect(try pipeline(approvedPR(mergeable: .conflicting, checks: "FAILURE")).blocker == "conflicts with main")
    }

    @Test func failedCIComesBeforeChangeRequests() throws {
      let pr = samplePR(
        reviewDecision: .changesRequested, verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED")], checks: "FAILURE",
        reviewDecisionRead: true)

      #expect(try pipeline(pr).blocker == "CI failed")
    }

    @Test func changeRequestsComeBeforeADependency() throws {
      let pr = samplePR(
        reviewDecision: .changesRequested, verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED")], checks: "SUCCESS",
        reviewDecisionRead: true)

      #expect(try pipeline(pr, dependencies: [dependency(7, state: .open)]).blocker == "changes requested by bob")
    }

    @Test func conflictComesBeforeEveryOtherBlocker() throws {
      let pr = samplePR(
        mergeable: .conflicting, reviewDecision: .changesRequested,
        verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED")], checks: "FAILURE", reviewDecisionRead: true)

      #expect(try pipeline(pr, dependencies: [dependency(7, state: .open)]).blocker == "conflicts with main")
    }

    @Test func sessionWithoutAPRHasNoBlocker() throws {
      #expect(try pipeline(nil, dependencies: [dependency(7, state: .open)]).blocker == nil)
    }

    @Test(arguments: [
      ("merged with failed checks", samplePR(state: .merged, checks: "FAILURE")),
      (
        "merged with a change request",
        samplePR(state: .merged, verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED")])
      ),
      ("closed with failed checks", samplePR(state: .closed, checks: "FAILURE")),
      ("closed with a conflict", samplePR(state: .closed, mergeable: .conflicting)),
    ])
    func prThatIsNotOpenHasNoBlocker(_ label: String, _ pr: PullRequest) throws {
      #expect(try pipeline(pr, dependencies: [dependency(7, state: .open)]).blocker == nil)
    }

    @Test(arguments: [
      ("failed checks", samplePR(draft: true, checks: "FAILURE"), [Dependency]()),
      (
        "a change request",
        samplePR(draft: true, verdicts: [sampleVerdict("bob", "CHANGES_REQUESTED")]), [Dependency]()
      ),
      ("a dependency that holds", samplePR(draft: true), [dependency(7, state: .open)]),
    ])
    func draftHasNoBlockerUnlessItConflicts(_ label: String, _ pr: PullRequest, _ deps: [Dependency]) throws {
      #expect(try pipeline(pr, dependencies: deps).blocker == nil)
    }

    @Test func draftThatConflictsIsBlockedByTheConflict() throws {
      #expect(try pipeline(samplePR(draft: true, mergeable: .conflicting)).blocker == "conflicts with main")
    }

    /// Outside a queue and without a conflict, every failure that puts the PR
    /// in CI is the failure that the blocker names.
    @Test(arguments: [
      ("checks failed", approvedPR(checks: "FAILURE")),
      ("checks errored", awaitingReviewPR(checks: "ERROR")),
      ("a Depot job failed on the head", withDepot(awaitingReviewPR(checks: nil), depotRun())),
      ("a Depot run failed on the head", withDepot(approvedPR(checks: "PENDING"), depotRun(failed: []))),
    ])
    func ciFailureGivesTheCIStageAndTheCIBlocker(_ label: String, _ pr: PullRequest) throws {
      let p = try pipeline(pr)

      #expect(p.stage == .ci && p.blocker == "CI failed")
    }

    @Test func depotFailureOnATrunkQueuedPRIsNoBlocker() throws {
      let p = try pipeline(withDepot(approvedPR(checks: "PENDING", queue: .testing), depotRun()))

      #expect(p.stage == .merging && p.blocker == nil)
    }
  }
}

// MARK: Since

extension PipelineTests {
  @Suite struct Since {
    @Test func sessionWithoutAPREventCountsFromItsCreation() {
      let f = facts([event("UserPromptSubmit", 30, ["prompt": "go"]), event("Stop", 40)])

      #expect(Pipeline(f, created: 7).since == 7)
    }

    @Test func sessionWithoutAPREventIsBuilding() {
      #expect(Pipeline(facts([]), created: 7).stage == .building)
    }

    @Test func firstPREventThatChangesTheStageSetsTheTime() throws {
      #expect(try pipeline(after: [(10, awaitingReviewPR(checks: "PENDING"))], created: 7).since == 10)
    }

    @Test func stageChangeSetsTheTime() throws {
      let p = try pipeline(after: [(10, awaitingReviewPR(checks: "PENDING")), (20, awaitingReviewPR())])

      #expect(p.since == 20)
    }

    @Test func prEventThatKeepsTheStageKeepsTheTime() throws {
      let p = try pipeline(after: [(10, awaitingReviewPR()), (20, awaitingReviewPR()), (30, awaitingReviewPR())])

      #expect(p.since == 10)
    }

    @Test func newHeadCommitInCIRestartsTheTime() throws {
      let p = try pipeline(after: [
        (10, awaitingReviewPR(headSha: "head1", checks: "FAILURE")),
        (20, awaitingReviewPR(headSha: "head2", checks: "PENDING")),
      ])

      #expect(p.since == 20)
    }

    @Test func newHeadCommitWhoseChecksFailAgainRestartsTheTime() throws {
      let p = try pipeline(after: [
        (10, awaitingReviewPR(headSha: "head1", checks: "FAILURE")),
        (20, awaitingReviewPR(headSha: "head2", checks: "FAILURE")),
      ])

      #expect(p.since == 20)
    }

    @Test func checksThatFailOnTheSameHeadKeepTheTime() throws {
      let p = try pipeline(after: [
        (10, awaitingReviewPR(headSha: "head1", checks: "PENDING")),
        (20, awaitingReviewPR(headSha: "head1", checks: "FAILURE")),
      ])

      #expect(p.since == 10)
    }

    @Test func newHeadCommitInReviewKeepsTheTime() throws {
      let p = try pipeline(after: [
        (10, awaitingReviewPR(headSha: "head1")), (20, awaitingReviewPR(headSha: "head2")),
      ])

      #expect(p.since == 10)
    }

    @Test func reviewThenCIOnANewHeadThenAFailureCountsFromTheMoveToCI() throws {
      let p = try pipeline(after: [
        (10, awaitingReviewPR(headSha: "head1")),
        (20, awaitingReviewPR(headSha: "head2", checks: "PENDING")),
        (30, awaitingReviewPR(headSha: "head2", checks: "FAILURE")),
      ])

      #expect(p.since == 20)
    }

    @Test func returnToCIOnTheSameHeadSetsTheTime() throws {
      let p = try pipeline(after: [
        (10, awaitingReviewPR(headSha: "head1", checks: "PENDING")),
        (20, awaitingReviewPR(headSha: "head1")),
        (30, awaitingReviewPR(headSha: "head1", checks: "PENDING")),
      ])

      #expect(p.since == 30)
    }

    @Test func reviewToReadySetsTheTime() throws {
      let p = try pipeline(after: [(10, awaitingReviewPR()), (20, approvedPR())])

      #expect(p.since == 20)
    }

    @Test func prEventWithoutAPRMovesTheSessionToBuildingAtThatTime() throws {
      let p = try pipeline(after: [(10, awaitingReviewPR()), (20, nil)])

      #expect(p.stage == .building && p.since == 20)
    }

    @Test func otherEventsAfterAPREventKeepTheTime() throws {
      let f = facts([
        try prEvent(10, awaitingReviewPR()), event("UserPromptSubmit", 20, ["prompt": "go"]), event("Stop", 30),
      ])

      #expect(Pipeline(f, created: 0).since == 10)
    }
  }
}

// MARK: PR summary

extension PipelineTests {
  @Suite struct Summary {
    @Test func prSummaryCarriesTheBaseBranch() {
      #expect(PRSummary(samplePR(base: "release-2")).base == "release-2")
    }
  }
}

// MARK: Merge board

/// A work session on the board, in `stage` since `since`. A nil stage gives
/// the session no pipeline.
private func boardSession(
  _ id: String, _ stage: PipelineStage?, since: Int64 = 0, blocker: String? = nil, state: AttentionState = .waiting
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: "uuid-\(id)", state: state,
    reason: "", since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false, lastReply: nil, waits: [],
    notes: [])
  s.pipeline = stage.map { Pipeline(stage: $0, since: since, blocker: blocker) }
  return s
}

extension PipelineTests {
  @Suite struct Board {
    @Test func columnsAreEveryStageBeforeMerged() {
      #expect(MergeBoard.columns == [.building, .ci, .review, .ready, .merging])
    }

    @Test func doneSessionIsDone() {
      #expect(MergeBoard.isDone(boardSession("a", .review, state: .done)))
    }

    @Test func mergedSessionIsDone() {
      #expect(MergeBoard.isDone(boardSession("a", .merged, state: .waiting)))
    }

    @Test(arguments: [PipelineStage?.none, .building, .ci, .review, .ready, .merging])
    func sessionThatIsNotDoneAndNotMergedIsNotDone(_ stage: PipelineStage?) {
      #expect(!MergeBoard.isDone(boardSession("a", stage, state: .working)))
    }

    @Test func cardsKeepOnlyTheSessionsInTheStage() {
      let sessions = [boardSession("a", .ci), boardSession("b", .review), boardSession("c", .ci)]

      #expect(MergeBoard.cards(sessions, in: .ci).map(\.id) == ["a", "c"])
    }

    @Test func sessionWithoutAPipelineIsABuildingCard() {
      let sessions = [boardSession("a", nil), boardSession("b", .ci)]

      #expect(MergeBoard.cards(sessions, in: .building).map(\.id) == ["a"])
    }

    @Test func doneSessionIsNoCard() {
      let sessions = [boardSession("a", .ci, state: .done), boardSession("b", .ci)]

      #expect(MergeBoard.cards(sessions, in: .ci).map(\.id) == ["b"])
    }

    @Test func doneSessionWithoutAPipelineIsNoBuildingCard() {
      #expect(MergeBoard.cards([boardSession("a", nil, state: .done)], in: .building).isEmpty)
    }

    @Test func mergedSessionIsNoCard() {
      #expect(MergeBoard.cards([boardSession("a", .merged)], in: .merged).isEmpty)
    }

    @Test func blockedCardsComeFirst() {
      let sessions = [boardSession("a", .ci, since: 1), boardSession("b", .ci, since: 5, blocker: "CI failed")]

      #expect(MergeBoard.cards(sessions, in: .ci).map(\.id) == ["b", "a"])
    }

    @Test func olderCardsComeFirst() {
      let sessions = [boardSession("a", .review, since: 5), boardSession("b", .review, since: 1)]

      #expect(MergeBoard.cards(sessions, in: .review).map(\.id) == ["b", "a"])
    }

    @Test func olderBlockedCardsComeFirstAmongTheBlocked() {
      let sessions = [
        boardSession("a", .ready, since: 9, blocker: "conflicts with main"),
        boardSession("b", .ready, since: 3, blocker: "waits on #7"),
      ]

      #expect(MergeBoard.cards(sessions, in: .ready).map(\.id) == ["b", "a"])
    }

    @Test func cardsOfTheSameAgeGoByID() {
      let sessions = [boardSession("b", .merging, since: 4), boardSession("a", .merging, since: 4)]

      #expect(MergeBoard.cards(sessions, in: .merging).map(\.id) == ["a", "b"])
    }

    @Test func lanesGroupSessionsByTheirLabel() {
      let sessions = [boardSession("a", .ci), boardSession("b", .review), boardSession("c", .ready)]
      let labels = ["a": "posthog", "b": "widgets", "c": "posthog"]

      let lanes = MergeBoard.repoLanes(sessions, labels: labels)

      #expect(lanes.map { Set($0.sessions.map(\.id)) } == [["a", "c"], ["b"]])
    }

    @Test func lanesGoByTitle() {
      let sessions = [boardSession("a", .ci), boardSession("b", .ci)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "widgets", "b": "charts"])

      #expect(lanes.map(\.title) == ["charts", "widgets"])
    }

    @Test func sessionWithoutALabelGoesInOther() {
      let sessions = [boardSession("a", .ci), boardSession("b", .ci), boardSession("c", .ci)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "posthog", "b": "widgets"])

      #expect(lanes.first { $0.title == "Other" }?.sessions.map(\.id) == ["c"])
    }

    @Test func otherLaneSortsByItsTitle() {
      let sessions = [boardSession("a", .ci), boardSession("b", .ci), boardSession("c", .ci)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "posthog", "b": "widgets"])

      #expect(lanes.map(\.title) == ["Other", "posthog", "widgets"])
    }

    @Test func laneIDIsItsTitle() {
      let sessions = [boardSession("a", .ci), boardSession("b", .ci)]

      let lanes = MergeBoard.repoLanes(sessions, labels: ["a": "posthog"])

      #expect(lanes.map(\.id) == lanes.map(\.title))
    }

    @Test func lanesLeaveOutDoneAndMergedSessions() {
      let sessions = [
        boardSession("a", .ci, state: .done), boardSession("b", .merged), boardSession("c", .review),
      ]
      let labels = ["a": "charts", "b": "posthog", "c": "widgets"]

      let lanes = MergeBoard.repoLanes(sessions, labels: labels)

      #expect(lanes.map(\.title) == ["widgets"])
    }

    @Test func noSessionsGiveNoLanes() {
      #expect(MergeBoard.repoLanes([], labels: [:]).isEmpty)
    }
  }
}
