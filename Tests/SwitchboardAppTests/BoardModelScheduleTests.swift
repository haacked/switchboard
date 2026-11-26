import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A model whose `send` records every request and answers each with a schedule row, as sbd answers `schedule`
/// and `edit-schedule`.
@MainActor
private func rowAnsweringModel() -> (BoardModel, SentRequests) {
  let model = offlineModel()
  let sent = SentRequests()
  model.send = { op, args in
    sent.append(op, args)
    return try JSON(encoding: ScheduleRow(session: "s1", name: "s1", schedule: scheduleFixture("r1")))
  }
  return (model, sent)
}

@MainActor
@Suite struct BoardModelScheduleTests {
  @Test func pausingAScheduleSendsPauseScheduleWithPausedTrue() async {
    let sent = await firstRequest { $0.pauseSchedule("r1", paused: true) }

    #expect(sent.op == "pause-schedule")
    #expect(sent.args == ["schedule": "r1", "paused": true])
  }

  @Test func resumingAScheduleSendsPauseScheduleWithPausedFalse() async {
    let sent = await firstRequest { $0.pauseSchedule("r1", paused: false) }

    #expect(sent.op == "pause-schedule")
    #expect(sent.args == ["schedule": "r1", "paused": false])
  }

  @Test func removingAScheduleSendsRemoveScheduleWithTheId() async {
    let sent = await firstRequest { $0.removeSchedule("r1") }

    #expect(sent.op == "remove-schedule")
    #expect(sent.args == ["schedule": "r1"])
  }

  @Test func runningAScheduleNowSendsRunScheduleWithTheId() async {
    let sent = await firstRequest { $0.runSchedule("r1") }

    #expect(sent.op == "run-schedule")
    #expect(sent.args == ["schedule": "r1"])
  }

  // MARK: New Loop and Edit

  @Test func addingALoopSendsScheduleWithTheSessionIntervalPromptAndTheUserAsAuthor() async {
    let sent = await firstRequest { $0.addSchedule(session: "s1", every: "30m", prompt: "check the queue") }

    #expect(sent.op == "schedule")
    #expect(sent.args == ["session": "s1", "every": "30m", "prompt": "check the queue", "by": "you"])
  }

  /// sbd's `schedule` creates the operator when the session is its name and none exists yet.
  @Test func addingALoopOnTheSyntheticOperatorSendsTheOperatorsName() async throws {
    let choice = try #require(LoopEditor.sessionChoices([], operatorID: nil).first)

    let sent = await firstRequest { $0.addSchedule(session: choice.session, every: "30m", prompt: "check the queue") }

    #expect(sent.op == "schedule")
    #expect(sent.args["session"] == .string(Manager.operatorName))
  }

