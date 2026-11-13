import Foundation
import Testing

@testable import SwitchboardCore

let utc = TimeZone(identifier: "UTC")!
let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
let kolkata = TimeZone(identifier: "Asia/Kolkata")!
let lordHowe = TimeZone(identifier: "Australia/Lord_Howe")!
let santiago = TimeZone(identifier: "America/Santiago")!
/// Years away from the real clock, so a test catches code that reads the clock in place of `now`.
let fixedNow = epochMs(2030, 6, 15, 12, 0, zone: utc)
let farFuture = epochMs(2090, 1, 1, zone: utc)
let localNineAM = epochMs(2026, 10, 26, 9, 0, zone: .current)
let pr1204 = Wait.PullRequest(number: 1204)
let posthog1204 = Wait.PullRequest(repository: "PostHog/posthog", number: 1204)
let flagCache = Wait.SessionTarget(id: "k3x9p", name: "flag-cache")
let prKinds: [Wait.Kind] = [.ci, .review, .botReview, .approval, .queue, .merge, .deploy]

func epochMs(
  _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, zone: TimeZone
) -> Int64 {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
  return Int64(calendar.date(from: parts)!.timeIntervalSince1970 * 1000)
}

func waitOn(
  _ kind: Wait.Kind, pr: Wait.PullRequest? = nil, session: Wait.SessionTarget? = nil, state: AttentionState? = nil,
  who: String? = nil, environment: String? = nil, service: String? = nil, until: Int64? = nil, note: String? = nil,
  then: Wait.Then = .resume
) -> Wait {
  Wait(
    id: "w1", kind: kind, pr: pr, session: session, state: state, who: who, environment: environment, service: service,
    until: until, note: note, created: 0, then: then)
}

func withWaits(_ waits: [Wait]?, done: Bool = false) -> Session {
  var s = session(done: done)
  s.waits = waits
  return s
}

func resolved(_ wait: Wait, _ outcome: String, _ t: Int64) throws -> Event {
  event("wait-resolved", t, ["wait": try JSON(encoding: wait), "outcome": .string(outcome)])
}

struct NoSuchSession: Error {}

func findFlagCache(_ text: String) throws -> Wait.SessionTarget {
  guard ["k3x9p", "k3", "flag-cache"].contains(text) else { throw NoSuchSession() }
  return flagCache
}

func buildWait(_ request: WaitRequest, waiter: String = "s1", now: Int64 = fixedNow) throws -> Wait {
  try request.makeWait(id: "w7", waiter: waiter, now: now, findSession: findFlagCache)
}

/// The fewest arguments that make a valid wait of the kind.
func minimalRequest(_ kind: Wait.Kind) -> WaitRequest {
  switch kind {
  case .review: WaitRequest(kind: "review", who: "alex")
  case .session: WaitRequest(kind: "session", target: "flag-cache")
  case .date: WaitRequest(kind: "date", until: "2h")
  default: WaitRequest(kind: kind.rawValue)
  }
}

enum WaitField: CaseIterable {
  case target, who, environment, service, state, until
}

let kindsThatUse: [WaitField: Set<Wait.Kind>] = [
  .target: Set(prKinds + [.session]), .who: [.review, .botReview, .approval], .environment: [.deploy],
  .service: [.deploy], .state: [.session], .until: [.date, .manual],
]
let kindFields = Wait.Kind.allCases.flatMap { kind in WaitField.allCases.map { (kind, $0) } }
let usedFields = kindFields.filter { kindsThatUse[$0.1]!.contains($0.0) }
let unusedFields = kindFields.filter { !kindsThatUse[$0.1]!.contains($0.0) }

/// The minimal request with a value for `field` that would be valid on a kind that uses it.
func request(_ kind: Wait.Kind, adding field: WaitField) -> WaitRequest {
  var r = minimalRequest(kind)
  switch field {
  case .target: r.target = kind == .session ? "flag-cache" : "1204"
  case .who: r.who = "alex"
  case .environment: r.environment = "prod-us"
  case .service: r.service = "feature-flags"
  case .state: r.state = "waiting"
  case .until: r.until = "2h"
  }
  return r
}

@Suite struct WaitKinds {
  @Test(arguments: [
    (Wait.Kind.ci, "ci"), (.review, "review"), (.botReview, "bot-review"), (.approval, "approval"),
    (.queue, "queue"), (.merge, "merge"), (.deploy, "deploy"), (.session, "session"), (.date, "date"),
    (.manual, "manual"),
  ])
  func kindsUseTheirWireNames(_ kind: Wait.Kind, _ name: String) {
    #expect(kind.rawValue == name)
  }
}

@Suite struct PullRequestParsing {
  @Test(arguments: [
    ("1204", pr1204), ("#1204", pr1204), ("PostHog/posthog#1204", posthog1204),
    ("https://github.com/PostHog/posthog/pull/1204", posthog1204),
    ("https://github.com/PostHog/posthog/pull/1204/files", posthog1204),
    ("https://github.com/PostHog/posthog/pull/1204#discussion_r1", posthog1204),
    ("https://github.com/PostHog/posthog/pull/1204?x=1", posthog1204),
    ("http://github.com/PostHog/posthog/pull/1204", posthog1204),
    ("pr:1204", pr1204), ("pr:PostHog/posthog#1204", posthog1204),
  ])
  func readsEachForm(_ text: String, _ pr: Wait.PullRequest) {
    #expect(Wait.PullRequest(parsing: text) == pr)
  }

  @Test(arguments: [
    "", "abc", "#", "0", "-3", "12a", "owner#12", "a/b/c#1", "https://github.com/PostHog/posthog/issues/12",
    "#0", "PostHog/posthog#0", "PostHog/posthog#-3", "PostHog/posthog#", "/posthog#12", "PostHog/#12",
    "https://github.com/PostHog/posthog/pull/", "https://github.com/PostHog/posthog/pull/0",
    "https://github.com/PostHog/posthog/pull/12a", "https://gitlab.com/PostHog/posthog/pull/12", "pr:", "pr:abc",
  ])
  func refusesWhatIsNotAPR(_ text: String) {
    #expect(Wait.PullRequest(parsing: text) == nil)
  }

