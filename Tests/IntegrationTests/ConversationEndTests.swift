import Foundation
import SwitchboardCore
import Testing

/// `sb manager end` removes a Manager conversation once nothing of the user's would go with it unseen. A wait, a
/// pause condition, or a schedule that stays on the conversation blocks the end until `--drop` names it. A message
/// that is queued for the conversation, or that claude has not confirmed, blocks the end whatever `--drop` names.
/// A wait handed to the operator never blocks and stays there. Only the user ends a conversation, so sbd refuses a session caller, a process in
/// any session's Claude pane, and sb refuses inside Claude Code. `--new` starts a conversation in its place.
/// `sb rm` on a conversation gets the same wait and schedule check. An open to-do blocks the end until the request's
/// `resolve` names every open to-do, as it does for `sb rm`.
///
/// The answer of `sb manager end --json` is an object. `ended` is the conversation's id, `name` its name,
/// `transcript` the path of its transcript, and `claudeSessionId` its Claude session id. `handed` and `dropped` are
/// lists of wait and schedule ids. With `--new`, `started` is the summary of the new conversation.
@Suite(.blocking(timeLimit: .seconds(120))) struct ConversationEndTests {
  let handoff = OperatorHandoffTests()
  let conversationHelpers = ManagerConversationsTests()
  let operatorHelpers = OperatorTests()
  let schedules = ScheduleTests()
  let liveCap = LiveCapTests()

  /// The gate that holds `rm` after it stopped claude and before it forgets the session. sbd waits while
  /// `$SB_HOME/hold-removal-forget` exists, as with the other `hold-removal-*` gates.
  static let forgetGate = "hold-removal-forget"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func inside(_ id: String) -> [String: String] { handoff.inside(id) }

  func conversation(_ sbd: Instance, _ name: String = OperatorHandoffTests.conversationName) throws -> SessionSummary {
    try handoff.conversation(sbd, name)
  }

  /// The ids that `sb manager ls` lists.
  func listed(_ sbd: Instance) throws -> [String] { try conversationHelpers.conversations(sbd).map(\.id) }

  /// The strings of a JSON list.
  func strings(_ value: JSON?) -> [String] { value?.array?.compactMap(\.string) ?? [] }

  func dropFlags(_ ids: [String]) -> [String] { ids.flatMap { ["--drop", $0] } }

  /// Runs `sb manager end <conv> --json` from a terminal and returns the answer. It throws when sb fails.
  func end(_ sbd: Instance, _ c: SessionSummary, _ more: [String] = []) throws -> JSON {
    let text = try sbd.sb(["manager", "end", c.id, "--json"] + more)
    return try #require(JSON.parse(text), "sb manager end printed \(text)")
  }

  /// Runs `sb manager end <conv>` from a terminal and requires that it fails.
  func refusedEnd(_ sbd: Instance, _ c: SessionSummary, _ more: [String] = [], env: [String: String] = [:]) throws
    -> CommandResult
  {
    let r = try sbd.run(["manager", "end", c.id] + more, env: env)
    try #require(r.status != 0, "sb manager end ended \(c.name): \(r.stdout)")
    return r
  }

  /// The id of the new conversation in an answer of `--new`.
  func started(_ answer: JSON) throws -> String {
    try #require(answer["started"]?["id"]?.string, "the answer has no started conversation: \(answer.text)")
  }

  /// Requires that a refused end left the conversation as `before` shows it: listed, with the same waits and
  /// schedules, and with the same claude.
  func expectUnchanged(_ sbd: Instance, _ before: SessionSummary, sourceLocation: SourceLocation = #_sourceLocation)
    throws
  {
    #expect(try listed(sbd).contains(before.id), sourceLocation: sourceLocation)
    let after = try sbd.get(before.id)
    #expect(after.waits.map(\.id) == before.waits.map(\.id), sourceLocation: sourceLocation)
    #expect(after.schedules?.map(\.id) == before.schedules?.map(\.id), sourceLocation: sourceLocation)
    #expect(after.claudePid == before.claudePid, sourceLocation: sourceLocation)
  }

  /// The id of the one wait that Claude in the conversation set and that stayed there.
  func stayingWait(_ sbd: Instance, _ c: SessionSummary, _ flags: [String]) throws -> String {
    let answer = try handoff.waitInside(sbd, c, flags)
    try #require(answer.id == c.id, "the wait went to \(answer.name)")
    return try #require(answer.waits.last?.id)
  }

  /// The id of a date wait that the user set on the conversation from a terminal.
  func typedWait(_ sbd: Instance, _ c: SessionSummary, env: [String: String] = [:], until: String = "1h") throws
    -> String
  {
    let answer = try decode(
      SessionSummary.self, sbd.sb(["wait", "--json", c.id, "--kind", "date", "--until", until], env: env))
    try #require(answer.id == c.id)
    return try #require(answer.waits.last?.id)
  }

  /// The id of the wait that Claude in the conversation handed to the operator.
  func handedWait(_ sbd: Instance, _ c: SessionSummary, _ flags: [String]) throws -> String {
    let answer = try handoff.waitInside(sbd, c, flags)
    return try handoff.expectHandedOff(sbd, from: c, answer: answer).id
  }

  func scheduleId(_ sbd: Instance, _ c: SessionSummary) throws -> String {
    try schedules.schedule(sbd, c.id).schedule.id
  }

  // MARK: Ending a conversation with nothing of its own

  @Test func theAnswerNamesTheConversationItsTranscriptAndItsClaudeSession() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let answer = try end(sbd, c)

    #expect(answer["ended"]?.string == c.id, "\(answer.text)")
    #expect(answer["name"]?.string == c.name, "\(answer.text)")
    #expect(answer["claudeSessionId"]?.string == c.claudeSessionId, "\(answer.text)")
    #expect(answer["transcript"]?.string?.hasSuffix("/\(c.claudeSessionId).jsonl") == true, "\(answer.text)")
    #expect(answer["handed"] == [], "\(answer.text)")
    #expect(answer["dropped"] == [], "\(answer.text)")
    #expect(answer["started"] == nil, "\(answer.text)")
  }

  @Test func anEndedConversationLeavesManagerLsAndItsClaudeExits() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let pid = try #require(try sbd.waitFor(c.id, "the conversation's claude") { $0.claudePid != nil }.claudePid)

    _ = try end(sbd, c)

    #expect(try !listed(sbd).contains(c.id))
    #expect(try !sbd.client.sessions().map(\.id).contains(c.id))
    try sbd.waitFor("the conversation's claude to exit", timeout: 15) { !Processes.exists(pid) }
  }

  /// Decision 1: the user can still read the transcript or resume it with `claude --resume`.
  @Test func theTranscriptStaysOnDiskAfterTheEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let answer = try end(sbd, c)

    let path = try #require(answer["transcript"]?.string)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("hello"), "\(text)")
  }

  @Test func theTextAnswerNamesTheTranscriptAndTheWaitsTheOperatorStillFollows() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let handed = try handedWait(sbd, c, ["--kind", "date", "--until", "1h", "--note", "loop tick"])

    let out = try sbd.sb("manager", "end", c.id)

    #expect(out.contains("Ended \(c.name). Its transcript is at "), "\(out)")
    #expect(out.contains("\(c.claudeSessionId).jsonl"), "\(out)")
    #expect(out.contains("The operator still follows"), "\(out)")
    #expect(out.contains(handed), "\(out)")
  }

  // MARK: Waits and schedules of its own (Risk 1)

  @Test(arguments: OperatorHandoffTests.stayShapes)
  func claudesOwnWaitRefusesTheEndUntilDropNamesIt(_ shape: OperatorHandoffTests.StayShape) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let wait = try stayingWait(sbd, c, shape.flags)
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("sb manager end"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("--drop"), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)

    let answer = try end(sbd, c, ["--drop", wait])

    #expect(strings(answer["dropped"]) == [wait], "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  @Test(arguments: OperatorHandoffTests.Typed.allCases)
  func aWaitThatTheUserTypedRefusesTheEnd(_ how: OperatorHandoffTests.Typed) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let wait = try typedWait(sbd, c, env: how == .shellPane ? ["SB_SESSION_ID": c.id] : [:])
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  /// A terminal blocks on the wait, so dropping it unseen would leave that terminal waiting for nothing.
  @Test func aBlockedWaitRefusesTheEndAndTheTerminalKeepsWaiting() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let blocked = try BackgroundSb(sbd, ["wait", "--block", "--kind", "date", "--until", "1h"], env: inside(c.id))
    let waiting = try sbd.waitFor(c.id, "the blocked wait") { $0.waits.count == 1 }
    let wait = try #require(waiting.waits.first?.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, waiting)
    #expect(blocked.isRunning)
  }

  @Test func aSessionWaitWhoseTargetIsTheOperatorRefusesTheEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    _ = try operatorHelpers.openOperator(sbd)
    let wait = try stayingWait(sbd, c, ["--kind", "session", "--target", "Operator", "--state", "done"])
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  @Test func aScheduleRefusesTheEndUntilDropNamesIt() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let schedule = try scheduleId(sbd, c)
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains(schedule), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("--drop"), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)

    let answer = try end(sbd, c, ["--drop", schedule])

    #expect(strings(answer["dropped"]) == [schedule], "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  @Test func withTwoOwnWaitsNamingOneRefusesAndNamesTheOther() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let named = try typedWait(sbd, c, until: "1h")
    let other = try typedWait(sbd, c, until: "2h")
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c, ["--drop", named])

    #expect(refused.stderr.contains(other), Comment(rawValue: refused.stderr))
    // The command to run next names every own id, including the one that the user already named.
    #expect(refused.stderr.contains("--drop \(named)"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("--drop \(other)"), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  /// The app sends the ids that its confirmation showed. A wait that arrived after that is not among them.
  @Test func aWaitAddedAfterTheIdsWereReadRefusesTheEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    _ = try typedWait(sbd, c, until: "1h")
    let shown = try sbd.get(c.id).waits.map(\.id)
    let late = try stayingWait(sbd, c, ["--kind", "manual", "--note", "ask Alex"])
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c, dropFlags(shown))

    #expect(refused.stderr.contains(late), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  /// The allowance that `--drop` gives lasts only for its own request. The to-do refuses after the allowance is set,
  /// and a plain `rm` that follows still meets the wait guard, which runs before the to-do check.
  @Test func theDropAllowanceEndsWithItsRequest() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let wait = try typedWait(sbd, c)
    let todo = try sbd.addTodo(c.id, "tell Alex in #flags that the fix shipped")
    let ended = try refusedEnd(sbd, c, ["--drop", wait])
    try #require(ended.stderr.contains(todo.id), Comment(rawValue: ended.stderr))

    let refused = try sbd.run(["rm", c.id])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("sb manager end"), Comment(rawValue: refused.stderr))
    #expect(try sbd.get(c.id).waits.map(\.id) == [wait])
  }

  @Test func repeatedDropFlagsThatNameEveryWaitAndScheduleEndIt() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let typed = try typedWait(sbd, c)
    let claudes = try stayingWait(sbd, c, ["--here", "--kind", "date", "--until", "2h"])
    let schedule = try scheduleId(sbd, c)

    let answer = try end(sbd, c, dropFlags([typed, claudes, schedule]))

    #expect(Set(strings(answer["dropped"])) == [typed, claudes, schedule], "\(answer.text)")
    #expect(strings(answer["dropped"]).count == 3, "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  /// A wait that resolved or was cleared after the confirmation showed it no longer needs the user's say.
  @Test func aDropIdThatTheConversationNoLongerHoldsIsIgnored() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let gone = try typedWait(sbd, c)
    try sbd.sb("wait", c.id, "--clear")
    try #require(try sbd.get(c.id).waits.isEmpty)

    let answer = try end(sbd, c, ["--drop", gone])

    #expect(answer["ended"]?.string == c.id, "\(answer.text)")
    #expect(answer["dropped"] == [], "\(answer.text)")
  }

  @Test func aDropIdThatNamesAHandedWaitLeavesItOnTheOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let handed = try handedWait(sbd, c, ["--kind", "date", "--until", "1h"])

    let answer = try end(sbd, c, ["--drop", handed])

    #expect(strings(answer["handed"]) == [handed], "\(answer.text)")
    #expect(answer["dropped"] == [], "\(answer.text)")
    #expect(try handoff.theOperator(sbd).waits.map(\.id) == [handed])
  }

  // MARK: A wait that lands while claude stops (Risk 1)

  /// The first check passed, so only the check in `forgetSession` can catch the wait. The `wait` request takes a
  /// wait on a conversation that is being removed, so the end refuses, the conversation keeps the wait, and its
  /// claude stays stopped.
  @Test func aWaitThatLandsWhileClaudeStopsIsNeverDroppedUnseen() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let pid = try #require(try sbd.waitFor(c.id, "the conversation's claude") { $0.claudePid != nil }.claudePid)
    let marker = "end-race-\(UUID().uuidString.prefix(8)).txt"
    try sbd.sb("send", c.id, "onterm \(marker)")
    try sbd.waitFor(c.id, "the onterm reply") { $0.lastReply == "I'll write \(marker) when I stop." }
    sbd.hold(Self.forgetGate)
    let ending = try BackgroundSb(sbd, ["manager", "end", c.id, "--json"])
    try sbd.waitFor("SIGTERM to reach the conversation's claude", timeout: 30) {
      FileManager.default.fileExists(atPath: "\(sbd.home.managerFolder)/\(marker)")
    }
    try #require(ending.isRunning, "the end did not wait at \(Self.forgetGate)")

    let landed = try sbd.run(["wait", "--json", c.id, "--kind", "date", "--until", "1h"])
    try sbd.release(Self.forgetGate)
    let r = try ending.finish(within: 30)

    try #require(landed.status == 0, Comment(rawValue: landed.stderr))
    let wait = try #require(try decode(SessionSummary.self, landed.stdout).waits.last?.id)
    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(wait), Comment(rawValue: r.stderr))
    #expect(try listed(sbd).contains(c.id))
    #expect(try sbd.get(c.id).waits.map(\.id) == [wait])
    try sbd.waitFor("the conversation's claude to exit", timeout: 15) { !Processes.exists(pid) }
    let after = try sbd.get(c.id)
    #expect(after.claudePid == nil)
    #expect(!after.live)
  }

  // MARK: A paused conversation (Risk 1)

  /// Pauses the conversation from a terminal and returns it once its claude exited.
  func paused(_ sbd: Instance, _ c: SessionSummary, _ more: [String] = []) throws -> SessionSummary {
    try sbd.pauseJSON(c.id, more)
    return try sbd.waitForPausedExit(c.id)
  }

  /// The pause's condition is a wait that resumes the conversation with the user's message, so the end drops it
  /// only when `--drop` names it.
  @Test func aPauseConditionRefusesTheEndUntilDropNamesIt() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let before = try paused(sbd, c, ["--until", "2h", "--message", "check the flag rollout"])
    let until = try #require(before.pause?.until?.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains("\(until)  Paused by you; resumes when at "), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("check the flag rollout"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("--drop \(until)"), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
    #expect(try sbd.get(c.id).pause == before.pause)

    let answer = try end(sbd, c, ["--drop", until])

    #expect(strings(answer["dropped"]) == [until], "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  /// No id names a held message, so no `--drop` lets the end drop it.
  @Test func aPausedConversationThatHoldsAMessageRefusesTheEndAndKeepsIt() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    _ = try paused(sbd, c)
    try sbd.sb("send", c.id, "the deploy finished")
    let before = try sbd.waitFor(c.id, "the held message") { $0.heldMessages == 1 }

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains("has 1 message"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("sb resume \(c.id)"), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
    #expect(try sbd.get(c.id).heldMessages == 1)
  }

  @Test func aPausedConversationWithNoConditionAndNothingHeldEnds() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    _ = try paused(sbd, c, ["--message", "pick up the flag work"])

    let answer = try end(sbd, c)

    #expect(answer["dropped"] == [], "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  // MARK: Messages on their way to a conversation that isn't paused (Risk 1)

  /// The live cap is full, so the send queues a start of the stopped conversation and its message waits in the
  /// queue. `sb open` would start it ahead of the queue.
  @Test func aQueuedStartsMessageRefusesEndAndRmAndIsDeliveredLater() throws {
    let sbd = try Instance(config: ["liveCap": 1])
    let c = try conversation(sbd)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the conversation's stop") { $0.claudePid == nil && !$0.live }
    _ = try liveCap.busySession(sbd, name: "busy", seconds: 60)
    let text = "the deploy finished"

    let delivery = try sbd.sb("send", c.id, text)
    try #require(delivery == "queued\n", "sbd sent it another way: \(delivery)")
    try sbd.waitFor("the queued start") { try !sbd.events(c.id, kind: "start-queued").isEmpty }
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c)
    let viaRm = failure(sbd, "rm", ["session": .string(c.id)])
    let viaEnd = failure(sbd, "manager-end", ["session": .string(c.id)])

    #expect(refused.stderr.contains("has 1 message"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains(text), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("sb open \(c.id)"), Comment(rawValue: refused.stderr))
    #expect(viaRm.contains(text), Comment(rawValue: viaRm))
    #expect(viaEnd == viaRm)
    try expectUnchanged(sbd, before)

    try sbd.sb("live", "--set", "2")

    try sbd.waitFor("the queued message's delivery", timeout: 30) {
      try !sbd.events(c.id, "delivered", text: text).isEmpty
    }
  }

  /// `hold-paste` keeps the paste on the paste queue, so the message has left the queue and only `inFlight`
  /// shows it. A claude that started under 1.5 s ago gets the message queued first, and the refusal names its
  /// text until the paste takes it.
  @Test func aPasteHeldInFlightRefusesTheEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let text = "the deploy finished"
    sbd.hold("hold-paste")
    try sbd.sb("send", c.id, text)
    let before = try sbd.get(c.id)

    var refused = try refusedEnd(sbd, c)
    try sbd.waitFor("the paste to take the message") {
      refused = try refusedEnd(sbd, c)
      return refused.stderr.contains("a message that claude has not confirmed yet")
    }

    #expect(refused.stderr.contains("has 1 message"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("Try again then."), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)

    try sbd.release("hold-paste")
    try sbd.waitFor(c.id, "the message's reply", timeout: 30) { $0.lastReply == "Done: \(text)" }

    let answer = try end(sbd, c)

    #expect(answer["ended"]?.string == c.id, "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  /// The removal stopped claude and waits at `hold-removal-forget`. A send to the stopped conversation would
  /// start it, which a removal refuses, so the message never queues and the end goes through.
  @Test func aSendToAStoppedConversationDuringItsRemovalIsRefused() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let pid = try #require(try sbd.waitFor(c.id, "the conversation's claude") { $0.claudePid != nil }.claudePid)
    sbd.hold(Self.forgetGate)
    let ending = try BackgroundSb(sbd, ["manager", "end", c.id, "--json"])
    try sbd.waitFor("the conversation's claude to exit", timeout: 30) { !Processes.exists(pid) }
    try sbd.waitFor(c.id, "the conversation's stop", timeout: 30) { $0.claudePid == nil && !$0.live }
    try #require(ending.isRunning, "the end did not wait at \(Self.forgetGate)")

    let sent = try sbd.run(["send", c.id, "the deploy finished"])
    try sbd.release(Self.forgetGate)
    let r = try ending.finish(within: 30)

    #expect(sent.status != 0, Comment(rawValue: sent.stdout))
    #expect(sent.stderr.contains("being deleted"), Comment(rawValue: sent.stderr))
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try !listed(sbd).contains(c.id))
  }

  /// Where the stub holds the prompt of a launch until a test lets it go.
  enum HeldLaunch: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// `hold-start` keeps the stub before SessionStart.
    case beforeSessionStart
    /// `hold` keeps the stub after SessionStart and before the prompt's UserPromptSubmit, until `report` exists.
    case afterSessionStart

    var testDescription: String { rawValue }

    var gate: String {
      switch self {
      case .beforeSessionStart: "hold-start"
      case .afterSessionStart: "hold"
      }
    }

    /// Holds the stub's next launch prompt.
    func hold(_ sbd: Instance) { sbd.hold(gate) }

    /// Lets the held launch prompt reach claude's UserPromptSubmit.
    func release(_ sbd: Instance) throws {
      switch self {
      case .beforeSessionStart: try sbd.release(gate)
      case .afterSessionStart: sbd.hold("report")
      }
    }

    /// Waits until the launch after event `mark` reaches the place where the stub holds its prompt.
    func waitForTheHold(_ sbd: Instance, _ id: String, after mark: Int64) throws {
      _ = try sbd.waitFor(id, "claude to run") { $0.claudePid != nil }
      guard self == .afterSessionStart else { return }
      try sbd.waitFor("the launch's SessionStart") {
        try sbd.events(id, after: mark).contains { $0.kind == "SessionStart" }
      }
    }
  }

  /// A send to the stopped conversation launches claude with the message as its prompt. sbd restarts before claude
  /// submits that prompt. The restarted sbd reads the launch from the log, so the prompt still counts as on its
  /// way, and both `sb manager end` and `sb rm` refuse.
  @Test(arguments: HeldLaunch.allCases)
  func aLaunchPromptThatClaudeHasNotSubmittedRefusesEndAndRmAfterARestart(_ held: HeldLaunch) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the conversation's stop") { $0.claudePid == nil && !$0.live }
    let mark = try sbd.lastEventId(c.id)
    let text = "the deploy finished"
    held.hold(sbd)

    let delivery = try sbd.sb("send", c.id, text)
    try #require(delivery == "resumed\n", "sbd sent it another way: \(delivery)")
    try held.waitForTheHold(sbd, c.id, after: mark)
    sbd.killSbd()
    try sbd.startSbd()
    let before = try sbd.waitFor(c.id, "the restarted sbd to see claude") { $0.claudePid != nil }

    let refused = try refusedEnd(sbd, c)
    let viaRm = failure(sbd, "rm", ["session": .string(c.id)])
    let viaEnd = failure(sbd, "manager-end", ["session": .string(c.id)])

    #expect(refused.stderr.contains("has 1 message"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("a message that claude has not confirmed yet"), Comment(rawValue: refused.stderr))
    #expect(viaRm.contains("a message that claude has not confirmed yet"), Comment(rawValue: viaRm))
    #expect(viaEnd == viaRm)
    try expectUnchanged(sbd, before)
    #expect(try sbd.events(c.id, after: mark).allSatisfy { $0.kind != "UserPromptSubmit" })

    try held.release(sbd)
    try sbd.waitFor(c.id, "the launch prompt's reply", timeout: 30) { $0.lastReply == "Done: \(text)" }

    let answer = try end(sbd, c)

    #expect(answer["ended"]?.string == c.id, "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  /// sbd pasted a message into the running conversation and recorded `delivered`, and the stub holds the prompt's
  /// UserPromptSubmit until `report` exists. sbd restarts in that window. The restarted sbd reads the paste from the
  /// log, so the message still counts as on its way, and both `sb manager end` and `sb rm` refuse.
  @Test func aPasteThatClaudeHasNotSubmittedRefusesEndAndRmAfterARestart() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let mark = try sbd.lastEventId(c.id)
    let text = "lag held"

    try sbd.sb("send", c.id, text)
    try sbd.waitFor("the paste's delivered", timeout: 30) { try !sbd.events(c.id, "delivered", text: text).isEmpty }
    sbd.killSbd()
    try sbd.startSbd()
    let before = try sbd.waitFor(c.id, "the restarted sbd to see claude") { $0.claudePid != nil }

    let refused = try refusedEnd(sbd, c)
    let viaRm = failure(sbd, "rm", ["session": .string(c.id)])
    let viaEnd = failure(sbd, "manager-end", ["session": .string(c.id)])

    #expect(refused.stderr.contains("has 1 message"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("a message that claude has not confirmed yet"), Comment(rawValue: refused.stderr))
    #expect(viaRm.contains("a message that claude has not confirmed yet"), Comment(rawValue: viaRm))
    #expect(viaEnd == viaRm)
    try expectUnchanged(sbd, before)
    #expect(try sbd.events(c.id, after: mark).allSatisfy { $0.kind != "UserPromptSubmit" })

    sbd.hold("report")
    try sbd.waitFor(c.id, "the message's reply", timeout: 30) { $0.lastReply == "Done: \(text)" }

    let answer = try end(sbd, c)

    #expect(answer["ended"]?.string == c.id, "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  /// `/compact` sends no UserPromptSubmit. `hold-delivered` keeps sbd from recording the paste's `delivered` until
  /// the command's SessionStart has moved the in-flight window. The paste still clears its own mark once it lands,
  /// so the end goes through.
  @Test func aBuiltInCommandWhoseSessionStartComesBeforeDeliveredLetsTheEndThrough() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let mark = try sbd.lastEventId(c.id)
    let text = "/compact"
    sbd.hold("hold-delivered")

    try sbd.sb("send", c.id, text)
    _ = try sbd.waitFor("the command's SessionStart", timeout: 30, fetch: { try sbd.events(c.id, after: mark) }) {
      $0.contains { $0.kind == "SessionStart" && $0.data["source"]?.string == "compact" }
    }
    try #require(try sbd.events(c.id, "delivered", text: text).isEmpty, "hold-delivered let delivered through")
    try sbd.release("hold-delivered")
    try sbd.waitFor("the paste's delivered", timeout: 30) { try !sbd.events(c.id, "delivered", text: text).isEmpty }
    try #require(try sbd.events(c.id, after: mark).allSatisfy { $0.kind != "UserPromptSubmit" })

    let answer = try end(sbd, c)

    #expect(answer["ended"]?.string == c.id, "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  // MARK: Waits handed to the operator (Risk 2)

  @Test(arguments: OperatorHandoffTests.handOffShapes)
  func aHandedWaitDoesNotBlockTheEndAndStaysOnTheOperator(_ shape: OperatorHandoffTests.HandOffShape) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let handed = try handedWait(sbd, c, shape.flags)
    let before = try handoff.theOperator(sbd).waits

    let answer = try end(sbd, c)

    #expect(strings(answer["handed"]) == [handed], "\(answer.text)")
    #expect(answer["dropped"] == [], "\(answer.text)")
    #expect(try handoff.theOperator(sbd).waits == before)
  }

  @Test func aHandedDateWaitResolvesAfterTheEndWithTheConversationsName() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    _ = try handedWait(sbd, c, ["--kind", "date", "--until", "1h", "--note", "check the dashboard"])
    let op = try handoff.theOperator(sbd)
    _ = try end(sbd, c)

    try sbd.advanceClock(2 * WaitTests.hourMs)

    let resumed = try sbd.waitFor(op.id, "the operator's turn", timeout: 30) {
      $0.lastReply?.hasPrefix("Done: Switchboard: until ") == true
    }
    #expect(
      resumed.lastReply?.hasSuffix(
        #": the time came. For Manager conversation "\#(c.name)". Your note: check the dashboard."#) == true,
      "\(resumed.lastReply ?? "")")
    #expect(resumed.waits.isEmpty)
  }

  @Test func aSpawnWaitFromTheConversationStaysOnTheOperatorAfterTheEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let kid = try MCPClient(sbd, env: inside(c.id)).call(
      "spawn",
      [
        "repository": .string(try sbd.makeRepo()), "branch": "kid", "name": "kid", "prompt": "hello", "wait": "done",
      ]
    ).decode(SessionSummary.self)
    let before = try handoff.theOperator(sbd).waits
    try #require(before.map(\.session?.id) == [kid.id])

    let answer = try end(sbd, c)

    #expect(strings(answer["handed"]) == before.map(\.id), "\(answer.text)")
    #expect(try handoff.theOperator(sbd).waits == before)
  }

  // MARK: Only the user ends a conversation (Risk 3)

  /// The session whose SB_SESSION_ID the command carries.
  enum SessionCaller: CaseIterable { case itself, anotherConversation, theOperator, work }

  func caller(_ sbd: Instance, _ kind: SessionCaller, target: SessionSummary) throws -> SessionSummary {
    switch kind {
    case .itself: return target
    case .anotherConversation: return try conversation(sbd, "Another conversation")
    case .theOperator: return try operatorHelpers.idleOperator(sbd)
    case .work: return try sbd.idleSession(name: "work")
    }
  }

  /// A shell pane has SB_SESSION_ID without CLAUDECODE, so sb sends the request with `caller` and sbd refuses it.
  @Test(arguments: SessionCaller.allCases) func aCommandWithSbSessionIdIsRefused(_ kind: SessionCaller) throws {
    let sbd = try Instance()
    let target = try conversation(sbd)
    let from = try caller(sbd, kind, target: target)
    let before = try sbd.get(target.id)

    let refused = try refusedEnd(sbd, target, env: ["SB_SESSION_ID": from.id])

    #expect(!refused.stderr.contains("no Manager conversation"), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  /// The app's request names no caller. A request that names one comes from a session.
  @Test(arguments: SessionCaller.allCases) func theRequestWithACallerIsRefused(_ kind: SessionCaller) throws {
    let sbd = try Instance()
    let target = try conversation(sbd)
    let from = try caller(sbd, kind, target: target)
    let before = try sbd.get(target.id)

    let error = failure(sbd, "manager-end", ["session": .string(target.id), "caller": .string(from.id)])

    #expect(error != "no error")
    try expectUnchanged(sbd, before)
    _ = try sbd.client.call("manager-end", ["session": .string(target.id)])
    #expect(try !listed(sbd).contains(target.id), "the same request without caller did not end it")
  }

  /// CLAUDECODE alone marks a command that Claude runs, with or without SB_SESSION_ID.
  @Test func insideClaudeCodeSbRefusesTheEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let before = try sbd.get(c.id)

    _ = try refusedEnd(sbd, c, env: ["CLAUDECODE": "1"])

    try expectUnchanged(sbd, before)
    _ = try end(sbd, c)
    #expect(try !listed(sbd).contains(c.id), "the same command from a terminal did not end it")
  }

  /// The session whose Claude pane runs the command.
  enum PaneOwner: CaseIterable { case target, anotherConversation, work }

  /// A process in a Claude pane that unsets both variables still runs under that pane. When the target runs it on
  /// itself, its turn runs too, so the refusal must not be the turn's.
  @Test(arguments: PaneOwner.allCases) func aCommandInAClaudePaneWithBothVariablesUnsetIsRefused(_ owner: PaneOwner)
    throws
  {
    let sbd = try Instance()
    let target = try conversation(sbd)
    let pane: SessionSummary
    switch owner {
    case .target: pane = target
    case .anotherConversation: pane = try conversation(sbd, "Another conversation")
    case .work: pane = try sbd.idleSession(name: "work")
    }
    let sb = shellQuote("\(Instance.bin)/sb")
    try sbd.writeScript("endother", "env -u SB_SESSION_ID -u CLAUDECODE \(sb) manager end \(shellQuote(target.id))")
    // A tick installs a snapshot that holds the pane.
    try sbd.advanceClock(1)

    try sbd.sb("send", pane.id, "run endother")
    let r = try sbd.scriptResult("endother")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(!r.stderr.contains("is in a turn"), Comment(rawValue: r.stderr))
    #expect(try listed(sbd).contains(target.id))
    try sbd.waitFor(pane.id, "the end of the turn that ran the script", timeout: 30) {
      $0.lastReply == "Ran endother."
    }
    _ = try end(sbd, target)
    #expect(try !listed(sbd).contains(target.id), "the same command from a terminal did not end it")
  }

  // MARK: A turn or a background job (Decision 6)

  enum Busy: CaseIterable { case turn, backgroundJob }

  @Test(arguments: Busy.allCases) func aBusyConversationIsRefusedWithTheStopHint(_ busy: Busy) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    switch busy {
    case .turn:
      try sbd.sb("send", c.id, "slow 30")
      try sbd.waitFor(c.id, "the slow turn") { $0.state == .working }
    case .backgroundJob:
      try sbd.sb("send", c.id, "background 100 held")
      try sbd.waitFor(c.id, "the background job") {
        $0.lastReply == "Started a job of 100 s." && $0.reason.contains("background job")
      }
    }
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains("\(c.name) is in a turn"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains("sb stop"), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  // MARK: Only a Manager conversation or a group chat

  enum NotAConversation: CaseIterable { case theOperator, work }

  @Test(arguments: NotAConversation.allCases) func aSessionThatIsNotAConversationIsRefused(_ kind: NotAConversation)
    throws
  {
    let sbd = try Instance()
    let s: SessionSummary
    switch kind {
    case .theOperator: s = try operatorHelpers.idleOperator(sbd)
    case .work: s = try sbd.idleSession(name: "work")
    }

    let refused = try refusedEnd(sbd, s)

    #expect(refused.stderr.contains("no Manager conversation \(s.id)"), Comment(rawValue: refused.stderr))
    #expect(try sbd.client.sessions().map(\.id).contains(s.id))
  }

  // MARK: Open to-dos

  @Test func anOpenToDoRefusesTheEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let todo = try sbd.addTodo(c.id, "tell Alex in #flags that the fix shipped")
    let before = try sbd.get(c.id)

    let refused = try refusedEnd(sbd, c)

    #expect(refused.stderr.contains(todo.id), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
    #expect(try sbd.isOpenTodo(c.id, todo.id))
  }

  /// The app's delete names every open to-do in `resolve` and sends no `new`.
  @Test func aFullResolveEndsTheConversationAndRecordsEachTodo() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let first = try sbd.addTodo(c.id, "tell Alex in #flags that the fix shipped")
    let second = try sbd.addTodo(c.id, "bump the SDK")

    let answer = try sbd.client.call(
      "manager-end",
      ["session": .string(c.id), "drop": [], "resolve": .array([.string(first.id), .string(second.id)])])

    #expect(answer["ended"]?.string == c.id, "\(answer.text)")
    #expect(answer["started"] == nil, "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
    #expect(try !sbd.client.sessions().map(\.id).contains(c.id))
    let resolved = try sbd.resolvedTodoIds()
    #expect(resolved.contains(first.id), "\(resolved)")
    #expect(resolved.contains(second.id), "\(resolved)")
  }

  // MARK: --new (Decision 3)

  /// The MCP servers of the conversation that ends.
  enum Servers: CaseIterable { case switchboardOnly, named, fullSetup }

  @Test(arguments: Servers.allCases) func newCarriesTheServersOver(_ servers: Servers) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conversation(sbd)
    let expected: [String]?
    switch servers {
    case .switchboardOnly: expected = []
    case .named:
      try conversationHelpers.changeServers(sbd, c, "add", "grafana")
      expected = ["grafana"]
    case .fullSetup:
      try conversationHelpers.changeServers(sbd, c, "--all")
      expected = nil
    }
    try #require(try conversationHelpers.mcpAnswer(sbd, c).servers == expected)

    let fresh = try started(try end(sbd, c, ["--new"]))

    #expect(try conversationHelpers.mcpAnswer(sbd, sbd.get(fresh)).servers == expected)
  }

  @Test func newCarriesTheAccountOverAndNotTheDefault() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let c = try conversation(sbd)
    try #require(c.account == sbd.account("A"))
    try sbd.sb("account", "use", "B", "--new-only")
    try #require(try conversationHelpers.newConversation(sbd, name: "Control").account == sbd.account("B"))

    let fresh = try started(try end(sbd, c, ["--new"]))

    #expect(try sbd.get(fresh).account == sbd.account("A"))
  }

  @Test(arguments: [true, false]) func newCarriesThePinOver(_ pinned: Bool) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    if pinned { try sbd.sb("manager", "pin", c.id) }

    let fresh = try started(try end(sbd, c, ["--new"]))

    let isPinned = try sbd.get(fresh).pinned == true
    #expect(isPinned == pinned)
  }

  @Test func newStartsAnUntitledConversationThatBareManagerOpens() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let fresh = try started(try end(sbd, c, ["--new"]))

    let s = try sbd.get(fresh)
    #expect(s.kind == .manager)
    #expect(s.name == Manager.untitled)
    #expect(try listed(sbd) == [fresh])
    #expect(try decode(SessionSummary.self, sbd.sb("manager", "--json")).id == fresh)
  }

  /// The app sends `new` to replace the conversation. The replacement opens on Claude's terminal alone, even after
  /// the app and `sb open` ask for its terminals.
  @Test func theConversationThatEndReplacesStartsWithTheShellClosed() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let answer = try sbd.client.call("manager-end", ["session": .string(c.id), "new": true])

    #expect(answer["started"]?["shellClosed"] == true, "\(answer.text)")
    try sbd.expectShellAbsent(try started(answer))
  }

  @Test func newWithANameNamesTheNewConversation() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let fresh = try started(try end(sbd, c, ["--new", "--name", "Next steps"]))

    #expect(try sbd.get(fresh).name == "Next steps")
  }

  @Test func theTextAnswerOfNewNamesTheNewConversation() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let out = try sbd.sb("manager", "end", c.id, "--new")

    let fresh = try #require(try listed(sbd).first)
    #expect(out.contains("Started \(Manager.untitled) (\(fresh))"), "\(out)")
  }

  /// The app sends `drop` with the ids its confirmation listed and `new` set.
  @Test func theAppsRequestWithDropAndNewEndsAndStartsOne() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let wait = try typedWait(sbd, c)

    let answer = try sbd.client.call(
      "manager-end", ["session": .string(c.id), "drop": .array([.string(wait)]), "new": true])

    #expect(strings(answer["dropped"]) == [wait], "\(answer.text)")
    let fresh = try started(answer)
    #expect(try listed(sbd) == [fresh])
  }

  /// The app reads `drop` from sbd's summary, so the summary carries every id that sbd's guard refuses on.
  @Test func theAppsDropFromSbdsSummaryEndsAConversationWithEveryKindOfOwnItem() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    _ = try typedWait(sbd, c)
    _ = try scheduleId(sbd, c)
    _ = try paused(sbd, c, ["--until", "2h"])
    let drop = try sbd.get(c.id).ownItems.map(\.id)
    try #require(drop.count == 3, "\(drop)")

    let answer = try sbd.client.call(
      "manager-end", ["session": .string(c.id), "drop": .array(drop.map(JSON.string)), "new": true])

    #expect(Set(strings(answer["dropped"])) == Set(drop), "\(answer.text)")
    #expect(try !listed(sbd).contains(c.id))
  }

  // MARK: sb rm on a conversation (Decision 8)

  @Test func rmRefusesAConversationWithAnOwnWaitAndNamesSbManagerEnd() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let wait = try typedWait(sbd, c)
    let before = try sbd.get(c.id)

    let refused = try sbd.run(["rm", c.id])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("sb manager end"), Comment(rawValue: refused.stderr))
    #expect(refused.stderr.contains(wait), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  @Test func rmRefusesAConversationWithASchedule() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let schedule = try scheduleId(sbd, c)
    let before = try sbd.get(c.id)

    let refused = try sbd.run(["rm", c.id])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains(schedule), Comment(rawValue: refused.stderr))
    try expectUnchanged(sbd, before)
  }

  @Test func rmStillRemovesAConversationWithNothingOfItsOwn() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    try sbd.sb("rm", c.id)

    #expect(try !listed(sbd).contains(c.id))
  }

  @Test func rmRemovesAConversationWhoseOnlyWaitsWereHandedOff() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let handed = try handedWait(sbd, c, ["--kind", "date", "--until", "1h"])

    try sbd.sb("rm", c.id)

    #expect(try !listed(sbd).contains(c.id))
    #expect(try handoff.theOperator(sbd).waits.map(\.id) == [handed])
  }

  /// What stays on the conversation and blocks both paths.
  enum Own: CaseIterable { case claudesWait, typedWait, schedule, pauseCondition }

  @Test(arguments: Own.allCases) func rmAndManagerEndGiveTheSameRefusal(_ own: Own) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let id: String
    switch own {
    case .claudesWait: id = try stayingWait(sbd, c, ["--kind", "ci"])
    case .typedWait: id = try typedWait(sbd, c)
    case .schedule: id = try scheduleId(sbd, c)
    case .pauseCondition: id = try #require(try paused(sbd, c, ["--until", "2h"]).pause?.until?.id)
    }

    let viaRm = failure(sbd, "rm", ["session": .string(c.id)])
    let viaEnd = failure(sbd, "manager-end", ["session": .string(c.id)])

    #expect(viaRm.contains(id), Comment(rawValue: viaRm))
    #expect(viaEnd == viaRm)
    #expect(try listed(sbd).contains(c.id))
  }
}
