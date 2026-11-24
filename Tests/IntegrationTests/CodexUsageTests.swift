import Foundation
import SwitchboardCore
import Testing

/// `sb usage` for Codex accounts: limits from the newest rollout with
/// `"source": "rollout"`, "no reading" without one, and sign-in from `codex
/// login status`. Claude readings keep their keys and gain only `agent`.
@Suite(.blocking(timeLimit: .seconds(120))) struct CodexUsageTests {
  /// A sbd with the Claude account A, active and signed in, and the Codex
  /// account `.codex-work`. Its usage reader asks `fake` for A.
  func instance(_ fake: FakeUsage) throws -> Instance {
    let sbd = try Instance(
      accounts: ["A"], codexAccounts: [".codex-work"], inheriting: .unset,
      config: ["usage": ["url": .string(fake.url), "pollSeconds": 0, "keychain": false]])
    try sbd.sb("account", "use", "A")
    try sbd.signIn("A", token: "token-a")
    return sbd
  }

  @Test func aCodexAccountReportsTheLimitsOfItsNewestRollout() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")
    try sbd.writeCodexRollout(folder)

    let row = try sbd.row(try sbd.usageRows(), folder)
    let reading = try JSONCoding.convert(row, to: AccountUsage.self)

    #expect(row["agent"]?.string == "codex")
    #expect(row["source"]?.string == "rollout")
    #expect(reading.name == "codex-work")
    #expect(reading.limits.map(\.kind) == ["session", "weekly_all"])
    #expect(reading.limits.map(\.percent) == [12.5, 34])
    #expect(reading.limits.map(\.resetsAt) == [1_735_805_045_000, 1_736_305_445_000])
    #expect(reading.error == nil)
    #expect(reading.signedOut != true)
  }

  /// `checked` is the time Codex reported the limits, not the time sbd read the file.
  @Test func aCodexReadingIsCheckedAtTheTimeCodexReportedIt() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")
    try sbd.writeCodexRollout(folder)

    let reading = try JSONCoding.convert(try sbd.row(try sbd.usageRows(), folder), to: AccountUsage.self)

    #expect(reading.checked == Instance.codexRolloutAt)
  }

  @Test func theTextOutputShowsTheCodexLimits() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    try sbd.writeCodexRollout(sbd.account(".codex-work"))

    let blocks = try sbd.sb("usage").components(separatedBy: "\n\n")

    let block = try #require(blocks.first { $0.contains(sbd.account(".codex-work")) }, "\(blocks)")
    #expect(block.contains("5-hour"), "\(block)")
    #expect(block.contains("Weekly"), "\(block)")
    #expect(block.contains("13%") || block.contains("12%"), "\(block)")
    #expect(block.contains("34%"), "\(block)")
    #expect(block.contains("reported "), "\(block)")
  }

  /// Without a rollout, sbd shows no number. A missing rollout is not a sign-out.
  @Test func aCodexAccountWithoutARolloutSaysNoLimitsSeenYet() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")

    let row = try sbd.row(try sbd.usageRows(), folder)
    let text = try sbd.sb("usage")

    #expect(row["agent"]?.string == "codex")
    #expect(row["limits"]?.array?.isEmpty == true)
    #expect(row["signedOut"]?.bool != true)
    let block = try #require(text.components(separatedBy: "\n\n").first { $0.contains(folder) }, "\(text)")
    #expect(block.contains("no Codex limits seen yet"), "\(block)")
  }

  /// A keyring login leaves no auth.json, so only `codex login status` decides.
  @Test func aCodexAccountWithoutAuthJsonIsSignedInWhenCodexSaysSo() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")
    try sbd.writeCodexRollout(folder)
    #expect(!FileManager.default.fileExists(atPath: "\(folder)/auth.json"))

    let reading = try JSONCoding.convert(try sbd.row(try sbd.usageRows(), folder), to: AccountUsage.self)

    #expect(reading.signedOut != true)
    #expect(reading.error == nil)
  }

  /// The stub exits 1 for `login status`. An auth.json doesn't overrule it.
  @Test func aCodexAccountThatCodexReportsSignedOutIsSignedOut() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")
    FileManager.default.createFile(atPath: "\(folder)/auth.json", contents: Data("{}".utf8))
    sbd.signOutOfCodex(folder)

    let reading = try JSONCoding.convert(try sbd.row(try sbd.usageRows(), folder), to: AccountUsage.self)

    #expect(reading.signedOut == true)
    #expect(reading.error?.contains("codex login") == true, "\(reading.error ?? "nil")")
    #expect(reading.error?.contains("/login") == false, "\(reading.error ?? "nil")")
  }

  /// A `codex login status` that never answers costs the read 10 s and records an error, not a sign-out.
  @Test func aCodexLoginStatusThatHangsTimesOutWithAnError() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")
    FileManager.default.createFile(atPath: "\(folder)/stub-slow", contents: nil)
    let started = Date()

    let reading = try JSONCoding.convert(try sbd.row(try sbd.usageRows(), folder), to: AccountUsage.self)

    #expect(Date().timeIntervalSince(started) < 25)
    #expect(reading.error?.contains("did not answer") == true, "\(reading.error ?? "nil")")
    #expect(reading.signedOut != true)
  }

  @Test func theUsageReadRunsCodexLoginStatusUnderTheAccount() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")

    _ = try sbd.usageRows()

    #expect(sbd.codexCalls().contains { $0.home == folder && $0.args == "login status" }, "\(sbd.codexCalls())")
    let logins = sbd.codexCalls().filter { $0.args.hasPrefix("login") && $0.args != "login status" }
    #expect(logins.isEmpty, "\(logins)")
  }

  /// A Codex account sends no OAuth request and never runs claude, which would
  /// write Claude files into the Codex folder.
  @Test func aCodexReadingUsesNeitherTheOAuthEndpointNorClaude() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")
    try sbd.writeCodexRollout(folder)
    let before = [folder: sbd.tree(folder)]

    _ = try sbd.usageRows()

    #expect(fake.requests.map(\.authorization) == ["Bearer token-a"])
    sbd.expectClaudeNeverRan(in: [folder], before: before)
  }

  // MARK: Parity for Claude accounts

  /// A Claude reading keeps every key it had and gains only `agent`.
  @Test func aClaudeReadingGainsOnlyTheAgentKey() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)

    let row = try sbd.row(try sbd.usageRows(), sbd.account("A"))
    let reading = try JSONCoding.convert(row, to: AccountUsage.self)

    #expect(Set(row.object?.keys.map { $0 } ?? []) == ["name", "folder", "limits", "checked", "agent"])
    #expect(row["agent"]?.string == "claude")
    #expect(row["source"] == nil)
    #expect(reading.limits.map(\.percent) == [47, 20, 0])
    #expect(reading.limits.map(\.label) == ["Session (5h)", "Week (all models)", "Week (Fable)"])
  }

  /// The Claude block of the text output reads as it did before Codex
  /// accounts. Its first line also names the agent, so the test checks only
  /// that line's start and end.
  @Test func theClaudeTextBlockIsUnchanged() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)

    let blocks = try sbd.sb("usage").components(separatedBy: "\n\n")

    let block = try #require(blocks.first { $0.contains(sbd.account("A")) }, "\(blocks)")
    let lines = block.split(separator: "\n").map(String.init)
    #expect(lines.first?.hasPrefix("A · ") == true, "\(lines)")
    #expect(lines.first?.hasSuffix(sbd.account("A")) == true, "\(lines)")
    #expect(
      lines.dropFirst().map { $0.prefix(26) } == [
        "  Session (5h)         47%", "  Week (all models)    20%", "  Week (Fable)          0%",
      ])
  }

  /// The timer reads Codex accounts too, so the app sees their readings.
  @Test func theTimerReadsTheCodexAccount() throws {
    let fake = try FakeUsage()
    let sbd = try instance(fake)
    let folder = sbd.account(".codex-work")
    try sbd.writeCodexRollout(folder)

    try sbd.restart(setting: "usage", to: ["url": .string(fake.url), "pollSeconds": 1, "keychain": false])

    try sbd.waitFor("the timer's Codex reading") {
      try sbd.client.usage().first { $0.folder == folder }?.limits.map(\.percent) == [12.5, 34]
    }
  }
}
