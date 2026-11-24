import SwitchboardCore
import Testing

@testable import SwitchboardApp

let scheduleNow: Int64 = 1_700_000_000_000
let minuteMs: Int64 = 60_000

func scheduleFixture(
  _ id: String, _ prompt: String = "Run the Waiting audit", every: Int64 = 30 * minuteMs,
  next: Int64 = scheduleNow + 12 * minuteMs, paused: Bool? = nil, last: Schedule.Run? = nil
) -> Schedule {
  Schedule(
    id: id, prompt: prompt, every: every, next: next, paused: paused, by: .you, created: scheduleNow - every,
    last: last)
}

func scheduledSession(
  _ schedules: [Schedule]?, waits: [Wait] = [], markedDone: Bool = false, pause: Pause? = nil,
  removal: Removal.State? = nil
) -> SessionSummary {
  var s = waitingSession(waits, markedDone: markedDone)
  s.schedules = schedules
  s.pause = pause
  s.removal = removal.map { removalFixture($0) }
  return s
}

/// A removal of the session in `state`.
func removalFixture(_ state: Removal.State) -> Removal {
  var r = Removal(requested: 0, notBefore: 0, worktree: true, branch: true, remoteBranch: false, resolve: [])
  r.state = state
  return r
}

let sessionPause = Pause(by: .you, since: 0)

/// A session that holds none of its schedules: not marked done, not paused, and not being removed.
let freeSession = scheduledSession(nil)

/// The session facts that decide whether sbd's tick holds a session's schedules, with the hold each one gives.
enum SessionShape: CaseIterable, CustomTestStringConvertible {
  case free, done, paused, doneAndPaused, removalQueued, removalRunning, removalFailed

  var session: SessionSummary {
    switch self {
    case .free: freeSession
    case .done: scheduledSession(nil, markedDone: true)
    case .paused: scheduledSession(nil, pause: sessionPause)
    case .doneAndPaused: scheduledSession(nil, markedDone: true, pause: sessionPause)
    case .removalQueued: scheduledSession(nil, removal: .queued)
    case .removalRunning: scheduledSession(nil, removal: .running)
    case .removalFailed: scheduledSession(nil, removal: .failed)
    }
  }

  /// A failed removal no longer holds the session, so its schedules run.
  var hold: String? {
    switch self {
    case .free, .removalFailed: nil
    case .done, .doneAndPaused: "the session is marked done"
    case .paused: "the session is paused"
    case .removalQueued, .removalRunning: "the session is being removed"
    }
  }

  var testDescription: String { "\(self)" }
}

@Suite struct ScheduleListTests {
  @Suite struct Timing {
    @Test func anActiveScheduleShowsItsIntervalAndHowSoonItRuns() {
      let caption = ScheduleCaption(scheduleFixture("r1"), session: freeSession, now: scheduleNow)

      #expect(caption.timing == "every 30m · next in 12m")
    }

    @Test func anIntervalInHoursShowsInHours() {
      let caption = ScheduleCaption(
        scheduleFixture("r1", every: 120 * minuteMs, next: scheduleNow + 90 * minuteMs), session: freeSession,
        now: scheduleNow)

      #expect(caption.timing == "every 2h · next in 1h")
    }

    @Test func aScheduleWhoseRunIsPastDueSaysHowLateItIsAndThatItRunsWhenTheSessionIsFree() {
      let caption = ScheduleCaption(
        scheduleFixture("r1", next: scheduleNow - 5 * minuteMs), session: freeSession, now: scheduleNow)

      #expect(caption.timing == "every 30m · due 5m ago, runs when the session is free")
    }

    /// Core counts a schedule as due from the moment `next` comes.
    @Test func aScheduleDueThisMomentSaysItRunsWhenTheSessionIsFree() {
      let caption = ScheduleCaption(scheduleFixture("r1", next: scheduleNow), session: freeSession, now: scheduleNow)

      #expect(caption.timing == "every 30m · due 0s ago, runs when the session is free")
    }

    @Test func aScheduleLateByItsGraceSaysOverdue() {
      let caption = ScheduleCaption(
        scheduleFixture("r1", next: scheduleNow - 45 * minuteMs), session: freeSession, now: scheduleNow)

      #expect(caption.timing == "every 30m · overdue by 45m, runs when the session is free")
    }

    @Test func aDueScheduleOnASessionMarkedDoneSaysWhyItIsHeld() {
      let caption = ScheduleCaption(
        scheduleFixture("r1", next: scheduleNow - 5 * minuteMs), session: scheduledSession(nil, markedDone: true),
        now: scheduleNow)

      #expect(caption.timing == "every 30m · held: the session is marked done")
    }

