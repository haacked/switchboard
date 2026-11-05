import Foundation
import Testing

@testable import SwitchboardCore

/// The Depot API responses that Tests/IntegrationTests/Fixtures recorded for
/// PostHog/posthog#127964 on 2026-11-03.
enum DepotFixtures {
  static func response(_ file: String) -> JSON {
    JSON.parse((try? String(contentsOfFile: "\(GitHubFixtures.folder)/\(file)", encoding: .utf8)) ?? "") ?? .null
  }

  /// A ListRuns response, newest first.
  static let runs = response("depot-runs.json")
  /// GetRunStatus for run jtrfd10d8p, whose three jobs failed.
  static let failed = response("depot-status-failed.json")
  /// GetRunStatus for run bts9lt0vbr, which runs.
  static let running = response("depot-status-running.json")

  /// The head commit of run jtrfd10d8p.
  static let failedHead = "4c4295abbbc12c11be1407d5e10705cb74cf28fd"
  /// The head commit of the newest run, 8m4xsl1qqh, which finished.
  static let newestHead = "ced7697e0b4f1bba012e5cf1186cb8d169659879"

  static let aggregate = "Django Tests Pass on Depot"
  static let legacy =
    "Django tests – Core (persons-on-events on, events schema legacy), Py 3.14.7, clickhouse/clickhouse-server:26.6.2 (6/10)"
  static let jsonTargets =
    "Django tests – Core json-targets (persons-on-events on, events schema json), Py 3.14.7, clickhouse/clickhouse-server:26.6.2 (7/9)"
  /// The failed jobs of run jtrfd10d8p, in the response's order.
  static let failedJobs = [aggregate, legacy, jsonTargets]

  /// The response with `edit` applied to each job of each workflow.
  static func editingJobs(_ response: JSON, _ edit: (inout [String: JSON]) -> Void) -> JSON {
    editingWorkflows(response) { workflow in
      workflow["jobs"] = .array(
        (workflow["jobs"]?.array ?? []).map { job in
          var o = job.object ?? [:]
          edit(&o)
          return .object(o)
        })
    }
  }

  static func editingWorkflows(_ response: JSON, _ edit: (inout [String: JSON]) -> Void) -> JSON {
    var o = response.object ?? [:]
    o["workflows"] = .array(
      (o["workflows"]?.array ?? []).map { workflow in
        var w = workflow.object ?? [:]
        edit(&w)
        return .object(w)
      })
    return .object(o)
  }

  /// A ListRuns response with these runs, each given as (runId, headSha, createdAt).
  static func listing(_ runs: [(String, String, String)]) -> JSON {
    [
      "runs": .array(
        runs.map { run in
          ["runId": .string(run.0), "status": "finished", "headSha": .string(run.1), "createdAt": .string(run.2)]
        })
    ]
  }
}

/// A Depot run of `samplePR`'s head commit unless `headSha` says otherwise.
func sampleDepot(
  _ failed: [String] = [], status: String = "failed", headSha: String = samplePRHead, id: String = "r1",
  errors: [String] = []
) -> DepotRun {
  DepotRun(
    id: id, headSha: headSha, status: status, jobs: 90,
    failed: failed.map { DepotRun.Job(name: $0) }, errors: errors)
}

func withDepot(_ pr: PullRequest, _ run: DepotRun?) -> PullRequest {
  var pr = pr
  pr.depot = run
  return pr
}

/// The run that `Depot.run` parses from a GetRunStatus response, for `samplePR`'s head commit.
func parsedRun(_ response: JSON = DepotFixtures.failed, headSha: String = samplePRHead) throws -> DepotRun {
  try #require(Depot.run(response, headSha: headSha))
}

private func prFacts(_ pr: PullRequest, then: [Event] = []) throws -> SessionFacts {
  facts(
    [
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Pushed."]),
      event("pr", 2, ["pr": try JSON(encoding: pr), "comments": []]),
    ] + then)
}

