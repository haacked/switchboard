import Foundation
import SwitchboardCore

/// The top-up: when a gated schedule's group is short of its target, sbd lists the open issues and follow-ups, asks a
/// headless judge which to start, starts each pick in the gate's group, and arms the follow-through waits on the
/// Operator. Any failure on the way sends the schedule's fallback message instead.
extension Service {
  /// The most rows that a top-up asks gh for in each list.
  static let topupListLimit = 100

  /// Saves the schedule's next run, marks the schedule in flight, and runs its top-up on `topupQueue`. It runs on the
  /// state queue.
  func dispatchTopup(_ id: String, _ schedule: Schedule, status: QueueStatus, k: Int, now: Int64) {
    var ran = schedule
    guard let gate = schedule.gate, let skipped = saveNextRun(id, &ran, now: now) else { return }
    topupsInFlight.insert(schedule.id)
    topupQueue.async { [self] in
      defer { _ = queue.sync { topupsInFlight.remove(schedule.id) } }
      runTopup(id, schedule.id, gate: gate, status: status, k: k, skipped: skipped)
    }
  }

  /// One top-up. `status` is the gate's status at the due time, and `skipped` is the count of due times that the
  /// fallback's run skips. It runs on `topupQueue`, and it never starts a session inside `queue.sync`.
  private func runTopup(
    _ id: String, _ scheduleID: String, gate: Schedule.Gate, status: QueueStatus, k: Int, skipped: Int
  ) {
    let fail = { (failure: String) in
      self.fallBack(id, scheduleID, gate: gate, status: status, skipped: skipped, failure: failure)
    }
    let lists: (issues: [InboxIssue], openPRs: [TopupCandidates.OpenPR])
    do {
      lists = try topupLists(gate.repo)
    } catch {
      return fail("\(error)")
    }
    var dropped = ""
    let setup = queue.sync { () -> (holder: String, built: TopupCandidates, env: [String: String])? in
      if let refusal = scheduleRefusal(id, scheduleID) {
        dropped = refusal
        return nil
      }
      let holder = topupHolder(id)
      let followups = entries.values.map(\.session).filter { $0.waitsToStart && !starting.contains($0.id) }
      let built = TopupCandidates.build(
        repo: gate.repo, group: gate.group, issues: lists.issues, openPRs: lists.openPRs,
        sessions: coverageRows(gate: gate), followups: followups, viewer: issueCache.viewer, team: issueSettings.team)
      let env = headlessEnv(session: holder, account: triageAccount(for: holder).account)
      return (holder, built, env)
    }
    guard let setup else {
      return logLine("dropping the top-up of schedule \(scheduleID) of \(id), because \(dropped)")
    }
    let (holder, built, env) = setup
    guard !built.candidates.isEmpty else {
      return queue.sync {
        finishTopup(id, scheduleID, holder: holder, status: status, picks: [], started: [], skips: built.skips)
      }
    }

    let settings = operatorSettings
    let call = headlessCall(
      .topupPick, session: holder, arguments: TopupPick.arguments(model: settings.model),
      input: TopupPick.input(rubric: gate.rubric, k: k, candidates: built.candidates, sessions: status.counted),
      env: env, folder: home.path, timeout: Double(settings.topupTimeoutSeconds)
    ) { try TopupPick.parse($0, candidates: built.candidates, k: k) }
    let answer: TopupPick.Answer
    switch call.result {
    case .success(let value): answer = value
    case .failure(let error): return fail("\(error)")
    }

    var started: [(ref: String, session: SessionSummary)] = []
    var startErrors: [String] = []
    var skips = built.skips + answer.skips
    for pick in answer.picks {
      let refusal = queue.sync {
        scheduleRefusal(id, scheduleID)
          ?? pickRefusal(pick.candidate, gate: gate, openPRs: lists.openPRs, started: started.map(\.session.id))
      }
      if let refusal {
        skips.append(Schedule.Gate.Skip(ref: pick.ref, reason: refusal))
        continue
      }
      let session: SessionSummary
      do {
        session = try startPick(pick.candidate, gate: gate)
      } catch {
        skips.append(Schedule.Gate.Skip(ref: pick.ref, reason: "can't start it: \(error)"))
        startErrors.append("can't start \(pick.ref): \(error)")
        continue
      }
      started.append((pick.ref, session))
      queue.sync { recordTopupStart(id, scheduleID, session: session.id, holder: holder) }
    }
    // A pick that the re-check refused is not a start failure.
    if let first = startErrors.first, startErrors.count == answer.picks.count {
      return fallBack(id, scheduleID, gate: gate, status: status, skipped: skipped, failure: first, skips: skips)
    }
    queue.sync {
      finishTopup(
        id, scheduleID, holder: holder, status: status, picks: answer.picks, started: started, skips: skips)
    }
  }

