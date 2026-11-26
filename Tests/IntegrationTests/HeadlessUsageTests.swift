import Foundation
import SwitchboardCore
import Testing

/// The counts that the stub's `claude -p` envelope reports for every call.
let stubUsage = HeadlessUsage(input: 100, output: 20, cacheRead: 300, cacheWrite: 40)

extension Instance {
  /// The rows of `sb usage headless --json`.
  func headlessUsageRows() throws -> [JSON] {
    let report = try #require(JSON.parse(try sb("usage", "headless", "--json")))
    return report["rows"]?.array ?? []
  }

  /// The row of `sb usage headless --json` for the kind, once one exists.
  func waitForHeadlessUsageRow(_ kind: String, calls: Int) throws -> JSON {
    var found: JSON?
    try waitFor("the \(kind) row of sb usage headless") {
      found = try headlessUsageRows().first { $0["kind"]?.string == kind && $0["calls"]?.int == calls }
      return found != nil
    }
    return found!
  }

  /// The session's events as `sb events --json` prints them, one JSON object a line.
  fileprivate func eventsFromCLI(_ id: String) throws -> [Event] {
    try sb("events", "--json", "--session", id).split(separator: "\n").map {
      try JSONCoding.decode(Event.self, from: String($0))
    }
  }
}

/// The usage of a JSON value that encodes a `HeadlessUsage`, or nil.
func headlessUsage(_ json: JSON?) -> HeadlessUsage? {
  json.flatMap { try? JSONCoding.decode(HeadlessUsage.self, from: $0.text) }
}

/// sbd records the model and the tokens of each one-shot `claude -p` call, and `sb usage headless` sums them by day
/// and kind.
@Suite(.blocking(timeLimit: .seconds(180))) struct HeadlessUsageTests {
  /// The triage model is haiku by default, and the stub names the model that the call asked for.
  @Test func aTriageSummaryRecordsItsUsageAndModelOnTheEventAndInTheReport() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "ask", name: "review-code")
    try sbd.waitForTriageEvent(s.id)

    let event = try #require(try sbd.eventsFromCLI(s.id).last { $0.kind == "triage" })

    #expect(headlessUsage(event.data["usage"]) == stubUsage)
    #expect(event.data["model"]?.string == "haiku")
    let row = try sbd.waitForHeadlessUsageRow("triage", calls: 1)
    #expect(headlessUsage(row["usage"]) == stubUsage)
    #expect(row["models"]?.array?.compactMap(\.string) == ["haiku"])
  }

  /// A failed ask has no envelope, so it adds a call and an error but no tokens and no model.
  @Test func quickAsksAreRecordedWithTheirErrorsAndSummed() throws {
    let sbd = try Instance(config: ["triage": ["systemPrompt": "", "enabled": false]])
    try sbd.sb("ask", "what needs me?")
    _ = try sbd.run(["ask", "FAIL-ASK"])

    let row = try sbd.waitForHeadlessUsageRow("quickAsk", calls: 2)

    #expect(row["errors"]?.int == 1)
    #expect(headlessUsage(row["usage"]) == stubUsage)
    #expect(row["models"]?.array?.compactMap(\.string) == ["sonnet"])
  }

  /// claude exits 1 after an error envelope, which still reports the tokens that the call spent.
  @Test func anAskThatEndsInAnErrorEnvelopeRecordsItsTokens() throws {
    let sbd = try Instance(config: ["triage": ["systemPrompt": "", "enabled": false]])
    _ = try sbd.run(["ask", "ERROR-ASK"])

    let row = try sbd.waitForHeadlessUsageRow("quickAsk", calls: 1)

    #expect(row["errors"]?.int == 1)
    #expect(headlessUsage(row["usage"]) == stubUsage)
    #expect(row["models"]?.array?.compactMap(\.string) == ["sonnet"])
  }

  /// Decision 18: each headless schedule run adds a `schedule` row with the run's model and tokens.
  @Test func aHeadlessScheduleRunRecordsAScheduleRowWithItsModelAndTokens() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let headless = ScheduleHeadlessTests()
    let made = try headless.addHeadless(sbd, s.id, model: "haiku")

    let last = try headless.runNow(sbd, s.id, made.id)

    #expect(last.outcome == .ran, "\(last)")
    let row = try sbd.waitForHeadlessUsageRow("schedule", calls: 1)
    #expect(headlessUsage(row["usage"]) == stubUsage)
    #expect(row["models"]?.array?.compactMap(\.string) == ["haiku"])
    #expect(row["errors"]?.int == 0)
  }

  /// An error envelope still reports the tokens that the run spent, and the row counts the error.
  @Test func aHeadlessScheduleRunThatFailsRecordsItsTokensAndItsError() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let headless = ScheduleHeadlessTests()
    let made = try headless.addHeadless(sbd, s.id, "ERROR-SCHEDULE", model: "haiku")

    try headless.runNow(sbd, s.id, made.id)

    let row = try sbd.waitForHeadlessUsageRow("schedule", calls: 1)
    #expect(row["errors"]?.int == 1)
    #expect(headlessUsage(row["usage"]) == stubUsage)
  }

  /// A question refused before launch starts no `claude`, so it records no call. Store writes run one at a time on
  /// the state queue, so a row for the refusal would be in place before the ask's row. The text form prints one
  /// line for each day and kind. The date's three numbers come first, and the counts follow in column order.
  @Test func usageHeadlessPrintsALineWithTheKindAndItsTokensAndSkipsARefusedAsk() throws {
    let sbd = try Instance(config: ["triage": ["systemPrompt": "", "enabled": false]])
    #expect(throws: APIError.self) { try sbd.client.call("quick-ask", ["question": ""]) }
    try sbd.sb("ask", "what needs me?")
    var row: JSON?
    try sbd.waitFor("the quickAsk row with the ask's tokens") {
      row = try sbd.headlessUsageRows().first { $0["kind"]?.string == "quickAsk" && $0["usage"]?["input"]?.int == 100 }
      return row != nil
    }

    let out = try sbd.sb("usage", "headless", "--since", "1d")

    #expect(row?["calls"]?.int == 1)
    let line = try #require(out.split(separator: "\n").first { $0.contains("quickAsk") })
    let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    #expect(Array(numbers.dropFirst(3).prefix(6)) == [1, 0, 100, 20, 300, 40], "\(line)")
  }
}
