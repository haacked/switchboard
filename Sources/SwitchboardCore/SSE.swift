import Foundation

/// One server-sent event.
public struct SSEEvent: Equatable, Sendable {
  /// The id field of the event's own block, or nil when the block has none.
  public var id: String?
  /// The event field, or nil when the block has none.
  public var event: String?
  /// The data lines, joined with a line feed.
  public var data: String

  public init(id: String? = nil, event: String? = nil, data: String) {
    self.id = id
    self.event = event
    self.data = data
  }
}

/// Parses a `text/event-stream` body that arrives in chunks split anywhere, such as inside a line, between a CR and
/// its LF, or inside a UTF-8 character. A line is decoded only once it is complete.
public struct SSEParser: Sendable {
  private var line: [UInt8] = []
  /// A CR ended the last line, so an LF that follows belongs to it.
  private var afterCR = false
  private var id: String?
  private var event: String?
  private var data: [String] = []

  public init() {}

  /// The events that the bytes complete. A block ends at a blank line, and a block without a data line makes no
  /// event. A line that starts with a colon is a comment. Unknown fields are ignored.
  public mutating func feed(_ bytes: Data) -> [SSEEvent] {
    var events: [SSEEvent] = []
    for byte in bytes {
      if afterCR {
        afterCR = false
        if byte == 0x0A { continue }
      }
      guard byte == 0x0A || byte == 0x0D else {
        line.append(byte)
        continue
      }
      afterCR = byte == 0x0D
      // A comment, such as GitHub's keep-alive, needs no decoding.
      if line.first != 0x3A, let e = take(String(decoding: line, as: UTF8.self)) { events.append(e) }
      line.removeAll(keepingCapacity: true)
    }
    return events
  }

  private mutating func take(_ text: String) -> SSEEvent? {
    guard !text.isEmpty else { return dispatch() }
    let field: Substring
    var value: Substring
    if let colon = text.firstIndex(of: ":") {
      field = text[..<colon]
      value = text[text.index(after: colon)...]
      if value.hasPrefix(" ") { value = value.dropFirst() }
    } else {
      (field, value) = (text[...], "")
    }
    switch field {
    case "data": data.append(String(value))
    case "event": event = String(value)
    case "id" where !value.contains("\0"): id = String(value)
    default: break
    }
    return nil
  }

  private mutating func dispatch() -> SSEEvent? {
    defer { (id, event, data) = (nil, nil, []) }
    guard !data.isEmpty else { return nil }
    return SSEEvent(id: id, event: event, data: data.joined(separator: "\n"))
  }
}
