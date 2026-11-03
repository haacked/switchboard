import Foundation
import Testing

@testable import SwitchboardCore

/// The pure decisions of a `deploy` wait: the PR and its deploy comment, and
/// a named service's state file, compare result, and charts run.
@Suite struct DeployWaitTests {
  static let merge = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f"
  static let run = "https://github.com/PostHog/charts/actions/runs/40100000001"
  static let bot = "deployment-status-posthog[bot]"

  func wait(_ environment: String? = "prod", service: String? = nil) -> Wait {
    waitOn(.deploy, environment: environment, service: service)
  }

  func pr(_ state: PRState = .merged, repo: String = "PostHog/posthog", base: String = "master") -> PullRequest {
    var pr = PullRequest(id: "PR_1", number: 7, url: "", repo: repo, state: state, base: base)
    pr.mergeCommit = state == .merged ? DeployWaitTests.merge : nil
    return pr
  }

  func comment(_ fixture: String, by author: String = DeployWaitTests.bot) throws -> PRComment {
    PRComment(
      id: "IC_deploy", author: author, createdAt: "2026-10-23T22:20:27Z", editedAt: "2026-10-23T22:34:45Z",
      edited: true,
      body: try deployFixture(fixture))
  }

  static let trunk = PRComment(
    id: "IC_trunk", author: "trunk-io[bot]", createdAt: "2026-10-22T15:44:27Z", body: "Merged by the queue")

  // MARK: The resolution order

  @Test(arguments: ["PostHog/posthog", "PostHog/charts", "PostHog/posthog.com"], [nil, "feature-flags"])
  func anOpenPRKeepsTheWaitOpen(repo: String, service: String?) throws {
    let w = wait(service: service)

    let outcome = w.deployResolution(of: pr(.open, repo: repo), comments: [try comment("comment-deployed.md")])

    #expect(outcome == nil)
  }

  @Test(arguments: ["PostHog/posthog", "PostHog/charts", "PostHog/posthog.com"], [nil, "feature-flags"])
  func aPRThatClosedWithoutMergingResolvesTheWait(repo: String, service: String?) throws {
    let w = wait(service: service)

    let outcome = w.deployResolution(of: pr(.closed, repo: repo), comments: [try comment("comment-deployed.md")])

    #expect(outcome == "it closed without merging")
  }

  /// A service's state file decides, so the deploy comment and the repository
  /// rules don't.
  @Test(arguments: ["PostHog/posthog", "PostHog/charts", "PostHog/posthog.com"])
  func aMergedPRWhoseWaitNamesAServiceIsLeftToTheServicePath(repo: String) throws {
    let w = wait(service: "feature-flags")

    let outcome = w.deployResolution(of: pr(repo: repo), comments: [try comment("comment-deployed.md")])

    #expect(outcome == nil)
  }

  @Test(arguments: ["PostHog/charts", "posthog/charts", "POSTHOG/CHARTS"])
  func aMergedChartsPRResolvesBecauseSwitchboardCantReadArgoCD(repo: String) {
    let outcome = wait().deployResolution(of: pr(repo: repo), comments: [])

    #expect(outcome == "it merged, and Switchboard can't read ArgoCD to see it deploy")
  }

  @Test func aChartsPRIgnoresADeployComment() throws {
    let outcome = wait().deployResolution(
      of: pr(repo: "PostHog/charts"), comments: [try comment("comment-deployed.md")])

    #expect(outcome == "it merged, and Switchboard can't read ArgoCD to see it deploy")
  }

  /// Names that contain, start with, or end with posthog or charts are other
  /// repositories.
  @Test(arguments: [
    "PostHog/posthog.com", "PostHog/posthog-js", "haacked/posthog", "PostHog/charts-internal", "haacked/charts",
    "a/b",
  ])
  func aMergedPRInAnotherRepositoryResolvesWithNoDeploySignal(repo: String) throws {
    let outcome = wait().deployResolution(of: pr(repo: repo), comments: [try comment("comment-deployed.md")])

    #expect(outcome == "it merged, and Switchboard has no deploy signal for \(repo)")
  }

  // MARK: The deploy comment

