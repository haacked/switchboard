import Foundation
import SwitchboardCore
import Testing

struct TestError: Error, CustomStringConvertible {
  let description: String
}

// Temporary: prints how long each phase of an integration test takes, for profiling on CI.
func profilePhase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
  let start = Date()
  defer {
    let secs = Date().timeIntervalSince(start)
    let id = Test.current.map { "\($0.id)" } ?? "?"
    let phase = name.replacingOccurrences(of: " ", with: "_")
    FileHandle.standardOutput.write(Data("phase-seconds \(String(format: "%.3f", secs)) \(phase) \(id)\n".utf8))
  }
  return try body()
}

/// The path with every symlink resolved, as `pwd -P` prints it. /tmp is a link to /private/tmp.
func real(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
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
  let idleStopSeconds: Int
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
  /// The GitHub poller and the usage reader run only when a test asks, and the
  /// Depot poller is off.
  init(
    idleStopSeconds: Int = 600, testClock: Bool = true, shell: String = "/bin/sh", accounts: [String] = [],
    inheriting: Inherited = .scratch, config extra: [String: JSON] = [:], startingSbd: Bool = true
  ) throws {
    Blocking.requireSlot()
    _ = Instance.watcher
    self.idleStopSeconds = idleStopSeconds
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
      // No test reaches the real Depot API. DepotTests point sbd at a FakeDepot.
      "depot": ["enabled": false],
      "usage": ["pollSeconds": 0, "keychain": false],
      // No test runs the real trunk. A test that needs one writes a fake here.
      "trunk": ["path": .string("\(path)/trunk")],
      // Tests that read the stub's arguments don't expect the nudge in them.
      "triage": ["systemPrompt": ""],
      // Nor do they expect --permission-mode auto. AutoModeTests turn it on.
      "autoMode": false,
      // Tests that start many sessions don't expect sbd to stop the idle ones.
      "liveCap": 50,
    ]
    try JSON.object(config.merging(extra) { $1 }).text.write(toFile: home.config, atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: home.log, contents: nil)
    client = Client(home: home)
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    if startingSbd { try startSbd() }
  }

  deinit {
    _ = profilePhase("reap") { try? Instance.reapHome(home.path) }
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

  func startSbd() throws { try profilePhase("startSbd") { try startSbdTimed() } }

  func startSbdTimed() throws {
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

  /// Ends sbd with SIGKILL, as a crash or a forced quit does. sbd runs no
  /// handler, so it records nothing more and leaves its socket file behind.
  func killSbd() {
    guard let p = process else { return }
    kill(p.processIdentifier, SIGKILL)
    p.waitUntilExit()
    process = nil
  }

  /// A gate file in the home. While `hold-paste` exists, sbd holds each paste
  /// on the paste queue after it accepted the message and before it records
  /// `pasting`. While `hold-delivered` exists, sbd holds each paste after
  /// `host.paste` returned, Enter included, and before it records `delivered`.
  /// Neither gate blocks the state queue.
  func gate(_ name: String) -> String { "\(home.path)/\(name)" }

  func hold(_ gate: String) {
    FileManager.default.createFile(atPath: self.gate(gate), contents: nil)
  }

  func release(_ gate: String) throws {
    try FileManager.default.removeItem(atPath: self.gate(gate))
  }

  /// The lines that the stub read from its terminal, oldest first, with the paste markers.
  func stubInput() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/stub-input.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// How many lines that the stub read contain the text.
  func stubInputCount(_ text: String) -> Int { stubInput().filter { $0.contains(text) }.count }

  /// How many pastes reached the stub with their Enter. The stub reads the
  /// line that holds a paste's end marker only once Enter's new line arrives.
  func completePastes() -> Int { stubInputCount("\u{1B}[201~") }

  /// Whether the session's transcript holds a line with the text.
  func transcriptContains(_ s: SessionSummary, _ text: String) -> Bool {
    let files = FileManager.default.enumerator(atPath: home.path)?.compactMap { $0 as? String } ?? []
    return files.contains {
      $0.hasSuffix("/\(s.claudeSessionId).jsonl")
        && (try? String(contentsOfFile: "\(home.path)/\($0)", encoding: .utf8))?.contains(text) == true
    }
  }

  /// Runs sb and returns its output. It throws when sb fails.
  @discardableResult
  func sb(_ args: String..., env extra: [String: String] = [:]) throws -> String {
    try sb(args, env: extra)
  }

  @discardableResult
  func sb(_ args: [String], env extra: [String: String] = [:]) throws -> String {
    try profilePhase("sb:" + (args.first ?? "")) { try sbTimed(args, env: extra) }
  }

  func sbTimed(_ args: [String], env extra: [String: String] = [:]) throws -> String {
    let r = try run(args, env: extra)
    guard r.status == 0 else { throw TestError(description: "sb \(args.joined(separator: " ")) failed: \(r.stderr)") }
    return r.stdout
  }

  /// The environment of an sb command with this instance's SB_HOME.
  /// CLAUDECODE and SB_SESSION_ID mark a command that Claude runs in a
  /// session, so they come only from `extra`.
  func environment(_ extra: [String: String] = [:]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = home.path
    env["CLAUDECODE"] = nil
    env["SB_SESSION_ID"] = nil
    env.merge(extra) { $1 }
    return env
  }

  /// Runs sb with this instance's SB_HOME, whatever its exit status.
  func run(_ args: String...) throws -> CommandResult { try run(args) }

  func run(_ args: [String], env extra: [String: String] = [:]) throws -> CommandResult {
    try profilePhase("run:" + (args.first ?? "")) { try runTimed(args, env: extra) }
  }

  func runTimed(_ args: [String], env extra: [String: String] = [:]) throws -> CommandResult {
    try runCommand("\(Instance.bin)/sb", args, env: environment(extra))
  }

  /// The settings in config.json.
  func config() throws -> [String: JSON] {
    try #require(JSON.parse(try String(contentsOfFile: home.config, encoding: .utf8))?.object)
  }

  /// Sets one key of config.json. sbd reads the config only when it starts.
  func set(_ key: String, to value: JSON) throws {
    var config = try config()
    config[key] = value
    try JSON.object(config).text.write(toFile: home.config, atomically: true, encoding: .utf8)
  }

  /// Sets one key of config.json and restarts sbd, which reads the config when it starts.
  func restart(setting key: String, to value: JSON) throws {
    try set(key, to: value)
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
  func makeRepo(_ name: String = "repo", origin: String? = nil) throws -> String {
    try Repos.create("\(home.path)/\(name)", origin: origin)
  }

  /// A linked worktree of the repo on a new branch, in <home>/trees/<repo>/<branch>.
  func addWorktree(_ repo: String, _ branch: String) throws -> String {
    let dir = "\(home.path)/trees/\((repo as NSString).lastPathComponent)/\(branch)"
    try git(repo, "worktree", "add", "-b", branch, dir)
    return dir
  }

  @discardableResult
  func git(_ dir: String, _ args: String...) throws -> String {
    try Repos.git(dir, args)
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

  /// Moves the clock until the tick records `running` for a claude that has
  /// not sent SessionStart. Each clock request runs a tick. A tick that sees
  /// the claude as still starting restarts its 10 s, so one step can miss.
  /// The steps stay under the 60 s that a launch's prompt counts as on its way.
  func passUnreportedFallback(_ id: String, after mark: Int64) throws {
    for _ in 0..<4 {
      try advanceClock(11_000)
      if try events(id, after: mark).contains(where: { $0.kind == "running" }) { return }
    }
    throw TestError(description: "the tick never recorded running for \(id)")
  }

  /// Moves the clock past `idleStopSeconds` and waits until the session's claude stops.
  func passIdleStop(_ id: String) throws {
    try advanceClock(Int64(idleStopSeconds + 1) * 1000)
    try waitFor(id, "the idle stop", timeout: 10) { !$0.live }
  }

  /// Passes the idle stop and waits for the stopped claude's SessionEnd. The stop's `stopped` event ends `live`
  /// before that hook arrives. The hook moves `lastActivity`. A test that moves the clock past the stale time
  /// calls this first. One move past the stale time also passes the idle stop. The SessionEnd that arrives after
  /// that tick then ends the Stale state.
  func passIdleStopToSessionEnd(_ id: String) throws {
    let mark = try lastEventId(id)
    try passIdleStop(id)
    try waitFor("the SessionEnd after the idle stop of \(id)", timeout: 10) {
      try events(id, after: mark).contains { $0.kind == "SessionEnd" }
    }
  }

  /// sbd's clock, in ms since the epoch.
  func now() throws -> Int64 {
    Int64(try #require(try client.call("clock")["now"]?.int))
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

  /// The session's Claude pane as sbd reads it, with wrapped lines joined.
  func screen(_ id: String, colors: Bool = false) throws -> String {
    try client.call("screen", ["session": .string(id), "colors": .bool(colors)]).string ?? ""
  }

  /// Presses one key in the session's Claude pane, by its tmux key name,
  /// such as Down or Escape.
  func press(_ id: String, _ key: String) throws { try sendKeys(id, [key]) }

  /// Types the text into the session's Claude pane without Enter, so it stays in the prompt box.
  func typeDraft(_ id: String, _ text: String) throws { try sendKeys(id, ["-l", text]) }

  /// Sets the height of the session's Claude pane. tmux moves the top rows
  /// into the history when the pane shrinks, and brings them back when it grows.
  func resize(_ id: String, rows: Int) throws {
    let t = try client.terminals(id)
    let r = try runCommand(t.tmux, ["-S", t.socket, "resize-window", "-t", "=\(t.claude):", "-y", String(rows)])
    guard r.status == 0 else { throw TestError(description: "tmux resize-window -y \(rows): \(r.stderr)") }
  }

  private func sendKeys(_ id: String, _ keys: [String]) throws {
    let t = try client.terminals(id)
    let r = try runCommand(t.tmux, ["-S", t.socket, "send-keys", "-t", "=\(t.claude):"] + keys)
    guard r.status == 0 else { throw TestError(description: "tmux send-keys \(keys): \(r.stderr)") }
  }

  /// Whether the session's prompt box shows no typed text, read from the
  /// colored screen that sbd checks before a paste.
  func promptIsEmpty(_ id: String) throws -> Bool {
    ClaudeScreen.promptIsEmpty(try screen(id, colors: true))
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
    do {
      return try waitFor(what, timeout: timeout, fetch: { try get(id) }, until: match)
    } catch let error as TestError {
      let events = ((try? self.events(id)) ?? []).map { "\($0.t) \($0.kind)" }.joined(separator: "\n")
      throw TestError(description: "\(error.description)\nevents:\n\(events)")
    }
  }

  /// Waits until a fetched value matches, and returns it. A fetch that
  /// throws or returns nil counts as no match.
  func waitFor<T>(_ what: String, timeout: Double = 15, fetch: () throws -> T?, until match: (T) -> Bool) throws -> T {
    var last: T?
    do {
      try waitFor(what, timeout: timeout) {
        last = try? fetch()
        return last.map(match) ?? false
      }
    } catch let error as TestError {
      throw TestError(description: "\(error.description)\nlast value: \(String(describing: last))")
    }
    return last!
  }

  /// A CI runner has 3 CPUs, and it starts sbd, tmux, and a stub claude several times slower than a laptop does.
  /// A wait that succeeds returns at once, so only a failing wait takes longer.
  static let timeoutScale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 3

  func waitFor(_ what: String, timeout: Double = 15, _ condition: () throws -> Bool) throws {
    try profilePhase("wait:" + String(what.prefix(50))) { try waitForTimed(what, timeout: timeout, condition) }
  }

  func waitForTimed(_ what: String, timeout: Double = 15, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout * Instance.timeoutScale)
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
  func stubCalls() -> [(account: String, agent: String, args: String)] { stubCalls(in: home.path) }

  /// The runs that the stub logged in the folder, which was its SB_HOME.
  func stubCalls(in folder: String) -> [(account: String, agent: String, args: String)] {
    let text = (try? String(contentsOfFile: "\(folder)/stub-calls.log", encoding: .utf8)) ?? ""
    // The text after the last NUL is empty, or a record that the stub is writing.
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map { record in
      let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
      return (account: fields[0], agent: fields[1], args: fields[2])
    }
  }

  /// What the stub's hooks printed for the conversation, oldest first.
  func hookOutputs(_ claudeSessionId: String) -> [JSON] { stubLog("hook-output.log", claudeSessionId) }

  /// The decisions that the conversation's PermissionRequest hooks answered
  /// with, oldest first.
  func permissionAnswers(_ claudeSessionId: String) -> [JSON] {
    stubLog("permission-answers.log", claudeSessionId)
  }

  /// The JSON records of the conversation in one of the stub's logs. Each
  /// record is the conversation's id, a tab, and the JSON, with a NUL after it.
  private func stubLog(_ name: String, _ claudeSessionId: String) -> [JSON] {
    let text = (try? String(contentsOfFile: "\(home.path)/\(name)", encoding: .utf8)) ?? ""
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().compactMap { record in
      let fields = record.split(separator: "\t", maxSplits: 1).map(String.init)
      guard fields.count == 2, fields[0] == claudeSessionId else { return nil }
      return try? JSONCoding.decoder.decode(JSON.self, from: Data(fields[1].utf8))
    }
  }

  func events(_ id: String, after: Int64 = 0) throws -> [Event] {
    try client.call(
      "events", ["session": .string(id), "since": .number(Double(after)), "limit": 10_000], as: [Event].self)
  }
}

/// Remote hosts, which reach Fixtures/ssh-stub in place of ssh.
extension Instance {
  static let sshStub = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/ssh-stub").path

  /// A config.json `hosts` entry for an ssh host.
  static func sshHost(_ destination: String) -> JSON { ["kind": "ssh", "destination": .string(destination)] }

  /// The config.json keys that give sbd these hosts and the stub as its ssh.
  static func hostsConfig(_ hosts: [String: JSON]) -> [String: JSON] {
    ["ssh": .string(sshStub), "hosts": .object(hosts)]
  }

  /// Where the stub keeps its files, and where a test writes `refuse` and `hang`.
  var sshStubFolder: String { "\(home.path)/ssh-stub" }

  func setSSHStub(_ file: String, _ text: String = "") throws {
    try FileManager.default.createDirectory(atPath: sshStubFolder, withIntermediateDirectories: true)
    try text.write(toFile: "\(sshStubFolder)/\(file)", atomically: true, encoding: .utf8)
  }

  func clearSSHStub(_ file: String) throws {
    try FileManager.default.removeItem(atPath: "\(sshStubFolder)/\(file)")
  }

  var sshStubLog: String { (try? String(contentsOfFile: "\(sshStubFolder)/log", encoding: .utf8)) ?? "" }

  /// The arguments of each run of the stub as a master, oldest first.
  func sshStubMasters() -> [[String]] {
    sshStubLog.split(separator: "\n").compactMap { line in
      guard let argv = JSON.parse(String(line))?["argv"]?.array?.compactMap(\.string), argv.contains("-M") else {
        return nil
      }
      return argv
    }
  }

  /// The pid of the master that last started for the destination, or nil before one did. The
  /// stub names its pid file after the control socket.
  func sshStubPid(_ destination: String) throws -> pid_t? {
    let r = try runCommand(Instance.sshStub, ["-G", "-o", "ControlPath=\(home.path)/ssh/%C", "--", destination])
    let line = try #require(r.stdout.split(separator: "\n").first { $0.hasPrefix("controlpath ") })
    let socket = (String(line.dropFirst("controlpath ".count)) as NSString).lastPathComponent
    return stubPid("ssh-stub/\(socket).pid")
  }

  func hosts() throws -> [HostStatus] { try client.call("hosts", as: [HostStatus].self) }

  /// Waits for the host to match, and returns it.
  @discardableResult
  func waitForHost(_ name: String, _ what: String, timeout: Double = 15, _ match: (HostStatus) -> Bool) throws
    -> HostStatus
  {
    try waitFor(what, timeout: timeout, fetch: { try hosts().first { $0.name == name } }, until: match)
  }

  @discardableResult
  func waitForLink(_ name: String, _ state: LinkState) throws -> HostStatus {
    try waitForHost(name, "\(name)'s link to be \(state.rawValue)") { $0.link == state }
  }

  /// Drops the host's connection by killing the stub's master, which leaves its socket file
  /// behind as a killed ssh does. It returns the pid that it killed.
  @discardableResult
  func dropLink(_ name: String) throws -> pid_t {
    let host = try #require(try hosts().first { $0.name == name })
    let destination = try #require(host.destination)
    let pid = try #require(try sshStubPid(destination))
    kill(pid, SIGKILL)
    return pid
  }
}

/// The calls on this Mac's machine and site, which sbd writes to a file when `machineLog` is on.
extension Instance {
  /// The config.json key that turns the log on.
  static let machineLogConfig: [String: JSON] = ["machineLog": true]

  /// One line of the log.
  struct MachineCall: CustomStringConvertible {
    var json: JSON
    /// Every key, string, and whole number of the line at any depth, which hold the member's name and its arguments.
    var words: [String]
    var description: String { json.text }

    init(_ json: JSON) {
      self.json = json
      words = MachineCall.words(json)
    }

    private static func words(_ value: JSON) -> [String] {
      switch value {
      case .string(let text): [text]
      case .number: value.int.map { [String($0)] } ?? []
      case .array(let items): items.flatMap(words)
      case .object(let fields): fields.flatMap { [$0.key] + words($0.value) }
      case .null, .bool: []
      }
    }

    func has(_ word: String) -> Bool { words.contains(word) }

    /// Whether the call ran the program, whatever folder holds it.
    func runs(_ program: String) -> Bool {
      has("run") && words.contains { ($0 as NSString).lastPathComponent == program }
    }
  }

  var machineLog: String { "\(home.path)/mac-machine.log" }

  /// The log's whole lines, oldest first. It throws for a line that is not one JSON object. It leaves out the text
  /// after the last newline, which sbd may still be writing.
  func machineCalls() throws -> [MachineCall] {
    guard let text = try? String(contentsOfFile: machineLog, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line in
      guard let json = JSON.parse(String(line)), json.object != nil else {
        throw TestError(description: "\(machineLog) holds a line that is not a JSON object: \(line)")
      }
      return MachineCall(json)
    }
  }

  /// Waits for a logged call that matches, and returns it.
  func waitForMachineCall(_ what: String, _ match: (MachineCall) -> Bool) throws -> MachineCall {
    try waitFor(what, fetch: { try machineCalls().first(where: match) }, until: { _ in true })
  }
}

/// The box of a remote host. Fixtures/ssh-stub runs every remote command on this Mac with HOME set to a folder in
/// the test's home, so that folder stands in for the host's home.
extension Instance {
  static let boxDestination = "haacked@mini.local"

  /// The HOME of every command that the stub runs.
  var boxHome: String { "\(sshStubFolder)/home" }

  /// The folder that Switchboard keeps on the host, which is the SB_HOME of a remote pane.
  var boxSB: String { "\(boxHome)/.sb" }

  /// A config.json `hosts` entry for an ssh host whose claude is the claude stub and whose panes run /bin/sh.
  static func remoteHost(_ destination: String = boxDestination, _ extra: [String: JSON] = [:]) -> JSON {
    let host: [String: JSON] = [
      "kind": "ssh", "destination": .string(destination), "claude": .string(stub), "shell": "/bin/sh",
    ]
    return .object(host.merging(extra) { $1 })
  }

  /// A sbd with the host `mini`, the stub as its ssh, and the Mac's machine log on. `mini` takes the extra host
  /// keys, and config.json takes the extra settings. With `boxBin`, the box's shell finds the programs of
  /// `boxBin` before any other, because the stub's remote shell inherits sbd's PATH.
  static func remote(
    host extra: [String: JSON] = [:], hosts more: [String: JSON] = [:], config settings: [String: JSON] = [:],
    boxBin: Bool = false
  ) throws -> Instance {
    let sbd = try unstartedRemote(host: extra, hosts: more, config: settings, boxBin: boxBin)
    try sbd.startSbd()
    return sbd
  }

  /// The instance that `remote` returns, before sbd starts. A test that changes the config or the box's programs
  /// here does not have to start sbd again.
  static func unstartedRemote(
    host extra: [String: JSON] = [:], hosts more: [String: JSON] = [:], config settings: [String: JSON] = [:],
    boxBin: Bool = false
  ) throws -> Instance {
    let hosts = ["mini": remoteHost(boxDestination, extra)].merging(more) { $1 }
    let sbd = try Instance(
      config: hostsConfig(hosts).merging(machineLogConfig) { $1 }.merging(settings) { $1 }, startingSbd: false)
    try sbd.prepareBox()
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    var folders: [String] = []
    if boxBin {
      try FileManager.default.createDirectory(atPath: sbd.boxBin, withIntermediateDirectories: true)
      folders.append(sbd.boxBin)
    }
    if let python = Instance.python {
      let folder = "\(sbd.home.path)/python-bin"
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(atPath: "\(folder)/python3", withDestinationPath: python)
      folders.append(folder)
    }
    let first = folders.map { "\($0):" }.joined()
    sbd.sbdEnvironment["PATH"] = first + path
    if boxBin { sbd.sbdEnvironment["SB_SSH_STUB_PATH"] = first + path }
    return sbd
  }

  /// The interpreter that `python3` on the PATH runs. The ssh stub and the hooks on the box start python3 many
  /// times in each test. A version manager's shim, such as pyenv's, adds about 0.4 s to each start, so a remote
  /// sbd finds this interpreter first on its PATH.
  static let python: String? = {
    guard let found = findExecutable("python3"),
      let r = try? runCommand(found, ["-c", "import sys; print(sys.executable)"]), r.status == 0
    else { return nil }
    let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.hasPrefix("/") ? path : nil
  }()

  /// Creates the box's home. The claude stub keeps its transcripts in `$SB_HOME/claude` when CLAUDE_CONFIG_DIR is
  /// unset, which is `<box home>/.sb/claude` for a remote pane. sbd looks for a remote transcript under
  /// `<box home>/.claude`, so that name links to the stub's folder.
  func prepareBox() throws {
    try FileManager.default.createDirectory(atPath: boxHome, withIntermediateDirectories: true)
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(boxHome)/.claude")) == nil {
      try FileManager.default.createSymbolicLink(atPath: "\(boxHome)/.claude", withDestinationPath: ".sb/claude")
    }
  }

  /// A folder under the box's home, which a test names as `~/<name>` in `sb new --host`.
  @discardableResult
  func makeBoxFolder(_ name: String = "sb-box-repo") throws -> String {
    let path = "\(boxHome)/\(name)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  /// A git repo that exists only under the box's home, on branch main with one empty commit.
  @discardableResult
  func makeBoxRepo(_ name: String = "sb-box-repo") throws -> String { try Repos.create("\(boxHome)/\(name)") }

  /// Runs `sb new <folder> --host <host> --json` and returns what it printed as JSON. sb gets the folder as typed.
  func newOnHost(_ folder: String = "~/sb-box-repo", host: String = "mini", _ more: String...) throws -> JSON {
    try #require(JSON.parse(try sb(["new", folder, "--host", host, "--json"] + more)))
  }

  /// The id of the session in a summary that `newOnHost` returned.
  func id(of summary: JSON) throws -> String { try #require(summary["id"]?.string) }

  /// The session's summary as JSON, which holds the keys that `SessionSummary` may not decode yet.
  func summaryJSON(_ id: String) throws -> JSON { try #require(JSON.parse(try sb("get", id, "--json"))) }

  /// Runs tmux against the box's tmux server, whatever its exit status.
  func boxTmux(_ args: String...) throws -> CommandResult {
    let tmux = try #require(findExecutable("tmux"))
    return try runCommand(tmux, ["-S", "\(boxSB)/tmux.sock"] + args)
  }

  /// The names of the tmux sessions on the box's tmux server, or none when no server runs there.
  func boxTmuxSessions() throws -> [String] {
    let r = try boxTmux("list-sessions", "-F", "#{session_name}")
    return r.status == 0 ? r.stdout.split(separator: "\n").map(String.init).sorted() : []
  }

  /// Each run of the stub claude on the box, oldest first. A remote pane's SB_HOME is the box's `.sb`.
  func boxStubCalls() -> [(account: String, agent: String, args: String)] { stubCalls(in: boxSB) }

  /// The arguments of each run of the stub claude in a pane on the box, without its `agents` runs.
  func boxStubArgs() -> [String] { boxStubCalls().map(\.args).filter { !$0.hasPrefix("agents") } }

  /// The session's transcript files under the box's home.
  func boxTranscripts(_ claudeSessionId: String) -> [String] {
    let files = FileManager.default.enumerator(atPath: boxSB)?.compactMap { $0 as? String } ?? []
    return files.filter { $0.hasSuffix("/\(claudeSessionId).jsonl") }.map { "\(boxSB)/\($0)" }
  }

  /// The lines of the Mac's machine log that hold any of the texts, at any depth and inside any word.
  func macCalls(holding texts: [String]) throws -> [MachineCall] {
    try machineCalls().filter { call in texts.contains { !$0.isEmpty && call.json.text.contains($0) } }
  }

  /// The texts that name a remote session: its id, its pane names, its folder, and the box's home, each as typed
  /// and with its symlinks resolved.
  func namesOfRemoteSession(_ id: String, cwd: String) -> [String] {
    Array(Set([id, "\(id)-claude", "\(id)-shell", cwd, real(cwd), boxHome, real(boxHome)]))
  }

  // MARK: The box's programs

  /// A folder of programs that the box's shell finds first. Only a sbd from `remote(boxBin: true)` uses it.
  var boxBin: String { "\(home.path)/box-bin" }

  /// Puts a `ps` on the box that waits before it lists every process. While the home's `ps-gate` exists, a `ps -A`
  /// creates `ps-waiting` and waits for `ps-gate` to go. Every other `ps` runs at once.
  func installBoxPsGate() throws {
    let script = """
      #!/bin/sh
      case " $* " in
      *" -A "*)
        if [ -e '\(gate("ps-gate"))' ]; then
          : >'\(gate("ps-waiting"))'
          while [ -e '\(gate("ps-gate"))' ]; do sleep 0.05; done
        fi
        ;;
      esac
      exec /bin/ps "$@"

      """
    try script.write(toFile: "\(boxBin)/ps", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(boxBin)/ps")
  }

  // MARK: The link

  /// Drops the host's link and keeps it down: the stub refuses every new master with the text.
  func dropLinkAndRefuse(_ refusal: String, host name: String = "mini") throws {
    try setSSHStub("refuse", refusal + "\n")
    try dropLink(name)
    try waitForHost(name, "\(name)'s link to be unreachable with the refusal") {
      $0.link == .unreachable && $0.error == refusal
    }
  }

  /// Lets the stub connect again and waits for the link.
  func restoreLink(_ name: String = "mini") throws {
    try clearSSHStub("refuse")
    try connectHost(name)
  }

  /// The config.json key that makes a request that needs a host wait 2 s for the host's link, in place of 15 s.
  /// A test that drops the link and expects a request to fail sets it.
  static let shortHostWait: [String: JSON] = ["hostWaitSeconds": 2]

  /// Connects the host's link and waits for it. A sbd with `shortHostWait` connects first, so its first request
  /// that needs the host does not have to connect within the short wait.
  func connectHost(_ name: String = "mini") throws {
    try sb("host", "connect", name)
    try waitForLink(name, .connected)
  }

  /// Whether the process runs. A process that its parent has not waited for yet does not count.
  func runs(_ pid: Int) -> Bool {
    guard kill(pid_t(pid), 0) == 0 else { return false }
    let state = (try? runCommand("/bin/ps", ["-o", "stat=", "-p", String(pid)]).stdout) ?? ""
    return !state.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
  }
}

/// The hooks of a remote host. A remote claude's hooks reach sbd through the socket that sbd listens on for the
/// host, `$SB_HOME/hosts/<host>/sbd.sock`. A test sends raw lines to that socket, as a program on the host can.
extension Instance {
  /// The socket that sbd listens on for the host's requests.
  func hostSocket(_ host: String = "mini") -> String { "\(home.path)/hosts/\(host)/sbd.sock" }

  /// The far end of the forward, which the shim on the box connects to.
  var boxSocket: String { "\(boxSB)/sbd.sock" }

  var boxSpool: String { "\(boxSB)/spool.jsonl" }

  var boxShim: String { "\(boxSB)/bin/sb-shim" }

  var boxSettings: String { "\(boxSB)/claude-settings.json" }

  /// A hook event id as the shim makes it: the clock in ns as 20 digits, a pid, and 4 hex digits.
  static func eventId(ns: UInt64, pid: Int = Int(getpid()), suffix: String? = nil) -> String {
    let digits = String(ns)
    let clock = String(repeating: "0", count: max(0, 20 - digits.count)) + digits
    return "\(clock)-\(pid)-\(suffix ?? String(format: "%04x", UInt32.random(in: 0...0xffff)))"
  }

  /// This Mac's clock in ns, which is also the box's clock, because the stub runs the box here.
  static func clockNs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000_000_000) }

  /// A payload that sbd records and that changes no turn: a Notification that names the marker in `probe`.
  static func probePayload(_ marker: String, kind: String = "Notification", claudeSessionId: String = "probe") -> JSON {
    var payload: [String: JSON] = [
      "hook_event_name": .string(kind), "session_id": .string(claudeSessionId), "permission_mode": "default",
      "probe": .string(marker),
    ]
    switch kind {
    case "Notification": payload["notification_type"] = "sb_test"
    case "PermissionRequest", "PreToolUse", "PostToolUse":
      payload["tool_name"] = "Bash"
      payload["tool_input"] = ["command": .string("touch \(marker)")]
    default: break
    }
    return .object(payload)
  }

  /// The line of a `hook` request, as the shim sends it. Nil leaves the key out.
  static func hookLine(session: JSON?, payload: JSON?, id: String?, extra: [String: JSON] = [:]) -> String {
    var args = extra
    if let session { args["session"] = session }
    if let payload { args["payload"] = payload }
    if let id { args["id"] = .string(id) }
    return JSON.object(["op": "hook", "args": .object(args)]).text
  }

  static func requestLine(_ op: String, _ args: [String: JSON] = [:]) -> String {
    JSON.object(["op": .string(op), "args": .object(args)]).text
  }

  /// Sends each line on one connection and returns the answer to each. An answer is nil when sbd closed the
  /// connection or sent a line that is not JSON. It throws when sbd sends nothing within the timeout.
  func sendLines(_ lines: [Data], to socket: String, timeout: TimeInterval = 5) throws -> [JSON?] {
    let fd = try UnixSocket.connect(path: socket, timeout: timeout)
    defer { close(fd) }
    var reader = UnixSocket.LineReader(fd: fd)
    var answers: [JSON?] = []
    for line in lines {
      guard (try? UnixSocket.write(fd, line + Data("\n".utf8))) != nil else {
        answers.append(nil)
        continue
      }
      let reply = try reader.next()
      answers.append(reply.flatMap { String(data: $0, encoding: .utf8) }.flatMap(JSON.parse))
    }
    return answers
  }

  func sendLine(_ line: String, to socket: String, timeout: TimeInterval = 5) throws -> JSON? {
    try sendLines([Data(line.utf8)], to: socket, timeout: timeout)[0]
  }

  /// Sends a probe hook for the session to the host's socket and returns sbd's answer.
  @discardableResult
  func sendProbe(
    _ marker: String, session: String, id: String = Instance.eventId(ns: Instance.clockNs()), host: String = "mini",
    kind: String = "Notification"
  ) throws -> JSON? {
    try sendLine(
      Instance.hookLine(session: .string(session), payload: Instance.probePayload(marker, kind: kind), id: id),
      to: hostSocket(host))
  }

  /// Every event in the log, of every session, oldest first.
  func allEvents() throws -> [Event] {
    try client.call("events", ["since": 0, "limit": 1_000_000], as: [Event].self)
  }

  /// The events whose payload names the marker, oldest first.
  func probes(_ marker: String) throws -> [Event] { try allEvents().filter { $0.data["probe"] == .string(marker) } }

  /// Waits until the log has held the same events for a second, and returns them. A hook that sbd holds for its
  /// order window, and a hook that a starting claude still sends, are then in the log.
  func settledEvents() throws -> [Event] {
    var last = try allEvents()
    var since = Date()
    try waitFor("the event log to stop growing", timeout: 30) {
      let now = try allEvents()
      if now != last {
        last = now
        since = Date()
      }
      return Date().timeIntervalSince(since) >= 1
    }
    return last
  }

  /// The lines that the stub claude on the box read from its terminal, oldest first.
  func boxStubInput() -> [String] {
    let text = (try? String(contentsOfFile: "\(boxSB)/stub-input.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// The whole lines of the box's spool as JSON, oldest first. A line that is not JSON reads as null.
  func boxSpoolLines() -> [JSON] {
    let text = (try? String(contentsOfFile: boxSpool, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map {
      JSON.parse(String($0)) ?? .null
    }
  }

  /// The arguments of each `-O forward` run of the ssh stub, oldest first.
  func sshStubForwards() -> [[String]] {
    sshStubLog.split(separator: "\n").compactMap { line in
      guard let argv = JSON.parse(String(line))?["argv"]?.array?.compactMap(\.string),
        let at = argv.firstIndex(of: "-O"), argv.indices.contains(at + 1), argv[at + 1] == "forward"
      else { return nil }
      return argv
    }
  }

  /// Whether the PermissionRequest hook that the stub claude on the box ran last still runs.
  func boxHeldHookRuns() -> Bool {
    guard let pid = stubPid("ssh-stub/home/.sb/held-hook.pid") else { return false }
    return runs(Int(pid))
  }

  /// A session on the host whose claude reported its SessionStart through the forward. With a prompt, it does not
  /// wait for the turn. It connects the host first. `sb new` waits only `hostWaitSeconds` for the link, and a slow
  /// runner can take longer than that to connect.
  func startOnHost(_ folder: String = "sb-box-repo", host: String = "mini", prompt: String? = nil) throws -> (
    id: String, claudeSessionId: String, cwd: String, pid: Int
  ) {
    try makeBoxFolder(folder)
    try connectHost(host)
    let summary = try #require(
      JSON.parse(try sb(["new", "~/\(folder)", "--host", host, "--json"] + (prompt.map { ["--prompt", $0] } ?? []))))
    let id = try self.id(of: summary)
    let live = try waitFor(id, "the SessionStart of the claude on the box") { $0.live && $0.claudePid != nil }
    return (
      id, try #require(summary["claudeSessionId"]?.string), try #require(summary["cwd"]?.string),
      try #require(live.claudePid)
    )
  }
}

/// A request that a test sends on a thread of its own, because sbd holds its answer.
final class HeldLine: @unchecked Sendable {
  private let lock = NSLock()
  private var fd: Int32 = -1
  private var answer: JSON??
  private let done = DispatchSemaphore(value: 0)

  /// Connects and sends the line. The answer arrives on another thread.
  init(_ line: String, to socket: String, timeout: TimeInterval = 120) throws {
    let fd = try UnixSocket.connect(path: socket, timeout: timeout)
    self.fd = fd
    try UnixSocket.write(fd, Data((line + "\n").utf8))
    Thread.detachNewThread { [self] in
      var reader = UnixSocket.LineReader(fd: fd)
      let reply = (try? reader.next()).flatMap { $0 }
      lock.lock()
      answer = .some(reply.flatMap { String(data: $0, encoding: .utf8) }.flatMap(JSON.parse))
      lock.unlock()
      done.signal()
    }
  }

  deinit { close() }

  /// The answer, or nil when none arrived within the seconds or sbd closed the connection.
  func wait(_ seconds: Double) -> JSON? {
    guard done.wait(timeout: .now() + seconds * Instance.timeoutScale) == .success else { return nil }
    done.signal()
    lock.lock()
    defer { lock.unlock() }
    return answer ?? nil
  }

  /// Whether sbd has answered or closed the connection.
  var answered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return answer != nil
  }

  /// Closes the connection, as a hook that Claude Code ended does.
  func close() {
    lock.lock()
    defer { lock.unlock() }
    if fd >= 0 {
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
      fd = -1
    }
  }
}

/// The reconcile that sbd runs on each reconnect of a host, and what a test does on the box while the link is down.
extension Instance {
  /// A step of the reconcile that a test can hold on the box.
  enum BoxGate: String, CaseIterable, Sendable {
    /// The read of `~/.sb/spool.jsonl`.
    case spoolRead = "spool-read"
    /// `claude agents --json`.
    case agents
    /// The read of a session's transcript.
    case transcript
    /// `sb-shim spool-drop`, the spool cut.
    case spoolDrop = "spool-drop"
  }

  /// The programs that a file read on the box can run, and `python3`, which runs the shim.
  private static let gatedPrograms = [
    "tail": "/usr/bin/tail", "head": "/usr/bin/head", "cat": "/bin/cat", "dd": "/bin/dd", "wc": "/usr/bin/wc",
    "stat": "/usr/bin/stat",
  ]

  private func boxGateFile(_ gate: BoxGate, _ suffix: String) -> String {
    "\(home.path)/box-gate-\(gate.rawValue).\(suffix)"
  }

  /// A sbd with the host `mini` whose box runs its file reads, its python3, and its claude through wrappers that
  /// a test can hold with `holdBoxGate`. The box's claude is the claude stub behind a wrapper that gives it the
  /// box's `.sb` as SB_HOME when it has none, as a pane does, so `claude agents` there reads the stub's status
  /// files.
  static func remoteWithGates(config settings: [String: JSON] = [:]) throws -> Instance {
    let sbd = try unstartedRemote(config: settings, boxBin: true)
    try sbd.installBoxGates()
    try sbd.set("hosts", to: ["mini": remoteHost(boxDestination, ["claude": .string("\(sbd.boxBin)/claude-stub")])])
    try sbd.startSbd()
    return sbd
  }

  /// Writes the wrappers into `boxBin`. A wrapper waits while a gate is held and its run matches the gate: one of
  /// its arguments holds the gate's word, or its stdin is the gate's file. It then runs the real program.
  func installBoxGates() throws {
    func write(_ name: String, _ script: String) throws {
      try script.write(toFile: "\(boxBin)/\(name)", atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(boxBin)/\(name)")
    }
    var programs = Instance.gatedPrograms
    let python = try #require(Instance.python ?? findExecutable("python3"), "python3 is not installed")
    programs["python3"] = python
    for (name, path) in programs {
      try write(
        name,
        """
        #!/bin/sh
        for on in '\(home.path)'/box-gate-*.on; do
          [ -e "$on" ] || continue
          gate=${on%.on}
          hit=
          if [ -s "$gate.word" ]; then
            word=$(/bin/cat "$gate.word")
            case " $* " in *"$word"*) hit=1 ;; esac
          fi
          if [ -z "$hit" ] && [ -s "$gate.file" ]; then
            want=$(/usr/bin/stat -L -f %d:%i "$(/bin/cat "$gate.file")" 2>/dev/null)
            have=$(/usr/bin/stat -f %d:%i 2>/dev/null)
            [ -n "$want" ] && [ "$want" = "$have" ] && hit=1
          fi
          if [ -n "$hit" ]; then
            : >"$gate.waiting"
            while [ -e "$on" ]; do /bin/sleep 0.05; done
          fi
        done
        exec '\(path)' "$@"

        """)
    }
    let agents = boxGateFile(.agents, "on")
    // sbd finds a pane's claude by the last word of the host's claude command, so the wrapper has the stub's name.
    try write(
      "claude-stub",
      """
      #!/bin/sh
      : "${SB_HOME:=$HOME/.sb}"
      export SB_HOME
      if [ "${1-}" = agents ] && [ -e '\(agents)' ]; then
        : >'\(boxGateFile(.agents, "waiting"))'
        while [ -e '\(agents)' ]; do /bin/sleep 0.05; done
      fi
      if [ "${1-}" = agents ] && [ -e '\(boxAgentsFail)' ]; then
        echo 'claude agents failed on the box' >&2
        exit 1
      fi
      exec '\(Instance.stub)' "$@"

      """)
  }

  /// While this file exists, `claude agents` on the box exits 1.
  var boxAgentsFail: String { "\(home.path)/box-agents-fail" }

  /// Holds the step from now on. The transcript gate needs the session's conversation, whose transcript it holds.
  func holdBoxGate(_ gate: BoxGate, claudeSessionId: String? = nil) throws {
    try? FileManager.default.removeItem(atPath: boxGateFile(gate, "waiting"))
    var word: String?
    var file: String?
    switch gate {
    case .spoolRead:
      word = "spool.jsonl"
      file = boxSpool
    case .spoolDrop: word = "spool-drop"
    case .transcript:
      let id = try #require(claudeSessionId, "the transcript gate needs a conversation")
      word = "\(id).jsonl"
      let transcript = try #require(boxTranscripts(id).first, "no transcript of \(id) on the box")
      file = transcript
    case .agents: break
    }
    if let word { try word.write(toFile: boxGateFile(gate, "word"), atomically: true, encoding: .utf8) }
    if let file { try file.write(toFile: boxGateFile(gate, "file"), atomically: true, encoding: .utf8) }
    FileManager.default.createFile(atPath: boxGateFile(gate, "on"), contents: nil)
  }

  /// Whether a run on the box waits at the gate, or waited there since it was last held.
  func boxGateReached(_ gate: BoxGate) -> Bool { FileManager.default.fileExists(atPath: boxGateFile(gate, "waiting")) }

  func releaseBoxGate(_ gate: BoxGate) throws {
    try FileManager.default.removeItem(atPath: boxGateFile(gate, "on"))
  }

  /// Types a line into the session's Claude pane on the box with the box's own tmux, as a person at the box does.
  /// It works while the link is down.
  func typeOnBox(_ id: String, _ line: String) throws {
    for keys in [["-l", line], ["Enter"]] {
      let tmux = try #require(findExecutable("tmux"))
      let r = try runCommand(tmux, ["-S", "\(boxSB)/tmux.sock", "send-keys", "-t", "=\(id)-claude:"] + keys)
      guard r.status == 0 else { throw TestError(description: "tmux send-keys \(keys) on the box: \(r.stderr)") }
    }
  }

  /// Runs the shim that sbd wrote on the box with the payload, as a hook of the session's claude does. It appends
  /// the event to the box's spool, and sends it to sbd when the forward is up.
  @discardableResult
  func runBoxShim(session: String, payload: JSON) throws -> CommandResult {
    try runCommand(
      findExecutable("python3") ?? "/usr/bin/python3", [boxShim, "hook"],
      env: ["HOME": boxHome, "SB_HOME": boxSB, "SB_SESSION_ID": session, "PATH": "/usr/local/bin:/usr/bin:/bin"],
      input: Data(payload.text.utf8), timeout: 15)
  }

  /// Spools a probe for the session through the box's shim.
  func spoolProbe(_ marker: String, session: String) throws {
    let r = try runBoxShim(session: session, payload: Instance.probePayload(marker))
    guard r.status == 0 else { throw TestError(description: "the box's shim exited \(r.status): \(r.stderr)") }
  }

  /// The bytes of the box's spool, or none when the file is missing.
  var boxSpoolData: Data { FileManager.default.contents(atPath: boxSpool) ?? Data() }

  /// The whole lines of the box's spool that name the marker in their payload's `probe`.
  func boxSpoolProbes(_ marker: String) -> [JSON] {
    boxSpoolLines().filter { $0["payload"]?["probe"]?.string == marker }
  }

  /// The session's events of the kind, oldest first.
  func events(_ id: String, kind: String) throws -> [Event] { try events(id).filter { $0.kind == kind } }
}

/// Removal on a host: a box repo whose pushes reach a bare repo on the box, a box git that a test can hold or end,
/// and what a removal can change on the box, in the store, and in sbd.
extension Instance {
  /// The GitHub repo of the recorded PRs.
  static let posthogURL = "https://github.com/PostHog/posthog.git"
  /// The head branch of the recorded PR 122953 in PostHog/posthog.
  static let mergedBranch = "haacked/cdp-dlq-breaker-counts-lookups"

  /// The config.json keys that point sbd's poller at the fake. The poller runs only when a test polls.
  static func gitHubConfig(_ github: FakeGitHub) -> [String: JSON] {
    [
      "github": ["gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url), "pollSeconds": 0],
      "tickSeconds": 1,
    ]
  }

  /// A sbd with the host `mini` whose box runs git through `installBoxGit`. The box's git must be in place before
  /// the first session on the host, because setup finds it once per connection.
  static func remoteForRemoval(host extra: [String: JSON] = [:], config settings: [String: JSON] = [:]) throws
    -> Instance
  {
    let sbd = try unstartedRemote(host: extra, config: settings, boxBin: true)
    try sbd.installBoxGit()
    try sbd.startSbd()
    return sbd
  }

  /// A repo under the box's home whose origin is `url`. git sends its pushes and fetches to a bare repo under the
  /// box's home, which holds main. The poller reads `url` from the config, so it looks up GitHub's PRs for it.
  @discardableResult
  func makeBoxRepoWithOrigin(_ name: String = "sb-box-repo", url: String = Instance.posthogURL) throws -> (
    repo: String, origin: String
  ) {
    let repo = try Repos.create("\(boxHome)/\(name)", origin: url)
    let origin = "\(boxHome)/\(name)-origin.git"
    try git(boxHome, "init", "-q", "--bare", origin)
    try git(repo, "config", "url.\(origin).insteadOf", url)
    try git(repo, "push", "-q", "origin", "main")
    return (repo, origin)
  }

  /// A remote session in a worktree that sbd made on the box.
  struct BoxSession {
    var id: String
    var claudeSessionId: String
    var cwd: String
    /// The claude of its first launch.
    var pid: Int
    /// The repo that the worktree belongs to.
    var repo: String
  }

  /// Starts a session on mini in a new worktree of `~/<folder>` on `branch`, and waits for the first reply, which
  /// reaches sbd through the box's hooks.
  func startBoxWorktree(
    _ folder: String = "sb-box-repo", branch: String = "haacked/remote", prompt: String = "hello"
  ) throws -> BoxSession {
    let summary = try newOnHost("~/\(folder)", "--branch", branch, "--prompt", prompt)
    let id = try self.id(of: summary)
    let s = try waitFor(id, "the first reply on the box", timeout: 30) {
      $0.lastReply == "Done: \(prompt)" && $0.claudePid != nil
    }
    return BoxSession(
      id: id, claudeSessionId: s.claudeSessionId, cwd: s.cwd, pid: try #require(s.claudePid),
      repo: "\(boxHome)/\(folder)")
  }

  /// The sessions of `host` that the store lists in `removed_host_sessions`. sqlite3 reads the file without
  /// writing to it, so the read can't contend with sbd's writes.
  func removedHostSessions(_ host: String = "mini") throws -> [String] {
    let r = try runCommand(
      "/usr/bin/sqlite3",
      ["-readonly", home.database, "SELECT id FROM removed_host_sessions WHERE host = '\(host)' ORDER BY id"])
    guard r.status == 0 else { throw TestError(description: "sqlite3 read removed_host_sessions: \(r.stderr)") }
    return r.stdout.split(separator: "\n").map(String.init)
  }

  /// The session's launcher folder on the box.
  func boxSessionFolder(_ id: String) -> String { "\(boxSB)/sessions/\(id)" }

  /// The calls on this Mac's machine that name the remote session, its folder, the box, or its claude's pid in a
  /// signal or a process check.
  func macCalls(for s: BoxSession) throws -> [MachineCall] {
    try macCalls(id: s.id, cwd: s.cwd, claudeSessionId: s.claudeSessionId, pid: s.pid)
  }

  /// The calls on this Mac's machine that name the remote session, its folder, the box, its conversation, or any
  /// text in `also`, and the calls that name its claude's pid in a signal or a process check.
  func macCalls(id: String, cwd: String, claudeSessionId: String, pid: Int, also: [String] = []) throws
    -> [MachineCall]
  {
    let named = try macCalls(holding: namesOfRemoteSession(id, cwd: cwd) + [claudeSessionId] + also)
    let signalled = try machineCalls().filter {
      ($0.has("signal") || $0.has("stopClaude") || $0.has("alive") || $0.has("folderUsers")) && $0.has(String(pid))
    }
    return named + signalled
  }

  // MARK: What a removal changes

  /// What a removal of a remote session can change: sbd's sessions, the box's panes and claude, the session's
  /// `stopped` events, the worktree's files, the repo's worktrees and branches, the origin's branches, the
  /// session's launcher folder on the box, and the store's removed host sessions.
  struct RemovalState: Equatable, CustomStringConvertible {
    var sessions: [String]
    var boxPanes: [String]
    var claudeRuns: Bool
    /// nil once sbd no longer holds the session.
    var stopped: Int?
    /// nil when the folder is gone.
    var worktreeFiles: [String]?
    var worktrees: String
    var branches: String
    var originBranches: String
    var sessionFolder: Bool
    var removed: [String]

    var description: String {
      """
      sessions \(sessions), panes \(boxPanes), claude runs \(claudeRuns), stopped \(String(describing: stopped)), \
      files \(String(describing: worktreeFiles)), worktrees \(worktrees), branches \(branches), \
      origin \(originBranches), launcher folder \(sessionFolder), removed \(removed)
      """
    }

    /// The same state without what stopping claude changes, for a refusal that comes after the stop.
    var withoutClaude: RemovalState {
      var s = self
      s.claudeRuns = false
      s.stopped = nil
      s.boxPanes = s.boxPanes.filter { !$0.hasSuffix("-claude") && !$0.hasSuffix("-shell") }
      return s
    }
  }

  func removalState(_ s: BoxSession, origin: String? = nil) throws -> RemovalState {
    let git = { (dir: String, args: [String]) -> String in
      (try? runCommand("/usr/bin/git", ["-C", dir] + args).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        ?? "?"
    }
    return RemovalState(
      sessions: try client.sessions().map(\.id).sorted(), boxPanes: try boxTmuxSessions(), claudeRuns: runs(s.pid),
      stopped: (try? events(s.id, kind: "stopped"))?.count,
      worktreeFiles: (try? FileManager.default.contentsOfDirectory(atPath: s.cwd))?.sorted(),
      worktrees: git(s.repo, ["worktree", "list", "--porcelain"]), branches: git(s.repo, ["branch", "--list", "-v"]),
      originBranches: origin.map { git($0, ["branch", "--list", "-v"]) } ?? "",
      sessionFolder: FileManager.default.fileExists(atPath: boxSessionFolder(s.id)), removed: try removedHostSessions())
  }

  // MARK: The box's git

  private func boxGitFile(_ gate: String, _ suffix: String) -> String { "\(home.path)/box-git-\(gate).\(suffix)" }

  /// Writes a `git` into `boxBin` that runs `/usr/bin/git` unless a test holds or ends it.
  ///
  /// While `holdBoxGit` is on, a run whose arguments hold its text passes the first `skipping` such runs. Each run
  /// after them marks that it waits and waits until `releaseBoxGit`. While `endBoxGit` is on, a run whose arguments
  /// hold its text prints nothing and exits 143, as a command that its timeout ended does. With `whenMissing`, it
  /// does that only when git would answer that the ref does not exist. After a `worktree remove` that succeeds, it
  /// runs the snippet of `afterBoxWorktreeRemoval`.
  func installBoxGit() throws {
    try FileManager.default.createDirectory(atPath: boxBin, withIntermediateDirectories: true)
    let hold = { (suffix: String) in shellQuote(self.boxGitFile("hold", suffix)) }
    let end = { (suffix: String) in shellQuote(self.boxGitFile("end", suffix)) }
    let script = """
      #!/bin/sh
      args=" $* "
      if [ -e \(hold("on")) ]; then
        word=$(/bin/cat \(hold("word")))
        case $args in
        *"$word"*)
          n=$(/bin/cat \(hold("count")) 2>/dev/null || echo 0)
          n=$((n + 1))
          echo "$n" >\(hold("count"))
          skip=$(/bin/cat \(hold("skip")) 2>/dev/null || echo 0)
          if [ "$n" -gt "$skip" ]; then
            : >\(hold("waiting"))
            while [ -e \(hold("on")) ]; do /bin/sleep 0.05; done
          fi
          ;;
        esac
      fi
      if [ -e \(end("on")) ]; then
        word=$(/bin/cat \(end("word")))
        case $args in
        *"$word"*)
          if [ -e \(end("missing")) ] && /usr/bin/git "$@" >/dev/null 2>&1; then exec /usr/bin/git "$@"; fi
          : >\(end("ended"))
          exit 143
          ;;
        esac
      fi
      after=\(shellQuote(boxGitFile("after-remove", "sh")))
      case $args in
      *" worktree remove "*)
        if [ -f "$after" ]; then
          /usr/bin/git "$@" || exit $?
          /bin/sh "$after"
          exit 0
        fi
        ;;
      esac
      exec /usr/bin/git "$@"

      """
    try script.write(toFile: "\(boxBin)/git", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(boxBin)/git")
  }

  /// Holds each run of the box's git whose arguments hold `word`, after the first `skipping` of them.
  func holdBoxGit(_ word: String, skipping: Int = 0) throws {
    for suffix in ["count", "waiting"] { try? FileManager.default.removeItem(atPath: boxGitFile("hold", suffix)) }
    try word.write(toFile: boxGitFile("hold", "word"), atomically: true, encoding: .utf8)
    try String(skipping).write(toFile: boxGitFile("hold", "skip"), atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: boxGitFile("hold", "on"), contents: nil)
  }

  /// Whether a run of the box's git waits at the hold, or waited there since `holdBoxGit`.
  var boxGitHeld: Bool { FileManager.default.fileExists(atPath: boxGitFile("hold", "waiting")) }

  func releaseBoxGit() throws { try FileManager.default.removeItem(atPath: boxGitFile("hold", "on")) }

  /// Ends each run of the box's git whose arguments hold `word` with status 143 and no output.
  func endBoxGit(_ word: String, whenMissing: Bool = false) throws {
    try? FileManager.default.removeItem(atPath: boxGitFile("end", "ended"))
    try word.write(toFile: boxGitFile("end", "word"), atomically: true, encoding: .utf8)
    if whenMissing { FileManager.default.createFile(atPath: boxGitFile("end", "missing"), contents: nil) }
    FileManager.default.createFile(atPath: boxGitFile("end", "on"), contents: nil)
  }

  /// Whether the box's git ended a run since `endBoxGit`.
  var boxGitEnded: Bool { FileManager.default.fileExists(atPath: boxGitFile("end", "ended")) }

  func stopEndingBoxGit() throws {
    try? FileManager.default.removeItem(atPath: boxGitFile("end", "missing"))
    try FileManager.default.removeItem(atPath: boxGitFile("end", "on"))
  }

  /// Runs the shell snippet on the box after each `git worktree remove` that succeeds, as a commit or a checkout
  /// that lands right after the removal does.
  func afterBoxWorktreeRemoval(_ snippet: String) throws {
    try snippet.write(toFile: boxGitFile("after-remove", "sh"), atomically: true, encoding: .utf8)
  }

  // MARK: Processes on the box

  /// Starts `sleep` with its working folder in `folder`, as a program that the user left running on the box does.
  /// The box is this Mac, so it is a process here.
  func startProcess(in folder: String, seconds: Int = 60) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = [String(seconds)]
    p.currentDirectoryURL = URL(fileURLWithPath: folder)
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
  }
}

/// Commands in a session's panes.
extension Instance {
  /// Types the text into the session's shell pane and presses Enter.
  func typeInShell(_ t: Terminals, _ text: String) throws {
    for keys in [["-l", text], ["Enter"]] {
      let r = try runCommand(t.tmux, ["-S", t.socket, "send-keys", "-t", "=\(t.shell):"] + keys)
      guard r.status == 0 else { throw TestError(description: "tmux send-keys: \(r.stderr)") }
    }
  }

  /// Writes `$SB_HOME/<name>.sh`, which runs sb with the arguments.
  func writeSbScript(_ name: String, _ args: [String]) throws {
    try writeScript(name, ([shellQuote("\(Instance.bin)/sb")] + args.map(shellQuote)).joined(separator: " "))
  }

  /// Writes `$SB_HOME/<name>.sh`, which runs the command and writes its stdout, stderr, and exit status to
  /// `<name>.out`, `<name>.err`, and `<name>.status` in SB_HOME. A pane runs it with the stub's `run <name>` or with
  /// `sh` in the shell, so that the command descends from that pane.
  func writeScript(_ name: String, _ command: String) throws {
    let script =
      "\(command) >\"$SB_HOME/\(name).out\" 2>\"$SB_HOME/\(name).err\"\necho $? >\"$SB_HOME/\(name).status\"\n"
    try script.write(toFile: "\(home.path)/\(name).sh", atomically: true, encoding: .utf8)
  }

  /// Waits until the script that `writeScript` wrote has recorded its command's exit status, and returns the
  /// command's result.
  func scriptResult(_ name: String, timeout: Double = 30) throws -> CommandResult {
    let file = { (suffix: String) in "\(self.home.path)/\(name).\(suffix)" }
    let status = try waitFor(
      "\(name).sh to record its exit status", timeout: timeout,
      fetch: { () -> Int32? in
        guard let text = try? String(contentsOfFile: file("status"), encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      }, until: { _ in true })
    return CommandResult(
      status: status, stdout: (try? String(contentsOfFile: file("out"), encoding: .utf8)) ?? "",
      stderr: (try? String(contentsOfFile: file("err"), encoding: .utf8)) ?? "")
  }
}

/// The refusal that sbd sends when the process that sent `command` descends from one of the session's panes.
func insideRefusal(_ command: String, _ id: String) -> String {
  "`\(command)` runs inside \(id), so it would stop itself. Run it from a terminal outside the session."
}
