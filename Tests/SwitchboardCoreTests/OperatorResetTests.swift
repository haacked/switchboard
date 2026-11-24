import Foundation
import Testing

@testable import SwitchboardCore

/// When sbd starts a fresh Operator conversation: `OperatorReset.due` and `OperatorReset.blocker`, the facts that
/// count the conversation's turns and its start, and the `operator` settings that set the limits.
@Suite struct OperatorResetTests {
  static let created: Int64 = 1_700_000_000_000
  static let dayMs: Int64 = 86_400_000

  /// Facts with `turns` turns since the last reset and the start of the conversation, nil before any reset.
  static func facts(turns: Int, started: Int64? = nil) -> SessionFacts {
    var f = SessionFacts()
    f.turnsSinceReset = turns
    f.conversationStarted = started
    return f
  }

  static func settings(maxTurns: Int = 20, resetEverySeconds: Int = 86400) -> OperatorSettings {
    var s = OperatorSettings()
    s.maxTurns = maxTurns
    s.resetEverySeconds = resetEverySeconds
    return s
  }

  static func due(
    turns: Int, started: Int64? = nil, now: Int64, maxTurns: Int = 20, resetEverySeconds: Int = 86400
  ) -> Bool {
    OperatorReset.due(
      facts(turns: turns, started: started), created: created, now: now,
      settings: settings(maxTurns: maxTurns, resetEverySeconds: resetEverySeconds))
  }

  static func event(_ kind: String, t: Int64 = created, id: Int64 = 0, _ data: JSON = [:]) -> Event {
    Event(id: id, session: "op1", t: t, kind: kind, data: data)
  }

  /// The facts that the events give, applied in order as sbd applies them live and at a restart's replay.
  static func folded(_ events: [Event]) -> SessionFacts {
    var f = SessionFacts()
    for e in events { f.apply(e) }
    return f
  }

  static func prompt(_ text: String = "check the queue", t: Int64 = created) -> Event {
    event("UserPromptSubmit", t: t, ["prompt": .string(text)])
  }

  static func subagentPrompt(t: Int64 = created) -> Event {
    event("UserPromptSubmit", t: t, ["prompt": "look up the PR", "agent_id": "a1b2c3"])
  }

  static func reset(t: Int64, from: String = "old-uuid") -> Event {
    event("conversation-reset", t: t, ["from": .string(from), "to": "new-uuid", "turns": 20])
  }
}

// MARK: Due

extension OperatorResetTests {
  @Suite struct Due {
    typealias T = OperatorResetTests

    @Test(arguments: [20, 21, 500])
    func turnsAtOrPastMaxTurnsAreDue(_ turns: Int) {
      #expect(T.due(turns: turns, now: T.created + 1))
    }

    @Test(arguments: [1, 19])
    func turnsBelowMaxTurnsInAYoungConversationAreNotDue(_ turns: Int) {
      #expect(!T.due(turns: turns, now: T.created + 1))
    }

    @Test func aConversationExactlyResetEveryOldIsDue() {
      #expect(T.due(turns: 1, now: T.created + T.dayMs))
    }

    @Test func aConversationOneMsYoungerThanResetEveryIsNotDue() {
      #expect(!T.due(turns: 1, now: T.created + T.dayMs - 1))
    }

    @Test func aSmallMaxTurnsIsDueAtThatCount() {
      #expect(T.due(turns: 2, now: T.created + 1, maxTurns: 2))
    }

    /// An idle Operator has no turn since its last reset, so it never resets, however old the conversation or low
    /// the limits.
    @Test(arguments: [(20, 86400), (1, 1), (0, 86400), (20, 0), (0, 0)])
    func zeroTurnsAreNeverDue(_ maxTurns: Int, _ resetEverySeconds: Int) {
      #expect(
        !T.due(
          turns: 0, now: T.created + 365 * T.dayMs, maxTurns: maxTurns, resetEverySeconds: resetEverySeconds))
    }

