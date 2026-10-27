import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct BackgroundJobTests {
  /// claude starts the turn that reports a background job up to 1.3 s after
  /// the job's process exits. The stub starts it 0.5 s after. The job runs
  /// longer than the idle wait, so sbd sees no job and no turn in that gap.
  /// The stub plays the report turn even after a SIGTERM, before it exits.
  @Test func waitsForTheTurnThatReportsABackgroundJob() throws {
    let sbd = try Instance(idleStopSeconds: 2)
    let s = try sbd.new(prompt: "background 4")
    try sbd.waitFor("the turn that reports the job", timeout: 30) {
      try sbd.events(s.id).filter { $0.kind == "Stop" }.count == 2
    }
    try sbd.waitFor(s.id, "the idle stop", timeout: 20) { !$0.live }
    let events = try sbd.events(s.id)
    let report = try #require(events.last { $0.kind == "Stop" })
    let stopped = try #require(events.first { $0.kind == "stopped" })
    #expect(stopped.id > report.id)
  }
}
