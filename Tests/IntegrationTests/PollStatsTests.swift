import Foundation
import SwitchboardCore
import Testing

/// The reads, requests, and points of one trigger and owner of `sb poll --stats --json`.
private struct Share: Equatable {
  var reads = 0
  var requests = 0.0
  var points = 0.0
}

extension Instance {
  /// The report of `sb poll --stats --json`, which must have the totals and the reads.
  fileprivate func pollStats() throws -> JSON {
    let output = try sb("poll", "--stats", "--json")
    let stats = try #require(JSON.parse(output), "sb poll --stats --json printed \(output)")
    _ = try #require(stats["requests"]?.int, "sb poll --stats --json has no requests: \(output)")
    _ = try #require(stats["reads"]?.object, "sb poll --stats --json has no reads: \(output)")
    return stats
  }
}

/// The share of `stats` for `trigger` and `owner`. A missing share counts nothing.
private func share(_ stats: JSON, _ trigger: String, _ owner: String) -> Share {
  guard let s = stats["reads"]?[trigger]?[owner] else { return Share() }
  return Share(reads: s["reads"]?.int ?? 0, requests: s["requests"]?.double ?? 0, points: s["points"]?.double ?? 0)
}

/// Every share of `stats`, keyed by trigger/owner.
private func shares(_ stats: JSON) -> [String: Share] {
  var all: [String: Share] = [:]
  for (trigger, owners) in stats["reads"]?.object ?? [:] {
    for owner in (owners.object ?? [:]).keys { all["\(trigger)/\(owner)"] = share(stats, trigger, owner) }
  }
  return all
}

private func total(_ stats: JSON, _ key: String) -> Int { stats[key]?.int ?? 0 }

/// The PRs whose reads a test checks: the number in FakeGitHub's fixtures, and
/// the owner, lowercased, that the stats name.
struct StatsPR: Sendable, CustomStringConvertible {
  var repo: String
  var branch: String
  var number: Int
  var owner: String
  var description: String { "\(repo)#\(number)" }

  static let haacked = StatsPR(
    repo: "haacked/review-code", branch: "haacked/better-hogql-reviews", number: 189, owner: "haacked")
  static let charts = StatsPR(
    repo: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step", number: 18303, owner: "posthog")
}

/// What FakeGitHub saw from a mark on.
private struct Seen {
  var graphQL: [FakeGitHub.Request]
  var rest: Int

  /// The status, merged-base, and comment-body requests, which the stats split among the PRs they served.
  var split: Int { graphQL.filter { ["status", "base", "bodies"].contains($0.kind) }.count }

  /// How many times the status requests read the PR with node id `id`.
  func statusReads(of id: String) -> Int {
    graphQL.filter { $0.kind == "status" }.flatMap(\.ids).filter { $0 == id }.count
  }
}

extension FakeGitHub {
  fileprivate var mark: (Int, Int) { (requests.count, restRequestsWithoutEvents.count) }

  fileprivate func seen(since mark: (Int, Int)) -> Seen {
    Seen(graphQL: Array(requests.dropFirst(mark.0)), rest: restRequestsWithoutEvents.count - mark.1)
  }

  fileprivate func nodeId(_ number: Int) throws -> String { try #require(pr(number)["id"]?.string) }
}

/// sbd counts every GitHub request and GraphQL point, and splits the PR reads
/// by why the poller read each PR and by the owner of its repo. `sb poll
/// --stats` reports the counts without asking GitHub.
@Suite(.blocking(timeLimit: .seconds(120))) struct PollStatsTests {
  @Test(arguments: [StatsPR.haacked, StatsPR.charts])
  func sbPollAllCountsEachPRReadUnderPollAndItsOwner(_ w: StatsPR) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: w.repo, branch: w.branch)
    let before = try sbd.pollStats()
    let mark = github.mark

    try sbd.poll(all: true)

    let after = try sbd.pollStats()
    let reads = share(after, "poll", w.owner).reads - share(before, "poll", w.owner).reads
    #expect(reads == github.seen(since: mark).statusReads(of: try github.nodeId(w.number)))
    #expect(reads > 0)
  }

