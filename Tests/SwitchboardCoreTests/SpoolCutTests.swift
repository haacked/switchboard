import Foundation
import Testing

@testable import SwitchboardCore

private func eventId(_ n: Int) -> String { String(format: "%020d-4242-%04x", 1_700_000_000_000_000_000 + n, n) }

/// One spool line as the shim writes it, with its newline.
private func line(_ n: Int, session: String = "s1") -> Data {
  let payload: JSON = ["hook_event_name": "Notification", "message": .string("event \(n) ✓ \"quoted\"")]
  let fields: JSON = ["v": 1, "id": .string(eventId(n)), "session": .string(session), "payload": payload]
  return Data((fields.text + "\n").utf8)
}

private func text(_ s: String) -> Data { Data(s.utf8) }

private func ids(_ numbers: Int...) -> Set<String> { Set(numbers.map(eventId)) }

/// The count of bytes at the start of the spool that sbd may remove. `recorded` holds the ids that this sbd
/// recorded, and `removed` the sessions that this sbd removed. This is the one call of the function under test.
private func cut(_ spool: Data, recorded: Set<String>, removed: Set<String> = []) -> Int {
  Spool.cutLength(spool, recorded: { recorded.contains($0.id.text) }, removed: { removed.contains($0) })
}

/// The file after sbd cut what it may.
private func after(_ spool: Data, recorded: Set<String>, removed: Set<String> = []) -> Data {
  spool.dropFirst(cut(spool, recorded: recorded, removed: removed)).asData
}

extension Data.SubSequence {
  fileprivate var asData: Data { Data(self) }
}

/// A line that `Spool.parse` can't read as a spool line.
private let unreadable: [(name: String, bytes: Data)] = [
  ("text that is not JSON", text("not json\n")),
  ("an empty line", text("\n")),
  ("half an object", text("{\"v\":1,\"id\":\n")),
  ("a JSON array", text("[1,2]\n")),
  ("another version", text("{\"v\":2,\"id\":\"\(eventId(2))\",\"session\":\"s1\",\"payload\":{}}\n")),
  ("no version", text("{\"id\":\"\(eventId(2))\",\"session\":\"s1\",\"payload\":{}}\n")),
  ("an id that is not well formed", text("{\"v\":1,\"id\":\"12-4242-0002\",\"session\":\"s1\",\"payload\":{}}\n")),
  (
    "an id with uppercase hex",
    text("{\"v\":1,\"id\":\"01700000000000000002-4242-00AB\",\"session\":\"s1\",\"payload\":{}}\n")
  ),
  ("no id", text("{\"v\":1,\"session\":\"s1\",\"payload\":{}}\n")),
  ("no session", text("{\"v\":1,\"id\":\"\(eventId(2))\",\"payload\":{}}\n")),
  ("a session that is a number", text("{\"v\":1,\"id\":\"\(eventId(2))\",\"session\":7,\"payload\":{}}\n")),
  ("a payload that is text", text("{\"v\":1,\"id\":\"\(eventId(2))\",\"session\":\"s1\",\"payload\":\"x\"}\n")),
  ("bytes that are not UTF-8", Data([0xff, 0xfe, 0x7b, 0x0a])),
  ("a NUL", Data([0x00, 0x0a])),
]

/// Spools of every kind of line, for the tests of the property.
private let mixed: [(name: String, spool: Data)] = [
  ("recorded lines", line(1) + line(2) + line(3)),
  ("a gap", line(1) + line(9) + line(2)),
  ("a removed session", line(1) + line(8, session: "gone") + line(2) + line(9) + line(3)),
  ("a stranger", line(1) + line(2, session: "stranger") + line(3)),
  ("garbage", line(1) + text("garbage\n") + line(2)),
  ("a torn end", line(1) + line(2) + line(3).dropLast(4).asData),
  ("only garbage", text("\n\n{}\n")),
  ("a line with CR", line(1) + text("{\"v\":1}\r\n") + line(2)),
]

/// The spool cut is destructive. sbd removes a spool line only when this sbd recorded that line's id, or the
/// line's session is one that this sbd removed. The cut is the longest prefix of whole lines in which every line
/// meets that. Each test asserts the exact bytes that stay in the file.
@Suite struct SpoolCutTests {
  // MARK: What is cut

  @Test func anEmptySpoolCutsNothing() {
    #expect(cut(Data(), recorded: ids(1, 2)) == 0)
  }

  @Test func aSpoolOfRecordedLinesIsCutWhole() {
    let spool = line(1) + line(2) + line(3)

    #expect(cut(spool, recorded: ids(1, 2, 3)) == spool.count)
    #expect(after(spool, recorded: ids(1, 2, 3)) == Data())
  }

  @Test func theCutStopsAtTheFirstLineThatIsNotRecorded() {
    let spool = line(1) + line(2) + line(3)

    #expect(after(spool, recorded: ids(1, 3)) == line(2) + line(3))
  }

  /// A recorded line behind one that is not recorded stays. The next reconcile skips it by its id.
  @Test func aRecordedLineBehindALineThatIsNotRecordedStays() {
    let spool = line(1) + line(2) + line(3) + line(4)

    #expect(after(spool, recorded: ids(1, 3, 4)) == line(2) + line(3) + line(4))
  }

  @Test func aSpoolWhoseFirstLineIsNotRecordedIsNotCut() {
    let spool = line(1) + line(2)

    #expect(cut(spool, recorded: ids(2)) == 0)
    #expect(after(spool, recorded: ids(2)) == spool)
  }

  @Test func aSpoolWithNothingRecordedIsNotCut() {
    let spool = line(1) + line(2)

    #expect(cut(spool, recorded: []) == 0)
  }

