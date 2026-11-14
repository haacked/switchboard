import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// An sbd whose GitHub poller reads the fake only when a test asks. The
  /// poll interval still sets the wait after a turn, which is two intervals.
  /// The idle stop comes after the longest clock move in these tests.
  static func withRequestHold(_ github: FakeGitHub) throws -> Instance {
    try Instance(
      idleStopSeconds: 7200,
      config: [
        "github": [
          "gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url),
          "pollSeconds": .number(InboxRequestTests.pollSeconds),
        ],
        "tickSeconds": 1,
      ])
  }

  /// The time of the session's last `request` event.
  func requestTime(_ id: String) throws -> Int64 {
    try #require(try events(id).last { $0.kind == "request" }).t
  }
}

/// A click on a rule item's send option records a request, which holds the
/// session in Waiting while the session works on it.
@Suite(.blocking(timeLimit: .seconds(120))) struct InboxRequestTests {
  /// The real-time poller never fires within a test at this interval.
  static let pollSeconds: Double = 600
  static let readMs = Int64(pollSeconds) * 2 * 1000
  static let minuteMs: Int64 = 60_000
  static let conflict = "merge main in; #18303 conflicts with main"
  static let message = "Merge origin/main into this branch, resolve the conflicts, run the tests, and push."

  /// A session on #18303's branch whose PR conflicts with main, so the conflict rule's item is in the Inbox.
  func conflictingSession(_ github: FakeGitHub, _ sbd: Instance) throws -> SessionSummary {
    github.change(MergeTests.number) { $0["mergeable"] = "CONFLICTING" }
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    return try sbd.waitFor(s.id, "the conflict rule's item") {
      $0.reason == Self.conflict && $0.triage?.source == .rule
    }
  }

  /// Clicks the conflict item's Merge main option and waits for the turn that it starts to end.
  func chooseMerge(_ sbd: Instance, _ s: SessionSummary) throws {
    try sbd.sb("choose", s.id, "Merge main")
    try sbd.waitFor(s.id, "the reply to the merge request") { $0.lastReply == "Done: \(Self.message)" }
  }

  /// Sends the message as a click would, and waits for its reply when sbd accepts it.
  func send(_ sbd: Instance, _ s: SessionSummary, ref: String) throws {
    let args: [String: JSON] = ["session": .string(s.id), "text": .string(Self.message), "ref": .string(ref)]
    guard (try? sbd.client.call("send", args)) != nil else { return }
    try sbd.waitFor(s.id, "the reply to the message") { $0.lastReply == "Done: \(Self.message)" }
  }

  func held(_ at: Int64, _ work: String) -> String {
    "you asked at \(Wait.formatTime(at)): \(Self.conflict); \(work)"
  }

  @Test func chooseOnTheConflictItemRecordsTheRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)

    try chooseMerge(sbd, s)

    #expect(try sbd.count("request", of: s.id) == 1)
    let request = try #require(try sbd.events(s.id).last { $0.kind == "request" })
    #expect(request.data["state"]?.string == "needs_you")
    #expect(request.data["reason"]?.string == Self.conflict)
    #expect(request.data["head"]?.string == MergeTests().head(github))
    #expect(request.data["message"]?.string == Self.message)
  }

  @Test func requestEventCarriesItsTimeLimitAndReadWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)

    try chooseMerge(sbd, s)

    let request = try #require(try sbd.events(s.id).last { $0.kind == "request" })
    // sbd may read its clock once for `until` and again for the event's time.
    let limit = try #require(request.data["until"]?.int.map(Int64.init)) - request.t
    #expect((3_599_000...3_601_000).contains(limit))
    #expect(request.data["readMs"]?.int.map(Int64.init) == Self.readMs)
  }

  @Test func sendWithTheRuleItemsRefRecordsTheRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    let item = try #require(try sbd.get(s.id).triage)

    try send(sbd, s, ref: item.ref)

    #expect(try sbd.count("request", of: s.id) == 1)
  }

  /// The message is the option's own text, so only the missing ref keeps sbd from recording a request.
  @Test func sendWithoutARefRecordsNoRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)

    try sbd.sb("send", s.id, Self.message)
    try sbd.waitFor(s.id, "the reply to the message") { $0.lastReply == "Done: \(Self.message)" }

    #expect(try sbd.count("request", of: s.id) == 0)
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == Self.conflict)
    #expect(row["requested"] == nil)
  }

  @Test func sendWithAnOutdatedRefRecordsNoRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)

    try send(sbd, s, ref: "rule:an item the user saw earlier")

    #expect(try sbd.count("request", of: s.id) == 0)
  }

  /// Only a send or reply option records a request, even on a rule item.
  @Test func chooseAcknowledgeOnARuleItemRecordsNoRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    let item = try #require(try sbd.get(s.id).triage)
    try #require(item.source == .rule)
    try #require(item.options.contains { $0.label == "Acknowledge" && $0.action == .dismiss })

    try sbd.sb("choose", s.id, "Acknowledge")

    #expect(try sbd.count("request", of: s.id) == 0)
  }

  /// A summary item comes from the reply, not from a rule.
  @Test func chooseOnASummaryItemRecordsNoRequest() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "ask")
    try sbd.waitFor(s.id, "the summary") { $0.triage?.source == .summary }

    try sbd.sb("choose", s.id, "1")
    try sbd.waitFor(s.id, "the reply to the choice") { $0.lastReply == "Done: Use Postgres." }

    #expect(try sbd.count("request", of: s.id) == 0)
  }

  @Test func chosenSessionIsWaitingWithRequestedWhileGitHubReadsThePR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)

    try chooseMerge(sbd, s)

    let at = try sbd.requestTime(s.id)
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["requested"]?.bool == true)
    #expect(row["reason"]?.string == held(at, "waiting for GitHub to read the PR"))
  }

  @Test func getJSONShowsTheHeldSessionAsRequested() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)

    try chooseMerge(sbd, s)

    let got = try sbd.getJSON(s.id)
    #expect(got["state"]?.string == "waiting")
    #expect(got["requested"]?.bool == true)
  }

  /// The incident: a job runs when the user clicks, and the click's turn ends while it runs.
  @Test func chosenSessionIsWaitingWhileABackgroundJobRuns() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    try sbd.sb("send", s.id, "background 100 free")
    try sbd.waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
    try sbd.advanceClock(1)
    #expect(try sbd.get(s.id).reason == Self.conflict)

    try chooseMerge(sbd, s)
    try sbd.advanceClock(Self.readMs + Self.minuteMs)

    let at = try sbd.requestTime(s.id)
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["requested"]?.bool == true)
    #expect(row["reason"]?.string == held(at, "1 background job running"))
    let got = try sbd.getJSON(s.id)
    #expect(got["state"]?.string == "waiting")
    #expect(got["requested"]?.bool == true)
  }

  @Test func heldSessionLeavesTheInbox() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)

    try chooseMerge(sbd, s)

    #expect(try !sbd.triage().map(\.id).contains(s.id))
  }

  @Test func holdSurvivesAnSbdRestart() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    try chooseMerge(sbd, s)

    sbd.stopSbd()
    try sbd.startSbd()

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["requested"]?.bool == true)
  }

  @Test func ackUndoPutsAHeldSessionBackInNeedsYou() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    try chooseMerge(sbd, s)
    #expect(try sbd.listed(s.id)["requested"]?.bool == true)

    try sbd.sb("ack", "--undo", s.id)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == Self.conflict)
    #expect(row["requested"] == nil)
    #expect(try sbd.count("unack", of: s.id) == 1)
  }

  @Test func ackUndoBringsTheMergeOptionBack() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    try chooseMerge(sbd, s)

    try sbd.sb("ack", "--undo", s.id)

    #expect(try sbd.get(s.id).triage?.options.map(\.label) == ["Merge main"])
  }

  @Test func turnThatLeavesNoWorkBringsTheSessionBackOnceTheReadWaitPasses() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    try chooseMerge(sbd, s)

    try sbd.advanceClock(Self.readMs + Self.minuteMs)

    let at = try sbd.requestTime(s.id)
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(
      row["reason"]?.string
        == "\(Self.conflict) (you asked at \(Wait.formatTime(at)); the session stopped without doing it)")
    #expect(row["requested"] == nil)
    #expect(try sbd.get(s.id).triage?.options.map(\.label) == ["Merge main"])
  }

  /// A stall: the job exits, claude reports it in a turn of its own,
  /// and that turn ends with the PR still conflicting at the same head.
  @Test func reportedJobWhoseTurnStopsWithoutTheMergeBringsTheSessionBack() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    try sbd.sb("send", s.id, "background 100 free")
    try sbd.waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
    try chooseMerge(sbd, s)
    try sbd.advanceClock(1)
    #expect(try sbd.listed(s.id)["state"]?.string == "waiting")
    let stops = try sbd.events(s.id).filter { $0.kind == "Stop" }.count

    try sbd.endJob()
    try sbd.waitFor("the turn that reports the job") {
      try sbd.events(s.id).filter { $0.kind == "Stop" }.count == stops + 1
    }
    try sbd.advanceClock(Self.readMs + Self.minuteMs)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string?.hasSuffix("; the session stopped without doing it)") == true)
    #expect(row["requested"] == nil)
  }

  @Test func newHeadCommitEndsTheHold() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withRequestHold(github)
    let s = try conflictingSession(github, sbd)
    try chooseMerge(sbd, s)

    github.change(MergeTests.number) { $0["headRefOid"] = "c0ffee1" }
    try sbd.poll(all: true)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == Self.conflict)
    #expect(row["requested"] == nil)
  }
}
