import Foundation
import SwitchboardCore
import Testing

/// The real claude tier. `bin/test --claude` turns it on with SB_TEST_CLAUDE.
/// SB_TEST_CLAUDE_PATH picks the claude binary. Without it, the tier uses the
/// one on PATH or in ~/.local/bin.
enum ClaudeTier {
  static let enabled = ProcessInfo.processInfo.environment["SB_TEST_CLAUDE"] != nil
  static let claude: String? = {
    if let path = ProcessInfo.processInfo.environment["SB_TEST_CLAUDE_PATH"] { return findExecutable(path) }
    return findExecutable("claude") ?? findExecutable("~/.local/bin/claude")
  }()
  static let version: String = {
    guard let claude, let r = try? runCommand(claude, ["--version"]) else { return "?" }
    return r.stdout.split(separator: " ").first.map(String.init) ?? "?"
  }()
}

/// A private sbd that runs the installed claude with Haiku and no MCP
/// servers. The work folder's local settings turn Remote Control and prompt
/// suggestions off and hold the test's permission rules, and `slow.sh
/// <seconds>` there gives a tool call that takes a known time. When the
/// instance goes away, it stops claude and purges the work folder's Claude
/// state: its transcripts, its trust entry, and its prompt history.
final class ClaudeInstance {
  let sbd: Instance
  let claude: String
  /// The work folder as claude reports it, with symlinks such as /tmp resolved.
  let cwd: String
  let nonce = "SB\(Int.random(in: 100_000...999_999))"
  /// Claude stores trust for the folder, so only the first start asks for it.
  private var trusted = false

  init(idleStopSeconds: Int = 600, allow: [String] = [], ask: [String] = []) throws {
    guard let claude = ClaudeTier.claude else {
      throw TestError(description: "can't find claude. Set SB_TEST_CLAUDE_PATH to its path")
    }
    self.claude = claude
    // The panes run the login shell, as they do for real sessions, so claude
    // runs its Bash tool in that shell.
    sbd = try Instance(
      idleStopSeconds: idleStopSeconds, shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
      config: [
        "claude": .string(claude), "model": "haiku",
        "claudeArgs": ["--strict-mcp-config", "--permission-mode", "manual"],
      ])
    guard let real = realpath(sbd.work, nil) else { throw TestError(description: "can't resolve \(sbd.work)") }
    cwd = String(cString: real)
    free(real)
    // A prompt suggestion fires a SubagentStop after some turns and not
    // others, which would change the recordings from run to run.
    let settings: JSON = [
      "remoteControlAtStartup": false, "promptSuggestionEnabled": false,
      "permissions": ["allow": .array(allow.map(JSON.string)), "ask": .array(ask.map(JSON.string))],
    ]
    try FileManager.default.createDirectory(atPath: "\(sbd.work)/.claude", withIntermediateDirectories: true)
    try settings.text.write(toFile: "\(sbd.work)/.claude/settings.local.json", atomically: true, encoding: .utf8)
    try "#!/bin/sh\nsleep \"$1\"\n".write(toFile: "\(sbd.work)/slow.sh", atomically: true, encoding: .utf8)
    chmod("\(sbd.work)/slow.sh", 0o755)
  }

  /// claude writes its transcript until it exits, so the purge waits for that.
  /// purge leaves the scratchpad and task output in claude's temporary folder.
  deinit {
    var tmp: [String] = []
    for s in (try? sbd.client.sessions()) ?? [] {
      if s.claudePid != nil { _ = try? sbd.client.call("stop", ["session": .string(s.id)]) }
      _ = try? sbd.waitFor(s.id, "claude to exit") { $0.claudePid == nil }
      // claude names the folder after the work folder, with each character
      // other than a letter or a digit replaced by a dash.
      let encoded = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
      if let paths = Recording.claudePaths((try? sbd.stepPayloads(s.id, after: 0)) ?? []), paths.encodedCwd == encoded {
        tmp.append("\(paths.tmp)/\(paths.encodedCwd)")
      }
    }
    _ = try? runCommand(claude, ["purge", cwd, "-y"])
    for folder in Set(tmp) { try? FileManager.default.removeItem(atPath: folder) }
  }

  // MARK: Waiting

  /// Waits for the session to match, accepting workspace trust meanwhile.
  @discardableResult
  func waitFor(_ id: String, _ what: String, timeout: Double = 90, _ match: (SessionSummary) -> Bool) throws
    -> SessionSummary
  {
    try sbd.waitFor(id, what, timeout: timeout) { acceptTrust(id) ? false : match($0) }
  }

