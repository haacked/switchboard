import Foundation
import Testing

@testable import SwitchboardCore

/// How the parser turns a `text/event-stream` body into events.
@Suite struct SSEParserTests {
  private static func parse(_ text: String) -> [SSEEvent] {
    var parser = SSEParser()
    return parser.feed(Data(text.utf8))
  }

  /// Two events as GitHub sends them, with CRLF endings and a 4-byte character in the first event's data.
  private static let twoEvents = Data(
    ("id: e1\r\nevent: com.github.pull_request.head.changed.v1\r\ndata: {\"title\":\"🚀 ship\"}\r\n\r\n"
      + ": keep-alive\r\n\r\n"
      + "id: e2\r\nevent: github.stream.end\r\ndata: {\"outcome\":\"reconnect\"}\r\n\r\n").utf8)

  private static let twoEventsParsed = [
    SSEEvent(id: "e1", event: "com.github.pull_request.head.changed.v1", data: #"{"title":"🚀 ship"}"#),
    SSEEvent(id: "e2", event: "github.stream.end", data: #"{"outcome":"reconnect"}"#),
  ]

  @Test func anEventHasItsIdEventAndData() {
    #expect(Self.parse("id: 1\nevent: ping\ndata: {}\n\n") == [SSEEvent(id: "1", event: "ping", data: "{}")])
  }

  @Test func aBlockWithoutIdOrEventHasNilForBoth() {
    #expect(Self.parse("data: x\n\n") == [SSEEvent(id: nil, event: nil, data: "x")])
  }

  /// The id belongs to its own block. A later block without an id line has none.
  @Test func anIdDoesNotCarryOverToTheNextBlock() {
    #expect(
      Self.parse("id: 1\nevent: a\ndata: x\n\ndata: y\n\n") == [
        SSEEvent(id: "1", event: "a", data: "x"), SSEEvent(data: "y"),
      ])
  }

  @Test func dataLinesJoinWithALineFeed() {
    #expect(Self.parse("data: a\ndata: b\ndata: c\n\n") == [SSEEvent(data: "a\nb\nc")])
  }

  @Test func aCommentInsideABlockDoesNotEndIt() {
    #expect(Self.parse("data: a\n: note\ndata: b\n\n") == [SSEEvent(data: "a\nb")])
  }

  @Test func keepAliveCommentsAloneGiveNoEvent() {
    #expect(Self.parse(": keep-alive\n\n: keep-alive\n\n:\n\n").isEmpty)
  }

  @Test func aBlockWithoutDataGivesNoEvent() {
    #expect(Self.parse("id: 1\nevent: ping\n\n").isEmpty)
  }

  @Test func aFieldWithoutASpaceAfterTheColonKeepsItsWholeValue() {
    #expect(Self.parse("id:7\nevent:ping\ndata:value\n\n") == [SSEEvent(id: "7", event: "ping", data: "value")])
  }

  @Test func onlyTheFirstSpaceAfterTheColonIsRemoved() {
    #expect(Self.parse("data:  two\n\n") == [SSEEvent(data: " two")])
  }

  @Test func aColonInTheValueStaysInTheValue() {
    #expect(Self.parse("data: {\"a\":\"b:c\"}\n\n") == [SSEEvent(data: #"{"a":"b:c"}"#)])
  }

  @Test func unknownFieldsAreIgnored() {
    #expect(Self.parse("retry: 1000\nfoo: bar\ndata: x\nbaz\n\n") == [SSEEvent(data: "x")])
  }

  @Test(arguments: ["\n", "\r", "\r\n"])
  func eachLineEndingEndsALine(_ end: String) {
    let text = ["id: 1", "event: ping", "data: a", "data: b", "", "data: c", ""].map { $0 + end }.joined()

    #expect(Self.parse(text) == [SSEEvent(id: "1", event: "ping", data: "a\nb"), SSEEvent(data: "c")])
  }

  @Test func oneStreamMayMixLineEndings() {
    #expect(Self.parse("data: a\r\ndata: b\rdata: c\n\r\n") == [SSEEvent(data: "a\nb\nc")])
  }

  /// A CR ends a line at once, so a block that a bare CR ends gives its event without waiting for the next byte.
  @Test func aBareCRAtTheEndOfAChunkEndsTheBlockAtOnce() {
    #expect(Self.parse("data: a\r\r") == [SSEEvent(data: "a")])
  }

  /// An LF in the next chunk belongs to the CR that ended the last one, so it isn't a blank line.
  @Test func anLFAfterACRInTheNextChunkIsNotABlankLine() {
    var parser = SSEParser()

    let first = parser.feed(Data("data: a\r".utf8))
    let second = parser.feed(Data("\ndata: b\r\n\r\n".utf8))

    #expect(first.isEmpty)
    #expect(second == [SSEEvent(data: "a\nb")])
  }

  @Test func aBlockWithoutItsBlankLineWaitsForIt() {
    var parser = SSEParser()

    let first = parser.feed(Data("data: a\n".utf8))
    let second = parser.feed(Data("\n".utf8))

    #expect(first.isEmpty)
    #expect(second == [SSEEvent(data: "a")])
  }

  @Test func theTwoEventStreamInOneChunkGivesBothEvents() {
    var parser = SSEParser()

    #expect(parser.feed(Self.twoEvents) == Self.twoEventsParsed)
  }

  /// A split at each byte offset, including between a CR and its LF and inside the 4-byte character, gives the
  /// events that one chunk gives.
  @Test func aSplitAtEveryOffsetGivesTheSameEvents() {
    let bytes = Self.twoEvents

    for offset in 0...bytes.count {
      var parser = SSEParser()
      let first = parser.feed(bytes.prefix(offset))
      let second = parser.feed(bytes.dropFirst(offset))

      #expect(first + second == Self.twoEventsParsed, "split at \(offset)")
    }
  }

  @Test func oneByteAtATimeGivesTheSameEvents() {
    var parser = SSEParser()
    var events: [SSEEvent] = []

    for byte in Self.twoEvents { events += parser.feed(Data([byte])) }

    #expect(events == Self.twoEventsParsed)
  }

  @Test func anEmptyChunkGivesNoEvent() {
    var parser = SSEParser()

    #expect(parser.feed(Data()).isEmpty)
  }
}
