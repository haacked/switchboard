import Foundation
import SwitchboardCore

extension Service {
  /// The `ack` request, which marks the Inbox item of `session` as seen, or
  /// with `undo` puts it back. It changes nothing else about the session.
  /// `caller` is the asking session's id, which `lookupOther` refuses. A
  /// session that acknowledged itself could hide its own question from the user.
  func acknowledgeRequest(_ args: JSON) throws -> JSON {
    let id = try lookupOther(args, refusing: "acknowledge itself out of the Inbox")
    let e = entries[id]!
    let now = nowMs()
    let verdict = Attention.evaluate(e.session, e.facts, now: now, stateOf: lastState)
    if args["undo"]?.bool == true {
      // The operator's reports reopen even while a wait or a prompt gives it an item that hides Undo Acknowledge.
      let reopensReports = e.session.kind == .operator && !e.facts.acknowledgedReports.isEmpty
      guard shown(id, verdict, now: now).acknowledged || verdict.requested || reopensReports else {
        throw APIError("\(e.session.name) isn't acknowledged")
      }
      record(id, "unack")
    } else if let op = operatorID(),
      let ref = Triage.item(e.facts, shown(id, verdict, now: now), kind: e.session.kind)?.ref, Triage.isReportRef(ref)
    {
      try closeAsks(id, on: op, args)
    } else {
      // An ack closes the operator's open reports. Claude Code may not ack them for the user, as with `choose`.
      let closesReports = e.session.kind == .operator && e.facts.ackClosesReports
      if closesReports { try Service.refuseClaude(args, "an ack closes the operator's reports") }
      // A report from before routing shows on the session that it is about, so the operator can be out of the
      // Inbox. An ack on the operator still closes it (Decision 51 in the notes repo's
      // `plans/410-invisible-operator.md`).
      if closesReports, !AttentionState.inbox.contains(verdict.state) {
        record(id, "ack", try JSON(encoding: Acknowledgment(verdict, e.facts)))
      } else {
        try acknowledge(id, verdict)
      }
    }
    return try JSON(encoding: summary(id))
  }

  /// Closes the asks that the user saw on `id`'s item with a `report-closed` event on the operator `op`, which has
  /// no undo. It records no `ack` on `id`, so the item that the ask hid shows again (Decision 40 in the notes repo's
  /// `plans/410-invisible-operator.md`).
  private func closeAsks(_ id: String, on op: String, _ args: JSON) throws {
    try Service.refuseClaude(args, "an ack closes the operator's question")
    let ids = entries[id]!.facts.operatorItems.asks.map { JSON.number(Double($0.id)) }
    try recordStored(op, SessionFacts.reportClosedEvent, ["reports": .array(ids)])
  }

  /// Records the acknowledgment of the Inbox verdict that `evaluate` gave,
  /// unless the user already acknowledged it.
  func acknowledge(_ id: String, _ verdict: Verdict) throws {
    let e = entries[id]!
    guard !shown(id, verdict, now: nowMs()).acknowledged else { return }
    guard AttentionState.inbox.contains(verdict.state) else {
      throw APIError("\(e.session.name) isn't in the Inbox: \(verdict.reason)")
    }
    record(id, "ack", try JSON(encoding: Acknowledgment(verdict, e.facts)))
  }

  /// The request that a message sent with `ref` makes, or nil when `ref`
  /// doesn't name the session's current item, that item doesn't come from a
  /// rule, or the rule offers no send option. It records the verdict without
  /// the current request's hold, so a second click on an item whose hold
  /// ended matches the rule again.
  func inboxRequest(_ id: String, ref: String, message: String) -> InboxRequest? {
    let e = entries[id]!
    let now = nowMs()
    let shownVerdict = shown(id, Attention.evaluate(e.session, e.facts, now: now, stateOf: lastState), now: now)
    guard let item = Triage.item(e.facts, shownVerdict, kind: e.session.kind), item.ref == ref, item.source == .rule
    else { return nil }
    let verdict = Attention.unheld(e.session, e.facts, now: now, stateOf: lastState)
    // Only a rule that asks the session to do something holds. A permission or question prompt and Ready to merge
    // offer no send option.
    guard AttentionState.inbox.contains(verdict.state), verdict.options.contains(where: { $0.action == .send })
    else { return nil }
    return InboxRequest(
      verdict, e.facts, message: message, until: now + config.recheck.requestedMs,
      readMs: Int64(config.github.pollSeconds * 2000))
  }

  /// The verdict that the app and `sb` show for `id`, given the verdict that
  /// `evaluate` gave at `now`. Every caller goes through here, so the
  /// acknowledgment rules read the same settings everywhere. `facts` replaces the session's facts, as for a host's view.
  func shown(_ id: String, _ verdict: Verdict, now: Int64, facts: SessionFacts? = nil) -> Verdict {
    let e = entries[id]!
    return Attention.shown(
      verdict, facts ?? e.facts, now: now, acknowledgedMs: config.recheck.acknowledgedMs, kind: e.session.kind)
  }
}
