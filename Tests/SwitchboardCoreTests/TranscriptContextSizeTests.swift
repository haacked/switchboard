import Foundation
import Testing

@testable import SwitchboardCore

// MARK: - Transcript lines

/// A transcript in the Manager's projects folder, which only `TranscriptMachine` holds.
private let path = "/box/home/.claude/projects/-box-home--sb-manager/0b6e4c2a-5d1f-4e8b-9a3c-7f2d1e6b8a40.jsonl"

private let realModel = "claude-opus-5-5"

/// A usage as Claude Code 2.1.318 writes it. The nested `iterations` and `cache_creation` repeat the top-level
/// numbers, so a reader that sums every token field it finds counts them twice.
private func usage(input: Int, cacheRead: Int, cacheCreation: Int, output: Int = 165) -> JSON {
  [
    "input_tokens": .number(Double(input)),
    "cache_creation_input_tokens": .number(Double(cacheCreation)),
    "cache_read_input_tokens": .number(Double(cacheRead)),
    "output_tokens": .number(Double(output)),
    "output_tokens_details": ["thinking_tokens": 0],
    "server_tool_use": ["web_search_requests": 0, "web_fetch_requests": 0],
    "service_tier": "standard",
    "cache_creation": ["ephemeral_1h_input_tokens": .number(Double(cacheCreation)), "ephemeral_5m_input_tokens": 0],
    "inference_geo": "global",
    "iterations": [
      [
        "input_tokens": .number(Double(input)), "output_tokens": .number(Double(output)),
        "cache_read_input_tokens": .number(Double(cacheRead)),
        "cache_creation_input_tokens": .number(Double(cacheCreation)),
        "cache_creation": [
          "ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": .number(Double(cacheCreation)),
        ],
        "type": "message",
      ]
    ],
    "speed": "standard",
  ]
}

/// A usage whose context is `tokens`: one input token and the rest read from the cache.
private func context(_ tokens: Int) -> JSON { usage(input: 1, cacheRead: tokens - 1, cacheCreation: 0) }

/// An assistant line of the main conversation. A nil `usage` leaves the key out, and `.null` writes it as null.
private func assistant(
  _ usage: JSON?, model: String = realModel, messageId: String = "msg_1",
  content: JSON = [["type": "text", "text": "Done."]],
  _ extra: [String: JSON] = [:]
) -> JSON {
  var message: [String: JSON] = [
    "model": .string(model), "id": .string(messageId), "type": "message", "role": "assistant", "content": content,
    "stop_reason": "end_turn",
  ]
  if let usage { message["usage"] = usage }
  let line: [String: JSON] = [
    "parentUuid": "p1", "isSidechain": false, "type": "assistant", "uuid": .string(UUID().uuidString),
    "timestamp": "2026-11-05T19:59:34.346Z", "message": .object(message),
  ]
  return .object(line.merging(extra) { $1 })
}

private func user(_ text: String) -> JSON {
  [
    "parentUuid": "p1", "isSidechain": false, "type": "user", "timestamp": "2026-11-05T19:59:30.000Z",
    "message": ["role": "user", "content": .string(text)],
  ]
}

/// The line that Claude Code writes when it compacts a conversation, as 2.1.318 wrote it.
private let compactBoundary: JSON = [
  "parentUuid": .null, "logicalParentUuid": "p1", "isSidechain": false, "type": "system",
  "subtype": "compact_boundary", "content": "Conversation compacted", "isMeta": false,
  "timestamp": "2026-11-04T17:06:47.427Z", "level": "info",
  "compactMetadata": ["trigger": "auto", "preTokens": 218_690, "durationMs": 38_453, "postTokens": 19_257],
]

/// A system line of a subtype that Claude Code writes after most turns.
private func system(_ subtype: String) -> JSON {
  [
    "parentUuid": "p1", "isSidechain": false, "type": "system", "subtype": .string(subtype), "isMeta": false,
    "timestamp": "2026-11-05T19:59:35.000Z", "level": "info",
  ]
}

/// The assistant line that Claude Code writes for an API error, as 2.1.316 wrote one for a usage limit.
private func synthetic(_ usage: JSON) -> JSON {
  assistant(
    usage, model: "<synthetic>", messageId: "4eaf423a-9f9e-4ab4-86cd-59bbbefa82e1",
    content: [["type": "text", "text": "You've hit your weekly limit"]],
    ["isApiErrorMessage": true, "apiErrorStatus": 429, "error": "rate_limit"])
}