  @Test(arguments: [(pr1204, "#1204"), (posthog1204, "PostHog/posthog#1204")])
  func textNamesTheRepositoryOnlyWhenItHasOne(_ pr: Wait.PullRequest, _ text: String) {
    #expect(pr.text == text)
  }

  @Test(arguments: [pr1204, posthog1204, Wait.PullRequest(repository: "PostHog/charts", number: 17545)])
  func textParsesBackToThePR(_ pr: Wait.PullRequest) {
    #expect(Wait.PullRequest(parsing: pr.text) == pr)
  }
}

@Suite struct WaitText {
  @Test(arguments: [
    (waitOn(.ci, pr: pr1204), "CI on #1204"),
    (waitOn(.ci, pr: pr1204, note: "merge when green"), "CI on #1204"),
    (waitOn(.ci, pr: Wait.PullRequest(repository: "PostHog/charts", number: 17545)), "CI on PostHog/charts#17545"),
    (waitOn(.ci), "CI on the session's PR"),
    (waitOn(.review, pr: pr1204, who: "alex"), "a review from alex on #1204"),
    (waitOn(.botReview, pr: pr1204, who: "ReviewHog"), "ReviewHog's review on #1204"),
    (waitOn(.botReview, pr: pr1204), "a bot review on #1204"),
    (waitOn(.approval, pr: pr1204, who: "stamphog"), "approval from stamphog on #1204"),
    (waitOn(.approval, pr: pr1204), "approval on #1204"),
    (waitOn(.queue, pr: pr1204), "the merge queue for #1204"),
    (waitOn(.merge, pr: Wait.PullRequest(number: 1190)), "#1190 to merge"),
    (waitOn(.deploy, pr: pr1204, environment: "prod-us"), "#1204 to reach prod-us"),
    (
      waitOn(.deploy, pr: pr1204, environment: "prod", service: "feature-flags"),
      "#1204 to reach prod in feature-flags"
    ),
    (waitOn(.session, session: flagCache, state: .done), "flag-cache to reach Done"),
    (waitOn(.date, until: localNineAM), "until 2026-10-26 09:00"),
    (waitOn(.manual, note: "ask Alex"), "ask Alex"),
    (waitOn(.manual), "a manual wait"),
  ])
  func summaryNamesWhatItWaitsOn(_ wait: Wait, _ summary: String) {
    #expect(wait.summary == summary)
  }

  @Test(arguments: AttentionState.allCases)
  func sessionSummaryNamesTheStateByItsTitle(_ state: AttentionState) {
    #expect(waitOn(.session, session: flagCache, state: state).summary == "flag-cache to reach \(state.title)")
  }

  @Test(arguments: prKinds)
  func prKindWithoutAPRNamesTheSessionsPR(_ kind: Wait.Kind) {
    let wait = waitOn(kind, who: kind == .review ? "alex" : nil, environment: kind == .deploy ? "prod" : nil)
    #expect(wait.summary.contains("the session's PR"))
  }

  @Test(arguments: [
    (waitOn(.ci, pr: pr1204, note: "merge when green"), "CI on #1204 (merge when green)"),
    (waitOn(.review, pr: pr1204, who: "alex"), "a review from alex on #1204"),
    (
      waitOn(.session, session: flagCache, state: .done, note: "then rebase"),
      "flag-cache to reach Done (then rebase)"
    ),
    (waitOn(.date, until: localNineAM, note: "standup"), "until 2026-10-26 09:00 (standup)"),
    (waitOn(.manual, note: "ask Alex"), "ask Alex"),
    (waitOn(.manual, until: localNineAM, note: "ask Alex"), "ask Alex (recheck 2026-10-26 09:00)"),
    (waitOn(.manual, until: localNineAM), "a manual wait (recheck 2026-10-26 09:00)"),
  ])
  func lineAddsTheNoteOrTheRecheckTime(_ wait: Wait, _ line: String) {
    #expect(wait.line == line)
  }

  @Test(arguments: [
    (waitOn(.ci, pr: pr1204, note: "merge when green"), "the checks passed", "CI on #1204: the checks passed"),
    (waitOn(.manual, until: localNineAM, note: "ask Alex"), "time to recheck", "ask Alex: time to recheck"),
  ])
  func outcomeLineIsTheSummaryAndTheOutcome(_ wait: Wait, _ outcome: String, _ line: String) {
    #expect(wait.outcomeLine(outcome) == line)
  }

  @Test(arguments: [
    (
      waitOn(.ci, pr: pr1204, note: "merge when green"), "the checks passed",
      "Switchboard: CI on #1204: the checks passed. Your note: merge when green."
    ),
    (waitOn(.ci, pr: pr1204), "the checks passed", "Switchboard: CI on #1204: the checks passed."),
    (
      waitOn(.review, pr: pr1204, who: "alex", note: "address it"), "alex approved",
      "Switchboard: a review from alex on #1204: alex approved. Your note: address it."
    ),
    (waitOn(.manual, note: "ask Alex", then: .notify), "time to recheck", "Switchboard: ask Alex: time to recheck."),
    (waitOn(.manual), "time to recheck", "Switchboard: a manual wait: time to recheck."),
    (waitOn(.ci, pr: pr1204), "the checks passed.", "Switchboard: CI on #1204: the checks passed."),
    (waitOn(.ci, pr: pr1204), "they failed!", "Switchboard: CI on #1204: they failed!"),
    (waitOn(.ci, pr: pr1204), "did they pass?", "Switchboard: CI on #1204: did they pass?"),
    (
      waitOn(.ci, pr: pr1204, note: "merge when green."), "the checks passed",
      "Switchboard: CI on #1204: the checks passed. Your note: merge when green."
    ),
    (
      waitOn(.ci, pr: pr1204, note: "merge?"), "the checks passed!",
      "Switchboard: CI on #1204: the checks passed! Your note: merge?"
    ),
  ])
  func messageSaysWhatHappenedAndRepeatsTheNote(_ wait: Wait, _ outcome: String, _ message: String) {
    #expect(wait.message(outcome: outcome) == message)
  }
}

