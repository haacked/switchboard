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

  /// Records alice's approval on the PR, which GitHub then counts as approved.
  fileprivate func approveByAlice(_ number: Int) {
    change(number) {
      $0["reviewDecision"] = "APPROVED"
      $0["reviewRequests"] = ["nodes": []]
      $0["latestOpinionatedReviews"] = [
        "nodes": [
          [
            "author": ["__typename": "User", "login": "alice"], "state": "APPROVED",
            "submittedAt": "2026-11-11T10:00:00Z",
          ]
        ]
      ]
    }
  }
}

extension Instance {
  /// The line of `sb get` that shows the session's board column.
  fileprivate func columnLine(_ id: String) throws -> String {
    let lines = try sb("get", id).split(separator: "\n").map(String.init)
    return try #require(lines.first { $0.hasPrefix("  column:") })
  }

  /// The session's `board` in `sb ls --json`, once the session is out of a
  /// turn, because a turn puts every card in In progress.
  fileprivate func idleBoard(_ id: String) throws -> JSON {
    let row = try listed(id)
    try #require(row["state"]?.string != "working", "\(row)")
    return try #require(row["board"])
  }
}

/// sbd places each work session in a board column and shows it in `sb ls`
/// and `sb get`.
@Suite(.blocking(timeLimit: .seconds(120))) struct BoardColumnTests {
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

  /// A session on #18303's branch, whose PR the fixture records as approved
  /// with checks that passed.
  func approvedSession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: Self.charts, branch: Self.branch)
    try sbd.poll()
    return s
  }

  @Test func prThatAwaitsReviewIsInReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "SUCCESS")

    #expect(try sbd.idleBoard(s.id)["column"]?.string == "in_review")
  }

  @Test func runningChecksLeaveThePRInReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "PENDING")

    #expect(try sbd.idleBoard(s.id)["column"]?.string == "in_review")
  }

  @Test func inReviewCardListsTheRequestedReviewer() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "SUCCESS")

    let reviewers = try #require(try sbd.idleBoard(s.id)["reviewers"]?.array).compactMap(\.string)

    #expect(reviewers.contains { $0 == "alice" || $0 == "@alice" }, "\(reviewers)")
  }

  @Test func approvalWithPassingChecksMovesTheCardFromInReviewToApproved() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "PENDING")
    try #require(try sbd.idleBoard(s.id)["column"]?.string == "in_review")

    github.approveByAlice(Self.number)
    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)

    #expect(try sbd.idleBoard(s.id)["column"]?.string == "approved")
  }

  @Test func moveToApprovedRestartsTheColumnTime() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "SUCCESS")
    let reviewSince = try #require(try sbd.idleBoard(s.id)["since"]?.int)
    try sbd.advanceClock(60_000)

    github.approveByAlice(Self.number)
    try sbd.poll(all: true)

    let board = try sbd.idleBoard(s.id)
    try #require(board["column"]?.string == "approved")
    #expect(try #require(board["since"]?.int) > reviewSince)
  }

  @Test func approvedPRIsApproved() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try approvedSession(sbd)

    #expect(try sbd.idleBoard(s.id)["column"]?.string == "approved")
  }

  @Test func conflictMovesTheApprovedPRToWaitingHeldByYou() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try approvedSession(sbd)

    github.change(Self.number) { $0["mergeable"] = "CONFLICTING" }
    try sbd.poll(all: true)

    let board = try sbd.idleBoard(s.id)
    #expect(board["column"]?.string == "waiting")
    #expect(board["holder"]?.string == "you")
  }

  /// Pushes a new head commit to the approved PR, whose checks start over.
  func pushNewCommits(_ github: FakeGitHub, _ sbd: Instance) throws {
    github.change(Self.number) { $0["headRefOid"] = .string(String(repeating: "f", count: 40)) }
    github.checks(Self.number, "PENDING")
    try sbd.poll(all: true)
  }

  @Test func newCommitsOnAnApprovedPRLeaveABackFromApprovedNote() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try approvedSession(sbd)
    try #require(try sbd.idleBoard(s.id)["column"]?.string == "approved")

    try pushNewCommits(github, sbd)

    let back = try #require(try sbd.idleBoard(s.id)["back"])
    #expect(back["from"]?.string == "approved")
    #expect(back["reason"]?.string == "new commits")
  }

  @Test func sbGetCarriesTheBackFromNote() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try approvedSession(sbd)
    try pushNewCommits(github, sbd)

    let back = try #require(try sbd.getJSON(s.id)["board"]?["back"])

    #expect(back["reason"]?.string == "new commits")
  }

  @Test func checksThatPassAgainClearTheNote() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try approvedSession(sbd)
    try pushNewCommits(github, sbd)
    try #require(try sbd.idleBoard(s.id)["back"]?.object != nil)

    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)

    let board = try sbd.idleBoard(s.id)
    try #require(board["column"]?.string == "approved")
    #expect(board.object?["back"] == nil)
  }

  @Test func sbGetPrintsTheColumnAndItsAge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "SUCCESS")
    try #require(try sbd.idleBoard(s.id)["column"]?.string == "in_review")

    let line = try sbd.columnLine(s.id)

    #expect(line.prefixMatch(of: try Regex(#"  column:  In review \d+[smhd]"#)) != nil, "\(line)")
  }

  @Test func sbGetPrintsTheColumnsLine() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try reviewSession(github, sbd, checks: "SUCCESS")
    try #require(try sbd.idleBoard(s.id)["column"]?.string == "in_review")

    #expect(try sbd.columnLine(s.id).contains("alice"))
  }

  @Test func sbGetPrintsTheBackFromNote() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try approvedSession(sbd)
    try pushNewCommits(github, sbd)

    let line = try sbd.columnLine(s.id)

    #expect(line.contains("back from Approved: new commits"), "\(line)")
  }

  @Test func sbGetPrintsNoStageLine() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")

    #expect(try !sbd.sb("get", s.id).contains("  stage:"))
  }

  @Test func workSessionHasNoPipeline() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")

    #expect(try sbd.listed(s.id).object?["pipeline"] == nil)
  }

  /// The stub may still be in its first turn, so either column is right.
  @Test func workSessionWithoutAPRIsInProgressOrWaiting() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")

    let column = try sbd.listed(s.id)["board"]?["column"]?.string

    #expect(column == "in_progress" || column == "waiting", "\(column ?? "nil")")
  }

  /// The work session shows that the field is there to leave out, so a
  /// renamed key cannot pass the tests below.
  func workSessionWithABoard(_ sbd: Instance) throws {
    let s = try sbd.new(prompt: "hello")
    try #require(try sbd.listed(s.id)["board"]?.object != nil)
  }

  @Test func managerHasNoBoardInSbLs() throws {
    let sbd = try Instance()
    try workSessionWithABoard(sbd)
    let manager = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("manager", "--json"))

    #expect(try sbd.listed(manager.id).object?["board"] == nil)
  }

  @Test func managerHasNoBoardInSbGet() throws {
    let sbd = try Instance()
    try workSessionWithABoard(sbd)
    let manager = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("manager", "--json"))

    #expect(try sbd.getJSON(manager.id).object?["board"] == nil)
  }

  @Test func managerHasNoColumnLine() throws {
    let sbd = try Instance()
    try workSessionWithABoard(sbd)
    let manager = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("manager", "--json"))

    #expect(try !sbd.sb("get", manager.id).contains("column:"))
  }

  @Test func groupChatHasNoBoard() throws {
    let sbd = try Instance()
    try workSessionWithABoard(sbd)
    try sbd.sb("group", "add", "--json", "Flags")
    let chat = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("chat", "Flags", "--json"))

    #expect(try sbd.listed(chat.id).object?["board"] == nil)
    #expect(try sbd.getJSON(chat.id).object?["board"] == nil)
  }
}