  // MARK: A removed session, and a session that sbd never held

  @Test func theCutPassesALineOfARemovedSessionThatWasNeverRecorded() {
    let spool = line(1) + line(2, session: "gone") + line(3)

    #expect(after(spool, recorded: ids(1, 3), removed: ["gone"]) == Data())
  }

  @Test func aSpoolOfOnlyARemovedSessionsLinesIsCutWhole() {
    let spool = line(1, session: "gone") + line(2, session: "gone")

    #expect(after(spool, recorded: [], removed: ["gone"]) == Data())
  }

  /// sbd refused the line's event, so its id is not recorded, and sbd never removed a session of that name.
  @Test func theCutStopsAtALineOfASessionThatSbdNeverHeld() {
    let spool = line(1) + line(2, session: "stranger") + line(3)

    #expect(after(spool, recorded: ids(1, 3), removed: ["gone"]) == line(2, session: "stranger") + line(3))
  }

  /// A removed session's name gives no pass to another session whose name only contains it.
  @Test(arguments: ["gone2", "gon", "GONE", " gone", "gone ", ""])
  func aSessionWhoseNameOnlyResemblesARemovedOneStopsTheCut(name: String) {
    let spool = line(1) + line(2, session: name) + line(3)

    #expect(after(spool, recorded: ids(1, 3), removed: ["gone"]) == line(2, session: name) + line(3))
  }

  /// The id decides for a session that sbd holds. A line of a held session whose id is not recorded stays, and so
  /// does a line whose session was removed but whose neighbor was not.
  @Test func aRemovedSessionsLineDoesNotCarryTheLineBehindIt() {
    let spool = line(1, session: "gone") + line(2) + line(3, session: "gone")

    #expect(after(spool, recorded: [], removed: ["gone"]) == line(2) + line(3, session: "gone"))
  }

  // MARK: A line that sbd can't read

  @Test(arguments: unreadable.indices)
  func theCutStopsAtAnUnreadableLineAndKeepsItAndEveryLineBehindIt(shape: Int) {
    let (name, bad) = unreadable[shape]
    let spool = line(1) + bad + line(3)

    #expect(cut(spool, recorded: ids(1, 2, 3), removed: ["s1"]) == line(1).count, "\(name)")
    #expect(after(spool, recorded: ids(1, 2, 3), removed: ["s1"]) == bad + line(3), "\(name)")
  }

  @Test(arguments: unreadable.indices)
  func aSpoolThatStartsWithAnUnreadableLineIsNotCut(shape: Int) {
    let (name, bad) = unreadable[shape]
    let spool = bad + line(1) + line(2)

    #expect(cut(spool, recorded: ids(1, 2), removed: ["s1"]) == 0, "\(name)")
  }

  // MARK: A line that the shim is still writing

  @Test func theCutLeavesATornLastLine() {
    let torn = line(3).dropLast(9).asData
    let spool = line(1) + line(2) + torn

    #expect(after(spool, recorded: ids(1, 2, 3)) == torn)
  }

  /// The whole text of a line without its newline is still a line that the shim has not finished.
  @Test func theCutLeavesALastLineThatLacksOnlyItsNewline() {
    let unfinished = line(2).dropLast().asData
    let spool = line(1) + unfinished

    #expect(after(spool, recorded: ids(1, 2)) == unfinished)
  }

  @Test func aSpoolOfOneTornLineIsNotCut() {
    let torn = line(1).dropLast(5).asData

    #expect(cut(torn, recorded: ids(1)) == 0)
  }

  // MARK: The property

  /// Whatever the spool holds, the cut ends on a line boundary, every line in it is one that sbd recorded or that
  /// belongs to a removed session, and the bytes behind it are untouched.
  @Test(arguments: mixed.indices)
  func everyLineOfTheCutIsRecordedOrOfARemovedSession(shape: Int) {
    let (name, spool) = mixed[shape]
    let recorded = ids(1, 2, 3)

    let n = cut(spool, recorded: recorded, removed: ["gone"])

    let prefix = spool.prefix(n).asData
    let parsed = Spool.parse(prefix)
    #expect(n >= 0 && n <= spool.count, "\(name)")
    #expect(n == 0 || spool[spool.index(spool.startIndex, offsetBy: n - 1)] == UInt8(ascii: "\n"), "\(name)")
    #expect(parsed.firstUnreadable == nil, "\(name)")
    #expect(parsed.complete == n, "\(name)")
    #expect(parsed.lines.allSatisfy { recorded.contains($0.id.text) || $0.session == "gone" }, "\(name)")
    #expect(prefix + spool.dropFirst(n).asData == spool, "\(name)")
  }

  /// The cut is the longest such prefix: the line right behind it, when there is one, is one that sbd may not
  /// remove.
  @Test(arguments: mixed.indices)
  func theLineBehindTheCutIsOneThatSbdMayNotRemove(shape: Int) {
    let (name, spool) = mixed[shape]
    let recorded = ids(1, 2, 3)

    let n = cut(spool, recorded: recorded, removed: ["gone"])

    let rest = Spool.parse(spool.dropFirst(n).asData)
    if let next = rest.lines.first, next.bytes.lowerBound == 0 {
      #expect(!recorded.contains(next.id.text) && next.session != "gone", "\(name): the cut stopped early")
    }
  }

  /// The bytes of the cut are the ones whose hash sbd sends with `spool-drop`, so the count is in bytes of the
  /// file and not in characters.
  @Test func theCutCountsBytesAndNotCharacters() {
    let spool = line(1) + line(2)

    #expect(String(decoding: line(1), as: UTF8.self).count < line(1).count)
    #expect(cut(spool, recorded: ids(1)) == line(1).count)
  }
}
