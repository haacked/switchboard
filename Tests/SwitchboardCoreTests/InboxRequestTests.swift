import Foundation
import Testing

@testable import SwitchboardCore

// The timeline of one request. The PR arrives at t=2, after a turn that
// ended at t=1. The user's click records the request at `requestAt`. The
// turn that the click started runs from `requestStart` to `requestStop`. A
// background job exits at `jobExit`, and claude reports it in a turn from
// `resultStart` to `resultStop`.
private let requestAt: Int64 = 10_000
private let requestStart: Int64 = requestAt + 1_000
private let requestStop: Int64 = requestAt + 20_000
private let jobExit: Int64 = 600_000
private let resultStart: Int64 = jobExit + 1_000
private let resultStop: Int64 = jobExit + 20_000
/// Two GitHub poll intervals of 30 s, as sbd stamps them on the event.
private let readMs: Int64 = 60_000
/// `recheckSeconds.requested`, as sbd stamps it on the event.
private let holdMs: Int64 = 3_600_000
private let until = requestAt + holdMs

private let conflictReason = "merge main in; #42 conflicts with main"
private let mergeMessage = "Merge origin/main into this branch, resolve the conflicts, run the tests, and push."
private let readTheReply = "read its last reply and decide what's next"

private let stalled = "the session stopped without doing it"
private let askedAQuestion = "it asked a question"
private let timeToRecheck = "time to recheck"

private let conflictingPR = samplePR(mergeable: .conflicting)

/// The reason while the request holds the session.
private func held(_ work: String, reason: String = conflictReason, at t: Int64 = requestAt) -> String {
  "you asked at \(Wait.formatTime(t)): \(reason); \(work)"
}

/// The rule's reason once the hold ends with the rule still matching.
private func ended(_ why: String, reason: String = conflictReason, at t: Int64 = requestAt) -> String {
  "\(reason) (you asked at \(Wait.formatTime(t)); \(why))"
}

/// A `request` event as `choose` records it for the rule item's send option.
private func requestEvent(
  _ t: Int64 = requestAt, state: String = "needs_you", reason: String = conflictReason,
  head: String? = samplePRHead, until: Int64? = nil, readMs: Int64 = readMs
) -> Event {
  var data: [String: JSON] = [
    "state": .string(state), "reason": .string(reason), "message": .string(mergeMessage),
    "until": .number(Double(until ?? t + holdMs)), "readMs": .number(Double(readMs)),
  ]
  if let head { data["head"] = .string(head) }
  return event("request", t, data)
}

private func jobs(_ count: Int, at t: Int64) -> Event {
  event("job", t, ["count": .number(Double(count))])
}

/// A session whose turn ended at t=1 and whose PR the poller read at t=2,
/// with `running` background jobs from that turn.
private func before(_ pr: PullRequest = conflictingPR, running: Int = 0) throws -> [Event] {
  var events = [
    event("UserPromptSubmit", 0, ["prompt": "go"]),
    event("Stop", 1, ["last_assistant_message": "Pushed."]),
    try prEvent(2, pr),
  ]
  if running > 0 { events.append(jobs(running, at: 3)) }
  return events
}

/// The turn that the click's message started.
private func requestTurn(
  reply: String = "I'll merge main in once the review finishes.", during: [Event] = [], stop: Int64 = requestStop
) -> [Event] {
  [event("UserPromptSubmit", requestStart, ["prompt": .string(mergeMessage)])] + during
    + [event("Stop", stop, ["last_assistant_message": .string(reply)])]
}

/// The prompt of a background command's result on Claude Code 2.1.308.
private let taskNotification = """
  <task-notification>
  <task-id>b7q2xk</task-id>
  <status>completed</status>
  <summary>Background command "Run the review" completed (exit code 0)</summary>
  </task-notification>
  """

/// The prompt of a subagent's result on Claude Code 2.1.310.
private let agentMessage = """
  <agent-message from="review-code">
  The review found two nits.
  </agent-message>
  """

