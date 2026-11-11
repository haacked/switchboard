import Foundation
import SwitchboardCore

/// What sbd records when it starts to stop a session's panes before it deletes the session's folder.
struct PaneStop {
  /// The claude that got SIGTERM, when one ran.
  var claudePid: Int?
  /// The panes' processes and every process below them.
  var processes: Set<Int>
}

extension Service {
  /// Records every process below the session's panes, closes the shell pane,
  /// and sends SIGTERM to claude. It runs on the state queue, after `install`
  /// of a fresh snapshot, because it reads the panes' processes from it.
  func beginPaneStop(_ id: String) throws -> PaneStop {
    let pids = [Pane.claude, .shell].compactMap { paneRow(id, $0) }.filter { !$0.dead }.map(\.pid)
    let processes = Processes.descendants(of: pids.filter(Processes.isValidPid), in: processChildren(of: id))
    try site(of: id).terminals().kill(paneName(id, .shell))
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
    try site.terminals().kill(paneName(session.id, .claude))
    let deadline = Date().addingTimeInterval(5)
    let running = try waitForExit(stop.processes, seconds: deadline.timeIntervalSinceNow, at: site)
    var users = try site.folderUsers(session.cwd).filter { !running.contains($0.pid) }
    while running.isEmpty, !users.isEmpty, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.25)
      users = try site.folderUsers(session.cwd).filter { !running.contains($0.pid) }
    }
    guard !running.isEmpty || !users.isEmpty else { return }
    let commands = Dictionary(
      uniqueKeysWithValues: Processes.byParent(on: site.machine).values.joined().map { ($0.pid, $0.command) })
    let named =
      running.sorted().map { "\($0) (\(commands[$0] ?? "?"), started by the session)" }
      + users.map { "\($0.pid) (\(commands[$0.pid] ?? "?"), \($0.use.rawValue) \($0.path))" }
    throw APIError(
      "Processes from \(session.id) or in \(session.cwd) still run: \(named.joined(separator: ", ")). Stop them, then run `\(command)` again."
    )
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
