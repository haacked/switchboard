import Foundation
import Testing

@testable import SwitchboardCore

private let cancelledText = "Pull request was removed from the merge queue because it was canceled by Phil Haack."
private let failedText =
  "Pull request was removed from the merge queue because the following required check failed: `Django Tests`."

private func entry(_ time: Int64, _ label: String, _ state: TrunkQueueState, _ text: String = "")
  -> TrunkTimeline.Entry
{
  TrunkTimeline.Entry(time: time, label: label, state: state, text: text)
}

private func trunkFound(_ entries: [TrunkTimeline.Entry]) -> TrunkTimeline.Result {
  .found(TrunkTimeline(number: 42, title: "fix: a thing", author: "haacked", entries: entries))
}

/// A timeline whose newest entry removes the PR, after a testing entry.
private let removedTimeline = trunkFound([
  entry(ms("2026-10-25T01:00:00.000Z"), "Testing", .testing, "Tests ran."),
  entry(ms("2026-10-25T02:00:00.123Z"), "Cancelled", .removed, cancelledText),
])

private let openPR = samplePR()

/// The comments of a PR that Trunk is testing, according to its status comment.
private let testingComments = [status(trunkTesting)]

@Suite struct ShownWithTrunk {
  @Test func foundTimelineSetsTheQueueToItsNewestState() {
    let shown = GitHub.shown(openPR, testingComments, trunk: removedTimeline, last: nil)

    #expect(shown.queue == .removed)
  }

  @Test func foundTimelineSetsQueueAtToTheNewestEntrysTime() {
    let shown = GitHub.shown(openPR, testingComments, trunk: removedTimeline, last: nil)

    #expect(shown.queueAt == ms("2026-10-25T02:00:00.123Z"))
  }

  @Test func foundTimelineSetsTheQueueLabelToTheNewestEntrysLabel() {
    let shown = GitHub.shown(openPR, testingComments, trunk: removedTimeline, last: nil)

    #expect(shown.queueLabel == "Cancelled")
  }

  @Test func foundTimelineSetsTheQueueTextToTheNewestEntrysText() {
    let shown = GitHub.shown(openPR, testingComments, trunk: removedTimeline, last: nil)

    #expect(shown.queueText == cancelledText)
  }

  @Test func foundTimelineDoesNotAskForALogin() {
    let shown = GitHub.shown(openPR, testingComments, trunk: removedTimeline, last: nil)

    #expect(shown.trunkLoginNeeded != true)
  }

  /// Comments that show the PR in the queue, a state that didn't load, or the timeline's own final state.
  @Test(arguments: [
    [status(trunkTesting)],
    [status(trunkTesting), PRComment(id: "x", author: "trunk-io[bot]", createdAt: trunkTime, edited: true)],
    [status(trunkCancelled, at: "2026-10-26T00:00:00Z")],
  ])
  func foundTimelineWinsWhileTheCommentsAgreeOrLag(_ comments: [PRComment]) {
    let shown = GitHub.shown(openPR, comments, trunk: removedTimeline, last: nil)

    #expect(shown.queue == .removed)
    #expect(shown.queueLabel == "Cancelled")
  }

  /// Comments that name no state, or a final state other than the timeline's.
  @Test(arguments: [[PRComment](), [status(trunkControl)], [status(trunkMerged, at: "2026-10-26T00:00:00Z")]])
  func commentsThatMovedOnWinOverTheTimeline(_ comments: [PRComment]) {
    let fromComments = GitHub.shown(openPR, comments, last: nil)

    let shown = GitHub.shown(openPR, comments, trunk: removedTimeline, last: nil)

    #expect(shown.queue == fromComments.queue)
    #expect(shown.queueLabel == nil)
  }

  /// Every result except a timeline with entries leaves the queue fields that the comments give.
  static let resultsThatKeepTheComments: [TrunkTimeline.Result?] = [
    nil, .notFound, .notLoggedIn, .unrecognized("✖ Something new went wrong"), trunkFound([]),
  ]

  @Test(arguments: ShownWithTrunk.resultsThatKeepTheComments)
  func resultWithoutEntriesKeepsTheCommentsQueueState(_ result: TrunkTimeline.Result?) {
    let shown = GitHub.shown(openPR, testingComments, trunk: result, last: nil)

    #expect(shown.queue == .testing)
  }

