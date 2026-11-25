import Foundation
import SwitchboardCore
import os

/// Wait actions: when an action wait's condition is met, sbd runs the action with its checks on
/// `followThroughQueue`, off the state queue, and records the result. Anything that needs judgment goes to the
/// wait's holder as one question.
extension Service {
  /// What one run of an action ended with.
  enum ActionOutcome {
    /// The action ran or was already done. With `reports`, `detail` becomes an info report on the operator. `merged`
    /// is the PR that a merge action merged, which `finish` records as sbd's last merge in its repository.
    case done(result: String, detail: String, reports: Bool, merged: SbdMergeRecord? = nil)
    /// Not yet. `message` goes to the subject once per `messageKey`.
    case hold(reason: String, message: String? = nil, messageKey: String? = nil)
    /// The subject is no longer in the wait's state, so the wait waits for its condition again.
    case rearm
    /// The holder must decide. `approval` is what `sb operator approve` approves, for a question about the reply,
    /// and `reply` is the last reply whose digest it covers.
    case judgment(question: String, approval: MergeGuard.Approval? = nil, reply: String? = nil)
  }

  /// config.json's `operator` settings. sbd reads them again when config.json's modification date changes, so an
  /// edit takes effect without a restart. A config.json that doesn't decode allows no merges and keeps the hold
  /// timing that sbd started with.
  var operatorSettings: OperatorSettings {
    let stamp = try? FileManager.default.attributesOfItem(atPath: home.config)[.modificationDate] as? Date
    if let read = operatorSettingsRead.withLock({ $0 }), read.stamp == stamp { return read.settings }
    let settings: OperatorSettings
    do {
      settings = try home.readConfig().operator
    } catch {
      logLine("ignoring \(home.config) for operator settings: \(error)")
      var fallback = config.operator
      fallback.mergeRepos = []
      settings = fallback
    }
    operatorSettingsRead.withLock { $0 = (stamp, settings) }
    return settings
  }

  /// Marks the action running, stores it, and runs it on `followThroughQueue`.
  ///
  /// The run keeps a hold's start time, its message key, and an approval. `approval` replaces the stored one. It runs
  /// on the state queue.
  func startAction(_ holder: String, _ wait: Wait, approval: MergeGuard.Approval? = nil) throws {
    var status = wait.actionStatus ?? ActionStatus(kind: .running, since: nowMs())
    status.kind = .running
    status.retryAt = nil
    if let approval { status.approval = approval }
    try setActionStatus(holder, wait.id, status)
    followThroughQueue.async { [self] in runAction(holder, wait.id) }
  }

  /// A PR of `subject` that a merge action merged, with its changed files and its merge commit. A nil field is one
  /// that sbd did not read.
  struct SbdMergeRecord {
    var subject: String
    var repo: String
    var number: Int
    var files: Set<String>?
    var commit: String?
  }

  /// Rebuilds `lastSbdMerges` from the newest `wait-resolved` events of merge actions that merged, so a restart
  /// keeps the hold on a base whose checks run on sbd's own merge. It runs on the state queue.
  func loadSbdMerges() {
    let events = (try? store.events(kinds: ["wait-resolved"], limit: 500, newest: true)) ?? []
    for event in events.sorted(by: { $0.id < $1.id }) {
      let action = event.data["action"]
      guard action?["kind"]?.string == WaitAction.Kind.merge.rawValue,
        action?["result"]?.string == MergeAttempt.Result.merged.rawValue, let repo = action?["repo"]?.string,
        let number = action?["pr"]?.int, let subject = event.data["wait"]?["session"]?["id"]?.string
      else { continue }
      let files = action?["files"]?.array.map { Set($0.compactMap(\.string)) }
      lastSbdMerges[repo.lowercased()] = SbdMergeRecord(
        subject: subject, repo: repo, number: number, files: files, commit: action?["commit"]?.string)
    }
  }

  /// Runs the actions that were running when sbd stopped, from their checks. A merge that landed before the stop
  /// finishes as done. It runs on the state queue.
  func resumeActions() {
    for id in entries.keys.sorted() {
      for wait in entries[id]?.session.waits ?? [] where wait.actionStatus?.kind == .running {
        followThroughQueue.async { [self] in runAction(id, wait.id) }
      }
    }
  }

