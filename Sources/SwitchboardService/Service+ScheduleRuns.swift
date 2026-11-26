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

/// Script schedules: sbd runs the command in the session's folder, outside the session's conversation, on
/// `scheduleRunQueue`, and records the result on the state queue.
extension Service {
  /// The folder of the schedule's run logs, one `<run t>.log` file per run.
  func runLogFolder(_ id: String, _ scheduleId: String) -> String {
    "\(home.sessionFolder(id))/schedules/\(scheduleId)"
  }

  /// Saves the schedule's next run and the start of this run, marks the run in flight, and runs the command on
  /// `scheduleRunQueue`. A crash after the save leaves `running` set, which `recoverRuns` reads at the next load. A
  /// schedule whose save fails runs nothing. It runs on the state queue.
  func dispatchRun(_ id: String, _ schedule: Schedule, now: Int64) {
    guard let session = entries[id]?.session else { return }
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
    // The run has the session's environment, so `sb` in it claims the session as its caller.
    var env = headlessEnv(session: id, account: nil)
    env["SB_SESSION_ID"] = id
    env[ScheduleRun.marker] = "\(schedule.id):\(now)"
    let argv = ScheduleRun.scriptArguments(command: schedule.prompt, shell: env["SHELL"])
    let timeout = schedule.runTimeout
    let scheduleId = schedule.id
    runsInFlight[scheduleId] = RunInFlight(session: id, pid: 0, start: 0)
    scheduleRunQueue.async { [self] in
      let outcome = Result {
        try DetachedRun.run(
          executable: argv[0], arguments: Array(argv.dropFirst()), env: env, folder: session.cwd,
          log: "\(folder)/\(now).log", timeout: Double(timeout) / 1000,
          cancelled: { cancelledRuns.withLock { $0.contains(scheduleId) } },
          onStart: { pid in
            let start = Processes.startTime(of: Int(pid)) ?? 0
            queue.sync { runsInFlight[scheduleId] = RunInFlight(session: id, pid: Int(pid), start: start) }
          })
      }
      queue.sync {
        finishRun(
          id, scheduleId, run: Self.scheduleRun(outcome, t: now, skipped: skipped, timeout: timeout))
      }
    }
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
