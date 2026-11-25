import Foundation

/// The argv of a headless or script schedule's run. sbd passes the session's own permission mode and MCP arguments,
/// so a run can do no more than a prompt sent into the session.
public enum ScheduleRun {
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
