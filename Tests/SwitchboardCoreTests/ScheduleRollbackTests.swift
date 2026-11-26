import Foundation
import Testing

@testable import SwitchboardCore

/// Main's `Schedule` at 9b5e73bf, frozen. An sbd built from main decodes a session row's `schedules` with these types, and
/// `Store.sessions()` throws on the first row that fails, so no session loads. Never update these to match the current types.
private struct LegacySchedule: Decodable, Equatable {
  struct Run: Decodable, Equatable {
    enum Outcome: String, Decodable {
      case pasted
      case resumed
      case queued
      case failed
    }

    var t: Int64
    var outcome: Outcome
    var skipped: Int
    var error: String?
    var gated: Int?
    var sent: Int64?
  }

  enum Author: String, Decodable {
    case you
    case claude
  }

  var id: String
  var prompt: String
  var every: Int64
  var next: Int64
  var paused: Bool?
  var by: Author
  var created: Int64
  var last: Run?
  var runs: [Run]?
}

/// The part of main's `Session` that holds schedules. Synthesized decoding ignores the keys that it does not name, as main's does.
private struct LegacySessionRow: Decodable {
  var id: String
  var schedules: [LegacySchedule]?
}

/// The keys of main's `Schedule` and `Run`.
private let legacyScheduleKeys: Set<String> = [
  "id", "prompt", "every", "next", "paused", "by", "created", "last", "runs", "gate",
]
private let legacyRunKeys: Set<String> = ["t", "outcome", "skipped", "error", "gated", "sent"]
private let legacyOutcomes: Set<String> = ["pasted", "resumed", "queued", "failed"]

private let now: Int64 = 1_800_000_000_000
private let minute: Int64 = 60_000

private func make(_ id: String, _ prompt: String, runner: String? = nil) throws -> Schedule {
  var fields: [String: JSON] = ["every": .string("30m"), "prompt": .string(prompt)]
  if let runner { fields["runner"] = .string(runner) }
  return try JSONCoding.decode(ScheduleRequest.self, from: JSON.object(fields).text).makeSchedule(id: id, now: now)
}

private func ran(_ t: Int64, exit: Int32 = 0, tail: String = "done") -> Schedule.Run {
  var run = Schedule.Run(t: t, outcome: .ran, skipped: 0)
  run.exit = exit
  run.ms = 1500
  run.tail = tail
  return run
}

private func failed(_ t: Int64, exit: Int32?, error: String) -> Schedule.Run {
  var run = Schedule.Run(t: t, outcome: .failed, skipped: 1, error: error)
  run.exit = exit
  run.ms = 10 * minute
  run.tail = "error: could not read from remote repository"
  return run
}

/// A prompt schedule that has run, with a history from before this change.
private func promptSchedule() throws -> Schedule {
  var schedule = try make("rk3x9p", "/audit-waiting")
  schedule.record(Schedule.Run(t: now - 40 * minute, outcome: .pasted, skipped: 0, sent: 12))
  schedule.record(Schedule.Run(t: now - 10 * minute, outcome: .failed, skipped: 2, error: "the folder is gone"))
  return schedule
}

private func scriptSchedule(_ id: String = "rj7k2m") throws -> Schedule {
  try make(id, "git fetch --prune", runner: "script")
}

private func headlessSchedule(_ id: String = "rj9w4t") throws -> Schedule {
  var fields: [String: JSON] = [
    "every": .string("1h"), "prompt": .string("summarize the open PRs"), "runner": .string("headless"),
    "account": .string("work"), "model": .string("haiku"), "timeout": .string("20m"),
  ]
  fields["by"] = .string("claude")
  return try JSONCoding.decode(ScheduleRequest.self, from: JSON.object(fields).text).makeSchedule(id: id, now: now)
}

/// A Risk 3 shape: a session row this branch writes, and how many prompt schedules it holds.
struct RollbackShape: Sendable, CustomTestStringConvertible {
  var name: String
  var session: Session
  var promptSchedules: Int

  var testDescription: String { name }
}

private func session(_ schedules: [Schedule]) -> Session {
  var s = Session(id: "s1", name: "flags", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)
  for schedule in schedules { s.addSchedule(schedule) }
  return s
}

private func shapes() throws -> [RollbackShape] {
  var running = try scriptSchedule()
  running.running = now - minute

  var scriptRan = try scriptSchedule()
  scriptRan.record(ran(now - 30 * minute))

  var scriptFailed = try scriptSchedule()
  scriptFailed.record(ran(now - 60 * minute))
  scriptFailed.record(failed(now - 30 * minute, exit: 128, error: "exited with status 128"))

  var timedOut = try headlessSchedule()
  timedOut.record(failed(now - 30 * minute, exit: nil, error: "timed out after 20m"))

  var headlessRan = try headlessSchedule()
  headlessRan.record(ran(now - 5 * minute, tail: "Three PRs wait on review."))
  headlessRan.running = now

  return [
    RollbackShape(name: "no schedules", session: session([]), promptSchedules: 0),
    RollbackShape(name: "only prompt schedules", session: session([try promptSchedule()]), promptSchedules: 1),
    RollbackShape(name: "a headless schedule", session: session([try headlessSchedule()]), promptSchedules: 0),
    RollbackShape(name: "a script schedule", session: session([try scriptSchedule()]), promptSchedules: 0),
    RollbackShape(name: "a detached run recorded as ran", session: session([scriptRan]), promptSchedules: 0),
    RollbackShape(name: "a failed detached run with an exit", session: session([scriptFailed]), promptSchedules: 0),
    RollbackShape(name: "a timed-out headless run", session: session([timedOut]), promptSchedules: 0),
    RollbackShape(name: "a run in flight", session: session([running]), promptSchedules: 0),
    RollbackShape(
      name: "every kind together",
      session: session([try promptSchedule(), scriptRan, headlessRan, try make("r2mzq4", "check the queue")]),
      promptSchedules: 2),
  ]
}

