import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A private sbd whose poller asks `github`, with Fixtures/gh-merge-stub as
  /// its gh. Polls run only when a test asks.
  static func withMergeStub(_ github: FakeGitHub) throws -> Instance {
    try Instance(config: [
      "github": [
        "gh": .string("\(FakeGitHub.fixtures)/gh-merge-stub"), "url": .string(github.url), "pollSeconds": 0,
      ],
      "tickSeconds": 1,
    ])
  }

  /// The arguments of each gh call that the stub ran and that starts with
  /// `prefix`, oldest first. A call with a multi-line argument takes several
  /// lines.
  func ghCalls(_ prefix: String = "") -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/gh-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
  }

  /// The arguments of each `gh pr merge` that the stub ran, oldest first.
  func ghMerges() -> [String] { ghCalls("pr merge ") }

  /// Makes the stub's `gh pr merge` print `text` to stderr and exit 1.
  func ghMergeFails(with text: String) throws {
    try text.write(toFile: "\(home.path)/gh-merge-error", atomically: true, encoding: .utf8)
  }

  /// The session as `sb get --json` prints it.
  func getJSON(_ id: String) throws -> JSON {
    try #require(JSON.parse(try sb("get", "--json", id)))
  }
}

/// `sb merge` merges a ready PR with gh and resumes the session.
@Suite(.blocking(timeLimit: .seconds(120))) struct MergeTests {
  static let charts = "PostHog/charts"
  /// The head branch of PostHog/charts#18303, which the fixture records as
  /// open, mergeable, approved by stamphog, and with checks that passed.
  static let branch = "haacked/cdp-dlq-runbook-lookup-step"
  static let number = 18303
  static let message = "PR #18303 merged; finish the post-merge steps"

  /// A session on #18303's branch, whose PR the poller has read.
  func readySession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    return s
  }

  func head(_ github: FakeGitHub) -> String { github.pr(MergeTests.number)["headRefOid"]!.string! }

  @Test func readyPRShowsReadyToMerge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    let got = try sbd.getJSON(s.id)

    #expect(got["state"]?.string == "ready_to_merge")
    #expect(got["reason"]?.string == "#18303 is ready to merge, approved by stamphog")
  }

  /// A busy PR in a repository that merges through Trunk: Trunk's comment is
  /// older than the comments the poller reads, so the poller sees only other
  /// bots. The repository's `.trunk` folder still shows the queue.
  @Test func busyPRInATrunkRepositoryIsEnqueuedWithoutAMerge() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) {
      $0["repository"] = [
        "nameWithOwner": .string(MergeTests.charts), "defaultBranchRef": ["name": "main"],
        "trunkConfig": ["id": "TREE_trunk"],
      ]
    }
    for i in 0..<25 {
      github.comment(
        on: MergeTests.number, by: "github-actions[bot]", body: "Deploy preview \(i)",
        at: String(format: "2026-10-22T06:%02d:00Z", i))
    }
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    #expect(try sbd.get(s.id).reason == "#18303 is ready to merge, approved by stamphog")

    let r = try sbd.run(["merge", s.id])

    #expect(r.status == 0)
    #expect(sbd.ghComments() == ["pr comment 18303 --repo PostHog/charts --body /trunk merge"])
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test func readyPRShowsReadyToMergeInTheList() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    let rows = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)

    #expect(rows.first { $0["id"]?.string == s.id }?["state"]?.string == "ready_to_merge")
  }

  @Test func mergeRunsGhOnceAndResumesTheSession() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    let printed = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("merge", "--json", s.id))

    #expect(printed.id == s.id)
    #expect(printed.state != .readyToMerge)
    #expect(
      sbd.ghMerges() == ["pr merge 18303 --repo PostHog/charts --merge --match-head-commit \(head(github))"])
    try sbd.waitFor("the post-merge message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id) == [MergeTests.message])
  }

  @Test func secondMergeIsRefusedAndGhRunsOnce() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    try sbd.sb("merge", s.id)

    let again = try sbd.run(["merge", s.id])

    #expect(again.status != 0)
    #expect(sbd.ghMerges().count == 1)
  }

  @Test func mergeWhileAMergeRunsIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    let gate = "\(sbd.home.path)/gh-merge-gate"
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    let first = Process()
    first.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sb")
    first.arguments = ["merge", s.id]
    first.environment = sbd.environment()
    first.standardOutput = FileHandle.nullDevice
    first.standardError = FileHandle.nullDevice
    try first.run()
    try sbd.waitFor("gh to start the merge") { sbd.ghMerges().count == 1 }

    let second = try sbd.run(["merge", s.id])

    // Opening the FIFO for writing lets the stub's read finish.
    let writer = try #require(FileHandle(forWritingAtPath: gate))
    writer.write(Data("go\n".utf8))
    try writer.close()
    first.waitUntilExit()
    #expect(second.status != 0)
    #expect(second.stderr.contains("#18303 is already merging"))
    #expect(first.terminationStatus == 0)
    #expect(sbd.ghMerges().count == 1)
  }

  @Test func removeWhileAMergeRunsIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    let gate = "\(sbd.home.path)/gh-merge-gate"
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    let merge = Process()
    merge.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sb")
    merge.arguments = ["merge", s.id]
    merge.environment = sbd.environment()
    merge.standardOutput = FileHandle.nullDevice
    merge.standardError = FileHandle.nullDevice
    try merge.run()
    try sbd.waitFor("gh to start the merge") { sbd.ghMerges().count == 1 }

    let removed = try sbd.run(["rm", s.id])

    let writer = try #require(FileHandle(forWritingAtPath: gate))
    writer.write(Data("go\n".utf8))
    try writer.close()
    merge.waitUntilExit()
    #expect(removed.status != 0)
    #expect(removed.stderr.contains("is merging its PR"))
    #expect(merge.terminationStatus == 0)
    #expect(try sbd.get(s.id).id == s.id)
  }

  @Test func conflictingPRIsNotReadyAndMergeIsRefusedWithItsReason() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    github.change(MergeTests.number) { $0["mergeable"] = "CONFLICTING" }
    try sbd.poll(all: true)

    let got = try sbd.getJSON(s.id)
    let r = try sbd.run(["merge", s.id])

    #expect(got["state"]?.string != "ready_to_merge")
    #expect(got["reason"]?.string == "merge main in; #18303 conflicts with main")
    #expect(r.status != 0)
    #expect(r.stderr.contains("merge main in; #18303 conflicts with main"))
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test func prWithFailingChecksIsNotReadyAndMergeIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    github.checks(MergeTests.number, "FAILURE")
    try sbd.poll(all: true)

    let state = try sbd.getJSON(s.id)["state"]?.string
    let r = try sbd.run(["merge", s.id])

    #expect(state != "ready_to_merge")
    #expect(r.status != 0)
    #expect(sbd.ghMerges().isEmpty)
  }

  /// The fixture's base query has no `baseRef` for #18303, so the poller
  /// reads no merged base for the `release` base.
  @Test func approvedPROnANonDefaultBaseSaysWhatBlocksTheMerge() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) { $0["baseRefName"] = "release" }
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    let got = try sbd.get(s.id)
    let r = try sbd.run(["merge", s.id])

    #expect(got.state == .needsYou)
    #expect(got.reason == "#18303 targets release, not main; approved by stamphog")
    #expect(r.status != 0)
    #expect(r.stderr.contains("#18303 targets release, not main; approved by stamphog"))
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test func failedMergeKeepsTheSessionReadyAndRecordsGhsError() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    let error = "X Pull request PostHog/charts#18303 is not mergeable: the base branch policy prohibits the merge."
    try sbd.ghMergeFails(with: error)

    let r = try sbd.run(["merge", s.id])

    let after = try sbd.get(s.id)
    #expect(r.status != 0)
    #expect(sbd.ghMerges().count == 1)
    #expect(after.state == .readyToMerge)
    #expect(after.mergeError?.contains(error) == true)
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  @Test func dismissAcknowledgesTheReadyToMergeItem() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    try sbd.sb("merge", "--dismiss", s.id)

    let got = try sbd.getJSON(s.id)
    #expect(got["state"]?.string == "waiting")
    #expect(got["reason"]?.string == "#18303 is ready to merge, approved by stamphog")
    #expect(got["acknowledged"]?.bool == true)
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test func dismissPrintsThatItAcknowledgedThePR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    let printed = try sbd.sb("merge", "--dismiss", s.id)

    #expect(printed.trimmingCharacters(in: .whitespacesAndNewlines) == "acknowledged #18303 of \(s.name)")
  }

  @Test func acknowledgedReadyToMergeSessionStillMerges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    try sbd.sb("ack", s.id)

    try sbd.sb("merge", s.id)

    #expect(
      sbd.ghMerges() == ["pr merge 18303 --repo PostHog/charts --merge --match-head-commit \(head(github))"])
  }

  @Test func secondDismissRecordsNoSecondAck() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    try sbd.sb("merge", "--dismiss", s.id)
    try sbd.sb("merge", "--dismiss", s.id)

    #expect(try sbd.events(s.id).filter { $0.kind == "ack" }.count == 1)
  }

  @Test func dismissRecordsAnAckEventAndNoMergeEvent() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    try sbd.sb("merge", "--dismiss", s.id)

    let kinds = try sbd.events(s.id).map(\.kind)
    #expect(kinds.filter { $0 == "ack" }.count == 1)
    #expect(!kinds.contains("merge"))
  }

  @Test func dismissedPRReturnsToReadyToMergeAfterANewPush() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    try sbd.sb("merge", "--dismiss", s.id)

    github.change(MergeTests.number) { $0["headRefOid"] = "pushed" }
    try sbd.poll(all: true)

    let got = try sbd.getJSON(s.id)
    #expect(got["state"]?.string == "ready_to_merge")
    #expect(got["acknowledged"] == nil)
  }

  @Test func dismissedPRStaysAcknowledgedAcrossPollsOfTheSameHead() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    try sbd.sb("merge", "--dismiss", s.id)
    github.change(MergeTests.number) { $0["title"] = "a new title" }

    try sbd.poll(all: true)

    let got = try sbd.getJSON(s.id)
    #expect(got["state"]?.string == "waiting")
    #expect(got["acknowledged"]?.bool == true)
  }

  @Test func dismissedPRReturnsToReadyToMergeAfterANewTurn() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)
    try sbd.sb("merge", "--dismiss", s.id)

    try sbd.sb("send", s.id, "again")

    let back = try sbd.waitFor(s.id, "the reply to the new turn") {
      $0.lastReply == "Done: again" && $0.state == .readyToMerge
    }
    #expect(back.acknowledged == nil)
  }

  @Test func mergeInsideClaudeCodeIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    let r = try sbd.run(["merge", s.id], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(sbd.ghMerges().isEmpty)
    #expect(try sbd.get(s.id).state == .readyToMerge)
  }

  @Test func dismissInsideClaudeCodeIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    let r = try sbd.run(["merge", "--dismiss", s.id], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(try sbd.get(s.id).state == .readyToMerge)
  }

  @Test(arguments: ["18303", "#18303", "PostHog/charts#18303", "https://github.com/PostHog/charts/pull/18303"])
  func mergeByPRNumberMergesThatSessionsPR(_ target: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    try sbd.sb("merge", target)

    #expect(
      sbd.ghMerges() == ["pr merge 18303 --repo PostHog/charts --merge --match-head-commit \(head(github))"])
    try sbd.waitFor("the post-merge message") { try !sbd.messagesFromSbd(s.id).isEmpty }
  }

  @Test func dismissByPRNumberAcknowledgesThatSessionsPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(sbd)

    try sbd.sb("merge", "--dismiss", "#18303")

    let got = try sbd.getJSON(s.id)
    #expect(got["state"]?.string == "waiting")
    #expect(got["acknowledged"]?.bool == true)
  }

  @Test func mergeByAPRNumberThatTwoSessionsShareIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    _ = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch, folder: "one")
    _ = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch, folder: "two")
    try sbd.poll()

    let r = try sbd.run(["merge", "18303"])

    #expect(r.status != 0)
    #expect(sbd.ghMerges().isEmpty)
  }

  /// The second PR has #18303's number in another repository.
  @Test(arguments: ["99999", "acme/widgets#18303"])
  func mergeByAPRThatNoSessionHasIsRefused(_ target: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    _ = try readySession(sbd)

    let r = try sbd.run(["merge", target])

    #expect(r.status != 0)
    #expect(sbd.ghMerges().isEmpty)
  }
}
