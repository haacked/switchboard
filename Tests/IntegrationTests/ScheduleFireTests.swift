import Foundation
import SwitchboardCore
import Testing

/// The idle stop runs earlier in the tick than the schedules, after 600 s of quiet. Each test that expects a live
/// session moves the clock less than that past the last turn, so the schedules run every 1m.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScheduleFireTests {
  static let every: Int64 = 60_000
  /// Past one interval, and well short of the idle stop.
  static let pastDue: Int64 = 61_000

  /// Adds a schedule through `sb schedule <session> --every 1m <prompt> --json`.
  func schedule(_ sbd: Instance, _ session: String, _ prompt: String) throws -> Schedule {
    try JSONCoding.decode(
      ScheduleRow.self, from: sbd.sb("schedule", session, "--every", "1m", prompt, "--json")
    ).schedule
  }

  /// The schedule as `sb get` shows it now.
  func current(_ sbd: Instance, _ session: String, _ id: String) throws -> Schedule? {
    try sbd.get(session).schedules?.first { $0.id == id }
  }

  /// The `sent` events that carry the prompt.
  func runs(_ sbd: Instance, _ session: String, _ prompt: String) throws -> [Event] {
    try sbd.events(session, "sent", text: prompt)
  }

  func scheduleRan(_ sbd: Instance, _ session: String) throws -> [Event] {
    try sbd.events(session).filter { $0.kind == "schedule-ran" }
  }

  /// The `UserPromptSubmit` events of the prompt.
  func prompts(_ sbd: Instance, _ session: String, _ prompt: String) throws -> [Event] {
    try sbd.events(session).filter { $0.kind == "UserPromptSubmit" && $0.data["prompt"]?.string == prompt }
  }

  /// Waits until the stub reports the prompt, which starts its turn.
  @discardableResult
  func waitForPrompt(_ sbd: Instance, _ session: String, _ prompt: String) throws -> Event {
    try sbd.waitFor(
      "the turn of \(prompt)", fetch: { try prompts(sbd, session, prompt).first }, until: { _ in true })
  }

  /// Waits until the schedule records a run, and returns that run.
  @discardableResult
  func waitForRun(_ sbd: Instance, _ session: String, _ id: String, timeout: Double = 15) throws -> Schedule.Run {
    try sbd.waitFor(
      "a run of \(id)", timeout: timeout, fetch: { try current(sbd, session, id)?.last }, until: { _ in true })
  }

  /// Whether a turn ended after `first` and before `second`.
  func turnEnded(_ sbd: Instance, _ session: String, after first: Event, before second: Event) throws -> Bool {
    try sbd.events(session).contains { $0.kind == "Stop" && $0.id > first.id && $0.id < second.id }
  }

  // MARK: Delivery

  @Test func aDueScheduleIsPastedIntoAnIdleSession() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick one")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the run") { $0.lastReply == "Done: tick one" }
    let after = try #require(try current(sbd, s.id, made.id))
    let last = try #require(after.last)
    #expect(last.outcome == .pasted)
    #expect(last.skipped == 0)
    #expect(last.error == nil)
    #expect(after.next == last.t + ScheduleFireTests.every)
    let ran = try scheduleRan(sbd, s.id)
    try #require(ran.count == 1, "\(ran)")
    #expect(ran[0].data["outcome"]?.string == "pasted")
    #expect(ran[0].data["skipped"]?.int == 0)
  }

  /// The prompt goes as typed, with no "Switchboard:" in front, so a slash command runs as one.
  @Test func theRunSendsThePromptVerbatimAsSbd() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    _ = try schedule(sbd, s.id, "tick verbatim")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the run") { $0.lastReply == "Done: tick verbatim" }
    #expect(try sbd.messagesFromSbd(s.id) == ["tick verbatim"])
  }

  @Test func aDueScheduleResumesAStoppedSession() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    // The idle stop moves the clock 601 s, which would pass a schedule made before it.
    try sbd.passIdleStop(s.id)
    let made = try schedule(sbd, s.id, "tick two")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the resumed run", timeout: 30) { $0.lastReply == "Done: tick two" }
    #expect(sbd.stubArgs().last?.hasPrefix("--resume \(s.claudeSessionId) ") == true, "\(sbd.stubArgs())")
    #expect(try current(sbd, s.id, made.id)?.last?.outcome == .resumed)
    #expect(try sbd.triggers(s.id).compactMap { $0 }.last == "schedule")
  }

  /// A run can start claude, which needs the shared MCP servers. `mcpStarting` counts only a server that started
  /// in the last 10 s, so the server restarts after the long clock move and just before the run is due.
  @Test func aRunThatResumesASessionWaitsForAStartingServer() throws {
    let gate = try MCPGate(open: true)
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", gate: gate)]])
    let s = try sbd.idleSession()
    try sbd.passIdleStop(s.id)
    let made = try schedule(sbd, s.id, "tick after the server")
    try sbd.advanceClock(made.next - (try sbd.now()) - 1_000)
    try sbd.restartServer(try sbd.waitForRunning("slow"), behind: gate)

    try sbd.advanceClock(2_000)

    #expect(try sbd.events(s.id, kind: "resumed").isEmpty)
    #expect(try runs(sbd, s.id, "tick after the server").isEmpty)
    try gate.open()
    try sbd.waitFor(s.id, "the resumed run", timeout: 30) { $0.lastReply == "Done: tick after the server" }
    let resumed = try #require(try sbd.events(s.id, kind: "resumed").last)
    #expect(resumed.data["mcp"] == ["slow"])
    #expect(resumed.data["trigger"]?.string == "schedule")
  }

  // MARK: Queue one

  /// `slow held` runs a tool call until $SB_HOME/report exists, so `turnRunning` holds through the clock move.
  @Test func aRunningTurnHoldsTheScheduleAndItRunsOnceAfterTheTurn() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick held")
    try sbd.sb("send", s.id, "slow held")
    try waitForPrompt(sbd, s.id, "slow held")
    try sbd.waitFor(s.id, "the held turn") { $0.state == .working }

    try sbd.advanceClock(3 * ScheduleFireTests.every + 30_000)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick held").isEmpty)
    #expect(try current(sbd, s.id, made.id)?.last == nil)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick held" }
    // Three due times passed during the turn, and one of them runs.
    #expect(try current(sbd, s.id, made.id)?.last?.skipped == 2)
    sleep(3)
    #expect(try runs(sbd, s.id, "tick held").count == 1)
    #expect(try scheduleRan(sbd, s.id).count == 1)
  }

  /// sbd visits sessions in id order, so the busy session has the lower id and comes first.
  @Test func aBusySessionDoesNotHoldBackAnotherSessionsSchedule() throws {
    let sbd = try Instance()
    let pair = [try sbd.idleSession(name: "a"), try sbd.idleSession(name: "b")].sorted { $0.id < $1.id }
    let (busy, free) = (pair[0], pair[1])
    let held = try schedule(sbd, busy.id, "tick busy")
    let other = try schedule(sbd, free.id, "tick free")
    try sbd.sb("send", busy.id, "slow held")
    try waitForPrompt(sbd, busy.id, "slow held")
    try sbd.waitFor(busy.id, "the held turn") { $0.state == .working }

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    #expect(try waitForRun(sbd, free.id, other.id).outcome == .pasted)
    #expect(try current(sbd, busy.id, held.id)?.last == nil)
  }

  /// `resolveDueWaits` runs before the schedules in the tick. The wait's message is in flight when the schedule
  /// comes due, so the schedule runs after that message's turn.
  @Test func aWaitDueOnTheSameTickGoesFirst() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1m")
    _ = try schedule(sbd, s.id, "tick after the wait")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick after the wait" }
    let sent = try sbd.sbdMessages(s.id)
    try #require(sent.count == 2, "\(sent)")
    #expect(sent[0].data["text"]?.string?.hasPrefix("Switchboard:") == true, "\(sent[0])")
    #expect(sent[1].data["text"]?.string == "tick after the wait")
    #expect(try turnEnded(sbd, s.id, after: sent[0], before: sent[1]))
  }

  /// The first schedule's prompt holds its turn, so the second can't run during it.
  @Test func twoSchedulesDueTogetherSendOneMessageAtATime() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let first = try schedule(sbd, s.id, "slow held")
    let second = try schedule(sbd, s.id, "tick second")
    try #require(first.next <= second.next)

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForPrompt(sbd, s.id, "slow held")
    sleep(1)

    #expect(try sbd.messagesFromSbd(s.id) == ["slow held"])
    #expect(try current(sbd, s.id, second.id)?.last == nil)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the second run's reply", timeout: 30) { $0.lastReply == "Done: tick second" }
    let sent = try sbd.sbdMessages(s.id)
    try #require(sent.count == 2, "\(sent)")
    #expect(sent.compactMap { $0.data["text"]?.string } == ["slow held", "tick second"])
    #expect(try turnEnded(sbd, s.id, after: sent[0], before: sent[1]))
    #expect(try current(sbd, s.id, first.id)?.last?.outcome == .pasted)
    #expect(try current(sbd, s.id, second.id)?.last?.outcome == .pasted)
  }

  /// The user's message waits in `pending` behind a running turn. When the turn ends, the user's message goes
  /// first, and the schedule runs after the user's turn.
  @Test func aUserMessageQueuedBehindATurnGoesBeforeTheRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick behind")
    try sbd.sb("send", s.id, "slow held")
    try waitForPrompt(sbd, s.id, "slow held")
    try sbd.sb("send", s.id, "my own words")
    let mine = try #require(try sbd.events(s.id, "sent", text: "my own words").first)
    try #require(mine.data["delivery"]?.string == "queued", "\(mine)")

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick behind").isEmpty)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick behind" }
    let run = try #require(try runs(sbd, s.id, "tick behind").first)
    let typed = try #require(try prompts(sbd, s.id, "my own words").first)
    #expect(typed.id < run.id)
    #expect(try turnEnded(sbd, s.id, after: typed, before: run))
    #expect(try runs(sbd, s.id, "tick behind").count == 1)
    #expect(try current(sbd, s.id, made.id)?.last?.outcome == .pasted)
  }

  /// `lag held` keeps the user's message in flight: the stub reads it and does not report it until
  /// $SB_HOME/report exists. The clock stops 2 s short of the due time before the message goes, so the schedule
  /// comes due inside the message's 10 s in-flight window.
  @Test func aUserMessageInFlightGoesBeforeTheRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick in flight")
    let now = try sbd.now()
    try sbd.advanceClock(made.next - now - 2_000)
    try sbd.sb("send", s.id, "lag held")
    let mine = try #require(try sbd.events(s.id, "sent", text: "lag held").first)
    try #require(mine.data["delivery"]?.string == "pasted", "\(mine)")

    try sbd.advanceClock(2_500)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick in flight").isEmpty)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick in flight" }
    let run = try #require(try runs(sbd, s.id, "tick in flight").first)
    let typed = try #require(try prompts(sbd, s.id, "lag held").first)
    #expect(try turnEnded(sbd, s.id, after: typed, before: run))
    #expect(try runs(sbd, s.id, "tick in flight").count == 1)
  }

  /// While $SB_HOME/hold exists, the stub reads the run's paste and never reports it. The paste stops counting as
  /// in flight after 10 s. The next run is still a whole interval after the first.
  @Test func aRunWhosePromptIsNeverReportedDoesNotRunAgainBeforeItsNextTime() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick unreported")
    sbd.hold("hold")

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try sbd.waitFor("the run's paste") { try runs(sbd, s.id, "tick unreported").count == 1 }
    for _ in 0..<3 { try sbd.advanceClock(11_000) }
    sleep(1)

    #expect(try prompts(sbd, s.id, "tick unreported").isEmpty)
    #expect(try runs(sbd, s.id, "tick unreported").count == 1)
    #expect(try scheduleRan(sbd, s.id).count == 1)
    let after = try #require(try current(sbd, s.id, made.id))
    let last = try #require(after.last)
    #expect(after.next == last.t + ScheduleFireTests.every)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run") { $0.lastReply == "Done: tick unreported" }
    #expect(try runs(sbd, s.id, "tick unreported").count == 1)
  }

  // MARK: Done and paused

  @Test func aDoneSessionsScheduleWaitsAndRunsOnceAfterUndone() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick done")
    try sbd.sb("done", s.id)

    try sbd.advanceClock(3 * ScheduleFireTests.every + 30_000)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick done").isEmpty)
    let kept = try #require(try current(sbd, s.id, made.id))
    #expect(kept.last == nil)
    try sbd.sb("undone", s.id)
    let last = try waitForRun(sbd, s.id, made.id, timeout: 30)
    #expect(last.skipped == 2)
    sleep(2)
    #expect(try runs(sbd, s.id, "tick done").count == 1)
  }

  /// Nothing is held, so only the session's pause can hold the run: a stopped session's run would resume it.
  @Test func aPausedSessionsScheduleWaitsAndRunsOnceAfterTheResumeMessage() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick while paused")
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)

    try sbd.advanceClock(3 * ScheduleFireTests.every + 30_000)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick while paused").isEmpty)
    #expect(try current(sbd, s.id, made.id)?.last == nil)
    #expect(try scheduleRan(sbd, s.id).isEmpty)
    #expect(try sbd.pauseField(s.id) != nil)
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id, "--message", "go on")
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 2) == ["go on", "tick while paused"])
    // The resumed launch and its turn pass real time on sbd's clock, which can pass one more due time.
    #expect(try waitForRun(sbd, s.id, made.id).skipped >= 2)
    sleep(2)
    #expect(try runs(sbd, s.id, "tick while paused").count == 1)
    #expect(try scheduleRan(sbd, s.id).count == 1)
  }

  /// A held message keeps the session's queue busy, so the run also waits behind it after the resume.
  @Test func aRunThatCameDueWhilePausedFollowsTheResumeMessageAndTheHeldMessages() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    _ = try schedule(sbd, s.id, "tick after held")
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)
    try sbd.sb("send", s.id, "held note")

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick after held").isEmpty)
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id, "--message", "go on")
    let expected = ["go on", "held note", "tick after held"]
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 3) == expected)
    sleep(2)
    #expect(try sbd.promptsSince(s.id, after: mark) == expected)
    #expect(try scheduleRan(sbd, s.id).count == 1)
  }

  @Test func aPausedScheduleDoesNotRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick paused")
    try sbd.sb("schedule", "pause", made.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick paused").isEmpty)
    #expect(try current(sbd, s.id, made.id)?.last == nil)
    #expect(try scheduleRan(sbd, s.id).isEmpty)
    // A resume sets the next run one interval later, so the pause is what held the schedule.
    try sbd.sb("schedule", "resume", made.id)
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForRun(sbd, s.id, made.id)
    #expect(try runs(sbd, s.id, "tick paused").count == 1)
  }

  // MARK: Restart and failure

  /// `Clock`'s offset lives only in sbd's memory, so the clock moves after the restart.
  @Test func aScheduleMissedWhileSbdWasDownRunsOnceAndCountsTheRestAsSkipped() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick catch up")
    sbd.stopSbd()
    try sbd.startSbd()

    try sbd.advanceClock(5 * ScheduleFireTests.every + 1_000)

    let last = try waitForRun(sbd, s.id, made.id, timeout: 30)
    #expect(last.skipped == 4)
    sleep(3)
    #expect(try runs(sbd, s.id, "tick catch up").count == 1)
  }

  /// `send` throws because the session's folder is gone. The run records the failure once and waits a whole
  /// interval.
  @Test func aRunThatCantBeSentRecordsTheFailureOnceAndMovesToTheNextTime() throws {
    let sbd = try Instance()
    let folder = "\(sbd.home.path)/doomed"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let s = try sbd.client.call(
      "new", ["path": .string(folder), "name": "doomed", "prompt": "hello"], as: SessionSummary.self)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.passIdleStop(s.id)
    let made = try schedule(sbd, s.id, "tick gone")
    try FileManager.default.removeItem(atPath: folder)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let last = try waitForRun(sbd, s.id, made.id)
    sleep(3)
    #expect(last.outcome == .failed)
    #expect(last.error?.contains(s.cwd) == true, "\(String(describing: last.error))")
    #expect(try current(sbd, s.id, made.id)?.next == last.t + ScheduleFireTests.every)
    let ran = try scheduleRan(sbd, s.id)
    try #require(ran.count == 1, "\(ran)")
    #expect(ran[0].data["outcome"]?.string == "failed")
    #expect(ran[0].data["error"]?.string?.isEmpty == false)
    #expect(try runs(sbd, s.id, "tick gone").isEmpty)
    let log = (try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? ""
    #expect(log.split(separator: "\n").filter { $0.contains("\(s.cwd) is gone") }.count == 1, "\(log)")
  }
}

