import Foundation
import SwitchboardCore
import Testing

/// The recorded Haiku-shaped answer for the reply in `decisions.md`, with its six decisions.
let decisionsSummaryAnswer = Instance.root.appendingPathComponent(
  "Tests/SwitchboardCoreTests/Fixtures/replies/decisions.summary.json"
).path

/// Three decisions as a session writes them with `sb summary set`: one with
/// a recommended option, one without, and one multi-select decision.
private let threeDecisionCard = """
  {
    "title": "Answer three design choices",
    "summary": "It planned the storage.\\nIt needs three decisions.",
    "decisions": [
      {"number": 1, "header": "Database", "question": "Which database should sbd use?",
       "context": "Postgres is already in use.",
       "options": [{"label": "Postgres", "detail": "Already in use", "recommended": true}, {"label": "SQLite"}]},
      {"number": 2, "header": "Name", "question": "What should the new note be called?",
       "options": [{"label": "to-do"}, {"label": "follow-up note"}]},
      {"number": 3, "header": "Icons", "question": "Which tiles show the icon?", "multiSelect": true,
       "options": [{"label": "Plain notes"}, {"label": "Follow-ups"}, {"label": "Groups"}]}
    ]
  }
  """

private let threeHeaders = ["Database", "Name", "Icons"]

/// A card with one yes-or-no decision for each header.
private func decisionCard(_ headers: [String]) -> String {
  let decisions = headers.enumerated().map { i, header -> JSON in
    [
      "number": .number(Double(i + 1)), "header": .string(header), "question": .string("Change \(header)?"),
      "options": [["label": "Yes", "recommended": true], ["label": "No"]],
    ]
  }
  return JSON.object(["summary": "It planned it.\nIt needs some decisions.", "decisions": .array(decisions)]).text
}

/// The list's JSON without the fields that a later turn changes.
private func withoutStaleAndNewer(_ list: JSON) -> JSON {
  .object((list.object ?? [:]).filter { $0.key != "stale" && $0.key != "newer" })
}

extension Instance {
  /// A session whose ended turn has the card with the three decisions.
  func decisionSession() throws -> SessionSummary {
    let s = try endedSession()
    try setSummary(s.id, threeDecisionCard)
    return try waitFor(s.id, "the card's decisions") {
      $0.triage?.source == .session && $0.triage?.decisions.count == 3
    }
  }

  func decisionList(_ id: String) throws -> DecisionList {
    try JSONCoding.decode(DecisionList.self, from: try sb("decide", "--json", id))
  }

  func decisionListJSON(_ id: String) throws -> JSON {
    try #require(JSON.parse(try sb("decide", "--json", id)))
  }

  /// Answers the three decisions: the recommended option by number, typed text, and a skip.
  func answerThreeDecisions(_ id: String) throws {
    try sb("decide", id, "1", "1")
    try sb("decide", id, "2", "--text", "Call it task")
    try sb("decide", id, "3", "--skip")
  }

  /// The messages that a submit sent to the session.
  func decisionMessages(_ id: String) throws -> [String] {
    try sentTexts(id).filter { $0.hasPrefix("My decisions") }
  }
}

