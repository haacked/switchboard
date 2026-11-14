import Foundation
import Testing

@testable import SwitchboardCore

// MARK: - Transcript lines

private func textBlock(_ text: String) -> JSON { ["type": "text", "text": .string(text)] }

private func useBlock(_ name: String, _ input: JSON, id: String) -> JSON {
  ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
}

private let thinkingBlock: JSON = ["type": "thinking", "thinking": "decoy-thinking", "signature": "x"]

private func assistant(_ content: JSON, at time: String? = nil, _ extra: [String: JSON] = [:]) -> JSON {
  var line: [String: JSON] = ["type": "assistant", "message": ["role": "assistant", "content": content]]
  if let time { line["timestamp"] = .string(time) }
  return .object(line.merging(extra) { $1 })
}

private func said(_ text: String, at time: String? = nil) -> JSON { assistant([textBlock(text)], at: time) }

private func called(_ name: String, _ input: JSON, id: String, at time: String? = nil) -> JSON {
  assistant([useBlock(name, input, id: id)], at: time)
}

private func user(_ content: JSON) -> JSON { ["type": "user", "message": ["role": "user", "content": content]] }

private func toolResult(_ id: String, _ content: JSON = "ok", error: Bool = false) -> JSON {
  user([["type": "tool_result", "tool_use_id": .string(id), "content": content, "is_error": .bool(error)]])
}

/// The ways a transcript line can carry a text or a tool_use block that is not one of Claude's steps in the main
/// conversation. `Transcript.message(_:)` drops every one of them, so the context reader must drop them too.
enum TranscriptDecoy: String, CaseIterable, CustomTestStringConvertible {
  case sidechain, apiRequestBlob, meta, compactSummary, transcriptOnly, system, userLine, toolResult

  var testDescription: String { rawValue }

  func line(_ blocks: [JSON]) -> JSON {
    switch self {
    case .sidechain: assistant(.array(blocks), ["isSidechain": true])
    case .apiRequestBlob: assistant(.array(blocks), ["type": "api-request-blob"])
    case .meta: assistant(.array(blocks), ["isMeta": true])
    case .compactSummary: assistant(.array(blocks), ["isCompactSummary": true])
    case .transcriptOnly: assistant(.array(blocks), ["isVisibleInTranscriptOnly": true])
    case .system: assistant(.array(blocks), ["type": "system"])
    case .userLine: user(.array(blocks))
    case .toolResult: user([["type": "tool_result", "tool_use_id": "decoy", "content": .array(blocks)]])
    }
  }
}

// MARK: - Reading

/// Writes the lines to a transcript in a new temporary folder and returns its path.
private func transcriptFile(raw lines: [String], newlineAtEnd: Bool = true) throws -> String {
  let dir = try tempFolder()
  let path = "\(dir)/transcript.jsonl"
  try (lines.joined(separator: "\n") + (newlineAtEnd ? "\n" : "")).write(
    toFile: path, atomically: true, encoding: .utf8)
  return path
}

