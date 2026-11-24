import Foundation
import SwitchboardCore

/// The CI reader: when a merge action's subject keeps failing its checks at one head while it is idle, a one-shot
/// judge reads the failed logs. sbd then sends the subject the judge's summary, reruns a flake once, or asks the
/// wait's holder. It never changes the action's status, so a later Ready to merge still runs the merge.
extension Service {
  /// A merge wait whose subject's checks failed at `head`, as the tick read it.
  private struct CIRead {
    var holder: String
    var wait: String
    var subject: String
    var name: String
    var repo: String
    var number: Int
    var title: String
    var head: String

    var key: String { Self.key(holder: holder, wait: wait) }

    /// The key of the wait `wait` of `holder` in `ciReads`.
    static func key(holder: String, wait: String) -> String { "\(holder) \(wait)" }

    /// The question to the holder about the failed checks, for `reason`.
    func question(_ reason: String) -> String {
      "The checks on #\(number) of \(name) failed at \(head.prefix(7)). " + Wait.sentence(reason)
    }
  }

  /// What the reader decided.
  private enum CIVerdict {
    /// Send the subject the judge's summary.
    case tell(String)
    /// Rerun the failed jobs of these runs.
    case rerun([Int])
    /// Ask the holder, for this reason.
    case ask(String)
  }

  /// Moves the CI state of each merge action wait on from its subject's facts, and starts the reader on
  /// `ciReaderQueue` for a failure that two ticks at least `operator.holdRetrySeconds` apart saw at one head.
  ///
  /// It looks at a wait whose action is not running, whose subject has an open PR in `operator.mergeRepos` with
  /// failed checks, and whose subject's turn does not run and has no message on its way. A wait that no longer
  /// qualifies forgets a failure that it only saw, so pending checks or a turn start the count again. It runs no
  /// gh. `tick` calls it after `resolveDueWaits`. It runs on the state queue.
  func checkFailedCI(now: Int64) {
    lazy var settings = self.operatorSettings
    for holder in entries.keys.sorted() {
      for wait in entries[holder]?.session.waits ?? [] where wait.action?.kind == .merge {
        guard !ciReads.contains(CIRead.key(holder: holder, wait: wait.id)) else { continue }
        // At a head that the reader judged, only a question that sbd could not send is left to do.
        if let check = wait.ciCheck, check.step == .judged,
          let pr = wait.actionSubject.flatMap({ entries[$0.id]?.facts.pr }), check.head == pr.headSha
        {
          if let text = check.unsent {
            if pr.state != .open || !pr.checksFailed {
              var answered = check
              answered.unsent = nil
              setCICheck(holder, wait.id, answered)
            } else if now - check.since >= Int64(settings.holdRetrySeconds) * 1000 {
              sendCIQuestion(holder, wait.id, check, text)
            }
          }
          continue
        }
        guard wait.actionStatus?.kind != .running, let subject = wait.actionSubject?.id, let e = entries[subject],
          let pr = e.facts.pr, pr.state == .open, pr.checksFailed, !turnRuns(e), settings.mergesIn(pr.repo)
        else {
          if wait.ciCheck?.step == .seen { setCICheck(holder, wait.id, nil) }
          continue
        }
        guard let check = wait.ciCheck, check.head == pr.headSha else {
          setCICheck(holder, wait.id, CICheck(head: pr.headSha, since: now, step: .seen))
          continue
        }
        let window = Int64(settings.holdRetrySeconds) * 1000
        let read = CIRead(
          holder: holder, wait: wait.id, subject: subject, name: e.session.name, repo: pr.repo, number: pr.number,
          title: pr.title, head: pr.headSha)
        switch check.step {
        case .judged:
          continue
        case .seen:
          guard now - check.since >= window else { continue }
          ciReads.insert(read.key)
          ciReaderQueue.async { [self] in readCI(read) }
        case .reran:
          // A rerun that fails again before a PR read sees it running leaves `stateSince` unchanged. So checks that
          // still fail one idle poll plus the window after the rerun also count as a second failure.
          let since = e.facts.stateSince
          let failedAgain = since > check.since && now - since >= window
          let idlePoll = Int64(config.github.idlePollSeconds * 1000)
          guard failedAgain || now - check.since >= idlePoll + window else { continue }
          askAboutCI(
            read,
            "sbd's CI reader called the failure a flake, and sbd reran the failed jobs once. The checks still fail.")
        }
      }
    }
  }