    @Test(arguments: [0, -1])
    func aMaxTurnsOfZeroOrLessTurnsTheTurnLimitOff(_ maxTurns: Int) {
      #expect(!T.due(turns: 1000, now: T.created + 1, maxTurns: maxTurns))
    }

    @Test(arguments: [0, -1])
    func aResetEveryOfZeroOrLessTurnsTheAgeLimitOff(_ seconds: Int) {
      #expect(!T.due(turns: 1, now: T.created + 365 * T.dayMs, resetEverySeconds: seconds))
    }

    @Test func bothLimitsOffIsNeverDue() {
      #expect(!T.due(turns: 1000, now: T.created + 365 * T.dayMs, maxTurns: 0, resetEverySeconds: 0))
    }

    @Test func theTurnLimitAloneIsDueWithTheAgeLimitOff() {
      #expect(T.due(turns: 20, now: T.created + 1, resetEverySeconds: 0))
    }

    @Test func theAgeLimitAloneIsDueWithTheTurnLimitOff() {
      #expect(T.due(turns: 1, now: T.created + T.dayMs, maxTurns: 0))
    }

    // Where the age counts from

    @Test func beforeAnyResetTheAgeCountsFromTheSessionsCreation() {
      #expect(T.due(turns: 1, started: nil, now: T.created + T.dayMs))
    }

    @Test func afterAResetAConversationYoungerThanResetEveryIsNotDueThoughTheSessionIsOld() {
      let started = T.created + 10 * T.dayMs

      #expect(!T.due(turns: 1, started: started, now: started + T.dayMs - 1))
    }

    @Test func afterAResetTheAgeCountsFromConversationStarted() {
      let started = T.created + 10 * T.dayMs

      #expect(T.due(turns: 1, started: started, now: started + T.dayMs))
    }

    @Test func aStartLaterThanNowIsNotDueByAge() {
      let started = T.created + T.dayMs

      #expect(!T.due(turns: 1, started: started, now: T.created))
    }
  }
}

// MARK: Blocker

extension OperatorResetTests {
  /// The reset blockers that the Operator's waits and facts show. A turn, a queued message, a pause, a claude that is
  /// not quiet, an MCP or resume launch, and a host are service state, which Tests/IntegrationTests/
  /// OperatorResetTests.swift covers.
  @Suite struct Blocker {
    typealias T = OperatorResetTests

    static func wait(_ status: ActionStatus.Kind?) -> Wait {
      WaitActionTests.storedWait(
        action: WaitAction(kind: .merge), status: status.map { ActionStatus(kind: $0, since: 5) })
    }

    static func report(id: Int64, needsYou: Bool) -> Event {
      T.event(
        OperatorReport.event, id: id, ["text": "PR #12 is green. Merge it?", "needsYou": .bool(needsYou)])
    }

    @Test func noWaitAndNoReportBlocksNothing() {
      #expect(OperatorReset.blocker(waits: [], facts: SessionFacts()) == nil)
    }

    @Test func aWaitAwaitingJudgmentBlocks() {
      #expect(OperatorReset.blocker(waits: [Self.wait(.awaitingJudgment)], facts: SessionFacts()) != nil)
    }

    /// A held or running action, or a wait whose condition has not been met, needs nothing from the conversation.
    @Test(arguments: [ActionStatus.Kind.held, .running, nil])
    func aWaitThatDoesNotAwaitJudgmentDoesNotBlock(_ status: ActionStatus.Kind?) {
      #expect(OperatorReset.blocker(waits: [Self.wait(status)], facts: SessionFacts()) == nil)
    }

    /// The judge's `ask` parks the action without a question in this conversation, so the park needs nothing from it.
    @Test func aWaitTheJudgeParkedDoesNotBlock() {
      let parked = WaitActionTests.storedWait(
        action: WaitAction(kind: .merge),
        status: OperatorJudgeTests.Status.awaiting(subjectSince: 7))

      #expect(OperatorReset.blocker(waits: [parked], facts: SessionFacts()) == nil)
    }

