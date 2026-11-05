import Foundation
import SwitchboardCore
import Testing

extension FakeGitHub {
  /// Makes the PR one that nobody reviewed and GitHub asks nobody to review:
  /// mergeable, its checks passed, no review, and GitHub requires one.
  fileprivate func unreviewed(_ number: Int) {
    change(number) {
      $0["title"] = "Fix"
      $0["isDraft"] = false
      $0["mergeable"] = "MERGEABLE"
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
      $0["reviews"] = ["nodes": []]
      $0["reviewRequests"] = ["nodes": []]
    }
    checks(number, "SUCCESS")
  }

  fileprivate func requestReview(_ number: Int, from login: String) {
    change(number) {
      $0["reviewRequests"] = ["nodes": [["requestedReviewer": ["__typename": "User", "login": .string(login)]]]]
    }
  }
}

extension Instance {
  /// The arguments of each `gh pr edit` that the stub ran, oldest first.
  fileprivate func ghEdits() -> [String] { ghCalls().filter { $0.hasPrefix("pr edit ") } }

  /// Makes the stub's `gh pr edit` print `text` to stderr and exit 1.
  fileprivate func ghEditFails(with text: String) throws {
    try text.write(toFile: "\(home.path)/gh-edit-error", atomically: true, encoding: .utf8)
  }
}

