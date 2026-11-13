import Testing

@testable import SwitchboardCore

/// The inputs of one `LivePlan.make` call.
struct PlanInput: CustomTestStringConvertible, Sendable {
  var label: String
  var cap: Int
  var live: [LivePlan.Process]
  var queued: [LivePlan.Start]
  var candidates: [String] = []
  var mcpStarting = false

  var testDescription: String { label }

  func plan() -> LivePlan {
    LivePlan.make(cap: cap, live: live, queued: queued, candidates: candidates, mcpStarting: mcpStarting)
  }

  /// The inputs of the next plan once sbd has run `plan`: each stopped claude
  /// is still exiting, each started claude runs, and neither is a candidate.
  func after(_ plan: LivePlan) -> PlanInput {
    var next = self
    next.live =
      live.map { plan.stops.contains($0.session) ? LivePlan.Process(session: $0.session, exiting: true) : $0 }
      + plan.starts.map { LivePlan.Process(session: $0, exiting: false) }
    next.queued = queued.filter { !plan.starts.contains($0.session) }
    next.candidates = candidates.filter { !plan.stops.contains($0) }
    return next
  }
}

/// Running claudes. The ones in `exiting` were stopped and haven't exited yet.
private func running(_ ids: String..., exiting: Set<String> = []) -> [LivePlan.Process] {
  ids.map { LivePlan.Process(session: $0, exiting: exiting.contains($0)) }
}

/// A queued start. A background start has no `jumped`. A jump has the time
/// of its jump.
private func start(_ id: String, since: Int64, rank: Int = 0, jumped: Int64? = nil) -> LivePlan.Start {
  LivePlan.Start(session: id, since: since, rank: rank, jumped: jumped)
}

private func input(
  _ label: String, cap: Int, live: [LivePlan.Process], queued: [LivePlan.Start], candidates: [String] = [],
  mcpStarting: Bool = false
) -> PlanInput {
  PlanInput(label: label, cap: cap, live: live, queued: queued, candidates: candidates, mcpStarting: mcpStarting)
}

private let capFull = "the cap of 1 is full and no idle session can stop"

@Suite struct LivePlanRankTests {
  func plan(
    cap: Int, live: [LivePlan.Process], queued: [LivePlan.Start], candidates: [String] = [],
    mcpStarting: Bool = false, names: [String: String] = [:]
  ) -> LivePlan {
    LivePlan.make(
      cap: cap, live: live, queued: queued, candidates: candidates, mcpStarting: mcpStarting, names: names)
  }

  // MARK: Rank order

  @Test func aHigherRankStartRunsBeforeAnOlderLowerRankOne() {
    let p = plan(cap: 2, live: running("busy"), queued: [start("low", since: 1), start("high", since: 5, rank: 2)])

    #expect(p.starts == ["high"])
  }

  @Test func theQueueOrdersByRankThenByTime() {
    let queued = [
      start("r0-old", since: 1), start("r2", since: 9, rank: 2), start("r1-new", since: 8, rank: 1),
      start("r1-old", since: 2, rank: 1), start("r0-new", since: 7),
    ]

    let p = plan(cap: 1, live: running("busy"), queued: queued)

    #expect(p.order == ["r2", "r1-old", "r1-new", "r0-old", "r0-new"])
  }

  @Test func startsOfOneRankRunOldestFirst() {
    let p = plan(
      cap: 2, live: running("busy"), queued: [start("newer", since: 5, rank: 1), start("older", since: 1, rank: 1)])

    #expect(p.starts == ["older"])
  }

  @Test func freeSlotsGoToStartsInRankOrder() {
    let queued = [start("a", since: 1), start("b", since: 3, rank: 2), start("c", since: 2, rank: 1)]

    let p = plan(cap: 4, live: [], queued: queued)

    #expect(p.starts == ["b", "c", "a"])
  }

  @Test func theFirstStopGoesToTheHigherRankStart() {
    let queued = [start("low", since: 1), start("high", since: 5, rank: 2)]

    let p = plan(cap: 1, live: running("idle"), queued: queued, candidates: ["idle"], names: ["idle": "idle-one"])

    #expect(p.stops == ["idle"])
    #expect(p.starts == ["high"])
    #expect(p.waits["low"] == capFull)
  }

