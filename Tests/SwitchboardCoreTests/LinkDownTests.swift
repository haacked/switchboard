import Foundation
import Testing

@testable import SwitchboardCore

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"
private let notConnected = "mini is not connected: \(refusal)"
private let day = Attention.dayMs
private let longAfter = Attention.staleAfterMs + 10 * day

/// A session on the host `mini`.
private func remote(done: Bool = false, waits: [Wait]? = nil) -> Session {
  var s = session(done: done)
  s.host = "mini"
  s.waits = waits
  return s
}

private func linkDown(_ t: Int64, error: String? = refusal, link: String = "unreachable") -> Event {
  var data: [String: JSON] = ["host": "mini", "link": .string(link)]
  if let error { data["error"] = .string(error) }
  return event("link_down", t, data)
}

private func linkUp(_ t: Int64) -> Event { event("link_up", t, ["host": "mini"]) }

private func reconciled(_ t: Int64, reply: String?, activity: Int64) -> Event {
  event("reconciled", t, ["lastReply": reply.map(JSON.string) ?? .null, "lastActivity": .number(Double(activity))])
}

private func stop(_ t: Int64, _ reply: String) -> Event {
  event("Stop", t, ["last_assistant_message": .string(reply)])
}

private func prompt(_ t: Int64, _ text: String = "go") -> Event {
  event("UserPromptSubmit", t, ["prompt": .string(text)])
}

/// The facts as sbd holds them: each event folded in and the state tracked at the event's time.
private func tracked(_ events: [Event], _ session: Session = remote()) -> SessionFacts {
  SessionReplay.replaying(events, session: session).facts
}

