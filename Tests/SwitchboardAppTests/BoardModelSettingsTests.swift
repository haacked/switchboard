import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A write that the General tab of the Settings window sends to sbd.
enum SettingsWrite: String, CaseIterable, CustomTestStringConvertible, Sendable {
  case cap, autoMode, openShell, account

  /// The op that carries the write.
  var op: String {
    switch self {
    case .cap: "live"
    case .autoMode: "auto-mode"
    case .openShell: "open-shell"
    case .account: "account-use"
    }
  }

  @MainActor func run(_ model: BoardModel) {
    switch self {
    case .cap: model.setLiveCap(4)
    case .autoMode: model.setAutoMode(true)
    case .openShell: model.setOpenShell(false)
    case .account: model.setDefaultAccount(BoardModelSettingsTests.folder)
    }
  }

  var testDescription: String { rawValue }
}

@MainActor
private final class TabBox {
  var tab: SettingsTab?
}

/// The Settings window's model: the General tab reads and writes the live cap, auto mode, the open shell setting,
/// and the account through sbd, and its refusals stay in the Settings window instead of the main window's banner.
@MainActor
@Suite struct BoardModelSettingsTests {
  nonisolated static let folder = "/Users/me/.claude-work"
  nonisolated static let refusal = "the live cap is a whole number of at least 1"

  /// What the fake sbd answers.
  struct Sbd: Sendable {
    /// The cap that `live` answers, with or without a set.
    var cap = 7
    /// The setting that `auto-mode` answers, with or without a set.
    var autoMode = false
    /// The setting that `open-shell` answers, with or without a set.
    var openShell = true
    /// The op whose write sbd refuses with `refusal`. A read of that op, which has no arguments, is still answered.
    var refusing: String?
  }

  /// A model whose `send` records every request and answers as `sbd` says. `account-move` answers a plan that
  /// moves a session, so a dry run would open the move dialog.
  func model(_ sbd: Sbd = Sbd()) -> (BoardModel, SentRequests) {
    let model = offlineModel()
    let sent = SentRequests()
    model.send = { op, args in
      sent.append(op, args)
      if op == sbd.refusing, !args.isEmpty { throw APIError(Self.refusal) }
      switch op {
      case "live": return try JSON(encoding: LiveStatus(cap: sbd.cap, live: [], queued: []))
      case "auto-mode": return ["autoMode": .bool(sbd.autoMode)]
      case "open-shell": return ["openShell": .bool(sbd.openShell)]
      case "account-move": return try JSON(encoding: AccountMove(account: Self.folder, moved: ["a"]))
      default: return .null
      }
    }
    return (model, sent)
  }

  /// Whether the model read `live`, `auto-mode`, and `open-shell` without arguments after it sent the write of `op`.
  func rereads(_ sent: SentRequests, after op: String) -> Bool {
    let value = sent.value
    guard let write = value.firstIndex(where: { $0.op == op && !$0.args.isEmpty }) else { return false }
    let later = value[(write + 1)...]
    return later.contains { $0.op == "live" && $0.args.isEmpty }
      && later.contains { $0.op == "auto-mode" && $0.args.isEmpty }
      && later.contains { $0.op == "open-shell" && $0.args.isEmpty }
  }

