import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The arguments of each merge brief call that the stub saw.
  func briefCalls() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/pr-brief-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\0").map(String.init)
  }

  /// The Summary section of the session's Inbox item, as `sb get --json`
  /// prints it.
  func mergeSummary(_ id: String) throws -> JSON {
    try #require(try getJSON(id)["triage"]?["message"]?["summary"])
  }
}

/// The ready-to-merge card says what the PR does, its size, approvals, and
/// checks, and what should give the user pause.
@Suite(.blocking(timeLimit: .seconds(180))) struct MergeSummaryTests {
  static let body = """
    ## Problem

    - When a flag targets a dynamic cohort, the result depends on child order.

    Closes #133410

    ## Changes

    - A sibling now decides the result in either order.

    ## How did you test this code?

    New cases cover both orders. Not run: the database-backed suites.

    - [ ] Tested by hand

    ## 🤖 Agent context

    Written by an agent.
    """

  static let gist =
    "When a flag targets a dynamic cohort, the result depends on child order. A sibling now decides the result in either order."

  func github() throws -> FakeGitHub {
    let github = try FakeGitHub()
    github.change(MergeTests.number) {
      $0["body"] = .string(Self.body)
      $0["additions"] = 315
      $0["deletions"] = 208
      $0["changedFiles"] = 4
    }
    return github
  }

  func detailsReads(_ github: FakeGitHub) -> Int {
    github.requests.filter { $0.kind == FakeGitHub.PRQuery.mergeDetails.rawValue }.count
  }

  func plain(_ markdown: String) -> String {
    MarkdownBlock.parse(markdown).compactMap { block -> String? in
      guard case .paragraph(let text) = block else { return nil }
      return text.plain
    }.joined(separator: "\n")
  }

  @Test func readyCardSummarizesThePRWithItsFactsAndPauses() throws {
    let github = try github()
    github.reviewThreads(MergeTests.number, resolved: [true, false])
    let sbd = try Instance.withMergeStub(github)
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "enabled": false])
    let s = try MergeTests().readySession(sbd)

    let summary = try sbd.mergeSummary(s.id)
    let text = plain(try #require(summary["text"]?.string))

    #expect(detailsReads(github) == 1)
    #expect(text == "\(Self.gist)\n4 files, +315 -208. Approved by stamphog. Checks passed.")
    #expect(!text.contains("is ready to merge"))
    let callouts = try #require(summary["callouts"]?.array)
    #expect(callouts.map { $0["title"]?.string } == ["1 open review thread", "The test plan has gaps"])
    let gaps = try #require(callouts[1]["body"]?.string).replacingOccurrences(of: "\\", with: "")
    #expect(gaps == "- Not run: the database-backed suites.\n- Tested by hand")
    #expect(sbd.briefCalls().isEmpty)
  }

  @Test func briefReplacesTheGistOncePerHead() throws {
    let github = try github()
    let sbd = try Instance.withMergeStub(github)
    try #"{"summary":"It makes cohort results independent of child order."}"#.write(
      toFile: "\(sbd.home.path)/pr-brief-answer.json", atomically: true, encoding: .utf8)
    let s = try MergeTests().readySession(sbd)

    let text = try sbd.waitFor("the brief", fetch: { try sbd.mergeSummary(s.id)["text"]?.string }) {
      $0.contains("independent")
    }

    #expect(plain(text).hasPrefix("It makes cohort results independent of child order.\n4 files"))
    let input = try String(contentsOfFile: "\(sbd.home.path)/pr-brief-input.txt", encoding: .utf8)
    #expect(input.contains("<pr-body>"))
    #expect(input.contains("depends on child order"))
    #expect(!input.contains("Agent context"))
    try sbd.poll()
    try sbd.poll()
    #expect(sbd.briefCalls().count == 1)
    #expect(detailsReads(github) == 1)
  }

  @Test func statusReReadAtTheSameHeadReadsTheThreadsAgain() throws {
    let github = try github()
    let sbd = try Instance.withMergeStub(github)
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "enabled": false])
    let s = try MergeTests().readySession(sbd)
    #expect(detailsReads(github) == 1)

    github.reviewThreads(MergeTests.number, resolved: [false])
    try sbd.advanceClock(600_000)
    try sbd.poll()

    #expect(detailsReads(github) == 2)
    let callouts = try #require(try sbd.mergeSummary(s.id)["callouts"]?.array)
    #expect(callouts.first?["title"]?.string == "1 open review thread")
  }

  @Test func briefThatTheHourlyLimitSkippedRunsOnceTheHourPasses() throws {
    let github = try github()
    let sbd = try Instance.withMergeStub(github)
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "perHour": 1])
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    // The turn's summary uses the hour's one call.
    _ = try sbd.waitForTriageEvents(s.id, count: 1)
    try sbd.poll()
    try sbd.advanceClock(1_000)

    let briefs = try sbd.events(s.id).filter { $0.kind == MergeBrief.event }
    #expect(briefs.count == 1)
    #expect(briefs.first?.data["skipped"]?.string?.isEmpty == false)
    #expect(sbd.briefCalls().isEmpty)
    #expect(plain(try sbd.mergeSummary(s.id)["text"]?.string ?? "").hasPrefix(Self.gist))

    try sbd.advanceClock(3_600_000)

    let text = try sbd.waitFor("the brief", fetch: { try sbd.mergeSummary(s.id)["text"]?.string }) {
      $0.contains("It changes the code.")
    }
    #expect(plain(text).hasPrefix("It changes the code.\n4 files"))
    #expect(sbd.briefCalls().count == 1)
  }

  @Test func newHeadReadsTheDetailsAndTheBriefAgain() throws {
    let github = try github()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try sbd.waitFor("the first brief") { sbd.briefCalls().count == 1 }

    github.change(MergeTests.number) {
      $0["headRefOid"] = "0123456789abcdef0123456789abcdef01234567"
      $0["additions"] = 400
    }
    try sbd.advanceClock(600_000)
    try sbd.poll()

    try sbd.waitFor("the second brief") { sbd.briefCalls().count == 2 }
    #expect(detailsReads(github) == 2)
    #expect(try sbd.mergeSummary(s.id)["text"]?.string?.contains("400") == true)
  }

  @Test func prUnderReviewReadsDetailsOncePerHeadForItsNudgeWithoutABrief() throws {
    let github = try github()
    github.change(MergeTests.number) {
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
    }
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try sbd.poll()

    let pr = try #require(try sbd.get(s.id).pr)
    #expect(try sbd.get(s.id).state != .readyToMerge)
    #expect(pr.gist == Self.gist)
    #expect(pr.additions == 315)
    #expect(pr.deletions == 208)
    #expect(detailsReads(github) == 1)
    #expect(sbd.briefCalls().isEmpty)
  }

  @Test func answeredChangeRequestShowsWhoToAskForAReReview() throws {
    let github = try github()
    github.change(MergeTests.number) {
      $0["author"] = ["__typename": "User", "login": "haacked"]
      $0["reviewDecision"] = "CHANGES_REQUESTED"
      let request: JSON = [
        "author": ["__typename": "User", "login": "mariusandra"], "state": "CHANGES_REQUESTED",
        "submittedAt": "2026-11-13T08:53:58Z",
      ]
      $0["latestOpinionatedReviews"] = ["nodes": [request]]
      $0["reviews"] = [
        "nodes": [
          request,
          [
            "author": ["__typename": "User", "login": "haacked"], "state": "COMMENTED",
            "submittedAt": "2026-11-13T18:07:49Z",
          ],
        ]
      ]
    }
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)

    let pr = try #require(try sbd.get(s.id).pr)
    #expect(pr.rereview?.reviewers == ["mariusandra"])
    #expect(pr.rereview?.repliedAt == Transcript.milliseconds("2026-11-13T18:07:49Z"))
    #expect(detailsReads(github) == 0)
  }

  @Test func failedBriefKeepsTheGistAndIsNotRetriedForTheSameHead() throws {
    let github = try github()
    // The description drops the agent section, so the marker goes in a kept one.
    let body = Self.body.replacingOccurrences(
      of: "either order.\n", with: "either order.\n\nFAIL-BRIEF\n")
    github.change(MergeTests.number) { $0["body"] = .string(body) }
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)

    try sbd.waitFor("the failed brief") { try sbd.events(s.id).contains { $0.kind == MergeBrief.event } }
    try sbd.poll()

    #expect(sbd.briefCalls().count == 1)
    #expect(plain(try sbd.mergeSummary(s.id)["text"]?.string ?? "").hasPrefix(Self.gist))
  }

  @Test func failedDetailsReadShowsTheFactsWithoutSizeAndRecovers() throws {
    let github = try github()
    github.fail(MergeTests.number, in: .mergeDetails)
    let sbd = try Instance.withMergeStub(github)
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "enabled": false])
    let s = try MergeTests().readySession(sbd)

    #expect(plain(try sbd.mergeSummary(s.id)["text"]?.string ?? "") == "Approved by stamphog. Checks passed.")
    #expect(try sbd.poll()["mergeDetailsError"]?.string?.isEmpty == false)

    github.recover(MergeTests.number, in: .mergeDetails)
    #expect(try sbd.poll()["mergeDetailsError"] == nil)

    #expect(plain(try sbd.mergeSummary(s.id)["text"]?.string ?? "").hasPrefix(Self.gist))
  }
}
