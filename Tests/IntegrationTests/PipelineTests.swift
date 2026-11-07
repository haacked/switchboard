import Foundation
import SwitchboardCore
import Testing

extension FakeGitHub {
  /// Makes the PR wait on a review from alice, with mergeable code, no
  /// verdict, and checks in `checks`.
  fileprivate func awaitAlice(_ number: Int, checks: String) {
    change(number) {
      $0["isDraft"] = false
      $0["mergeable"] = "MERGEABLE"
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
      $0["reviewRequests"] = ["nodes": [["requestedReviewer": ["__typename": "User", "login": "alice"]]]]
    }
    self.checks(number, checks)
  }
}

extension Instance {
  /// The line of `sb get` that shows the session's pipeline stage.
  fileprivate func stageLine(_ id: String) throws -> String {
    let lines = try sb("get", id).split(separator: "\n").map(String.init)
    return try #require(lines.first { $0.hasPrefix("  stage:") })
  }
}

/// sbd computes each work session's pipeline stage and shows it in `sb ls`
/// and `sb get`.
@Suite(.blocking(timeLimit: .seconds(120))) struct PipelineTests {
  static let charts = "PostHog/charts"
  /// The head branch of PostHog/charts#18303. The fixture records it as
  /// open, mergeable, approved, and with checks that passed.
  static let branch = "haacked/cdp-dlq-runbook-lookup-step"
  static let number = 18303

  /// A session on #18303's branch whose PR waits on alice's review while its
  /// checks are in `checks`.
  func reviewSession(_ github: FakeGitHub, _ sbd: Instance, checks: String) throws -> SessionSummary {
    github.awaitAlice(Self.number, checks: checks)
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    try sbd.poll()
    return s
  }

  @Test func runningChecksPutTheSessionInCI() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "PENDING")

    let row = try sbd.listed(s.id)

    #expect(row["pipeline"]?["stage"]?.string == "ci")
  }

  @Test func passingChecksMoveTheSessionFromCIToReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "PENDING")
    try #require(try sbd.listed(s.id)["pipeline"]?["stage"]?.string == "ci")

    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)

    #expect(try sbd.listed(s.id)["pipeline"]?["stage"]?.string == "review")
  }

  @Test func moveToReviewRestartsTheStageTime() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "PENDING")
    let ciSince = try #require(try sbd.listed(s.id)["pipeline"]?["since"]?.int)
    try sbd.advanceClock(60_000)

    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)

    #expect(try #require(try sbd.listed(s.id)["pipeline"]?["since"]?.int) > ciSince)
  }

  @Test func conflictingPRIsBlockedByTheConflictWithItsBase() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    try sbd.poll()

    github.change(Self.number) { $0["mergeable"] = "CONFLICTING" }
    try sbd.poll(all: true)

    #expect(try sbd.listed(s.id)["pipeline"]?["blocker"]?.string == "conflicts with main")
  }

  @Test func conflictLeavesTheApprovedPRReady() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    try sbd.poll()

    github.change(Self.number) { $0["mergeable"] = "CONFLICTING" }
    try sbd.poll(all: true)

    #expect(try sbd.getJSON(s.id)["pipeline"]?["stage"]?.string == "ready")
  }

  @Test func prWithNothingInTheWayHasNoBlocker() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "SUCCESS")

    let pipeline = try #require(try sbd.getJSON(s.id)["pipeline"])

    try #require(pipeline["stage"]?.string == "review")
    #expect(pipeline.object?["blocker"] == nil)
  }

  @Test func sbGetPrintsTheStageAndItsAge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "PENDING")

    let line = try sbd.stageLine(s.id)

    #expect(line.wholeMatch(of: try Regex(#"  stage:   CI \d+[smhd]"#)) != nil, "\(line)")
  }

  @Test func sbGetPrintsTheBlockerAfterTheStage() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    try sbd.poll()
    github.change(Self.number) { $0["mergeable"] = "CONFLICTING" }
    try sbd.poll(all: true)

    let line = try sbd.stageLine(s.id)

    #expect(line.wholeMatch(of: try Regex(#"  stage:   Ready \d+[smhd]; conflicts with main"#)) != nil, "\(line)")
  }

  @Test func workSessionWithoutAPRIsBuilding() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")

    #expect(try sbd.listed(s.id)["pipeline"]?["stage"]?.string == "building")
  }

  @Test func workSessionWithoutAPRCountsFromItsCreation() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")

    let row = try sbd.listed(s.id)

    let created = try #require(row["created"]?.int)
    #expect(row["pipeline"]?["since"]?.int == created)
  }

  /// The work session shows that the field is there to leave out, so a
  /// renamed key cannot pass the tests below.
  func workSessionWithAPipeline(_ sbd: Instance) throws {
    let s = try sbd.new(prompt: "hello")
    try #require(try sbd.listed(s.id)["pipeline"]?.object != nil)
  }

  @Test func managerHasNoPipelineInSbLs() throws {
    let sbd = try Instance()
    try workSessionWithAPipeline(sbd)
    let manager = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("manager", "--json"))

    #expect(try sbd.listed(manager.id).object?["pipeline"] == nil)
  }

  @Test func managerHasNoPipelineInSbGet() throws {
    let sbd = try Instance()
    try workSessionWithAPipeline(sbd)
    let manager = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("manager", "--json"))

    #expect(try sbd.getJSON(manager.id).object?["pipeline"] == nil)
  }

  @Test func groupChatHasNoPipeline() throws {
    let sbd = try Instance()
    try workSessionWithAPipeline(sbd)
    try sbd.sb("group", "add", "--json", "Flags")
    let chat = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("chat", "Flags", "--json"))

    #expect(try sbd.listed(chat.id).object?["pipeline"] == nil)
  }
}
