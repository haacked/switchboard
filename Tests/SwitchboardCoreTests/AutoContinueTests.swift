import Foundation
import Testing

@testable import SwitchboardCore

private let minuteMs: Int64 = 60_000
private let hourMs: Int64 = 3_600_000
private let now: Int64 = 100 * hourMs
private let offer = Verdict(state: .canContinue, reason: "offered: Want me to run the tests?")

/// An input that every guard passes: a live, idle claude whose reply offered
/// a next step, last touched two hours ago.
private func passing() -> AutoContinueInput {
  var f = facts([
    event("SessionStart", now - 3 * hourMs), event("UserPromptSubmit", now - 2 * hourMs, ["prompt": "go"]),
    event("Stop", now - 2 * hourMs + 1000, ["last_assistant_message": "I wrote the parser. Want me to run the tests?"]),
  ])
  f.lastTouched = now - 2 * hourMs
  // The offer came after every continue that a test sets.
  f.stateSince = now - 5 * minuteMs
  var input = AutoContinueInput(session: session(), facts: f, verdict: offer, now: now)
  input.live = 1
  input.account = "/Users/me/.claude"
  return input
}

private func blocker(_ change: (inout AutoContinueInput) -> Void) -> String? {
  var input = passing()
  change(&input)
  return AutoContinue.blocker(input)
}

