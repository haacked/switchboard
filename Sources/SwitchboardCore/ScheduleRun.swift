import Foundation

/// The argv of a headless or script schedule's run. sbd passes the session's own permission mode and MCP arguments,
/// so a run can do no more than a prompt sent into the session.
public enum ScheduleRun {
  /// The variable that a run's environment holds, as `<schedule id>:<run t>`, where the run's t is its start in ms
  /// since the epoch. sbd finds a run that it lost at a restart by it.
  public static let marker = "SB_SCHEDULE_RUN"

  /// The session that `sb hook` posts a hook payload for: `SB_SESSION_ID`, or nil inside a run. A headless run's
  /// claude can fire `sb hook` from the account's or the worktree's settings, and its hooks would read as the
  /// session's. Its SessionStart would point the session at a conversation that the run never saves.
  public static func hookSession(_ env: [String: String]) -> String? {
    env[marker] == nil ? env["SB_SESSION_ID"] : nil
  }

  /// `claude -p` with the prompt and the options of `ClaudeLaunch.options`, which `Service.startClaude` passes
  /// too. The run passes no `--settings` file, so sbd's hooks never fire for it, and it saves no conversation. A
  /// Manager conversation's or the operator's run appends its kind's prompt. A work or chat session's run appends
  /// none, because the triage prompt asks for `sb summary set`, which would put a card on the session.
  public static func headlessArguments(
    claude: String, kind: SessionKind, model: String?, permissionMode: String?, mcpArgs: [String],
    claudeArgs: [String], prompt: String
  ) -> [String] {
    let system: String? =
      switch kind {
      case .manager: Manager.conversationPrompt
      case .operator: Manager.operatorPrompt
      case .work, .chat: nil
      }
    let options = ClaudeLaunch.options(
      mcpArgs: mcpArgs, noChrome: kind == .operator, model: model, claudeArgs: claudeArgs,
      permissionMode: permissionMode, appendedPrompt: system)
    // `--` keeps a prompt that starts with a dash from reading as an option.
    return [claude, "-p", "--output-format", "json", "--no-session-persistence"] + options + ["--", prompt]
  }

  /// The login shell runs the command. `-l` without `-i`, because an interactive shell without a terminal prints
  /// job-control warnings into the log. No shell, or an empty one, falls back to `fallback`.
  public static func scriptArguments(command: String, shell: String?, fallback: String) -> [String] {
    let shell = shell.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    return [shell, "-l", "-c", command]
  }
}

/// The options that a session's claude launch and its headless schedule's run both pass.
public enum ClaudeLaunch {
  /// The MCP arguments, `--no-chrome`, the model, `claudeArgs`, the permission mode, and the appended system prompt,
  /// in that order. The permission mode comes after `claudeArgs`, so the session's mode wins over one there. The
  /// operator launches with `noChrome`, because Claude in Chrome loads even under `--strict-mcp-config` and nobody
  /// reads the operator's chat. An empty appended prompt passes none.
  public static func options(
    mcpArgs: [String], noChrome: Bool, model: String?, claudeArgs: [String], permissionMode: String?,
    appendedPrompt: String?
  ) -> [String] {
    var args = mcpArgs
    if noChrome { args.append("--no-chrome") }
    if let model { args += ["--model", model] }
    args += claudeArgs
    if let permissionMode { args += ["--permission-mode", permissionMode] }
    if let appendedPrompt, !appendedPrompt.isEmpty { args += ["--append-system-prompt", appendedPrompt] }
    return args
  }
}
