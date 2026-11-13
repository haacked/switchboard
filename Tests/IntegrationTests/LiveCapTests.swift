import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// What `sb live --json` prints.
  func liveStatus() throws -> JSON {
    let text = try sb("live", "--json")
    guard let json = JSON.parse(text) else { throw TestError(description: "sb live --json printed \(text)") }
    return json
  }

  /// The ids that a list in `sb live --json` names, in its order.
  func liveIds(_ list: String) throws -> [String] {
    (try liveStatus()[list]?.array ?? []).compactMap { $0["session"]?.string }
  }

  /// The session's `stopped` events whose reason mentions the live cap.
  func capStops(_ id: String) throws -> [Event] {
    try events(id).filter { $0.kind == "stopped" && $0.data["reason"]?.string?.contains("live cap") == true }
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct LiveCapTests {
  func instance(cap: Int, extra: [String: JSON] = [:]) throws -> Instance {
    try Instance(config: extra.merging(["liveCap": .number(Double(cap))]) { $1 })
  }

  /// A session in the middle of a long tool call.
  func busySession(_ sbd: Instance, name: String, seconds: Int = 30) throws -> SessionSummary {
    let s = try sbd.new(prompt: "slow \(seconds)", name: name)
    return try sbd.waitFor(s.id, "\(name)'s slow tool") { $0.state == .working && $0.claudePid != nil }
  }

  /// An idle session on screen, which sbd never stops to make room. `sb stop`
  /// ends its stub claude at once. The stub runs a tool call to its end first.
  /// Call the returned function to take it off screen.
  func onScreenSession(_ sbd: Instance, name: String, ticking: Bool = false) throws -> (SessionSummary, () -> Void) {
    let s = try idleSession(sbd, name: name, ticking: ticking)
    let detach = try sbd.attach(s.id)
    return (try waitFor(sbd, s.id, "\(name) on screen", ticking: ticking) { $0.attached }, detach)
  }

  /// A session whose first turn has ended, with claude still running. It
  /// runs in `path`, or in the instance's work folder when `path` is nil.
  func idleSession(_ sbd: Instance, name: String, path: String? = nil, ticking: Bool = false) throws
    -> SessionSummary
  {
    let s = try newSession(sbd, prompt: "hello", name: name, path: path)
    return try waitFor(sbd, s.id, "\(name)'s first reply", ticking: ticking) {
      $0.lastReply == "Done: hello" && $0.claudePid != nil
    }
  }

  /// A session whose claude was stopped after its first turn.
  func stoppedSession(_ sbd: Instance, name: String, ticking: Bool = false) throws -> SessionSummary {
    let s = try idleSession(sbd, name: name, ticking: ticking)
    try sbd.sb("stop", s.id)
    return try waitFor(sbd, s.id, "\(name)'s stop", ticking: ticking) { $0.claudePid == nil && !$0.live }
  }

  /// A new session in `path`, or in the instance's work folder when `path` is nil.
  func newSession(_ sbd: Instance, prompt: String? = nil, name: String, path: String? = nil) throws -> SessionSummary {
    guard let path else { return try sbd.new(prompt: prompt, name: name) }
    var args: [String: JSON] = ["path": .string(path), "name": .string(name)]
    if let prompt { args["prompt"] = .string(prompt) }
    return try sbd.client.call("new", args, as: SessionSummary.self)
  }

  /// Waits for the session to match. With `ticking`, each look first runs a
  /// tick, for an instance whose ticks run only when the test moves the
  /// clock. Only a tick reads the processes and terminals that the summary shows.
  @discardableResult
  func waitFor(
    _ sbd: Instance, _ id: String, _ what: String, ticking: Bool, timeout: Double = 15,
    _ match: (SessionSummary) -> Bool
  ) throws -> SessionSummary {
    guard ticking else { return try sbd.waitFor(id, what, timeout: timeout, match) }
    return try sbd.waitFor(
      what, timeout: timeout,
      fetch: {
        try sbd.advanceClock(1)
        return try sbd.get(id)
      }, until: match)
  }

  /// Waits until sbd has read the GitHub repository of each session, or found that it has none.
  func waitForRepositories(_ sbd: Instance, _ sessions: SessionSummary...) throws {
    for s in sessions {
      try sbd.waitFor(s.id, "\(s.name)'s repository") { $0.repositoryRead == true }
    }
  }

  /// An instance with this cap and this `livePriority`.
  func priorityInstance(cap: Int, _ entries: [String], extra: [String: JSON] = [:]) throws -> Instance {
    try instance(cap: cap, extra: extra.merging(["livePriority": .array(entries.map(JSON.string))]) { $1 })
  }

  /// The entry of `sb live --json`'s list whose session is `id`.
  func liveEntry(_ status: JSON, _ list: String, _ id: String) -> JSON? {
    status[list]?.array?.first { $0["session"]?.string == id }
  }

  /// The reason for a queued start when no idle session can make room.
  func capFullReason(cap: Int) -> String { "the cap of \(cap) is full and no idle session can stop" }

  /// The reason of a queued session while every slot is taken.
  func queuedReason(cap: Int) -> String { "queued: \(cap) of \(cap) live" }

  @discardableResult
  func waitForQueued(_ sbd: Instance, _ id: String, cap: Int) throws -> SessionSummary {
    try sbd.waitFor(id, "the queued start") { $0.reason == queuedReason(cap: cap) }
  }

  // MARK: The cap holds

  @Test func aStartPastTheCapQueuesWithTheReasonAndRunsNoClaude() throws {
    let sbd = try instance(cap: 2)
    _ = try busySession(sbd, name: "a")
    _ = try busySession(sbd, name: "b")

    let c = try sbd.new(prompt: "hello", name: "c")

    let queued = try waitForQueued(sbd, c.id, cap: 2)
    #expect(queued.claudePid == nil)
    #expect(!queued.live)
    #expect(try sbd.events(c.id).contains { $0.kind == "start-queued" })
    try sbd.advanceClock(1_000)
    #expect(!sbd.stubArgs().contains { $0.contains(c.claudeSessionId) })
    #expect(try sbd.get(c.id).claudePid == nil)
  }

  @Test(arguments: ["ls", "get"])
  func theCLIShowsTheQueuedReason(_ command: String) throws {
    let sbd = try instance(cap: 2)
    _ = try busySession(sbd, name: "a")
    _ = try busySession(sbd, name: "b")
    let c = try sbd.new(prompt: "hello", name: "c")
    try waitForQueued(sbd, c.id, cap: 2)

    let row: SessionSummary
    if command == "ls" {
      let rows = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
      row = try #require(rows.first { $0.id == c.id })
    } else {
      row = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("get", "--json", c.id))
    }

    #expect(row.reason == queuedReason(cap: 2))
    #expect(row.claudePid == nil)
  }

  @Test func sbLiveJsonListsTheCapTheLiveAndTheQueued() throws {
    let sbd = try instance(cap: 2)
    let a = try busySession(sbd, name: "a")
    let b = try busySession(sbd, name: "b")
    let c = try sbd.new(prompt: "hello", name: "c")
    try waitForQueued(sbd, c.id, cap: 2)

    let status = try sbd.liveStatus()

    #expect(status["cap"]?.int == 2)
    let live = try #require(status["live"]?.array)
    #expect(Set(live.compactMap { $0["session"]?.string }) == [a.id, b.id])
    #expect(Set(live.compactMap { $0["name"]?.string }) == ["a", "b"])
    #expect(live.allSatisfy { $0["pid"]?.int != nil })
    #expect(live.allSatisfy { $0["state"]?.string != nil })
    let queued = try #require(status["queued"]?.array)
    #expect(queued.compactMap { $0["session"]?.string } == [c.id])
    #expect(queued.first?["name"]?.string == "c")
    #expect(queued.first?["since"]?.int != nil)
  }

  @Test func sbLiveTextShowsTheCapAndTheSessions() throws {
    let sbd = try instance(cap: 2)
    _ = try busySession(sbd, name: "alpha-busy")
    _ = try busySession(sbd, name: "bravo-busy")
    let c = try sbd.new(prompt: "hello", name: "charlie-queued")
    try waitForQueued(sbd, c.id, cap: 2)

    let text = try sbd.sb("live")

    #expect(text.contains("2 of 2 claude processes live, 1 queued"), "\(text)")
    #expect(text.contains("alpha-busy"), "\(text)")
    #expect(text.contains("bravo-busy"), "\(text)")
    #expect(text.contains("charlie-queued  queued"), "\(text)")
  }

  @Test func theQueuedListKeepsTheOrderOfTheStarts() throws {
    let sbd = try instance(cap: 1)
    _ = try busySession(sbd, name: "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)
    let c = try sbd.new(prompt: "hello", name: "c")
    try waitForQueued(sbd, c.id, cap: 1)

    #expect(try sbd.liveIds("queued") == [b.id, c.id])
  }

  /// Raising the cap frees a slot, but only the tick fills it. Ticks run
  /// only when the test moves the clock.
  @Test func aLaunchWaitsBehindAQueuedStartWhenASlotFrees() throws {
    let sbd = try instance(cap: 1, extra: ["tickSeconds": 3600])
    let a = try sbd.new(prompt: "slow 30", name: "a")
    try sbd.waitFor(a.id, "a's slow tool") { $0.state == .working }
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)
    try sbd.sb("live", "--set", "2")

    let c = try sbd.new(prompt: "hello", name: "c")

    #expect(try sbd.liveIds("queued") == [b.id, c.id])
    try sbd.advanceClock(1)
    #expect(try sbd.liveIds("queued") == [c.id])
  }

  /// `resume` and `open` count against the cap, as `new` does.
  @Test(arguments: ["resume", "open"])
  func aStoppedSessionThatResumesPastTheCapQueues(_ command: String) throws {
    let sbd = try instance(cap: 1)
    let a = try stoppedSession(sbd, name: "a")
    _ = try busySession(sbd, name: "b")

    try sbd.sb(command, a.id)

    let queued = try waitForQueued(sbd, a.id, cap: 1)
    #expect(queued.claudePid == nil)
    #expect(try sbd.events(a.id).contains { $0.kind == "start-queued" })
  }

  // MARK: A slot frees

  @Test func aQueuedStartRunsWhenAProcessStops() throws {
    let sbd = try instance(cap: 2)
    let (a, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    _ = try busySession(sbd, name: "b")
    let c = try sbd.new(prompt: "hello", name: "c")
    try waitForQueued(sbd, c.id, cap: 2)

    try sbd.sb("stop", a.id)

    let started = try sbd.waitFor(c.id, "the queued start to run") { $0.lastReply == "Done: hello" }
    #expect(started.reason != queuedReason(cap: 2))
    #expect(try sbd.liveIds("queued").isEmpty)
  }

  @Test func theOldestQueuedStartRunsFirst() throws {
    let sbd = try instance(cap: 1)
    let (a, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    let b = try sbd.new(prompt: "slow 30", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)
    let c = try sbd.new(prompt: "hello", name: "c")
    try waitForQueued(sbd, c.id, cap: 1)

    try sbd.sb("stop", a.id)

    try sbd.waitFor(b.id, "the oldest start to run") { $0.state == .working && $0.claudePid != nil }
    #expect(try sbd.get(c.id).reason == queuedReason(cap: 1))
    #expect(try sbd.liveIds("queued") == [c.id])
  }

  @Test func aQueuedStartsPromptSurvivesARestart() throws {
    let sbd = try instance(cap: 1)
    let (a, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    let c = try sbd.new(prompt: "hello", name: "c")
    try waitForQueued(sbd, c.id, cap: 1)

    sbd.stopSbd()
    try sbd.startSbd()
    try waitForQueued(sbd, c.id, cap: 1)
    try sbd.sb("stop", a.id)

    try sbd.waitFor(c.id, "the queued prompt's reply") { $0.lastReply == "Done: hello" }
  }

  @Test func raisingTheCapRunsAQueuedStartAtOnce() throws {
    let sbd = try instance(cap: 1)
    _ = try busySession(sbd, name: "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)

    try sbd.sb("live", "--set", "2")

    try sbd.waitFor(b.id, "the queued start to run") { $0.lastReply == "Done: hello" }
  }

  // MARK: Sessions sbd never stops

  /// The turn of `slow 20` outlasts the checks. When it ends, sbd stops the
  /// session to make room.
  @Test func aMidTurnSessionIsStoppedOnlyAfterItsTurnEnds() throws {
    let sbd = try instance(cap: 1)
    let a = try busySession(sbd, name: "a", seconds: 20)
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)

    // Each advance runs a tick before it replies.
    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    #expect(try sbd.get(a.id).claudePid == a.claudePid)
    #expect(try !sbd.events(a.id).contains { $0.kind == "stopped" })
    #expect(try sbd.get(b.id).reason == queuedReason(cap: 1))

    try sbd.waitFor(b.id, "the queued start after a's turn", timeout: 40) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(a.id).isEmpty)
  }

  @Test func aSessionWithAnOpenPermissionCardIsNotStopped() throws {
    let sbd = try instance(cap: 1)
    let s = try sbd.new(prompt: "perm ls", name: "a")
    let a = try sbd.waitFor(s.id, "the permission card") { !$0.cards.isEmpty && $0.claudePid != nil }
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)

    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    let after = try sbd.get(a.id)
    #expect(after.claudePid == a.claudePid)
    #expect(after.cards.count == 1)
    #expect(try !sbd.events(a.id).contains { $0.kind == "stopped" })
    #expect(try sbd.get(b.id).reason == queuedReason(cap: 1))
  }

  /// claude starts the turn that reports a background job up to 1.3 s after
  /// the job's process exits. The stub starts that turn only after the test
  /// creates $SB_HOME/report. Ticks run only when the test moves the clock.
  @Test func aSessionWhoseBackgroundJobJustExitedIsNotStopped() throws {
    let sbd = try instance(cap: 1, extra: ["tickSeconds": 3600])
    let a = try sbd.new(prompt: "background 100 held", name: "a")
    try sbd.waitFor(a.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)
    try sbd.advanceClock(1)

    let job = try #require(sbd.stubPid("job.pid"))
    kill(job, SIGTERM)
    try sbd.waitFor("the job to exit") { kill(job, 0) != 0 }
    try sbd.advanceClock(1)

    #expect(try sbd.get(a.id).live)
    #expect(try sbd.capStops(a.id).isEmpty)
    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    try sbd.waitFor("the turn that reports the job") { try sbd.events(a.id).filter { $0.kind == "Stop" }.count == 2 }

    // StopPolicy.capJobGraceMs is 5 s.
    try sbd.advanceClock(5_000)
    #expect(try !sbd.capStops(a.id).isEmpty)
    try sbd.waitFor("b's start after a exits", timeout: 20) {
      try sbd.advanceClock(1)
      return try sbd.get(b.id).lastReply == "Done: hello"
    }
  }

  // MARK: Which idle session sbd stops

  @Test func anIdleSessionIsStoppedToMakeRoom() throws {
    let sbd = try instance(cap: 1)
    let a = try idleSession(sbd, name: "a")

    let b = try sbd.new(prompt: "hello", name: "b")

    try sbd.waitFor(b.id, "b's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(a.id).isEmpty)
    #expect(try sbd.get(a.id).claudePid == nil)
  }

  /// A Done session stops no sooner than its idle time and last view put it.
  @Test func aLongerIdleSessionIsStoppedBeforeADoneOne() throws {
    let sbd = try instance(cap: 2)
    let plain = try idleSession(sbd, name: "plain")
    let finished = try idleSession(sbd, name: "finished")
    try sbd.sb("done", finished.id)

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(plain.id).isEmpty)
    #expect(try sbd.get(finished.id).claudePid == finished.claudePid)
    #expect(try !sbd.events(finished.id).contains { $0.kind == "stopped" })
  }

  /// A session with an open wait stops no sooner than its idle time and last view put it.
  @Test func aLongerIdleSessionIsStoppedBeforeAWaitingOne() throws {
    let sbd = try instance(cap: 2)
    let plain = try idleSession(sbd, name: "plain")
    let waiting = try idleSession(sbd, name: "waiting")
    try sbd.sb("wait", waiting.id, "CI", "on", "#12")

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    try sbd.waitFor(plain.id, "the plain session's stop") { $0.claudePid == nil }
    #expect(try !sbd.capStops(plain.id).isEmpty)
    #expect(try sbd.get(waiting.id).claudePid == waiting.claudePid)
    #expect(try !sbd.events(waiting.id).contains { $0.kind == "stopped" })
  }

  @Test func theLongestIdleSessionIsStoppedFirst() throws {
    let sbd = try instance(cap: 2)
    let older = try idleSession(sbd, name: "older")
    let newer = try idleSession(sbd, name: "newer")

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(older.id).isEmpty)
    #expect(try sbd.get(newer.id).claudePid == newer.claudePid)
  }

  /// The stub waits 5 s after SIGTERM before it exits, so ticks see the
  /// older session still running after sbd stopped it. Those ticks must not
  /// stop a second session for the same queued start.
  @Test func aSessionThatIsExitingKeepsItsSlotUntilItExits() throws {
    let sbd = try instance(cap: 2)
    let older = try sbd.new(prompt: "linger 5", name: "older")
    try sbd.waitFor(older.id, "older's reply") { $0.lastReply == "I'll linger 5 s when I stop." && $0.claudePid != nil }
    let newer = try idleSession(sbd, name: "newer")

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(older.id).isEmpty)
    #expect(try sbd.get(newer.id).claudePid == newer.claudePid)
    #expect(try !sbd.events(newer.id).contains { $0.kind == "stopped" })
  }

  @Test func anAttachedSessionIsNotStopped() throws {
    let sbd = try instance(cap: 1)
    let (a, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)

    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    #expect(try sbd.get(a.id).claudePid == a.claudePid)
    #expect(try sbd.get(b.id).reason == queuedReason(cap: 1))
  }

  // MARK: Messages

  @Test func aMessageToAQueuedSessionAnswersQueued() throws {
    let sbd = try instance(cap: 1)
    _ = try busySession(sbd, name: "a")
    let b = try sbd.new(name: "b")
    try waitForQueued(sbd, b.id, cap: 1)

    let result = JSON.parse(try sbd.sb("send", "--json", b.id, "follow", "up"))

    #expect(result?["delivery"]?.string == "queued")
  }

  @Test func aMessageToAQueuedSessionIsDeliveredAfterTheStart() throws {
    let sbd = try instance(cap: 1)
    let (a, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    let b = try sbd.new(name: "b")
    try waitForQueued(sbd, b.id, cap: 1)
    try sbd.sb("send", b.id, "follow", "up")

    try sbd.sb("stop", a.id)

    try sbd.waitFor(b.id, "the message's reply") { $0.lastReply == "Done: follow up" }
  }

  @Test func aMessageToAStoppedSessionWhenTheCapIsFullAnswersQueued() throws {
    let sbd = try instance(cap: 1)
    let a = try stoppedSession(sbd, name: "a")
    _ = try busySession(sbd, name: "b")

    let result = JSON.parse(try sbd.sb("send", "--json", a.id, "again"))

    #expect(result?["delivery"]?.string == "queued")
    try waitForQueued(sbd, a.id, cap: 1)
  }

  @Test func aMessageToAStoppedSessionWhenTheCapIsFullIsDeliveredAfterTheStart() throws {
    let sbd = try instance(cap: 1)
    let a = try stoppedSession(sbd, name: "a")
    let (b, detach) = try onScreenSession(sbd, name: "b")
    defer { detach() }
    try sbd.sb("send", a.id, "again")
    try waitForQueued(sbd, a.id, cap: 1)

    try sbd.sb("stop", b.id)

    try sbd.waitFor(a.id, "the message's reply") { $0.lastReply == "Done: again" }
  }

  @Test func aNewChatWhoseStartQueuesAnswersQueued() throws {
    let sbd = try instance(cap: 1)
    _ = try busySession(sbd, name: "a")
    try sbd.sb("group", "add", "Flags")

    let reply = JSON.parse(try sbd.sb("chat", "Flags", "--send", "hello", "--json"))

    #expect(reply?["delivery"]?.string == "queued")
  }

  // MARK: sb live --set

  @Test func setChangesTheCapThatSbLiveShows() throws {
    let sbd = try instance(cap: 2)

    let result = JSON.parse(try sbd.sb("live", "--set", "5", "--json"))

    #expect(result?["cap"]?.int == 5)
    #expect(try sbd.liveStatus()["cap"]?.int == 5)
    #expect(try sbd.autoContinueStatus().liveCap == 5)
  }

  @Test func setSavesTheCapAndKeepsTheOtherKeys() throws {
    let sbd = try instance(cap: 2, extra: ["autoContinue": ["perHour": 2]])
    var before = try sbd.config()

    try sbd.sb("live", "--set", "5")

    before["liveCap"] = 5
    #expect(try sbd.config() == before)
  }

  @Test func setSurvivesARestart() throws {
    let sbd = try instance(cap: 2)
    try sbd.sb("live", "--set", "5")

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.liveStatus()["cap"]?.int == 5)
  }

  @Test(arguments: ["0", "-1", "1.5", "two"])
  func setRefusesAnythingButAWholeNumberOfAtLeastOne(_ value: String) throws {
    let sbd = try instance(cap: 2)
    let before = try sbd.config()

    let r = try sbd.run("live", "--set", value)

    #expect(r.status != 0)
    #expect(try sbd.config() == before)
    #expect(try sbd.liveStatus()["cap"]?.int == 2)
  }

  @Test(arguments: [JSON.number(0), .number(-1), .number(1.5), .string("2")])
  func theServiceRefusesACapThatIsNotAWholeNumberOfAtLeastOne(_ cap: JSON) throws {
    let sbd = try instance(cap: 2)
    let before = try sbd.config()

    #expect(throws: (any Error).self) { try sbd.client.call("live", ["cap": cap]) }
    #expect(try sbd.config() == before)
    #expect(try sbd.liveStatus()["cap"]?.int == 2)
  }

  // MARK: Priority

  @Test func aHigherPriorityStartRunsFirst() throws {
    let repos = try Repos()
    let sbd = try priorityInstance(cap: 1, ["PostHog/posthog"])
    let (a, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    let unranked = try newSession(sbd, prompt: "slow 30", name: "unranked", path: try repos.make("haacked/other"))
    try waitForQueued(sbd, unranked.id, cap: 1)
    let ranked = try newSession(sbd, prompt: "slow 30", name: "ranked", path: try repos.make("PostHog/posthog"))
    try waitForQueued(sbd, ranked.id, cap: 1)
    try waitForRepositories(sbd, a, unranked, ranked)

    try sbd.sb("stop", a.id)

    try sbd.waitFor(ranked.id, "the PostHog start to run") { $0.state == .working && $0.claudePid != nil }
    #expect(try sbd.liveIds("queued") == [unranked.id])
  }

  @Test func anOrgEntryRanksItsRepositories() throws {
    let repos = try Repos()
    let sbd = try priorityInstance(cap: 1, ["PostHog"])
    let (a, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    let unranked = try newSession(sbd, prompt: "slow 30", name: "unranked", path: try repos.make("haacked/other"))
    try waitForQueued(sbd, unranked.id, cap: 1)
    let org = try newSession(sbd, prompt: "slow 30", name: "org", path: try repos.make("PostHog/other"))
    try waitForQueued(sbd, org.id, cap: 1)
    try waitForRepositories(sbd, a, unranked, org)

    try sbd.sb("stop", a.id)

    try sbd.waitFor(org.id, "the PostHog/other start to run") { $0.state == .working && $0.claudePid != nil }
    #expect(try sbd.liveIds("queued") == [unranked.id])
  }

  /// The PostHog/posthog session has been idle longer, so idle time alone would stop it.
  @Test func aLowerPriorityIdleSessionIsStoppedFirst() throws {
    let repos = try Repos()
    let sbd = try priorityInstance(cap: 2, ["PostHog/posthog"])
    let ranked = try idleSession(sbd, name: "ranked", path: try repos.make("PostHog/posthog"))
    let unranked = try idleSession(sbd, name: "unranked", path: try repos.make("haacked/other"))
    try waitForRepositories(sbd, ranked, unranked)

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(unranked.id).isEmpty)
    #expect(try sbd.get(ranked.id).claudePid == ranked.claudePid)
    #expect(try sbd.capStops(ranked.id).isEmpty)
  }

  @Test func aHigherPriorityIdleSessionStopsWhenNoLowerOneCan() throws {
    let repos = try Repos()
    let sbd = try priorityInstance(cap: 1, ["PostHog/posthog"])
    let ranked = try idleSession(sbd, name: "ranked", path: try repos.make("PostHog/posthog"))
    try waitForRepositories(sbd, ranked)

    let unranked = try sbd.new(prompt: "hello", name: "unranked")

    try sbd.waitFor(unranked.id, "the unranked start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(ranked.id).isEmpty)
  }

  /// No session is Done or waits, so only the last views explain why b stops before a.
  @Test func aRecentlyViewedSessionOutlastsALongerIdleOne() throws {
    let sbd = try instance(cap: 3)
    let a = try idleSession(sbd, name: "a")
    let b = try idleSession(sbd, name: "b")
    let c = try idleSession(sbd, name: "c")
    // Both are live, so each open only marks the session viewed. c is viewed last.
    try sbd.sb("open", a.id)
    try sbd.sb("open", c.id)

    let d = try sbd.new(prompt: "hello", name: "d")

    try sbd.waitFor(d.id, "d's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(b.id).isEmpty)
    #expect(try sbd.capStops(a.id).isEmpty)
    #expect(try sbd.capStops(c.id).isEmpty)
  }

  /// Only an open or a terminal makes a session the last viewed. If a
  /// message counted, a would be the last viewed and v would stop.
  @Test func aMessageDoesNotMakeASessionTheLastViewed() throws {
    let sbd = try instance(cap: 2)
    let v = try idleSession(sbd, name: "v")
    let a = try idleSession(sbd, name: "a")
    try sbd.sb("open", v.id)
    try sbd.sb("send", a.id, "again")
    try sbd.waitFor(a.id, "a's reply") { $0.lastReply == "Done: again" }

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(a.id).isEmpty)
    #expect(try sbd.get(v.id).claudePid == v.claudePid)
  }

  /// The session is off screen before the start queues, so only the last-viewed rule keeps it.
  @Test func theLastViewedSessionIsNotStopped() throws {
    let sbd = try instance(cap: 1)
    let a = try idleSession(sbd, name: "a")
    try sbd.sb("open", a.id)
    let detach = try sbd.attach(a.id)
    try sbd.waitFor(a.id, "a on screen") { $0.attached }
    detach()
    try sbd.waitFor(a.id, "a off screen") { !$0.attached }
    let b = try sbd.new(prompt: "hello", name: "b")
    try waitForQueued(sbd, b.id, cap: 1)

    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    #expect(try sbd.get(a.id).claudePid == a.claudePid)
    #expect(try sbd.capStops(a.id).isEmpty)
    #expect(try liveEntry(sbd.liveStatus(), "queued", b.id)?["reason"]?.string == capFullReason(cap: 1))
  }

  /// A busy PostHog/posthog session holds the only slot, and a haacked/other start waits for it.
  func rankedQueue(_ repos: Repos) throws -> (sbd: Instance, busy: SessionSummary, queued: SessionSummary) {
    let sbd = try priorityInstance(cap: 1, ["PostHog/posthog", "haacked"])
    let s = try newSession(sbd, prompt: "slow 30", name: "alpha-busy", path: try repos.make("PostHog/posthog"))
    let busy = try sbd.waitFor(s.id, "alpha-busy's slow tool") { $0.state == .working && $0.claudePid != nil }
    let queued = try newSession(sbd, prompt: "hello", name: "bravo-queued", path: try repos.make("haacked/other"))
    try waitForQueued(sbd, queued.id, cap: 1)
    try waitForRepositories(sbd, busy, queued)
    return (sbd, busy, queued)
  }

  /// Waits until `sb live --json` shows the queued start's priority entry, and returns that status.
  @discardableResult
  func waitForQueuedPriority(_ sbd: Instance, _ queued: SessionSummary, _ entry: String) throws -> JSON {
    try sbd.waitFor(
      "\(queued.name)'s priority", fetch: { try sbd.liveStatus() },
      until: { liveEntry($0, "queued", queued.id)?["priority"]?.string == entry })
  }

  @Test func sbLiveJsonShowsThePriorityAndWhyAStartWaits() throws {
    let repos = try Repos()
    let (sbd, busy, queued) = try rankedQueue(repos)

    let status = try waitForQueuedPriority(sbd, queued, "haacked")

    #expect(status["priority"]?.array?.compactMap(\.string) == ["PostHog/posthog", "haacked"])
    #expect(liveEntry(status, "live", busy.id)?["priority"]?.string == "PostHog/posthog")
    #expect(liveEntry(status, "queued", queued.id)?["reason"]?.string == capFullReason(cap: 1))
  }

  @Test func sbLiveTextShowsThePriorityAndWhyAStartWaits() throws {
    let repos = try Repos()
    let (sbd, _, queued) = try rankedQueue(repos)
    try waitForQueuedPriority(sbd, queued, "haacked")

    let text = try sbd.sb("live")

    let lines = text.split(separator: "\n").map(String.init)
    let busyLine = lines.first { $0.contains("alpha-busy") } ?? ""
    let queuedLine = lines.first { $0.contains("bravo-queued") } ?? ""
    #expect(lines.contains { $0.contains("PostHog/posthog") && $0.contains("haacked") && !$0.contains("alpha-busy") })
    #expect(busyLine.contains("PostHog/posthog"), "\(text)")
    #expect(queuedLine.contains("haacked"), "\(text)")
    #expect(queuedLine.contains(capFullReason(cap: 1)), "\(text)")
  }

  /// A `livePriority` that isn't an array must not make sbd ignore config.json, whose default cap is 10.
  @Test func aBadLivePriorityKeepsTheCap() throws {
    let sbd = try instance(cap: 2, extra: ["livePriority": "PostHog"])

    #expect(try sbd.liveStatus()["cap"]?.int == 2)
  }

  // MARK: Jumps

  /// Ticks run only when the test moves the clock, so only a request can start claude.
  func jumpInstance(cap: Int) throws -> Instance { try instance(cap: cap, extra: ["tickSeconds": 3600]) }

  /// The opened session's SessionStart arrives through its hook, without a tick.
  @Test func openingAStoppedSessionStartsItWithoutATick() throws {
    let sbd = try jumpInstance(cap: 1)
    let stopped = try stoppedSession(sbd, name: "stopped", ticking: true)
    let idle = try idleSession(sbd, name: "idle", ticking: true)

    try sbd.sb("open", stopped.id)

    try sbd.waitFor(stopped.id, "the opened session's start") { $0.live }
    #expect(try !sbd.capStops(idle.id).isEmpty)
  }

  /// The user's real switch: x was on screen, so x is the last viewed until
  /// the open marks y viewed. A jump before that mark finds no session to stop.
  @Test func switchingFromAnIdleSessionStopsIt() throws {
    let sbd = try jumpInstance(cap: 1)
    let y = try stoppedSession(sbd, name: "y", ticking: true)
    let (x, detach) = try onScreenSession(sbd, name: "x", ticking: true)
    detach()
    try waitFor(sbd, x.id, "x off screen", ticking: true) { !$0.attached }

    try sbd.sb("open", y.id)

    try sbd.waitFor(y.id, "y's start") { $0.live }
    #expect(try !sbd.capStops(x.id).isEmpty)
  }

  /// The app sends the open while x is still on screen, then shows y's dead
  /// pane and leaves x. The tick then stops x for y, because y is the session
  /// the user opened last.
  @Test func aSwitchStopsTheSessionLeftOnceItLeavesTheScreen() throws {
    let sbd = try jumpInstance(cap: 1)
    let y = try stoppedSession(sbd, name: "y", ticking: true)
    let (x, detachX) = try onScreenSession(sbd, name: "x", ticking: true)

    try sbd.sb("open", y.id)
    #expect(try sbd.get(y.id).queued == true)

    let detachY = try sbd.attach(y.id)
    defer { detachY() }
    detachX()
    try waitFor(sbd, y.id, "y's start", ticking: true) { $0.live }
    #expect(try !sbd.capStops(x.id).isEmpty)
  }

  /// The request queues the opened session first, and the tick starts it first.
  @Test func openingJumpsAheadOfOlderStarts() throws {
    let sbd = try jumpInstance(cap: 1)
    let opened = try stoppedSession(sbd, name: "opened", ticking: true)
    let (a, detach) = try onScreenSession(sbd, name: "a", ticking: true)
    defer { detach() }
    let background = try sbd.new(prompt: "hello", name: "background")
    try waitForQueued(sbd, background.id, cap: 1)

    try sbd.sb("open", opened.id)

    #expect(try sbd.liveIds("queued") == [opened.id, background.id])
    try sbd.sb("stop", a.id)
    try waitFor(sbd, opened.id, "the opened session's start", ticking: true) { $0.live }
    #expect(try sbd.liveIds("queued") == [background.id])
  }

  /// The stub waits 5 s after SIGTERM before it exits, so the ticks after the
  /// jump see the stopped claude still running. Its slot belongs to the jump.
  @Test func aJumpWithNothingElseQueuedStopsOneSession() throws {
    let sbd = try jumpInstance(cap: 2)
    let stopped = try stoppedSession(sbd, name: "stopped", ticking: true)
    let lingering = try newSession(sbd, prompt: "linger 5", name: "lingering")
    try waitFor(sbd, lingering.id, "lingering's reply", ticking: true) {
      $0.lastReply == "I'll linger 5 s when I stop." && $0.claudePid != nil
    }
    let other = try idleSession(sbd, name: "other", ticking: true)
    try sbd.sb("open", stopped.id)
    #expect(try !sbd.capStops(lingering.id).isEmpty)

    try sbd.advanceClock(1)
    try sbd.advanceClock(1)

    #expect(try sbd.get(lingering.id).claudePid != nil, "the lingering claude still exits")
    #expect(try liveEntry(sbd.liveStatus(), "live", lingering.id)?["stopping"]?.bool == true)
    #expect(try sbd.capStops(other.id).isEmpty)
    #expect(try sbd.get(other.id).claudePid == other.claudePid)
  }

  @Test func aJumpWhileAStartIsQueuedStopsOneMore() throws {
    let sbd = try jumpInstance(cap: 2)
    let jumped = try stoppedSession(sbd, name: "jumped", ticking: true)
    let first = try idleSession(sbd, name: "first", ticking: true)
    let second = try idleSession(sbd, name: "second", ticking: true)
    let background = try sbd.new(prompt: "hello", name: "background")
    try waitForQueued(sbd, background.id, cap: 2)

    try sbd.sb("live", "--next", jumped.id)

    try waitFor(sbd, background.id, "the background start", ticking: true, timeout: 20) {
      $0.lastReply == "Done: hello"
    }
    try sbd.waitFor(jumped.id, "the jumped start") { $0.live }
    #expect(try [first, second, jumped, background].map { try sbd.capStops($0.id).count } == [1, 1, 0, 0])
  }

  @Test func aJumpWithNothingToStopWaitsAtTheFront() throws {
    let sbd = try jumpInstance(cap: 1)
    let jumped = try stoppedSession(sbd, name: "jumped", ticking: true)
    let (a, detach) = try onScreenSession(sbd, name: "a", ticking: true)
    defer { detach() }
    let background = try sbd.new(prompt: "hello", name: "background")
    try waitForQueued(sbd, background.id, cap: 1)

    try sbd.sb("live", "--next", jumped.id)

    let status = try sbd.liveStatus()
    #expect(status["queued"]?.array?.compactMap { $0["session"]?.string } == [jumped.id, background.id])
    #expect(liveEntry(status, "queued", jumped.id)?["reason"]?.string == capFullReason(cap: 1))
    #expect(try sbd.get(jumped.id).queued == true)
    try sbd.sb("stop", a.id)
    try waitFor(sbd, jumped.id, "the jumped start", ticking: true) { $0.live }
  }

  @Test func sbLiveNextRefusesARunningSession() throws {
    let sbd = try instance(cap: 2)
    let alpha = try idleSession(sbd, name: "alpha")

    let r = try sbd.run("live", "--next", alpha.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("alpha is already running"), "\(r.stderr)")
  }

  /// `open` on a live session only marks it viewed. It runs no plan.
  @Test func openingALiveSessionStopsNothing() throws {
    let sbd = try jumpInstance(cap: 1)
    let live = try idleSession(sbd, name: "live", ticking: true)
    let queued = try sbd.new(prompt: "hello", name: "queued")
    try waitForQueued(sbd, queued.id, cap: 1)

    try sbd.sb("open", live.id)

    #expect(try sbd.capStops(live.id).isEmpty)
    #expect(try sbd.liveIds("queued") == [queued.id])
  }

  /// A message isn't a view. Inbox and group sends reach many sessions, and a
  /// jump for each would skip the priority order.
  @Test func aMessageToAQueuedSessionDoesNotJump() throws {
    let sbd = try instance(cap: 1)
    let (_, detach) = try onScreenSession(sbd, name: "a")
    defer { detach() }
    let first = try sbd.new(name: "first")
    try waitForQueued(sbd, first.id, cap: 1)
    let second = try sbd.new(name: "second")
    try waitForQueued(sbd, second.id, cap: 1)

    try sbd.sb("send", second.id, "follow", "up")

    #expect(try sbd.liveIds("queued") == [first.id, second.id])
  }
}