@Suite struct WaitTimes {
  @Test(arguments: [
    (epochMs(2026, 10, 26, 9, 0, zone: utc), utc, "2026-10-26 09:00"),
    (epochMs(2026, 10, 26, 9, 0, zone: utc), losAngeles, "2026-10-26 02:00"),
    (epochMs(2026, 10, 26, 9, 0, zone: utc), kolkata, "2026-10-26 14:30"),
    (epochMs(2026, 1, 5, 21, 7, 59, zone: utc) + 999, utc, "2026-01-05 21:07"),
  ])
  func formatTimeWritesTheMinuteInTheZone(_ ms: Int64, _ zone: TimeZone, _ text: String) {
    #expect(Wait.formatTime(ms, zone: zone) == text)
  }

  @Test func formatTimeDefaultsToTheLocalZone() {
    #expect(Wait.formatTime(localNineAM) == "2026-10-26 09:00")
  }

  @Test(arguments: [("90s", 90), ("30m", 1800), ("2h", 7200), ("1d", 86_400), ("1w", 604_800)])
  func durationCountsFromNow(_ text: String, _ seconds: Int) {
    #expect(Wait.parseTime(text, now: fixedNow) == fixedNow + Int64(seconds) * 1000)
  }

  @Test(arguments: [utc, losAngeles, kolkata])
  func dateIsMidnightInTheZone(_ zone: TimeZone) {
    #expect(Wait.parseTime("2026-10-26", now: fixedNow, zone: zone) == epochMs(2026, 10, 26, zone: zone))
  }

  @Test(
    arguments: [("2026-10-26T09:00", 0), ("2026-10-26 09:00", 0), ("2026-10-26T09:00:30", 30)],
    [utc, losAngeles, kolkata])
  func dateAndTimeAreInTheZone(_ form: (String, Int), _ zone: TimeZone) {
    #expect(Wait.parseTime(form.0, now: fixedNow, zone: zone) == epochMs(2026, 10, 26, 9, 0, form.1, zone: zone))
  }

  @Test func localFormsDefaultToTheLocalZone() {
    #expect(Wait.parseTime("2026-10-26", now: fixedNow) == epochMs(2026, 10, 26, zone: .current))
    #expect(Wait.parseTime("2026-10-26 09:00", now: fixedNow) == localNineAM)
  }

  @Test(
    arguments: [("2026-10-26T09:00:00Z", 9), ("2026-10-26T09:00:00+02:00", 7), ("2026-10-26T09:00:00-05:00", 14)],
    [utc, losAngeles, kolkata])
  func isoTimeWithAZoneIgnoresTheGivenZone(_ form: (String, Int), _ zone: TimeZone) {
    #expect(Wait.parseTime(form.0, now: fixedNow, zone: zone) == epochMs(2026, 10, 26, form.1, zone: utc))
  }

  @Test(arguments: [
    "", "soon", "2h30m", "12x", "-2h", "h", "2026-13-01", "2026-02-30", "2026-10-26T25:00", "2026-10-26T09:60",
    "99999999999999999w", "9223372036854775807s",
  ])
  func refusesWhatIsNotATime(_ text: String) {
    #expect(Wait.parseTime(text, now: fixedNow, zone: utc) == nil)
  }

  /// Los Angeles skips 02:00 to 03:00 on 2026-03-08. Lord Howe skips 02:00 to
  /// 02:30 on 2026-10-04. Santiago skips midnight to 01:00 on 2026-09-06.
  @Test(arguments: [
    ("2026-03-08 02:30", losAngeles, epochMs(2026, 3, 8, 10, 30, zone: utc)),
    ("2026-03-08T02:30", losAngeles, epochMs(2026, 3, 8, 10, 30, zone: utc)),
    ("2026-03-08T02:30:30", losAngeles, epochMs(2026, 3, 8, 10, 30, 30, zone: utc)),
    ("2026-10-04 02:10", lordHowe, epochMs(2026, 10, 3, 15, 40, zone: utc)),
    ("2026-09-06", santiago, epochMs(2026, 9, 6, 4, 0, zone: utc)),
  ])
  func timeTheZoneSkipsMovesForwardByTheSkip(_ text: String, _ zone: TimeZone, _ ms: Int64) {
    #expect(Wait.parseTime(text, now: fixedNow, zone: zone) == ms)
  }

  @Test(arguments: ["2026-03-08 25:00", "2026-02-30 02:30", "2026-03-08T02:60"])
  func refusesWhatIsNotATimeInAZoneWithASkip(_ text: String) {
    #expect(Wait.parseTime(text, now: fixedNow, zone: losAngeles) == nil)
  }

  /// Los Angeles reads 01:00 to 02:00 twice on 2026-11-01.
  @Test func repeatedTimeIsTheLaterOne() {
    #expect(
      Wait.parseTime("2026-11-01 01:30", now: fixedNow, zone: losAngeles) == epochMs(2026, 11, 1, 9, 30, zone: utc))
  }

  @Test(
    arguments: [epochMs(2026, 10, 26, 9, 0, zone: utc), epochMs(2027, 1, 5, 21, 7, zone: utc)],
    [utc, losAngeles, kolkata])
  func formattedTimeParsesBack(_ ms: Int64, _ zone: TimeZone) {
    #expect(Wait.parseTime(Wait.formatTime(ms, zone: zone), now: fixedNow, zone: zone) == ms)
  }
}