/// A remote session's process state is unknown while sbd can't read its host.
@Suite(.blocking(timeLimit: .seconds(180))) struct ScheduleFireRemoteTests {
  private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"

  @Test func aScheduleOnAHostWhoseLinkIsDownWaitsForTheLink() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let summary = try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello")
    let id = try sbd.id(of: summary)
    let claudeSessionId = try #require(summary["claudeSessionId"]?.string)
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }
    try sbd.waitFor("the first turn's transcript on the box") { !sbd.boxTranscripts(claudeSessionId).isEmpty }
    let made = try JSONCoding.decode(
      ScheduleRow.self, from: sbd.sb("schedule", id, "--every", "1m", "tick remote", "--json")
    ).schedule
    try sbd.dropLinkAndRefuse(refusal)

    try sbd.advanceClock(61_000)
    for _ in 0..<2 { try sbd.advanceClock(11_000) }

    #expect(try sbd.events(id, "sent", text: "tick remote").isEmpty)
    #expect(try sbd.get(id).schedules?.first { $0.id == made.id }?.last == nil)
    try sbd.restoreLink()
    try sbd.waitFor("the run after the link returns", timeout: 30) {
      try sbd.events(id, "sent", text: "tick remote").count == 1
    }
    sleep(2)
    #expect(try sbd.events(id, "sent", text: "tick remote").count == 1)
  }
}

