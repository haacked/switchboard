import Testing

@testable import SwitchboardCore

@Suite struct StopPolicyTests {
  let policy = StopPolicy(idleStopSeconds: 600)

  /// A claude whose SessionStart arrived at `start`, with no turn since.
  func idle(
    _ id: String = "s1", start: Int64 = 0, done: Bool = false, wait: Bool = false, events more: [Event] = []
  ) -> StopPolicy.Claude {
    var s = session(done: done, wait: wait ? "CI" : nil)
    s.id = id
    return StopPolicy.Claude(session: s, facts: facts([event("SessionStart", start)] + more))
  }

  @Test func isQuietOnlyWhenAStopLosesNothing() {
    #expect(policy.isQuiet(idle()))
    #expect(!policy.isQuiet(StopPolicy.Claude(session: session(), facts: SessionFacts())))
    #expect(!policy.isQuiet(idle(events: [event("UserPromptSubmit", 1, ["prompt": "go"])])))
    #expect(!policy.isQuiet(idle(events: [event("PermissionRequest", 1, tool("Bash", ["command": "x"]))])))
    var c = idle()
    c.messageWaiting = true
    #expect(!policy.isQuiet(c))
    c = idle()
    c.attached = true
    #expect(!policy.isQuiet(c))
    c = idle()
    c.jobs = 1
    #expect(!policy.isQuiet(c))
  }

  @Test func theIdleStopIsDueAfterIdleStopSeconds() {
    #expect(!policy.idleStopDue(idle(start: 1000), now: 1000 + 600_000 - 1))
    #expect(policy.idleStopDue(idle(start: 1000), now: 1000 + 600_000))
  }

  @Test func theIdleStopIsNeverDueForAClaudeThatIsNotQuiet() {
    var c = idle()
    c.attached = true
    #expect(!policy.idleStopDue(c, now: 10 * 600_000))
  }

  @Test func theIdleWaitCountsFromTheLastBackgroundJob() {
    var c = idle(start: 0)
    c.lastJobSeen = 500_000
    #expect(!policy.idleStopDue(c, now: 600_000))
    #expect(policy.idleStopDue(c, now: 1_100_000))
  }

  @Test func aSessionWithAnOpenWaitStopsAfterIdleStopSecondsLikeAnyOther() {
    #expect(!policy.idleStopDue(idle(wait: true), now: 600_000 - 1))
    #expect(policy.idleStopDue(idle(wait: true), now: 600_000))
  }

  @Test func aRunningSubagentHoldsTheStopForTwiceTheIdleTime() {
    let c = idle(events: [event("SubagentStart", 0, ["agent_id": "a1"])])
    #expect(!policy.idleStopDue(c, now: 600_000))
    #expect(policy.idleStopDue(c, now: 1_200_000))
  }

  @Test func theCapStopsDoneAndWaitingSessionsFirstThenTheLongestIdle() {
    let claudes = [
      idle("busy", start: 0, events: [event("UserPromptSubmit", 1, ["prompt": "go"])]),
      idle("old", start: 100), idle("new", start: 300), idle("waiting", start: 400, wait: true),
      idle("done", start: 500, done: true),
    ]
    #expect(policy.capOrder(claudes, now: 10_000) == ["waiting", "done", "old", "new"])
  }

  @Test func theCapSkipsAClaudeWithAnOpenCardASubagentOrARecentJob() {
    var job = idle("job")
    job.lastJobSeen = 1000
    let claudes = [
      idle("card", events: [sendPending()]),
      idle("deferred", events: questionTurn() + [event("deferred", 4, ["card": 3]), event("Stop", 5)]),
      idle("agent", events: [event("SubagentStart", 1, ["agent_id": "a1"])]), job, idle("free"),
    ]
    #expect(policy.capOrder(claudes, now: 1000 + StopPolicy.capJobGraceMs - 1).sorted() == ["deferred", "free"])
    #expect(policy.capOrder(claudes, now: 1000 + StopPolicy.capJobGraceMs).sorted() == ["deferred", "free", "job"])
  }
}