private let readTheReply = Verdict(state: .needsYou, reason: "read its last reply and decide what's next")

/// The queue states of a PR that Trunk added to its merge queue.
private let heldByTrunk: [TrunkQueueState] = [.pending, .testing, .passed, .failing, .queued]

@Suite struct DepotParsing {
  @Test func failedRunHasItsIdStatusAndHeadCommit() throws {
    let run = try parsedRun(headSha: DepotFixtures.failedHead)

    #expect(run.id == "jtrfd10d8p")
    #expect(run.status == "failed")
    #expect(run.headSha == DepotFixtures.failedHead)
  }

  @Test func failedRunNamesItsFailedJobsInTheResponsesOrder() throws {
    #expect(try parsedRun().failed.map(\.name) == DepotFixtures.failedJobs)
  }

  @Test func failedJobLinksToItsPageOnDepot() throws {
    let first = try #require(try parsedRun().failed.first)

    #expect(first.url == "https://depot.dev/orgs/ntsdt08fpt/workflows/05ktvf2pd7?job=v669r36tlh")
  }

  @Test func failedRunCountsEveryJob() throws {
    let run = try parsedRun()

    #expect(run.jobs == 9)
  }

  @Test func runningRunCountsItsJobs() throws {
    let run = try parsedRun(DepotFixtures.running)

    #expect(run.id == "bts9lt0vbr")
    #expect(run.status == "running")
    #expect(run.jobs == 10)
    #expect(run.failed.isEmpty)
  }

  @Test func runWithoutWorkflowErrorsRecordsNone() throws {
    #expect(try parsedRun().errors.isEmpty)
  }

  @Test func workflowErrorMessageIsRecorded() throws {
    let response = DepotFixtures.editingWorkflows(DepotFixtures.failed) {
      $0["errorMessage"] = "workflow ci-backend.yml: unknown key \"runs_on\""
    }

    #expect(try parsedRun(response).errors == ["workflow ci-backend.yml: unknown key \"runs_on\""])
  }

  @Test func emptyWorkflowErrorMessageIsNotAnError() throws {
    let response = DepotFixtures.editingWorkflows(DepotFixtures.failed) { $0["errorMessage"] = "" }

    #expect(try parsedRun(response).errors.isEmpty)
  }

  @Test func failedJobOfARunWithoutAnOrganizationHasNoLink() throws {
    var o = try #require(DepotFixtures.failed.object)
    o["orgId"] = nil

    #expect(try parsedRun(.object(o)).failed.allSatisfy { $0.url == nil })
  }

  @Test func jobFailedWhileTheRunStillRunsIsNamed() throws {
    let response = DepotFixtures.editingJobs(DepotFixtures.running) {
      if $0["jobId"]?.string == "nr8pm6phmn" { $0["status"] = "failed" }
    }

    let run = try parsedRun(response)

    #expect(run.status == "running")
    #expect(run.failed.map(\.name) == ["Validate migrations"])
  }

  @Test(arguments: [JSON.object([:]), .null, ["code": "not_found", "message": "run not found"]])
  func responseWithoutARunParsesToNil(_ response: JSON) {
    #expect(Depot.run(response, headSha: samplePRHead) == nil)
  }

  @Test func runRoundTripsThroughJSON() throws {
    let run = try parsedRun()

    #expect(try JSONCoding.convert(run, to: DepotRun.self) == run)
  }
}

@Suite struct DepotHeadRun {
  @Test func headRunIsThePRsNewestRun() {
    #expect(Depot.headRun(DepotFixtures.runs, headSha: DepotFixtures.newestHead)?.id == "8m4xsl1qqh")
  }

  /// Right after a push, GitHub can still show the old head commit while
  /// Depot already lists the new commit's run.
  @Test(arguments: [DepotFixtures.failedHead, "dddbee51334b5de42c3e4fb35bb52128b75fd368"])
  func olderCommitsRunDoesNotCountOnceANewerRunExists(_ head: String) {
    #expect(Depot.headRun(DepotFixtures.runs, headSha: head) == nil)
  }