  @Test(arguments: [
    ("comment-deployed.md", "prod", "it deployed to prod-us and prod-eu"),
    ("comment-deployed.md", "prod-us", "it deployed to prod-us"),
    ("comment-deployed.md", "prod-eu", "it deployed to prod-eu"),
    ("comment-deployed.md", "dev", "it deployed to dev"),
    ("comment-prod-us-pending.md", "dev", "it deployed to dev"),
    ("comment-prod-us-pending.md", "prod-eu", "it deployed to prod-eu"),
    ("comment-prod-pending.md", "dev", "it deployed to dev"),
    ("comment-dev-unknown.md", "dev", "it deployed to dev"),
    ("comment-dev-unknown.md", "prod-us", "it deployed to prod-us"),
  ])
  func theCommentResolvesWhenEveryNamedEnvironmentDeployed(fixture: String, environment: String, outcome: String)
    throws
  {
    let w = wait(environment)

    let resolved = w.deployResolution(of: pr(), comments: [try comment(fixture)])

    #expect(resolved == outcome)
  }

  @Test(arguments: [
    ("comment-prod-us-pending.md", "prod"),
    ("comment-prod-us-pending.md", "prod-us"),
    ("comment-prod-pending.md", "prod"),
    ("comment-prod-pending.md", "prod-us"),
    ("comment-prod-pending.md", "prod-eu"),
    ("comment-dev-unknown.md", "prod"),
    ("comment-dev-unknown.md", "prod-eu"),
  ])
  func theCommentKeepsTheWaitOpenWhileANamedEnvironmentIsPending(fixture: String, environment: String) throws {
    let w = wait(environment)

    let resolved = w.deployResolution(of: pr(), comments: [try comment(fixture)])

    #expect(resolved == nil)
  }