  /// Waits for a hook event of the kind after the event id, and returns it.
  @discardableResult
  func waitForHook(
    _ id: String, _ kind: String, after: Int64 = 0, timeout: Double = 90, where match: (Event) -> Bool = { _ in true }
  ) throws -> Event {
    var found: Event?
    try sbd.waitFor("\(kind) after event \(after)", timeout: timeout) {
      if acceptTrust(id) { return false }
      found = try sbd.hooks(id, after: after).first { $0.kind == kind && match($0) }
      return found != nil
    }
    return found!
  }

  /// Answers the trust dialog until claude reports SessionStart in this
  /// folder, and returns whether it answered. sbd also marks claude live
  /// after 10 s without SessionStart, which happens while the dialog is up.
  private func acceptTrust(_ id: String) -> Bool {
    guard !trusted else { return false }
    if (try? sbd.hooks(id).contains { $0.kind == "SessionStart" }) == true {
      trusted = true
      return false
    }
    return (try? answer(id, .trust)) == true
  }

  /// Waits until the session has had no event for 3 s. A prompt suggestion's
  /// SubagentStop arrives up to 1.6 s after Stop.
  func settle(_ id: String) throws {
    try sbd.waitFor("the session to settle", timeout: 30) {
      (try sbd.lastEvent(id).map { nowMs() - $0.t > 3000 }) ?? false
    }
  }

  /// The id of the newest event, which marks where a step starts.
  func lastEventId(_ id: String) throws -> Int64 { try sbd.lastEvent(id)?.id ?? 0 }

  /// The id of the last hook event before the first prompt.
  func startupEnd(_ id: String) throws -> Int64 {
    try #require(try sbd.hooks(id).first { $0.kind == "UserPromptSubmit" }).id - 1
  }

  // MARK: The terminal

  func screen(_ id: String) throws -> String { try sbd.client.call("screen", ["session": .string(id)]).string ?? "" }

  func press(_ id: String, _ key: String) throws {
    let t = try sbd.client.terminals(id)
    let r = try runCommand(t.tmux, ["-S", t.socket, "send-keys", "-t", "=\(t.claude):", key])
    guard r.status == 0 else { throw TestError(description: "tmux send-keys \(key): \(r.stderr)") }
  }

  /// A dialog that claude draws: a regex for its title, and a regex for the
  /// item to pick from the menu below the title.
  struct Dialog {
    var title: String
    var item: String

    /// The trust dialog highlights "No, exit" first.
    static let trust = Dialog(title: "Accessing workspace", item: "^Yes, I trust this folder")
    static let proceed = Dialog(title: "Do you want to proceed", item: "^(1\\. )?Yes")
  }

  /// The highlighted item of the menu below the title, without its ❯ marker.
  /// Claude Code also marks each past prompt with ❯, so the search starts at
  /// the title.
  static func menuCursor(_ screen: String, title: String) -> String? {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.range(of: title, options: .regularExpression) != nil }) else {
      return nil
    }
    guard let line = lines[start...].first(where: { $0.range(of: "^ *❯ ", options: .regularExpression) != nil })
    else { return nil }
    return line.replacingOccurrences(of: "^ *❯ ", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  /// Picks the dialog's item if the dialog is on screen, and returns whether
  /// it did. Claude Code menus don't always number their items or keep their
  /// order, so this moves down until the highlighted item matches.
  @discardableResult
  func answer(_ id: String, _ dialog: Dialog) throws -> Bool {
    guard var cursor = Self.menuCursor(try screen(id), title: dialog.title) else { return false }
    for _ in 0..<10 {
      if cursor.range(of: dialog.item, options: .regularExpression) != nil {
        try press(id, "Enter")
        // Gives the dialog time to close, so the next poll doesn't answer it again.
        usleep(500_000)
        return true
      }
      try press(id, "Down")
      usleep(200_000)
      cursor = Self.menuCursor(try screen(id), title: dialog.title) ?? ""
    }
    throw TestError(description: "no item matches \(dialog.item) in the dialog \(dialog.title):\n\(try screen(id))")
  }

  // MARK: Recordings

  /// Writes the session's hook payloads after the event id `after`, through
  /// the event id `through`, to Fixtures/claude/<step>.jsonl.
  func record(
    _ step: String, _ id: String, after: Int64, through: Int64 = .max, prompts: [String] = [],
    commands: [String] = []
  ) throws {
    let context = Recording.Context(
      cwd: [sbd.work, cwd], home: NSHomeDirectory(), nonce: nonce, prompts: prompts, commands: commands)
    let payloads = try sbd.stepPayloads(id, after: after, through: through)
    try FileManager.default.createDirectory(atPath: Recording.folder, withIntermediateDirectories: true)
    try Recording.write(Recording.normalize(payloads, context), to: "\(Recording.folder)/\(step).jsonl")
    try "\(ClaudeTier.version)\n".write(toFile: "\(Recording.folder)/VERSION", atomically: true, encoding: .utf8)
  }
}