/// Helpers that the history, status, and Run now suites share with `ScheduleFireTests`.
extension ScheduleFireTests {
  /// Adds a schedule through `sb schedule <session> --every <every> <prompt> --json`.
  func add(_ sbd: Instance, _ session: String, every: String, _ prompt: String) throws -> ScheduleRow {
    try JSONCoding.decode(ScheduleRow.self, from: sbd.sb("schedule", session, "--every", every, prompt, "--json"))
  }

  /// The schedule's status as `sb schedule ls --json` prints it.
  func status(_ sbd: Instance, _ id: String) throws -> ScheduleStatus? {
    try JSONCoding.decode([ScheduleRow].self, from: sbd.sb("schedule", "ls", "--json"))
      .first { $0.schedule.id == id }?.status
  }

  /// The line of `sb schedule ls` that names the schedule.
  func listedLine(_ sbd: Instance, _ id: String) throws -> String? {
    try sbd.sb("schedule", "ls").split(separator: "\n").first { $0.contains(id) }.map(String.init)
  }

  /// Starts a `slow held` turn, which runs a tool call until $SB_HOME/report exists.
  func holdATurn(_ sbd: Instance, _ session: String) throws {
    try sbd.sb("send", session, "slow held")
    try waitForPrompt(sbd, session, "slow held")
    try sbd.waitFor(session, "the held turn") { $0.state == .working }
  }

