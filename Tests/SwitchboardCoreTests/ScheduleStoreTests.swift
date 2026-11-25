import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ScheduleStoreTests {
  static let created: Int64 = 1_800_000_000_000

  static func session() throws -> Session {
    var s = Session(id: "s1", name: "manager", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)
    var ran = try ScheduleRequest(every: "30m", prompt: "/audit-waiting", by: "claude").makeSchedule(
      id: "rk3x9p", now: created)
    ran.last = Schedule.Run(t: created + 1, outcome: .failed, skipped: 2, error: "the folder /tmp/a is gone")
    var paused = try ScheduleRequest(every: "1h", prompt: "check the queue", by: nil).makeSchedule(
      id: "r2mzq4", now: created)
    paused.paused = true
    s.schedules = [ran, paused]
    return s
  }

  /// The text of every row in the database, as sqlite3 dumps it.
  static func dump(_ path: String) throws -> String {
    let r = try runCommand("/usr/bin/sqlite3", [path, ".dump"])
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    return r.stdout
  }

  @Test func savedSchedulesComeBackFromANewConnection() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let s = try Self.session()
    try Store(path: "\(dir)/sb.db").save(s)

    let sessions = try Store(path: "\(dir)/sb.db").sessions()

    #expect(sessions == [s])
    #expect(sessions.first?.schedules == s.schedules)
  }

  @Test func savingASessionWithNoSchedulesLeavesThemNil() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var s = try Self.session()
    s.schedules = nil
    try Store(path: "\(dir)/sb.db").save(s)

    #expect(try Store(path: "\(dir)/sb.db").sessions().first?.schedules == nil)
  }

  @Test func deletingTheSessionLeavesNoRowThatHoldsItsSchedules() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = try Self.session()
    try store.save(s)
    try #require(try Self.dump("\(dir)/sb.db").contains("rk3x9p"))

    try store.delete(session: SessionRemoval(id: s.id, name: s.name))

    #expect(try store.sessions().isEmpty)
    let dump = try Self.dump("\(dir)/sb.db")
    for schedule in s.schedules ?? [] {
      #expect(!dump.contains(schedule.id))
      #expect(!dump.contains(schedule.prompt))
    }
  }

  @Test func deletingOneSessionKeepsAnotherSessionsSchedules() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = try Self.session()
    var other = Session(id: "s2", name: "flags", cwd: "/tmp/b", claudeSessionId: "u2", created: 6)
    other.schedules = [
      try ScheduleRequest(every: "2h", prompt: "look at the flags", by: nil).makeSchedule(
        id: "rp7hw3", now: Self.created)
    ]
    try store.save(s)
    try store.save(other)

    try store.delete(session: SessionRemoval(id: s.id, name: s.name))

    #expect(try store.sessions() == [other])
  }
}

extension ScheduleStoreTests {
  static func job(_ id: String, _ command: String, runner: String) throws -> Schedule {
    let request = try JSONCoding.decode(
      ScheduleRequest.self,
      from: JSON.object(["every": .string("1h"), "prompt": .string(command), "runner": .string(runner)]).text)
    return try request.makeSchedule(id: id, now: created)
  }

  /// A session with prompt schedules and one job of each detached runner, one of them mid-run with a recorded run.
  static func sessionWithJobs() throws -> Session {
    var s = try session()
    var script = try job("rj7k2m", "git fetch --prune", runner: "script")
    script.running = created + 5
    var run = Schedule.Run(t: created + 1, outcome: .ran, skipped: 0)
    run.exit = 0
    run.ms = 1200
    run.tail = "Already up to date."
    script.record(run)
    s.addSchedule(script)
    s.addSchedule(try job("rj9w4t", "summarize the open PRs", runner: "headless"))
    return s
  }

  @Test func savedJobsComeBackFromANewConnection() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let s = try Self.sessionWithJobs()
    try Store(path: "\(dir)/sb.db").save(s)

    let sessions = try Store(path: "\(dir)/sb.db").sessions()

    #expect(sessions == [s])
    #expect(sessions.first?.jobs == s.jobs)
    #expect(sessions.first?.schedules == s.schedules)
  }

  @Test func aSessionWithOnlyPromptSchedulesStoresNoJobsKey() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Store(path: "\(dir)/sb.db").save(try Self.session())

    #expect(!(try Self.dump("\(dir)/sb.db").contains("\"jobs\"")))
  }

  @Test func deletingTheSessionLeavesNoRowThatHoldsItsJobs() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = try Self.sessionWithJobs()
    try store.save(s)
    try #require(try Self.dump("\(dir)/sb.db").contains("rj7k2m"))

    try store.delete(session: SessionRemoval(id: s.id, name: s.name))

    let dump = try Self.dump("\(dir)/sb.db")
    for job in s.jobs ?? [] {
      #expect(!dump.contains(job.id))
      #expect(!dump.contains(job.prompt))
    }
  }
}
