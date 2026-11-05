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
    if open {
      try openShell(id)
    } else {
      try closeShell(id)
    }
    return try JSON(encoding: summary(id))
  }

  /// Records the shell as closed and ends its tmux session, which also ends
  /// each terminal attached to it.
  func closeShell(_ id: String) throws {
    if entries[id]?.session.shellClosed != true { try update(id) { $0.shellClosed = true } }
    let name = paneName(id, .shell)
    host.kill(name)
    snapshot.panes[name] = nil
  }

  func openShell(_ id: String) throws {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    try requireFolder(session)
    if session.shellClosed == true { try update(id) { $0.shellClosed = nil } }
    try startShell(id)
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
