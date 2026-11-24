import Foundation
import Testing

@testable import SwitchboardCore

/// `Transcript.messages(_:limit:mark:on:)` marks the one user message of the main conversation that starts inside
/// the mark's byte window and records the mark's text. Every test computes the window from the bytes it wrote.
@Suite struct TranscriptMarkTests {
  static let prompt = "Check the deploy queue."
  static let run: Int64 = 7

  /// A transcript written to a new temporary folder, and the byte offset where each of its lines starts.
  struct Fixture {
    let path: String
    let offsets: [UInt64]
    let size: UInt64

    init(_ lines: [String], newlineAtEnd: Bool = true, written: Bool = true) throws {
      let folder = try tempFolder()
      path = "\(folder)/c1.jsonl"
      var offsets: [UInt64] = []
      var offset: UInt64 = 0
      for line in lines {
        offsets.append(offset)
        offset += UInt64(line.utf8.count + 1)
      }
      let text = lines.joined(separator: "\n") + (newlineAtEnd && !lines.isEmpty ? "\n" : "")
      if written { try text.write(toFile: path, atomically: true, encoding: .utf8) }
      self.offsets = offsets
      size = UInt64(text.utf8.count)
    }

    func remove() { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

    func read(limit: Int, mark: SentMark?) -> [ChatMessage] {
      Transcript.messages(path, limit: limit, mark: mark, on: LocalMachine())
    }

    func plain(limit: Int) -> [ChatMessage] { Transcript.messages(path, limit: limit, on: LocalMachine()) }

    /// Every message of the file, read from the start one line at a time.
    func forwardScan() -> [ChatMessage] {
      guard let data = FileManager.default.contents(atPath: path) else { return [] }
      return data.split(separator: UInt8(ascii: "\n")).compactMap { Transcript.message(Data($0)) }
    }
  }

  enum Line {
    static func user(_ text: String, _ extra: [String: JSON] = [:]) -> String { line("user", .string(text), extra) }

    static func assistant(_ text: String, _ extra: [String: JSON] = [:]) -> String {
      line("assistant", .string(text), extra)
    }

    /// The line Claude Code writes when the user runs `/<name> <args>`.
    static func slashCommand(_ name: String, args: String) -> String {
      user(
        "<command-message>\(name)</command-message>\n<command-name>/\(name)</command-name>\n"
          + "<command-args>\(args)</command-args>")
    }

    static func userBlocks(_ blocks: [JSON]) -> String { line("user", .array(blocks), [:]) }

    static func toolResult(_ text: String) -> String {
      line("user", [["type": "tool_result", "tool_use_id": "t1", "content": .string(text)]], [:])
    }

    /// A line that holds no message, such as the summary claude writes after a Stop hook.
    static let system = #"{"type":"system","subtype":"stop_hook_summary"}"#

    static func reply(to text: String) -> String { assistant("Done: \(text)") }

    /// Assistant lines of `lineLength` bytes of text that hold at least `bytes` bytes in all.
    static func filler(bytes: Int, lineLength: Int = 8_000) -> [String] {
      var lines: [String] = []
      var total = 0
      while total < bytes {
        let line = assistant("filler \(lines.count) " + String(repeating: "x", count: lineLength))
        lines.append(line)
        total += line.utf8.count + 1
      }
      return lines
    }

    private static func line(_ type: String, _ content: JSON, _ extra: [String: JSON]) -> String {
      let base: [String: JSON] = ["type": .string(type), "message": ["role": .string(type), "content": content]]
      return JSON.object(base.merging(extra) { $1 }).text
    }
  }

  /// A line that holds the prompt's text but is not the transcript's record of a prompt that sbd sent.
  enum Decoy: String, CaseIterable, CustomTestStringConvertible {
    case sidechain, meta, compactSummary, transcriptOnly, toolResult, reply, notice, commandOutput

    var testDescription: String { rawValue }

    func line(holding text: String) -> String {
      switch self {
      case .sidechain: Line.user(text, ["isSidechain": true])
      case .meta: Line.user(text, ["isMeta": true])
      case .compactSummary: Line.user(text, ["isCompactSummary": true])
      case .transcriptOnly: Line.user(text, ["isVisibleInTranscriptOnly": true])
      case .toolResult: Line.toolResult(text)
      case .reply: Line.reply(to: text)
      case .notice: Line.user("Switchboard: a loop sent \(text)")
      case .commandOutput: Line.user("<local-command-stdout>\(text)</local-command-stdout>")
      }
    }
  }

