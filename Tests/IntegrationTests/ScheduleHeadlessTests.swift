import Foundation
import SwitchboardCore
import Testing

/// What `sb schedule <s> --headless` runs. The stub's `<run>.args` and `<run>.env` files record it.
struct HeadlessStubRun: CustomStringConvertible {
  var args: [String]
  var account: String
  var session: String
  var marker: String
  var folder: String

  /// The arguments before `--`.
  var options: [String] { Array(args.prefix { $0 != "--" }) }

  /// The value after the last `flag` before `--`.
  func value(_ flag: String) -> String? { valueOf(flag, in: options) }

  var description: String { "\(marker) in \(folder) under \(account): \(args)" }
}

/// The value after the last `flag` in `options`.
func valueOf(_ flag: String, in options: [String]) -> String? {
  guard let i = options.lastIndex(of: flag), i + 1 < options.count else { return nil }
  return options[i + 1]
}

/// The words of shell text whose arguments `shellQuote` wrote, one per argument. A quoted argument can span lines.
/// Outside quotes, a space, a tab, or a line feed ends a word, and a `#` that starts a word starts a comment that runs
/// to the end of its line.
func shellWords(_ text: String) -> [String] {
  var words: [String] = []
  var word = ""
  var inWord = false
  var quoted = false
  var escaped = false
  var comment = false
  for c in text {
    if comment {
      if c == "\n" { comment = false }
    } else if escaped {
      word.append(c)
      escaped = false
    } else if quoted {
      if c == "'" { quoted = false } else { word.append(c) }
    } else if c == "'" {
      quoted = true
      inWord = true
    } else if c == "\\" {
      escaped = true
      inWord = true
    } else if c == "#" && !inWord {
      comment = true
    } else if c == " " || c == "\t" || c == "\n" {
      if inWord { words.append(word) }
      word = ""
      inWord = false
    } else {
      word.append(c)
      inWord = true
    }
  }
  if inWord { words.append(word) }
  return words
}

extension Instance {
  /// Each headless schedule run of the stub, in no order.
  func headlessStubRuns() -> [HeadlessStubRun] {
    let dir = "\(home.path)/schedule-runs"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".env") }
    func fields(_ path: String) -> [String] {
      let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
      return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
    return names.compactMap { name in
      let base = String(name.dropLast(".env".count))
      let env = fields("\(dir)/\(name)")
      guard env.count == 4 else { return nil }
      return HeadlessStubRun(
        args: fields("\(dir)/\(base).args"), account: env[0], session: env[1], marker: env[2], folder: env[3])
    }
  }

  /// The stub's runs of the schedule.
  func headlessStubRuns(of scheduleId: String) -> [HeadlessStubRun] {
    headlessStubRuns().filter { $0.marker.hasPrefix("\(scheduleId):") }
  }

  /// The arguments of the session's last launch, from the `claude.sh` that sbd wrote for its Claude pane. A local
  /// session's launcher holds a comment and the command.
  func launchArguments(_ id: String) throws -> [String] {
    shellWords(try String(contentsOfFile: "\(home.sessionFolder(id))/claude.sh", encoding: .utf8))
  }
}