  /// The merge commit (`sha`) differs from the head commit, and only `headSha` counts.
  @Test func mergeCommitDoesNotSelectARun() {
    #expect(Depot.headRun(DepotFixtures.runs, headSha: "573d42789a17d09fb14431c417d79510ac12adbc") == nil)
  }

  @Test func headCommitWithoutARunHasNoHeadRun() {
    #expect(Depot.headRun(DepotFixtures.runs, headSha: "pushed-commit") == nil)
  }

  @Test(arguments: [
    [("old", "h", "2026-11-03T10:00:00Z"), ("new", "h", "2026-11-03T12:00:00Z")],
    [("new", "h", "2026-11-03T12:00:00Z"), ("old", "h", "2026-11-03T10:00:00Z")],
  ])
  func headRunIsTheNewestRunOfTheHeadCommitInEitherOrder(_ runs: [(String, String, String)]) {
    let listing = DepotFixtures.listing(runs + [("other", "x", "2026-11-03T09:00:00Z")])

    #expect(Depot.headRun(listing, headSha: "h")?.id == "new")
  }

  @Test(arguments: [JSON.object([:]), ["runs": []]])
  func emptyListingHasNoRuns(_ response: JSON) {
    #expect(!Depot.hasRuns(response))
    #expect(Depot.headRun(response, headSha: DepotFixtures.failedHead) == nil)
  }

  @Test func recordedListingHasRuns() {
    #expect(Depot.hasRuns(DepotFixtures.runs))
  }

  @Test func listRunsBodyAsksForThePRsRunsInEveryStatus() {
    let body = Depot.listRunsBody(repo: "PostHog/posthog", number: 127964)

    #expect(body["repo"]?.string == "PostHog/posthog")
    #expect(body["pr"]?.string == "127964" || body["pr"]?.int == 127964)
    #expect(
      Set(body["status"]?.array?.compactMap(\.string) ?? [])
        == ["queued", "running", "finished", "failed", "cancelled"])
  }
}

@Suite struct DepotDue {
  static let now: Int64 = 1_000_000
  static let pendingMs: Int64 = 30_000
  static let idleMs: Int64 = 300_000

  func due(_ last: DepotRead?, head: String = samplePRHead, after ms: Int64) -> Bool {
    Depot.isDue(
      last, pr: samplePR(headSha: head, checks: "PENDING"), now: DepotDue.now + ms, pendingMs: DepotDue.pendingMs,
      idleMs: DepotDue.idleMs)
  }

  func read(hasRuns: Bool = true, run: DepotRun?, head: String = samplePRHead) -> DepotRead {
    DepotRead(headSha: head, checks: "PENDING", hasRuns: hasRuns, run: run, at: DepotDue.now)
  }

  @Test func prNeverReadIsDue() {
    #expect(due(nil, after: 0))
  }

  @Test func newHeadCommitIsDueAtOnce() {
    #expect(due(read(run: sampleDepot(status: "finished"), head: "older"), after: 0))
  }

  @Test(arguments: ["queued", "running"])
  func runThatHasNotEndedIsDueAfterThePollInterval(_ status: String) {
    let last = read(run: sampleDepot(status: status))

    #expect(!due(last, after: DepotDue.pendingMs - 1))
    #expect(due(last, after: DepotDue.pendingMs))
  }

  @Test func prWithRunsButNoneForItsHeadIsDueAfterThePollInterval() {
    let last = read(hasRuns: true, run: nil)

    #expect(!due(last, after: DepotDue.pendingMs - 1))
    #expect(due(last, after: DepotDue.pendingMs))
  }

  @Test(arguments: ["finished", "failed", "cancelled"])
  func runThatEndedIsDueAfterTheIdleInterval(_ status: String) {
    let last = read(run: sampleDepot(status: status))

    #expect(!due(last, after: DepotDue.pendingMs))
    #expect(!due(last, after: DepotDue.idleMs - 1))
    #expect(due(last, after: DepotDue.idleMs))
  }