@Suite struct AutoContinueGuardTests {
  @Test func anInputThatPassesEveryGuardHasNoBlocker() {
    #expect(AutoContinue.blocker(passing()) == nil)
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .canContinue })
  func aSessionNotInClaudeCanContinueIsHeldBack(_ state: AttentionState) {
    #expect(blocker { $0.verdict = Verdict(state: state, reason: "something") } == "not in Claude can continue")
  }

  @Test func theManagerIsHeldBack() {
    #expect(blocker { $0.session.manager = true } == "the Manager")
  }

  @Test func aGroupChatIsHeldBack() {
    #expect(blocker { $0.session.chat = "g1" } == "a group chat")
  }

  @Test func aSessionMarkedNotTheManagerPasses() {
    #expect(blocker { $0.session.manager = false } == nil)
  }

  enum OpenPrompt: CaseIterable, Sendable {
    case card, deferredCard, sessionCard, permission, question
  }

  @Test(arguments: OpenPrompt.allCases)
  func anOpenCardPermissionPromptOrQuestionHoldsItBack(_ open: OpenPrompt) {
    let request = event("PermissionRequest", now - hourMs, tool("Bash", ["command": "rm -rf build"]))
    let reason = blocker { input in
      switch open {
      case .card:
        input.facts.cards = [Card(request)]
      case .deferredCard:
        var card = Card(request)
        card.deferred = true
        input.facts.cards = [card]
      case .sessionCard:
        input.facts.sessionSummary = sessionCard
      case .permission:
        input.facts.openPermission = ToolCall(tool: "Bash", summary: "`rm -rf build`", since: now - hourMs)
      case .question:
        input.facts.openQuestion = ToolCall(tool: "AskUserQuestion", summary: "Which fruit?", since: now - hourMs)
      }
    }
    #expect(reason == "an open card")
  }

  /// Design A test 13. A continue would answer the reply while the user works through its decisions.
  @Test func aSummaryWithDecisionsHoldsItBack() throws {
    let summary = try JSONCoding.convert(decisionSummaryJSON, to: TriageSummary.self)

    let reason = blocker { input in
      input.verdict.source = .reply
      input.facts.triage = summary
    }

    #expect(reason != nil)
  }

  @Test func anOpenDecisionListHoldsItBack() {
    #expect(
      blocker { $0.facts.apply(decisionsOpened(10, t: now - 2 * hourMs + 2000, ref: "stop:2", lastStop: 2)) } != nil)
  }

  @Test(arguments: ["decisions_submitted", "decisions_discarded"])
  func aClosedDecisionListNoLongerHoldsItBack(_ kind: String) {
    let reason = blocker { input in
      input.facts.apply(decisionsOpened(10, t: now - 2 * hourMs + 2000, ref: "stop:2", lastStop: 2))
      input.facts.apply(Event(id: 11, session: "s1", t: now - 2 * hourMs + 3000, kind: kind, data: ["message": "x"]))
    }

    #expect(reason == nil)
  }

  @Test func anOpenWaitHoldsItBack() {
    #expect(blocker { $0.session = session(wait: "CI on #12") } == "an open wait")
  }

  @Test func anEmptyListOfWaitsPasses() {
    #expect(blocker { $0.session.waits = [] } == nil)
  }

  @Test func aRunningTurnHoldsItBack() {
    #expect(blocker { $0.facts.turnRunning = true } == "a turn is running")
  }

  @Test func aMessageInFlightOrQueuedHoldsItBack() {
    #expect(blocker { $0.busy = true } == "a message is on its way")
  }

  @Test func claudeThatIsStartingHoldsItBack() {
    #expect(blocker { $0.process = .starting } == "claude is starting or stopping")
  }

  @Test func claudeThatRunsAfterItsSessionEndedIsExitingAndHoldsItBack() {
    let reason = blocker {
      $0.process = .running
      $0.facts.live = false
    }
    #expect(reason == "claude is starting or stopping")
  }

  @Test func aStoppedClaudeIsNotExiting() {
    let reason = blocker {
      $0.process = .stopped
      $0.facts.live = false
      $0.live = 0
    }
    #expect(reason == nil)
  }

  @Test func aPaneOnScreenHoldsItBack() {
    #expect(blocker { $0.onScreen = true } == "on screen")
  }

  @Test func aTouchWithinTheQuietTimeHoldsItBack() {
    #expect(blocker { $0.facts.lastTouched = now - 12_000 } == "you touched it 12 s ago")
  }

  @Test func theLastTickOnScreenCountsAsATouch() {
    #expect(blocker { $0.lastOnScreen = now - 30_000 } == "you touched it 30 s ago")
  }

  @Test func theLaterOfTheTouchAndTheTickOnScreenCounts() {
    let touchedLater = blocker {
      $0.facts.lastTouched = now - 20_000
      $0.lastOnScreen = now - 100_000
    }
    let onScreenLater = blocker {
      $0.facts.lastTouched = now - 100_000
      $0.lastOnScreen = now - 20_000
    }
    #expect(touchedLater == "you touched it 20 s ago")
    #expect(onScreenLater == "you touched it 20 s ago")
  }

  @Test func aTouchExactlyTheQuietTimeAgoPasses() {
    #expect(blocker { $0.facts.lastTouched = now - 600_000 } == nil)
  }

  @Test func theQuietTimeComesFromTheSettings() {
    let short = blocker {
      $0.settings.quietSeconds = 60
      $0.facts.lastTouched = now - 100_000
    }
    let long = blocker {
      $0.settings.quietSeconds = 3600
      $0.facts.lastTouched = now - 1_200_000
    }
    #expect(short == nil)
    #expect(long == "you touched it 1200 s ago")
  }

  @Test func aContinueSinceTheOfferHoldsItBack() {
    let reason = blocker { $0.facts.autoContinues = [now - minuteMs] }
    #expect(reason == "already continued this offer")
  }

  @Test func aContinueBeforeTheOfferPasses() {
    #expect(blocker { $0.facts.autoContinues = [now - 10 * minuteMs] } == nil)
  }

  @Test func perHourContinuesWithinTheLastHourHoldItBack() {
    let reason = blocker { $0.facts.autoContinues = [now - 30 * minuteMs, now - 20 * minuteMs, now - 10 * minuteMs] }
    #expect(reason == "continued 3 times in the last hour")
  }

  @Test func continuesMoreThanAnHourAgoDontCount() {
    let reason = blocker {
      $0.facts.autoContinues = [now - 3 * hourMs, now - 2 * hourMs, now - hourMs - minuteMs]
    }
    #expect(reason == nil)
  }

  @Test func onlyTheContinuesWithinTheLastHourCountTowardTheLimit() {
    let reason = blocker { $0.facts.autoContinues = [now - 2 * hourMs, now - 20 * minuteMs, now - 10 * minuteMs] }
    #expect(reason == nil)
  }

  @Test func theLimitComesFromTheSettings() {
    let reason = blocker {
      $0.settings.perHour = 2
      $0.facts.autoContinues = [now - 20 * minuteMs, now - 10 * minuteMs]
    }
    #expect(reason == "continued 2 times in the last hour")
  }

  /// A session whose claude is stopped, so a continue has to start it.
  private func stopped(live: Int, cap: Int = 12) -> String? {
    blocker {
      $0.process = .stopped
      $0.facts.live = false
      $0.live = live
      $0.liveCap = cap
    }
  }

  @Test func aStoppedSessionWaitsWhenTheLiveCapIsFull() {
    #expect(stopped(live: 12) == "the live cap of 12 is full")
  }

  @Test func aStoppedSessionWaitsWhenMoreThanTheLiveCapRun() {
    #expect(stopped(live: 13) == "the live cap of 12 is full")
  }

  @Test func aStoppedSessionGoesWhenOneSlotIsFree() {
    #expect(stopped(live: 11) == nil)
  }

  @Test func theLiveCapComesFromTheSettings() {
    #expect(stopped(live: 1, cap: 1) == "the live cap of 1 is full")
  }

  @Test func aRunningSessionIgnoresAFullLiveCap() {
    let reason = blocker {
      $0.process = .running
      $0.live = 20
      $0.liveCap = 12
    }
    #expect(reason == nil)
  }

  @Test func noBudgetForTheAccountHoldsItBack() {
    let reason = blocker {
      $0.hasBudget = false
      $0.account = "/Users/me/.claude-work"
    }
    #expect(reason == "no quota left for /Users/me/.claude-work")
  }

  @Test func eachGuardGivesWayToTheOneBeforeIt() {
    var input = AutoContinueInput(
      session: session(wait: "CI"), facts: SessionFacts(), verdict: Verdict(state: .needsYou, reason: "x"), now: now)
    input.session.manager = true
    input.session.chat = "g1"
    input.facts.cards = [Card(event("PermissionRequest", now - hourMs, tool("Bash", ["command": "ls"])))]
    input.facts.sessionSummary = sessionCard
    input.facts.turnRunning = true
    input.busy = true
    input.facts.live = false
    input.facts.lastTouched = now - 5000
    input.facts.autoContinues = [now - 3 * minuteMs, now - 2 * minuteMs, now - minuteMs]
    input.process = .starting
    input.onScreen = true
    input.live = 12
    input.account = "/a"
    input.hasBudget = false
    let fixes: [(String, (inout AutoContinueInput) -> Void)] = [
      ("not in Claude can continue", { $0.verdict = offer }),
      ("the Manager", { $0.session.manager = nil }),
      ("a group chat", { $0.session.chat = nil }),
      ("an open card", { $0.facts.cards = [] }),
      ("an open card", { $0.facts.sessionSummary = nil }),
      ("an open wait", { $0.session.waits = nil }),
      ("a turn is running", { $0.facts.turnRunning = false }),
      ("a message is on its way", { $0.busy = false }),
      ("claude is starting or stopping", { $0.process = .stopped }),
      ("on screen", { $0.onScreen = false }),
      ("you touched it 5 s ago", { $0.facts.lastTouched = 0 }),
      ("continued 3 times in the last hour", { $0.facts.autoContinues = [now - minuteMs] }),
      ("already continued this offer", { $0.facts.stateSince = now }),
      ("the live cap of 12 is full", { $0.live = 0 }),
      ("no quota left for /a", { $0.hasBudget = true }),
    ]
    for (reason, fix) in fixes {
      #expect(AutoContinue.blocker(input) == reason)
      fix(&input)
    }
    #expect(AutoContinue.blocker(input) == nil)
  }
}

