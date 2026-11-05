import Foundation
import SwitchboardCore
import Testing

extension FakeGitHub {
  /// Makes the PR one that waits on a review from `reviewers`: mergeable, its
  /// checks passed, no verdict, and GitHub requires a review. With no
  /// reviewers, GitHub asks nobody, so the session needs the user.
  fileprivate func awaitReview(_ number: Int, draft: Bool, from reviewers: [String] = ["alice"]) {
    let requested = reviewers.map { login -> JSON in
      ["requestedReviewer": ["__typename": "User", "login": .string(login)]]
    }
    change(number) {
      $0["isDraft"] = .bool(draft)
      $0["mergeable"] = "MERGEABLE"
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
      $0["reviewRequests"] = ["nodes": .array(requested)]
    }
    checks(number, "SUCCESS")
  }

  fileprivate func setDraft(_ number: Int, _ draft: Bool) {
    change(number) { $0["isDraft"] = .bool(draft) }
  }
}

extension Instance {
  /// The rows of `sb ls --json`.
  fileprivate func listJSON() throws -> [JSON] {
    try #require(JSON.parse(try sb("ls", "--json"))?.array)
  }

  /// The time of the session's last `pr` event.
  fileprivate func lastPREvent(_ id: String) throws -> Int64 {
    try #require(try events(id).last { $0.kind == "pr" }).t
  }
}