  /// Waits a moment for a request that should not come.
  func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }

  // MARK: - Reading

  /// A read with a `cap`, `autoMode`, or `openShell` argument would be a set. sbd answers open-shell off, which
  /// differs from the default, so that value can only come from the read.
  @Test func loadSettingsReadsTheCapAutoModeAndOpenShell() async {
    let (model, sent) = model(Sbd(cap: 7, autoMode: false, openShell: false))

    model.loadSettings()
    await settle { model.liveCap != nil && model.defaultAutoMode != nil && model.openShellByDefault != nil }

    #expect(model.liveCap == 7)
    #expect(model.defaultAutoMode == false)
    #expect(model.openShellByDefault == false)
    #expect(sent.value.allSatisfy { $0.args.isEmpty })
  }

  // MARK: - Writing

  /// sbd answers with the cap it keeps. The model shows that, not the number it sent.
  @Test func setLiveCapSendsTheCapAndShowsSbdsAnswer() async {
    let (model, sent) = model(Sbd(cap: 9))

    model.setLiveCap(4)
    await settle { model.liveCap == 9 }

    #expect(sent.value.first { $0.op == "live" }?.args == ["cap": 4])
    #expect(model.liveCap == 9)
  }

  /// sbd answers writes in order. The answer to the first click must not undo the second click while the second is
  /// still on its way, or the Stepper's next click would count from the older cap.
  @Test func anOlderCapAnswerLeavesANewerPendingCap() async {
    let model = offlineModel()
    let sent = SentRequests()
    let release = DispatchSemaphore(value: 0)
    model.send = { op, args in
      sent.append(op, args)
      let cap = args["cap"]?.int ?? 3
      if cap == 5 { release.wait() }
      return try JSON(encoding: LiveStatus(cap: cap, live: [], queued: []))
    }
    model.liveCap = 3

    model.setLiveCap(4)
    model.setLiveCap(5)
    await settle { model.pendingSettingWrites["live"] == 1 }

    #expect(model.liveCap == 5)
    release.signal()
    await settle { model.pendingSettingWrites["live"] == 0 }
    #expect(model.liveCap == 5)
  }

  /// sbd's answer wins over the value that the toggle sent.
  @Test func setAutoModeSendsTheSettingAndShowsSbdsAnswer() async {
    let (model, sent) = model(Sbd(autoMode: false))

    model.setAutoMode(true)
    await sent.wait(for: "auto-mode")
    await settle { model.defaultAutoMode == false }

    #expect(sent.value.first { $0.op == "auto-mode" }?.args == ["autoMode": true])
    #expect(model.defaultAutoMode == false)
  }

  /// sbd's answer wins over the value that the toggle sent.
  @Test func setOpenShellSendsTheSettingAndShowsSbdsAnswer() async {
    let (model, sent) = model(Sbd(openShell: true))

    model.setOpenShell(false)
    await sent.wait(for: "open-shell")
    await settle { model.openShellByDefault == true }

    #expect(sent.value.first { $0.op == "open-shell" }?.args == ["openShell": false])
    #expect(model.openShellByDefault == true)
  }

  /// The move dialog is attached to the main window, so it would open behind the Settings window.
  @Test func choosingAnAccountInSettingsSendsAccountUseWithoutAMoveOffer() async {
    let (model, sent) = model()

    model.setDefaultAccount(Self.folder)
    await sent.wait(for: "account-use")
    await pause()

    #expect(!sent.ops.contains("account-move"))
    #expect(sent.value.filter { $0.op == "account-use" }.map(\.args) == [["account": .string(Self.folder)]])
    #expect(model.switchingAccount == nil)
  }

  @Test func theToolbarStillOffersAMove() async {
    let sent = await firstRequest { $0.useAccount(Self.folder) }

    #expect(sent.op == "account-move")
    #expect(sent.args["dryRun"] == .bool(true))
  }

  // MARK: - Refusals stay in Settings

  @Test(arguments: SettingsWrite.allCases)
  func aRefusedWriteShowsInSettingsAndRereadsTheSettings(_ write: SettingsWrite) async {
    let (model, sent) = model(Sbd(refusing: write.op))

    write.run(model)
    await settle {
      model.settingsError != nil && rereads(sent, after: write.op) && model.liveCap == 7
        && model.defaultAutoMode == false && model.openShellByDefault == true
    }
    await pause()

    #expect(model.settingsError?.contains(Self.refusal) == true)
    #expect(model.actionError == nil)
    #expect(rereads(sent, after: write.op))
    #expect(model.liveCap == 7)
    #expect(model.defaultAutoMode == false)
    #expect(model.openShellByDefault == true)
  }

  @Test(arguments: SettingsWrite.allCases)
  func aSuccessfulWriteClearsTheSettingsError(_ write: SettingsWrite) async {
    let (model, sent) = model()
    model.settingsError = "an older refusal"

    write.run(model)
    await sent.wait(for: write.op)
    await settle { model.settingsError == nil }

    #expect(model.settingsError == nil)
  }

  // MARK: - Opening the window

  /// A window that opens for the first time shows the tab that is selected when it opens.
  @Test func openSettingsSelectsTheTabBeforeItOpens() {
    let model = offlineModel()
    let seen = TabBox()
    let opened = Counter()
    model.showSettings = {
      seen.tab = model.settingsTab
      opened.increment()
    }

    model.openSettings(.advanced)

    #expect(seen.tab == .advanced)
    #expect(opened.value == 1)
  }

  @Test func openSettingsWithoutARegisteredOpenerOnlySelectsTheTab() {
    let model = offlineModel()

    model.openSettings(.issues)

    #expect(model.settingsTab == .issues)
  }
}
