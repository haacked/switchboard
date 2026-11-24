import Foundation
import Testing

@testable import SwitchboardCore

/// The limits that the Codex usage reader takes from a CODEX_HOME, and the
/// time that Codex reported them, in ms since the epoch.
private func reading(_ home: String) throws -> (limits: [UsageLimit], checked: Int64)? {
  try CodexRollout.rateLimits(home: home, on: LocalMachine()).map { ($0.limits, $0.checked) }
}

/// A rollout whose second `token_count` is its last. Its keys follow the
/// shapes in codex-0.161-research.md section 3 and section 9, not a real
/// rollout. The tests assume that the envelope's `timestamp` is ISO 8601 in
/// UTC with milliseconds.
private let recorded = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("Fixtures/codex/rollout-token-count.jsonl").path

/// 2025-01-02T03:04:05.678Z, the `timestamp` of the recorded rollout's last
/// `token_count`. It is long past, so a reader that stamps the time it read
/// the file fails.
private let recordedAt: Int64 = 1_735_787_045_678

/// One `token_count` line. Each window is (used_percent, window_minutes,
/// resets_at in epoch seconds). `rateLimits` "omit" leaves the key out and
/// "null" writes null.
private func tokenCount(
  at timestamp: String = "2026-11-20T09:15:30.250Z", primary: (Double, Int, Int64)? = (12.5, 300, 1_795_209_852),
  secondary: (Double, Int, Int64)? = (34, 10080, 1_795_700_000), rateLimits: String = "object"
) -> String {
  func window(_ w: (Double, Int, Int64)?) -> String {
    guard let w else { return "null" }
    return #"{"used_percent":\#(w.0),"window_minutes":\#(w.1),"resets_at":\#(w.2)}"#
  }
  let limits =
    #"{"limit_id":"codex","limit_name":null,"primary":\#(window(primary)),"secondary":\#(window(secondary)),"credits":{"has_credits":false,"unlimited":false,"balance":null},"individual_limit":null,"spend_control_reached":false,"plan_type":"plus","rate_limit_reached_type":null}"#
  let info =
    #""info":{"total_token_usage":{"total_tokens":1500},"last_token_usage":{"total_tokens":600},"model_context_window":258400}"#
  let tail: String
  switch rateLimits {
  case "omit": tail = ""
  case "null": tail = #","rate_limits":null"#
  default: tail = #","rate_limits":\#(limits)"#
  }
  return
    #"{"timestamp":"\#(timestamp)","ordinal":3,"type":"event_msg","payload":{"type":"token_count",\#(info)\#(tail)}}"#
}

private let taskComplete =
  #"{"timestamp":"2026-11-20T09:15:31.000Z","ordinal":4,"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Done.","started_at":1795166100,"completed_at":1795166131,"duration_ms":31000,"time_to_first_token_ms":800}}"#

private func isoMs(_ iso: String) -> Int64 {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return Int64((f.date(from: iso)!.timeIntervalSince1970 * 1000).rounded())
}

/// A CODEX_HOME in the temporary folder.
private struct CodexHome {
  let path: String

  init() throws { path = try tempFolder() }

  func remove() { try? FileManager.default.removeItem(atPath: path) }

  /// Writes a rollout at sessions/<day>/rollout-<time>-<uuid>.<ext>, as Codex
  /// names them, and returns its path. `text` is the file's whole content.
  @discardableResult
  func rollout(
    day: String = "2026/11/20", time: String = "2026-11-20T09-15-02", ext: String = "jsonl",
    folder: String = "sessions",
    _ text: String
  ) throws -> String {
    let dir = "\(path)/\(folder)/\(day)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = "\(dir)/rollout-\(time)-01941d3a-7c00-7000-8000-000000000001.\(ext)"
    try text.write(toFile: file, atomically: true, encoding: .utf8)
    return file
  }

  func rollout(day: String = "2026/11/20", time: String = "2026-11-20T09-15-02", lines: [String]) throws {
    try rollout(day: day, time: time, lines.map { $0 + "\n" }.joined())
  }
}

/// `CodexRollout.rateLimits(home:on:)`, which `sb usage` reads for a Codex account.
@Suite struct CodexUsageTests {
  @Test func readsTheLimitsOfTheLastTokenCountInTheRecordedRollout() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(try String(contentsOfFile: recorded, encoding: .utf8))

    let r = try #require(try reading(home.path))