@Suite struct AutoContinueSettingsTests {
  @Test func defaultsSendYesGoAheadAfterTenQuietMinutes() {
    let settings = Config().autoContinue
    #expect(settings.message == "Yes, go ahead.")
    #expect(settings.quietSeconds == 600)
    #expect(settings.perHour == 3)
    #expect(Config().liveCap == 10)
  }

  @Test(arguments: [#"{}"#, #"{"autoContinue": {}}"#])
  func aConfigWithoutTheFieldsUsesTheDefaults(_ text: String) throws {
    #expect(try JSONCoding.decode(Config.self, from: text).autoContinue == AutoContinueSettings())
  }

  @Test func readsPartOfTheObject() throws {
    let settings = try JSONCoding.decode(Config.self, from: #"{"autoContinue": {"perHour": 5}}"#).autoContinue
    var expected = AutoContinueSettings()
    expected.perHour = 5
    #expect(settings == expected)
  }

  @Test func readsEveryField() throws {
    let text = #"{"autoContinue": {"message": "offer more", "quietSeconds": 60, "perHour": 2}, "liveCap": 1}"#
    let config = try JSONCoding.decode(Config.self, from: text)
    let settings = config.autoContinue
    #expect(settings.message == "offer more")
    #expect(settings.quietSeconds == 60)
    #expect(settings.perHour == 2)
    #expect(config.liveCap == 1)
  }
}

@Suite struct AutoContinueFactsTests {
  @Test func lastTouchedIsZeroBeforeAnyTouch() {
    #expect(facts([event("SessionStart", 1000)]).lastTouched == 0)
  }

  @Test func aUserPromptIsATouch() {
    #expect(
      facts([event("SessionStart", 1000), event("UserPromptSubmit", 5000, ["prompt": "go"])]).lastTouched == 5000)
  }

  @Test(arguments: ["pasted", "queued", "resumed"])
  func aMessageFromTheUserIsATouch(_ delivery: String) {
    let f = facts([
      event("UserPromptSubmit", 1000, ["prompt": "go"]),
      event("sent", 5000, ["text": "run the tests", "delivery": .string(delivery)]),
    ])
    #expect(f.lastTouched == 5000)
  }

  @Test func answeringACardIsATouch() {
    let f = facts([
      event("UserPromptSubmit", 1000, ["prompt": "go"]),
      event("PermissionRequest", 2000, tool("Bash", ["command": "touch x"])),
      event("answered", 7000, ["card": 0, "behavior": "allow"]),
    ])
    #expect(f.lastTouched == 7000)
  }

  @Test func sbdsOwnMessageIsNotATouch() {
    let f = facts([
      event("UserPromptSubmit", 1000, ["prompt": "go"]),
      event("sent", 5000, ["text": "Yes, go ahead.", "delivery": "pasted", "by": "sbd"]),
      event("UserPromptSubmit", 5100, ["prompt": "Yes, go ahead."]),
    ])
    #expect(f.lastTouched == 1000)
  }

  @Test func theUserTypingTheSameTextAsSbdsReportedMessageIsATouch() {
    let f = facts([
      event("UserPromptSubmit", 1000, ["prompt": "go"]),
      event("sent", 5000, ["text": "Yes, go ahead.", "delivery": "pasted", "by": "sbd"]),
      event("UserPromptSubmit", 5100, ["prompt": "Yes, go ahead."]),
      event("UserPromptSubmit", 9000, ["prompt": "Yes, go ahead."]),
    ])
    #expect(f.lastTouched == 9000)
  }

  @Test(arguments: [
    "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n</task-notification>",
    "<agent-message from=\"reviewer\">LGTM</agent-message>",
  ])
  func aSubagentResultIsNotATouch(_ prompt: String) {
    let f = facts([
      event("UserPromptSubmit", 1000, ["prompt": "go"]), event("UserPromptSubmit", 5000, ["prompt": .string(prompt)]),
    ])
    #expect(f.lastTouched == 1000)
  }

  @Test(arguments: ["Stop", "SessionStart", "stopped", "PreToolUse", "deferred", "auto-continue"])
  func otherEventsAreNotTouches(_ kind: String) {
    let f = facts([event("UserPromptSubmit", 1000, ["prompt": "go"]), event(kind, 5000)])
    #expect(f.lastTouched == 1000)
  }

  @Test func autoContinuesRecordsEachContinue() {
    let f = facts([
      event("auto-continue", 1000, ["text": "Yes, go ahead."]),
      event("auto-continue", 2000, ["text": "Yes, go ahead."]),
    ])
    #expect(f.autoContinues == [1000, 2000])
  }

  @Test func autoContinuesKeepsOnlyTheHourBeforeTheNewest() {
    let newest = 10 * hourMs
    let f = facts(
      [newest - 3 * hourMs, newest - hourMs - 1, newest - 59 * minuteMs, newest - minuteMs, newest].map {
        event("auto-continue", $0, ["text": "Yes, go ahead."])
      })
    #expect(f.autoContinues == [newest - 59 * minuteMs, newest - minuteMs, newest])
  }

  @Test func aFailedContinueCountsTowardTheLimit() {
    let f = facts([event("auto-continue", 1000, ["text": "Yes, go ahead.", "error": "claude did not start"])])
    #expect(f.autoContinues == [1000])
  }

  /// A continue that failed leaves the session to go Stale. One that succeeds
  /// records a `sent` event, which is activity.
  @Test func aContinueIsNotActivity() {
    let f = facts([
      event("Stop", 1000, ["last_assistant_message": "Want me to run the tests?"]),
      event("auto-continue", 5000, ["text": "Yes, go ahead.", "error": "claude did not start"]),
    ])
    #expect(f.lastActivity == 1000)
  }
}
