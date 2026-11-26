import Foundation
import Testing

@testable import SwitchboardCore

private let claude = "/opt/homebrew/bin/claude"

private let kinds: [SessionKind] = [.work, .manager, .chat, .operator]

private enum StartMode: String, CaseIterable, Sendable {
  case none, auto, plan, manual
}

/// A session of the kind that started in the mode, as `sb new` stores it.
private func session(_ kind: SessionKind, _ mode: StartMode) -> Session {
  var s = Session(id: "s1", name: "flags", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)
  switch kind {
  case .work: break
  case .manager: s.manager = true
  case .chat: s.chat = "c1"
  case .operator: s.isOperator = true
  }
  switch mode {
  case .none: break
  case .auto: s.setStartModes(auto: true, plan: nil, manual: nil, defaultAuto: false)
  case .plan: s.setStartModes(auto: nil, plan: true, manual: nil, defaultAuto: false)
  case .manual: s.setStartModes(auto: nil, plan: nil, manual: true, defaultAuto: false)
  }
  return s
}

/// The mode that a fresh launch of the session passes, which Decision 4 gives a headless run.
private func mode(_ s: Session) -> String? { PermissionMode.forLaunch(s, resume: false, lastReported: nil) }

private func arguments(
  _ s: Session, model: String? = "haiku", mcpArgs: [String] = [], claudeArgs: [String] = [],
  prompt: String = "summarize the open PRs"
) -> [String] {
  ScheduleRun.headlessArguments(
    claude: claude, kind: s.kind, model: model, permissionMode: mode(s), mcpArgs: mcpArgs, claudeArgs: claudeArgs,
    prompt: prompt)
}

/// The arguments before `--`.
private func options(_ args: [String]) -> [String] { Array(args.prefix { $0 != "--" }) }

/// The value after the last `flag` before `--`, or nil when the flag isn't there.
private func value(of flag: String, in args: [String]) -> String? {
  let before = options(args)
  guard let i = before.lastIndex(of: flag), i + 1 < before.count else { return nil }
  return before[i + 1]
}

/// Whether `part` appears in `whole` as one unbroken run.
private func containsRun(_ whole: [String], _ part: [String]) -> Bool {
  guard !part.isEmpty else { return true }
  guard whole.count >= part.count else { return false }
  return (0...(whole.count - part.count)).contains { Array(whole[$0..<($0 + part.count)]) == part }
}

struct ScheduleRunShape: Sendable, CustomTestStringConvertible {
  fileprivate var kind: SessionKind
  fileprivate var mode: StartMode
  var testDescription: String { "\(kind.rawValue) in \(mode.rawValue) mode" }
}

private let shapes = kinds.flatMap { kind in StartMode.allCases.map { ScheduleRunShape(kind: kind, mode: $0) } }

/// Decisions 6 and 16: the argv of a script run and of a headless run.
/// Risk 5 of the plan: `sb hook` sends nothing inside a headless or script run.
@Suite struct ScheduleRunHookTests {
  @Test func aHookOutsideARunPostsForTheSession() {
    #expect(ScheduleRun.hookSession(["SB_SESSION_ID": "s1"]) == "s1")
  }

  @Test(arguments: ["r1:1800000000000", ""])
  func aHookInsideARunPostsNothing(_ marker: String) {
    #expect(ScheduleRun.hookSession(["SB_SESSION_ID": "s1", ScheduleRun.marker: marker]) == nil)
  }

  @Test func aHookWithNoSessionPostsNothing() {
    #expect(ScheduleRun.hookSession([:]) == nil)
  }
}

@Suite struct ScheduleRunArgumentsTests {
  // MARK: Headless: every shape

  @Test(arguments: shapes)
  func startsWithClaudeInPrintModeWithJSONOutput(_ shape: ScheduleRunShape) {
    let args = arguments(session(shape.kind, shape.mode))

    #expect(args.first == claude)
    #expect(options(args).contains("-p"))
    #expect(value(of: "--output-format", in: args) == "json")
  }

