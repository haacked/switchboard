import Foundation
import SwitchboardCore
import Testing

/// Phase 1's done criterion: `sb ls` answers in under 1 s with 25 sessions.
/// bin/measure reports the same timings and the memory.
@Suite struct MeasureTests {
  static let sessions = 25
  static let runs = 5

  @Test func listAnswersInUnderASecondWithTwentyFiveSessions() throws {
    let sbd = try Instance()
    let ids = try (0..<Self.sessions).map { try sbd.new(name: "m\($0)").id }
    for id in ids { try sbd.waitFor(id, "claude runs", timeout: 30) { $0.claudePid != nil } }
    // A loaded machine slows every process, so a slow answer there says
    // nothing about sbd. Swift Testing in this toolchain can't skip a test
    // that has started, so the test returns.
    let cores = ProcessInfo.processInfo.activeProcessorCount
    var load = [0.0, 0, 0]
    getloadavg(&load, 3)
    if load[0] > Double(cores) {
      print("MeasureTests: skipped the timing, the load average \(load[0]) is above \(cores) cores")
      return
    }
    for args in [["ls"], ["ls", "--json"]] {
      let times = try (0..<Self.runs).map { _ in try ContinuousClock().measure { _ = try sbd.sb(args) } }
      let median = times.sorted()[Self.runs / 2]
      #expect(median < .seconds(1), "sb \(args.joined(separator: " ")) took \(median), the median of \(Self.runs) runs")
    }
  }
}
