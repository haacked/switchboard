import Foundation

/// The suggestion in a Manager conversation's header to end it.
public struct EndHint: Codable, Equatable, Sendable {
  public enum Reason: String, Codable, Sendable {
    /// Every session that the conversation spawned is Done or gone.
    case done
    /// The conversation's context reached the threshold.
    case context
  }

  public var reason: Reason
  /// What the hint said. A dismissal hides the hint until its key changes: `done:<spawned sessions>` or
  /// `context:<tokens / threshold>`.
  public var key: String
  public var text: String
  /// The context size, for the context reason only.
  public var tokens: Int?

  public init(reason: Reason, key: String, text: String, tokens: Int? = nil) {
    self.reason = reason
    self.key = key
    self.text = text
    self.tokens = tokens
  }

  /// The hint that the conversation shows, or nil. `spawned` maps each session that the conversation spawned to its
  /// state, or to nil once sbd no longer holds it. The done hint needs at least one spawned session, each of them
  /// Done or gone, and no waits, pause condition, or schedules of the conversation's own. The context hint needs
  /// `contextTokens` at or above `threshold`, which 0 turns off. When both hold, the done hint shows. No hint shows
  /// while a turn or a background job runs, while a message is on its way to the conversation, or while it needs the
  /// user. The hint that holds shows only
  /// when its key differs from `dismissed`.
  public static func evaluate(
    spawned: [String: AttentionState?], hasOwnItems: Bool, inTurnOrJob: Bool, messageOnItsWay: Bool, needsMe: Bool,
    contextTokens: Int?, threshold: Int, dismissed: String?
  ) -> EndHint? {
    guard !inTurnOrJob, !messageOnItsWay, !needsMe else { return nil }
    let hint: EndHint
    if !spawned.isEmpty, spawned.values.allSatisfy({ $0 == nil || $0 == .done }), !hasOwnItems {
      hint = EndHint(
        reason: .done, key: "done:\(spawned.count)",
        text: "Every session this conversation started is done. End it to start fresh.")
    } else if threshold > 0, let tokens = contextTokens, tokens >= threshold {
      hint = EndHint(
        reason: .context, key: "context:\(tokens / threshold)",
        text:
          "This conversation's context is \(tokens / 1000)k tokens, and each turn re-reads it. End it to start fresh.",
        tokens: tokens)
    } else {
      return nil
    }
    return hint.key == dismissed ? nil : hint
  }
}