  /// The run saves no conversation, so it can't take over the session's `claudeSessionId` or its transcript.
  @Test(arguments: shapes)
  func savesNoSession(_ shape: ScheduleRunShape) {
    let args = arguments(session(shape.kind, shape.mode))

    #expect(options(args).contains("--no-session-persistence"))
    #expect(!options(args).contains("--session-id"))
    #expect(!options(args).contains("--resume"))
    #expect(!options(args).contains("--continue"))
  }

  /// sbd's settings file installs its hooks. A run with it would post hook events as the session.
  @Test(arguments: shapes)
  func passesNoSettingsFile(_ shape: ScheduleRunShape) {
    #expect(!options(arguments(session(shape.kind, shape.mode))).contains("--settings"))
  }

  /// A run gets the session's mode, never more: Decision 4.
  @Test(arguments: shapes)
  func passesTheModeThatAFreshLaunchOfTheSessionPasses(_ shape: ScheduleRunShape) {
    let s = session(shape.kind, shape.mode)

    let args = arguments(s)

    #expect(value(of: "--permission-mode", in: args) == mode(s))
  }

  @Test(arguments: shapes)
  func neverBypassesPermissions(_ shape: ScheduleRunShape) {
    let args = arguments(session(shape.kind, shape.mode))

    #expect(!args.contains("--dangerously-skip-permissions"))
    #expect(value(of: "--permission-mode", in: args) != "bypassPermissions")
  }

  /// `forLaunch` reads the start modes, so each shape passes the mode that its name says.
  @Test func eachStartModePassesItsMode() {
    #expect(value(of: "--permission-mode", in: arguments(session(.work, .auto))) == PermissionMode.auto)
    #expect(value(of: "--permission-mode", in: arguments(session(.work, .plan))) == PermissionMode.plan)
    #expect(value(of: "--permission-mode", in: arguments(session(.work, .manual))) == PermissionMode.manual)
    #expect(value(of: "--permission-mode", in: arguments(session(.work, .none))) == nil)
  }

  // MARK: Headless: the prompt

  @Test(arguments: shapes)
  func endsWithTheSeparatorAndThePrompt(_ shape: ScheduleRunShape) {
    let args = arguments(session(shape.kind, shape.mode), prompt: "summarize the open PRs")

    #expect(Array(args.suffix(2)) == ["--", "summarize the open PRs"])
  }

  /// `--` keeps a prompt that starts with a dash from reading as an option.
  @Test func aPromptThatStartsWithADashFollowsTheSeparator() {
    let args = arguments(session(.work, .auto), prompt: "--dangerously-skip-permissions")

    #expect(Array(args.suffix(2)) == ["--", "--dangerously-skip-permissions"])
    #expect(args.filter { $0 == "--dangerously-skip-permissions" }.count == 1)
  }

  @Test func aPromptWithNewlinesAndQuotesStaysOneArgument() {
    let prompt = "line one\nline \"two\" and 'three' $HOME"

    #expect(arguments(session(.work, .auto), prompt: prompt).last == prompt)
  }

  // MARK: Headless: the model

  @Test func passesTheModel() {
    #expect(value(of: "--model", in: arguments(session(.work, .auto), model: "haiku")) == "haiku")
  }

  @Test func passesNoModelWhenItHasNone() {
    #expect(!options(arguments(session(.work, .auto), model: nil)).contains("--model"))
  }

  // MARK: Headless: MCP arguments

  @Test(arguments: shapes)
  func passesTheSessionsMCPArgumentsVerbatimAndTogether(_ shape: ScheduleRunShape) {
    let mcp = ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{"switchboard":{"command":"sb"}}}"#]

    let args = arguments(session(shape.kind, shape.mode), mcpArgs: mcp)