/// Headless schedules: `sb schedule <session> --every <interval> --headless [--account A] [--model M] <prompt>`
/// stores a prompt that sbd runs as a one-shot `claude -p` turn in the session's folder, outside the session's
/// conversation, under the schedule's account and model and the session's permission mode and MCP servers. The stub
/// claude records each run's arguments and environment, see Fixtures/claude-stub.
///
/// A command that the test runner starts runs outside every pane, which counts as the user. A test makes a schedule
/// due with Run Now, or with a clock move where the interval is what it tests.
@Suite(.blocking(timeLimit: .seconds(180))) struct ScheduleHeadlessTests {
  let scripts = ScheduleScriptTests()
  let fire = ScheduleFireTests()
  let waits = WaitActionTests()
  let operatorHelpers = OperatorTests()

  /// Decision 5's refusal of `--account` or `--model` on a schedule that sends its prompt into the session.
  static let accountRefusal = "Add --headless to run it as its own claude -p turn"

  /// `checkActionCaller`'s refusal, which Decision 4 applies to a headless schedule on a coordinator.
  static let coordinatorRefusal = "only a Manager conversation, the Operator, or you can"

  /// A usage reading whose weekly limit is spent until 2099.
  static let spentReading =
    #"{"limits":[{"kind":"weekly_all","percent":100,"resets_at":"2099-01-01T00:00:00+00:00"}]}"#

  // MARK: Helpers

  func row(_ text: String) throws -> ScheduleRow { try JSONCoding.decode(ScheduleRow.self, from: text) }

  /// The arguments of `sb schedule <session> --every <every> [--timeout] --headless [--account] [--model] <prompt>`.
  func headlessArgs(
    _ session: String, _ prompt: String, every: String = "30m", timeout: String? = nil, account: String? = nil,
    model: String? = nil
  ) -> [String] {
    var args = ["schedule", session, "--every", every]
    if let timeout { args += ["--timeout", timeout] }
    args.append("--headless")
    if let account { args += ["--account", account] }
    if let model { args += ["--model", model] }
    return args + [prompt, "--json"]
  }

  /// Adds a headless schedule from a terminal outside Switchboard.
  @discardableResult
  func addHeadless(
    _ sbd: Instance, _ session: String, _ prompt: String = "check the queue", every: String = "30m",
    timeout: String? = nil, account: String? = nil, model: String? = nil
  ) throws -> Schedule {
    let added = try row(
      sbd.sb(headlessArgs(session, prompt, every: every, timeout: timeout, account: account, model: model)))
    // An sb that doesn't know --headless would store the prompt to paste into the session.
    try #require(added.schedule.runner == .headless, "\(added.schedule)")
    return added.schedule
  }

  func current(_ sbd: Instance, _ session: String, _ id: String) throws -> Schedule? {
    try fire.current(sbd, session, id)
  }

  /// Makes the schedule due now and waits for its run.
  @discardableResult
  func runNow(_ sbd: Instance, _ session: String, _ id: String, after: Int64? = nil, timeout: Double = 30) throws
    -> Schedule.Run
  {
    try scripts.runNow(sbd, id)
    return try scripts.waitForRun(sbd, session, id, after: after, timeout: timeout)
  }

  /// The stub's one run of the schedule.
  func stubRun(_ sbd: Instance, _ id: String) throws -> HeadlessStubRun {
    let runs = sbd.headlessStubRuns(of: id)
    try #require(runs.count == 1, "\(runs)")
    return runs[0]
  }

  /// The options of a launch that a headless run shares: no program, no conversation, no settings file, no prompt,
  /// and no appended system prompt, which differs by kind.
  func sharedLaunchOptions(_ args: [String]) -> [String] {
    dropping(Array(args.dropFirst().prefix { $0 != "--" }), valued: ["--session-id", "--resume", "--settings"])
  }

  /// The options of a headless run that a launch shares: no print mode, no output format, and no persistence flag.
  func sharedRunOptions(_ run: HeadlessStubRun) -> [String] {
    dropping(run.options.filter { $0 != "-p" && $0 != "--no-session-persistence" }, valued: ["--output-format"])
  }

  /// `options` without each flag of `valued` and its value, and without `--append-system-prompt` and its value.
  func dropping(_ options: [String], valued: Set<String>) -> [String] {
    let drop = valued.union(["--append-system-prompt"])
    var kept: [String] = []
    var i = 0
    while i < options.count {
      if drop.contains(options[i]) {
        i += 2
      } else {
        kept.append(options[i])
        i += 1
      }
    }
    return kept
  }

  /// The events that a hook posts.
  static let hookKinds: Set<String> = [
    "SessionStart", "UserPromptSubmit", "Stop", "PreToolUse", "PostToolUse", "Notification", "PermissionRequest",
  ]

  func hookEvents(_ sbd: Instance, _ id: String) throws -> [Event] {
    try sbd.events(id).filter { Self.hookKinds.contains($0.kind) }
  }

  // MARK: Arguments and environment

  /// The first success criterion of Stage 4: print mode, the model, the other account, and no settings file.
  @Test func aRunRunsClaudeInPrintModeWithItsModelUnderTheOtherAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, "say hi", every: "1m", account: "B", model: "haiku")
    #expect(made.model == "haiku")
    #expect(made.account == sbd.account("B"))

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let last = try scripts.waitForRun(sbd, s.id, made.id)
    #expect(last.outcome == .ran, "\(last)")
    let run = try stubRun(sbd, made.id)
    #expect(run.options.contains("-p"), "\(run)")
    #expect(run.value("--output-format") == "json", "\(run)")
    #expect(run.value("--model") == "haiku", "\(run)")
    #expect(run.options.contains("--no-session-persistence"), "\(run)")
    #expect(!run.options.contains("--settings"), "\(run)")
    #expect(!run.options.contains("--session-id"), "\(run)")
    #expect(!run.options.contains("--resume"), "\(run)")
    #expect(Array(run.args.suffix(2)) == ["--", "say hi"], "\(run)")
    #expect(run.account == sbd.account("B"))
  }

  /// Decision 4: `SB_SESSION_ID` names the session, so `sb` in the run claims it, and the marker names the run.
  /// Decision 6: the run runs in the session's folder.
  @Test func aRunRunsInTheSessionsFolderWithTheSessionAndTheRunInItsEnvironment() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id)

    let last = try runNow(sbd, s.id, made.id)

    let run = try stubRun(sbd, made.id)
    #expect(run.folder == real(s.cwd), "\(run)")
    #expect(run.session == s.id, "\(run)")
    #expect(run.marker == "\(made.id):\(last.t)", "\(run)")
  }

  /// Decision 15: no `--account` means the session's account, whatever account is active.
  @Test func aRunWithoutAnAccountRunsUnderTheSessionsAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    try sbd.sb("account", "use", "B")
    let made = try addHeadless(sbd, s.id)
    #expect(made.account == nil)

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .ran, "\(last)")
    #expect(try stubRun(sbd, made.id).account == sbd.account("A"))
  }

  @Test func anAccountByNameRunsUnderThatAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, account: "B")

    try runNow(sbd, s.id, made.id)

    #expect(try stubRun(sbd, made.id).account == sbd.account("B"))
  }

  /// Decision 15: no `--model` means the model that the session's next launch passes.
  @Test func aRunWithoutAModelPassesTheModelOfTheSessionsLaunch() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id)
    #expect(made.model == nil)

    try runNow(sbd, s.id, made.id)

    let launch = try sbd.launchArguments(s.id)
    let run = try stubRun(sbd, made.id)
    #expect(run.value("--model") == valueOf("--model", in: launch), "run \(run), launch \(launch)")
  }

  @Test func aModelOverridesTheSessionsModel() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, model: "claude-test-model")

    try runNow(sbd, s.id, made.id)

    #expect(try stubRun(sbd, made.id).value("--model") == "claude-test-model")
  }

  // MARK: Parity with the session's launch (Risk 2)

  enum LaunchShape: String, CaseIterable, Sendable {
    case work, plan, auto, manager, `operator`
  }

  /// The session of the shape, idle after its first turn, on an sbd that passes `--verbose` in `claudeArgs`.
  func session(_ shape: LaunchShape) throws -> (Instance, SessionSummary) {
    let config: [String: JSON] = ["claudeArgs": ["--verbose"], "autoMode": .bool(shape == .auto)]
    let sbd = try Instance(config: config)
    switch shape {
    case .work, .auto: return (sbd, try sbd.idleSession())
    case .plan:
      let s = try JSONCoding.decode(
        SessionSummary.self,
        from: sbd.sb("new", "--json", "--name", "t", "--plan-mode", "--prompt", "hello", sbd.work))
      try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
      return (sbd, s)
    case .manager: return (sbd, try waits.conversation(sbd))
    case .operator: return (sbd, try operatorHelpers.idleOperator(sbd))
    }
  }

  /// A run passes the MCP arguments, the operator's `--no-chrome`, the model, `claudeArgs`, and the permission
  /// mode that the session's own launch passed, in the same order. `PermissionMode.forLaunch` and `launchMCPArgs`
  /// give both.
  @Test(arguments: LaunchShape.allCases)
  func aRunPassesTheOptionsOfTheSessionsLaunch(_ shape: LaunchShape) throws {
    let (sbd, s) = try session(shape)
    let made = try addHeadless(sbd, s.id)

    try runNow(sbd, s.id, made.id)

    let launch = try sbd.launchArguments(s.id)
    let run = try stubRun(sbd, made.id)
    #expect(sharedRunOptions(run) == sharedLaunchOptions(launch), "run \(run.args), launch \(launch)")
  }

  /// The run's `claude` gets the environment of the session's pane, so it runs under the account of the launch.
  @Test(arguments: LaunchShape.allCases)
  func aRunRunsUnderTheAccountOfTheSessionsLaunch(_ shape: LaunchShape) throws {
    let (sbd, s) = try session(shape)
    let made = try addHeadless(sbd, s.id)

    try runNow(sbd, s.id, made.id)

    let launched = try #require(sbd.stubCalls().last { $0.args.contains(s.claudeSessionId) })
    #expect(try stubRun(sbd, made.id).account == launched.account)
  }

  /// Decision 16: a work session's run appends no system prompt, because the triage nudge asks for a card. A
  /// coordinator's run appends its kind's prompt, which its launch appends too.
  @Test(arguments: LaunchShape.allCases)
  func onlyACoordinatorsRunAppendsTheSystemPromptOfItsLaunch(_ shape: LaunchShape) throws {
    let (sbd, s) = try session(shape)
    let made = try addHeadless(sbd, s.id)

    try runNow(sbd, s.id, made.id)

    let run = try stubRun(sbd, made.id)
    switch shape {
    case .work, .plan, .auto: #expect(run.value("--append-system-prompt") == nil, "\(run)")
    case .manager, .operator:
      let launched = valueOf("--append-system-prompt", in: try sbd.launchArguments(s.id))
      #expect(launched != nil)
      #expect(run.value("--append-system-prompt") == launched, "\(run)")
    }
  }

  // MARK: The run's result

  /// Decision 11: the tail is the first line of the envelope's result. Decision 12: the log holds the result's text,
  /// then the raw envelope.
  @Test func aRunRecordsTheFirstLineOfTheReplyAndLogsTheReplyAndTheEnvelope() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, "say hi")

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .ran, "\(last)")
    #expect(last.tail == "Done: say hi")
    #expect(last.error == nil)
    #expect(last.ms != nil)
    #expect(try current(sbd, s.id, made.id)?.running == nil)
    let log = try sbd.sb("schedule", "log", made.id)
    let reply = try #require(log.range(of: "Done: say hi\nIt ran headless."), Comment(rawValue: log))
    let envelope = try #require(log.range(of: #""type":"result""#), Comment(rawValue: log))
    #expect(reply.lowerBound < envelope.lowerBound, Comment(rawValue: log))
  }

  @Test func theScheduleRanEventCarriesTheHeadlessRunner() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, "say hi")

    try runNow(sbd, s.id, made.id)

    let ran = try fire.scheduleRan(sbd, s.id)
    try #require(ran.count == 1, "\(ran)")
    #expect(ran[0].data["outcome"]?.string == "ran")
    #expect(ran[0].data["runner"]?.string == "headless")
    #expect(ran[0].data["tail"]?.string == "Done: say hi")
  }

  /// Decision 5: `headless <model> on <account> · <prompt>`.
  @Test func scheduleLsShowsTheModelTheAccountAndThePrompt() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, "say hi", account: "B", model: "haiku")

    let line = try #require(try fire.listedLine(sbd, made.id))

    #expect(line.contains("headless haiku on B"), Comment(rawValue: line))
    #expect(line.contains("say hi"), Comment(rawValue: line))
  }

  /// Decision 11: an `is_error` envelope is a failed run.
  @Test func anErrorEnvelopeRecordsAFailedRunWithTheFirstLineOfTheResult() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, "ERROR-SCHEDULE")

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .failed, "\(last)")
    #expect(last.tail == "The run failed.", "\(last)")
    #expect(last.error != nil)
    #expect(try fire.status(sbd, made.id)?.state == .failed)
  }

  @Test func aClaudeThatExitsWithoutAnEnvelopeRecordsAFailedRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, "FAIL-SCHEDULE")

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .failed, "\(last)")
    #expect(last.error != nil)
  }

  @Test func aTimeoutEndsTheRunAndRecordsAFailedRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, "SLOW-SCHEDULE", timeout: "10s")
    #expect(made.timeout == 10_000)

    try scripts.runNow(sbd, made.id)
    let pid = try sbd.waitFor(
      "the run's pid", timeout: 15, fetch: { sbd.stubPid("schedule-run.pid") }, until: { _ in true })
    let last = try scripts.waitForRun(sbd, s.id, made.id, timeout: 40)

    #expect(last.outcome == .failed, "\(last)")
    #expect(last.error?.contains("timed out after 10s") == true, "\(last)")
    try sbd.waitFor("the run to end", timeout: 10) { !Processes.exists(Int(pid)) }
  }

  // MARK: Refusals when a schedule is added

  @Test(arguments: [["--account", "B"], ["--model", "haiku"]])
  func anAccountOrAModelWithoutHeadlessIsRefused(_ flag: [String]) throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()

    let r = try sbd.run(["schedule", s.id, "--every", "30m"] + flag + ["check the queue", "--json"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(Self.accountRefusal), Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).schedules == nil)
  }

  /// The model lands in claude's argv.
  @Test(arguments: ["-p", " "])
  func aModelThatIsBlankOrAnOptionIsRefused(_ model: String) throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()

    let r = try sbd.run(headlessArgs(s.id, "check the queue", model: model))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try sbd.get(s.id).schedules == nil)
  }

  @Test func aCodexAccountIsRefusedWhenTheScheduleIsAdded() throws {
    let sbd = try Instance(accounts: ["A"], codexAccounts: ["cx"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()

    let r = try sbd.run(headlessArgs(s.id, "check the queue", account: "cx"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("is a Codex account"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).schedules == nil)
  }

  /// Decision 15: with no `--account`, a session whose own account is a Codex account refuses the add.
  @Test func aSessionWhoseAccountIsACodexAccountRefusesTheAddWithoutAnAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    try sbd.makeCodex("A")

    let r = try sbd.run(headlessArgs(s.id, "check the queue"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("is a Codex account"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).schedules == nil)
  }

  @Test func anAccountThatSbdDoesNotHaveIsRefused() throws {
    let sbd = try Instance(accounts: ["A"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()

    let r = try sbd.run(headlessArgs(s.id, "check the queue", account: "nobody"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try sbd.get(s.id).schedules == nil)
  }

  @Test func aHostSessionRefusesAHeadlessSchedule() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello"))

    let r = try sbd.run(headlessArgs(id, "check the queue"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("run only for a session on this Mac"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(id).schedules == nil)
  }

  // MARK: Refusals when a schedule runs

  /// Decision 15: a session whose account became a Codex account after the add refuses the run, and no claude runs
  /// under the Codex folder or under a stand-in for it.
  @Test func aRunWhoseAccountBecameACodexAccountFailsAndStartsNoClaude() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id)
    let (calls, headless) = (sbd.stubCalls().count, sbd.headlessAccounts().count)
    // The session's own launch wrote its transcript into A before A became a Codex account.
    let before = [sbd.account("A"): sbd.tree(sbd.account("A"))]
    try sbd.makeCodex("A")

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .failed, "\(last)")
    #expect(last.error?.contains("Codex") == true, "\(last)")
    #expect(sbd.headlessStubRuns(of: made.id).isEmpty)
    sbd.expectClaudeNeverRan(in: [sbd.account("A")], since: calls, headlessSince: headless, before: before)
  }

  /// The schedule's own account is checked at each run too, not only the session's.
  @Test func aRunWhoseScheduleAccountBecameACodexAccountFailsAndStartsNoClaude() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, account: "B")
    let (calls, headless) = (sbd.stubCalls().count, sbd.headlessAccounts().count)
    let before = [sbd.account("B"): sbd.tree(sbd.account("B"))]
    try sbd.makeCodex("B")

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .failed, "\(last)")
    #expect(last.error?.contains("Codex") == true, "\(last)")
    #expect(sbd.headlessStubRuns(of: made.id).isEmpty)
    sbd.expectClaudeNeverRan(in: [sbd.account("B")], since: calls, headlessSince: headless, before: before)
  }

  /// Decision 17: the schedule's account must have quota. The run fails, shows in the Loops tab, and moves on.
  @Test func aSpentScheduleAccountRecordsAFailedRunAndStartsNoClaude() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("A", token: "token-a")
    try sbd.signIn("B", token: "token-b")
    fake.reply(to: "token-b", Self.spentReading)
    _ = try sbd.usage()
    #expect(try sbd.usage(of: "B").budget().isSpent)
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, account: "B")

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .failed, "\(last)")
    #expect(last.error?.contains("no quota is left") == true, "\(last)")
    #expect(sbd.headlessStubRuns(of: made.id).isEmpty)
    #expect(try current(sbd, s.id, made.id).map { $0.next > last.t } == true)
  }

  /// The quota check reads the schedule's account, not the session's.
  @Test func aSpentSessionAccountDoesNotHoldARunOnAnAccountWithRoom() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("A", token: "token-a")
    try sbd.signIn("B", token: "token-b")
    let s = try sbd.idleSession()
    fake.reply(to: "token-a", Self.spentReading)
    _ = try sbd.usage()
    #expect(try sbd.usage(of: "A").budget().isSpent)
    let made = try addHeadless(sbd, s.id, account: "B")

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .ran, "\(last)")
    #expect(try stubRun(sbd, made.id).account == sbd.account("B"))
  }

  // MARK: A run writes nothing into its session's state (Risk 5)

  /// The stub fires no hooks of its own, so the run's claude runs a script that sends the hooks that an `sb hook`
  /// entry in the account's settings would send. Each goes to this test's sbd, and none reaches the session.
  @Test func theHooksThatARunFiresRecordNothingOnTheSession() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let before = try sbd.get(s.id)
    let hooksBefore = try hookEvents(sbd, s.id).count
    let unsaved = "00000000-0000-4000-8000-0000000000be"
    let payloads: [JSON] = [
      ["hook_event_name": "SessionStart", "session_id": .string(unsaved), "source": "startup"],
      ["hook_event_name": "UserPromptSubmit", "session_id": .string(unsaved), "prompt": "check the queue"],
      ["hook_event_name": "Stop", "session_id": .string(unsaved)],
    ]
    let home = shellQuote(sbd.home.path)
    let sb = shellQuote("\(Instance.bin)/sb")
    var lines = [
      #"printf '%s' "${SB_HOME-unset}" >"# + shellQuote(scripts.path(sbd, "hook-home")),
      #"printf '%s' "${SB_SCHEDULE_RUN-unset}" >"# + shellQuote(scripts.path(sbd, "hook-marker")),
    ]
    for payload in payloads {
      lines.append(
        "printf '%s' \(shellQuote(payload.text)) | SB_HOME=\(home) \(sb) hook || echo failed >>"
          + shellQuote(scripts.path(sbd, "hook-failed")))
    }
    lines.append("echo done >" + shellQuote(scripts.path(sbd, "hook-status")))
    try (lines.joined(separator: "\n") + "\n").write(
      toFile: scripts.path(sbd, "schedule-run.sh"), atomically: true, encoding: .utf8)
    let made = try addHeadless(sbd, s.id)

    let last = try runNow(sbd, s.id, made.id)

    #expect(last.outcome == .ran, "\(last)")
    #expect(scripts.lines(scripts.path(sbd, "hook-status")) == ["done"], "the run's script did not run")
    #expect(scripts.lines(scripts.path(sbd, "hook-home")) == [sbd.home.path])
    #expect(scripts.lines(scripts.path(sbd, "hook-marker")).first?.hasPrefix("\(made.id):") == true)
    #expect(scripts.lines(scripts.path(sbd, "hook-failed")).isEmpty)
    #expect(try sbd.get(s.id).claudeSessionId == before.claudeSessionId)
    #expect(try hookEvents(sbd, s.id).count == hooksBefore)
    #expect(try sbd.events(s.id).filter { $0.data["session_id"]?.string == unsaved }.isEmpty)
  }

  // MARK: A run has its session's authority (Risk 2)

  /// `sb` in a work session's run claims the work session from SB_SESSION_ID. With the variable unset, only the
  /// run's pid in the client's ancestry places sb inside the work session, which proposes and so is refused.
  @Test(arguments: [false, true])
  func aWorkSessionsRunCannotAddAScript(_ unsetsCaller: Bool) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let add = scripts.sbCommand(
      sbd, unsetsCaller: unsetsCaller, ["schedule", worker.id, "--every", "30m", "--script", "echo pwned", "--json"])
    try (scripts.recorded(sbd, "from-run", add) + "\n").write(
      toFile: scripts.path(sbd, "schedule-run.sh"), atomically: true, encoding: .utf8)
    let made = try addHeadless(sbd, worker.id)

    try runNow(sbd, worker.id, made.id)
    let r = try sbd.scriptResult("from-run")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try sbd.get(worker.id).schedules?.map(\.runner) == [.headless])
  }

  // MARK: Who may add or change a coordinator's headless schedule (Decision 4)

  enum Coordinator: String, CaseIterable, Sendable {
    case manager, `operator`
  }

  func coordinator(_ sbd: Instance, _ kind: Coordinator) throws -> SessionSummary {
    switch kind {
    case .manager: try waits.conversation(sbd)
    case .operator: try operatorHelpers.idleOperator(sbd)
    }
  }

  /// A headless run of a coordinator has its MCP caller identity and its mode, so a work session can't plant one.
  @Test(arguments: Coordinator.allCases)
  func aWorkSessionsPaneCannotAddAHeadlessScheduleToACoordinator(_ kind: Coordinator) throws {
    let sbd = try Instance()
    let target = try coordinator(sbd, kind)
    let worker = try sbd.idleSession(name: "worker")

    let r = try waits.sbInPane(sbd, of: worker, headlessArgs(target.id, "merge everything"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(Self.coordinatorRefusal), Comment(rawValue: r.stderr))
    #expect(try sbd.get(target.id).schedules == nil)
    // The same add from a terminal is stored, so the refusal came from who sent it.
    #expect(try addHeadless(sbd, target.id).runner == .headless)
  }

  @Test func aManagerConversationsPaneAddsAHeadlessScheduleToTheOperator() throws {
    let sbd = try Instance()
    let op = try operatorHelpers.idleOperator(sbd)
    let c = try waits.conversation(sbd)

    let r = try waits.sbInPane(sbd, of: c, headlessArgs(op.id, "check the queue"))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules?.map(\.runner) == [.headless])
  }

  /// A work session's headless run has no more authority than the session, so any caller may add one.
  @Test func aWorkSessionsPaneAddsAHeadlessScheduleToItself() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let r = try waits.sbInPane(sbd, of: worker, headlessArgs(worker.id, "check the queue", model: "haiku"))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let stored = try #require(try sbd.get(worker.id).schedules?.first)
    #expect(stored.runner == .headless)
    #expect(stored.model == "haiku")
    #expect(stored.by == .claude)
  }

  /// A shell pane that opened after the last tick's snapshot. The tick runs once an hour here, so only a fresh
  /// snapshot that the request takes holds the pane's pid. The command drops SB_SESSION_ID, so without that snapshot
  /// the client would be below sbd's tmux server in no known pane.
  @Test func aWorkSessionsShellPaneThatOpenedSinceTheLastSnapshotCannotAddAHeadlessScheduleToAConversation() throws {
    let sbd = try Instance(config: ["tickSeconds": 3600])
    let c = try waits.conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")
    _ = try sbd.client.call("shell", ["session": .string(worker.id), "open": true])
    let terminals = try sbd.client.terminals(worker.id)
    try sbd.writeScript(
      "late-add", scripts.sbCommand(sbd, unsetsCaller: true, headlessArgs(c.id, "merge everything")))

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/late-add.sh\"")
    let r = try sbd.scriptResult("late-add")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try sbd.get(c.id).schedules == nil)
  }

  /// Decision 4: an edit of a coordinator's headless prompt, account, or model checks the caller as an add does.
  @Test(arguments: [["--model", "sonnet"], ["--account", "B"], ["merge everything"]])
  func aWorkSessionsPaneCannotChangeACoordinatorsHeadlessSchedule(_ change: [String]) throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let c = try waits.conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")
    let made = try addHeadless(sbd, c.id)

    let r = try waits.sbInPane(sbd, of: worker, ["schedule", "edit", made.id] + change)

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try current(sbd, c.id, made.id) == made)
  }

  /// An interval changes when the run happens, not what it does, so Decision 4 leaves it to today's rules.
  @Test func aWorkSessionsPaneCanChangeACoordinatorsHeadlessInterval() throws {
    let sbd = try Instance()
    let c = try waits.conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")
    let made = try addHeadless(sbd, c.id)

    let r = try waits.sbInPane(sbd, of: worker, ["schedule", "edit", made.id, "--every", "1h"])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try current(sbd, c.id, made.id)?.every == 3_600_000)
  }

  // MARK: Edits from the CLI

  /// Decision 5: an empty value resets the model to the session's.
  @Test func anEditChangesTheModelAndAnEmptyModelResetsIt() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id, model: "haiku")

    try sbd.sb("schedule", "edit", made.id, "--model", "sonnet")
    #expect(try current(sbd, s.id, made.id)?.model == "sonnet")

    try sbd.sb("schedule", "edit", made.id, "--model", "")
    let reset = try #require(try current(sbd, s.id, made.id))
    #expect(reset.model == nil)
    #expect(reset.prompt == made.prompt)
  }

  @Test func anEditChangesTheAccountAndAnEmptyAccountResetsIt() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id)

    try sbd.sb("schedule", "edit", made.id, "--account", "B")
    #expect(try current(sbd, s.id, made.id)?.account == sbd.account("B"))

    try sbd.sb("schedule", "edit", made.id, "--account", "")
    #expect(try current(sbd, s.id, made.id)?.account == nil)
  }

  @Test func anEditToACodexAccountIsRefused() throws {
    let sbd = try Instance(accounts: ["A"], codexAccounts: ["cx"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try sbd.idleSession()
    let made = try addHeadless(sbd, s.id)

    let r = try sbd.run(["schedule", "edit", made.id, "--account", "cx"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("is a Codex account"), Comment(rawValue: r.stderr))
    #expect(try current(sbd, s.id, made.id) == made)
  }

  @Test func anEditOfTheModelOfAScheduleThatSendsItsPromptIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try row(sbd.sb("schedule", s.id, "--every", "30m", "check the queue", "--json")).schedule

    let r = try sbd.run(["schedule", "edit", made.id, "--model", "haiku"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(Self.accountRefusal), Comment(rawValue: r.stderr))
    #expect(try current(sbd, s.id, made.id) == made)
  }
}
