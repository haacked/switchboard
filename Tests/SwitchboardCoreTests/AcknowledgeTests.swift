import Foundation
import Testing

@testable import SwitchboardCore

private let readTheReply = "read its last reply and decide what's next"
private let now: Int64 = 100

/// An `ack` event whose data is the JSON encoding of the acknowledgment.
private func ackEvent(_ t: Int64, _ state: AttentionState, _ reason: String, head: String? = nil) throws -> Event {
  let data = try JSON(encoding: Acknowledgment(state: state, reason: reason, head: head))
  return event("ack", t, data.object ?? [:])
}

/// The events of a turn that ended with `reply`.
private func turn(_ reply: String, start: Int64 = 0) -> [Event] {
  [
    event("UserPromptSubmit", start, ["prompt": "go"]),
    event("Stop", start + 1, ["last_assistant_message": .string(reply)]),
  ]
}

/// A PR that every ready-to-merge condition passes.
private func mergeablePR(headSha: String = samplePRHead, mergeable: Mergeable = .mergeable) -> PullRequest {
  var pr = samplePR(headSha: headSha, mergeable: mergeable, checks: "SUCCESS")
  pr.trunkConfig = false
  pr.mergeQueue = false
  pr.reviewDecisionRead = true
  return pr
}

private func prEvent(_ t: Int64, _ pr: PullRequest) throws -> Event {
  event("pr", t, ["pr": try JSON(encoding: pr), "comments": []])
}

private let acknowledgedMs = RecheckSettings().acknowledgedMs

private func verdict(_ facts: SessionFacts, _ s: Session = session(), at t: Int64 = now) -> Verdict {
  Attention.shown(Attention.evaluate(s, facts, now: t), facts, now: t, acknowledgedMs: acknowledgedMs)
}

/// The suites nest under one name, so `--filter AcknowledgeTests` runs them all.
@Suite struct AcknowledgeTests {}

extension AcknowledgeTests {
  @Suite struct AcknowledgmentCoding {
    @Test func encodesTheStateAsItsWireName() throws {
      let json = try JSON(encoding: Acknowledgment(state: .needsYou, reason: readTheReply, head: "abc"))

      #expect(json["state"]?.string == "needs_you")
      #expect(json["reason"]?.string == readTheReply)
      #expect(json["head"]?.string == "abc")
    }

    @Test(arguments: [
      Acknowledgment(state: .needsYou, reason: readTheReply, head: nil),
      Acknowledgment(state: .readyToMerge, reason: "#42 is ready to merge", head: samplePRHead),
      Acknowledgment(state: .canContinue, reason: "offered: Want me to push?", head: "abc"),
    ])
    func roundTripsThroughJSON(_ ack: Acknowledgment) throws {
      #expect(try JSONCoding.convert(JSON(encoding: ack), to: Acknowledgment.self) == ack)
    }
  }
}

