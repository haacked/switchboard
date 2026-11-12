import Foundation
import SwitchboardCore

extension SessionSite {
  /// The visible screen of the pane, as `TerminalHost.screen` gives it. A site that names a host returns only
  /// a screen that the host's tmux answered with. It throws when the capture got no answer or its output is
  /// not in the answered form, so the empty output of a command that its timeout ended never reads as an empty
  /// screen.
  func screen(_ pane: String, colors: Bool = false) throws -> String {
    let terminals = try terminals()
    guard hostName != nil else { return try terminals.screen(pane, colors: colors) }
    return try confirmed("the screen read of \(pane)") { try terminals.answeredScreen(pane, colors: colors, on: $0) }
  }
}

/// Where a session's claude, shell, folder, and transcript are: this Mac or a remote host.
/// Session code reaches tmux, git, ps, kill, and files only through the session's site.
protocol SessionSite: AnyObject {
  /// nil for this Mac.
  var hostName: String? { get }
  /// Runs commands and reads files at the site. A remote site's machine gives every `run` a timeout.
  var machine: any Machine { get }
  /// The site's tmux server. A remote site throws `HostUnread` until its link is connected and set up.
  func terminals() throws -> TerminalHost
  /// Throws what `terminals()` throws. It does nothing on this Mac.
  func requireReady() throws
  /// The folder where Switchboard keeps its files at the site: sbd's home on this Mac, `~/.sb` on a host.
  func sbFolder() throws -> String
  /// The home folder of the user at the site.
  func userHome() throws -> String
  /// The git program at the site.
  func git() throws -> String
  /// Where `sb new --branch` makes worktrees at the site, with `~` resolved there.
  func worktreeRoot() throws -> String
  /// A session's launcher folder at the site.
  func sessionFolder(_ id: String) throws -> String
  /// Runs `body` with the site's machine. On a remote site it returns `body`'s result only when the link was
  /// connected and every command that `body` sent got an answer from the host. It throws `HostUnread`
  /// otherwise. On this Mac it runs `body`.
  func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T
  /// Runs `body` with a scope whose site sends its commands on one connection. On a remote site, the scope's
  /// `require` throws `HostUnread` unless every command of the scope got an answer and the link is still on the
  /// connection that the scope began on. The scope's machine refuses each command once `require` would throw,
  /// and the call throws then too. On this Mac, the scope's site is the site and `require` does nothing.
  func scoped<T>(_ what: String, _ body: (SiteScope) throws -> T) throws -> T
  /// The panes and the processes, from one read. It throws when tmux can't list the panes.
  func readSnapshot(claudeProgram: String) throws -> Service.Snapshot
  /// The pids that still run.
  func alive(_ pids: Set<Int>) throws -> Set<Int>
  /// The processes that use the folder, as `Processes.using` defines it.
  func folderUsers(_ folder: String) throws -> [FolderUser]
  func samePath(_ a: String, _ b: String) throws -> Bool
  /// The path with every symlink resolved, or nil when the path doesn't exist.
  func realPath(_ path: String) throws -> String?
  /// True only when the site answered that the path does not exist.
  func folderGone(_ path: String) throws -> Bool
  /// Sends SIGTERM to the session's claude, which runs below the pane's process.
  func stopClaude(_ pid: Int, below pane: Int, program: String) throws
}

/// The site of one `scoped` call and its check.
struct SiteScope {
  let site: any SessionSite
  let require: () throws -> Void
}

extension SessionSite {
  /// A scope whose site is a `CheckedSite` of one `confirmed` call. Its `require` checks nothing before the
  /// call ends.
  func scoped<T>(_ what: String, _ body: (SiteScope) throws -> T) throws -> T {
    try confirmed(what) { machine in try body(SiteScope(site: CheckedSite(self, machine: machine), require: {})) }
  }
}

/// A path at one site. A host can hold the same path as this Mac, so what sbd remembers about a path belongs
/// to the path and its site.
struct SitePath: Hashable {
  /// nil for this Mac.
  var host: String?
  var path: String

  init(_ path: String, at site: any SessionSite) {
    self.host = site.hostName
    self.path = path
  }
}

