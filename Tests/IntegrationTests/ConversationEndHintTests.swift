import Foundation
import SwitchboardCore
import Testing

/// The end hint of a Manager conversation. `sb manager ls --json` and `sb get --json` carry `endHint` with
/// `reason`, `key`, `text`, and, for the context reason, `tokens`. The done hint shows when every session the
/// conversation spawned is Done or gone and the conversation has no waits, pause condition, or schedules of its
/// own. The context hint shows when the context reached `conversationHintTokens`. No hint shows while a message is
/// on its way to the conversation. `sb manager hint <conv> --dismiss` hides the hint until its key changes.
///
/// The conversation's summary also carries `handedWaits`, the operator's waits that the conversation handed off.
@Suite(.blocking(timeLimit: .seconds(120))) struct ConversationEndHintTests {
  let handoff = OperatorHandoffTests()
  let digest = DigestTests()
  let context = ConversationContextTests()
  let schedules = ScheduleTests()
  let chatRead = ChatReadTests()

  static let doneText = "Every session this conversation started is done. End it to start fresh."

  func conversation(_ sbd: Instance, _ name: String = OperatorHandoffTests.conversationName) throws -> SessionSummary {
    try handoff.conversation(sbd, name)
  }

  /// The conversation's row in `sb manager ls --json`, as raw JSON.
  func row(_ sbd: Instance, _ id: String) throws -> JSON {
    let rows = try #require(JSON.parse(try sbd.sb("manager", "ls", "--json"))?.array)
    return try #require(rows.first { $0["id"]?.string == id }, "manager ls has no \(id)")
  }

  /// The `endHint` of a summary in JSON, or nil when it has none.
  func endHint(_ summary: JSON) -> JSON? {
    guard let hint = summary["endHint"], hint != .null else { return nil }
    return hint
  }

  /// The conversation's `endHint` in `sb manager ls --json`.
  func hint(_ sbd: Instance, _ id: String) throws -> JSON? { endHint(try row(sbd, id)) }

  /// Requires the done hint whose key counts `count` spawned sessions.
  func expectDone(
    _ sbd: Instance, _ id: String, count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let h = try #require(try hint(sbd, id), "no hint", sourceLocation: sourceLocation)
    #expect(h["reason"]?.string == "done", "\(h.text)", sourceLocation: sourceLocation)
    #expect(h["key"]?.string == "done:\(count)", "\(h.text)", sourceLocation: sourceLocation)
  }

  func expectNoHint(_ sbd: Instance, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let h = try hint(sbd, id)
    #expect(h == nil, "\(h?.text ?? "")", sourceLocation: sourceLocation)
  }

  /// A session that Claude in the conversation started, once its first turn has ended.
  func kid(_ sbd: Instance, of c: SessionSummary, _ name: String = "kid") throws -> SessionSummary {
    let k = try digest.child(sbd, of: c, name: name, prompt: "hello")
    try #require(k.parent == c.id, "\(name)'s parent is \(k.parent ?? "nil")")
    return try sbd.waitFor(k.id, "\(name)'s reply", timeout: 30) { $0.lastReply == "Done: hello" }
  }

  /// A conversation whose one spawned session is Done, so it shows the done hint.
  func doneConversation(_ sbd: Instance) throws -> (conversation: SessionSummary, kid: SessionSummary) {
    let c = try conversation(sbd)
    let k = try kid(sbd, of: c)
    try sbd.markSessionDone(k.id)
    try expectDone(sbd, c.id)
    return (c, k)
  }

  /// A conversation whose context is `tokens`, once `sb manager ls` shows that size.
  func contextConversation(_ sbd: Instance, _ tokens: Int) throws -> SessionSummary {
    let c = try conversation(sbd)
    try context.sendContext(sbd, c.id, tokens)
    return c
  }

  /// Runs `sb manager hint <conv> --dismiss --json` from a terminal and returns the answer.
  @discardableResult
  func dismiss(_ sbd: Instance, _ id: String) throws -> JSON {
    let text = try sbd.sb("manager", "hint", id, "--dismiss", "--json")
    return try #require(JSON.parse(text), "sb manager hint printed \(text)")
  }

  // MARK: The done hint (Risk 6)

  @Test func aConversationShowsTheDoneHintOnceItsChildIsDone() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let k = try kid(sbd, of: c)
    try expectNoHint(sbd, c.id)

    try sbd.markSessionDone(k.id)

    try expectDone(sbd, c.id)
    #expect(try hint(sbd, c.id)?["text"]?.string == Self.doneText)
  }

  @Test func aConversationThatSpawnedNothingShowsNoHint() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    try expectNoHint(sbd, c.id)
  }

  /// sbd records the child on the conversation when it creates it, so the conversation keeps it after the removal
  /// and after a restart, from a snapshot or from a full replay.
  @Test(arguments: [false, true])
  func theDoneHintStaysAfterTheChildIsRemovedAndSbdRestarts(_ snapshot: Bool) throws {
    let sbd = try Instance()
    let (c, k) = try doneConversation(sbd)

    try sbd.sb("rm", k.id)
    try expectDone(sbd, c.id)
    try chatRead.restart(sbd, snapshot: snapshot, checking: [c.id])

    try expectDone(sbd, c.id)
  }

  /// Removal is the user's or the operator's decision, so a child removed before it reached Done counts as
  /// finished.
  @Test func aChildRemovedBeforeItWasDoneCountsAsFinished() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let k = try kid(sbd, of: c)
    try expectNoHint(sbd, c.id)

    try sbd.sb("rm", k.id)

    try expectDone(sbd, c.id)
  }

  @Test func aSecondChildThatIsWorkingHidesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    let busy = try digest.child(sbd, of: c, name: "busy", prompt: "slow 60")
    try sbd.waitFor(busy.id, "the busy child's turn") { $0.state == .working }

    try expectNoHint(sbd, c.id)
  }

  /// End refuses while a background job runs, so the hint hides then too.
  @Test func aBackgroundJobHidesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    try sbd.sb("send", c.id, "background 100 held")
    try sbd.waitFor(c.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }

    try expectNoHint(sbd, c.id)
  }

  /// `sb parent --clear` takes the child out of the conversation's spawned sessions.
  @Test func unlinkingTheOnlyUnfinishedChildBringsTheDoneHintBack() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)
    let busy = try digest.child(sbd, of: c, name: "busy", prompt: "slow 60")
    try sbd.waitFor(busy.id, "the busy child's turn") { $0.state == .working }
    try expectNoHint(sbd, c.id)

    try sbd.sb("parent", busy.id, "--clear")

    try expectDone(sbd, c.id, count: 1)
  }

  /// `sb parent <session> <conv>` links a session that the conversation did not start, and it counts. The removal
  /// leaves only the recorded `linked` event to count it.
  @Test func aLinkedSessionCountsAsSpawnedAfterItsRemoval() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let other = try sbd.idleSession(name: "other")
    try sbd.sb("parent", other.id, c.id)
    try expectNoHint(sbd, c.id)
    try sbd.markSessionDone(other.id)
    try expectDone(sbd, c.id)

    try sbd.sb("rm", other.id)

    try expectDone(sbd, c.id)
  }

  @Test func aTerminalHereWaitOnTheConversationHidesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    let answer = try JSONCoding.decode(
      SessionSummary.self,
      from: try sbd.sb("wait", "--json", c.id, "--here", "--kind", "date", "--until", "1h"))
    try #require(answer.id == c.id, "the wait went to \(answer.name)")

    try expectNoHint(sbd, c.id)
  }

  @Test func aClaudeWaitThatStaysOnTheConversationHidesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    let answer = try handoff.waitInside(sbd, c, ["--here", "--kind", "date", "--until", "1h"])
    try #require(answer.id == c.id, "the wait went to \(answer.name)")

    try expectNoHint(sbd, c.id)
  }

  /// A wait handed to the operator belongs to the operator, so it leaves the done hint.
  @Test func aWaitHandedToTheOperatorLeavesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    let answer = try handoff.waitInside(sbd, c, ["--kind", "date", "--until", "1h", "--note", "loop tick"])
    try handoff.expectHandedOff(sbd, from: c, answer: answer)

    try expectDone(sbd, c.id)
  }

  @Test func aScheduleHidesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    _ = try schedules.schedule(sbd, c.id)

    try expectNoHint(sbd, c.id)
  }

  // MARK: A paused conversation

  /// The pause's condition is a wait of the conversation's own.
  @Test func aPauseConditionHidesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    let paused = try sbd.pauseJSON(c.id, ["--until", "2h", "--message", "check the flag rollout"])
    try #require(paused["pause"]?["until"] != nil, "\(paused.text)")

    try expectNoHint(sbd, c.id)
  }

  @Test func aPauseWithNoConditionLeavesTheDoneHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    try sbd.pauseJSON(c.id, ["--message", "pick up the flag work"])
    try sbd.waitForPausedExit(c.id)

    try expectDone(sbd, c.id)
  }

  // MARK: A message on its way

  /// No hint shows while a message waits for the conversation, because ending it would refuse.
  @Test func aMessageHeldForAPausedConversationHidesTheHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)
    try sbd.pauseJSON(c.id)
    try sbd.waitForPausedExit(c.id)
    try expectDone(sbd, c.id)

    try sbd.sb("send", c.id, "the deploy finished")
    try sbd.waitFor(c.id, "the held message") { $0.heldMessages == 1 }

    try expectNoHint(sbd, c.id)
  }

  /// `hold-paste` keeps the paste from reaching claude, so the message is on its way and no turn runs.
  @Test func aMessageThatClaudeHasNotConfirmedHidesTheHintUntilItsTurnEnds() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)
    sbd.hold("hold-paste")
    let text = "the deploy finished"

    try sbd.sb("send", c.id, text)

    try expectNoHint(sbd, c.id)
    try sbd.release("hold-paste")
    try sbd.waitFor(c.id, "the message's reply", timeout: 30) { $0.lastReply == "Done: \(text)" }
    try sbd.waitFor("the done hint to come back") { try hint(sbd, c.id)?["reason"]?.string == "done" }
  }

  // MARK: The context hint

  @Test func aContextAtOrAboveTheDefaultThresholdShowsTheContextHint() throws {
    let sbd = try Instance()

    let c = try contextConversation(sbd, 250_000)

    let h = try #require(try hint(sbd, c.id))
    #expect(h["reason"]?.string == "context", "\(h.text)")
    #expect(h["tokens"]?.int == 250_000, "\(h.text)")
    #expect(h["key"]?.string == "context:2", "\(h.text)")
    #expect(
      h["text"]?.string
        == "This conversation's context is 250k tokens, and each turn re-reads it. End it to start fresh.",
      "\(h.text)")
  }

  @Test func aThresholdOfZeroShowsNoContextHint() throws {
    let sbd = try Instance(config: ["conversationHintTokens": 0])

    let c = try contextConversation(sbd, 250_000)

    try expectNoHint(sbd, c.id)
  }

  @Test func aContextBelowTheConfiguredThresholdShowsNoHint() throws {
    let sbd = try Instance(config: ["conversationHintTokens": 300_000])

    let c = try contextConversation(sbd, 250_000)

    try expectNoHint(sbd, c.id)
  }

  /// The app reads `sb get`'s summary and `sb manager ls` reads its own, so both carry the same hint.
  @Test func managerLsAndGetCarryTheSameHint() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)

    let listed = try hint(sbd, c.id)
    let got = endHint(try #require(JSON.parse(try sbd.sb("get", "--json", c.id))))

    #expect(listed != nil)
    #expect(got == listed)
  }

  /// The decoded summary is what the app shows.
  @Test func theSummaryDecodesTheHint() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)

    let summary = try sbd.get(c.id)

    #expect(summary.endHint?.key == "context:2")
    #expect(summary.endHint?.tokens == 250_000)
  }

  // MARK: Dismissal

  @Test func dismissingHidesTheHintInTheAnswerAndInManagerLs() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)

    let answer = try dismiss(sbd, c.id)

    #expect(answer["id"]?.string == c.id, "\(answer.text)")
    #expect(endHint(answer) == nil, "\(answer.text)")
    try expectNoHint(sbd, c.id)
  }

  /// 260k is still the second multiple of 120k. 450k passes the third.
  @Test func aDismissedContextHintReturnsAtTheNextMultipleOfTheThreshold() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)
    try dismiss(sbd, c.id)

    try context.sendContext(sbd, c.id, 260_000)
    try expectNoHint(sbd, c.id)
    try context.sendContext(sbd, c.id, 450_000)

    let h = try #require(try hint(sbd, c.id))
    #expect(h["key"]?.string == "context:3", "\(h.text)")
  }

  /// The conversation spawned another session and that one reached Done too, so the count grew.
  @Test func aDismissedDoneHintReturnsWhenAnotherChildIsDone() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)
    try dismiss(sbd, c.id)
    try expectNoHint(sbd, c.id)

    let second = try kid(sbd, of: c, "second")
    try expectNoHint(sbd, c.id)
    try sbd.markSessionDone(second.id)

    try expectDone(sbd, c.id, count: 2)
  }

  @Test(arguments: [false, true])
  func aDismissalSurvivesARestartOfSbd(_ snapshot: Bool) throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)
    try dismiss(sbd, c.id)

    try chatRead.restart(sbd, snapshot: snapshot, checking: [c.id])

    // The context survived the restart, so the dismissal is what hides the hint.
    #expect(try context.listed(sbd, c.id).contextTokens == 250_000)
    try expectNoHint(sbd, c.id)
  }

  @Test func dismissingWithNoHintRecordsNothing() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    try dismiss(sbd, c.id)

    #expect(try sbd.events(c.id, kind: "end-hint-dismissed").isEmpty)
  }

  // MARK: Only the user dismisses (the hint is the user's)

  /// A shell pane has SB_SESSION_ID without CLAUDECODE, so sb sends the request with `caller` and sbd refuses it.
  @Test func aDismissWithSbSessionIdIsRefused() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)

    let r = try sbd.run(["manager", "hint", c.id, "--dismiss"], env: ["SB_SESSION_ID": c.id])

    #expect(r.status != 0, "sb manager hint --dismiss ran: \(r.stdout)")
    #expect(try hint(sbd, c.id) != nil)
    #expect(try sbd.events(c.id, kind: "end-hint-dismissed").isEmpty)
  }

  @Test func theDismissRequestWithACallerIsRefused() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)

    let error = failure(
      sbd, "manager-hint", ["session": .string(c.id), "dismiss": true, "caller": .string(c.id)])

    #expect(error != "no error")
    #expect(try hint(sbd, c.id) != nil)
    _ = try sbd.client.call("manager-hint", ["session": .string(c.id), "dismiss": true])
    try expectNoHint(sbd, c.id)
  }

  /// Only `--dismiss` needs the user. A session may read the hint.
  @Test func aSessionCanReadTheHint() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    let out = try sbd.sb(["manager", "hint", c.id], env: ["SB_SESSION_ID": c.id])

    #expect(out.contains(Self.doneText), "\(out)")
  }

  // MARK: The CLI's text

  @Test func managerHintPrintsTheHintsText() throws {
    let sbd = try Instance()
    let (c, _) = try doneConversation(sbd)

    let out = try sbd.sb("manager", "hint", c.id)

    #expect(out.contains(Self.doneText), "\(out)")
  }

  @Test func managerHintWithNoHintPrintsNoSuggestion() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let out = try sbd.sb("manager", "hint", c.id)

    #expect(out.contains("No suggestion"), "\(out)")
  }

  @Test func managerLsMarksOnlyTheRowWithAHint() throws {
    let sbd = try Instance()
    let withHint = try contextConversation(sbd, 250_000)
    let without = try conversation(sbd, "Another conversation")

    let lines = try sbd.sb("manager", "ls").split(separator: "\n").map(String.init)

    let hinted = try #require(lines.first { $0.hasPrefix(withHint.id) }, "\(lines)")
    let plain = try #require(lines.first { $0.hasPrefix(without.id) }, "\(lines)")
    #expect(hinted.contains("suggest ending"), "\(hinted)")
    #expect(!plain.contains("suggest ending"), "\(plain)")
  }

  // MARK: Handed waits (Decision 20)

  @Test func aHandedWaitShowsInTheConversationsHandedWaitsAndAnOwnWaitDoesNot() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let answer = try handoff.waitInside(sbd, c, ["--kind", "date", "--until", "1h", "--note", "loop tick"])
    let handed = try handoff.expectHandedOff(sbd, from: c, answer: answer).id
    let own = try handoff.waitInside(sbd, c, ["--here", "--kind", "date", "--until", "1h"])
    try #require(own.id == c.id, "the own wait went to \(own.name)")
    let ownWait = try #require(own.waits.last?.id)

    let summary = try sbd.get(c.id)

    let ids = summary.handedWaits?.map(\.id) ?? []
    #expect(ids == [handed], "\(ids)")
    #expect(!ids.contains(ownWait))
  }

  @Test func eachConversationListsOnlyTheWaitsItHandedOff() throws {
    let sbd = try Instance()
    let a = try conversation(sbd)
    let b = try conversation(sbd, "Another conversation")
    let fromA = try handoff.expectHandedOff(
      sbd, from: a, answer: try handoff.waitInside(sbd, a, ["--kind", "date", "--until", "1h", "--note", "a"])
    ).id
    let fromB = try handoff.expectHandedOff(
      sbd, from: b, answer: try handoff.waitInside(sbd, b, ["--kind", "date", "--until", "2h", "--note", "b"])
    ).id

    let listedA = try sbd.get(a.id).handedWaits?.map(\.id) ?? []
    let listedB = try sbd.get(b.id).handedWaits?.map(\.id) ?? []

    #expect(listedA == [fromA], "\(listedA)")
    #expect(listedB == [fromB], "\(listedB)")
  }
}
