import Foundation
import SwitchboardCore

/// Where a session's claude, shell, folder, and transcript are: this Mac or a remote host.
/// Session code reaches tmux, git, ps, kill, and files only through the session's site.
protocol SessionSite: AnyObject {
  /// nil for this Mac.
  var hostName: String? { get }
  /// Runs commands and reads files at the site.
  var machine: any Machine { get }
  /// The site's tmux server.
  func terminals() throws -> TerminalHost
  /// The git program at the site.
  func git() throws -> String
  /// Where `sb new --branch` makes worktrees at the site, with `~` resolved there.
  func worktreeRoot() throws -> String
  /// A session's launcher folder at the site.
  func sessionFolder(_ id: String) throws -> String
  /// Runs `body` with the site's machine. On this Mac it runs `body`.
  func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T
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
    self.machine = MacSite.logging(LocalMachine(), to: log)
    self.tmuxServer = try TerminalHost(home: home, config: config, machine: machine)
    guard let git = findExecutable("git") else { throw APIError("can't find git") }
    self.gitPath = git
  }

  private static func logging(_ machine: any Machine, to log: MachineLog?) -> any Machine {
    log.map { LoggedMachine(machine, log: $0.path) } ?? machine
  }

  func terminals() -> TerminalHost { tmuxServer }

  func git() -> String { gitPath }

  func worktreeRoot() throws -> String { config.worktreeRoot.expandingTilde }

  func sessionFolder(_ id: String) throws -> String { home.sessionFolder(id) }

  func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T { try body(machine) }

  func readSnapshot(claudeProgram: String) throws -> Service.Snapshot {
    var s = Service.Snapshot()
    // A snapshot is as old as its first read. `install` uses this to drop
    // one that began before a launch.
    s.taken = nowMs()
    s.panes = try tmuxServer.checkedPanes()
    s.children = Processes.byParent(on: machine)
    for (name, pane) in s.panes where name.hasSuffix("-claude") && !pane.dead {
      if let pid = Service.findClaude(below: pane.pid, program: claudeProgram, in: s.children) {
        s.claudePids[String(name.dropLast("-claude".count))] = pid
      }
    }
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
