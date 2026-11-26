import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func named(_ s: SessionSummary, _ name: String) -> SessionSummary {
  var s = s
  s.name = name
  return s
}

private func operatorNamed(_ id: String, _ name: String = Manager.operatorName) -> SessionSummary {
  var s = named(needsItem(id, manager: true, state: .working), name)
  s.kind = .operator
  return s
}

private func conversation(_ id: String, _ name: String) -> SessionSummary {
  named(needsItem(id, manager: true, state: .working), name)
}

private func groupChat(_ id: String, _ name: String) -> SessionSummary {
  named(chatItem(id, group: "g-\(id)", state: .working), name)
}

private func work(_ id: String, _ name: String) -> SessionSummary {
  named(orgSession(id, "PostHog/\(id)"), name)
}

private func sessions(_ choices: [LoopEditor.Choice]) -> [String] { choices.map(\.session) }

/// A 30m loop whose prompt is "Run the Waiting audit".
private let loop = scheduleFixture("r1")

@MainActor
@Suite struct LoopEditorTests {
  // MARK: Session choices

  /// Each kind's names sort the opposite way to its ids, so the order shows both the kind order and the
  /// by-name order inside a kind.
  @Test func choicesListTheOperatorThenConversationsThenGroupChatsThenWorkSessionsEachByName() {
    let list = [
      work("w1", "zeta"), groupChat("c1", "Yankee"), conversation("m1", "Xray"), operatorNamed("op"),
      work("w2", "alpha"), conversation("m2", "Bravo"), groupChat("c2", "Charlie"),
    ]

    let choices = LoopEditor.sessionChoices(list, operatorID: "op")

    #expect(sessions(choices) == ["op", "m2", "m1", "c2", "c1", "w2", "w1"])
  }

  @Test func withNoOperatorTheFirstChoiceIsASyntheticOperatorThatSbdCreatesByName() throws {
    let choices = LoopEditor.sessionChoices([work("w1", "fix")], operatorID: nil)

    let first = try #require(choices.first)
    #expect(first.session == Manager.operatorName)
    #expect(first.name == Manager.operatorName)
    #expect(sessions(choices) == [Manager.operatorName, "w1"])
  }

  @Test func withNoSessionsAtAllTheSyntheticOperatorIsTheOnlyChoice() {
    #expect(sessions(LoopEditor.sessionChoices([], operatorID: nil)) == [Manager.operatorName])
  }

  @Test func anExistingOperatorIsTheFirstChoiceByItsIdAndNoSyntheticOneIsAdded() throws {
    let choices = LoopEditor.sessionChoices([work("w1", "fix"), operatorNamed("op")], operatorID: "op")

    let first = try #require(choices.first)
    #expect(first.session == "op")
    #expect(choices.filter { $0.session == "op" }.count == 1)
    #expect(!choices.contains { $0.session == Manager.operatorName })
  }

  /// sbd's `schedule` refuses a session with no folder through `refuseNotStarted`.
  @Test(arguments: [unstartedFollowup("f1", "PostHog/posthog"), docketSession("d1")])
  func aSessionWithNoFolderIsLeftOut(_ session: SessionSummary) {
    let choices = LoopEditor.sessionChoices([work("w1", "fix"), session], operatorID: nil)

    #expect(!choices.contains { $0.session == session.id })
    #expect(choices.contains { $0.session == "w1" })
  }

  @Test func aFollowupThatHasStartedIsOffered() {
    var started = work("f1", "started")
    started.followup = Followup(prompt: "p")

    let choices = LoopEditor.sessionChoices([started], operatorID: nil)

    #expect(choices.contains { $0.session == "f1" })
  }

  @Test func aHostSessionsChoiceNamesItsHost() {
    var s = work("w1", "fix")
    s.host = "mini"

    let choices = LoopEditor.sessionChoices([s], operatorID: nil)

    #expect(choices.last?.name == "fix · mini")
  }

  @Test func aNewLoopDefaultsToTheExistingOperator() {
    let choices = LoopEditor.sessionChoices([work("w1", "aaa"), operatorNamed("op")], operatorID: "op")

    #expect(LoopEditor.Form(new: choices).session == "op")
  }

  @Test func aNewLoopDefaultsToTheSyntheticOperatorWhenThereIsNone() {
    let choices = LoopEditor.sessionChoices([work("w1", "aaa")], operatorID: nil)

    #expect(LoopEditor.Form(new: choices).session == Manager.operatorName)
  }