    /// A question to the holder stores no `subjectSince`, and one from before the judge has no `judged`.
    @Test(arguments: [(nil, OperatorJudgeTests.Status.pair), (Int64(7), nil)] as [(Int64?, MergeGuard.Approval?)])
    func aWaitThatAskedTheHolderBlocks(_ subjectSince: Int64?, _ judged: MergeGuard.Approval?) {
      let asked = WaitActionTests.storedWait(
        action: WaitAction(kind: .merge),
        status: OperatorJudgeTests.Status.awaiting(subjectSince: subjectSince, judged: judged))

      #expect(OperatorReset.blocker(waits: [asked], facts: SessionFacts()) != nil)
    }

    @Test func oneWaitAwaitingJudgmentAmongOthersBlocks() {
      let waits = [Self.wait(nil), Self.wait(.held), Self.wait(.awaitingJudgment), Self.wait(.running)]

      #expect(OperatorReset.blocker(waits: waits, facts: SessionFacts()) != nil)
    }

    @Test func anOpenNeedsYouReportBlocks() {
      let facts = T.folded([Self.report(id: 1, needsYou: true)])

      #expect(OperatorReset.blocker(waits: [], facts: facts) != nil)
    }

    @Test func aReportWithoutNeedsYouDoesNotBlock() {
      let facts = T.folded([Self.report(id: 1, needsYou: false)])

      #expect(OperatorReset.blocker(waits: [], facts: facts) == nil)
    }

    @Test func aReportThatTheUserAnsweredDoesNotBlock() {
      let facts = T.folded([
        Self.report(id: 1, needsYou: true), T.event("sent", id: 2, ["text": "merge it", "by": "you"]),
      ])

      #expect(OperatorReset.blocker(waits: [], facts: facts) == nil)
    }

    @Test func aReportThatTheUserAcknowledgedDoesNotBlock() {
      let facts = T.folded([Self.report(id: 1, needsYou: true), T.event("ack", id: 2)])

      #expect(OperatorReset.blocker(waits: [], facts: facts) == nil)
    }

    @Test func aReportThatAnUndoReopenedBlocks() {
      let facts = T.folded([Self.report(id: 1, needsYou: true), T.event("ack", id: 2), T.event("unack", id: 3)])

      #expect(OperatorReset.blocker(waits: [], facts: facts) != nil)
    }

    /// An open card, such as a question that sbd deferred after its turn ended, waits for an answer that only this
    /// conversation can act on.
    @Test func anOpenCardBlocks() throws {
      var facts = SessionFacts()
      facts.cards = [try suggestionCard(nil)]

      #expect(OperatorReset.blocker(waits: [], facts: facts) != nil)
    }

    /// The new conversation never saw the reports that an ack closed before the reset, so an undo reopens none.
    @Test func anUndoAfterAResetReopensNoReport() {
      let acked = T.folded([Self.report(id: 1, needsYou: true), T.event("ack", id: 2), T.reset(t: T.created + 5)])
      let undone = T.folded([
        Self.report(id: 1, needsYou: true), T.event("ack", id: 2), T.reset(t: T.created + 5), T.event("unack", id: 4),
      ])

      #expect(acked.acknowledgedReports.isEmpty)
      #expect(undone.openReports.isEmpty)
      #expect(OperatorReset.blocker(waits: [], facts: undone) == nil)
    }

    /// sbd's own message does not answer the report, so the question still sits in the old conversation.
    @Test func aReportThatOnlySbdWroteAfterStillBlocks() {
      let facts = T.folded([
        Self.report(id: 1, needsYou: true), T.event("sent", id: 2, ["text": "wait w1 resolved", "by": "sbd"]),
      ])

      #expect(OperatorReset.blocker(waits: [], facts: facts) != nil)
    }
  }
}