@Suite struct WaitResolution {
  @Test(arguments: [(Wait.Kind.date, "the time came"), (.manual, "time to recheck")], [Int64(1000), 5000])
  func timedWaitResolvesOnceItsTimeComes(_ kind: (Wait.Kind, String), _ now: Int64) {
    #expect(waitOn(kind.0, until: 1000).resolution(now: now, stateOf: { _ in nil }) == kind.1)
  }

  @Test(arguments: [Wait.Kind.date, .manual])
  func timedWaitStaysOpenBeforeItsTime(_ kind: Wait.Kind) {
    #expect(waitOn(kind, until: 1000).resolution(now: 999, stateOf: { _ in nil }) == nil)
  }

  @Test func manualWaitWithoutARecheckTimeStaysOpen() {
    #expect(waitOn(.manual, note: "ask Alex").resolution(now: farFuture, stateOf: { _ in .done }) == nil)
  }

  @Test(arguments: AttentionState.allCases)
  func sessionWaitResolvesWhenTheOtherSessionReachesItsState(_ state: AttentionState) {
    let wait = waitOn(.session, session: flagCache, state: state)
    #expect(wait.resolution(now: 1, stateOf: { $0 == "k3x9p" ? state : nil }) == "it did")
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .done && $0 != .stale })
  func sessionWaitStaysOpenInAnotherState(_ other: AttentionState) {
    let wait = waitOn(.session, session: flagCache, state: .done)
    #expect(wait.resolution(now: 1, stateOf: { $0 == "k3x9p" ? other : nil }) == nil)
  }

  @Test func sessionWaitResolvesWhenTheOtherSessionIsGone() {
    let wait = waitOn(.session, session: flagCache, state: .done)
    #expect(wait.resolution(now: 1, stateOf: { _ in nil }) == "it was removed")
  }

  @Test(arguments: prKinds)
  func pollerKindNeverResolvesInSbd(_ kind: Wait.Kind) {
    let wait = waitOn(kind, pr: pr1204, session: flagCache, state: .done, until: 0)
    #expect(wait.resolution(now: farFuture, stateOf: { _ in .done }) == nil)
  }
}

