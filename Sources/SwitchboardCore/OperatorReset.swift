import Foundation

/// When sbd starts a fresh operator conversation. The operator keeps its standing instructions in memory and its
/// waits and schedules in sbd, so a fresh conversation loses only chat history, which every turn would reread.
public enum OperatorReset {
  /// The kind of the event that records a fresh conversation, with `from` and `to` (the old and the new Claude
  /// session id) and `turns` (the old conversation's turns).
  public static let event = "conversation-reset"

  /// Whether the conversation has run long enough for a fresh one: it has had a turn since the last reset, and it
  /// has reached `maxTurns` turns or is older than `resetEverySeconds`. Before the first reset, its age counts from
  /// `created`, the session's creation.
  public static func due(_ facts: SessionFacts, created: Int64, now: Int64, settings: OperatorSettings) -> Bool {
    let turns = facts.turnsSinceReset
    guard turns > 0 else { return false }
    if settings.maxTurns > 0, turns >= settings.maxTurns { return true }
    let start = facts.conversationStarted ?? created
    return settings.resetEverySeconds > 0 && now - start >= Int64(settings.resetEverySeconds) * 1000
  }

  /// Why the current conversation must stay, or nil when nothing needs it. A wait whose action awaits judgment
  /// asked its question in this conversation, unless the judge parked it. An open `needsYou` report asked the user, and
  /// the user's answer arrives as a message without the question. An open card, such as a deferred question, also waits
  /// for an answer that only this conversation can act on.
  public static func blocker(waits: [Wait], facts: SessionFacts) -> String? {
    if waits.contains(where: { $0.actionStatus?.kind == .awaitingJudgment && $0.actionStatus?.parkedByJudge == false })
    {
      return "a wait awaits its judgment"
    }
    if !facts.openReports.isEmpty { return "a report waits for the user's answer" }
    if !facts.cards.isEmpty { return "a card waits for the user's answer" }
    return nil
  }
}