private func removeTranscript(_ path: String) {
  try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

private typealias Context = (steps: [TranscriptStep], anchored: Bool, more: Bool)

private func context(raw lines: [String], anchor: TranscriptAnchor, steps: Int = 5, newlineAtEnd: Bool = true)
  throws -> Context
{
  let path = try transcriptFile(raw: lines, newlineAtEnd: newlineAtEnd)
  defer { removeTranscript(path) }
  return Transcript.context(path, anchor: anchor, steps: steps, on: LocalMachine())
}

private func context(_ lines: [JSON], anchor: TranscriptAnchor, steps: Int = 5) throws -> Context {
  try context(raw: lines.map(\.text), anchor: anchor, steps: steps)
}

/// A step as one string: a text step's text, or `tool:<name>#<id>` for a tool step.
private func shown(_ step: TranscriptStep) -> String {
  switch step.kind {
  case .text: step.text ?? "<no text>"
  case .tool: "tool:\(step.tool ?? "<no tool>")#\(step.id ?? "<no id>")"
  }
}

private func shown(_ steps: [TranscriptStep]) -> [String] { steps.map(shown) }

/// The texts s1, s2, … sN as one text step each.
private func numbered(_ count: Int) -> [JSON] { (1...count).map { said("s\($0)") } }

private let make: JSON = ["command": "make test"]

private let dbQuestions: JSON = [
  "questions": [
    [
      "question": "Which database?", "header": "DB", "multiSelect": false,
      "options": [["label": "Postgres"], ["label": "SQLite"]],
    ],
    ["question": "Which region?", "header": "Region", "multiSelect": false, "options": [["label": "us"]]],
  ]
]

private func replyItem(_ source: TriageSource = .summary, ref: String = "stop:7") -> TriageItem {
  TriageItem(title: "Read the reply", kind: .decision, summary: "", source: source, ref: ref)
}

// MARK: - The reader

@Suite struct ItemContextTests {
  // MARK: The end anchor and the step count

  /// `steps` counts the steps before the anchor, and the anchor is extra. `.end` anchors at the newest step.
  @Test func theEndGivesTheNewestStepAndTheFiveBeforeItOldestFirst() throws {
    let read = try context(numbered(7), anchor: .end, steps: 5)

    #expect(shown(read.steps) == ["s2", "s3", "s4", "s5", "s6", "s7"])
    #expect(read.anchored)
  }

  @Test func theEndHasMoreWhenSixOrMoreStepsAreOlderThanTheNewest() throws {
    #expect(try context(numbered(7), anchor: .end, steps: 5).more)
  }

  @Test func theEndHasNoMoreWhenItReachesTheFirstStep() throws {
    let read = try context(numbered(6), anchor: .end, steps: 5)

    #expect(shown(read.steps) == ["s1", "s2", "s3", "s4", "s5", "s6"])
    #expect(!read.more)
  }

  @Test func theEndOfAShortTranscriptGivesEveryStep() throws {
    let read = try context(numbered(3), anchor: .end, steps: 5)

    #expect(shown(read.steps) == ["s1", "s2", "s3"])
    #expect(read.anchored)
    #expect(!read.more)
  }

  /// `end` counts as found only when the transcript has a step.
  @Test func theEndOfATranscriptWithoutStepsIsNotAnchored() throws {
    let read = try context(
      [user("Fix it."), toolResult("t1"), assistant([thinkingBlock])], anchor: .end, steps: 5)

    #expect(read.steps.isEmpty)
    #expect(!read.anchored)
    #expect(!read.more)
  }

  @Test(arguments: [TranscriptAnchor.end, .unanchored, .reply("Ship it?"), .toolCall(tool: "Bash", input: make)])
  func aMissingTranscriptGivesNoSteps(_ anchor: TranscriptAnchor) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let read = Transcript.context("\(dir)/missing.jsonl", anchor: anchor, steps: 5, on: LocalMachine())

    #expect(read.steps.isEmpty)
    #expect(!read.anchored)
    #expect(!read.more)
  }

  @Test func oneStepBeforeTheEndGivesTwoSteps() throws {
    let read = try context(numbered(4), anchor: .end, steps: 1)

    #expect(shown(read.steps) == ["s3", "s4"])
    #expect(read.more)
  }

  @Test func twoHundredStepsBeforeTheEndReadTheWholeOfALongTranscript() throws {
    let read = try context(numbered(250), anchor: .end, steps: 200)

    #expect(read.steps.count == 201)
    #expect(read.steps.first?.text == "s50")
    #expect(read.steps.last?.text == "s250")
    #expect(read.more)
  }

  // MARK: Unanchored

  /// Without an anchor there is nothing extra, so the reader returns exactly `steps` steps.
  @Test func unanchoredGivesTheNewestStepsStepsOldestFirst() throws {
    let read = try context(numbered(7), anchor: .unanchored, steps: 5)

    #expect(shown(read.steps) == ["s3", "s4", "s5", "s6", "s7"])
    #expect(!read.anchored)
    #expect(read.more)
  }

  @Test func unanchoredHasNoMoreWhenItReachesTheFirstStep() throws {
    let read = try context(numbered(5), anchor: .unanchored, steps: 5)

    #expect(shown(read.steps) == ["s1", "s2", "s3", "s4", "s5"])
    #expect(!read.more)
  }

  /// An anchor that is not found falls back to the same newest steps as `.unanchored`.
  @Test(arguments: [TranscriptAnchor.reply("Nowhere."), .toolCall(tool: "Bash", input: ["command": "nowhere"])])
  func anAnchorThatIsNotFoundGivesTheNewestStepsStepsUnanchored(_ anchor: TranscriptAnchor) throws {
    let read = try context(numbered(7), anchor: anchor, steps: 5)

    #expect(shown(read.steps) == ["s3", "s4", "s5", "s6", "s7"])
    #expect(!read.anchored)
    #expect(read.more)
  }

  // MARK: Steps

  @Test func blocksOfOneLineKeepTheirOrder() throws {
    let line = assistant([textBlock("Plan."), useBlock("Bash", make, id: "t1"), textBlock("Then.")])

    let read = try context([line], anchor: .end)

    #expect(shown(read.steps) == ["Plan.", "tool:Bash#t1", "Then."])
  }

  @Test func aStringContentIsOneTextStep() throws {
    let read = try context([assistant("Fixed.")], anchor: .end)

    #expect(shown(read.steps) == ["Fixed."])
  }

  @Test func aTextStepIsTrimmed() throws {
    let read = try context([said("  \nShip it?\n\n ")], anchor: .end)

    #expect(read.steps.map(\.text) == ["Ship it?"])
  }

  @Test(
    arguments: [
      ("Bash", ["command": "make test"]),
      ("Edit", ["file_path": "/w/Sources/a.swift", "old_string": "a", "new_string": "b"]),
      ("Write", ["file_path": "/w/notes.txt", "content": "hi"]),
      ("Read", ["file_path": "/w/README.md"]),
      ("Agent", ["description": "find the parser", "prompt": "Find it."]),
      ("mcp__github__get_pull_request", ["number": 5]),
      ("WebFetch", ["url": "https://example.com"]),
    ] as [(String, JSON)])
  func aToolStepCarriesTheToolTheOneLineSummaryAndTheCallsId(_ name: String, _ input: JSON) throws {
    let read = try context([called(name, input, id: "toolu_1")], anchor: .end)

    let step = try #require(read.steps.last)
    #expect(step.kind == .tool)
    #expect(step.tool == name)
    #expect(step.summary == Attention.callLine(name, input))
    #expect(step.id == "toolu_1")
    #expect(step.text == nil)
  }

  /// A question's step shows its first question, which is what the user reads.
  @Test func anAskUserQuestionStepsSummaryIsItsFirstQuestion() throws {
    let read = try context([called("AskUserQuestion", dbQuestions, id: "q1")], anchor: .end)

    #expect(read.steps.last?.summary == "AskUserQuestion Which database?")
  }

  @Test func aStepCarriesItsLinesTimestampInMilliseconds() throws {
    let read = try context(
      [said("Plan.", at: "2026-10-25T10:00:01.000Z"), called("Bash", make, id: "t1", at: "2026-10-25T10:00:02.250Z")],
      anchor: .end)

    #expect(read.steps.map(\.t) == [1_792_922_401_000, 1_792_922_402_250])
  }

  @Test func aStepOfALineWithoutATimestampHasNone() throws {
    let read = try context([said("Plan.")], anchor: .end)

    #expect(read.steps.first?.t == nil)
  }

  @Test func aThinkingBlockGivesNoStep() throws {
    let read = try context([assistant([thinkingBlock, textBlock("Visible.")])], anchor: .end)

    #expect(shown(read.steps) == ["Visible."])
  }

  @Test func userPromptsAndToolResultsGiveNoSteps() throws {
    let read = try context(
      [
        user("decoy-prompt"), said("Plan."), called("Bash", make, id: "t1"),
        toolResult("t1", "decoy-result"), user([textBlock("decoy-prompt-block")]),
      ], anchor: .end, steps: 50)

    #expect(shown(read.steps) == ["Plan.", "tool:Bash#t1"])
  }

  @Test(arguments: TranscriptDecoy.allCases)
  func aLineOutsideTheMainConversationGivesNoStep(_ decoy: TranscriptDecoy) throws {
    let read = try context(
      [said("Plan."), decoy.line([textBlock("decoy-text"), useBlock("Bash", make, id: "decoy")])],
      anchor: .end, steps: 50)

    #expect(shown(read.steps) == ["Plan."])
  }

  // MARK: Reading from the end

  /// The first read takes the last 64 KB, so a line of 150 KB starts in a later read than it ends in.
  @Test func aTextLineThatCrossesAReadChunkGivesOneWholeStep() throws {
    let long = String(repeating: "Ünïcödé ⏺ \"quoted\" \\ \n", count: 6_000) + "The end."
    let lines = [said("Before."), said(long), said("After.")]

    let read = try context(lines, anchor: .unanchored, steps: 10)

    #expect(read.steps.count == 3)
    #expect(read.steps[1].text?.utf8.count == long.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count)
    let whole = read.steps[1].text == long.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(whole)
  }

  @Test func aToolCallThatCrossesAReadChunkIsFoundOnce() throws {
    let input: JSON = ["command": .string("echo " + String(repeating: "x", count: 150_000))]
    let lines = [said("Before."), called("Bash", input, id: "t1"), said("After.")]

    let read = try context(lines, anchor: .toolCall(tool: "Bash", input: input), steps: 10)

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Before.", "tool:Bash#t1"])
  }

  @Test func aPartialLineThatClaudeIsStillWritingGivesNoStep() throws {
    let partial = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Half"#

    let read = try context(raw: [said("Done.").text, partial], anchor: .end, newlineAtEnd: false)

    #expect(shown(read.steps) == ["Done."])
  }
}

