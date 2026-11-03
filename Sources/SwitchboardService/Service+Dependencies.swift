import Foundation
import SwitchboardCore

extension Service {
  /// The session's state when sbd last evaluated it.
  func lastState(_ id: String) -> AttentionState? { entries[id]?.facts.lastState }

  /// The `dependency-resolved` request, which the GitHub poller sends when a
  /// PR that the session's PR waits on merged or deployed. It sends `message`
  /// to the session, then records `dependencies`. A session marked done gets
  /// no message.
  func dependencyResolved(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    if let message = args["message"]?.string, entries[id]?.session.done == false {
      _ = try send(id, message, byUser: false)
    }
    record(id, "dependencies", ["dependencies": args["dependencies"] ?? []])
    return try JSON(encoding: summary(id))
  }
}