  /// Marks the session done, or pauses it and waits for its claude to exit.
  func holdSession(_ sbd: Instance, _ session: String, _ how: String) throws {
    if how == "done" {
      try sbd.sb("done", session)
    } else {
      try sbd.pauseJSON(session)
      try sbd.waitForPausedExit(session)
    }
  }

  /// A stopped session whose folder is gone, with a schedule, so the schedule's run fails.
  func doomedLoop(_ sbd: Instance, every: String, _ prompt: String) throws -> (SessionSummary, Schedule) {
    let folder = "\(sbd.home.path)/doomed"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let s = try sbd.client.call(
      "new", ["path": .string(folder), "name": "doomed", "prompt": "hello"], as: SessionSummary.self)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.passIdleStop(s.id)
    let made = try add(sbd, s.id, every: every, prompt).schedule
    try FileManager.default.removeItem(atPath: folder)
    return (s, made)
  }
}

/// `runs` keeps each schedule's recent runs, newest first, and every reader shows the same runs. The cap is a
/// Core unit test, because each run here costs a stub turn.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScheduleHistoryTests {
  let fire = ScheduleFireTests()

  /// Moves the clock past the next run and waits until the run's turn ends, so the next move finds the session
  /// free. Each move stays well short of the idle stop.
  func fireOnce(_ sbd: Instance, _ session: String, _ id: String, count: Int) throws {
    let stops = try sbd.events(session, kind: "Stop").count
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try sbd.waitFor("run \(count) of \(id)", timeout: 30) {
      try fire.current(sbd, session, id)?.runs?.count == count
    }
    try sbd.waitFor("the turn of run \(count)", timeout: 30) { try sbd.events(session, kind: "Stop").count > stops }
  }

  @Test func eachRunIsKeptNewestFirstAndEveryReaderShowsTheSameRuns() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try fire.schedule(sbd, s.id, "tick history")

    for i in 1...3 { try fireOnce(sbd, s.id, made.id, count: i) }

    let stored = try #require(try fire.current(sbd, s.id, made.id))
    let runs = try #require(stored.runs)
    #expect(runs.count == 3)
    #expect(Set(runs.map(\.t)).count == 3)
    #expect(runs.map(\.t) == runs.map(\.t).sorted(by: >))
    #expect(runs.first == stored.last)
    #expect(runs.allSatisfy { $0.outcome == .pasted })
    let got = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("get", s.id, "--json"))
    let listed = try JSONCoding.decode([SessionSummary].self, from: sbd.sb("ls", "--json"))
    let rows = try JSONCoding.decode([ScheduleRow].self, from: sbd.sb("schedule", "ls", "--json"))
    #expect(got.schedules?.first?.runs == runs)
    #expect(listed.first { $0.id == s.id }?.schedules?.first?.runs == runs)
    #expect(rows.first { $0.schedule.id == made.id }?.schedule.runs == runs)
  }

  /// The `schedule-ran` event's schedule is the schedule after the run, with its history.
  @Test func theScheduleRanEventCarriesTheRuns() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try fire.schedule(sbd, s.id, "tick event")

    for i in 1...2 { try fireOnce(sbd, s.id, made.id, count: i) }

    let ran = try fire.scheduleRan(sbd, s.id)
    try #require(ran.count == 2, "\(ran)")
    let schedule = try #require(ran[1].data["schedule"])
    let runs = try #require(try JSONCoding.convert(schedule, to: Schedule.self).runs)
    #expect(runs.count == 2)
    #expect(runs == (try fire.current(sbd, s.id, made.id)?.runs))
  }

  @Test func theHistorySurvivesAnSbdRestart() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try fire.schedule(sbd, s.id, "tick restart")
    for i in 1...2 { try fireOnce(sbd, s.id, made.id, count: i) }
    let before = try #require(try fire.current(sbd, s.id, made.id)?.runs)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try fire.current(sbd, s.id, made.id)?.runs == before)
    #expect(before.count == 2)
  }
}