/// `sb decide` answers the decisions in a session's last reply one at a time
/// and sends them back in one message.
@Suite(.blocking(timeLimit: .seconds(120))) struct DecideTests {
  // MARK: The decisions on the item

  @Test func summarySetShowsTheDecisionsOnTheItem() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()

    try sbd.setSummary(s.id, threeDecisionCard)

    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }
    let row = try #require(JSON.parse(try sbd.sb("get", "--json", s.id)))
    let decisions = try #require(row["triage"]?["decisions"]?.array)
    #expect(decisions.compactMap { $0["header"]?.string } == threeHeaders)
    #expect(decisions.first?["options"]?.array?.compactMap { $0["recommended"]?.bool } == [true, false])
    #expect(decisions.last?["multiSelect"]?.bool == true)
  }

  /// Design A test 12, through sbd: the model's summary of the reply carries its decisions to the item.
  @Test func theSummaryOfTheDecisionsReplyListsItsSixDecisions() throws {
    let sbd = try Instance()
    try FileManager.default.copyItem(atPath: decisionsReply, toPath: "\(sbd.home.path)/decisions.md")
    try FileManager.default.copyItem(atPath: decisionsSummaryAnswer, toPath: "\(sbd.home.path)/summary-answer.json")

    let s = try sbd.new(prompt: "reply decisions")

    let item = try #require(try sbd.waitFor(s.id, "the summary") { $0.triage?.source == .summary }.triage)
    #expect(item.decisions.map(\.number) == [1, 2, 3, 4, 5, 6])
    #expect(item.decisions[1].options.filter(\.recommended).map(\.label) == ["to-do"])
  }

  // MARK: Answering

  @Test func theFirstAnswerOpensTheListFromTheCurrentItemOnce() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let item = try #require(s.triage)

    try sbd.sb("decide", s.id, "1", "1")
    try sbd.sb("decide", s.id, "2", "to-do")

    let list = try sbd.decisionList(s.id)
    #expect(list.ref == item.ref)
    #expect(list.decisions == item.decisions)
    #expect(try sbd.count("decisions_opened", of: s.id) == 1)
    #expect(try sbd.count("decision_answered", of: s.id) == 2)
    #expect(try sbd.get(s.id).triage?.ref == item.ref)
  }

  /// The last answer shows that the refusals came from the keys, not from a missing command.
  @Test func refusesAnAnswerThatTheListDoesNotHave() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    for (number, key) in [("0", "1"), ("4", "1"), ("1", "3"), ("1", "MySQL"), ("1", "1,2")] {
      let r = try sbd.run(["decide", s.id, number, key])
      #expect(r.status != 0, "decision \(number), option \(key)")
    }
    // An answer gives exactly one of an option, --text, and --skip.
    for answer in [["1", "1", "--skip"], ["1"], ["1", "--text", "  "]] {
      let r = try sbd.run(["decide", s.id] + answer)
      #expect(r.status != 0, "decide \(answer)")
    }

    #expect(try sbd.count("decision_answered", of: s.id) == 0)
    try sbd.sb("decide", s.id, "1", "Postgres")
    #expect(try sbd.count("decision_answered", of: s.id) == 1)
  }

  /// A pick-any decision takes several options by number or label, and keeps them in the options' order.
  @Test func aPickAnyDecisionTakesOptionsSeparatedByCommas() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    try sbd.sb("decide", s.id, "3", "Groups, 1")

    #expect(try sbd.decisionList(s.id).answer(3)?.labels == ["Plain notes", "Groups"])
  }

  @Test func theFirstAnswerRefusesAnItemWithoutDecisions() throws {
    try expectTheFirstAnswerRefused(decisionCard([]))
  }

  /// A lone decision becomes the card's options, so the item has no decision list.
  @Test func theFirstAnswerRefusesAnItemWhoseLoneDecisionBecameOptions() throws {
    try expectTheFirstAnswerRefused(decisionCard(["Database"]))
  }

  private func expectTheFirstAnswerRefused(_ card: String) throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, card)
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let r = try sbd.run(["decide", s.id, "1", "1"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("decision"), "\(r.stderr)")
    #expect(try sbd.count("decisions_opened", of: s.id) == 0)
  }

  @Test func decidePrintsEachQuestionAndItsAnswer() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)

    let out = try sbd.sb("decide", s.id)

    for text in [
      "Which database should sbd use?", "What should the new note be called?", "Which tiles show the icon?",
      "Postgres", "Call it task",
    ] {
      #expect(out.contains(text), "missing \(text): \(out)")
    }
  }

  /// Design A test 7. sbd rebuilds the list from the events, then from a snapshot.
  @Test func answersSurviveARestart() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    let before = try sbd.decisionList(s.id)

    try sbd.restart(setting: "snapshotEvery", to: 0)
    let replayed = try sbd.decisionList(s.id)
    try sbd.restart(setting: "snapshotEvery", to: 500)
    try sbd.restart(setting: "snapshotEvery", to: 500)
    let restored = try sbd.decisionList(s.id)

    #expect(replayed == before)
    #expect(restored == before)
  }

  // MARK: Submitting

  /// Design A test 5, through sbd and the session.
  @Test func submitSendsOneMessageInDecisionOrderAndTheSessionReceivesIt() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)

    try sbd.sb("decide", s.id, "--submit")

    let messages = try sbd.decisionMessages(s.id)
    #expect(messages.count == 1)
    let lines = messages.first?.components(separatedBy: "\n") ?? []
    #expect(lines.first == "My decisions on the 3 questions in your last reply:")
    #expect(lines.dropFirst().map { String($0.prefix(3)) } == ["1. ", "2. ", "3. "])
    #expect(lines.count == 4 && lines[1].contains("Postgres (your recommendation)."))
    #expect(lines.count == 4 && lines[2].contains("Call it task"))
    #expect(lines.count == 4 && lines[3].contains("Not decided. Don't act on it yet. Ask me again later."))
    try sbd.waitFor(s.id, "the reply to the decisions") { $0.lastReply?.hasPrefix("Done: My decisions") == true }
    #expect(try sbd.events(s.id).last { $0.kind == "decisions_submitted" }?.data["message"]?.string == messages.first)
    #expect(try sbd.get(s.id).decisions == nil)
  }

  /// The submit after the last answer shows that the refusal came from the unanswered decision.
  @Test func submitRefusesWhileADecisionIsUnanswered() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    try sbd.sb("decide", s.id, "2", "--skip")

    let r = try sbd.run(["decide", s.id, "--submit"])

    #expect(r.status != 0)
    #expect(try sbd.decisionMessages(s.id).isEmpty)
    #expect(try sbd.count("decisions_submitted", of: s.id) == 0)
    try sbd.sb("decide", s.id, "3", "--skip")
    try sbd.sb("decide", s.id, "--submit")
    #expect(try sbd.decisionMessages(s.id).count == 1)
  }

  /// Design A test 4. Every decision has an answer, so only the turn can refuse the submit.
  @Test func aTurnAfterTheListOpenedMakesItStaleAndSubmitNeedsStale() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)

    try sbd.sb("send", s.id, "hello again")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello again" }

    #expect(try sbd.decisionList(s.id).stale)
    let r = try sbd.run(["decide", s.id, "--submit"])
    #expect(r.status != 0)
    #expect(try sbd.decisionMessages(s.id).isEmpty)
    try sbd.sb("decide", s.id, "--submit", "--stale")
    #expect(try sbd.decisionMessages(s.id).count == 1)
  }

  /// Design A test 6. With claude stopped and its folder gone, the send can't start claude.
  @Test func aFailedSendLeavesTheListOpenWithEveryAnswer() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    let before = try sbd.decisionList(s.id)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop") { !$0.live }
    try FileManager.default.removeItem(atPath: s.cwd)

    let r = try sbd.run(["decide", s.id, "--submit"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("is gone"), "\(r.stderr)")
    #expect(try sbd.decisionList(s.id) == before)
    #expect(try sbd.count("decisions_submitted", of: s.id) == 0)
    #expect(try sbd.decisionMessages(s.id).isEmpty)
  }

  // MARK: A later turn and discarding

  /// Design A test 8. The later turn writes a card with other decisions.
  @Test func aNewListDoesNotReplaceAnOpenOne() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    let before = try sbd.decisionListJSON(s.id)
    try sbd.writeCard("c2", decisionCard(["Retries", "Timeouts"]))

    try sbd.sb("send", s.id, "card c2")
    try sbd.waitFor(s.id, "the second card") {
      $0.lastReply == "I wrote the card c2." && $0.triage?.source == .session
    }

    let after = try sbd.decisionListJSON(s.id)
    #expect(withoutStaleAndNewer(after) == withoutStaleAndNewer(before))
    #expect(after["newer"]?.array?.compactMap { $0["header"]?.string } == ["Retries", "Timeouts"])
    #expect(after["stale"]?.bool == true)
    #expect(try sbd.get(s.id).triage?.decisions.map(\.header) == threeHeaders)
    // An answer names the stored list. Decision 3 exists only there, and "Yes" is a label only on c2's decisions.
    let answered = try sbd.count("decision_answered", of: s.id)
    try sbd.sb("decide", s.id, "3", "Groups")
    #expect(try sbd.run(["decide", s.id, "1", "Yes"]).status != 0)
    #expect(try sbd.count("decision_answered", of: s.id) == answered + 1)
  }

  @Test func discardClosesTheListAndSendsNothing() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.sb("decide", s.id, "1", "1")
    try #require(try sbd.get(s.id).decisions != nil)

    try sbd.sb("decide", s.id, "--discard")

    #expect(try sbd.get(s.id).decisions == nil)
    #expect(try sbd.count("decisions_discarded", of: s.id) == 1)
    #expect(try sbd.decisionMessages(s.id).isEmpty)
  }
}