private let backgroundResults = [taskNotification, agentMessage]

/// The turn that claude starts to report a background result.
private func resultTurn(
  _ prompt: String = taskNotification, start: Int64 = resultStart, stop: Int64 = resultStop, during: [Event] = [],
  reply: String = "The review found two nits, and I fixed them."
) -> [Event] {
  [event("UserPromptSubmit", start, ["prompt": .string(prompt)])] + during
    + [event("Stop", stop, ["last_assistant_message": .string(reply)])]
}

/// The incident's shape: two jobs run when the user clicks, the click's turn
/// ends while they run, and one job exits and is reported later. The other
/// job, such as a dev server, keeps running.
private func incident(_ result: [Event]) throws -> [Event] {
  try before(running: 2) + [requestEvent()] + requestTurn() + [jobs(1, at: jobExit)] + result
}

private func evaluate(_ events: [Event], at t: Int64) -> Verdict {
  Attention.evaluate(session(), facts(events), now: t)
}

/// The verdict for the same events without the `request` event.
private func unrequested(_ events: [Event], at t: Int64) -> Verdict {
  evaluate(events.filter { $0.kind != "request" }, at: t)
}

/// A main-session tool call that starts background work, or a call that doesn't.
private func call(_ name: String, background: Bool?, agent: String? = nil, at t: Int64 = resultStart + 2_000) -> Event {
  var input: [String: JSON] = ["command": "bin/test", "description": "Run the tests"]
  if let background { input["run_in_background"] = .bool(background) }
  return event("PreToolUse", t, tool(name, input, id: "toolu_\(name)_\(t)", agent: agent))
}

/// The suites nest under one name, so `--filter InboxRequestTests` runs them all.
@Suite struct InboxRequestTests {}

extension InboxRequestTests {
  @Suite struct RequestFacts {
    @Test func requestEventSetsTheRequest() throws {
      let f = facts(try before() + [requestEvent()])

      let request = try #require(f.request)
      #expect(request.state == .needsYou)
      #expect(request.reason == conflictReason)
      #expect(request.head == samplePRHead)
      #expect(request.message == mergeMessage)
      #expect(request.until == until)
      #expect(request.readMs == readMs)
    }

    @Test func requestTakesTheEventsTime() throws {
      let f = facts(try before() + [requestEvent()])

      #expect(f.request?.at == requestAt)
    }

    @Test func requestWithoutAHeadHasANilHead() throws {
      let f = facts(try before() + [requestEvent(head: nil)])

      #expect(f.request != nil)
      #expect(f.request?.head == nil)
    }

    /// An acknowledgment lasts one turn. A request lasts through the turns it starts.
    @Test func requestSurvivesTheTurnsItStarts() throws {
      let f = facts(try incident(resultTurn()))

      #expect(f.request?.at == requestAt)
    }

    @Test func unackClearsTheRequest() throws {
      let f = facts(try before() + [requestEvent()] + requestTurn() + [event("unack", requestStop + 1)])

      #expect(f.request == nil)
    }

    @Test func userPromptOtherThanTheMessageClearsTheRequest() throws {
      let f = facts(
        try before() + [
          requestEvent(), event("UserPromptSubmit", requestStart, ["prompt": "Fix the flaky test instead."]),
        ])

      #expect(f.request == nil)
    }

    /// claude's prompt for a message with an image shows the image as `[Image #1]` after the text.
    @Test func messagesPromptWithAnImageKeepsTheRequest() throws {
      let f = facts(
        try before() + [
          requestEvent(), event("UserPromptSubmit", requestStart, ["prompt": .string("\(mergeMessage)\n[Image #1]")]),
        ])

      #expect(f.request != nil)
    }

    @Test func laterRequestReplacesTheEarlierOne() throws {
      let f = facts(try before() + [requestEvent(), requestEvent(requestAt + 5)])

      #expect(f.request?.at == requestAt + 5)
    }
  }
}

