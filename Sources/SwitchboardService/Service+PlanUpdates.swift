import Foundation
import SwitchboardCore

/// Status cells that the model rewrites, and rows for sessions that no row
/// covers. `plans/plan-model-updates.md` in the notes repo describes them.
extension Service {
  /// What an update turn needs, taken from the state when it starts.
  struct PlanJob {
    var plan: PlanDocument
    var rows: [PlanRow]
    var env: [String: String]
    var folder: String
  }

  // MARK: Requests

  /// The requests that change only sbd's state. They run on the state queue.
  func planProposalRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "plan-proposals":
      var list = try planProposals()
      if args["group"] != nil {
        let group = try lookupGroup(args)
        list = list.filter { $0.group == group }
      }
      if args["plan"] != nil {
        let plan = try lookupPlan(args)
        list = list.filter { $0.plan == plan }
      }
      return try JSON(encoding: list)
    case "plan-reject":
      let proposal = try lookupProposal(args)
      switch proposal.kind {
      case .update:
        updatePlan(proposal.plan) {
          $0.proposal = nil
          $0.settled = proposal.key
        }
      case .row:
        try store.decline(suggestion: proposal.id)
      }
      return ["rejected": .string(proposal.id)]
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// The requests that run the model or write a document. They run off the
  /// state queue, because they wait on claude, GitHub, or the disk.
  func planProposalDocumentRequest(_ op: String, _ args: JSON) throws -> JSON {
    guard let github else { throw APIError("sbd has no GitHub poller") }
    switch op {
    case "plan-propose":
      let job = try queue.sync { try startPlanUpdate(try lookupPlan(args)) }
      let (proposal, applied) = try runPlanUpdate(job, github: github, now: nowMs())
      guard var out = try JSON(encoding: proposal).object else { throw APIError("can't encode the proposal") }
      out["applied"] = .bool(applied)
      return .object(out)
    case "plan-apply":
      let proposal = try queue.sync { try lookupProposal(args) }
      try applyProposal(proposal, github: github)
      return try queue.sync {
        guard let plan = plans[proposal.plan] else { throw APIError("no plan \(proposal.plan)") }
        return try JSON(encoding: reported(plan, planRowFollowups()))
      }
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// The updates that wait for the user, then the suggested rows. An update
  /// shows its plan's group now, which a group merge may have changed.
  func planProposals() throws -> [PlanProposal] {
    let sorted = plans.values.sorted { $0.id < $1.id }
    let updates = sorted.compactMap { plan in
      plan.proposal.map { proposal in
        var proposal = proposal
        proposal.group = plan.group
        return proposal
      }
    }
    return updates + (try rowSuggestions(sorted))
  }

  /// A row for each session of a plan's group whose PR no row of the plan
  /// links, unless the user declined it. A plan needs a work table.
  private func rowSuggestions(_ list: [PlanDocument]) throws -> [PlanProposal] {
    let declined = try store.declinedSuggestions()
    var out: [PlanProposal] = []
    for plan in list {
      guard let group = plan.group, let table = plan.workTable else { continue }
      let linked = Set(plan.rows.flatMap(\.prs).map(\.link.key))
      for session in members(group).sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) {
        guard let pr = entries[session.id]?.facts.pr else { continue }
        let link = PlanLink(repo: pr.repo, number: pr.number)
        let id = "\(plan.id):\(link.key.text)"
        guard !linked.contains(link.key), !declined.contains(id) else { continue }
        let row = PlanUpdates.newRow(table, pr: link, title: pr.title, stage: PlanStage(pr.state))
        out.append(
          PlanProposal(
            id: id, kind: .row, plan: plan, made: plan.read ?? plan.attached,
            edits: [PlanEdit(new: row, after: table.last)], session: session.id, pr: link))
      }
    }
    return out
  }

  private func lookupProposal(_ args: JSON) throws -> PlanProposal {
    guard let key = args["proposal"]?.string, !key.isEmpty else { throw APIError("name a proposal") }
    let list = try planProposals()
    let id = try resolveRef(key, "proposal", list.map { ($0.id, $0.id) })
    return list.first { $0.id == id }!
  }

  // MARK: Update turns

  /// Starts a turn for each plan that is due: one whose out-of-date rows
  /// changed since its last batch, at least `PlanUpdates.batchMs` after that
  /// batch. A plan that must wait says until when.
  func startDuePlanUpdates(now: Int64) {
    guard let github else { return }
    let jobs = queue.sync { () -> [PlanJob] in
      var jobs: [PlanJob] = []
      for plan in plans.values.sorted(by: { $0.id < $1.id }) where !planUpdatesRunning.contains(plan.id) {
        switch PlanUpdates.due(plan, now: now) {
        case .skip:
          if PlanUpdates.editable(plan).isEmpty {
            updatePlan(plan.id) {
              $0.updateNote = nil
              $0.proposal = nil
            }
          }
        case .wait(let until):
          // A failed batch's reason stays on the plan until the next batch runs.
          updatePlan(plan.id) {
            if $0.updateNote == nil { $0.updateNote = "the next update waits until \(Wait.formatTime(until))" }
          }
        case .run:
          // A plan with no quota left gets a note. The next poll checks the quota again.
          if let job = try? startPlanUpdate(plan.id) { jobs.append(job) }
        }
      }
      return jobs
    }
    for job in jobs {
      planJobs.addOperation { [self] in _ = try? runPlanUpdate(job, github: github, now: now) }
    }
  }

  /// Checks that the plan has rows to update and that its account has quota
  /// left, and marks its turn as running. Runs on the state queue.
  func startPlanUpdate(_ id: String) throws -> PlanJob {
    guard let plan = plans[id] else { throw APIError("no plan \(id)") }
    guard !planUpdatesRunning.contains(id) else { throw APIError("an update of \(plan.source.text) is running") }
    let rows = PlanUpdates.editable(plan)
    guard !rows.isEmpty else { throw APIError("\(plan.source.text) has no out-of-date rows with a Status column") }
    let (account, env, folder) = planTurnAccount(plan)
    guard quota.hasBudget(account: account) else {
      let note = "no quota left for \(account)"
      updatePlan(id) { $0.updateNote = note }
      throw APIError(note)
    }
    planUpdatesRunning.insert(id)
    return PlanJob(plan: plan, rows: rows, env: env, folder: folder)
  }

  /// The turn runs as the group's chat: under its account and in its folder.
  /// Without a chat, it runs under the account that new sessions use, in
  /// the state folder.
  private func planTurnAccount(_ plan: PlanDocument) -> (account: String, env: [String: String], folder: String) {
    if let group = plan.group, let chat = chatID(group) {
      let folder = home.chatFolder(group)
      return (
        claudeAccount(of: chat), headlessEnv(session: chat, account: nil),
        FileManager.default.fileExists(atPath: folder) ? folder : home.path
      )
    }
    return (activeAccount, headlessEnv(session: nil, account: activeAccount), home.path)
  }

  /// Asks the model for the rows' new status cells, checks its answer, and
  /// stores the proposal. A plan with auto update applies it at once. It
  /// returns the proposal and whether it was applied. Runs off the state queue.
  func runPlanUpdate(_ job: PlanJob, github: GitHubPoller, now: Int64) throws -> (PlanProposal, Bool) {
    let id = job.plan.id
    defer { queue.sync { _ = planUpdatesRunning.remove(id) } }
    let key = PlanUpdates.key(job.rows)
    let proposal: PlanProposal
    do {
      var stats = GitHubPoller.Stats()
      let text = try github.queue.sync { try github.readDocument(job.plan.source, stats: &stats) }
      let output = try runHeadless(
        PlanUpdates.arguments(model: config.planUpdates.model), input: PlanUpdates.input(rows: job.rows), env: job.env,
        folder: job.folder, timeout: config.planUpdates.timeoutSeconds)
      let edits = try PlanUpdates.edits(
        PlanUpdates.parse(output), rows: job.rows, markdown: text,
        today: Date(timeIntervalSince1970: Double(now) / 1000))
      guard !edits.isEmpty else {
        queue.sync { updatePlan(id) { $0.settled = key } }
        throw APIError("the model left every row as it was")
      }
      try PlanUpdates.verify(old: text, new: try PlanUpdates.apply(text, edits), rows: job.rows)
      proposal = try queue.sync {
        guard plans[id] != nil else { throw APIError("\(job.plan.source.text) was detached") }
        let taken = plans.values.compactMap(\.proposal?.id)
        let proposal = PlanProposal(
          id: shortId("u", taken: taken), kind: .update, plan: job.plan, made: now, edits: edits, key: key)
        updatePlan(id) {
          $0.proposed = now
          $0.proposal = proposal
          $0.updateNote = nil
        }
        return proposal
      }
    } catch {
      // A failed batch waits like any other, so a broken answer doesn't spend quota at every poll.
      queue.sync {
        updatePlan(id) {
          $0.proposed = now
          $0.updateNote = "\(error)"
        }
      }
      throw error
    }
    guard job.plan.autoUpdate else { return (proposal, false) }
    try applyProposal(proposal, github: github)
    return (proposal, true)
  }

  // MARK: Apply

  /// Writes the proposal into the document as it is now, with the retries
  /// of `sb plan update`. An update must still pass `PlanUpdates.verify`.
  func applyProposal(_ proposal: PlanProposal, github: GitHubPoller) throws {
    guard let plan = queue.sync(execute: { plans[proposal.plan] }) else { throw APIError("no plan \(proposal.plan)") }
    let olds = Set(proposal.edits.compactMap(\.old))
    let rows = plan.rows.filter { olds.contains($0.text) }
    var stats = GitHubPoller.Stats()
    let written = try github.queue.sync {
      try github.writeDocument(plan.source, message: proposal.title, stats: &stats) { text in
        let new = try PlanUpdates.apply(text, proposal.edits)
        if proposal.kind == .update { try PlanUpdates.verify(old: text, new: new, rows: rows) }
        return new
      }
    }
    let now = nowMs()
    queue.sync {
      updatePlan(plan.id) {
        if $0.proposal?.id == proposal.id { $0.proposal = nil }
        if let written { $0.update(from: written, now: now) }
      }
    }
  }
}
