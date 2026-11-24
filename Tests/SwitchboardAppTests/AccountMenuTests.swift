import AppKit
import SwitchboardCore
import Testing
import os

@testable import SwitchboardApp

@Suite struct AccountMenuText {
  let limits = [
    UsageLimit(kind: "session", label: "Session (5h)", percent: 52.4, resetsAt: 7_200_000 + 300_000),
    UsageLimit(kind: "weekly_all", label: "Week (all models)", percent: 21),
    UsageLimit(kind: "weekly_scoped", label: "Week (Fable)", percent: 63.6),
  ]

  func row(_ reading: AccountUsage?, active: Bool = true, sessions: Int = 11) -> AccountRow {
    AccountRow(
      account: AccountInfo(name: "automation", folder: "/a", active: active, sessions: sessions), usage: reading)
  }

  @Test func theLabelNamesTheAccountWithItsSessionAndHighestWeeklyPercent() {
    let reading = AccountUsage(name: "automation", folder: "/a", limits: limits)
    #expect(AccountMenu.label(row(reading)) == "automation · 5h 52% · wk 64%")
  }

  @Test func theLabelIsTheAccountNameWithoutAReading() {
    #expect(AccountMenu.label(row(nil)) == "automation")
    #expect(
      AccountMenu.label(row(AccountUsage(name: "automation", folder: "/a", error: "not signed in"))) == "automation")
  }

  @Test func theLabelSaysAccountBeforeTheAccountsAreRead() {
    #expect(AccountMenu.label(nil) == "Account")
  }

  @Test func theTooltipStartsWithTheLabel() {
    let reading = AccountUsage(name: "automation", folder: "/a", limits: limits)
    #expect(
      AccountMenu.help(row(reading)).hasPrefix("automation · 5h 52% · wk 64%. The Claude account for new sessions"))
    #expect(AccountMenu.help(nil).hasPrefix("Account. "))
  }

  @Test func theSummarySaysWhyTheAccountNeedsTheUser() {
    let spent = row(
      AccountUsage(name: "a", folder: "/a", limits: [UsageLimit(kind: "session", label: "Session (5h)", percent: 100)]))
    let failed = row(AccountUsage(name: "a", folder: "/a", error: "timed out"))
    let healthy = row(AccountUsage(name: "a", folder: "/a", limits: limits))
    #expect(AccountMenu.summary(spent) == "automation · 5h 100% · wk 0%, limit spent")
    #expect(AccountMenu.summary(failed) == "automation, usage read failed")
    #expect(AccountMenu.summary(healthy) == "automation · 5h 52% · wk 64%")
    #expect(AccountMenu.help(failed).hasPrefix("automation, usage read failed. "))
  }

  @Test func onlyASpentLimitOrAFailedReadWarns() {
    let spent = [UsageLimit(kind: "session", label: "Session (5h)", percent: 100, resetsAt: nil)]
    #expect(!AccountMenu.warns(nil))
    #expect(!AccountMenu.warns(row(nil)))
    #expect(!AccountMenu.warns(row(AccountUsage(name: "a", folder: "/a"))))
    #expect(!AccountMenu.warns(row(AccountUsage(name: "a", folder: "/a", limits: limits))))
    #expect(AccountMenu.warns(row(AccountUsage(name: "a", folder: "/a", limits: spent))))
    #expect(AccountMenu.warns(row(AccountUsage(name: "a", folder: "/a", error: "not signed in"))))
  }

  @Test func theWarningIsNotTheNeedsYouColor() {
    #expect(AccountMenu.warningColor != AttentionState.needsYou.color)
  }

  /// A misspelled symbol name draws an empty toolbar item.
  @Test func bothToolbarSymbolsExist() {
    for name in [AccountMenu.symbol, AccountMenu.warningSymbol] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  @Test func aLimitRowNamesTheResetTimeWhenThereIsOne() {
    #expect(AccountMenu.limitRow(limits[0], now: 0) == "Session (5h): 52% · resets in 2h 5m")
    #expect(AccountMenu.limitRow(limits[1], now: 0) == "Week (all models): 21%")
  }

  @Test func theSessionCountNamesTheAccountsSessions() {
    #expect(row(nil).sessionCount == "11 sessions")
  }

  @Test func theSessionCountIsSingularForOneSession() {
    #expect(row(nil, sessions: 1).sessionCount == "1 session")
  }

  @Test func theSessionCountIsNilForAnAccountWithoutSessions() {
    #expect(row(nil, sessions: 0).sessionCount == nil)
  }
}

