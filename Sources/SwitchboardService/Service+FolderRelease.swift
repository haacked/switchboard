import Foundation
import SwitchboardCore

/// What sbd records when it starts to stop a session's panes before it deletes the session's folder.
struct PaneStop {
  /// The claude that got SIGTERM, when one ran.
  var claudePid: Int?
  /// The panes' processes and every process below them.
  var processes: Set<Int>
  /// Every pane's process on this Mac, each of their ancestors, and sbd's tmux servers. A stop of leftovers never
  /// signals them, because their exit ends sessions.
  var spared: Set<Int> = []
}

/// Who sent a request.
public enum Caller: Sendable {
  /// sbd itself, or a test that calls `handle` directly.
  case inProcess
  /// A client on sbd's socket, with the pid that the kernel recorded at connect, or nil when sbd couldn't read it.
  case client(pid: Int?)

  /// The client's pid and each of its parents, read live, or nil for `.inProcess`. A client
  /// whose pid sbd can't read throws, because sbd then can't show that the client runs
  /// outside the session that `command` would stop.
  func ancestry(command: String) throws -> Set<Int>? {
    guard case .client(let pid) = self else { return nil }
    guard let pid, let ancestry = Processes.ancestors(of: pid) else {
      throw APIError("sbd can't tell which process sent `\(command)`. Run it from a terminal outside the session.")
    }
    return ancestry
  }
}

extension Service {
  /// The pids of the session's `panes` that still run. It runs on the state queue.
  func livePanePids(_ id: String, panes: [Pane] = [.claude, .shell]) -> [Int] {
    panes.compactMap { paneRow(id, $0) }.filter { !$0.dead }.map(\.pid).filter(Processes.isValidPid)
  }

  /// Whether `ancestry` holds the pid of a live pane of `panes` of a session on this Mac. A session on a host never
  /// holds a local caller, because its pane pids belong to the host. It runs on the state queue.
  func isInside(_ id: String, _ ancestry: Set<Int>, panes: [Pane] = [.claude, .shell]) -> Bool {
    entries[id]?.session.host == nil && !ancestry.isDisjoint(with: livePanePids(id, panes: panes))
  }

  /// Where a client with `ancestry` runs: the sessions on this Mac whose panes it runs below, in id order, and
  /// whether it runs below sbd's tmux server. A program that a session starts with `tmux new-session` or
  /// `tmux new-window` runs below the server and outside every pane. It runs on the state queue, after `install` of a
  /// fresh snapshot.
  func callerPlace(_ ancestry: Set<Int>) -> (inside: [String], inServer: Bool) {
    let servers = Set(mac.snapshot.panes.values.map(\.server).filter(Processes.isValidPid))
    return (entries.keys.sorted().filter { isInside($0, ancestry) }, !ancestry.isDisjoint(with: servers))
  }

  /// The refusal for a caller that runs below the session's Claude or shell pane, or nil.
  /// A stop would wait on such a caller, which waits on sbd, so the stop could never
  /// finish. It returns nil for a nil `ancestry`. It runs on the state queue. A client's ancestry holds pids
  /// of this Mac. A request from a host's socket never reaches this, because `HostScope` refuses `rm`, `cleanup`,
  /// and `rm-done` from a host. So a client is never inside a session on a host. The pids of such a session's
  /// panes belong to the host, so it returns nil for it.
  func insideRefusal(_ id: String, _ ancestry: Set<Int>?, command: String) -> APIError? {
    guard let ancestry, isInside(id, ancestry) else { return nil }
    return APIError(
      "`\(command)` runs inside \(mention(id)), so it would stop itself. Run it from a terminal outside the session.")
  }

  /// Records every process below the session's panes, closes the shell pane,
  /// and sends SIGTERM to claude. It runs on the state queue, after `install`
  /// of a fresh snapshot, because it reads the panes' processes from it. It throws for a session on a host
  /// whose snapshot sbd can't read, because it would then find no process to wait for.
  /// It first throws `insideRefusal` for a caller inside the session, so a refusal stops nothing.
  func beginPaneStop(_ id: String, ancestry: Set<Int>?, command: String) throws -> PaneStop {
    try requireRead(id)
    if let refusal = insideRefusal(id, ancestry, command: command) { throw refusal }
    let processes = self.processes(of: id).descendants(of: livePanePids(id))
    try closePane(id, .shell, at: site(of: id))
    var claudePid: Int?
    if case .running(let pid) = claudeState(id) {
      try stopClaude(id, pid)
      claudePid = pid
    }
    return PaneStop(claudePid: claudePid, processes: processes, spared: paneAncestry())
  }

