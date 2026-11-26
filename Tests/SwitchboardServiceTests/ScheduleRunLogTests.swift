import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// Runs the script with `/bin/sh -c` through `DetachedRun.run`, as sbd runs a headless schedule's claude, with its log
/// at `folder/run.log`.
private func headlessRun(_ script: String, folder: String) throws -> (log: String, ended: DetachedRun.Result) {
  let log = "\(folder)/run.log"
  let ended = try DetachedRun.run(
    executable: "/bin/sh", arguments: ["-c", script], env: ProcessInfo.processInfo.environment, folder: folder,
    log: log, timeout: 30)
  return (log, ended)
}

/// A script that prints an envelope whose result is `bytes` x characters, with its usage, and exits 0.
private func envelopeScript(resultBytes bytes: Int) -> String {
  "printf '{\"type\":\"result\",\"is_error\":false,\"result\":\"'; head -c \(bytes) /dev/zero | tr '\\0' x; "
    + "printf '\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7}}'"
}

/// The run that `scheduleRun` makes of an exit with status 0.
private func ranRun(_ ended: DetachedRun.Result) -> Schedule.Run {
  var run = Schedule.Run(t: 1, outcome: .ran, skipped: 0)
  run.exit = ended.exit
  run.tail = ended.tail
  return run
}

/// What `schedule-log` answers for the log at `path`.
private func scheduleLog(_ path: String) throws -> JSON {
  try Service.scheduleLog((path: path, run: 1, schedule: "r1", t: 1))
}

/// A headless run's log keeps the cap of Decision 12 after sbd rewrites it, and an envelope that passed the cap
/// leaves the run's outcome to claude's exit status.
@Suite struct ScheduleRunLogTests {
  /// DetachedRun cut the envelope, so no JSON parses, but claude exited 0.
  @Test func aCutEnvelopeFromAnExitWithStatusZeroIsARanRunWithUnknownUsage() throws {
    let folder = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let (log, ended) = try headlessRun(envelopeScript(resultBytes: DetachedRun.logCap + 1000), folder: folder)
    try #require(ended.exit == 0)
    var run = ranRun(ended)

    let reply = Service.readHeadlessLog(log, ended: ended, run: &run)

    #expect(run.outcome == .ran, "\(run)")
    #expect(run.error == nil, "\(run)")
    #expect(run.tail?.contains("1 MiB") == true, "\(String(describing: run.tail))")
    #expect(reply.usage == nil)
    #expect(reply.model == nil)
  }

  /// The rewritten log holds the result, then as much of the envelope as fits under the cap, then the cut marker.
  @Test func aRewrittenLogStaysUnderTheCapAndSaysItWasCut() throws {
    let folder = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let (log, ended) = try headlessRun(envelopeScript(resultBytes: 700_000), folder: folder)
    var run = ranRun(ended)

    let reply = Service.readHeadlessLog(log, ended: ended, run: &run)

    #expect(run.outcome == .ran, "\(run)")
    #expect(reply.usage?.input == 5)
    let answer = try scheduleLog(log)
    let text = answer["text"]?.string ?? ""
    #expect(answer["truncated"]?.bool == true)
    #expect(text.utf8.count <= DetachedRun.logCap + DetachedRun.cutMarker.utf8.count + 2, "\(text.utf8.count)")
    #expect(text.hasPrefix(String(repeating: "x", count: 700_000) + "\n\n{"))
  }

  @Test func aRewrittenLogUnderTheCapHoldsTheResultAndTheWholeEnvelope() throws {
    let folder = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let (log, ended) = try headlessRun(envelopeScript(resultBytes: 3), folder: folder)
    let envelope = try String(contentsOfFile: log, encoding: .utf8)
    var run = ranRun(ended)

    _ = Service.readHeadlessLog(log, ended: ended, run: &run)

    let answer = try scheduleLog(log)
    #expect(answer["text"]?.string == "xxx\n\n" + envelope)
    #expect(answer["truncated"]?.bool == false)
    #expect(run.tail == "xxx")
  }
}

extension ScheduleRunLogTests {
  /// A log folder that sbd can't make records a failed run and moves the next run on, so the tick doesn't try the
  /// schedule again on each pass.
  @Test func aLogFolderThatCantBeMadeRecordsAFailedRunAndMovesTheNextRun() throws {
    try withService { service, home in
      try service.addLive("w1", name: "work")
      let made = try ScheduleRequest(every: "30m", prompt: "true", by: nil, runner: "script")
        .makeSchedule(id: "r1", now: 1_800_000_000_000)
      try service.queue.sync { try service.update("w1") { $0.addSchedule(made) } }
      // A file where the run's log folder would go makes its parent unusable as a folder.
      try FileManager.default.createDirectory(atPath: home.sessionFolder("w1"), withIntermediateDirectories: true)
      try #require(FileManager.default.createFile(atPath: "\(home.sessionFolder("w1"))/schedules", contents: Data()))

      service.queue.sync { service.dispatchRun("w1", made, now: made.next) }

      let stored = try #require(service.queue.sync { service.entries["w1"]?.session.schedule("r1") })
      #expect(stored.last?.outcome == .failed, "\(String(describing: stored.last))")
      #expect(stored.last?.error?.contains("log") == true, "\(String(describing: stored.last))")
      #expect(stored.next > made.next)
      #expect(stored.running == nil)
      #expect(service.queue.sync { service.runsInFlight.isEmpty })
    }
  }
}
