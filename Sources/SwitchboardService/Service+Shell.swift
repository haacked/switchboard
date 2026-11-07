import Foundation
import SwitchboardCore

/// A session's shell pane. A shell that exits, as after `exit` or Ctrl-D,
/// closes the pane. sbd then starts no shell for the session until the user
/// opens one. The Claude pane never changes here.
extension Service {
  /// The `shell` request: `open` true starts the shell pane, and false ends it.
  func shellRequest(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    guard let open = args["open"]?.bool else { throw APIError("shell needs open true or false") }
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    // A closed flag saved on an unstarted follow-up would keep its shell closed after `followup start`.
    try requireFolder(session)
    if open {
      try openShell(id)
    } else {
      try closeShell(id)
    }
    return try JSON(encoding: summary(id))
  }

  /// Records the shell as closed and ends its tmux session, which also ends
  /// each terminal attached to it. A snapshot that began before the kill can
  /// no longer replace the pane list, so it can't show the pane again.
  func closeShell(_ id: String) throws {
    if entries[id]?.session.shellClosed != true { try update(id) { $0.shellClosed = true } }
    let name = paneName(id, .shell)
    host.kill(name)
    snapshot.panes[name] = nil
    snapshot.taken = nowMs()
  }

  /// Starts the shell, then records it as open. A shell that fails to start stays closed.
  func openShell(_ id: String) throws {
    try startShell(id)
    if entries[id]?.session.shellClosed == true { try update(id) { $0.shellClosed = nil } }
  }

  /// Starts a missing shell pane, and starts a dead one again.
  func startShell(_ id: String) throws {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    let name = paneName(id, .shell)
    switch snapshot.panes[name] {
    case nil:
      try host.create(name, cwd: session.cwd, env: paneEnv(id))
    case let row? where row.dead:
      try host.respawn(name, cwd: session.cwd, env: paneEnv(id), command: nil)
    default:
      return
    }
    markStarting(name)
  }

  /// Closes each shell pane whose shell exited.
  func closeExitedShells() {
    for id in entries.keys where snapshot.panes[paneName(id, .shell)]?.dead == true {
      try? closeShell(id)
    }
  }
}