  private func setActionStatus(_ holder: String, _ waitId: String, _ status: ActionStatus?) throws {
    try updateWait(holder, waitId) { $0.actionStatus = status }
  }

  /// Applies `change` to the stored wait `waitId` of `holder`, and changes nothing else. It runs on the state queue.
  func updateWait(_ holder: String, _ waitId: String, _ change: (inout Wait) -> Void) throws {
    try update(holder) {
      $0.waits = $0.waits?.map { w in
        guard w.id == waitId else { return w }
        var w = w
        change(&w)
        return w
      }
    }
  }

  /// Runs the action of the wait and records how it ended. Any error becomes a question to the holder, so a wait
  /// never stays running. It runs on `followThroughQueue`.
  private func runAction(_ holder: String, _ waitId: String) {
    guard let wait = queue.sync(execute: { storedWait(holder, waitId) }), let action = wait.action
    else { return }
    let outcome: ActionOutcome
    do {
      switch action.kind {
      case .merge: outcome = try runMerge(holder, wait)
      case .rmWorktree: outcome = try runRemoval(wait, worktree: true)
      case .rm: outcome = try runRemoval(wait, worktree: false)
      case .report: outcome = try runReport(wait)
      }
    } catch {
      outcome = .judgment(question: "sbd could not \(action.kind.skipped): \(error)")
    }
    if case .judgment(let question, let approval?, let reply?) = outcome {
      return gateReply(holder, waitId, question: question, approval: approval, reply: reply)
    }
    queue.sync { finish(holder, waitId, outcome) }
  }

  /// Sends a question about the subject's last reply to the reply gate judge before the holder.
  ///
  /// `merge` starts the action again with the approval, so `takeForMerge` checks the head and the reply again. `ask`
  /// records a needs-you report with the judge's question and parks the action until the subject's state changes.
  /// Anything else asks the holder. The judge runs once per head and reply digest: a later question about the pair
  /// that the judge asked about parks again, and one about a pair that it was unsure of or failed on asks the holder.
  /// A reply longer than `OperatorJudge.maxReply` skips the judge. It runs on `followThroughQueue`.
  private func gateReply(
    _ holder: String, _ waitId: String, question: String, approval: MergeGuard.Approval, reply: String
  ) {
    let toHolder = ActionOutcome.judgment(question: question, approval: approval, reply: reply)
    let call: (input: String, subject: String, since: Int64?)? = queue.sync {
      guard let wait = storedWait(holder, waitId), let status = wait.actionStatus, status.kind == .running,
        let subject = wait.actionSubject?.id, let e = entries[subject], let pr = e.facts.pr
      else {
        finish(holder, waitId, toHolder)
        return nil
      }
      // The subject replied after the run read its facts, so its `stateSince` already reflects that reply. A park would
      // store that value, and no later change of state would retry the park. So sbd runs the checks again.
      guard MergeGuard.replyDigest(e.facts.lastReply) == approval.replyDigest else {
        do { try startAction(holder, wait) } catch { finish(holder, waitId, toHolder) }
        return nil
      }
      if status.judged == approval {
        if status.subjectSince == nil {
          finish(holder, waitId, toHolder)
        } else {
          parkAsk(holder, waitId, status, since: subjectSince(of: wait))
        }
        return nil
      }
      guard reply.count <= OperatorJudge.maxReply else {
        finish(holder, waitId, toHolder)
        return nil
      }
      let input = OperatorJudge.ReplyGate.input(
        repo: pr.repo, number: pr.number, title: pr.title, session: e.session.name, reply: reply)
      return (input, subject, subjectSince(of: wait))
    }
    guard let call else { return }
    let result = judge(
      OperatorJudge.ReplyGate.self, session: call.subject, wait: waitId, head: approval.head, input: call.input)
    queue.sync {
      guard let result else { return finish(holder, waitId, toHolder) }
      guard var wait = storedWait(holder, waitId), var status = wait.actionStatus, status.kind == .running else {
        logLine("wait \(waitId) of \(holder) went while the judge read its reply")
        return
      }
      status.judged = approval
      wait.actionStatus = status
      do {
        switch result {
        case .success(let answer) where answer.word == .merge:
          try startAction(holder, wait, approval: approval)
        case .success(let answer) where answer.word == .ask:
          let about = entries[call.subject] == nil ? nil : call.subject
          try recordReport(answer.question, needsYou: true, about: about, on: try ensureOperator(), wait: waitId)
          status.reason = answer.question
          parkAsk(holder, waitId, status, since: call.since)
        case .success(let answer):
          try setActionStatus(holder, waitId, status)
          let because = answer.reason.isEmpty ? "" : " sbd's reply judge was unsure: " + Wait.sentence(answer.reason)
          finish(
            holder, waitId, .judgment(question: Wait.sentence(question) + because, approval: approval, reply: reply))
        case .failure:
          try setActionStatus(holder, waitId, status)
          finish(holder, waitId, toHolder)
        }
      } catch {
        logLine("can't record the judge's answer for wait \(waitId) of \(holder): \(error)")
        finish(holder, waitId, toHolder)
      }
    }
  }

