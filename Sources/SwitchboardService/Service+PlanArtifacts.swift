import Foundation
import SwitchboardCore

/// Plans in claude.ai artifacts. sbd can't reach an artifact. The group's
/// chat reads and publishes it and reports each result with `plan_artifact`.
/// `plans/artifact-plan-documents.md` in the notes repo describes the turns.
extension Service {
  /// Asks the group's chat to read a new artifact plan. A failure to reach
  /// the chat goes on the plan, which stays attached.
  func askChatToRead(_ id: String) {
    do {
      try sendArtifactTask(.read, id)
    } catch {
      queue.sync { recordPlanError(id, error) }
    }
  }

  /// The requests that send the chat a turn. They run off the state queue,
  /// because the chat may have to start.
  func artifactTurnRequest(_ op: String, _ args: JSON) throws -> JSON {
    let id = try queue.sync { try lookupArtifactPlan(args) }
    switch op {
    case "plan-artifact-read": try sendArtifactTask(.read, id)
    case "plan-artifact-rewrite": try requestArtifactRewrite(id, rows: args["rows"]?.array?.compactMap(\.string))
    case "plan-artifact-apply": try applyArtifactProposal(id)
    default: throw APIError("unknown request \(op)")
    }
    return try queue.sync { try JSON(encoding: reportedPlan(id)) }
  }

  /// Asks the chat to rewrite the rows that `refs` name, or the out-of-date
  /// rows without `refs`. The result arrives as a `proposal` report.
  func requestArtifactRewrite(_ id: String, rows refs: [String]?) throws {
    try queue.sync {
      let (plan, _, _) = try artifactCopy(id)
      let rows =
        try refs.map { try $0.map { try Plans.row($0, in: plan.rows).text } }
        ?? plan.rows.filter(\.outOfDate).map(\.text)
      guard !rows.isEmpty else { throw APIError("\(id) has no out-of-date rows. Name the rows to rewrite") }
      updatePlan(id) { $0.artifact?.rewrite = rows }
    }
    do {
      try sendArtifactTask(.rewrite, id)
    } catch {
      queue.sync { updatePlan(id) { $0.artifact?.rewrite = nil } }
      throw error
    }
  }

  /// The user approved the pending update: asks the chat to publish it.
  func applyArtifactProposal(_ id: String) throws {
    try queue.sync {
      guard plans[id]?.artifact?.proposal != nil else { throw APIError("\(id) has no update to apply") }
      updatePlan(id) {
        $0.artifact?.proposal?.state = .publishing
        $0.artifact?.proposal?.checked = false
      }
    }
    do {
      try sendArtifactTask(.publish, id)
    } catch {
      queue.sync { updatePlan(id) { $0.artifact?.proposal?.state = .pending } }
      throw error
    }
  }

  /// The requests that change only sbd's state. They run on the state queue.
  func artifactRequest(_ op: String, _ args: JSON) throws -> JSON {
    let id = try lookupArtifactPlan(args)
    switch op {
    case "plan-artifact-reject":
      guard plans[id]?.artifact?.proposal != nil || plans[id]?.artifact?.rewrite != nil else {
        throw APIError("\(id) has no update to reject")
      }
      updatePlan(id) {
        $0.artifact?.proposal = nil
        $0.artifact?.rewrite = nil
      }
    case "plan-artifact-report":
      try artifactReport(id, args)
      joinPlanGroups()
    default:
      throw APIError("unknown request \(op)")
    }
    return try JSON(encoding: reportedPlan(id))
  }

