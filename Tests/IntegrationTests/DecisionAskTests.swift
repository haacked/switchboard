import Foundation
import SwitchboardCore
import Testing

/// The question that the tests ask about decision 2 of the three-decision card, whose header is "Name".
private let askText = "why not B?"

/// The message that sbd sends the session for a question about one decision. The message names the decision by
/// its number and header only.
func clarifyingMessage(_ number: Int, _ header: String, _ text: String) -> String {
  DecisionAsk.message(about: PendingDecision(number: number, header: header, question: "", options: []), text)
}

/// The stub answers a prompt that matches none of its commands with "Done: <prompt>".
private let stubReply = "Done: " + clarifyingMessage(2, "Name", askText)

/// The reply that a test reports as the clarifying turn's Stop when it plays the turn's hooks itself.
private let clarifyingAnswer = "B would break the public API, so I left it out."

/// The last line of every question's message, which shows that the stub read the whole paste.
private let messageEnd = "I'll send all my decisions together when I'm done."

/// What the Inbox shows for a session. A clarifying turn changes none of it.
private struct Shown: Equatable, CustomStringConvertible {
  var state: AttentionState
  var reason: String
  var since: Int64
  var ref: String?

  var description: String { "\(state.rawValue) \"\(reason)\" since \(since) ref \(ref ?? "nil")" }
}

extension Instance {
  /// Runs `sb decide <id> --ask <number> <question>` with the extra arguments, whatever its exit status.
  fileprivate func runAsk(
    _ id: String, _ number: String = "2", _ question: String = askText, more: [String] = [],
    env: [String: String] = [:]
  ) throws -> CommandResult {
    try run(["decide", id, "--ask", number, question] + more, env: env, timeout: 30)
  }

  /// Asks about decision 2, waits for the session's reply, and returns what `--json` printed.
  fileprivate func ask(_ id: String) throws -> JSON {
    let r = try runAsk(id, more: ["--timeout", "20", "--json"])
    guard r.status == 0 else { throw TestError(description: "sb decide --ask failed: \(text(r))") }
    return try #require(JSON.parse(r.stdout), "not JSON: \(r.stdout)")
  }

  /// Asks about decision 2 with `--no-wait` and returns the ask id that `--json` printed.
  @discardableResult
  fileprivate func askNoWait(_ id: String, _ number: String = "2", _ question: String = askText) throws -> String {
    let r = try runAsk(id, number, question, more: ["--no-wait", "--json"])
    guard r.status == 0 else { throw TestError(description: "sb decide --ask --no-wait failed: \(text(r))") }
    return try #require(JSON.parse(r.stdout)?["askId"]?.string, "no askId: \(r.stdout)")
  }

  /// Sends `decision-ask` with the ref that the caller saw.
  @discardableResult
  fileprivate func askOp(_ id: String, ref: String, number: Int = 2, text: String = askText) throws -> JSON {
    try client.call(
      "decision-ask",
      ["session": .string(id), "ref": .string(ref), "number": .number(Double(number)), "text": .string(text)])
  }

  /// The messages that sbd sent the session for questions about decisions.
  fileprivate func questions(_ id: String) throws -> [String] {
    try sentTexts(id).filter { $0.hasPrefix("Question about decision") }
  }

  fileprivate func exchanges(_ id: String) throws -> [DecisionExchange] { try decisionList(id).exchanges }

  /// The message of the newest `decision_asked` event.
  fileprivate func askedMessage(_ id: String) throws -> String {
    try #require(try events(id, kind: "decision_asked").last?.data["message"]?.string, "no decision_asked")
  }

  fileprivate func shown(_ id: String) throws -> Shown {
    let s = try JSONCoding.decode(SessionSummary.self, from: try sb("get", "--json", id))
    return Shown(state: s.state, reason: s.reason, since: s.since, ref: s.triage?.ref)
  }

  /// Makes the stub wait before it reports each prompt it reads, until the test writes `report`.
  fileprivate func holdPrompts() {
    FileManager.default.createFile(atPath: "\(home.path)/hold", contents: nil)
  }

  /// Waits until the stub has read the whole message of the `count`th question.
  fileprivate func waitForQuestionPaste(count: Int = 1) throws {
    try waitFor("the question's paste") { stubInputCount(messageEnd) >= count }
  }