/// While the request covers the rule's verdict and work runs, the session is Waiting.
extension InboxRequestTests {
  @Suite struct Held {
    @Test(arguments: [(1, "1 background job running"), (2, "2 background jobs running")])
    func heldWhileBackgroundJobsRunAfterTheRequestsTurn(_ running: Int, _ work: String) throws {
      let events = try before(running: running) + [requestEvent()] + requestTurn()

      let v = evaluate(events, at: requestStop + readMs + 5 * 60_000)

      #expect(v == Verdict(state: .waiting, reason: held(work)))
    }

    @Test func heldVerdictIsMarkedRequested() throws {
      let events = try before(running: 2) + [requestEvent()] + requestTurn()

      #expect(evaluate(events, at: requestStop + readMs + 1).requested)
    }

    /// The turn that ended at t=1, before the click, is not the request's turn.
    @Test(arguments: [requestAt + 1, requestAt + readMs + 10 * 60_000])
    func heldBeforeTheRequestsFirstTurnStarts(_ t: Int64) throws {
      let events = try before() + [requestEvent()]

      let v = evaluate(events, at: t)

      #expect(v == Verdict(state: .waiting, reason: held("waiting for it to start")))
      #expect(v.requested)
    }

    @Test func heldDuringTheReadWaitAfterATurnThatLeftNoWork() throws {
      let events = try before() + [requestEvent()] + requestTurn()

      let v = evaluate(events, at: requestStop + readMs - 1)

      #expect(v == Verdict(state: .waiting, reason: held("waiting for GitHub to read the PR")))
      #expect(v.requested)
    }

    @Test func heldWhileASubagentRuns() throws {
      let start = event("SubagentStart", requestStart + 2_000, ["agent_id": "a1", "agent_type": "general-purpose"])
      let events = try before() + [requestEvent()] + requestTurn(during: [start])

      let v = evaluate(events, at: requestStop + readMs + 60_000)

      #expect(v == Verdict(state: .waiting, reason: held("1 subagent running")))
    }

    /// Each rule above the jobs rule that offers a send option, not only the conflict.
    @Test(arguments: [
      samplePR(mergeable: .conflicting),
      samplePR(base: "haacked/parent", mergedBase: 41),
      samplePR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)]),
    ])
    func heldUnderEachRuleThatOffersASend(_ pr: PullRequest) throws {
      let start = try before(pr, running: 1)
      let rule = evaluate(start, at: requestAt)
      try #require(rule.state == .needsYou)
      let events = start + [requestEvent(reason: rule.reason)] + requestTurn()

      let v = evaluate(events, at: requestStop + readMs + 60_000)

      #expect(v == Verdict(state: .waiting, reason: held("1 background job running", reason: rule.reason)))
    }

    /// The hold applies after `readyForReview`.
    @Test func heldConflictIsNotReadyForReview() throws {
      let pr = samplePR(mergeable: .conflicting, reviewDecision: .reviewRequired)
      let events = try before(pr, running: 1) + [requestEvent()] + requestTurn()

      let v = evaluate(events, at: requestStop + readMs + 60_000)

      #expect(v == Verdict(state: .waiting, reason: held("1 background job running")))
    }

    @Test func offerInTheLastReplyKeepsTheHold() throws {
      let events = try before(running: 1) + [requestEvent()] + requestTurn(reply: "Want me to push once it passes?")

      let v = evaluate(events, at: requestStop + readMs + 60_000)

      #expect(v.state == .waiting)
      #expect(v.requested)
    }

    /// A user turn that ends while jobs run is not a stall, however long the jobs run.
    @Test func heldUntilAMinuteBeforeTheTimeLimitWhileJobsRun() throws {
      let events = try before(running: 2) + [requestEvent()] + requestTurn()

      let v = evaluate(events, at: until - 60_000)

      #expect(v == Verdict(state: .waiting, reason: held("2 background jobs running")))
    }
  }
}