private let zeroUsage: JSON = [
  "input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
  "server_tool_use": ["web_search_requests": 0, "web_fetch_requests": 0],
  "cache_creation": ["ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 0],
]

// MARK: - Reading

/// A machine that holds only the files it was given.
private struct TranscriptMachine: Machine {
  var files: [String: Data] = [:]

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    CommandResult(status: 0, stdout: "", stderr: "")
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    guard let data = files[path] else { return nil }
    let rest = data.dropFirst(Int(min(offset, UInt64(data.count))))
    return Data(count.map { rest.prefix($0) } ?? rest)
  }

  func size(_ path: String) -> UInt64? { files[path].map { UInt64($0.count) } }
  func exists(_ path: String) -> Bool { files[path] != nil }
  func isFolder(_ path: String) -> Bool { false }
  func modified(_ path: String) -> Date? { nil }
  func list(_ folder: String) -> [String] { [] }
  func createFolder(_ path: String) throws {}
  func signal(_ pid: Int, _ signal: Int32) {}
}

private func file(raw lines: [String], newlineAtEnd: Bool = true) -> Data {
  Data((lines.joined(separator: "\n") + (newlineAtEnd && !lines.isEmpty ? "\n" : "")).utf8)
}

private func contextTokens(raw lines: [String], newlineAtEnd: Bool = true) -> Int? {
  Transcript.contextTokens(path, on: TranscriptMachine(files: [path: file(raw: lines, newlineAtEnd: newlineAtEnd)]))
}

private func contextTokens(_ lines: [JSON]) -> Int? { contextTokens(raw: lines.map(\.text)) }

/// Transcripts that give a value, nil after a compaction, a value past a synthetic line, and nil without a reply.
enum ContextParityShape: String, CaseIterable, CustomTestStringConvertible {
  case reply, compacted, pastSynthetic, noReply

  var testDescription: String { rawValue }

  var lines: [JSON] {
    switch self {
    case .reply: [user("Fix it."), assistant(context(90_000))]
    case .compacted: [assistant(context(90_000)), compactBoundary]
    case .pastSynthetic: [assistant(context(90_000)), synthetic(zeroUsage), system("stop_hook_summary")]
    case .noReply: [user("Fix it.")]
    }
  }
}

// MARK: - The reader

/// `Transcript.contextTokens`: the input context of the latest API call of the main conversation since the last
/// compaction, which sbd reads after each turn of a Manager conversation.
@Suite struct TranscriptContextSizeTests {
  // MARK: The sum

  @Test func theContextIsTheSumOfInputCacheReadAndCacheCreationTokens() {
    let lines = [user("Fix it."), assistant(usage(input: 2, cacheRead: 331_644, cacheCreation: 561, output: 165))]

    #expect(contextTokens(lines) == 2 + 331_644 + 561)
  }

  @Test func aUsageWithoutCacheFieldsCountsItsInputTokens() {
    let lines = [user("Fix it."), assistant(["input_tokens": 1_234, "output_tokens": 5])]

    #expect(contextTokens(lines) == 1_234)
  }

  @Test func theLatestAssistantLineGivesTheContext() {
    let lines = [
      user("Fix it."), assistant(context(100_000), messageId: "msg_1"), user("And the tests."),
      assistant(context(150_000), messageId: "msg_2"),
    ]

    #expect(contextTokens(lines) == 150_000)
  }

  /// Claude Code writes one line per content block of a message, and each line repeats the message's usage.
  @Test func linesOfOneMessageThatShareAUsageGiveItOnce() {
    let shared = context(120_000)
    let lines = [
      user("Fix it."),
      assistant(
        shared, messageId: "msg_7", content: [["type": "thinking", "thinking": "Look first.", "signature": "x"]]),
      assistant(shared, messageId: "msg_7", content: [["type": "text", "text": "I'll look."]]),
      assistant(
        shared, messageId: "msg_7",
        content: [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]),
    ]

    #expect(contextTokens(lines) == 120_000)
  }

  // MARK: Lines that are skipped

  @Test func aSidechainLineAfterTheMainLineIsSkipped() {
    let lines = [
      assistant(context(90_000)), assistant(context(12_000), messageId: "msg_sub", ["isSidechain": true]),
    ]

    #expect(contextTokens(lines) == 90_000)
  }

  @Test func aMetaLineAfterTheMainLineIsSkipped() {
    let lines = [assistant(context(90_000)), assistant(context(12_000), messageId: "msg_meta", ["isMeta": true])]

    #expect(contextTokens(lines) == 90_000)
  }

  @Test func aSyntheticLineIsSkippedForTheEarlierRealLine() {
    let lines = [assistant(context(90_000)), user("Go on."), synthetic(zeroUsage)]

    #expect(contextTokens(lines) == 90_000)
  }

  /// The model alone rules a synthetic line out, so a usage on it does not count.
  @Test func aSyntheticLineWithAUsageIsStillSkipped() {
    let lines = [assistant(context(90_000)), synthetic(context(5_000))]

    #expect(contextTokens(lines) == 90_000)
  }

  /// A zero sum alone rules a line out, whatever its model.
  @Test func aLineOfARealModelWhoseSumIsZeroIsSkipped() {
    let lines = [
      assistant(context(90_000)),
      assistant(usage(input: 0, cacheRead: 0, cacheCreation: 0, output: 40), messageId: "msg_2"),
    ]

    #expect(contextTokens(lines) == 90_000)
  }