  /// Reads the failed runs at the head, asks the judge, and sends, reruns, or asks the holder. A result for a head,
  /// a wait, or checks that changed during the reads is dropped. It runs on `ciReaderQueue`.
  private func readCI(_ read: CIRead) {
    let verdict = ciVerdict(read)
    switch verdict {
    case .tell, .ask:
      queue.sync {
        ciReads.remove(read.key)
        guard ciCurrent(read) else { return }
        if case .tell(let message) = verdict { tellAboutCI(read, message) }
        if case .ask(let reason) = verdict { askAboutCI(read, reason) }
      }
    case .rerun(let runs):
      rerunCI(read, runs)
    }
  }

  /// Records the head as rerun, then reruns the failed jobs of `runs` and asks the holder when gh refuses one. It
  /// runs on `ciReaderQueue`.
  private func rerunCI(_ read: CIRead, _ runs: [Int]) {
    // The step is stored before the reruns, so a restart during them never reruns the head again.
    let current = queue.sync {
      guard ciCurrent(read) else {
        ciReads.remove(read.key)
        return false
      }
      guard setCICheck(read.holder, read.wait, CICheck(head: read.head, since: nowMs(), step: .reran)) else {
        ciReads.remove(read.key)
        askAboutCI(read, "sbd could not record the rerun, so it did not rerun the failed jobs")
        return false
      }
      return true
    }
    guard current else { return }
    var refusal: String?
    for run in runs {
      if let error = ghError(["run", "rerun", String(run), "--failed", "--repo", read.repo], timeout: 30) {
        refusal = "gh refused to rerun the failed jobs of run \(run): \(oneLine(error, max: TriageCard.lineLength))"
        break
      }
    }
    queue.sync {
      ciReads.remove(read.key)
      // A push during the reruns makes the refusal about a head that no longer matters.
      guard let refusal, storedWait(read.holder, read.wait)?.ciCheck?.head == read.head,
        entries[read.subject]?.facts.pr?.headSha == read.head
      else { return }
      askAboutCI(read, refusal)
    }
  }

  /// Lists the runs at the head, reads the failed runs' logs, and asks the judge. It runs on `ciReaderQueue`.
  private func ciVerdict(_ read: CIRead) -> CIVerdict {
    let list: [JSON]
    do {
      let output = try runGh(
        [
          "run", "list", "--repo", read.repo, "--commit", read.head, "--limit", "100", "--json",
          "databaseId,name,workflowName,conclusion,status",
        ], timeout: 30)
      guard let runs = JSON.parse(output)?.array else { return .ask("gh run list printed no list of runs") }
      list = runs
    } catch {
      return .ask("sbd could not list the runs: \(oneLine("\(error)", max: TriageCard.lineLength))")
    }
    let failed: [(id: Int, workflow: String)] = list.compactMap { run in
      // A run counts as failed exactly when it makes the PR's checks rollup fail.
      guard ChecksRollup(contexts: [run]) == .failed, let id = run["databaseId"]?.int else { return nil }
      return (id, run["workflowName"]?.string ?? run["name"]?.string ?? "")
    }
    guard !failed.isEmpty else { return .ask("sbd found no failed GitHub Actions run at that head") }
    var jobs: [OperatorJudge.CIFailure.Job] = []
    for run in failed where jobs.count < OperatorJudge.CIFailure.maxJobs {
      do {
        let log = try runGh(["run", "view", String(run.id), "--repo", read.repo, "--log-failed"], timeout: 30)
        jobs += OperatorJudge.CIFailure.jobs(workflow: run.workflow, log: log)
      } catch {
        return .ask(
          "sbd could not read the failed log of run \(run.id): \(oneLine("\(error)", max: TriageCard.lineLength))")
      }
    }
    jobs = Array(jobs.prefix(OperatorJudge.CIFailure.maxJobs))
    guard !jobs.isEmpty else { return .ask("the failed runs' logs hold no failed job") }
    let input = OperatorJudge.CIFailure.input(
      repo: read.repo, number: read.number, title: read.title, head: read.head, jobs: jobs)
    let result = judge(
      OperatorJudge.CIFailure.self, session: read.subject, wait: read.wait, head: read.head, input: input)
    switch result {
    case nil:
      return .ask("sbd's CI reader did not run")
    case .failure(let error):
      return .ask("sbd's CI reader failed: \(oneLine("\(error)", max: TriageCard.lineLength))")
    case .success(let answer):
      return answer.cause == .flake ? .rerun(failed.map(\.id)) : .tell(answer.message)
    }
  }