  @Test func prWithNoRunsIsDueAfterTheIdleInterval() {
    let last = read(hasRuns: false, run: nil)

    #expect(!due(last, after: DepotDue.pendingMs))
    #expect(due(last, after: DepotDue.idleMs))
  }

  @Test func runThatFailedWhileRunningIsStillReadAfterThePollInterval() {
    let last = read(run: sampleDepot([DepotFixtures.aggregate], status: "running"))

    #expect(due(last, after: DepotDue.pendingMs))
  }
}

@Suite struct DepotWaitOutcome {
  func ci(_ pr: PullRequest) -> String? { waitOn(.ci).resolution(of: pr) }

  @Test(arguments: [
    ([DepotFixtures.aggregate], "Depot CI failed: Django Tests Pass on Depot (run r1)"),
    (["a", "b"], "Depot CI failed: a and 1 more (run r1)"),
    (["a", "b", "c"], "Depot CI failed: a and 2 more (run r1)"),
    (["a", "b", "c", "d"], "Depot CI failed: a and 3 more (run r1)"),
  ])
  func outcomeNamesTheFailedJobsAndTheRun(_ failed: [String], _ outcome: String) {
    #expect(ci(withDepot(samplePR(checks: "PENDING"), sampleDepot(failed))) == outcome)
  }

  @Test func recordedFailedRunResolvesAPendingRollup() throws {
    let run = try parsedRun()

    #expect(
      ci(withDepot(samplePR(checks: "PENDING"), run))
        == "Depot CI failed: \(DepotFixtures.aggregate) and 2 more (run jtrfd10d8p)")
  }

  @Test(arguments: ["PENDING", "EXPECTED", "FAILURE", "ERROR", nil] as [String?])
  func depotFailureOnTheHeadCommitIsTheOutcomeUnlessTheChecksPassed(_ checks: String?) {
    #expect(ci(withDepot(samplePR(checks: checks), sampleDepot(["a"]))) == "Depot CI failed: a (run r1)")
  }

  @Test func failedRunWithoutAFailedJobResolvesWithItsError() {
    let run = sampleDepot([], errors: [#"workflow ci-backend.yml: unknown key "runs_on""#])

    #expect(
      ci(withDepot(samplePR(checks: "PENDING"), run))
        == #"Depot CI failed: workflow ci-backend.yml: unknown key "runs_on" (run r1)"#)
  }

  @Test func passedRollupStaysTheChecksPassed() {
    #expect(ci(withDepot(samplePR(checks: "SUCCESS"), sampleDepot(["a"]))) == "the checks passed")
  }

  @Test(
    arguments: [("PENDING", nil), ("FAILURE", "the checks failed"), ("SUCCESS", "the checks passed")]
      as [(String, String?)])
  func depotFailureOnAnOlderHeadCommitDoesNotCount(_ checks: String, _ outcome: String?) {
    let pr = withDepot(samplePR(checks: checks), sampleDepot(["a"], headSha: "older"))

    #expect(ci(pr) == outcome)
  }

  @Test(arguments: ["queued", "running", "finished"])
  func depotRunWithoutAFailedJobLeavesAPendingRollupOpen(_ status: String) {
    #expect(ci(withDepot(samplePR(checks: "PENDING"), sampleDepot(status: status))) == nil)
  }

  @Test func depotFailureBeforeTheRunEndsResolvesTheWait() {
    let pr = withDepot(samplePR(checks: "PENDING"), sampleDepot(["a"], status: "running"))

    #expect(ci(pr) == "Depot CI failed: a (run r1)")
  }

  /// A ci wait is about the PR's own checks, so Trunk's queue doesn't change its outcome.
  @Test(arguments: [TrunkQueueState.submitted] + heldByTrunk)
  func depotFailureResolvesACIWaitWhileTrunkHasThePR(_ queue: TrunkQueueState) {
    #expect(
      ci(withDepot(samplePR(checks: "PENDING", queue: queue), sampleDepot(["a"]))) == "Depot CI failed: a (run r1)")
  }

  @Test(arguments: [Wait.Kind.merge, .queue, .approval])
  func otherKindsIgnoreADepotFailure(_ kind: Wait.Kind) {
    #expect(waitOn(kind).resolution(of: withDepot(samplePR(checks: "PENDING"), sampleDepot(["a"]))) == nil)
  }
}