extension AcknowledgeTests {
  @Suite struct AcknowledgmentFacts {
    @Test func ackEventSetsTheAcknowledgment() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply, head: "abc")])

      #expect(f.acknowledgment == Acknowledgment(state: .needsYou, reason: readTheReply, head: "abc", at: 2))
    }

    /// The data that the spec gives as the wire format.
    @Test func ackEventWithLiteralDataSetsTheAcknowledgment() {
      let f = facts(
        turn("Done.") + [event("ack", 2, ["state": "needs_you", "reason": .string(readTheReply), "head": "abc"])])

      #expect(f.acknowledgment == Acknowledgment(state: .needsYou, reason: readTheReply, head: "abc", at: 2))
    }

    @Test func ackEventWithoutAHeadSetsANilHead() {
      let f = facts(turn("Done.") + [event("ack", 2, ["state": "needs_you", "reason": .string(readTheReply)])])

      #expect(f.acknowledgment == Acknowledgment(state: .needsYou, reason: readTheReply, head: nil, at: 2))
    }

    @Test func laterAckEventReplacesTheEarlierOne() throws {
      let f = facts(
        turn("Done.") + [
          try ackEvent(2, .needsYou, "first"), try ackEvent(3, .needsYou, readTheReply),
        ])

      #expect(f.acknowledgment == Acknowledgment(state: .needsYou, reason: readTheReply, head: nil, at: 3))
    }

    @Test func unackEventClearsTheAcknowledgment() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), event("unack", 3)])

      #expect(f.acknowledgment == nil)
    }

    @Test func userPromptSubmitClearsTheAcknowledgment() throws {
      let f = facts(
        turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), event("UserPromptSubmit", 3, ["prompt": "more"])])

      #expect(f.acknowledgment == nil)
    }

    @Test func preToolUseWhenNoTurnRunsClearsTheAcknowledgment() throws {
      let f = facts(
        turn("Done.") + [
          try ackEvent(2, .needsYou, readTheReply),
          event("PreToolUse", 3, tool("Bash", ["command": "ls"], id: "t1")),
        ])

      #expect(f.acknowledgment == nil)
    }

    /// A permission prompt in a running turn is an Inbox item. Another tool
    /// call in the same turn starts no turn.
    @Test func preToolUseWhileATurnRunsKeepsTheAcknowledgment() throws {
      let events =
        promptTurn(touchCall, touch) + [
          try ackEvent(3, .needsYou, "approve `touch x`"),
          event("PreToolUse", 4, tool("Read", ["file_path": "/a"], id: "r1")),
        ]

      let f = facts(events)

      #expect(f.acknowledgment == Acknowledgment(state: .needsYou, reason: "approve `touch x`", head: nil, at: 3))
    }

    @Test func subagentPreToolUseKeepsTheAcknowledgment() throws {
      let f = facts(
        turn("Done.") + [
          try ackEvent(2, .needsYou, readTheReply),
          event("PreToolUse", 3, tool("Bash", ["command": "ls"], id: "t1", agent: "a1")),
        ])

      #expect(f.acknowledgment != nil)
    }

    @Test(arguments: ["ack", "unack"])
    func ackAndUnackMoveTheLastActivity(_ kind: String) throws {
      let later: Int64 = 50
      let e = try kind == "ack" ? ackEvent(later, .needsYou, readTheReply) : event("unack", later)

      let f = facts(turn("Done.") + [e])

      #expect(f.lastActivity == later)
    }
  }
}

extension AcknowledgeTests {
  @Suite struct AcknowledgedVerdict {
    @Test func acknowledgedReplyIsWaitingWithTheSameReason() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply)])

      #expect(verdict(f) == Verdict(state: .waiting, reason: readTheReply))
    }

    @Test func acknowledgedReplyVerdictIsMarkedAcknowledged() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply)])

      #expect(verdict(f).acknowledged)
    }

    @Test func unacknowledgedVerdictIsNotMarkedAcknowledged() {
      let f = facts(turn("Done."))

      #expect(verdict(f) == Verdict(state: .needsYou, reason: readTheReply))
      #expect(!verdict(f).acknowledged)
    }

    @Test func acknowledgedQuestionIsWaiting() throws {
      let f = facts(
        turn("Which database, Postgres or SQLite?") + [
          try ackEvent(2, .needsYou, "answer: Which database, Postgres or SQLite?")
        ])

      let v = verdict(f)

      #expect(v == Verdict(state: .waiting, reason: "answer: Which database, Postgres or SQLite?"))
      #expect(v.acknowledged)
    }

    @Test func acknowledgedOfferIsWaiting() throws {
      let f = facts(turn("Want me to push?") + [try ackEvent(2, .canContinue, "offered: Want me to push?")])

      let v = verdict(f)

      #expect(v == Verdict(state: .waiting, reason: "offered: Want me to push?"))
      #expect(v.acknowledged)
    }

    @Test func acknowledgedReadyToMergeIsWaiting() throws {
      let f = try prFacts(
        mergeablePR(), then: [try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: samplePRHead)])

      let v = verdict(f)

      #expect(v == Verdict(state: .waiting, reason: "#42 is ready to merge"))
      #expect(v.acknowledged)
    }

    @Test func acknowledgedPermissionPromptIsWaiting() throws {
      let f = facts(promptTurn(touchCall, touch) + [try ackEvent(3, .needsYou, "approve `touch x`")])

      let v = verdict(f)

      #expect(v == Verdict(state: .waiting, reason: "approve `touch x`"))
      #expect(v.acknowledged)
    }

    @Test func acknowledgedNeedsYouPRRuleIsWaiting() throws {
      let f = try prFacts(
        mergeablePR(mergeable: .conflicting),
        then: [try ackEvent(3, .needsYou, "merge main in; #42 conflicts with main", head: samplePRHead)])

      let v = verdict(f)

      #expect(v == Verdict(state: .waiting, reason: "merge main in; #42 conflicts with main"))
      #expect(v.acknowledged)
    }

    /// The acknowledgment stays in the facts until the next turn, so the
    /// reason that comes back within the turn is acknowledged again.
    @Test func reasonThatChangesAndChangesBackIsAcknowledgedAgain() throws {
      let f = try prFacts(
        mergeablePR(),
        then: [
          try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: samplePRHead),
          try prEvent(4, mergeablePR(mergeable: .conflicting)),
          try prEvent(5, mergeablePR()),
        ])

      #expect(verdict(f).acknowledged)
    }

    @Test func unackRestoresTheInboxVerdict() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), event("unack", 3)])

      let v = verdict(f)

      #expect(v == Verdict(state: .needsYou, reason: readTheReply))
      #expect(!v.acknowledged)
    }
  }
}

