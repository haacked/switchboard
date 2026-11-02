import Foundation
import SwitchboardCore
import Testing

struct TestError: Error, CustomStringConvertible {
  let description: String
}

extension Home {
  /// Names the test process that owns the home, for Fixtures/reap.
  func setOwner(_ pid: pid_t) throws {
    try String(pid).write(toFile: "\(path)/owner.pid", atomically: true, encoding: .utf8)
  }
}

/// A private sbd for one test, with its own SB_HOME, tmux server, and stub
/// claude (Fixtures/claude-stub). Fixtures/reap ends the processes that the
/// home started: deinit runs it, and so does a watcher process after this
/// test process exits, as when it crashes or is killed.
final class Instance {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  /// The folder that holds sb and sbd. SwiftPM builds them next to the test
  /// bundle, so `swift test -c release` uses the release builds. `SB_BIN_DIR`
  /// overrides the folder.
  static let bin = binDir(
    testBundle: Bundle(for: Instance.self).bundlePath, override: ProcessInfo.processInfo.environment["SB_BIN_DIR"])

  static func binDir(testBundle: String, override: String?) -> String {
    override ?? URL(fileURLWithPath: testBundle).deletingLastPathComponent().path
  }
  static let stub = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/claude-stub").path
  static let slowShell = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/slow-shell").path
  static let reap = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/reap").path

  /// Runs once per test process, before the first home.
  private static let watcher: Void = { try? watch(getpid()) }()