@Suite struct WaitRequests {
  @Test func noKindIsAManualWaitThatNotifies() throws {
    #expect(
      try buildWait(WaitRequest(note: "ask Alex"))
        == Wait(id: "w7", kind: .manual, note: "ask Alex", by: .you, created: fixedNow, then: .notify))
  }

  @Test(arguments: ["bogus", "botReview"])
  func unknownKindThrows(_ kind: String) {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: kind)) }
  }

  @Test(arguments: Wait.Kind.allCases)
  func minimalRequestBuildsItsKind(_ kind: Wait.Kind) throws {
    #expect(try buildWait(minimalRequest(kind)).kind == kind)
  }

  @Test func reviewKeepsEveryArgument() throws {
    let r = WaitRequest(kind: "review", target: "#1204", who: "alex", note: "address it", then: "notify", by: "claude")
    #expect(
      try buildWait(r)
        == Wait(
          id: "w7", kind: .review, pr: pr1204, who: "alex", note: "address it", by: .claude, created: fixedNow,
          then: .notify))
  }

  @Test(arguments: prKinds)
  func prKindReadsItsTarget(_ kind: Wait.Kind) throws {
    var r = minimalRequest(kind)
    r.target = "PostHog/posthog#1204"
    #expect(try buildWait(r).pr == posthog1204)
  }

  @Test(arguments: ["1204", "#1204", "PostHog/posthog#1204", "https://github.com/PostHog/posthog/pull/1204/files"])
  func prTargetParsesLikePullRequestParsing(_ target: String) throws {
    let parsed = try #require(Wait.PullRequest(parsing: target))
    #expect(try buildWait(WaitRequest(kind: "ci", target: target)).pr == parsed)
  }

  @Test(arguments: prKinds)
  func prKindWithoutATargetWaitsOnTheSessionsPR(_ kind: Wait.Kind) throws {
    #expect(try buildWait(minimalRequest(kind)).pr == nil)
  }

  @Test(arguments: prKinds, ["abc", "owner#12", "https://github.com/PostHog/posthog/issues/12"])
  func prKindRefusesATargetThatIsNotAPR(_ kind: Wait.Kind, _ target: String) {
    var r = minimalRequest(kind)
    r.target = target
    #expect(throws: APIError.self) { try buildWait(r) }
  }

  @Test func reviewRequiresWho() {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "review", target: "1204")) }
  }

  @Test(arguments: [Wait.Kind.botReview, .approval], ["stamphog", nil] as [String?])
  func botReviewAndApprovalTakeAnOptionalWho(_ kind: Wait.Kind, _ who: String?) throws {
    #expect(try buildWait(WaitRequest(kind: kind.rawValue, target: "1204", who: who)).who == who)
  }

  @Test func deployDefaultsToProdWithNoService() throws {
    #expect(
      try buildWait(WaitRequest(kind: "deploy", target: "1204"))
        == Wait(id: "w7", kind: .deploy, pr: pr1204, environment: "prod", created: fixedNow, then: .resume))
  }

  @Test(arguments: ["dev", "prod-us", "prod-eu", "prod"])
  func deployTakesEachEnvironment(_ environment: String) throws {
    #expect(try buildWait(WaitRequest(kind: "deploy", environment: environment)).environment == environment)
  }

  @Test(arguments: ["staging", "prod-ap", "us"])
  func deployRefusesAnUnknownEnvironment(_ environment: String) {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "deploy", environment: environment)) }
  }

  @Test func deployTakesAService() throws {
    #expect(try buildWait(WaitRequest(kind: "deploy", service: "feature-flags")).service == "feature-flags")
  }

  @Test func sessionWaitStoresTheSessionThatTheLookupFound() throws {
    #expect(
      try buildWait(WaitRequest(kind: "session", target: "k3"))
        == Wait(id: "w7", kind: .session, session: flagCache, state: .done, created: fixedNow, then: .resume))
  }

  @Test func sessionWaitRequiresATarget() {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "session")) }
  }

  @Test func sessionWaitPassesOnTheLookupError() {
    #expect(throws: NoSuchSession.self) { try buildWait(WaitRequest(kind: "session", target: "nope")) }
  }

  @Test(arguments: ["k3x9p", "k3", "flag-cache"])
  func sessionCantWaitOnItself(_ target: String) {
    #expect(throws: APIError.self) {
      try buildWait(WaitRequest(kind: "session", target: target), waiter: flagCache.id)
    }
  }

  @Test(arguments: AttentionState.allCases)
  func sessionWaitTakesEachState(_ state: AttentionState) throws {
    #expect(try buildWait(WaitRequest(kind: "session", target: "k3", state: state.rawValue)).state == state)
  }

  @Test(arguments: ["needsYou", "Done", "finished"])
  func sessionWaitRefusesAnUnknownState(_ state: String) {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "session", target: "k3", state: state)) }
  }

  @Test func dateWaitCountsUntilFromTheGivenNow() throws {
    #expect(
      try buildWait(WaitRequest(kind: "date", until: "2h"))
        == Wait(id: "w7", kind: .date, until: fixedNow + 7_200_000, created: fixedNow, then: .resume))
  }

  @Test func dateWaitRequiresUntil() {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "date")) }
  }

  @Test func manualWaitTakesARecheckTime() throws {
    #expect(try buildWait(WaitRequest(kind: "manual", until: "1d")).until == fixedNow + 86_400_000)
  }

  @Test(arguments: [Wait.Kind.date, .manual])
  func untilThatDoesNotParseThrows(_ kind: Wait.Kind) {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: kind.rawValue, until: "soon")) }
  }

  @Test(arguments: [Wait.Kind.date, .manual], ["2030-06-15T12:00:00Z", "2030-06-15T11:59:59Z", "2026-10-26", "0s"])
  func untilAtOrBeforeNowThrows(_ kind: Wait.Kind, _ until: String) {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: kind.rawValue, until: until)) }
  }

  @Test(arguments: [Wait.Kind.date, .manual])
  func untilASecondAfterNowIsTaken(_ kind: Wait.Kind) throws {
    #expect(try buildWait(WaitRequest(kind: kind.rawValue, until: "2030-06-15T12:00:01Z")).until == fixedNow + 1000)
  }

  @Test(arguments: [Wait.Kind.date, .manual])
  func untilIsMeasuredFromTheGivenNowNotTheClock(_ kind: Wait.Kind) throws {
    let wait = try buildWait(
      WaitRequest(kind: kind.rawValue, until: "2010-01-01T00:00:00Z"), now: epochMs(2000, 1, 1, zone: utc))
    #expect(wait.until == epochMs(2010, 1, 1, zone: utc))
  }

  @Test(
    arguments: [Wait.Kind.date, .manual],
    [
      "90s", "1w", "2031-01-01", "2031-01-01T09:00", "2031-01-01 09:00:30", "2031-01-01T09:00:00Z",
      "2031-01-01T09:00:00+02:00",
    ])
  func untilParsesLikeParseTime(_ kind: Wait.Kind, _ until: String) throws {
    let parsed = try #require(Wait.parseTime(until, now: fixedNow))
    #expect(try buildWait(WaitRequest(kind: kind.rawValue, until: until)).until == parsed)
  }

  @Test(arguments: unusedFields)
  func kindRefusesAFieldItDoesNotUse(_ kind: Wait.Kind, _ field: WaitField) {
    #expect(throws: APIError.self) { try buildWait(request(kind, adding: field)) }
  }

  @Test(arguments: usedFields)
  func kindTakesEachFieldItUses(_ kind: Wait.Kind, _ field: WaitField) throws {
    #expect(try buildWait(request(kind, adding: field)).kind == kind)
  }

  @Test(arguments: Wait.Kind.allCases)
  func everyKindTakesANoteAThenAndABy(_ kind: Wait.Kind) throws {
    var r = minimalRequest(kind)
    r.note = "x"
    r.then = "resume"
    r.by = "claude"
    let wait = try buildWait(r)
    #expect((wait.note, wait.then, wait.by) == ("x", .resume, .claude))
  }

  @Test(arguments: Wait.Kind.allCases)
  func thenDefaultsToNotifyForManualAndResumeOtherwise(_ kind: Wait.Kind) throws {
    #expect(try buildWait(minimalRequest(kind)).then == (kind == .manual ? .notify : .resume))
  }

  @Test(arguments: Wait.Kind.allCases, [Wait.Then.resume, .notify])
  func thenOverridesTheDefault(_ kind: Wait.Kind, _ then: Wait.Then) throws {
    var r = minimalRequest(kind)
    r.then = then.rawValue
    #expect(try buildWait(r).then == then)
  }

  @Test(arguments: ["later", "both"])
  func unknownThenThrows(_ then: String) {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "ci", then: then)) }
  }

  @Test(arguments: ["robot", "me"])
  func unknownByThrows(_ by: String) {
    #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "ci", by: by)) }
  }

  @Test(
    arguments: [("  merge when green \n", "merge when green"), ("a  b", "a  b"), ("", nil), (" \n\t ", nil)]
      as [(String, String?)])
  func noteIsTrimmedAndBlankIsNone(_ text: String, _ note: String?) throws {
    #expect(try buildWait(WaitRequest(kind: "ci", note: text)).note == note)
  }
}