/// Each condition of the acknowledgment, broken one at a time.
extension AcknowledgeTests {
  @Suite struct AcknowledgmentEnds {
    @Test func changedReasonBringsTheSessionBack() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, "some other reason")])

      let v = verdict(f)

      #expect(v == Verdict(state: .needsYou, reason: readTheReply))
      #expect(!v.acknowledged)
    }

    @Test(arguments: [AttentionState.readyToMerge, .canContinue, .waiting, .working, .done, .stale])
    func sameReasonInAnotherStateBringsTheSessionBack(_ state: AttentionState) throws {
      let f = facts(turn("Done.") + [try ackEvent(2, state, readTheReply)])

      let v = verdict(f)

      #expect(v == Verdict(state: .needsYou, reason: readTheReply))
      #expect(!v.acknowledged)
    }

    @Test func newPRHeadBringsTheSessionBack() throws {
      let f = try prFacts(
        mergeablePR(),
        then: [
          try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: samplePRHead),
          try prEvent(4, mergeablePR(headSha: "pushed")),
        ])

      let v = verdict(f)

      #expect(v == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
      #expect(!v.acknowledged)
    }

    @Test func acknowledgmentAtAnOlderHeadDoesNotApply() throws {
      let f = try prFacts(
        mergeablePR(), then: [try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: "older")])

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test func acknowledgmentWithoutAHeadDoesNotApplyOnceAPRExists() throws {
      let f = try prFacts(mergeablePR(), then: [try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: nil)])

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test func acknowledgmentWithAHeadDoesNotApplyWithoutAPR() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply, head: samplePRHead)])

      #expect(verdict(f) == Verdict(state: .needsYou, reason: readTheReply))
    }

    /// A PR that the poller found after the acknowledgment gives the session a head.
    @Test func prThatAppearsAfterTheAcknowledgmentBringsTheSessionBack() throws {
      let f = facts(
        turn("Done.") + [
          try ackEvent(2, .needsYou, readTheReply),
          try prEvent(3, samplePR(draft: true)),
        ])

      let v = verdict(f)

      #expect(!v.acknowledged)
    }

    @Test func prThatBecomesConflictingBringsTheSessionBack() throws {
      let f = try prFacts(
        mergeablePR(),
        then: [
          try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: samplePRHead),
          try prEvent(4, mergeablePR(mergeable: .conflicting)),
        ])

      let v = verdict(f)

      #expect(v == Verdict(state: .needsYou, reason: "merge main in; #42 conflicts with main"))
      #expect(!v.acknowledged)
    }

    @Test func cardThatOpensAfterTheAcknowledgmentBringsTheSessionBack() throws {
      let f = facts(
        turn("Done.") + [
          try ackEvent(2, .needsYou, readTheReply),
          Event(id: 9, session: "s1", t: 3, kind: "PermissionRequest", data: .object(touch)),
        ])

      let v = verdict(f)

      #expect(v.state == .needsYou)
      #expect(!v.acknowledged)
    }

    @Test func questionThatOpensAfterTheAcknowledgmentBringsTheSessionBack() throws {
      let f = facts(
        turn("Done.") + [
          try ackEvent(2, .needsYou, readTheReply),
          Event(id: 9, session: "s1", t: 3, kind: "PermissionRequest", data: .object(ask(id: nil))),
        ])

      let v = verdict(f)

      #expect(v.state == .needsYou)
      #expect(!v.acknowledged)
    }

    @Test func newTurnThatEndsWithTheSameReplyBringsTheSessionBack() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply)] + turn("Done.", start: 3))

      let v = verdict(f)

      #expect(v == Verdict(state: .needsYou, reason: readTheReply))
      #expect(!v.acknowledged)
    }

    @Test func newTurnBringsAnAcknowledgedReadyToMergeBack() throws {
      let f = try prFacts(
        mergeablePR(),
        then: [try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: samplePRHead)] + turn("Pushed.", start: 4))

      let v = verdict(f)

      #expect(v == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
      #expect(!v.acknowledged)
    }

    @Test func runningTurnIsWorkingNotAcknowledged() throws {
      let f = facts(
        turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), event("UserPromptSubmit", 3, ["prompt": "more"])])

      let v = verdict(f)

      #expect(v.state == .working)
      #expect(!v.acknowledged)
    }

    /// The acknowledgment of the Inbox verdict that `events` give.
    private func ackOfCurrentVerdict(_ events: [Event], at t: Int64) throws -> Event {
      let v = Attention.evaluate(session(), facts(events), now: now)
      return try ackEvent(t, v.state, v.reason)
    }

    @Test func sameCommandPromptInTheSameTurnBringsTheSessionBack() throws {
      var events = promptTurn(touchCall, touch)
      events += [
        try ackOfCurrentVerdict(events, at: 3),
        event("PostToolUse", 4, touchCall),
        event("PreToolUse", 5, tool("Bash", ["command": "touch x"], id: "b2")),
        Event(id: 7, session: "s1", t: 6, kind: "PermissionRequest", data: .object(touch)),
      ]

      let v = verdict(facts(events))

      #expect(v == Verdict(state: .needsYou, reason: "approve `touch x`"))
      #expect(!v.acknowledged)
    }

    @Test func sameQuestionInTheSameTurnBringsTheSessionBack() throws {
      var events = [event("UserPromptSubmit", 0, ["prompt": "go"]), event("PreToolUse", 1, ask())]
      events += [
        try ackOfCurrentVerdict(events, at: 2),
        event("PostToolUse", 3, ask()),
        event("PreToolUse", 4, ask(id: "q2")),
      ]

      let v = verdict(facts(events))

      #expect(v.state == .needsYou)
      #expect(!v.acknowledged)
    }

    @Test func sameGroupMessageWhileIdleBringsTheSessionBack() throws {
      var events = turn("Done.") + [sendPending()]
      events += [
        try ackOfCurrentVerdict(events, at: 11),
        sendDecided(7, "send", t: 12),
        Event(id: 9, session: "s1", t: 13, kind: "send_pending", data: .object(sendPendingData())),
      ]

      let v = verdict(facts(events))

      #expect(v.state == .needsYou)
      #expect(!v.acknowledged)
    }

    /// A prompt that only a Notification reported has no card and no PermissionRequest.
    @Test func sameNotificationPromptInTheSameTurnBringsTheSessionBack() throws {
      let prompt: [String: JSON] = [
        "notification_type": "permission_prompt", "message": "Claude needs your permission",
      ]
      var events = [
        event("UserPromptSubmit", 0, ["prompt": "go"]),
        event("PreToolUse", 1, tool("Bash", ["command": "ls"], id: "b1")),
        event("Notification", 2, prompt),
      ]
      events += [
        try ackOfCurrentVerdict(events, at: 3),
        event("PostToolUse", 4, tool("Bash", ["command": "ls"], id: "b1")),
        event("PreToolUse", 5, tool("Bash", ["command": "ls"], id: "b2")),
        event("Notification", 6, prompt),
      ]

      let v = verdict(facts(events))

      #expect(v == Verdict(state: .needsYou, reason: "approve Claude needs your permission"))
      #expect(!v.acknowledged)
    }

    @Test func acknowledgedPromptStaysAcknowledged() throws {
      var events = promptTurn(touchCall, touch)
      events.append(try ackOfCurrentVerdict(events, at: 3))

      #expect(verdict(facts(events)).acknowledged)
    }
  }
}