// MARK: The facts that count the conversation

extension OperatorResetTests {
  @Suite struct Facts {
    typealias T = OperatorResetTests

    @Test func aNewSessionHasNoTurnsAndNoConversationStart() {
      let facts = SessionFacts()

      #expect(facts.turnsSinceReset == 0)
      #expect(facts.conversationStarted == nil)
    }

    @Test(arguments: [1, 3])
    func eachMainUserPromptSubmitCountsATurn(_ count: Int) {
      let facts = T.folded((0..<count).map { T.prompt("turn \($0)", t: T.created + Int64($0)) })

      #expect(facts.turnsSinceReset == count)
    }

    @Test func aSubagentsUserPromptSubmitCountsNoTurn() {
      let facts = T.folded([T.subagentPrompt()])

      #expect(facts.turnsSinceReset == 0)
    }

    @Test func subagentPromptsBetweenMainPromptsCountOnlyTheMainOnes() {
      let facts = T.folded([T.prompt(), T.subagentPrompt(), T.subagentPrompt(), T.prompt("next")])

      #expect(facts.turnsSinceReset == 2)
    }

    /// `prompts` leaves out sbd's messages, which are nearly all of the Operator's turns. The turn count keeps them.
    @Test func aPromptThatSbdSentCountsATurn() {
      let text = "Wait w1 on fix-cache resolved: merged."
      let facts = T.folded([T.event("sent", ["text": .string(text), "by": "sbd"]), T.prompt(text)])

      #expect(facts.turnsSinceReset == 1)
    }

    @Test func aPeerMessageCountsATurn() {
      let facts = T.folded([T.prompt("[from Cache work] check #12")])

      #expect(facts.turnsSinceReset == 1)
    }

    @Test(arguments: ["SessionStart", "Stop", "PreToolUse", "PostToolUse", "Notification", "SubagentStart", "sent"])
    func anotherEventCountsNoTurn(_ kind: String) {
      let facts = T.folded([T.event(kind, ["tool_name": "Bash", "text": "hello", "by": "you"])])

      #expect(facts.turnsSinceReset == 0)
    }

    @Test func aConversationResetZeroesTheTurns() {
      let facts = T.folded([T.prompt(), T.prompt("two"), T.reset(t: T.created + 5)])

      #expect(facts.turnsSinceReset == 0)
    }

    @Test func aConversationResetSetsConversationStartedToItsTime() {
      let facts = T.folded([T.prompt(), T.reset(t: T.created + 5)])

      #expect(facts.conversationStarted == T.created + 5)
    }

    @Test func aConversationResetClearsTheTranscriptPath() {
      let start = T.event("SessionStart", ["transcript_path": "/a/projects/-m/old-uuid.jsonl", "source": "startup"])
      let facts = T.folded([start, T.prompt(), T.reset(t: T.created + 5)])

      #expect(facts.transcriptPath == nil)
    }

    @Test func turnsAfterAResetCountFromZero() {
      let facts = T.folded([T.prompt(), T.prompt("two"), T.prompt("three"), T.reset(t: T.created + 5), T.prompt("new")])

      #expect(facts.turnsSinceReset == 1)
    }

    @Test func aSecondResetMovesConversationStarted() {
      let facts = T.folded([
        T.prompt(), T.reset(t: T.created + 5), T.prompt("two", t: T.created + 6), T.reset(t: T.created + 9),
      ])

      #expect(facts.conversationStarted == T.created + 9)
    }

    @Test func eachResetAddsTheConversationItLeftToPastConversations() {
      let facts = T.folded([
        T.prompt(), T.reset(t: T.created + 5, from: "first"), T.prompt("two", t: T.created + 6),
        T.reset(t: T.created + 9, from: "second"),
      ])

      #expect(facts.pastConversations == ["first", "second"])
    }

