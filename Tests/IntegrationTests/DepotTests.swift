import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A private sbd whose GitHub poller asks `github` and whose Depot poller
  /// asks `depot`, with `token` as the Depot token. `depot` overrides the
  /// other Depot settings.
  static func withDepot(
    _ github: FakeGitHub, _ depot: FakeDepot, token: String? = "depot-token-1", settings: [String: JSON] = [:]
  ) throws -> Instance {
    var depotSettings: [String: JSON] = ["url": .string(depot.url), "config": "/nonexistent/depot.yaml"]
    if let token { depotSettings["token"] = .string(token) }
    return try Instance(config: [
      "github": [
        "gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url), "pollSeconds": 0,
      ],
      "depot": .object(depotSettings.merging(settings) { $1 }),
      "tickSeconds": 1,
    ])
  }

  /// The `pr.depot` of `sb get --json`, or nil when it shows none.
  func depotShown(_ id: String) throws -> JSON? {
    let depot = JSON.parse(try sb("get", id, "--json"))?["pr"]?["depot"]
    return depot == .null ? nil : depot
  }

  /// The `depot:` line of `sb get` without its label.
  func depotLine(_ id: String) throws -> String? {
    try sb("get", id).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("depot:") }
      .map { $0.dropFirst("depot:".count).trimmingCharacters(in: .whitespaces) }
  }

  /// The Depot run of the session's last `pr` event.
  func recordedDepot(_ id: String) throws -> DepotRun? {
    guard let pr = try events(id).last(where: { $0.kind == "pr" })?.data["pr"], pr != .null else { return nil }
    return try JSONCoding.convert(pr, to: PullRequest.self).depot
  }
}