  /// Takes in what the chat reports from a turn.
  private func artifactReport(_ id: String, _ args: JSON) throws {
    guard let plan = plans[id], let artifact = plan.artifact else { throw APIError("no plan \(id)") }
    if let group = args["group"]?.string, plan.group != group {
      throw APIError("plan \(id) does not belong to group \(group)")
    }
    let kind = args["kind"]?.string ?? ""
    var text = args["text"]?.string
    if text == nil, let file = args["file"]?.string {
      guard let read = try? String(contentsOfFile: file.expandingTilde, encoding: .utf8) else {
        throw APIError("can't read \(file)")
      }
      text = read
    }
    let version = args["version"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    func needText() throws -> String {
      guard let text else { throw APIError("a \(kind) report needs the artifact's text") }
      return text
    }
    let now = nowMs()
    switch kind {
    case "read":
      let text = try needText()
      updatePlan(id) { $0.takeCopy(text, version: version, now: now) }
    case "proposal":
      let text = try needText()
      guard let rows = artifact.rewrite, let base = artifact.copy else {
        throw APIError("sbd asked for no rewrite of \(id), so it takes no proposal")
      }
      try Plans.checkRewrite(base: base, text: text, rows: rows)
      updatePlan(id) {
        $0.artifact?.proposal = ArtifactProposal(
          rows: rows, base: base, version: artifact.version, text: text, created: now)
        $0.artifact?.rewrite = nil
      }
    case "check":
      let text = try needText()
      guard let proposal = artifact.proposal, proposal.state == .publishing else {
        throw APIError("\(id) has no approved update to publish. Do not publish")
      }
      let moved = text != proposal.base || (version != nil && proposal.version != nil && version != proposal.version)
      guard moved else {
        updatePlan(id) { $0.artifact?.proposal?.checked = true }
        return
      }
      let reason =
        "the artifact changed since sbd's copy, so the update was not published. The copy now holds the new text. Propose the update again"
      updatePlan(id) {
        $0.takeCopy(text, version: version, now: now)
        $0.artifact?.proposal = nil
        $0.error = reason
      }
      throw APIError("\(reason). Do not publish")
    case "published":
      guard let proposal = artifact.proposal, proposal.state == .publishing, proposal.checked else {
        throw APIError("\(id) had no approved and checked update to publish")
      }
      updatePlan(id) {
        $0.takeCopy(proposal.text, version: version, now: now)
        $0.artifact?.proposal = nil
      }
    default:
      throw APIError("the report kind is read, proposal, check, or published")
    }
  }

  /// `sb plan update` for an artifact: the generated table goes into the
  /// copy as a proposal. It returns false when the copy already holds the table.
  func proposeArtifactTable(_ id: String) throws -> Bool {
    let (plan, artifact, copy) = try artifactCopy(id)
    let new = try Plans.splice(copy, planTable(plan))
    guard new != copy else { return false }
    updatePlan(id) {
      $0.artifact?.proposal = ArtifactProposal(
        rows: [], base: copy, version: artifact.version, text: new, created: nowMs())
    }
    return true
  }

  /// The plan, its artifact state, and its copy, for a new update. It
  /// refuses a plan with no copy, or with an update in progress.
  private func artifactCopy(_ id: String) throws -> (PlanDocument, ArtifactPlan, String) {
    guard let plan = plans[id], let artifact = plan.artifact else { throw APIError("no plan \(id)") }
    guard let copy = artifact.copy else {
      throw APIError("sbd has no copy of \(plan.source.text) yet. Run: sb plan artifact read \(id)")
    }
    if artifact.proposal != nil { throw APIError("\(id) has an update waiting. Apply or reject it first") }
    if artifact.rewrite != nil { throw APIError("\(id) waits for the chat's rewrite. Reject it to start over") }
    return (plan, artifact, copy)
  }

  private func lookupArtifactPlan(_ args: JSON) throws -> String {
    let id = try lookupPlan(args)
    guard plans[id]?.source.kind == .artifact else { throw APIError("\(plans[id]!.source.text) is not an artifact") }
    return id
  }

  func reportedPlan(_ id: String) throws -> PlanDocument {
    guard let plan = plans[id] else { throw APIError("no plan \(id)") }
    return reported(plan, planRowFollowups())
  }

  /// Writes the files that the task names into the chat's folder, then sends
  /// the chat the task.
  private func sendArtifactTask(_ task: Plans.ArtifactTask, _ id: String) throws {
    let (group, plan) = try queue.sync { () -> (String, PlanDocument) in
      guard let plan = plans[id], let group = plan.group else { throw APIError("no group plan \(id)") }
      return (group, plan)
    }
    let folder = "\(home.chatFolder(group))/plans"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let copy = "\(folder)/\(id).md"
    let proposed = "\(folder)/\(id).proposed.md"
    let url = plan.source.url ?? ""
    let text: String
    switch task {
    case .read:
      text = Plans.artifactTask(.read, plan: id, url: url)
    case .rewrite:
      try (plan.artifact?.copy ?? "").write(toFile: copy, atomically: true, encoding: .utf8)
      text = Plans.artifactTask(
        .rewrite, plan: id, url: url, copy: copy, write: proposed, rows: plan.artifact?.rewrite ?? [])
    case .publish:
      try (plan.artifact?.proposal?.text ?? "").write(toFile: proposed, atomically: true, encoding: .utf8)
      text = Plans.artifactTask(.publish, plan: id, url: url, publish: proposed)
    }
    let response = chatRequest(["group": .string(group), "text": .string(text)])
    if let error = response.error { throw APIError(error) }
  }
}

extension PlanDocument {
  /// Takes `text` as the artifact's copy.
  mutating func takeCopy(_ text: String, version: String?, now: Int64) {
    update(from: text, now: now)
    artifact?.copy = text
    artifact?.version = version
  }
}