/// A ref that is not the session's current item's ref.
enum OtherRef: String, CaseIterable, CustomStringConvertible {
  /// The ref of the item that the session showed before its last turn.
  case earlierItem
  case empty
  case unknown

  var description: String { rawValue }

  func ref(earlier: String) -> String {
    switch self {
    case .earlierItem: earlier
    case .empty: ""
    case .unknown: "summary:no-such-item"
    }
  }
}

/// A request that changes the decision list.
enum ListChange: String, CaseIterable, CustomStringConvertible {
  case submit
  case answer
  case discard

  var description: String { rawValue }

  /// The `sb decide` arguments after the session.
  var args: [String] {
    switch self {
    case .submit: ["--submit"]
    case .answer: ["2", "--text", "Changed while sending"]
    case .discard: ["--discard"]
    }
  }
}

extension Instance {
  /// A session whose item changed from the three-decision card to a card
  /// with two other decisions while no list was open. Returns the session
  /// and the first item's ref.
  func sessionWithAChangedItem() throws -> (session: SessionSummary, earlier: String) {
    let s = try decisionSession()
    let earlier = try #require(s.triage?.ref)
    try writeCard("c2", decisionCard(["Retries", "Timeouts"]))
    try sb("send", s.id, "card c2")
    let changed = try waitFor(s.id, "the second card") {
      $0.lastReply == "I wrote the card c2." && $0.triage?.source == .session && $0.triage?.ref != earlier
    }
    try #require(changed.decisions == nil)
    return (changed, earlier)
  }

