import Foundation
import SwitchboardCore
import Testing

extension Instance {
  func activityStatus() throws -> ActivityStatus {
    try JSONCoding.decode(ActivityStatus.self, from: try sb("activity", "status", "--json"))
  }

  func activityReport(_ extra: String...) throws -> ActivityReport {
    try JSONCoding.decode(ActivityReport.self, from: try sb(["activity", "report", "--json"] + extra))
  }

  /// Waits until the report holds `count` resumes with the trigger, and returns that row.
  @discardableResult
  func waitForResumes(_ trigger: LaunchTrigger, count: Int = 1) throws -> ResumeTiming {
    try waitFor(
      "\(count) \(trigger.rawValue) resumes in the activity report",
      fetch: { try activityReport().resumes.first { $0.trigger == trigger.rawValue } },
      until: { $0.count >= count })
  }

  func triggers(_ id: String) throws -> [String?] {
    try events(id).filter { $0.kind == "resumed" }.map { $0.data["trigger"]?.string }
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct ActivityLogCommandTests {
  /// A session that answered one prompt, with its claude stopped.
  func stoppedSession(_ sbd: Instance, prompt: String = "hello") throws -> SessionSummary {
    let s = try sbd.new(prompt: prompt)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: \(prompt)" }
    return try stop(sbd, s)
  }

  /// A session whose one `open` resume the activity log recorded.
  @discardableResult
  func sessionWithOneLoggedResume(_ sbd: Instance) throws -> SessionSummary {
    let s = try stoppedSession(sbd)
    try sbd.sb("activity", "on")
    try sbd.sb("open", s.id)
    try sbd.waitForResumes(.open)
    return s
  }

  @discardableResult
  func stop(_ sbd: Instance, _ s: SessionSummary) throws -> SessionSummary {
    try sbd.sb("stop", s.id)
    return try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
  }

  @Test func isOffByDefaultAndRecordsNothing() throws {
    let sbd = try Instance()
    let s = try stoppedSession(sbd)

    try sbd.sb("open", s.id)
    try sbd.waitFor(s.id, "the resume") { $0.claudePid != nil && $0.live }

    #expect(try sbd.activityStatus() == ActivityStatus(enabled: false, events: 0, oldest: nil))
    #expect(try sbd.activityReport().resumes.isEmpty)
    #expect(try sbd.triggers(s.id) == ["open"])
  }

  @Test func recordsEachResumeWithWhatCausedIt() throws {
    let sbd = try Instance()
    let s = try stoppedSession(sbd)
    try sbd.sb("activity", "on")

    try sbd.sb("open", s.id)
    let open = try sbd.waitForResumes(.open)
    try stop(sbd, s)
    try sbd.sb("send", s.id, "again")
    let send = try sbd.waitForResumes(.send)
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: again" }
    try stop(sbd, s)
    try sbd.sb("resume", s.id)
    let resume = try sbd.waitForResumes(.resume)

    #expect(try sbd.triggers(s.id) == ["open", "send", "resume"])
    #expect([open, send, resume].allSatisfy { $0.count == 1 && $0.userCaused && $0.maxMs >= 0 })
    #expect(try sbd.activityStatus().events == 3)
  }

  @Test func aStartThatQueuedBehindTheCapKeepsItsTrigger() throws {
    let sbd = try Instance(config: ["liveCap": 1])
    let s = try stoppedSession(sbd)
    let other = try sbd.new(prompt: "busy", name: "other")
    try sbd.waitFor(other.id, "the other reply") { $0.lastReply == "Done: busy" }
    try sbd.sb("activity", "on")

    try sbd.sb("open", s.id)
    #expect(try sbd.events(s.id).contains { $0.kind == "start-queued" })

    // sbd stops the idle session to make room for the queued start.
    try sbd.waitForResumes(.open)
    #expect(try sbd.triggers(s.id) == ["open"])
  }

  @Test func aNoticeToAParentIsNotByTheUser() throws {
    let sbd = try Instance()
    let parent = try stoppedSession(sbd)
    try sbd.sb("activity", "on")
    let child = try sbd.client.call(
      "new", ["path": .string(sbd.work), "prompt": "hello", "parent": .string(parent.id)], as: SessionSummary.self)
    try sbd.waitFor(child.id, "the child's reply") { $0.lastReply == "Done: hello" }

    let notice = try sbd.waitForResumes(.notice)

    #expect(!notice.userCaused)
    #expect(try sbd.triggers(parent.id).last == "notice")
  }

  func postSessionStart(_ sbd: Instance, _ id: String, claudeSessionId: String, source: String) throws {
    _ = try sbd.client.call(
      "hook",
      [
        "session": .string(id),
        "payload": [
          "hook_event_name": "SessionStart", "session_id": .string(claudeSessionId), "source": .string(source),
        ],
      ])
  }

  @Test func onlyTheFirstSessionStartAfterAResumeCounts() throws {
    let sbd = try Instance()
    let s = try sessionWithOneLoggedResume(sbd)

    try postSessionStart(sbd, s.id, claudeSessionId: s.claudeSessionId, source: "compact")

    #expect(try sbd.activityStatus().events == 1)
  }

  /// The stub runs no hooks after the restart, so only the SessionStart that the test posts reaches sbd.
  @Test(arguments: [true, false])
  func onlyASessionStartOfTheSameConversationCounts(sameConversation: Bool) throws {
    let sbd = try Instance()
    let s = try stoppedSession(sbd)
    try sbd.restart(setting: "env", to: ["STUB_HOOKS": "off"])
    try sbd.sb("activity", "on")
    try sbd.sb("resume", s.id)
    try sbd.waitFor("the resume event") { try sbd.triggers(s.id) == ["resume"] }

    let conversation = sameConversation ? s.claudeSessionId : UUID().uuidString.lowercased()
    try postSessionStart(sbd, s.id, claudeSessionId: conversation, source: "resume")

    #expect(try sbd.activityStatus().events == (sameConversation ? 1 : 0))
  }

  @Test func aFreshStartIsNotAResume() throws {
    let sbd = try Instance()
    try sbd.sb("activity", "on")

    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }

    #expect(try sbd.activityStatus().events == 0)
  }

  @Test func aReportRefusesADurationPastTheClock() throws {
    let sbd = try Instance()

    #expect(throws: (any Error).self) { try sbd.client.call("activity-report", ["durationMs": 1e19]) }
    #expect(try sbd.client.call("ping")["pid"] != nil)
  }

  @Test func theLogOutlivesTheSessionUntilCleared() throws {
    let sbd = try Instance()
    let s = try sessionWithOneLoggedResume(sbd)

    try sbd.sb("rm", s.id)

    #expect(try sbd.activityStatus().events == 1)
    try sbd.sb("activity", "clear")
    #expect(try sbd.activityStatus().events == 0)
  }

  @Test func theSwitchSurvivesARestart() throws {
    let sbd = try Instance()
    try sbd.sb("activity", "on")

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.activityStatus().enabled)
    try sbd.sb("activity", "off")
    #expect(try !sbd.activityStatus().enabled)
  }

  @Test func sinceLimitsTheReportToRecentRows() throws {
    let sbd = try Instance()
    try sessionWithOneLoggedResume(sbd)

    try sbd.advanceClock(2 * 24 * 3600 * 1000)

    #expect(try sbd.activityReport("--since", "1d").events == 0)
    #expect(try sbd.activityReport("--since", "3d").events == 1)
    #expect(try sbd.run("activity", "report", "--since", "soon").status != 0)
  }

  @Test func rowsPastTheRetentionAreDeleted() throws {
    let sbd = try Instance()
    try sessionWithOneLoggedResume(sbd)

    try sbd.advanceClock(ActivityLog.retentionMs + 24 * 3600 * 1000)

    try sbd.waitFor("the prune") { try sbd.activityStatus().events == 0 }
  }
}
