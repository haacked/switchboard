import Foundation
import SwitchboardCore
import Testing

/// The text of a resume that names no message, for a session that you paused without a reason.
let defaultResume = "Switchboard: You were paused by you. Continue where you left off."
/// The Claude pane's dead message while the session that you paused without a reason stays paused.
private let pausedPane = "Paused by you. Resume the session to start claude again."
private let stoppedPane = "Claude stopped. Switchboard resumes it when you open the session or send it a message."

extension Instance {
  /// The `pause` field of `sb get --json`, or nil when the session isn't paused.
  func pauseField(_ id: String) throws -> JSON? {
    let field = try summaryJSON(id)["pause"]
    return field == .null ? nil : field
  }

  func heldCount(_ id: String) throws -> Int? { try get(id).heldMessages }

  /// The `result` of each row of a group pause or resume, by session id.
  func results(_ report: JSON?) -> [String: String] {
    var out: [String: String] = [:]
    for row in report?["sessions"]?.array ?? [] {
      if let id = row["session"]?.string { out[id] = row["result"]?.string ?? "" }
    }
    return out
  }

  /// The id of the group's chat.
  func chatOf(_ group: String) throws -> String {
    try id(of: try #require(JSON.parse(try sb("chat", group, "--json"))))
  }

  /// Waits until the claude that the pause stopped has exited.
  @discardableResult
  func waitForPausedExit(_ id: String) throws -> SessionSummary {
    try waitFor(id, "claude to exit after the pause") { !$0.live && $0.claudePid == nil }
  }

  /// The session's `started` and `resumed` events after the mark.
  func launchEvents(_ id: String, after mark: Int64) throws -> [Event] {
    try events(id, after: mark).filter { ["started", "resumed"].contains($0.kind) }
  }

  func unpausedEvents(_ id: String, after mark: Int64) throws -> [Event] {
    try events(id, after: mark).filter { $0.kind == "unpaused" }
  }

  /// Checks that the session stays paused after `mark`: no `unpaused` event, no launch, and no live claude.
  func expectStillPaused(_ id: String, after mark: Int64) throws {
    #expect(try pauseField(id) != nil)
    #expect(try unpausedEvents(id, after: mark).isEmpty)
    #expect(try launchEvents(id, after: mark).isEmpty)
    #expect(try !get(id).live)
  }

  /// The prompts that the session's claude reported after the mark, oldest first.
  func promptsSince(_ id: String, after mark: Int64) throws -> [String] {
    try events(id, after: mark).filter { $0.kind == "UserPromptSubmit" }.compactMap { $0.data["prompt"]?.string }
  }

  /// Waits until the session's claude reported `count` prompts after the mark, and returns them.
  @discardableResult
  func waitForPrompts(_ id: String, after mark: Int64, count: Int, timeout: Double = 30) throws
    -> [String]
  {
    try waitFor(
      "\(count) prompts after event \(mark)", timeout: timeout, fetch: { try promptsSince(id, after: mark) },
      until: { $0.count >= count })
  }

  /// The session's `stopped` events with the reason after the mark.
  fileprivate func stopEvents(_ id: String, reason: String, after mark: Int64 = 0) throws -> [Event] {
    try events(id, after: mark).filter { $0.kind == "stopped" && $0.data["reason"]?.string == reason }
  }

  /// Advances the clock by three ticks of 6 s each. Each tick passes the 5 s limit between stops of a paused claude.
  func tickThrice() throws {
    for _ in 0..<3 { try advanceClock(6_000) }
    usleep(500_000)
  }

  /// Runs `sb pause <id> --json` with the extra arguments and returns what it printed.
  @discardableResult
  func pauseJSON(_ id: String, _ more: [String] = [], env: [String: String] = [:]) throws -> JSON {
    try #require(JSON.parse(try sb(["pause", id, "--json"] + more, env: env)))
  }

  /// A session whose first turn ended, with its claude still running and its pid known.
  func liveIdle(_ name: String = "t", prompt: String = "hello") throws -> SessionSummary {
    let s = try new(prompt: prompt, name: name)
    return try waitFor(s.id, "\(name)'s first reply") { $0.lastReply != nil && $0.claudePid != nil }
  }

  /// A session that you paused after its first turn, once its claude exited.
  func pausedStopped(_ name: String = "t", _ more: [String] = []) throws -> SessionSummary {
    let s = try liveIdle(name)
    try pauseJSON(s.id, more)
    return try waitForPausedExit(s.id)
  }

  /// The session ids in every list of `sb live --json`.
  fileprivate func idsInLiveStatus() throws -> [String] {
    let status = try #require(JSON.parse(try sb("live", "--json"))?.object)
    return status.values.compactMap(\.array).flatMap { $0.compactMap { $0["session"]?.string } }
  }

  /// Starts a session from inside `parent`, as a command that Claude runs there would.
  fileprivate func childOf(_ parent: String, name: String) throws -> SessionSummary {
    try JSONCoding.decode(
      SessionSummary.self,
      from: try sb(
        "new", "--json", "--name", name, "--prompt", "hello", work, env: ["SB_SESSION_ID": parent, "CLAUDECODE": "1"]))
  }

  /// The env of an sb command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["CLAUDECODE": "1", "SB_SESSION_ID": id] }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct PauseTests {
  // MARK: Pausing

  @Test func pausingAnIdleSessionStopsClaudeAndShowsPausedByYou() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let mark = try sbd.lastEventId(s.id)

    let printed = try sbd.pauseJSON(s.id)

    #expect(printed["pause"]?["by"] == "you")
    let after = try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    #expect(after.state == .waiting)
    #expect(after.reason == "Paused by you")
    #expect(after.triage == nil)
    #expect(try sbd.stopEvents(s.id, reason: "paused", after: mark).count == 1)
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "paused" }.count == 1)
    #expect(try !sbd.triage().contains { $0.id == s.id })
  }

  enum Pauser: String, CaseIterable, Sendable { case manager, chat, work }

  @Test(arguments: Pauser.allCases)
  func claudeInAnotherSessionPausesWithItsName(_ pauser: Pauser) throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let from: String
    let expected: String
    switch pauser {
    case .manager:
      from = try sbd.id(of: try #require(JSON.parse(try sbd.sb("manager", "--json"))))
      expected = "Paused by Manager"
    case .chat:
      _ = try sbd.sb("group", "add", "--json", "Flags", s.id)
      from = try sbd.id(of: try #require(JSON.parse(try sbd.sb("chat", "Flags", "--json"))))
      expected = "Paused by the Flags chat"
    case .work:
      from = try sbd.new(name: "flag-cache").id
      expected = "Paused by flag-cache"
    }

    let printed = try sbd.pauseJSON(s.id, env: sbd.inside(from))

    #expect(printed["reason"]?.string?.hasPrefix(expected) == true, "\(printed.text)")
    #expect(try sbd.get(s.id).reason == expected)
    let pause = try #require(try sbd.pauseField(s.id))
    #expect(pause["by"] == "claude")
    #expect(pause["from"]?["id"]?.string == from)
  }

  @Test func theReasonShowsInTheReasonInLsAndInGet() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()

    try sbd.pauseJSON(s.id, ["--reason", "free CPU for flags"])

    #expect(try sbd.get(s.id).reason == "Paused by you: free CPU for flags")
    #expect(try sbd.pauseField(s.id)?["reason"] == "free CPU for flags")
    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array?.first { $0["id"]?.string == s.id })
    #expect(listed["reason"] == "Paused by you: free CPU for flags")
    #expect(listed["pause"]?["reason"] == "free CPU for flags")
    let line = try #require(try sbd.sb("get", s.id).split(separator: "\n").first { $0.contains("paused:") })
    #expect(line.contains("by you"), "\(line)")
    #expect(line.contains("free CPU for flags"), "\(line)")
  }

  /// The app's sidebar label, Board card, and banner read these fields of `ls --json`.
  @Test func lsCarriesThePauseTheHeldCountAndTheBoardLineThatTheAppReads() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--reason", "free CPU for flags"])
    try sbd.sb("send", s.id, "check the logs")

    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array?.first { $0["id"]?.string == s.id })

    #expect(listed["pause"]?["by"] == "you")
    #expect(listed["pause"]?["reason"] == "free CPU for flags")
    #expect(listed["heldMessages"]?.int == 1)
    #expect(listed["board"]?["column"] == "waiting")
    #expect(listed["board"]?["line"] == "Paused by you: free CPU for flags")
    #expect(listed["board"]?["holder"] == "you")
  }

  @Test(arguments: [("ask which base should it target?", AttentionState.needsYou), ("offer", .canContinue)])
  func aSessionInTheInboxLeavesItWhenPaused(_ prompt: String, _ state: AttentionState) throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: prompt)
    try sbd.waitFor(s.id, "\(state.title)") { $0.lastReply != nil && $0.state == state && $0.claudePid != nil }
    try #require(try sbd.triage().contains { $0.id == s.id }, "the session never reached the Inbox")

    try sbd.pauseJSON(s.id)

    let paused = try sbd.waitFor(s.id, "the stop") { !$0.live }
    #expect(paused.state == .waiting)
    #expect(paused.triage == nil)
    #expect(try !sbd.triage().contains { $0.id == s.id })
  }

  @Test func pausingAPausedSessionReplacesTheReasonAndWhoAndKeepsSince() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--reason", "one"])
    let other = try sbd.new(name: "flag-cache")
    let since = try #require(try sbd.pauseField(s.id)?["since"]?.int)
    try sbd.advanceClock(60_000)

    try sbd.pauseJSON(s.id, ["--reason", "two"], env: sbd.inside(other.id))

    let after = try sbd.get(s.id)
    #expect(after.reason == "Paused by flag-cache: two")
    #expect(try sbd.pauseField(s.id)?["since"]?.int == since)
    #expect(Int(after.since) == since)
    #expect(try sbd.events(s.id).filter { $0.kind == "paused" }.count == 2)
  }

  // MARK: Refusals

  enum Refusal: String, CaseIterable, Sendable {
    case itself, claudePausesTheManager, claudePausesAGroupChat, claudeWithNoSessionPausesTheManager
    case unstartedFollowup
  }

  @Test(arguments: Refusal.allCases)
  func aRefusedPauseLeavesTheSessionUnpaused(_ refusal: Refusal) throws {
    let sbd = try Instance()
    let target: String
    var env: [String: String] = [:]
    var says: String?
    switch refusal {
    case .itself:
      target = try sbd.liveIdle().id
      env = sbd.inside(target)
      says = "sb wait"
    case .claudePausesTheManager:
      target = try sbd.id(of: try #require(JSON.parse(try sbd.sb("manager", "--json"))))
      env = try sbd.inside(sbd.new(name: "w").id)
    case .claudePausesAGroupChat:
      _ = try sbd.sb("group", "add", "--json", "Flags")
      target = try sbd.id(of: try #require(JSON.parse(try sbd.sb("chat", "Flags", "--json"))))
      env = try sbd.inside(sbd.new(name: "w").id)
    case .claudeWithNoSessionPausesTheManager:
      target = try sbd.id(of: try #require(JSON.parse(try sbd.sb("manager", "--json"))))
      env = ["CLAUDECODE": "1"]
    case .unstartedFollowup:
      target = try add(sbd, ["prompt": "Fix the cache."]).id
      says = "hasn't started"
    }

    let r = try sbd.run(["pause", target], env: env)

    #expect(r.status != 0, "\(r.stdout)")
    if let says { #expect(r.stderr.contains(says), "\(r.stderr)") }
    #expect(try sbd.pauseField(target) == nil)
    #expect(try !sbd.events(target).contains { $0.kind == "paused" })
  }

  // MARK: Holding messages

  enum Sender: String, CaseIterable, Sendable { case you, anotherSession }

  @Test(arguments: Sender.allCases)
  func aMessageToAPausedSessionIsHeldAndStartsNothing(_ sender: Sender) throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let env: [String: String] = try sender == .you ? [:] : sbd.inside(sbd.new(name: "other").id)
    let mark = try sbd.lastEventId(s.id)

    let reply = try #require(JSON.parse(try sbd.sb(["send", "--json", s.id, "check the logs"], env: env)))

    #expect(reply["held"] == "Paused by you")
    #expect(reply["delivery"] == "queued")
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
    #expect(try sbd.heldCount(s.id) == 1)
    #expect(try !sbd.get(s.id).live)
    let sent = try #require(try sbd.events(s.id, after: mark).last { $0.kind == "sent" })
    #expect(sent.data["held"] == true)
  }

  @Test func sbSendSaysThatTheMessageIsHeld() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()

    let out = try sbd.sb("send", s.id, "check the logs")

    #expect(out.contains("held until t resumes (Paused by you)"), "\(out)")
  }

  @Test func aSessionThatIsNotPausedWithAnEmptyQueueHasNoHeldMessagesField() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()

    #expect(try sbd.heldCount(s.id) == nil)
    #expect(try sbd.pauseField(s.id) == nil)
  }

  /// The tick's relaunch for `pending` skips a paused session after the restart, and the resume delivers the
  /// resume message first, then the held messages in the order they came.
  @Test func heldMessagesSurviveARestartAndFollowTheResumeMessageInOrder() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let since = try #require(try sbd.pauseField(s.id)?["since"]?.int)
    try sbd.sb("send", s.id, "first held note")
    try sbd.sb("send", s.id, "second held note")
    let beforeRestart = try sbd.lastEventId(s.id)

    sbd.stopSbd()
    try sbd.startSbd()

    try sbd.tickThrice()
    #expect(try sbd.launchEvents(s.id, after: beforeRestart).isEmpty)
    #expect(try sbd.pauseField(s.id) != nil)
    #expect(try sbd.heldCount(s.id) == 2)
    #expect(try sbd.sb("get", s.id).contains("2 messages held"))
    #expect(Int(try sbd.get(s.id).since) == since)
    try sbd.sb("send", s.id, "third held note")
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("resume", s.id, "--message", "go on")

    let expected = ["go on", "first held note", "second held note", "third held note"]
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 4) == expected)
    usleep(1_500_000)
    #expect(try sbd.promptsSince(s.id, after: mark) == expected)
    #expect(try sbd.heldCount(s.id) == nil)
  }

  /// A message that waited behind a turn before the pause stays ahead of the messages held during it.
  /// The resume message goes in front of both.
  @Test func aMessageQueuedBeforeThePauseFollowsTheResumeMessageAheadOfTheHeldOnes() throws {
    let sbd = try Instance()
    let s = try busy(sbd, "t")
    let queued = try #require(JSON.parse(try sbd.sb("send", "--json", s.id, "queued before")))
    #expect(queued["delivery"] == "queued")
    #expect(queued["held"] == nil)

    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)
    try sbd.sb("send", s.id, "held while paused")
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id, "--message", "go on")

    let expected = ["go on", "queued before", "held while paused"]
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 3) == expected)
    usleep(1_500_000)
    #expect(try sbd.promptsSince(s.id, after: mark) == expected)
  }

  /// sbd stops while the resumed claude waits before SessionStart, so the queue that `unpause` built in memory
  /// is gone. The restarted sbd must rebuild the same order from the log. The restarted sbd has no record of the
  /// launch prompt in flight, so only the production wait after SessionStart keeps a held note from going first.
  @Test func theResumeMessageStaysFirstWhenSbdRestartsBeforeItIsPasted() throws {
    let sbd = try Instance(config: Instance.productionPasteSettle)
    let s = try sbd.pausedStopped()
    try sbd.sb("send", s.id, "first held note")
    try sbd.sb("send", s.id, "second held note")
    sbd.hold("hold-start")
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id, "--message", "go on")
    try sbd.waitFor("the launch after the resume") { try !sbd.launchEvents(s.id, after: mark).isEmpty }

    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.release("hold-start")

    let expected = ["go on", "first held note", "second held note"]
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 3) == expected)
    usleep(1_500_000)
    #expect(try sbd.promptsSince(s.id, after: mark) == expected)
  }

  /// `send` waits up to 5 s for an exiting claude, so a 7 s exit outlasts it.
  @Test func aMessageSentWhileThePausedClaudeExitsIsNotPastedAndArrivesAfterTheResume() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle(prompt: "linger 7")
    let pastes = sbd.completePastes()
    try sbd.pauseJSON(s.id)

    let reply = try #require(JSON.parse(try sbd.sb("send", "--json", s.id, "while it exits")))

    #expect(reply["held"] == "Paused by you")
    usleep(2_000_000)
    #expect(sbd.completePastes() == pastes)
    try sbd.waitFor(s.id, "the lingering claude to exit", timeout: 20) { $0.claudePid == nil }
    #expect(sbd.completePastes() == pastes)
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id)
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 2) == [defaultResume, "while it exits"])
  }

  /// Claude Code doesn't attach the images of a prompt that starts it, so a held message with an image is pasted
  /// after the resume message.
  @Test func aHeldMessageWithAnImageFollowsTheResumeMessage() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let dir = "\(sbd.home.path)/pictures"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let picture = "\(dir)/shot.png"
    try AttachmentTests.png.write(to: URL(fileURLWithPath: picture))
    let reply = try #require(JSON.parse(try sbd.sb("send", "--json", s.id, "--image", picture, "look at this")))
    #expect(reply["held"] == "Paused by you")
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("resume", s.id)

    let prompts = try sbd.waitForPrompts(s.id, after: mark, count: 2)
    #expect(prompts.first == defaultResume)
    #expect(prompts.dropFirst().first?.contains("look at this") == true, "\(prompts)")
  }

  /// The paste waits at `hold-paste` until after the pause, so it reaches sbd's last check while the session is
  /// paused.
  @Test func aPasteThatStartsAfterThePauseWaitsForTheResume() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    // sbd pastes only `pasteSettleSeconds` after SessionStart. A paste that `send` starts reaches the gate at once.
    Thread.sleep(forTimeInterval: Instance.pasteSettleSeconds + 0.3)
    sbd.hold("hold-paste")
    let reply = try #require(JSON.parse(try sbd.sb("send", "--json", s.id, "late note")))
    try #require(reply["delivery"] == "pasted", "\(reply.text)")

    try sbd.pauseJSON(s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    try sbd.release("hold-paste")

    try sbd.waitFor("the message to wait for the resume") { try sbd.heldCount(s.id) == 1 }
    #expect(try !sbd.events(s.id).contains { $0.kind == "pasting" && $0.data["text"] == "late note" })
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id)
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 2) == [defaultResume, "late note"])
  }

  /// tmux reads the dead message as a format, and a format runs the command in `#(…)`.
  @Test func theClaudePaneShowsAReasonWithAHashAsWritten() throws {
    let sbd = try Instance()
    let reason = "fix #12 #(echo INJECTED)"
    let s = try sbd.pausedStopped("t", ["--reason", reason])

    try sbd.waitFor("the reason in the pane") { try sbd.screen(s.id).contains("Paused by you: \(reason).") }
  }

  // MARK: Resuming

  @Test func aResumeWithNothingHeldStartsClaudeWithTheDefaultResumeText() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("resume", s.id)

    try sbd.waitForPrompts(s.id, after: mark, count: 1)
    let resumed = try #require(try sbd.events(s.id, after: mark).first { $0.kind == "resumed" })
    #expect(resumed.data["trigger"] == "resume")
    #expect(resumed.data["prompt"]?.string == defaultResume)
    let launch = try #require(sbd.stubArgs().last { $0.hasPrefix("--resume \(s.claudeSessionId) ") })
    #expect(launch.contains(defaultResume), "\(launch)")
    #expect(try sbd.pauseField(s.id) == nil)
    let unpaused = try #require(try sbd.events(s.id, after: mark).first { $0.kind == "unpaused" })
    #expect(unpaused.data["by"] == "you")
  }

  @Test func aResumeBeforeThePausedClaudeExitsDeliversTheMessageOnceAfterTheExit() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle(prompt: "linger 7")
    let old = try #require(s.claudePid)
    let mark = try sbd.lastEventId(s.id)

    try sbd.pauseJSON(s.id)
    try sbd.sb("resume", s.id, "--message", "carry on now")

    try sbd.waitFor("the resume message", timeout: 40) {
      try sbd.promptsSince(s.id, after: mark).contains("carry on now")
    }
    #expect(!sbd.runs(old))
    #expect(try sbd.get(s.id).claudePid != old)
    try sbd.waitFor(s.id, "the resumed claude") { $0.live }
    usleep(1_500_000)
    #expect(try sbd.promptsSince(s.id, after: mark).filter { $0 == "carry on now" }.count == 1)
  }

  @Test func resumePromptStillResumesASessionThatIsNotPaused() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("resume", s.id, "--prompt", "keep at it")

    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 1) == ["keep at it"])
  }

  @Test func resumePromptIsTheResumeMessageOfAPausedSession() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("resume", s.id, "--prompt", "keep at it")

    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 1) == ["keep at it"])
    #expect(try sbd.pauseField(s.id) == nil)
  }

  @Test func resumeRefusesPromptWithMessageAndKeepsThePause() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let mark = try sbd.lastEventId(s.id)

    let r = try sbd.run(["resume", s.id, "--prompt", "one", "--message", "two"])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.pauseField(s.id) != nil)
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
  }

  // MARK: Nothing launches a paused session

  enum OpenPath: String, CaseIterable, Sendable { case open, terminals, terminalsWithTheClaudePaneMissing, liveNext }

  @Test(arguments: OpenPath.allCases)
  func openingAPausedSessionLaunchesNothing(_ path: OpenPath) throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let mark = try sbd.lastEventId(s.id)
    let runs = sbd.stubArgs().count
    let args: [String]
    switch path {
    case .open: args = ["open", s.id]
    case .terminals: args = ["open", s.id, "--terminals", "--json"]
    case .terminalsWithTheClaudePaneMissing:
      let claude = try sbd.client.terminals(s.id).claude
      try #require(try sbd.tmux("kill-session", "-t", "=\(claude)").status == 0)
      args = ["open", s.id, "--terminals", "--json"]
    case .liveNext: args = ["live", "--next", s.id]
    }

    let r = try sbd.run(args)

    #expect(r.status == 0, "\(r.stderr)")
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
    #expect(sbd.stubArgs().count == runs)
    #expect(try !sbd.get(s.id).live)
    #expect(try sbd.pauseField(s.id) != nil)
  }

  @Test func aMissingClaudePaneComesBackDeadWithThePauseMessage() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let claude = try sbd.client.terminals(s.id).claude
    try #require(try sbd.tmux("kill-session", "-t", "=\(claude)").status == 0)

    try sbd.sb("open", s.id, "--terminals", "--json")

    try sbd.waitFor("the pause message in the new pane") { try sbd.screen(s.id).contains(pausedPane) }
  }

  @Test func theClaudePaneSaysToResumeWhilePausedAndTheUsualTextAfterTheResume() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()

    try sbd.waitFor("the pause message in the pane") { try sbd.screen(s.id).contains(pausedPane) }

    try sbd.sb("resume", s.id)
    try sbd.waitFor(s.id, "the resumed claude") { $0.live && $0.claudePid != nil }
    try sbd.sb("stop", s.id)
    try sbd.waitFor("the usual message in the pane") { try sbd.screen(s.id).contains(stoppedPane) }
  }

  @Test func autoContinueLeavesAPausedSessionAlone() throws {
    let sbd = try Instance(config: ["autoContinue": ["quietSeconds": 60]])
    try sbd.sb("autocontinue", "on")
    let s = try sbd.new(prompt: "offer")
    try sbd.waitFor(s.id, "the offer") { $0.state == .canContinue && $0.claudePid != nil }
    let mark = try sbd.lastEventId(s.id)

    try sbd.pauseJSON(s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    try sbd.advanceClock(61_000)
    try sbd.tickThrice()

    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
  }

  @Test func aPausedParentHearsOfItsChildOnlyInTheDigestAfterTheResume() throws {
    let sbd = try Instance()
    let parent = try sbd.pausedStopped("p")
    let pauseMark = try sbd.lastEventId(parent.id)

    let kid = try sbd.childOf(parent.id, name: "kid")
    try sbd.waitForReply(kid)
    try sbd.tickThrice()

    #expect(try !sbd.events(parent.id, after: pauseMark).contains { $0.kind == "sent" })
    #expect(try sbd.launchEvents(parent.id, after: pauseMark).isEmpty)
    let mark = try sbd.lastEventId(parent.id)
    try sbd.sb("resume", parent.id)
    let prompts = try sbd.waitForPrompts(parent.id, after: mark, count: 1)
    #expect(prompts.first == defaultResume)
    try sbd.sb("send", parent.id, "what changed")
    try sbd.waitFor("the digest", timeout: 30) {
      try sbd.events(parent.id, after: mark).contains { $0.kind == "digest" }
    }
    #expect(try sbd.sbdMessages(parent.id).filter { $0.data["text"]?.string?.contains(kid.id) == true }.isEmpty)
  }

  // MARK: The live cap

  /// A session in the middle of a long tool call.
  private func busy(_ sbd: Instance, _ name: String) throws -> SessionSummary {
    let s = try sbd.new(prompt: "slow 30", name: name)
    return try sbd.waitFor(s.id, "\(name)'s slow tool") { $0.state == .working && $0.claudePid != nil }
  }

  @Test func pausingALiveSessionFreesItsSlotForAQueuedStart() throws {
    let sbd = try Instance(config: ["liveCap": 1])
    let a = try busy(sbd, "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    try sbd.waitFor(b.id, "b's queued start") { $0.reason.hasPrefix("queued") }

    try sbd.pauseJSON(a.id)

    try sbd.waitFor(b.id, "b's start", timeout: 30) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.idsInLiveStatus().contains(a.id))
    #expect(try !sbd.get(a.id).live)
  }

  @Test func aPausedQueuedSessionLosesItsPlaceAndDoesNotStartWhenASlotFrees() throws {
    let sbd = try Instance(config: ["liveCap": 1])
    let a = try busy(sbd, "a")
    let b = try sbd.new(prompt: "hello", name: "b")
    try sbd.waitFor(b.id, "b's queued start") { $0.reason.hasPrefix("queued") }

    try sbd.pauseJSON(b.id)

    #expect(try sbd.summaryJSON(b.id)["queued"]?.bool != true)
    #expect(try !sbd.idsInLiveStatus().contains(b.id))
    try sbd.sb("stop", a.id)
    try sbd.waitFor(a.id, "a's stop") { !$0.live && $0.claudePid == nil }
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(b.id, after: 0).isEmpty)
    #expect(!sbd.stubArgs().contains { $0.contains(b.claudeSessionId) })
    #expect(try sbd.get(b.id).reason == "Paused by you")
  }

  /// The resume's start queues behind the cap like any other, and the resume message stays first.
  @Test func aResumeWithTheCapFullQueuesAndKeepsTheResumeMessageFirst() throws {
    let sbd = try Instance(config: ["liveCap": 1])
    let b = try sbd.pausedStopped("b")
    try sbd.sb("send", b.id, "first held note")
    let a = try busy(sbd, "a")
    let mark = try sbd.lastEventId(b.id)

    try sbd.sb("resume", b.id, "--message", "go on")

    try sbd.waitFor(b.id, "b's queued start") { $0.reason.hasPrefix("queued") }
    #expect(try sbd.launchEvents(b.id, after: mark).isEmpty)
    try sbd.sb("stop", a.id)
    let expected = ["go on", "first held note"]
    #expect(try sbd.waitForPrompts(b.id, after: mark, count: 2) == expected)
    usleep(1_500_000)
    #expect(try sbd.promptsSince(b.id, after: mark) == expected)
  }

  // MARK: The tick

  /// The pause comes while claude waits before SessionStart, so sbd has no running claude to stop. The tick
  /// stops it once it runs, and only once.
  @Test func theTickStopsAClaudeThatWasStartingWhenPausedOnce() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    sbd.hold("hold-start")
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id)
    try sbd.waitFor(s.id, "the held claude") { $0.claudePid != nil }

    try sbd.pauseJSON(s.id)
    try sbd.release("hold-start")

    try sbd.waitFor(
      s.id, "the tick to stop the claude", timeout: 30,
      {
        // A step under the 5 s between stops drives a tick without allowing a second stop of the exiting claude.
        _ = try? sbd.advanceClock(1)
        return !$0.live && $0.claudePid == nil
      })
    try sbd.tickThrice()
    #expect(try sbd.stopEvents(s.id, reason: "paused", after: mark).count == 1)
    #expect(try !sbd.get(s.id).live)
  }

  /// A message that starts a stopped claude is its launch prompt. A pause that stops the claude before
  /// SessionStart holds the prompt, so the resume delivers it after the resume message.
  @Test func aLaunchPromptThatThePauseStopsArrivesAfterTheResume() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    sbd.hold("hold-start")
    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("send", s.id, "the task")
    try sbd.waitFor(s.id, "the held claude") { $0.claudePid != nil }

    try sbd.pauseJSON(s.id)
    try sbd.release("hold-start")
    try sbd.waitForPausedExit(s.id)
    #expect(try sbd.heldCount(s.id) == 1)

    try sbd.sb("resume", s.id)
    let prompts = try sbd.waitForPrompts(s.id, after: mark, count: 2)
    #expect(prompts.last == "the task", "\(prompts)")
  }

  /// A claude that waits before SessionStart and takes 10 s to exit after SIGTERM, through the stub's
  /// `hold-start` and `start-linger` gates. It returns the claude's pid.
  private func slowExitingClaudeBeforeStart(_ sbd: Instance, _ s: SessionSummary) throws -> Int {
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    sbd.hold("hold-start")
    try "10".write(toFile: sbd.gate("start-linger"), atomically: true, encoding: .utf8)
    try sbd.sb("resume", s.id)
    return try #require(try sbd.waitFor(s.id, "the held claude") { $0.claudePid != nil }.claudePid)
  }

  /// The pause's stop leaves a claude that never reported SessionStart running. The tick stops it again, at most
  /// once every 5 s.
  @Test func theTickStopsAPausedClaudeThatOutlastsTheStopAgainEveryFiveSeconds() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let old = try slowExitingClaudeBeforeStart(sbd, s)
    let mark = try sbd.lastEventId(s.id)

    try sbd.pauseJSON(s.id)

    try sbd.advanceClock(1_000)
    #expect(try sbd.stopEvents(s.id, reason: "paused", after: mark).count == 1)
    try sbd.advanceClock(5_000)
    #expect(try sbd.stopEvents(s.id, reason: "paused", after: mark).count == 2)
    try sbd.advanceClock(1_000)
    #expect(try sbd.stopEvents(s.id, reason: "paused", after: mark).count == 2)
    try sbd.release("hold-start")
    try sbd.release("start-linger")
    try sbd.waitFor(s.id, "the lingering claude to exit", timeout: 30) { $0.claudePid == nil }
    try sbd.tickThrice()
    let stops = try sbd.stopEvents(s.id, reason: "paused", after: mark)
    #expect(stops.allSatisfy { $0.data["pid"]?.int == old })
    #expect(zip(stops, stops.dropFirst()).allSatisfy { $1.t - $0.t >= 5_000 })
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
    #expect(try !sbd.get(s.id).live)
  }

  /// The paused claude never reported SessionStart and outlasts the 5 s that `resume` waits for it, so the resume
  /// message waits at the front of the queue. The tick launches claude for it once the old claude exits.
  @Test func aResumeBeforeAClaudeThatNeverStartedExitsLaunchesClaudeAfterTheExit() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let old = try slowExitingClaudeBeforeStart(sbd, s)
    let mark = try sbd.lastEventId(s.id)
    try sbd.pauseJSON(s.id)

    try sbd.sb("resume", s.id, "--message", "carry on now")
    try sbd.release("hold-start")
    try sbd.release("start-linger")

    let sent = try #require(
      try sbd.events(s.id, after: mark).first { $0.kind == "sent" && $0.data["text"]?.string == "carry on now" })
    #expect(sent.data["first"] == true, "the old claude exited before the resume, so the queue was not used")
    try sbd.waitFor("the resume message", timeout: 40) {
      try sbd.promptsSince(s.id, after: mark).contains("carry on now")
    }
    #expect(!sbd.runs(old))
    try sbd.waitFor(s.id, "the resumed claude") { $0.live }
    usleep(1_500_000)
    #expect(try sbd.promptsSince(s.id, after: mark).filter { $0 == "carry on now" }.count == 1)
    let launches = try sbd.launchEvents(s.id, after: mark)
    #expect(launches.count == 1)
    #expect(launches.first?.data["trigger"] == "resume")
  }

  /// The tick's first launch for the resume fails, because the session's folder is gone. The tick tries again
  /// once the folder is back, so the resume message is not stranded in the queue.
  @Test func aResumeLaunchThatFailsIsTriedAgainOnALaterTick() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    _ = try slowExitingClaudeBeforeStart(sbd, s)
    let mark = try sbd.lastEventId(s.id)
    try sbd.pauseJSON(s.id)
    try sbd.sb("resume", s.id, "--message", "carry on now")
    let away = s.cwd + ".away"
    try FileManager.default.moveItem(atPath: s.cwd, toPath: away)
    defer { try? FileManager.default.moveItem(atPath: away, toPath: s.cwd) }

    try sbd.release("hold-start")
    try sbd.release("start-linger")
    try sbd.waitFor(s.id, "the lingering claude to exit", timeout: 30) { $0.claudePid == nil }
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)

    try FileManager.default.moveItem(atPath: away, toPath: s.cwd)
    try sbd.waitFor("the resume message", timeout: 40) {
      try sbd.promptsSince(s.id, after: mark).contains("carry on now")
    }
    usleep(1_500_000)
    #expect(try sbd.promptsSince(s.id, after: mark).filter { $0 == "carry on now" }.count == 1)
    let launches = try sbd.launchEvents(s.id, after: mark)
    #expect(launches.count == 1)
    #expect(launches.first?.data["trigger"] == "resume")
  }

  /// A session whose folder went away while it was paused can't start, but its pause still ends, so it is never
  /// stuck paused. The resume sends nothing and launches nothing. It reports the folder's error.
  @Test func aResumeOfASessionWhoseFolderIsGoneEndsThePauseAndLaunchesNothing() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let mark = try sbd.lastEventId(s.id)
    let away = s.cwd + ".away"
    try FileManager.default.moveItem(atPath: s.cwd, toPath: away)
    defer { try? FileManager.default.moveItem(atPath: away, toPath: s.cwd) }

    let r = try sbd.run("resume", s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("is gone"), "\(r.stderr)")
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "unpaused" }.count == 1)
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "sent" }.isEmpty)
  }

  // MARK: Other commands on a paused session

  @Test func stopFailsOnAPausedSessionAndKeepsThePause() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()

    let r = try sbd.run("stop", s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("is not running"), "\(r.stderr)")
    #expect(try sbd.pauseField(s.id) != nil)
  }

  @Test func doneOutranksThePauseAndUndoneShowsItPausedAgain() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()

    try sbd.sb("done", s.id)

    #expect(try sbd.get(s.id).state == .done)
    #expect(try sbd.pauseField(s.id) != nil)
    try sbd.sb("undone", s.id)
    let undone = try sbd.get(s.id)
    #expect(undone.state == .waiting)
    #expect(undone.reason == "Paused by you")
  }

  @Test func movingAPausedSessionToAnotherGroupKeepsThePause() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    _ = try sbd.sb("group", "add", "--json", "Flags", s.id)
    _ = try sbd.sb("group", "add", "--json", "Billing")

    _ = try sbd.sb("group", "move", "--json", s.id, "--to", "Billing")

    #expect(try sbd.get(s.id).groupName == "Billing")
    #expect(try sbd.get(s.id).reason == "Paused by you")
    #expect(try sbd.pauseField(s.id) != nil)
  }

  @Test func rmRemovesAPausedSession() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    try sbd.sb("send", s.id, "check the logs")

    try sbd.sb("rm", s.id)

    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    #expect(!listed.contains { $0["id"]?.string == s.id })
  }
}

