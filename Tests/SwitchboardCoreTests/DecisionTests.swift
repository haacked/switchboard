import Foundation
import Testing

@testable import SwitchboardCore

/// Three decisions with every field written out, as a cleaned card stores
/// them: one with a recommended option, one without a recommendation, and
/// one multi-select decision.
let threeDecisions: JSON = [
  [
    "number": 1, "header": "Database", "question": "Which database should sbd use?",
    "context": "Postgres is already in use.", "multiSelect": false,
    "options": [
      ["label": "Postgres", "detail": "Already in use", "recommended": true],
      ["label": "SQLite", "recommended": false],
    ],
  ],
  [
    "number": 2, "header": "Name", "question": "What should the new note be called?", "multiSelect": false,
    "options": [["label": "to-do", "recommended": false], ["label": "follow-up note", "recommended": false]],
  ],
  [
    "number": 3, "header": "Icons", "question": "Which tiles show the icon?", "multiSelect": true,
    "options": [
      ["label": "Plain notes", "recommended": false], ["label": "Follow-ups", "recommended": false],
      ["label": "Groups", "recommended": false],
    ],
  ],
]

/// A summary of a turn whose reply asks for the three decisions.
let decisionSummaryJSON: JSON = [
  "title": "Answer three design choices", "kind": "decision",
  "summary": "It planned the storage.\nIt needs three decisions.", "options": [], "callouts": [],
  "decisions": threeDecisions,
]

/// The `decisions_opened` event that the first answer records.
func decisionsOpened(_ id: Int64, t: Int64 = 200, ref: String, decisions: JSON = threeDecisions) -> Event {
  Event(id: id, session: "s1", t: t, kind: "decisions_opened", data: ["decisions": decisions, "ref": .string(ref)])
}

/// A `decision_answered` event. `answer` holds one of `labels`, `text`, or `skip`.
func decisionAnswered(_ id: Int64, t: Int64 = 210, _ number: Int, _ answer: [String: JSON]) -> Event {
  var data = answer
  data["number"] = .number(Double(number))
  return Event(id: id, session: "s1", t: t, kind: "decision_answered", data: .object(data))
}

/// A decision with `count` options, where the options at `recommended` are recommended.
private func decision(_ number: Int, options count: Int, recommended: Set<Int> = [0]) -> JSON {
  [
    "number": .number(Double(number)), "header": .string("Decision \(number)"),
    "question": .string("Pick one for \(number)?"),
    "options": .array(
      (0..<count).map { ["label": .string("Option \($0 + 1)"), "recommended": .bool(recommended.contains($0))] }),
  ]
}

/// A card that a session writes with `sb summary set`, with the decisions.
private func cardWith(_ decisions: [JSON]) -> JSON {
  ["summary": "It planned the storage.\nIt needs some decisions.", "decisions": .array(decisions)]
}

/// The events of a turn that ended in prose, followed by the card with the
/// decisions that the session wrote for it. Its item's ref is `summary:3`.
private func decisionTurn() -> [Event] {
  [
    Event(id: 1, session: "s1", t: 0, kind: "UserPromptSubmit", data: ["prompt": "plan it"]),
    stop(2, 10, "I planned the storage. I need three decisions from you."),
    Event(id: 3, session: "s1", t: 20, kind: Triage.sessionEvent, data: decisionSummaryJSON),
  ]
}

private func shownVerdict(_ f: SessionFacts) -> Verdict {
  Attention.shown(Attention.evaluate(session(), f, now: 1000), f)
}

private func decisionsEnvelope(_ payload: JSON) -> String {
  JSON.object(["is_error": false, "result": .string(payload.text), "structured_output": payload]).text
}

/// The recorded Haiku-shaped answer for the reply in `decisions.md`.
private func recordedDecisionsAnswer() throws -> JSON {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/replies")
  let text = try String(contentsOf: dir.appendingPathComponent("decisions.summary.json"), encoding: .utf8)
  return try #require(JSON.parse(text))
}

// MARK: The decisions field