  /// Parks the action after the judge's `ask` for the pair in `status.judged`, with no message to the holder.
  /// `since` is the subject's state when the judge read the reply, so the next change of state runs the checks
  /// again. It runs on the state queue.
  private func parkAsk(_ holder: String, _ waitId: String, _ status: ActionStatus, since: Int64?) {
    var status = status
    status.kind = .awaitingJudgment
    status.since = nowMs()
    status.retryAt = nil
    status.asked = status.judged
    status.subjectSince = since
    do {
      try setActionStatus(holder, waitId, status)
    } catch {
      logLine("can't park wait \(waitId) of \(holder) after the judge asked: \(error)")
      holdAfterFailure(holder, waitId, "sbd could not record the judge's question")
    }
  }

  /// Records how the action ended.
  ///
  /// Done removes the wait and records `wait-resolved`, a `follow-through` event on the subject, and an info report
  /// for a merge or a removal. A hold sets the retry time and sends its message to the subject once. A hold for one
  /// reason past `operator.holdLimitSeconds` becomes a question. A question goes to the holder. It runs on the state
  /// queue.
  private func finish(_ holder: String, _ waitId: String, _ outcome: ActionOutcome) {
    guard let wait = storedWait(holder, waitId), let action = wait.action else {
      logLine("wait \(waitId) of \(holder) went while its action ran")
      return
    }
    let now = nowMs()
    let old = wait.actionStatus ?? ActionStatus(kind: .running, since: now)
    let subject = wait.actionSubject?.id
    do {
      switch outcome {
      case .done(let result, let detail, let reports, let merged):
        var data: [String: JSON] = [
          "kind": .string(action.kind.rawValue), "result": .string(result), "detail": .string(detail),
        ]
        if let merged {
          data["repo"] = .string(merged.repo)
          data["pr"] = .number(Double(merged.number))
          data["files"] = merged.files.map { .array($0.sorted().map(JSON.string)) } ?? .null
          data["commit"] = merged.commit.map(JSON.string) ?? .null
          lastSbdMerges[merged.repo.lowercased()] = merged
        }
        try closeWait(holder, wait, extra: ["outcome": .string(detail), "action": .object(data)])
        if let subject, entries[subject] != nil {
          var event: [String: JSON] = [
            "wait": .string(waitId), "action": .string(action.kind.rawValue), "result": .string(result),
          ]
          if let from = wait.handedFrom { event["from"] = .string(from.id) }
          record(subject, "follow-through", .object(event))
        }
        if reports {
          let about = subject.flatMap { entries[$0] == nil ? nil : $0 }
          try recordReport(detail, needsYou: false, about: about, on: try ensureOperator(), wait: waitId)
        }
        if action.kind == .merge, let repo = subject.flatMap({ entries[$0]?.facts.pr?.repo }) {
          try retryHeldMerges(in: repo)
        }
      case .hold(let reason, let message, let key):
        var status = old
        if old.reason != reason { status.since = now }
        let limitSeconds = operatorSettings.holdLimitSeconds
        if now - status.since >= Int64(limitSeconds) * 1000 {
          let hours = limitSeconds / 3600
          return finish(holder, waitId, .judgment(question: "still held after \(hours) h: \(reason)"))
        }
        hold(&status, reason, now: now)
        status.subjectSince = subjectSince(of: wait)
        try setActionStatus(holder, waitId, status)
        if let message, let subject, key != old.messageKey {
          // A failed send leaves the key unset, so the next hold sends the message again.
          do {
            _ = try send(subject, message, by: .sbd, trigger: .wait)
            status.messageKey = key
            try setActionStatus(holder, waitId, status)
          } catch {
            logLine("can't send the hold message of wait \(waitId) to \(subject): \(error)")
          }
        }
      case .rearm:
        try setActionStatus(holder, waitId, nil)
      case .judgment(let question, let approval, let reply):
        var status = old
        status.kind = .awaitingJudgment
        status.since = now
        status.reason = question
        status.retryAt = nil
        status.asked = approval
        status.subjectSince = nil
        try setActionStatus(holder, waitId, status)
        do {
          let session = entries[holder]!.session
          let text = wait.judgmentMessage(
            question: question, holder: Wait.SessionTarget(id: holder, name: session.name),
            byOperator: session.kind == .operator, approvable: approval != nil, reply: reply)
          _ = try send(holder, text, by: .sbd, trigger: .wait, extra: handedFromData(holder, wait))
        } catch {
          logLine("can't ask about wait \(waitId) of \(holder): \(error)")
          holdAfterFailure(holder, waitId, question)
        }
      }
    } catch {
      logLine("can't record the \(action.kind.rawValue) action of wait \(waitId) of \(holder): \(error)")
      holdAfterFailure(holder, waitId, "sbd could not record how the action ended")
    }
  }