  /// Whether the wait still records the failure as seen at the read's head, the subject's PR still fails its checks
  /// at that head, and the subject's turn still does not run. It runs on the state queue.
  private func ciCurrent(_ read: CIRead) -> Bool {
    guard let check = storedWait(read.holder, read.wait)?.ciCheck, check.head == read.head, check.step == .seen,
      let e = entries[read.subject], let pr = e.facts.pr
    else { return false }
    return pr.headSha == read.head && pr.checksFailed && !turnRuns(e)
  }

  /// Sends the subject the judge's summary and records the head as judged. A failed send asks the holder instead. It
  /// runs on the state queue.
  private func tellAboutCI(_ read: CIRead, _ message: String) {
    let text =
      "Switchboard: the checks on #\(read.number) failed at \(read.head.prefix(7)). sbd's CI reader, which read the "
      + "failed logs, says: \(Wait.sentence(message)) Check this against the logs. If your change caused it, fix it "
      + "and push. sbd runs the merge when the PR is Ready to merge."
    setCICheck(read.holder, read.wait, CICheck(head: read.head, since: nowMs(), step: .judged))
    do {
      _ = try send(read.subject, text, by: .sbd, trigger: .wait)
    } catch {
      logLine("can't send the CI reader's summary of wait \(read.wait) to \(read.subject): \(error)")
      askAboutCI(
        read,
        "sbd could not send the session its CI reader's summary: \(oneLine("\(error)", max: TriageCard.lineLength))")
    }
  }

  /// Asks the wait's holder about the subject's failed checks, with no approval, and records the head as judged. It
  /// runs on the state queue.
  private func askAboutCI(_ read: CIRead, _ reason: String) {
    guard let wait = storedWait(read.holder, read.wait), let session = entries[read.holder]?.session else { return }
    let text = wait.keepWaitMessage(question: read.question(reason), byOperator: session.kind == .operator)
    sendCIQuestion(read.holder, read.wait, CICheck(head: read.head, since: nowMs(), step: .judged), text)
  }

  /// Records `check` as judged, then sends the holder `text`. A failed send stores `text` as unsent, so a later tick
  /// sends it again. It runs on the state queue.
  private func sendCIQuestion(_ holder: String, _ waitId: String, _ check: CICheck, _ text: String) {
    var check = check
    check.since = nowMs()
    check.unsent = nil
    // The step is stored before the send, so a restart after the send never sends it twice.
    setCICheck(holder, waitId, check)
    do {
      _ = try send(holder, text, by: .sbd, trigger: .wait)
    } catch {
      logLine("can't ask about the failed checks of wait \(waitId) of \(holder): \(error)")
      check.unsent = text
      setCICheck(holder, waitId, check)
    }
  }

  /// Stores `check` as the CI state of the wait, and changes nothing else on it. It returns false when the store
  /// failed. It runs on the state queue.
  @discardableResult
  private func setCICheck(_ holder: String, _ waitId: String, _ check: CICheck?) -> Bool {
    do {
      try updateWait(holder, waitId) { $0.ciCheck = check }
      return true
    } catch {
      logLine("can't record the CI state of wait \(waitId) of \(holder): \(error)")
      return false
    }
  }
}