    #expect(r.limits.map(\.kind) == ["session", "weekly_all"])
    #expect(r.limits.map(\.percent) == [12.5, 34])
  }

  /// `resets_at` is in epoch seconds. A `UsageLimit` holds ms.
  @Test func convertsTheResetTimesFromSecondsToMilliseconds() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(try String(contentsOfFile: recorded, encoding: .utf8))

    let r = try #require(try reading(home.path))

    #expect(r.limits.map(\.resetsAt) == [1_735_805_045_000, 1_736_305_445_000])
  }

  /// `checked` is when Codex reported the limits, not when sbd read the file.
  @Test func theReadingsTimeIsTheTokenCountsTimestamp() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(try String(contentsOfFile: recorded, encoding: .utf8))

    #expect(try reading(home.path)?.checked == recordedAt)
  }

  @Test func theLabelsNameTheWindow() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(lines: [tokenCount(), taskComplete])

    #expect(try reading(home.path)?.limits.map(\.label) == ["5-hour", "Weekly"])
  }

  @Test func aNullSecondaryGivesOnlyThePrimaryLimit() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(lines: [tokenCount(primary: (40, 300, 1_795_209_852), secondary: nil)])

    let r = try #require(try reading(home.path))

    #expect(r.limits.map(\.kind) == ["session"])
    #expect(r.limits.map(\.percent) == [40])
  }

  @Test func aWeeklyPrimaryWithANullSecondaryGivesOnlyTheWeeklyLimit() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(lines: [tokenCount(primary: (7, 10080, 1_795_700_000), secondary: nil)])

    let r = try #require(try reading(home.path))

    #expect(r.limits.map(\.kind) == ["weekly_all"])
    #expect(r.limits.map(\.percent) == [7])
    #expect(r.limits.map(\.label) == ["Weekly"])
  }

  /// A window of 24 hours or less is a session. A longer one is a week.
  @Test(arguments: [(60, "session"), (300, "session"), (1440, "session"), (1441, "weekly_all"), (10080, "weekly_all")])
  func theWindowLengthDecidesTheKind(_ minutes: Int, _ kind: String) throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(lines: [tokenCount(primary: (10, minutes, 1_795_209_852), secondary: nil)])

    #expect(try reading(home.path)?.limits.map(\.kind) == [kind])
  }

  @Test(arguments: ["omit", "null"])
  func aLastTokenCountWithoutRateLimitsLeavesTheOneBeforeIt(_ rateLimits: String) throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(lines: [
      tokenCount(at: "2026-11-20T09:15:10.000Z", primary: (21, 300, 1_795_209_852)),
      tokenCount(at: "2026-11-20T09:15:20.000Z", rateLimits: rateLimits),
      taskComplete,
    ])

    let r = try #require(try reading(home.path))

    #expect(r.limits.first?.percent == 21)
    #expect(r.checked == isoMs("2026-11-20T09:15:10.000Z"))
  }

  @Test(arguments: ["omit", "null"])
  func aRolloutWithNoRateLimitsGivesNoReading(_ rateLimits: String) throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(lines: [tokenCount(rateLimits: rateLimits), taskComplete])

    #expect(try reading(home.path) == nil)
  }

  @Test func aHomeWithoutSessionsGivesNoReading() throws {
    let home = try CodexHome()
    defer { home.remove() }

    #expect(try reading(home.path) == nil)
    try FileManager.default.createDirectory(
      atPath: "\(home.path)/sessions/2026/11/20", withIntermediateDirectories: true)
    #expect(try reading(home.path) == nil)
  }

  @Test func aMissingHomeGivesNoReading() throws {
    #expect(try reading("\(NSTemporaryDirectory())sb-test-missing-\(UUID().uuidString)") == nil)
  }

  /// A rollout that sbd can't read may hold limits, so the reader reports an error instead of no reading.
  @Test func anUnreadableRolloutIsAnError() throws {
    let home = try CodexHome()
    defer { home.remove() }
    let file = try home.rollout(tokenCount() + "\n")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file) }

    let error = #expect(throws: (any Error).self) { try reading(home.path) }

    #expect(error.map { "\($0)" }?.contains(file) == true, "\(String(describing: error))")
  }

  /// A rollout can go between the listing and the read, as when Codex compresses it. The dangling link stands for
  /// such a rollout: the listing names it, and no file is there.
  @Test func aRolloutThatIsGoneIsSkipped() throws {
    let home = try CodexHome()
    defer { home.remove() }
    let file = try home.rollout(time: "2026-11-20T09-15-02", tokenCount(primary: (12.5, 300, 1_795_209_852)) + "\n")
    let gone = file.replacingOccurrences(of: "2026-11-20T09-15-02", with: "2026-11-20T10-00-00")
    try FileManager.default.createSymbolicLink(atPath: gone, withDestinationPath: "\(home.path)/missing")

    #expect(try reading(home.path)?.limits.first?.percent == 12.5)
  }

  /// Codex compresses only cold rollouts, so the reader skips a .jsonl.zst. This
  /// one holds plain text with 99%, so a reader that opened it would report 99.
  @Test func skipsACompressedRolloutEvenWhenItIsNewer() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(time: "2026-11-20T09-15-02", lines: [tokenCount(primary: (12.5, 300, 1_795_209_852))])
    try home.rollout(
      time: "2026-11-20T10-00-00", ext: "jsonl.zst", tokenCount(primary: (99, 300, 1_795_209_852)) + "\n")

    #expect(try reading(home.path)?.limits.first?.percent == 12.5)
  }

  @Test func aHomeWithOnlyACompressedRolloutGivesNoReading() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(ext: "jsonl.zst", tokenCount() + "\n")

    #expect(try reading(home.path) == nil)
  }

  /// Codex may be writing the file, so its last line can be cut short.
  @Test(arguments: [
    #"{"timestamp":"2026-11-20T09:15:40.000Z","ordinal":9,"type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"primary":{"used_percent":99"#,
    #"{"timestamp":"2026-11-20T09:15:40.000Z","ordi"#,
    "{",
  ])
  func aTruncatedLastLineLeavesTheCompleteLineBeforeIt(_ cut: String) throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(tokenCount(at: "2026-11-20T09:15:30.250Z", primary: (12.5, 300, 1_795_209_852)) + "\n" + cut)

    let r = try #require(try reading(home.path))

    #expect(r.limits.first?.percent == 12.5)
    #expect(r.checked == isoMs("2026-11-20T09:15:30.250Z"))
  }

  /// Rollout names start with the local start time, so path order is age
  /// order. The test gives the older file the later mtime, so a reader that
  /// went by mtime would pick it.
  @Test func readsTheNewestRolloutByPathOrderNotByModificationTime() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(lines: [tokenCount(primary: (20, 300, 1_795_209_852))])
    let older = try home.rollout(time: "2026-11-20T08-00-00", tokenCount(primary: (60, 300, 1_795_209_852)) + "\n")
    let newer = try home.rollout(time: "2026-11-20T10-00-00", tokenCount(primary: (40, 300, 1_795_209_852)) + "\n")
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: older)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: newer)

    #expect(try reading(home.path)?.limits.first?.percent == 40)
  }

  @Test(arguments: [
    ("2026/11/19", "2026-11-19T23-59-59", "2026/11/20", "2026-11-20T00-00-01"),
    ("2026/11/30", "2026-11-30T12-00-00", "2026/12/01", "2026-12-01T12-00-00"),
    ("2026/12/31", "2026-12-31T23-00-00", "2027/01/01", "2027-01-01T01-00-00"),
  ])
  func readsTheNewestDayFolder(_ oldDay: String, _ oldTime: String, _ newDay: String, _ newTime: String) throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(day: oldDay, time: oldTime, lines: [tokenCount(primary: (20, 300, 1_795_209_852))])
    try home.rollout(day: newDay, time: newTime, lines: [tokenCount(primary: (40, 300, 1_795_209_852))])

    #expect(try reading(home.path)?.limits.first?.percent == 40)
  }

  /// A thread that has had no turn yet has no `token_count`. The reader then
  /// takes the newest rollout of the same day that has one.
  @Test func aNewerRolloutWithoutRateLimitsLeavesTheOlderOneOfTheSameDay() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(time: "2026-11-20T08-00-00", lines: [tokenCount(primary: (33, 300, 1_795_209_852))])
    try home.rollout(time: "2026-11-20T10-00-00", lines: [taskComplete])

    #expect(try reading(home.path)?.limits.first?.percent == 33)
  }

  @Test func ignoresArchivedSessions() throws {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(time: "2026-11-20T08-00-00", lines: [tokenCount(primary: (33, 300, 1_795_209_852))])
    try home.rollout(
      day: "2026/11/21", time: "2026-11-21T08-00-00", folder: "archived_sessions",
      tokenCount(primary: (99, 300, 1_795_209_852)) + "\n")

    #expect(try reading(home.path)?.limits.first?.percent == 33)
  }

  @Test func anIntegerPercentReadsAsANumber() throws {
    let home = try CodexHome()
    defer { home.remove() }
    let line = tokenCount().replacingOccurrences(of: #""used_percent":12.5"#, with: #""used_percent":12"#)
    try home.rollout(lines: [line])

    #expect(try reading(home.path)?.limits.first?.percent == 12)
  }
}

