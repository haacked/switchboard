import Foundation

/// The Operator's open questions and waits that show on one session's Inbox item: the session that they are about,
/// or a Manager conversation, or the Operator itself when no other owner is live. sbd derives them from the
/// Operator's facts and waits with `assign` and sets them on each owner's `SessionFacts.operatorItems`. No event
/// folds them. The Decision numbers in this file are those of `plans/410-invisible-operator.md` in the notes repo.
public struct OperatorItems: Codable, Equatable, Sendable {
  /// The open `needsYou` reports that this session owns, oldest first.
  public var asks: [OperatorReport] = []
  /// Every Operator wait that this session owns, overdue or not. The verdict names only the overdue ones.
  public var heldWaits: [Wait] = []

  public init(asks: [OperatorReport] = [], heldWaits: [Wait] = []) {
    self.asks = asks
    self.heldWaits = heldWaits
  }

  /// The first of `candidates` that may own an item and is not the Operator, or nil when none is.
  public static func owner(among candidates: [String?], operatorID: String?, isLive: (String) -> Bool) -> String? {
    candidates.lazy.compactMap { $0 }.first { $0 != operatorID && isLive($0) }
  }

  /// The items of each owner, keyed by the owner's id. An owner with nothing is absent. Every open report and every
  /// wait lands on exactly one owner, and none is dropped.
  ///
  /// A report goes to its `reportOwners` entry while that session is live (Decision 35). A report without an entry
  /// goes to its `about` session while that session is live and is not the Operator (Decision 51). A wait with an
  /// action goes to its `actionSubject` while that session is live, and any wait then goes to its `handedFrom`
  /// conversation while that is live (Decision 38). Everything else goes to `newestConversation` while it is live,
  /// or else to the Operator (Decision 37).
  ///
  /// `isLive` says whether a session may own an item. It must be true only for a local session that exists and whose
  /// verdict an ask can decide. A host session, a paused session, a session marked done, a failed removal, and a
  /// followup or docket row get a verdict before the ask, so an item routed to one would show nowhere. A wait's owner
  /// does not depend on whether it is overdue. The result therefore changes only when the reports, `reportOwners`,
  /// the waits, the live sessions, or `newestConversation` change.
  public static func assign(
    openReports: [OperatorReport], reportOwners: [Int64: String], waits: [Wait], operatorID: String,
    isLive: (String) -> Bool, newestConversation: String?
  ) -> [String: OperatorItems] {
    func owner(_ candidates: String?...) -> String {
      Self.owner(among: candidates + [newestConversation], operatorID: operatorID, isLive: isLive) ?? operatorID
    }
    var out: [String: OperatorItems] = [:]
    for report in openReports {
      let id = reportOwners[report.id].map { owner($0) } ?? owner(report.about)
      out[id, default: OperatorItems()].asks.append(report)
    }
    for wait in waits {
      let id = owner(wait.action == nil ? nil : wait.actionSubject?.id, wait.handedFrom?.id)
      out[id, default: OperatorItems()].heldWaits.append(wait)
    }
    return out
  }
}

extension KeyedDecodingContainer {
  /// Facts decoded without an `operatorItems` key get none. Synthesized `Decodable` ignores a property's default
  /// and throws for a missing key, so `SessionFacts` decodes the key through this overload instead.
  func decode(_ type: OperatorItems.Type, forKey key: Key) throws -> OperatorItems {
    try decodeIfPresent(type, forKey: key) ?? OperatorItems()
  }
}

extension Attention {
  /// Needs you while the session owns an open ask, with "Operator: " and the latest ask's text as the reason.
  static func askVerdict(_ items: OperatorItems) -> Verdict? {
    guard !items.asks.isEmpty else { return nil }
    return Verdict(
      state: .needsYou, reason: "Operator: " + OperatorReport.reason(items.asks), kind: .question, fromOperator: true)
  }

  /// Needs you while a wait that the session owns is overdue, naming each overdue wait.
  static func heldWaitVerdict(_ items: OperatorItems, now: Int64) -> Verdict? {
    let overdue = items.heldWaits.filter { $0.isOverdue(now: now) }
    guard !overdue.isEmpty else { return nil }
    let lines = overdue.map { wait in
      wait.action.map { "sbd still waits to \($0.kind.skipped): \(wait.overdueLine)" }
        ?? "Background follow-through still waits: \(wait.overdueLine)"
    }
    // The prefix of an action wait alone can take 55 characters, so the default 70 would cut the wait's own line.
    return Verdict(
      state: .needsYou, reason: oneLine(lines.joined(separator: "; "), max: 200), kind: .info,
      overdueWaits: overdue.map(\.id), fromOperator: true)
  }

  /// The Operator's verdict (Decision 43). Its open reports and waits show on the sessions that sbd routes them to,
  /// so it is Needs you only for a prompt that blocks it, an exit at the trust dialog, an item that sbd left on it,
  /// or a `notify` outcome. Otherwise it is working while a turn runs and waiting the rest of the time.
  static func operatorRules(_ session: Session, _ facts: SessionFacts, now: Int64) -> Verdict {
    if let card = facts.cards.first(where: { Triage.blocks($0.kind) }) {
      return Verdict(state: .needsYou, reason: oneLine(card.reason))
    }
    if facts.exitedAtTrust { return trustExitVerdict }
    if let v = openPromptVerdict(facts) { return v }
    if let v = askVerdict(facts.operatorItems) { return v }
    if facts.turnRunning { return workingVerdict(facts, now: now) }
    if let outcome = facts.waitOutcome {
      return Verdict(state: .needsYou, reason: oneLine(outcome), kind: .info, byWaitRule: true)
    }
    if let v = heldWaitVerdict(facts.operatorItems, now: now) { return v }
    let waits = session.waits ?? []
    return Verdict(state: .waiting, reason: waits.isEmpty ? "idle" : oneLine(waits.map(\.line).joined(separator: "; ")))
  }
}

extension Triage {
  /// The item of a verdict that background follow-through gave: the asks' report item, or for overdue waits an item
  /// that names them and offers no options. Nil for any other verdict.
  static func operatorSourcedItem(_ facts: SessionFacts, _ verdict: Verdict) -> TriageItem? {
    guard verdict.fromOperator, AttentionState.inbox.contains(verdict.state) else { return nil }
    guard !verdict.overdueWaits.isEmpty else {
      return facts.operatorItems.asks.isEmpty ? nil : reportItem(facts.operatorItems.asks)
    }
    var item = ruleItem(verdict)
    item.source = .report
    item.options = []
    item.ref = heldRef(verdict.overdueWaits)
    return item
  }
}
