import Foundation
import Testing

@testable import SwitchboardCore

/// Fixtures/Deploys holds real responses from 2026-10-23 to 2026-10-27:
/// deploy comments from PostHog/posthog PRs #122399, #123721, and #122941,
/// state files from PostHog/charts, and the jobs of PostHog/charts deploy
/// runs. comment-dev-unknown.md is the exception. It comes from the
/// `build_new_comment` template in PostHog/charts
/// scripts/notify-pr-deployed.sh, run for prod-us.
func deployFixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/Deploys/\(name)")
  return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct DeployCommentParsing {
  @Test func readsEveryEnvironmentOfADeployedPR() throws {
    let c = try #require(DeployComment.parse(try deployFixture("comment-deployed.md")))
    let run = "https://github.com/PostHog/charts/actions/runs/40031747810"
    #expect(c.rows[.dev] == DeployComment.Row(status: .deployed, deployedAt: ms("2026-10-23T22:20:00.000Z"), run: run))
    #expect(c.rows[.prodUS] == DeployComment.Row(status: .deployed, deployedAt: ms("2026-10-23T22:34:00.000Z"), run: run))
    #expect(c.rows[.prodEU] == DeployComment.Row(status: .deployed, deployedAt: ms("2026-10-23T22:34:00.000Z"), run: run))
    #expect(DeployEnvironment.allCases.allSatisfy { c.state(in: $0) == .deployed })
  }

  @Test func onePendingProdRegionIsNotDeployed() throws {
    let c = try #require(DeployComment.parse(try deployFixture("comment-prod-us-pending.md")))
    #expect(c.rows[.prodUS] == DeployComment.Row(status: .pending, deployedAt: nil, run: nil))
    #expect(c.state(in: .dev) == .deployed)
    #expect(c.state(in: .prodEU) == .deployed)
    #expect(c.state(in: .prodUS) == .pending)
  }

  @Test func bothProdRegionsPending() throws {
    let c = try #require(DeployComment.parse(try deployFixture("comment-prod-pending.md")))
    #expect(c.state(in: .dev) == .deployed)
    #expect(c.state(in: .prodUS) == .pending)
    #expect(c.state(in: .prodEU) == .pending)
  }

  /// The bot writes Unknown for dev when it creates the comment at a prod
  /// deploy. A prod deploy runs only after dev deployed in the same run.
  @Test func unknownDevCountsAsDeployedOnceAProdRegionDeployed() throws {
    let c = try #require(DeployComment.parse(try deployFixture("comment-dev-unknown.md")))
    #expect(c.rows[.dev]?.status == .unknown)
    #expect(c.state(in: .dev) == .deployed)
    #expect(c.state(in: .prodUS) == .deployed)
    #expect(c.state(in: .prodEU) == .pending)
  }

  @Test func unknownDevWithNoProdDeployIsNotDeployed() throws {
    let body = try deployFixture("comment-dev-unknown.md")
      .replacingOccurrences(of: ":white_check_mark: Deployed", with: ":hourglass_flowing_sand: Pending")
    let c = try #require(DeployComment.parse(body))
    #expect(c.state(in: .dev) == .pending)
  }

  /// Only the bot's Unknown means that it missed dev.
  @Test func anUnrecognizedDevStatusIsNotDeployed() throws {
    let body = try deployFixture("comment-dev-unknown.md")
      .replacingOccurrences(of: ":grey_question: Unknown", with: ":x: Failed")
    let c = try #require(DeployComment.parse(body))
    #expect(c.rows[.dev]?.status == .unrecognized(":x: Failed"))
    #expect(c.state(in: .dev) == .pending)
  }

  @Test func aCommentWithoutTheMarkerIsNotADeployComment() throws {
    let body = try deployFixture("comment-deployed.md").replacingOccurrences(of: DeployComment.marker, with: "")
    #expect(DeployComment.parse(body) == nil)
    #expect(DeployComment.parse("LGTM") == nil)
  }

  @Test func aMissingRowIsNotDeployed() throws {
    let body = try deployFixture("comment-deployed.md").split(separator: "\n")
      .filter { !$0.contains("**prod-eu**") }.joined(separator: "\n")
    let c = try #require(DeployComment.parse(body))
    #expect(c.rows[.prodEU] == nil)
    #expect(c.state(in: .prodEU) == .pending)
  }
}

@Suite struct YAMLScalarReading {
  @Test func nestedKeysBecomeDottedPaths() {
    let s = YAMLScalars.read(
      """
      state:
        app:
          deploy_info:
            dev:
              sha: abc
          image:
            dev: def
      """)
    #expect(s == ["state.app.deploy_info.dev.sha": "abc", "state.app.image.dev": "def"])
  }