/// `schedule ls --json` computes each row's status with `Schedule.hold`, the same function that decides which
/// sessions `fireDueSchedules` skips. `overdue` is in `ScheduleFireRemoteTests`, because a held turn across more
/// than 10 minutes of clock time is fragile.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScheduleStatusTests {
  let fire = ScheduleFireTests()

  /// A live idle session runs the loop on the tick that the clock move starts, so a running turn holds it.
  @Test func aLoopDueDuringATurnIsDue() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try fire.schedule(sbd, s.id, "tick due")
    try fire.holdATurn(sbd, s.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let status = try #require(try fire.status(sbd, made.id))
    #expect(status.state == .due)
    #expect(status.text.hasPrefix("due "), "\(status.text)")
    #expect(status.text.hasSuffix("runs when the session is free"), "\(status.text)")
    sbd.hold("report")
  }

  @Test func aLoopWhoseRunFailedIsFailedWithTheError() throws {
    let sbd = try Instance()
    let (s, made) = try fire.doomedLoop(sbd, every: "1m", "tick gone")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let last = try fire.waitForRun(sbd, s.id, made.id)
    try #require(last.outcome == .failed)
    let status = try #require(try fire.status(sbd, made.id))
    #expect(status.state == .failed)
    #expect(status.text.hasPrefix("failed "), "\(status.text)")
    #expect(status.text.contains(s.cwd), "\(status.text)")
  }

  /// Risk 2: the status says `held` exactly when the tick skips the session. The JSON and the text both say so,
  /// and three more ticks send nothing.
  @Test(arguments: [("done", "the session is marked done"), ("paused", "the session is paused")])
  func aHeldLoopIsHeldAndSendsNothing(_ how: String, _ hold: String) throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try fire.schedule(sbd, s.id, "tick \(how)")
    try fire.holdSession(sbd, s.id, how)

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    let status = try #require(try fire.status(sbd, made.id))
    let line = try fire.listedLine(sbd, made.id)
    for _ in 0..<3 { try sbd.advanceClock(11_000) }
    sleep(1)

    #expect(status.state == .held)
    #expect(status.text == "held: \(hold)")
    #expect(line?.contains("held: \(hold)") == true, "\(String(describing: line))")
    #expect(try fire.runs(sbd, s.id, "tick \(how)").isEmpty)
    #expect(try fire.scheduleRan(sbd, s.id).isEmpty)
  }

  /// Risk 2's other side: a live session's loop that is `due` sends once when the session is free.
  @Test func aDueLoopOnALiveSessionSendsOnceWhenTheSessionIsFree() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try fire.schedule(sbd, s.id, "tick live")
    try fire.holdATurn(sbd, s.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    let status = try #require(try fire.status(sbd, made.id))
    sbd.hold("report")

    #expect(status.state == .due)
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick live" }
    sleep(2)
    #expect(try fire.runs(sbd, s.id, "tick live").count == 1)
    #expect(try fire.scheduleRan(sbd, s.id).count == 1)
  }

  /// `schedules` keeps its order on main: paused last, then `next`, then id. Only the Loops tab sorts attention
  /// first. The failed loop's next run is two minutes after its run, past the 1m loop's.
  @Test func aFailedLoopDoesNotMoveAheadOfALoopDueSooner() throws {
    let sbd = try Instance()
    let (s, failed) = try fire.doomedLoop(sbd, every: "2m", "tick gone")
    try sbd.advanceClock(121_000)
    try #require(try fire.waitForRun(sbd, s.id, failed.id).outcome == .failed)
    let other = try sbd.new(name: "other")
    let sooner = try fire.add(sbd, other.id, every: "1m", "sooner")

    let rows = try JSONCoding.decode([ScheduleRow].self, from: sbd.sb("schedule", "ls", "--json"))

    #expect(rows.map(\.schedule.id) == [sooner.schedule.id, failed.id])
    #expect(rows.map { $0.status?.state } == [.active, .failed])
  }
}

