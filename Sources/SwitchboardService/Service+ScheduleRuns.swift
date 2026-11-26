import Foundation
import SwitchboardCore

/// A headless or script run in flight.
struct RunInFlight {
  /// The session that owns the run's schedule.
  var session: String
  /// 0 until the process starts. No process has pid 0.
  var pid: Int
  /// The process's start time, in microseconds since the epoch, as `Processes.startTime(of:)` reads it.
  var start: Int64
}

/// Headless and script schedules: sbd runs a `claude -p` turn or the command in the session's folder, outside the
/// session's conversation, on `scheduleRunQueue`, and records the result on the state queue.
extension Service {
  /// The folder of the schedule's run logs, one `<run t>.log` file per run.
  func runLogFolder(_ id: String, _ scheduleId: String) -> String {
    "\(home.sessionFolder(id))/schedules/\(scheduleId)"
  }

  /// Saves the schedule's next run and the start of this run, marks the run in flight, and runs the command on
  /// `scheduleRunQueue`. A crash after the save leaves `running` set, which `recoverRuns` reads at the next load. A
  /// schedule whose save fails runs nothing. A run that `runCommand` refuses starts no process and records a failed
  /// run. It runs on the state queue.
  func dispatchRun(_ id: String, _ schedule: Schedule, now: Int64) {
    guard let session = entries[id]?.session else { return }
    let command: (argv: [String], env: [String: String])
    do {
      command = try runCommand(id, session, schedule, marker: "\(schedule.id):\(now)")
    } catch {
      var ran = schedule
      guard let skipped = saveNextRun(id, &ran, now: now) else { return }
      recordRun(id, ran, run: Schedule.Run(t: now, outcome: .failed, skipped: skipped, error: "\(error)"), check: nil)
      return
    }
    let (next, skipped) = schedule.fired(at: now)
    let folder = runLogFolder(id, schedule.id)
    do {
      // A removal deletes the folder on the state queue, so the run can't make it again after that.
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      try changeSchedule(id, schedule.id) {
        $0.next = next
        $0.running = now
      }
    } catch {
      logLine("can't run schedule \(schedule.id) of \(id): \(error)")
      return
    }
    let (argv, env) = command
    let timeout = schedule.runTimeout
    let scheduleId = schedule.id
    let headless = schedule.runner == .headless
    let log = "\(folder)/\(now).log"
    runsInFlight[scheduleId] = RunInFlight(session: id, pid: 0, start: 0)
    scheduleRunQueue.async { [self] in
      let outcome = Result {
        try DetachedRun.run(
          executable: argv[0], arguments: Array(argv.dropFirst()), env: env, folder: session.cwd,
          log: log, timeout: Double(timeout) / 1000,
          cancelled: { cancelledRuns.withLock { $0.contains(scheduleId) } },
          onStart: { pid in
            let start = Processes.startTime(of: Int(pid)) ?? 0
            queue.sync { runsInFlight[scheduleId] = RunInFlight(session: id, pid: Int(pid), start: start) }
          })
      }
      var run = Self.scheduleRun(outcome, t: now, skipped: skipped, timeout: timeout)
      let call = headless ? (try? outcome.get()).map { Self.readHeadlessLog(log, ended: $0, run: &run) } : nil
      queue.sync {
        finishRun(id, scheduleId, run: run)
        guard let reply = call else { return }
        let row = HeadlessCall(
          t: nowMs(), kind: HeadlessKind.schedule.rawValue, session: id, model: reply.model, usage: reply.usage,
          error: run.error)
        do { try store.append(headlessCall: row) } catch { logLine("can't store the schedule call: \(error)") }
      }
    }
  }