  // MARK: Validation

  /// A new loop on the operator with a prompt, so only the interval decides whether Save is enabled.
  private func newForm(interval: String, prompt: String = "check the queue") -> LoopEditor.Form {
    var form = LoopEditor.Form(new: LoopEditor.sessionChoices([], operatorID: nil))
    form.interval = interval
    form.prompt = prompt
    return form
  }

  @Test func aReadableIntervalOfAtLeastAMinuteHasNoErrorAndAllowsSave() {
    let form = newForm(interval: "30m")

    #expect(form.intervalError == nil)
    #expect(form.canSave)
  }

  @Test func anIntervalUnderAMinuteShowsTheTooShortErrorAndDisablesSave() {
    let form = newForm(interval: "30s")

    #expect(form.intervalError?.contains("too short") == true, "\(form.intervalError ?? "nil")")
    #expect(!form.canSave)
  }

  @Test func aCompoundIntervalShowsTheOneUnitErrorAndDisablesSave() {
    let form = newForm(interval: "1h30m")

    #expect(form.intervalError?.contains("more than one unit") == true, "\(form.intervalError ?? "nil")")
    #expect(!form.canSave)
  }

  @Test func theIntervalErrorIsTheCoreParsersError() throws {
    let form = newForm(interval: "soon")

    let error = try #require(form.intervalError)
    #expect(error.contains("can't read the interval soon"))
  }

  @Test func anEmptyIntervalDisablesSave() {
    #expect(!newForm(interval: "").canSave)
  }

  @Test(arguments: ["", " ", "  \n\t "])
  func aPromptThatIsEmptyAfterTrimmingDisablesSave(_ prompt: String) {
    let form = newForm(interval: "30m", prompt: prompt)

    #expect(form.intervalError == nil)
    #expect(!form.canSave)
  }

  // MARK: Editing

  /// An edit form for `loop` with `interval` and `prompt` typed over the loop's own values.
  private func editForm(interval: String? = nil, prompt: String? = nil) -> LoopEditor.Form {
    var form = LoopEditor.Form(editing: loop)
    if let interval { form.interval = interval }
    if let prompt { form.prompt = prompt }
    return form
  }

  @Test func anEditOpensWithTheLoopsIntervalAndPrompt() {
    let form = LoopEditor.Form(editing: loop)

    #expect(form.interval == Schedule.intervalText(loop.every))
    #expect(form.interval == "30m")
    #expect(form.prompt == loop.prompt)
  }

  @Test func anUnchangedEditDisablesSaveAndChangesNothing() {
    let form = editForm()

    #expect(!form.canSave)
    #expect(form.changedInterval == nil)
    #expect(form.changedPrompt == nil)
  }

  @Test func anIntervalOnlyEditChangesOnlyTheInterval() {
    let form = editForm(interval: "1h")

    #expect(form.canSave)
    #expect(form.changedInterval == "1h")
    #expect(form.changedPrompt == nil)
  }

  @Test func aPromptOnlyEditChangesOnlyThePrompt() {
    let form = editForm(prompt: "Run the Done audit")

    #expect(form.canSave)
    #expect(form.changedInterval == nil)
    #expect(form.changedPrompt == "Run the Done audit")
  }

  @Test func anEditOfBothChangesBoth() {
    let form = editForm(interval: "1h", prompt: "Run the Done audit")

    #expect(form.canSave)
    #expect(form.changedInterval == "1h")
    #expect(form.changedPrompt == "Run the Done audit")
  }

  @Test func aChangedPromptIsSentTrimmed() {
    let form = editForm(prompt: "  Run the Done audit\n")

    #expect(form.changedPrompt == "Run the Done audit")
  }

  /// sbd trims the prompt, so spaces around the loop's own prompt change nothing.
  @Test func spacesAroundTheSamePromptAreNoChange() {
    let form = editForm(prompt: "  \(loop.prompt)\n")

    #expect(form.changedPrompt == nil)
    #expect(!form.canSave)
  }

  /// The interval is compared by its length, so the same interval in another unit changes nothing.
  @Test func theSameIntervalWrittenInAnotherUnitIsNoChange() {
    var form = LoopEditor.Form(editing: scheduleFixture("r1", every: 60 * minuteMs))
    form.interval = "60m"

    #expect(form.changedInterval == nil)
    #expect(!form.canSave)
  }