  /// Reports the asked message as claude's prompt, which starts the clarifying turn. The stub holds the pasted
  /// message, so this is the only prompt that sbd sees. A test that calls this never writes `report`, because the
  /// stub would then report the same prompt again, and that prompt would close the ask and make the list stale.
  fileprivate func startClarifyingTurn(_ id: String) throws {
    try waitForQuestionPaste()
    try postHook(id, "UserPromptSubmit", ["prompt": .string(try askedMessage(id))])
  }

  /// Ends the clarifying turn that `startClarifyingTurn` started with a Stop that carries `reply`.
  fileprivate func stopClarifyingTurn(_ id: String, reply: String = clarifyingAnswer) throws {
    try postHook(id, "Stop", ["last_assistant_message": .string(reply)])
  }

  /// Asks a question of another session with the three decisions. A test whose session refuses every ask calls this
  /// first, so its refusal shows that sbd takes asks and refused for the session's own reason.
  fileprivate func expectAnotherSessionTakesAnAsk() throws {
    let other = try new(prompt: "hello", name: "other")
    try waitFor(other.id, "the other session's summary") { $0.triage?.source == .summary }
    try setSummary(other.id, threeDecisionCard)
    try waitFor(other.id, "the other session's card") { $0.triage?.decisions.count == 3 }
    try askNoWait(other.id)
    #expect(try count("decision_asked", of: other.id) == 1)
  }

  /// Waits until no exchange of the session's list is pending.
  @discardableResult
  fileprivate func waitForClosedAsk(_ id: String) throws -> [DecisionExchange] {
    try waitFor(
      "the ask to close", fetch: { try exchanges(id) },
      until: { !$0.isEmpty && !$0.contains(where: \.pending) })
  }
}

/// How a clarifying turn ends without its Stop.
enum ClarifyEnd: String, CaseIterable, CustomStringConvertible {
  case idlePrompt
  case stopFailure
  /// The session's claude exits. A SIGKILL ends it with no hook, so sbd learns it from the pane.
  case exit

  var description: String { rawValue }

  func run(_ sbd: Instance, _ id: String) throws {
    switch self {
    case .idlePrompt:
      try sbd.postHook(
        id, "Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
    case .stopFailure:
      try sbd.postHook(id, "StopFailure", ["error": "rate_limit"])
    case .exit:
      let pid = try #require(try sbd.get(id).claudePid, "claude has no pid")
      kill(pid_t(pid), SIGKILL)
      try sbd.waitFor(id, "claude to exit") { !$0.live }
    }
  }
}

/// Where `--ask` runs inside Claude Code.
enum InsideClaudeCode: String, CaseIterable, CustomStringConvertible {
  /// Any Claude Code session.
  case claudeCode
  /// The session that the question is for.
  case ownSession

  var description: String { rawValue }

  func env(_ sbd: Instance, _ id: String) -> [String: String] {
    switch self {
    case .claudeCode: ["CLAUDECODE": "1"]
    case .ownSession: ["SB_SESSION_ID": id, "CLAUDECODE": "1"]
    }
  }
}

/// `sb decide --ask` sends the session a question about one decision, and files the turn's reply under that
/// decision without changing what the Inbox shows for the session.
@Suite(.blocking(timeLimit: .seconds(120))) struct DecideAskTests {
  // MARK: The reply

  @Test func askPrintsTheSessionsReplyAsJSON() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    let out = try sbd.ask(s.id)

    #expect(out["reply"]?.string == stubReply, "\(out.text)")
    #expect(out["askId"]?.string?.isEmpty == false, "\(out.text)")
  }

  @Test func askPrintsTheSessionsReply() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    let r = try sbd.runAsk(s.id, more: ["--timeout", "20"])