/// A session whose PR is open and not a draft, and that waits on other
/// people, is in Ready for review.
@Suite(.blocking(timeLimit: .seconds(120))) struct ReadyForReviewTests {
  static let charts = "PostHog/charts"
  /// The head branch of PostHog/charts#18303. The fixture records it as open,
  /// mergeable, and approved, so each test first makes it wait on a review.
  static let branch = "haacked/cdp-dlq-runbook-lookup-step"
  static let number = 18303
  static let docs = "PostHog/posthog.com"
  static let docsBranch = "haacked/flag-calls-move-docs"
  static let docsNumber = 20992
  static let hour: Int64 = 3_600_000

  /// A session on #18303's branch whose PR waits on a review from
  /// `reviewers`, which the poller has read.
  func session(
    _ github: FakeGitHub, _ sbd: Instance, draft: Bool, from reviewers: [String] = ["alice"]
  ) throws -> SessionSummary {
    github.awaitReview(Self.number, draft: draft, from: reviewers)
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    try sbd.poll()
    return s
  }

  func markReady(_ github: FakeGitHub, _ sbd: Instance, _ number: Int = Self.number) throws {
    github.setDraft(number, false)
    try sbd.poll(all: true)
  }

  @Test func draftPRsSessionIsNotReadyForReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: true)

    let got = try sbd.getJSON(s.id)

    #expect(got["state"]?.string != "ready_for_review")
  }

  @Test func markingThePRReadyMovesTheSessionIn() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: true)

    try markReady(github, sbd)

    #expect(try sbd.getJSON(s.id)["state"]?.string == "ready_for_review")
  }

  @Test func sbGetAndSbLsShowReadyForReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: false)

    let printed = try sbd.sb("get", s.id)
    let lines = try sbd.sb("ls").split(separator: "\n").map(String.init)

    #expect(printed.contains("state:   Ready for review: #18303 "))
    #expect(lines.contains("Ready for review"))
  }

  @Test func reasonNamesThePRTheReviewerAndTheChecks() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.change(Self.number) { $0["title"] = "Fix" }
    let s = try session(github, sbd, draft: false)

    let got = try sbd.get(s.id)

    #expect(got.reason == "#18303 Fix; review requested from alice, checks success")
  }

  @Test func sessionInReadyForReviewIsNotInTheInbox() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: false)

    let inbox = try sbd.triage()

    #expect(try sbd.get(s.id).state == .readyForReview)
    #expect(!inbox.contains { $0.id == s.id })
  }

  @Test(arguments: [("isDraft", JSON.bool(true)), ("state", "MERGED"), ("state", "CLOSED")])
  func unreadyPRMovesTheSessionOut(_ field: String, _ value: JSON) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: false)
    #expect(try sbd.get(s.id).state == .readyForReview)

    github.change(Self.number) { $0[field] = value }
    try sbd.poll(all: true)

    #expect(try sbd.getJSON(s.id)["state"]?.string != "ready_for_review")
  }

  @Test func sessionWhoseLastReplyAsksAQuestionStaysInNeedsYou() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.awaitReview(Self.number, draft: false)
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    try sbd.sb("send", s.id, "Which base should it target?")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: Which base should it target?" }

    try sbd.poll()

    #expect(try sbd.getJSON(s.id)["state"]?.string == "needs_you")
  }

  @Test func sinceIsTheTimeOfThePollThatFirstSawThePRReady() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: true)
    let before = try sbd.now()
    try markReady(github, sbd)
    let after = try sbd.now()
    let ready = try sbd.lastPREvent(s.id)
    try sbd.advanceClock(Self.hour)
    github.change(Self.number) { $0["title"] = "a new title" }
    try sbd.poll(all: true)

    let got = try sbd.get(s.id)

    #expect(try sbd.lastPREvent(s.id) > ready)
    #expect(got.state == .readyForReview)
    #expect(got.since == ready)
    #expect((before...after).contains(got.since))
  }

  /// The PR was ready an hour before GitHub asked for a review, so the
  /// session entered the column an hour after its PR became ready.
  @Test func sinceIsWhenThePRBecameReadyNotWhenTheSessionEnteredTheColumn() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: false, from: [])
    let ready = try sbd.lastPREvent(s.id)
    #expect(try sbd.get(s.id).state == .needsYou)
    try sbd.advanceClock(Self.hour)
    github.awaitReview(Self.number, draft: false, from: ["alice"])
    try sbd.poll(all: true)

    let got = try sbd.get(s.id)

    #expect(got.state == .readyForReview)
    #expect(got.since == ready)
  }

  @Test func readyAgainAfterADraftCountsFromThePollThatSawItReadyAgain() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: false)
    let first = try sbd.lastPREvent(s.id)
    try sbd.advanceClock(Self.hour)
    github.setDraft(Self.number, true)
    try sbd.poll(all: true)
    try sbd.advanceClock(Self.hour)
    try markReady(github, sbd)
    let again = try sbd.lastPREvent(s.id)

    let got = try sbd.get(s.id)

    #expect(again > first)
    #expect(got.state == .readyForReview)
    #expect(got.since == again)
  }

  /// The docs session's PR became ready first, while nobody was asked to
  /// review it. It enters the column last, so an order by the time a session
  /// entered the column would list it second.
  @Test func longestReadySessionListsFirst() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.awaitReview(Self.number, draft: true)
    github.awaitReview(Self.docsNumber, draft: false, from: [])
    let charts = try sbd.session(in: Self.charts, branch: Self.branch)
    let docs = try sbd.session(in: Self.docs, branch: Self.docsBranch)
    try sbd.poll()
    try sbd.advanceClock(Self.hour)
    try markReady(github, sbd)
    try sbd.advanceClock(Self.hour)
    github.awaitReview(Self.docsNumber, draft: false, from: ["bob"])
    try sbd.poll(all: true)

    let rows = try sbd.listJSON().filter { $0["state"]?.string == "ready_for_review" }

    #expect(rows.compactMap { $0["id"]?.string } == [docs.id, charts.id])
  }

  @Test func lsAndGetCarryThePRsReviewRequests() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, draft: false, from: ["alice", "bob"])

    let row = try #require(try sbd.listJSON().first { $0["id"]?.string == s.id })
    let got = try sbd.getJSON(s.id)

    #expect(row["pr"]?["reviewRequests"] == ["alice", "bob"])
    #expect(got["pr"]?["reviewRequests"] == ["alice", "bob"])
  }
}
