import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The session's `snoozedUntil` in `sb ls --json`, or nil.
  func snoozedUntil(_ id: String) throws -> Int64? {
    try listed(id)["snoozedUntil"]?.int.map(Int64.init)
  }

  /// The rows of `sb triage --json`.
  func triageJSON() throws -> [JSON] {
    try #require(JSON.parse(try sb("triage", "--json"))?.array)
  }
}

/// `sb snooze` takes a session's item out of every user-facing list until a time, or until a new prompt, a failed
/// CI run, or the PR's merge wakes it. `sb unsnooze` brings it back.
@Suite(.blocking(timeLimit: .seconds(120))) struct SnoozeTests {
  static let hourMs: Int64 = 3_600_000
  static let minuteMs: Int64 = 60_000
  static let reasonKeys = ["state", "reason", "snoozedUntil", "snoozeNote"]

  func needsYouSession(_ sbd: Instance, name: String = "t") throws -> SessionSummary {
    try AcknowledgeTests().needsYouSession(sbd, name: name)
  }

  /// Runs `sb snooze` with `args` and returns sbd's clock before and after it.
  @discardableResult
  func snooze(_ sbd: Instance, _ args: String...) throws -> ClosedRange<Int64> {
    let before = try sbd.now()
    try sbd.sb(["snooze"] + args)
    return before...(try sbd.now())
  }

  /// The note that a session carries after its snooze until `until` ended.
  func note(_ until: Int64, wokeEarly why: String? = nil, zone: TimeZone = .current) -> String {
    "snoozed until \(Wait.formatTime(until, zone: zone))" + (why.map { ", woke early: \($0)" } ?? "")
  }

  /// A sbd whose zone is UTC, so a local time in `--until` reads the same on every machine.
  func utcInstance() throws -> Instance {
    let sbd = try Instance()
    sbd.stopSbd()
    sbd.sbdEnvironment["TZ"] = "UTC"
    try sbd.startSbd()
    return sbd
  }

  func utcMs(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Int64 {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let date = try #require(
      calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    return Int64(date.timeIntervalSince1970 * 1000)
  }

  // Snoozing

  @Test func snoozedSessionIsWaitingWithTheSameReason() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try snooze(sbd, s.id)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["reason"]?.string == s.reason)
    #expect(row["board"]?["holder"]?.string == "you")
  }

  @Test func snoozeDoesNotMarkTheSessionAcknowledged() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try snooze(sbd, s.id)

    #expect(try sbd.listed(s.id)["acknowledged"] == nil)
  }

  @Test func snoozedSessionLeavesTheInbox() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try snooze(sbd, s.id)

    #expect(try sbd.listed(s.id)["triage"] == nil)
    #expect(try !sbd.triage().map(\.id).contains(s.id))
  }

  @Test func snoozeWithoutATimeEndsAnHourAfterSbdsClock() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let clock = try snooze(sbd, s.id)

    let until = try #require(try sbd.snoozedUntil(s.id))
    #expect((clock.lowerBound + SnoozeTests.hourMs...clock.upperBound + SnoozeTests.hourMs).contains(until))
  }

  @Test(arguments: [(["--for", "30m"], 30 * SnoozeTests.minuteMs), (["--until", "2h"], 2 * SnoozeTests.hourMs)])
  func durationSetsTheEndAfterSbdsClock(_ flags: [String], _ ms: Int64) throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    let before = try sbd.now()

    try sbd.sb(["snooze", s.id] + flags)

    let after = try sbd.now()
    let until = try #require(try sbd.snoozedUntil(s.id))
    #expect((before + ms...after + ms).contains(until))
  }

  @Test func untilALocalDateAndTimeReadsItInSbdsZone() throws {
    let sbd = try utcInstance()
    let s = try needsYouSession(sbd)

    try sbd.sb("snooze", s.id, "--until", "2090-03-12 09:00")

    #expect(try sbd.snoozedUntil(s.id) == utcMs(2090, 3, 12, 9, 0))
  }

  @Test func untilAnISOTimeWithAZoneReadsThatZone() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("snooze", s.id, "--until", "2090-03-12T09:00:00-08:00")

    #expect(try sbd.snoozedUntil(s.id) == utcMs(2090, 3, 12, 17, 0))
  }

  @Test func snoozeRecordsOneSnoozeEventWithTheEnd() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try snooze(sbd, s.id)

    let events = try sbd.events(s.id, kind: "snooze")
    #expect(events.count == 1)
    #expect(events.first?.data["until"]?.int.map(Int64.init) == (try sbd.snoozedUntil(s.id)))
  }

  @Test func snoozingSendsNothingToTheSession() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    let sent = try sbd.count("sent", of: s.id)
    let input = sbd.stubInput().count
    let runs = sbd.stubArgs().count

    try snooze(sbd, s.id)

    #expect(try sbd.count("sent", of: s.id) == sent)
    #expect(sbd.stubInput().count == input)
    #expect(sbd.stubArgs().count == runs)
  }

  @Test func snoozingASnoozedSessionReplacesTheTime() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("snooze", s.id, "--for", "2h")
    let before = try sbd.now()

    try sbd.sb("snooze", s.id, "--for", "30m")

    let after = try sbd.now()
    let until = try #require(try sbd.snoozedUntil(s.id))
    #expect((before + 30 * SnoozeTests.minuteMs...after + 30 * SnoozeTests.minuteMs).contains(until))
    #expect(try sbd.count("snooze", of: s.id) == 2)
  }

  /// The snooze holds the item if the session reaches the Inbox before it ends.
  @Test func snoozingAWorkingSessionIsAllowed() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 60", name: "busy")
    try sbd.waitFor(s.id, "the slow tool call") { $0.state == .working }

    try snooze(sbd, s.id)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "working")
    #expect(row["snoozedUntil"]?.int != nil)
  }

  @Test func snoozeRequestReturnsTheSnoozedSummary() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let got = try sbd.client.call("snooze", ["session": .string(s.id)])

    #expect(got["id"]?.string == s.id)
    #expect(got["state"]?.string == "waiting")
    #expect(got["snoozedUntil"]?.int != nil)
  }

  @Test func snoozeJSONPrintsTheSummary() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let got = try #require(JSON.parse(try sbd.sb("snooze", "--json", s.id)))

    #expect(got["id"]?.string == s.id)
    #expect(got["state"]?.string == "waiting")
    #expect(got["snoozedUntil"]?.int.map(Int64.init) == (try sbd.snoozedUntil(s.id)))
  }

  @Test func lsAndGetMarkTheReasonSnoozed() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try snooze(sbd, s.id)

    let until = try #require(try sbd.snoozedUntil(s.id))
    let marked = "\(s.reason) (snoozed until \(Wait.formatTime(until)))"
    #expect(try sbd.sb("ls").contains(marked))
    #expect(try sbd.sb("get", s.id).contains(marked))
  }

  @Test func getPrintsTheSnoozedLine() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try snooze(sbd, s.id)

    let until = try #require(try sbd.snoozedUntil(s.id))
    #expect(try sbd.sb("get", s.id).contains("  snoozed: until \(Wait.formatTime(until))"))
  }

  @Test func lsDoesNotMarkAnUnsnoozedReason() throws {
    let sbd = try Instance()
    _ = try needsYouSession(sbd)

    #expect(try !sbd.sb("ls").contains("(snoozed"))
  }

  @Test func acknowledgedAndSnoozedReasonShowsTheSnoozeAfterTheAcknowledgment() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("ack", s.id)

    try snooze(sbd, s.id)

    let until = try #require(try sbd.snoozedUntil(s.id))
    #expect(try sbd.sb("ls").contains("\(s.reason) (acknowledged) (snoozed until \(Wait.formatTime(until)))"))
  }

  // Bad times

  @Test func bothFlagsAreRefusedBySb() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["snooze", s.id, "--until", "2h", "--for", "30m"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("--until and --for don't go together"))
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  @Test func snoozeRequestWithBothTimesIsRefusedBySbd() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    #expect(throws: APIError.self) {
      try sbd.client.call("snooze", ["session": .string(s.id), "until": "2h", "for": "30m"])
    }
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  @Test(arguments: ["2020-01-01 00:00", "0s"])
  func timeAtOrBeforeNowIsRefused(_ text: String) throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["snooze", s.id, "--until", text])

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(text) has passed"))
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  @Test func unreadableTimeIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["snooze", s.id, "--until", "soonish"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("can't read the time soonish"))
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  /// `--for` takes only a duration, so a date that `--until` would read is refused.
  @Test func forWithADateIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["snooze", s.id, "--for", "2090-03-12"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("2090-03-12"))
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  /// The event's JSON number can't hold an end past 2^53 ms exactly.
  @Test func endPastWhatTheEventCanHoldIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["snooze", s.id, "--for", "9007199254741s"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("9007199254741s is too far away"))
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  @Test func forOfZeroIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["snooze", s.id, "--for", "0m"])

    #expect(r.status != 0)
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  // Ending by time

  @Test func snoozeHoldsUntilAMinuteBeforeItsEnd() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try sbd.advanceClock(until - (try sbd.now()) - SnoozeTests.minuteMs)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["snoozedUntil"]?.int.map(Int64.init) == until)
  }

  @Test func snoozeThatEndsBringsTheSameItemBack() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    let ref = try #require(try sbd.listed(s.id)["triage"]?["ref"]?.string)
    try snooze(sbd, s.id)

    try sbd.advanceClock(61 * SnoozeTests.minuteMs)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == s.reason)
    #expect(row["triage"]?["ref"]?.string == ref)
  }

  @Test func snoozeThatEndsNotesItsEndAndDropsItsEnd() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try sbd.advanceClock(61 * SnoozeTests.minuteMs)

    let row = try sbd.listed(s.id)
    #expect(row["snoozeNote"]?.string == note(until))
    #expect(row["snoozedUntil"] == nil)
  }

  @Test func snoozeOfAPausedSessionEndsOnTimeAndLeavesThePause() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    try sbd.sb("pause", s.id)
    try sbd.waitForPausedExit(s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try sbd.advanceClock(until - (try sbd.now()) - SnoozeTests.minuteMs)
    #expect(try sbd.snoozedUntil(s.id) == until)

    try sbd.advanceClock(2 * SnoozeTests.minuteMs)

    #expect(try sbd.snoozedUntil(s.id) == nil)
    #expect(try sbd.pauseField(s.id) != nil)
    #expect(try sbd.listed(s.id)["state"]?.string == "waiting")
    let refusal = try sbd.run(["unsnooze", s.id])
    #expect(refusal.status != 0)
    #expect(refusal.stderr.contains("isn't snoozed"))
  }

  @Test func snoozeThatEndsReturnsTheSessionToTriage() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)

    try sbd.advanceClock(61 * SnoozeTests.minuteMs)

    #expect(try sbd.triage().map(\.id).contains(s.id))
  }

  @Test func lsAndGetShowTheNoteAfterTheReasonOnceTheSnoozeEnds() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try sbd.advanceClock(61 * SnoozeTests.minuteMs)

    let marked = "\(s.reason) (\(note(until)))"
    #expect(try sbd.sb("ls").contains(marked))
    #expect(try sbd.sb("get", s.id).contains(marked))
    #expect(try !sbd.sb("get", s.id).contains("  snoozed: until"))
  }

  @Test func messageFromTheUserAfterTheSnoozeEndsClearsTheNote() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    try sbd.advanceClock(61 * SnoozeTests.minuteMs)
    try #require(try sbd.listed(s.id)["snoozeNote"] != nil)

    try sbd.sb("send", s.id, "again")

    try sbd.waitFor(s.id, "the second reply", timeout: 30) { $0.lastReply == "Done: again" && $0.state != .working }
    #expect(try sbd.listed(s.id)["snoozeNote"] == nil)
  }

  // Unsnoozing

  @Test func unsnoozeBringsTheSessionBackAtOnce() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)

    try sbd.sb("unsnooze", s.id)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == s.reason)
    #expect(row["snoozeNote"] == nil)
    #expect(row["snoozedUntil"] == nil)
    #expect(try sbd.count("unsnooze", of: s.id) == 1)
  }

  @Test func unsnoozeJSONPrintsTheSummary() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)

    let got = try #require(JSON.parse(try sbd.sb("unsnooze", "--json", s.id)))

    #expect(got["id"]?.string == s.id)
    #expect(got["state"]?.string == "needs_you")
    #expect(got["snoozedUntil"] == nil)
  }

  @Test func unsnoozeOfASessionThatIsntSnoozedIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "idle")

    let r = try sbd.run(["unsnooze", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("idle isn't snoozed"))
    #expect(try sbd.count("unsnooze", of: s.id) == 0)
  }

  @Test func unsnoozeOfASnoozeThatEndedIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "idle")
    try snooze(sbd, s.id)
    try sbd.advanceClock(61 * SnoozeTests.minuteMs)

    let r = try sbd.run(["unsnooze", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("idle isn't snoozed"))
    #expect(try sbd.count("unsnooze", of: s.id) == 0)
  }

  @Test func ackThenSnoozeThenUnsnoozeLeavesTheSessionAcknowledged() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("ack", s.id)
    try snooze(sbd, s.id)

    try sbd.sb("unsnooze", s.id)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["acknowledged"]?.bool == true)
    #expect(row["snoozedUntil"] == nil)
  }

  // Early wake

  @Test func permissionPromptWakesTheSnooze() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try sbd.sb("send", s.id, "perm touch x")

    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == "approve `touch x`")
    #expect(row["snoozeNote"]?.string == note(until, wokeEarly: "a new prompt"))
    #expect(row["snoozedUntil"] == nil)
  }

  @Test func answeringTheWokenPromptClearsTheNote() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    try sbd.sb("send", s.id, "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }

    try sbd.sb("allow", s.id)

    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch x" && $0.state != .working }
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["snoozeNote"] == nil)
    #expect(row["snoozedUntil"] == nil)
  }

  @Test func ciFailureWakesTheSnooze() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    github.checks(MergeTests.number, "FAILURE")
    try sbd.poll(all: true)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["snoozeNote"]?.string == note(until, wokeEarly: "CI failed"))
    #expect(row["snoozedUntil"] == nil)
  }

  @Test func ciThatWasFailingAtSnoozeTimeDoesNotWakeTheSnooze() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    github.checks(MergeTests.number, "FAILURE")
    try sbd.poll(all: true)
    try #require(try sbd.listed(s.id)["state"]?.string == "needs_you")
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))
    let prEvents = try sbd.count("pr", of: s.id)

    github.change(MergeTests.number) { $0["title"] = "a new title" }
    try sbd.poll(all: true)

    try #require(try sbd.count("pr", of: s.id) > prEvents, "the poller recorded no pr event for the new title")
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["snoozedUntil"]?.int.map(Int64.init) == until)
  }

  @Test func ciThatPassesAndThenFailsAgainWakesTheSnooze() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    github.checks(MergeTests.number, "FAILURE")
    try sbd.poll(all: true)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    github.checks(MergeTests.number, "SUCCESS")
    try sbd.poll(all: true)
    try #require(try sbd.listed(s.id)["state"]?.string == "waiting")
    github.checks(MergeTests.number, "FAILURE")
    try sbd.poll(all: true)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["snoozeNote"]?.string == note(until, wokeEarly: "CI failed"))
  }

  /// A merged PR whose folder has uncommitted changes needs you, so the woken item shows its note.
  @Test func mergeWakesTheSnooze() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))
    try "x".write(toFile: "\(s.cwd)/notes.txt", atomically: true, encoding: .utf8)

    github.change(MergeTests.number) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == "#18303 merged; commit or discard the uncommitted changes")
    #expect(row["snoozeNote"]?.string == note(until, wokeEarly: "the PR merged"))
    #expect(row["snoozedUntil"] == nil)
  }

  /// A merged PR with a clean folder is Done, which is not an Inbox state, so it carries no note.
  @Test func mergeWithACleanFolderEndsTheSnoozeWithoutANote() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try snooze(sbd, s.id)

    github.change(MergeTests.number) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "done")
    #expect(row["snoozedUntil"] == nil)
    #expect(row["snoozeNote"] == nil)
  }

  @Test func plainReplyDoesNotWakeTheSnooze() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try sbd.sb("send", s.id, "again")

    try sbd.waitFor(s.id, "the second reply") { $0.lastReply == "Done: again" && $0.state != .working }
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["triage"] == nil)
    #expect(row["snoozedUntil"]?.int.map(Int64.init) == until)
  }

  @Test func replyThatAsksAQuestionDoesNotWakeTheSnooze() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try sbd.sb("send", s.id, "ask which database")

    try sbd.waitFor(s.id, "the question") {
      $0.lastReply == "Which database should I use, Postgres or SQLite?" && $0.state != .working
    }
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["triage"] == nil)
    #expect(row["snoozedUntil"]?.int.map(Int64.init) == until)
    let inputPath = "\(sbd.home.path)/summary-input.txt"
    var input = ""
    try sbd.waitFor("the summary call of the question") {
      input = (try? String(contentsOfFile: inputPath, encoding: .utf8)) ?? ""
      return input.contains("Which database should I use")
    }
    #expect(input.contains("State: Needs you"))
  }

  // A working session

  /// A session whose `slow held` turn runs, snoozed with `flags` during that turn.
  func snoozedWorkingSession(_ sbd: Instance, _ flags: String...) throws -> SessionSummary {
    let s = try sbd.new(prompt: "slow held", name: "busy")
    // The session reads Working before its turn starts. A clock jump between SessionStart and UserPromptSubmit
    // would let the idle stop end claude.
    try ScheduleFireTests().waitForPrompt(sbd, s.id, "slow held")
    try sbd.sb(["snooze", s.id] + flags)
    return s
  }

  func finish(_ sbd: Instance, _ s: SessionSummary) throws {
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply", timeout: 30) { $0.lastReply == "Slept held s." && $0.state != .working }
  }

  @Test func workingSessionSnoozedMidTurnFinishesItsTurn() throws {
    let sbd = try Instance()
    let s = try snoozedWorkingSession(sbd)
    let sent = try sbd.count("sent", of: s.id)
    let input = sbd.stubInput().count

    try finish(sbd, s)

    #expect(try sbd.count("sent", of: s.id) == sent)
    #expect(sbd.stubInput().count == input)
  }

  @Test func workingSessionSnoozedMidTurnHoldsItsNeedsYou() throws {
    let sbd = try Instance()
    let s = try snoozedWorkingSession(sbd)
    let until = try #require(try sbd.snoozedUntil(s.id))

    try finish(sbd, s)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["triage"] == nil)
    #expect(row["snoozedUntil"]?.int.map(Int64.init) == until)
  }

  @Test func heldNeedsYouComesBackWhenTheSnoozeEnds() throws {
    let sbd = try Instance()
    let s = try snoozedWorkingSession(sbd)
    let until = try #require(try sbd.snoozedUntil(s.id))
    try finish(sbd, s)

    try sbd.advanceClock(61 * SnoozeTests.minuteMs)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["snoozeNote"]?.string == note(until))
  }

  /// The user hasn't acted on the item that the turn ends with, so the note stays.
  @Test func snoozeThatEndsMidTurnShowsItsNoteOnTheReply() throws {
    let sbd = try Instance()
    let s = try snoozedWorkingSession(sbd, "--for", "30m")
    let until = try #require(try sbd.snoozedUntil(s.id))
    try sbd.advanceClock(31 * SnoozeTests.minuteMs)

    try finish(sbd, s)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["snoozeNote"]?.string == note(until))
  }

  // Restart

  @Test func snoozeSurvivesAnSbdRestart() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))

    sbd.stopSbd()
    try sbd.startSbd()

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["snoozedUntil"]?.int.map(Int64.init) == until)
  }

  /// The poller wakes it, so no hook connection breaks across the restart.
  @Test func earlyWakeSurvivesAnSbdRestart() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try snooze(sbd, s.id)
    let until = try #require(try sbd.snoozedUntil(s.id))
    github.checks(MergeTests.number, "FAILURE")
    try sbd.poll(all: true)
    try #require(try sbd.listed(s.id)["snoozeNote"] != nil)

    sbd.stopSbd()
    try sbd.startSbd()

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["snoozeNote"]?.string == note(until, wokeEarly: "CI failed"))
    #expect(row["snoozedUntil"] == nil)
  }

  // Every list agrees (Risk 2)

  func expectListsAgree(_ sbd: Instance, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let row = try sbd.listed(id)
    let got = try sbd.getJSON(id)
    for key in SnoozeTests.reasonKeys {
      #expect(
        row[key] == got[key], "\(key): ls \(row[key]?.text ?? "nil"), get \(got[key]?.text ?? "nil")",
        sourceLocation: sourceLocation)
    }
    #expect((row["triage"] == nil) == (got["triage"] == nil), sourceLocation: sourceLocation)
    let triaged = try sbd.triageJSON().first { $0["id"]?.string == id }
    #expect((triaged == nil) == (row["triage"] == nil), sourceLocation: sourceLocation)
    if let triaged {
      for key in SnoozeTests.reasonKeys {
        #expect(triaged[key] == row[key], "\(key) in triage", sourceLocation: sourceLocation)
      }
    }
  }

  @Test func lsGetAndTriageAgreeWhileSnoozedAndAfterTheSnoozeEnds() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)
    try #require(try sbd.listed(s.id)["snoozedUntil"] != nil)
    try expectListsAgree(sbd, s.id)
    #expect(try sbd.triageJSON().allSatisfy { $0["id"]?.string != s.id })

    try sbd.advanceClock(61 * SnoozeTests.minuteMs)

    try #require(try sbd.listed(s.id)["snoozeNote"] != nil)
    try expectListsAgree(sbd, s.id)
    #expect(try sbd.triageJSON().contains { $0["id"]?.string == s.id })
  }

  // Refusals

  /// The caller and the target can each name the session by its id, its name, or a prefix of its id.
  @Test(arguments: [("id", "id"), ("name", "id"), ("prefix", "id"), ("id", "name"), ("id", "prefix")])
  func sessionCantSnoozeItself(_ target: String, _ caller: String) throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "worker")
    func ref(_ form: String) -> String {
      switch form {
      case "name": s.name
      case "prefix": String(s.id.prefix(s.id.count - 1))
      default: s.id
      }
    }

    let r = try sbd.run(["snooze", ref(target)], env: ["CLAUDECODE": "1", "SB_SESSION_ID": ref(caller)])

    #expect(r.status != 0)
    #expect(r.stderr.contains("can't snooze itself"))
    #expect(try sbd.get(s.id).state == .needsYou)
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  @Test func snoozeRequestWithTheTargetAsCallerIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    #expect(throws: APIError.self) {
      try sbd.client.call("snooze", ["session": .string(s.id), "caller": .string(s.id)])
    }
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  @Test func unsnoozeByTheSessionItselfIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try snooze(sbd, s.id)

    let r = try sbd.run(["unsnooze", s.id], env: ["CLAUDECODE": "1", "SB_SESSION_ID": s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("can't unsnooze itself"))
    #expect(try sbd.count("unsnooze", of: s.id) == 0)
    #expect(try sbd.listed(s.id)["snoozedUntil"] != nil)
  }

  @Test func managerConversationCantBeSnoozed() throws {
    let sbd = try Instance()
    let conversation = try #require(JSON.parse(try sbd.sb("manager", "new", "--json"))?["id"]?.string)

    let r = try sbd.run(["snooze", conversation])

    #expect(r.status != 0)
    #expect(r.stderr.contains("only a work session can be snoozed"))
    #expect(try sbd.count("snooze", of: conversation) == 0)
  }

  @Test func sessionMarkedDoneCantBeSnoozed() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "finished")
    try sbd.sb("done", s.id)

    let r = try sbd.run(["snooze", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("finished is marked done"))
    #expect(try sbd.count("snooze", of: s.id) == 0)
  }

  /// The Manager runs inside Claude Code with its own SB_SESSION_ID.
  @Test func managerCanSnoozeAnotherSession() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "worker")
    let conversation = try #require(JSON.parse(try sbd.sb("manager", "new", "--json"))?["id"]?.string)

    try sbd.sb(["snooze", s.id], env: ["CLAUDECODE": "1", "SB_SESSION_ID": conversation])

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["snoozedUntil"]?.int != nil)
  }
}