/// A remote host could not be read: its link is not connected, or a command got no answer.
struct HostUnread: Error, CustomStringConvertible {
  var hostName: String
  var why: String
  var description: String { "\(hostName) is not connected: \(why)" }
}

/// This Mac. It is the only code that builds this Mac's machine and calls the local process and path functions.
final class MacSite: SessionSite {
  let hostName: String? = nil
  let machine: any Machine
  /// The panes and processes of this Mac. `Service` reads and writes it on its state queue.
  var snapshot = Service.Snapshot()
  private let home: Home
  private let config: Config
  private let tmuxServer: TerminalHost
  private let gitPath: String
  /// Set when config.json turns `machineLog` on.
  private let log: MachineLog?

  init(home: Home, config: Config) throws {
    self.home = home
    self.config = config
    let log = config.machineLog ? MachineLog(path: home.machineLog) : nil
    self.log = log
    self.machine = log.map { LoggedMachine(LocalMachine(), log: $0) } ?? LocalMachine()
    self.tmuxServer = try TerminalHost(home: home, config: config, machine: machine)
    guard let git = findExecutable("git") else { throw APIError("can't find git") }
    self.gitPath = git
  }

  func terminals() -> TerminalHost { tmuxServer }

  func requireReady() {}

  func sbFolder() -> String { home.path }

  func userHome() -> String { "~".expandingTilde }

  func git() -> String { gitPath }

  func worktreeRoot() throws -> String { config.worktreeRoot.expandingTilde }

  func sessionFolder(_ id: String) throws -> String { home.sessionFolder(id) }

  func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T { try body(machine) }

  func scoped<T>(_ what: String, _ body: (SiteScope) throws -> T) throws -> T {
    try body(SiteScope(site: self, require: {}))
  }

  func readSnapshot(claudeProgram: String) throws -> Service.Snapshot {
    var s = Service.Snapshot()
    // A snapshot is as old as its first read. `install` uses this to drop
    // one that began before a launch.
    s.taken = nowMs()
    s.panes = try tmuxServer.checkedPanes()
    s.children = Processes.byParent(on: machine)
    s.findClaudes(program: claudeProgram)
    return s
  }

  func alive(_ pids: Set<Int>) throws -> Set<Int> {
    log?.append("alive", ["pids": .array(pids.sorted().map { .number(Double($0)) })])
    return pids.filter(Processes.exists)
  }

  func folderUsers(_ folder: String) throws -> [FolderUser] {
    log?.append("folderUsers", ["folder": .string(folder)])
    return Processes.using(folder)
  }

  func samePath(_ a: String, _ b: String) throws -> Bool {
    log?.append("samePath", ["a": .string(a), "b": .string(b)])
    // A gone worktree may have lost its parent folders too, so the deepest folder that exists is resolved.
    let real = { (path: String) -> String in
      var url = URL(fileURLWithPath: path).standardizedFileURL
      var gone: [String] = []
      while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
        gone.insert(url.lastPathComponent, at: 0)
        url.deleteLastPathComponent()
      }
      return gone.reduce(url.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
    return real(a) == real(b)
  }

  func realPath(_ path: String) throws -> String? {
    log?.append("realPath", ["path": .string(path)])
    return SwitchboardCore.realPath(path)
  }

  /// Only ENOENT counts as gone. A permission error or a hung mount leaves the folder unread.
  func folderGone(_ path: String) throws -> Bool {
    log?.append("folderGone", ["path": .string(path)])
    var info = stat()
    return stat(path, &info) != 0 && errno == ENOENT
  }

  func stopClaude(_ pid: Int, below pane: Int, program: String) throws {
    log?.append(
      "stopClaude", ["pid": .number(Double(pid)), "pane": .number(Double(pane)), "program": .string(program)])
    machine.signal(pid, SIGTERM)
  }
}

extension Service.Snapshot {
  /// Sets the claude of each session whose Claude pane is alive, from the panes and the processes.
  mutating func findClaudes(program: String) {
    for (name, pane) in panes where name.hasSuffix("-claude") && !pane.dead {
      if let pid = Service.findClaude(below: pane.pid, program: program, in: children) {
        claudePids[String(name.dropLast("-claude".count))] = pid
      }
    }
  }
}

extension RemoteSite {
  /// The path with every symlink resolved, or nil when the host answered that the path doesn't exist.
  func realPath(_ path: String) throws -> String? { try resolvedPath(path) }
}

/// The site of a session whose host config.json no longer lists, or lists without a link. Every member throws
/// `HostUnread` and its machine runs nothing, so none of the session's work runs on this Mac.
final class UnlistedSite: SessionSite {
  /// A machine that answers nothing.
  private struct NoMachine: Machine {
    var failure: HostUnread