  @Test func blockScalarLinesAreTheValueNotKeys() {
    let s = YAMLScalars.read(
      """
      a:
        message: |-
          fix: a thing

          sha: not-a-key
        sha: real
      """)
    #expect(s["a.message"] == "fix: a thing\n\nsha: not-a-key")
    #expect(s["a.sha"] == "real")
    #expect(s["a.message.sha"] == nil)
  }

  @Test func blockScalarChompingAndFolding() {
    let s = YAMLScalars.read("a: |\n  one\n  two\n\nb: >-\n  one\n  two\nc: |+\n  keep\n\nd: x\n")
    #expect(s["a"] == "one\ntwo\n")
    #expect(s["b"] == "one two")
    #expect(s["c"] == "keep\n\n")
    #expect(s["d"] == "x")
  }

  @Test func quotedPlainAndNullScalars() {
    let s = YAMLScalars.read(
      """
      single: 'it''s # not a comment'
      double: "line\\nnext \\"quoted\\""
      plain: value # a comment
      empty: ""
      nothing: null
      tilde: ~
      quotedNull: "null"
      list: []
      items:
        - one
        - two
      after: yes
      """)
    #expect(s["single"] == "it's # not a comment")
    #expect(s["double"] == "line\nnext \"quoted\"")
    #expect(s["plain"] == "value")
    #expect(s["empty"] == "")
    #expect(s["nothing"] == nil)
    #expect(s["tilde"] == nil)
    #expect(s["quotedNull"] == "null")
    #expect(s["list"] == nil)
    #expect(s["items"] == nil)
    #expect(s["after"] == "yes")
  }

  @Test func aQuotedScalarCanSpanLines() {
    let s = YAMLScalars.read("a: \"one\n  two\"\nb: 'three\n  four'\nc: x\n")
    #expect(s["a"] == "one two")
    #expect(s["b"] == "three four")
    #expect(s["c"] == "x")
  }
}

@Suite struct ServiceDeployStateParsing {
  @Test func readsEachStageCommitFromItsImage() throws {
    let s = try #require(ServiceDeployState.parse(service: "posthog", yaml: try deployFixture("state-posthog.yaml")))
    #expect(s.repository == "PostHog/posthog")
    #expect(s.devCommit == "ac70ab68b2bba96d0c3c30743bf8e5aff39cd9cf")
    #expect(s.prodCommit == "053a4f952205e52907bf176a617337993db99286")
    #expect(!s.requiresProdApproval)
    #expect(s.commit(for: .dev) == s.devCommit)
    #expect(s.commit(for: .prodUS) == s.prodCommit)
    #expect(s.commit(for: .prodEU) == s.prodCommit)
  }

  /// feature-flags names its images by digest only. Each stage runs the last
  /// build, image.sha, so the build's deploy_info.commit names the commit.
  /// Its canary image doesn't count as deployed.
  @Test func aDigestOnlyImageOfTheLastBuildTakesTheBuildsCommit() throws {
    let yaml = try deployFixture("state-feature-flags.yaml")
    let s = try #require(ServiceDeployState.parse(service: "feature-flags", yaml: yaml))
    #expect(s.devCommit == "a706fcc2eda17bb6ebafa270285bc39b7a2db629")
    #expect(s.prodCommit == "a706fcc2eda17bb6ebafa270285bc39b7a2db629")
  }

  /// promote-to-prod.yml works for any app. A rollback writes an older
  /// image.prod and leaves deploy_info.prod naming the newer commit.
  @Test func aDigestOnlyImageThatIsntTheLastBuildHasNoKnownCommit() throws {
    let yaml = try deployFixture("state-feature-flags.yaml")
      .replacingOccurrences(
        of: "prod: sha256:4711f592bd317d739b5768504a55609fbb80fc47a0c33da357124f4edb2cc432",
        with: "prod: sha256:0123fa477bc20577d897e0484ad68fb75fb2be8e945200f06d525737891531ab")
    let s = try #require(ServiceDeployState.parse(service: "feature-flags", yaml: yaml))
    #expect(!s.requiresProdApproval)
    #expect(s.prodCommit == nil)
    #expect(s.devCommit == "a706fcc2eda17bb6ebafa270285bc39b7a2db629")
  }

  /// A manual prod promotion writes image.prod and leaves deploy_info.prod
  /// at an older commit.
  @Test func anImageThatNamesItsCommitWinsOverDeployInfo() throws {
    let s = try #require(ServiceDeployState.parse(service: "duckgres", yaml: try deployFixture("state-duckgres.yaml")))
    #expect(s.repository == "PostHog/duckgres")
    #expect(s.requiresProdApproval)
    #expect(s.devCommit == "3da57b65843596d95001cdb3904407b58e22492e")
    #expect(s.prodCommit == "3da57b65843596d95001cdb3904407b58e22492e")
  }

