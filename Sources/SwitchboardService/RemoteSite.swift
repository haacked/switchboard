import Foundation
import SwitchboardCore

/// What one setup run learned about the host. It belongs to one connection.
struct BoxFacts: Equatable {
  /// The link's connection counter when setup read the facts.
  var epoch: Int
  /// Absolute, from $HOME on the host.
  var home: String
  /// The host's `shell` key, else $SHELL there, else /bin/sh.
  var shell: String
  var user: String
  var lang: String
  /// Absolute paths on the host.
  var tmux: String
  var git: String
  var python: String
  /// This Mac's clock minus the host's.
  var clockOffsetMs: Int64

  /// The folder that Switchboard keeps on the host.
  var folder: String { "\(home)/.sb" }

  /// Reads the setup script's answer: the home, tmux, git, python3, the shell, the user, the locale, and the
  /// clock in ns, with a NUL after each. The shell is empty when the host's `shell` key is not an absolute path to
  /// an executable file there. It throws for an answer that is cut short, for a home that is empty, not absolute,
  /// or holds a newline, for a host that lacks a tool, for such a `shell` key, and for a shell whose path holds a
  /// character other than letters, digits, and / . _ + -.
  static func parse(_ answer: Data, epoch: Int, host: HostConfig, now: Int64) throws -> BoxFacts {
    let f = try RemoteSite.fields(answer, count: 8, of: "the setup answer of \(host.name)")
    let home = f[0]
    guard isAbsolute(home) else {
      throw APIError("\(host.name) reports the home \"\(home)\", which is not an absolute path on one line")
    }
    var tools: [String] = []
    for (name, path) in [("tmux", f[1]), ("git", f[2]), ("python3", f[3])] {
      if path.isEmpty {
        throw APIError(
          "\(name) is not installed on \(host.name). Install it there with `sudo apt-get install -y \(name)`")
      }
      guard isAbsolute(path) else {
        throw APIError("\(host.name) reports \(name) at \"\(path)\", which is not absolute")
      }
      tools.append(path)
    }
    if let shell = host.shell, f[4].isEmpty {
      throw APIError(
        "\(host.name)'s shell key names \"\(shell)\", which is not an absolute path to an executable file on \(host.name)"
      )
    }
    let shell = host.shell ?? (f[4].isEmpty ? "/bin/sh" : f[4])
    // The pane's command names the shell without quotes, so a character that a shell reads would break it.
    guard shell.range(of: "^[A-Za-z0-9/._+-]+$", options: .regularExpression) != nil else {
      let named = host.shell == nil ? "\(host.name)'s $SHELL is" : "\(host.name)'s shell key names"
      throw APIError("\(named) \"\(shell)\", which holds a character other than letters, digits, and / . _ + -")
    }
    let clock = f[7]
    guard !clock.isEmpty, clock.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
      let ns = UInt64(clock)
    else { throw APIError("\(host.name) reports the clock \"\(clock)\", which is not a count of nanoseconds") }
    return BoxFacts(
      epoch: epoch, home: home, shell: shell, user: f[5], lang: f[6],
      tmux: tools[0], git: tools[1], python: tools[2], clockOffsetMs: now - Int64(ns / 1_000_000))
  }

  private static func isAbsolute(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.utf8.contains(UInt8(ascii: "\n"))
  }
}

/// Gives a timeout to each `run` that names none, so no command reaches a host without one.
struct TimedMachine: Machine {
  /// `git worktree add` checks out a whole repo, and `git worktree remove` deletes one.
  static let worktreeChangeSeconds = 600.0

  private let base: any Machine
  private let fallback: Double