  @Test(arguments: ShownWithTrunk.resultsThatKeepTheComments)
  func resultWithoutEntriesKeepsTheCommentsQueueTime(_ result: TrunkTimeline.Result?) {
    let shown = GitHub.shown(openPR, testingComments, trunk: result, last: nil)

    #expect(shown.queueAt == ms("2026-10-25T00:00:00.000Z"))
  }

  @Test(arguments: ShownWithTrunk.resultsThatKeepTheComments)
  func resultWithoutEntriesHasNoQueueLabelOrText(_ result: TrunkTimeline.Result?) {
    let shown = GitHub.shown(openPR, testingComments, trunk: result, last: nil)

    #expect(shown.queueLabel == nil)
    #expect(shown.queueText == nil)
  }

  @Test(arguments: ShownWithTrunk.resultsThatKeepTheComments)
  func resultWithoutEntriesKeepsAnUnknownCommentState(_ result: TrunkTimeline.Result?) {
    let unloaded = PRComment(id: "x", author: "trunk-io[bot]", createdAt: trunkTime, edited: true)

    let shown = GitHub.shown(openPR, [unloaded], trunk: result, last: nil)

    #expect(shown.queue == .unknown)
  }

  @Test(arguments: ShownWithTrunk.resultsThatKeepTheComments)
  func resultWithoutEntriesKeepsNoQueueStateWhenTheCommentsNameNone(_ result: TrunkTimeline.Result?) {
    let shown = GitHub.shown(openPR, [status(trunkControl)], trunk: result, last: nil)

    #expect(shown.queue == nil)
  }

  @Test func notLoggedInAsksForALogin() {
    let shown = GitHub.shown(openPR, testingComments, trunk: .notLoggedIn, last: nil)

    #expect(shown.trunkLoginNeeded == true)
  }

  @Test(arguments: [TrunkTimeline.Result?.none, .notFound, .unrecognized("?"), trunkFound([]), removedTimeline])
  func everyOtherResultDoesNotAskForALogin(_ result: TrunkTimeline.Result?) {
    let shown = GitHub.shown(openPR, testingComments, trunk: result, last: nil)

    #expect(shown.trunkLoginNeeded != true)
  }

  static let finishedWithEachResult: [(PRState, TrunkTimeline.Result)] = [
    (.merged, removedTimeline), (.closed, removedTimeline), (.merged, .notLoggedIn), (.closed, .notLoggedIn),
  ]

  @Test(arguments: ShownWithTrunk.finishedWithEachResult)
  func finishedPRIgnoresTheTrunkQueueState(_ state: PRState, _ result: TrunkTimeline.Result) {
    let shown = GitHub.shown(samplePR(state: state), testingComments, trunk: result, last: nil)

    #expect(shown.queue == nil)
  }

  @Test(arguments: ShownWithTrunk.finishedWithEachResult)
  func finishedPRIgnoresTheTrunkQueueTime(_ state: PRState, _ result: TrunkTimeline.Result) {
    let shown = GitHub.shown(samplePR(state: state), testingComments, trunk: result, last: nil)

    #expect(shown.queueAt == nil)
  }

  @Test(arguments: ShownWithTrunk.finishedWithEachResult)
  func finishedPRIgnoresTheTrunkLabelAndText(_ state: PRState, _ result: TrunkTimeline.Result) {
    let shown = GitHub.shown(samplePR(state: state), testingComments, trunk: result, last: nil)

    #expect(shown.queueLabel == nil)
    #expect(shown.queueText == nil)
  }

  @Test(arguments: ShownWithTrunk.finishedWithEachResult)
  func finishedPRIgnoresTheTrunkLogin(_ state: PRState, _ result: TrunkTimeline.Result) {
    let shown = GitHub.shown(samplePR(state: state), testingComments, trunk: result, last: nil)

    #expect(shown.trunkLoginNeeded != true)
  }

  @Test func foundTimelineKeepsTheMergeabilityRule() {
    var pr = samplePR(mergeable: .unknown)
    pr.headSha = "h1"
    var last = pr
    last.mergeable = .conflicting

    let shown = GitHub.shown(pr, testingComments, trunk: removedTimeline, last: last)

    #expect(shown.mergeable == .conflicting)
  }