/// An Ultra plan has no 5-hour session, so the menu shows only the weeks.
@Suite struct AccountMenuWithoutASessionLimit {
  /// A usage response with no open 5-hour window.
  static let response = Data(
    #"""
    {"limits": [
      {"kind": "weekly_all", "percent": 8, "severity": "normal"},
      {"kind": "weekly_scoped", "percent": 3, "severity": "normal", "scope": {"model": {"display_name": "Fable"}}}
    ]}
    """#.utf8)

  func row(_ limits: [UsageLimit]) -> AccountRow {
    AccountRow(
      account: AccountInfo(name: "max", folder: "/m", active: true, sessions: 2),
      usage: AccountUsage(name: "max", folder: "/m", limits: limits))
  }

  @Test func anUltraReadingShowsOnlyTheWeekInTheLabelAndTheRows() throws {
    let limits = try Usage.parse(Self.response, plan: "Ultra")

    #expect(AccountMenu.label(row(limits)) == "max · wk 8%")
    #expect(limits.map { AccountMenu.limitRow($0, now: 0) } == ["Week (all models): 8%", "Week (Fable): 3%"])
  }

  /// The label drops the session only when the reading has none, not when it is at 0%.
  @Test func anotherPlansReadingShowsItsUnusedSessionInTheLabelAndTheRows() throws {
    let limits = try Usage.parse(Self.response, plan: "Pro")

    #expect(AccountMenu.label(row(limits)) == "max · 5h 0% · wk 8%")
    #expect(
      limits.map { AccountMenu.limitRow($0, now: 0) } == [
        "Session (5h): 0%", "Week (all models): 8%", "Week (Fable): 3%",
      ])
  }
}

@Suite struct AccountMenuRows {
  let accounts = [
    AccountInfo(name: "default", folder: "/d", active: false, sessions: 0),
    AccountInfo(name: "automation", folder: "/a", active: true, sessions: 11),
    AccountInfo(name: "prompts", folder: "/p", active: false, sessions: 0),
  ]
  let limits = [UsageLimit(kind: "session", label: "Session (5h)", percent: 66)]

  @Test func rowsFollowTheAccountsAndPairEachWithItsReading() {
    let usage = [
      AccountUsage(name: "automation", folder: "/a", email: "a@example.com", limits: limits),
      AccountUsage(name: "default", folder: "/d", email: "d@example.com"),
    ]

    let rows = AccountMenu.rows(accounts: accounts, usage: usage)

    #expect(rows.map(\.account.folder) == ["/d", "/a", "/p"])
    #expect(rows.map { $0.usage?.email } == ["d@example.com", "a@example.com", nil])
    #expect(rows[1].usage?.limits == limits)
  }

  @Test func onlyTheActiveAccountIsChecked() {
    let rows = AccountMenu.rows(accounts: accounts, usage: [])
    #expect(rows.map(\.account.active) == [false, true, false])
  }

  @Test func aSignedOutAccountCannotBeChosenAndSaysWhy() {
    let usage = [
      AccountUsage(name: "prompts", folder: "/p", error: "not signed in; run `x` and /login", signedOut: true)
    ]

    let prompts = AccountMenu.rows(accounts: accounts, usage: usage)[2]

    #expect(!prompts.canChoose)
    #expect(prompts.disabledReason == "New sessions can't use it until it signs in.")
  }

  @Test func aCodexAccountCannotBeChosenAndSaysWhy() {
    let codex = AccountInfo(name: "codex-work", folder: "/c", active: false, sessions: 0, agent: .codex)

    let row = AccountMenu.rows(accounts: accounts + [codex], usage: [])[3]

    #expect(!row.canChoose)
    #expect(row.disabledReason?.contains(Agent.onlyClaudeRunsSessions) == true)
  }

  @Test func aSignedOutActiveAccountStaysCheckedAndSaysWhy() {
    let usage = [AccountUsage(name: "automation", folder: "/a", error: "not signed in", signedOut: true)]

    let automation = AccountMenu.rows(accounts: accounts, usage: usage)[1]

    #expect(automation.account.active)
    #expect(automation.disabledReason != nil)
  }

  @Test func theActiveAccountIsNotAChoice() {
    let rows = AccountMenu.rows(accounts: accounts, usage: [])
    #expect(rows.map(\.canChoose) == [true, false, true])
  }

  @Test func anAccountWithoutAReadingOrWithAFailedReadCanBeChosen() {
    let usage = [AccountUsage(name: "default", folder: "/d", error: "the usage endpoint answered 500")]

    let rows = AccountMenu.rows(accounts: accounts, usage: usage)

    #expect(rows[0].canChoose)
    #expect(rows[0].disabledReason == nil)
    #expect(rows[2].canChoose)
  }

  @Test func theMenuShowsWithAReadingOrWithMoreThanOneAccount() {
    let one = [AccountInfo(name: "default", folder: "/d", active: true, sessions: 0)]
    #expect(!AccountMenu.shows(accounts: [], usage: []))
    #expect(!AccountMenu.shows(accounts: one, usage: []))
    #expect(AccountMenu.shows(accounts: one, usage: [AccountUsage(name: "default", folder: "/d")]))
    #expect(AccountMenu.shows(accounts: accounts, usage: []))
  }
}

final class OpLog: Sendable {
  private let ops = OSAllocatedUnfairLock<[String]>(initialState: [])
  var value: [String] { ops.withLock { $0 } }
  func append(_ op: String) { ops.withLock { $0.append(op) } }
}

@MainActor
@Suite struct BoardModelAccountSwitch {
  let plan = AccountMove(account: "/a", moved: ["s1"])

  func model(_ log: OpLog) -> BoardModel {
    let model = offlineModel()
    model.send = { op, _ in
      log.append(op)
      return .null
    }
    return model
  }

  @Test func aMoveOnlyChangeSendsOnlyTheMove() async {
    let log = OpLog()
    let model = model(log)

    model.confirmAccountSwitch(AccountSwitch(folder: "/a", plan: plan, switches: false), move: true)

    await settle { log.value.count == 1 }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(log.value == ["account-move"])
  }

  @Test func aSwitchThatMovesSwitchesFirst() async {
    let log = OpLog()
    let model = model(log)

    model.confirmAccountSwitch(AccountSwitch(folder: "/a", plan: plan, switches: true), move: true)

    await settle { log.value.count == 2 }
    #expect(log.value == ["account-use", "account-move"])
  }

  @Test func aSwitchForNewSessionsOnlyMovesNothing() async {
    let log = OpLog()
    let model = model(log)

    model.confirmAccountSwitch(AccountSwitch(folder: "/a", plan: plan, switches: true), move: false)

    await settle { log.value.count == 1 }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(log.value == ["account-use"])
  }

  @Test func readMovableFillsTheFooterPlanFromTheDryRun() async throws {
    let log = OpLog()
    let model = offlineModel()
    let planJSON = try JSONCoding.convert(plan, to: JSON.self)
    model.send = { op, _ in
      log.append(op)
      return planJSON
    }
    model.accounts = [
      AccountInfo(name: "a", folder: "/a", active: true, sessions: 0),
      AccountInfo(name: "b", folder: "/b", active: false, sessions: 2),
    ]

    model.readMovable()

    await settle { model.movable == plan }
    #expect(model.movable == plan)
    #expect(log.value == ["account-move"])
  }

  @Test func readMovableClearsTheFooterPlanWhenNothingCanMove() async {
    let log = OpLog()
    let model = model(log)
    model.accounts = [AccountInfo(name: "a", folder: "/a", active: true, sessions: 0)]
    model.movable = plan

    model.readMovable()

    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(model.movable == nil)
    #expect(log.value.isEmpty)
  }

  @Test func choosingAnAccountClosesTheMenu() {
    let model = model(OpLog())
    model.showingAccounts = true

    model.useAccount("/b")

    #expect(!model.showingAccounts)
  }

  @Test func offeringAMoveClosesTheMenuAndAsksWithoutSwitching() {
    let model = model(OpLog())
    model.showingAccounts = true

    model.offerMove(plan)

    #expect(!model.showingAccounts)
    #expect(model.switchingAccount?.folder == "/a")
    #expect(model.switchingAccount?.switches == false)
  }

  nonisolated static let refusal = "b is not signed in; run `CLAUDE_CONFIG_DIR=/b claude` and /login"

  /// A model whose sbd refuses `account-use` and `account-move` as it refuses a signed-out account.
  func refusingModel(_ log: OpLog) -> BoardModel {
    let model = offlineModel()
    model.send = { op, _ in
      log.append(op)
      if op == "account-use" || op == "account-move" { throw APIError(Self.refusal) }
      return .null
    }
    return model
  }

  @Test func choosingARefusedAccountShowsTheRefusalAndAsksNothing() async {
    let log = OpLog()
    let model = refusingModel(log)

    model.useAccount("/b")

    await settle { log.value.contains("account-use") && model.actionError != nil }
    #expect(model.actionError?.contains(Self.refusal) == true)
    #expect(model.switchingAccount == nil)
  }

  @Test func aRefusedSwitchShowsTheRefusalAndMovesNoSessions() async {
    let log = OpLog()
    let model = refusingModel(log)

    model.confirmAccountSwitch(AccountSwitch(folder: "/b", plan: plan, switches: true), move: true)

    await settle { model.actionError != nil }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(model.actionError?.contains(Self.refusal) == true)
    #expect(log.value == ["account-use"])
  }

  @Test func theMenuOffersAMoveOnlyToASignedInActiveAccountWithSessionsElsewhere() {
    let model = offlineModel()
    model.accounts = [
      AccountInfo(name: "a", folder: "/a", active: true, sessions: 0),
      AccountInfo(name: "b", folder: "/b", active: false, sessions: 2),
    ]
    #expect(model.moveTarget?.folder == "/a")

    model.usage = [AccountUsage(name: "a", folder: "/a", error: "not signed in", signedOut: true)]
    #expect(model.moveTarget == nil)

    model.usage = []
    model.accounts[1].sessions = 0
    #expect(model.moveTarget == nil)
  }

  /// Sessions on a Codex account never move to a Claude account, so they offer no move.
  @Test func sessionsOnACodexAccountOfferNoMove() {
    let model = offlineModel()
    model.accounts = [
      AccountInfo(name: "a", folder: "/a", active: true, sessions: 0),
      AccountInfo(name: "codex", folder: "/c", active: false, sessions: 2, agent: .codex),
    ]

    #expect(model.sessionAccounts.map(\.folder) == ["/a"])
    #expect(model.moveTarget == nil)
  }
}