  @Test(arguments: ["30s", "1h30m", "soon", ""])
  func anEditWithAnUnreadableIntervalDisablesSaveEvenWithANewPrompt(_ interval: String) {
    let form = editForm(interval: interval, prompt: "Run the Done audit")

    #expect(!form.canSave)
  }

  @Test(arguments: ["", "  \n "])
  func anEditThatEmptiesThePromptDisablesSave(_ prompt: String) {
    let form = editForm(interval: "1h", prompt: prompt)

    #expect(!form.canSave)
  }

  @Test func theIntervalIsReadAndSentWithoutSurroundingSpaces() {
    let form = newForm(interval: " 30m\n")

    #expect(form.intervalError == nil)
    #expect(form.canSave)
    #expect(form.changedInterval == "30m")
  }

  @Test func aDayWrittenAsHoursIsNoChange() {
    var form = LoopEditor.Form(editing: scheduleFixture("r1", every: 24 * 60 * minuteMs))
    form.interval = "24h"

    #expect(form.changedInterval == nil)
    #expect(!form.canSave)
  }

  /// Only the ends are trimmed, so a change of the spaces inside the prompt is a change.
  @Test func aChangeOfTheSpacesInsideThePromptIsAChange() {
    let form = editForm(prompt: "Run the  Waiting audit")

    #expect(form.changedPrompt == "Run the  Waiting audit")
    #expect(form.canSave)
  }
}

// MARK: - Runners

private let workFolder = "/Users/me/.claude-work"
private let personalFolder = "/Users/me/.claude-personal"

/// A 1h script loop that runs `command`.
private func scriptLoop(_ command: String = "git fetch", every: Int64 = 60 * minuteMs, timeout: Int64? = nil)
  -> Schedule
{
  var s = scheduleFixture("r2", command, every: every)
  s.runner = .script
  s.timeout = timeout
  return s
}

/// A 1h headless loop on the work account and haiku, unless told otherwise.
private func headlessLoop(account: String? = workFolder, model: String? = "haiku", timeout: Int64? = nil) -> Schedule {
  var s = scheduleFixture("r3", "Summarize the open PRs", every: 60 * minuteMs)
  s.runner = .headless
  s.account = account
  s.model = model
  s.timeout = timeout
  return s
}

/// A new loop of `runner` with an interval of 1h, and the prompt or command filled in.
@MainActor
private func newRunnerForm(_ runner: Schedule.Runner, text: String = "git fetch") -> LoopEditor.Form {
  var form = LoopEditor.Form(new: LoopEditor.sessionChoices([], operatorID: nil))
  form.runner = runner
  form.interval = "1h"
  if runner == .script { form.command = text } else { form.prompt = text }
  return form
}

extension LoopEditorTests {
  // MARK: A new loop's runner

  @Test func aNewLoopRunsInTheSessionWithEmptyRunnerFields() {
    let form = LoopEditor.Form(new: LoopEditor.sessionChoices([], operatorID: nil))

    #expect(form.runner == .session)
    #expect(form.account == "")
    #expect(form.model == "")
    #expect(form.timeout == "")
    #expect(form.command == "")
  }

  @Test func aNewScriptWithACommandCanSaveAndSendsTheCommand() {
    let form = newRunnerForm(.script)

    #expect(form.canSave)
    #expect(form.changedCommand == "git fetch")
    #expect(form.changedPrompt == nil)
  }

  @Test(arguments: ["", "  \n "])
  func aNewScriptWithoutACommandCantSave(_ command: String) {
    var form = newRunnerForm(.script, text: command)
    form.prompt = "a prompt typed before the runner changed"

    #expect(!form.canSave)
  }

  @Test func aNewScriptsCommandIsSentTrimmed() {
    #expect(newRunnerForm(.script, text: "  git fetch\n").changedCommand == "git fetch")
  }

  @Test func aNewHeadlessLoopWithAPromptCanSaveAndSendsThePrompt() {
    let form = newRunnerForm(.headless, text: "Summarize the open PRs")

    #expect(form.canSave)
    #expect(form.changedPrompt == "Summarize the open PRs")
    #expect(form.changedCommand == nil)
  }

  @Test func aNewHeadlessLoopWithoutAPromptCantSave() {
    var form = newRunnerForm(.headless, text: "")
    form.command = "git fetch"

    #expect(!form.canSave)
  }

  /// An empty account or model runs on the session's, so nothing is sent for it.
  @Test func aNewHeadlessLoopSendsAnAccountAndAModelOnlyWhenGiven() {
    var form = newRunnerForm(.headless)
    #expect(form.changedAccount == nil)
    #expect(form.changedModel == nil)

    form.account = "work"
    form.model = "haiku"

    #expect(form.changedAccount == "work")
    #expect(form.changedModel == "haiku")
    #expect(form.canSave)
  }