  /// The open issues and the open PRs of `repo`, read with gh. It throws when either read fails or prints rows that
  /// sbd can't read, and when the PR list may be cut off, because a PR that sbd doesn't see may cover an issue. An
  /// issue row that sbd can't read only drops a candidate, so it is left out. It runs off the state queue.
  private func topupLists(_ repo: String) throws -> (issues: [InboxIssue], openPRs: [TopupCandidates.OpenPR]) {
    let limit = "\(Self.topupListLimit)"
    let issues = try ghRows(
      [
        "issue", "list", "--repo", repo, "--state", "open", "--limit", limit, "--json",
        "number,title,url,body,labels,author,createdAt,updatedAt",
      ], what: "the open issues of \(repo)")
    let prs = try ghRows(
      [
        "pr", "list", "--repo", repo, "--state", "open", "--limit", limit, "--json",
        "number,headRefName,closingIssuesReferences",
      ], what: "the open PRs of \(repo)")
    guard prs.count < Self.topupListLimit else {
      throw APIError("\(repo) has \(limit) or more open PRs, so sbd can't tell which issues they cover")
    }
    let openPRs = try prs.map { row in
      guard let pr = Self.openPR(row) else { throw APIError("can't read an open PR of \(repo) that gh printed") }
      return pr
    }
    return (issues.compactMap { Self.inboxIssue($0, repo: repo) }, openPRs)
  }

  /// Saves `session` in the gate's `started` and arms the removal of its worktree once it is done, held by `holder`.
  /// It runs on the state queue.
  private func recordTopupStart(_ id: String, _ scheduleID: String, session: String, holder: String) {
    do {
      try changeSchedule(id, scheduleID) { s in
        // The exclusivity check refuses a read of `s.gate` inside an optional-chained assignment to it.
        let ids = (s.gate?.started ?? []) + [session]
        s.gate?.started = ids
      }
    } catch {
      logLine("can't save \(session) as started by the top-up of schedule \(scheduleID): \(error)")
    }
    do {
      try armSessionWait(holder: holder, target: session, state: AttentionState.done.rawValue, then: .rmWorktree)
    } catch {
      logLine("can't arm the removal of \(session) for the top-up of schedule \(scheduleID): \(error)")
    }
  }

  private func ghRows(_ args: [String], what: String) throws -> [JSON] {
    let text: String
    do {
      text = try runGh(args, timeout: 30)
    } catch {
      throw APIError("can't list \(what): \(error)")
    }
    guard let rows = JSON.parse(text)?.array else { throw APIError("can't read the list of \(what) that gh printed") }
    return rows
  }

  /// One row of `gh issue list --json number,title,url,body,labels,author,createdAt,updatedAt`.
  private static func inboxIssue(_ row: JSON, repo: String) -> InboxIssue? {
    guard let number = row["number"]?.int, let title = row["title"]?.string, let url = row["url"]?.string else {
      return nil
    }
    return InboxIssue(
      repo: repo, number: number, title: title, url: url, body: row["body"]?.string ?? "",
      labels: (row["labels"]?.array ?? []).compactMap { $0["name"]?.string }, author: row["author"]?["login"]?.string,
      createdAt: row["createdAt"]?.string ?? "", updatedAt: row["updatedAt"]?.string ?? "")
  }

  /// One row of `gh pr list --json number,headRefName,closingIssuesReferences`, or nil when a field is missing. gh
  /// names a closing reference's repository by `owner.login` and `name`.
  private static func openPR(_ row: JSON) -> TopupCandidates.OpenPR? {
    guard let number = row["number"]?.int, let branch = row["headRefName"]?.string,
      let references = row["closingIssuesReferences"]?.array
    else { return nil }
    var closes: [IssueRef] = []
    for reference in references {
      guard let issue = reference["number"]?.int else { return nil }
      let repository = reference["repository"]
      let name = repository?["owner"]?["login"]?.string.flatMap { owner in
        repository?["name"]?.string.map { "\(owner)/\($0)" }
      }
      closes.append(IssueRef(repo: name, number: issue))
    }
    return TopupCandidates.OpenPR(number: number, headRefName: branch, closes: closes)
  }