/// Risk 1: `run-schedule` only moves `next` to now. The next tick fires the schedule through
/// `fireDueSchedules`, so the session hold and `Schedule.blocker` apply as for any due schedule. Each loop here
/// runs every 30m, so only Run now makes it due.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScheduleRunNowTests {
  static let thirtyMinutes: Int64 = 1_800_000
  let fire = ScheduleFireTests()

  func add(_ sbd: Instance, _ session: String, _ prompt: String) throws -> ScheduleRow {
    try fire.add(sbd, session, every: "30m", prompt)
  }

  /// `sb schedule run <id> --json`.
  func runNow(_ sbd: Instance, _ id: String) throws -> ScheduleRow {
    try JSONCoding.decode(ScheduleRow.self, from: sbd.sb("schedule", "run", id, "--json"))
  }

  func requested(_ sbd: Instance, _ session: String) throws -> [Event] {
    try sbd.events(session, kind: "schedule-run-requested")
  }

  /// The schedule with only its next run changed.
  func onlyNextMoved(_ before: Schedule, _ after: Schedule) -> Bool {
    var expected = before
    expected.next = after.next
    return after == expected
  }

  @Test func runNowReturnsADueRowWithOnlyTheNextRunMoved() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try add(sbd, s.id, "tick returned")

    let r = try runNow(sbd, made.schedule.id)

    let after = try sbd.now()
    #expect(r.schedule.next <= after)
    #expect(onlyNextMoved(made.schedule, r.schedule))
    #expect(r.status?.state == .due)
    #expect(r.session == s.id)
  }

  @Test func runNowOnAnIdleSessionSendsThePromptOnceAndStartsTheIntervalAgain() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try add(sbd, s.id, "tick now")
    // sbd pastes only `pasteSettleSeconds` after SessionStart, so a run right after the first reply would be queued.
    try sbd.advanceClock(2_000)

    _ = try runNow(sbd, made.schedule.id)

    try sbd.waitFor("the run's send", timeout: 10) { try fire.runs(sbd, s.id, "tick now").count == 1 }
    let last = try fire.waitForRun(sbd, s.id, made.schedule.id)
    let stored = try #require(try fire.current(sbd, s.id, made.schedule.id))
    #expect(last.outcome == .pasted)
    #expect(last.skipped == 0)
    #expect(stored.next == last.t + ScheduleRunNowTests.thirtyMinutes)
    try sbd.waitFor(s.id, "the reply to the run") { $0.lastReply == "Done: tick now" }
    sleep(2)
    #expect(try fire.runs(sbd, s.id, "tick now").count == 1)
    #expect(try fire.scheduleRan(sbd, s.id).count == 1)
    #expect(try requested(sbd, s.id).count == 1)
  }

  @Test func runNowDuringATurnSendsNothingUntilTheTurnEndsThenOnce() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try add(sbd, s.id, "tick after the turn")
    try fire.holdATurn(sbd, s.id)

    _ = try runNow(sbd, made.schedule.id)
    sleep(2)

    #expect(try fire.runs(sbd, s.id, "tick after the turn").isEmpty)
    #expect(try fire.current(sbd, s.id, made.schedule.id)?.last == nil)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick after the turn" }
    sleep(2)
    #expect(try fire.runs(sbd, s.id, "tick after the turn").count == 1)
  }

  /// An open card holds the run as a running turn does. The prompt goes in once, after the card closes.
  @Test func runNowWithAnOpenCardSendsNothingUntilTheCardCloses() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    let made = try add(sbd, s.id, "tick after the card")

    let r = try runNow(sbd, made.schedule.id)
    sleep(2)

    #expect(r.status?.state == .due)
    #expect(try fire.runs(sbd, s.id, "tick after the card").isEmpty)
    #expect(try fire.current(sbd, s.id, made.schedule.id)?.last == nil)
    try sbd.sb("allow", s.id)
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick after the card" }
    sleep(2)
    #expect(try fire.runs(sbd, s.id, "tick after the card").count == 1)
  }

  @Test func runNowResumesAStoppedSession() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    try sbd.passIdleStop(s.id)
    let made = try add(sbd, s.id, "tick resumed")

    _ = try runNow(sbd, made.schedule.id)

    try sbd.waitFor(s.id, "the reply to the resumed run", timeout: 30) { $0.lastReply == "Done: tick resumed" }
    #expect(sbd.stubArgs().last?.hasPrefix("--resume \(s.claudeSessionId) ") == true, "\(sbd.stubArgs())")
    #expect(try fire.current(sbd, s.id, made.schedule.id)?.last?.outcome == .resumed)
  }

  /// A second run before the schedule fires, on the same tick or while a turn holds it, finds it due already.
  /// It returns the row, records no second event, and the session gets one prompt.
  @Test func twoRunsBeforeTheScheduleFiresSendOnePrompt() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try add(sbd, s.id, "tick twice")
    try fire.holdATurn(sbd, s.id)

    let first = try runNow(sbd, made.schedule.id)
    let second = try runNow(sbd, made.schedule.id)

    #expect(second.schedule == first.schedule)
    #expect(try requested(sbd, s.id).count == 1)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick twice" }
    sleep(2)
    #expect(try fire.runs(sbd, s.id, "tick twice").count == 1)
    #expect(try fire.scheduleRan(sbd, s.id).count == 1)
  }

  @Test func runNowRefusesAPausedScheduleAndKeepsItsNextRun() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let made = try add(sbd, s.id, "tick paused")
    try sbd.sb("schedule", "pause", made.schedule.id)
    let paused = try fire.current(sbd, s.id, made.schedule.id)

    let r = try sbd.run(["schedule", "run", made.schedule.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("is paused. Resume it first"), "\(r.stderr)")
    #expect(try fire.current(sbd, s.id, made.schedule.id) == paused)
    #expect(try requested(sbd, s.id).isEmpty)
  }

  /// The tick would skip the session, so accepting the request would mislead.
  @Test(arguments: [("done", "the session is marked done"), ("paused", "the session is paused")])
  func runNowRefusesAHeldSessionWithTheReason(_ how: String, _ hold: String) throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try add(sbd, s.id, "tick \(how)")
    try fire.holdSession(sbd, s.id, how)

    let r = try sbd.run(["schedule", "run", made.schedule.id])
    sleep(2)

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(made.schedule.id) can't run, because \(hold)"), "\(r.stderr)")
    #expect(try fire.current(sbd, s.id, made.schedule.id) == made.schedule)
    #expect(try requested(sbd, s.id).isEmpty)
    #expect(try fire.runs(sbd, s.id, "tick \(how)").isEmpty)
  }

  @Test func runNowNeedsAKnownIdOnTheNamedSession() throws {
    let sbd = try Instance()
    let owner = try sbd.new(name: "owner")
    let other = try sbd.new(name: "other")
    let made = try add(sbd, owner.id, "tick owned")

    let unknown = try sbd.run(["schedule", "run", "rzzzzz"])
    let missing = try sbd.run(["schedule", "run"])
    let elsewhere = failure(
      sbd, "run-schedule", ["schedule": .string(made.schedule.id), "session": .string(other.id)])

    #expect(unknown.status != 0)
    #expect(missing.status != 0)
    #expect(elsewhere.contains("has no schedule \(made.schedule.id)"), "\(elsewhere)")
    #expect(try fire.current(sbd, owner.id, made.schedule.id) == made.schedule)
  }

  // MARK: Group scope (Risk 7)

  @Test func aScopedRunActsOnAMembersSchedule() throws {
    let s = try ScheduleTests().scoped()

    let ran = try s.call("run-schedule", ["schedule": .string(s.a.schedule.id)])

    let now = try s.sbd.now()
    #expect(ran.schedule.next <= now)
  }

  @Test func aScopedRunActsOnTheCallersOwnSchedule() throws {
    let s = try ScheduleTests().scoped()

    let ran = try s.call("run-schedule", ["schedule": .string(s.caller.schedule.id)])

    let now = try s.sbd.now()
    #expect(ran.schedule.next <= now)
  }

  @Test(arguments: ["b", "loose"])
  func aScopedRunRefusesAScheduleOutsideTheGroup(_ which: String) throws {
    let s = try ScheduleTests().scoped()
    let target = which == "b" ? s.b : s.loose

    let error = s.refusal("run-schedule", ["schedule": .string(target.schedule.id)])

    #expect(error.contains("not in group"), "\(error)")
    #expect(try s.stored(target) == [target.schedule])
  }

  @Test func aScopedRunRefusesAnUnknownId() throws {
    let s = try ScheduleTests().scoped()

    #expect(s.refusal("run-schedule", ["schedule": "rzzzzz"]) != "no error")
  }

  @Test func aScopedRunRefusesASessionThatLeftTheGroup() throws {
    let s = try ScheduleTests().scoped()
    _ = try s.sbd.client.call("group-move", ["sessions": [.string(s.a.session)], "ungrouped": true])

    let error = s.refusal("run-schedule", ["schedule": .string(s.a.schedule.id)])

    #expect(error.contains("not in group"), "\(error)")
    #expect(try s.stored(s.a) == [s.a.schedule])
  }
}