    func run(
      _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
    ) throws -> CommandResult { throw failure }
    func read(_ path: String, from offset: UInt64, count: Int?) -> Data? { nil }
    func size(_ path: String) -> UInt64? { nil }
    func exists(_ path: String) -> Bool { false }
    func isFolder(_ path: String) -> Bool { false }
    func modified(_ path: String) -> Date? { nil }
    func list(_ folder: String) -> [String] { [] }
    func createFolder(_ path: String) throws { throw failure }
    func signal(_ pid: Int, _ signal: Int32) {}
  }

  let hostName: String?
  let machine: any Machine
  private let failure: HostUnread

  init(hostName: String, why: String) {
    self.hostName = hostName
    failure = HostUnread(hostName: hostName, why: why)
    machine = NoMachine(failure: failure)
  }

  func terminals() throws -> TerminalHost { throw failure }
  func requireReady() throws { throw failure }
  func sbFolder() throws -> String { throw failure }
  func userHome() throws -> String { throw failure }
  func git() throws -> String { throw failure }
  func worktreeRoot() throws -> String { throw failure }
  func sessionFolder(_ id: String) throws -> String { throw failure }
  func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T { throw failure }
  func readSnapshot(claudeProgram: String) throws -> Service.Snapshot { throw failure }
  func alive(_ pids: Set<Int>) throws -> Set<Int> { throw failure }
  func folderUsers(_ folder: String) throws -> [FolderUser] { throw failure }
  func samePath(_ a: String, _ b: String) throws -> Bool { throw failure }
  func realPath(_ path: String) throws -> String? { throw failure }
  func folderGone(_ path: String) throws -> Bool { throw failure }
  func stopClaude(_ pid: Int, below pane: Int, program: String) throws { throw failure }
}

/// A site whose `machine` is the one that a `confirmed` body got, so code that takes a site reports each
/// unanswered command to that call. Every other member is the base site's.
final class CheckedSite: SessionSite {
  private let base: any SessionSite
  let machine: any Machine

  init(_ base: any SessionSite, machine: any Machine) {
    self.base = base
    self.machine = machine
  }

  var hostName: String? { base.hostName }
  func terminals() throws -> TerminalHost { try base.terminals() }
  func requireReady() throws { try base.requireReady() }
  func sbFolder() throws -> String { try base.sbFolder() }
  func userHome() throws -> String { try base.userHome() }
  func git() throws -> String { try base.git() }
  func worktreeRoot() throws -> String { try base.worktreeRoot() }
  func sessionFolder(_ id: String) throws -> String { try base.sessionFolder(id) }
  func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T { try base.confirmed(what, body) }
  func scoped<T>(_ what: String, _ body: (SiteScope) throws -> T) throws -> T { try base.scoped(what, body) }
  func readSnapshot(claudeProgram: String) throws -> Service.Snapshot {
    try base.readSnapshot(claudeProgram: claudeProgram)
  }
  func alive(_ pids: Set<Int>) throws -> Set<Int> { try base.alive(pids) }
  func folderUsers(_ folder: String) throws -> [FolderUser] { try base.folderUsers(folder) }
  func samePath(_ a: String, _ b: String) throws -> Bool { try base.samePath(a, b) }
  func realPath(_ path: String) throws -> String? { try base.realPath(path) }
  func folderGone(_ path: String) throws -> Bool { try base.folderGone(path) }
  func stopClaude(_ pid: Int, below pane: Int, program: String) throws {
    try base.stopClaude(pid, below: pane, program: program)
  }
}