/// The objects of the row's `schedules` array, as an older sbd reads them.
private func storedSchedules(_ row: String) throws -> [[String: JSON]] {
  let object = try #require(JSON.parse(row)?.object)
  return (object["schedules"]?.array ?? []).compactMap(\.object)
}

/// Risk 3: a row that this branch writes decodes with main's types, and its `schedules` holds nothing that main would run as
/// a prompt or fail to read.
@Suite struct ScheduleRollbackTests {
  static let cases: [RollbackShape] = (try? shapes()) ?? []

  @Test func everyShapeIsBuilt() {
    #expect(Self.cases.count == 9)
  }

  @Test(arguments: cases)
  func theRowDecodesWithMainsTypes(_ shape: RollbackShape) throws {
    let row = try JSONCoding.encode(shape.session)

    #expect(throws: Never.self) { try JSONCoding.decode(LegacySessionRow.self, from: row) }
  }

  /// A headless or script schedule in `schedules` would decode as a prompt schedule, and an older sbd would paste its
  /// command into Claude on every interval.
  @Test(arguments: cases)
  func mainSeesOnlyThePromptSchedules(_ shape: RollbackShape) throws {
    let row = try JSONCoding.encode(shape.session)

    let legacy = try JSONCoding.decode(LegacySessionRow.self, from: row)

    #expect((legacy.schedules ?? []).count == shape.promptSchedules)
    let detached: Set<String> = Set(shape.session.allSchedules.filter { $0.runner != nil }.map(\.id))
    let read: Set<String> = Set((legacy.schedules ?? []).map(\.id))
    #expect(read.isDisjoint(with: detached))
  }

  @Test(arguments: cases)
  func mainReadsEachPromptScheduleAsTheCurrentTypesDo(_ shape: RollbackShape) throws {
    let row = try JSONCoding.encode(shape.session)

    let legacy = try JSONCoding.decode(LegacySessionRow.self, from: row)

    let current: [Schedule] = shape.session.allSchedules.filter { $0.runner == nil }
    let read: [LegacySchedule] = legacy.schedules ?? []
    #expect(read.map(\.id) == current.map(\.id))
    #expect(read.map(\.prompt) == current.map(\.prompt))
    let readRuns: [Int] = read.map { $0.runs?.count ?? 0 }
    let currentRuns: [Int] = current.map { $0.runs?.count ?? 0 }
    #expect(readRuns == currentRuns)
  }

  @Test(arguments: cases)
  func schedulesHoldsNoKeyThatMainLacks(_ shape: RollbackShape) throws {
    let row = try JSONCoding.encode(shape.session)

    for schedule in try storedSchedules(row) {
      #expect(Set(schedule.keys).isSubset(of: legacyScheduleKeys), "\(schedule.keys.sorted())")
      let runs = (schedule["runs"]?.array ?? []) + [schedule["last"]].compactMap { $0 }
      for run in runs.compactMap(\.object) {
        #expect(Set(run.keys).isSubset(of: legacyRunKeys), "\(run.keys.sorted())")
      }
    }
  }

  @Test(arguments: cases)
  func schedulesHoldsNoOutcomeThatMainLacks(_ shape: RollbackShape) throws {
    let row = try JSONCoding.encode(shape.session)

    for schedule in try storedSchedules(row) {
      let runs = (schedule["runs"]?.array ?? []) + [schedule["last"]].compactMap { $0 }
      for outcome in runs.compactMap({ $0.object?["outcome"]?.string }) {
        #expect(legacyOutcomes.contains(outcome), "\(outcome)")
      }
    }
  }

  /// The row goes through the store, as sbd writes it, and an older sbd's read of the same text still decodes.
  @Test(arguments: cases)
  func aStoredRowDecodesWithMainsTypes(_ shape: RollbackShape) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Store(path: "\(dir)/sb.db").save(shape.session)
    let r = try runCommand("/usr/bin/sqlite3", ["\(dir)/sb.db", "SELECT json FROM sessions"])
    try #require(r.status == 0, Comment(rawValue: r.stderr))

    let legacy = try JSONCoding.decode(LegacySessionRow.self, from: r.stdout)

    #expect((legacy.schedules ?? []).count == shape.promptSchedules)
  }
}
