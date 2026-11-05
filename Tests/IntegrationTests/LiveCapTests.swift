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

@Suite(.timeLimit(.minutes(2))) struct LiveCapTests {
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
  func onScreenSession(_ sbd: Instance, name: String) throws -> (SessionSummary, () -> Void) {
    let s = try idleSession(sbd, name: name)
    let detach = try sbd.attach(s.id)
    return (try sbd.waitFor(s.id, "\(name) on screen") { $0.attached }, detach)
  }

  /// A session whose first turn has ended, with claude still running.
  func idleSession(_ sbd: Instance, name: String) throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    return try sbd.waitFor(s.id, "\(name)'s first reply") { $0.lastReply == "Done: hello" && $0.claudePid != nil }
  }

  /// A session whose claude was stopped after its first turn.
  func stoppedSession(_ sbd: Instance, name: String) throws -> SessionSummary {
    let s = try idleSession(sbd, name: name)
    try sbd.sb("stop", s.id)
    return try sbd.waitFor(s.id, "\(name)'s stop") { $0.claudePid == nil && !$0.live }
  }

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

    #expect(text.contains("2"), "\(text)")
    #expect(text.contains("alpha-busy"), "\(text)")
    #expect(text.contains("bravo-busy"), "\(text)")
    #expect(text.contains("charlie-queued"), "\(text)")
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

  // MARK: Which idle session sbd stops

  @Test func anIdleSessionIsStoppedToMakeRoom() throws {
    let sbd = try instance(cap: 1)
    let a = try idleSession(sbd, name: "a")

    let b = try sbd.new(prompt: "hello", name: "b")

    try sbd.waitFor(b.id, "b's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(a.id).isEmpty)
    #expect(try sbd.get(a.id).claudePid == nil)
  }

  @Test func aDoneSessionIsStoppedBeforeALongerIdleOne() throws {
    let sbd = try instance(cap: 2)
    let plain = try idleSession(sbd, name: "plain")
    let finished = try idleSession(sbd, name: "finished")
    try sbd.sb("done", finished.id)

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(finished.id).isEmpty)
    #expect(try sbd.get(plain.id).claudePid == plain.claudePid)
    #expect(try !sbd.events(plain.id).contains { $0.kind == "stopped" })
  }

  /// A wait also makes sbd stop the session 2 s after its last activity. The
  /// cap may not be what stops it, but the plain session must keep running.
  @Test func aWaitingSessionIsStoppedBeforeALongerIdleOne() throws {
    let sbd = try instance(cap: 2)
    let plain = try idleSession(sbd, name: "plain")
    let waiting = try idleSession(sbd, name: "waiting")
    try sbd.sb("wait", waiting.id, "CI", "on", "#12")

    let c = try sbd.new(prompt: "hello", name: "c")

    try sbd.waitFor(c.id, "c's start", timeout: 20) { $0.lastReply == "Done: hello" }
    try sbd.waitFor(waiting.id, "the waiting session's stop") { $0.claudePid == nil }
    #expect(try sbd.get(plain.id).claudePid == plain.claudePid)
    #expect(try !sbd.events(plain.id).contains { $0.kind == "stopped" })
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

  // MARK: sb live --set

  @Test func setChangesTheCapThatSbLiveShows() throws {
    let sbd = try instance(cap: 2)

    let result = JSON.parse(try sbd.sb("live", "--set", "5", "--json"))

    #expect(result?["cap"]?.int == 5)
    #expect(try sbd.liveStatus()["cap"]?.int == 5)
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
}