/// An acknowledgment applies only to an Inbox verdict, even when it matches
/// another verdict's state and reason.
extension AcknowledgeTests {
  @Suite struct OutsideTheInbox {
    @Test func waitingVerdictIgnoresAMatchingAcknowledgment() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .waiting, "the deploy of #42")])

      let v = verdict(f, session(wait: "the deploy of #42"))

      #expect(v == Verdict(state: .waiting, reason: "the deploy of #42"))
      #expect(!v.acknowledged)
    }

    @Test func doneVerdictIgnoresAMatchingAcknowledgment() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .done, "marked done")])

      let v = verdict(f, session(done: true))

      #expect(v == Verdict(state: .done, reason: "marked done"))
      #expect(!v.acknowledged)
    }

    @Test func workingVerdictIgnoresAMatchingAcknowledgment() throws {
      let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), try ackEvent(1, .working, "working (<1 min)")])

      let v = verdict(f)

      #expect(v == Verdict(state: .working, reason: "working (<1 min)"))
      #expect(!v.acknowledged)
    }

    @Test func staleVerdictIgnoresAMatchingAcknowledgment() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .stale, "idle for 3 days")])

      let v = verdict(f, at: 3 * Attention.dayMs + 2)

      #expect(v == Verdict(state: .stale, reason: "idle for 3 days"))
      #expect(!v.acknowledged)
    }

    /// sbd's own rules, such as waits and auto-continue, read `evaluate` and
    /// the tracked state, so the acknowledgment changes neither.
    @Test func evaluateAndTrackKeepTheRulesState() throws {
      var f = facts(turn("Done.") + [try ackEvent(2, .needsYou, "read its last reply and decide what's next")])

      let v = Attention.track(session(), &f, now: now)

      #expect(v.state == .needsYou)
      #expect(!v.acknowledged)
      #expect(f.lastState == .needsYou)
      #expect(Attention.shown(v, f, now: now, acknowledgedMs: acknowledgedMs).state == .waiting)
    }
  }
}