  /// The argv, with the program first, and the environment of the schedule's run. The run has the session's pane
  /// environment, so `sb` in it claims the session as its caller, and `marker` names the run. A headless run takes
  /// the session's permission mode and MCP arguments, as `ScheduleRun.headlessArguments` says, and runs under the
  /// schedule's account, else the account of the session's pane. It throws, so no process starts, for a session on a
  /// host, for an account that is a Codex account or has no quota left, and when sbd can't find claude. It runs on
  /// the state queue.
  private func runCommand(_ id: String, _ session: Session, _ schedule: Schedule, marker: String) throws
    -> (argv: [String], env: [String: String])
  {
    guard session.host == nil else { throw APIError("--headless and --script run only for a session on this Mac") }
    guard schedule.runner == .headless else {
      var env = headlessEnv(session: id, account: nil)
      env["SB_SESSION_ID"] = id
      env[ScheduleRun.marker] = marker
      return (ScheduleRun.scriptArguments(command: schedule.prompt, shell: env["SHELL"]), env)
    }
    // `headlessEnv` runs a Codex folder's turn under a stand-in account, so the check comes before it.
    let folder = schedule.account ?? paneEnv(id)["CLAUDE_CONFIG_DIR"] ?? ClaudeAccount.defaultFolder
    if let name = codexName(folder) { throw APIError(Self.codexRefusal(name)) }
    guard quota.hasBudget(account: folder) else {
      throw APIError("no quota is left for \(Account.name(ofFolder: folder))")
    }
    let command = claudeCommand(for: session)
    guard let claude = findExecutable(command) else { throw APIError("can't find \(command)") }
    var env = headlessEnv(session: id, account: schedule.account.map(ClaudeAccount.init(folder:)))
    env["SB_SESSION_ID"] = id
    env[ScheduleRun.marker] = marker
    let model =
      schedule.model
      ?? SessionModel.launch(
        kind: session.kind, stored: session.model, coordinatorModel: managerModel,
        operatorModel: operatorSettings.model)
    let argv = ScheduleRun.headlessArguments(
      claude: claude, kind: session.kind, model: model,
      permissionMode: PermissionMode.forLaunch(session, resume: false, lastReported: nil),
      mcpArgs: launchMCPArgs(id, session), claudeArgs: config.claudeArgs, prompt: schedule.prompt)
    return (argv, env)
  }

  /// Reads a headless run's log, which holds claude's envelope, and returns the model and tokens that it reports.
  /// It sets `run`'s tail to the first line of the envelope's result, and it fails a run whose envelope is an error
  /// or that printed none. A timeout or a cancel keeps its own error. It rewrites the log as the result's text, then
  /// what claude printed. It runs off the state queue.
  private static func readHeadlessLog(_ log: String, ended: DetachedRun.Result, run: inout Schedule.Run)
    -> HeadlessReply
  {
    let output = String(decoding: FileManager.default.contents(atPath: log) ?? Data(), as: UTF8.self)
    let reply = Headless.reply(output)
    let stopped = ended.timedOut || ended.cancelled
    guard let envelope = Headless.envelope(output), let result = envelope["result"]?.string else {
      if !stopped {
        run.outcome = .failed
        run.error = run.error ?? "claude printed no result: \(oneLine(output, max: 200))"
      }
      return reply
    }
    FileManager.default.createFile(
      atPath: log, contents: Data((result + "\n\n" + output).utf8), attributes: [.posixPermissions: 0o600])
    run.tail = DetachedRun.firstLine(result)
    if envelope["is_error"]?.bool == true, !stopped {
      run.outcome = .failed
      run.error = "claude failed: \(oneLine(result, max: 200))"
    }
    return reply
  }

  /// The run's result. Only an exit with status 0 is `ran`.
  private static func scheduleRun(
    _ outcome: Result<DetachedRun.Result, any Error>, t: Int64, skipped: Int, timeout: Int64
  ) -> Schedule.Run {
    let ended: DetachedRun.Result
    switch outcome {
    case .failure(let error): return Schedule.Run(t: t, outcome: .failed, skipped: skipped, error: "\(error)")
    case .success(let result): ended = result
    }
    let error: String? =
      if ended.timedOut {
        "timed out after \(Schedule.intervalText(timeout))"
      } else if ended.cancelled {
        "cancelled"
      } else if let exit = ended.exit {
        exit == 0 ? nil : "exited with status \(exit)"
      } else {
        "ended on a signal"
      }
    var run = Schedule.Run(t: t, outcome: error == nil ? .ran : .failed, skipped: skipped, error: error)
    run.exit = ended.exit
    run.ms = ended.ms
    run.tail = ended.tail
    return run
  }