@Suite struct ShortIds {
  static let alphabet = Set("abcdefghijkmnpqrstuvwxyz23456789")

  @Test(arguments: ["w", "n"])
  func shortIdIsThePrefixAndFiveCharactersFromTheAlphabet(_ prefix: String) {
    let id = shortId(prefix)
    #expect(id.hasPrefix(prefix))
    #expect(id.count == prefix.count + 5)
    #expect(id.dropFirst(prefix.count).allSatisfy { Self.alphabet.contains($0) })
  }

  @Test func shortIdAvoidsTakenIds() {
    var taken = Set<String>()
    var repeats = 0
    for _ in 0..<500 {
      let id = shortId("w", taken: taken)
      if !taken.insert(id).inserted { repeats += 1 }
    }
    #expect(repeats == 0)
  }
}

@Suite struct WaitFacts {
  let notified = waitOn(.ci, pr: pr1204, note: "merge when green", then: .notify)
  let resumed = waitOn(.review, pr: pr1204, who: "alex")

  func afterNotify(_ later: [Event] = []) throws -> SessionFacts {
    facts(
      [
        event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Pushed."]),
        try resolved(notified, "the checks passed", 2),
      ] + later)
  }

  @Test func notifyResolutionRecordsItsOutcomeLine() throws {
    #expect(try afterNotify().waitOutcome == "CI on #1204: the checks passed")
  }

  @Test func resumeResolutionRecordsNoOutcome() throws {
    #expect(facts([try resolved(resumed, "alex approved", 1)]).waitOutcome == nil)
  }

  @Test func resumeResolutionLeavesAnEarlierOutcome() throws {
    #expect(try afterNotify([resolved(resumed, "alex approved", 3)]).waitOutcome == "CI on #1204: the checks passed")
  }

  @Test func promptClearsTheOutcome() throws {
    #expect(try afterNotify([event("UserPromptSubmit", 3, ["prompt": "merge it"])]).waitOutcome == nil)
  }

  @Test(arguments: [
    "<task-notification><task-id>a1</task-id></task-notification>", "<agent-message from=\"a1\"> [Subagent] done",
    peerMessage,
  ])
  func anotherAgentsMessageLeavesTheOutcome(_ prompt: String) throws {
    let f = try afterNotify([event("UserPromptSubmit", 3, ["prompt": .string(prompt)])])
    #expect(f.waitOutcome == "CI on #1204: the checks passed")
  }

  @Test func newWaitClearsTheOutcome() throws {
    #expect(try afterNotify([event("wait", 3, ["wait": JSON(encoding: resumed)])]).waitOutcome == nil)
  }

  @Test(arguments: [
    event("Stop", 3, ["last_assistant_message": "Done."]), event("stopped", 3), event("SessionStart", 3),
  ])
  func otherEventsLeaveTheOutcome(_ later: Event) throws {
    #expect(try afterNotify([later]).waitOutcome == "CI on #1204: the checks passed")
  }
}

@Suite struct WaitAttention {
  let idleEvents = [
    event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Want me to push?"]),
  ]
  var idle: SessionFacts { facts(idleEvents) }
  let review = waitOn(.review, pr: pr1204, who: "alex")
  let notified = waitOn(.ci, pr: pr1204, then: .notify)

  @Test func openWaitsAreWaitingWithTheirLines() {
    let s = withWaits([waitOn(.ci, pr: pr1204, note: "merge when green"), review])
    #expect(
      Attention.evaluate(s, idle, now: 2)
        == Verdict(state: .waiting, reason: "CI on #1204 (merge when green); a review from alex on #1204"))
  }

  @Test func openWaitsAreCutToOneLine() {
    let s = withWaits([waitOn(.ci, pr: pr1204, note: "merge when green"), review, waitOn(.queue, pr: pr1204)])
    #expect(
      Attention.evaluate(s, idle, now: 2)
        == Verdict(state: .waiting, reason: "CI on #1204 (merge when green); a review from alex on #1204; the merg…"))
  }

  @Test func waitBeforeTheFirstPromptIsWaiting() {
    let s = withWaits([waitOn(.manual, note: "ask Alex")])
    #expect(
      Attention.evaluate(s, facts([event("SessionStart", 1)]), now: 2) == Verdict(state: .waiting, reason: "ask Alex"))
  }

  @Test func openWaitIsNeverStale() {
    #expect(Attention.evaluate(withWaits([review]), idle, now: Attention.staleAfterMs + 10).state == .waiting)
  }

  @Test(arguments: [
    (
      facts([
        event("UserPromptSubmit", 0, ["prompt": "go"]),
        event("PermissionRequest", 1, tool("Bash", ["command": "rm -rf build"])),
      ]), AttentionState.needsYou
    ),
    (
      facts([
        event("UserPromptSubmit", 0, ["prompt": "go"]),
        event("PreToolUse", 1, tool("AskUserQuestion", ["questions": [["question": "Which fruit?"]]], id: "q")),
      ]), .needsYou
    ),
    (facts([event("UserPromptSubmit", 0, ["prompt": "go"])]), .working),
  ])
  func openPromptOrRunningTurnWinsOverAnOpenWait(_ f: SessionFacts, _ state: AttentionState) {
    let v = Attention.evaluate(withWaits([review]), f, now: 2)
    #expect(v == Attention.evaluate(session(), f, now: 2))
    #expect(v.state == state)
  }

  /// An idle session whose `notify` wait resolved with "the checks passed".
  func afterNotify() throws -> SessionFacts {
    facts(idleEvents + [try resolved(notified, "the checks passed", 2)])
  }

  @Test(arguments: [nil, []] as [[Wait]?])
  func notifyOutcomeNeedsYouWhenNoWaitIsOpen(_ waits: [Wait]?) throws {
    let f = try afterNotify()
    #expect(
      Attention.evaluate(withWaits(waits), f, now: 3)
        == Verdict(state: .needsYou, reason: "CI on #1204: the checks passed"))
  }

  @Test func notifyOutcomeOutlastsTheStaleRule() throws {
    let f = try afterNotify()
    #expect(
      Attention.evaluate(withWaits([]), f, now: 2 + Attention.staleAfterMs + 10)
        == Verdict(state: .needsYou, reason: "CI on #1204: the checks passed"))
  }

  @Test func notifyOutcomeComesBeforeTheFirstPrompt() throws {
    let f = facts([event("SessionStart", 1), try resolved(notified, "the checks passed", 2)])
    #expect(
      Attention.evaluate(withWaits([]), f, now: 3)
        == Verdict(state: .needsYou, reason: "CI on #1204: the checks passed"))
  }

  @Test func notifyOutcomeWinsOverTheWaitsStillOpen() throws {
    let f = try afterNotify()
    #expect(
      Attention.evaluate(withWaits([review]), f, now: 3)
        == Verdict(state: .needsYou, reason: "CI on #1204: the checks passed"))
  }

  @Test func doneWinsOverWaitsAndOutcomes() throws {
    let f = try afterNotify()
    #expect(
      Attention.evaluate(withWaits([review], done: true), f, now: 3) == Verdict(state: .done, reason: "marked done"))
  }
}