@Suite struct DecisionFieldTests {
  @Test func aSummaryAndAnItemWrittenWithoutDecisionsReadWithNone() throws {
    let summary = try JSONCoding.decode(
      TriageSummary.self, from: #"{"title": "Pick", "kind": "decision", "summary": "It asks."}"#)
    let item = try JSONCoding.decode(
      TriageItem.self,
      from:
        #"{"title": "Pick", "kind": "decision", "summary": "It asks.", "options": [], "callouts": [], "source": "summary", "ref": "stop:2"}"#
    )

    #expect(summary.decisions.isEmpty)
    #expect(item.decisions.isEmpty)
  }

  @Test func cleaningKeepsEachFieldOfAValidDecision() throws {
    let result = try TriageCard.clean(cardWith(threeDecisions.array ?? []))

    let decisions = result.card.decisions
    #expect(result.dropped.isEmpty)
    #expect(decisions.map(\.number) == [1, 2, 3])
    #expect(decisions.map(\.header) == ["Database", "Name", "Icons"])
    #expect(decisions[0].question == "Which database should sbd use?")
    #expect(decisions[0].context == "Postgres is already in use.")
    #expect(decisions[0].options.map(\.label) == ["Postgres", "SQLite"])
    #expect(decisions[0].options.map(\.detail) == ["Already in use", nil])
    #expect(decisions[0].options.map(\.recommended) == [true, false])
    #expect(decisions.map(\.multiSelect) == [false, false, true])
  }

  @Test(arguments: [2, 5])
  func cleaningKeepsADecisionWithTwoToFiveOptions(_ count: Int) throws {
    let result = try TriageCard.clean(cardWith([decision(1, options: count), decision(2, options: 2)]))

    #expect(result.card.decisions.map(\.options.count) == [count, 2])
    #expect(result.dropped.isEmpty)
  }

  /// Each broken decision sits between two valid ones, which stay.
  @Test(arguments: [
    ("no options", decision(2, options: 0, recommended: [])),
    ("one option", decision(2, options: 1)),
    ("six options", decision(2, options: 6)),
    ("two recommended options", decision(2, options: 3, recommended: [0, 1])),
  ])
  func cleaningDropsADecisionThatBreaksARuleAndSaysWhy(_ name: String, _ broken: JSON) throws {
    let result = try TriageCard.clean(cardWith([decision(1, options: 2), broken, decision(3, options: 2)]))

    #expect(result.card.decisions.map(\.number) == [1, 3], "\(name)")
    #expect(result.dropped.count == 1, "\(name): \(result.dropped)")
  }

  enum Field: String, CaseIterable, Sendable {
    case header, question, context, label, detail

    var limit: Int {
      switch self {
      case .header: 24
      case .question: 200
      case .context: 1_000
      case .label: 80
      case .detail: 200
      }
    }

    func read(_ d: PendingDecision) -> String? {
      switch self {
      case .header: d.header
      case .question: d.question
      case .context: d.context
      case .label: d.options.first?.label
      case .detail: d.options.first?.detail
      }
    }
  }

  @Test(arguments: Field.allCases)
  func cleaningCutsAFieldToItsLength(_ field: Field) throws {
    let long = JSON.string(String(repeating: "x", count: field.limit + 50))
    var raw: [String: JSON] = [
      "number": 1, "header": "Name", "question": "What should it be called?",
      "options": [["label": "to-do", "detail": "sb note --todo"], ["label": "follow-up note"]],
    ]
    switch field {
    case .header, .question, .context: raw[field.rawValue] = long
    case .label, .detail:
      raw["options"] = [
        ["label": field == .label ? long : "to-do", "detail": field == .detail ? long : "short"], ["label": "b"],
      ]
    }

    let result = try TriageCard.clean(cardWith([.object(raw), decision(2, options: 2)]))

    #expect(result.card.decisions.map(\.number) == [1, 2])
    #expect(result.dropped.isEmpty)
    let kept = try #require(result.card.decisions.first)
    let value = try #require(field.read(kept))
    #expect(!value.isEmpty)
    #expect(value.count <= field.limit)
  }

  @Test func cleaningKeepsAtMostTheMostDecisionsTheSummaryLists() throws {
    let many = (1...(TriageSummarizer.maxDecisions + 1)).map { decision($0, options: 2) }

    let result = try TriageCard.clean(cardWith(many))

    #expect(result.card.decisions.map(\.number) == Array(1...TriageSummarizer.maxDecisions))
    #expect(result.dropped.contains { $0.contains("after the first \(TriageSummarizer.maxDecisions)") })
  }

  @Test func summaryHelpDocumentsTheDecisionsField() {
    #expect(TriageCard.instructions.contains("decisions"))
  }

  @Test func theNudgeAsksForSeveralDecisionsThroughSummarySet() {
    let prompt = Config().triage.systemPrompt

    #expect(prompt.contains("sb summary set"))
    #expect(prompt.contains("decisions"))
  }
}

// MARK: The summarizer

@Suite struct DecisionSummarizerTests {
  /// Design A test 12.
  @Test func parsesTheRecordedAnswerForTheDecisionsReplyIntoSixDecisions() throws {
    let summary = try TriageSummarizer.parse(decisionsEnvelope(try recordedDecisionsAnswer()))

    let recommended = summary.decisions.map { $0.options.filter(\.recommended).map(\.label) }
    #expect(summary.decisions.map(\.number) == [1, 2, 3, 4, 5, 6])
    #expect(
      recommended == [
        ["Yes"], ["to-do"], ["A new table in sbd's database"], ["Refuse them for now"], ["Yes, dimmed"], ["No"],
      ])
  }