  /// A ranked start never waits in the queue for a stopped claude to exit.
  @Test func aRankedStartRunsWhileAStoppedSessionExits() {
    let p = plan(cap: 1, live: running("x", exiting: ["x"]), queued: [start("q", since: 1, rank: 2)])

    #expect(p.starts == ["q"])
    #expect(p.waits.isEmpty)
  }

  @Test func anUnrankedStartWaitsForAStoppedSessionToExit() {
    let p = plan(cap: 1, live: running("x", exiting: ["x"]), queued: [start("q", since: 1)])

    #expect(p.starts.isEmpty)
    #expect(p.waits["q"] == "waits for a stopped session to exit")
  }

  // MARK: Why a start waits

  /// N is 2 so that the test holds whether the reason says "start" or "starts" for one.
  @Test func aStartBehindHigherRankStartsThatWaitSaysHowMany() {
    let queued = [start("low", since: 0), start("h1", since: 1, rank: 2), start("h2", since: 2, rank: 2)]

    let p = plan(cap: 1, live: running("busy"), queued: queued)

    #expect(p.waits["low"] == "behind 2 higher-priority starts")
  }

  @Test func theFrontStartWithNoSlotSaysTheCapIsFull() {
    let queued = [start("low", since: 0), start("h1", since: 1, rank: 2), start("h2", since: 2, rank: 2)]

    let p = plan(cap: 1, live: running("busy"), queued: queued)

    #expect(p.waits["h1"] == capFull)
  }

  @Test func everyStartThatDoesNotRunHasAReason() {
    let queued = [
      start("a", since: 1), start("b", since: 2, rank: 1), start("c", since: 3, jumped: 3), start("d", since: 4),
    ]

    let p = plan(cap: 2, live: running("x", "y", "z", exiting: ["z"]), queued: queued, candidates: ["y"])

    #expect(Set(p.waits.keys) == Set(queued.map(\.session)).subtracting(p.starts))
  }

  // MARK: Jumps

  @Test func aJumpWithAFreeSlotStartsAheadOfOlderBackgroundStarts() {
    let queued = [start("bg", since: 1, rank: 3), start("jump", since: 5, jumped: 5)]

    let p = plan(cap: 2, live: running("busy"), queued: queued)

    #expect(p.starts == ["jump"])
  }

  @Test func aJumpGoesAheadOfHigherRankStarts() {
    let queued = [start("high", since: 1, rank: 3), start("jump", since: 5, jumped: 5)]

    let p = plan(cap: 1, live: running("busy"), queued: queued)

    #expect(p.order == ["jump", "high"])
  }

  @Test func aJumpWithNoSlotStopsTheFirstCandidateAndStartsInTheSamePlan() {
    let p = plan(
      cap: 2, live: running("i1", "i2"), queued: [start("jump", since: 5, jumped: 5)], candidates: ["i1", "i2"])

    #expect(p.stops == ["i1"])
    #expect(p.starts == ["jump"])
  }

  /// The jump started while the claude that it stopped still exits. That
  /// claude's slot belongs to the jump, so the next plan has nothing to do.
  @Test func thePlanAfterAJumpWithNothingElseQueuedStopsNobody() {
    let first = input(
      "jump", cap: 2, live: running("i1", "i2"), queued: [start("jump", since: 5, jumped: 5)],
      candidates: ["i1", "i2"])

    let next = first.after(first.plan()).plan()

    #expect(next == LivePlan())
  }

  @Test func aJumpWhileABackgroundStartWaitsGivesThatStartOneStop() {
    let queued = [start("bg", since: 1), start("jump", since: 5, jumped: 5)]

    let p = plan(cap: 2, live: running("i1", "i2"), queued: queued, candidates: ["i1", "i2"])

    #expect(p.starts == ["jump"])
    #expect(p.stops == ["i1", "i2"])
  }

  @Test func thePlanAfterAJumpAndABackgroundStartStopsNoMore() {
    let first = input(
      "jump and background", cap: 3, live: running("i1", "i2", "i3"),
      queued: [start("bg", since: 1), start("jump", since: 5, jumped: 5)], candidates: ["i1", "i2", "i3"])

    let next = first.after(first.plan()).plan()

    #expect(next.stops.isEmpty)
    #expect(next.starts.isEmpty)
  }

