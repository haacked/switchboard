import Foundation

/// Where in a transcript a message that sbd sent to claude can be, so `chat-log` can mark that message.
public struct SentMark: Equatable, Sendable {
  /// The id of the message's `sent` event.
  public var sent: Int64
  /// The claude conversation that the message went to. The transcript is `<conversation>.jsonl`.
  public var conversation: String
  /// The transcript's size just before the message went to claude.
  public var from: UInt64
  /// The transcript's size when the next message went to the same conversation, or nil when no message did.
  public var before: UInt64?
  /// The text as claude received it, without image paths.
  public var text: String

  public init(sent: Int64, conversation: String, from: UInt64, before: UInt64?, text: String) {
    self.sent = sent
    self.conversation = conversation
    self.from = from
    self.before = before
    self.text = text
  }

  /// The mark of the `sent` event's message. `later` holds the session's `pasting` and `sent` events after `sent`,
  /// oldest first. `text` is the message's text without image paths.
  ///
  /// The mark starts at the last `pasting` that names `sent`, because a failed paste is pasted again. A launch
  /// with the prompt pastes nothing, so its `sent` event records the start itself. The mark ends where the next
  /// message went to the same conversation: at the next `pasting` of another message, or at the next launch whose
  /// `sent` event records its start. A `pasting` that names no conversation came from an older sbd and counts as
  /// the same conversation, which can only shorten the mark.
  ///
  /// It is nil when the event is not a `sent` event, when the text is empty, or when no event records where the
  /// message started. A message that sbd restored from the log after a restart has a `pasting` that names no
  /// `sent`, so it gets no mark.
  public static func of(sent: Event, later: [Event], text: String) -> SentMark? {
    guard sent.kind == "sent", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let start: (data: JSON, after: Int)
    if let last = later.lastIndex(where: { $0.kind == "pasting" && names($0, sent.id) }) {
      start = (later[last].data, last + 1)
    } else if marksLaunch(sent) {
      start = (sent.data, 0)
    } else {
      return nil
    }
    guard let conversation = start.data["conversation"]?.string else { return nil }
    let next = later[start.after...].first { event in
      switch event.kind {
      case "pasting":
        !names(event, sent.id) && (event.data["conversation"]?.string ?? conversation) == conversation
      case "sent":
        marksLaunch(event) && event.data["conversation"]?.string == conversation
      default:
        false
      }
    }
    return SentMark(
      sent: sent.id, conversation: conversation, from: offset(start.data),
      before: next.map { offset($0.data) }, text: text)
  }

  /// Whether the `sent` event launched claude with its message and recorded where the message started. Without a
  /// size, a mark would start at 0 and could find an earlier run's copy of the prompt.
  private static func marksLaunch(_ sent: Event) -> Bool {
    sent.data["delivery"]?.string == Delivery.resumed.rawValue && sent.data["transcript_bytes"] != nil
  }

  private static func names(_ pasting: Event, _ sent: Int64) -> Bool {
    pasting.data["sent"]?.int.map(Int64.init) == sent
  }

  /// A `pasting` that found no transcript records no size, because the file did not exist yet.
  private static func offset(_ data: JSON) -> UInt64 {
    UInt64(max(0, data["transcript_bytes"]?.int ?? 0))
  }
}
