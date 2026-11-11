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
    [Pane.claude, .shell].compactMap { snapshot.panes[paneName(id, $0)] }.filter { !$0.dead }.map(\.pid)
      .filter(Processes.isValidPid)
  }

  /// The refusal for a caller that runs below the session's Claude or shell pane, or nil.
  /// A stop would wait on such a caller, which waits on sbd, so the stop could never
  /// finish. It returns nil for a nil `ancestry`. It runs on the state queue. Every session's panes run
  /// on this Mac, so a local ancestry can hold their pids. A session on another host needs
  /// another check.
  func insideRefusal(_ id: String, _ ancestry: Set<Int>?, command: String) -> APIError? {
    guard let ancestry, !ancestry.isDisjoint(with: livePanePids(id)) else { return nil }
    return APIError(
      "`\(command)` runs inside \(id), so it would stop itself. Run it from a terminal outside the session.")
  }

  /// Records every process below the session's panes, closes the shell pane,
  /// and sends SIGTERM to claude. It runs on the state queue, after `install`
  /// of a fresh snapshot, because it reads the panes' processes from it.
  /// It first throws `insideRefusal` for a caller inside the session, so a
  /// refusal stops nothing.
  func beginPaneStop(_ id: String, caller ancestry: Set<Int>?, command: String) throws -> PaneStop {
    if let refusal = insideRefusal(id, ancestry, command: command) { throw refusal }
    let processes = Processes.descendants(of: livePanePids(id), in: snapshot.children)
    host.kill(paneName(id, .shell))
    var claudePid: Int?
    if case .running(let pid) = claudeState(id) {
      machine(of: id).signal(pid, SIGTERM)
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
    if let pid = stop.claudePid, !Processes.waitForExit([pid], seconds: 5).isEmpty {
      throw APIError("\(session.id)'s claude has not exited. Run `\(command)` again once it has.")
    }
    host.kill(paneName(session.id, .claude))
    let deadline = Date().addingTimeInterval(5)
    let running = Processes.waitForExit(stop.processes, seconds: deadline.timeIntervalSinceNow)
    var users = Processes.using(session.cwd).filter { !running.contains($0.pid) }
    while running.isEmpty, !users.isEmpty, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.25)
      users = Processes.using(session.cwd).filter { !running.contains($0.pid) }
    }
    guard !running.isEmpty || !users.isEmpty else { return }
    let commands = Dictionary(
      uniqueKeysWithValues: Processes.byParent().values.joined().map { ($0.pid, $0.command) })
    let named =
      running.sorted().map { "\($0) (\(commands[$0] ?? "?"), started by the session)" }
      + users.map { "\($0.pid) (\(commands[$0.pid] ?? "?"), \($0.use.rawValue) \($0.path))" }
    throw APIError(
      "Processes from \(session.id) or in \(session.cwd) still run: \(named.joined(separator: ", ")). Stop them, then run `\(command)` again."
    )
  }
}