extension ScheduleFireRemoteTests {
  /// Host sessions' schedules live in the Mac's sbd (Decision 9). With the link down, sbd can't read the
  /// session's process, so the loop stays due with no turn running and turns overdue after its grace. A 1m loop's
  /// grace is 10 minutes.
  @Test func aHostSessionsLoopShowsItsStatusAndTurnsOverdueWhileTheLinkIsDown() throws {
    let fire = ScheduleFireTests()
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let summary = try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello")
    let id = try sbd.id(of: summary)
    let claudeSessionId = try #require(summary["claudeSessionId"]?.string)
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }
    try sbd.waitFor("the first turn's transcript on the box") { !sbd.boxTranscripts(claudeSessionId).isEmpty }
    let made = try fire.add(sbd, id, every: "1m", "tick overdue").schedule
    let manual = try fire.add(sbd, id, every: "30m", "tick manual").schedule
    let rows = try JSONCoding.decode([ScheduleRow].self, from: sbd.sb("schedule", "ls", "--json"))
    try sbd.dropLinkAndRefuse("ssh: connect to host mini.local port 22: Operation timed out")
    // Run now takes a session whose link is down. The run waits for the link and never reads as held.
    let ran = try JSONCoding.decode(ScheduleRow.self, from: sbd.sb("schedule", "run", manual.id, "--json"))

    try sbd.advanceClock(61_000)
    let due = try fire.status(sbd, made.id)
    try sbd.advanceClock(10 * 60_000)
    let overdue = try fire.status(sbd, made.id)
    let manualLater = try fire.status(sbd, manual.id)

    #expect(rows.first { $0.schedule.id == made.id }?.session == id)
    #expect(rows.first { $0.schedule.id == made.id }?.status?.state == .active)
    #expect(due?.state == .due)
    #expect(overdue?.state == .overdue)
    #expect(overdue?.text.hasPrefix("overdue by 10m") == true, "\(String(describing: overdue?.text))")
    #expect(try sbd.events(id, "sent", text: "tick overdue").isEmpty)
    #expect(ran.status?.state == .due)
    #expect(manualLater?.state == .due)
    #expect(try sbd.events(id, "sent", text: "tick manual").isEmpty)
  }
}