  init(_ base: any Machine, fallback: Double) {
    self.base = base
    self.fallback = fallback
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    let changesWorktree = zip(args, args.dropFirst()).contains { $0 == "worktree" && ($1 == "add" || $1 == "remove") }
    return try base.run(
      executable, args, env: env, input: input,
      timeout: timeout ?? (changesWorktree ? Self.worktreeChangeSeconds : fallback))
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? { base.read(path, from: offset, count: count) }
  func size(_ path: String) -> UInt64? { base.size(path) }
  func exists(_ path: String) -> Bool { base.exists(path) }
  func isFolder(_ path: String) -> Bool { base.isFolder(path) }
  func modified(_ path: String) -> Date? { base.modified(path) }
  func list(_ folder: String) -> [String] { base.list(folder) }
  func createFolder(_ path: String) throws { try base.createFolder(path) }
  func signal(_ pid: Int, _ signal: Int32) { base.signal(pid, signal) }
}

/// A machine of one `scoped` call. Each member first runs the scope's `require`. A `run` throws its error, and
/// every other member sends nothing and returns what a host that gave no answer returns.
private struct ScopedMachine: Machine {
  let base: any Machine
  let require: @Sendable () throws -> Void

  private var allowed: Bool { (try? require()) != nil }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    try require()
    return try base.run(executable, args, env: env, input: input, timeout: timeout)
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    allowed ? base.read(path, from: offset, count: count) : nil
  }
  func size(_ path: String) -> UInt64? { allowed ? base.size(path) : nil }
  func exists(_ path: String) -> Bool { allowed && base.exists(path) }
  func isFolder(_ path: String) -> Bool { allowed && base.isFolder(path) }
  func modified(_ path: String) -> Date? { allowed ? base.modified(path) : nil }
  func list(_ folder: String) -> [String] { allowed ? base.list(folder) : [] }
  func createFolder(_ path: String) throws {
    try require()
    try base.createFolder(path)
  }
  func signal(_ pid: Int, _ signal: Int32) { if allowed { base.signal(pid, signal) } }
}

/// Holds the first error of the commands of one `confirmed` call that got no answer.
final class AnswerCheck: @unchecked Sendable {
  private let lock = NSLock()
  private var first: Error?

  func missed(_ error: Error) { lock.withLock { first = first ?? error } }

  var failure: Error? { lock.withLock { first } }
}

/// A remote host that sbd reaches over one `HostLink`. Every member but `hostName`, `machine`, `facts`,
/// `setupError`, and `prepare` throws `HostUnread` unless the link is connected and setup ran on its
/// current connection.
final class RemoteSite: SessionSite, @unchecked Sendable {
  /// The timeout of each tmux, ps, and kill command.
  static let commandSeconds = 5.0
  /// A command with no timeout of its own gets this one.
  static let fallbackSeconds = 30.0
  /// How long after a command's timeout the link gives up on the answer and closes.
  static let deadlineSlack = 3.0
  static let setupSeconds = 20.0
  /// How long a failed setup waits for the link to report a drop before the failure counts as lasting.
  static let dropGraceSeconds = 1.0
  /// The host sends SIGKILL this long after the SIGTERM of a command's timeout, in `RemoteShellProtocol`'s
  /// `sb_run`.
  static let killGraceSeconds = 2.0

  var hostName: String? { name }
  let machine: any Machine
  let link: HostLink
  let config: HostConfig
  private var name: String { config.name }
  private let home: Home
  private let tap: ((any Machine) -> any Machine)?

  private struct Ready {
    var facts: BoxFacts
    var terminals: TerminalHost
  }

  /// Guards `ready` and `failed`.
  private let lock = NSLock()
  private var ready: Ready?
  /// Why setup failed, and the connection it failed on.
  private var failed: (epoch: Int, text: String)?
  private var listenerFailure: String?
  /// Why the reconcile last failed, and the connection it failed on.
  private var reconcileFailure: (epoch: Int, text: String)?
  private var lastClockOffsetMs: Int64?
  /// One setup runs at a time.
  private let setup = NSLock()

  /// `tap` wraps each machine that the site builds, below the one that supplies timeouts. Tests record through it.
  init(link: HostLink, config: HostConfig, home: Home, tap: ((any Machine) -> any Machine)? = nil) {
    self.link = link
    self.config = config
    self.home = home
    self.tap = tap
    self.machine = RemoteSite.timed(link, check: nil, tap: tap)
  }