  /// duckgres's image.sha names its commit, so a digest-only image.prod with
  /// the same digest runs that commit. deploy_info.prod names dba33087.
  @Test func aDigestOnlyImageTakesTheCommitThatTheLastBuildNames() throws {
    let yaml = try deployFixture("state-duckgres.yaml")
      .replacingOccurrences(
        of: "prod: 3da57b65843596d95001cdb3904407b58e22492e@sha256:",
        with: "prod: sha256:")
    let s = try #require(ServiceDeployState.parse(service: "duckgres", yaml: yaml))
    #expect(s.prodCommit == "3da57b65843596d95001cdb3904407b58e22492e")
  }

  @Test func requireProdApprovalReadsAsYAMLReadsABoolean() throws {
    let yaml = try deployFixture("state-duckgres.yaml")
      .replacingOccurrences(of: "require_prod_approval: true", with: "require_prod_approval: True")
    #expect(try #require(ServiceDeployState.parse(service: "duckgres", yaml: yaml)).requiresProdApproval)
  }

  /// A deploy commit with no source SHA wrote null deploy_info.dev fields.
  @Test func imageCommitWinsOverNullDeployInfo() throws {
    let yaml = try deployFixture("state-temporal-worker-analytics-platform.yaml")
    let s = try #require(ServiceDeployState.parse(service: "temporal-worker-analytics-platform", yaml: yaml))
    #expect(s.devCommit == "c636770135a647a0aad6b305291522fd99ee457d")
    #expect(s.prodCommit == "363cbcbc7e643e7404de72f84c32e75b3de21789")
  }

  @Test func aStageWithNoImageHasNoCommit() throws {
    let yaml = try deployFixture("state-ai-gateway-billing.yaml")
    let s = try #require(ServiceDeployState.parse(service: "ai-gateway-billing", yaml: yaml))
    #expect(s.devCommit == "cee03eaa9533eb76ee4e91b4921c85effbc2fe73")
    #expect(s.prodCommit == nil)
  }

  @Test func aNullImageHasNoCommit() throws {
    let s = try #require(ServiceDeployState.parse(service: "hoghooks", yaml: try deployFixture("state-hoghooks.yaml")))
    #expect(s.devCommit == nil)
    #expect(s.prodCommit == nil)
  }

  @Test func anotherServiceNameIsNotInTheFile() throws {
    #expect(ServiceDeployState.parse(service: "posthog-web", yaml: try deployFixture("state-posthog.yaml")) == nil)
  }
}

@Suite struct DeployStates {
  @Test func aWaitsEnvironmentNamesOneOrBothRegions() {
    #expect(DeployEnvironment.named("dev") == [.dev])
    #expect(DeployEnvironment.named("prod-eu") == [.prodEU])
    #expect(DeployEnvironment.named("prod") == [.prodUS, .prodEU])
    #expect(DeployEnvironment.named("staging") == nil)
  }

  @Test func comparePathPutsTheDeployedCommitFirst() {
    #expect(
      DeployedAncestry.comparePath(repository: "PostHog/posthog", deployed: "c805", merge: "a706")
        == "repos/PostHog/posthog/compare/c805...a706")
  }

  @Test func compareStatusSaysWhetherTheDeployedCommitContainsTheMerge() {
    #expect(DeployedAncestry(compareStatus: "behind") == .contains)
    #expect(DeployedAncestry(compareStatus: "identical") == .contains)
    #expect(DeployedAncestry(compareStatus: "ahead") == .notYet)
    #expect(DeployedAncestry(compareStatus: "diverged") == .diverged)
    #expect(DeployedAncestry(compareStatus: "") == nil)
  }

  @Test func aServiceStateComesFromTheAncestryAndTheSync() {
    #expect(DeployState(ancestry: .notYet, sync: .succeeded) == .pending)
    #expect(DeployState(ancestry: .diverged, sync: nil) == .offBranch)
    #expect(DeployState(ancestry: .contains, sync: .succeeded) == .deployed)
    #expect(DeployState(ancestry: .contains, sync: .failed) == .failed)
    for sync in [nil, .waiting, .running, .cancelled, .skipped] as [ChartsDeployJobs.State?] {
      #expect(DeployState(ancestry: .contains, sync: sync) == .deploying)
    }
  }
}

