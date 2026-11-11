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

/// A decision whose options have the given labels.
private func decision(_ number: Int, labels: [String]) -> JSON {
  [
    "number": .number(Double(number)), "header": .string("Decision \(number)"),
    "question": .string("Pick one for \(number)?"), "options": .array(labels.map { ["label": .string($0)] }),
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
    ("a number that another decision has", decision(1, options: 2)),
    ("two labels that differ only in case", decision(2, labels: ["Yes", "yes"])),
    ("number 0", decision(0, options: 2)),
  ])
  func cleaningDropsADecisionThatBreaksARuleAndSaysWhy(_ name: String, _ broken: JSON) throws {
    let result = try TriageCard.clean(cardWith([decision(1, options: 2), broken, decision(3, options: 2)]))

    #expect(result.card.decisions.map(\.number) == [1, 3], "\(name)")
    #expect(result.dropped.count == 1, "\(name): \(result.dropped)")
  }

  /// One decision makes no list, so the card offers its options instead.
  @Test func cleaningTurnsALoneDecisionIntoTheCardsOptions() throws {
    let result = try TriageCard.clean(cardWith([decision(1, options: 2)]))

    #expect(result.card.decisions.isEmpty)
    #expect(result.card.options.map(\.label) == ["Option 1", "Option 2"])
    #expect(result.card.options.map(\.action) == [.send, .send])
    #expect(result.card.options.map(\.recommended) == [true, false])
    #expect(result.dropped.isEmpty)
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
    let summary = try TriageSummarizer.parse(decisionsEnvelope(try recordedDecisionsAnswer()), reply: "")

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

  /// A held prompt needs its own answer first, so its item keeps none of the open list's decisions.
  @Test func aHeldPromptsItemKeepsNoDecisions() {
    let f = facts(
      decisionTurn() + [
        decisionsOpened(4, ref: "summary:3"),
        Event(
          id: 5, session: "s1", t: 300, kind: "PermissionRequest",
          data: .object(tool("Bash", ["command": "rm -rf build"]))),
      ])

    #expect(item(f)?.source == .card)
    #expect(item(f)?.decisions.isEmpty == true)
    #expect(f.decisionList != nil)
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

// MARK: The delivery of a submit

/// The message that the submit in `submitted` sends.
private let submittedMessage = "My decisions on the 3 questions in your last reply:\n1. Postgres."

/// One event about a message on its way, with the message's text.
private func delivery(_ id: Int64, _ kind: String, _ text: String = submittedMessage) -> Event {
  Event(id: id, session: "s1", t: 200 + id, kind: kind, data: ["text": .string(text)])
}

/// The events of an accepted submit: the `sent` of its send, then
/// `decisions_submitted` with the send's delivery. sbd records both in one
/// block, so `pasting` comes after them. The facts don't depend on that
/// order, so `pastingFirst` puts `pasting` first.
private func submitted(via sentDelivery: Delivery = .pasted, pastingFirst: Bool = false) -> [Event] {
  let sent = Event(
    id: 6, session: "s1", t: 230, kind: "sent",
    data: ["text": .string(submittedMessage), "delivery": .string(sentDelivery.rawValue)])
  let submit = Event(
    id: 8, session: "s1", t: 240, kind: "decisions_submitted",
    data: ["message": .string(submittedMessage), "ref": "summary:3", "delivery": .string(sentDelivery.rawValue)])
  let pasting = delivery(7, "pasting")
  let pasted = pastingFirst ? [pasting, submit] : [submit, pasting]
  return decisionTurn() + [
    decisionsOpened(4, ref: "summary:3"), decisionAnswered(5, 1, ["labels": ["Postgres"]]), sent,
  ]
    + (sentDelivery == .resumed ? [submit] : pasted)
}

private func summary() -> SessionSummary {
  SessionSummary(
    id: "s1", name: "s1", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "s1", state: .needsYou, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
}

/// `SessionFacts` follows the submitted message from `decisions_submitted`
/// until claude got it or sbd can't tell.
@Suite struct DecisionDeliveryTests {
  @Test func factsKeepTheSubmittedMessageWithItsRef() {
    let f = facts(submitted())

    #expect(f.submittedDecisionsMessage == submittedMessage)
    #expect(f.submittedDecisionsRef == "summary:3")
  }

  @Test func nothingSubmittedHasNoDelivery() {
    let f = facts(decisionTurn() + [decisionsOpened(4, ref: "summary:3")])

    #expect(f.decisionsDelivery == nil)
  }

  @Test(arguments: [false, true])
  func anAcceptedSubmitIsSendingUntilDelivered(_ pastingFirst: Bool) {
    let f = facts(submitted(pastingFirst: pastingFirst))

    #expect(f.decisionsDelivery == .sending)
  }

  @Test(arguments: [Delivery.pasted, .queued])
  func deliveredMakesTheSubmitDelivered(_ sentDelivery: Delivery) {
    let f = facts(submitted(via: sentDelivery) + [delivery(9, "delivered")])

    #expect(f.decisionsDelivery == .delivered)
  }

  /// A submit that resumed a stopped claude passed the message as its first
  /// prompt. No paste follows, so no `delivered` ever comes.
  @Test func aSubmitThatResumedClaudeIsDelivered() {
    let f = facts(submitted(via: .resumed))

    #expect(f.decisionsDelivery == .delivered)
  }

  @Test(arguments: [false, true])
  func deliveryUnknownMakesTheSubmitUnknown(_ pastingFirst: Bool) {
    let f = facts(submitted(pastingFirst: pastingFirst) + [delivery(9, "delivery_unknown")])

    #expect(f.decisionsDelivery == .unknown)
  }

  /// A submit from an sbd that recorded no delivery with it, and no
  /// `delivered` for a direct paste, counts as delivered.
  @Test func anOldSubmitIsDelivered() {
    let submit = Event(
      id: 8, session: "s1", t: 240, kind: "decisions_submitted",
      data: ["message": .string(submittedMessage), "ref": "summary:3"])

    let f = facts(submitted().filter { $0.kind != "decisions_submitted" && $0.kind != "pasting" } + [submit])

    #expect(f.decisionsDelivery == .delivered)
  }

  /// A resend sends the stored message again, which is on its way until its own `delivered`.
  @Test func aResendAfterAnUnknownDeliveryIsSendingAgain() {
    let resend = Event(
      id: 10, session: "s1", t: 300, kind: "sent",
      data: ["text": .string(submittedMessage), "delivery": .string(Delivery.pasted.rawValue)])

    let f = facts(submitted() + [delivery(9, "delivery_unknown"), resend])

    #expect(f.decisionsDelivery == .sending)
  }

  /// Only events about the submitted text change its delivery.
  @Test(arguments: ["delivered", "delivery_unknown"])
  func anotherMessagesEventLeavesTheDelivery(_ kind: String) {
    let f = facts(submitted() + [delivery(9, kind, "an unrelated message")])

    #expect(f.decisionsDelivery == .sending)
  }

  /// The app reads the delivery from the summary's JSON.
  @Test(arguments: [(DecisionsDelivery.sending, "sending"), (.delivered, "delivered"), (.unknown, "unknown")])
  func theSummaryCarriesTheDeliveryByName(_ state: DecisionsDelivery, _ name: String) throws {
    var s = summary()
    s.decisionsDelivery = state

    let json = try JSON(encoding: s)

    #expect(json["decisionsDelivery"]?.string == name)
    #expect(try JSONCoding.convert(json, to: SessionSummary.self).decisionsDelivery == state)
  }

  @Test func theSummaryOmitsTheDeliveryWhenNothingWasSubmitted() throws {
    let s = summary()

    #expect(try JSON(encoding: s)["decisionsDelivery"] == nil)
  }
}
