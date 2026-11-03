import Foundation
import SwitchboardCore
import Testing

extension Instance {
  func autoContinueStatus() throws -> AutoContinueStatus {
    try JSONCoding.decode(AutoContinueStatus.self, from: try sb("autocontinue", "status", "--json"))
  }

  /// The blocker that the status shows for the session, or nil when nothing
  /// holds it back. It throws when the status doesn't list the session.
  func blocker(_ id: String) throws -> String? {
    guard let row = try autoContinueStatus().sessions.first(where: { $0.session == id }) else {
      throw TestError(description: "the auto-continue status doesn't list \(id)")
    }
    return row.blocker
  }

  func autoContinues(_ id: String) throws -> [Event] {
    try events(id).filter { $0.kind == "auto-continue" }
  }

  /// The messages that sbd sent to the session on its own.
  func sbdMessages(_ id: String) throws -> [Event] {
    try events(id).filter { $0.kind == "sent" && $0.data["by"]?.string == "sbd" }
  }
}

@Suite(.timeLimit(.minutes(2))) struct AutoContinueTests {
  static let quietSeconds = 60
  /// Past the quiet time, and well short of the 600 s idle stop.
  static let pastQuiet: Int64 = 61_000
  static let hourMs: Int64 = 3600 * 1000

  /// `liveCap` is a top-level setting. `extra` sets the rest of `autoContinue`.
  func instance(_ extra: [String: JSON] = [:], liveCap: Int? = nil, shell: String = "/bin/sh") throws -> Instance {
    var settings: [String: JSON] = ["quietSeconds": .number(Double(AutoContinueTests.quietSeconds))]
    settings.merge(extra) { $1 }
    var config: [String: JSON] = ["autoContinue": .object(settings)]
    if let liveCap { config["liveCap"] = .number(Double(liveCap)) }
    return try Instance(shell: shell, config: config)
  }

  /// A session whose reply offered a next step, so that it is in Claude can continue.
  func offerSession(_ sbd: Instance, name: String = "t") throws -> SessionSummary {
    let s = try sbd.new(prompt: "offer", name: name)
    return try sbd.waitFor(s.id, "the offer") { $0.state == .canContinue }
  }

  @discardableResult
  func waitForContinue(_ sbd: Instance, _ id: String, count: Int = 1, timeout: Double = 15) throws -> [Event] {
    try sbd.waitFor(
      "\(count) auto-continue events", timeout: timeout, fetch: { try sbd.autoContinues(id) },
      until: {
        $0.count >= count
      })
  }

  @Test func isOffByDefault() throws {
    let sbd = try instance()
    let s = try offerSession(sbd)
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    let status = try sbd.autoContinueStatus()
    #expect(!status.enabled)
    // The switch being off is not a blocker.
    #expect(status.sessions.map(\.session) == [s.id])
    #expect(status.sessions.first?.blocker == nil)
    #expect(try sbd.get(s.id).state == .canContinue)
    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
  }

  @Test func theSwitchRoundTripsAndSurvivesARestart() throws {
    let sbd = try instance()
    #expect(try !sbd.autoContinueStatus().enabled)
    try sbd.sb("autocontinue", "on")
    #expect(try sbd.autoContinueStatus().enabled)
    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try sbd.autoContinueStatus().enabled)
    try sbd.sb("autocontinue", "off")
    #expect(try !sbd.autoContinueStatus().enabled)
    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try !sbd.autoContinueStatus().enabled)
  }

  @Test func theRequestSetsTheSwitchAndReturnsTheStatus() throws {
    let sbd = try instance()
    let on = try sbd.client.call("autocontinue", ["enabled": true], as: AutoContinueStatus.self)
    #expect(on.enabled)
    #expect(try sbd.client.call("autocontinue", as: AutoContinueStatus.self).enabled)
    let off = try sbd.client.call("autocontinue", ["enabled": false], as: AutoContinueStatus.self)
    #expect(!off.enabled)
  }

  @Test func statusReportsTheSettingsFromTheConfig() throws {
    let sbd = try instance(["message": "Carry on.", "perHour": 2], liveCap: 5)
    let status = try sbd.autoContinueStatus()
    #expect(status.message == "Carry on.")
    #expect(status.quietSeconds == AutoContinueTests.quietSeconds)
    #expect(status.perHour == 2)
    #expect(status.liveCap == 5)
    #expect(status.sessions.isEmpty)
  }

  @Test func statusCountsTheLiveSessions() throws {
    let sbd = try instance()
    let a = try sbd.new(prompt: "hello", name: "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    for s in [a, b] { try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" } }
    #expect(try sbd.autoContinueStatus().live == 2)
    try sbd.sb("stop", a.id)
    try sbd.waitFor(a.id, "the stop") { $0.claudePid == nil }
    try sbd.waitFor("one live session", fetch: { try sbd.autoContinueStatus().live }, until: { $0 == 1 })
  }

  @Test func statusTextShowsTheSwitchAndEachSessionsBlocker() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd, name: "parser")
    try sbd.waitFor(
      "the status to list the session", fetch: { try sbd.blocker(s.id) },
      until: {
        $0.hasPrefix("you touched it")
      })
    let lines = try sbd.sb("autocontinue", "status").split(separator: "\n").map(String.init)
    #expect(lines.first == "auto-continue is on")
    #expect(lines.contains { $0.contains("Yes, go ahead.") }, "\(lines)")
    #expect(
      lines.contains { ($0.contains(s.id) || $0.contains("parser")) && $0.contains("you touched it") }, "\(lines)")
    #expect(try sbd.sb("autocontinue").split(separator: "\n").first == "auto-continue is on")
    try sbd.sb("autocontinue", "off")
    #expect(try sbd.sb("autocontinue", "status").split(separator: "\n").first == "auto-continue is off")
  }

  @Test func continuesASessionOnceTheQuietTimePasses() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    let event = try #require(try waitForContinue(sbd, s.id).first)
    #expect(event.data["text"]?.string == "Yes, go ahead.")
    #expect(event.data["offer"]?.string == s.reason)
    // The paste waits for the prompt to settle, so it may queue first.
    #expect(["pasted", "queued"].contains(event.data["delivery"]?.string))
    #expect(event.data["error"] == nil)
    try sbd.waitFor(s.id, "the reply to the continue") { $0.lastReply == "Done: Yes, go ahead." }
    #expect(try sbd.sbdMessages(s.id).map { $0.data["text"]?.string } == ["Yes, go ahead."])
  }

  @Test func sbEventsShowsTheContinue() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    try waitForContinue(sbd, s.id)
    let lines = try sbd.sb("events", "--json", "--session", s.id).split(separator: "\n")
    let kinds = try lines.map { try JSONCoding.decode(Event.self, from: String($0)).kind }
    #expect(kinds.contains("auto-continue"))
  }

  @Test func sbdsMessageIsNotATouch() throws {
    // The continue's reply offers again. The quiet time comes before the
    // limit, so the limit holds it back only when sbd's message was no touch.
    let sbd = try instance(["message": "offer again", "perHour": 1])
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    try waitForContinue(sbd, s.id)
    try sbd.waitFor(
      "the reply to the continue", fetch: { try sbd.blocker(s.id) },
      until: {
        $0 == "continued 1 times in the last hour"
      })
  }

  @Test func aSessionTouchedWithinTheQuietTimeWaits() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.advanceClock(30_000)
    let blocker = try #require(try sbd.blocker(s.id))
    #expect(blocker.hasPrefix("you touched it"))
    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
  }

  @Test func aMessageFromTheUserRestartsTheQuietTime() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.advanceClock(30_000)
    try sbd.sb("send", s.id, "offer")
    try sbd.waitFor(
      "the second offer", fetch: { try sbd.events(s.id).filter { $0.kind == "Stop" }.count },
      until: {
        $0 == 2
      })
    try sbd.waitFor(s.id, "Claude can continue") { $0.state == .canContinue }
    // 70 s since the first prompt, and 40 s since the message.
    try sbd.advanceClock(40_000)
    let blocker = try #require(try sbd.blocker(s.id))
    #expect(blocker.hasPrefix("you touched it"))
    #expect(try sbd.autoContinues(s.id).isEmpty)
    try sbd.advanceClock(25_000)
    try waitForContinue(sbd, s.id)
  }

  @Test func aPaneOnScreenWaitsAndTheQuietTimeCountsFromTheDetach() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    let detach = try sbd.attach(s.id)
    try sbd.waitFor(s.id, "the attached flag") { $0.attached }
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    #expect(try sbd.blocker(s.id) == "on screen")
    #expect(try sbd.autoContinues(s.id).isEmpty)
    detach()
    try sbd.waitFor(s.id, "the detach") { !$0.attached }
    try sbd.waitFor(
      "the quiet time after the detach", fetch: { try sbd.blocker(s.id) },
      until: {
        $0.hasPrefix("you touched it")
      })
    #expect(try sbd.autoContinues(s.id).isEmpty)
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    try waitForContinue(sbd, s.id)
  }

  @Test func timeOnScreenWhileTheSwitchIsOffCountsAsATouch() throws {
    let sbd = try instance()
    let s = try offerSession(sbd)
    let detach = try sbd.attach(s.id)
    try sbd.waitFor(s.id, "the attached flag") { $0.attached }
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    detach()
    try sbd.waitFor(s.id, "the detach") { !$0.attached }
    try sbd.sb("autocontinue", "on")
    let blocker = try #require(try sbd.blocker(s.id))
    #expect(blocker.hasPrefix("you touched it"), "\(blocker)")
    #expect(try sbd.autoContinues(s.id).isEmpty)
  }

  @Test func anOpenCardIsNotContinued() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.sb("send", s.id, "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
    #expect(try sbd.get(s.id).cards.count == 1)
  }

  @Test func anOpenWaitIsNotContinued() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.sb("wait", s.id, "CI", "on", "#12")
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test func aRunningTurnIsNotContinued() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.sb("send", s.id, "slow 20")
    try sbd.waitFor(s.id, "the slow tool") { $0.state == .working }
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
    #expect(try sbd.get(s.id).state == .working)
  }

  @Test func perHourLimitsTheContinuesUntilAnHourPasses() throws {
    // Each continue's reply offers again, and sbd's message is no touch, so
    // the second continue follows the first one's reply.
    let sbd = try instance(["message": "offer again", "perHour": 2])
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    try sbd.waitFor(
      "the third continue to wait", timeout: 30, fetch: { try sbd.blocker(s.id) },
      until: {
        $0 == "continued 2 times in the last hour"
      })
    #expect(try sbd.autoContinues(s.id).count == 2)
    #expect(try sbd.sbdMessages(s.id).count == 2)
    // The hour also passes the idle stop, so the third continue may resume claude.
    try sbd.advanceClock(AutoContinueTests.hourMs + AutoContinueTests.pastQuiet)
    let all = try waitForContinue(sbd, s.id, count: 3, timeout: 30)
    #expect(all.map { $0.data["text"]?.string } == ["offer again", "offer again", "offer again"])
  }

  @Test func aStoppedSessionWaitsForAFreeSlotUnderTheLiveCap() throws {
    let sbd = try instance(liveCap: 1)
    let a = try offerSession(sbd, name: "a")
    try sbd.sb("stop", a.id)
    let stopped = try sbd.waitFor(a.id, "a's stop") { $0.claudePid == nil }
    #expect(stopped.state == .canContinue)
    let b = try sbd.new(prompt: "hello", name: "b")
    try sbd.waitFor(b.id, "b's reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("autocontinue", "on")
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    try sbd.waitFor(
      "the live cap to hold a back", fetch: { try sbd.blocker(a.id) },
      until: {
        $0 == "the live cap of 1 is full"
      })
    #expect(try sbd.autoContinues(a.id).isEmpty)
    try sbd.sb("stop", b.id)
    let event = try #require(try waitForContinue(sbd, a.id).first)
    #expect(event.data["delivery"]?.string == "resumed")
    try sbd.waitFor(a.id, "the resumed reply") { $0.lastReply == "Done: Yes, go ahead." }
    #expect(sbd.stubArgs().contains { $0.hasPrefix("--resume \(a.claudeSessionId) ") })
  }

  /// The pane's shell takes 1.5 s to start claude, and the clock passes the
  /// 10 s in-flight window meanwhile. The `lag` message then reaches claude
  /// 1 s after its SessionStart, while ticks run.
  @Test func aSlowStartDoesNotContinueTwice() throws {
    let sbd = try instance(["message": "lag"], shell: Instance.slowShell)
    let s = try offerSession(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
    try sbd.sb("autocontinue", "on")
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    try waitForContinue(sbd, s.id)
    try sbd.advanceClock(11_000)
    try sbd.waitFor(s.id, "the reply to the continue", timeout: 30) { $0.lastReply == "Done: lag" }
    #expect(try sbd.autoContinues(s.id).count == 1)
  }

  @Test func oneTickResumesNoMoreStoppedSessionsThanTheLiveCapAllows() throws {
    let sbd = try instance(liveCap: 1)
    let a = try offerSession(sbd, name: "a")
    let b = try offerSession(sbd, name: "b")
    for s in [a, b] {
      try sbd.sb("stop", s.id)
      try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
    }
    try sbd.sb("autocontinue", "on")
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    try sbd.waitFor(
      "one continue", fetch: { try [a, b].filter { try !sbd.autoContinues($0.id).isEmpty } },
      until: { !$0.isEmpty })
    let continued = try [a, b].filter { try !sbd.autoContinues($0.id).isEmpty }
    #expect(continued.count == 1)
    let held = continued.first?.id == a.id ? b : a
    #expect(try sbd.blocker(held.id) == "the live cap of 1 is full")
  }

  @Test func aRunningSessionIgnoresAFullLiveCap() throws {
    let sbd = try instance(liveCap: 1)
    let a = try offerSession(sbd, name: "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    try sbd.waitFor(b.id, "b's reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("autocontinue", "on")
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    let event = try #require(try waitForContinue(sbd, a.id).first)
    #expect(["pasted", "queued"].contains(event.data["delivery"]?.string))
  }
}