  /// Every session sbd has, as the candidate list of `gate` reads it for coverage: a row for its current branch and
  /// one for the branch it started on. It runs on the state queue.
  private func coverageRows(gate: Schedule.Gate) -> [TopupCandidates.SessionRow] {
    entries.values.flatMap { e in
      let repository = repository(of: e, checkout: checkout(e.session), gate: gate)
      // A session that switched branches may still work on the issue that its first branch names.
      return Set([e.branch, e.session.branch]).map { branch in
        TopupCandidates.SessionRow(
          repository: repository, branch: branch, prNumber: e.facts.pr?.number, issue: e.session.issue,
          closesIssues: e.facts.pr?.closesIssues)
      }
    }
  }

  /// Why the schedule can't start sessions now, or nil when it can: the session no longer has it, it is paused, or
  /// `Schedule.hold` holds its session. It runs on the state queue.
  private func scheduleRefusal(_ id: String, _ scheduleID: String) -> String? {
    guard let s = entries[id]?.session, let schedule = s.schedule(scheduleID) else {
      return "\(id) no longer has the schedule"
    }
    if schedule.paused == true { return "the schedule is paused" }
    return s.scheduleHold
  }

  /// Why a pick can't start now, or nil when it can: the group has reached its target, counting the sessions that
  /// this top-up started, a session needs attention or sbd can't read one, a session or an open PR covers the issue
  /// now, or the follow-up is no longer a candidate. It runs on the state queue.
  private func pickRefusal(
    _ candidate: TopupCandidates.Candidate, gate: Schedule.Gate, openPRs: [TopupCandidates.OpenPR], started: [String]
  ) -> String? {
    if let refusal = QueueStatus.startRefusal(
      queueRows(subjects: actionSubjects(), gate: gate), gate: gate, started: started)
    {
      return refusal
    }
    switch candidate {
    case .issue(let issue):
      let fresh = TopupCandidates.build(
        repo: gate.repo, group: gate.group, issues: [issue], openPRs: openPRs, sessions: coverageRows(gate: gate),
        followups: [], viewer: issueCache.viewer, team: issueSettings.team)
      guard !fresh.candidates.contains(candidate) else { return nil }
      return fresh.skips.first?.reason ?? "a session covers it now"
    case .followup(let followupID, _):
      let followups = [entries[followupID]?.session].compactMap { $0 }.filter { !starting.contains($0.id) }
      let fresh = TopupCandidates.build(
        repo: gate.repo, group: gate.group, issues: [], openPRs: [], sessions: [], followups: followups,
        viewer: issueCache.viewer, team: issueSettings.team)
      // The candidate carries the prompt, so an edited prompt would not match the candidate itself.
      guard !fresh.candidates.contains(where: { $0.ref == candidate.ref }) else { return nil }
      return "the follow-up is no longer one that the top-up may start"
    }
  }

  /// Starts an issue from the gate's template in the gate's group, or a follow-up with its own prompt. It runs off
  /// the state queue.
  private func startPick(_ candidate: TopupCandidates.Candidate, gate: Schedule.Gate) throws -> SessionSummary {
    switch candidate {
    case .issue(let issue):
      return try startIssueSession(
        issue, prompt: IssuePreset(name: "topup", prompt: gate.template).prompt(for: issue), group: gate.group,
        path: nil, manualMode: false)
    case .followup(let id, _):
      return try startFollowup(["session": .string(id)])
    }
  }

  /// It sends nothing. It runs on the state queue.
  private func finishTopup(
    _ id: String, _ scheduleID: String, holder: String, status: QueueStatus, picks: [TopupPick.Pick],
    started: [(ref: String, session: SessionSummary)], skips: [Schedule.Gate.Skip]
  ) {
    let check = Schedule.Gate.Check(
      .started, status: status, now: nowMs(), started: started.map(\.session.id), skipped: skips)
    do {
      try changeSchedule(id, scheduleID) { $0.gate?.last = check }
    } catch {
      logLine("can't save the top-up check of schedule \(scheduleID) of \(id): \(error)")
    }
    let schedule = entries[id]?.session.schedule(scheduleID)
    let data = gateEventData(
      schedule, status: status,
      [
        "picks": .array(picks.map { ["ref": .string($0.ref), "reason": .string($0.reason)] }),
        "started": .array(started.map { ["ref": .string($0.ref), "session": .string($0.session.id)] }),
        "skipped": (try? JSON(encoding: skips)) ?? .array([]),
      ])
    record(id, "schedule-topup", data)
    guard !started.isEmpty else { return }
    do {
      try recordReport(Self.topupReport(started: started, skips: skips), needsYou: false, about: nil, on: holder)
    } catch {
      logLine("can't record the report of the top-up of schedule \(scheduleID): \(error)")
    }
  }

