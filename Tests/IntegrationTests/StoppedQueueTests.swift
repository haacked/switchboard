import Foundation
import SwitchboardCore
import Testing

/// How a claude exits before its SessionStart while a message waits in sbd's queue. sbd records `running` for
/// such a claude after 10 s without a hook, and a send then queues its message, because claude is not ready for
/// a paste.
enum EarlyExit: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// The stub waits before SessionStart while `hold-start` exists, and SIGTERM then ends it with no hook.
  case killed
  /// The stub shows the workspace trust dialog while `ask-trust` exists, and Escape there ends it with no hook.
  case exitAtTrustDialog

  var testDescription: String { rawValue }

  var gate: String {
    switch self {
    case .killed: "hold-start"
    case .exitAtTrustDialog: "ask-trust"
    }
  }
}

/// A message that waits for a running claude that has not taken it yet.
enum WaitingMessage: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// A send queued behind a running turn.
  case queuedBehindATurn
  /// A paste whose UserPromptSubmit has not arrived, because the stub holds `lag held` until `report` exists.
  case pastedInFlight
  /// The prompt of a launch whose claude waits before SessionStart.
  case launchPromptInFlight
  /// A send queued for a claude that waits before SessionStart, after sbd recorded `running` for it.
  case queuedBeforeSessionStart

  var testDescription: String { rawValue }
}

