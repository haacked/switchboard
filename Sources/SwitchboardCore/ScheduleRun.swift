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

  /// `claude -p` with the prompt, in the order that `Service.startClaude` uses: the MCP arguments, the model,
  /// `claudeArgs`, then the permission mode, so the session's mode wins over one in `claudeArgs`. The run passes no
  /// `--settings` file, so sbd's hooks never fire for it, and it saves no conversation. A Manager conversation's or
  /// the operator's run appends its kind's prompt. A work or chat session's run appends none, because the triage
  /// prompt asks for `sb summary set`, which would put a card on the session.
  public static func headlessArguments(
    claude: String, kind: SessionKind, model: String?, permissionMode: String?, mcpArgs: [String],
    claudeArgs: [String], prompt: String
  ) -> [String] {
    var args = [claude, "-p", "--output-format", "json", "--no-session-persistence"]
    args += mcpArgs
    // The operator launches without Claude in Chrome, which loads even under `--strict-mcp-config`.
    if kind == .operator { args.append("--no-chrome") }
    if let model { args += ["--model", model] }
    args += claudeArgs
    if let permissionMode { args += ["--permission-mode", permissionMode] }
    let system: String? =
      switch kind {
      case .manager: Manager.conversationPrompt
      case .operator: Manager.operatorPrompt
      case .work, .chat: nil
      }
    if let system, !system.isEmpty { args += ["--append-system-prompt", system] }
    // `--` keeps a prompt that starts with a dash from reading as an option.
    return args + ["--", prompt]
  }

  /// The user's login shell runs the command. `-l` without `-i`, because an interactive shell without a terminal
  /// prints job-control warnings into the log. No shell, or an empty one, falls back to `/bin/zsh`.
  public static func scriptArguments(command: String, shell: String?) -> [String] {
    let shell = shell.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    return [shell, "-l", "-c", command]
  }
}