  /// Such as "Top-up: started fix-the-cache (#12), inbox-dupes (#15); skipped #9: needs a design decision".
  static func topupReport(started: [(ref: String, session: SessionSummary)], skips: [Schedule.Gate.Skip]) -> String {
    let names = started.map { "\($0.session.name) (\($0.ref))" }.joined(separator: ", ")
    let passed = skips.map { "\($0.ref): \($0.reason)" }.joined(separator: "; ")
    return "Top-up: started \(names)" + (passed.isEmpty ? "" : "; skipped \(passed)")
  }

  /// Sends the schedule's fallback message with the failure on its first line, and records the run with a failed
  /// check that lists `skips`. When the session isn't free, it saves the failed check, sends nothing, and records no
  /// run, so the next due time tries again. When `scheduleRefusal` refuses the schedule, it sends and saves nothing.
  /// It runs off the state queue.
  private func fallBack(
    _ id: String, _ scheduleID: String, gate: Schedule.Gate, status: QueueStatus, skipped: Int, failure: String,
    skips: [Schedule.Gate.Skip] = []
  ) {
    logLine("the top-up of schedule \(scheduleID) of \(id) failed: \(failure)")
    queue.sync {
      if let refusal = scheduleRefusal(id, scheduleID) {
        return logLine("not sending the fallback of schedule \(scheduleID) of \(id), because \(refusal)")
      }
      guard let e = entries[id], let schedule = e.session.schedule(scheduleID) else {
        return
      }
      let now = nowMs()
      let check = Schedule.Gate.Check(.failed, status: status, now: now, skipped: skips, error: failure)
      // A busy session would queue the message, and each later failed top-up would queue another behind it.
      if let blocker = pasteBlocker(id, e, now: now) {
        logLine("not sending the fallback of schedule \(scheduleID) of \(id), because \(blocker)")
        do {
          try changeSchedule(id, scheduleID) { $0.gate?.last = check }
        } catch {
          logLine("can't save the failed check of schedule \(scheduleID) of \(id): \(error)")
        }
        return
      }
      let text = gate.fallbackMessage(status: status, prompt: schedule.prompt, failure: failure)
      sendAndRecord(id, schedule, text: text, skipped: skipped, check: check, now: now)
    }
  }

  private func topupHolder(_ id: String) -> String { operatorID() ?? id }

  /// For each session that a top-up started and that sbd still has, arms the merge of its open PR once it is Ready
  /// to merge, held by the Operator, when `operator.mergeRepos` lists the PR's repository and no wait will merge it
  /// yet. It drops from each gate's `started` the ids that sbd no longer has and each id whose merge it armed, so it
  /// arms each session's merge once. The tick calls it on the state queue.
  func armTopupMerges() {
    let owners = entries.filter { _, e in e.session.allSchedules.contains { $0.gate?.started?.isEmpty == false } }
    guard !owners.isEmpty else { return }
    var candidates: [(id: String, scheduleID: String, subject: String, repo: String)] = []
    for (id, e) in owners.sorted(by: { $0.key < $1.key }) {
      for schedule in e.session.allSchedules {
        guard let started = schedule.gate?.started, !started.isEmpty else { continue }
        let kept = started.filter { entries[$0] != nil }
        if kept != started {
          do {
            try changeSchedule(id, schedule.id) { $0.gate?.started = kept.isEmpty ? nil : kept }
          } catch {
            logLine("can't prune the started sessions of schedule \(schedule.id) of \(id): \(error)")
          }
        }
        for subject in kept {
          guard let s = entries[subject], !s.session.done, let pr = s.facts.pr, pr.state == .open else { continue }
          candidates.append((id, schedule.id, subject, pr.repo))
        }
      }
    }
    guard !candidates.isEmpty else { return }
    var merging = actionSubjects().merging
    let settings = operatorSettings
    for c in candidates where !merging.contains(c.subject) && settings.mergesIn(c.repo) {
      do {
        try armSessionWait(
          holder: topupHolder(c.id), target: c.subject, state: AttentionState.readyToMerge.rawValue, then: .merge)
        merging.insert(c.subject)
      } catch {
        logLine("can't arm the merge of \(c.subject) for schedule \(c.scheduleID): \(error)")
        continue
      }
      do {
        try changeSchedule(c.id, c.scheduleID) { s in
          let rest = (s.gate?.started ?? []).filter { $0 != c.subject }
          s.gate?.started = rest.isEmpty ? nil : rest
        }
      } catch {
        logLine("can't drop \(c.subject) from the started sessions of schedule \(c.scheduleID): \(error)")
      }
    }
  }
}
