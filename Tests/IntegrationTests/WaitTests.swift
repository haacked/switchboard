import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct WaitTests {
  static let hourMs: Int64 = 3600 * 1000

  /// A session whose first turn has ended.
  func idleSession(_ sbd: Instance, name: String = "t") throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    return s
  }

  /// A session whose stub waits `seconds` after SIGTERM before it exits.
  func lingeringSession(_ sbd: Instance, seconds: Int) throws -> SessionSummary {
    let s = try sbd.new(prompt: "linger \(seconds)")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "I'll linger \(seconds) s when I stop." }
    return s
  }

  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  @Test func aFreeTextWaitIsAManualWait() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    let waiting = try decode(sbd.sb("wait", "--json", s.id, "CI", "on", "#12"))
    #expect(waiting.state == .waiting)
    #expect(waiting.reason == "CI on #12")
    #expect(waiting.waits.map(\.kind) == [.manual])
    #expect(waiting.waits.map(\.by) == [.you])
    let cleared = try decode(sbd.sb("wait", "--json", s.id, "--clear"))
    #expect(cleared.waits.isEmpty)
    #expect(cleared.state != .waiting)
  }

  @Test func aDateWaitStopsTheSessionAndResumesItWhenTheClockPassesIt() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    let waiting = try decode(
      sbd.sb("wait", "--json", s.id, "--kind", "date", "--until", "1h", "--note", "check the dashboard"))
    #expect(waiting.state == .waiting)
    #expect(waiting.reason.hasPrefix("until "))
    // idleStopSeconds is 600, so only the open wait stops it this soon.
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(2 * WaitTests.hourMs)
    let resumed = try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }
    #expect(resumed.lastReply?.hasSuffix(": the time came. Your note: check the dashboard.") == true)
    #expect(resumed.waits.isEmpty)
    #expect(sbd.stubArgs().last?.hasPrefix("--resume \(s.claudeSessionId) ") == true)
    #expect(try sbd.events(s.id).map(\.kind).contains("wait-resolved"))
  }

  @Test func aWaitResolvedWhileClaudeExitsStillResumesTheSession() throws {
    let sbd = try Instance()
    // `send` waits up to 5 s for an exiting claude, so a 7 s exit outlasts it.
    let s = try lingeringSession(sbd, seconds: 7)
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1190")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    // The stub runs for 7 s after the stop, so the resolution meets a claude that is exiting.
    #expect(try sbd.get(s.id).claudePid != nil)
    try sbd.sb("wait", s.id, "--resolve", "#1190 merged")
    try sbd.waitFor(s.id, "the resumed turn", timeout: 30) {
      $0.lastReply == "Done: Switchboard: #1190 to merge: #1190 merged."
    }
  }

  @Test
  func aDateWaitThatPassesWhileClaudeExitsStillResumesTheSession() throws {
    let sbd = try Instance()
    let s = try lingeringSession(sbd, seconds: 3)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(2 * WaitTests.hourMs)
    try sbd.waitFor(s.id, "the resumed turn", timeout: 30) {
      $0.lastReply?.hasPrefix("Done: Switchboard: until ") == true
    }
  }

  @Test func aClaudeThatIsExitingAfterItsSessionEndedStaysNotLive() throws {
    let sbd = try Instance()
    let s = try lingeringSession(sbd, seconds: 8)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    // A tick sees the exiting claude first. Then the clock passes the 10 s that a claude may run without a SessionStart.
    sleep(1)
    try sbd.advanceClock(15_000)
    sleep(1)
    #expect(try sbd.get(s.id).live == false)
    #expect(try sbd.get(s.id).claudePid != nil)
  }

  /// The clock resolves the wait. The session's own SessionEnd stays the last event that counts.
  @Test func aDateWaitThatNotifiesKeepsTheLastActivity() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h", "--then", "notify")
    try sbd.waitFor("the stop's SessionEnd", timeout: 10) {
      try sbd.events(s.id).contains { $0.kind == "SessionEnd" }
    }
    let before = try sbd.get(s.id).lastActivity
    let wait = try #require(try sbd.events(s.id).last { $0.kind == "wait" })
    #expect(before >= wait.t)

    try sbd.advanceClock(2 * WaitTests.hourMs)
    let resolved = try sbd.waitFor(
      "the wait-resolved event", fetch: { try sbd.events(s.id).last { $0.kind == "wait-resolved" } },
      until: { _ in true })

    #expect(resolved.t > before)
    #expect(try sbd.get(s.id).lastActivity == before)
  }

  @Test func aDoneSessionsWaitsDontResumeIt() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.sb("done", s.id)
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(2 * WaitTests.hourMs)
    sleep(1)
    let after = try sbd.get(s.id)
    #expect(after.state == .done)
    #expect(after.waits.count == 1)
    #expect(sbd.stubArgs().count == 1)
  }

  @Test func refusesWordsThatTheFlagsWouldDrop() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let open = try decode(sbd.sb("wait", "--json", s.id, "--kind", "merge", "--target", "1190")).waits
    try sbd.sb("note", s.id, "stacked on #1190")
    let note = try #require(try sbd.get(s.id).notes.first)
    for args in [
      ["wait", s.id, "--resolve", "the", "checks", "passed"], ["wait", s.id, "--clear", "now"],
      ["wait", s.id, "--kind", "ci", "--note", "merge", "when", "green"], ["note", s.id, "--rm", note.id, "now"],
    ] {
      #expect(throws: TestError.self) { try sbd.sb(args) }
    }
    #expect(try sbd.get(s.id).waits == open)
    #expect(try sbd.get(s.id).notes == [note])
  }

  @Test func refusesNumbersTooLargeForAnInt() throws {
    let sbd = try Instance()
    #expect(throws: APIError.self) { try sbd.client.call("clock", ["advance": 1e19]) }
    try sbd.advanceClock(9_000_000_000_000_000_000)
    #expect(throws: APIError.self) { try sbd.advanceClock(9_000_000_000_000_000_000) }
    _ = try sbd.client.call("events", ["limit": 1e19, "since": 1e19])
    #expect(try sbd.client.call("ping")["pid"] != nil)
  }

  @Test func aSessionWaitResumesWhenTheOtherSessionIsDone() throws {
    let sbd = try Instance()
    let a = try idleSession(sbd, name: "a")
    let b = try idleSession(sbd, name: "b")
    #expect(throws: TestError.self) { try sbd.sb("wait", a.id, "--kind", "session", "--target", "a") }
    try sbd.sb("wait", a.id, "--kind", "session", "--target", "b")
    #expect(try sbd.get(a.id).reason == "b to reach Done")
    try sbd.sb("done", b.id)
    try sbd.waitFor(a.id, "the resumed turn") { $0.lastReply == "Done: Switchboard: b to reach Done: it did." }
    #expect(try sbd.get(a.id).waits.isEmpty)
  }

  @Test func aManualWaitReturnsToNeedsYouOnItsRecheckDate() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "manual", "--note", "ask Alex", "--until", "1d")
    try sbd.waitFor(s.id, "the stop", timeout: 10) { !$0.live }
    try sbd.advanceClock(25 * WaitTests.hourMs)
    let due = try sbd.waitFor(s.id, "the recheck") { $0.state == .needsYou }
    #expect(due.reason == "ask Alex: time to recheck")
    #expect(due.waits.isEmpty)
    #expect(!due.live)
    #expect(sbd.stubArgs().count == 1)
  }

  @Test func aPollerResolvesACIWaitAndTheSessionResumes() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    let set = try decode(
      sbd.sb(
        "wait", "--json", s.id, "--kind", "ci", "--target", "https://github.com/PostHog/posthog/pull/1204", "--note",
        "merge when green"))
    let wait = try #require(set.waits.first)
    #expect(wait.pr == Wait.PullRequest(repository: "PostHog/posthog", number: 1204))
    #expect(set.reason == "CI on PostHog/posthog#1204 (merge when green)")
    // Service.resolveWait, the interface that pollers use, sends this request.
    _ = try sbd.client.call(
      "resolve-wait", ["session": .string(s.id), "wait": .string(wait.id), "outcome": "the checks passed"])
    try sbd.waitFor(s.id, "the resumed turn") {
      $0.lastReply == "Done: Switchboard: CI on PostHog/posthog#1204: the checks passed. Your note: merge when green."
    }
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func aWaitThatNotifiesMovesTheSessionToNeedsYouWithoutResumingIt() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "review", "--target", "1204", "--who", "alex", "--then", "notify")
    let after = try decode(sbd.sb("wait", "--json", s.id, "--resolve", "alex approved"))
    #expect(after.state == .needsYou)
    #expect(after.reason == "a review from alex on #1204: alex approved")
    #expect(after.waits.isEmpty)
    #expect(try sbd.events(s.id).filter { $0.kind == "UserPromptSubmit" }.count == 1)
    try sbd.sb("send", s.id, "offer it")
    try sbd.waitFor(s.id, "the reply to the next prompt") { $0.state == .canContinue }
  }

  @Test func aWaitFromInsideASessionIsSetByClaude() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", "--kind", "bot-review", "--who", "ReviewHog", env: ["SB_SESSION_ID": s.id, "CLAUDECODE": "1"])
    let after = try sbd.get(s.id)
    let wait = try #require(after.waits.first)
    #expect(wait.kind == .botReview)
    #expect(wait.by == .claude)
    #expect(wait.pr == nil)
    #expect(after.reason == "ReviewHog's review on the session's PR")
  }

  @Test func addsListsAndRemovesNotes() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    try sbd.sb("note", s.id, "rebased", "onto", "#1190")
    try sbd.sb("note", s.id, "ask Alex about the cache", env: ["CLAUDECODE": "1"])
    let notes = try sbd.get(s.id).notes
    #expect(notes.map(\.text) == ["rebased onto #1190", "ask Alex about the cache"])
    #expect(notes.map(\.by) == [.you, .claude])
    #expect(try sbd.sb("note", s.id).contains("rebased onto #1190 (you, "))
    try sbd.sb("note", s.id, "--rm", notes[0].id)
    #expect(try sbd.get(s.id).notes.map(\.text) == ["ask Alex about the cache"])
    #expect(throws: TestError.self) { try sbd.sb("note", s.id, "--rm", "nnope") }
  }

  @Test func keepsWaitsAndNotesAcrossARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try idleSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "#1190")
    try sbd.sb("note", s.id, "stacked on #1190")
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.state == .waiting)
    #expect(after.reason == "#1190 to merge")
    #expect(after.notes.map(\.text) == ["stacked on #1190"])
  }

  @Test func turnsAV01WaitNoteIntoAManualWait() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "old")
    sbd.stopSbd()
    do {
      let store = try Store(path: sbd.home.database)
      var session = try #require(try store.sessions().first)
      session.waitNote = "CI on #12"
      try store.save(session)
    }
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.waits.map(\.kind) == [.manual])
    #expect(after.waits.map(\.note) == ["CI on #12"])
    #expect(after.reason == "CI on #12")
  }

  @Test func theClockMovesOnlyInATestInstance() throws {
    let sbd = try Instance(testClock: false)
    #expect(throws: APIError.self) { try sbd.advanceClock(1000) }
  }

  @Test func theClockPassesTheIdleStopWithoutSleeping() throws {
    let sbd = try Instance(idleStopSeconds: 900)
    let s = try idleSession(sbd)
    try sbd.waitFor(s.id, "claude's pid") { $0.claudePid != nil }
    try sbd.advanceClock(16 * 60 * 1000)
    try sbd.waitFor(s.id, "the idle stop", timeout: 5) { !$0.live }
  }
}