  @Test func editingOnlyTheIntervalSendsEditScheduleWithOnlyEvery() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: "1h", prompt: nil) }

    #expect(sent.op == "edit-schedule")
    #expect(sent.args == ["schedule": "r1", "every": "1h"])
  }

  @Test func editingOnlyThePromptSendsEditScheduleWithOnlyThePrompt() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: nil, prompt: "Run the Done audit") }

    #expect(sent.op == "edit-schedule")
    #expect(sent.args == ["schedule": "r1", "prompt": "Run the Done audit"])
  }

  @Test func editingBothSendsEditScheduleWithBoth() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: "1h", prompt: "Run the Done audit") }

    #expect(sent.op == "edit-schedule")
    #expect(sent.args == ["schedule": "r1", "every": "1h", "prompt": "Run the Done audit"])
  }

  @Test(arguments: [LoopEditorRequest.new, .edit("r1")])
  func theOpenLoopEditorCountsAsASheet(_ request: LoopEditorRequest) throws {
    let model = offlineModel()
    try #require(!model.presentingSheet)

    model.loopEditor = request
    #expect(model.presentingSheet)
    model.loopEditor = nil
    #expect(!model.presentingSheet)
  }

  @Test func aNewLoopThatSbdAddsClosesTheEditor() async {
    let (model, sent) = rowAnsweringModel()
    model.loopEditor = .new

    model.addSchedule(session: "s1", every: "30m", prompt: "check the queue")
    await settle { sent.ops.contains("schedule") && model.loopEditor == nil }

    #expect(model.loopEditor == nil)
  }

  @Test func aNewLoopThatSbdRefusesKeepsTheEditorOpenAndShowsTheError() async {
    let (model, _) = recordingModel { op, _ in op == "schedule" ? "s1 has 10 schedules" : nil }
    model.loopEditor = .new

    model.addSchedule(session: "s1", every: "30m", prompt: "check the queue")
    await settle { model.loopEditorError != nil }

    #expect(model.loopEditorError?.contains("s1 has 10 schedules") == true, "\(model.loopEditorError ?? "nil")")
    #expect(model.actionError == nil)
    #expect(model.loopEditor == .new)
  }

  @Test func anEditThatSbdAppliesClosesTheEditor() async {
    let (model, sent) = rowAnsweringModel()
    model.loopEditor = .edit("r1")

    model.editSchedule("r1", every: "1h", prompt: nil)
    await settle { sent.ops.contains("edit-schedule") && model.loopEditor == nil }

    #expect(model.loopEditor == nil)
  }

  @Test func anEditThatSbdRefusesKeepsTheEditorOpenAndShowsTheError() async {
    let (model, _) = recordingModel { op, _ in op == "edit-schedule" ? "no schedule r1" : nil }
    model.loopEditor = .edit("r1")

    model.editSchedule("r1", every: "1h", prompt: nil)
    await settle { model.loopEditorError != nil }

    #expect(model.loopEditorError?.contains("no schedule r1") == true, "\(model.loopEditorError ?? "nil")")
    #expect(model.actionError == nil)
    #expect(model.loopEditor == .edit("r1"))
  }

  @Test func closingTheEditorClearsItsRefusal() async {
    let (model, _) = recordingModel { op, _ in op == "edit-schedule" ? "no schedule r1" : nil }
    model.loopEditor = .edit("r1")
    model.editSchedule("r1", every: "1h", prompt: nil)
    await settle { model.loopEditorError != nil }

    model.loopEditor = nil

    #expect(model.loopEditorError == nil)
  }

  /// An answer to the first editor's save must not close an editor that the user opened after cancelling it.
  @Test func aSaveThatSbdAppliesAfterTheUserOpenedAnotherEditorLeavesThatEditorOpen() async {
    let (model, release, _) = heldModel()
    model.loopEditor = .edit("r1")
    model.editSchedule("r1", every: "1h", prompt: nil)
    #expect(model.savingLoop)

    model.loopEditor = .edit("r2")
    release.signal()
    await settle { !model.savingLoop }

    #expect(!model.savingLoop)
    #expect(model.loopEditor == .edit("r2"))
  }

  @Test func aSaveThatSbdAppliesAfterTheUserReopenedTheSameEditorLeavesItOpen() async {
    let (model, release, _) = heldModel()
    model.loopEditor = .new
    model.addSchedule(session: "s1", every: "1h", prompt: "check")

    model.loopEditor = nil
    model.loopEditor = .new
    release.signal()
    await settle { !model.savingLoop }

    #expect(model.loopEditor == .new)
  }

  @Test func aSecondSaveWhileTheFirstIsOutSendsNothing() async {
    let (model, release, requests) = heldModel()
    model.loopEditor = .new
    model.addSchedule(session: "s1", every: "1h", prompt: "check")
    model.addSchedule(session: "s1", every: "1h", prompt: "check")
    release.signal()
    release.signal()
    await settle { !model.savingLoop }

    #expect(requests.value == 1)
  }

  @Test func aRefusedSaveEndsTheSaving() async {
    let (model, _) = recordingModel { _, _ in "no schedule r1" }
    model.loopEditor = .edit("r1")

    model.editSchedule("r1", every: "1h", prompt: nil)
    #expect(model.savingLoop)
    await settle { !model.savingLoop }

    #expect(!model.savingLoop)
  }
}

// MARK: - Runners and output (Stage 5)

/// A model whose `send` records every request and answers `schedule-log` with `text`.
@MainActor
private func logAnsweringModel(_ text: String = "Already up to date.\n", truncated: Bool = false) -> (
  BoardModel, SentRequests
) {
  let model = offlineModel()
  let sent = SentRequests()
  model.send = { op, args in
    sent.append(op, args)
    return ["text": .string(text), "truncated": .bool(truncated)]
  }
  return (model, sent)
}