// MARK: - The tool anchor (guard)

/// The property: the block found is the call that the card holds.
@Suite struct ItemContextToolAnchorTests {
  @Test func theCallIsTheLastStepWithTheStepsBeforeIt() throws {
    let read = try context(
      [user("Run the tests."), said("I'll run the tests."), called("Bash", make, id: "t1")],
      anchor: .toolCall(tool: "Bash", input: make))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["I'll run the tests.", "tool:Bash#t1"])
  }

  @Test func stepsAfterTheCallAreLeftOut() throws {
    let read = try context(
      [
        said("Plan."), called("Bash", make, id: "t1"), toolResult("t1"), said("After."),
        called("Read", ["file_path": "/a"], id: "r1"),
      ],
      anchor: .toolCall(tool: "Bash", input: make))

    #expect(shown(read.steps) == ["Plan.", "tool:Bash#t1"])
  }

  @Test func theSameToolWithAnotherInputIsNotTheCall() throws {
    let read = try context(
      [said("Plan."), called("Bash", ["command": "make lint"], id: "t1")],
      anchor: .toolCall(tool: "Bash", input: make))

    #expect(!read.anchored)
    #expect(shown(read.steps) == ["Plan.", "tool:Bash#t1"])
  }

  @Test func anotherToolWithTheSameInputIsNotTheCall() throws {
    let read = try context(
      [said("Plan."), called("Monitor", make, id: "m1")], anchor: .toolCall(tool: "Bash", input: make))

    #expect(!read.anchored)
  }

  @Test(arguments: TranscriptDecoy.allCases)
  func theSameCallOutsideTheMainConversationIsNotTheCall(_ decoy: TranscriptDecoy) throws {
    let read = try context(
      [said("Plan."), called("Bash", ["command": "ls"], id: "t1"), decoy.line([useBlock("Bash", make, id: "decoy")])],
      anchor: .toolCall(tool: "Bash", input: make))

    #expect(!read.anchored)
    #expect(!read.steps.contains { $0.id == "decoy" })
    #expect(shown(read.steps) == ["Plan.", "tool:Bash#t1"])
  }

  /// The decoy is newer, so a reader that accepts it would anchor there instead of at the real call.
  @Test(arguments: TranscriptDecoy.allCases)
  func aNewerCopyOutsideTheMainConversationLeavesTheRealCallAsTheAnchor(_ decoy: TranscriptDecoy) throws {
    let read = try context(
      [
        said("Plan."), called("Bash", make, id: "t1"), decoy.line([useBlock("Bash", make, id: "decoy")]),
        said("Later."),
      ],
      anchor: .toolCall(tool: "Bash", input: make))

    #expect(read.anchored)
    #expect(read.steps.last?.id == "t1")
  }

  @Test func theSameInputQuotedInAToolResultIsNotTheCall() throws {
    let read = try context(
      [said("Plan."), toolResult("x", .string(make.text)), toolResult("y", [useBlock("Bash", make, id: "decoy")])],
      anchor: .toolCall(tool: "Bash", input: make))

    #expect(!read.anchored)
    #expect(shown(read.steps) == ["Plan."])
  }

  /// The same command run twice in the turn: the card holds the newer call.
  @Test func twoIdenticalCallsAnchorAtTheNewerOne() throws {
    let read = try context(
      [
        said("Run it."), called("Bash", make, id: "t1"), toolResult("t1"),
        said("Again."), called("Bash", make, id: "t2"),
      ], anchor: .toolCall(tool: "Bash", input: make))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Run it.", "tool:Bash#t1", "Again.", "tool:Bash#t2"])
  }

  /// Parallel tool use puts both calls in one assistant line.
  @Test func twoIdenticalCallsInOneLineAnchorAtTheLaterBlock() throws {
    let line = assistant([textBlock("Both."), useBlock("Bash", make, id: "p1"), useBlock("Bash", make, id: "p2")])

    let read = try context([line], anchor: .toolCall(tool: "Bash", input: make))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Both.", "tool:Bash#p1", "tool:Bash#p2"])
  }

  /// sbd denies a deferred question so the turn can end, and the user answers it turns later.
  @Test func aDeferredQuestionThreeTurnsBackIsFoundWithTheStepsBeforeIt() throws {
    let read = try context(
      [
        user("Set up the store."), said("I'll ask."), called("AskUserQuestion", dbQuestions, id: "q1"),
        toolResult("q1", .string(Card.deferMessage), error: true), said("Waiting for your answer."),
        user("hello"), said("Done: hello"),
        user("again"), said("Done: again"),
        user("third"), said("Done: third"),
      ], anchor: .toolCall(tool: "AskUserQuestion", input: dbQuestions))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["I'll ask.", "tool:AskUserQuestion#q1"])
    #expect(read.steps.last?.summary == "AskUserQuestion Which database?")
  }

  /// JSON equality: object key order doesn't matter, and every number is a Double. The line is raw text, because
  /// `JSONCoding.encoder` sorts keys and writes 1.0 as 1.
  @Test func anInputWithKeysInAnotherOrderAndNumbersWrittenAnotherWayIsTheCall() throws {
    let raw =
      #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e1","name":"Edit","#
      + #""input":{"replace_all":false,"old_string":"a","limit":1.0,"count":1e1,"nested":{"z":1,"a":[1,2.5]},"#
      + #""file_path":"\/w\/x.swift"}}]}}"#
    let input: JSON = [
      "file_path": "/w/x.swift", "nested": ["a": [.number(1), .number(2.5)], "z": .number(1)], "count": .number(10),
      "limit": .number(1), "old_string": "a", "replace_all": false,
    ]

    let read = try context(raw: [said("Edit it.").text, raw], anchor: .toolCall(tool: "Edit", input: input))

    #expect(read.anchored)
    #expect(read.steps.last?.id == "e1")
  }

  @Test func anInputWithEscapedCharactersIsTheCall() throws {
    let input: JSON = ["command": "printf \"a\\tb\\n\" | grep 'b' > /tmp/out ⏺ \u{2028} \u{1F600}"]

    let read = try context(
      [said("Plan."), called("Bash", input, id: "t1")], anchor: .toolCall(tool: "Bash", input: input))

    #expect(read.anchored)
  }

  @Test func anInputWrittenWithUnicodeAndSlashEscapesIsTheCall() throws {
    // The JSON escapes for "A" and "é", built in pieces so that no tool or formatter decodes them in this source.
    let backslash = "\\"
    let escapes = backslash + "u0041" + backslash + "u00e9"
    let raw =
      #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","#
      + #""input":{"command":"ls \/tmp "# + escapes + #""}}]}}"#
    try #require(raw.contains(backslash + "u0041"))

    let read = try context(raw: [raw], anchor: .toolCall(tool: "Bash", input: ["command": "ls /tmp Aé"]))

    #expect(read.anchored)
  }

  /// Raw transcript input text against the card's input. Each pair differs only in how a value is stored.
  @Test(arguments: [
    (#"{"x":"null"}"#, JSON.object(["x": .null])),
    (#"{"x":null}"#, JSON.object(["x": ""])),
    (#"{"x":""}"#, JSON.object(["x": "null"])),
    (#"{}"#, JSON.object(["x": .null])),
    (#"{"x":"1"}"#, JSON.object(["x": .number(1)])),
    (#"{"x":1}"#, JSON.object(["x": "1"])),
    (#"{"x":[1,2]}"#, JSON.object(["x": [.number(2), .number(1)]])),
    (#"{"x":{"a":1}}"#, JSON.object(["x": ["a": .number(1), "b": .number(2)]])),
    (#"{"command":"make test","description":"Run the tests"}"#, JSON.object(["command": "make test"])),
    (#"{"command":"make test "}"#, JSON.object(["command": "make test"])),
  ])
  func anInputThatDiffersInHowAValueIsStoredIsNotTheCall(_ transcriptInput: String, _ cardInput: JSON) throws {
    let raw =
      #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":"#
      + transcriptInput + "}]}}"

    let read = try context(raw: [said("Plan.").text, raw], anchor: .toolCall(tool: "Bash", input: cardInput))

    #expect(!read.anchored)
  }

  @Test func aCallThatIsTheOldestStepHasNoMore() throws {
    let read = try context(
      [user("Run the tests."), called("Bash", make, id: "t1"), said("After.")],
      anchor: .toolCall(tool: "Bash", input: make))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["tool:Bash#t1"])
    #expect(!read.more)
  }

  @Test func exactlyStepsOlderStepsHaveNoMore() throws {
    let read = try context(
      [said("a"), said("b"), called("Bash", make, id: "t1")], anchor: .toolCall(tool: "Bash", input: make), steps: 2)

    #expect(shown(read.steps) == ["a", "b", "tool:Bash#t1"])
    #expect(!read.more)
  }

  @Test func oneMoreOlderStepThanStepsHasMore() throws {
    let read = try context(
      [said("z"), said("a"), said("b"), called("Bash", make, id: "t1")],
      anchor: .toolCall(tool: "Bash", input: make), steps: 2)

    #expect(shown(read.steps) == ["a", "b", "tool:Bash#t1"])
    #expect(read.more)
  }
}

// MARK: - The reply anchor (guard)

/// The property: the message found is the reply whose text the item's Summary came from.
@Suite struct ItemContextReplyAnchorTests {
  @Test func theNewestReplyIsTheLastStep() throws {
    let read = try context(
      [
        user("Pick one."), said("Looking."), called("Bash", make, id: "t1"), toolResult("t1"),
        said("Postgres or SQLite?"),
      ],
      anchor: .reply("Postgres or SQLite?"))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Looking.", "tool:Bash#t1", "Postgres or SQLite?"])
  }

  /// The Stop hook's `last_assistant_message` and the transcript's text can differ in whitespace at the ends.
  @Test func aReplyThatIsEqualAfterTrimmingIsFound() throws {
    let anchor = TranscriptAnchor.of(item: replyItem(), cards: [], lastReply: "\n  Ship it?  \n")

    let read = try context([said("Plan."), said("  Ship it?\n")], anchor: anchor)

    #expect(read.anchored)
    #expect(read.steps.last?.text == "Ship it?")
  }

  /// `TranscriptLine.text` joins a line's text blocks with a blank line, and the hook may hold the joined message.
  @Test func aReplySplitIntoTwoTextBlocksOfOneLineIsFoundAsTheirJoin() throws {
    let line = assistant([textBlock("Part one."), textBlock("Part two.")])

    let read = try context([said("Plan."), line], anchor: .reply("Part one.\n\nPart two."))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Plan.", "Part one.", "Part two."])
  }

  @Test func aReplyWhoseTextBlocksSurroundAToolCallIsFoundAsTheJoinOfItsTexts() throws {
    let line = assistant([textBlock("Ran it."), useBlock("Bash", make, id: "t1"), textBlock("Want me to push?")])

    let read = try context([line], anchor: .reply("Ran it.\n\nWant me to push?"))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Ran it.", "tool:Bash#t1", "Want me to push?"])
  }

  /// After an Escape the item is `stop:0` and `lastReply` is an older turn's reply.
  @Test func aStaleReplyTwoTurnsBackIsFoundAtThatMessage() throws {
    let read = try context(
      [
        user("Pick a store."), said("Which database?"),
        user("go on"), said("Done: go on"),
        user("and again"), said("Done: and again"),
      ], anchor: .reply("Which database?"))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Which database?"])
    #expect(!read.more)
  }

  @Test func aReplyThatAppearsNowhereGivesTheNewestStepsUnanchored() throws {
    let read = try context(numbered(3), anchor: .reply("Never said."))

    #expect(!read.anchored)
    #expect(shown(read.steps) == ["s1", "s2", "s3"])
  }

  @Test func theSameReplyTwiceAnchorsAtTheNewerOne() throws {
    let read = try context(
      [said("Done."), said("middle"), said("Done."), called("Bash", make, id: "t9")], anchor: .reply("Done."))

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Done.", "middle", "Done."])
  }

  /// Equality, not a prefix or a substring: (the transcript's text, the reply).
  @Test(arguments: [
    ("Done. And more.", "Done."), ("Done", "Done."), ("Done.", "Done"), ("Part one. Part two.", "Part two."),
  ])
  func aTextThatOnlyHoldsTheReplyOrPartOfItIsNotTheReply(_ text: String, _ reply: String) throws {
    let read = try context([said(text)], anchor: .reply(reply))

    #expect(!read.anchored)
  }

  @Test(arguments: TranscriptDecoy.allCases)
  func theReplyOutsideTheMainConversationIsNotTheReply(_ decoy: TranscriptDecoy) throws {
    let read = try context([said("Older."), decoy.line([textBlock("Ship it?")])], anchor: .reply("Ship it?"))

    #expect(!read.anchored)
    #expect(shown(read.steps) == ["Older."])
  }

  @Test func theUsersPromptWithTheSameTextIsNotTheReply() throws {
    let read = try context([said("Older."), user("Ship it?")], anchor: .reply("Ship it?"))

    #expect(!read.anchored)
  }

  @Test(arguments: [
    "He said \"ship it\" and left \\ ok?", "Line one\nLine two\n\n- a\n- b", "Ünïcödé ⏺\u{2028}sep \u{1F600}",
    "null", "42", "{\"json\": true}", "a\ttab, <angle brackets> & an ampersand",
  ])
  func aReplyWithCharactersThatJSONEscapesIsFound(_ reply: String) throws {
    let read = try context([said("Older."), said(reply)], anchor: .reply(reply))

    #expect(read.anchored)
    #expect(read.steps.last?.text == reply)
  }
}

// MARK: - Parity with the readers that Details replaces and sits beside

@Suite struct ItemContextParityTests {
  enum Storage: String, CaseIterable, CustomTestStringConvertible {
    case blocks, string
    var testDescription: String { rawValue }
    func line(_ text: String) -> JSON { self == .blocks ? said(text) : assistant(.string(text)) }
  }

  /// "Last reply" shows `Transcript.tail(path).lastReply` today. The reply anchor must land on that same text.
  @Test(
    arguments: [
      "Fixed.", "  padded  \n", "Quote \"x\" and \\ backslash", "Line one\nLine two", "Ünïcödé ⏺\u{2028}sep",
      "null", "123",
    ], Storage.allCases)
  func theReplyAnchorsTextIsTheLastReplyThatTailReads(_ reply: String, _ storage: Storage) throws {
    let path = try transcriptFile(
      raw: [user("go"), said("Working."), called("Bash", make, id: "t1"), toolResult("t1"), storage.line(reply)].map(
        \.text))
    defer { removeTranscript(path) }
    let lastReply = try #require(Transcript.tail(path, on: LocalMachine()).lastReply)
    let anchor = TranscriptAnchor.of(item: replyItem(), cards: [], lastReply: lastReply)

    let read = Transcript.context(path, anchor: anchor, steps: 5, on: LocalMachine())

    #expect(read.anchored)
    #expect(read.steps.last?.text == lastReply)
  }

  /// `tail` skips a last line that holds only a tool call, so its reply is older than the newest step.
  @Test func theReplyAnchorFindsTheLastReplyThatTailReadsBehindAToolCall() throws {
    let path = try transcriptFile(raw: [said("Ship it?"), called("Bash", make, id: "t1")].map(\.text))
    defer { removeTranscript(path) }
    let lastReply = try #require(Transcript.tail(path, on: LocalMachine()).lastReply)

    let read = Transcript.context(path, anchor: .reply(lastReply), steps: 5, on: LocalMachine())

    #expect(read.anchored)
    #expect(shown(read.steps) == ["Ship it?"])
  }

  @Test func theReplyAnchorFindsALastReplyThatTailJoinedFromTwoBlocks() throws {
    let path = try transcriptFile(
      raw: [said("Plan."), assistant([textBlock("Part one."), textBlock(" Part two. ")])].map(\.text))
    defer { removeTranscript(path) }
    let lastReply = try #require(Transcript.tail(path, on: LocalMachine()).lastReply)

    let read = Transcript.context(path, anchor: .reply(lastReply), steps: 5, on: LocalMachine())

    #expect(read.anchored)
    #expect(read.steps.suffix(2).compactMap(\.text) == ["Part one.", "Part two."])
  }

  /// Every assistant message that the chat view shows is a text step, in the same order and with the same time, and
  /// no line that `messages` drops gives a step. Each assistant line holds one text block, because `messages` joins
  /// a line's blocks into one message.
  @Test func theTextStepsAreTheAssistantMessagesThatMessagesReads() throws {
    var lines: [JSON] = [
      user("Fix the parser."),
      said("I'll look.", at: "2026-10-25T10:00:01.000Z"),
      called("Bash", make, id: "t1", at: "2026-10-25T10:00:02.000Z"),
      toolResult("t1"),
      assistant([thinkingBlock, textBlock("After thinking.")], at: "2026-10-25T10:00:03.000Z"),
      assistant(.string("A string reply."), at: "2026-10-25T10:00:04.000Z"),
      said("Quote \"x\" ⏺\u{2028}\\ and null", at: "2026-10-25T10:00:05.000Z"),
    ]
    for decoy in TranscriptDecoy.allCases {
      lines.append(decoy.line([textBlock("decoy-\(decoy.rawValue)"), useBlock("Bash", make, id: "decoy")]))
    }
    lines.append(said("Fixed.", at: "2026-10-25T10:00:06.000Z"))
    let path = try transcriptFile(raw: lines.map(\.text))
    defer { removeTranscript(path) }
    let messages = Transcript.messages(path, limit: 1_000, on: LocalMachine()).filter { $0.role == .assistant }

    let texts = Transcript.context(path, anchor: .end, steps: 200, on: LocalMachine()).steps.filter { $0.kind == .text }

    try #require(messages.count == 5)
    #expect(texts.map(\.text) == messages.map(\.text))
    #expect(texts.map(\.t) == messages.map(\.t))
  }
}

// MARK: - The anchor of each item

@Suite struct ItemContextAnchorOfTests {
  private func cardItem(_ ref: String) -> TriageItem {
    TriageItem(title: "Approve", kind: .approval, summary: "", source: .card, ref: ref)
  }

  private func permissionCard() throws -> Card { try #require(facts(permissionTurn()).cards.first) }

  private func questionCard() throws -> Card { try #require(facts(questionTurn()).cards.first) }

  @Test func noItemAnchorsAtTheEnd() {
    #expect(TranscriptAnchor.of(item: nil, cards: [], lastReply: "Ship it?") == .end)
  }

  @Test func aPermissionCardAnchorsAtItsToolCall() throws {
    let card = try permissionCard()

    let anchor = TranscriptAnchor.of(item: cardItem(card.ref), cards: [card], lastReply: "Ship it?")

    #expect(anchor == .toolCall(tool: "Bash", input: ["command": "touch x"]))
  }

  @Test(arguments: [false, true])
  func aQuestionCardAnchorsAtItsCallWhetherOrNotItIsDeferred(_ deferred: Bool) throws {
    var card = try questionCard()
    card.deferred = deferred

    let anchor = TranscriptAnchor.of(item: cardItem(card.ref), cards: [card], lastReply: nil)

    #expect(anchor == .toolCall(tool: "AskUserQuestion", input: fruitQuestions))
  }

  /// Claude has not started, so no transcript exists.
  @Test func aTrustCardIsUnanchored() {
    let card = Card(trustDialog: Event(id: 7, session: "s1", t: 1, kind: "trust_dialog", data: ["folder": "/w"]))

    #expect(TranscriptAnchor.of(item: cardItem(card.ref), cards: [card], lastReply: "Ship it?") == .unanchored)
  }

  /// A group message's Details already holds the message, and its MCP tool's name need not equal `card.tool`.
  @Test func aSendCardIsUnanchored() throws {
    var card = try permissionCard()
    card.kind = .send
    card.tool = "mcp__switchboard__send_group"

    #expect(TranscriptAnchor.of(item: cardItem(card.ref), cards: [card], lastReply: "Ship it?") == .unanchored)
  }

  @Test func aCardRefWhoseCardIsGoneIsUnanchored() {
    #expect(TranscriptAnchor.of(item: cardItem("card:3"), cards: [], lastReply: "Ship it?") == .unanchored)
  }

  /// A lookup that took the first card would anchor at a call that the item is not about.
  @Test func aCardRefWhoseCardIsGoneIgnoresTheOtherCards() throws {
    let other = try permissionCard()

    #expect(TranscriptAnchor.of(item: cardItem("card:9"), cards: [other], lastReply: nil) == .unanchored)
  }

  @Test func aCardRefAnchorsAtThatCardsCallAmongSeveral() throws {
    let first = try permissionCard()
    var second = first
    second.id = 4
    second.input = ["command": "ls"]

    let anchor = TranscriptAnchor.of(item: cardItem("card:4"), cards: [first, second], lastReply: nil)

    #expect(anchor == .toolCall(tool: "Bash", input: ["command": "ls"]))
  }

  @Test(arguments: [TriageSource.summary, .fallback])
  func aReplyItemAnchorsAtItsReply(_ source: TriageSource) {
    let anchor = TranscriptAnchor.of(item: replyItem(source), cards: [], lastReply: "Ship it?")

    #expect(anchor == .reply("Ship it?"))
  }

  @Test(arguments: [TriageSource.summary, .fallback], [nil, "", "  \n"] as [String?])
  func aReplyItemWithoutAReplyIsUnanchored(_ source: TriageSource, _ lastReply: String?) {
    #expect(TranscriptAnchor.of(item: replyItem(source), cards: [], lastReply: lastReply) == .unanchored)
  }

  /// A new prompt drops the session's card, so it always belongs to the newest turn.
  @Test func aSessionCardAnchorsAtTheEnd() {
    let item = TriageItem(
      title: "Pick how to land #98", kind: .decision, summary: "", source: .session, ref: "summary:2")

    #expect(TranscriptAnchor.of(item: item, cards: [], lastReply: "I wrote the card.") == .end)
  }

  @Test func aRuleItemIsUnanchored() {
    let item = TriageItem(
      title: "Give it a first prompt", kind: .action, summary: "", source: .rule, ref: "rule:Give it a first prompt")

    #expect(TranscriptAnchor.of(item: item, cards: [], lastReply: "Ship it?") == .unanchored)
  }
}

// MARK: - The answer's JSON

@Suite struct ItemContextJSONTests {
  @Test func thePlansExampleDecodes() throws {
    let text = """
      {"session": "s1", "ref": "card:12", "anchor": "tool", "anchored": true, "more": true,
       "steps": [{"kind": "text", "text": "I'll run the tests.", "t": 1731600000000},
                 {"kind": "tool", "tool": "Bash", "summary": "`make test`", "id": "toolu_1", "t": 1731600001000}]}
      """

    let context = try JSONCoding.decode(ItemContext.self, from: text)

    #expect(context.session == "s1")
    #expect(context.ref == "card:12")
    #expect(context.anchored)
    #expect(context.more)
    #expect(
      context.steps == [
        TranscriptStep(kind: .text, text: "I'll run the tests.", t: 1_731_600_000_000),
        TranscriptStep(kind: .tool, tool: "Bash", summary: "`make test`", id: "toolu_1", t: 1_731_600_001_000),
      ])
  }

  /// The case is `unanchored` in Swift, because `none` would clash with `Optional.none`. The wire name is "none".
  @Test(arguments: ["tool", "reply", "end", "none"])
  func eachAnchorNameSurvivesARoundTrip(_ name: String) throws {
    let text = #"{"session":"s1","ref":null,"anchor":"\#(name)","anchored":false,"more":false,"steps":[]}"#

    let encoded = try JSON(encoding: try JSONCoding.decode(ItemContext.self, from: text))

    #expect(encoded["anchor"]?.string == name)
  }

  @Test func aNullRefIsASessionWithoutAnItem() throws {
    let text = #"{"session":"s1","ref":null,"anchor":"end","anchored":true,"more":false,"steps":[]}"#

    #expect(try JSONCoding.decode(ItemContext.self, from: text).ref == nil)
  }

  @Test func aStepWithoutATimeHasNoTField() throws {
    let encoded = try JSON(encoding: TranscriptStep(kind: .text, text: "Hi."))

    #expect(encoded["t"] == nil)
    #expect(encoded["kind"]?.string == "text")
  }
}

@Suite struct CallLineTests {
  @Test(
    arguments: [
      ("Bash", ["command": "make test"], "Bash `make test`"),
      ("Read", ["file_path": "/w/Makefile"], "Read Makefile"),
      ("mcp__github__get_pull_request", ["number": 5], "github get pull request"),
      ("WebFetch", ["url": "https://example.com"], "WebFetch"),
      ("AskUserQuestion", ["questions": [["question": "Which database?"]]], "AskUserQuestion Which database?"),
    ] as [(String, JSON, String)])
  func aCallLineNamesTheToolOnce(_ tool: String, _ input: JSON, _ line: String) {
    #expect(Attention.callLine(tool, input) == line)
  }
}