  /// Holds the action of a wait that `finish` could not move on, so the tick or the poller checks it again and the
  /// wait never stays running or asks nobody. It does nothing when the wait is gone.
  ///
  /// It forgets the pair that the judge answered. Otherwise a later hold would store the subject's state, and the
  /// next question about that pair would park as if the judge's `ask` had reached the user.
  private func holdAfterFailure(_ holder: String, _ waitId: String, _ reason: String) {
    guard var status = storedWait(holder, waitId)?.actionStatus, status.kind != .held else { return }
    let now = nowMs()
    hold(&status, reason, now: now)
    status.since = now
    status.judged = nil
    try? setActionStatus(holder, waitId, status)
  }

  /// Marks the action held for `reason` until `operator.holdRetrySeconds` from `now`.
  private func hold(_ status: inout ActionStatus, _ reason: String, now: Int64) {
    status.kind = .held
    status.reason = reason
    status.retryAt = now + Int64(operatorSettings.holdRetrySeconds) * 1000
  }

  func storedWait(_ holder: String, _ id: String) -> Wait? {
    entries[holder]?.session.waits?.first { $0.id == id }
  }

  /// Makes the held merges in `repo` due now, because a merge that one of them held behind just finished.
  private func retryHeldMerges(in repo: String) throws {
    let now = nowMs()
    for id in entries.keys.sorted() {
      for wait in entries[id]?.session.waits ?? [] {
        guard wait.action?.kind == .merge, var status = wait.actionStatus, status.kind == .held,
          let pr = wait.session.flatMap({ entries[$0.id]?.facts.pr }), Dependencies.sameRepo(pr.repo, repo)
        else { continue }
        status.retryAt = now
        try setActionStatus(id, wait.id, status)
      }
    }
  }

  // MARK: The approval

  /// The `wait-approve` request: the operator approves the merge that a question about the last reply asked about.
  ///
  /// The approval covers the head and the reply that the question covered, so a push or a new reply makes sbd ask
  /// again. Only a client inside the operator's Claude pane may send it, and its `caller` must name the operator,
  /// because any process can set SB_SESSION_ID. It runs on the state queue, after `install` of a fresh snapshot.
  func approveWait(_ args: JSON, caller: Caller) throws -> JSON {
    let refusal = APIError("only the operator approves a wait, from its own pane")
    guard let op = operatorID(), args["caller"]?.string == op else { throw refusal }
    guard let ancestry = try caller.ancestry(command: "sb operator approve"), let pane = paneRow(op, .claude),
      !pane.dead, Processes.isValidPid(pane.pid), ancestry.contains(pane.pid)
    else { throw refusal }
    let waitId = args["wait"]?.string ?? ""
    guard let wait = storedWait(op, waitId) else { throw APIError("the operator has no wait \(waitId)") }
    guard let status = wait.actionStatus, status.kind == .awaitingJudgment, let asked = status.asked else {
      throw APIError("wait \(waitId) isn't waiting for an approval of a merge")
    }
    try startAction(op, wait, approval: asked)
    return try JSON(encoding: summary(op))
  }