  @Test func theSchemaHasADecisionsArray() {
    #expect(TriageSummarizer.schema["properties"]?["decisions"]?["type"]?.string == "array")
  }

  @Test func theSystemPromptDescribesTheDecisionsField() {
    #expect(TriageSummarizer.system.contains("- decisions:"))
  }

  /// A long reply lists its decisions near the top.
  @Test func theInputKeepsTheStartOfAReplyOfSixThousandCharacters() {
    let s = SessionSummary(
      id: "s1", name: "review-code", cwd: "/", repo: nil, branch: nil, claudeSessionId: "u", state: .needsYou,
      reason: "read its last reply and decide what's next", since: 0, lastActivity: 0, live: true, claudePid: nil,
      attached: false, lastReply: nil, waits: [], notes: [])
    let reply = "1. FIRST DECISION?\n" + String(repeating: "a", count: 6_000)

    let input = TriageSummarizer.input(session: s, reply: reply)

    #expect(input.contains("1. FIRST DECISION?"))
  }
}

// MARK: The decision list

@Suite struct DecisionListTests {
  /// Design A test 3. Each kind applies after the events that come before it.
  @Test(arguments: ["decisions_opened", "decision_answered", "decisions_submitted", "decisions_discarded"])
  func aDecisionEventLeavesTheVerdictAndTheItemRef(_ kind: String) throws {
    let base = facts(decisionTurn())
    var opened = base
    opened.apply(decisionsOpened(4, ref: "summary:3"))
    try #require(opened.decisionList != nil, "the facts ignore decisions_opened")
    let chain: [Event] =
      switch kind {
      case "decisions_opened": [decisionsOpened(4, ref: "summary:3")]
      case "decision_answered":
        [decisionsOpened(4, ref: "summary:3"), decisionAnswered(5, 1, ["skip": true])]
      case "decisions_submitted":
        [
          decisionsOpened(4, ref: "summary:3"), decisionAnswered(5, 1, ["skip": true]),
          Event(id: 6, session: "s1", t: 220, kind: kind, data: ["message": "My decisions"]),
        ]
      default: [decisionsOpened(4, ref: "summary:3"), Event(id: 5, session: "s1", t: 220, kind: kind)]
      }
    var after = base
    for e in chain { after.apply(e) }

    #expect(shownVerdict(after) == shownVerdict(base))
    #expect(item(after)?.ref == item(base)?.ref)
  }

  @Test func openingKeepsACopyOfTheDecisionsAndTheOriginRef() {
    let f = facts(decisionTurn() + [decisionsOpened(4, ref: "summary:3")])

    #expect(f.decisionList?.decisions.map(\.header) == ["Database", "Name", "Icons"])
    #expect(f.decisionList?.ref == "summary:3")
  }

  @Test func aPromptAfterTheListOpenedMakesItStale() {
    var f = facts(decisionTurn() + [decisionsOpened(4, ref: "summary:3")])
    let before = f.decisionList?.stale

    f.apply(Event(id: 5, session: "s1", t: 300, kind: "UserPromptSubmit", data: ["prompt": "go on"]))

    #expect(before == false)
    #expect(f.decisionList?.stale == true)
  }