private let minuteMs: Int64 = 60_000
private let hourMs: Int64 = 60 * minuteMs
private let pr1 = Wait.PullRequest(number: 1)
private let pr2 = Wait.PullRequest(number: 2)
/// The kinds whose recheck time moves the session to Needs you while the wait stays open.
private let overdueKinds: [Wait.Kind] = prKinds + [.session]

/// The wait with its recheck time `ms` after it was set.
private func stamped(_ wait: Wait, after ms: Int64) -> Wait {
  var w = wait
  w.recheck = w.created + ms
  return w
}

/// A wait goes overdue at its recheck time and not before.
@Suite struct WaitOverdue {
  static let recheck: Int64 = 5000

  @Test(arguments: overdueKinds)
  func waitIsNotOverdueAMillisecondBeforeItsRecheck(_ kind: Wait.Kind) {
    #expect(!stamped(waitOn(kind, pr: pr1204), after: Self.recheck).isOverdue(now: Self.recheck - 1))
  }

  @Test(arguments: overdueKinds)
  func waitIsOverdueAtItsRecheck(_ kind: Wait.Kind) {
    #expect(stamped(waitOn(kind, pr: pr1204), after: Self.recheck).isOverdue(now: Self.recheck))
  }

  @Test(arguments: overdueKinds)
  func waitWithoutARecheckIsNeverOverdue(_ kind: Wait.Kind) {
    #expect(!waitOn(kind, pr: pr1204).isOverdue(now: farFuture))
  }

  /// A date wait and a manual wait resolve at `until`. Neither goes overdue.
  @Test(arguments: [
    RecheckSettings().stamped(waitOn(.date, until: 9000)), RecheckSettings().stamped(waitOn(.manual, until: 9000)),
    RecheckSettings().stamped(waitOn(.manual, note: "ask Alex")),
  ])
  func timedWaitIsNeverOverdue(_ wait: Wait) {
    #expect(!wait.isOverdue(now: farFuture))
  }
}

extension WaitResolution {
  /// `RecheckSettings.stamped` gives a manual wait without `until` one a day after it was set.
  @Test func stampedManualWaitResolvesADayAfterItWasSet() {
    let wait = RecheckSettings().stamped(waitOn(.manual, note: "ask Alex"))
    let due = wait.created + Attention.dayMs

    #expect(wait.resolution(now: due - 1, stateOf: { _ in nil }) == nil)
    #expect(wait.resolution(now: due, stateOf: { _ in nil }) == "time to recheck")
  }

  /// The wait stays open past its recheck time, and the session goes to Needs you instead.
  @Test(arguments: prKinds)
  func pollerKindStaysOpenPastItsRecheck(_ kind: Wait.Kind) {
    let wait = stamped(waitOn(kind, pr: pr1204), after: 5000)

    #expect(wait.resolution(now: farFuture, stateOf: { _ in .done }) == nil)
  }

  @Test func sessionWaitStaysOpenPastItsRecheckWhileTheTargetWorks() {
    let wait = stamped(waitOn(.session, session: flagCache, state: .done), after: 5000)

    #expect(wait.resolution(now: farFuture, stateOf: { $0 == "k3x9p" ? .working : nil }) == nil)
  }
}

/// A `session` wait ends when its target can't reach the wanted state on its own.
@Suite struct SessionWaitTargets {
  func resolution(wanting state: AttentionState, target: AttentionState?, now: Int64 = 1) -> String? {
    waitOn(.session, session: flagCache, state: state)
      .resolution(now: now, stateOf: { $0 == flagCache.id ? target : nil })
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .done })
  func targetInDoneEndsAWaitForAnotherState(_ wanted: AttentionState) {
    #expect(resolution(wanting: wanted, target: .done) == "it reached Done first")
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .stale })
  func targetInStaleEndsAWaitForAnotherState(_ wanted: AttentionState) {
    #expect(resolution(wanting: wanted, target: .stale) == "it went stale")
  }

  @Test(arguments: [AttentionState.done, .stale])
  func targetThatReachesTheWantedStateDidIt(_ state: AttentionState) {
    #expect(resolution(wanting: state, target: state) == "it did")
  }

  /// The real outcome wins over the terminal states and over a recheck time that passed.
  @Test(arguments: [AttentionState.done, .stale])
  func realOutcomeWinsPastTheRecheck(_ state: AttentionState) {
    let wait = stamped(waitOn(.session, session: flagCache, state: state), after: 5000)

    #expect(wait.resolution(now: farFuture, stateOf: { _ in state }) == "it did")
  }

  @Test func targetRemovedEndsTheWait() {
    #expect(resolution(wanting: .readyForReview, target: nil) == "it was removed")
  }

  /// Not started, and Needs you with its claude stopped, can still move on.
  @Test(
    arguments: [AttentionState.notStarted, .needsYou, .canContinue, .readyToMerge, .waiting, .working],
    [AttentionState.done, .readyForReview])
  func targetThatCanStillMoveKeepsTheWaitOpen(_ target: AttentionState, _ wanted: AttentionState) {
    #expect(resolution(wanting: wanted, target: target, now: farFuture) == nil)
  }

  @Test func onlyTheTargetsOwnStateCounts() {
    let wait = waitOn(.session, session: flagCache, state: .readyForReview)

    #expect(wait.resolution(now: 1, stateOf: { $0 == flagCache.id ? .waiting : .done }) == nil)
  }
}

