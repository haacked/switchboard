import CryptoKit
import Foundation
import Testing

@testable import SwitchboardCore

/// A response from https://api.anthropic.com/api/oauth/usage. legacy.json
/// holds only the older `five_hour` and `seven_day` fields. The others were
/// recorded on 2026-11-03.
func usageFixture(_ name: String) throws -> Data {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/usage")
  return try Data(contentsOf: dir.appendingPathComponent("\(name).json"))
}

func parsedUsage(_ name: String) throws -> [UsageLimit] { try Usage.parse(usageFixture(name)) }

@Suite struct UsageParseTests {
  @Test func aResponseWithASessionWindowListsEachLimit() throws {
    let limits = try parsedUsage("with-session")

    #expect(limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
    #expect(limits.map(\.label) == ["Session (5h)", "Week (all models)", "Week (Fable)"])
    #expect(limits.map(\.percent) == [47, 20, 0])
    #expect(limits.map(\.severity) == ["normal", "normal", "normal"])
  }

  @Test func resetTimesDropTheEndpointsMicroseconds() throws {
    let limits = try parsedUsage("with-session")

    #expect(
      limits.map(\.resetsAt) == [
        ms("2026-11-03T20:10:00.743Z"), ms("2026-11-07T11:00:00.743Z"), ms("2026-11-07T11:00:00.000Z"),
      ])
  }

  @Test func aResponseWithoutASessionWindowGetsAnUnusedSessionFirst() throws {
    let limits = try parsedUsage("no-session")

    #expect(limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
    #expect(limits.map(\.label) == ["Session (5h)", "Week (all models)", "Week (Fable)"])
    #expect(limits.map(\.percent) == [0, 75, 0])
    #expect(limits.map(\.resetsAt) == [nil, ms("2026-11-04T19:59:59.752Z"), ms("2026-11-04T20:00:00.000Z")])
  }

  @Test func aSpentWeekReportsOneHundredPercent() throws {
    let limits = try parsedUsage("weekly-spent")

    #expect(limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
    #expect(limits.map(\.percent) == [0, 100, 0])
    #expect(limits.map(\.resetsAt) == [nil, ms("2026-11-03T23:59:59.769Z"), ms("2026-11-04T00:00:00.000Z")])
    #expect(limits.first { $0.kind == "weekly_all" }?.severity == "critical")
  }

  @Test func aLegacyResponseReadsTheFiveHourAndSevenDayFields() throws {
    let limits = try parsedUsage("legacy")

    #expect(limits.map(\.kind) == ["session", "weekly_all"])
    #expect(limits.map(\.label) == ["Session (5h)", "Week (all models)"])
    #expect(limits.map(\.percent) == [47, 20])
    #expect(limits.map(\.resetsAt) == [ms("2026-11-03T20:10:00.743Z"), ms("2026-11-07T11:00:00.743Z")])
  }

  @Test func aLegacyResponseWithNoFiveHourWindowGetsAnUnusedSession() throws {
    let data = Data(
      #"{"five_hour": null, "seven_day": {"utilization": 75.0, "resets_at": "2026-11-04T19:59:59.752373+00:00"}}"#.utf8)

    let limits = try Usage.parse(data)

    #expect(limits.map(\.kind) == ["session", "weekly_all"])
    #expect(limits.map(\.percent) == [0, 75])
    #expect(limits.map(\.resetsAt) == [nil, ms("2026-11-04T19:59:59.752Z")])
  }

  /// with-session.json and legacy.json carry the same five_hour and
  /// seven_day numbers, so both fields must read the same session and week.
  @Test func theLimitsListAndTheLegacyFieldsReadTheSameSessionAndWeek() throws {
    func comparable(_ limits: [UsageLimit]) -> [String] {
      limits.filter { $0.kind != "weekly_scoped" }.map {
        "\($0.kind)|\($0.label)|\($0.percent)|\($0.resetsAt.map { "\($0)" } ?? "nil")"
      }
    }

    #expect(try comparable(parsedUsage("with-session")) == comparable(parsedUsage("legacy")))
  }

  @Test(arguments: ["not json", "<html><body>502 Bad Gateway</body></html>", ""])
  func aBodyThatIsNotJSONThrows(_ body: String) {
    #expect(throws: (any Error).self) { try Usage.parse(Data(body.utf8)) }
  }
}

@Suite struct UsageCredentialsTests {
  @Test func readsTheAccessTokenAndExpiry() throws {
    let data = Data(
      #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
        .utf8)

    let credentials = try #require(Usage.credentials(from: data))

    #expect(credentials.token == "sk-ant-oat01-abc")
    #expect(credentials.expiresAt == 4_102_444_800_000)
  }