  @Test func recordedTimelineSetsTheQueueLabelAndTextFromItsLastRow() throws {
    let output = try trunkFixture("cancelled-by-user")
    let now = ms("2026-10-19T23:06:47.364Z")

    let shown = GitHub.shown(openPR, testingComments, trunk: TrunkTimeline.parse(output, now: now), last: nil)

    #expect(shown.queueLabel == "Cancelled")
    #expect(shown.queueText == cancelledText)
    #expect(shown.queueAt == ms("2026-10-19T22:51:57.959Z"))
  }
}

@Suite struct TrunkQueueWait {
  static let set = epochMs(2030, 6, 15, 12, 0, zone: utc)

  func wait() -> Wait {
    var w = waitOn(.queue)
    w.created = Self.set
    return w
  }

  func pr(
    _ state: PRState = .open, queue: TrunkQueueState?, at: Int64 = TrunkQueueWait.set + 1000, label: String? = nil,
    text: String? = nil
  ) -> PullRequest {
    var pr = PullRequest(id: "PR_1", number: 7, url: "", repo: "a/b", state: state, queue: queue)
    pr.queueAt = queue == nil ? nil : at
    pr.queueLabel = label
    pr.queueText = text
    return pr
  }

  @Test func removalWithALabelAndTextNamesTrunksLabelAndDescription() {
    #expect(
      wait().resolution(of: pr(queue: .removed, label: "Cancelled", text: cancelledText))
        == "Trunk removed it from the queue (Cancelled): " + cancelledText)
  }

  @Test func removalWithAFailedLabelNamesTheFailure() {
    #expect(
      wait().resolution(of: pr(queue: .removed, label: "Failed", text: failedText))
        == "Trunk removed it from the queue (Failed): " + failedText)
  }

  @Test(arguments: [(String?.none, String?.none), ("Cancelled", nil), (nil, cancelledText)])
  func removalWithoutBothALabelAndTextKeepsTheShortOutcome(_ label: String?, _ text: String?) {
    #expect(
      wait().resolution(of: pr(queue: .removed, label: label, text: text)) == "Trunk removed it from the queue")
  }

  @Test(arguments: [(String?.none, String?.none), ("Merged", "Pull request has been merged successfully.")])
  func mergeKeepsTheShortOutcome(_ label: String?, _ text: String?) {
    #expect(wait().resolution(of: pr(queue: .merged, label: label, text: text)) == "Trunk merged it")
  }

  @Test(arguments: [TrunkQueueWait.set - 1000, TrunkQueueWait.set])
  func removalFromTrunkBeforeTheWaitKeepsItOpen(_ at: Int64) {
    #expect(wait().resolution(of: pr(queue: .removed, at: at, label: "Cancelled", text: cancelledText)) == nil)
  }

  @Test(arguments: [TrunkQueueState.submitted, .pending, .testing, .passed, .failing, .queued])
  func trunkStateThatHoldsThePRKeepsTheWaitOpen(_ state: TrunkQueueState) {
    #expect(wait().resolution(of: pr(queue: state, label: "Testing", text: "Tests ran.")) == nil)
  }

  @Test(arguments: [PRState.merged, .closed])
  func finishedPRResolvesFromItsStateNotTheLabel(_ state: PRState) {
    let expected = state == .merged ? "it merged" : "it closed without merging"

    #expect(wait().resolution(of: pr(state, queue: .removed, label: "Cancelled", text: cancelledText)) == expected)
  }

  /// Every queue state at a time before, at, and after the wait was set.
  static let stateTimes: [(TrunkQueueState, Int64)] = [
    TrunkQueueState.submitted, .pending, .testing, .passed, .failing, .queued, .merged, .removed, .unknown,
  ].flatMap { s in [TrunkQueueWait.set - 1000, TrunkQueueWait.set, TrunkQueueWait.set + 1000].map { (s, $0) } }

  /// The comments and trunk give the same state and time, so the wait resolves or stays open the same way.
  @Test(arguments: TrunkQueueWait.stateTimes)
  func trunkAndCommentsAgreeOnWhetherTheWaitResolves(_ state: TrunkQueueState, _ at: Int64) {
    let fromComments = pr(queue: state, at: at)
    let fromTrunk = pr(queue: state, at: at, label: "Label", text: "Text.")

    #expect((wait().resolution(of: fromComments) == nil) == (wait().resolution(of: fromTrunk) == nil))
  }
}

