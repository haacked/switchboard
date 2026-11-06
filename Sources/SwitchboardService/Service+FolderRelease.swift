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
  func beginPaneStop(_ id: String) -> PaneStop {
    let panes = [Pane.claude, .shell].compactMap { snapshot.panes[paneName(id, $0)]?.pid }
    let processes = Processes.descendants(of: panes.filter(Processes.isValidPid), in: snapshot.children)
    host.kill(paneName(id, .shell))
    var claudePid: Int?
    if case .running(let pid) = claudeState(id) {
      kill(pid_t(pid), SIGTERM)
      claudePid = pid
    }
    return PaneStop(claudePid: claudePid, processes: processes)
  }

  /// Returns once claude has exited, the Claude pane is closed, every process
  /// that `stop` recorded has exited, and no process has its working folder,
  /// its program, or an open file in the session's folder. It runs off the
  /// state queue. A claude that has not exited 5 s after SIGTERM throws, and
  /// its pane stays open, so that a later call finds it. A process that still
  /// runs or still has the folder open 5 s after the pane closes throws. sbd
  /// does not signal those processes, because the user may want to keep them.
  /// `command` names the command that the error tells the user to run again.
  func finishPaneStop(_ session: Session, _ stop: PaneStop, command: String) throws {
    // A process can write to the folder until it exits. `worktree remove` deletes ignored files.
    if let pid = stop.claudePid, !Processes.waitForExit([pid], seconds: 5).isEmpty {
      throw APIError("\(session.id)'s claude has not exited. Run `\(command)` again once it has.")
    }
    host.kill(paneName(session.id, .claude))
    let deadline = Date().addingTimeInterval(5)
    while true {
      let running = stop.processes.filter(Processes.exists)
      let late = Date() >= deadline
      // The folder scan reads every process, so it waits until the panes' processes are gone.
      guard running.isEmpty || late else {
        Thread.sleep(forTimeInterval: 0.25)
        continue
      }
      let users = Processes.using(session.cwd).filter { !running.contains($0.pid) }
      if running.isEmpty && users.isEmpty { return }
      if late {
        let commands = Dictionary(
          uniqueKeysWithValues: Processes.byParent().values.joined().map { ($0.pid, $0.command) })
        let named =
          running.sorted().map { "\($0) (\(commands[$0] ?? "?"))" }
          + users.map { "\($0.pid) (\(commands[$0.pid] ?? "?"), \($0.path))" }
        throw APIError(
          "Processes from \(session.id) or in \(session.cwd) still run: \(named.joined(separator: ", ")). Stop them, then run `\(command)` again."
        )
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
  }
}
