import Foundation
import SwitchboardCore
import Testing

/// Starts `count` sessions and waits until each one's claude runs.
private func runningSessions(_ sbd: Instance, _ count: Int) throws -> [String] {
  let ids = try (0..<count).map { try sbd.new(name: "m\($0)").id }
  for id in ids { try sbd.waitFor(id, "claude runs", timeout: 30) { $0.claudePid != nil } }
  return ids
}

/// Phase 1's done criterion: `sb ls` answers in under 1 s with 25 sessions.
/// bin/measure reports the same timings and the memory.
@Suite(.blocking()) struct MeasureTests {
  static let sessions = 25
  static let runs = 5

  @Test func listAnswersInUnderASecondWithTwentyFiveSessions() throws {
    // A loaded machine slows every process, so a slow answer there says
    // nothing about sbd. Swift Testing in this toolchain can't skip a test
    // that has started, so the test returns. The test reads the load before
    // it starts its sessions, so their startup does not count toward it.
    let cores = ProcessInfo.processInfo.activeProcessorCount
    var load = [0.0, 0, 0]
    getloadavg(&load, 3)
    if load[0] > Double(cores) {
      print("MeasureTests: skipped the timing, the load average \(load[0]) is above \(cores) cores")
      return
    }
    let sbd = try Instance()
    _ = try runningSessions(sbd, Self.sessions)
    for args in [["ls"], ["ls", "--json"]] {
      let times = try (0..<Self.runs).map { _ in try ContinuousClock().measure { _ = try sbd.sb(args) } }
      let median = times.sorted()[Self.runs / 2]
      #expect(median < .seconds(1), "sb \(args.joined(separator: " ")) took \(median), the median of \(Self.runs) runs")
    }
  }
}

/// `bin/measure --running` reports the memory of the sbd at SB_HOME by group.
@Suite(.blocking()) struct MeasureRunningTests {
  struct Report: Decodable {
    struct Group: Decodable {
      var processes: Int
      var footprintKB: Int
      var residentKB: Int
    }
    var home: String
    var sessions: Int
    var live: Int
    var cap: Int?
    var groups: [String: Group]
    var total: Group
  }

  /// The output of `bin/measure --running` with `flags` after it.
  func output(_ sbd: Instance, _ flags: [String] = []) throws -> String {
    let script = Instance.root.appendingPathComponent("bin/measure").path
    let r = try runCommand(script, ["--running"] + flags, env: sbd.environment(["SB_BIN_DIR": Instance.bin]))
    guard r.status == 0 else { throw TestError(description: "bin/measure --running failed: \(r.stderr)") }
    return r.stdout
  }

  func measure(_ sbd: Instance) throws -> Report {
    try JSONCoding.decode(Report.self, from: try output(sbd, ["--json"]))
  }

  @Test func reportsTheMemoryOfEachGroup() throws {
    let sbd = try Instance(config: ["liveCap": 7])
    _ = try runningSessions(sbd, 2)

    let report = try measure(sbd)

    #expect(report.home == sbd.home.path)
    #expect(report.sessions == 2)
    #expect(report.live == 2)
    #expect(report.cap == 7)
    #expect(report.groups.keys.sorted() == ["app", "claude", "sbd", "terminals", "tools"])
    // sbd starts tmux and ps on each tick, and they count while they run.
    #expect((report.groups["sbd"]?.processes ?? 0) >= 1)
    // The app that shows another home, such as the installed one on a
    // developer's machine, is not this home's app.
    #expect(report.groups["app"]?.processes == 0)
    #expect(report.groups["claude"]?.processes == 2)
    // The tmux server and each session's shell pane and claude pane.
    #expect((report.groups["terminals"]?.processes ?? 0) >= 5)
    #expect(report.total.processes == report.groups.values.map(\.processes).reduce(0, +))
    #expect(report.total.footprintKB == report.groups.values.map(\.footprintKB).reduce(0, +))
    #expect(report.total.residentKB == report.groups.values.map(\.residentKB).reduce(0, +))
    for name in ["sbd", "claude", "terminals"] {
      #expect((report.groups[name]?.footprintKB ?? 0) > 0, "\(name) has no footprint")
      #expect((report.groups[name]?.residentKB ?? 0) > 0, "\(name) has no resident size")
    }
  }

  @Test func printsATableWithoutJSON() throws {
    let sbd = try Instance(config: ["liveCap": 7])
    _ = try runningSessions(sbd, 2)

    let table = try output(sbd)

    #expect(table.contains("2 sessions, 2 live claude processes, cap 7"))
    for name in ["group", "sbd", "terminals", "claude", "tools", "app", "total"] {
      #expect(table.contains("\n\(name) "), "the table has no \(name) row")
    }
  }

  @Test func countsAProcessThatClaudeStartedAsATool() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "background 100 held")
    try sbd.waitFor(s.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }

    let report = try measure(sbd)

    #expect(report.groups["claude"]?.processes == 1)
    #expect((report.groups["tools"]?.processes ?? 0) >= 1)
  }

  @Test func leavesOutAStoppedSessionsClaude() throws {
    let sbd = try Instance()
    let ids = try runningSessions(sbd, 2)
    try sbd.sb("stop", ids[0])
    try sbd.waitFor(ids[0], "claude stops") { $0.claudePid == nil }

    let report = try measure(sbd)

    #expect(report.sessions == 2)
    #expect(report.live == 1)
    #expect(report.groups["claude"]?.processes == 1)
  }
}