  /// Starts a process that reaps the homes of test processes that exited,
  /// both now and after `pid` exits.
  static func watch(_ pid: pid_t) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: reap)
    p.arguments = ["--watch", String(pid)]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
  }

  let home: Home
  let client: Client
  /// The CLAUDE_CONFIG_DIR that sbd inherits, or nil for Claude's default
  /// account.
  let inheritedAccount: String?

  /// The account that sbd inherits.
  enum Inherited {
    /// An empty folder in the home, which only the stub's transcripts use.
    case scratch
    /// None, so sbd runs under Claude's default account.
    case unset
    /// The test runner's, which the real claude is logged in to.
    case runner
  }
  private var process: Process?

  /// The folder is under /tmp, because a Unix socket path can't exceed 103
  /// bytes. The stop rule runs every 0.2 s, so idle stops come quickly. The
  /// panes run /bin/sh by default, because a login shell with the user's
  /// setup can take 1.5 s to start, and the tests start dozens of panes at once.
  /// Each account is a Claude config folder that this creates in the home.
  /// The config lists only those, so a test never reads the user's accounts.
  /// The GitHub poller runs only when a test asks.
  init(
    idleStopSeconds: Int = 600, testClock: Bool = true, shell: String = "/bin/sh", accounts: [String] = [],
    inheriting: Inherited = .scratch, config extra: [String: JSON] = [:]
  ) throws {
    _ = Instance.watcher
    var template = Array("/tmp/sbt.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    let path = String(cString: dir)
    home = Home(path: path)
    try home.setOwner(getpid())
    switch inheriting {
    case .scratch: inheritedAccount = "\(path)/inherited-account"
    case .unset: inheritedAccount = nil
    case .runner: inheritedAccount = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    }
    sbdAgent = "\(path)/sbd-agent.sock"
    let folders = accounts.map { "\(path)/\($0)" }
    for folder in folders {
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: "\(folder)/.claude.json", contents: Data("{}".utf8))
    }
    let config: [String: JSON] = [
      "claude": .string(Instance.stub), "idleStopSeconds": .number(Double(idleStopSeconds)), "tickSeconds": 0.2,
      "worktreeRoot": .string("\(home.path)/worktrees"), "testClock": .bool(testClock), "shell": .string(shell),
      "claudeConfigDirs": .array(folders.map(JSON.string)), "github": ["pollSeconds": 0],
      // Tests that read the stub's arguments don't expect the nudge in them.
      "triage": ["systemPrompt": ""],
    ]
    try JSON.object(config.merging(extra) { $1 }).text.write(toFile: home.config, atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: home.log, contents: nil)
    client = Client(home: home)
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    try startSbd()
  }

  deinit {
    _ = try? Instance.reapHome(home.path)
  }

  /// Runs Fixtures/reap on the home.
  @discardableResult
  static func reapHome(_ home: String) throws -> CommandResult {
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = home
    return try runCommand(reap, [], env: env)
  }

  var work: String { "\(home.path)/work" }

  /// The SSH_AUTH_SOCK that sbd runs with. A test changes it before it starts
  /// sbd again.
  var sbdAgent: String

  /// Extra environment for the sbd that `startSbd` starts.
  var sbdEnvironment: [String: String] = [:]

  func startSbd() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sbd")
    // reap finds sbd by the home in its arguments.
    p.arguments = ["--home", home.path]
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = home.path
    // sbd inherits an account, as it does from a user who exports one. A test
    // can then tell the account that sbd sets from the one it inherited.
    env["CLAUDE_CONFIG_DIR"] = inheritedAccount
    // A fixed agent lets a test tell sbd's own SSH agent from a terminal's.
    env["SSH_AUTH_SOCK"] = sbdAgent
    env.merge(sbdEnvironment) { $1 }
    p.environment = env
    let log = FileHandle(forWritingAtPath: home.log)!
    log.seekToEndOfFile()
    p.standardOutput = log
    p.standardError = log
    try p.run()
    process = p
    try waitFor("sbd answers", timeout: 10) { (try? client.call("ping", timeout: 1)) != nil }
  }

  /// The pid of the sbd that `startSbd` started.
  var sbdPid: Int { Int(process?.processIdentifier ?? 0) }

  func stopSbd() {
    guard let p = process else { return }
    p.terminate()
    p.waitUntilExit()
    process = nil
  }

  /// Runs sb and returns its output. It throws when sb fails.
  @discardableResult
  func sb(_ args: String..., env extra: [String: String] = [:]) throws -> String {
    try sb(args, env: extra)
  }

  @discardableResult
  func sb(_ args: [String], env extra: [String: String] = [:]) throws -> String {
    let r = try run(args, env: extra)
    guard r.status == 0 else { throw TestError(description: "sb \(args.joined(separator: " ")) failed: \(r.stderr)") }
    return r.stdout
  }

  /// Runs sb with this instance's SB_HOME, whatever its exit status.
  /// CLAUDECODE and SB_SESSION_ID mark a command that Claude runs in a
  /// session, so they come only from `env`.
  func run(_ args: String...) throws -> CommandResult { try run(args) }

  func run(_ args: [String], env extra: [String: String] = [:]) throws -> CommandResult {
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = home.path
    env["CLAUDECODE"] = nil
    env["SB_SESSION_ID"] = nil
    env.merge(extra) { $1 }
    return try runCommand("\(Instance.bin)/sb", args, env: env)
  }

  /// Sets one key of config.json and restarts sbd, which reads the config when it starts.
  func restart(setting key: String, to value: JSON) throws {
    var config = try #require(JSON.parse(try String(contentsOfFile: home.config, encoding: .utf8))?.object)
    config[key] = value
    try JSON.object(config).text.write(toFile: home.config, atomically: true, encoding: .utf8)
    stopSbd()
    try startSbd()
  }

  /// The full path of an account that `init` created.
  func account(_ name: String) -> String { "\(home.path)/\(name)" }

  /// The rows that the stub prints for `claude agents --json` in the account.
  func writeAgents(_ account: String, _ rows: [JSON]) throws {
    try JSON.array(rows).text.write(toFile: "\(self.account(account))/agents.json", atomically: true, encoding: .utf8)
  }

  func writeTranscript(_ account: String, _ sessionId: String, _ lines: [JSON]) throws {
    let dir = "\(self.account(account))/projects/-test"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try lines.map { $0.text + "\n" }.joined().write(
      toFile: "\(dir)/\(sessionId).jsonl", atomically: true, encoding: .utf8)
  }

  /// A git repo in the home, on branch main with one empty commit.
  func makeRepo(_ name: String = "repo") throws -> String { try Repos.create("\(home.path)/\(name)") }

  /// A linked worktree of the repo on a new branch, in <home>/trees/<repo>/<branch>.
  func addWorktree(_ repo: String, _ branch: String) throws -> String {
    let dir = "\(home.path)/trees/\((repo as NSString).lastPathComponent)/\(branch)"
    try git(repo, "worktree", "add", "-b", branch, dir)
    return dir
  }

  @discardableResult
  func git(_ dir: String, _ args: String...) throws -> String {
    let r = try runCommand("/usr/bin/git", ["-C", dir] + args)
    guard r.status == 0 else { throw TestError(description: "git \(args.joined(separator: " ")) failed: \(r.stderr)") }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func new(prompt: String? = nil, name: String = "t") throws -> SessionSummary {
    var args: [String: JSON] = ["path": .string(work), "name": .string(name)]
    if let prompt { args["prompt"] = .string(prompt) }
    return try client.call("new", args, as: SessionSummary.self)
  }

  func get(_ id: String) throws -> SessionSummary { try client.session(id) }

  /// Attaches a control-mode tmux client to the session's Claude pane, which
  /// counts as a terminal that shows the session. It returns a function that
  /// detaches the client.
  func attach(_ id: String) throws -> () -> Void {
    let terminals = try client.terminals(id)
    let attached = Process()
    attached.executableURL = URL(fileURLWithPath: terminals.tmux)
    attached.arguments = ["-S", terminals.socket, "-C", "attach-session", "-t", "=\(terminals.claude)"]
    let input = Pipe()
    attached.standardInput = input
    attached.standardOutput = FileHandle.nullDevice
    try attached.run()
    return { input.fileHandleForWriting.write(Data("detach-client\n".utf8)) }
  }

  /// sbd runs a tick at the new time before it replies. The tick resolves
  /// due waits only when no shared MCP server is starting.
  func advanceClock(_ ms: Int64) throws {
    _ = try client.call("clock", ["advance": .number(Double(ms))])
  }

  /// Waits until the stub reports the session to `claude agents` with the status.
  func waitForStubStatus(_ s: SessionSummary, _ status: String) throws {
    try waitFor("the stub to report \(status)") {
      let files = FileManager.default.enumerator(atPath: home.path)?.compactMap { $0 as? String } ?? []
      return files.contains {
        $0.hasSuffix("/status/\(s.claudeSessionId)")
          && (try? String(contentsOfFile: "\(home.path)/\($0)", encoding: .utf8))?.contains("\"\(status)\"") == true
      }
    }
  }

  /// The pid that the stub wrote to the file in SB_HOME, or nil before it wrote one.
  func stubPid(_ file: String) -> pid_t? {
    guard let text = try? String(contentsOfFile: "\(home.path)/\(file)", encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Waits for the session to match, and returns it.
  @discardableResult
  func waitFor(_ id: String, _ what: String, timeout: Double = 15, _ match: (SessionSummary) -> Bool) throws
    -> SessionSummary
  {
    try waitFor(what, timeout: timeout, fetch: { try get(id) }, until: match)
  }

  /// Waits until a fetched value matches, and returns it. A fetch that
  /// throws or returns nil counts as no match.
  func waitFor<T>(_ what: String, timeout: Double = 15, fetch: () throws -> T?, until match: (T) -> Bool) throws -> T {
    var last: T?
    try waitFor(what, timeout: timeout) {
      last = try? fetch()
      return last.map(match) ?? false
    }
    return last!
  }

  func waitFor(_ what: String, timeout: Double = 15, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if try condition() { return }
      usleep(100_000)
    }
    let log = (try? String(contentsOfFile: home.log, encoding: .utf8)) ?? ""
    throw TestError(description: "timed out waiting for \(what). sbd log:\n\(log)")
  }

  func stubArgs() -> [String] { stubCalls().map(\.args) }

  /// Each run of the stub claude, oldest first: its CLAUDE_CONFIG_DIR, its
  /// SSH_AUTH_SOCK, and its arguments. A variable that was unset reads as
  /// empty.
  func stubCalls() -> [(account: String, agent: String, args: String)] {
    let text = (try? String(contentsOfFile: "\(home.path)/stub-calls.log", encoding: .utf8)) ?? ""
    // The text after the last NUL is empty, or a record that the stub is writing.
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map { record in
      let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
      return (account: fields[0], agent: fields[1], args: fields[2])
    }
  }

  func events(_ id: String, after: Int64 = 0) throws -> [Event] {
    try client.call(
      "events", ["session": .string(id), "since": .number(Double(after)), "limit": 10_000], as: [Event].self)
  }
}