  @Test func aJumpTakesTheSlotOfAnExitingClaudeAndTheQueuedStartGetsOneStop() {
    let queued = [start("bg", since: 1), start("jump", since: 5, jumped: 5)]

    let p = plan(cap: 2, live: running("x", "i", exiting: ["x"]), queued: queued, candidates: ["i"])

    #expect(p.starts == ["jump"])
    #expect(p.stops == ["i"])
  }

  @Test func ofTwoJumpsTheNewerRunsFirst() {
    let queued = [start("j1", since: 1, jumped: 10), start("j2", since: 2, jumped: 20)]

    let p = plan(cap: 2, live: running("busy"), queued: queued)

    #expect(p.starts == ["j2"])
  }

  @Test func twoJumpsInARowStopOneSessionEach() {
    let first = input(
      "first jump", cap: 2, live: running("i1", "i2"), queued: [start("j1", since: 1, jumped: 1)],
      candidates: ["i1", "i2"])
    var second = first.after(first.plan())
    second.queued.append(start("j2", since: 2, jumped: 2))

    let p = second.plan()

    #expect(p.stops == ["i2"])
    #expect(p.starts == ["j2"])
  }

  @Test func aJumpWithNoCandidateWaitsWithItsReason() {
    let queued = [start("bg", since: 1), start("jump", since: 5, jumped: 5)]

    let p = plan(cap: 1, live: running("busy"), queued: queued)

    #expect(p.starts.isEmpty)
    #expect(p.waits["jump"] == capFull)
  }

  @Test func aJumpWithNoCandidateWaitsAtTheFront() {
    let queued = [start("bg", since: 1, rank: 2), start("jump", since: 5, jumped: 5)]

    let p = plan(cap: 1, live: running("busy"), queued: queued)

    #expect(p.order == ["jump", "bg"])
  }

  /// The plan gets candidates already in stop order, so rank can't keep a jump from its only candidate.
  @Test func aJumpStopsAHigherRankCandidateWhenItIsTheOnlyOne() {
    let p = plan(
      cap: 1, live: running("posthog"), queued: [start("jump", since: 5, jumped: 5)], candidates: ["posthog"])

    #expect(p.stops == ["posthog"])
    #expect(p.starts == ["jump"])
  }

  @Test func aJumpWaitsWhileTheMCPServersStart() {
    let p = plan(cap: 2, live: [], queued: [start("jump", since: 5, jumped: 5)], mcpStarting: true)

    #expect(p.starts.isEmpty)
    #expect(p.waits["jump"] == "the shared MCP servers are starting")
  }

  // MARK: The cap changes

  @Test func loweringTheCapBelowTheLiveCountStopsNothingByItself() {
    let p = plan(cap: 1, live: running("a", "b", "c"), queued: [], candidates: ["a", "b", "c"])

    #expect(p == LivePlan())
  }

  @Test func raisingTheCapStartsTheQueuedStarts() {
    let p = plan(cap: 3, live: running("a"), queued: [start("b", since: 1), start("c", since: 2)])

    #expect(p.starts == ["b", "c"])
  }

  // MARK: Slot counts

