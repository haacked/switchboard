import Foundation
import Testing

@testable import SwitchboardCore

private let now: Int64 = 1_800_000_000_000
private let second: Int64 = 1000
private let minute: Int64 = 60 * second

/// A request as sb sends it on the wire. Only the fields that are not nil go in.
private func request(
  every: String? = "30m", prompt: String? = "check the queue", runner: String? = nil, account: String? = nil,
  model: String? = nil, timeout: String? = nil, gate: Bool = false
) throws -> ScheduleRequest {
  var fields: [String: JSON] = [:]
  for (key, value) in [
    ("every", every), ("prompt", prompt), ("runner", runner), ("account", account), ("model", model),
    ("timeout", timeout),
  ] {
    if let value { fields[key] = .string(value) }
  }
  if gate {
    fields["gate"] = .object([
      "group": .string("g1"), "repo": .string("haacked/switchboard"), "target": .number(3),
      "template": .string("work on {issue}"), "rubric": .string("small issues"),
    ])
  }
  return try JSONCoding.decode(ScheduleRequest.self, from: JSON.object(fields).text)
}

/// The schedule that the request makes, with the group a gate needs.
private func make(
  id: String = "rk3x9p", every: String? = "30m", prompt: String? = "check the queue", runner: String? = nil,
  account: String? = nil, model: String? = nil, timeout: String? = nil, gate: Bool = false
) throws -> Schedule {
  try request(
    every: every, prompt: prompt, runner: runner, account: account, model: model, timeout: timeout, gate: gate
  ).makeSchedule(id: id, now: now, group: gate ? (id: "g1", name: "flags") : nil)
}

/// The message of the error that the body throws, or "no error". A request that does not decode counts as an error.
private func message(_ body: () throws -> Any) -> String {
  do {
    _ = try body()
    return "no error"
  } catch {
    return "\(error)"
  }
}