/// The time of the `ack` in the manager-redesign (sni5dx) replay.
let sni5dxAck = fixedNow + 220_000

/// The events that held manager-redesign (sni5dx) in Waiting, as its event
/// log recorded them: a turn that ran a job and ended with an informational
/// reply, an `ack` at `sni5dxAck`, an idle stop, and an `open` that resumed
/// claude without a prompt and ran a job. No prompt follows the `ack`, so no
/// new turn clears it.
func sni5dxEvents(acknowledged: Bool = true) -> [Event] {
  let start = fixedNow
  let minute: Int64 = 60_000
  var events = [
    event("UserPromptSubmit", start, ["prompt": "redesign the manager"]),
    event("job", start + 1000, ["count": 1]),
    event("Stop", start + minute, ["last_assistant_message": "The manager redesign is pushed and the tests pass."]),
    event("job", start + minute + 1000, ["count": 0]),
  ]
  if acknowledged {
    events.append(event("ack", sni5dxAck, ["state": "needs_you", "reason": .string(readTheReply)]))
  }
  events += [
    event("stopped", sni5dxAck + 15 * minute),
    event("SessionEnd", sni5dxAck + 15 * minute + 1, ["reason": "other"]),
    event("resumed", sni5dxAck + 30 * minute, ["trigger": "open", "prompt": .null]),
    event("SessionStart", sni5dxAck + 30 * minute + 1000),
    event("job", sni5dxAck + 31 * minute, ["count": 2]),
    event("job", sni5dxAck + 40 * minute, ["count": 0]),
  ]
  return events
}

/// The reason of an Inbox verdict whose acknowledgment at `at` passed its recheck time.
private func expired(_ reason: String, acknowledgedAt at: Int64) -> String {
  "\(reason) (acknowledged \(Wait.formatTime(at)), time to recheck)"
}

/// An acknowledgment holds a session in Waiting only until its recheck time.
extension AcknowledgeTests {
  @Suite struct Sni5dxReplay {
    let f = facts(sni5dxEvents())