  /// sbd refuses a model that `Manager.modelProblem` refuses, because the value lands in claude's argv.
  @Test(arguments: ["-p", "two words", "--model"])
  func aHeadlessModelThatSbdRefusesShowsAnErrorAndDisablesSave(_ model: String) {
    var form = newRunnerForm(.headless)
    form.model = model

    #expect(form.modelError != nil)
    #expect(!form.canSave)
  }

  @Test func aScriptSendsNoAccountAndNoModel() {
    var form = newRunnerForm(.script)
    form.account = "work"
    form.model = "haiku"

    #expect(form.changedAccount == nil)
    #expect(form.changedModel == nil)
    #expect(form.canSave)
  }

  @Test func aLoopThatRunsInTheSessionSendsNoTimeoutNoAccountAndNoModel() {
    var form = newRunnerForm(.session, text: "check the queue")
    form.timeout = "5m"
    form.account = "work"
    form.model = "haiku"

    #expect(form.changedTimeout == nil)
    #expect(form.changedAccount == nil)
    #expect(form.changedModel == nil)
    #expect(form.timeoutError == nil)
    #expect(form.canSave)
  }

  // MARK: The timeout

  @Test(arguments: [Schedule.Runner.headless, .script])
  func aReadableTimeoutWithinTheIntervalIsSent(_ runner: Schedule.Runner) {
    var form = newRunnerForm(runner)
    form.timeout = " 5m "

    #expect(form.timeoutError == nil)
    #expect(form.changedTimeout == "5m")
    #expect(form.canSave)
  }

  @Test(arguments: [Schedule.Runner.headless, .script])
  func anEmptyTimeoutUsesTheDefaultAndSendsNothing(_ runner: Schedule.Runner) {
    let form = newRunnerForm(runner)

    #expect(form.timeoutError == nil)
    #expect(form.changedTimeout == nil)
    #expect(form.canSave)
  }

  /// Too short, too long, unreadable, and longer than the 1h interval.
  @Test(arguments: ["5s", "3h", "soon", "1h30m", "2h"])
  func aTimeoutThatSbdRefusesShowsAnErrorAndDisablesSave(_ timeout: String) {
    var form = newRunnerForm(.script)
    form.timeout = timeout

    #expect(form.timeoutError != nil, "\(timeout)")
    #expect(!form.canSave)
  }

  @Test func aTimeoutEqualToTheIntervalIsAllowed() {
    var form = newRunnerForm(.script)
    form.timeout = "60m"

    #expect(form.timeoutError == nil)
    #expect(form.canSave)
  }

  // MARK: Editing a script or a headless loop

  @Test func anEditOfAScriptOpensWithItsRunnerCommandAndTimeout() {
    let form = LoopEditor.Form(editing: scriptLoop(timeout: 300_000))

    #expect(form.runner == .script)
    #expect(form.command == "git fetch")
    #expect(form.timeout == "5m")
    #expect(form.interval == "1h")
  }

  @Test func anEditOfAScriptWithTheDefaultTimeoutOpensWithAnEmptyTimeout() {
    #expect(LoopEditor.Form(editing: scriptLoop()).timeout == "")
  }

  @Test func anEditOfAHeadlessLoopOpensWithItsAccountNameAndModel() {
    let form = LoopEditor.Form(editing: headlessLoop())

    #expect(form.runner == .headless)
    #expect(form.account == "work")
    #expect(form.model == "haiku")
    #expect(form.prompt == "Summarize the open PRs")
  }

  @Test func anEditOfAHeadlessLoopOnTheSessionsAccountAndModelOpensWithBothEmpty() {
    let form = LoopEditor.Form(editing: headlessLoop(account: nil, model: nil))

    #expect(form.account == "")
    #expect(form.model == "")
  }

  @Test(arguments: [scriptLoop(timeout: 300_000), headlessLoop(timeout: 300_000)])
  func anUnchangedEditOfADetachedLoopChangesNothing(_ loop: Schedule) {
    let form = LoopEditor.Form(editing: loop)

    #expect(!form.canSave)
    #expect(form.changedInterval == nil)
    #expect(form.changedPrompt == nil)
    #expect(form.changedCommand == nil)
    #expect(form.changedTimeout == nil)
    #expect(form.changedAccount == nil)
    #expect(form.changedModel == nil)
  }

