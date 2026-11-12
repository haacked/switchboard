import Foundation
import Testing

@testable import SwitchboardCore

/// The text of an event id: the clock in ns as 20 digits, a pid, and 4 hex digits.
private func idText(_ ns: UInt64, pid: Int = 4242, _ suffix: String = "a1b2") -> String {
  let digits = String(ns)
  return "\(String(repeating: "0", count: 20 - digits.count))\(digits)-\(pid)-\(suffix)"
}

private func eventId(_ ns: UInt64, pid: Int = 4242, _ suffix: String = "a1b2") throws -> HostEventID {
  try #require(HostEventID(idText(ns, pid: pid, suffix)), "\(idText(ns, pid: pid, suffix)) did not parse")
}

/// 2026-11-11 00:00:00 UTC in ns, a clock that a box can show.
private let clock: UInt64 = 1_794_355_200_000_000_000

// MARK: Ids

@Suite struct HostEventIDTests {
  @Test(arguments: [
    (clock, 4242, "a1b2"), (UInt64(0), 1, "0000"), (UInt64.max, 4_194_304, "ffff"), (UInt64(1), 99_999, "09af"),
  ])
  func aWellFormedIdParsesAndGivesItsClock(ns: UInt64, pid: Int, suffix: String) throws {
    let id = try #require(HostEventID(idText(ns, pid: pid, suffix)))

    #expect(id.ns == ns)
  }

  @Test func idsSortByTheirClock() throws {
    let clocks: [UInt64] = [clock + 5, 0, clock, 999_999_999, 1_000_000_000, UInt64.max, clock + 1, 9, 10]

    let sorted = try clocks.map { try eventId($0) }.sorted()

    #expect(sorted.map(\.ns) == clocks.sorted())
  }

  /// The pid and the last part never outrank the clock.
  @Test func anEarlierClockSortsFirstWhateverThePidAndTheLastPart() throws {
    let early = try eventId(clock, pid: 99_999, "ffff")
    let late = try eventId(clock + 1, pid: 1, "0000")

    #expect(early < late)
    #expect(!(late < early))
    #expect(early != late)
  }

