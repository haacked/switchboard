import Testing

@testable import SwitchboardCore

@Suite struct LivePlanTests {
  func live(_ ids: String..., exiting: Set<String> = []) -> [LivePlan.Process] {
    ids.map { LivePlan.Process(session: $0, exiting: exiting.contains($0)) }
  }

  func plan(
    cap: Int, live: [LivePlan.Process], queued: [LivePlan.Start], candidates: [String] = [],
    mcpStarting: Bool = false
  ) -> LivePlan {
    LivePlan.make(cap: cap, live: live, queued: queued, candidates: candidates, mcpStarting: mcpStarting)
  }

  @Test func theOldestStartsTakeTheFreeSlots() {
    let queued = [
      LivePlan.Start(session: "c", since: 30), LivePlan.Start(session: "a", since: 10),
      LivePlan.Start(session: "b", since: 20),
    ]
    let p = plan(cap: 3, live: live("x"), queued: queued)
    #expect(p.order == ["a", "b", "c"])
    #expect(p.starts == ["a", "b"])
    #expect(p.stops.isEmpty)
    #expect(p.waits["c"] == "the cap of 3 is full and no idle session can stop")
  }

  @Test func aTieInTimeGoesBySessionId() {
    let p = plan(
      cap: 1, live: [], queued: [LivePlan.Start(session: "b", since: 5), LivePlan.Start(session: "a", since: 5)])
    #expect(p.order == ["a", "b"])
    #expect(p.starts == ["a"])
  }

  @Test func eachWaitingStartStopsOneCandidate() {
    let queued = [LivePlan.Start(session: "q1", since: 1), LivePlan.Start(session: "q2", since: 2)]
    let p = plan(cap: 2, live: live("x", "y"), queued: queued, candidates: ["y", "x"])
    #expect(p.starts.isEmpty)
    #expect(p.stops == ["y", "x"])
    #expect(p.waits["q1"] == "waits for y to stop")
  }

  @Test func anExitingClaudeCoversOneWaitingStart() {
    let queued = [LivePlan.Start(session: "q1", since: 1), LivePlan.Start(session: "q2", since: 2)]
    let p = plan(cap: 2, live: live("x", "y", exiting: ["x"]), queued: queued, candidates: ["y"])
    #expect(p.starts.isEmpty)
    #expect(p.stops == ["y"])
    #expect(p.waits["q1"] == "waits for a stopped session to exit")
  }

  @Test func aStartWithNothingToStopWaits() {
    let p = plan(cap: 1, live: live("x"), queued: [LivePlan.Start(session: "q", since: 1)])
    #expect(p.starts.isEmpty)
    #expect(p.stops.isEmpty)
    #expect(p.waits["q"] == "the cap of 1 is full and no idle session can stop")
  }

  @Test func nothingStartsWhileTheMCPServersStart() {
    let p = plan(cap: 2, live: [], queued: [LivePlan.Start(session: "q", since: 1)], mcpStarting: true)
    #expect(p.starts.isEmpty)
    #expect(p.stops.isEmpty)
    #expect(p.waits["q"] == "the shared MCP servers are starting")
  }

  @Test func aCapBelowTheLiveCountStopsEnoughForTheQueue() {
    let p = plan(
      cap: 1, live: live("x", "y", "z"), queued: [LivePlan.Start(session: "q", since: 1)],
      candidates: ["x", "y", "z"])
    #expect(p.stops == ["x", "y", "z"])
  }

  @Test func aCapBelowTheLiveCountStopsNothingWithoutAQueue() {
    let p = plan(cap: 1, live: live("x", "y"), queued: [], candidates: ["x", "y"])
    #expect(p == LivePlan())
  }
}
