import Foundation
import Testing

@testable import SwitchboardCore

private func nav(_ t: Int64, _ to: String, via: String = "list") -> ActivityEvent {
  ActivityEvent(t: t, kind: "nav", data: ["to": .string(to), "via": .string(via)])
}

private func app(_ t: Int64, _ event: String) -> ActivityEvent {
  ActivityEvent(t: t, kind: "app", data: ["event": .string(event)])
}

private func ready(_ ms: Int, wasLive: Bool, left: Bool) -> ActivityEvent {
  ActivityEvent(
    t: 1, kind: "terminal.ready", data: ["ms": .number(Double(ms)), "wasLive": .bool(wasLive), "left": .bool(left)])
}

private func command(_ name: String, via: String?) -> ActivityEvent {
  var data: [String: JSON] = ["name": .string(name)]
  if let via { data["via"] = .string(via) }
  return ActivityEvent(t: 1, kind: "command", data: .object(data))
}

private func send(_ t: Int64, _ hash: String?, session: String? = "s1") -> ActivityEvent {
  var data: [String: JSON] = [:]
  if let hash { data["textHash"] = .string(hash) }
  return ActivityEvent(t: t, kind: "send", session: session, data: .object(data))
}

private func build(_ events: [ActivityEvent]) -> ActivityReport {
  ActivityReport.build(events, enabled: true, since: nil)
}

@Suite struct ActivityReportSectionsTests {
  // MARK: Places

