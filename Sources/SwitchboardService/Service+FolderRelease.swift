import Foundation
import SwitchboardCore

/// What sbd records when it starts to stop a session's panes before it deletes the session's folder.
struct PaneStop {
  /// The claude that got SIGTERM, when one ran.
  var claudePid: Int?
  /// The panes' processes and every process below them.
  var processes: Set<Int>
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
  /// The pids of the session's Claude and shell panes that still run. It runs on the state queue.
  func livePanePids(_ id: String) -> [Int] {
    [Pane.claude, .shell].compactMap { paneRow(id, $0) }.filter { !$0.dead }.map(\.pid)
      .filter(Processes.isValidPid)
  }

  /// Whether `ancestry` holds the pid of a live Claude or shell pane of a session on this Mac. A session on a
  /// host never holds a local caller, because its pane pids belong to the host. It runs on the state queue.
  func isInside(_ id: String, _ ancestry: Set<Int>) -> Bool {
    entries[id]?.session.host == nil && !ancestry.isDisjoint(with: livePanePids(id))
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
      "`\(command)` runs inside \(id), so it would stop itself. Run it from a terminal outside the session.")
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
    return PaneStop(claudePid: claudePid, processes: processes)
  }

  /// Returns once claude has exited, the Claude pane is closed, every process
  /// that `stop` recorded has exited, and no process uses the session's folder
  /// as `Processes.using` defines it. It runs off the state queue. A claude
  /// that has not exited 5 s after SIGTERM throws, and its pane stays open, so
  /// that a later call finds it. A process that still runs or still uses the
  /// folder 5 s after the pane closes throws. sbd does not signal those
  /// processes, because the user may want to keep them.
  /// `command` names the command that the error tells the user to run again.
  func finishPaneStop(_ session: Session, _ stop: PaneStop, command: String) throws {
    // A process can write to the folder until it exits. `worktree remove` deletes ignored files.
    let site = self.site(for: session)
    if let pid = stop.claudePid, try !waitForExit([pid], seconds: 5, at: site).isEmpty {
      throw APIError("\(session.id)'s claude has not exited. Run `\(command)` again once it has.")
    }
    try closePane(session.id, .claude, at: site)
    let deadline = Date().addingTimeInterval(5)
    let running = try waitForExit(stop.processes, seconds: deadline.timeIntervalSinceNow, at: site)
    var users = try site.folderUsers(session.cwd).filter { !running.contains($0.pid) }
    while running.isEmpty, !users.isEmpty, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.25)
      users = try site.folderUsers(session.cwd).filter { !running.contains($0.pid) }
    }
    guard !running.isEmpty || !users.isEmpty else { return }
    let processes = (try? site.processes()) ?? ProcessTable()
    let named =
      running.sorted().map { "\($0) (\(processes.command(of: $0) ?? "?"), started by the session)" }
      + users.map { "\($0.pid) (\(processes.command(of: $0.pid) ?? "?"), \($0.use.rawValue) \($0.path))" }
    throw APIError(
      "Processes from \(session.id) or in \(session.cwd) still run: \(named.joined(separator: ", ")). Stop them, then run `\(command)` again."
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