    @Test func aPausedScheduleSaysPaused() {
      let caption = ScheduleCaption(scheduleFixture("r1", paused: true), session: freeSession, now: scheduleNow)

      #expect(caption.timing == "every 30m · paused")
    }

    /// A paused schedule keeps the `next` it had, which can be in the past. It is not held, so it doesn't say due.
    @Test func aPausedScheduleWhoseNextRunHasPassedSaysPausedNotDue() {
      let caption = ScheduleCaption(
        scheduleFixture("r1", next: scheduleNow - 5 * minuteMs, paused: true), session: freeSession, now: scheduleNow)

      #expect(caption.timing == "every 30m · paused")
    }
  }

  @Suite struct LastResult {
    @Test func aScheduleThatHasNotRunSaysNeverRan() {
      #expect(ScheduleCaption(scheduleFixture("r1"), session: freeSession, now: scheduleNow).result == "never ran")
    }

    @Test func aPastedRunWithNoSkippedTimesShowsTheOutcomeAndTheAge() {
      let run = Schedule.Run(t: scheduleNow - 5 * minuteMs, outcome: .pasted, skipped: 0)

      #expect(
        ScheduleCaption(scheduleFixture("r1", last: run), session: freeSession, now: scheduleNow).result
          == "last: pasted 5m ago")
    }