  private static func timed(
    _ link: HostLink, check: AnswerCheck?, tap: ((any Machine) -> any Machine)?, slack: Double = deadlineSlack
  ) -> any Machine {
    let base: any Machine = link.machine(slack: slack, check: check)
    return TimedMachine(tap?(base) ?? base, fallback: fallbackSeconds)
  }

  // MARK: Setup

  /// The facts of the current connection, or nil before setup finished on it.
  var facts: BoxFacts? { (try? current())?.facts }

  /// Why setup failed on the current connection.
  var setupError: String? {
    let status = link.status
    guard status.state == .connected else { return nil }
    return lock.withLock { failed.flatMap { $0.epoch == status.connection ? $0.text : nil } }
  }

  /// Why sbd does not listen on the host's socket on this Mac, or nil when it does. Setup fails with it,
  /// because the host's hooks could not reach sbd.
  var listenerProblem: String? {
    get { lock.withLock { listenerFailure } }
    set { lock.withLock { listenerFailure = newValue } }
  }

  /// Why the reconcile failed on the current connection, or nil. `sb host ls` shows it, because the link reads
  /// `connected` while the host's sessions still wait for the reconcile.
  var reconcileError: String? {
    let status = link.status
    guard status.state == .connected else { return nil }
    return lock.withLock { reconcileFailure.flatMap { $0.epoch == status.connection ? $0.text : nil } }
  }

  /// Keeps why the reconcile failed on the connection, or forgets it with nil.
  func noteReconcile(failure text: String?, on epoch: Int) {
    lock.withLock { reconcileFailure = text.map { (epoch, $0) } }
  }

  /// This Mac's clock minus the host's, as the last setup measured it on any connection.
  var clockOffsetMs: Int64? { lock.withLock { lastClockOffsetMs } }

  private func unread(_ why: String) -> HostUnread { HostUnread(hostName: name, why: why) }

  private func requireConnected() throws -> HostLink.Status {
    let status = link.status
    guard status.state == .connected else { throw unread(status.error ?? "its link is \(status.state.rawValue)") }
    return status
  }

  /// The facts and the tmux server of the current connection. It throws `HostUnread` unless the link is
  /// connected and setup ran on this connection.
  private func current() throws -> Ready {
    let status = try requireConnected()
    return try lock.withLock {
      if let ready, ready.facts.epoch == status.connection { return ready }
      if let failed, failed.epoch == status.connection { throw unread(failed.text) }
      throw unread("setup has not run on this connection")
    }
  }

  /// Runs setup on the current connection unless it already ran. One caller runs it at a time. A failed setup
  /// leaves the link connected, and the next call runs setup again.
  @discardableResult
  func prepare() throws -> BoxFacts {
    try setup.withLock {
      let status = try requireConnected()
      if let ready = lock.withLock({ ready }), ready.facts.epoch == status.connection { return ready.facts }
      do {
        let facts = try runSetup(epoch: status.connection)
        let after = link.status
        guard after.state == .connected, after.connection == facts.epoch else {
          throw unread("the link dropped during setup")
        }
        lock.withLock {
          ready = Ready(facts: facts, terminals: terminals(for: facts))
          failed = nil
        }
        return facts
      } catch {
        lock.withLock {
          ready = nil
          failed = error is HostUnread ? nil : (status.connection, "\(error)")
        }
        throw error
      }
    }
  }

