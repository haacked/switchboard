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

/// The cards, the permission prompt, and the question that wait on the user.
struct OpenPrompts {
  var cards: Set<Int64>
  var permission: ToolCall?
  var question: ToolCall?

  /// Whether a card, a prompt, or a question is open here that was not open in `before`.
  func opened(since before: OpenPrompts) -> Bool {
    !cards.isSubset(of: before.cards) || (permission != nil && permission != before.permission)
      || (question != nil && question != before.question)
  }
}

extension SessionFacts {
  var openPrompts: OpenPrompts {
    OpenPrompts(cards: Set(cards.map(\.id)), permission: openPermission, question: openQuestion)
  }

  /// `startTurn` clears the acknowledgment, so it covers one turn. A prompt
  /// that opens after `before` clears it too, because a new prompt is a new
  /// item even when its reason repeats the acknowledged one. sbd records
  /// `ack` after the prompt that it covers, so this never clears the
  /// acknowledgment of the prompt that the user saw.
  /// `before` is nil when no acknowledgment was set before the event.
  mutating func applyAcknowledgment(_ event: Event, promptsBefore before: OpenPrompts?) {
    switch event.kind {
    case "ack": acknowledgment = try? JSONCoding.convert(event.data, to: Acknowledgment.self)
    case "unack": acknowledgment = nil
    default: if let before, openPrompts.opened(since: before) { acknowledgment = nil }
    }
  }
}

extension Attention {
  /// The verdict that the app and `sb` show. An Inbox verdict that the user
  /// acknowledged moves to Waiting while its state, its reason, and the PR's
  /// head commit are the ones that the user saw. sbd's own rules, such as
  /// waits, parent notices, and auto-continue, read `evaluate`'s verdict. An
  /// acknowledgment therefore changes nothing that sbd does.
  public static func shown(_ verdict: Verdict, _ facts: SessionFacts, held: Bool = false) -> Verdict {
    var out = verdict
    if held, mayHold(verdict, facts) {
      out.state = .waiting
      out.held = true
    }
    guard AttentionState.inbox.contains(verdict.state), facts.acknowledgment == Acknowledgment(verdict, facts) else {
      return out
    }
    out.state = .waiting
    out.acknowledged = true
    return out
  }

  /// Whether a session whose start is held shows in Waiting. A session with
  /// an open card, prompt, or question keeps its state, so that a held start
  /// never hides a decision from the user. A running turn can't be held.
  private static func mayHold(_ verdict: Verdict, _ facts: SessionFacts) -> Bool {
    verdict.state != .working && facts.cards.isEmpty && facts.openPermission == nil && facts.openQuestion == nil
  }
}