extension BoardModelScheduleTests {
  @Test func addingAScriptLoopSendsTheRunnerTheCommandAsThePromptAndTheTimeout() async {
    let sent = await firstRequest {
      $0.addSchedule(session: "s1", every: "1h", prompt: "git fetch", runner: .script, timeout: "5m")
    }

    #expect(sent.op == "schedule")
    #expect(
      sent.args == [
        "session": "s1", "every": "1h", "prompt": "git fetch", "by": "you", "runner": "script", "timeout": "5m",
      ])
  }

  /// sbd stores a script only for the user. The app runs outside every session, so its request claims no caller and
  /// no group, which `scriptAuthority` reads as the user.
  @Test func theAppsScriptRequestClaimsNoCallerAndNoGroup() async {
    let sent = await firstRequest { $0.addSchedule(session: "s1", every: "1h", prompt: "git fetch", runner: .script) }

    #expect(sent.args["caller"] == nil)
    #expect(sent.args["group"] == nil)
    #expect(sent.args["by"] == "you")
  }

  @Test func addingAHeadlessLoopSendsTheRunnerTheAccountAndTheModel() async {
    let sent = await firstRequest {
      $0.addSchedule(
        session: "s1", every: "1h", prompt: "Summarize the open PRs", runner: .headless, account: "work",
        model: "haiku")
    }

    #expect(
      sent.args == [
        "session": "s1", "every": "1h", "prompt": "Summarize the open PRs", "by": "you", "runner": "headless",
        "account": "work", "model": "haiku",
      ])
  }

  @Test func addingAHeadlessLoopOnTheSessionsAccountAndModelSendsNeither() async {
    let sent = await firstRequest {
      $0.addSchedule(session: "s1", every: "1h", prompt: "Summarize the open PRs", runner: .headless)
    }

    #expect(sent.args["account"] == nil)
    #expect(sent.args["model"] == nil)
    #expect(sent.args["runner"] == "headless")
  }

  @Test func editingOnlyTheTimeoutSendsEditScheduleWithOnlyTheTimeout() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: nil, prompt: nil, timeout: "2m") }

    #expect(sent.op == "edit-schedule")
    #expect(sent.args == ["schedule": "r1", "timeout": "2m"])
  }

  /// An empty account or model resets it to the session's.
  @Test func clearingAHeadlessLoopsAccountAndModelSendsEmptyValues() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: nil, prompt: nil, account: "", model: "") }

    #expect(sent.args == ["schedule": "r1", "account": "", "model": ""])
  }

  /// A script's command travels in `prompt`. An edit never sends a runner, because sbd fixes it at creation.
  @Test func editingAScriptsCommandSendsItAsThePromptAndNoRunner() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: nil, prompt: "git pull --rebase") }

    #expect(sent.args == ["schedule": "r1", "prompt": "git pull --rebase"])
  }

  // MARK: Output…

  @Test func loadingALoopsOutputSendsScheduleLogForTheNewestRun() async {
    let sent = await firstRequest { $0.loadScheduleLog("r1") }

    #expect(sent.op == "schedule-log")
    #expect(sent.args == ["schedule": "r1"])
  }

  @Test func loadingAnOlderRunSendsItsNumber() async {
    let sent = await firstRequest { $0.loadScheduleLog("r1", run: 3) }

    #expect(sent.args == ["schedule": "r1", "run": 3])
  }

  @Test func theLogThatSbdReturnsShowsInTheOutputSheet() async {
    let (model, _) = logAnsweringModel("Already up to date.\n", truncated: true)

    model.loadScheduleLog("r1", run: 2)
    await settle { model.loopOutput?.text != nil }

    #expect(model.loopOutput?.schedule == "r1")
    #expect(model.loopOutput?.run == 2)
    #expect(model.loopOutput?.text == "Already up to date.\n")
    #expect(model.loopOutput?.truncated == true)
  }

  @Test func aLogThatSbdRefusesShowsTheRefusalInTheSheet() async {
    let (model, _) = recordingModel { op, _ in op == "schedule-log" ? "schedule r1 has not run yet" : nil }

    model.loadScheduleLog("r1")
    await settle { model.loopOutput?.error != nil }

    #expect(model.loopOutput?.error?.contains("has not run yet") == true, "\(model.loopOutput?.error ?? "nil")")
    #expect(model.actionError == nil)
  }

  @Test func theOpenOutputSheetCountsAsASheet() throws {
    let model = offlineModel()
    try #require(!model.presentingSheet)

    model.loadScheduleLog("r1")
    #expect(model.presentingSheet)
    model.loopOutput = nil
    #expect(!model.presentingSheet)
  }
}
