import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// A private sbd whose usage reader asks `fake`, with the accounts in the
  /// home and the first one active. The default account is then not listed,
  /// so sbd never reads the user's ~/.claude.
  static func withUsage(_ fake: FakeUsage, accounts: [String] = ["A"]) throws -> Instance {
    let sbd = try Instance(
      accounts: accounts, inheriting: .unset,
      config: ["usage": ["url": .string(fake.url), "pollSeconds": 0, "keychain": false]])
    try sbd.sb("account", "use", accounts[0])
    return sbd
  }

  /// Writes the account's OAuth credentials as claude writes them when it has
  /// no keychain. `file` names refreshed-credentials.json for the stub's
  /// `mcp get` to install.
  func signIn(
    _ account: String, token: String, expiresAt: Int64 = 4_102_444_800_000, file: String = ".credentials.json"
  ) throws {
    let credentials: JSON = [
      "claudeAiOauth": [
        "accessToken": .string(token), "refreshToken": .string("refresh-\(token)"),
        "expiresAt": .number(Double(expiresAt)),
        "scopes": ["user:inference"],
      ]
    ]
    try credentials.text.write(toFile: "\(self.account(account))/\(file)", atomically: true, encoding: .utf8)
  }

  /// Runs `sb usage --json`, which reads every account first.
  func usage() throws -> [AccountUsage] {
    try JSONCoding.decode([AccountUsage].self, from: try sb("usage", "--json"))
  }

  func usage(of account: String) throws -> AccountUsage {
    let folder = self.account(account)
    return try #require(try usage().first { $0.folder == folder })
  }

  /// The runs of the stub claude that asked it to refresh a token.
  func refreshCalls() -> [(account: String, agent: String, args: String)] {
    stubCalls().filter { $0.args.hasPrefix("mcp get") }
  }
}

