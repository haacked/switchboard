import Foundation
import SwitchboardCore
import Testing

/// A recorded deploy response from Tests/SwitchboardCoreTests/Fixtures/Deploys.
func deployResponse(_ name: String) throws -> String {
  try String(
    contentsOf: Instance.root.appendingPathComponent("Tests/SwitchboardCoreTests/Fixtures/Deploys/\(name)"),
    encoding: .utf8)
}

/// Deploy waits resolve through `sb poll` against the fake GitHub: from the
/// deploy comment of a PostHog/posthog PR, from a named service's state file
/// and charts run, and when a PostHog/charts PR merges.
@Suite(.timeLimit(.minutes(2))) struct DeployPollerTests {
  /// The branch of PostHog/posthog#122179, which merged on 2026-10-23 and has
  /// a deploy comment that says Deployed in every environment.
  static let mergedBranch = "posthog/groups-list-two-phase-dedup"
  static let chartsBranch = "haacked/cdp-dlq-runbook-lookup-step"
  static let bot = "deployment-status-posthog[bot]"

  static let merge = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f"
  /// The commit that state-feature-flags.yaml says every stage runs.
  static let flagsCommit = "a706fcc2eda17bb6ebafa270285bc39b7a2db629"
  static let chartsCommit = "c4a27c0de5f1b2a3c4d5e6f708192a3b4c5d6e7f"
  static let runId = 40_100_000_001
  static let runURL = "https://github.com/PostHog/charts/actions/runs/\(runId)"

  static let statePath = "repos/PostHog/charts/contents/state/feature-flags.yaml"
  static let comparePath = "repos/PostHog/posthog/compare/\(flagsCommit)...\(merge)"
  static let commitsPath = "repos/PostHog/charts/commits"
  static let runsPath = "repos/PostHog/charts/actions/workflows/state-deploy.yml/runs"
  static let jobsPath = "repos/PostHog/charts/actions/runs/\(runId)/jobs"

  /// A session on #122179's branch, whose PR the poller has read with its
  /// merge commit.
  func mergedSession(_ github: FakeGitHub, _ sbd: Instance) throws -> SessionSummary {
    github.change(122179) { $0["mergeCommit"] = ["oid": .string(DeployPollerTests.merge)] }
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: DeployPollerTests.mergedBranch)
    try sbd.poll()
    return s
  }

  /// The jobs of a feature-flags deploy run in which every environment
  /// synced, with the jobs whose names start with a key of `changes` given
  /// that status and conclusion.
  func flagsJobs(_ changes: [String: (status: String, conclusion: String?)] = [:]) throws -> String {
    var run = try #require(JSON.parse(try deployResponse("jobs-feature-flags-deployed.json"))?.object)
    run["jobs"] = .array(
      (run["jobs"]?.array ?? []).map { job in
        guard let name = job["name"]?.string, let change = changes.first(where: { name.hasPrefix($0.key) })?.value,
          var o = job.object
        else { return job }
        o["status"] = .string(change.status)
        o["conclusion"] = change.conclusion.map(JSON.string) ?? .null
        return .object(o)
      })
    return JSON.object(run).text
  }

  /// github.deployPollSeconds, which defaults to 2 minutes.
  static let deployMs: Int64 = 120_000

  static let prodEUSync = "Prod: Deploy with ArgoCD (feature-flags) / Prod EU: ArgoCD Sync"

  /// Routes the feature-flags state file, the compare of its commit with the
  /// merge, the charts deploy commit, its state-deploy.yml run, and the run's
  /// jobs.
  func serveFeatureFlags(_ github: FakeGitHub, jobs: String) throws {
    let p = DeployPollerTests.self
    github.route(
      p.statePath, etag: "\"state-1\"", contentType: "text/plain; charset=utf-8",
      try deployResponse("state-feature-flags.yaml"))
    github.route(p.comparePath, #"{"status":"behind","ahead_by":0,"behind_by":3,"total_commits":0,"files":[]}"#)
    let commits: JSON = [
      [
        "sha": "9f0e1d2c3b4a59687766554433221100ffeeddcc",
        "commit": ["message": "chore: update dev image with a706fcc for feature-flags [skip ci]"],
      ],
      [
        "sha": .string(p.chartsCommit),
        "commit": [
          "message": .string(
            "deploy feature-flags from PostHog/posthog@\(p.flagsCommit) by Piccirello\n\n"
              + "feat(security): log out-of-band interaction domains in the rust guards (#118875)"
          )
        ],
      ],
      [
        "sha": "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567",
        "commit": [
          "message": "deploy feature-flags from PostHog/posthog@bd924da1c2b3a4958677685940312a1b2c3d4e5f by dmarticus"
        ],
      ],
    ]
    github.route("\(p.commitsPath)?path=state/feature-flags.yaml", commits.text)
    let runs: JSON = [
      "total_count": 1,
      "workflow_runs": [
        [
          "id": .number(Double(p.runId)), "name": "State Deploy", "head_sha": .string(p.chartsCommit),
          "path": ".github/workflows/state-deploy.yml", "status": "in_progress", "conclusion": .null,
          "html_url": .string(p.runURL),
        ]
      ],
    ]
    github.route("\(p.runsPath)?head_sha=\(p.chartsCommit)", runs.text)
    github.route(p.jobsPath, jobs)
  }

  // MARK: The deploy comment

  @Test func aPostHogPRsWaitResumesTheSessionOnceEveryNamedEnvironmentDeployed() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "deploy")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
      $0["mergeCommit"] = ["oid": .string(DeployPollerTests.merge)]
    }
    let comment = github.comment(
      on: 122953, by: DeployPollerTests.bot, body: try deployResponse("comment-prod-us-pending.md"), at: stamp(90))

    try sbd.advanceClock(30_000)
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)

    github.edit(comment: comment, body: try deployResponse("comment-deployed.md"), at: stamp(120))
    try sbd.advanceClock(30_000)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "the session's PR to reach prod: it deployed to prod-us and prod-eu.")
  }

  /// Waiting on a merged PR's deploy is the common case, so the rule that
  /// skips an earlier PR of a reused branch doesn't apply.
  @Test func aWaitOnTheSessionsPRResolvesWhenThePRMergedBeforeTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: DeployPollerTests.mergedBranch)
    try sbd.poll()

    try sbd.sb("wait", s.id, "--kind", "deploy")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "the session's PR to reach prod: it deployed to prod-us and prod-eu.")
  }

  @Test func aWaitOnAnotherPRResolvesFromThatPRsDeployComment() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)

    try sbd.sb("wait", s.id, "--kind", "deploy", "--target", "#122179")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "#122179 to reach prod: it deployed to prod-us and prod-eu.")
  }

  @Test func aDevWaitResolvesWhileProdIsPending() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    try sbd.poll()
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
    }
    github.comment(
      on: 122953, by: DeployPollerTests.bot, body: try deployResponse("comment-prod-pending.md"), at: stamp(90))

    try sbd.sb("wait", s.id, "--kind", "deploy", "--env", "dev")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "the session's PR to reach dev: it deployed to dev.")
  }

  @Test func aCommentWaitSendsNoRESTRequests() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "deploy")

    try sbd.poll()

    #expect(github.restRequests.isEmpty)
  }

  // MARK: A named service

  @Test func aNamedServiceResolvesAfterASuccessfulSync() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs())

    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "the session's PR to reach prod in feature-flags: it deployed to prod-us and prod-eu.")
  }

  /// #122179's deploy comment says Deployed everywhere, and it describes the
  /// main posthog app, not feature-flags.
  @Test func aNamedServiceStaysOpenWhileTheSyncRunsAndNotifiesWhenItFails() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags", "--then", "notify")

    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)

    github.route(DeployPollerTests.jobsPath, try flagsJobs([DeployPollerTests.prodEUSync: ("completed", "failure")]))
    try sbd.advanceClock(DeployPollerTests.deployMs)
    try sbd.poll()
    let after = try sbd.get(s.id)
    let reason =
      "the session's PR to reach prod in feature-flags: the deploy to prod-eu failed: \(DeployPollerTests.runURL)"
    #expect(after.state == .needsYou)
    #expect(after.reason == oneLine(reason))
    #expect(after.waits.isEmpty)
    let resolved = try sbd.events(s.id).last { $0.kind == "wait-resolved" }
    #expect(resolved?.data["outcome"]?.string == "the deploy to prod-eu failed: \(DeployPollerTests.runURL)")
  }

  /// sbd checks a named service again only after 2 minutes. An `sb poll` in between doesn't read it.
  @Test func aNamedServiceIsCheckedAgainAfterTwoMinutes() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")
    #expect(try sbd.poll()["resolved"]?.int == 0)

    github.route(DeployPollerTests.jobsPath, try flagsJobs())

    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(github.restRequests(to: DeployPollerTests.jobsPath).count == 1)
    try sbd.advanceClock(120_000)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    #expect(github.restRequests(to: DeployPollerTests.jobsPath).count == 2)
  }

  /// The last read of the state file can't show what happened after a newer
  /// wait was set, so that wait's service is read again at once.
  @Test func aWaitSetSinceTheLastReadOfItsServiceIsCheckedAtOnce() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    try sbd.advanceClock(1_000)

    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags", "--env", "prod-us")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    #expect(github.restRequests(to: DeployPollerTests.statePath).count == 2)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func anUnreadableStateFileKeepsTheWaitOpen() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    github.route(DeployPollerTests.statePath, contentType: "text/plain; charset=utf-8", "not a state file\n")
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")

    #expect(try sbd.poll()["resolved"]?.int == 0)

    #expect(try sbd.get(s.id).waits.count == 1)
  }

  /// State-deploy.yml starts a little after the state file changes, so a
  /// check can find no run yet. The next check looks again.
  @Test func aChartsRunThatDoesntExistYetIsReadOnTheNextCheck() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs())
    let runs = "\(DeployPollerTests.runsPath)?head_sha=\(DeployPollerTests.chartsCommit)"
    github.route(runs, #"{"total_count":0,"workflow_runs":[]}"#)
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    let misses = github.restRequests(to: DeployPollerTests.runsPath).count

    try serveFeatureFlags(github, jobs: try flagsJobs())
    try sbd.advanceClock(DeployPollerTests.deployMs)

    #expect(try sbd.poll()["resolved"]?.int == 1)
    #expect(github.restRequests(to: DeployPollerTests.runsPath).count > misses)
  }

  /// A merged PR can't change a named service's deploy wait, so after the
  /// read that follows the wait, the PR polls at the idle rate.
  @Test func aNamedServicesWaitDoesntReadItsMergedPRAtThePendingRate() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    let reads = github.requests.filter { $0.kind == "status" }.count

    try sbd.advanceClock(30_000)
    try sbd.poll()

    #expect(github.requests.filter { $0.kind == "status" }.count == reads)
  }

  /// GitHub counts REST and GraphQL against separate quotas. Other `gh` calls
  /// with the same token spend the REST one.
  @Test func aRESTRateLimitDoesntPauseTheGraphQLReads() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    github.route(DeployPollerTests.statePath, status: 403, #"{"message":"API rate limit exceeded for user ID 1."}"#)
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")
    #expect(try sbd.poll()["error"]?.string?.contains("rate limit") == true)
    let before = github.requests.count

    let result = try sbd.poll(all: true)

    #expect(github.requests.count > before)
    #expect(result["error"]?.string?.contains("paused after a GitHub core rate limit") == true)
    #expect(github.restRequests(to: DeployPollerTests.statePath).count == 1)
  }

  @Test func aWaitStaysOpenWhileTheDeployedCommitLacksTheMerge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs())
    github.route(DeployPollerTests.comparePath, #"{"status":"ahead","ahead_by":4,"behind_by":0,"files":[]}"#)
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")

    #expect(try sbd.poll()["resolved"]?.int == 0)

    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func aMergeOffTheDeployedBranchResolvesTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs())
    github.route(DeployPollerTests.comparePath, #"{"status":"diverged","ahead_by":2,"behind_by":5,"files":[]}"#)

    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(
      sbd, s,
      with: "the session's PR to reach prod in feature-flags: "
        + "it merged into master, which feature-flags doesn't deploy from."
    )
  }

  @Test func a304ReusesTheStateFile() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")
    #expect(try sbd.poll()["resolved"]?.int == 0)

    github.route(DeployPollerTests.jobsPath, try flagsJobs())
    try sbd.advanceClock(DeployPollerTests.deployMs)
    #expect(try sbd.poll()["resolved"]?.int == 1)

    let reads = github.restRequests(to: DeployPollerTests.statePath)
    #expect(reads.count == 2)
    #expect(reads.last?.ifNoneMatch == "\"state-1\"")
    try resumed(sbd, s, with: "the session's PR to reach prod in feature-flags: it deployed to prod-us and prod-eu.")
  }

  @Test func theCompareIsntRepeatedForTheSameCommits() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")

    try sbd.poll()
    try sbd.advanceClock(DeployPollerTests.deployMs)
    try sbd.poll()

    #expect(github.restRequests(to: DeployPollerTests.comparePath).count == 1)
  }

  /// The charts commit and its run don't change once found. The jobs do,
  /// until the environment finishes.
  @Test func theChartsCommitAndRunAreReadOnceAndTheJobsEachPass() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")

    try sbd.poll()
    try sbd.advanceClock(DeployPollerTests.deployMs)
    try sbd.poll()

    #expect(github.restRequests(to: DeployPollerTests.commitsPath).count == 1)
    #expect(github.restRequests(to: DeployPollerTests.runsPath).count == 1)
    #expect(github.restRequests(to: DeployPollerTests.jobsPath).count == 2)
  }

  @Test func aServiceThatBuildsFromAnotherRepositoryResolvesTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    github.route(
      "repos/PostHog/charts/contents/state/duckgres.yaml", contentType: "text/plain; charset=utf-8",
      try deployResponse("state-duckgres.yaml"))

    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "duckgres")

    let result = try sbd.poll()

    #expect(result["resolved"]?.int == 1)
    #expect(result["error"] == nil)
    #expect(!github.restRequests.contains { $0.path.contains("/compare/") })
    try resumed(
      sbd, s,
      with: "the session's PR to reach prod in duckgres: duckgres deploys from PostHog/duckgres, not PostHog/posthog.")
  }

  @Test func aServiceWithNoStateFileResolvesTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)

    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flag")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(
      sbd, s, with: "the session's PR to reach prod in feature-flag: PostHog/charts has no state/feature-flag.yaml.")
  }

  /// The failing service sorts before feature-flags, so the poller meets it first.
  @Test func aFailingServiceDoesntStopTheCheckOfAnother() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs())
    github.route("repos/PostHog/charts/contents/state/billing.yaml", status: 500, "{}")
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "billing")
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags", "--then", "notify")

    let result = try sbd.poll()

    #expect(result["resolved"]?.int == 1)
    #expect(result["error"]?.string?.contains("state/billing.yaml") == true)
    #expect(try sbd.get(s.id).waits.map(\.service) == ["billing"])
  }

  @Test func thePollCountsRESTRequests() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try mergedSession(github, sbd)
    try serveFeatureFlags(github, jobs: try flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags")
    let before = (graphQL: github.requests.count, rest: github.restRequests.count)

    let result = try sbd.poll()

    let rest = github.restRequests.count - before.rest
    #expect(rest > 0)
    #expect(result["requests"]?.int == github.requests.count - before.graphQL + rest)
  }

  // MARK: A charts PR

  @Test func aChartsPRsWaitResolvesWhenItMerges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: DeployPollerTests.chartsBranch)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "deploy")
    #expect(try sbd.poll()["resolved"]?.int == 0)

    github.change(18303) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
      $0["mergeCommit"] = ["oid": .string(DeployPollerTests.chartsCommit)]
    }
    try sbd.advanceClock(30_000)

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(
      sbd, s, with: "the session's PR to reach prod: it merged, and Switchboard can't read ArgoCD to see it deploy.")
  }
}
