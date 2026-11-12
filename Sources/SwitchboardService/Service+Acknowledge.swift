import Foundation
import SwitchboardCore

extension Service {
  /// The `ack` request, which marks the Inbox item of `session` as seen, or
  /// with `undo` puts it back. It changes nothing else about the session.
  /// `caller` is the asking session's id. A session can't acknowledge itself,
  /// because it could then hide its own question from the user.
  func acknowledgeRequest(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    let e = entries[id]!
    if let caller = args["caller"]?.string, (try? lookup(["session": .string(caller)])) == id {
      throw APIError("\(e.session.name) can't acknowledge itself out of the Inbox")
    }
    let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
    if args["undo"]?.bool == true {
      guard shown(id, verdict).acknowledged else {
        throw APIError("\(e.session.name) isn't acknowledged")
      }
      record(id, "unack")
    } else {
      try acknowledge(id, verdict)
    }
    return try JSON(encoding: summary(id))
  }

  /// Records the acknowledgment of the Inbox verdict that `evaluate` gave,
  /// unless the user already acknowledged it.
  func acknowledge(_ id: String, _ verdict: Verdict) throws {
    let e = entries[id]!
    guard !shown(id, verdict).acknowledged else { return }
    guard AttentionState.inbox.contains(verdict.state) else {
      throw APIError("\(e.session.name) isn't in the Inbox: \(verdict.reason)")
    }
    record(id, "ack", try JSON(encoding: Acknowledgment(verdict, e.facts)))
  }

  /// The verdict that the app and `sb` show for `id`, given the verdict that
  /// `evaluate` gave. Every caller goes through here, so the acknowledgment
  /// rules read the same settings everywhere.
  func shown(_ id: String, _ verdict: Verdict) -> Verdict {
    Attention.shown(verdict, entries[id]!.facts)
  }
}