  /// `security find-generic-password -w` ends its output with a newline.
  @Test func readsTheKeychainsOutputWithItsTrailingNewline() throws {
    let data = Data("{\"claudeAiOauth\":{\"accessToken\":\"tok\",\"expiresAt\":4102444800000}}\n".utf8)

    #expect(Usage.credentials(from: data)?.token == "tok")
  }

  @Test(arguments: [
    #"{"claudeAiOauth":{"expiresAt":4102444800000}}"#,
    #"{"claudeAiOauth":{"accessToken":"","expiresAt":4102444800000}}"#,
    #"{"claudeAiOauth":{"accessToken":null,"expiresAt":4102444800000}}"#,
    #"{"claudeAiOauth":{"accessToken":42,"expiresAt":4102444800000}}"#,
    #"{"claudeAiOauth":null}"#,
    #"{"mcpOAuth":{"accessToken":"tok"}}"#,
    #"{}"#,
  ])
  func credentialsWithoutAnAccessTokenReadAsNone(_ text: String) {
    #expect(Usage.credentials(from: Data(text.utf8)) == nil)
  }

  @Test(arguments: ["", "not json", #"{"claudeAiOauth":{"accessToken":"tok""#, "[]"])
  func malformedCredentialsReadAsNone(_ text: String) {
    #expect(Usage.credentials(from: Data(text.utf8)) == nil)
  }
}

@Suite struct UsageKeychainServiceTests {
  func service(hashing path: String) -> String {
    let hex = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-\(hex.prefix(8))"
  }

  @Test(arguments: ["~/.claude", "~/.claude/", ClaudeAccount.defaultFolder, "\(NSHomeDirectory())/./.claude"])
  func theDefaultAccountUsesTheServiceWithoutASuffix(_ folder: String) {
    #expect(ClaudeAccount.keychainService(folder) == "Claude Code-credentials")
  }

  /// sha256("/Users/someone/.claude-work") starts with 18cc900a.
  @Test func anotherAccountAddsTheFirstEightHexDigitsOfTheFoldersSHA256() {
    #expect(ClaudeAccount.keychainService("/Users/someone/.claude-work") == "Claude Code-credentials-18cc900a")
  }

  /// Switchboard sets CLAUDE_CONFIG_DIR to the normalized folder, so claude
  /// hashes that string, whatever form the config names the folder in.
  @Test(arguments: [
    "/Users/someone/.claude-work/", "/Users/someone/./.claude-work", "/Users/someone/x/../.claude-work",
  ])
  func theHashUsesTheNormalizedFolder(_ folder: String) {
    #expect(ClaudeAccount.keychainService(folder) == "Claude Code-credentials-18cc900a")
  }

  @Test func aTildeFolderHashesTheExpandedPath() {
    #expect(
      ClaudeAccount.keychainService("~/.claude-work") == service(hashing: "\(NSHomeDirectory())/.claude-work"))
  }

  /// Only Claude's default account runs with CLAUDE_CONFIG_DIR unset. A
  /// folder named .claude in another place is another account.
  @Test(arguments: ["/tmp/.claude", "\(NSHomeDirectory())/.claude-default", "\(NSHomeDirectory())/other/.claude"])
  func aFolderThatOnlyLooksLikeTheDefaultGetsASuffix(_ folder: String) {
    #expect(ClaudeAccount.keychainService(folder) == service(hashing: ClaudeAccount.normalize(folder)))
  }
}

@Suite struct UsageBudgetTests {
  func reading(_ limits: [UsageLimit], error: String? = nil) -> AccountUsage {
    AccountUsage(name: "A", folder: "/tmp/A", email: nil, limits: limits, checked: 1, error: error)
  }

  func limit(_ kind: String, _ percent: Double, resetsAt: Int64?) -> UsageLimit {
    UsageLimit(kind: kind, label: kind, percent: percent, resetsAt: resetsAt, severity: nil)
  }

  @Test func limitsUnderOneHundredPercentLeaveBudget() throws {
    #expect(reading(try parsedUsage("with-session")).budget(now: 0) == .left)
  }

  @Test func aSpentWeekIsSpentUntilItResets() throws {
    #expect(
      reading(try parsedUsage("weekly-spent")).budget(now: 0) == .spent(resetsAt: ms("2026-11-03T23:59:59.769Z")))
  }

