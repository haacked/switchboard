import Foundation

/// The id of a hook event that a host's shim made: `<box clock in ns, 20 digits>-<pid>-<4 hex>`. Ids sort as
/// text in the order of their clock. One event has one text, so the text is what sbd records.
public struct HostEventID: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let text: String
  public let ns: UInt64

  /// Nil unless the text is 20 ASCII digits that a 64-bit clock holds, a pid of 1 to 10 ASCII digits, and 4
  /// lowercase hex digits, with one `-` between them and nothing around them.
  public init?(_ text: String) {
    let bytes = Array(text.utf8)
    func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
    func isHex(_ b: UInt8) -> Bool { isDigit(b) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f")) }
    let dash = UInt8(ascii: "-")
    // 20 digits, a dash, 1 to 10 digits, a dash, 4 hex digits.
    guard bytes.count >= 27, bytes.count <= 36, bytes[20] == dash, bytes[bytes.count - 5] == dash,
      bytes[..<20].allSatisfy(isDigit), bytes[21..<(bytes.count - 5)].allSatisfy(isDigit),
      bytes[(bytes.count - 4)...].allSatisfy(isHex), let ns = UInt64(String(decoding: bytes[..<20], as: UTF8.self))
    else { return nil }
    self.text = text
    self.ns = ns
  }

  public var description: String { text }

  public static func < (a: HostEventID, b: HostEventID) -> Bool {
    a.ns != b.ns ? a.ns < b.ns : a.text.utf8.lexicographicallyPrecedes(b.text.utf8)
  }

  /// The clock of the id in ms.
  public var ms: Int64 { Int64(ns / 1_000_000) }
}

/// What a hook payload asks of sbd. The shim on a host makes the same decision in Python.
public enum HostHook {
  /// The payload's `hook_event_name` when it is exactly one of `SessionFacts.hookKinds`, else nil. Every other
  /// kind in the event log is one that only sbd records, so sbd records a payload from a host only under a kind
  /// that this returns.
  public static func kind(_ payload: JSON) -> String? {
    guard let name = payload["hook_event_name"]?.string, SessionFacts.hookKinds.contains(name) else { return nil }
    return name
  }

  /// Whether the hook waits for sbd's answer: a PermissionRequest, and a PreToolUse whose tool is
  /// AskUserQuestion. Every other hook sends its event and exits.
  public static func waits(_ payload: JSON) -> Bool {
    switch payload["hook_event_name"]?.string {
    case "PermissionRequest": return true
    case "PreToolUse": return payload["tool_name"]?.string == "AskUserQuestion"
    default: return false
    }
  }
}

/// One line of a host's `spool.jsonl`: `{"v":1,"id":…,"session":…,"payload":{…}}`.
public struct SpoolLine: Equatable, Sendable {
  public var id: HostEventID
  public var session: String
  public var payload: JSON
  /// Where the line is in the file, with its newline.
  public var bytes: Range<Int>
}

public enum Spool {
  /// The version of the line format that this reader knows.
  public static let version = 1

  /// Reads the bytes of a spool. `lines` holds each whole line that is a spool line, in the order of the file.
  /// `firstUnreadable` is the offset of the first whole line that is not one. `complete` is the count of bytes
  /// through the last newline. Bytes after it are a line that the shim is still writing, which is in neither.
  public static func parse(_ data: Data) -> (lines: [SpoolLine], firstUnreadable: Int?, complete: Int) {
    let bytes = [UInt8](data)
    var lines: [SpoolLine] = []
    var firstUnreadable: Int?
    var start = 0
    while let end = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
      let range = start..<(end + 1)
      if let line = line(bytes[start..<end], at: range) {
        lines.append(line)
      } else if firstUnreadable == nil {
        firstUnreadable = start
      }
      start = end + 1
    }
    return (lines, firstUnreadable, start)
  }

  /// The count of bytes at the start of a spool that sbd may remove: the longest run of whole spool lines from
  /// the first byte in which each line is one that `recorded` or `removed` accepts. `recorded` says whether
  /// this sbd recorded the line's event, and `removed` whether this sbd removed the session of that id. The
  /// run ends before the first line that neither accepts, before the first line that is not a spool line, and
  /// before a last line that has no newline yet.
  public static func cutLength(_ data: Data, recorded: (SpoolLine) -> Bool, removed: (String) -> Bool) -> Int {
    var end = 0
    for line in parse(data).lines {
      // `lines` leaves out a line that is not a spool line, so a line that starts later than `end` follows one.
      guard line.bytes.lowerBound == end, recorded(line) || removed(line.session) else { break }
      end = line.bytes.upperBound
    }
    return end
  }

  private static func line(_ bytes: ArraySlice<UInt8>, at range: Range<Int>) -> SpoolLine? {
    guard let text = String(bytes: bytes, encoding: .utf8),
      let json = JSON.parse(text), let fields = json.object, fields["v"] == .number(Double(version)),
      let id = fields["id"]?.string.flatMap(HostEventID.init), let session = fields["session"]?.string,
      let payload = fields["payload"], payload.object != nil
    else { return nil }
    return SpoolLine(id: id, session: session, payload: payload, bytes: range)
  }
}

/// Holds a session's arriving events for a short window and releases them lowest id first. An event leaves
/// only after it waited the window, and never ahead of a held event with a lower id.
public struct HostEventOrder {
  /// How long an event waits for an earlier one that is still on its way.
  public static let windowMs: Int64 = 250

  private var held: [HostEventID: Int64] = [:]
  private var lastReleased: HostEventID?

  public init() {}

  /// Whether the buffer holds the id.
  public func holds(_ id: HostEventID) -> Bool { held[id] != nil }

  /// Whether the id is below one that the buffer already released, so it can no longer leave in order.
  public func isLate(_ id: HostEventID) -> Bool { lastReleased.map { id < $0 } ?? false }

  /// Takes an event that arrived at `now`. An id that the buffer holds keeps its first arrival.
  public mutating func add(_ id: HostEventID, at now: Int64) {
    if held[id] == nil { held[id] = now }
  }

  /// Releases the held events, lowest id first, up to the first one that has waited less than the window.
  public mutating func due(now: Int64) -> [HostEventID] {
    var out: [HostEventID] = []
    for id in held.keys.sorted() {
      guard let arrived = held[id], now - arrived >= Self.windowMs else { break }
      out.append(id)
    }
    release(out)
    return out
  }

  /// Releases every held event, lowest id first.
  public mutating func flush() -> [HostEventID] {
    let out = held.keys.sorted()
    release(out)
    return out
  }

  private mutating func release(_ ids: [HostEventID]) {
    for id in ids { held[id] = nil }
    if let last = ids.last, lastReleased.map({ $0 < last }) ?? true { lastReleased = last }
  }
}
