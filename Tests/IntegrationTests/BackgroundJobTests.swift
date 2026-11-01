import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct BackgroundJobTests {
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

    let job = try #require(sbd.stubPid("job.pid"))
    kill(job, SIGTERM)
    // The stub reaps the job, so ps no longer lists it once kill finds no process.
    try sbd.waitFor("the job to exit") { kill(job, 0) != 0 }
    try sbd.advanceClock(1)
    #expect(try sbd.get(s.id).live)

    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    try sbd.waitFor("the turn that reports the job") { try sbd.events(s.id).filter { $0.kind == "Stop" }.count == 2 }
    try sbd.advanceClock(600_000)
    try sbd.waitFor(s.id, "the idle stop") { !$0.live }
  }

  /// sbd finds a job in the process list when the tick runs, so each step
  /// moves the clock by 1 ms to run it.
  @Test func sessionWaitsWhileItsBackgroundJobRuns() throws {
    let sbd = try Instance(idleStopSeconds: 600, config: ["tickSeconds": 3600])
    let s = try sbd.new(prompt: "background 100 held")
    try sbd.waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
    try sbd.advanceClock(1)
    let waiting = try sbd.get(s.id)
    #expect(waiting.state == .waiting)
    #expect(waiting.reason == "waiting on 1 background job")

    // A job that is killed leaves the wait. claude still reports it in a turn of its own.
    let job = try #require(sbd.stubPid("job.pid"))
    kill(job, SIGTERM)
    try sbd.waitFor("the job to exit") { kill(job, 0) != 0 }
    try sbd.advanceClock(1)
    #expect(try sbd.get(s.id).state == .needsYou)

    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    try sbd.waitFor("the turn that reports the job") { try sbd.events(s.id).filter { $0.kind == "Stop" }.count == 2 }
    try sbd.advanceClock(1)
    #expect(try sbd.get(s.id).state == .needsYou)
  }

  @Test func sessionWaitsUntilItsLastBackgroundJobEnds() throws {
    let sbd = try Instance(idleStopSeconds: 600, config: ["tickSeconds": 3600])
    let s = try sbd.new(prompt: "background 100 two")
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
    #expect(try sbd.get(s.id).state == .needsYou)
  }
}