  @Test func aLimitAtTheThresholdCountsAsSpent() throws {
    #expect(
      reading(try parsedUsage("with-session")).budget(limit: 47, now: 0)
        == .spent(resetsAt: ms("2026-11-03T20:10:00.743Z")))
  }

  @Test func aLimitJustUnderTheThresholdLeavesBudget() throws {
    #expect(reading(try parsedUsage("with-session")).budget(limit: 47.5, now: 0) == .left)
  }

  @Test func aLimitIsSpentUntilItsResetPasses() {
    let session = limit("session", 100, resetsAt: 10)
    #expect(session.isSpent(now: 0))
    #expect(!session.isSpent(now: 10))
    #expect(limit("weekly_all", 100, resetsAt: nil).isSpent(now: .max - 1))
    #expect(!limit("weekly_all", 99.9, resetsAt: 10).isSpent(now: 0))
  }

  /// Every spent limit must reset before the account has budget again.
  @Test func severalSpentLimitsWaitForTheLatestReset() {
    let limits = [
      limit("session", 100, resetsAt: 3_000), limit("weekly_all", 100, resetsAt: 9_000),
      limit("weekly_scoped", 100, resetsAt: 5_000),
    ]

    #expect(reading(limits).budget(now: 0) == .spent(resetsAt: 9_000))
  }

  @Test func aLaterResetOfALimitWithRoomDoesNotCount() {
    let limits = [limit("session", 100, resetsAt: 3_000), limit("weekly_all", 50, resetsAt: 9_000)]

    #expect(reading(limits).budget(now: 0) == .spent(resetsAt: 3_000))
  }

  @Test func aLimitOverOneHundredPercentIsSpent() {
    #expect(reading([limit("weekly_all", 104, resetsAt: 9_000)]).budget(now: 0) == .spent(resetsAt: 9_000))
  }

  @Test func aSpentLimitWithNoResetTimeIsSpentWithNoReset() {
    #expect(reading([limit("weekly_all", 100, resetsAt: nil)]).budget(now: 0) == .spent(resetsAt: nil))
  }

  @Test func aFailedReadingWithNoLimitsIsUnknown() {
    let budget = reading([], error: "not signed in").budget(now: 0)

    guard case .unknown(let reason) = budget else {
      Issue.record("budget is \(budget)")
      return
    }
    #expect(reason.contains("not signed in"))
  }

  /// A failure keeps the previous limits, so the budget still reads from them.
  @Test func aFailedReadingThatKeptItsLimitsUsesThem() throws {
    let spent = reading(try parsedUsage("weekly-spent"), error: "the usage endpoint answered 429")
    let left = reading(try parsedUsage("with-session"), error: "the usage endpoint answered 429")

    #expect(spent.budget(now: 0) == .spent(resetsAt: ms("2026-11-03T23:59:59.769Z")))
    #expect(left.budget(now: 0) == .left)
  }

  /// A reading can be older than the reset of a limit it saw spent.
  @Test func aSpentLimitWhoseResetHasPassedLeavesBudget() {
    let limits = [limit("session", 100, resetsAt: 3_000), limit("weekly_all", 100, resetsAt: 9_000)]

    #expect(reading(limits).budget(now: 3_000) == .spent(resetsAt: 9_000))
    #expect(reading(limits).budget(now: 9_000) == .left)
  }
}

@Suite struct UsageUntilTests {
  @Test(arguments: [
    (Int64(-5_000), "now"), (59_000, "now"), (60_000, "in 1m"), (300_000, "in 5m"),
    (3_600_000, "in 1h 0m"), (3 * 86_400_000 + 4 * 3_600_000, "in 3d 4h"),
  ])
  func untilNamesTheWaitInTheLargestUnits(_ ms: Int64, _ text: String) {
    #expect(Usage.until(ms, now: 0) == text)
  }
}

@Suite struct UsageSettingsTests {
  @Test func defaultsReadTheRealEndpointEveryFiveMinutesFromTheKeychain() {
    let settings = UsageSettings()

    #expect(settings.url == "https://api.anthropic.com/api/oauth/usage")
    #expect(settings.pollSeconds == 300)
    #expect(settings.keychain == true)
  }

  @Test func aPartialObjectKeepsTheOtherDefaults() throws {
    let settings = try JSONCoding.decode(UsageSettings.self, from: #"{"pollSeconds": 0}"#)

    #expect(settings.pollSeconds == 0)
    #expect(settings.url == UsageSettings().url)
    #expect(settings.keychain == true)
  }

  @Test func theConfigReadsItsUsageObject() throws {
    let config = try JSONCoding.decode(
      Config.self, from: #"{"usage": {"url": "http://127.0.0.1:9/u", "pollSeconds": 0, "keychain": false}}"#)

    #expect(config.usage.url == "http://127.0.0.1:9/u")
    #expect(config.usage.pollSeconds == 0)
    #expect(config.usage.keychain == false)
  }
}
