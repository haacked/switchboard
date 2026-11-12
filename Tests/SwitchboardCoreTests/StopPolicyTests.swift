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
    #expect(policy.isQuiet(idle(), now: 0))
    #expect(!policy.isQuiet(StopPolicy.Claude(session: session(), facts: SessionFacts()), now: 0))
    #expect(!policy.isQuiet(idle(events: [event("UserPromptSubmit", 1, ["prompt": "go"])]), now: 1))
    #expect(!policy.isQuiet(idle(events: [event("PermissionRequest", 1, tool("Bash", ["command": "x"]))]), now: 1))
    var c = idle()
    c.messageWaiting = true
    #expect(!policy.isQuiet(c, now: 0))
    c = idle()
    c.attached = true
    #expect(!policy.isQuiet(c, now: 0))
    c = idle()
    c.jobs = 1
    #expect(!policy.isQuiet(c, now: 0))
  }

  /// The tick's fallback records `running` for a claude whose SessionStart
  /// hasn't come 10 s after its launch.
  func unreported(launch: Int64) -> StopPolicy.Claude {
    var s = session(wait: "CI")
    s.id = "s1"
    return StopPolicy.Claude(
      session: s, facts: facts([event("SessionStart", 0), event("resumed", launch), event("running", launch + 10_000)]))
  }

  @Test func aClaudeWithNoSessionStartSinceItsLaunchIsQuietOnlyAfterStartingMs() {
    let c = unreported(launch: 1000)
    #expect(!policy.isQuiet(c, now: 1000 + StopPolicy.startingMs - 1))
    #expect(policy.isQuiet(c, now: 1000 + StopPolicy.startingMs))
  }

  @Test func neitherStopTakesAClaudeThatMayStillBeStarting() {
    let c = unreported(launch: 1000)
    let short = StopPolicy(idleStopSeconds: 1)
    #expect(!short.idleStopDue(c, now: 1000 + 15_000))
    #expect(short.capOrder([c], now: 1000 + 15_000).isEmpty)
    #expect(short.idleStopDue(c, now: 1000 + StopPolicy.startingMs))
    #expect(short.capOrder([c], now: 1000 + StopPolicy.startingMs) == ["s1"])
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

  @Test func aSessionWithAnOpenWaitStopsSoonAfterItsTurn() {
    #expect(policy.idleStopMs(idle(wait: true)) == StopPolicy.waitingStopMs)
    #expect(policy.idleStopDue(idle(wait: true), now: StopPolicy.waitingStopMs))
    #expect(StopPolicy(idleStopSeconds: 1).idleStopMs(idle(wait: true)) == 1000)
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
      idle("card", events: [event("PermissionRequest", 1, tool("Bash", ["command": "x"]))]),
      idle("agent", events: [event("SubagentStart", 1, ["agent_id": "a1"])]), job, idle("free"),
    ]
    #expect(policy.capOrder(claudes, now: 1000 + StopPolicy.jobReportMs - 1) == ["free"])
    #expect(policy.capOrder(claudes, now: 1000 + StopPolicy.jobReportMs).sorted() == ["free", "job"])
  }
}
