import Foundation
import SwitchboardCore

/// Follow-ups made from the Not started rows of plan documents.
extension Service {
  /// Maps a plan's document, then a row's item, to the lowest id of a
  /// follow-up made from that row.
  typealias PlanRowFollowups = [PlanSource: [String: String]]

  /// Makes a follow-up from a row that links no PR and whose status reads
  /// Not started. The row's item is its title and prompt. The checks and the
  /// add run in one turn of the state queue, so two requests make one follow-up.
  func planFollowup(_ args: JSON) throws -> SessionSummary {
    try queue.sync {
      let plan = plans[try lookupPlan(args)]!
      guard let ref = args["row"]?.string, !ref.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw APIError("name a row of \(plan.id)")
      }
      let row = try Plans.row(ref, in: reported(plan, planRowFollowups()).rows)
      if let pr = row.prs.first {
        throw APIError("row \(row.label) links \(pr.link.text). A follow-up comes from a row with no PR")
      }
      if let followup = row.followup { throw APIError("row \(row.label) has the follow-up \(followup)") }
      guard row.notStarted, let item = row.item else {
        throw APIError("row \(row.label) reads \(row.status ?? "no status"), not Not started")
      }
      let followup = Followup(
        prompt: item, repository: sharedRepository(plan) ?? plan.source.repo, link: plan.source.link,
        planRow: Followup.PlanRowRef(source: plan.source, item: item))
      return try insertFollowup(followup, parent: plan.session, group: plan.group)
    }
  }

  /// The one `owner/name` that the plan's sessions name through their
  /// follow-up or their PR, or nil when they name none or more than one.
  private func sharedRepository(_ plan: PlanDocument) -> String? {
    let names = planSessions(plan).filter(groupable).compactMap { s in
      s.followup?.repository ?? entries[s.id]?.facts.pr?.repo
    }
    return Set(names.map { $0.lowercased() }).count == 1 ? names.first : nil
  }

  func planRowFollowups() -> PlanRowFollowups {
    guard !plans.isEmpty else { return [:] }
    var rowFollowups: PlanRowFollowups = [:]
    for (id, e) in entries {
      guard let ref = e.session.followup?.planRow else { continue }
      rowFollowups[ref.source, default: [:]][ref.item] = min(rowFollowups[ref.source]?[ref.item] ?? id, id)
    }
    return rowFollowups
  }

  /// The plan with each row's follow-up filled in.
  func reported(_ plan: PlanDocument, _ rowFollowups: PlanRowFollowups) -> PlanDocument {
    var out = plan
    out.artifact?.stale = Plans.copyStale(read: plan.read, now: nowMs())
    guard let items = rowFollowups[plan.source] else { return out }
    for i in out.rows.indices { out.rows[i].followup = out.rows[i].item.flatMap { items[$0] } }
    return out
  }
}