/// The events of a session in each state that a link can freeze, and that state.
private let frozenShapes: [(name: String, events: [Event], state: AttentionState)] = [
  ("a turn that runs", [event("SessionStart", 0), prompt(1_000)], .working),
  (
    "a running tool",
    [
      event("SessionStart", 0), prompt(1_000),
      event("PreToolUse", 2_000, tool("Bash", ["command": "make test"], id: "t1")),
    ], .working
  ),
  ("a reply to read", [event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass.")], .needsYou),
  ("a question", [event("SessionStart", 0), prompt(1_000), stop(2_000, "Postgres or SQLite?")], .needsYou),
  ("no prompt yet", [event("SessionStart", 0)], .needsYou),
  (
    "an open permission prompt",
    [
      event("SessionStart", 0), prompt(1_000),
      event("PermissionRequest", 2_000, tool("Bash", ["command": "rm -rf build"])),
    ], .needsYou
  ),
]

/// `link_down` and `link_up` in a session's facts.
@Suite struct LinkDownFacts {
  @Test func linkDownSetsUnreadWithItsTimeItsHostItsReasonAndTheStateAtThatMoment() {
    let f = tracked([event("SessionStart", 0), prompt(1_000), linkDown(5_000)])

    #expect(f.unread?.since == 5_000)
    #expect(f.unread?.host == "mini")
    #expect(f.unread?.why == refusal)
    #expect(f.unread?.state == .working)
  }

  @Test func factsWithNoLinkDownHaveNoUnread() {
    let f = tracked([event("SessionStart", 0), prompt(1_000), stop(2_000, "Done.")])

    #expect(f.unread == nil)
  }

  @Test func linkUpClearsUnread() {
    let f = tracked([event("SessionStart", 0), prompt(1_000), linkDown(5_000), linkUp(9_000)])

    #expect(f.unread == nil)
  }

  @Test func linkUpWithNoLinkDownBeforeItChangesNothing() {
    let events = [event("SessionStart", 0), prompt(1_000), stop(2_000, "Done.")]

    #expect(tracked(events + [linkUp(9_000)]).unread == nil)
    #expect(
      Attention.evaluate(remote(), tracked(events + [linkUp(9_000)]), now: 10_000)
        == Attention.evaluate(remote(), tracked(events), now: 10_000))
  }

  /// sbd records `link_down` again at load while the link is still down. The state that it keeps is still the
  /// one from before the first drop.
  @Test func aSecondLinkDownKeepsTheStateOfTheFirst() {
    let f = tracked([
      event("SessionStart", 0), prompt(1_000), linkDown(5_000), stop(6_000, "Done."), linkDown(7_000),
    ])

    #expect(f.unread?.state == .working)
    #expect(f.unread?.host == "mini")
  }

  @Test(arguments: ["link_down", "link_up", "reconciled"])
  func noneOfTheThreeKindsCountsAsActivity(kind: String) {
    let before = [event("SessionStart", 0), prompt(1_000), stop(2_000, "Done.")]
    let late: Event =
      switch kind {
      case "link_down": linkDown(900_000)
      case "link_up": linkUp(900_000)
      default: reconciled(900_000, reply: "Done.", activity: 2_000)
      }

    let f = tracked(before + (kind == "link_up" ? [linkDown(800_000), late] : [late]))

    #expect(f.lastActivity == 2_000)
    #expect(!SessionFacts.activityKinds.contains(kind))
  }

  @Test func theFactsWithUnreadSurviveAnEncodeAndADecode() throws {
    let f = tracked([event("SessionStart", 0), prompt(1_000), linkDown(5_000)])

    let decoded = try JSONCoding.decoder.decode(SessionFacts.self, from: try JSONCoding.encoder.encode(f))

    #expect(decoded == f)
    #expect(decoded.unread?.state == .working)
    #expect(decoded.unread?.why == refusal)
  }

  /// A snapshot that an sbd from before `unread` saved has no such key.
  @Test func factsEncodedWithoutUnreadDecodeWithNone() throws {
    let plain = try JSONCoding.encoder.encode(tracked([event("SessionStart", 0), prompt(1_000)]))
    var object = try #require(JSON.parse(String(decoding: plain, as: UTF8.self))?.object)
    object["unread"] = nil

    let decoded = try JSONCoding.decoder.decode(SessionFacts.self, from: Data(JSON.object(object).text.utf8))

    #expect(decoded.unread == nil)
  }
}

/// `reconciled` sets the two facts that the transcript tail gave.
@Suite struct ReconciledFacts {
  @Test func reconciledSetsTheLastReplyAndTheLastActivity() {
    let f = tracked([
      event("SessionStart", 0), prompt(1_000), stop(2_000, "First."), linkDown(3_000),
      reconciled(900_000, reply: "Finished while the link was down.", activity: 500_000),
    ])

    #expect(f.lastReply == "Finished while the link was down.")
    #expect(f.lastActivity == 500_000)
  }

  /// The event is recorded at the reconnect. The work happened at the time that it names.
  @Test func reconciledTakesItsActivityFromItsDataAndNotFromItsOwnTime() {
    let f = tracked([event("SessionStart", 0), reconciled(900_000, reply: "Done.", activity: 40_000)])

    #expect(f.lastActivity == 40_000)
  }

  @Test func reconciledLeavesUnreadAsItIs() {
    let f = tracked([
      event("SessionStart", 0), prompt(1_000), stop(2_000, "First."), linkDown(3_000),
      reconciled(900_000, reply: "Second.", activity: 500_000),
    ])

    #expect(f.unread?.since == 3_000)
  }
}

/// Risk 8: while a session's host can't be read, no rule that depends on time or on hook events changes the
/// session's state, and the reason names the host and why.
@Suite struct LinkDownRules {
  @Test(arguments: frozenShapes.indices)
  func aFrozenSessionKeepsItsStateAndNamesTheHostAndWhy(shape: Int) throws {
    let (name, events, state) = frozenShapes[shape]
    let before = Attention.evaluate(remote(), tracked(events), now: 3_000)
    try #require(before.state == state, "\(name) reads \(before.state) before the drop")

    let v = Attention.evaluate(remote(), tracked(events + [linkDown(3_000)]), now: 4_000)

    #expect(v.state == state, "\(name)")
    #expect(v.reason == notConnected, "\(name)")
  }

  @Test(arguments: frozenShapes.indices)
  func aLinkDownForLongerThanTheStaleTimeLeavesTheSessionInItsKeptState(shape: Int) {
    let (name, events, state) = frozenShapes[shape]
    let f = tracked(events + [linkDown(3_000)])

    let v = Attention.evaluate(remote(), f, now: 3_000 + longAfter)

    #expect(v.state == state, "\(name)")
    #expect(v.state != .stale, "\(name)")
    #expect(v.reason == notConnected, "\(name)")
  }

  /// The same facts without the `link_down` do go Stale, so the test above shows the freeze and not a state
  /// that never goes Stale.
  @Test func theSameIdleSessionWithoutALinkDownGoesStale() {
    let f = tracked([event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass.")])

    #expect(Attention.evaluate(remote(), f, now: 3_000 + longAfter).state == .stale)
  }

  /// sbd records no `link_down` for a session whose claude had stopped on record before the link dropped, so the
  /// session is not frozen.
  @Test(arguments: ["stopped", "exited", "SessionEnd"])
  func aSessionWhoseClaudeStoppedBeforeTheDropAndHasNoLinkDownGoesStale(end: String) {
    let f = tracked([event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass."), event(end, 2_500)])

    let v = Attention.evaluate(remote(), f, now: 3_000 + longAfter)

    #expect(f.unread == nil)
    #expect(v.state == .stale)
  }

  /// The subagent wait and the job wait depend on the time since the last event.
  @Test func theSubagentWaitDoesNotRunOnAFrozenSession() throws {
    let events = [
      event("SessionStart", 0), prompt(1_000), event("SubagentStart", 1_500, ["agent_id": "a1"]),
      stop(2_000, "Started a subagent."),
    ]
    let before = Attention.evaluate(remote(), tracked(events), now: 3_000)
    try #require(before.state == .waiting)

    let v = Attention.evaluate(
      remote(), tracked(events + [linkDown(3_000)]), now: 3_000 + Attention.subagentQuietMs + 60_000)

    #expect(v.state == .waiting)
    #expect(v.reason == notConnected)
  }

  @Test func theJobWaitDoesNotRunOnAFrozenSession() throws {
    let events = [
      event("SessionStart", 0), prompt(1_000), stop(2_000, "Started a job."), event("job", 2_100, ["count": 1]),
    ]
    let before = Attention.evaluate(remote(), tracked(events), now: 2_200)
    try #require(before.state == .waiting)

    let v = Attention.evaluate(remote(), tracked(events + [linkDown(2_300)]), now: 2_300 + longAfter)

    #expect(v.state == .waiting)
    #expect(v.reason == notConnected)
  }

  // MARK: Events that arrive while the link is down

  /// The reconcile applies the spool's hooks before it records `link_up`.
  @Test func aHookEventAppliedWhileUnreadUpdatesTheFactsAndNotTheState() {
    let f = tracked([
      event("SessionStart", 0), prompt(1_000), linkDown(3_000), stop(4_000, "Finished while down."),
    ])

    let v = Attention.evaluate(remote(), f, now: 5_000)

    #expect(f.turnRunning == false)
    #expect(f.lastReply == "Finished while down.")
    #expect(v.state == .working)
    #expect(v.reason == notConnected)
  }

  @Test func aPermissionRequestAppliedWhileUnreadDoesNotChangeTheStateUntilLinkUp() {
    let request = event("PermissionRequest", 4_000, tool("Bash", ["command": "rm -rf build"]))
    let down = [event("SessionStart", 0), prompt(1_000), linkDown(3_000), request]

    let frozen = Attention.evaluate(remote(), tracked(down), now: 5_000)
    let after = Attention.evaluate(remote(), tracked(down + [linkUp(6_000)]), now: 7_000)

    #expect(frozen.state == .working)
    #expect(frozen.reason == notConnected)
    #expect(after.state == .needsYou)
    #expect(after.reason == "approve `rm -rf build`")
  }

  @Test func aPREventFromThePollerWhileUnreadUpdatesThePRAndNotTheState() throws {
    let merged = samplePR(state: .merged)
    let f = tracked([
      event("SessionStart", 0), prompt(1_000), linkDown(3_000), try prEvent(4_000, merged),
    ])

    let v = Attention.evaluate(remote(), f, now: 5_000)

    #expect(f.pr == merged)
    #expect(v.state == .working)
    #expect(v.reason == notConnected)
  }

  @Test func aWorktreeEventFromThePollerWhileUnreadDoesNotChangeTheState() throws {
    let before = [
      event("SessionStart", 0), prompt(1_000), stop(2_000, "Pushed."), try prEvent(2_500, samplePR(state: .merged)),
    ]
    let kept = Attention.evaluate(remote(), tracked(before), now: 2_600)

    let f = tracked(before + [linkDown(3_000), event("worktree", 4_000, ["dirty": 0])])
    let v = Attention.evaluate(remote(), f, now: 5_000)

    #expect(f.dirty == 0)
    #expect(v.state == kept.state)
    #expect(v.reason == notConnected)
  }

  /// A session that waits moves to Ready for review when its PR is ready. That reading is of facts that sbd
  /// can't check while the link is down.
  @Test func aPRThatBecomesReadyWhileUnreadDoesNotMoveAWaitingSessionToReadyForReview() throws {
    let waiting = remote(waits: [Wait(id: "w1", kind: .manual, note: "the vendor's reply", created: 0, then: .notify)])
    let events = [event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass."), event("wait", 2_100)]
    let ready = try prEvent(
      4_000,
      samplePR(reviewDecision: .reviewRequired, checks: "SUCCESS", reviewRequests: ["ann"], reviewDecisionRead: true))
    try #require(Attention.evaluate(waiting, tracked(events + [ready], waiting), now: 5_000).state == .readyForReview)

    let v = Attention.evaluate(waiting, tracked(events + [linkDown(3_000), ready], waiting), now: 5_000)

    #expect(v.state == .waiting)
    #expect(v.reason == notConnected)
  }

  // MARK: What the user does while the link is down

  /// The session was Done when the link dropped, so it has no other state to keep. Once it is no longer Done, it
  /// gets the state that the rules give at the time of the drop, and keeps that one.
  @Test func aSessionThatWasDoneWhenTheLinkDroppedKeepsTheStateOfTheDropOnceItIsUndone() throws {
    var f = tracked([event("SessionStart", 0), prompt(1_000), linkDown(3_000)], remote(done: true))
    try #require(f.unread?.state == .done)

    let undone = Attention.track(remote(), &f, now: 3_000 + longAfter)
    f.apply(stop(3_001 + longAfter, "Finished while down."))
    let later = Attention.track(remote(), &f, now: 3_002 + longAfter)

    #expect(undone.state == .working)
    #expect(undone.reason == notConnected)
    #expect(later.state == .working)
    #expect(later.reason == notConnected)
  }

  @Test func aSessionMarkedDoneWhileUnreadIsDone() {
    let f = tracked([event("SessionStart", 0), prompt(1_000), linkDown(3_000)], remote(done: true))

    let v = Attention.evaluate(remote(done: true), f, now: 3_000 + longAfter)

    #expect(v == Verdict(state: .done, reason: "marked done"))
  }

  @Test func aSessionMarkedDoneAndThenUndoneWhileUnreadReturnsToItsKeptState() throws {
    let events = [event("SessionStart", 0), prompt(1_000), linkDown(3_000)]
    var f = tracked(events)
    Attention.track(remote(done: true), &f, now: 4_000)
    try #require(f.lastState == .done)

    let v = Attention.track(remote(), &f, now: 5_000)

    #expect(v.state == .working)
    #expect(v.reason == notConnected)
  }

  @Test func aWaitSetWhileUnreadDoesNotChangeTheState() throws {
    let waiting = remote(waits: [Wait(id: "w1", kind: .manual, note: "the vendor's reply", created: 0, then: .notify)])
    let events = [event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass.")]
    try #require(Attention.evaluate(waiting, tracked(events, waiting), now: 2_500).state == .waiting)

    let f = tracked(events + [linkDown(3_000), event("wait", 4_000)])
    let v = Attention.evaluate(waiting, f, now: 5_000)

    #expect(v.state == .needsYou)
    #expect(v.reason == notConnected)
  }

  @Test func aMessageSentWhileUnreadDoesNotChangeTheState() {
    let sent = event("sent", 4_000, ["text": "next step", "delivery": "queued"])
    let f = tracked([event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass."), linkDown(3_000), sent])

    let v = Attention.evaluate(remote(), f, now: 4_000 + longAfter)

    #expect(v.state == .needsYou)
    #expect(v.reason == notConnected)
    #expect(f.unread?.since == 3_000)
  }

  // MARK: link_up

  @Test func linkUpRestoresTheNormalRules() {
    let events = [event("SessionStart", 0), prompt(1_000), linkDown(3_000), stop(4_000, "Finished while down.")]

    let v = Attention.evaluate(remote(), tracked(events + [linkUp(5_000)]), now: 6_000)

    #expect(v == Verdict(state: .needsYou, reason: "read its last reply and decide what's next"))
  }

  @Test func afterLinkUpAnIdleSessionGoesStaleAgain() {
    let events = [
      event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass."), linkDown(3_000), linkUp(5_000),
    ]

    let v = Attention.evaluate(remote(), tracked(events), now: 5_000 + longAfter)

    #expect(v.state == .stale)
  }

  /// Neither `link_down` nor `link_up` counts as activity, so the two days run from the session's last work.
  @Test func afterLinkUpTheStaleTimeRunsFromTheLastWorkAndNotFromTheReconnect() {
    let events = [
      event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass."), linkDown(3_000),
      linkUp(2_000 + Attention.staleAfterMs),
    ]

    let v = Attention.evaluate(remote(), tracked(events), now: 2_000 + Attention.staleAfterMs + 1_000)

    #expect(v.state == .stale)
  }

  @Test func afterLinkUpARunningTurnReadsWorkingWithItsOwnReason() {
    let events = [event("SessionStart", 0), prompt(1_000), linkDown(3_000), linkUp(5_000)]

    let v = Attention.evaluate(remote(), tracked(events), now: 61_000)

    #expect(v == Verdict(state: .working, reason: "working (1 min)"))
  }

  // MARK: The reason

  @Test func theReasonOfALinkDownWithoutAnErrorStillNamesTheHost() {
    let f = tracked([event("SessionStart", 0), prompt(1_000), linkDown(3_000, error: nil, link: "disconnected")])

    let v = Attention.evaluate(remote(), f, now: 4_000)

    #expect(v.state == .working)
    #expect(v.reason.hasPrefix("mini is not connected"), "\(v.reason)")
  }

  /// The reason is one line of the tile, as every other reason is.
  @Test func aLinkErrorOfSeveralLinesGivesAReasonOfOneLine() {
    let f = tracked([
      event("SessionStart", 0), prompt(1_000), linkDown(3_000, error: "kex_exchange_identification:\nreset by peer"),
    ])

    let v = Attention.evaluate(remote(), f, now: 4_000)

    #expect(v.reason.hasPrefix("mini is not connected: kex_exchange_identification:"), "\(v.reason)")
    #expect(!v.reason.contains("\n"))
  }
}

/// A replay of a log with `link_down` gives the same facts as the live fold, which also tracks the state on each
/// tick. So a restart of sbd while the link is down shows the frozen state.
@Suite struct LinkDownReplay {
  /// The live fold: each event applied and tracked at its time, and a tick's track at each of `ticks` in between.
  private func live(_ events: [Event], ticks: [Int64], _ session: Session = remote()) -> SessionFacts {
    var f = SessionFacts()
    var ticks = ticks.sorted()[...]
    for e in events {
      while let tick = ticks.first, tick < e.t {
        Attention.track(session, &f, now: tick)
        ticks = ticks.dropFirst()
      }
      f.apply(e)
      Attention.track(session, &f, now: e.t)
    }
    for tick in ticks { Attention.track(session, &f, now: tick) }
    return f
  }

  @Test(arguments: frozenShapes.indices)
  func aReplayOfALogWithLinkDownGivesTheFactsOfTheLiveFoldWithItsTicks(shape: Int) {
    let events = frozenShapes[shape].events + [linkDown(3_000)]
    let ticks = [3_500, 3_000 + day, 3_000 + longAfter]

    let replayed = SessionReplay.replaying(events, session: remote()).facts

    #expect(replayed == live(events, ticks: ticks), "\(frozenShapes[shape].name)")
    #expect(replayed.lastState == frozenShapes[shape].state)
  }

  @Test func aReplayThroughADropAHookAndAReconnectGivesTheFactsOfTheLiveFold() {
    let end = 3_000 + longAfter
    let events = [
      event("SessionStart", 0), prompt(1_000), linkDown(3_000), stop(4_000, "Finished while down."),
      reconciled(end, reply: "Finished while down.", activity: 4_000), linkUp(end + 1),
    ]

    let replayed = SessionReplay.replaying(events, session: remote()).facts

    #expect(replayed == live(events, ticks: [3_500, 3_000 + day, end - 1]))
    #expect(replayed.unread == nil)
  }

  /// A tick during a long drop does not move `stateSince`: the state did not change.
  @Test func ticksDuringALongDropLeaveTheStateAndItsStartAsTheyWere() {
    let events = [event("SessionStart", 0), prompt(1_000), stop(2_000, "All tests pass."), linkDown(3_000)]

    let f = live(events, ticks: [3_000 + day, 3_000 + longAfter])

    #expect(f.lastState == .needsYou)
    #expect(f.stateSince == 2_000)
  }

  @Test func theReplayOfARestartKeepsUnread() {
    var replay = SessionReplay.replaying([event("SessionStart", 0), prompt(1_000), linkDown(3_000)], session: remote())

    replay.restarted()

    #expect(replay.facts.unread?.since == 3_000)
    #expect(Attention.evaluate(remote(), replay.facts, now: 3_000 + longAfter).state == .working)
  }

  @Test func aSnapshotOfAFrozenSessionDecodesToTheSameReplay() throws {
    let replay = SessionReplay.replaying(
      [event("SessionStart", 0), prompt(1_000), linkDown(3_000)], session: remote())

    let decoded = try JSONCoding.decoder.decode(SessionReplay.self, from: try JSONCoding.encoder.encode(replay))

    #expect(decoded == replay)
  }
}
