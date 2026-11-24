import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// A Manager conversation whose transcript ends with a turn of 250,000 context tokens. Its hooks are stamped with
/// their time, so two starts can land in the same millisecond.
private final class ConversationBench {
  static let id = "m1"
  static let firstClaudeSession = "c-m1"

  let service: Service
  private var stamps = 0

  init(_ service: Service, home: Home) throws {
    self.service = service
    let transcript = home.path + "/transcript.jsonl"
    let usage: JSON = ["input_tokens": 1, "cache_read_input_tokens": 249_999, "cache_creation_input_tokens": 0]
    let line: JSON = [
      "type": "assistant", "isSidechain": false,
      "message": ["model": "claude-test", "role": "assistant", "usage": usage],
    ]
    try (line.text + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
    var session = makeSession(Self.id, name: "conversation")
    session.manager = true
    try service.store.save(session)
    service.queue.sync { service.entries[Self.id] = Service.Entry(session: session) }
    try start(claudeSession: Self.firstClaudeSession, source: "startup", t: 1_000, transcript: transcript)
  }

  func start(claudeSession: String, source: String, t: Int64, transcript: String? = nil) throws {
    var payload: [String: JSON] = [
      "hook_event_name": "SessionStart", "session_id": .string(claudeSession), "source": .string(source),
    ]
    if let transcript { payload["transcript_path"] = .string(transcript) }
    try hook(.object(payload), t: t)
  }

  /// The end of a turn, which starts the context read.
  func stop() throws {
    try hook(["hook_event_name": "Stop", "session_id": .string(Self.firstClaudeSession)], t: 2_000)
  }

  func remove() throws {
    try service.queue.sync { try service.forgetSession(Self.id, resolving: []) }
  }

  /// Holds every context read that `body` starts until `body` returns, then waits for the reads to finish and
  /// for the state queue to run what they queued.
  func holdingContextReads(_ body: () throws -> Void) throws {
    let gate = DispatchSemaphore(value: 0)
    Service.contextReads.async { gate.wait() }
    do {
      defer { gate.signal() }
      try body()
    }
    Service.contextReads.sync {}
    service.queue.sync {}
  }

  var contextEvents: [Event] {
    get throws { try service.queue.sync { try service.store.events(session: Self.id, kinds: ["context"]) } }
  }

  var contextTokens: Int? { service.queue.sync { service.entries[Self.id]?.facts.contextTokens } }

  private func hook(_ payload: JSON, t: Int64) throws {
    stamps += 1
    // Each hook gets its own host event id, because sbd skips an id that it already recorded.
    let id = try #require(HostEventID(String(format: "%020lld", t) + "-\(stamps)-abcd"))
    let recorded = try service.queue.sync {
      try service.hook(
        ["session": .string(Self.id), "payload": payload], stamp: HostEventStamp(id: id, host: "mini", t: t))
    }
    try #require(recorded != nil)
  }
}

private func withConversation(_ body: (ConversationBench) throws -> Void) throws {
  try withService { service, home in try body(try ConversationBench(service, home: home)) }
}

/// A conversation's context read runs off the state queue. Each test holds the read until something lands on the
/// conversation, then checks what the read records once it finishes. The cases each trip one check that
/// `recordContext` makes before it records, except `clear` and `resumeOfAnotherConversation`, which each trip two.
@Suite(.serialized) struct ContextReadRaceTests {
  enum Landing: String, CaseIterable, CustomTestStringConvertible {
    /// Only the Claude session id changes.
    case clearInTheSameMillisecond
    /// Only the start time changes, because a compaction keeps the Claude session id.
    case compaction
    /// The Claude session id and the start time both change.
    case clear
    /// A `/resume` in the pane opens another conversation, so the Claude session id and the start time both change.
    case resumeOfAnotherConversation
    case removal

    var testDescription: String { rawValue }
  }

  @Test(.timeLimit(.minutes(1)))
  func aReadWithNothingLandedRecordsTheContext() throws {
    try withConversation { bench in
      try bench.holdingContextReads { try bench.stop() }

      #expect(try bench.contextEvents.map { $0.data["tokens"]?.int } == [250_000])
      #expect(bench.contextTokens == 250_000)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: Landing.allCases)
  func aReadThatFinishesAfterTheConversationChangedRecordsNothing(landing: Landing) throws {
    try withConversation { bench in
      try bench.holdingContextReads {
        try bench.stop()
        switch landing {
        case .clearInTheSameMillisecond:
          try bench.start(claudeSession: "c-cleared", source: "clear", t: 1_000)
        case .compaction:
          try bench.start(claudeSession: ConversationBench.firstClaudeSession, source: "compact", t: 3_000)
        case .clear:
          try bench.start(claudeSession: "c-cleared", source: "clear", t: 3_000)
        case .resumeOfAnotherConversation:
          try bench.start(claudeSession: "c-resumed", source: "resume", t: 3_000)
        case .removal:
          try bench.remove()
        }
      }

      #expect(try bench.contextEvents.isEmpty)
      #expect(bench.contextTokens == nil)
    }
  }
}