  /// Returns once claude has exited, the Claude pane is closed, every process
  /// that `stop` recorded has exited, and no process uses the session's folder
  /// as `Processes.using` defines it. It runs off the state queue. A claude
  /// that has not exited `stopWaitSeconds` after SIGTERM throws, and its pane stays open, so
  /// that a later call finds it. When every recorded process has exited and each process that
  /// still uses the folder is a leftover, as `leftovers` defines it, of a session on this Mac,
  /// sbd stops the leftovers as `stopLeftovers` describes. A process that still runs or still
  /// uses the folder `stopWaitSeconds` after the pane closes, or after the leftovers' stop, throws.
  /// sbd signals no process other than a leftover, because the user may want to keep it.
  /// `again` is the clause, in lower case, that tells the user how to try again.
  func finishPaneStop(_ session: Session, _ stop: PaneStop, again: String) throws {
    // A process can write to the folder until it exits. `worktree remove` deletes ignored files.
    let site = self.site(for: session)
    if let pid = stop.claudePid, try !waitForExit([pid], seconds: config.stopWaitSeconds, at: site).isEmpty {
      throw APIError("\(session.mention)'s claude has not exited. Once it has, \(again).")
    }
    try closePane(session.id, .claude, at: site)
    let deadline = Date().addingTimeInterval(config.stopWaitSeconds)
    let running = try waitForExit(stop.processes, seconds: deadline.timeIntervalSinceNow, at: site)
    var users = try site.folderUsers(session.cwd).filter { !running.contains($0.pid) }
    let local = site.hostName == nil
    var leftovers: [Int: Int64]?
    while running.isEmpty, !users.isEmpty {
      if local {
        let found = Self.leftovers(
          users, in: ProcessTable.readLocal(), sessionId: session.id, startedSince: session.created,
          sparing: stop.spared)
        if users.allSatisfy({ found[$0.pid] != nil }) {
          leftovers = found
          break
        }
      }
      guard Date() < deadline else { break }
      Thread.sleep(forTimeInterval: 0.25)
      users = try site.folderUsers(session.cwd).filter { !running.contains($0.pid) }
    }
    if let leftovers {
      stopLeftovers(leftovers, of: session, at: site)
      users = try site.folderUsers(session.cwd)
    }
    guard !running.isEmpty || !users.isEmpty else { return }
    let processes = (try? site.processes()) ?? ProcessTable()
    let named =
      running.sorted().map { "\($0) (\(processes.command(of: $0) ?? "?"), started by the session)" }
      + users.map { "\($0.pid) (\(processes.command(of: $0.pid) ?? "?"), \($0.use.rawValue) \($0.path))" }
    throw APIError(
      "Processes from \(session.mention) or in \(session.cwd) still run: \(named.joined(separator: ", ")). Stop them, then \(again)."
    )
  }

  /// Closes the session's pane at the site. On a host, it throws unless the host answered that the pane is
  /// gone, because `TerminalHost.kill` reads a close that got no answer as done.
  func closePane(_ id: String, _ pane: Pane, at site: any SessionSite) throws {
    let name = paneName(id, pane)
    let terminals = try site.terminals()
    guard site.hostName != nil else { return terminals.kill(name) }
    try site.confirmed("the close of \(name)") { _ in try terminals.close(name) }
  }

  /// Every pane's process on this Mac and each of its ancestors, and the tmux server of every pane, read from the
  /// snapshot. It runs on the state queue.
  func paneAncestry() -> Set<Int> {
    let table = mac.snapshot.processes
    var found: Set<Int> = []
    for pane in mac.snapshot.panes.values {
      found.insert(pane.server)
      var pid = pane.pid
      while Processes.isValidPid(pid), found.insert(pid).inserted, let row = table.row(pid) { pid = row.ppid }
    }
    return found
  }

  /// The start time, in microseconds since the epoch, of each user that is a leftover of the session. A leftover's
  /// parent is pid 1, so no process waits on it. It is not a zombie, and it started at or after `since`, which is in
  /// milliseconds since the epoch. Its environment holds the session's `SB_SESSION_ID`, so the session started it.
  /// The Bash tool runs each command in a new POSIX session, so the environment is the only link between the
  /// session and a watcher that a Bash command starts. macOS hides the environment of a program that ships with
  /// macOS, such as /bin/sh, so such a program is never a leftover. A pid in `sparing` is never a leftover. A table
  /// parsed from `ps` holds start time 0, so it gives no leftover.
  static func leftovers(
    _ users: [FolderUser], in table: ProcessTable, sessionId: String, startedSince since: Int64,
    sparing: Set<Int> = [], environment: (Int) -> [String] = { ProcessTable.environment(of: pid_t($0)) }
  ) -> [Int: Int64] {
    let marker = "SB_SESSION_ID=\(sessionId)"
    var found: [Int: Int64] = [:]
    for user in users where !sparing.contains(user.pid) {
      guard let row = table.row(user.pid), row.ppid == 1, !row.isZombie, row.startTime > 0,
        row.startTime >= since * 1000, environment(user.pid).contains(marker)
      else { continue }
      found[user.pid] = row.startTime
    }
    return found
  }

  /// Sends SIGTERM to each leftover on this Mac, waits up to `stopWaitSeconds` for them to exit, then sends
  /// SIGKILL to each that still runs. A pid whose start time differs from the recorded one names another
  /// process, so it gets no signal.
  private func stopLeftovers(_ leftovers: [Int: Int64], of session: Session, at site: any SessionSite) {
    let signal = { (sig: Int32) in
      let table = ProcessTable.readLocal()
      for (pid, start) in leftovers where table.row(pid)?.startTime == start {
        logLine("sending signal \(sig) to leftover \(pid) (\(table.command(of: pid) ?? "?")) of \(session.id)")
        site.machine.signal(pid, sig)
      }
    }
    signal(SIGTERM)
    guard !Processes.waitForExit(Set(leftovers.keys), seconds: config.stopWaitSeconds).isEmpty else { return }
    signal(SIGKILL)
    _ = Processes.waitForExit(Set(leftovers.keys), seconds: 1)
  }

  /// Waits up to `seconds` for every pid to exit at the site. Returns the pids that still run.
  private func waitForExit(_ pids: Set<Int>, seconds: TimeInterval, at site: any SessionSite) throws -> Set<Int> {
    let deadline = Date().addingTimeInterval(seconds)
    var alive = try site.alive(pids)
    while !alive.isEmpty, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      alive = try site.alive(alive)
    }
    return alive
  }
}
