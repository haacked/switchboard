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

  /// Sets the PR's reviewDecision. JSON null is GitHub's answer for a base
  /// branch that requires no review. nil drops the key, so the poll does not
  /// read it.
  fileprivate func decide(_ number: Int, _ decision: JSON?) {
    change(number) { $0["reviewDecision"] = decision }
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
@Suite(.timeLimit(.minutes(2))) struct ReadyForReviewTests {
  static let charts = "PostHog/charts"
  /// The head branch of PostHog/charts#18303. The fixture records it as open,
  /// mergeable, and approved, so each test first makes it wait on a review.
  static let branch = "haacked/cdp-dlq-runbook-lookup-step"
  static let number = 18303
  static let docs = "PostHog/posthog.com"
  static let docsBranch = "haacked/flag-calls-move-docs"
  static let docsNumber = 20992
  static let hour: Int64 = 3_600_000
  /// The fixture's head commit of #18303.
  static let headCommit = "04e3f33e9804c4ff6fbd57f41ebd75e6c1e50547"
  static let olderCommit = "0000000000000000000000000000000000000001"
  static let reviewedAt = "2026-11-01T00:00:00Z"

  /// A session on #18303's branch whose PR waits on a review from
  /// `reviewers`, with `decision` as its reviewDecision, which the poller
  /// has read. `wait` opens a wait before the poll, so the other rules give
  /// Waiting. `configure` edits the fake PR before the session starts.
  func session(
    _ github: FakeGitHub, _ sbd: Instance, draft: Bool = false, decision: JSON? = "REVIEW_REQUIRED",
    from reviewers: [String] = ["alice"], wait: String? = nil, configure: (FakeGitHub) -> Void = { _ in }
  ) throws -> SessionSummary {
    github.awaitReview(Self.number, draft: draft, from: reviewers)
    github.decide(Self.number, decision)
    configure(github)
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    if let wait { try sbd.sb(["wait", s.id] + wait.split(separator: " ").map(String.init)) }
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

    #expect(got.reason == "#18303 Fix; review required; review requested from alice, checks success")
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

  /// The author pushed after bob's change request, so the PR waits on bob's
  /// second review.
  @Test func changesRequestedOnAnOlderCommitIsReadyForReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, decision: "CHANGES_REQUESTED", from: ["bob"]) {
      $0.review(Self.number, by: "bob", "CHANGES_REQUESTED", at: Self.reviewedAt, verdict: true, on: Self.olderCommit)
    }

    let got = try sbd.get(s.id)

    #expect(got.state == .readyForReview)
    #expect(
      got.reason.hasPrefix(
        "#18303 chore(cdp): document lookup records in the dead-letter runbook; changes requested by bob"))
  }

  /// No rule requires a review, the checks passed, and nobody is asked, so
  /// the PR can merge.
  @Test func prThatNeedsNoReviewIsReadyToMerge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, decision: .null, from: [])

    #expect(try sbd.get(s.id).state == .readyToMerge)
  }

  @Test func reviewRequestOnAPRThatNeedsNoReviewIsNotReadyForReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, decision: .null, from: ["alice"])

    #expect(try sbd.get(s.id).state == .needsYou)
  }

  @Test func waitingSessionWhosePRNeedsNoReviewStaysWaitingAndSaysWhy() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, decision: .null, from: [], wait: "CI on #18303")

    let got = try sbd.get(s.id)
    let printed = try sbd.sb("get", s.id)

    #expect(got.state == .waiting)
    #expect(got.reason.hasSuffix("; #18303 needs no review"))
    #expect(printed.contains("needs no review"))
  }

  @Test func sbGetSaysReviewRequiredInTheColumn() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, wait: "CI on #18303")

    let printed = try sbd.sb("get", s.id)

    #expect(printed.contains("state:   Ready for review: #18303 "))
    #expect(printed.contains("; review required; review requested from alice"))
  }

  @Test func approvedPRIsNotReadyForReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, decision: "APPROVED", from: [], wait: "CI on #18303") {
      $0.review(Self.number, by: "alice", "APPROVED", at: Self.reviewedAt, verdict: true, on: Self.headCommit)
    }

    let got = try sbd.get(s.id)

    #expect(got.state == .waiting)
    #expect(got.reason.hasSuffix("; #18303 approved"))
  }

  @Test func waitingSessionWithAnUnreadReviewDecisionSaysTheRuleIsNotRead() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd, decision: nil, wait: "CI on #18303")

    let got = try sbd.get(s.id)

    #expect(got.state == .waiting)
    #expect(got.reason.hasSuffix("; #18303: GitHub's review rule not read yet"))
  }

  @Test func approvalMovesTheSessionOutAfterTheNextPoll() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try session(github, sbd)
    #expect(try sbd.get(s.id).state == .readyForReview)
    try sbd.advanceClock(Self.hour)
    github.decide(Self.number, "APPROVED")
    github.review(Self.number, by: "alice", "APPROVED", at: Self.reviewedAt, verdict: true, on: Self.headCommit)
    github.change(Self.number) { $0["reviewRequests"] = ["nodes": []] }

    try sbd.poll(all: true)

    #expect(try sbd.getJSON(s.id)["state"]?.string != "ready_for_review")
  }
}
