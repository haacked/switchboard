import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct LaunchTriggerTests {
  @Test func autoContinueUsesAHyphenatedRawValue() {
    #expect(LaunchTrigger(rawValue: "auto-continue") == .autoContinue)
  }

  @Test func aResumeSetsTheResumeTriggerAndAFreshStartClearsIt() {
    var f = SessionFacts()
    f.apply(Event(session: "s1", t: 1, kind: "resumed", data: ["trigger": "open"]))
    #expect(f.lastResumeTrigger == .open)

    f.apply(Event(session: "s1", t: 2, kind: "started", data: ["trigger": "create"]))
    #expect(f.lastResumeTrigger == nil)
  }
}

@Suite struct ActivityStoreTests {
  func withStore(_ body: (Store) throws -> Void) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try body(try Store(path: "\(dir)/sb.db"))
  }

  @Test func appendAssignsIncreasingIds() throws {
    try withStore { store in
      let first = try store.append(activity: ActivityEvent(t: 1, kind: "a"))
      let second = try store.append(activity: ActivityEvent(t: 2, kind: "b"))

      let firstId = try #require(first.id)
      let secondId = try #require(second.id)
      #expect(secondId > firstId)
    }
  }

  @Test func appendedEventsRoundTripWithAndWithoutASession() throws {
    try withStore { store in
      let a = try store.append(
        activity: ActivityEvent(t: 10, kind: "resume.ready", session: "s1", data: ["trigger": "open", "ms": 3500]))
      let b = try store.append(
        activity: ActivityEvent(
          t: 11, kind: "usage", data: ["nested": ["list": [1, "two", true]], "quote": "a \"b\""]))

      #expect(try store.activity() == [a, b])
    }
  }

  /// Events come back in the order they were appended, even when a later append has an earlier time.
  @Test func activityListsEventsInAppendOrder() throws {
    try withStore { store in
      try store.append(activity: ActivityEvent(t: 50, kind: "first"))
      try store.append(activity: ActivityEvent(t: 20, kind: "second"))

      #expect(try store.activity().map(\.kind) == ["first", "second"])
    }
  }

  @Test func activitySinceIncludesAnEventAtExactlyThatTime() throws {
    try withStore { store in
      try store.append(activity: ActivityEvent(t: 99, kind: "before"))
      try store.append(activity: ActivityEvent(t: 100, kind: "at"))
      try store.append(activity: ActivityEvent(t: 101, kind: "after"))

      #expect(try store.activity(since: 100).map(\.kind) == ["at", "after"])
    }
  }

  @Test func pruneKeepsAnEventAtExactlyTheCutoff() throws {
    try withStore { store in
      try store.append(activity: ActivityEvent(t: 99, kind: "before"))
      try store.append(activity: ActivityEvent(t: 100, kind: "at"))
      try store.append(activity: ActivityEvent(t: 101, kind: "after"))

      try store.pruneActivity(before: 100)

      #expect(try store.activity().map(\.kind) == ["at", "after"])
    }
  }

  @Test func clearRemovesEveryEvent() throws {
    try withStore { store in
      try store.append(activity: ActivityEvent(t: 1, kind: "a", session: "s1"))
      try store.append(activity: ActivityEvent(t: 2, kind: "b"))

      try store.clearActivity()

      #expect(try store.activity().isEmpty)
    }
  }

  @Test func summaryOfAnEmptyLogHasNoOldest() throws {
    try withStore { store in
      let summary = try store.activitySummary()
      #expect(summary.count == 0)
      #expect(summary.oldest == nil)
    }
  }

  @Test func summaryCountsTheRowsAndFindsTheOldest() throws {
    try withStore { store in
      try store.append(activity: ActivityEvent(t: 40, kind: "a"))
      try store.append(activity: ActivityEvent(t: 7, kind: "b"))
      try store.append(activity: ActivityEvent(t: 90, kind: "c"))

      let summary = try store.activitySummary()
      #expect(summary.count == 3)
      #expect(summary.oldest == 7)
    }
  }

  @Test func deletingASessionKeepsItsActivity() throws {
    try withStore { store in
      try store.save(Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5))
      let event = try store.append(
        activity: ActivityEvent(t: 10, kind: "resume.ready", session: "s1", data: ["trigger": "open", "ms": 3500]))

      try store.delete(session: "s1", name: "one")

      #expect(try store.sessions().isEmpty)
      #expect(try store.activity() == [event])
    }
  }
}