/// A session whose open PR nobody reviewed and GitHub asks nobody to review
/// gets a review card, and `sb review` requests the review with gh.
@Suite(.timeLimit(.minutes(2))) struct ReviewRequestTests {
  static let number = MergeTests.number
  static let card = "#18303 is ready for review"
  static let readTheReply = "read its last reply and decide what's next"

  /// A session on #18303's branch, whose unreviewed PR the poller has read.
  func unreviewedSession(_ github: FakeGitHub, _ sbd: Instance) throws -> SessionSummary {
    github.unreviewed(Self.number)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    return s
  }

  @Test func unreviewedPRShowsTheReviewCardInTheInbox() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    let got = try sbd.get(s.id)

    #expect(got.state == .needsYou)
    #expect(got.reason == Self.card)
    let item = try #require(got.triage)
    #expect(item.options.map(\.action) == [.requestReview, .dismissReview])
    #expect(item.summary.hasPrefix("#18303 Fix\nChecks success."))
    #expect(try sbd.triage().contains { $0.id == s.id })
  }

  @Test func reviewWithoutReviewersListsTheSuggestions() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    let printed = try sbd.sb("review", s.id)

    #expect(printed.contains("ann"))
    #expect(printed.contains("committed to the changed files"))
    #expect(printed.contains("@copilot"))
    #expect(!printed.contains("haacked "))
    #expect(sbd.ghEdits().isEmpty)
    let query = try #require(sbd.ghCalls().first { $0.hasPrefix("api graphql ") })
    #expect(query.hasPrefix("api graphql -f id=\(github.pr(Self.number)["id"]!.string!) -f query="))
  }

  @Test func reviewJSONListsTheSuggestions() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    let got = try #require(JSON.parse(try sbd.sb("review", "--json", s.id)))

    #expect(got["suggestions"]?.array?.compactMap { $0["login"]?.string } == ["ann", "@copilot"])
    #expect(got["session"]?.string == s.id)
  }

  @Test func reviewRequestsTheReviewersOnceAndMovesTheSessionToReadyForReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    try sbd.sb("review", s.id, "ann", "@copilot")

    #expect(sbd.ghEdits() == ["pr edit 18303 --repo PostHog/charts --add-reviewer ann,@copilot"])
    let got = try sbd.get(s.id)
    #expect(got.state == .readyForReview)
    #expect(got.reason == "#18303 Fix; review requested from ann and @copilot, checks success")
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  @Test func secondRequestWhileOneRunsIsRefusedAndGhRunsOnce() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)
    let gate = "\(sbd.home.path)/gh-edit-gate"
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    let first = Process()
    first.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sb")
    first.arguments = ["review", s.id, "ann"]
    first.environment = sbd.environment()
    first.standardOutput = FileHandle.nullDevice
    first.standardError = FileHandle.nullDevice
    try first.run()
    try sbd.waitFor("gh to start the request") { sbd.ghEdits().count == 1 }

    let second = try sbd.run(["review", s.id, "bob"])

    // Opening the FIFO for writing lets the stub's read finish.
    let writer = try #require(FileHandle(forWritingAtPath: gate))
    writer.write(Data("go\n".utf8))
    try writer.close()
    first.waitUntilExit()
    #expect(second.status != 0)
    #expect(second.stderr.contains("#18303 already has a review request running"))
    #expect(first.terminationStatus == 0)
    #expect(sbd.ghEdits() == ["pr edit 18303 --repo PostHog/charts --add-reviewer ann"])
  }

  @Test func sessionStaysInReadyForReviewOnceGitHubListsTheReviewer() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)
    try sbd.sb("review", s.id, "ann")

    github.requestReview(Self.number, from: "ann")
    try sbd.poll(all: true)

    let got = try sbd.get(s.id)
    #expect(got.state == .readyForReview)
    #expect(got.reason == "#18303 Fix; review requested from ann, checks success")
  }

  @Test func failedRequestKeepsTheCardAndShowsGhsError() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)
    let error = "could not request reviewer: 'nobody' not found"
    try sbd.ghEditFails(with: error)

    let r = try sbd.run(["review", s.id, "nobody"])

    #expect(r.status != 0)
    #expect(r.stderr.contains(error))
    let got = try sbd.get(s.id)
    #expect(got.reason == Self.card)
    #expect(got.triage?.callouts.contains { $0.kind == .warning && $0.body.contains(error) } == true)
  }

  @Test func dismissHidesTheCardUntilANewCommit() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    try sbd.sb("review", "--dismiss", s.id)

    #expect(try sbd.get(s.id).reason == Self.readTheReply)
    #expect(sbd.ghEdits().isEmpty)
    github.change(Self.number) { $0["title"] = "a new title" }
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).reason == Self.readTheReply)
    github.change(Self.number) { $0["headRefOid"] = "pushed" }
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).reason == Self.card)
  }

  @Test func reviewOfASessionWithoutTheCardIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()

    let r = try sbd.run(["review", s.id, "ann"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("isn't ready for a review request"))
    #expect(sbd.ghEdits().isEmpty)
  }

  @Test(arguments: [["-x"], ["ann;rm"], ["a/b/c"]])
  func reviewWithAnInvalidReviewerIsRefused(_ reviewers: [String]) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    let r = try sbd.run(["review", s.id] + reviewers)

    #expect(r.status != 0)
    #expect(sbd.ghEdits().isEmpty)
    #expect(try sbd.get(s.id).reason == Self.card)
  }

  @Test(arguments: [["review", "ann"], ["review"], ["review", "--dismiss"]])
  func reviewInsideClaudeCodeIsRefused(_ args: [String]) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    let r = try sbd.run(args + [s.id], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(sbd.ghCalls().allSatisfy { !$0.hasPrefix("pr edit") && !$0.hasPrefix("api graphql") })
    #expect(try sbd.get(s.id).reason == Self.card)
  }

  @Test(arguments: ["#18303", "PostHog/charts#18303"])
  func reviewByPRRequestsThatSessionsReview(_ target: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    try sbd.sb("review", target, "ann")

    #expect(sbd.ghEdits() == ["pr edit 18303 --repo PostHog/charts --add-reviewer ann"])
    #expect(try sbd.get(s.id).state == .readyForReview)
  }

  @Test func choosingRequestReviewWithTextRequestsThoseReviewers() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    try sbd.sb("choose", s.id, "Request review", "--text", "ann, @copilot")

    #expect(sbd.ghEdits() == ["pr edit 18303 --repo PostHog/charts --add-reviewer ann,@copilot"])
  }

  @Test func choosingRequestReviewWithoutReviewersIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    let r = try sbd.run(["choose", s.id, "Request review"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("sb review"))
    #expect(sbd.ghEdits().isEmpty)
  }

  @Test func choosingDismissHidesTheReviewCard() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    try sbd.sb("choose", s.id, "Dismiss")

    #expect(try sbd.get(s.id).reason == Self.readTheReply)
  }

  @Test(arguments: ["1", "2"])
  func chooseRefusesTheReviewOptionsInsideClaudeCode(_ option: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try unreviewedSession(github, sbd)

    let r = try sbd.run(["choose", s.id, option, "--text", "ann"], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(sbd.ghEdits().isEmpty)
    #expect(try sbd.get(s.id).reason == Self.card)
  }
}