  /// Connects the link and waits up to `seconds` for setup to finish on a connection. It throws the reason when
  /// the link is still down then. A setup that fails while its connection stays up throws within
  /// `dropGraceSeconds`. A setup that ends because its connection dropped runs again on the next connection,
  /// until the deadline. A setup that `HostLink.disconnect()` ended throws, and the link stays disconnected.
  func awaitReady(seconds: Double) throws {
    link.connect()
    let deadline = Date().addingTimeInterval(seconds)
    while true {
      let status = link.status
      if status.state == .connected {
        do {
          try prepare()
          return
        } catch {
          // A command or the forward reports a dropped link before the link's status does. Any other
          // failure waits `dropGraceSeconds` for that status before it counts as lasting.
          let wait = error is HostUnread ? deadline : min(deadline, Date().addingTimeInterval(Self.dropGraceSeconds))
          // `disconnect()` also ends setup. The user closed that link, so it stays closed.
          guard waitToLeave(status.connection, until: wait), link.status.state != .disconnected else { throw error }
          // Only the service's tick polls the link, so the next connection starts here.
          link.connect()
          continue
        }
      }
      if Date() >= deadline {
        // A retry clears the link's error while it runs. The last failure still holds the cause.
        let why = status.lastFailure.map { ": \($0)" } ?? ""
        throw APIError("\(name) is not connected (\(status.state.rawValue)\(why)). Switchboard keeps trying.")
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  private func hasLeft(_ connection: Int) -> Bool {
    let status = link.status
    return status.state != .connected || status.connection != connection
  }

  /// Waits until the link is no longer connected on `connection`. It returns false when the deadline passes first.
  private func waitToLeave(_ connection: Int, until deadline: Date) -> Bool {
    while !hasLeft(connection) {
      if Date() >= deadline { return false }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return true
  }

  /// Prints the facts, then creates the box's folders, writes tmux.conf, and points agent.sock at the
  /// connection's agent. `$1` is the host's `tmux` key or empty, `$2` is the text of tmux.conf, and `$3` is the
  /// host's `shell` key or empty. The shell that it prints is `$3` when that is an absolute path to an executable
  /// file, empty when it is not, and $SHELL when `$3` is empty. It creates nothing under a home that
  /// `BoxFacts.parse` refuses. It exits 1, and changes nothing, when `.sb`, `.sb/bin`, or `.sb/sessions` is a
  /// link.
  private static let setupScript = #"""
    set -f
    find_tool() {
      case $1 in
      */*)
        if [ -f "$1" ] && [ -x "$1" ]; then printf %s "$1"; fi
        return
        ;;
      esac
      old=$IFS
      IFS=:
      for d in $PATH "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin /usr/bin /bin; do
        case $d in /*) ;; *) continue ;; esac
        if [ -f "$d/$1" ] && [ -x "$d/$1" ]; then
          IFS=$old
          printf %s "$d/$1"
          return
        fi
      done
      IFS=$old
    }
    python=$(find_tool python3)
    clock=
    if [ -n "$python" ]; then clock=$("$python" -c 'import time; print(time.time_ns())' 2>/dev/null); fi
    sh=$SHELL
    if [ -n "$3" ]; then
      sh=
      case $3 in /*) if [ -f "$3" ] && [ -x "$3" ]; then sh=$3; fi ;; esac
    fi
    printf '%s\0' "$HOME" "$(find_tool "${1:-tmux}")" "$(find_tool git)" "$python" "$sh" "$(id -un)" "$LANG" "$clock"
    case $HOME in /*) ;; *) exit 0 ;; esac
    case $HOME in *'
    '*) exit 0 ;; esac
    sb=$HOME/.sb
    for d in "$sb" "$sb/bin" "$sb/sessions"; do
      if [ -L "$d" ]; then
        printf '%s is a link. Switchboard keeps its files on the host in a folder that is not a link\n' "$d" >&2
        exit 1
      fi
    done
    umask 077
    mkdir -p "$sb/bin" "$sb/sessions" && chmod 700 "$sb" "$sb/bin" "$sb/sessions" || exit 1
    rm -f "$sb/tmux.conf.new" && printf %s "$2" >"$sb/tmux.conf.new" && mv "$sb/tmux.conf.new" "$sb/tmux.conf" || exit 1
    if [ -n "$SSH_AUTH_SOCK" ]; then
      ln -sfn "$SSH_AUTH_SOCK" "$sb/agent.sock" || exit 1
    elif [ -L "$sb/agent.sock" ]; then
      rm -f "$sb/agent.sock"
    fi
    """#

  /// Writes the shim and the hook settings when their text differs, then removes a socket file that an
  /// earlier forward left at `sbd.sock`. `$1` is the box's folder, `$2` the shim, and `$3` the settings. It
  /// exits 1, and writes nothing, when the box's folder or its `bin` is a link or not a folder. It exits 4, and
  /// removes nothing, when `sbd.sock` exists and is not a socket.
  static let hookScript = #"""
    for d in "$1" "$1/bin"; do
      if [ -L "$d" ] || [ ! -d "$d" ]; then
        printf '%s is a link or not a folder, so Switchboard wrote nothing there\n' "$d" >&2
        exit 1
      fi
    done
    umask 077
    put() {
      if [ -f "$1" ] && [ ! -L "$1" ] && [ "$(cat "$1"; printf x)" = "${2}x" ]; then return 0; fi
      rm -f "$1.new" && printf %s "$2" >"$1.new" && chmod "$3" "$1.new" && mv -f "$1.new" "$1"
    }
    put "$1/bin/sb-shim" "$2" 700 || exit 1
    put "$1/claude-settings.json" "$3" 600 || exit 1
    s=$1/sbd.sock
    if [ -L "$s" ] || { [ -e "$s" ] && [ ! -S "$s" ]; }; then
      printf '%s exists and is not a socket, so Switchboard did not replace it with its forward\n' "$s" >&2
      exit 4
    fi
    if [ -S "$s" ]; then rm -f "$s" || exit 1; fi
    """#

  /// Writes the shim and the hook settings on the host, then forwards the host's `~/.sb/sbd.sock` to the
  /// host's socket on this Mac. The forward can't start with the master, because its path needs the host's
  /// home.
  private func setUpHooks(_ facts: BoxFacts) throws {
    if let listenerProblem { throw APIError(listenerProblem) }
    let r: CommandResult
    do {
      r = try machine.run(
        "/bin/sh", ["-c", Self.hookScript, "sb", facts.folder, BoxShim.source, BoxShim.settings(for: facts)],
        env: nil, input: nil, timeout: Self.setupSeconds)
    } catch {
      throw unread("setup got no answer: \(error)")
    }
    guard r.status == 0 else { throw APIError("setup on \(name) failed: \(r.problem)") }
    try link.forward(remote: BoxShim.socketPath(for: facts), local: home.hostSocket(name))
  }

  private func runSetup(epoch: Int) throws -> BoxFacts {
    let r: CommandResult
    do {
      r = try machine.run(
        "/bin/sh", ["-c", Self.setupScript, "sb", config.tmux ?? "", TerminalHost.configText, config.shell ?? ""],
        env: nil, input: nil, timeout: Self.setupSeconds)
    } catch {
      throw unread("setup got no answer: \(error)")
    }
    guard r.status == 0 else { throw APIError("setup on \(name) failed: \(r.problem)") }
    let facts = try BoxFacts.parse(Data(r.stdout.utf8), epoch: epoch, host: config, now: nowMs())
    lock.withLock { lastClockOffsetMs = facts.clockOffsetMs }
    try setUpHooks(facts)
    return facts
  }

  /// The host's tmux server. A pane gets the host's values and nothing from sbd's environment. SSH_AUTH_SOCK
  /// names the box's agent.sock, which setup points at each connection's agent. The link may forward no agent,
  /// and the name then leads nowhere.
  private func terminals(for facts: BoxFacts) -> TerminalHost {
    TerminalHost(
      tmux: facts.tmux, socket: "\(facts.folder)/tmux.sock", conf: "\(facts.folder)/tmux.conf", shell: facts.shell,
      baseEnv: Self.environment(for: facts), timeout: Self.commandSeconds, machine: machine)
  }

  /// The environment that sbd gives a program on the host that runs as a pane's program does: the host's
  /// values and nothing from sbd's environment.
  static func environment(for facts: BoxFacts) -> [String: String] {
    var env = [
      "TERM": "xterm-256color", "SHELL": facts.shell, "HOME": facts.home,
      "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "SSH_AUTH_SOCK": "\(facts.folder)/agent.sock",
    ]
    if !facts.user.isEmpty {
      env["USER"] = facts.user
      env["LOGNAME"] = facts.user
    }
    if !facts.lang.isEmpty { env["LANG"] = facts.lang }
    return env
  }

  // MARK: The site

  func terminals() throws -> TerminalHost { try current().terminals }

  func requireReady() throws { _ = try current() }

  func sbFolder() throws -> String { try current().facts.folder }

  func userHome() throws -> String { try current().facts.home }

  func git() throws -> String { try current().facts.git }

  func worktreeRoot() throws -> String { try expand(config.worktreeRoot) }

  func sessionFolder(_ id: String) throws -> String { "\(try sbFolder())/sessions/\(id)" }

  /// `~` and `~/x` become the host's home. Any other `~name` throws, because sbd does not know that user's home.
  func expand(_ path: String) throws -> String {
    let home = try current().facts.home
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst() }
    if path.hasPrefix("~") {
      throw APIError("\(path) names the home of another user on \(name). Use an absolute path, or one below ~/")
    }
    return path
  }

  /// Runs `body` with a machine of the host. It returns `body`'s result only when setup ran on the link's
  /// connection, the host answered every command that `body` sent, and the link is still on that connection
  /// afterwards. It throws `HostUnread` otherwise, before `body` runs when the site is not ready. An error
  /// that `body` throws passes through when every command was answered.
  func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T {
    try confirmed(what, slack: Self.deadlineSlack, body)
  }

  /// `confirmed(_:_:)` whose machine waits `slack` past each command's timeout for the host's answer.
  func confirmed<T>(_ what: String, slack: Double, _ body: (any Machine) throws -> T) throws -> T {
    let epoch = try current().facts.epoch
    let check = AnswerCheck()
    let result = Result { try body(RemoteSite.timed(link, check: check, tap: tap, slack: slack)) }
    try requireAnswered(what, check: check, epoch: epoch)
    return try result.get()
  }

  func scoped<T>(_ what: String, _ body: (SiteScope) throws -> T) throws -> T {
    let epoch = try current().facts.epoch
    let check = AnswerCheck()
    let require: @Sendable () throws -> Void = { [self] in try requireAnswered(what, check: check, epoch: epoch) }
    let machine = ScopedMachine(base: RemoteSite.timed(link, check: check, tap: tap), require: require)
    let result = Result { try body(SiteScope(site: CheckedSite(self, machine: machine), require: require)) }
    try require()
    return try result.get()
  }

  /// Throws `HostUnread` when a command got no answer or the link left the connection `epoch`. The link's
  /// counter only grows, so a link that is on `epoch` now was on it since `epoch` began.
  private func requireAnswered(_ what: String, check: AnswerCheck, epoch: Int) throws {
    if let failure = check.failure { throw unread("\(what) got no answer (\(failure))") }
    let status = link.status
    guard status.state == .connected, status.connection == epoch else {
      throw unread(status.error ?? "the link dropped during \(what)")
    }
  }

  /// The fields of an answer that prints a NUL after each field. It throws for an answer that does not end
  /// with a NUL, which a cut answer does not, and for any other count of fields.
  static func fields(_ answer: Data, count: Int, of what: String) throws -> [String] {
    guard answer.last == 0 else { throw APIError("\(what) is cut short") }
    let parts = answer.dropLast().split(separator: 0, omittingEmptySubsequences: false)
    guard parts.count == count else { throw APIError("\(what) has \(parts.count) fields, not \(count)") }
    return try parts.map {
      guard let text = String(data: Data($0), encoding: .utf8) else { throw APIError("\(what) is not text") }
      return text
    }
  }

  // MARK: Panes and processes

  /// Prints tmux's exit status, its output with its error text, ps's exit status, and ps's output, with a NUL
  /// after each. `$1` to `$4` are the tmux program, its socket, its config file, and the pane format.
  private static let readScript = #"""
    out=$("$1" -S "$2" -f "$3" list-panes -a -F "$4" 2>&1)
    printf '%s\0%s\0' "$?" "$out"
    out=$(ps -A -o pid=,ppid=,pgid=,args=)
    printf '%s\0%s\0' "$?" "$out"
    """#

  /// The snapshot in one answer of `readScript`. It throws unless ps exited 0 and tmux either exited 0 or
  /// reported that no server runs, which means no panes.
  static func parseBatchedRead(_ answer: Data) throws -> Service.Snapshot {
    let f = try fields(answer, count: 4, of: "the pane and process read")
    guard let tmuxStatus = Int(f[0]), let psStatus = Int(f[2]) else {
      throw APIError("the pane and process read holds no exit status")
    }
    guard psStatus == 0 else { throw APIError("ps exited with status \(psStatus)") }
    var read = Service.Snapshot()
    if tmuxStatus == 0 {
      read.panes = PaneRow.parse(f[1])
    } else if !TerminalHost.saysNoServer(f[1]) {
      throw APIError("tmux list-panes: \(f[1].trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    read.processes = ProcessTable.parse(f[3])
    return read
  }

  private func batchedRead(_ machine: any Machine) throws -> Service.Snapshot {
    let ready = try current()
    let server = ready.terminals
    let taken = nowMs()
    let r = try machine.run(
      "/bin/sh", ["-c", Self.readScript, "sb", server.tmux, server.socket, server.conf, TerminalHost.paneFormat],
      env: nil, input: nil, timeout: Self.commandSeconds)
    guard r.status == 0 else { throw APIError("the pane and process read on \(name) failed: \(r.problem)") }
    var read = try Self.parseBatchedRead(Data(r.stdout.utf8))
    read.taken = taken
    read.connection = ready.facts.epoch
    return read
  }

  func readSnapshot(claudeProgram: String) throws -> Service.Snapshot {
    var read = try confirmed("the pane and process read") { try batchedRead($0) }
    read.findClaudes(program: claudeProgram)
    return read
  }

  func processes() throws -> ProcessTable {
    try confirmed("the pane and process read") { try batchedRead($0) }.processes
  }

  /// Exits 3 without a signal unless the parent of pid `$1` is still `$2`.
  private static let killScript = #"[ "$(ps -o ppid= -p "$1" | tr -d " ")" = "$2" ] || exit 3; kill -s TERM "$1""#

  /// Sends SIGTERM to `pid` only when a read taken in this call shows `pane` as the live Claude pane of a
  /// session, `pid` as that session's claude, and the claude program in its command, and the host finds `pid`
  /// still below the parent that the read showed in the command that sends the signal. It throws otherwise.
  /// `HostUnread` means that sbd can't say whether the signal was sent.
  func stopClaude(_ pid: Int, below pane: Int, program: String) throws {
    _ = try current()
    guard Processes.isValidPid(pid), pid > 1, Processes.isValidPid(pane), pane > 1 else {
      throw APIError("\(pid) below \(pane) names no claude process on \(name), so nothing was signalled")
    }
    try confirmed("the stop of claude") { machine in
      var read = try batchedRead(machine)
      read.findClaudes(program: program)
      let changed = APIError("the claude process changed, so nothing was signalled")
      let row = read.panes.first { $0.key.hasSuffix("-claude") && !$0.value.dead && $0.value.pid == pane }
      guard let session = row.map({ String($0.key.dropLast("-claude".count)) }), read.claudePids[session] == pid,
        let process = read.processes.row(pid), Service.isClaude(read.processes.command(of: pid) ?? "", program: program)
      else { throw changed }
      let r = try machine.run(
        "/bin/sh", ["-c", Self.killScript, "sb", String(pid), String(process.ppid)], env: nil, input: nil,
        timeout: Self.commandSeconds)
      if r.status == 3 { throw changed }
      guard r.status == 0 else { throw APIError("the signal to \(pid) on \(name) failed: \(r.problem)") }
    }
  }

  /// Lists every pid on the host, then a line `done`. `ps` lists another user's process, which `kill -0` can't
  /// tell from one that exited.
  private static let aliveScript = "ps -A -o pid= && echo done"

  /// The pids that still run on the host, from one list of its processes. It throws unless the list ends as
  /// `aliveScript` ends it, so a list that its timeout cut never reads as an exit.
  func alive(_ pids: Set<Int>) throws -> Set<Int> {
    try confirmed("the check of the processes") { machine in
      let r = try machine.run(
        "/bin/sh", ["-c", Self.aliveScript], env: nil, input: nil, timeout: Self.commandSeconds)
      let lines = r.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      guard r.status == 0, lines.last == "done" else {
        throw APIError("the check of the processes on \(name) failed: \(r.problem)")
      }
      return pids.intersection(lines.dropLast().compactMap { Int($0) })
    }
  }

  /// The status with which `folderUsersScript` says that it can't check, such as on a host with neither /proc
  /// nor lsof.
  static let cantCheckStatus: Int32 = 97

  /// The processes on the host that use the folder, as `Processes.using` defines a use. It throws when the
  /// host can't check, so a missing answer never reads as no users.
  func folderUsers(_ folder: String) throws -> [FolderUser] {
    try confirmed("the check of the processes that use \(folder)") { machine in
      let r = try machine.run(
        "/bin/sh", ["-c", Self.folderUsersScript, "sb", folder, "/proc"], env: nil, input: nil,
        timeout: Self.fallbackSeconds)
      if r.status == Self.cantCheckStatus {
        throw APIError("can't check which processes use \(folder) on \(name): \(r.problem)")
      }
      guard r.status == 0 else {
        throw APIError("the check of the processes that use \(folder) on \(name) failed: \(r.problem)")
      }
      return try Self.parseFolderUsers(Data(r.stdout.utf8))
    }
  }

  // MARK: Paths

  /// Runs Python code on the host with the paths as its arguments and returns what it printed.
  private func pathAnswer(_ what: String, _ code: String, _ paths: [String]) throws -> String {
    try confirmed(what) { machine in
      let r = try machine.run(try current().facts.python, ["-I", "-S", "-c", code] + paths)
      guard r.status == 0 else { throw APIError("\(what) on \(name) failed: \(r.problem)") }
      return r.stdout
    }
  }

  /// As `MacSite.samePath`: the deepest folder that exists is resolved, and the rest is compared as text.
  func samePath(_ a: String, _ b: String) throws -> Bool {
    let code = """
      import os, sys
      def real(p):
          p = os.path.normpath(p)
          gone = []
          while not os.path.exists(p) and p != "/":
              gone.insert(0, os.path.basename(p))
              p = os.path.dirname(p)
          return os.path.join(os.path.realpath(p), *gone)
      sys.stdout.write("same" if real(sys.argv[1]) == real(sys.argv[2]) else "different")
      """
    switch try pathAnswer("the comparison of two paths", code, [a, b]) {
    case "same": return true
    case "different": return false
    case let other: throw APIError("the comparison of two paths on \(name) printed \"\(other)\"")
    }
  }

  /// The path with every symlink resolved, or nil when the host answered that the path doesn't exist.
  func resolvedPath(_ path: String) throws -> String? {
    let code = """
      import os, sys
      p = sys.argv[1]
      sys.stdout.buffer.write(b"path\\0" + os.fsencode(os.path.realpath(p)) if os.path.exists(p) else b"none")
      """
    let answer = try pathAnswer("the resolution of a path", code, [path])
    if answer == "none" { return nil }
    guard answer.hasPrefix("path\0") else {
      throw APIError("the resolution of a path on \(name) printed \"\(answer)\"")
    }
    return String(answer.dropFirst("path\0".count))
  }

  /// True only when the host answered that the path does not exist. Any other failure to read it, such as a
  /// folder above it that the host can't search, is not gone.
  func folderGone(_ path: String) throws -> Bool {
    let code = """
      import os, sys
      try:
          os.stat(sys.argv[1])
          sys.stdout.write("there")
      except FileNotFoundError:
          sys.stdout.write("gone")
      except OSError:
          sys.stdout.write("unread")
      """
    switch try pathAnswer("the check of a folder", code, [path]) {
    case "gone": return true
    case "there", "unread": return false
    case let other: throw APIError("the check of a folder on \(name) printed \"\(other)\"")
    }
  }
}