/// A running turn ranks above the hold.
extension InboxRequestTests {
  @Suite struct RunningTurn {
    @Test func requestsTurnIsWorking() throws {
      let events =
        try before(running: 1) + [
          requestEvent(), event("UserPromptSubmit", requestStart, ["prompt": .string(mergeMessage)]),
        ]

      let v = evaluate(events, at: requestStart + 1_000)

      #expect(v.state == .working)
      #expect(!v.requested)
    }

    @Test func resultTurnIsWorking() throws {
      let events = try incident([event("UserPromptSubmit", resultStart, ["prompt": .string(taskNotification)])])

      #expect(evaluate(events, at: resultStart + 1_000).state == .working)
    }
  }
}

/// Each way the hold ends.
extension InboxRequestTests {
  @Suite struct Ends {
    @Test func turnThatLeftNoWorkEndsTheHoldOnceTheReadWaitPasses() throws {
      let events = try before() + [requestEvent()] + requestTurn()

      let v = evaluate(events, at: requestStop + readMs)

      #expect(v == Verdict(state: .needsYou, reason: ended(stalled)))
      #expect(!v.requested)
    }

    @Test func endedHoldOffersTheRulesOptionsAgain() throws {
      let events = try before() + [requestEvent()] + requestTurn()

      let v = evaluate(events, at: requestStop + readMs)

      #expect(v.options == unrequested(events, at: requestStop + readMs).options)
      #expect(v.options.map(\.label) == ["Merge main"])
    }

    /// The incident's stall: the reported job exited, another job still runs,
    /// and the result's turn ended without starting new background work.
    @Test(arguments: backgroundResults)
    func resultTurnWithoutNewBackgroundWorkEndsTheHold(_ prompt: String) throws {
      let events = try incident(resultTurn(prompt))

      let v = evaluate(events, at: resultStop + readMs)

      #expect(v == Verdict(state: .needsYou, reason: ended(stalled)))
      #expect(!v.requested)
    }

    @Test(arguments: backgroundResults)
    func resultTurnHoldsDuringTheReadWait(_ prompt: String) throws {
      let events = try incident(resultTurn(prompt))

      let v = evaluate(events, at: resultStop + readMs - 1)

      #expect(v.state == .waiting)
      #expect(v.requested)
    }

    /// A pending stall shows the GitHub wording even while a job runs.
    @Test func resultTurnSaysItWaitsForGitHubDuringTheReadWait() throws {
      let events = try incident(resultTurn())

      let v = evaluate(events, at: resultStop + readMs - 1)

      #expect(v.reason == held("waiting for GitHub to read the PR"))
    }

    /// Only main-session calls that start background work keep the hold.
    @Test(arguments: [
      call("Bash", background: false),
      call("Bash", background: nil),
      call("Bash", background: true, agent: "a7"),
      call("Monitor", background: nil, agent: "a7"),
    ])
    func resultTurnWhoseNewWorkIsNotMainSessionBackgroundWorkEndsTheHold(_ work: Event) throws {
      let events = try incident(resultTurn(during: [work]))

      let v = evaluate(events, at: resultStop + readMs)

      #expect(v == Verdict(state: .needsYou, reason: ended(stalled)))
    }

    @Test func headChangeEndsTheHoldAndTheRuleDecides() throws {
      var pushed = conflictingPR
      pushed.headSha = "c0ffee1"
      let events = try incident([try prEvent(resultStop, pushed)])

      let v = evaluate(events, at: resultStop + 1)

      #expect(v == Verdict(state: .needsYou, reason: conflictReason))
      #expect(!v.requested)
    }

    @Test func reasonChangeEndsTheHoldAndTheRuleDecides() throws {
      var retargeted = conflictingPR
      retargeted.base = "release"
      let events = try incident([try prEvent(resultStop, retargeted)])

      let v = evaluate(events, at: resultStop + 1)

      #expect(v == Verdict(state: .needsYou, reason: "merge release in; #42 conflicts with release"))
      #expect(!v.requested)
    }