@Suite struct DepotAttention {
  static let now: Int64 = 10
  static let failing = sampleDepot([DepotFixtures.aggregate, "b", "c"])

  func verdict(_ pr: PullRequest, then: [Event] = [], session s: Session = session(), now: Int64 = DepotAttention.now)
    throws -> Verdict
  {
    Attention.evaluate(s, try prFacts(pr, then: then), now: now)
  }

  @Test func failedDepotJobNeedsYou() throws {
    #expect(
      try verdict(withDepot(samplePR(checks: "PENDING"), Self.failing))
        == Verdict(state: .needsYou, reason: "fix Depot CI on #42: Django Tests Pass on Depot and 2 more"))
  }

  @Test func oneFailedDepotJobIsNamedAlone() throws {
    #expect(
      try verdict(withDepot(samplePR(checks: "PENDING"), sampleDepot(["unit tests"])))
        == Verdict(state: .needsYou, reason: "fix Depot CI on #42: unit tests"))
  }

  /// The spec's `sb get` example shortens a long job name and keeps the count.
  @Test func longFirstJobNameKeepsTheCountOfTheOthers() throws {
    let v = try verdict(
      withDepot(samplePR(checks: "PENDING"), sampleDepot([DepotFixtures.legacy, DepotFixtures.jsonTargets, "c"])))

    #expect(v.state == .needsYou)
    #expect(v.reason.hasPrefix("fix Depot CI on #42: Django tests – Core"))
    #expect(v.reason.count == 70)
    #expect(v.reason.contains("…"))
    #expect(v.reason.hasSuffix(" and 2 more"))
  }

  /// A workflow that failed to start fails the run without a failed job.
  @Test(
    arguments: [
      ([#"workflow ci-backend.yml: unknown key "runs_on""#], #"workflow ci-backend.yml: unknown key "runs_on""#),
      ([], "the run failed"),
    ] as [([String], String)])
  func failedRunWithoutAFailedJobNamesItsError(_ errors: [String], _ summary: String) throws {
    #expect(
      try verdict(withDepot(samplePR(checks: "PENDING"), sampleDepot([], errors: errors)))
        == Verdict(state: .needsYou, reason: "fix Depot CI on #42: \(summary)"))
  }

  @Test func recordedFailedRunNeedsYou() throws {
    let pr = withDepot(samplePR(checks: "FAILURE"), try parsedRun())

    #expect(
      try verdict(pr) == Verdict(state: .needsYou, reason: "fix Depot CI on #42: Django Tests Pass on Depot and 2 more")
    )
  }

  @Test func depotFailureOnAnOlderHeadCommitFiresNoRule() throws {
    #expect(try verdict(withDepot(samplePR(checks: "PENDING"), sampleDepot(["a"], headSha: "older"))) == readTheReply)
  }

  @Test(arguments: ["queued", "running", "finished", "cancelled"])
  func depotRunWithoutAFailedJobFiresNoRule(_ status: String) throws {
    #expect(try verdict(withDepot(samplePR(checks: "PENDING"), sampleDepot(status: status))) == readTheReply)
  }

  @Test func depotFailureWhileTheRunStillRunsNeedsYou() throws {
    let v = try verdict(withDepot(samplePR(checks: "PENDING"), sampleDepot(["a"], status: "running")))

    #expect(v == Verdict(state: .needsYou, reason: "fix Depot CI on #42: a"))
  }

  /// A finished PR's folder that was never counted fires no rule, so only an
  /// open-PR rule could set the reason.
  @Test(arguments: [PRState.merged, .closed])
  func depotFailureOnAFinishedPRFiresNoRule(_ state: PRState) throws {
    #expect(try verdict(withDepot(samplePR(state: state, checks: "PENDING"), Self.failing)) == readTheReply)
  }

  @Test(arguments: [
    (samplePR(base: "haacked/parent", mergedBase: 41), "retarget #42; its base #41 merged"),
    (samplePR(mergeable: .conflicting), "rebase; #42 conflicts with main"),
    (
      samplePR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)]),
      "address the changes that alice requested on #42"
    ),
    (samplePR(reviewDecision: .changesRequested), "address the requested changes on #42"),
    (samplePR(queue: .removed), "find out why Trunk removed #42 from its queue"),
  ])
  func earlierPRRuleWinsOverADepotFailure(_ pr: PullRequest, _ reason: String) throws {
    var pr = withDepot(pr, Self.failing)
    pr.checks = "PENDING"

    #expect(try verdict(pr) == Verdict(state: .needsYou, reason: reason))
  }

  /// Trunk queues a PR only after its required checks pass, so a Depot
  /// failure on a queued PR comes from a job that isn't required. GitHub's
  /// rollup can still say FAILURE.
  @Test(arguments: heldByTrunk, ["PENDING", "FAILURE", nil] as [String?])
  func depotFailureOnAPRInTrunksQueueFiresNoRule(_ queue: TrunkQueueState, _ checks: String?) throws {
    #expect(try verdict(withDepot(samplePR(checks: checks, queue: queue), Self.failing)) == readTheReply)
    let approved = samplePR(
      reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], checks: checks, queue: queue)
    #expect(try verdict(withDepot(approved, Self.failing)) == readTheReply)
  }

  /// sbd can't tell whether Trunk holds a PR whose queue status did not load.
  /// A submitted PR waits outside the queue until its required checks pass.
  @Test(arguments: [nil, .unknown, .submitted] as [TrunkQueueState?], ["PENDING", "FAILURE"])
  func depotFailureOnAPROutsideTrunksQueueNeedsYou(_ queue: TrunkQueueState?, _ checks: String) throws {
    #expect(
      try verdict(withDepot(samplePR(checks: checks, queue: queue), Self.failing))
        == Verdict(state: .needsYou, reason: "fix Depot CI on #42: Django Tests Pass on Depot and 2 more"))
  }

  @Test(arguments: heldByTrunk)
  func idleSessionWithADepotFailureOnAPRInTrunksQueueIsStale(_ queue: TrunkQueueState) throws {
    let v = try verdict(
      withDepot(samplePR(checks: "PENDING", queue: queue), Self.failing), now: Attention.staleAfterMs + 10)

    #expect(v.state == .stale)
  }

  @Test(arguments: heldByTrunk)
  func failedCIOnAPRInTrunksQueueNeedsNoPRAction(_ queue: TrunkQueueState) throws {
    #expect(!Attention.needsPRAction(try prFacts(withDepot(samplePR(checks: "PENDING", queue: queue), Self.failing))))
    #expect(!Attention.needsPRAction(try prFacts(samplePR(checks: "FAILURE", queue: queue))))
  }

  @Test(arguments: [nil, .unknown, .removed, .submitted] as [TrunkQueueState?])
  func depotFailureOnAPROutsideTrunksQueueNeedsPRAction(_ queue: TrunkQueueState?) throws {
    let f = try prFacts(withDepot(samplePR(checks: "PENDING", queue: queue), Self.failing))

    #expect(Attention.needsPRAction(f))
  }

  @Test func depotFailureWinsOverTheApprovedRule() throws {
    let pr = withDepot(
      samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], checks: "PENDING"),
      Self.failing)

    #expect(
      try verdict(pr) == Verdict(state: .needsYou, reason: "fix Depot CI on #42: Django Tests Pass on Depot and 2 more")
    )
  }

  @Test func depotFailureWinsOverTheReviewWait() throws {
    let pr = withDepot(samplePR(checks: "PENDING", reviewRequests: ["alex"]), Self.failing)

    #expect(
      try verdict(pr) == Verdict(state: .needsYou, reason: "fix Depot CI on #42: Django Tests Pass on Depot and 2 more")
    )
  }

  @Test func runningTurnWinsOverADepotFailure() throws {
    let v = try verdict(
      withDepot(samplePR(checks: "PENDING"), Self.failing), then: [event("UserPromptSubmit", 4, ["prompt": "fix CI"])])

    #expect(v.state == .working)
  }

  @Test func openWaitWinsOverADepotFailure() throws {
    let v = try verdict(
      withDepot(samplePR(reviewDecision: .reviewRequired, checks: "PENDING"), Self.failing),
      session: session(wait: "CI on #42"))

    #expect(v == sampleReadyForReview("CI on #42", checks: "checks pending"))
  }

  @Test func idleSessionWithADepotFailureIsNotStale() throws {
    let v = try verdict(withDepot(samplePR(checks: "PENDING"), Self.failing), now: Attention.staleAfterMs + 10)

    #expect(v == Verdict(state: .needsYou, reason: "fix Depot CI on #42: Django Tests Pass on Depot and 2 more"))
  }

  @Test func idleSessionWithADepotFailureOnAnOlderHeadCommitIsStale() throws {
    let v = try verdict(
      withDepot(samplePR(checks: "PENDING"), sampleDepot(["a"], headSha: "older")), now: Attention.staleAfterMs + 10)

    #expect(v.state == .stale)
  }
}