  // MARK: Merge

  /// What `runMerge` reads on the state queue.
  private struct MergeFacts {
    var name: String
    var facts: SessionFacts
    var verdict: Verdict?
    var busy: Bool
    /// The PRs of the earlier merges, with the heads that the poller read.
    var earlier: [(number: Int, head: String)]
    var lastSbdMerge: MergeGuard.SbdMerge?
    var approval: MergeGuard.Approval?
  }

  /// Lands the subject's PR when `MergeGuard` acts.
  ///
  /// A live read runs only after the stages before it pass. A PR that is already merged finishes as done. It reads
  /// `operator.mergeRepos` from config.json on each call. It runs on `followThroughQueue`.
  private func runMerge(_ holder: String, _ wait: Wait) throws -> ActionOutcome {
    guard let subject = wait.session?.id else {
      return .judgment(question: "the wait names no session to merge")
    }
    let mergeRepos = operatorSettings.mergeRepos
    let read = queue.sync { mergeFacts(subject, wait) }
    let facts = read.facts
    // A recorded merge of the current head comes from a gh merge that succeeded. The action treats it as merged
    // before the poller reads the merge from GitHub.
    if let pr = facts.pr, pr.state == .merged || facts.currentMerge?.result == .merged {
      return alreadyMerged(pr, subject, read.name, liveCommit: nil)
    }
    if read.busy, let pr = facts.pr { return .hold(reason: "\(read.name) is merging #\(pr.number) or being deleted") }
    if let verdict = MergeGuard.checkFacts(mergeRepos: mergeRepos, verdict: read.verdict, facts: facts) {
      return outcome(of: verdict, input: nil)
    }
    let pr = facts.pr!
    if GitLab.isMR(pr.id) {
      return .judgment(
        question: "Merge !\(pr.number) from the session. sbd doesn't merge a GitLab merge request from a wait.")
    }
    var input = MergeGuard.Input(
      mergeRepos: mergeRepos, verdict: read.verdict, facts: facts, live: livePR(pr), behindBy: nil, baseTip: nil,
      baseRollup: nil, files: nil, earlierFiles: [], lastSbdMerge: read.lastSbdMerge, approval: read.approval)
    if let live = input.live, live.state == .merged {
      return alreadyMerged(pr, subject, read.name, liveCommit: live.mergeCommit)
    }
    if let verdict = MergeGuard.checkLive(input) { return outcome(of: verdict, input: input) }
    let live = input.live!
    let compared = compare(pr.repo, base: live.base, head: live.head)
    input.behindBy = compared?.behindBy
    input.baseTip = compared?.baseTip
    input.baseRollup = compared.flatMap { baseRollup(pr.repo, $0.baseTip) }
    if let verdict = MergeGuard.checkBase(input) { return outcome(of: verdict, input: input) }
    if !read.earlier.isEmpty || MergeGuard.ownMergeUnderCI(input) != nil {
      input.files = changedFiles(pr.repo, pr.number, head: pr.headSha)
      input.earlierFiles = read.earlier.map { changedFiles(pr.repo, $0.number, head: $0.head) }
    }
    let verdict = MergeGuard.check(input)
    guard verdict == .act, let approval = read.approval else { return outcome(of: verdict, input: input) }
    if let changed = queue.sync(execute: { takeForMerge(holder, wait.id, subject, pr, approval) }) { return changed }
    defer { queue.sync { _ = merging.remove(subject) } }
    let attempt: MergeAttempt
    do {
      attempt = try landPR(subject, pr: pr, method: facts.mergeMethod)
    } catch {
      return .judgment(question: "\(error)")
    }
    let landed = "\(facts.mergeMethod.pastTense.capitalized) #\(pr.number) of \(read.name) at \(pr.headSha.prefix(7))"
    guard attempt.result == .merged else {
      return .done(result: attempt.result.rawValue, detail: landed, reports: true)
    }
    let files = input.files ?? changedFiles(pr.repo, pr.number, head: pr.headSha)
    changedFilesRead[filesKey(pr.repo, pr.number)] = nil
    return .done(
      result: attempt.result.rawValue, detail: landed, reports: true,
      merged: SbdMergeRecord(
        subject: subject, repo: pr.repo, number: pr.number, files: files, commit: mergeCommit(of: pr)))
  }