  /// Ids sort as text in the order of their clock, so a text sort of spool lines agrees with `<`.
  @Test func idsWithDifferentClocksSortAsTheirTextSorts() throws {
    let texts = [
      idText(clock + 7, pid: 3, "00ff"), idText(9, pid: 70_000, "abcd"), idText(10, pid: 2, "0001"),
      idText(clock, pid: 800, "ffff"), idText(UInt64.max, pid: 1, "0000"), idText(0, pid: 5, "1234"),
    ]
    var textOf: [HostEventID: String] = [:]
    for text in texts { textOf[try #require(HostEventID(text))] = text }

    let sorted = textOf.keys.sorted().compactMap { textOf[$0] }

    #expect(sorted == texts.sorted())
  }

  @Test func twoIdsWithTheSameTextAreEqualAndHashAlike() throws {
    let a = try eventId(clock, pid: 7, "00aa")
    let b = try eventId(clock, pid: 7, "00aa")

    #expect(a == b)
    #expect(Set([a, b]).count == 1)
    #expect(!(a < b) && !(b < a))
  }

  /// Two shims that read the same clock make two events.
  @Test(arguments: [(7, "00aa", 7, "00ab"), (7, "00aa", 8, "00aa"), (99, "ffff", 100, "0000")])
  func idsWithTheSameClockThatDifferElsewhereAreTwoIdsInOneFixedOrder(
    pidA: Int, suffixA: String, pidB: Int, suffixB: String
  ) throws {
    let a = try eventId(clock, pid: pidA, suffixA)
    let b = try eventId(clock, pid: pidB, suffixB)

    #expect(a != b)
    #expect(Set([a, b]).count == 2)
    #expect((a < b) != (b < a), "exactly one of the two sorts first")
    #expect([a, b].sorted() == [b, a].sorted())
  }

  @Test(arguments: [
    "",
    "not-an-id",
    // Wrong width of the clock.
    "1794355200000000000-4242-a1b2",
    "001794355200000000000-4242-a1b2",
    "1-4242-a1b2",
    // Twenty digits that no 64-bit clock holds.
    "99999999999999999999-4242-a1b2",
    "18446744073709551616-4242-a1b2",
    // Letters and signs in the clock.
    "0179435520000000000x-4242-a1b2",
    "x1794355200000000000-4242-a1b2",
    "-1794355200000000000-4242-a1b2",
    "+1794355200000000000-4242-a1b2",
    " 1794355200000000000-4242-a1b2",
    "0x00000000000000001f-4242-a1b2",
    "٠١٧٩٤٣٥٥٢٠٠٠٠٠٠٠٠٠٠٠-4242-a1b2",
    // Missing parts.
    "01794355200000000000",
    "01794355200000000000-4242",
    "01794355200000000000-4242-",
    "01794355200000000000--a1b2",
    "01794355200000000000-a1b2",
    "-4242-a1b2",
    "01794355200000000000 4242 a1b2",
    "01794355200000000000_4242_a1b2",
    // A pid that is not a number.
    "01794355200000000000-42x2-a1b2",
    "01794355200000000000-pid-a1b2",
    "01794355200000000000- 42-a1b2",
    // A last part that is not 4 hex digits.
    "01794355200000000000-4242-a1b",
    "01794355200000000000-4242-a1b2c",
    "01794355200000000000-4242-g1b2",
    "01794355200000000000-4242-a1 2",
    // More than three parts, and text around the id.
    "01794355200000000000-4242-a1b2-0000",
    "01794355200000000000-4242-a1b2\n",
    "01794355200000000000-4242-a1b2 ",
    "\n01794355200000000000-4242-a1b2",
    "01794355200000000000-4242-a1b2\0",
    "01794355200000000000-4242-a1b2/../x",
  ])
  func aMalformedIdIsRefused(text: String) {
    #expect(HostEventID(text) == nil, "\(text.debugDescription) parsed")
  }
}

/// The kind that sbd records a host's hook under.
@Suite struct HostEventKindTests {
  @Test(arguments: SessionFacts.hookKinds)
  func aClaudeHooksNameIsItsKind(name: String) {
    #expect(HostHook.kind(["hook_event_name": .string(name)]) == name)
  }

  @Test(
    arguments: [
      "send_pending", "sent", "answered", "card_closed", "stopped", "exited", "pr", "unknown", "", "stop", "Stop ",
      " Stop", "Stop\n", "Stop\0", "PreCompact", JSON.null, 7, true, ["Stop"], ["hook_event_name": "Stop"],
    ] as [JSON])
  func anyOtherNameIsNoKind(name: JSON) {
    #expect(HostHook.kind(["hook_event_name": name]) == nil)
  }

  @Test func aPayloadWithNoNameOrThatIsNoObjectHasNoKind() {
    #expect(HostHook.kind([:]) == nil)
    #expect(HostHook.kind(["hookEventName": "Stop", "kind": "Stop"]) == nil)
    #expect(HostHook.kind("Stop") == nil)
    #expect(HostHook.kind(["Stop"]) == nil)
  }
}

// MARK: The reorder buffer

/// `HostEventOrder` holds a session's arriving events for 250 ms and releases them lowest id first.
@Suite struct HostEventOrderTests {
  /// Everything that `due` released over these times, in the order released.
  private func released(_ order: inout HostEventOrder, at times: [Int64]) -> [HostEventID] {
    times.flatMap { order.due(now: $0) }
  }

  @Test func anEmptyBufferReleasesNothing() {
    var order = HostEventOrder()

    #expect(order.due(now: 1_000).isEmpty)
    #expect(order.flush().isEmpty)
  }

  @Test func anEventIsHeldForTheWindowAndThenReleasedOnce() throws {
    var order = HostEventOrder()
    let a = try eventId(clock)

    order.add(a, at: 1_000)
    let early = order.due(now: 1_200)
    let after = order.due(now: 1_300)
    let again = order.due(now: 2_000)

    #expect(early.isEmpty, "an event left the buffer 200 ms after it arrived")
    #expect(after == [a])
    #expect(again.isEmpty)
    #expect(order.flush().isEmpty)
  }

  @Test func eventsThatArriveInReverseOrderLeaveInIdOrder() throws {
    var order = HostEventOrder()
    let a = try eventId(clock)
    let b = try eventId(clock + 10_000_000)

    order.add(b, at: 1_000)
    order.add(a, at: 1_050)

    // At 1,260 only the later event has waited its window. It never leaves ahead of the earlier one.
    #expect(released(&order, at: [1_100, 1_260, 1_310, 1_400]) == [a, b])
  }

  @Test func manyEventsThatArriveShuffledLeaveInIdOrder() throws {
    var order = HostEventOrder()
    let ids = try (0..<20).map { try eventId(clock + UInt64($0) * 1_000) }

    for (index, id) in ids.shuffled().enumerated() { order.add(id, at: 1_000 + Int64(index)) }

    #expect(released(&order, at: [1_100, 1_200, 1_400]) == ids)
  }

  @Test func eventsWithTheSameClockLeaveInTheOrderOfTheirIds() throws {
    var order = HostEventOrder()
    let ids = [
      try eventId(clock, pid: 7, "00ab"), try eventId(clock, pid: 7, "00aa"), try eventId(clock, pid: 8, "0000"),
    ]

    for id in ids { order.add(id, at: 1_000) }

    #expect(order.due(now: 1_300) == ids.sorted())
  }

  @Test func anEventThatArrivedLaterStaysWhileAnEarlierArrivalIsDue() throws {
    var order = HostEventOrder()
    let a = try eventId(clock)
    let b = try eventId(clock + 10_000_000)

    order.add(a, at: 1_000)
    order.add(b, at: 1_200)
    let first = order.due(now: 1_300)
    let second = order.due(now: 1_500)

    #expect(first == [a])
    #expect(second == [b])
  }

  @Test func flushReleasesEverythingInIdOrderBeforeTheWindowEnds() throws {
    var order = HostEventOrder()
    let ids = try [3, 1, 2].map { try eventId(clock + UInt64($0)) }

    for id in ids { order.add(id, at: 1_000) }
    let flushed = order.flush()

    #expect(flushed == ids.sorted())
    #expect(order.flush().isEmpty)
    #expect(order.due(now: 5_000).isEmpty, "a flushed event left the buffer twice")
  }

  @Test func theBufferTakesEventsAgainAfterAFlush() throws {
    var order = HostEventOrder()
    let a = try eventId(clock)
    let b = try eventId(clock + 1)

    order.add(a, at: 1_000)
    _ = order.flush()
    order.add(b, at: 1_010)

    #expect(order.due(now: 1_100).isEmpty)
    #expect(order.due(now: 1_300) == [b])
  }

  /// An id below the last one released is late. The buffer still releases it, so sbd still records it.
  @Test func anIdBelowTheLastOneReleasedIsStillReleased() throws {
    var order = HostEventOrder()
    let early = try eventId(clock)
    let late = try eventId(clock + 10_000_000)

    order.add(late, at: 1_000)
    let first = order.due(now: 1_300)
    order.add(early, at: 1_400)
    let second = released(&order, at: [1_500, 1_700])

    #expect(first == [late])
    #expect(second == [early])
  }

  @Test func theBufferReportsAnIdBelowTheLastOneReleasedAsLate() throws {
    var order = HostEventOrder()
    let early = try eventId(clock)
    let released = try eventId(clock + 10_000_000)
    let later = try eventId(clock + 20_000_000)

    #expect(!order.isLate(early), "nothing was released yet")
    order.add(released, at: 1_000)
    _ = order.due(now: 1_300)

    #expect(order.isLate(early))
    #expect(!order.isLate(later))
  }

  @Test func anIdBelowTheLastOneFlushedIsLate() throws {
    var order = HostEventOrder()
    let early = try eventId(clock)
    let flushed = try eventId(clock + 10_000_000)

    order.add(flushed, at: 1_000)
    _ = order.flush()

    #expect(order.isLate(early))
  }
}

// MARK: The spool

private func spoolLine(_ id: String, session: String = "s1", payload: JSON = ["hook_event_name": "Stop"]) -> String {
  JSON.object(["v": 1, "id": .string(id), "session": .string(session), "payload": payload]).text + "\n"
}

/// `Spool.parse` reads the bytes of `spool.jsonl`. Each line is `{"v":1,"id":…,"session":…,"payload":{…}}` and a
/// newline.
@Suite struct HostEventSpoolTests {
  @Test func anEmptyFileHoldsNoLines() {
    let parsed = Spool.parse(Data())

    #expect(parsed.lines.isEmpty)
    #expect(parsed.firstUnreadable == nil)
    #expect(parsed.complete == 0)
  }

  @Test func wholeLinesParseInTheOrderOfTheFile() throws {
    let texts = [
      spoolLine(idText(clock + 2), session: "s2", payload: ["hook_event_name": "Stop", "n": 2]),
      spoolLine(idText(clock), session: "s1", payload: ["hook_event_name": "SessionStart"]),
      spoolLine(idText(clock + 1, pid: 9, "00ff"), session: "s1", payload: [:]),
    ]
    let data = Data(texts.joined().utf8)

    let parsed = Spool.parse(data)

    try #require(parsed.lines.count == 3)
    #expect(
      parsed.lines.map(\.id) == [try eventId(clock + 2), try eventId(clock), try eventId(clock + 1, pid: 9, "00ff")])
    #expect(parsed.lines.map(\.session) == ["s2", "s1", "s1"])
    #expect(parsed.lines[0].payload == ["hook_event_name": "Stop", "n": 2])
    #expect(parsed.lines[1].payload == ["hook_event_name": "SessionStart"])
    #expect(parsed.lines[2].payload == [:])
    #expect(parsed.firstUnreadable == nil)
    #expect(parsed.complete == data.count)
  }

  /// A line's bytes are where the line is in the file, so a cut can name them.
  @Test func eachLineNamesItsBytesInTheFile() throws {
    let texts = [
      spoolLine(idText(clock)), spoolLine(idText(clock + 1), payload: ["text": "héllo ✓"]),
      spoolLine(idText(clock + 2)),
    ]
    let data = Data(texts.joined().utf8)

    let parsed = Spool.parse(data)

    try #require(parsed.lines.count == 3)
    var offset = 0
    for (line, text) in zip(parsed.lines, texts) {
      let bytes = Data(text.utf8)
      #expect(line.bytes.lowerBound == offset)
      // The range holds the line, with or without its newline.
      #expect([bytes.count, bytes.count - 1].contains(line.bytes.count), "\(line.bytes)")
      #expect(data.subdata(in: line.bytes) == bytes.prefix(line.bytes.count))
      offset += bytes.count
    }
  }

  @Test func aPayloadKeepsItsEscapedCharactersAndItsNumbersThatAreText() throws {
    let payload: JSON = [
      "prompt": "line one\nline two \"quoted\" \\ back \u{2028} ✓", "null": "null", "empty": "", "number": "007",
      "nothing": .null, "nested": ["list": [1, "1", true]],
    ]
    let data = Data(spoolLine(idText(clock), payload: payload).utf8)

    let parsed = Spool.parse(data)

    #expect(parsed.lines.map(\.payload) == [payload])
    #expect(parsed.firstUnreadable == nil)
  }

  @Test(arguments: [
    #"{"v":1,"id":"01794355200000000002-4242-a1b2","session":"s1","payload":{"hook_event_name":"Stop"}}"#,
    #"{"v":1,"id":"01794355200000000002-4242-a1b2","session":"s1","payload":{"hook_ev"#,
    #"{"v":1,"id":"0179435520000"#,
    "{",
  ])
  func aTornLastLineIsNotALineAndNotPartOfTheWholeLines(torn: String) throws {
    let whole = spoolLine(idText(clock)) + spoolLine(idText(clock + 1))
    let data = Data((whole + torn).utf8)

    let parsed = Spool.parse(data)

    #expect(parsed.lines.map(\.id) == [try eventId(clock), try eventId(clock + 1)])
    #expect(parsed.complete == Data(whole.utf8).count)
    #expect(parsed.firstUnreadable == nil, "a line that the shim is still writing is not an unreadable line")
  }

  @Test func aFileThatIsOnlyATornLineHoldsNoLines() {
    let parsed = Spool.parse(Data(#"{"v":1,"id":"01794355200000000002-4242-a1b2","session":"s1""#.utf8))

    #expect(parsed.lines.isEmpty)
    #expect(parsed.complete == 0)
    #expect(parsed.firstUnreadable == nil)
  }

  @Test(arguments: [
    "not json",
    "{",
    "[]",
    "\"text\"",
    "null",
    // A bad id.
    #"{"v":1,"id":"1794355200000000001-4242-a1b2","session":"s1","payload":{}}"#,
    #"{"v":1,"id":"01794355200000000001-4242-zzzz","session":"s1","payload":{}}"#,
    #"{"v":1,"id":"","session":"s1","payload":{}}"#,
    #"{"v":1,"id":1794355200000000001,"session":"s1","payload":{}}"#,
    #"{"v":1,"id":null,"session":"s1","payload":{}}"#,
    // A missing key.
    #"{"v":1,"session":"s1","payload":{}}"#,
    #"{"v":1,"id":"01794355200000000001-4242-a1b2","payload":{}}"#,
    #"{"v":1,"id":"01794355200000000001-4242-a1b2","session":"s1"}"#,
    #"{"id":"01794355200000000001-4242-a1b2","session":"s1","payload":{}}"#,
    // A value of the wrong sort.
    #"{"v":1,"id":"01794355200000000001-4242-a1b2","session":7,"payload":{}}"#,
    #"{"v":1,"id":"01794355200000000001-4242-a1b2","session":null,"payload":{}}"#,
    #"{"v":1,"id":"01794355200000000001-4242-a1b2","session":"s1","payload":"text"}"#,
    #"{"v":1,"id":"01794355200000000001-4242-a1b2","session":"s1","payload":[]}"#,
    // A version that this reader does not know.
    #"{"v":2,"id":"01794355200000000001-4242-a1b2","session":"s1","payload":{}}"#,
    #"{"v":"1","id":"01794355200000000001-4242-a1b2","session":"s1","payload":{}}"#,
    // Bytes that are not UTF-8 text reach the file as U+FFFD here, and a NUL as itself.
    "\u{0}\u{0}\u{0}",
  ])
  func aMiddleLineThatIsNotASpoolLineIsUnreadableAndTheLinesAroundItStillParse(bad: String) throws {
    let first = spoolLine(idText(clock))
    let last = spoolLine(idText(clock + 2), session: "s2")
    let data = Data((first + bad + "\n" + last).utf8)

    let parsed = Spool.parse(data)

    #expect(parsed.lines.map(\.id) == [try eventId(clock), try eventId(clock + 2)], "\(bad.debugDescription)")
    #expect(parsed.lines.map(\.session) == ["s1", "s2"])
    #expect(parsed.firstUnreadable == Data(first.utf8).count, "\(bad.debugDescription)")
    #expect(parsed.complete == data.count)
  }

  @Test func bytesThatAreNotTextMakeAnUnreadableLine() throws {
    let first = spoolLine(idText(clock))
    let last = spoolLine(idText(clock + 2))
    let data = Data(first.utf8) + Data([0xff, 0xfe, 0x80, 0x0a]) + Data(last.utf8)

    let parsed = Spool.parse(data)

    #expect(parsed.lines.map(\.id) == [try eventId(clock), try eventId(clock + 2)])
    #expect(parsed.firstUnreadable == Data(first.utf8).count)
    #expect(parsed.complete == data.count)
  }

  @Test func theFirstOfTwoUnreadableLinesIsTheOneNamed() throws {
    let first = spoolLine(idText(clock))
    let data = Data((first + "bad one\n" + spoolLine(idText(clock + 1)) + "bad two\n").utf8)

    let parsed = Spool.parse(data)

    #expect(parsed.firstUnreadable == Data(first.utf8).count)
    #expect(parsed.lines.count == 2)
    #expect(parsed.complete == data.count)
  }

  @Test func anUnreadableFirstLineIsNamedAtTheStartOfTheFile() throws {
    let data = Data(("garbage\n" + spoolLine(idText(clock))).utf8)

    let parsed = Spool.parse(data)

    #expect(parsed.firstUnreadable == 0)
    #expect(parsed.lines.map(\.id) == [try eventId(clock)])
  }

  /// The spool can hold one event twice, as when a cut failed. The dedup table drops the second, not the parser.
  @Test func twoLinesWithTheSameIdAreBothLines() throws {
    let line = spoolLine(idText(clock))

    let parsed = Spool.parse(Data((line + line).utf8))

    #expect(parsed.lines.count == 2)
    #expect(parsed.firstUnreadable == nil)
  }
}