private func withLabel(_ pr: PullRequest, _ label: String?) -> PullRequest {
  var pr = pr
  pr.queueLabel = label
  return pr
}

@Suite struct TrunkRemovalAttention {
  static let removed = [samplePR(queue: .removed), samplePR(reviewDecision: .approved, queue: .removed)]

  @Test(arguments: TrunkRemovalAttention.removed)
  func removalWithALabelNamesTrunksLabel(_ pr: PullRequest) throws {
    let f = try prFacts(withLabel(pr, "Failed"), comments: testingComments)

    #expect(
      Attention.evaluate(session(), f, now: 10)
        == Verdict(state: .needsYou, reason: "find out why Trunk removed #42 from its queue (Failed)"))
  }

  @Test(arguments: TrunkRemovalAttention.removed)
  func removalWithoutALabelKeepsTheShortReason(_ pr: PullRequest) throws {
    let f = try prFacts(withLabel(pr, nil), comments: testingComments)

    #expect(
      Attention.evaluate(session(), f, now: 10)
        == Verdict(state: .needsYou, reason: "find out why Trunk removed #42 from its queue"))
  }
}

@Suite struct TrunkSummary {
  static func pr(
    checks: String? = "SUCCESS", queue: TrunkQueueState? = nil, label: String? = nil, login: Bool? = nil
  ) -> PullRequest {
    var pr = PullRequest(
      id: "PR_1", number: 122953, url: "https://github.com/PostHog/posthog/pull/122953", repo: "PostHog/posthog",
      reviewDecision: .approved, checks: checks, queue: queue)
    pr.queueLabel = label
    pr.trunkLoginNeeded = login
    return pr
  }

  @Test(arguments: [
    (pr(), "#122953 Approved, checks success"),
    (pr(queue: .unknown), "#122953 Approved, checks success"),
    (pr(queue: .testing), "#122953 Approved, checks success, Trunk testing"),
    (pr(checks: nil, queue: .pending), "#122953 Approved, Trunk pending"),
    (pr(queue: .removed), "#122953 Approved, checks success, Trunk removed"),
    (pr(queue: .failing, label: "Pending Failure"), "#122953 Approved, checks success, Trunk pending failure"),
    (pr(queue: .removed, label: "Cancelled"), "#122953 Approved, checks success, Trunk cancelled"),
    (pr(queue: .submitted, label: "Not Ready"), "#122953 Approved, checks success, Trunk not ready"),
    (pr(login: true), "#122953 Approved, checks success; trunk login needed"),
    (pr(queue: .queued, login: true), "#122953 Approved, checks success, Trunk queued; trunk login needed"),
    (pr(queue: .unknown, login: true), "#122953 Approved, checks success; trunk login needed"),
    (pr(checks: nil, login: true), "#122953 Approved; trunk login needed"),
    (pr(queue: .testing, login: false), "#122953 Approved, checks success, Trunk testing"),
  ])
  func lineNamesTheTrunkStateAndTheMissingLogin(_ pr: PullRequest, _ line: String) {
    #expect(PRSummary(pr).line == line)
  }

  @Test func summaryTakesThePRsLabel() {
    #expect(PRSummary(Self.pr(queue: .failing, label: "Pending Failure")).queueLabel == "Pending Failure")
  }

  @Test func summaryWithoutALabelHasNoLabel() {
    #expect(PRSummary(Self.pr(queue: .testing)).queueLabel == nil)
  }

  @Test(arguments: [true, false, nil] as [Bool?])
  func summaryTakesTheLoginFlag(_ login: Bool?) {
    #expect(PRSummary(Self.pr(login: login)).trunkLoginNeeded == login)
  }
}

@Suite struct TrunkPullRequestCoding {
  @Test func prWithTrunksLabelAndTextDecodesToTheSamePR() throws {
    var pr = TrunkSummary.pr(queue: .removed, label: "Cancelled", login: true)
    pr.queueText = cancelledText

    let decoded = try JSONCoding.convert(pr, to: PullRequest.self)

    #expect(decoded == pr)
  }