@Suite struct DepotOnThePR {
  @Test func prEventCarriesTheDepotRunIntoTheFacts() throws {
    let pr = withDepot(samplePR(checks: "PENDING"), try parsedRun())

    #expect(try prFacts(pr).pr?.depot == pr.depot)
  }

  @Test func prWithADepotRunRoundTripsThroughJSON() throws {
    let pr = withDepot(samplePR(), try parsedRun())

    #expect(try JSONCoding.convert(pr, to: PullRequest.self) == pr)
  }

  @Test func prRecordedBeforeDepotHasNoDepotRun() throws {
    var o = try #require(try JSON(encoding: samplePR()).object)
    o["depot"] = nil

    #expect(try JSONCoding.convert(JSON.object(o), to: PullRequest.self).depot == nil)
  }

  @Test func summaryShowsTheHeadCommitsDepotRun() throws {
    let summary = PRSummary(withDepot(samplePR(), try parsedRun()))

    #expect(summary.depot?.status == "failed")
  }

  @Test func summaryHidesAnOlderHeadCommitsDepotRun() throws {
    let summary = PRSummary(withDepot(samplePR(), try parsedRun(headSha: "older")))

    #expect(summary.depot == nil)
  }

  @Test func failedRunLineCountsTheFailedJobsAndNamesTheRun() throws {
    #expect(
      try parsedRun().line == "failed, 9 jobs, 3 failed: Django Tests Pass on Depot and 2 more (run jtrfd10d8p)")
  }

  @Test func runningRunLineStartsWithItsStatusAndNamesTheRun() throws {
    let line = try parsedRun(DepotFixtures.running).line

    #expect(line.hasPrefix("running"))
    #expect(line.hasSuffix("(run bts9lt0vbr)"))
  }
}