    @Test func aPastedRunWithSkippedTimesCountsThem() {
      let run = Schedule.Run(t: scheduleNow - 5 * minuteMs, outcome: .pasted, skipped: 2)

      #expect(
        ScheduleCaption(scheduleFixture("r1", last: run), session: freeSession, now: scheduleNow).result
          == "last: pasted 5m ago · 2 skipped")
    }

    @Test(arguments: [Schedule.Run.Outcome.resumed, .queued])
    func aDeliveredRunNamesHowItWasDelivered(_ outcome: Schedule.Run.Outcome) {
      let run = Schedule.Run(t: scheduleNow - 3 * minuteMs, outcome: outcome, skipped: 0)

      #expect(
        ScheduleCaption(scheduleFixture("r1", last: run), session: freeSession, now: scheduleNow).result
          == "last: \(outcome.rawValue) 3m ago")
    }

    @Test func aFailedRunShowsTheError() {
      let run = Schedule.Run(
        t: scheduleNow - 2 * minuteMs, outcome: .failed, skipped: 0, error: "the folder /work/gone is missing")

      #expect(
        ScheduleCaption(scheduleFixture("r1", last: run), session: freeSession, now: scheduleNow).result
          == "last: failed 2m ago: the folder /work/gone is missing")
    }

    /// A gated check appends no run, so a top-up's row shows its last check beside its last run.
    @Test func aTopupShowsItsLastCheckAfterItsLastRun() {
      let run = Schedule.Run(t: scheduleNow - 3 * 24 * 60 * minuteMs, outcome: .pasted, skipped: 0)
      var schedule = scheduleFixture("r1", last: run)
      var gate = Schedule.Gate(
        group: "g1", repo: "acme/widgets", target: 5, template: "Fix {url}", rubric: "Bugs first")
      gate.last = Schedule.Gate.Check(
        t: scheduleNow - 2 * minuteMs, result: .gated, active: 5, target: 5, started: [], skipped: [])
      schedule.gate = gate

      #expect(
        ScheduleCaption(schedule, session: freeSession, now: scheduleNow).result
          == "last: pasted 3d ago · top-up 5/5 · checked 2m ago: gated")
    }

    @Test func aTopupThatHasNotCheckedShowsOnlyItsLastRun() {
      var schedule = scheduleFixture("r1")
      schedule.gate = Schedule.Gate(
        group: "g1", repo: "acme/widgets", target: 5, template: "Fix {url}", rubric: "Bugs first")

      #expect(ScheduleCaption(schedule, session: freeSession, now: scheduleNow).result == "never ran")
    }
  }

  @Suite struct Prompt {
    @Test func theRowShowsTheWholePrompt() {
      let prompt = "Run the Waiting audit.\nThen list the sessions that need me.\nThen stop.\nAnd a fourth line."

      #expect(ScheduleCaption(scheduleFixture("r1", prompt), session: freeSession, now: scheduleNow).prompt == prompt)
    }
  }

  @Suite struct PauseButton {
    @Test func anActiveScheduleOffersPause() {
      #expect(ScheduleCaption(scheduleFixture("r1"), session: freeSession, now: scheduleNow).toggleTitle == "Pause")
    }

    @Test func aPausedScheduleOffersResume() {
      #expect(
        ScheduleCaption(scheduleFixture("r1", paused: true), session: freeSession, now: scheduleNow).toggleTitle
          == "Resume")
    }
  }

  /// `sb schedule ls` and the app read the same schedule. Their captions say the same thing.
  @Suite struct MatchesTheCLI {
    static let schedules: [Schedule] = [
      scheduleFixture("r1"),
      scheduleFixture("r2", next: scheduleNow),
      scheduleFixture("r3", next: scheduleNow - 45 * minuteMs),
      scheduleFixture("r4", paused: true),
      scheduleFixture("r5", every: 7 * 24 * 60 * minuteMs, next: scheduleNow + 3 * 24 * 60 * minuteMs),
      scheduleFixture("r6", every: 90_000, next: scheduleNow + 30_000),
      scheduleFixture("r7", last: Schedule.Run(t: scheduleNow - 1_000, outcome: .resumed, skipped: 0)),
      scheduleFixture("r8", last: Schedule.Run(t: scheduleNow - 3 * 3_600_000, outcome: .queued, skipped: 11)),
      scheduleFixture("r9", last: Schedule.Run(t: scheduleNow - 2 * minuteMs, outcome: .failed, skipped: 1, error: "")),
    ]

    /// `printSchedules` in `Sources/sb/Schedules.swift` builds the hold from the same three session facts and
    /// prints `timingText` of the status text.
    @Test(arguments: schedules, SessionShape.allCases)
    func theTimingIsTheCLIsStatusLine(_ schedule: Schedule, _ shape: SessionShape) {
      let s = shape.session
      let hold = Schedule.hold(done: s.markedDone, paused: s.pause != nil, removing: s.removal?.holdsSession == true)

      let caption = ScheduleCaption(schedule, session: s, now: scheduleNow)

      #expect(caption.timing == schedule.timingText(ScheduleStatus(schedule, hold: hold, now: scheduleNow).text))
    }

    @Test(arguments: schedules)
    func theResultIsTheCLIsLastText(_ schedule: Schedule) {
      #expect(
        ScheduleCaption(schedule, session: freeSession, now: scheduleNow).result == schedule.lastText(now: scheduleNow))
    }
  }

  static let failedRun = Schedule.Run(
    t: scheduleNow - 2 * minuteMs, outcome: .failed, skipped: 0, error: "the folder /work/gone is missing")
  /// Due 5 minutes ago on a 30m loop, inside its 30 minute grace.
  static let due = scheduleFixture("r1", next: scheduleNow - 5 * minuteMs)
  /// Due 2 hours ago on a 30m loop, past its 30 minute grace.
  static let overdue = scheduleFixture("r1", next: scheduleNow - 120 * minuteMs)
  static let active = scheduleFixture("r1")
  static let failed = scheduleFixture("r1", last: failedRun)
  static let heldShapes: [SessionShape] = [.done, .paused, .doneAndPaused, .removalQueued, .removalRunning]

  /// The status of a schedule comes from the session facts that sbd's tick reads, so the row says held exactly
  /// when the tick skips the session.
  @Suite struct Status {
    func caption(_ schedule: Schedule, _ session: SessionSummary = freeSession) -> ScheduleCaption {
      ScheduleCaption(schedule, session: session, now: scheduleNow)
    }

    @Test(arguments: [ScheduleListTests.due, ScheduleListTests.overdue], SessionShape.allCases)
    func aDueScheduleGetsTheStatusOfItsSessionsHold(_ schedule: Schedule, _ shape: SessionShape) {
      #expect(caption(schedule, shape.session).status == ScheduleStatus(schedule, hold: shape.hold, now: scheduleNow))
    }

    @Test func aDueScheduleOnASessionMarkedDoneIsHeld() {
      let caption = caption(ScheduleListTests.due, scheduledSession(nil, markedDone: true))

      #expect(caption.status.state == .held)
      #expect(caption.status.text == "held: the session is marked done")
    }

    @Test func aDueScheduleOnAPausedSessionIsHeld() {
      let caption = caption(ScheduleListTests.due, scheduledSession(nil, pause: sessionPause))

      #expect(caption.status.state == .held)
      #expect(caption.status.text == "held: the session is paused")
    }

    @Test(arguments: [Removal.State.queued, .running])
    func aDueScheduleOnASessionBeingRemovedIsHeld(_ state: Removal.State) {
      let caption = caption(ScheduleListTests.due, scheduledSession(nil, removal: state))

      #expect(caption.status.state == .held)
      #expect(caption.status.text == "held: the session is being removed")
    }

    @Test func aDueScheduleOnASessionMarkedDoneAndPausedNamesTheDoneHold() {
      let caption = caption(ScheduleListTests.due, scheduledSession(nil, markedDone: true, pause: sessionPause))

      #expect(caption.status.text == "held: the session is marked done")
    }

    /// A loop on a held session waits for the user to reopen or resume the session, so it does not light the badge.
    @Test(arguments: ScheduleListTests.heldShapes)
    func anOverdueScheduleOnAHeldSessionNeedsNoAttention(_ shape: SessionShape) {
      let caption = caption(ScheduleListTests.overdue, shape.session)

      #expect(caption.status.state == .held)
      #expect(!caption.status.needsAttention)
    }

    @Test func aFailedRemovalDoesNotHoldTheSchedule() {
      let caption = caption(ScheduleListTests.overdue, scheduledSession(nil, removal: .failed))

      #expect(caption.status.state == .overdue)
      #expect(caption.status.needsAttention)
    }

    @Test func aFailedRunNeedsAttention() {
      let caption = caption(ScheduleListTests.failed)

      #expect(caption.status.state == .failed)
      #expect(caption.status.text == "failed 2m ago: the folder /work/gone is missing · next in 12m")
      #expect(caption.status.needsAttention)
    }

    @Test(arguments: ScheduleListTests.heldShapes)
    func aFailedRunOnAHeldSessionStillNeedsAttention(_ shape: SessionShape) {
      let schedule = scheduleFixture("r1", next: scheduleNow - 5 * minuteMs, last: ScheduleListTests.failedRun)

      let caption = caption(schedule, shape.session)

      #expect(caption.status.state == .failed)
      #expect(caption.status.needsAttention)
    }

    @Test func anOverdueLoopNeedsAttention() {
      let caption = caption(ScheduleListTests.overdue)

      #expect(caption.status.state == .overdue)
      #expect(caption.status.text == "overdue by 2h, runs when the session is free")
      #expect(caption.status.needsAttention)
    }

    /// A 30m loop's grace is 30 minutes.
    @Test func aLoopLateByExactlyItsGraceIsOverdue() {
      let caption = caption(scheduleFixture("r1", next: scheduleNow - 30 * minuteMs))

      #expect(caption.status.state == .overdue)
      #expect(caption.status.needsAttention)
    }

    @Test func aLoopOneMillisecondInsideItsGraceIsDueAndNeedsNoAttention() {
      let caption = caption(scheduleFixture("r1", next: scheduleNow - 30 * minuteMs + 1))

      #expect(caption.status.state == .due)
      #expect(!caption.status.needsAttention)
    }

    @Test func anActiveLoopNeedsNoAttention() {
      let caption = caption(ScheduleListTests.active)

      #expect(caption.status.state == .active)
      #expect(caption.status.text == "next in 12m")
      #expect(!caption.status.needsAttention)
    }

    /// The user stopped the loop, so neither its failed run nor its session's hold makes it need attention.
    @Test(arguments: SessionShape.allCases)
    func aPausedLoopWithAFailedRunSaysPausedAndNeedsNoAttention(_ shape: SessionShape) {
      let schedule = scheduleFixture(
        "r1", next: scheduleNow - 120 * minuteMs, paused: true, last: ScheduleListTests.failedRun)

      let caption = caption(schedule, shape.session)

      #expect(caption.status.state == .paused)
      #expect(!caption.status.needsAttention)
    }
  }

  /// Run Now is disabled exactly when sbd's `run-schedule` refuses: for a paused schedule, and for any schedule
  /// of a session that sbd's tick holds, due or not.
  @Suite struct RunNowButton {
    func caption(_ schedule: Schedule, _ session: SessionSummary = freeSession) -> ScheduleCaption {
      ScheduleCaption(schedule, session: session, now: scheduleNow)
    }

    @Test(arguments: [
      ScheduleListTests.active, ScheduleListTests.due, ScheduleListTests.overdue, ScheduleListTests.failed,
    ])
    func aScheduleOnAFreeSessionCanRunNow(_ schedule: Schedule) {
      #expect(caption(schedule).runNowBlocker == nil)
    }

    @Test func aPausedScheduleCantRunNowAndSaysItIsPaused() {
      let blocker = caption(scheduleFixture("r1", paused: true)).runNowBlocker

      #expect(blocker?.contains("paused") == true)
    }

    /// A schedule that isn't due yet shows `active` on a held session. sbd still refuses Run Now for it.
    @Test(
      arguments: [ScheduleListTests.active, ScheduleListTests.due, ScheduleListTests.failed],
      ScheduleListTests.heldShapes)
    func aScheduleOnAHeldSessionCantRunNowAndNamesTheHold(_ schedule: Schedule, _ shape: SessionShape) throws {
      let hold = try #require(shape.hold)

      let blocker = caption(schedule, shape.session).runNowBlocker

      #expect(blocker?.contains(hold) == true)
    }

    /// sbd checks the schedule's pause before the session's hold, so the reason names the pause.
    @Test func aPausedScheduleOnAHeldSessionSaysItIsPaused() throws {
      let blocker = try #require(
        caption(scheduleFixture("r1", paused: true), scheduledSession(nil, markedDone: true)).runNowBlocker)

      #expect(blocker.contains("paused"))
      #expect(!blocker.contains("the session is marked done"))
    }

    @Test func aScheduleOnASessionWhoseRemovalFailedCanRunNow() {
      #expect(caption(ScheduleListTests.active, scheduledSession(nil, removal: .failed)).runNowBlocker == nil)
    }
  }

  /// Delete asks first, because the loop's prompt is lost.
  @Suite struct DeleteConfirmation {
    @Test func theQuestionNamesTheLinesOfThePromptOnOneLine() {
      let schedule = scheduleFixture("r1", "Run the Waiting audit.\nThen list the sessions that need me.")

      let caption = ScheduleCaption(schedule, session: freeSession, now: scheduleNow)

      #expect(caption.deleteQuestion == "Delete this loop? Run the Waiting audit. Then list the sessions that need me.")
    }

    @Test func aLongPromptIsCutWithAnEllipsis() {
      let prompt = String(repeating: "Run the Waiting audit. ", count: 5)

      let caption = ScheduleCaption(scheduleFixture("r1", prompt), session: freeSession, now: scheduleNow)

      #expect(caption.deleteQuestion == "Delete this loop? \(String(prompt.prefix(69)))…")
    }

    @Test func aOneLinePromptIsNamedWhole() {
      let caption = ScheduleCaption(scheduleFixture("r1"), session: freeSession, now: scheduleNow)

      #expect(caption.deleteQuestion == "Delete this loop? Run the Waiting audit")
    }
  }

  @Suite struct Strip {
    @Test func drawsNothingForASessionWithoutSchedules() {
      #expect(SchedulesStrip.text(nil, now: scheduleNow) == nil)
    }

    @Test func drawsNothingForAnEmptyList() {
      #expect(SchedulesStrip.text([], now: scheduleNow) == nil)
    }

    @Test func oneScheduleSaysHowSoonItRuns() {
      #expect(SchedulesStrip.text([scheduleFixture("r1")], now: scheduleNow) == "1 schedule · next in 12m")
    }

    @Test func severalSchedulesCountThemAndShowTheSoonestRun() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow + 40 * minuteMs),
        scheduleFixture("r2", next: scheduleNow + 12 * minuteMs),
        scheduleFixture("r3", next: scheduleNow + 25 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "3 schedules · next in 12m")
    }

    @Test func aHeldScheduleMakesTheStripSayDue() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow + 12 * minuteMs),
        scheduleFixture("r2", next: scheduleNow - 3 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · due")
    }

    @Test func aScheduleDueThisMomentMakesTheStripSayDue() {
      #expect(SchedulesStrip.text([scheduleFixture("r1", next: scheduleNow)], now: scheduleNow) == "1 schedule · due")
    }

    /// A paused schedule doesn't run, so its `next` is neither the soonest run nor a held one.
    @Test func aPausedScheduleWhoseNextRunHasPassedDoesNotMakeTheStripSayDue() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow - 3 * minuteMs, paused: true),
        scheduleFixture("r2", next: scheduleNow + 12 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · next in 12m")
    }

    @Test func aPausedScheduleWithTheSoonestNextIsNotTheNextRun() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow + 2 * minuteMs, paused: true),
        scheduleFixture("r2", next: scheduleNow + 12 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · next in 12m")
    }

    @Test func onlyPausedSchedulesSayPaused() {
      let schedules = [scheduleFixture("r1", paused: true), scheduleFixture("r2", paused: true)]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · paused")
    }
  }
}
