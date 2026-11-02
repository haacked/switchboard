import Foundation
import SwitchboardCore

/// One pane from `list-panes`, keyed by its tmux session name.
struct PaneRow {
  var pid: Int
  /// The pane's program exited. tmux keeps the pane with its last screen.
  var dead: Bool
  /// The number of terminals attached to the pane's tmux session.
  var clients: Int

  /// Reads the output of `list-panes -F` with `TerminalHost.paneFormat`. A
  /// field may be empty: tmux 3.8 prints no pid for a pane whose program
  /// exited. A pane is listed whenever its line has a session name, because a
  /// pane that sbd missed would make it start the session again.
  static func parse(_ output: String) -> [String: PaneRow] {
    var rows: [String: PaneRow] = [:]
    for line in output.split(separator: "\n") {
      let f = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard let name = f.first, !name.isEmpty else { continue }
      func field(_ i: Int) -> Substring { i < f.count ? f[i] : "" }
      rows[String(name)] = PaneRow(pid: Int(field(1)) ?? 0, dead: field(2) == "1", clients: Int(field(3)) ?? 0)
    }
    return rows
  }
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
    for key in TerminalHost.inherited {
      if let value = env[key] { base[key] = value }
    }
    base["LANG"] = base["LANG"] ?? "en_US.UTF-8"
    self.baseEnv = base
    try TerminalHost.configText.write(toFile: conf, atomically: true, encoding: .utf8)
    syncServer()
  }

  /// The variables that panes get from sbd's own environment.
  private static let inherited = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SSH_AUTH_SOCK"]

  /// A tmux server outlives the sbd that started it and keeps that sbd's
  /// environment. A pane gets the server's value of each variable that its
  /// session lacks. So this gives a running server this sbd's values. tmux
  /// refuses when no server runs, and the next new-session starts one with
  /// them.
  private func syncServer() {
    let commands = Set(baseEnv.keys).union(TerminalHost.inherited).sorted().map { key in
      ["set-environment", "-g"] + (baseEnv[key].map { [key, $0] } ?? ["-u", key])
    }
    _ = try? run(Array(commands.joined(separator: [";"])))
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

  /// The format that `checkedPanes()` asks `list-panes` for, and `PaneRow.parse` reads.
  static let paneFormat = "#{session_name}\t#{pane_pid}\t#{pane_dead}\t#{session_attached}"

  /// Every pane on the server, keyed by its tmux session name. A missing
  /// server has no panes. It throws when tmux fails for any other reason,
  /// which leaves the panes unknown.
  func checkedPanes() throws -> [String: PaneRow] {
    do {
      return PaneRow.parse(try run(["list-panes", "-a", "-F", TerminalHost.paneFormat]))
    } catch {
      if TerminalHost.isNoServer(error) { return [:] }
      throw error
    }
  }

  /// Whether the error is tmux's own report that no server runs: it says "no
  /// server running", or it fails to connect because the socket is missing.
  /// An error from starting tmux, such as a missing binary, and any other
  /// "No such file or directory", such as a missing config file, is not.
  static func isNoServer(_ error: Error) -> Bool {
    guard let error = error as? APIError, error.description.hasPrefix("tmux ") else { return false }
    let text = error.description
    return text.contains("no server running")
      || (text.contains("error connecting to") && text.contains("No such file or directory"))
  }

  static func isDuplicateSession(_ error: Error) -> Bool {
    guard let error = error as? APIError else { return false }
    return error.description.hasPrefix("tmux new-session: duplicate session")
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

  /// Starts a pane in its own tmux session. When the session already exists,
  /// this leaves a running pane alone and starts a dead one again. With no
  /// command, the pane runs the login shell. tmux stores `env` in the session
  /// for later respawns. tmux also copies the variables that its `update-environment` option
  /// names from each terminal that attaches. `-E` keeps it from copying them
  /// from sbd's own client. This removes those names in `env` from the
  /// session again. A value that the session holds for one of them then came
  /// from a terminal.
  func create(_ name: String, cwd: String, env: [String: String], command: String? = nil) throws {
    do {
      try run(
        ["new-session", "-d", "-E", "-s", name, "-x", "200", "-y", "50", "-c", cwd] + envArgs(env)
          + (command.map { [$0] } ?? []))
    } catch {
      guard TerminalHost.isDuplicateSession(error) else { throw error }
      // The pane exists, so sbd's list of panes was out of date. A running
      // pane stays as it is, and a dead one starts again.
      if display(name, "#{pane_dead}") == "1" { try respawn(name, cwd: cwd, env: env, command: command) }
      return
    }
    let copied = try copiedFromTerminals()
    for key in env.keys where copied.contains(key) { try run(["set-environment", "-t", "=\(name)", "-u", key]) }
  }

  /// Starts a dead pane again, with the command or the login shell. tmux
  /// refuses when the pane's program still runs. The new program gets the
  /// variables that the pane's tmux session holds, and the server's value of
  /// each one that the session lacks. This unsets each one that `env` lacks,
  /// except a value that tmux copied from a terminal, such as a forwarded
  /// SSH_AUTH_SOCK.
  func respawn(_ name: String, cwd: String, env: [String: String], command: String?) throws {
    let copied = try copiedFromTerminals()
    for line in try run(["show-environment", "-t", "=\(name)"]).split(separator: "\n") {
      // show-environment prints -NAME for a variable that is marked for removal.
      let key = String((line.hasPrefix("-") ? line.dropFirst() : line).prefix { $0 != "=" })
      // tmux prints a value with a newline over several lines. This skips a
      // further line that doesn't start with a variable name.
      guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, env[key] == nil,
        !copied.contains(key)
      else { continue }
      try run(["set-environment", "-t", "=\(name)", "-u", key])
    }
    for key in copied.sorted() where baseEnv[key] != nil && env[key] == nil && fallsBack(key, in: name) {
      try run(["set-environment", "-t", "=\(name)", "-u", key])
    }
    try run(["respawn-pane", "-t", "=\(name):", "-c", cwd] + envArgs(env) + (command.map { [$0] } ?? []))
  }

  /// Whether the pane's session should drop its value of a variable that tmux
  /// copies from terminals and that sbd also has, so that the pane gets sbd's
  /// value. A terminal without the variable, as the app's, leaves a mark that
  /// removes it. A forwarded agent's socket goes away when its SSH login ends.
  /// This asks for the variable by name, because a line of the full listing
  /// can belong to another variable's multi-line value.
  private func fallsBack(_ key: String, in name: String) -> Bool {
    guard let held = try? run(["show-environment", "-t", "=\(name)", key]) else { return false }
    if held.hasPrefix("-") { return true }
    guard key == "SSH_AUTH_SOCK" else { return false }
    var path = Array(held.utf8.dropFirst(key.utf8.count + 1))
    if path.last == UInt8(ascii: "\n") { path.removeLast() }
    return !FileManager.default.fileExists(atPath: String(decoding: path, as: UTF8.self))
  }

  /// The variables that tmux copies from each terminal that attaches.
  private func copiedFromTerminals() throws -> Set<String> {
    Set(try run(["show-options", "-gv", "update-environment"]).split(separator: "\n").map(String.init))
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