  /// A sum that `Int` can't hold exactly gives its line no value, so the read takes the earlier line.
  @Test(arguments: [1e20, 2.5])
  func aUsageThatIntCantHoldIsSkipped(_ input: Double) {
    let lines = [
      assistant(context(90_000)),
      assistant(["input_tokens": .number(input), "output_tokens": 5], messageId: "msg_2"),
    ]

    #expect(contextTokens(lines) == 90_000)
  }

  /// The stub's reply line and the line before a usage arrives carry no usage.
  @Test(arguments: [nil, JSON.null] as [JSON?])
  func anAssistantLineWithoutAUsageIsSkipped(_ missing: JSON?) {
    let lines = [assistant(context(90_000)), assistant(missing, messageId: "msg_2")]

    #expect(contextTokens(lines) == 90_000)
  }

  @Test(arguments: ["user", "api-request-blob"])
  func aLineThatIsNotAnAssistantLineIsSkippedEvenWithAUsage(_ type: String) {
    let lines = [assistant(context(90_000)), assistant(context(7_000), messageId: "msg_2", ["type": .string(type)])]

    #expect(contextTokens(lines) == 90_000)
  }

  @Test(arguments: ["stop_hook_summary", "turn_duration", "away_summary", "informational", "local_command"])
  func aSystemLineOfAnotherSubtypeDoesNotEndTheRead(_ subtype: String) {
    let lines = [user("Fix it."), assistant(context(90_000)), system(subtype)]

    #expect(contextTokens(lines) == 90_000)
  }

  // MARK: Compaction

  @Test func aCompactBoundaryAfterTheLastAssistantLineGivesNil() {
    let lines = [user("Fix it."), assistant(context(218_690)), compactBoundary, user("Continue.")]

    #expect(contextTokens(lines) == nil)
  }

  @Test func anAssistantLineAfterACompactBoundaryGivesItsValue() {
    let lines = [
      assistant(context(218_690), messageId: "msg_1"), compactBoundary, user("Continue."),
      assistant(context(19_300), messageId: "msg_2"),
    ]

    #expect(contextTokens(lines) == 19_300)
  }

  /// The read stops at the boundary even when only skipped lines follow it.
  @Test func aCompactBoundaryFollowedOnlyBySkippedLinesGivesNil() {
    let lines = [
      assistant(context(218_690), messageId: "msg_1"), compactBoundary, synthetic(zeroUsage),
      assistant(context(4_000), messageId: "msg_sub", ["isSidechain": true]),
    ]

    #expect(contextTokens(lines) == nil)
  }

  // MARK: The file

  /// Claude writes the last line in pieces, so a read can see it cut off.
  @Test func aTruncatedLastLineIsSkipped() {
    let whole = assistant(context(90_000)).text
    let cut = String(assistant(context(150_000), messageId: "msg_2").text.prefix(120))

    #expect(contextTokens(raw: [whole, cut], newlineAtEnd: false) == 90_000)
  }

  @Test func anEmptyTranscriptGivesNil() {
    #expect(contextTokens(raw: []) == nil)
  }

  @Test func aTranscriptWithoutAssistantLinesGivesNil() {
    #expect(contextTokens([user("Fix it."), system("turn_duration")]) == nil)
  }

  @Test func aMissingTranscriptGivesNil() {
    #expect(Transcript.contextTokens(path, on: TranscriptMachine()) == nil)
  }

  /// The first read takes the last 64 KB, so these lines push the usage line past several reads.
  @Test func aUsageLineFollowedBy200KBOfUserLinesIsFound() {
    let filler = (1...200).map { user("u\($0) " + String(repeating: "x", count: 1_000)).text }
    let raw = [assistant(context(250_000)).text] + filler
    #expect(raw.dropFirst().map(\.utf8.count).reduce(0, +) > 200_000)

    #expect(contextTokens(raw: raw) == 250_000)
  }

  @Test func aUsageLineLongerThanSeveralReadsIsFound() {
    let long = String(repeating: "Ünïcödé \"quoted\"\n", count: 20_000)
    let lines = [
      user("Write it all out."),
      assistant(context(180_000), content: [["type": "text", "text": .string(long)]]),
      system("turn_duration"),
    ]
    #expect(lines[1].text.utf8.count > 1 << 18)

    #expect(contextTokens(lines) == 180_000)
  }

  // MARK: The machine

  /// sbd reads a local session's transcript on this Mac and a remote one's on its host. Both give the same value.
  @Test(arguments: ContextParityShape.allCases)
  func thisMacAndAMachineGiveTheSameValue(_ shape: ContextParityShape) throws {
    let lines = shape.lines
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let local = "\(dir)/transcript.jsonl"
    try file(raw: lines.map(\.text)).write(to: URL(fileURLWithPath: local))

    #expect(Transcript.contextTokens(local, on: LocalMachine()) == contextTokens(lines))
  }
}
