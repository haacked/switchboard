import Testing

@testable import SwitchboardCore

@Suite struct StopPolicyTests {
  let policy = StopPolicy(idleStopSeconds: 600)

  /// A claude whose SessionStart arrived at `start`, with no turn since.
  func idle(
    _ id: String = "s1", start: Int64 = 0, done: Bool = false, wait: Bool = false, events more: [Event] = [],
    rank: Int? = 0, lastViewed: Int64 = 0
  ) -> StopPolicy.Claude {
    var s = session(done: done, wait: wait ? "CI" : nil)
    s.id = id
    var c = StopPolicy.Claude(session: s, facts: facts([event("SessionStart", start)] + more))
    c.rank = rank
    c.lastViewed = lastViewed
    return c
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

  /// A Done session or one with an open wait gets no earlier place than its idle time gives it.
  @Test func theCapStopsTheLongestIdleFirstWhetherDoneOrWaiting() {
    let claudes = [
      idle("busy", start: 0, events: [event("UserPromptSubmit", 1, ["prompt": "go"])]),
      idle("old", start: 100), idle("new", start: 300), idle("waiting", start: 400, wait: true),
      idle("done", start: 500, done: true),
    ]
    #expect(policy.capOrder(claudes, now: 10_000) == ["old", "new", "waiting", "done"])
  }

  @Test func theCapSkipsAClaudeWithAnOpenCardASubagentOrARecentJob() {
    var job = idle("job")
    job.lastJobSeen = 1000
    let claudes = [
      idle("card", events: [sendPending()]),
      idle("deferred", events: questionTurn() + [event("deferred", 4, ["card": 3]), event("Stop", 5)]),
      idle("agent", events: [event("SubagentStart", 1, ["agent_id": "a1"])]), job, idle("free"),
    ]
    let grace = StopPolicy.capJobGraceMs
    #expect(policy.capOrder(claudes, now: 1000 + grace - 1).sorted() == ["deferred", "free"])
    #expect(policy.capOrder(claudes, now: 1000 + grace).sorted() == ["deferred", "free", "job"])
  }

  // MARK: Rank and last viewed

  @Test func theCapStopsALowerRankBeforeAHigherRankWhateverTheLastView() {
    let claudes = [
      idle("high", start: 100, rank: 2, lastViewed: 0), idle("low", start: 900, rank: 0, lastViewed: 9_000),
    ]

    #expect(policy.capOrder(claudes, now: 10_000) == ["low", "high"])
  }

  @Test func theCapStopsEveryLowerRankBeforeAnyHigherRank() {
    let claudes = [
      idle("r2", start: 100, rank: 2), idle("r0-new", start: 800, rank: 0, lastViewed: 9_500),
      idle("r1", start: 200, rank: 1), idle("r0-old", start: 300, rank: 0),
    ]

    #expect(policy.capOrder(claudes, now: 10_000) == ["r0-old", "r0-new", "r1", "r2"])
  }

  /// "viewed-long-ago" has been idle for less time, so only the last view puts it first.
  @Test func withinARankTheLeastRecentlyViewedStopsFirst() {
    let claudes = [
      idle("viewed-lately", start: 100, rank: 1, lastViewed: 5_000),
      idle("viewed-long-ago", start: 300, rank: 1, lastViewed: 1_000),
    ]

    #expect(policy.capOrder(claudes, now: 10_000) == ["viewed-long-ago", "viewed-lately"])
  }

  @Test func aTieInRankAndLastViewGoesToTheLongestIdle() {
    let claudes = [
      idle("newer", start: 300, rank: 1, lastViewed: 1_000), idle("older", start: 100, rank: 1, lastViewed: 1_000),
    ]

    #expect(policy.capOrder(claudes, now: 10_000) == ["older", "newer"])
  }

  @Test func aTieInRankLastViewAndIdleTimeGoesBySessionId() {
    let claudes = [
      idle("b", start: 100, rank: 1, lastViewed: 1_000), idle("a", start: 100, rank: 1, lastViewed: 1_000),
    ]

    #expect(policy.capOrder(claudes, now: 10_000) == ["a", "b"])
  }

  @Test func aRecentBackgroundJobCountsAsIdleTimeWithinATie() {
    var job = idle("job", start: 100, rank: 1, lastViewed: 1_000)
    job.lastJobSeen = 600
    let claudes = [job, idle("plain", start: 400, rank: 1, lastViewed: 1_000)]

    #expect(policy.capOrder(claudes, now: 10_000) == ["plain", "job"])
  }

  @Test func theCapNeverStopsTheSessionViewedLast() {
    var last = idle("last", start: 0, rank: 0)
    last.openedLast = true
    let claudes = [last, idle("other", start: 500, rank: 3, lastViewed: 9_000)]

    #expect(policy.capOrder(claudes, now: 10_000) == ["other"])
  }

  @Test func theSessionViewedLastIsNotStoppedWithoutPriorityEither() {
    var last = idle("last", start: 0)
    last.openedLast = true

    #expect(policy.capOrder([last], now: 10_000).isEmpty)
  }

  @Test func whileRankedTheCapSkipsASessionWhoseRepositoryIsUnread() {
    let claudes = [idle("unread", start: 0, rank: nil), idle("read", start: 500, rank: 2, lastViewed: 9_000)]

    #expect(policy.capOrder(claudes, now: 10_000) == ["read"])
  }

  /// Each case breaks one rule that a candidate must meet. The claude would
  /// stop first by rank, last view, and idle time if the rule didn't hold.
  enum Unstoppable: String, CaseIterable, Sendable {
    case runningTurn, openPermission, openQuestion, groupMessageCard, messageWaiting
    case runningJob, jobSeenFourSecondsAgo, subagent, starting, attached, openedLast, unreadRepository
  }

  func unstoppable(_ rule: Unstoppable, now: Int64) -> StopPolicy.Claude {
    var c: StopPolicy.Claude
    switch rule {
    case .runningTurn: c = idle("bad", events: [event("UserPromptSubmit", 1, ["prompt": "go"])])
    case .openPermission: c = idle("bad", events: permissionTurn())
    case .openQuestion: c = idle("bad", events: questionTurn())
    case .groupMessageCard: c = idle("bad", events: [sendPending()])
    case .messageWaiting:
      c = idle("bad")
      c.messageWaiting = true
    case .runningJob:
      c = idle("bad")
      c.jobs = 1
    case .jobSeenFourSecondsAgo:
      c = idle("bad")
      c.lastJobSeen = now - 4_000
    case .subagent: c = idle("bad", events: [event("SubagentStart", 1, ["agent_id": "a1"])])
    case .starting:
      var s = session()
      s.id = "bad"
      c = StopPolicy.Claude(session: s, facts: SessionFacts())
      c.rank = 0
    case .attached:
      c = idle("bad")
      c.attached = true
    case .openedLast:
      c = idle("bad")
      c.openedLast = true
    case .unreadRepository: c = idle("bad", rank: nil)
    }
    return c
  }

  @Test(arguments: Unstoppable.allCases)
  func theCapRefusesAClaudeThatBreaksARule(_ rule: Unstoppable) {
    let now: Int64 = 10_000
    let claudes = [unstoppable(rule, now: now), idle("good", start: 500, rank: 5, lastViewed: 9_000)]

    #expect(policy.capOrder(claudes, now: now) == ["good"])
  }
}