/// The Depot poller, through `sb poll` against a fake Depot and a fake GitHub.
@Suite(.timeLimit(.minutes(2))) struct DepotTests {
  static let posthog = "PostHog/posthog"
  /// The branch of PostHog/posthog#122953, which fires no PR rule.
  static let branch = "haacked/cdp-dlq-breaker-counts-lookups"
  static let number = 122953
  static let readTheReply = "read its last reply and decide what's next"
  static let fixReason = "fix Depot CI on #122953: Django Tests Pass on Depot and 2 more"
  static let failedOutcome =
    "Depot CI failed: \(FakeDepot.failedJobs[0]) and 2 more (run \(FakeDepot.failedRun))"

  /// Gives #122953 the head commit of the failed Depot run, with checks that
  /// still run, as GitHub shows while other checks haven't finished.
  func failingPR(_ github: FakeGitHub, _ depot: FakeDepot) throws {
    github.change(DepotTests.number) { $0["headRefOid"] = .string(FakeDepot.failedHead) }
    github.checks(DepotTests.number, "PENDING")
    try depot.useRecordedRuns(for: DepotTests.posthog, DepotTests.number)
  }

  func session(_ sbd: Instance) throws -> SessionSummary {
    try sbd.session(in: DepotTests.posthog, branch: DepotTests.branch)
  }

  func resumed(_ sbd: Instance, _ s: SessionSummary, with message: String) throws {
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: Switchboard: \(message)" }
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func sessionsOpenPRShowsItsDepotRun() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot, settings: ["org": "org-1"])
    try failingPR(github, depot)
    let s = try session(sbd)

    let result = try sbd.poll()

    #expect(result["depotRequests"]?.int == 2)
    #expect(result["depotRuns"]?.int == 1)
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "failed")
    #expect(
      try sbd.depotLine(s.id) == "failed, 9 jobs, 3 failed: Django Tests Pass on Depot and 2 more (run jtrfd10d8p)")
    let recorded = try #require(try sbd.recordedDepot(s.id))
    #expect(recorded.id == FakeDepot.failedRun)
    #expect(recorded.headSha == FakeDepot.failedHead)
    #expect(recorded.failed.map(\.name) == FakeDepot.failedJobs)
    #expect(recorded.failed.first?.url == "https://depot.dev/orgs/ntsdt08fpt/workflows/05ktvf2pd7?job=v669r36tlh")
  }

  @Test func depotRequestsNameThePRAndCarryTheTokenAndOrganization() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot, settings: ["org": "org-1"])
    try failingPR(github, depot)
    _ = try session(sbd)

    try sbd.poll()

    #expect(depot.requests.map(\.method) == ["ListRuns", "GetRunStatus"])
    let list = try #require(depot.requests("ListRuns").first)
    #expect(list.body["repo"]?.string == DepotTests.posthog)
    #expect(list.body["pr"]?.string == "122953" || list.body["pr"]?.int == 122953)
    #expect(
      Set(list.body["status"]?.array?.compactMap(\.string) ?? [])
        == ["queued", "running", "finished", "failed", "cancelled"])
    #expect(depot.requests("GetRunStatus").first?.body["runId"]?.string == FakeDepot.failedRun)
    #expect(depot.requests.allSatisfy { $0.authorization == "Bearer depot-token-1" && $0.org == "org-1" })
  }

  @Test func failedDepotJobMovesAnIdleSessionToNeedsYou() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    try depot.setStatus(FakeDepot.failedRun, from: "depot-status-running.json")
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.get(s.id).reason == DepotTests.readTheReply)

    try depot.setStatus(FakeDepot.failedRun, from: "depot-status-failed.json")
    try sbd.poll()

    let after = try sbd.get(s.id)
    #expect(after.state == .needsYou)
    #expect(after.reason == DepotTests.fixReason)
  }

  /// Trunk queues a PR only after its required checks pass, so a failed
  /// Depot job on a queued PR is one that isn't required.
  @Test func failedDepotJobOnAPRInTrunksQueueLeavesTheSessionsReason() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    github.checks(DepotTests.number, "FAILURE")
    github.edit(
      comment: try github.trunkComment(DepotTests.number), body: "Testing in the queue", at: "2026-10-26T00:00:00Z")
    let s = try session(sbd)

    try sbd.poll()

    let after = try sbd.get(s.id)
    #expect(after.pr?.queue?.isQueued == true)
    #expect(after.pr?.depot?.status == "failed")
    #expect(after.reason == DepotTests.readTheReply)
  }

  @Test func aCIWaitResumesTheSessionWhenADepotJobFailsWhileTheRollupIsPending() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    try depot.setStatus(FakeDepot.failedRun, from: "depot-status-running.json")
    let s = try session(sbd)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "ci")
    #expect(try sbd.poll()["resolved"]?.int == 0)

    try depot.setStatus(FakeDepot.failedRun, from: "depot-status-failed.json")

    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "CI on the session's PR: \(DepotTests.failedOutcome).")
  }

  /// More jobs can fail between the two reads. Both reads say failed on the
  /// same head commit, so they agree. The second read's wording wins.
  @Test func aCIWaitResolvesWithTheSecondReadsWordingWhenMoreJobsFail() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    try depot.setStatus(FakeDepot.failedRun, from: "depot-status-running.json")
    let s = try session(sbd)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "ci")
    try depot.setStatus(FakeDepot.failedRun, from: "depot-status-failed.json", status: "running") { job in
      if job["jobDisplayName"]?.string != FakeDepot.failedJobs[0], job["status"]?.string == "failed" {
        job["status"] = "running"
      }
    }
    #expect(try sbd.poll()["resolved"]?.int == 0)

    try depot.setStatus(FakeDepot.failedRun, from: "depot-status-failed.json")

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "CI on the session's PR: \(DepotTests.failedOutcome).")
  }

  @Test func aDepotRunOnAnOlderHeadCommitNeitherShowsNorResolvesTheWait() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.depotShown(s.id) != nil)

    github.change(DepotTests.number) { $0["headRefOid"] = "pushed-commit" }
    try sbd.sb("wait", s.id, "--kind", "ci")

    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 0)
    let after = try sbd.get(s.id)
    #expect(after.waits.count == 1)
    #expect(try sbd.depotShown(s.id) == nil)
    #expect(try sbd.depotLine(s.id) == nil)
    #expect(!after.reason.contains("Depot"))
  }

  @Test func aRunningRunIsAskedAgainAtTheNextPollAndAFinishedOneIsNot() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    let head = try #require(github.pr(DepotTests.number)["headRefOid"]?.string)
    depot.addRun(DepotTests.posthog, DepotTests.number, id: FakeDepot.runningRun, headSha: head)
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "running")
    func statusReads() -> Int { depot.requests("GetRunStatus").count }

    try sbd.poll()
    #expect(statusReads() == 2)

    try depot.setStatus(FakeDepot.runningRun, from: "depot-status-running.json", status: "finished") {
      $0["status"] = "finished"
    }
    try sbd.poll()
    #expect(statusReads() == 3)
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "finished")

    let asked = depot.requests.count
    #expect(try sbd.poll()["depotRequests"]?.int == 0)
    #expect(depot.requests.count == asked)

    #expect(try sbd.poll(all: true)["depotRequests"]?.int == 1)
    #expect(depot.requests("ListRuns").count == 2)

    // A retry lists the finished run as running again, so its status is read again.
    try depot.setStatus(FakeDepot.runningRun, from: "depot-status-running.json", status: "running")
    #expect(try sbd.poll(all: true)["depotRequests"]?.int == 2)
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "running")
  }

  @Test func a401FromDepotPutsADepotErrorInThePollAndLeavesGitHubWorking() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot(token: "depot-token-1")
    let sbd = try Instance.withDepot(github, depot, token: "revoked-token")
    try failingPR(github, depot)
    let s = try session(sbd)

    let run = try sbd.run("poll", "--json")

    let result = try #require(JSON.parse(run.stdout))
    let error = try #require(result["depotError"]?.string)
    #expect(error.contains("depot: "))
    #expect(error.contains("depot login"))
    #expect(result["polled"]?.int == 1)
    #expect(depot.requests.first?.authorization == "Bearer revoked-token")
    let after = try sbd.get(s.id)
    #expect(after.pr?.number == DepotTests.number)
    #expect(after.reason == DepotTests.readTheReply)
    #expect(try String(contentsOfFile: sbd.home.log, encoding: .utf8).contains("depot: "))
  }

  /// A 401 drops the cached token, so a `depot login` takes effect without a restart.
  @Test func aNewDepotLoginAfterA401IsUsedAtTheNextPoll() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot(token: "new-token")
    let sbd = try Instance.withDepot(github, depot, token: nil)
    sbd.sbdEnvironment["DEPOT_TOKEN"] = ""
    let config = "\(sbd.home.path)/depot.yaml"
    try "api_token: old-token\n".write(toFile: config, atomically: true, encoding: .utf8)
    try sbd.restart(setting: "depot", to: ["url": .string(depot.url), "config": .string(config)])
    try failingPR(github, depot)
    let s = try session(sbd)

    let revoked = try sbd.poll()

    #expect(revoked["depotError"]?.string?.contains("depot login") == true)
    #expect(depot.requests.last?.authorization == "Bearer old-token")

    try "api_token: new-token\n".write(toFile: config, atomically: true, encoding: .utf8)
    let renewed = try sbd.poll()

    #expect(renewed["depotError"] == nil)
    #expect(depot.requests.last?.authorization == "Bearer new-token")
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "failed")
  }

  /// The first failed Depot request ends the poll's Depot reads, so an
  /// unreachable Depot costs one timeout per poll rather than one per PR.
  @Test func aFailedDepotRequestEndsThePollsDepotReads() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    _ = try session(sbd)
    _ = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    depot.reply(503, #"{"code":"unavailable","message":"try again"}"#)

    let failed = try sbd.poll(all: true)

    #expect(failed["depotRequests"]?.int == 1)
    #expect(failed["depotError"] != nil)
    let next = try sbd.poll(all: true)
    #expect(next["depotError"] == nil)
    #expect((next["depotRequests"]?.int ?? 0) >= 2)
  }

  @Test func depotTokenComesFromTheDepotCLIsConfigAndWithoutOneThePollReportsIt() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot(token: "cli-token")
    let sbd = try Instance.withDepot(github, depot, token: nil)
    // An empty DEPOT_TOKEN keeps the runner's own token out of sbd.
    sbd.sbdEnvironment["DEPOT_TOKEN"] = ""
    sbd.stopSbd()
    try sbd.startSbd()
    try failingPR(github, depot)
    let s = try session(sbd)

    let missing = try sbd.poll()

    #expect(missing["depotError"]?.string?.contains("depot: ") == true)
    #expect(missing["polled"]?.int == 1)
    #expect(depot.requests.isEmpty)

    let config = "\(sbd.home.path)/depot.yaml"
    try "api_token: cli-token\norg_id: cli-org\n".write(toFile: config, atomically: true, encoding: .utf8)
    try sbd.restart(setting: "depot", to: ["url": .string(depot.url), "config": .string(config)])
    let found = try sbd.poll()

    #expect(found["depotError"] == nil)
    #expect(!depot.requests.isEmpty)
    #expect(depot.requests.allSatisfy { $0.authorization == "Bearer cli-token" && $0.org == "cli-org" })
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "failed")
  }

  @Test func aRepoWithNoDepotRunsIsAskedOnceUntilTheIdleInterval() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    let s = try session(sbd)

    let first = try sbd.poll()

    #expect(first["depotRequests"]?.int == 1)
    #expect(first["depotError"] == nil)
    #expect(depot.requests.map(\.method) == ["ListRuns"])
    #expect(try sbd.depotShown(s.id) == nil)
    #expect(try sbd.poll()["depotRequests"]?.int == 0)
    try sbd.advanceClock(300_000)
    #expect(try sbd.poll()["depotRequests"]?.int == 1)
  }

  /// A GitHub read keeps the Depot state, and a failed Depot request keeps it too.
  @Test func aFailedDepotRequestKeepsTheLastDepotStateAndAsksAgain() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    let s = try session(sbd)
    try sbd.poll()
    github.change(DepotTests.number) { $0["title"] = "a new title" }
    depot.reply(503, #"{"code":"unavailable","message":"try again"}"#)

    try sbd.poll(all: true)

    #expect(try sbd.events(s.id).last { $0.kind == "pr" }?.data["pr"]?["title"]?.string == "a new title")
    #expect(try sbd.recordedDepot(s.id)?.id == FakeDepot.failedRun)
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "failed")
    #expect(try sbd.get(s.id).reason == DepotTests.fixReason)
    let asked = depot.requests.count
    try sbd.poll()
    #expect(depot.requests.count > asked)
  }

  @Test func depotStateSurvivesARestartOfSbd() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot)
    try failingPR(github, depot)
    let s = try session(sbd)
    try sbd.poll()

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.depotShown(s.id)?["status"]?.string == "failed")
    #expect(try sbd.get(s.id).reason == DepotTests.fixReason)
    // The first read after the restart fails, so only the event log holds the run.
    depot.reply(503, #"{"code":"unavailable","message":"try again"}"#)
    try sbd.poll(all: true)
    #expect(try sbd.depotShown(s.id)?["status"]?.string == "failed")
    #expect(try sbd.get(s.id).reason == DepotTests.fixReason)
  }

  @Test func disabledDepotPollerAsksNothing() throws {
    let github = try FakeGitHub()
    let depot = try FakeDepot()
    let sbd = try Instance.withDepot(github, depot, settings: ["enabled": false])
    try failingPR(github, depot)
    let s = try session(sbd)

    let result = try sbd.poll(all: true)

    #expect(result["depotError"] == nil)
    #expect(depot.requests.isEmpty)
    #expect(try sbd.depotShown(s.id) == nil)
  }
}