  /// Puts the subject in `merging` when nothing changed during the live reads, or returns the outcome that replaces
  /// the merge.
  ///
  /// The merge runs only for a wait that is still running, at the head that the guard read, for the reply that the
  /// holder approved, while the subject is still Ready to merge and its facts still pass `MergeGuard.checkFacts`. It
  /// runs on the state queue.
  private func takeForMerge(
    _ holder: String, _ waitId: String, _ subject: String, _ pr: PullRequest, _ approval: MergeGuard.Approval
  ) -> ActionOutcome? {
    guard storedWait(holder, waitId)?.actionStatus?.kind == .running else { return .rearm }
    let (e, verdict): (Entry, Verdict)
    switch mergeAdmission(subject) {
    case .busy: return .hold(reason: "the session is merging #\(pr.number) or being deleted")
    case .notReady: return .rearm
    case .ready(let entry, let v): (e, verdict) = (entry, v)
    }
    guard e.facts.pr?.headSha == pr.headSha else {
      return .hold(reason: "the head of #\(pr.number) moved during the checks")
    }
    // Ready to merge allows open review threads, so a poll during the live reads can add one at the same head.
    if let changed = MergeGuard.checkFacts(
      mergeRepos: operatorSettings.mergeRepos, verdict: verdict, facts: e.facts)
    {
      return outcome(of: changed, input: nil)
    }
    let digest = MergeGuard.replyDigest(e.facts.lastReply)
    guard digest == approval.replyDigest else {
      return .judgment(
        question: MergeGuard.replyQuestion(
          "\(e.session.name) replied again while sbd checked #\(pr.number) at \(pr.headSha.prefix(7))."),
        approval: MergeGuard.Approval(head: pr.headSha, replyDigest: digest), reply: e.facts.lastReply)
    }
    merging.insert(subject)
    return nil
  }

  /// The facts that `runMerge` reads on the state queue. A subject that is gone or being deleted has no verdict.
  /// The earlier merges are the other open merge waits on an open PR in the same repository, set before this one.
  private func mergeFacts(_ subject: String, _ wait: Wait) -> MergeFacts {
    guard let e = entries[subject] else {
      return MergeFacts(
        name: wait.session?.name ?? subject, facts: SessionFacts(), verdict: nil, busy: false, earlier: [],
        lastSbdMerge: nil, approval: wait.actionStatus?.approval)
    }
    let deleting = beingDeletedRefusal(subject) != nil
    let verdict = deleting ? nil : Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
    var earlier: [(number: Int, head: String)] = []
    var last: MergeGuard.SbdMerge?
    if let repo = e.facts.pr?.repo {
      for holder in entries.values {
        for other in holder.session.waits ?? [] {
          guard other.id != wait.id, other.action?.kind == .merge, (other.created, other.id) < (wait.created, wait.id),
            let pr = other.session.flatMap({ entries[$0.id]?.facts.pr }), pr.state == .open,
            Dependencies.sameRepo(pr.repo, repo)
          else { continue }
          earlier.append((pr.number, pr.headSha))
        }
      }
      if let merged = lastSbdMerges[repo.lowercased()] {
        // Removing the subject also removes its facts and their merge commit from `entries`.
        let pr = entries[merged.subject]?.facts.pr
        let commit = merged.commit ?? (pr?.number == merged.number ? pr?.mergeCommit : nil)
        last = MergeGuard.SbdMerge(commit: commit, files: merged.files)
      }
    }
    return MergeFacts(
      name: e.session.name, facts: e.facts, verdict: verdict, busy: merging.contains(subject), earlier: earlier,
      lastSbdMerge: last, approval: wait.actionStatus?.approval)
  }