  @Test(arguments: ["decisions_submitted", "decisions_discarded"])
  func submittingOrDiscardingClosesTheList(_ kind: String) throws {
    var f = facts(decisionTurn() + [decisionsOpened(4, ref: "summary:3")])
    try #require(f.decisionList != nil)

    f.apply(
      Event(id: 5, session: "s1", t: 300, kind: kind, data: kind == "decisions_submitted" ? ["message": "x"] : [:]))

    #expect(f.decisionList == nil)
  }

  /// A later turn's card has its own decisions. The item keeps the stored copy, so the answers stay with it.
  @Test func theItemKeepsTheOpenListsDecisionsAfterALaterCard() {
    var later = decisionSummaryJSON.object ?? [:]
    later["decisions"] = [decision(1, options: 2), decision(2, options: 2)]
    let f = facts(
      decisionTurn() + [
        decisionsOpened(4, ref: "summary:3"),
        Event(id: 5, session: "s1", t: 300, kind: "UserPromptSubmit", data: ["prompt": "go on"]),
        stop(6, 310, "I planned more."),
        Event(id: 7, session: "s1", t: 320, kind: Triage.sessionEvent, data: .object(later)),
      ])

    #expect(item(f)?.decisions.map(\.header) == ["Database", "Name", "Icons"])
  }
}

// MARK: The message that Submit sends

@Suite struct DecisionMessageTests {
  /// The message of a list whose decisions have the answers. A decision
  /// without an answer here is skipped.
  func message(_ answers: [Int: [[String: JSON]]]) throws -> String {
    var f = facts(decisionTurn() + [decisionsOpened(4, ref: "summary:3")])
    var id: Int64 = 5
    for number in 1...3 {
      for answer in answers[number] ?? [["skip": true]] {
        f.apply(decisionAnswered(id, t: 200 + id, number, answer))
        id += 1
      }
    }
    return try #require(f.decisionList?.message)
  }

  /// Design A test 5: one message, a lead line, then one line per decision in order.
  @Test func theMessageHasALeadLineAndOneLinePerDecisionInOrder() throws {
    let text = try message([1: [["labels": ["Postgres"]]], 2: [["text": "Call it task"]], 3: [["skip": true]]])

    let lines = text.components(separatedBy: "\n")
    #expect(lines.count == 4, "\(text)")
    #expect(lines.first == "My decisions on the 3 questions in your last reply:")
    #expect(lines.dropFirst().map { String($0.prefix(3)) } == ["1. ", "2. ", "3. "])
  }

  struct AnswerCase: Sendable, CustomTestStringConvertible {
    var name: String
    var number: Int
    var answers: [[String: JSON]]
    var contains: String
    var lacks: String?
    var testDescription: String { name }
  }

  @Test(arguments: [
    AnswerCase(
      name: "the recommended option", number: 1, answers: [["labels": ["Postgres"]]],
      contains: "Postgres (your recommendation).", lacks: nil),
    AnswerCase(
      name: "an option that isn't recommended", number: 2, answers: [["labels": ["to-do"]]], contains: "to-do.",
      lacks: "recommendation"),
    AnswerCase(
      name: "typed text after an option", number: 1,
      answers: [["labels": ["Postgres"]], ["text": "Use SQLite, and keep a dump."]],
      contains: "Use SQLite, and keep a dump.", lacks: "Postgres"),
    AnswerCase(
      name: "a skip", number: 2, answers: [["skip": true]],
      contains: "Not decided. Don't act on it yet. Ask me again later.", lacks: nil),
    AnswerCase(
      name: "several picks of a multi-select decision", number: 3,
      answers: [["labels": ["Plain notes", "Groups"]]], contains: "Plain notes, Groups", lacks: nil),
  ])
  func eachAnswerIsSpelledOutOnItsDecisionsLine(_ c: AnswerCase) throws {
    let text = try message([c.number: c.answers])

    let line = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("\(c.number). ") }, "\(text)")
    #expect(line.contains(c.contains), "\(line)")
    if let lacks = c.lacks { #expect(!line.contains(lacks), "\(line)") }
  }
}