  /// A prompt that a transcript line stores in a form other than plain ASCII string content.
  enum Stored: String, CaseIterable, CustomTestStringConvertible {
    case blocksWithAnImage, escapedAndMultiByte

    var testDescription: String { rawValue }

    var text: String {
      switch self {
      case .blocksWithAnImage: TranscriptMarkTests.prompt
      case .escapedAndMultiByte: "Check the \"deploy\" queue\nfor café ✅"
      }
    }

    var line: String {
      switch self {
      case .blocksWithAnImage:
        Line.userBlocks([
          ["type": "text", "text": .string("[Image #1] \(text)")],
          ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]],
        ])
      case .escapedAndMultiByte: Line.user(text)
      }
    }
  }

  static func mark(
    _ sent: Int64 = TranscriptMarkTests.run, from: UInt64, before: UInt64? = nil,
    text: String = TranscriptMarkTests.prompt
  ) -> SentMark {
    SentMark(sent: sent, conversation: "c1", from: from, before: before, text: text)
  }

  static func markedIndices(_ messages: [ChatMessage]) -> [Int] {
    messages.indices.filter { messages[$0].sent != nil }
  }

  static func stripped(_ messages: [ChatMessage]) -> [ChatMessage] {
    messages.map {
      var message = $0
      message.sent = nil
      return message
    }
  }

  /// Six messages after the window's own lines, so a window can be older than a small `limit`.
  static let later: [String] = (1...3).flatMap { [Line.user("Next \($0)."), Line.assistant("Ok \($0).")] }

  // MARK: Finding the run's message

  @Test func theRunsPromptInItsWindowIsMarkedWithTheRunsSent() throws {
    let fixture = try Fixture(
      [Line.user("Hello."), Line.assistant("Hi."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[2]))

    #expect(Self.markedIndices(read) == [2])
    #expect(read[2].sent == Self.run)
  }

  @Test func theMarkedAnswerIsThePlainAnswerWithOnlyTheMarkAdded() throws {
    let fixture = try Fixture(
      [Line.user("Hello."), Line.assistant("Hi."), Line.user(Self.prompt), Line.reply(to: Self.prompt)] + Self.later)
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[2]))

    #expect(Self.stripped(read) == fixture.plain(limit: 50))
  }

  /// Every run of a loop sends the same text, so only the window tells two runs apart.
  @Test(arguments: [0, 1])
  func twoCopiesOfOnePromptInTwoWindowsEachMarkFindsItsOwnLine(_ run: Int) throws {
    let fixture = try Fixture([
      Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt),
      Line.user("Thanks."), Line.user(Self.prompt), Line.reply(to: Self.prompt),
    ])
    defer { fixture.remove() }
    let marks = [
      Self.mark(7, from: fixture.offsets[1], before: fixture.offsets[4]), Self.mark(8, from: fixture.offsets[4]),
    ]

    let read = fixture.read(limit: 50, mark: marks[run])

    #expect(Self.markedIndices(read) == [[1, 4][run]])
    #expect(read[[1, 4][run]].sent == marks[run].sent)
  }

  /// A launch into a conversation with no transcript yet measures 0 bytes.
  @Test func aPromptAtTheStartOfTheFileIsMarked() throws {
    let fixture = try Fixture([Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: 0))

    #expect(Self.markedIndices(read) == [0])
  }

  @Test func aPromptAtTheStartOfTheFileThatIsOlderThanLimitIsMarked() throws {
    let fixture = try Fixture([Line.user(Self.prompt), Line.reply(to: Self.prompt)] + Self.later)
    defer { fixture.remove() }

    let read = fixture.read(limit: 1, mark: Self.mark(from: 0))

    #expect(read.first?.sent == Self.run)
    #expect(Self.stripped(read) == fixture.plain(limit: 1_000))
  }

  /// The lines before the window hold multi-byte characters, so their byte counts differ from their lengths.
  @Test(arguments: Stored.allCases)
  func aPromptStoredInAnotherFormIsMarked(_ stored: Stored) throws {
    let fixture = try Fixture(
      [Line.user("Héllo ✅"), Line.assistant("Hï ✅ ünïcödé"), stored.line, Line.reply(to: stored.text)] + Self.later)
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[2], text: stored.text))

    #expect(Self.markedIndices(read) == [2])
  }

  @Test(arguments: [("prod", "/check-deploy prod"), ("", "/check-deploy")])
  func aSlashCommandPromptIsFoundByItsNameAndArgs(_ args: String, _ typed: String) throws {
    let fixture = try Fixture(
      [Line.user("Hello."), Line.slashCommand("check-deploy", args: args), Line.assistant("Done.")])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1], text: typed))

    #expect(Self.markedIndices(read) == [1])
  }

  /// The first read covers the last 64 KB, so its edge falls inside the prompt's line.
  @Test func aPromptLineThatCrossesAReadChunkEdgeIsMarked() throws {
    let long = Self.prompt + " " + String(repeating: "p", count: 2_000)
    let fixture = try Fixture(
      [Line.user("Hello."), Line.user(long)] + Line.filler(bytes: 64_000, lineLength: 1_000))
    defer { fixture.remove() }
    let edge = fixture.size - (1 << 16)
    try #require(fixture.offsets[1] < edge && edge < fixture.offsets[2] - 1)

    let read = fixture.read(limit: 100, mark: Self.mark(from: fixture.offsets[1]))

    #expect(Self.markedIndices(read) == [1])
  }

  // MARK: Window edges

  @Test func aCopyThatStartsAtFromCountsAndOneThatStartsAtBeforeDoesNot() throws {
    let fixture = try Fixture([
      Line.user("Hello."), Line.user(Self.prompt), Line.user(Self.prompt), Line.reply(to: Self.prompt),
    ])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1], before: fixture.offsets[2]))

    #expect(Self.markedIndices(read) == [1])
  }

  @Test func aCopyThatStartsOneByteBeforeFromDoesNotCount() throws {
    let fixture = try Fixture([Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1] + 1))

    #expect(read == fixture.plain(limit: 50))
  }

  @Test func aCopyThatStartsOneByteBeforeBeforeCounts() throws {
    let fixture = try Fixture([Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1], before: fixture.offsets[1] + 1))

    #expect(Self.markedIndices(read) == [1])
  }

  /// `SentMark.of` gives `before` 0 when the next `pasting` measured no size.
  @Test func aWindowThatEndsBeforeItStartsMarksNothing() throws {
    let fixture = try Fixture([Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1], before: 0))

    #expect(read == fixture.plain(limit: 50))
  }

  // MARK: The guard refuses

  /// The run's prompt never landed, and an earlier run's copy sits before the window.
  @Test(arguments: [2, 50])
  func aWindowWithNoCopyOfThePromptMarksNothing(_ limit: Int) throws {
    let fixture = try Fixture(
      [Line.user(Self.prompt), Line.reply(to: Self.prompt), Line.user("Hello."), Line.assistant("Hi.")] + Self.later)
    defer { fixture.remove() }

    let read = fixture.read(limit: limit, mark: Self.mark(from: fixture.offsets[2]))

    #expect(read == fixture.plain(limit: limit))
  }

  @Test(arguments: [2, 50])
  func aWindowWithTwoCopiesOfThePromptMarksNothing(_ limit: Int) throws {
    let fixture = try Fixture(
      [
        Line.user("Hello."), Line.user(Self.prompt), Line.user(Self.prompt),
        Line.reply(to: Self.prompt), Line.reply(to: Self.prompt),
      ] + Self.later)
    defer { fixture.remove() }

    let read = fixture.read(limit: limit, mark: Self.mark(from: fixture.offsets[1]))

    #expect(read == fixture.plain(limit: limit))
  }

  /// Run N's prompt is held until after run N+1 pastes, so both copies land in run N+1's window. Run N's window
  /// holds no copy and run N+1's holds two, so neither run can tell which line is its own.
  @Test(arguments: [0, 1])
  func aPromptThatLandsAfterTheNextRunPastesMarksNeitherRun(_ run: Int) throws {
    let fixture = try Fixture(
      [
        Line.user("Earlier."), Line.assistant("Ok."), Line.system,
        Line.user(Self.prompt), Line.user(Self.prompt), Line.reply(to: Self.prompt), Line.reply(to: Self.prompt),
      ] + Self.later)
    defer { fixture.remove() }
    let marks = [
      Self.mark(7, from: fixture.offsets[2], before: fixture.offsets[3]), Self.mark(8, from: fixture.offsets[3]),
    ]

    let read = fixture.read(limit: 50, mark: marks[run])

    #expect(read == fixture.plain(limit: 50))
  }

  /// A mark measured on another file, such as one that claude rewrote, starts at or past this file's end.
  @Test(arguments: [UInt64(0), 100])
  func aMarkThatStartsAtOrPastTheEndOfTheFileMarksNothing(_ past: UInt64) throws {
    let fixture = try Fixture([Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.size + past))

    #expect(read == fixture.plain(limit: 50))
  }

  @Test(arguments: Decoy.allCases)
  func aLineThatIsNotARecordedPromptDoesNotCountAlone(_ decoy: Decoy) throws {
    let fixture = try Fixture(
      [Line.user("Hello."), decoy.line(holding: Self.prompt), Line.assistant("Hi.")] + Self.later)
    defer { fixture.remove() }

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1]))

    #expect(read == fixture.plain(limit: 50))
  }

  @Test(arguments: Decoy.allCases)
  func aLineThatIsNotARecordedPromptDoesNotMakeASecondMatch(_ decoy: Decoy) throws {
    let fixture = try Fixture([
      Line.user("Hello."), decoy.line(holding: Self.prompt), Line.user(Self.prompt), Line.reply(to: Self.prompt),
    ])
    defer { fixture.remove() }
    let prompt = try #require(fixture.plain(limit: 50).firstIndex { $0.role == .user && $0.text == Self.prompt })

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1]))

    #expect(Self.markedIndices(read) == [prompt])
  }

  // MARK: A mark older than limit

  @Test func aMarkOlderThanLimitReachesBackToTheMarkedMessageAndNoFurther() throws {
    let fixture = try Fixture(
      [Line.user("Hello."), Line.assistant("Hi."), Line.user(Self.prompt), Line.reply(to: Self.prompt)] + Self.later)
    defer { fixture.remove() }
    let all = fixture.plain(limit: 1_000)

    let read = fixture.read(limit: 3, mark: Self.mark(from: fixture.offsets[2]))

    #expect(read.first?.sent == Self.run)
    #expect(Self.stripped(read) == Array(all[2...]))
  }

  @Test func aMarkOlderThanLimitKeepsTheNewestLimitMessagesOfThePlainAnswer() throws {
    let fixture = try Fixture(
      [Line.user("Hello."), Line.assistant("Hi."), Line.user(Self.prompt), Line.reply(to: Self.prompt)] + Self.later)
    defer { fixture.remove() }

    let read = fixture.read(limit: 3, mark: Self.mark(from: fixture.offsets[2]))

    #expect(Array(read.suffix(3)) == fixture.plain(limit: 3))
  }

  // MARK: The search budget

  private static var budget: Int { Int(Transcript.markSearchBytes) }

  @Test func aMarkFartherThanMarkSearchBytesFromTheEndMarksNothing() throws {
    let fixture = try Fixture(
      [Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)]
        + Line.filler(bytes: Self.budget + (1 << 16)) + Self.later)
    defer { fixture.remove() }
    try #require(fixture.offsets[1] + UInt64(Self.budget) < fixture.size)

    let read = fixture.read(limit: 3, mark: Self.mark(from: fixture.offsets[1]))

    #expect(read == fixture.plain(limit: 3))
  }

  /// Tool output holds no messages, so the walk passes the budget before it holds `limit` messages.
  @Test func aMarkFartherThanMarkSearchBytesBehindLinesWithNoMessagesMarksNothing() throws {
    let output = Line.toolResult(String(repeating: "x", count: 8_000))
    let filler = Array(repeating: output, count: (Self.budget + (1 << 16)) / 8_000 + 1)
    let fixture = try Fixture(
      [Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)] + filler + Self.later)
    defer { fixture.remove() }
    try #require(fixture.offsets[1] + UInt64(Self.budget) < fixture.size)

    let read = fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1]))

    #expect(read == fixture.plain(limit: 50))
  }

  @Test func aMarkWithinMarkSearchBytesOfTheEndIsMarked() throws {
    let before = Line.filler(bytes: 1 << 20)
    let fixture = try Fixture(
      before + [Line.user(Self.prompt), Line.reply(to: Self.prompt)]
        + Line.filler(bytes: Self.budget - (1 << 20)) + Self.later)
    defer { fixture.remove() }
    let from = fixture.offsets[before.count]
    try #require(from + UInt64(Self.budget) > fixture.size)

    let read = fixture.read(limit: 3, mark: Self.mark(from: from))

    #expect(Self.markedIndices(read) == [0])
    #expect(read.first?.text == Self.prompt)
  }

  /// The budget stops the search for the mark, not the read of the newest `limit` messages.
  @Test func newestMessagesLargerThanMarkSearchBytesComeBackWhole() throws {
    let big = Line.filler(bytes: 3 * (Self.budget / 3 + (1 << 20)), lineLength: Self.budget / 3 + (1 << 20))
    try #require(big.count == 3)
    let fixture = try Fixture([Line.user(Self.prompt), Line.reply(to: Self.prompt)] + big)
    defer { fixture.remove() }

    let read = fixture.read(limit: 3, mark: Self.mark(from: 0))

    #expect(read == fixture.plain(limit: 3))
  }

  // MARK: Parity without a mark (Risk 2)

  enum Shape: String, CaseIterable, CustomTestStringConvertible {
    case empty, missing, oneChunk, manyChunks, lineOverFourMB, decoys, noTrailingNewline, blankAndBrokenLines

    var testDescription: String { rawValue }

    var lines: [String] {
      switch self {
      case .empty, .missing: []
      case .oneChunk, .noTrailingNewline:
        (1...5).flatMap { [Line.user("Question \($0)."), Line.assistant("Answer \($0).")] }
      case .manyChunks:
        (1...200).flatMap {
          [Line.user("Question \($0) " + String(repeating: "q", count: 1_000)), Line.assistant("Answer \($0).")]
        }
      case .lineOverFourMB:
        [
          Line.user("Before."), Line.assistant("Long " + String(repeating: "x", count: 4_500_000)),
          Line.user("After."), Line.assistant("Ok."),
        ]
      case .decoys:
        Decoy.allCases.flatMap { [Line.user("Ask \($0.rawValue)."), $0.line(holding: "decoy"), Line.system] }
          + [Line.assistant("Last.")]
      case .blankAndBrokenLines:
        [Line.user("First."), "", "not json", "{", "", Line.assistant("Second."), "[]", Line.user("Third.")]
      }
    }

    func fixture() throws -> Fixture {
      try Fixture(lines, newlineAtEnd: self != .noTrailingNewline, written: self != .missing)
    }
  }

  @Test(arguments: Shape.allCases, [1, 3, 50, 10_000])
  func withoutAMarkTheAnswerIsThePlainAnswer(_ shape: Shape, _ limit: Int) throws {
    let fixture = try shape.fixture()
    defer { fixture.remove() }

    let read = fixture.read(limit: limit, mark: nil)

    #expect(read == fixture.plain(limit: limit))
  }

  /// The plain answer is the newest `limit` messages that a read from the start of the file finds.
  @Test(arguments: Shape.allCases, [1, 3, 50, 10_000])
  func withoutAMarkTheAnswerIsTheNewestLimitMessagesOfAForwardScan(_ shape: Shape, _ limit: Int) throws {
    let fixture = try shape.fixture()
    defer { fixture.remove() }

    let read = fixture.read(limit: limit, mark: nil)

    #expect(read == Array(fixture.forwardScan().suffix(limit)))
  }

  /// A socket client can send any limit, and `prefix` traps on a negative length.
  @Test(arguments: [-1, 0])
  func aLimitBelowOneReadsAsALimitOfOne(_ limit: Int) throws {
    let fixture = try Fixture([Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    #expect(fixture.plain(limit: limit) == fixture.plain(limit: 1))
    #expect(fixture.read(limit: limit, mark: Self.mark(from: fixture.size)) == fixture.plain(limit: 1))
  }

  /// An older app and `sb … --log --json` read the same JSON as before, with no `sent` key.
  @Test func thePlainAnswerEncodesNoSentKey() throws {
    let fixture = try Fixture([Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let json = try JSONCoding.encode(fixture.plain(limit: 50))

    #expect(!json.contains(#""sent""#))
  }

  @Test func theMarkedMessageEncodesItsSent() throws {
    let fixture = try Fixture([Line.user("Hello."), Line.user(Self.prompt), Line.reply(to: Self.prompt)])
    defer { fixture.remove() }

    let json = try JSONCoding.encode(fixture.read(limit: 50, mark: Self.mark(from: fixture.offsets[1])))

    #expect(json.contains(#""sent":7"#))
  }
}