@Suite(.timeLimit(.minutes(2))) struct UsageTests {
  @Test func reportsTheLimitsThatTheEndpointAnswers() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")
    try #"{"oauthAccount":{"emailAddress":"a@example.com"}}"#.write(
      toFile: "\(sbd.account("A"))/.claude.json", atomically: true, encoding: .utf8)

    let a = try sbd.usage(of: "A")

    #expect(a.error == nil)
    #expect(a.email == "a@example.com")
    #expect(a.limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
    #expect(a.limits.map(\.label) == ["Session (5h)", "Week (all models)", "Week (Fable)"])
    #expect(a.limits.map(\.percent) == [47, 20, 0])
    #expect(a.checked != nil)
  }

  @Test func sendsTheAccountsTokenAsABearerWithTheOAuthBetaHeader() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")

    _ = try sbd.usage(of: "A")

    #expect(fake.requests.map(\.method) == ["GET"])
    #expect(fake.requests.map(\.path) == ["/api/oauth/usage"])
    #expect(fake.requests.map(\.authorization) == ["Bearer token-a"])
    #expect(fake.requests.map(\.beta) == ["oauth-2025-04-20"])
  }

  @Test func eachAccountReadsWithItsOwnToken() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("A", token: "token-a")
    try sbd.signIn("B", token: "token-b")
    fake.reply(to: "token-b", try FakeUsage.recorded("weekly-spent"))

    let readings = try sbd.usage()

    let a = try #require(readings.first { $0.folder == sbd.account("A") })
    let b = try #require(readings.first { $0.folder == sbd.account("B") })
    #expect(a.limits.map(\.percent) == [47, 20, 0])
    #expect(b.limits.map(\.percent) == [0, 100, 0])
    #expect(Set(fake.requests.compactMap(\.authorization)) == ["Bearer token-a", "Bearer token-b"])
  }

  @Test func theTokenNeverAppearsInAStubArgument() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "stale-token", expiresAt: 1)
    try sbd.signIn("A", token: "fresh-token", file: "refreshed-credentials.json")

    _ = try sbd.usage(of: "A")

    #expect(!sbd.stubCalls().contains { $0.args.contains("stale-token") || $0.args.contains("fresh-token") })
  }

  /// The app reads the op without a refresh, so only the timer fills what it sees.
  @Test func theTimerFillsTheReadingsThatTheAppReads() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")
    let unread = try sbd.client.usage()
    #expect(unread.map(\.folder) == [sbd.account("A")])
    #expect(unread.first?.limits == [])
    #expect(fake.requests.isEmpty)

    // sbd lists Claude's default account until `account use` runs, so the timer starts only after a restart.
    try sbd.restart(setting: "usage", to: ["url": .string(fake.url), "pollSeconds": 1, "keychain": false])

    try sbd.waitFor("the timer's read") { try sbd.client.usage().first?.limits.map(\.percent) == [47, 20, 0] }
  }

  // MARK: Failures

  @Test func anAccountWithNoCredentialsIsNotSignedIn() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)

    let a = try sbd.usage(of: "A")

    #expect(a.error?.contains("not signed in") == true)
    #expect(a.limits.isEmpty)
    #expect(fake.requests.isEmpty)
  }

  @Test(arguments: [
    #"{"claudeAiOauth":{"expiresAt":4102444800000}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#, "not json", "",
  ])
  func credentialsWithoutATokenSendNoRequest(_ text: String) throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try text.write(toFile: "\(sbd.account("A"))/.credentials.json", atomically: true, encoding: .utf8)

    let a = try sbd.usage(of: "A")

    #expect(a.error != nil)
    #expect(fake.requests.isEmpty)
  }

  @Test func anHTTPErrorReportsTheStatus() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")
    fake.reply(#"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}"#, status: 429)

    let a = try sbd.usage(of: "A")

    #expect(a.error?.contains("429") == true)
  }

  @Test func aFailedReadKeepsTheLimitsOfTheReadBeforeIt() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")
    let before = try sbd.usage(of: "A")
    #expect(before.limits.map(\.percent) == [47, 20, 0])
    fake.reply("", status: 500)

    let after = try sbd.usage(of: "A")

    #expect(after.error?.contains("500") == true)
    #expect(after.limits == before.limits)
  }

  @Test func aReadAfterAFailureClearsTheError() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")
    fake.reply("", status: 429)
    _ = try sbd.usage(of: "A")
    fake.reply(try FakeUsage.recorded("weekly-spent"))

    let a = try sbd.usage(of: "A")

    #expect(a.error == nil)
    #expect(a.limits.map(\.percent) == [0, 100, 0])
  }

  @Test func theTextOutputMarksAnAccountThatFailed() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)

    let out = try sbd.sb("usage")

    #expect(out.contains("✗"))
    #expect(out.contains("not signed in"))
  }

  // MARK: Token refresh

  @Test func anExpiredTokenIsRefreshedThroughClaudeUnderTheAccount() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "stale-token", expiresAt: 1)
    try sbd.signIn("A", token: "fresh-token", file: "refreshed-credentials.json")

    let a = try sbd.usage(of: "A")

    #expect(sbd.refreshCalls().map(\.account) == [sbd.account("A")])
    #expect(fake.requests.map(\.authorization) == ["Bearer fresh-token"])
    #expect(a.error == nil)
    #expect(a.limits.map(\.percent) == [47, 20, 0])
  }

  @Test func anExpiredTokenThatClaudeCannotRefreshSendsNoRequest() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "stale-token", expiresAt: 1)

    let a = try sbd.usage(of: "A")

    #expect(sbd.refreshCalls().count == 1)
    #expect(fake.requests.isEmpty)
    #expect(a.error?.contains("could not refresh") == true)
    #expect(a.limits.isEmpty)
  }

  /// sbd refreshes a token that expires within 60 s, so the request can't
  /// arrive with a token that expired on the way.
  @Test func aTokenThatExpiresWithinAMinuteIsRefreshed() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "stale-token", expiresAt: nowMs() + 30_000)
    try sbd.signIn("A", token: "fresh-token", file: "refreshed-credentials.json")

    _ = try sbd.usage(of: "A")

    #expect(sbd.refreshCalls().count == 1)
    #expect(fake.requests.map(\.authorization) == ["Bearer fresh-token"])
  }

  @Test func aTokenThatLastsLongerIsSentWithoutARefresh() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a", expiresAt: nowMs() + 600_000)
    try sbd.signIn("A", token: "fresh-token", file: "refreshed-credentials.json")

    _ = try sbd.usage(of: "A")

    #expect(sbd.refreshCalls().isEmpty)
    #expect(fake.requests.map(\.authorization) == ["Bearer token-a"])
  }
}