/// `sb pause` and `sb resume` on a session on a remote host, which the ssh stub stands in for.
@Suite(.blocking(timeLimit: .seconds(180))) struct PauseTestsOnARemoteHost {
  private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"

  /// A session on mini whose claude runs and has answered its first prompt.
  private func start(_ sbd: Instance) throws -> (id: String, pid: Int) {
    try sbd.makeBoxFolder()
    let summary = try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello")
    let id = try sbd.id(of: summary)
    let claudeSessionId = try #require(summary["claudeSessionId"]?.string)
    let pid = try #require(try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }.claudePid)
    try sbd.waitFor("the first turn's transcript on the box") { !sbd.boxTranscripts(claudeSessionId).isEmpty }
    return (id, pid)
  }

  @Test func pauseAndResumeStopAndStartClaudeOnTheHost() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)

    try sbd.sb("pause", s.id)

    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil && !$0.live }
    #expect(!sbd.runs(s.pid))
    #expect(try sbd.pauseField(s.id) != nil)
    #expect(sbd.boxStubArgs().count == 1)
    try sbd.sb("resume", s.id)
    try sbd.waitFor(s.id, "claude to run on the box again") { $0.claudePid != nil }
    #expect(sbd.boxStubArgs().count == 2)
    #expect(try sbd.pauseField(s.id) == nil)
  }

  @Test func pauseWithTheLinkDownIsRefusedAndLeavesTheSessionUnpaused() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    try sbd.connectHost()
    let s = try start(sbd)
    try sbd.dropLinkAndRefuse(refusal)

    let r = try sbd.run("pause", s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("mini is not connected"), "\(r.stderr)")
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(sbd.runs(s.pid))
  }

  /// A condition that comes due while sbd can't read the host keeps the pause. The tick resumes the session
  /// once, after the link returns.
  @Test func aConditionThatComesDueWithTheLinkDownResumesAfterTheLinkReturns() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    try sbd.connectHost()
    let s = try start(sbd)
    try sbd.sb("pause", s.id, "--until", "1h")
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil && !$0.live }
    try sbd.dropLinkAndRefuse(refusal)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * 3_600_000)
    try sbd.tickThrice()

    #expect(try sbd.pauseField(s.id) != nil)
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "unpaused" }.isEmpty)
    try sbd.restoreLink()
    try sbd.waitFor(
      s.id, "claude to run on the box again", timeout: 30,
      {
        _ = try? sbd.advanceClock(1)
        return $0.claudePid != nil
      })
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "unpaused" }.count == 1)
  }
}