  /// The outcome for a PR that merged before this run, such as a merge that landed before a restart. It counts as
  /// sbd's last merge in the repository, with unknown files. sbd holds the next merge while the base's checks run on
  /// its merge commit. A merge commit that sbd can't read matches any base tip. `liveCommit` is the merge commit from
  /// the live read, which comes first.
  private func alreadyMerged(_ pr: PullRequest, _ subject: String, _ name: String, liveCommit: String?)
    -> ActionOutcome
  {
    changedFilesRead[filesKey(pr.repo, pr.number)] = nil
    return .done(
      result: MergeAttempt.Result.merged.rawValue, detail: "#\(pr.number) of \(name) is merged", reports: true,
      merged: SbdMergeRecord(
        subject: subject, repo: pr.repo, number: pr.number, files: nil,
        commit: liveCommit ?? pr.mergeCommit ?? mergeCommit(of: pr)))
  }

  /// The action's outcome for a verdict that does not act. A hold's message goes once per head and base tip. A
  /// question about the reply carries the approval that would let `input` act.
  private func outcome(of verdict: MergeGuard.Verdict, input: MergeGuard.Input?) -> ActionOutcome {
    switch verdict {
    case .act:
      return .judgment(question: "sbd could not decide whether to merge")
    case .hold(let reason, let message):
      let key = input.map { "\($0.live?.head ?? "")@\($0.baseTip ?? "")" }
      return .hold(reason: reason, message: message, messageKey: message == nil ? nil : key)
    case .rearm:
      return .rearm
    case .judgment(let question):
      let approval = input.flatMap(MergeGuard.replyGate)
      return .judgment(question: question, approval: approval, reply: approval == nil ? nil : input?.facts.lastReply)
    }
  }

  // MARK: Live reads

  /// gh's output as JSON, or nil when gh failed or printed something else.
  private func ghJSON(_ args: [String]) -> JSON? {
    (try? runGh(args, timeout: 30)).flatMap(JSON.parse)
  }

  /// The PR as GitHub has it.
  private func livePR(_ pr: PullRequest) -> MergeGuard.LivePR? {
    guard
      let json = ghJSON([
        "pr", "view", String(pr.number), "--repo", pr.repo, "--json",
        "headRefOid,state,isDraft,mergeable,baseRefName,statusCheckRollup,mergeCommit",
      ]), let head = json["headRefOid"]?.string, let state = json["state"]?.string.flatMap(PRState.init(rawValue:)),
      let draft = json["isDraft"]?.bool, let base = json["baseRefName"]?.string
    else { return nil }
    return MergeGuard.LivePR(
      head: head, state: state, draft: draft, mergeable: json["mergeable"]?.string.flatMap(Mergeable.init(rawValue:)),
      base: base, rollup: ChecksRollup(contexts: json["statusCheckRollup"]?.array ?? []),
      mergeCommit: json["mergeCommit"]?["oid"]?.string)
  }

  /// The merge commit of a merged PR, or nil when gh failed or GitHub has none yet.
  private func mergeCommit(of pr: PullRequest) -> String? {
    ghJSON(["pr", "view", String(pr.number), "--repo", pr.repo, "--json", "mergeCommit"])?["mergeCommit"]?["oid"]?
      .string
  }

  /// How many commits the head lacks from the base branch, and the base branch's tip.
  private func compare(_ repo: String, base: String, head: String) -> (behindBy: Int, baseTip: String)? {
    guard let json = ghJSON(["api", "repos/\(repo)/compare/\(base)...\(head)"]),
      let behind = json["behind_by"]?.int, let tip = json["base_commit"]?["sha"]?.string
    else { return nil }
    return (behind, tip)
  }

  /// The rollup of a commit's check runs and statuses. A list longer than one page is unknown.
  private func baseRollup(_ repo: String, _ sha: String) -> ChecksRollup? {
    guard let runs = ghJSON(["api", "repos/\(repo)/commits/\(sha)/check-runs?per_page=100"]),
      let list = runs["check_runs"]?.array, (runs["total_count"]?.int ?? 0) <= list.count,
      let status = ghJSON(["api", "repos/\(repo)/commits/\(sha)/status"])
    else { return nil }
    // GitHub's combined state is pending for a commit without statuses.
    let statuses = (status["total_count"]?.int ?? 0) > 0 ? [JSON.object(["state": status["state"] ?? .null])] : []
    return ChecksRollup(contexts: list + statuses)
  }