  /// Each input that Risk 1 of the plan lists.
  static let slotInputs: [PlanInput] = [
    input("nothing queued", cap: 2, live: running("a", "b"), queued: [], candidates: ["a", "b"]),
    input("a jump with a free slot", cap: 2, live: running("a"), queued: [start("j", since: 1, jumped: 1)]),
    input(
      "a jump with no free slot and one candidate", cap: 1, live: running("a"),
      queued: [start("j", since: 1, jumped: 1)], candidates: ["a"]),
    input(
      "a jump while a background start is queued", cap: 2, live: running("a", "b"),
      queued: [start("bg", since: 1), start("j", since: 2, jumped: 2)], candidates: ["a", "b"]),
    input(
      "a jump while a stopped claude is exiting", cap: 2, live: running("x", "a", exiting: ["x"]),
      queued: [start("bg", since: 1), start("j", since: 2, jumped: 2)], candidates: ["a"]),
    input(
      "a jump after a jump", cap: 2, live: running("x", "a", "j1", exiting: ["x"]),
      queued: [start("j2", since: 2, jumped: 2)], candidates: ["a"]),
    input(
      "two jumps at once", cap: 2, live: running("a", "b", "c"),
      queued: [start("j1", since: 1, jumped: 1), start("j2", since: 2, jumped: 2)], candidates: ["a", "b", "c"]),
    input(
      "a jump while the MCP servers start", cap: 1, live: running("a"), queued: [start("j", since: 1, jumped: 1)],
      candidates: ["a"], mcpStarting: true),
    input(
      "background starts while the MCP servers start", cap: 2, live: running("a"),
      queued: [start("q1", since: 1), start("q2", since: 2)], candidates: ["a"], mcpStarting: true),
    input(
      "a cap below the live count", cap: 1, live: running("a", "b", "c"), queued: [], candidates: ["a", "b", "c"]),
    input(
      "a background start with more candidates than it needs", cap: 2, live: running("a", "b"),
      queued: [start("q", since: 1)], candidates: ["a", "b"]),
    input(
      "a background start and a jump with spare candidates", cap: 3, live: running("a", "b", "c"),
      queued: [start("q", since: 1), start("j", since: 2, jumped: 2)], candidates: ["a", "b", "c"]),
    input(
      "a cap below the live count with a start queued", cap: 1, live: running("a", "b", "c"),
      queued: [start("q", since: 1)], candidates: ["a", "b"]),
    input(
      "a raised cap with starts queued", cap: 4, live: running("a"),
      queued: [start("q1", since: 1), start("q2", since: 2), start("q3", since: 3, rank: 1)]),
    input(
      "a jump with no candidate", cap: 1, live: running("a"),
      queued: [start("bg", since: 1), start("j", since: 2, jumped: 2)]),
    input(
      "background starts, an exiting claude, and candidates", cap: 3, live: running("x", "a", "b", exiting: ["x"]),
      queued: [start("q1", since: 1), start("q2", since: 2, rank: 1), start("q3", since: 3)],
      candidates: ["a", "b"]),
    input(
      "ranked starts with fewer candidates than starts", cap: 2, live: running("a", "b"),
      queued: [start("q1", since: 1), start("q2", since: 2, rank: 2), start("q3", since: 3, rank: 1)],
      candidates: ["b"]),
  ]

  /// Live claudes that sbd hasn't asked to stop.
  func held(_ input: PlanInput, after plan: LivePlan) -> Int {
    input.live.filter { !$0.exiting }.count - plan.stops.count + plan.starts.count
  }

  @Test(arguments: slotInputs)
  func aPlanThatStartsClaudeKeepsTheHeldClaudesWithinTheCap(_ input: PlanInput) {
    let p = input.plan()

    #expect(p.starts.isEmpty || held(input, after: p) <= input.cap)
  }

  /// A free slot or an exiting claude counts as a slot on its way.
  @Test(arguments: slotInputs)
  func eachWaitingStartHasASlotOnItsWayWhileACandidateIsLeft(_ input: PlanInput) {
    let p = input.plan()
    let waiting = input.queued.count - p.starts.count

    if waiting > 0, p.stops.count < input.candidates.count {
      #expect(waiting <= input.cap - held(input, after: p))
    }
  }

  @Test(arguments: slotInputs)
  func thePlanStopsNoMoreThanTheWaitingStartsNeed(_ input: PlanInput) {
    let p = input.plan()
    let waiting = input.queued.count - p.starts.count

    if !p.stops.isEmpty {
      #expect(input.cap - held(input, after: p) <= waiting)
    }
  }

  /// A start that isn't a jump needs a slot that no claude holds, an exiting one included.
  @Test(arguments: slotInputs)
  func onlyAJumpOrARankedStartStartsOverTheCapOfAllProcesses(_ input: PlanInput) {
    let p = input.plan()
    let jumps = Set(input.queued.filter { $0.jumped != nil || $0.rank > 0 }.map(\.session))

    for (index, id) in p.starts.enumerated() where !jumps.contains(id) {
      #expect(input.live.count + index < input.cap, "\(id)")
    }
  }

  @Test(arguments: slotInputs)
  func thePlanStopsOnlyCandidates(_ input: PlanInput) {
    let p = input.plan()

    #expect(Set(p.stops).isSubset(of: input.candidates))
  }

  /// The request runs a plan and the tick runs the next one before any
  /// stopped claude exits. The tick must not stop or start anything more.
  @Test(arguments: slotInputs)
  func thePlanRightAfterAPlanDoesNothing(_ input: PlanInput) {
    let next = input.after(input.plan()).plan()

    #expect(next.stops.isEmpty)
    #expect(next.starts.isEmpty)
  }
}