  @Test func aWaitWithoutAnEnvironmentWaitsForBothProdRegions() throws {
    let w = wait(nil)

    #expect(w.deployResolution(of: pr(), comments: [try comment("comment-prod-us-pending.md")]) == nil)
    #expect(
      w.deployResolution(of: pr(), comments: [try comment("comment-deployed.md")])
        == "it deployed to prod-us and prod-eu")
  }

  @Test(arguments: ["PostHog/posthog", "posthog/posthog", "POSTHOG/POSTHOG", "Posthog/PostHog"])
  func thePostHogRepositoryNameComparesWithoutCase(repo: String) throws {
    let outcome = wait().deployResolution(of: pr(repo: repo), comments: [try comment("comment-deployed.md")])

    #expect(outcome == "it deployed to prod-us and prod-eu")
  }

  @Test func aMergedPostHogPRWithoutADeployCommentStaysOpen() {
    #expect(wait().deployResolution(of: pr(), comments: []) == nil)
    #expect(wait().deployResolution(of: pr(), comments: [DeployWaitTests.trunk]) == nil)
  }

  /// The status query carries no bodies, so a comment whose body the poller
  /// hasn't read yet says nothing.
  @Test func aDeployCommentWhoseBodyIsUnreadStaysOpen() {
    let unread = PRComment(id: "IC_deploy", author: DeployWaitTests.bot, createdAt: "2026-10-23T22:20:27Z")

    #expect(wait().deployResolution(of: pr(), comments: [unread]) == nil)
  }

  @Test func theDeployCommentIsFoundAmongOtherComments() throws {
    let comments = [DeployWaitTests.trunk, try comment("comment-deployed.md")]

    #expect(wait().deployResolution(of: pr(), comments: comments) == "it deployed to prod-us and prod-eu")
  }

  /// Only the bot's comment counts. A person can paste the bot's table, as
  /// in a review that quotes it.
  @Test(arguments: ["haacked", "deployment-status-posthog", "someone-else[bot]"])
  func aDeployTableFromAnotherAuthorDoesntResolveTheWait(author: String) throws {
    let pasted = try comment("comment-deployed.md", by: author)

    #expect(wait().deployResolution(of: pr(), comments: [pasted]) == nil)
  }

  // MARK: A named service

  func service(
    _ name: String = "feature-flags", repository: String? = "PostHog/posthog", approval: Bool = false
  ) -> ServiceDeployState {
    ServiceDeployState(
      service: name, repository: repository, devCommit: "a706fcc2eda17bb6ebafa270285bc39b7a2db629",
      prodCommit: "a706fcc2eda17bb6ebafa270285bc39b7a2db629", requiresProdApproval: approval)
  }

  func each(_ state: DeployState, run: String? = nil) -> [DeployEnvironment: EnvironmentDeploy] {
    Dictionary(uniqueKeysWithValues: DeployEnvironment.allCases.map { ($0, EnvironmentDeploy(state: state, run: run)) })
  }

  @Test func aServiceWithNoStateFileResolvesTheWait() {
    let w = wait(service: "feature-flag")

    let outcome = w.serviceDeployResolution(nil, pr: pr(), environments: [:])

    #expect(outcome == "PostHog/charts has no state/feature-flag.yaml")
  }

  @Test func aServiceThatBuildsFromAnotherRepositoryResolvesTheWait() throws {
    let duckgres = try #require(
      ServiceDeployState.parse(service: "duckgres", yaml: try deployFixture("state-duckgres.yaml")))
    let w = wait(service: "duckgres")

    let outcome = w.serviceDeployResolution(duckgres, pr: pr(), environments: [:])

    #expect(outcome == "duckgres deploys from PostHog/duckgres, not PostHog/posthog")
  }

  /// The service builds from another repository, so its environments say
  /// nothing about this PR's merge.
  @Test func anotherRepositoryWinsOverDeployedEnvironments() {
    let w = wait(service: "feature-flags")

    let outcome = w.serviceDeployResolution(
      service(repository: "PostHog/posthog-flags"), pr: pr(), environments: each(.deployed))

    #expect(outcome == "feature-flags deploys from PostHog/posthog-flags, not PostHog/posthog")
  }

  @Test(arguments: ["PostHog/posthog", "posthog/posthog", "POSTHOG/POSTHOG"])
  func theServiceRepositoryComparesWithoutCase(repository: String) {
    let w = wait(service: "feature-flags")

    let outcome = w.serviceDeployResolution(
      service(repository: repository), pr: pr(repo: "PostHog/posthog"), environments: each(.deployed))

    #expect(outcome == "it deployed to prod-us and prod-eu")
  }

  @Test(arguments: [
    ("prod", "it deployed to prod-us and prod-eu"),
    ("prod-us", "it deployed to prod-us"),
    ("prod-eu", "it deployed to prod-eu"),
    ("dev", "it deployed to dev"),
  ])
  func everyNamedEnvironmentDeployedResolvesTheWait(environment: String, outcome: String) {
    let w = wait(environment, service: "feature-flags")

    #expect(w.serviceDeployResolution(service(), pr: pr(), environments: each(.deployed)) == outcome)
  }

  @Test(arguments: [DeployState.pending, .deploying, .unknown])
  func oneProdRegionNotDeployedKeepsTheWaitOpen(state: DeployState) {
    let w = wait("prod", service: "feature-flags")
    let environments: [DeployEnvironment: EnvironmentDeploy] = [
      .dev: EnvironmentDeploy(state: .deployed), .prodUS: EnvironmentDeploy(state: .deployed),
      .prodEU: EnvironmentDeploy(state: state),
    ]

    #expect(w.serviceDeployResolution(service(), pr: pr(), environments: environments) == nil)
  }

  @Test(arguments: [DeployEnvironment.prodUS, .prodEU])
  func aMissingProdRegionKeepsTheWaitOpen(missing: DeployEnvironment) {
    let w = wait("prod", service: "feature-flags")
    var environments = each(.deployed)
    environments[missing] = nil

    #expect(w.serviceDeployResolution(service(), pr: pr(), environments: environments) == nil)
  }

  @Test func noDecidedEnvironmentKeepsTheWaitOpen() {
    let w = wait("prod", service: "feature-flags")

    #expect(w.serviceDeployResolution(service(), pr: pr(), environments: [:]) == nil)
  }

  @Test func aFailedEnvironmentResolvesWithItsRun() {
    let w = wait("prod", service: "feature-flags")
    let environments: [DeployEnvironment: EnvironmentDeploy] = [
      .prodUS: EnvironmentDeploy(state: .deployed, run: DeployWaitTests.run),
      .prodEU: EnvironmentDeploy(state: .failed, run: DeployWaitTests.run),
    ]

    let outcome = w.serviceDeployResolution(service(), pr: pr(), environments: environments)

    #expect(outcome == "the deploy to prod-eu failed: \(DeployWaitTests.run)")
  }

  @Test func aFailedEnvironmentWithNoKnownRunResolvesWithoutOne() {
    let w = wait("prod-us", service: "feature-flags")

    let outcome = w.serviceDeployResolution(
      service(), pr: pr(), environments: [.prodUS: EnvironmentDeploy(state: .failed)])

    #expect(outcome == "the deploy to prod-us failed")
  }

  @Test(arguments: [DeployState.pending, .deploying, .unknown])
  func aFailedRegionResolvesWhileTheOtherIsStillGoing(other: DeployState) {
    let w = wait("prod", service: "feature-flags")
    let environments: [DeployEnvironment: EnvironmentDeploy] = [
      .prodUS: EnvironmentDeploy(state: other), .prodEU: EnvironmentDeploy(state: .failed, run: DeployWaitTests.run),
    ]

    let outcome = w.serviceDeployResolution(service(), pr: pr(), environments: environments)

    #expect(outcome == "the deploy to prod-eu failed: \(DeployWaitTests.run)")
  }

  @Test(arguments: ["master", "release-2026-10"])
  func anOffBranchMergeResolvesWithTheBaseBranch(base: String) {
    let w = wait("prod", service: "feature-flags")

    let outcome = w.serviceDeployResolution(service(), pr: pr(base: base), environments: each(.offBranch))

    #expect(outcome == "it merged into \(base), which feature-flags doesn't deploy from")
  }

  @Test func oneOffBranchRegionResolvesTheWait() {
    let w = wait("prod", service: "feature-flags")
    let environments: [DeployEnvironment: EnvironmentDeploy] = [
      .prodUS: EnvironmentDeploy(state: .deploying), .prodEU: EnvironmentDeploy(state: .offBranch),
    ]

    let outcome = w.serviceDeployResolution(service(), pr: pr(), environments: environments)

    #expect(outcome == "it merged into master, which feature-flags doesn't deploy from")
  }

  /// An environment that the wait doesn't name doesn't count, even when it failed.
  @Test func onlyTheNamedEnvironmentsCount() {
    let prod = wait("prod", service: "feature-flags")
    let failedDev: [DeployEnvironment: EnvironmentDeploy] = [
      .dev: EnvironmentDeploy(state: .failed, run: DeployWaitTests.run), .prodUS: EnvironmentDeploy(state: .deployed),
      .prodEU: EnvironmentDeploy(state: .deployed),
    ]
    let dev = wait("dev", service: "feature-flags")
    let failedProd: [DeployEnvironment: EnvironmentDeploy] = [
      .dev: EnvironmentDeploy(state: .deploying), .prodEU: EnvironmentDeploy(state: .failed, run: DeployWaitTests.run),
    ]

    #expect(
      prod.serviceDeployResolution(service(), pr: pr(), environments: failedDev) == "it deployed to prod-us and prod-eu"
    )
    #expect(dev.serviceDeployResolution(service(), pr: pr(), environments: failedProd) == nil)
  }

  // MARK: One environment's state

  static let ancestries: [DeployedAncestry] = [.contains, .notYet, .diverged]
  static let syncs: [ChartsDeployJobs.State?] = [nil, .waiting, .running, .succeeded, .failed, .cancelled, .skipped]

  /// A service without prod approval decides every environment from the
  /// ancestry and the sync alone.
  @Test(arguments: DeployEnvironment.allCases, DeployWaitTests.ancestries)
  func withoutApprovalTheStateMatchesTheAncestryAndTheSync(
    environment: DeployEnvironment, ancestry: DeployedAncestry
  ) {
    for sync in DeployWaitTests.syncs {
      #expect(
        DeployState.of(service(), in: environment, ancestry: ancestry, sync: sync)
          == DeployState(ancestry: ancestry, sync: sync))
    }
  }

  @Test(arguments: [DeployEnvironment.prodUS, .prodEU])
  func anApprovalGatedProdRegionThatContainsTheMergeIsDeployed(environment: DeployEnvironment) {
    let state = DeployState.of(service(approval: true), in: environment, ancestry: .contains, sync: nil)

    #expect(state == .deployed)
  }

  @Test(arguments: [DeployEnvironment.prodUS, .prodEU])
  func anApprovalGatedProdRegionStillNeedsTheMerge(environment: DeployEnvironment) {
    let gated = service(approval: true)

    #expect(DeployState.of(gated, in: environment, ancestry: .notYet, sync: nil) == .pending)
    #expect(DeployState.of(gated, in: environment, ancestry: .diverged, sync: nil) == .offBranch)
  }

  /// Approval gates prod only. Dev syncs on every deploy.
  @Test func anApprovalGatedServicesDevStillNeedsItsSync() {
    let gated = service(approval: true)

    #expect(DeployState.of(gated, in: .dev, ancestry: .contains, sync: nil) == .deploying)
    #expect(DeployState.of(gated, in: .dev, ancestry: .contains, sync: .running) == .deploying)
    #expect(DeployState.of(gated, in: .dev, ancestry: .contains, sync: .succeeded) == .deployed)
    #expect(DeployState.of(gated, in: .dev, ancestry: .contains, sync: .failed) == .failed)
  }

  // MARK: From the recorded responses

  /// The states that the poller would give each environment of `service`,
  /// from a recorded jobs response and one ancestry for every environment.
  func environments(_ service: ServiceDeployState, jobs fixture: String, ancestry: DeployedAncestry) throws
    -> [DeployEnvironment: EnvironmentDeploy]
  {
    let jobs = try #require(JSON.parse(try deployFixture(fixture)))
    let syncs = ChartsDeployJobs.states(jobs, app: service.service)
    return Dictionary(
      uniqueKeysWithValues: DeployEnvironment.allCases.map { e in
        (
          e,
          EnvironmentDeploy(
            state: DeployState.of(service, in: e, ancestry: ancestry, sync: syncs[e]), run: DeployWaitTests.run)
        )
      })
  }

  @Test func aRecordedSuccessfulRunDeploysBothProdRegions() throws {
    let flags = try #require(
      ServiceDeployState.parse(service: "feature-flags", yaml: try deployFixture("state-feature-flags.yaml")))
    let w = wait("prod", service: "feature-flags")

    let envs = try environments(flags, jobs: "jobs-feature-flags-deployed.json", ancestry: .contains)

    #expect(w.serviceDeployResolution(flags, pr: pr(), environments: envs) == "it deployed to prod-us and prod-eu")
  }

  @Test func aRecordedRunWithProdUSSyncingKeepsAProdWaitOpen() throws {
    let posthog = try #require(
      ServiceDeployState.parse(service: "posthog", yaml: try deployFixture("state-posthog.yaml")))
    let envs = try environments(posthog, jobs: "jobs-posthog-prod-us-running.json", ancestry: .contains)

    #expect(wait("prod", service: "posthog").serviceDeployResolution(posthog, pr: pr(), environments: envs) == nil)
    #expect(
      wait("prod-eu", service: "posthog").serviceDeployResolution(posthog, pr: pr(), environments: envs)
        == "it deployed to prod-eu")
  }

  @Test func aRecordedRunWhoseProdEUSyncFailedResolvesWithTheFailure() throws {
    let app = service("temporal-worker-tasks-agent")
    let w = wait("prod", service: "temporal-worker-tasks-agent")

    let envs = try environments(app, jobs: "jobs-prod-eu-sync-failed.json", ancestry: .contains)

    #expect(
      w.serviceDeployResolution(app, pr: pr(), environments: envs)
        == "the deploy to prod-eu failed: \(DeployWaitTests.run)")
  }

  /// duckgres's prod needs approval, so its run has no prod sync job.
  @Test func anApprovalGatedServiceDeploysToProdWithoutASyncJob() throws {
    let duckgres = try #require(
      ServiceDeployState.parse(service: "duckgres", yaml: try deployFixture("state-duckgres.yaml")))
    let w = wait("prod", service: "duckgres")

    let envs = try environments(duckgres, jobs: "jobs-cancelled.json", ancestry: .contains)

    #expect(
      w.serviceDeployResolution(duckgres, pr: pr(repo: "PostHog/duckgres"), environments: envs)
        == "it deployed to prod-us and prod-eu")
  }

  // MARK: The merge commit

  @Test func theStatusQueryReadsTheMergeCommit() throws {
    var node = try #require(GitHubFixtures.statusNode(122179)?.object)
    node["mergeCommit"] = ["oid": .string(DeployWaitTests.merge)]

    let parsed = try #require(GitHub.parsePR(.object(node)))

    #expect(parsed.pr.mergeCommit == DeployWaitTests.merge)
  }

  @Test func anUnmergedPRHasNoMergeCommit() throws {
    var node = try #require(GitHubFixtures.statusNode(122953)?.object)
    node["mergeCommit"] = .null

    let parsed = try #require(GitHub.parsePR(.object(node)))

    #expect(parsed.pr.mergeCommit == nil)
  }

  @Test func theStatusQueryAsksForTheMergeCommit() {
    #expect(GitHub.statusQuery.contains("mergeCommit { oid }"))
  }

  /// Events that an older sbd recorded have no mergeCommit.
  @Test func aRecordedPRWithoutAMergeCommitStillDecodes() throws {
    let encoded = try JSONEncoder().encode(pr())
    var object = try #require(JSON.parse(String(decoding: encoded, as: UTF8.self))?.object)
    #expect(object["mergeCommit"]?.string == DeployWaitTests.merge)
    object["mergeCommit"] = nil

    let decoded = try JSONDecoder().decode(PullRequest.self, from: Data(JSON.object(object).text.utf8))

    #expect(decoded.mergeCommit == nil)
  }
}