    #expect(containsRun(options(args), mcp), "\(args)")
  }

  /// A work session launches with no switchboard server, so its run gets none either.
  @Test func noMCPArgumentsAddsNoMCPFlag() {
    let args = arguments(session(.work, .auto), mcpArgs: [])

    #expect(!options(args).contains("--mcp-config"))
    #expect(!options(args).contains("--strict-mcp-config"))
  }

  /// `startClaude` launches the operator without Claude in Chrome, so its run gets no browser either.
  @Test(arguments: kinds)
  func onlyAnOperatorRunTurnsOffChrome(_ kind: SessionKind) {
    #expect(options(arguments(session(kind, .auto))).contains("--no-chrome") == (kind == .operator))
  }

  // MARK: Headless: claudeArgs

  @Test func passesTheConfiguredClaudeArgs() {
    let args = arguments(session(.work, .auto), claudeArgs: ["--verbose", "--add-dir", "/tmp/shared"])

    #expect(containsRun(options(args), ["--verbose", "--add-dir", "/tmp/shared"]))
  }

  /// `startClaude` puts the session's mode after `claudeArgs`, so a global mode can't widen a session's.
  @Test(arguments: [StartMode.auto, .plan, .manual])
  fileprivate func theSessionsModeComesAfterAModeInClaudeArgs(_ start: StartMode) throws {
    let s = session(.work, start)

    let args = arguments(s, claudeArgs: ["--permission-mode", "bypassPermissions"])

    #expect(value(of: "--permission-mode", in: args) == mode(s))
    let last = try #require(options(args).lastIndex(of: "--permission-mode"))
    let bypass = try #require(options(args).firstIndex(of: "bypassPermissions"))
    #expect(last > bypass)
  }

  // MARK: Headless: the appended system prompt

  /// The triage prompt asks for `sb summary set`, which would put a card on the session.
  @Test(arguments: [SessionKind.work, .chat])
  func aWorkOrChatRunAppendsNoSystemPrompt(_ kind: SessionKind) {
    #expect(!options(arguments(session(kind, .auto))).contains("--append-system-prompt"))
  }

  @Test func aManagerRunAppendsTheConversationPrompt() {
    let args = arguments(session(.manager, .auto))

    #expect(value(of: "--append-system-prompt", in: args) == Manager.conversationPrompt)
  }

  @Test func anOperatorRunAppendsTheOperatorPrompt() {
    let args = arguments(session(.operator, .auto))

    #expect(value(of: "--append-system-prompt", in: args) == Manager.operatorPrompt)
  }

  // MARK: Script

  @Test func aScriptRunsInTheLoginShellWithTheCommandAsOneArgument() {
    let args = ScheduleRun.scriptArguments(command: "git fetch --prune", shell: "/bin/bash")

    #expect(args == ["/bin/bash", "-l", "-c", "git fetch --prune"])
  }

  @Test(arguments: [nil, ""] as [String?])
  func aScriptWithoutAShellFallsBackToZsh(_ shell: String?) {
    #expect(ScheduleRun.scriptArguments(command: "make sync", shell: shell) == ["/bin/zsh", "-l", "-c", "make sync"])
  }

  /// An interactive shell without a terminal prints job-control warnings into the log.
  @Test func aScriptShellIsNotInteractive() {
    let args = ScheduleRun.scriptArguments(command: "true", shell: "/bin/zsh")

    #expect(!args.contains("-i"))
    #expect(!args.contains("-li"))
    #expect(!args.contains("-il"))
  }

  /// The shell parses the command, so sbd passes it as written, with no quoting of its own.
  @Test func aCommandWithPipesQuotesAndNewlinesIsPassedUnchanged() {
    let command = "git status --short | wc -l && echo \"done: $(date)\"\necho 'second line'"

    #expect(ScheduleRun.scriptArguments(command: command, shell: "/bin/zsh").last == command)
  }

  @Test func aCommandThatStartsWithADashIsTheArgumentOfDashC() {
    #expect(ScheduleRun.scriptArguments(command: "-x", shell: "/bin/zsh") == ["/bin/zsh", "-l", "-c", "-x"])
  }
}