    @Test func aSessionStartAfterAResetKeepsConversationStarted() {
      let start = T.event("SessionStart", t: T.created + 8, ["transcript_path": "/a/new-uuid.jsonl"])
      let facts = T.folded([T.prompt(), T.reset(t: T.created + 5), start])

      #expect(facts.conversationStarted == T.created + 5)
    }

    /// An `account-moved` event clears the transcript path and leaves the conversation as it was.
    @Test func anAccountMoveKeepsTheTurns() {
      let facts = T.folded([T.prompt(), T.prompt("two"), T.event("account-moved", ["to": "B"])])

      #expect(facts.turnsSinceReset == 2)
    }
  }
}

// MARK: Settings

extension OperatorResetTests {
  @Suite struct Settings {
    @Test(arguments: ["{}", #"{"operator": {}}"#, #"{"operator": {"mergeRepos": ["haacked/switchboard"]}}"#])
    func withoutTheKeysTheOperatorResetsAfter20TurnsOrADay(_ configJSON: String) throws {
      let s = try JSONCoding.decode(Config.self, from: configJSON).operator

      #expect(s.maxTurns == 20)
      #expect(s.resetEverySeconds == 86400)
    }

    @Test(arguments: ["{}", #"{"operator": {}}"#])
    func withoutAWindowTheOperatorGets183k(_ configJSON: String) throws {
      #expect(try JSONCoding.decode(Config.self, from: configJSON).operator.autoCompactWindow == 183_000)
    }

    @Test func configReadsMaxTurns() throws {
      let s = try JSONCoding.decode(Config.self, from: #"{"operator": {"maxTurns": 2}}"#).operator

      #expect(s.maxTurns == 2)
    }

    @Test func configReadsResetEverySeconds() throws {
      let s = try JSONCoding.decode(Config.self, from: #"{"operator": {"resetEverySeconds": 3600}}"#).operator

      #expect(s.resetEverySeconds == 3600)
    }

    @Test func configReadsAutoCompactWindow() throws {
      let s = try JSONCoding.decode(Config.self, from: #"{"operator": {"autoCompactWindow": 100000}}"#).operator

      #expect(s.autoCompactWindow == 100_000)
    }

    @Test func zeroTurnsALimitOffAndDecodesAsZero() throws {
      let s = try JSONCoding.decode(
        Config.self, from: #"{"operator": {"maxTurns": 0, "resetEverySeconds": 0, "autoCompactWindow": 0}}"#
      ).operator

      #expect(s.maxTurns == 0)
      #expect(s.resetEverySeconds == 0)
      #expect(s.autoCompactWindow == 0)
    }

    @Test func oneNewKeyLeavesTheOtherSettingsAtTheirDefaults() throws {
      let s = try JSONCoding.decode(Config.self, from: #"{"operator": {"maxTurns": 2}}"#).operator

      var expected = OperatorSettings()
      expected.maxTurns = 2
      #expect(s == expected)
    }

    @Test func theNewKeysLeaveTheExistingSettingsAsTheyWere() throws {
      let s = try JSONCoding.decode(
        Config.self,
        from: #"""
          {"operator": {"holdRetrySeconds": 30, "model": "haiku", "maxTurns": 5, "resetEverySeconds": 60,
           "autoCompactWindow": 120000}}
          """#
      ).operator

      #expect(s.holdRetrySeconds == 30)
      #expect(s.holdLimitSeconds == OperatorSettings().holdLimitSeconds)
      #expect(s.model == "haiku")
    }

    @Test func theNewSettingsRoundTripThroughConfig() throws {
      var config = Config()
      config.operator.maxTurns = 7
      config.operator.resetEverySeconds = 7200
      config.operator.autoCompactWindow = 150_000

      let decoded = try JSONCoding.decode(Config.self, from: try JSON(encoding: config).text)

      #expect(decoded.operator == config.operator)
    }
  }
}
