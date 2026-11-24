import Foundation
import SwitchboardCore

/// The Operator's needs-you reports and waits show on the sessions that they are about, or on a Manager
/// conversation. sbd records who owns each report and derives every session's `SessionFacts.operatorItems` from the
/// Operator's facts and waits. All of it runs on the state queue. The Decision numbers in this file are those of
/// `plans/410-invisible-operator.md` in the notes repo.
extension Service {
  /// Whether session `id` may own an item of the Operator's. A host session, a paused session, a session marked done,
  /// a session under removal, an unstarted follow-up, and a docket row get a verdict before an ask, so an item routed
  /// to one would show nowhere.
  func mayOwnOperatorItems(_ id: String) -> Bool {
    guard let s = entries[id]?.session, s.host == nil, s.pause == nil, !s.done, s.removal == nil, s.docket == nil
    else { return false }
    return !s.waitsToStart
  }

  /// The session that a needs-you report goes to (Decision 35): the session that it is about, else the conversation
  /// that handed off the wait that the Operator works on, else the most recent conversation. Each must be able to own
  /// an item and must not be the Operator. Nil means that the Operator keeps the report.
  func askOwner(about: String?, handedFrom: String?) -> String? {
    OperatorItems.owner(
      among: [about, handedFrom, newestConversation()], operatorID: operatorID(), isLive: mayOwnOperatorItems)
  }

  /// Records on the Operator that `owner` owns the report of `event`, and records the ask in the owner's log.
  func routeReport(_ event: Event, owner: String) {
    guard owner != event.session else { return }
    let report = JSON.number(Double(event.id))
    record(event.session, SessionFacts.reportRoutedEvent, ["report": report, "owner": .string(owner)])
    record(owner, SessionFacts.operatorAskEvent, ["report": report, "text": event.data["text"] ?? ""])
  }

  /// Sets every session's `operatorItems` to what `OperatorItems.assign` gives now, and re-tracks each session whose
  /// items changed. It records no event, so `fold` may call it.
  func syncOperatorItems() {
    var assigned: [String: OperatorItems] = [:]
    if let op = operatorID(), let e = entries[op] {
      assigned = OperatorItems.assign(
        openReports: e.facts.openReports, reportOwners: e.facts.reportOwners, waits: e.session.waits ?? [],
        operatorID: op, isLive: mayOwnOperatorItems, newestConversation: newestConversation())
    }
    let now = nowMs()
    for id in entries.keys.sorted() {
      let items = assigned[id] ?? OperatorItems()
      guard var e = entries[id], e.facts.operatorItems != items else { continue }
      e.facts.operatorItems = items
      let verdict = Attention.track(e.session, &e.facts, now: now, stateOf: lastState)
      entries[id] = e
      afterTrack(id, verdict)
    }
  }

  /// The `sent` data that names the conversation that handed the Operator the wait whose message it is (Decision 36).
  func handedFromData(_ holder: String, _ wait: Wait) -> [String: JSON] {
    guard entries[holder]?.session.kind == .operator, let from = wait.handedFrom else { return [:] }
    return ["handedFrom": .string(from.id)]
  }
}