    /// The conflict is gone at the same head, so the next rule decides as if no request was made.
    @Test func resolvedConflictLetsTheNextRuleDecide() throws {
      var resolved = conflictingPR
      resolved.mergeable = .mergeable
      let events = try incident([try prEvent(resultStop, resolved)])

      let v = evaluate(events, at: resultStop + 1)

      #expect(v == unrequested(events, at: resultStop + 1))
      #expect(!v.reason.contains("you asked"))
      #expect(!v.requested)
    }

    @Test func questionInTheLastReplyEndsTheHold() throws {
      let events =
        try before(running: 1) + [requestEvent()]
        + requestTurn(reply: "Which branch should I merge in, main or release?")

      let v = evaluate(events, at: requestStop + 1)

      #expect(v == Verdict(state: .needsYou, reason: ended(askedAQuestion)))
      #expect(!v.requested)
    }

    @Test func holdLastsUntilAMillisecondBeforeTheTimeLimit() throws {
      let events = try before(running: 1) + [requestEvent()] + requestTurn()

      #expect(evaluate(events, at: until - 1).state == .waiting)
    }

    @Test func timeLimitEndsTheHold() throws {
      let events = try before(running: 1) + [requestEvent()] + requestTurn()

      let v = evaluate(events, at: until)

      #expect(v == Verdict(state: .needsYou, reason: ended(timeToRecheck)))
      #expect(!v.requested)
    }

    /// An acknowledgment compares the reason, so a stall's reason must not change at the time limit.
    @Test func stallsReasonStaysAfterTheTimeLimit() throws {
      let events = try incident(resultTurn())

      #expect(evaluate(events, at: until) == Verdict(state: .needsYou, reason: ended(stalled)))
    }

    @Test func cardThatOpensEndsTheHold() throws {
      let events =
        try before(running: 1) + [requestEvent()]
        + [
          event("UserPromptSubmit", requestStart, ["prompt": .string(mergeMessage)]),
          event("PreToolUse", requestStart + 1, touchCall),
          Event(id: 9, session: "s1", t: requestStart + 2, kind: "PermissionRequest", data: .object(touch)),
        ]

      let v = evaluate(events, at: requestStart + 3)

      #expect(v == Verdict(state: .needsYou, reason: "approve `touch x`"))
      #expect(!v.requested)
    }

    @Test func unackEndsTheHold() throws {
      let events = try before(running: 1) + [requestEvent()] + requestTurn() + [event("unack", requestStop + 1)]

      let v = evaluate(events, at: requestStop + 2)

      #expect(v == Verdict(state: .needsYou, reason: conflictReason))
      #expect(!v.requested)
    }
  }
}

/// Background work that the result's turn starts keeps the hold.
extension InboxRequestTests {
  @Suite struct NewBackgroundWork {
    @Test(arguments: [call("Bash", background: true), call("Monitor", background: nil)])
    func resultTurnThatStartsBackgroundWorkKeepsTheHold(_ work: Event) throws {
      let events = try incident(resultTurn(during: [work]))

      let v = evaluate(events, at: resultStop + readMs + 5 * 60_000)

      #expect(v.state == .waiting)
      #expect(v.requested)
    }

    @Test func nextResultTurnWithoutNewWorkEndsTheHold() throws {
      let second = resultStop + 300_000
      let events = try incident(
        resultTurn(during: [call("Bash", background: true)])
          + resultTurn(start: second, stop: second + 10_000, reply: "The tests pass."))

      let v = evaluate(events, at: second + 10_000 + readMs)

      #expect(v == Verdict(state: .needsYou, reason: ended(stalled)))
    }
  }
}

/// The request applies only while it covers the verdict: same state, same reason, same head.
extension InboxRequestTests {
  @Suite struct Covers {
    @Test(arguments: [
      requestEvent(state: "can_continue"),
      requestEvent(head: nil),
      requestEvent(head: "older"),
      requestEvent(reason: "some other reason"),
    ])
    func requestThatDoesNotCoverTheVerdictDoesNotHold(_ request: Event) throws {
      let events = try before(running: 1) + [request] + requestTurn()

      let v = evaluate(events, at: requestStop + readMs + 60_000)

      #expect(v == Verdict(state: .needsYou, reason: conflictReason))
      #expect(!v.requested)
    }

