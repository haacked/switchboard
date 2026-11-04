import Foundation
import SwitchboardCore

/// The plan documents that groups and sessions have attached.
extension Service {
  /// The requests that don't read or write the document. They run on the state queue.
  func planRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "plan-ls":
      var list = plans.values.sorted { $0.id < $1.id }
      if args["group"] != nil {
        let group = try lookupGroup(args)
        list = list.filter { $0.group == group }
      }
      if args["session"] != nil {
        let session = try lookup(args)
        list = list.filter { $0.session == session }
      }
      return try JSON(encoding: list.map(PlanSummary.init))
    case "plan-get":
      return try JSON(encoding: plans[try lookupPlan(args)]!)
    case "plan-detach":
      let id = try lookupPlan(args)
      try detachPlans { $0.id == id }
      return ["detached": .string(id)]
    case "plan-auto":
      let id = try lookupPlan(args)
      guard let on = args["on"]?.bool else { throw APIError("plan auto needs on or off") }
      updatePlan(id) { $0.autoUpdate = on }
      return try JSON(encoding: plans[id]!)
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// The requests that read or write a document. They run off the state
  /// queue, because they wait on GitHub or the disk.
  func planDocumentRequest(_ op: String, _ args: JSON) throws -> JSON {
    guard let github else { throw APIError("sbd has no GitHub poller") }
    switch op {
    case "plan-attach":
      var plan = try queue.sync { try newPlan(args) }
      var stats = GitHubPoller.Stats()
      let now = nowMs()
      let text = try github.queue.sync { try github.fetchPlan(plan, all: true, now: now, stats: &stats) }
      plan.update(from: text ?? "", now: now)
      return try queue.sync {
        if let taken = plans.values.first(where: {
          $0.source == plan.source && $0.group == plan.group && $0.session == plan.session
        }) {
          throw APIError("\(plan.source.text) is attached as \(taken.id)")
        }
        try savePlan(plan)
        joinPlanGroups()
        return try JSON(encoding: plan)
      }
    case "plan-update":
      let id = try queue.sync { try lookupPlan(args) }
      var stats = GitHubPoller.Stats()
      let wrote = try github.queue.sync { try github.writePlan(id, now: nowMs(), stats: &stats) }
      return try queue.sync {
        guard let plan = plans[id], var out = try JSON(encoding: plan).object else { throw APIError("no plan \(id)") }
        out["wrote"] = .bool(wrote)
        return .object(out)
      }
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// A plan for the document that `doc` names, attached to `group` or
  /// `session`, which sbd hasn't read or saved yet.
  private func newPlan(_ args: JSON) throws -> PlanDocument {
    guard let doc = args["doc"]?.string, !doc.isEmpty else { throw APIError("plan attach needs a document") }
    let source = try PlanSource(parsing: doc, path: args["path"]?.string, cwd: args["cwd"]?.string ?? home.path)
    let group = try args["group"].map { _ in try lookupGroup(args) }
    let session = try args["session"].map { _ in try lookup(args) }
    guard (group == nil) != (session == nil) else { throw APIError("attach the plan to a group or to a session") }
    return PlanDocument(
      id: shortId("p", taken: plans.keys), source: source, group: group, session: session, attached: nowMs())
  }

  /// Finds a plan by id or unique id prefix, or by its document's text.
  private func lookupPlan(_ args: JSON) throws -> String {
    guard let key = args["plan"]?.string, !key.isEmpty else { throw APIError("name a plan") }
    return try resolve(key, "plan", plans.values.map { ($0.id, $0.source.text) })
  }

  private func savePlan(_ plan: PlanDocument) throws {
    try store.save(plan: plan)
    plans[plan.id] = plan
  }

  /// Changes the plan and saves it when it changed. A plan that was detached
  /// meanwhile stays detached.
  func updatePlan(_ id: String, _ change: (inout PlanDocument) -> Void) {
    guard var plan = plans[id] else { return }
    change(&plan)
    guard plan != plans[id] else { return }
    do {
      try savePlan(plan)
    } catch {
      logLine("plans: can't save \(id): \(error)")
    }
  }

  func recordPlanError(_ id: String, _ error: Error) {
    updatePlan(id) { $0.error = "\(error)" }
  }

  /// Detaches the plans of a group or a session that is going away.
  func detachPlans(where owned: (PlanDocument) -> Bool) throws {
    for plan in plans.values where owned(plan) {
      try store.delete(plan: plan.id)
      plans[plan.id] = nil
    }
  }

  /// Moves each session whose PR a group's plan links into that group. A
  /// session that the user placed by hand stays, and so does one whose PR
  /// the plans of more than one group link.
  func joinPlanGroups() {
    var linkedBy: [PlanLink: Set<String>] = [:]
    for plan in plans.values {
      guard let group = plan.group, groups[group] != nil else { continue }
      for link in plan.links { linkedBy[link.key, default: []].insert(group) }
    }
    guard !linkedBy.isEmpty else { return }
    for (id, e) in entries where groupable(e.session) && e.session.placedByHand != true {
      guard let pr = e.facts.pr, let linking = linkedBy[PlanLink(repo: pr.repo, number: pr.number).key],
        linking.count == 1, let group = linking.first, e.session.group != group
      else { continue }
      do {
        try update(id) { $0.group = group }
      } catch {
        logLine("plans: can't move \(id) into \(group): \(error)")
      }
    }
  }

  /// The generated table for the plan: the group's sessions, or the plan's session.
  func planTable(_ plan: PlanDocument) -> String {
    let sessions = plan.group.map(members) ?? plan.session.flatMap { entries[$0]?.session }.map { [$0] } ?? []
    return Plans.table(sessions.map(\.id).map(summary))
  }

  /// The plans of a group, or nil when it has none.
  func planSummaries(group: String) -> [PlanSummary]? {
    nonEmpty(plans.values.filter { $0.group == group })
  }

  /// The plans attached to the session and to its group, or nil when there are none.
  func planSummaries(session s: Session) -> [PlanSummary]? {
    nonEmpty(plans.values.filter { $0.session == s.id || ($0.group != nil && $0.group == s.group) })
  }

  private func nonEmpty(_ list: [PlanDocument]) -> [PlanSummary]? {
    list.isEmpty ? nil : list.sorted { $0.id < $1.id }.map(PlanSummary.init)
  }
}