  @Test func theOwnerIsLowercased() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: StatsPR.charts.repo, branch: StatsPR.charts.branch)

    try sbd.poll(all: true)

    #expect(try sbd.pollStats()["reads"]?["poll"]?.object.map { Set($0.keys) } == ["posthog"])
  }

  @Test(arguments: [StatsPR.haacked, StatsPR.charts])
  func sbPollAllLeavesTheOtherTriggersUnchanged(_ w: StatsPR) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: w.repo, branch: w.branch)
    let before = try sbd.pollStats()

    try sbd.poll(all: true)

    let after = try sbd.pollStats()
    #expect(shares(after).filter { !$0.key.hasPrefix("poll/") } == shares(before).filter { !$0.key.hasPrefix("poll/") })
  }

  /// One status request reads both PRs, so each owner gets half of its cost.
  @Test func aPollOfTwoOwnersCountsEachOwnersReads() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: StatsPR.haacked.repo, branch: StatsPR.haacked.branch)
    _ = try sbd.session(in: StatsPR.charts.repo, branch: StatsPR.charts.branch)
    let mark = github.mark

    try sbd.poll(all: true)

    let seen = github.seen(since: mark)
    let after = try sbd.pollStats()
    #expect(share(after, "poll", "haacked").reads == seen.statusReads(of: try github.nodeId(StatsPR.haacked.number)))
    #expect(share(after, "poll", "posthog").reads == seen.statusReads(of: try github.nodeId(StatsPR.charts.number)))
  }

  /// No status, merged-base, or body request is lost or counted twice among the PRs it served.
  @Test(arguments: [[StatsPR.haacked], [StatsPR.charts], [StatsPR.haacked, StatsPR.charts]])
  func theSharesAddUpToTheRequestsThatReadPRs(_ watched: [StatsPR]) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    for w in watched { _ = try sbd.session(in: w.repo, branch: w.branch) }
    let before = shares(try sbd.pollStats()).values.map(\.requests).reduce(0, +)
    let mark = github.mark

    try sbd.poll(all: true)

    let after = shares(try sbd.pollStats()).values.map(\.requests).reduce(0, +)
    let split = github.seen(since: mark).split
    #expect(abs(after - before - Double(split)) < 1e-9, "the shares grew by \(after - before), not \(split)")
    #expect(split > 0)
  }

  /// A stacked PR's merged-base request counts among the shares.
  @Test func theSharesAddUpWhenAStackedPRReadsItsMergedBase() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.change(StatsPR.charts.number) {
      $0["baseRefName"] = "haacked/stacked-base"
      $0["baseRef"] = ["associatedPullRequests": ["nodes": []]]
    }
    _ = try sbd.session(in: StatsPR.charts.repo, branch: StatsPR.charts.branch)
    let before = shares(try sbd.pollStats()).values.map(\.requests).reduce(0, +)
    let mark = github.mark

    try sbd.poll(all: true)

    let after = shares(try sbd.pollStats()).values.map(\.requests).reduce(0, +)
    let seen = github.seen(since: mark)
    #expect(seen.graphQL.contains { $0.kind == "base" })
    #expect(abs(after - before - Double(seen.split)) < 1e-9, "the shares grew by \(after - before), not \(seen.split)")
  }

  /// A sbd without the Event Streams provider. The totals count the provider's requests, which it sends on its own
  /// schedule, so a test that compares totals turns it off.
  private func withoutEvents(_ github: FakeGitHub) throws -> Instance {
    try Instance.withGitHub(github, events: "off")
  }

  @Test(arguments: [StatsPR.haacked, StatsPR.charts])
  func theTotalsCountEveryRequestGitHubSaw(_ w: StatsPR) throws {
    let github = try FakeGitHub()
    let sbd = try withoutEvents(github)
    _ = try sbd.session(in: w.repo, branch: w.branch)
    let before = try sbd.pollStats()
    let mark = github.mark

    try sbd.poll(all: true)

    let seen = github.seen(since: mark)
    #expect(total(try sbd.pollStats(), "requests") - total(before, "requests") == seen.graphQL.count + seen.rest)
  }

  @Test func theTotalsMatchWhatEachPollReported() throws {
    let github = try FakeGitHub()
    let sbd = try withoutEvents(github)
    _ = try sbd.session(in: StatsPR.charts.repo, branch: StatsPR.charts.branch)
    let before = try sbd.pollStats()

    let first = try sbd.poll(all: true)
    let second = try sbd.poll(all: true)

    let after = try sbd.pollStats()
    let requests = try #require(first["requests"]?.int) + (try #require(second["requests"]?.int))
    let points = try #require(first["points"]?.int) + (try #require(second["points"]?.int))
    #expect(total(after, "requests") - total(before, "requests") == requests)
    #expect(total(after, "points") - total(before, "points") == points)
  }

  @Test func aPlainSbPollCountsAPRThatWasNeverReadUnderFirst() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: StatsPR.haacked.repo, branch: StatsPR.haacked.branch)

    try sbd.poll()

    let stats = try sbd.pollStats()
    #expect(share(stats, "first", "haacked").reads == 1)
    #expect(share(stats, "poll", "haacked") == Share())
  }

  @Test func aPlainSbPollReadsNothingNewWhenNoPRIsDue() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: StatsPR.haacked.repo, branch: StatsPR.haacked.branch)
    try sbd.poll()
    let before = try sbd.pollStats()

    try sbd.poll()

    #expect(shares(try sbd.pollStats()) == shares(before))
  }

  @Test func aNewWaitCountsItsPRsReadUnderWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: StatsPR.charts.repo, branch: StatsPR.charts.branch)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "merge")
    let before = share(try sbd.pollStats(), "wait", "posthog")

    try sbd.poll()

    #expect(share(try sbd.pollStats(), "wait", "posthog").reads == before.reads + 1)
  }

  /// `send` counts a status request that GitHub fails in the totals, so the split counts it too.
  @Test func aFailedStatusRequestStillCountsUnderItsTrigger() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: StatsPR.charts.repo, branch: StatsPR.charts.branch)
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "merge")
    let before = share(try sbd.pollStats(), "wait", "posthog")
    let mark = github.mark
    github.reply(500, #"{"message":"Server Error"}"#)

    try sbd.poll()

    let after = share(try sbd.pollStats(), "wait", "posthog")
    #expect(github.seen(since: mark).graphQL.first?.kind == "status")
    #expect(after.requests == before.requests + 1)
    #expect(after.reads == before.reads)
  }

  @Test func statsDoNotAskGitHub() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: StatsPR.haacked.repo, branch: StatsPR.haacked.branch)
    try sbd.poll(all: true)
    let mark = github.mark

    _ = try sbd.pollStats()
    _ = try sbd.sb("poll", "--stats")

    let seen = github.seen(since: mark)
    #expect(seen.graphQL.isEmpty)
    #expect(seen.rest == 0)
  }

  @Test func statsDoNotChangeTheCounts() throws {
    let github = try FakeGitHub()
    let sbd = try withoutEvents(github)
    _ = try sbd.session(in: StatsPR.haacked.repo, branch: StatsPR.haacked.branch)
    try sbd.poll(all: true)

    let first = try sbd.pollStats()
    let second = try sbd.pollStats()

    #expect(total(second, "requests") == total(first, "requests"))
    #expect(total(second, "points") == total(first, "points"))
    #expect(shares(second) == shares(first))
  }

  @Test func statsGiveFiniteRatesAnHour() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: StatsPR.haacked.repo, branch: StatsPR.haacked.branch)
    try sbd.poll(all: true)

    let stats = try sbd.pollStats()

    var rates = [("total", stats)]
    for (trigger, owners) in stats["reads"]?.object ?? [:] {
      for (owner, s) in owners.object ?? [:] { rates.append(("\(trigger)/\(owner)", s)) }
    }
    #expect(rates.count > 1)
    for (name, s) in rates {
      for key in ["requestsPerHour", "pointsPerHour"] {
        let rate = try #require(s[key]?.double, "\(name) has no \(key)")
        #expect(rate.isFinite && rate >= 0, "\(name) \(key) is \(rate)")
      }
    }
  }

  @Test func statsBeforeAnyPollCountNothing() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)

    let stats = try sbd.pollStats()

    #expect(total(stats, "requests") == 0)
    #expect(total(stats, "points") == 0)
    #expect(shares(stats).isEmpty)
    #expect(github.requests.isEmpty)
  }

  @Test func statsWithoutJSONPrintEachTriggerAndOwner() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: StatsPR.haacked.repo, branch: StatsPR.haacked.branch)
    try sbd.poll(all: true)

    let text = try sbd.sb("poll", "--stats")

    #expect(text.contains("poll haacked: 1 reads"))
  }
}
