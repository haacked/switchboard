import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A session whose turn starts a background job of 100 s and ends while the
  /// job runs. The Stop counts the job, because no tick runs in between. The
  /// stub reports the job only after `reportJob`.
  func startHeldJob() throws -> SessionSummary {
    let s = try new()
    try waitFor(s.id, "claude's pid") { $0.claudePid != nil }
    try sb("send", s.id, "background 100 held")
    return try waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
  }

  /// Kills the job whose pid the stub wrote to `file`. It then runs the tick that finds the job gone.
  func endJob(_ file: String = "job.pid") throws {
    let job = try #require(stubPid(file))
    kill(job, SIGTERM)
    // The stub reaps the job, so ps no longer lists it once kill finds no process.
    try waitFor("the job to exit") { kill(job, 0) != 0 }
    try advanceClock(1)
  }

  /// Lets the stub report the job in a turn of its own. It then waits for that turn's Stop.
  func reportJob(_ id: String) throws {
    FileManager.default.createFile(atPath: "\(home.path)/report", contents: nil)
    try waitFor("the turn that reports the job") { try events(id).filter { $0.kind == "Stop" }.count == 2 }
  }

  /// The id of the session's last Stop event.
  func lastStop(_ id: String) throws -> Int64? { try events(id).last { $0.kind == "Stop" }?.id }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct BackgroundJobTests {
  /// claude starts the turn that reports a background job up to 1.3 s after
  /// the job's process exits. The stub starts that turn only after the test
  /// creates $SB_HOME/report. sbd runs the stop rule only when the test moves
  /// the clock, so the test runs it once in that gap, 600 s after the last hook.
  @Test func waitsForTheTurnThatReportsABackgroundJob() throws {
    let sbd = try Instance(idleStopSeconds: 600, config: ["tickSeconds": 3600])
    let s = try sbd.new(prompt: "background 100 held")
    try sbd.waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
    try sbd.advanceClock(600_000)
    #expect(try sbd.get(s.id).live)

    try sbd.endJob()
    #expect(try sbd.get(s.id).live)

    try sbd.reportJob(s.id)
    try sbd.advanceClock(600_000)
    try sbd.waitFor(s.id, "the idle stop") { !$0.live }
  }

  /// sbd finds a job in the process list when the tick runs. Each step moves
  /// the clock by 1 ms to run the tick.
  @Test func sessionWaitsWhileItsBackgroundJobRuns() throws {
    let sbd = try Instance(idleStopSeconds: 600, config: ["tickSeconds": 3600])
    let s = try sbd.startHeldJob()
    let waiting = try sbd.get(s.id)
    #expect(waiting.state == .waiting)
    #expect(waiting.reason == "waiting on 1 background job")

    // A job that is killed leaves the wait once claude has had time to report it.
    try sbd.endJob()
    #expect(try sbd.get(s.id).reason == "waiting for claude to report its background job")
    try sbd.advanceClock(Attention.jobReportMs)
    #expect(try sbd.get(s.id).state == .needsYou)

    try sbd.reportJob(s.id)
    try sbd.advanceClock(1)
    #expect(try sbd.get(s.id).state == .needsYou)
  }

  @Test func sessionWaitsUntilItsLastBackgroundJobEnds() throws {
    let sbd = try Instance(idleStopSeconds: 600, config: ["tickSeconds": 3600])
    let s = try sbd.new(prompt: "background 100 held two")
    try sbd.waitFor(s.id, "the turn that starts the jobs") { $0.lastReply == "Started a job of 100 s." }
    try sbd.advanceClock(1)
    #expect(try sbd.get(s.id).reason == "waiting on 2 background jobs")

    let first = try #require(sbd.stubPid("job.pid"))
    let second = try #require(sbd.stubPid("job2.pid"))
    kill(first, SIGTERM)
    try sbd.waitFor("the first job to exit") { kill(first, 0) != 0 }
    try sbd.advanceClock(1)
    let one = try sbd.get(s.id)
    #expect(one.state == .waiting)
    #expect(one.reason == "waiting on 1 background job")

    kill(second, SIGTERM)
    try sbd.waitFor("the second job to exit") { kill(second, 0) != 0 }
    try sbd.advanceClock(1)
    try sbd.advanceClock(Attention.jobReportMs)
    #expect(try sbd.get(s.id).state == .needsYou)
  }
}