@Suite struct ChartsDeployParsing {
  @Test func deployCommitNamesTheAppAndItsSource() {
    let c = ChartsDeployCommit(
      message:
        "deploy feature-flags from PostHog/posthog@a706fcc2eda17bb6ebafa270285bc39b7a2db629 by Piccirello\n\nbody")
    #expect(
      c
        == ChartsDeployCommit(
          app: "feature-flags", repository: "PostHog/posthog", commit: "a706fcc2eda17bb6ebafa270285bc39b7a2db629"))
  }

  @Test func otherChartsCommitsAreNotDeployCommits() {
    #expect(ChartsDeployCommit(message: "deploy temporal-worker-analytics-platform from PostHog/posthog@ by") == nil)
    #expect(ChartsDeployCommit(message: "chore: update dev image with a706fcc for feature-flags [skip ci]") == nil)
  }

  @Test func everyEnvironmentSynced() throws {
    let jobs = try #require(JSON.parse(try deployFixture("jobs-feature-flags-deployed.json")))
    let states = ChartsDeployJobs.states(jobs, app: "feature-flags")
    #expect(states == [.dev: .succeeded, .prodUS: .succeeded, .prodEU: .succeeded])
  }

  @Test func jobsOfAnotherAppDontCount() throws {
    let jobs = try #require(JSON.parse(try deployFixture("jobs-feature-flags-deployed.json")))
    #expect(ChartsDeployJobs.states(jobs, app: "posthog").isEmpty)
  }

  @Test func oneRegionStillSyncing() throws {
    let jobs = try #require(JSON.parse(try deployFixture("jobs-posthog-prod-us-running.json")))
    let states = ChartsDeployJobs.states(jobs, app: "posthog")
    #expect(states == [.dev: .succeeded, .prodUS: .running, .prodEU: .succeeded])
  }

  @Test func oneRegionFailedToSync() throws {
    let jobs = try #require(JSON.parse(try deployFixture("jobs-prod-eu-sync-failed.json")))
    let states = ChartsDeployJobs.states(jobs, app: "temporal-worker-tasks-agent")
    #expect(states == [.dev: .succeeded, .prodUS: .succeeded, .prodEU: .failed])
  }

  /// The runner of "Prod US: Compute combined result" lost its connection
  /// after the sync succeeded.
  @Test func aFailedJobAfterTheSyncDoesntFailTheDeploy() throws {
    let jobs = try #require(JSON.parse(try deployFixture("jobs-runner-lost.json")))
    let states = ChartsDeployJobs.states(jobs, app: "cohort-stream-processor")
    #expect(states == [.dev: .succeeded, .prodUS: .succeeded, .prodEU: .succeeded])
  }

  @Test func aRunCancelledBeforeItsSyncHasNoEnvironments() throws {
    let jobs = try #require(JSON.parse(try deployFixture("jobs-cancelled.json")))
    #expect(ChartsDeployJobs.states(jobs, app: "posthog").isEmpty)
  }

  func devJobs(sync: (String, String?), check: (String, String?)) -> JSON {
    func job(_ name: String, _ s: (String, String?)) -> JSON {
      ["name": .string(name), "status": .string(s.0), "conclusion": s.1.map { .string($0) } ?? .null]
    }
    return [
      "jobs": [
        job("Dev: Deploy with ArgoCD (posthog) / Dev: ArgoCD Sync / sync_argo", sync),
        job("Dev: Deploy with ArgoCD (posthog) / Dev: Check Posthog Deployment / Check Deployment", check),
      ]
    ]
  }

  @Test func devWaitsForThePosthogDeploymentCheck() {
    let running = devJobs(sync: ("completed", "success"), check: ("in_progress", nil))
    #expect(ChartsDeployJobs.states(running, app: "posthog") == [.dev: .running])
    let failed = devJobs(sync: ("completed", "success"), check: ("completed", "failure"))
    #expect(ChartsDeployJobs.states(failed, app: "posthog") == [.dev: .failed])
    let skipped = devJobs(sync: ("completed", "success"), check: ("completed", "skipped"))
    #expect(ChartsDeployJobs.states(skipped, app: "posthog") == [.dev: .succeeded])
  }

  @Test func jobStatesFromStatusAndConclusion() {
    func state(_ status: String, _ conclusion: String?) -> ChartsDeployJobs.State? {
      ChartsDeployJobs.states(devJobs(sync: (status, conclusion), check: ("completed", "skipped")), app: "posthog")[
        .dev]
    }
    #expect(state("queued", nil) == .waiting)
    #expect(state("waiting", nil) == .waiting)
    #expect(state("in_progress", nil) == .running)
    #expect(state("completed", "cancelled") == .cancelled)
    #expect(state("completed", "skipped") == .skipped)
    #expect(state("completed", "timed_out") == .failed)
  }
}
