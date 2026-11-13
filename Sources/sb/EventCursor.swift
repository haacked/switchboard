import Foundation
import SwitchboardCore

/// Follows sbd's events, for one session or for all.
struct EventCursor {
  /// The id of the last event read. Nil reads the newest events next.
  var since: Int64?
  let session: String?

  /// The events after `since`, oldest first, or the newest events when
  /// `since` is nil. It reads at most `limit` events, `Event.defaultLimit`
  /// without one, and moves `since` past them.
  mutating func next(limit: Int? = nil) throws -> [Event] {
    var args: [String: JSON] = [:]
    if let since { args["since"] = .number(Double(since)) }
    if let session { args["session"] = .string(session) }
    if let limit { args["limit"] = .number(Double(limit)) }
    let events = try client.call("events", args, as: [Event].self)
    since = events.last?.id ?? since ?? 0
    return events
  }
}
