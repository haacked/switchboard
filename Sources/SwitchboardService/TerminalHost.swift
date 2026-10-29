import Foundation
import SwitchboardCore

/// One pane from `list-panes`, keyed by its tmux session name.
struct PaneRow {
  var pid: Int
  /// The pane's program exited. tmux keeps the pane with its last screen.
  var dead: Bool
  /// The number of terminals attached to the pane's tmux session.
  var clients: Int
}

/// The terminal host: a private tmux server on $SB_HOME/tmux.sock. Each pane
/// is a tmux session of its own, so two terminals can show a session's Claude
/// pane and its shell at once.
final class TerminalHost {
  let tmux: String
  let socket: String
  let shell: String
  private let conf: String
  private let baseEnv: [String: String]

  init(home: Home, config: Config) throws {
    guard let tmux = findExecutable(config.tmux ?? "tmux") else {
      throw APIError("can't find tmux. Install it with `brew install tmux`, or set \"tmux\" in \(home.config)")
    }
    self.tmux = tmux
    self.socket = home.tmuxSocket
    self.shell = config.shell ?? TerminalHost.loginShell()
    self.conf = home.tmuxConfig
    // tmux runs every pane with the server's environment. Starting it from a
    // short list keeps variables such as CLAUDECODE, which mark a child of
    // another Claude session, out of the sessions that sbd starts.
    let env = ProcessInfo.processInfo.environment
    var base: [String: String] = ["TERM": "xterm-256color", "SHELL": shell, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SSH_AUTH_SOCK"] {
      if let value = env[key] { base[key] = value }
    }
    base["LANG"] = base["LANG"] ?? "en_US.UTF-8"
    self.baseEnv = base
    try TerminalHost.configText.write(toFile: conf, atomically: true, encoding: .utf8)
  }

  /// The server's options. The panes have no status line, because the app
  /// draws its own window chrome. There is no prefix key, so Ctrl-B reaches
  /// Claude Code, and no key splits a pane or opens copy mode. focus-events
  /// and extended-keys pass focus reports and extended keys through to Claude
  /// Code, as Ghostty does. A pane whose program exits keeps its last screen
  /// until sbd starts it again.
  static let configText = """
    set -g status off
    set -g prefix None
    set -g prefix2 None
    unbind-key -a -T prefix
    set -g remain-on-exit on
    set -g escape-time 0
    set -g history-limit 50000
    set -g mouse on
    set -g focus-events on
    set -s extended-keys on
    set -g default-terminal "xterm-256color"
    set -g set-clipboard on

    """

  static func loginShell() -> String {
    if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
    return "/bin/zsh"
  }