/// A message queued for a claude that then stopped before it took the message. The queue waits for claude's next
/// launch, which delivers it. It does not count as a message on its way, so `account move`, schedules, and the
/// other prompts that sbd sends do not wait on it. A running claude that has a queued or in-flight message still
/// refuses the move.
@Suite(.blocking(timeLimit: .seconds(180))) struct StoppedQueueTests {
  static let queuedText = "the stranded note"

  /// A sbd with accounts A and B and A active, so new sessions run under A and a move to B copies the transcript.
  func instance() throws -> Instance {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    return sbd
  }

  func delivery(_ printed: String) throws -> String? {
    try #require(JSON.parse(printed))["delivery"]?.string
  }

  /// The `queued:` lines of what `sb get` printed.
  static func queuedLines(in shown: String) -> [String] {
    shown.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("queued:") }
  }

  /// Runs `sb account move --json B` with the arguments, whatever its exit status, and decodes what it printed.
  func move(_ sbd: Instance, _ args: [String]) throws -> (status: Int32, result: AccountMove) {
    let r = try sbd.run(["account", "move", "--json", "B"] + args)
    let result = try #require(
      try? JSONCoding.decode(AccountMove.self, from: r.stdout), "sb account move \(args): \(text(r))")
    return (r.status, result)
  }

  /// Waits for the session's claude to run, and returns its pid.
  func waitForClaudePid(_ sbd: Instance, _ id: String) throws -> Int {
    try #require(try sbd.waitFor(id, "claude to run") { $0.claudePid != nil }.claudePid)
  }

  /// Launches the stopped session's claude with `sb open` behind the exit's gate. Returns once sbd has recorded
  /// `running` for that claude, which has sent no SessionStart, and returns that claude's pid.
  @discardableResult
  func launchUnreported(_ sbd: Instance, _ s: SessionSummary, _ exit: EarlyExit, after mark: Int64) throws -> Int {
    sbd.hold(exit.gate)
    try sbd.sb("open", s.id)
    let pid = try waitForClaudePid(sbd, s.id)
    if exit == .exitAtTrustDialog {
      try sbd.waitFor("the trust dialog") { try sbd.screen(s.id).contains("Accessing workspace:") }
    }
    try sbd.passUnreportedFallback(s.id, after: mark)
    return pid
  }

  /// A stopped session under A whose message waits in sbd's queue: its claude launched, never sent SessionStart,
  /// took the queued message into the queue, and exited. The exit's gate is gone on return, so the next launch
  /// reaches SessionStart.
  func stranded(_ sbd: Instance, _ exit: EarlyExit) throws -> SessionSummary {
    let s = try AccountTests().stoppedSession(sbd)
    let mark = try sbd.lastEventId(s.id)
    let pid = try launchUnreported(sbd, s, exit, after: mark)
    try #require(try delivery(sbd.sb("send", "--json", s.id, Self.queuedText)) == "queued")

    switch exit {
    case .killed: kill(pid_t(pid), SIGTERM)
    case .exitAtTrustDialog: try sbd.press(s.id, "Escape")
    }

    try sbd.waitFor(s.id, "claude to exit before SessionStart") { $0.claudePid == nil && !$0.live }
    try #require(try !sbd.events(s.id, after: mark).contains { $0.kind == "SessionStart" })
    try sbd.release(exit.gate)
    return s
  }

  /// Gives the session's running claude a message that it has not taken yet, and returns the session.
  func runningWithAWaitingMessage(_ sbd: Instance, _ waiting: WaitingMessage) throws -> SessionSummary {
    switch waiting {
    case .queuedBehindATurn:
      let s = try sbd.liveIdle("busy")
      try sbd.sb("send", s.id, "slow 30")
      try sbd.waitFor(s.id, "the slow tool") { $0.state == .working }
      try #require(try delivery(sbd.sb("send", "--json", s.id, "behind the turn")) == "queued")
      return s
    case .pastedInFlight:
      let s = try sbd.liveIdle("busy")
      // The send pastes at once, or queues until claude is ready for a paste. Either way, a paste follows.
      try sbd.sb("send", s.id, "lag held")
      try sbd.waitFor("the paste of the held message") { try !sbd.events(s.id, "pasting", text: "lag held").isEmpty }
      return s
    case .launchPromptInFlight:
      let s = try AccountTests().stoppedSession(sbd)
      sbd.hold("hold-start")
      try #require(try delivery(sbd.sb("send", "--json", s.id, "launch prompt")) == "resumed")
      _ = try waitForClaudePid(sbd, s.id)
      return s
    case .queuedBeforeSessionStart:
      let s = try AccountTests().stoppedSession(sbd)
      try launchUnreported(sbd, s, .killed, after: try sbd.lastEventId(s.id))
      try #require(try delivery(sbd.sb("send", "--json", s.id, "before SessionStart")) == "queued")
      return s
    }
  }

  // MARK: The queue waits for the next launch

  /// The tick does not launch the claude again, and a restart of sbd keeps the queue. The next start of claude
  /// delivers the message once.
  @Test(arguments: EarlyExit.allCases) func aQueuedMessageWaitsThroughARestartForClaudesNextStart(
    _ exit: EarlyExit
  ) throws {
    let sbd = try instance()
    let s = try stranded(sbd, exit)
    try sbd.tickThrice()

    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.tickThrice()

    #expect(try sbd.heldCount(s.id) == 1)
    #expect(try sbd.events(s.id, "delivered", text: Self.queuedText).isEmpty)
    #expect(try !sbd.promptsSince(s.id, after: 0).contains(Self.queuedText))
    #expect(sbd.stubInputCount(Self.queuedText) == 0)
    let shown = try sbd.sb("get", s.id)
    #expect(
      Self.queuedLines(in: shown) == ["queued:  1 message waits for claude's next start. sb open \(s.id) starts it"],
      "\(shown)")
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("open", s.id)

    try sbd.waitFor("the delivery of the queued message", timeout: 30) {
      try !sbd.events(s.id, "delivered", text: Self.queuedText).isEmpty
    }
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 1) == [Self.queuedText])
    try sbd.waitFor(s.id, "the reply to the queued message") { $0.lastReply == "Done: \(Self.queuedText)" }
    #expect(try sbd.events(s.id, "delivered", text: Self.queuedText).count == 1)
    #expect(try sbd.heldCount(s.id) == nil)
    #expect(Self.queuedLines(in: try sbd.sb("get", s.id)).isEmpty)
  }

  /// A send to the stopped claude launches it, and the launch takes the queued message before the new one.
  @Test(arguments: EarlyExit.allCases) func aSendToTheStoppedClaudeDeliversTheQueuedMessageFirst(
    _ exit: EarlyExit
  ) throws {
    let sbd = try instance()
    let s = try stranded(sbd, exit)
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("send", s.id, "the new note")

    let expected = [Self.queuedText, "the new note"]
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 2) == expected)
    try sbd.waitFor(s.id, "the reply to the new message") { $0.lastReply == "Done: the new note" }
    #expect(try sbd.promptsSince(s.id, after: mark) == expected)
    #expect(try sbd.heldCount(s.id) == nil)
  }

  // MARK: sb account move

  /// The move takes the stopped session with its queue, its dry run first, and the next launch under B delivers
  /// the message. How claude exited does not matter to the move, which sees only a stopped claude with a queue.
  @Test func aMoveTakesAStoppedSessionWithItsQueue() throws {
    let sbd = try instance()
    let s = try stranded(sbd, .killed)
    let plan = try move(sbd, ["--dry-run", "--session", s.id])
    #expect(plan.result.moved == [s.id], "\(plan.result)")
    #expect(try sbd.get(s.id).account == sbd.account("A"))

    let moved = try move(sbd, ["--session", s.id])

    #expect(moved.status == 0)
    #expect(moved.result.moved == [s.id])
    #expect(moved.result.blocked.isEmpty, "\(moved.result.blocked)")
    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(try sbd.heldCount(s.id) == 1)
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("open", s.id)

    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 1) == [Self.queuedText])
    try sbd.waitFor(s.id, "the reply to the queued message") { $0.lastReply == "Done: \(Self.queuedText)" }
    // sbd records `delivered` after the paste returns, which can come after claude's reply.
    try sbd.waitFor("the delivery of the queued message") {
      try !sbd.events(s.id, "delivered", text: Self.queuedText).isEmpty
    }
    #expect(try sbd.events(s.id, "delivered", text: Self.queuedText).count == 1)
    let launch = try #require(sbd.stubCalls().last { $0.args.contains(s.claudeSessionId) })
    #expect(launch.account == sbd.account("B"))
    #expect(launch.args.contains("--resume \(s.claudeSessionId)"), "\(launch.args)")
  }

  /// A paused session's held messages move with it, and the resume under B delivers them.
  @Test func aMoveTakesAPausedStoppedSessionWithItsHeldMessages() throws {
    let sbd = try instance()
    let s = try sbd.pausedStopped()
    try sbd.sb("send", s.id, "held note")

    let moved = try move(sbd, ["--session", s.id])

    #expect(moved.status == 0, "\(moved.result)")
    #expect(moved.result.moved == [s.id], "\(moved.result)")
    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(try sbd.heldCount(s.id) == 1)
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("resume", s.id)

    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 2) == [defaultResume, "held note"])
    let launch = try #require(sbd.stubCalls().last { $0.args.contains(s.claudeSessionId) })
    #expect(launch.account == sbd.account("B"))
  }

  /// The bulk move and the move with `--stop` list the stopped session as one that moves, their dry runs first,
  /// and then move it.
  @Test(arguments: [[], ["--stop", "--session"]])
  func everyFormOfTheMoveTakesAStoppedSessionWithAQueue(_ form: [String]) throws {
    let sbd = try instance()
    let s = try stranded(sbd, .killed)
    let args = form.last == "--session" ? form + [s.id] : form

    let plan = try move(sbd, ["--dry-run"] + args)
    #expect(plan.result.moved.contains(s.id), "\(plan.result)")
    #expect(!plan.result.blocked.contains { $0.session == s.id }, "\(plan.result)")
    #expect(try sbd.get(s.id).account == sbd.account("A"))

    let result = try move(sbd, args)

    #expect(result.status == 0, "\(result.result)")
    #expect(result.result.moved.contains(s.id), "\(result.result)")
    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(try sbd.heldCount(s.id) == 1)
  }

  /// A running claude that has a queued or in-flight message refuses every form of the move. A dry run with
  /// `--stop` does not list it as movable, so a move with `--stop` leaves its claude running.
  @Test(arguments: WaitingMessage.allCases) func aRunningClaudeWithAWaitingMessageRefusesEveryFormOfTheMove(
    _ waiting: WaitingMessage
  ) throws {
    let sbd = try instance()
    let s = try runningWithAWaitingMessage(sbd, waiting)
    let pid = try waitForClaudePid(sbd, s.id)

    let stopPlan = try move(sbd, ["--stop", "--dry-run", "--session", s.id])
    #expect(stopPlan.status != 0, "\(stopPlan.result)")
    #expect(stopPlan.result.moved.isEmpty, "\(stopPlan.result)")
    let reason = stopPlan.result.blocked.first { $0.session == s.id }?.reason ?? ""
    #expect(reason.contains("a message is on its way"), "\(reason)")

    // The move with --stop comes last, because a wrong answer would stop the claude.
    let forms = [
      ["--dry-run", "--session", s.id], ["--session", s.id], ["--dry-run"], [], ["--stop", "--session", s.id],
    ]
    for form in forms {
      let r = try move(sbd, form)
      #expect(!r.result.moved.contains(s.id), "\(form): \(r.result)")
      #expect(r.result.blocked.contains { $0.session == s.id }, "\(form): \(r.result)")
      if form.contains("--session") { #expect(r.status != 0, "\(form)") }
    }

    let kept = try sbd.get(s.id)
    #expect(kept.claudePid == pid)
    #expect(kept.account == sbd.account("A"))
    #expect(try sbd.events(s.id).allSatisfy { $0.kind != "account-moved" })
  }

  /// sbd restarts before claude submits its launch prompt. The restarted sbd reads the launch from the log, so the
  /// prompt still counts as on its way. A move with `--stop` refuses and leaves claude running, because stopping
  /// claude would drop the prompt.
  @Test(arguments: ConversationEndTests.HeldLaunch.allCases)
  func aLaunchPromptInFlightRefusesTheMoveAfterARestart(_ held: ConversationEndTests.HeldLaunch) throws {
    let sbd = try instance()
    let s = try AccountTests().stoppedSession(sbd)
    let mark = try sbd.lastEventId(s.id)
    held.hold(sbd)
    try #require(try delivery(sbd.sb("send", "--json", s.id, "launch prompt")) == "resumed")
    try held.waitForTheHold(sbd, s.id, after: mark)
    let pid = try waitForClaudePid(sbd, s.id)
    sbd.killSbd()
    try sbd.startSbd()
    _ = try waitForClaudePid(sbd, s.id)

    let plan = try move(sbd, ["--stop", "--dry-run", "--session", s.id])
    let r = try move(sbd, ["--stop", "--session", s.id])

    #expect(plan.status != 0, "\(plan.result)")
    #expect(plan.result.moved.isEmpty, "\(plan.result)")
    let reason = plan.result.blocked.first { $0.session == s.id }?.reason ?? ""
    #expect(reason.contains("a message is on its way"), "\(reason)")
    #expect(r.status != 0, "\(r.result)")
    #expect(!r.result.moved.contains(s.id), "\(r.result)")
    let kept = try sbd.get(s.id)
    #expect(kept.claudePid == pid)
    #expect(kept.account == sbd.account("A"))
    #expect(try sbd.events(s.id).allSatisfy { $0.kind != "account-moved" })
  }

  // MARK: Schedules

  /// The due schedule fires instead of waiting with "a message is on its way". Its send launches claude, which
  /// takes the queued message before the schedule's prompt.
  @Test func aDueScheduleRunsOnAStoppedSessionWithAQueuedMessage() throws {
    let sbd = try instance()
    let s = try stranded(sbd, .killed)
    let schedules = ScheduleFireTests()
    let made = try schedules.schedule(sbd, s.id, "tick one")
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let run = try schedules.waitForRun(sbd, s.id, made.id)
    #expect(run.outcome == .queued)
    #expect(run.error == nil)
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 2) == [Self.queuedText, "tick one"])
  }

  /// A start that waits behind the full live cap delivers the queue, so its queue still counts as a message on
  /// its way. The first due schedule queues the start, and the second waits for that start.
  @Test func aSecondDueScheduleWaitsForAStartQueuedBehindTheLiveCap() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset, config: ["liveCap": 1])
    let s = try AccountTests().stoppedSession(sbd)
    let other = try sbd.new(prompt: "busy", name: "other")
    try sbd.waitFor(other.id, "the other reply") { $0.lastReply == "Done: busy" }
    // The tick never stops the session that the user opened last, so the start stays queued.
    try sbd.sb("open", other.id)
    let schedules = ScheduleFireTests()
    let first = try schedules.schedule(sbd, s.id, "tick one")
    let second = try schedules.schedule(sbd, s.id, "tick two")

    func schedulesThatRan() throws -> [String] {
      try [first.id, second.id].filter { try schedules.current(sbd, s.id, $0)?.last != nil }
    }

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let ran = try sbd.waitFor("a run of either schedule", fetch: schedulesThatRan, until: { !$0.isEmpty })
    try sbd.tickThrice()
    #expect(try schedulesThatRan() == ran)
    #expect(ran.count == 1, "\(ran)")
    #expect(try sbd.events(s.id).contains { $0.kind == "start-queued" })
    #expect(try sbd.heldCount(s.id) == 1)
  }

  /// A paste that has not run yet still counts after claude exits, for the in-flight window. A due schedule
  /// waits, so its launch can't put its prompt ahead of the paste's message.
  @Test func aDueScheduleWaitsForAPasteStillOnItsWayToAClaudeThatExited() throws {
    let sbd = try instance()
    let s = try sbd.liveIdle()
    let schedules = ScheduleFireTests()
    let made = try schedules.schedule(sbd, s.id, "tick one")
    try sbd.advanceClock(55_000)
    usleep(2_000_000)
    sbd.hold("hold-paste")
    try sbd.sb("send", s.id, "the held paste")
    usleep(500_000)
    let pid = try waitForClaudePid(sbd, s.id)
    kill(pid_t(pid), SIGKILL)
    try sbd.waitFor(s.id, "claude to exit") { $0.claudePid == nil }

    // The schedule comes due 6 s after the paste started, inside the 10 s in-flight window.
    try sbd.advanceClock(6_000)
    usleep(1_000_000)

    #expect(try schedules.current(sbd, s.id, made.id)?.last == nil)
    #expect(sbd.stubCalls().allSatisfy { !$0.args.contains("tick one") })
    try sbd.release("hold-paste")
  }

  // MARK: heldMessages and the queued: line

  /// `heldMessages` counts the queue of a session that is not paused, and `sb get` prints a `queued:` line.
  @Test func aRunningSessionWithAQueuedMessageShowsItsQueue() throws {
    let sbd = try instance()
    let s = try runningWithAWaitingMessage(sbd, .queuedBehindATurn)

    #expect(try sbd.heldCount(s.id) == 1)
    let shown = try sbd.sb("get", s.id)
    #expect(Self.queuedLines(in: shown) == ["queued:  1 message waits for the turn to end"], "\(shown)")
  }

  /// A paused session's held messages show on its `paused:` line, not on a `queued:` line.
  @Test func aPausedSessionPrintsItsHeldMessagesOnlyOnThePausedLine() throws {
    let sbd = try instance()
    let s = try sbd.pausedStopped()
    try sbd.sb("send", s.id, "held note")

    let shown = try sbd.sb("get", s.id)

    #expect(try sbd.heldCount(s.id) == 1)
    #expect(shown.contains("1 message held"), "\(shown)")
    #expect(Self.queuedLines(in: shown).isEmpty, "\(shown)")
  }
}