private func keys(_ value: some Encodable) throws -> Set<String> {
  Set(try #require(JSON.parse(try JSONCoding.encode(value))?.object).keys)
}

extension ScheduleTests {
  /// Decisions 5, 10, 15, 21, and 23: the runner, account, model, and timeout of a schedule.
  @Suite struct Runners {
    // MARK: Making a schedule

    @Test func aRequestWithoutARunnerMakesASessionScheduleWithNoRunner() throws {
      #expect(try make().runner == nil)
    }

    /// Risk 3: a session schedule stores no new key, so an older sbd reads it exactly as before.
    @Test func anExplicitSessionRunnerMakesTheSameScheduleAsNoRunner() throws {
      #expect(try make(runner: "session") == make())
    }

    @Test func aSessionScheduleEncodesNoNewKey() throws {
      let schedule = try make(runner: "session")

      #expect(try keys(schedule) == ["id", "prompt", "every", "next", "by", "created"])
    }

    @Test(arguments: [("headless", Schedule.Runner.headless), ("script", .script)])
    func theRequestsRunnerIsStored(_ raw: String, _ runner: Schedule.Runner) throws {
      #expect(try make(runner: raw).runner == runner)
    }

    @Test func eachRunnerEncodesItsName() throws {
      #expect(try JSONCoding.encode(Schedule.Runner.session) == #""session""#)
      #expect(try JSONCoding.encode(Schedule.Runner.headless) == #""headless""#)
      #expect(try JSONCoding.encode(Schedule.Runner.script) == #""script""#)
    }

    @Test func refusesAnUnknownRunner() {
      #expect(message { try make(runner: "cron") } != "no error")
    }

    @Test func aScriptStoresItsTrimmedCommandAsThePrompt() throws {
      #expect(try make(prompt: "  git fetch --prune \n", runner: "script").prompt == "git fetch --prune")
    }

    @Test(arguments: [nil, "", "   ", " \n\t "] as [String?])
    func refusesAScriptWithNoCommand(_ command: String?) {
      #expect(message { try make(prompt: command, runner: "script") } != "no error")
    }

    /// A NUL can't reach the run's argv, so a schedule that holds one would fail on every run.
    @Test(arguments: ["headless", "script"])
    func refusesANulInTheCommandOrPrompt(_ runner: String) throws {
      #expect(message { try make(prompt: "git\u{0}fetch", runner: runner) } != "no error")
      #expect(message { try make(runner: runner).edited(every: nil, prompt: "a\u{0}b", now: now) } != "no error")
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func refusesAHeadlessScheduleWithNoPrompt(_ prompt: String?) {
      #expect(message { try make(prompt: prompt, runner: "headless") } != "no error")
    }

    @Test func aHeadlessScheduleStoresItsAccountAndModel() throws {
      let schedule = try make(runner: "headless", account: "work", model: "haiku")

      #expect(schedule.account == "work")
      #expect(schedule.model == "haiku")
    }

    /// No account means the session's account, and no model means the session's model. sbd resolves both at run time.
    @Test func aHeadlessScheduleWithoutAnAccountOrModelStoresNeither() throws {
      let schedule = try make(runner: "headless")

      #expect(schedule.account == nil)
      #expect(schedule.model == nil)
    }

    // MARK: Account and model only with headless

    @Test(arguments: [nil, "session", "script"] as [String?])
    func refusesAnAccountWithoutHeadless(_ runner: String?) {
      #expect(message { try make(runner: runner, account: "work") } != "no error")
    }

    @Test(arguments: [nil, "session", "script"] as [String?])
    func refusesAModelWithoutHeadless(_ runner: String?) {
      #expect(message { try make(runner: runner, model: "haiku") } != "no error")
    }

    /// The model lands in claude's argv, so a value that reads as an option or splits into two never gets stored.
    @Test(arguments: ["", " ", "a b", "-p", "--dangerously-skip-permissions"])
    func refusesAModelThatModelProblemRefuses(_ model: String) {
      let error = message { try make(runner: "headless", model: model) }

      #expect(Manager.modelProblem(model) != nil)
      #expect(error != "no error")
    }

    // MARK: Gates

    @Test(arguments: ["headless", "script"])
    func refusesAGateWithARunnerOtherThanTheSession(_ runner: String) {
      #expect(message { try make(runner: runner, gate: true) } != "no error")
    }

    @Test func aGateWithTheSessionRunnerIsAccepted() throws {
      #expect(try make(runner: "session", gate: true).gate != nil)
    }

    // MARK: Timeouts

    @Test(arguments: [nil, "session"] as [String?])
    func refusesATimeoutOnASessionSchedule(_ runner: String?) {
      #expect(message { try make(runner: runner, timeout: "5m") } != "no error")
    }

    @Test(arguments: ["headless", "script"])
    func storesTheTimeoutInMilliseconds(_ runner: String) throws {
      #expect(try make(every: "30m", runner: runner, timeout: "5m").timeout == 5 * minute)
    }

    @Test(arguments: ["headless", "script"])
    func noTimeoutStoresNone(_ runner: String) throws {
      #expect(try make(runner: runner).timeout == nil)
    }

    @Test(arguments: ["10s", "11s", "1m", "2h"])
    func acceptsATimeoutFromTenSecondsToTwoHours(_ timeout: String) throws {
      #expect(try make(every: "1d", runner: "script", timeout: timeout).timeout != nil)
    }

    @Test(arguments: ["9s", "1s", "0s", "121m", "3h", "1d"])
    func refusesATimeoutOutsideTenSecondsToTwoHours(_ timeout: String) {
      #expect(message { try make(every: "1w", runner: "script", timeout: timeout) } != "no error")
    }

    @Test(arguments: ["soon", "5", "1m30s", "-5m", " 5m"])
    func refusesATimeoutThatIsNotOneNumberAndOneUnit(_ timeout: String) {
      #expect(message { try make(every: "1d", runner: "script", timeout: timeout) } != "no error")
    }

    /// A run ends before its next due time, so a run never starts right after the one before it.
    @Test(arguments: ["headless", "script"])
    func refusesATimeoutLongerThanTheInterval(_ runner: String) {
      #expect(message { try make(every: "5m", runner: runner, timeout: "6m") } != "no error")
    }

    @Test func acceptsATimeoutEqualToTheInterval() throws {
      #expect(try make(every: "5m", runner: "script", timeout: "5m").timeout == 5 * minute)
    }

    // MARK: Duplicates (Decision 21)

    @Test(
      arguments: [
        (nil, "script"), (nil, "headless"), ("script", "headless"),
      ] as [(String?, String)])
    func theSameTextUnderAnotherRunnerIsNotADuplicate(_ first: String?, _ second: String) throws {
      let existing = try make(id: "r1", prompt: "check the queue", runner: first)
      let schedule = try make(id: "r2", prompt: "check the queue", runner: second)

      #expect(Schedule.duplicate(of: schedule, in: [existing]) == nil)
    }

    @Test func twoScriptsWithTheSameTrimmedCommandAreDuplicates() throws {
      let existing = try make(id: "r1", prompt: "git fetch", runner: "script")
      let schedule = try make(id: "r2", prompt: "  git fetch \n", runner: "script")

      let duplicate = Schedule.duplicate(of: schedule, in: [existing])

      #expect(duplicate?.contains("r1") == true, "\(String(describing: duplicate))")
    }

    @Test func twoHeadlessSchedulesWithTheSamePromptAccountAndModelAreDuplicates() throws {
      let existing = try make(id: "r1", runner: "headless", account: "work", model: "haiku")
      let schedule = try make(id: "r2", runner: "headless", account: "work", model: "haiku")

      #expect(Schedule.duplicate(of: schedule, in: [existing]) != nil)
    }

    @Test(
      arguments: [
        ("work", "haiku", "work", "sonnet"), ("work", "haiku", "personal", "haiku"), (nil, "haiku", "work", "haiku"),
        ("work", nil, "work", "haiku"),
      ] as [(String?, String?, String?, String?)])
    func headlessSchedulesWithAnotherAccountOrModelAreNotDuplicates(
      _ account: String?, _ model: String?, _ otherAccount: String?, _ otherModel: String?
    ) throws {
      let existing = try make(id: "r1", runner: "headless", account: account, model: model)
      let schedule = try make(id: "r2", runner: "headless", account: otherAccount, model: otherModel)

      #expect(Schedule.duplicate(of: schedule, in: [existing]) == nil)
    }

    // MARK: Coding

    @Test func ranIsAnOutcome() throws {
      let run = try JSONCoding.decode(Schedule.Run.self, from: #"{"t": 1, "outcome": "ran", "skipped": 0}"#)

      #expect(run.outcome == .ran)
    }

    @Test func aDetachedRunRoundTripsWithItsExitDurationAndTail() throws {
      var run = Schedule.Run(t: now, outcome: .ran, skipped: 0)
      run.exit = 0
      run.ms = 4200
      run.tail = "Already up to date."

      #expect(try JSONCoding.decode(Schedule.Run.self, from: try JSONCoding.encode(run)) == run)
    }

    @Test func aPastedRunEncodesNoExitDurationOrTail() throws {
      let run = Schedule.Run(t: now, outcome: .pasted, skipped: 0)

      #expect(try keys(run) == ["t", "outcome", "skipped"])
    }

    @Test func aHeadlessScheduleWithEveryFieldRoundTrips() throws {
      var schedule = try make(every: "1h", runner: "headless", account: "work", model: "haiku", timeout: "20m")
      schedule.running = now + minute
      var run = Schedule.Run(t: now, outcome: .failed, skipped: 1, error: "timed out after 20m")
      run.exit = 143
      run.ms = 20 * minute
      schedule.record(run)

      #expect(try JSONCoding.decode(Schedule.self, from: try JSONCoding.encode(schedule)) == schedule)
    }

    @Test func aScheduleRequestWithEveryNewFieldRoundTrips() throws {
      let original = try request(runner: "headless", account: "work", model: "haiku", timeout: "5m")

      #expect(try JSONCoding.decode(ScheduleRequest.self, from: try JSONCoding.encode(original)) == original)
    }

    // MARK: Run text

    @Test func aRanRunReadsAsRanWithItsExitAndTail() {
      var run = Schedule.Run(t: now - 5 * minute, outcome: .ran, skipped: 0)
      run.exit = 0
      run.tail = "Already up to date."

      #expect(run.text(now: now) == "ran 5m ago · exit 0 · Already up to date.")
    }

    @Test func aRanRunKeepsItsSkippedCount() {
      var run = Schedule.Run(t: now - 5 * minute, outcome: .ran, skipped: 2)
      run.exit = 0
      run.tail = "done"

      let text = run.text(now: now)

      #expect(text.hasPrefix("ran 5m ago"), "\(text)")
      #expect(text.contains("2 skipped"), "\(text)")
      #expect(text.contains("exit 0"), "\(text)")
      #expect(text.contains("done"), "\(text)")
    }

    @Test func aFailedRunNamesItsExitStatus() {
      var run = Schedule.Run(t: now - 2 * minute, outcome: .failed, skipped: 0, error: "exited with status 3")
      run.exit = 3

      let text = run.text(now: now)

      #expect(text.hasPrefix("failed 2m ago"), "\(text)")
      #expect(text.contains("exit 3"), "\(text)")
    }

    @Test func aPastedRunReadsAsBefore() {
      let run = Schedule.Run(t: now - 5 * minute, outcome: .pasted, skipped: 2)

      #expect(run.text(now: now) == "pasted 5m ago · 2 skipped")
    }

    @Test func lastTextOfARanScheduleNamesTheRun() throws {
      var schedule = try make(runner: "script")
      var run = Schedule.Run(t: now - 5 * minute, outcome: .ran, skipped: 0)
      run.exit = 0
      run.tail = "fetched"
      schedule.record(run)

      #expect(schedule.lastText(now: now) == "last: ran 5m ago · exit 0 · fetched")
    }

    // MARK: Status

    @Test func aScheduleWhoseLastRunRanIsActive() throws {
      var schedule = try make(runner: "script")
      var run = Schedule.Run(t: now - minute, outcome: .ran, skipped: 0)
      run.exit = 0
      schedule.record(run)

      let status = ScheduleStatus(schedule, hold: nil, now: now)

      #expect(status.state == .active)
      #expect(!status.needsAttention)
    }

    @Test func aDetachedScheduleWhoseLastRunFailedIsFailed() throws {
      var schedule = try make(runner: "headless")
      var run = Schedule.Run(t: now - minute, outcome: .failed, skipped: 0, error: "no quota is left for work")
      run.exit = 1
      schedule.record(run)

      let status = ScheduleStatus(schedule, hold: nil, now: now)

      #expect(status.state == .failed)
      #expect(status.text.contains("no quota is left for work"), "\(status.text)")
    }
  }
}

/// A script schedule made at `now` with a 30m interval and the given stored timeout.
private func script(timeout: String? = nil) throws -> Schedule {
  try make(every: "30m", prompt: "git fetch", runner: "script", timeout: timeout)
}

private func headless(account: String? = "work", model: String? = "haiku") throws -> Schedule {
  try make(every: "30m", runner: "headless", account: account, model: model)
}

extension ScheduleTests {
  /// Decision 23: the runner is fixed, account and model belong to headless schedules, and a timeout to detached ones.
  @Suite struct RunnerEdits {
    @Test func anAccountEditChangesAHeadlessSchedulesAccount() throws {
      #expect(try headless().edited(every: nil, prompt: nil, account: "personal", now: now).account == "personal")
    }

    @Test func aModelEditChangesAHeadlessSchedulesModel() throws {
      #expect(try headless().edited(every: nil, prompt: nil, model: "sonnet", now: now).model == "sonnet")
    }

    @Test func anEmptyAccountResetsItToTheSessions() throws {
      #expect(try headless().edited(every: nil, prompt: nil, account: "", now: now).account == nil)
    }

    @Test func anEmptyModelResetsItToTheSessions() throws {
      #expect(try headless().edited(every: nil, prompt: nil, model: "", now: now).model == nil)
    }

    @Test func anAccountEditLeavesTheModel() throws {
      #expect(try headless().edited(every: nil, prompt: nil, account: "personal", now: now).model == "haiku")
    }

    @Test(arguments: ["a b", "-p"])
    func refusesAModelThatModelProblemRefuses(_ model: String) {
      #expect(message { try headless().edited(every: nil, prompt: nil, model: model, now: now) } != "no error")
    }

    @Test(arguments: [nil, "script"] as [String?])
    func refusesAnAccountEditOfANonHeadlessSchedule(_ runner: String?) throws {
      let schedule = try make(runner: runner)

      #expect(message { try schedule.edited(every: nil, prompt: nil, account: "work", now: now) } != "no error")
    }

    @Test(arguments: [nil, "script"] as [String?])
    func refusesAModelEditOfANonHeadlessSchedule(_ runner: String?) throws {
      let schedule = try make(runner: runner)

      #expect(message { try schedule.edited(every: nil, prompt: nil, model: "haiku", now: now) } != "no error")
    }

    @Test func refusesATimeoutEditOfASessionSchedule() throws {
      let schedule = try make()

      #expect(message { try schedule.edited(every: nil, prompt: nil, timeout: "5m", now: now) } != "no error")
    }

    @Test(arguments: ["headless", "script"])
    func aTimeoutEditChangesTheTimeout(_ runner: String) throws {
      let schedule = try make(every: "30m", runner: runner)

      #expect(try schedule.edited(every: nil, prompt: nil, timeout: "5m", now: now).timeout == 5 * minute)
    }

    @Test(arguments: ["9s", "121m", "31m", "soon"])
    func refusesATimeoutEditThatMakeScheduleRefuses(_ timeout: String) throws {
      let schedule = try script()

      #expect(message { try schedule.edited(every: nil, prompt: nil, timeout: timeout, now: now) } != "no error")
    }

    /// The edit names both values, so the user sees which one to change.
    @Test func refusesAnIntervalShorterThanTheStoredTimeout() throws {
      let schedule = try script(timeout: "10m")

      let error = message { try schedule.edited(every: "5m", prompt: nil, now: now) }

      #expect(error != "no error")
      #expect(error.contains("5m") && error.contains("10m"), "\(error)")
    }

    @Test func anIntervalAndATimeoutThatFitTogetherAreAccepted() throws {
      let schedule = try script(timeout: "10m")

      let after = try schedule.edited(every: "5m", prompt: nil, timeout: "5m", now: now)

      #expect(after.every == 5 * minute)
      #expect(after.timeout == 5 * minute)
    }

    /// The default timeout follows the interval, so only a stored timeout can be too long.
    @Test func aShorterIntervalIsAcceptedWhenNoTimeoutIsStored() throws {
      #expect(try script().edited(every: "5m", prompt: nil, now: now).every == 5 * minute)
    }

    @Test func aCommandEditChangesTheScriptsCommand() throws {
      #expect(try script().edited(every: nil, prompt: " git pull ", now: now).prompt == "git pull")
    }

    @Test(arguments: ["", "   "])
    func refusesAnEmptyCommand(_ command: String) throws {
      let schedule = try script()

      #expect(message { try schedule.edited(every: nil, prompt: command, now: now) } != "no error")
    }

    @Test func anEditKeepsTheRunner() throws {
      #expect(try script().edited(every: "1h", prompt: "git pull", now: now).runner == .script)
    }

    @Test func anEditKeepsTheRunningMark() throws {
      var schedule = try script()
      schedule.running = now - minute

      #expect(try schedule.edited(every: "1h", prompt: nil, now: now).running == now - minute)
    }

    /// An edit of only the account, the model, or the timeout is an edit, not an empty request.
    @Test func anEditOfOnlyTheNewFieldsIsAccepted() throws {
      #expect(try headless().edited(every: nil, prompt: nil, account: "personal", now: now).account == "personal")
      #expect(try script().edited(every: nil, prompt: nil, timeout: "1m", now: now).timeout == minute)
    }

    @Test func anEditOfNothingIsStillRefused() throws {
      #expect(message { try headless().edited(every: nil, prompt: nil, now: now) } != "no error")
    }
  }
}