@Suite struct DepotSettingsTests {
  static let cliConfig = "api_token: cli-token\norg_id: cli-org\n"

  func settings(token: String? = nil, org: String? = nil) -> DepotSettings {
    var s = DepotSettings()
    s.token = token
    s.org = org
    return s
  }

  func credentials(
    _ s: DepotSettings, env: [String: String] = [:], file: String? = DepotSettingsTests.cliConfig
  ) -> (token: String, org: String?)? {
    s.credentials(environment: env, readConfig: { _ in file })
  }

  @Test func defaultsReachTheRealAPIWithTheCLIsConfig() {
    let d = Config().depot

    #expect(d.url == "https://api.depot.dev")
    #expect(d.token == nil)
    #expect(d.org == nil)
    #expect(d.config == "~/Library/Application Support/depot/depot.yaml")
    #expect(d.enabled)
  }

  @Test func enabledFalseKeepsTheOtherDefaults() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"depot": {"enabled": false}}"#)

    #expect(!c.depot.enabled)
    #expect(c.depot.url == "https://api.depot.dev")
  }

  @Test func configReadsEverySetting() throws {
    let c = try JSONCoding.decode(
      Config.self,
      from: #"{"depot": {"url": "http://127.0.0.1:9", "token": "t", "org": "o", "config": "/tmp/d.yaml"}}"#)

    #expect(c.depot.url == "http://127.0.0.1:9")
    #expect(c.depot.token == "t")
    #expect(c.depot.org == "o")
    #expect(c.depot.config == "/tmp/d.yaml")
  }

  @Test func settingsTokenComesFirst() {
    let c = credentials(settings(token: "set"), env: ["DEPOT_TOKEN": "env"])

    #expect(c?.token == "set")
  }

  @Test func environmentTokenComesBeforeTheCLIsConfig() {
    #expect(credentials(settings(), env: ["DEPOT_TOKEN": "env"])?.token == "env")
  }

  @Test func cliConfigGivesTheTokenAndOrganization() {
    let c = credentials(settings())

    #expect(c?.token == "cli-token")
    #expect(c?.org == "cli-org")
  }

  @Test func quotedValuesInTheCLIsConfigAreRead() {
    let c = credentials(settings(), file: "api_token: \"cli-token\"\norg_id: 'cli-org'\n")

    #expect(c?.token == "cli-token")
    #expect(c?.org == "cli-org")
  }

  @Test func settingsOrganizationWinsOverTheCLIsConfig() {
    #expect(credentials(settings(org: "set-org"))?.org == "set-org")
  }

  /// The CLI's org_id belongs to the CLI's login, so it counts only with that file's token.
  @Test func cliOrganizationDoesNotGoWithTheEnvironmentToken() {
    let c = credentials(settings(), env: ["DEPOT_TOKEN": "env"])

    #expect(c?.token == "env")
    #expect(c?.org == nil)
  }

  @Test func cliOrganizationDoesNotGoWithTheSettingsToken() {
    let c = credentials(settings(token: "set"))

    #expect(c?.token == "set")
    #expect(c?.org == nil)
  }

  @Test func emptyEnvironmentTokenFallsBackToTheCLIsConfig() {
    #expect(credentials(settings(), env: ["DEPOT_TOKEN": ""])?.token == "cli-token")
  }

  @Test(arguments: [nil, "", "org_id: cli-org\n", "api_token: \"\"\n"] as [String?])
  func noTokenAnywhereGivesNoCredentials(_ file: String?) {
    #expect(credentials(settings(org: "o"), file: file) == nil)
  }

  @Test func cliConfigIsReadFromTheExpandedPath() {
    var read: [String] = []
    _ = DepotSettings().credentials(environment: [:]) { path in
      read.append(path)
      return nil
    }

    #expect(read == [NSString(string: "~/Library/Application Support/depot/depot.yaml").expandingTildeInPath])
  }

  @Test func cliConfigSettingChangesTheFileRead() {
    var s = DepotSettings()
    s.config = "/tmp/elsewhere/depot.yaml"
    var read: [String] = []
    _ = s.credentials(environment: [:]) { path in
      read.append(path)
      return nil
    }

    #expect(read == ["/tmp/elsewhere/depot.yaml"])
  }
}
