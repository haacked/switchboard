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

    for (number, key) in [("0", "1"), ("4", "1"), ("1", "3"), ("1", "MySQL")] {
      let r = try sbd.run(["decide", s.id, number, key])
      #expect(r.status != 0, "decision \(number), option \(key)")
    }

    #expect(try sbd.count("decision_answered", of: s.id) == 0)
    try sbd.sb("decide", s.id, "1", "Postgres")
    #expect(try sbd.count("decision_answered", of: s.id) == 1)
  }

  @Test(arguments: [0, 1])
  func theFirstAnswerRefusesAnItemWithFewerThanTwoDecisions(_ count: Int) throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, decisionCard(Array(["Database"].prefix(count))))
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