    @Test func replayHasNoTurnAfterTheAcknowledgment() {
      #expect(f.acknowledgment != nil)
      #expect(!f.turnRunning)
      #expect(f.jobs == 0)
    }

    @Test func acknowledgedSessionIsWaitingFiftyNineMinutesLater() {
      let v = verdict(f, at: sni5dxAck + 59 * 60_000)

      #expect(v == Verdict(state: .waiting, reason: readTheReply))
      #expect(v.acknowledged)
    }

    @Test func acknowledgedSessionNeedsYouAnHourLater() {
      let v = verdict(f, at: sni5dxAck + 60 * 60_000)

      #expect(v == Verdict(state: .needsYou, reason: expired(readTheReply, acknowledgedAt: sni5dxAck)))
      #expect(!v.acknowledged)
    }
  }
}

extension AcknowledgeTests {
  @Suite struct AcknowledgmentTime {
    @Test func ackEventWithLiteralDataTakesTheEventsTime() {
      let f = facts(turn("Done.") + [event("ack", 7, ["state": "needs_you", "reason": .string(readTheReply)])])

      #expect(f.acknowledgment?.at == 7)
    }

    @Test func ackEventsTimeWinsOverATimeInItsData() {
      let f = facts(
        turn("Done.") + [event("ack", 7, ["state": "needs_you", "reason": .string(readTheReply), "at": 999])])

      #expect(f.acknowledgment?.at == 7)
    }

    @Test func laterAckEventTakesTheLaterTime() throws {
      let f = facts(
        turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), try ackEvent(9, .needsYou, readTheReply)])

      #expect(f.acknowledgment?.at == 9)
    }

    /// sbd records the acknowledgment of the evaluated verdict. The event's own time is the acknowledgment's time.
    @Test func acknowledgmentOfAVerdictHasNoTime() {
      let f = facts(turn("Done."))

      let ack = Acknowledgment(Attention.evaluate(session(), f, now: now), f)

      #expect(ack.at == nil)
    }
  }
}

/// Each acknowledged Inbox item, with the time of its `ack`.
enum AcknowledgedItem: String, CaseIterable, Sendable {
  case reply, question, offer, readyToMerge, permissionPrompt, prRule

  var ackAt: Int64 {
    switch self {
    case .reply, .question, .offer: 2
    case .readyToMerge, .permissionPrompt, .prRule: 3
    }
  }

  func acknowledgedFacts() throws -> SessionFacts {
    switch self {
    case .reply:
      return facts(turn("Done.") + [try ackEvent(ackAt, .needsYou, readTheReply)])
    case .question:
      let question = "Which database, Postgres or SQLite?"
      return facts(turn(question) + [try ackEvent(ackAt, .needsYou, "answer: \(question)")])
    case .offer:
      return facts(
        turn("Want me to push?") + [try ackEvent(ackAt, .canContinue, "offered: Want me to push?")])
    case .readyToMerge:
      return try prFacts(
        mergeablePR(), then: [try ackEvent(ackAt, .readyToMerge, "#42 is ready to merge", head: samplePRHead)])
    case .permissionPrompt:
      return facts(
        promptTurn(touchCall, touch) + [try ackEvent(ackAt, .needsYou, "approve `touch x`")])
    case .prRule:
      return try prFacts(
        mergeablePR(mergeable: .conflicting),
        then: [try ackEvent(ackAt, .needsYou, "merge main in; #42 conflicts with main", head: samplePRHead)])
    }
  }
}

extension AcknowledgeTests {
  @Suite struct AcknowledgmentRecheck {
    @Test(arguments: AcknowledgedItem.allCases)
    func itemIsWaitingAMillisecondBeforeItsRecheck(_ item: AcknowledgedItem) throws {
      let v = verdict(try item.acknowledgedFacts(), at: item.ackAt + acknowledgedMs - 1)

      #expect(v.state == .waiting)
      #expect(v.acknowledged)
    }

    /// Before the recheck time, only the state and the mark change, as before the recheck existed.
    @Test(arguments: AcknowledgedItem.allCases)
    func itemKeepsItsReasonBeforeItsRecheck(_ item: AcknowledgedItem) throws {
      let f = try item.acknowledgedFacts()
      let t = item.ackAt + acknowledgedMs - 1

      #expect(verdict(f, at: t).reason == Attention.evaluate(session(), f, now: t).reason)
    }