  /// The PR's changed files at `head`, or nil when a page failed or the PR has more files than 30 pages hold.
  ///
  /// A successful read stays in `changedFilesRead` until the PR's head moves or its merge wait finishes.
  private func changedFiles(_ repo: String, _ number: Int, head: String) -> Set<String>? {
    let key = filesKey(repo, number)
    if let read = changedFilesRead[key], read.head == head { return read.files }
    var files = Set<String>()
    for page in 1...30 {
      guard let list = ghJSON(["api", "repos/\(repo)/pulls/\(number)/files?per_page=100&page=\(page)"])?.array
      else { return nil }
      files.formUnion(list.compactMap { $0["filename"]?.string })
      if list.count < 100 {
        changedFilesRead[key] = (head, files)
        return files
      }
    }
    return nil
  }

  private func filesKey(_ repo: String, _ number: Int) -> String { "\(repo.lowercased())#\(number)" }

  // MARK: Removal and report

  /// `remove`'s refusal, with `whileIdle`, of a session whose turn runs or whose message is on its way after
  /// `RemovalGuard` passed.
  struct TurnRunsError: Error, CustomStringConvertible {
    var name: String
    var description: String { "the turn of \(name) runs" }
  }

  /// Whether the session's turn runs or a message is on its way to it, either of which a removal would stop. It runs
  /// on the state queue.
  func turnRuns(_ e: Entry) -> Bool { e.facts.turnRunning || messageWaiting(e, now: nowMs()) }

  /// Removes the subject as `sb rm` does, with its worktree for `rm-worktree`, when `RemovalGuard` allows it. A turn
  /// that starts during `remove`'s checks holds the removal. Each other refusal of `remove` becomes a question that
  /// quotes it. It runs on `followThroughQueue`.
  private func runRemoval(_ wait: Wait, worktree: Bool) throws -> ActionOutcome {
    guard let target = wait.actionSubject else {
      return .judgment(question: "the wait names no session to remove")
    }
    let subject = target.id
    let input = queue.sync {
      let e = entries[subject]
      return RemovalGuard.Input(
        name: e?.session.name ?? target.name, exists: e != nil,
        busy: beingDeletedRefusal(subject) != nil || busyRefusal(subject) != nil, host: e?.session.host,
        worktree: worktree, pr: e?.facts.pr, turnRunning: e?.facts.turnRunning ?? false,
        messageWaiting: e.map { messageWaiting($0, now: nowMs()) } ?? false)
    }
    switch RemovalGuard.check(input) {
    case .gone:
      return .done(result: "removed", detail: "\(target.name) was already removed", reports: false)
    case .hold(let reason):
      return .hold(reason: reason)
    case .judgment(let question):
      return .judgment(question: question)
    case .remove:
      break
    }
    do {
      _ = try remove(["session": .string(subject), "worktree": .bool(worktree)], caller: .inProcess, whileIdle: true)
    } catch let error as TurnRunsError {
      return .hold(reason: error.description)
    } catch {
      return .judgment(question: "sbd could not remove \(target.name): \(error)")
    }
    let detail = worktree ? "Removed \(target.name) and its worktree" : "Removed \(target.name)"
    return .done(result: "removed", detail: detail, reports: true)
  }

  /// Records the wait's note as a report on the operator, once: a report that already carries the wait's id, from a
  /// run before a restart, counts as done. It runs on `followThroughQueue`.
  private func runReport(_ wait: Wait) throws -> ActionOutcome {
    try queue.sync {
      let op = try ensureOperator()
      if try store.operatorReport(wait: wait.id, session: op) == nil {
        let about = wait.actionSubject.flatMap { entries[$0.id] == nil ? nil : $0.id }
        try recordReport(
          wait.note ?? "", needsYou: wait.action?.needsYou == true, about: about, on: op, wait: wait.id,
          handedFrom: wait.handedFrom?.id)
      }
      return .done(result: "reported", detail: "Recorded the report", reports: false)
    }
  }
}