  @Test func eachVisitEndsAtTheNextNavOrAQuit() {
    let report = build([nav(0, "session"), nav(1000, "inbox"), app(3000, "quit")])

    #expect(
      report.places == [
        PlaceTime(place: "inbox", visits: 1, ms: 2000), PlaceTime(place: "session", visits: 1, ms: 1000),
      ])
  }

  @Test func aDeactivatePausesTheClockAndAnActivateRestartsIt() {
    let report = build([
      nav(0, "session"), app(1000, "deactivate"), app(10_000, "activate"), nav(12_000, "board"),
      app(16_000, "deactivate"),
    ])

    #expect(
      report.places == [
        PlaceTime(place: "board", visits: 1, ms: 4000), PlaceTime(place: "session", visits: 1, ms: 3000),
      ])
  }

  /// The app records its first place after a launch, so the time before that place settles goes nowhere.
  @Test func aLaunchEndsTheVisitBeforeTheQuit() {
    let report = build([
      nav(0, "session"), app(500, "quit"), app(60_000, "launch"), app(61_000, "deactivate"), nav(62_000, "inbox"),
      app(63_000, "quit"),
    ])

    #expect(
      report.places == [
        PlaceTime(place: "inbox", visits: 1, ms: 1000), PlaceTime(place: "session", visits: 1, ms: 500),
      ])
  }

  @Test func anOptionClickIsNotAMessageTheUserWrote() {
    var option = send(0, "h1")
    option.data = ["textHash": "h1", "via": "option"]
    let report = build([option, option, send(5, "h2")])

    #expect(report.sends == 1)
    #expect(report.repeatedSends.isEmpty)
  }

  @Test func aVisitLongerThanTheCapCountsTheCap() {
    let report = build([
      nav(0, "session"), nav(ActivityReport.visitCapMs + 5000, "inbox"), app(ActivityReport.visitCapMs + 6000, "quit"),
    ])

    #expect(
      report.places == [
        PlaceTime(place: "session", visits: 1, ms: ActivityReport.visitCapMs),
        PlaceTime(place: "inbox", visits: 1, ms: 1000),
      ])
  }

  @Test func aVisitOfExactlyTheCapCountsInFull() {
    let report = build([nav(0, "session"), app(ActivityReport.visitCapMs, "deactivate")])

    #expect(report.places == [PlaceTime(place: "session", visits: 1, ms: ActivityReport.visitCapMs)])
  }

  @Test func aSecondDeactivateAddsNoTime() {
    let report = build([nav(0, "chat"), app(1000, "deactivate"), app(5000, "deactivate"), app(9000, "quit")])

    #expect(report.places == [PlaceTime(place: "chat", visits: 1, ms: 1000)])
  }

  @Test func aNavWhileInTheBackgroundStartsTheClock() {
    let report = build([nav(0, "inbox"), app(1000, "deactivate"), nav(5000, "session"), nav(7000, "board")])

    #expect(report.places.first { $0.place == "session" }?.ms == 2000)
    #expect(report.places.first { $0.place == "inbox" }?.ms == 1000)
  }

  @Test func repeatVisitsAddUp() {
    let report = build([nav(0, "session"), nav(1000, "inbox"), nav(1500, "session"), nav(2500, "board")])

    #expect(report.places.first { $0.place == "session" } == PlaceTime(place: "session", visits: 2, ms: 2000))
  }

  @Test func aVisitWithNothingAfterItCountsAVisitButNoTime() {
    let report = build([nav(0, "session"), nav(1000, "inbox")])

    #expect(report.places.first { $0.place == "inbox" } == PlaceTime(place: "inbox", visits: 1, ms: 0))
  }

  @Test func placesAreTimedInTimeOrderWhateverTheInputOrder() {
    let ordered = [
      nav(0, "session"), app(1000, "deactivate"), app(4000, "activate"), nav(6000, "board"), app(7000, "quit"),
    ]

    #expect(build(ordered.reversed()).places == build(ordered).places)
  }

  @Test func aNavWithoutADestinationIsSkipped() {
    let events = [
      nav(0, "session"), ActivityEvent(t: 500, kind: "nav", data: ["via": "list"]), nav(1000, "inbox"),
      app(1500, "quit"),
    ]

    #expect(
      build(events).places == [
        PlaceTime(place: "session", visits: 1, ms: 1000), PlaceTime(place: "inbox", visits: 1, ms: 500),
      ])
  }

  @Test func appEventsBeforeAnyNavRecordNoPlace() {
    #expect(build([app(0, "launch"), app(1000, "activate"), app(2000, "deactivate")]).places.isEmpty)
  }

  @Test func placesWithEqualTimeSortByName() {
    let report = build([nav(0, "session"), nav(1000, "board"), nav(2000, "inbox"), app(2500, "quit")])

    #expect(report.places.map(\.place) == ["board", "session", "inbox"])
  }

  // MARK: Navigation

  @Test func navigationCountsNavsByViaMostFirstThenByName() {
    let report = build([
      nav(1, "session", via: "list"), nav(2, "inbox", via: "command"), nav(3, "session", via: "list"),
      nav(4, "board", via: "back"), nav(5, "session", via: "list"), nav(6, "board", via: "command"),
    ])

    #expect(
      report.navigation == [
        ActivityCount(name: "list", count: 3), ActivityCount(name: "command", count: 2),
        ActivityCount(name: "back", count: 1),
      ])
  }

  @Test func aNavWithoutAViaIsNotCounted() {
    let report = build([ActivityEvent(t: 1, kind: "nav", data: ["to": "inbox"]), nav(2, "board", via: "search")])

    #expect(report.navigation == [ActivityCount(name: "search", count: 1)])
  }

  // MARK: Terminal ready

  @Test func terminalReadyGroupsLiveStoppedAndLeft() {
    let report = build([
      ready(100, wasLive: true, left: false), ready(300, wasLive: true, left: false),
      ready(2000, wasLive: false, left: false), ready(900, wasLive: false, left: true),
      ready(400, wasLive: true, left: true), ready(200, wasLive: true, left: false),
    ])

    #expect(
      report.terminalReady == [
        ActivityTiming(name: "live", count: 3, medianMs: 200, p90Ms: 300, maxMs: 300),
        ActivityTiming(name: "left before ready", count: 2, medianMs: 400, p90Ms: 900, maxMs: 900),
        ActivityTiming(name: "stopped", count: 1, medianMs: 2000, p90Ms: 2000, maxMs: 2000),
      ])
  }

  @Test func aTerminalReadyWithoutANumericMsIsSkipped() {
    let events = [
      ActivityEvent(t: 1, kind: "terminal.ready", data: ["wasLive": true, "left": false]),
      ActivityEvent(t: 2, kind: "terminal.ready", data: ["ms": "100", "wasLive": true, "left": false]),
    ]

    #expect(build(events).terminalReady.isEmpty)
  }

  @Test func aTerminalReadyWithoutFlagsCountsAsStopped() {
    let report = build([ActivityEvent(t: 1, kind: "terminal.ready", data: ["ms": 700])])

    #expect(report.terminalReady.map(\.name) == ["stopped"])
  }

  // MARK: Commands

  @Test func commandsCountEachNameByItsVias() {
    let report = build([
      command("back", via: "key"), command("nextNeedingYou", via: "click"), command("back", via: "mouse-button"),
      command("back", via: "key"),
    ])

    #expect(
      report.commands == [
        CommandUse(name: "back", count: 3, vias: ["key": 2, "mouse-button": 1]),
        CommandUse(name: "nextNeedingYou", count: 1, vias: ["click": 1]),
      ])
  }

  @Test func aCommandWithoutAViaCountsAsOther() {
    #expect(build([command("stop", via: nil)]).commands == [CommandUse(name: "stop", count: 1, vias: ["other": 1])])
  }

  @Test func aCommandWithoutANameIsSkipped() {
    #expect(build([ActivityEvent(t: 1, kind: "command", data: ["via": "key"])]).commands.isEmpty)
  }

  @Test func commandsWithEqualCountsSortByName() {
    let report = build([command("stop", via: "key"), command("acknowledge", via: "key")])

    #expect(report.commands.map(\.name) == ["acknowledge", "stop"])
  }

  // MARK: Sends

  @Test func sendsCountEverySendEvent() {
    #expect(build([send(1, "h1"), send(2, nil), send(3, "h2")]).sends == 3)
  }

  @Test func aSendWithoutAHashJoinsNoGroup() {
    #expect(build([send(1, nil), send(2, nil)]).repeatedSends.isEmpty)
  }

  @Test func aTextSentOnceIsNotRepeated() {
    #expect(build([send(1, "h1"), send(2, "h2")]).repeatedSends.isEmpty)
  }

  @Test func repeatedSendsCountDistinctSessionsAndTheSmallestGap() {
    let report = build([
      send(10_000, "h1", session: "a"), send(1000, "h1", session: "b"), send(4000, "h1", session: "a"),
    ])

    #expect(report.repeatedSends == [RepeatedSend(count: 3, sessions: 2, minGapMs: 3000)])
  }

  @Test func repeatedSendsWithoutSessionsCountNoSessions() {
    let report = build([send(1000, "h1", session: nil), send(1500, "h1", session: nil)])

    #expect(report.repeatedSends == [RepeatedSend(count: 2, sessions: 0, minGapMs: 500)])
  }

  @Test func repeatedSendsSortByCountThenBySmallestGap() {
    let report = build([
      send(0, "slow"), send(9000, "slow"),
      send(0, "fast"), send(100, "fast"),
      send(0, "many"), send(5000, "many"), send(10_000, "many"),
    ])

    #expect(
      report.repeatedSends == [
        RepeatedSend(count: 3, sessions: 1, minGapMs: 5000), RepeatedSend(count: 2, sessions: 1, minGapMs: 100),
        RepeatedSend(count: 2, sessions: 1, minGapMs: 9000),
      ])
  }

  // MARK: Errors

  @Test func errorsCountEachWhereAndCode() {
    let events = [
      ActivityEvent(t: 1, kind: "error", data: ["where": "open", "code": "APIError"]),
      ActivityEvent(t: 2, kind: "error", data: ["where": "send", "code": "APIError", "retry": 1]),
      ActivityEvent(t: 3, kind: "error", data: ["where": "open", "code": "APIError"]),
    ]

    #expect(
      build(events).errors == [
        ActivityCount(name: "open APIError", count: 2), ActivityCount(name: "send APIError", count: 1),
      ])
  }

  @Test func anErrorWithoutACodeShowsAQuestionMark() {
    let report = build([ActivityEvent(t: 1, kind: "error", data: ["where": "terminals"])])

    #expect(report.errors == [ActivityCount(name: "terminals ?", count: 1)])
  }

  @Test func anErrorWithoutAWhereIsSkipped() {
    #expect(build([ActivityEvent(t: 1, kind: "error", data: ["code": "APIError"])]).errors.isEmpty)
  }

  // MARK: Window sizes

  @Test func windowSizesCountEachWidthByHeight() {
    let events = [
      ActivityEvent(t: 1, kind: "window", data: ["width": 1440, "height": 900, "fullScreen": false]),
      ActivityEvent(t: 2, kind: "window", data: ["width": 1024, "height": 768]),
      ActivityEvent(t: 3, kind: "window", data: ["width": 1440, "height": 900, "fullScreen": true]),
    ]

    #expect(
      build(events).windowSizes == [
        ActivityCount(name: "1440x900", count: 2), ActivityCount(name: "1024x768", count: 1),
      ])
  }

  @Test(arguments: [
    ["width": 1440.5, "height": 900] as JSON,
    ["width": 1440],
    ["width": "1440", "height": 900],
    [:],
  ])
  func aWindowWithoutWholeNumberSidesIsSkipped(data: JSON) {
    #expect(build([ActivityEvent(t: 1, kind: "window", data: data)]).windowSizes.isEmpty)
  }

  // MARK: Kinds stay apart

  @Test func eachSectionReadsOnlyItsOwnKind() {
    let events = [
      ActivityEvent(t: 1, kind: "app", data: ["to": "inbox", "via": "list", "name": "back", "where": "open"]),
      ActivityEvent(t: 2, kind: "resume.ready", data: ["textHash": "h", "width": 10, "height": 10]),
    ]

    let report = build(events)

    #expect(report.places.isEmpty)
    #expect(report.navigation.isEmpty)
    #expect(report.commands.isEmpty)
    #expect(report.errors.isEmpty)
    #expect(report.sends == 0)
    #expect(report.windowSizes.isEmpty)
    #expect(report.terminalReady.isEmpty)
  }
}