  @Test func prRecordedWithoutTheTrunkFieldsDecodes() throws {
    let old =
      #"{"id":"PR_1","number":7,"url":"","repo":"a/b","title":"","state":"OPEN","draft":false,"head":"","headSha":"","base":"main","verdicts":[],"reviews":[],"labels":[],"queue":"testing"}"#

    let decoded = try JSONCoding.decode(PullRequest.self, from: old)

    #expect(decoded.queue == .testing)
    #expect(decoded.queueLabel == nil)
    #expect(decoded.queueText == nil)
    #expect(decoded.trunkLoginNeeded == nil)
  }
}

@Suite struct TrunkConfig {
  @Test func defaultSettingsRunTrunkFromThePathWithA30SecondTimeout() {
    let settings = TrunkSettings()

    #expect(settings.path == "trunk")
    #expect(settings.timeoutSeconds == 30)
  }

  @Test func configWithoutTrunkUsesTheDefaultSettings() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"idleStopSeconds": 30}"#)

    #expect(c.trunk == TrunkSettings())
  }

  @Test func missingTimeoutKeepsItsDefault() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"trunk": {"path": "/opt/trunk"}}"#)

    #expect(c.trunk.path == "/opt/trunk")
    #expect(c.trunk.timeoutSeconds == 30)
  }

  @Test func missingPathKeepsItsDefault() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"trunk": {"timeoutSeconds": 5}}"#)

    #expect(c.trunk.path == "trunk")
    #expect(c.trunk.timeoutSeconds == 5)
  }
}

/// A home folder with Trunk's launcher cache, removed when the test ends.
private final class LauncherHome {
  let path: String

  init() throws {
    path = FileManager.default.temporaryDirectory.appendingPathComponent("trunk-home-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: cli, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(atPath: path) }

  var cli: String { "\(path)/.cache/trunk/cli" }

  /// Adds a version folder, with a `trunk` file when `trunk` is true.
  @discardableResult
  func add(_ version: String, trunk: Bool = true, executable: Bool = true) throws -> String {
    let dir = "\(cli)/\(version)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = "\(dir)/trunk"
    if trunk {
      FileManager.default.createFile(
        atPath: file, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: executable ? 0o755 : 0o644])
    }
    return file
  }
}

@Suite struct TrunkLauncherCache {
  @Test(arguments: [
    (["1.9.0", "1.25.0"], "1.25.0"),
    (["1.25.0", "1.9.0"], "1.25.0"),
    (["1.9.9", "1.10.0"], "1.10.0"),
    (["2.0.0", "10.0.0"], "10.0.0"),
    (["1.22.10", "1.22.9"], "1.22.10"),
  ])
  func versionsCompareNumerically(_ versions: [String], _ newest: String) throws {
    let home = try LauncherHome()
    for v in versions { try home.add(v) }

    #expect(TrunkSettings.launcherCache(home: home.path) == "\(home.cli)/\(newest)/trunk")
  }

  @Test func newerVersionWithoutTrunkIsSkipped() throws {
    let home = try LauncherHome()
    let older = try home.add("1.24.0")
    try home.add("1.25.0", trunk: false)

    #expect(TrunkSettings.launcherCache(home: home.path) == older)
  }

  @Test func newerVersionWhoseTrunkIsNotExecutableIsSkipped() throws {
    let home = try LauncherHome()
    let older = try home.add("1.24.0")
    try home.add("1.25.0", executable: false)

    #expect(TrunkSettings.launcherCache(home: home.path) == older)
  }

  @Test func cacheWithoutAnExecutableTrunkHasNone() throws {
    let home = try LauncherHome()
    try home.add("1.25.0", trunk: false)
    try home.add("1.24.0", executable: false)

    #expect(TrunkSettings.launcherCache(home: home.path) == nil)
  }

  @Test func emptyCacheHasNone() throws {
    let home = try LauncherHome()

    #expect(TrunkSettings.launcherCache(home: home.path) == nil)
  }

  @Test func homeWithoutACacheHasNone() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-home-\(UUID().uuidString)").path

    #expect(TrunkSettings.launcherCache(home: missing) == nil)
  }
}