  /// Ends the run's time in flight and records it on its schedule, then deletes the logs of the runs that the history
  /// no longer holds. A schedule or session that is gone records nothing. It runs on the state queue.
  private func finishRun(_ id: String, _ scheduleId: String, run: Schedule.Run) {
    runsInFlight[scheduleId] = nil
    cancelledRuns.withLock { _ = $0.remove(scheduleId) }
    guard let schedule = entries[id]?.session.schedule(scheduleId) else { return }
    recordRun(id, schedule, run: run, check: nil)
    guard let kept = entries[id]?.session.schedule(scheduleId)?.history else { return }
    let names = Set(kept.map { "\($0.t).log" })
    let folder = runLogFolder(id, scheduleId)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    where name.hasSuffix(".log") && !names.contains(name) {
      try? FileManager.default.removeItem(atPath: "\(folder)/\(name)")
    }
  }

  /// Cancels the session's runs in flight. Each run's process group gets SIGTERM within 100 ms, and SIGKILL later,
  /// as `DetachedRun.run` says. It runs on the state queue.
  func cancelRuns(of id: String) {
    let ids = runsInFlight.filter { $0.value.session == id }.keys
    cancelledRuns.withLock { $0.formUnion(ids) }
  }

  /// Cancels the schedule's run in flight, if it has one. It runs on the state queue.
  func cancelRun(_ scheduleId: String) {
    guard runsInFlight[scheduleId] != nil else { return }
    cancelledRuns.withLock { _ = $0.insert(scheduleId) }
  }

  /// Records a failed run for each schedule whose run was in flight when sbd stopped, and then stops the run's
  /// processes that launchd adopted, off the state queue. `load` calls it.
  func recoverRuns() {
    var markers: [String: Session] = [:]
    for (id, e) in entries {
      for schedule in e.session.allSchedules {
        guard let t = schedule.running else { continue }
        markers["\(ScheduleRun.marker)=\(schedule.id):\(t)"] = e.session
        let run = Schedule.Run(t: t, outcome: .failed, skipped: 0, error: "sbd restarted during the run")
        recordRun(id, schedule, run: run, check: nil)
      }
    }
    guard !markers.isEmpty else { return }
    scheduleRunQueue.async { [self] in stopOrphanedRuns(markers) }
  }

  /// Stops each process whose parent is launchd and whose environment holds one of `markers`, which maps each run's
  /// `SB_SCHEDULE_RUN` assignment to the run's session, and every other process in its process group. It reads no
  /// state, because `load` may still be changing it. A run's first
  /// process leads its own group, so the processes that the run started stop with it. It stops them as
  /// `stopLeftovers` does. It runs off the state queue.
  private func stopOrphanedRuns(_ markers: [String: Session]) {
    let table = ProcessTable.readLocal()
    var found: [String: (session: Session, orphans: [Int: Int64])] = [:]
    for row in table.all where row.ppid == 1 && !row.isZombie && row.startTime > 0 {
      guard let session = ProcessTable.environment(of: pid_t(row.pid)).lazy.compactMap({ markers[$0] }).first else {
        continue
      }
      for member in table.all where member.pid == row.pid || (row.pgid > 1 && member.pgid == row.pgid) {
        found[session.id, default: (session, [:])].orphans[member.pid] = member.startTime
      }
    }
    for (session, orphans) in found.values {
      do {
        try stopLeftovers(orphans, of: session, at: site(for: session))
      } catch {
        logLine("can't stop the orphaned runs of \(session.id): \(error)")
      }
    }
  }
}
