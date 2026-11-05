import Foundation

/// The Inbox item that the user marked as seen, as an `ack` event recorded it.
public struct Acknowledgment: Codable, Equatable, Sendable {
  public var state: AttentionState
  public var reason: String
  /// The PR's head commit when the user acknowledged, or nil without a PR.
  public var head: String?

  public init(state: AttentionState, reason: String, head: String?) {
    self.state = state
    self.reason = reason
    self.head = head
  }

  /// The acknowledgment of the verdict for a session with these facts.
  public init(_ verdict: Verdict, _ facts: SessionFacts) {
    self.init(state: verdict.state, reason: verdict.reason, head: facts.pr?.headSha)
  }
}

extension SessionFacts {
  /// `startTurn` clears the acknowledgment, so it covers one turn.
  mutating func applyAcknowledgment(_ event: Event) {
    switch event.kind {
    case "ack": acknowledgment = try? JSONCoding.convert(event.data, to: Acknowledgment.self)
    case "unack": acknowledgment = nil
    default: break
    }
  }
}

extension Attention {
  /// The verdict that the app and `sb` show. An Inbox verdict that the user
  /// acknowledged moves to Waiting while its state, its reason, and the PR's
  /// head commit are the ones that the user saw. sbd's own rules, such as
  /// waits, parent notices, and auto-continue, read `evaluate`'s verdict. An
  /// acknowledgment therefore changes nothing that sbd does.
  public static func shown(_ verdict: Verdict, _ facts: SessionFacts) -> Verdict {
    guard AttentionState.inbox.contains(verdict.state), facts.acknowledgment == Acknowledgment(verdict, facts) else {
      return verdict
    }
    var out = verdict
    out.state = .waiting
    out.acknowledged = true
    return out
  }
}