/// An open wait past its recheck time moves the session
/// to Needs you and names the wait.
@Suite struct OverdueWaitAttention {
  let idle = facts([
    event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Want me to push?"]),
  ])
  let review = stamped(waitOn(.review, pr: pr1204, who: "alex"), after: Attention.dayMs)
  let ci = stamped(waitOn(.ci, pr: pr1), after: 2 * hourMs)
  let merge = stamped(waitOn(.merge, pr: pr2), after: Attention.dayMs)

  @Test func overdueWaitNeedsYouAndNamesTheWait() {
    let v = Attention.evaluate(withWaits([review]), idle, now: Attention.dayMs)

    #expect(v == Verdict(state: .needsYou, reason: "a review from alex on #1204: still open after 1 d"))
  }

  @Test func overdueWaitIsAnInfoItem() {
    #expect(Attention.evaluate(withWaits([review]), idle, now: Attention.dayMs).kind == .info)
  }

  @Test func waitAMillisecondBeforeItsRecheckIsWaitingWithItsLine() {
    let v = Attention.evaluate(withWaits([review]), idle, now: Attention.dayMs - 1)

    #expect(v == Verdict(state: .waiting, reason: "a review from alex on #1204"))
  }

  @Test func oneOverdueWaitAndOneOpenWaitNameOnlyTheOverdueOne() {
    let v = Attention.evaluate(withWaits([merge, ci]), idle, now: 2 * hourMs)

    #expect(v == Verdict(state: .needsYou, reason: "CI on #1: still open after 2 h"))
  }

  @Test func twoOverdueWaitsAreJoinedInTheirOrder() {
    let v = Attention.evaluate(withWaits([ci, merge]), idle, now: Attention.dayMs)

    #expect(v == Verdict(state: .needsYou, reason: "CI on #1: still open after 2 h; #2 to merge: still open after 1 d"))
  }

  @Test(arguments: [
    (59 * minuteMs, "59 min"), (60 * minuteMs, "1 h"), (90 * minuteMs, "1 h"), (2 * hourMs, "2 h"),
    (24 * hourMs, "1 d"), (25 * hourMs, "1 d"), (3 * Attention.dayMs, "3 d"),
  ])
  func ageIsTheLargestWholeUnit(_ ms: Int64, _ age: String) {
    let wait = stamped(waitOn(.ci, pr: pr1), after: ms)

    #expect(Attention.evaluate(withWaits([wait]), idle, now: ms).reason == "CI on #1: still open after \(age)")
  }

  /// The age is the recheck time less the time the wait was set, so an
  /// acknowledgment of the reason keeps matching.
  @Test(arguments: [Int64(0), 1, hourMs, Attention.dayMs, Attention.staleAfterMs])
  func reasonStaysTheSameAsTimePasses(_ later: Int64) {
    let at = Attention.evaluate(withWaits([review]), idle, now: Attention.dayMs)

    #expect(Attention.evaluate(withWaits([review]), idle, now: Attention.dayMs + later) == at)
  }

  @Test func overdueWaitOutlastsTheStaleRule() {
    let v = Attention.evaluate(withWaits([review]), idle, now: Attention.staleAfterMs + 10)

    #expect(v.state == .needsYou)
  }

  @Test func waitWithoutARecheckStaysWaitingForever() {
    let legacy = waitOn(.review, pr: pr1204, who: "alex")

    #expect(Attention.evaluate(withWaits([legacy]), idle, now: farFuture).state == .waiting)
  }

  @Test func notifyOutcomeWinsOverAnOverdueWait() throws {
    let notified = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Want me to push?"]),
      try resolved(waitOn(.ci, pr: pr1204, then: .notify), "the checks passed", 2),
    ])

    let v = Attention.evaluate(withWaits([review]), notified, now: Attention.dayMs)

    #expect(v == Verdict(state: .needsYou, reason: "CI on #1204: the checks passed"))
  }

  @Test func doneWinsOverAnOverdueWait() {
    let v = Attention.evaluate(withWaits([review], done: true), idle, now: Attention.dayMs)

    #expect(v == Verdict(state: .done, reason: "marked done"))
  }

  @Test func openPermissionPromptWinsOverAnOverdueWait() {
    let f = facts(promptTurn(touchCall, touch))

    #expect(Attention.evaluate(withWaits([review]), f, now: Attention.dayMs).reason == "approve `touch x`")
  }

  /// `finishedPR` reads `waitVerdict`, so an overdue deploy wait still blocks Done.
  @Test func overdueDeployWaitOnAMergedPRNeedsYouNotDone() throws {
    let deploy = stamped(waitOn(.deploy, pr: pr1204, environment: "prod"), after: 4 * hourMs)
    let f = try prFacts(samplePR(state: .merged), dirty: 0)

    let v = Attention.evaluate(withWaits([deploy]), f, now: 4 * hourMs)

    #expect(v == Verdict(state: .needsYou, reason: "#1204 to reach prod: still open after 4 h"))
  }
}
