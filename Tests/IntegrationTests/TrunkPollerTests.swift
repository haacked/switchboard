import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A private sbd whose poller asks `github`, with a fake trunk at the path
  /// that config.json names.
  static func withTrunk(_ github: FakeGitHub, pollSeconds: Double = 0) throws -> Instance {
    let sbd = try withGitHub(github, pollSeconds: pollSeconds)
    try sbd.writeFakeTrunk()
    return sbd
  }

  /// The trunk path that the base config.json names.
  var trunkPath: String { "\(home.path)/trunk" }
  var trunkOut: String { "\(home.path)/trunk-out" }
  var trunkCallLog: String { "\(home.path)/trunk-calls.log" }

  /// Writes a shell script at `trunkPath` that appends its physical folder
  /// and its arguments to `trunkCallLog`. It prints `<trunkOut>/<N>.txt` for
  /// `merge status <N>`, or Trunk's not-found error when that file is
  /// missing. It exits with the code in `<trunkOut>/<N>.status`, or 0.
  func writeFakeTrunk() throws {
    try FileManager.default.createDirectory(atPath: trunkOut, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      printf '%s\\t%s\\n' "$(pwd -P)" "$*" >> '\(trunkCallLog)'
      out='\(trunkOut)'/"$3".txt
      code='\(trunkOut)'/"$3".status
      if [ -f "$out" ]; then cat "$out"; else echo '✖ Item for merge queue instance not found, or you may not have permissions for it.'; fi
      if [ -f "$code" ]; then exit "$(cat "$code")"; fi
      exit 0

      """
    try script.write(toFile: trunkPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trunkPath)
  }

  /// Sets what the fake trunk prints for `merge status <number>`.
  func trunkPrints(_ number: Int, _ output: String, exit code: Int32 = 0) throws {
    try output.write(toFile: "\(trunkOut)/\(number).txt", atomically: true, encoding: .utf8)
    try String(code).write(toFile: "\(trunkOut)/\(number).status", atomically: true, encoding: .utf8)
  }

  /// Each run of the fake trunk, oldest first: the folder it ran in, with
  /// symlinks resolved, and its arguments.
  func trunkCalls() -> [TrunkCall] {
    let text = (try? String(contentsOfFile: trunkCallLog, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map { line in
      let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
      return TrunkCall(dir: fields[0], args: fields.count > 1 ? fields[1] : "")
    }
  }
}

struct TrunkCall: Equatable, CustomStringConvertible {
  var dir: String
  var args: String
  var description: String { "\(dir) \(args)" }
}

/// One row of `trunk merge status`: its time in seconds from now, its label,
/// and its description. A label that starts with ✖ or ✔ keeps the mark.
typealias TrunkRow = (seconds: Double, label: String, text: String)

/// What `trunk merge status <number>` prints for these rows, in trunk's
/// layout: a header, a link, and one line per row with the time in UTC
/// without a year.
func trunkStatus(_ number: Int, _ rows: [TrunkRow]) -> String {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = TimeZone(identifier: "UTC")
  f.dateFormat = "MM-dd HH:mm:ss.SSS"
  var lines = [
    "#\(number) feat(cdp): count the breaker lookups (haacked) ",
    " Learn more at https://app.trunk.io/gh/PostHog/posthog/merge/master/\(number)",
    "",
  ]
  for row in rows {
    let marked = row.label.hasPrefix("✖ ") || row.label.hasPrefix("✔ ")
    let label = (marked ? "  " : "    ") + row.label
    let time = f.string(from: Date().addingTimeInterval(row.seconds)) + "000"
    lines.append(" \(time)\(label.padding(toLength: 20, withPad: " ", startingAt: 0))\(row.text)")
  }
  return lines.joined(separator: "\n") + "\n"
}

private let submitted: TrunkRow = (
  -600, "Not Ready",
  "Pull request has been submitted to Merge by Phil Haack. It will be added to the merge queue once all branch protection rules pass."
)
private let pending: TrunkRow = (-300, "Pending", "Pull request has been added to the merge queue.")
private let testing: TrunkRow = (-60, "Testing", "Tests ran on PR 123456.")
private let cancelledText = "Pull request was removed from the merge queue because it was canceled by Phil Haack."
private let failedText =
  "Pull request was removed from the merge queue because the following required check failed: Django Tests (Failure)."
private let notLoggedIn = "\u{1B}[1m\u{1B}[31m✖ User not logged in: please run trunk login\u{1B}[0m\n"

/// PRs, comments, and trunk runs through `sb poll` against the fake GitHub and a fake trunk.
@Suite(.timeLimit(.minutes(2))) struct TrunkPollerTests {
  static let posthog = "PostHog/posthog"
  /// The branch of PostHog/posthog#122953, which has Trunk's status comment.
  static let posthogBranch = "haacked/cdp-dlq-breaker-counts-lookups"

  /// The id of the first trunk-io comment on the PR. Trunk edits it into the queue status.
  func trunkComment(_ github: FakeGitHub, _ number: Int = 122953) throws -> String {
    let nodes = github.pr(number)["firstComments"]?["nodes"]?.array ?? []
    return try #require(nodes.first { $0["author"]?["login"]?.string == "trunk-io" }?["id"]?.string)
  }

  /// Makes the PR's trunk-io comments show it in the queue, as `.queued`.
  func queue(_ github: FakeGitHub, _ number: Int = 122953) throws {
    github.edit(comment: try trunkComment(github, number), body: "Testing in the queue", at: stamp(-3600))
  }

  /// Opens #122179, which the fake GitHub records as merged, and shows it in the queue.
  func queueOpen122179(_ github: FakeGitHub) throws {
    github.change(122179) {
      $0["state"] = "OPEN"
      $0["mergedAt"] = .null
    }
    try queue(github, 122179)
  }

  func posthogSession(_ sbd: Instance) throws -> SessionSummary {
    try sbd.session(in: Self.posthog, branch: Self.posthogBranch)
  }

  func resumed(_ sbd: Instance, _ s: SessionSummary, with message: String) throws {
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: Switchboard: \(message)" }
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func aQueuedPRTakesItsStateFromTrunkRunInTheSessionsFolder() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))

    let result = try sbd.poll()

    #expect(result["trunkRuns"]?.int == 1)
    #expect(sbd.trunkCalls() == [TrunkCall(dir: real(s.cwd), args: "merge status 122953")])
    let pr = try #require(try sbd.get(s.id).pr)
    #expect(pr.queue == .testing)
    #expect(pr.queueLabel == "Testing")
    #expect(pr.trunkLoginNeeded != true)
    #expect(try sbd.sb("get", s.id).contains("#122953 Review required, checks success, Trunk testing"))
  }

  @Test func aPRWhoseCommentBodiesDidNotLoadRunsTrunk() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    github.fail(comment: try trunkComment(github))
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending]))

    try sbd.poll()

    #expect(sbd.trunkCalls() == [TrunkCall(dir: real(s.cwd), args: "merge status 122953")])
    #expect(try sbd.get(s.id).pr?.queue == .pending)
  }

  /// The comment bodies and PR states that don't show the PR in the queue. nil leaves the recorded comments,
  /// which are Trunk's control comment and its test analytics.
  @Test(arguments: [
    (String?.none, "OPEN"), ("Removed from the merge queue", "OPEN"), ("😎 Merged successfully", "OPEN"),
    ("Testing in the queue", "CLOSED"), ("Testing in the queue", "MERGED"),
  ])
  func aPRThatTheCommentsDoNotShowInTheQueueDoesNotRunTrunk(_ body: String?, _ state: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    if let body { github.edit(comment: try trunkComment(github), body: body, at: stamp(-3600)) }
    github.change(122953) { $0["state"] = .string(state) }
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))

    let first = try sbd.poll()
    let all = try sbd.poll(all: true)

    #expect(first["trunkRuns"]?.int == 0)
    #expect(all["trunkRuns"]?.int == 0)
    #expect(sbd.trunkCalls().isEmpty)
    #expect(try sbd.get(s.id).pr?.queueLabel == nil)
  }

  @Test func aSecondPollWithinThePendingIntervalDoesNotRunTrunkAgain() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github, pollSeconds: 30)
    _ = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))
    try sbd.poll()
    #expect(sbd.trunkCalls().count == 1)

    let second = try sbd.poll()

    #expect(second["trunkRuns"]?.int == 0)
    #expect(sbd.trunkCalls().count == 1)
  }

  @Test func aCommentChangeAfterTheLastReadRunsTrunkWithinTheInterval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github, pollSeconds: 30)
    let s = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, (-120, "✖ Failed", failedText)]))
    try sbd.poll()
    #expect(try sbd.get(s.id).pr?.queue == .removed)
    // The user submits the PR again. A new wait reads GitHub at once, and the
    // comment now names a newer run than the trunk read did.
    github.edit(comment: try trunkComment(github), body: "Submitted to merge", at: stamp(60))
    try sbd.trunkPrints(
      122953,
      trunkStatus(122953, [submitted, pending, (-120, "✖ Failed", failedText), (-5, "Not Ready", "Resubmitted.")]))
    try sbd.sb("wait", s.id, "--kind", "queue")

    let again = try sbd.poll()

    #expect(again["trunkRuns"]?.int == 1)
    #expect(try sbd.get(s.id).pr?.queue == .submitted)
  }

  @Test func aPollAfterThePendingIntervalRunsTrunkAgain() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github, pollSeconds: 30)
    _ = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))
    try sbd.poll()
    try sbd.advanceClock(30_000)

    let later = try sbd.poll()

    #expect(later["trunkRuns"]?.int == 1)
    #expect(sbd.trunkCalls().count == 2)
  }

  @Test func pollAllRunsTrunkWithinThePendingInterval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github, pollSeconds: 30)
    _ = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))
    try sbd.poll()

    let all = try sbd.poll(all: true)

    #expect(all["trunkRuns"]?.int == 1)
    #expect(sbd.trunkCalls().count == 2)
  }

  /// How the PR shows its place in the queue: through its comments, through trunk while its comment bodies
  /// didn't load, or not at all.
  enum QueueSource: String, CaseIterable {
    case comments, trunk, neither
  }

  @Test(arguments: QueueSource.allCases)
  func aQueuedPRPollsGitHubOnThePendingInterval(_ source: QueueSource) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    _ = try posthogSession(sbd)
    // #122953's recorded mergeability is UNKNOWN, which makes it pending on its own.
    github.change(122953) { $0["mergeable"] = "MERGEABLE" }
    switch source {
    case .comments: try queue(github)
    case .trunk:
      github.fail(comment: try trunkComment(github))
      try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))
    case .neither: break
    }
    try sbd.poll()
    let id = try #require(github.pr(122953)["id"]?.string)
    let before = github.requests.count

    try sbd.poll()

    let read = github.requests.dropFirst(before).contains { $0.kind == "status" && $0.ids.contains(id) }
    #expect(read == (source != .neither))
  }

  @Test func aQueueWaitResumesTheSessionWithTrunksLabelAndDescription() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "queue")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).waits.count == 1)

    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing, (60, "✖ Cancelled", cancelledText)]))
    try sbd.advanceClock(30_000)

    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(
      sbd, s,
      with: "the merge queue for the session's PR: Trunk removed it from the queue (Cancelled): \(cancelledText)")
    #expect(try sbd.get(s.id).pr?.queueLabel == "Cancelled")
  }

  @Test func aQueueWaitIgnoresATrunkRemovalFromBeforeItWasSet() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, (-60, "✖ Cancelled", cancelledText)]))
    try sbd.poll()
    try sbd.sb("wait", s.id, "--kind", "queue")
    try sbd.advanceClock(30_000)

    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.get(s.id).pr?.queue == .removed)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func aPRThatAWaitNamesRunsTrunkInASessionFolderInItsRepository() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    try queueOpen122179(github)
    try sbd.sb("wait", s.id, "--kind", "queue", "--target", "#122179")
    try sbd.trunkPrints(122179, trunkStatus(122179, [submitted, pending, (60, "✖ Failed", failedText)]))

    try sbd.poll()

    #expect(sbd.trunkCalls() == [TrunkCall(dir: real(s.cwd), args: "merge status 122179")])
    try resumed(sbd, s, with: "the merge queue for #122179: Trunk removed it from the queue (Failed): \(failedText)")
  }

  @Test func aPRThatAWaitNamesWithoutACheckoutOfItsRepositoryKeepsTheCommentsState() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try queueOpen122179(github)
    try sbd.sb("wait", s.id, "--kind", "queue", "--target", "PostHog/posthog#122179")
    try sbd.trunkPrints(122179, trunkStatus(122179, [submitted, pending, (60, "✖ Failed", failedText)]))

    try sbd.poll()
    try sbd.poll(all: true)

    #expect(sbd.trunkCalls().isEmpty)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  /// A session on a branch of another repository is no checkout of the PR's repository. GitHub's names ignore case.
  @Test(arguments: [
    ("PostHog/charts", "haacked/cdp-dlq-runbook-lookup-step", false), ("posthog/POSTHOG", "haacked/other", true),
  ])
  func aPRThatAWaitNamesRunsTrunkOnlyInACheckoutOfItsRepository(_ repo: String, _ branch: String, _ runs: Bool) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try sbd.session(in: repo, branch: branch)
    try queueOpen122179(github)
    try sbd.sb("wait", s.id, "--kind", "queue", "--target", "PostHog/posthog#122179")
    try sbd.trunkPrints(122179, trunkStatus(122179, [submitted, pending, testing]))

    try sbd.poll()

    #expect(sbd.trunkCalls() == (runs ? [TrunkCall(dir: real(s.cwd), args: "merge status 122179")] : []))
  }

  /// trunk that is missing, prints output that the parser doesn't know, or fails without output.
  enum Broken: String, CaseIterable {
    case missing, unrecognized, failed
  }

  @Test(arguments: Broken.allCases)
  func aTrunkThatGivesNoTimelineLeavesTheCommentsState(_ broken: Broken) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    try queue(github)
    switch broken {
    case .missing:
      try FileManager.default.removeItem(atPath: sbd.trunkPath)
    case .unrecognized: try sbd.trunkPrints(122953, "✖ Something new went wrong\n")
    case .failed: try sbd.trunkPrints(122953, "", exit: 1)
    }

    try sbd.poll()

    let pr = try #require(try sbd.get(s.id).pr)
    #expect(pr.queue == .queued)
    #expect(pr.queueLabel == nil)
    #expect(pr.trunkLoginNeeded != true)
  }

  @Test func withoutALoginPollAndPingReportItAndThePRKeepsTheCommentsState() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, notLoggedIn, exit: 1)

    let result = try #require(JSON.parse(try sbd.sb("poll", "--json")))

    #expect(result["trunkRuns"]?.int == 1)
    #expect(result["trunkError"]?.string?.contains("trunk login") == true)
    #expect(try sbd.client.call("ping")["trunk"]?.string?.contains("trunk login") == true)
    let pr = try #require(try sbd.get(s.id).pr)
    #expect(pr.trunkLoginNeeded == true)
    #expect(pr.queue == .queued)
    #expect(try sbd.sb("get", s.id).contains("; trunk login needed"))
  }

  @Test func aReadWithALoginClearsTheMissingLogin() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    let s = try posthogSession(sbd)
    try queue(github)
    try sbd.trunkPrints(122953, notLoggedIn, exit: 1)
    try sbd.poll()
    #expect(try sbd.client.call("ping")["trunk"] != nil)
    try sbd.trunkPrints(122953, trunkStatus(122953, [submitted, pending, testing]))
    try sbd.advanceClock(30_000)

    let result = try sbd.poll()

    #expect(result["trunkError"] == nil)
    #expect(try sbd.client.call("ping")["trunk"] == nil)
    let pr = try #require(try sbd.get(s.id).pr)
    #expect(pr.trunkLoginNeeded != true)
    #expect(pr.queue == .testing)
  }

  @Test func pollWithoutQueuedPRsReportsNoTrunkReads() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withTrunk(github)
    _ = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")

    let result = try #require(JSON.parse(try sbd.sb("poll", "--json")))

    #expect(result["trunkRuns"]?.int == 0)
    #expect(result["trunkError"] == nil)
  }
}