  @discardableResult
  func run(_ args: [String], input: Data? = nil) throws -> String {
    let r = try runCommand(tmux, ["-S", socket, "-f", conf] + args, env: baseEnv, input: input)
    guard r.status == 0 else {
      throw APIError("tmux \(args.first ?? ""): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return r.stdout
  }

  /// Every pane on the server, keyed by its tmux session name.
  func panes() -> [String: PaneRow] {
    guard
      let out = try? run(["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}\t#{pane_dead}\t#{session_attached}"])
    else { return [:] }
    var rows: [String: PaneRow] = [:]
    for line in out.split(separator: "\n") {
      let f = line.split(separator: "\t")
      guard f.count == 4, let pid = Int(f[1]) else { continue }
      rows[String(f[0])] = PaneRow(pid: pid, dead: f[2] == "1", clients: Int(f[3]) ?? 0)
    }
    return rows
  }

  /// The value of a tmux format for the pane, or nil when the pane is missing.
  /// For a missing pane, tmux prints the format with every value empty and
  /// exits 0. Every pane's `#{pane_id}` starts with `%`, so a line that
  /// doesn't start with one means the pane is missing.
  private func display(_ name: String, _ format: String) -> String? {
    guard let line = try? run(["display-message", "-p", "-t", "=\(name):", "#{pane_id}:\(format)"]),
      line.hasPrefix("%"), let colon = line.firstIndex(of: ":")
    else { return nil }
    return line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether the pane's program exited, or nil when the pane is missing.
  func isDead(_ name: String) -> Bool? {
    display(name, "#{pane_dead}").map { $0 == "1" }
  }

  /// How the pane's program ended, such as "status 3" or "signal kill".
  func exitText(_ name: String) -> String? {
    display(name, "#{?pane_dead_signal,signal #{pane_dead_signal},status #{pane_dead_status}}")
  }

  /// Starts a pane in its own tmux session. With no command, the pane runs
  /// the login shell.
  func create(_ name: String, cwd: String, env: [String: String], command: String? = nil) throws {
    try run(
      ["new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", cwd] + envArgs(env)
        + (command.map { [$0] } ?? []))
  }

  /// Starts a dead pane again, with the command or the login shell. tmux
  /// refuses when the pane's program still runs. The new program also gets
  /// the variables that `create` stored in the pane's tmux session. So this
  /// first unsets each one that `env` lacks, which leaves the server's own
  /// environment for that name.
  func respawn(_ name: String, cwd: String, env: [String: String], command: String?) throws {
    // show-environment prints -NAME for a variable that is already marked for removal.
    let held = try run(["show-environment", "-t", "=\(name)"]).split(separator: "\n").compactMap { line in
      line.hasPrefix("-") ? nil : line.split(separator: "=", maxSplits: 1).first.map(String.init)
    }
    for key in held where env[key] == nil { try run(["set-environment", "-t", "=\(name)", "-u", key]) }
    try run(["respawn-pane", "-t", "=\(name):", "-c", cwd] + envArgs(env) + (command.map { [$0] } ?? []))
  }

  private func envArgs(_ env: [String: String]) -> [String] {
    env.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
  }

  /// The line that a dead pane shows below its last screen.
  func setDeadMessage(_ name: String, _ message: String) throws {
    try run(["set-option", "-p", "-t", "=\(name):", "remain-on-exit-format", message])
  }

  func kill(_ name: String) {
    _ = try? run(["kill-session", "-t", "=\(name)"])
  }

  /// Pastes the text with bracketed paste, then presses Enter. It leaves copy
  /// mode first, where Enter would not reach the program.
  func paste(_ name: String, _ text: String) throws {
    let target = "=\(name):"
    if (try? run(["display-message", "-p", "-t", target, "#{pane_in_mode}"]))?.hasPrefix("1") == true {
      try run(["send-keys", "-t", target, "-X", "cancel"])
    }
    // The text goes in on stdin, because tmux strips a trailing semicolon
    // from a command argument.
    let buffer = "sb-\(name)"
    try run(["load-buffer", "-b", buffer, "-"], input: Data(text.utf8))
    try run(["paste-buffer", "-p", "-d", "-b", buffer, "-t", target])
    // Claude Code treats an Enter that arrives in the same read as the paste
    // as part of the pasted text.
    usleep(300_000)
    try run(["send-keys", "-t", target, "Enter"])
  }

  /// The visible screen as text, with wrapped lines joined. `history` adds
  /// that many lines of scrollback above it.
  func screen(_ name: String, history: Int = 0) throws -> String {
    try run(["capture-pane", "-p", "-J"] + (history > 0 ? ["-S", "-\(history)"] : []) + ["-t", "=\(name):"])
  }

  /// The last `count` lines that the pane's program printed, without the
  /// line that tmux adds when the program exits.
  func lastLines(_ name: String, _ count: Int) -> [String]? {
    guard let text = try? screen(name, history: 200) else { return nil }
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("Pane is dead (") }
    return lines.isEmpty ? nil : Array(lines.suffix(count))
  }

  func clearHistory(_ name: String) {
    _ = try? run(["clear-history", "-t", "=\(name):"])
  }
}