  /// Sends `decision-answer` for option 1 of decision 1 with the ref the caller saw.
  func answerFirstDecision(_ id: String, ref: String) throws -> JSON {
    try client.call(
      "decision-answer",
      ["session": .string(id), "number": 1, "options": ["1"], "ref": .string(ref)])
  }
}

/// The guards that the app depends on: an answer names the item the user saw,
/// and nothing changes the list while its submit is on its way.
@Suite(.blocking(timeLimit: .seconds(120))) struct DecideGuardTests {
  // MARK: The ref on the first answer

  /// The answer with the current ref shows that the refusal came from the ref.
  @Test(arguments: OtherRef.allCases)
  func theFirstAnswerRefusesARefThatIsNotTheCurrentItems(_ other: OtherRef) throws {
    let sbd = try Instance()
    let (s, earlier) = try sbd.sessionWithAChangedItem()
    let current = try #require(s.triage?.ref)

    #expect(throws: (any Error).self) { try sbd.answerFirstDecision(s.id, ref: other.ref(earlier: earlier)) }

    #expect(try sbd.count("decisions_opened", of: s.id) == 0)
    #expect(try sbd.count("decision_answered", of: s.id) == 0)
    #expect(try sbd.get(s.id).decisions == nil)
    let list = try JSONCoding.convert(try sbd.answerFirstDecision(s.id, ref: current), to: DecisionList.self)
    #expect(list.ref == current)
    #expect(list.decisions.map(\.header) == ["Retries", "Timeouts"])
  }

  /// Only the first answer compares the ref with the current item. Once the
  /// list is open, an answer with the list's own ref still lands after a
  /// later turn changed the item.
  @Test func anAnswerToAnOpenListTakesTheListsRefAfterTheItemChanged() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    let ref = try #require(s.triage?.ref)
    _ = try sbd.answerFirstDecision(s.id, ref: ref)
    try sbd.writeCard("c2", decisionCard(["Retries", "Timeouts"]))
    try sbd.sb("send", s.id, "card c2")
    try sbd.waitFor(s.id, "the second card") { $0.lastReply == "I wrote the card c2." }

    _ = try sbd.client.call(
      "decision-answer", ["session": .string(s.id), "number": 3, "options": ["Groups"], "ref": .string(ref)])

    #expect(try sbd.decisionList(s.id).answer(3)?.labels == ["Groups"])
  }

  /// The user saw the newer item, so the answer would land in a list they never saw.
  @Test func anAnswerToAnOpenListRefusesTheNewerItemsRef() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    _ = try sbd.answerFirstDecision(s.id, ref: try #require(s.triage?.ref))
    try sbd.writeCard("c2", decisionCard(["Retries", "Timeouts"]))
    try sbd.sb("send", s.id, "card c2")
    let changed = try sbd.waitFor(s.id, "the second card") { $0.lastReply == "I wrote the card c2." }
    let answered = try sbd.count("decision_answered", of: s.id)

    #expect(throws: (any Error).self) {
      try sbd.client.call(
        "decision-answer",
        ["session": .string(s.id), "number": 2, "skip": true, "ref": .string(try #require(changed.triage?.ref))])
    }

    #expect(try sbd.count("decision_answered", of: s.id) == answered)
    #expect(try sbd.decisionList(s.id).answer(2) == nil)
  }

  // MARK: A submit on its way

  /// The submit resumes a stopped claude, and sbd's send waits for the MCP
  /// server that the gate holds. The second request reaches sbd while the
  /// first submit waits there. Before the guard, a second submit also waits
  /// and then sends again, so it gets 5 s to come back with a refusal.
  @Test(arguments: ListChange.allCases)
  func aSubmitOnItsWayRefusesEveryOtherChangeToTheList(_ change: ListChange) throws {
    let gate = try MCPGate(open: true)
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", gate: gate)]])
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    let answered = try sbd.count("decision_answered", of: s.id)
    let slow = try sbd.waitForRunning("slow")
    try sbd.stopClaude(s.id)
    try sbd.restartServer(slow, behind: gate)

    let submit = Outcome.detached { try sbd.sb("decide", s.id, "--submit") }
    try gate.waitForRequest(sbd, submit)
    let other = Outcome.detached { try sbd.run(["decide", s.id] + change.args) }
    let returned = other.done.wait(timeout: .now() + 5) == .success
    _ = try gate.open(sbd, after: submit)
    if !returned { _ = other.done.wait(timeout: .now() + 30) }

    #expect(returned, "the \(change) waited for the submit's send instead of being refused")
    let r = try #require(try other.result?.get())
    #expect(r.status != 0, "the \(change) was accepted while the submit was on its way: \(r.stdout)")
    let messages = try sbd.decisionMessages(s.id)
    #expect(messages.count == 1)
    #expect(messages.first?.contains("Call it task") == true)
    #expect(try sbd.count("decisions_submitted", of: s.id) == 1)
    #expect(try sbd.count("decisions_discarded", of: s.id) == 0)
    #expect(try sbd.count("decision_answered", of: s.id) == answered)
    #expect(try sbd.get(s.id).decisions == nil)
  }

  // MARK: A submitted list

  /// The stub holds the submit's prompt, so the item keeps the sent decisions
  /// until the test writes `report`. The precondition shows that the refusal
  /// comes from the sent list and not from an item that already left.
  @Test(arguments: SubmitRestart.allCases)
  func aSubmittedListDoesNotOpenAgainBeforeThePromptLands(_ restart: SubmitRestart) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    FileManager.default.createFile(atPath: "\(sbd.home.path)/hold", contents: nil)
    try sbd.sb("decide", s.id, "--submit")
    try restart.run(sbd)

    let sent = try sbd.get(s.id)
    try #require(sent.triage?.ref == s.triage?.ref && sent.triage?.decisions.count == 3, "the prompt landed")
    #expect(sent.decisions == nil)
    #expect(sent.decisionsSent == true)
    for args in [[], ["1", "1"], ["2", "--skip"], ["--submit"], ["--submit", "--stale"], ["--discard"]] {
      let r = try sbd.run(["decide", s.id] + args)
      #expect(r.status != 0, "decide \(args) was accepted: \(r.stdout)")
      #expect(r.stderr.contains("already got your answers to these decisions"), "decide \(args): \(r.stderr)")
    }
    #expect(throws: (any Error).self) { try sbd.answerFirstDecision(s.id, ref: try #require(s.triage?.ref)) }
    #expect(try sbd.count("decisions_opened", of: s.id) == 1)
    #expect(try sbd.count("decisions_submitted", of: s.id) == 1)
    #expect(try sbd.decisionMessages(s.id).count == 1)

    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    // After the restart, the stub never reads the submit's message, so no reply comes. That is outside this test.
    guard restart == .none else { return }
    let replied = try sbd.waitFor(s.id, "the reply to the decisions") {
      $0.lastReply?.hasPrefix("Done: My decisions") == true
    }
    #expect(replied.decisionsSent == nil)
  }

  /// A stale submit sends the open list while a newer item has decisions of
  /// its own. Only the sent list's ref stays closed, so the newer list opens.
  @Test func aStaleSubmitLeavesTheNewerDecisionsOpenToAnswer() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    try sbd.writeCard("c2", decisionCard(["Retries", "Timeouts"]))
    try sbd.sb("send", s.id, "card c2")
    let newer = try sbd.waitFor(s.id, "the second card") {
      $0.lastReply == "I wrote the card c2." && $0.decisions?.newer.isEmpty == false
    }
    FileManager.default.createFile(atPath: "\(sbd.home.path)/hold", contents: nil)

    try sbd.sb("decide", s.id, "--submit", "--stale")

    let after = try sbd.get(s.id)
    try #require(after.triage?.ref == newer.triage?.ref, "the prompt landed")
    #expect(after.decisionsSent == nil)
    try sbd.sb("decide", s.id, "1", "Yes")
    #expect(try sbd.decisionList(s.id).decisions.map(\.header) == ["Retries", "Timeouts"])
    #expect(try sbd.count("decisions_opened", of: s.id) == 2)
    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
  }
}

/// How sbd comes back between a submit and the checks that follow it.
enum SubmitRestart: String, CaseIterable, CustomStringConvertible {
  case none
  /// sbd replays the session's events.
  case events
  /// sbd reads the session's facts from a snapshot.
  case snapshot

  var description: String { rawValue }

  func run(_ sbd: Instance) throws {
    switch self {
    case .none: break
    case .events: try sbd.restart(setting: "snapshotEvery", to: 0)
    case .snapshot:
      try sbd.restart(setting: "snapshotEvery", to: 500)
      try sbd.restart(setting: "snapshotEvery", to: 500)
    }
  }
}