    #expect(r.status == 0, "\(text(r))")
    #expect(r.stdout.contains("Done: Question about decision 2 (Name)"), "\(r.stdout)")
  }

  /// Test 5, through sbd: the reply is filed under the decision asked about and nowhere else.
  @Test func theReplyIsFiledUnderTheDecisionAskedAbout() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    let out = try sbd.ask(s.id)

    let exchanges = try sbd.exchanges(s.id)
    #expect(exchanges.map(\.number) == [2])
    let exchange = try #require(exchanges.first)
    #expect(exchange.askId == out["askId"]?.string)
    #expect(exchange.text == askText)
    #expect(exchange.reply == stubReply)
    #expect(exchange.error == nil)
    #expect(!exchange.pending)
    #expect(try sbd.decisionListJSON(s.id)["exchanges"]?.array?.count == 1)
  }

  /// A second ask, after the first clarifying turn ended, goes out, files its reply under its own decision, and keeps
  /// the hold that the first ask started.
  @Test func aSecondAskAfterTheFirstReplyIsFiledUnderItsDecision() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let before = try sbd.shown(s.id)
    let question = "why not every tile?"

    let first = try sbd.ask(s.id)
    #expect(try sbd.shown(s.id) == before, "after the first reply")
    let r = try sbd.runAsk(s.id, "3", question, more: ["--timeout", "20", "--json"])

    #expect(r.status == 0, "\(text(r))")
    let second = try #require(JSON.parse(r.stdout), "not JSON: \(r.stdout)")
    #expect(second["reply"]?.string == "Done: " + clarifyingMessage(3, "Icons", question), "\(second.text)")
    let exchanges = try sbd.exchanges(s.id)
    #expect(exchanges.map(\.askId) == [first["askId"]?.string, second["askId"]?.string].compactMap { $0 })
    #expect(exchanges.map(\.number) == [2, 3])
    #expect(exchanges.map(\.reply) == [stubReply, "Done: " + clarifyingMessage(3, "Icons", question)])
    #expect(exchanges.map(\.pending) == [false, false])
    #expect(try sbd.decisionListJSON(s.id)["exchanges"]?.array?.count == 2)
    #expect(try sbd.questions(s.id).count == 2)
    #expect(try sbd.shown(s.id) == before, "after the second reply")
  }

  @Test func decidePrintsTheQuestionUnderItsDecision() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    _ = try sbd.ask(s.id)

    let out = try sbd.sb("decide", s.id)

    let two = try #require(out.range(of: "2. Name:"), "\(out)")
    let three = try #require(out.range(of: "3. Icons:"), "\(out)")
    let question = try #require(out.range(of: askText), "\(out)")
    #expect(two.upperBound <= question.lowerBound && question.upperBound <= three.lowerBound, "\(out)")
    #expect(out.contains("Done: Question about decision 2 (Name)"), "\(out)")
  }

  @Test func noWaitPrintsTheAskIdAsJSON() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    sbd.holdPrompts()

    let askId = try sbd.askNoWait(s.id)

    #expect(try sbd.events(s.id, kind: "decision_asked").last?.data["askId"]?.string == askId)
    #expect(try sbd.exchanges(s.id).map(\.askId) == [askId])
    #expect(try sbd.exchanges(s.id).first?.pending == true)
  }

  @Test func noWaitPrintsTheAskId() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    sbd.holdPrompts()

    let r = try sbd.runAsk(s.id, more: ["--no-wait"])

    #expect(r.status == 0, "\(text(r))")
    let askId = try #require(try sbd.events(s.id, kind: "decision_asked").last?.data["askId"]?.string)
    #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == askId)
  }

  /// A question to a session is the user's to ask, so a session can't ask one.
  @Test(arguments: InsideClaudeCode.allCases)
  func askRefusesInsideClaudeCode(_ inside: InsideClaudeCode) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    let r = try sbd.runAsk(s.id, more: ["--no-wait"], env: inside.env(sbd, s.id))

    #expect(r.status != 0, "\(text(r))")
    #expect(try sbd.count("decision_asked", of: s.id) == 0)
    #expect(try sbd.questions(s.id).isEmpty)
    try sbd.askNoWait(s.id)
    #expect(try sbd.count("decision_asked", of: s.id) == 1)
  }

  // MARK: The message

  @Test func theMessageNamesTheDecisionAndAsksForAnAnswerOnly() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    _ = try sbd.ask(s.id)

    let expected = clarifyingMessage(2, "Name", askText)
    let sent = try sbd.events(s.id, kind: "sent").filter { $0.data["text"]?.string?.hasPrefix("Question") == true }
    #expect(sent.count == 1)
    #expect(sent.first?.data["text"]?.string == expected)
    #expect(sent.first?.data["by"]?.string == "sbd")
    #expect(try sbd.askedMessage(s.id) == expected)
  }

  /// The session sees the message as its prompt, which is what starts the clarifying turn.
  @Test func theSessionGetsTheMessageAsItsPrompt() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    _ = try sbd.ask(s.id)

    let prompt = try sbd.events(s.id, kind: "UserPromptSubmit").last?.data["prompt"]?.string
    #expect(prompt == clarifyingMessage(2, "Name", askText))
  }

  // MARK: The hold

  /// The success criterion: `sb get` shows the same state, reason, ref, and `since` before the ask, while its
  /// message is on its way, during the clarifying turn, and after its Stop.
  @Test func theSessionKeepsWhatItShowedThroughTheClarifyingTurn() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let before = try sbd.shown(s.id)
    try #require(before.state == .needsYou, "the card's item reads \(before)")
    sbd.holdPrompts()

    try sbd.askNoWait(s.id)
    #expect(try sbd.shown(s.id) == before, "after the ask")
    try sbd.waitForQuestionPaste()
    #expect(try sbd.shown(s.id) == before, "while the question is on its way")
    try sbd.startClarifyingTurn(s.id)
    #expect(try sbd.shown(s.id) == before, "during the clarifying turn")
    try sbd.stopClarifyingTurn(s.id)
    try sbd.waitForClosedAsk(s.id)

    #expect(try sbd.shown(s.id) == before, "after the clarifying Stop")
    #expect(try sbd.exchanges(s.id).first?.reply == clarifyingAnswer)
  }

  /// Test 6, through sbd: after the clarifying Stop the item is the one the user asked from, with no newer
  /// decisions and no summary of the reply. A later turn's summary shows that the test waited long enough to see
  /// a summary of the clarifying reply.
  @Test func theClarifyingReplyGetsNoSummaryAndNoNewItem() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let item = try #require(s.triage)
    let calls = sbd.summaryCalls().count

    _ = try sbd.ask(s.id)

    let after = try sbd.get(s.id)
    #expect(after.triage?.ref == item.ref)
    #expect(after.triage?.source == .session)
    #expect(after.triage?.title == item.title)
    #expect(after.decisions?.newer.isEmpty == true)
    try sbd.sb("send", s.id, "hello again")
    try sbd.waitFor("the later turn's summary") { sbd.summaryCalls().count > calls }
    usleep(500_000)
    #expect(sbd.summaryCalls().count == calls + 1)
    let input = (try? String(contentsOfFile: "\(sbd.home.path)/summary-input.txt", encoding: .utf8)) ?? ""
    #expect(input.contains("hello again"), "\(input)")
  }

  /// Test 2, through sbd: a parent's digest names its child once for needing you, and the child's clarifying turn
  /// adds nothing to the parent's next digest.
  @Test func aParentsDigestLeavesOutAChildsClarifyingTurn() throws {
    let sbd = try Instance()
    let digest = DigestTests()
    let p = try digest.parent(sbd, .work)
    let kid = try digest.child(sbd, of: p, name: "kid", prompt: "one")
    try sbd.waitFor(kid.id, "the kid's summary") { $0.triage?.source == .summary }
    try sbd.setSummary(kid.id, threeDecisionCard)
    try sbd.waitFor(kid.id, "the kid's card") { $0.triage?.source == .session && $0.triage?.decisions.count == 3 }
    try digest.prompt(sbd, p, "first")
    #expect(digest.contexts(sbd, p).contains { $0.contains(kid.id) }, "the parent never heard the kid need you")
    let heard = digest.contexts(sbd, p).count

    _ = try sbd.ask(kid.id)
    try digest.prompt(sbd, p, "after the question")

    let told = Array(digest.contexts(sbd, p).dropFirst(heard))
    #expect(!told.contains { $0.contains(kid.id) }, "\(told)")
    #expect(try sbd.sbdMessages(p.id).isEmpty)
  }

  // MARK: Opening the list

  /// Test 10. The clarifying prompt drops the live item, so the ask opens the list from the item before it sends.
  @Test func theFirstAskOpensTheListBeforeItSends() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let item = try #require(s.triage)
    try #require(try sbd.count("decisions_opened", of: s.id) == 0)

    _ = try sbd.ask(s.id)

    let events = try sbd.events(s.id)
    let opened = try #require(events.firstIndex { $0.kind == "decisions_opened" }, "no decisions_opened")
    let asked = try #require(events.firstIndex { $0.kind == "decision_asked" }, "no decision_asked")
    let sent = try #require(
      events.firstIndex { $0.kind == "sent" && $0.data["text"]?.string?.hasPrefix("Question") == true }, "no send")
    #expect(opened < asked)
    #expect(opened < sent)
    #expect(try sbd.count("decisions_opened", of: s.id) == 1)
    let list = try sbd.decisionList(s.id)
    #expect(list.ref == item.ref)
    #expect(list.decisions == item.decisions)
    #expect(try sbd.get(s.id).decisions?.decisions.map(\.header) == threeHeaders)
  }

  // MARK: Summary cards

  /// Test 7. The session's card would replace the item that the user asked from.
  @Test func summarySetRefusesDuringAClarifyingTurnAndWorksAfterItsStop() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let card = JSON.object([
      "summary": "It answered.\nIt needs a call.", "options": [["label": "Go"], ["label": "Wait"]],
    ]).text
    sbd.holdPrompts()
    try sbd.askNoWait(s.id)
    try sbd.startClarifyingTurn(s.id)

    let refused = try sbd.setSummary([s.id], card)

    #expect(refused.status != 0, "\(text(refused))")
    #expect(
      refused.stderr.contains(
        "This turn answers a question about decision 2. Switchboard did not save a summary card. Reply in text, and Switchboard shows your reply under that decision."
      ), "\(refused.stderr)")
    try sbd.stopClarifyingTurn(s.id)
    try sbd.waitForClosedAsk(s.id)
    let accepted = try sbd.setSummary([s.id], card)
    #expect(accepted.status == 0, "\(text(accepted))")
  }

  // MARK: A clarifying turn without its Stop

  /// Test 8's sbd cases. Claude Code may end the clarifying turn without a Stop. sbd closes the ask with an error,
  /// so the pending-ask refusals don't block Submit.
  @Test(arguments: ClarifyEnd.allCases)
  func aClarifyingTurnThatEndsWithoutAStopClosesTheAskWithAnError(_ end: ClarifyEnd) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    sbd.holdPrompts()
    let waiting = Outcome.detached { try sbd.runAsk(s.id, more: ["--timeout", "20"]) }
    try sbd.waitFor("the ask") { try sbd.count("decision_asked", of: s.id) == 1 }
    try sbd.startClarifyingTurn(s.id)
    try #require(try sbd.exchanges(s.id).first?.pending == true)

    try end.run(sbd, s.id)

    let exchange = try #require(try sbd.waitForClosedAsk(s.id).first)
    let error = try #require(exchange.error, "the ask closed without an error")
    #expect(!error.isEmpty)
    #expect(exchange.reply == nil)
    try #require(waiting.done.wait(timeout: .now() + 40) == .success, "sb decide --ask is still waiting")
    let asked = try #require(try waiting.result?.get())
    #expect(asked.status != 0, "\(text(asked))")
    #expect(asked.stderr.contains("got no answer: \(error)"), "\(asked.stderr)")
    let submit = try sbd.run(["decide", s.id, "--submit"], timeout: 30)
    #expect(submit.status == 0, "\(text(submit))")
    #expect(try sbd.count("decisions_submitted", of: s.id) == 1)
  }

  /// Claude exits after the question's paste and before its prompt, so the question never reached the session. The
  /// ask closes with an error, and the list takes answers again.
  @Test func anExitBeforeTheQuestionsPromptClosesTheAsk() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    sbd.holdPrompts()
    try sbd.askNoWait(s.id)
    try sbd.waitForQuestionPaste()
    try #require(try sbd.count("UserPromptSubmit", of: s.id) == 1)

    try ClarifyEnd.exit.run(sbd, s.id)

    let exchange = try #require(try sbd.waitForClosedAsk(s.id).first)
    #expect(exchange.error == "The question never reached the session. Ask again.")
    #expect(try sbd.count("UserPromptSubmit", of: s.id) == 1)
    try sbd.sb("decide", s.id, "2", "--skip")
    #expect(try sbd.decisionList(s.id).answer(2)?.skip == true)
  }

  /// With claude stopped and its folder gone, the send can't start claude. The ask then leaves nothing pending, so
  /// the list takes answers again.
  @Test func aFailedSendLeavesNoPendingAsk() throws {
    let sbd = try Instance()
    try sbd.expectAnotherSessionTakesAnAsk()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop") { !$0.live }
    try FileManager.default.removeItem(atPath: s.cwd)

    let r = try sbd.runAsk(s.id, more: ["--timeout", "20"])

    #expect(r.status != 0, "\(text(r))")
    #expect(try !sbd.exchanges(s.id).contains(where: \.pending))
    try sbd.sb("decide", s.id, "2", "--skip")
    #expect(try sbd.decisionList(s.id).answer(2)?.skip == true)
  }
}