@Suite struct ActivityReportTests {
  func ready(_ trigger: String, _ ms: Int) -> ActivityEvent {
    ActivityEvent(
      t: 1, kind: "resume.ready", session: "s1", data: ["trigger": .string(trigger), "ms": .number(Double(ms))])
  }

  @Test func emptyInputHasNoEventsAndNoResumes() {
    let report = ActivityReport.build([], enabled: false, since: 1234)

    #expect(report == ActivityReport(enabled: false, since: 1234, events: 0, resumes: []))
  }

  /// Ten values 1000…10000: the median is at index ceil(5) - 1 = 4 and p90 at ceil(9) - 1 = 8.
  @Test func percentilesUseNearestRankOnTenValues() throws {
    let events = stride(from: 10_000, through: 1000, by: -1000).map { ready("open", $0) }

    let row = try #require(ActivityReport.build(events, enabled: true, since: nil).resumes.first)

    #expect(
      row == ResumeTiming(trigger: "open", userCaused: true, count: 10, medianMs: 5000, p90Ms: 9000, maxMs: 10_000))
  }

  /// Four values: nearest rank picks 200 for the median, where interpolation would give 250.
  @Test func percentilesPickAStoredValueRatherThanInterpolating() throws {
    let events = [400, 100, 300, 200].map { ready("send", $0) }

    let row = try #require(ActivityReport.build(events, enabled: true, since: nil).resumes.first)

    #expect(row.medianMs == 200)
    #expect(row.p90Ms == 400)
    #expect(row.maxMs == 400)
  }

  @Test func aSingleValueIsTheMedianP90AndMax() throws {
    let row = try #require(ActivityReport.build([ready("wait", 4200)], enabled: true, since: nil).resumes.first)

    #expect(row.count == 1)
    #expect(row.medianMs == 4200)
    #expect(row.p90Ms == 4200)
    #expect(row.maxMs == 4200)
  }

  @Test func resumesGroupByTriggerSortedByCountThenName() {
    let events = [
      ready("wait", 1), ready("open", 1), ready("wait", 1), ready("send", 1),
      ready("wait", 1), ready("chat", 1), ready("open", 1),
    ]

    let report = ActivityReport.build(events, enabled: true, since: nil)

    #expect(report.resumes.map(\.trigger) == ["wait", "open", "chat", "send"])
    #expect(report.resumes.map(\.count) == [3, 2, 1, 1])
  }

  @Test func userCausedComesFromTheLaunchTrigger() {
    let events = [ready("open", 1), ready("notice", 1), ready("auto-continue", 1)]

    let report = ActivityReport.build(events, enabled: true, since: nil)

    #expect(
      Dictionary(uniqueKeysWithValues: report.resumes.map { ($0.trigger, $0.userCaused) })
        == ["open": true, "notice": false, "auto-continue": false])
  }

  @Test func anUnknownTriggerGetsItsOwnRowAndIsNotUserCaused() {
    let report = ActivityReport.build([ready("teleport", 800)], enabled: true, since: nil)

    #expect(
      report.resumes == [
        ResumeTiming(trigger: "teleport", userCaused: false, count: 1, medianMs: 800, p90Ms: 800, maxMs: 800)
      ])
  }

  @Test(arguments: [
    ["trigger": "open"] as JSON,
    ["ms": 3500],
    ["trigger": "open", "ms": "3500"],
    ["trigger": 7, "ms": 3500],
    ["trigger": .null, "ms": 3500],
    ["trigger": "open", "ms": .null],
    [:],
  ])
  func aMalformedResumeIsSkippedButCounted(data: JSON) {
    let events = [ActivityEvent(t: 1, kind: "resume.ready", data: data), ready("open", 1000)]

    let report = ActivityReport.build(events, enabled: true, since: nil)

    #expect(report.events == 2)
    #expect(
      report.resumes == [
        ResumeTiming(trigger: "open", userCaused: true, count: 1, medianMs: 1000, p90Ms: 1000, maxMs: 1000)
      ])
  }

  @Test func otherKindsCountAsEventsButNotResumes() {
    let events = [
      ActivityEvent(t: 1, kind: "resume.start", data: ["trigger": "open", "ms": 3500]),
      ActivityEvent(t: 2, kind: "usage"),
      ready("open", 2000),
    ]

    let report = ActivityReport.build(events, enabled: true, since: nil)

    #expect(report.events == 3)
    #expect(report.resumes.map(\.count) == [1])
  }
}