/// A newer Codex could write numbers in other units. A number out of range never traps the reader, which runs
/// on sbd's usage timer.
@Suite struct CodexUsageBoundsTests {
  private func line(minutes: String = "300", resets: String = "1795209852", percent: String = "12.5") -> String {
    #"{"timestamp":"2026-11-20T09:15:30.250Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(percent),"window_minutes":\#(minutes),"resets_at":\#(resets)},"secondary":null}}}"#
  }

  private func read(_ text: String) throws -> CodexRollout.Reading? {
    let home = try CodexHome()
    defer { home.remove() }
    try home.rollout(text + "\n")
    return try CodexRollout.rateLimits(home: home.path, on: LocalMachine())
  }

  @Test(arguments: ["1e300", "1e16", "-5", "0"])
  func aResetOutOfRangeLeavesTheWindowWithoutAReset(_ resets: String) throws {
    let r = try #require(try read(line(resets: resets)))

    #expect(r.limits.map(\.percent) == [12.5])
    #expect(r.limits.first?.resetsAt == nil)
  }

  @Test(arguments: ["1e300", "1e16", "-300", "0"])
  func aWindowOutOfRangeGivesNoReading(_ minutes: String) throws {
    #expect(try read(line(minutes: minutes)) == nil)
  }

  @Test(arguments: ["1e300", "-1"])
  func aPercentOutOfRangeGivesNoReading(_ percent: String) throws {
    #expect(try read(line(percent: percent)) == nil)
  }
}