/// The guards on an ask: it names the list the user saw, the list is open and fresh, the session is idle, and only
/// one ask is pending. Each refusal sends nothing.
@Suite(.blocking(timeLimit: .seconds(120))) struct DecideAskGuardTests {
  /// Checks that nothing was asked: no `decision_asked`, no question sent, and no exchange.
  private func expectNothingAsked(_ sbd: Instance, _ id: String, sourceLocation: SourceLocation = #_sourceLocation)
    throws
  {
    #expect(try sbd.count("decision_asked", of: id) == 0, sourceLocation: sourceLocation)
    #expect(try sbd.questions(id).isEmpty, sourceLocation: sourceLocation)
    #expect(try sbd.get(id).decisions?.exchanges.isEmpty ?? true, sourceLocation: sourceLocation)
  }

  /// Expects both ways of asking to refuse: the `decision-ask` request that the app sends with the ref the user
  /// saw, and `sb decide --ask`, which can check the list it fetched before it asks sbd. Each refusal holds
  /// `message` when it is given.
  private func expectAskRefused(
    _ sbd: Instance, _ id: String, number: Int = 2, question: String = askText, message: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let ref = try (try? sbd.decisionList(id).ref) ?? sbd.get(id).triage?.ref ?? ""
    let refused = failure(
      sbd, "decision-ask",
      ["session": .string(id), "ref": .string(ref), "number": .number(Double(number)), "text": .string(question)])
    #expect(refused != "no error", "decision-ask was accepted", sourceLocation: sourceLocation)
    let r = try sbd.runAsk(id, String(number), question, more: ["--no-wait"])
    #expect(r.status != 0, "sb decide --ask was accepted: \(text(r))", sourceLocation: sourceLocation)
    guard let message else { return }
    #expect(refused.contains(message), "decision-ask: \(refused)", sourceLocation: sourceLocation)
    #expect(r.stderr.contains(message), "sb decide --ask: \(r.stderr)", sourceLocation: sourceLocation)
  }

  // MARK: The ref

  /// The ask with the list's ref shows that the refusal came from the ref.
  @Test(arguments: ["", "summary:no-such-item"])
  func anAskRefusesARefThatIsNotTheOpenLists(_ ref: String) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    let listRef = try sbd.decisionList(s.id).ref

    #expect(throws: (any Error).self) { try sbd.askOp(s.id, ref: ref) }

    try expectNothingAsked(sbd, s.id)
    try sbd.askOp(s.id, ref: listRef)
    #expect(try sbd.count("decision_asked", of: s.id) == 1)
  }

  /// Before the list is open, the ref must be the current item's.
  @Test(arguments: OtherRef.allCases)
  func theFirstAskRefusesARefThatIsNotTheCurrentItems(_ other: OtherRef) throws {
    let sbd = try Instance()
    let (s, earlier) = try sbd.sessionWithAChangedItem()
    let current = try #require(s.triage?.ref)

    #expect(throws: (any Error).self) { try sbd.askOp(s.id, ref: other.ref(earlier: earlier)) }

    try expectNothingAsked(sbd, s.id)
    #expect(try sbd.count("decisions_opened", of: s.id) == 0)
    try sbd.askOp(s.id, ref: current)
    #expect(try sbd.count("decision_asked", of: s.id) == 1)
    #expect(try sbd.decisionList(s.id).decisions.map(\.header) == ["Retries", "Timeouts"])
  }

  // MARK: The list

  @Test func anAskRefusesAStaleList() throws {
    let sbd = try Instance()
    try sbd.expectAnotherSessionTakesAnAsk()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    try sbd.sb("send", s.id, "hello again")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello again" }
    try #require(try sbd.decisionList(s.id).stale)

    try expectAskRefused(sbd, s.id)

    try expectNothingAsked(sbd, s.id)
  }

  /// The stub holds the submit's prompt, so the item keeps the sent decisions.
  @Test func anAskRefusesASentList() throws {
    let sbd = try Instance()
    try sbd.expectAnotherSessionTakesAnAsk()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    sbd.holdPrompts()
    try sbd.sb("decide", s.id, "--submit")
    try #require(try sbd.get(s.id).decisionsSent == true)

    try expectAskRefused(sbd, s.id)

    let r = try sbd.runAsk(s.id, more: ["--no-wait"])
    #expect(r.stderr.contains("already got your answers to these decisions"), "\(r.stderr)")
    try expectNothingAsked(sbd, s.id)
  }

  /// An item with no decision list has nothing to ask about.
  @Test func anAskRefusesAnItemWithoutADecisionList() throws {
    let sbd = try Instance()
    try sbd.expectAnotherSessionTakesAnAsk()
    let s = try sbd.endedSession()

    try expectAskRefused(sbd, s.id, message: "decision")

    #expect(try sbd.count("decisions_opened", of: s.id) == 0)
    try expectNothingAsked(sbd, s.id)
  }

  // MARK: The question

  /// The ask about decision 2 shows that the refusals came from the numbers.
  @Test(arguments: [0, 4, -1])
  func anAskRefusesANumberThatTheListDoesNotHave(_ number: Int) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    try expectAskRefused(sbd, s.id, number: number)

    try expectNothingAsked(sbd, s.id)
    try sbd.askNoWait(s.id)
    #expect(try sbd.count("decision_asked", of: s.id) == 1)
  }

  @Test(arguments: ["", "   ", " \n\t "])
  func anAskRefusesEmptyText(_ question: String) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    try expectAskRefused(sbd, s.id, question: question)

    try expectNothingAsked(sbd, s.id)
    try sbd.askNoWait(s.id)
    #expect(try sbd.count("decision_asked", of: s.id) == 1)
  }

  // MARK: The session

  /// sbd holds a PermissionRequest hook until the card is answered, so the hook goes on a thread of its own. No
  /// prompt comes with it, so the list stays fresh.
  @Test func anAskRefusesWhileACardIsHeld() throws {
    let sbd = try Instance()
    try sbd.expectAnotherSessionTakesAnAsk()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    let payload: JSON = [
      "hook_event_name": "PermissionRequest", "session_id": .string(s.claudeSessionId), "permission_mode": "default",
      "cwd": .string(s.cwd), "tool_name": "Bash", "tool_input": ["command": "touch held"],
    ]
    let client = sbd.client
    _ = Outcome.detached {
      try client.call("hook", ["session": .string(s.id), "payload": payload], timeout: 600)
    }
    try sbd.waitFor(s.id, "the held card") { !$0.cards.isEmpty }
    try #require(try !sbd.decisionList(s.id).stale)

    try expectAskRefused(sbd, s.id, message: "\(s.name) waits on a card. Answer it before you ask")

    try expectNothingAsked(sbd, s.id)
  }

  /// A PreToolUse with no prompt runs a turn and leaves the list fresh.
  @Test func anAskRefusesWhileATurnRuns() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    try sbd.postHook(
      s.id, "PreToolUse", ["tool_name": "Read", "tool_use_id": "toolu_read", "tool_input": ["file_path": "/a"]])
    try sbd.waitFor(s.id, "the turn") { $0.state == .working }
    try #require(try !sbd.decisionList(s.id).stale)

    try expectAskRefused(sbd, s.id, message: "\(s.name) is working; ask when it stops")

    try expectNothingAsked(sbd, s.id)
  }

  /// The stub holds each prompt it reads, so the list stays fresh while the message is on its way.
  @Test(arguments: [1, 2])
  func anAskRefusesWhileAMessageIsOnItsWayOrQueued(_ messages: Int) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    sbd.holdPrompts()
    for i in 1...messages { try sbd.sb("send", s.id, "hello \(i)") }
    if messages > 1 {
      try #require(try sbd.events(s.id, kind: "sent").last?.data["delivery"]?.string == "queued")
    }
    try #require(try !sbd.decisionList(s.id).stale)

    try expectAskRefused(sbd, s.id, message: "\(s.name) is working; ask when it stops")

    try expectNothingAsked(sbd, s.id)
  }

  @Test func anAskRefusesAPausedSession() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)
    try #require(try !sbd.decisionList(s.id).stale)

    try expectAskRefused(sbd, s.id, message: "Resume \(s.name) first")

    try expectNothingAsked(sbd, s.id)
  }

  /// Only one clarifying turn can be matched to its reply.
  @Test func aSecondAskWhileOneIsPendingIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    sbd.holdPrompts()
    try sbd.askNoWait(s.id)

    try expectAskRefused(
      sbd, s.id, number: 3, question: "why not every tile?",
      message: "\(s.name) is still answering your question about decision 2")

    #expect(try sbd.count("decision_asked", of: s.id) == 1)
    #expect(try sbd.questions(s.id).count == 1)
    #expect(try sbd.exchanges(s.id).map(\.number) == [2])
  }

  // MARK: Changes to the list while an ask is pending

  /// Test 11. Each change is refused while the question is on its way and during its turn, and works after the
  /// turn's Stop.
  @Test(arguments: ListChange.allCases)
  func aPendingAskRefusesEveryChangeToTheListUntilItsStop(_ change: ListChange) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    let answered = try sbd.count("decision_answered", of: s.id)
    sbd.holdPrompts()
    try sbd.askNoWait(s.id)
    try sbd.waitForQuestionPaste()
    let refusal = "Wait for the answer to your question about decision 2"

    let onItsWay = try sbd.run(["decide", s.id] + change.args)
    try sbd.startClarifyingTurn(s.id)
    let during = try sbd.run(["decide", s.id] + change.args)

    for (when, r) in [("on its way", onItsWay), ("during the turn", during)] {
      #expect(r.status != 0, "the \(change) \(when) was accepted: \(r.stdout)")
      #expect(r.stderr.contains(refusal), "the \(change) \(when): \(r.stderr)")
    }
    #expect(try sbd.count("decision_answered", of: s.id) == answered)
    #expect(try sbd.count("decisions_submitted", of: s.id) == 0)
    #expect(try sbd.count("decisions_discarded", of: s.id) == 0)
    try sbd.stopClarifyingTurn(s.id)
    try sbd.waitForClosedAsk(s.id)
    let after = try sbd.run(["decide", s.id] + change.args, timeout: 30)
    #expect(after.status == 0, "the \(change) after the Stop: \(text(after))")
  }

  /// sbd refuses to send to a session that is being deleted before the send's block runs. Once the removal is
  /// cancelled, the list takes answers and asks again.
  @Test(arguments: ["submit", "ask"])
  func aSendThatADeletionRefusedLeavesTheListOpenToChanges(_ op: String) throws {
    let sbd = try longUndoInstance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    try sbd.holdForRemoval(s.id)

    let refused = try sbd.run(
      ["decide", s.id] + (op == "submit" ? ["--submit"] : ["--ask", "2", askText, "--no-wait"]))

    #expect(refused.status != 0, "\(text(refused))")
    #expect(refused.stderr.contains("\(s.id) is being deleted"), "\(refused.stderr)")
    #expect(cancelled(try sbd.cancelRemoval([s.id])) == [s.id])
    try sbd.sb("decide", s.id, "2", "--text", "Call it job")
    #expect(try sbd.decisionList(s.id).answer(2)?.text == "Call it job")
    try sbd.askNoWait(s.id)
    #expect(try sbd.count("decision_asked", of: s.id) == 1)
  }

  // MARK: Restart and removal

  /// Test 12. An answered exchange replays from the events and from a snapshot.
  @Test(arguments: [SubmitRestart.events, .snapshot])
  func anAnsweredExchangeSurvivesARestart(_ restart: SubmitRestart) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    _ = try sbd.ask(s.id)
    let before = try sbd.exchanges(s.id)
    try #require(before.count == 1 && before.first?.reply != nil)

    try restart.run(sbd)

    #expect(try sbd.exchanges(s.id) == before)
  }

  /// Test 12. A pending exchange replays as pending, and the hold keeps what the session showed.
  @Test(arguments: [SubmitRestart.events, .snapshot])
  func aPendingExchangeSurvivesARestart(_ restart: SubmitRestart) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let shown = try sbd.shown(s.id)
    sbd.holdPrompts()
    try sbd.askNoWait(s.id)
    try sbd.startClarifyingTurn(s.id)
    let before = try sbd.exchanges(s.id)
    try #require(before.count == 1 && before.first?.pending == true)

    try restart.run(sbd)

    #expect(try sbd.exchanges(s.id) == before)
    #expect(try sbd.shown(s.id).ref == shown.ref)
  }

  /// Test 12. `sb rm` drops the session's exchanges, answered and pending, with its events.
  @Test func removingTheSessionDropsItsExchanges() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    _ = try sbd.ask(s.id)
    sbd.holdPrompts()
    try sbd.askNoWait(s.id, "3", "why not every tile?")
    try #require(try sbd.exchanges(s.id).map(\.pending) == [false, true])

    try sbd.sb("rm", s.id)

    #expect(try sbd.run(["decide", "--json", s.id]).status != 0)
    sbd.stopSbd()
    let r = try runCommand(
      "/usr/bin/sqlite3",
      [sbd.home.database, "SELECT COUNT(*) FROM events WHERE session = '\(s.id)' AND kind LIKE 'decision%'"])
    #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "\(text(r))")
    try sbd.startSbd()
    #expect(try sbd.run(["decide", "--json", s.id]).status != 0)
  }
}