  @Test func aCommandOnlyEditChangesOnlyTheCommand() {
    var form = LoopEditor.Form(editing: scriptLoop())
    form.command = "git pull --rebase"

    #expect(form.canSave)
    #expect(form.changedCommand == "git pull --rebase")
    #expect(form.changedInterval == nil)
    #expect(form.changedTimeout == nil)
  }

  @Test func anEditThatEmptiesTheCommandCantSave() {
    var form = LoopEditor.Form(editing: scriptLoop())
    form.command = " "
    form.interval = "2h"

    #expect(!form.canSave)
  }

  @Test(arguments: [Schedule.Runner.headless, .script])
  func aTimeoutOnlyEditChangesOnlyTheTimeout(_ runner: Schedule.Runner) {
    var form = LoopEditor.Form(
      editing: runner == .script ? scriptLoop(timeout: 300_000) : headlessLoop(timeout: 300_000))
    form.timeout = "2m"

    #expect(form.canSave)
    #expect(form.changedTimeout == "2m")
    #expect(form.changedCommand == nil)
    #expect(form.changedPrompt == nil)
  }

  /// The timeout is compared by its length, as the interval is.
  @Test func theSameTimeoutWrittenInAnotherUnitIsNoChange() {
    var form = LoopEditor.Form(editing: scriptLoop(timeout: 120_000))
    form.timeout = "120s"

    #expect(form.changedTimeout == nil)
    #expect(!form.canSave)
  }

  /// sbd refuses an edit that shortens the interval below a stored timeout, so the form does too.
  @Test func anEditThatShortensTheIntervalBelowTheTimeoutCantSave() {
    var form = LoopEditor.Form(editing: scriptLoop(timeout: 20 * minuteMs))
    form.interval = "10m"

    #expect(form.timeoutError != nil)
    #expect(!form.canSave)
  }

  /// An empty account or model resets it to the session's, which sbd reads from an empty value.
  @Test func clearingAHeadlessLoopsAccountAndModelSendsEmptyValues() {
    var form = LoopEditor.Form(editing: headlessLoop())
    form.account = ""
    form.model = ""

    #expect(form.canSave)
    #expect(form.changedAccount == "")
    #expect(form.changedModel == "")
  }

  @Test func changingAHeadlessLoopsAccountSendsTheNewName() {
    var form = LoopEditor.Form(editing: headlessLoop())
    form.account = "personal"

    #expect(form.changedAccount == "personal")
    #expect(form.changedModel == nil)
    #expect(form.canSave)
  }

  @Test func anEmptyAccountOnALoopThatHasNoneIsNoChange() {
    let form = LoopEditor.Form(editing: headlessLoop(account: nil, model: nil))

    #expect(form.changedAccount == nil)
    #expect(form.changedModel == nil)
  }

  /// A loop's runner is fixed when it is made, so an edit never turns a loop into a script.
  @Test func anEditKeepsTheRunnerFixed() {
    var form = LoopEditor.Form(editing: loop)
    form.runner = .script
    form.command = "touch pwned"

    #expect(form.changedCommand == nil)
    #expect(!form.canSave)
  }

  // MARK: Choices

  /// Headless runs need a claude, so a Codex account is left out. The session's account comes first.
  @Test func theAccountChoicesPutTheSessionsAccountFirstAndLeaveOutCodex() {
    let accounts = [
      AccountInfo(name: "personal", folder: personalFolder, active: true, sessions: 1),
      AccountInfo(name: "codex", folder: "/Users/me/.codex", active: false, sessions: 0, agent: .codex),
      AccountInfo(name: "work", folder: workFolder, active: false, sessions: 2),
    ]

    let choices = LoopEditor.accountChoices(accounts, sessionFolder: workFolder)

    #expect(choices.map(\.name) == ["work", "personal"])
  }

  @Test func withNoSessionAccountTheChoicesKeepTheListsOrder() {
    let accounts = [
      AccountInfo(name: "personal", folder: personalFolder, active: true, sessions: 1),
      AccountInfo(name: "work", folder: workFolder, active: false, sessions: 2),
    ]

    #expect(LoopEditor.accountChoices(accounts, sessionFolder: nil).map(\.name) == ["personal", "work"])
  }

  @Test func theModelSuggestionsAreSonnetOpusAndHaiku() {
    #expect(LoopEditor.modelSuggestions == ["sonnet", "opus", "haiku"])
  }
}