    /// A reply decides this verdict, not a rule, so a request never holds it.
    @Test func requestDoesNotHoldAReplyVerdict() {
      let events = [
        event("UserPromptSubmit", 0, ["prompt": "go"]),
        event("Stop", 1, ["last_assistant_message": "Done."]),
        requestEvent(reason: readTheReply, head: nil),
      ]

      let v = evaluate(events, at: requestAt + 60_000)

      #expect(v == Verdict(state: .needsYou, reason: readTheReply))
      #expect(!v.requested)
    }
  }
}

/// The app and `sb` read `shown`, and sbd's own rules read `evaluate`. Both see the hold.
extension InboxRequestTests {
  @Suite struct Shown {
    @Test func shownKeepsTheHeldVerdict() throws {
      let f = facts(try before(running: 2) + [requestEvent()] + requestTurn())
      let t = requestStop + readMs + 60_000
      let evaluated = Attention.evaluate(session(), f, now: t)

      let v = Attention.shown(evaluated, f, now: t, acknowledgedMs: RecheckSettings().acknowledgedMs)

      #expect(v == evaluated)
      #expect(v.requested)
      #expect(!v.acknowledged)
    }
  }
}

/// Times on both sides of each change in the incident's verdict.
private let replayTimes: [Int64] = [
  requestAt + 1, requestStop + readMs + 60_000, resultStop + readMs - 1, resultStop + readMs, until,
]

/// sbd replays each session's log at startup, evaluating at each event's
/// time, and restores from snapshots of the facts.
extension InboxRequestTests {
  @Suite struct Replay {
    @Test(arguments: replayTimes)
    func replayedFactsGiveTheSameVerdict(_ t: Int64) throws {
      let events = try incident(resultTurn())
      let live = evaluate(events, at: t)

      let replayed = Attention.evaluate(
        session(), SessionReplay.replaying(events, session: session()).facts, now: t)

      #expect(replayed == live)
      #expect(replayed.requested == live.requested)
    }

    @Test(arguments: replayTimes)
    func replayingTwiceGivesTheSameVerdict(_ t: Int64) throws {
      let events = try incident(resultTurn())

      let first = Attention.evaluate(session(), SessionReplay.replaying(events, session: session()).facts, now: t)
      let second = Attention.evaluate(session(), SessionReplay.replaying(events, session: session()).facts, now: t)

      #expect(first == second)
      #expect(first.requested == second.requested)
    }

    @Test(arguments: replayTimes)
    func snapshotOfTheFactsGivesTheSameVerdict(_ t: Int64) throws {
      let f = SessionReplay.replaying(try incident(resultTurn()), session: session()).facts

      let restored = try JSONCoding.convert(JSON(encoding: f), to: SessionFacts.self)

      #expect(restored == f)
      #expect(Attention.evaluate(session(), restored, now: t) == Attention.evaluate(session(), f, now: t))
    }

    /// The time limit is the event's `until`, not a time counted from when sbd replays.
    @Test func timeLimitComesFromTheEvent() throws {
      let events = try before(running: 1) + [requestEvent(until: requestAt + 120_000)] + requestTurn()

      #expect(evaluate(events, at: requestAt + 120_000 - 1).state == .waiting)
      #expect(evaluate(events, at: requestAt + 120_000) == Verdict(state: .needsYou, reason: ended(timeToRecheck)))
    }

    /// The wait after a turn is the event's `readMs`, not the poll interval at replay.
    @Test func readWaitComesFromTheEvent() throws {
      let events = try before() + [requestEvent(readMs: 5_000)] + requestTurn()

      #expect(evaluate(events, at: requestStop + 5_000 - 1).state == .waiting)
      #expect(evaluate(events, at: requestStop + 5_000) == Verdict(state: .needsYou, reason: ended(stalled)))
    }
  }
}