    @Test(arguments: AcknowledgedItem.allCases)
    func itemReturnsToItsInboxStateAtItsRecheck(_ item: AcknowledgedItem) throws {
      let f = try item.acknowledgedFacts()
      let t = item.ackAt + acknowledgedMs

      let v = verdict(f, at: t)

      #expect(v.state == Attention.evaluate(session(), f, now: t).state)
      #expect(AttentionState.inbox.contains(v.state))
      #expect(!v.acknowledged)
    }

    @Test(arguments: AcknowledgedItem.allCases)
    func expiredReasonSaysWhenTheUserAcknowledged(_ item: AcknowledgedItem) throws {
      let f = try item.acknowledgedFacts()
      let t = item.ackAt + acknowledgedMs

      let evaluated = Attention.evaluate(session(), f, now: t)

      #expect(verdict(f, at: t).reason == expired(evaluated.reason, acknowledgedAt: item.ackAt))
    }

    /// The expired path equals the unacknowledged path apart from its reason.
    @Test(arguments: AcknowledgedItem.allCases)
    func expiredVerdictKeepsEverythingButTheReason(_ item: AcknowledgedItem) throws {
      let f = try item.acknowledgedFacts()
      let t = item.ackAt + acknowledgedMs
      let evaluated = Attention.evaluate(session(), f, now: t)

      let v = verdict(f, at: t)

      #expect(v.kind == evaluated.kind)
      #expect(v.source == evaluated.source)
      #expect(v.options == evaluated.options)
      #expect(v.callouts == evaluated.callouts)
      #expect(v.summary == evaluated.summary)
      #expect(v.summarizesPR == evaluated.summarizesPR)
    }

    @Test func recheckTimeComesFromTheSetting() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply)])
      let t: Int64 = 2 + 60_000

      let v = Attention.shown(Attention.evaluate(session(), f, now: t), f, now: t, acknowledgedMs: 60_000)

      #expect(v == Verdict(state: .needsYou, reason: expired(readTheReply, acknowledgedAt: 2)))
    }

    @Test func reAcknowledgingAfterTheRecheckHoldsAgain() throws {
      let again = 2 + acknowledgedMs + 10
      let f = facts(
        turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), try ackEvent(again, .needsYou, readTheReply)])

      let v = verdict(f, at: again + 1)

      #expect(v == Verdict(state: .waiting, reason: readTheReply))
      #expect(v.acknowledged)
    }

    @Test func reAcknowledgmentHoldsForItsOwnRecheckTime() throws {
      let again = 2 + acknowledgedMs + 10
      let f = facts(
        turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), try ackEvent(again, .needsYou, readTheReply)])

      #expect(verdict(f, at: again + acknowledgedMs).reason == expired(readTheReply, acknowledgedAt: again))
    }

    /// Only an acknowledgment that covers the verdict adds the recheck text.
    @Test func acknowledgmentOfAnotherReasonLeavesTheReasonPastItsRecheck() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, "some other reason")])

      let v = verdict(f, at: 2 + acknowledgedMs)

      #expect(v.reason == readTheReply)
    }

    @Test func acknowledgmentAtAnOlderHeadLeavesTheReasonPastItsRecheck() throws {
      let f = try prFacts(
        mergeablePR(), then: [try ackEvent(3, .readyToMerge, "#42 is ready to merge", head: "older")])

      #expect(verdict(f, at: 3 + acknowledgedMs).reason == "#42 is ready to merge")
    }

    @Test func waitingVerdictIgnoresAMatchingAcknowledgmentPastItsRecheck() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .waiting, "the deploy of #42")])

      let v = verdict(f, session(wait: "the deploy of #42"), at: 2 + acknowledgedMs)

      #expect(v.reason == "the deploy of #42")
      #expect(v.state == .waiting)
      #expect(!v.acknowledged)
    }

    @Test func unackAfterTheRecheckLeavesTheReasonPlain() throws {
      let f = facts(turn("Done.") + [try ackEvent(2, .needsYou, readTheReply), event("unack", 3)])

      #expect(verdict(f, at: 2 + acknowledgedMs).reason == readTheReply)
    }
  }
}
