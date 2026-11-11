import Foundation
import SwitchboardCore

/// Each session's site, and the reads and writes of a site's snapshot. They run on the state queue.
extension Service {
  /// The site that the session runs at. Every session runs on this Mac.
  func site(for session: Session) -> any SessionSite { mac }

  /// The site of the session with the id. It throws when sbd has no such session.
  func site(of id: String) throws -> any SessionSite {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    return site(for: session)
  }

  /// Writes the session's `claude.sh` in its launcher folder at the site.
  /// It throws for a site that names a host and creates nothing there, because the write runs on this Mac.
  func writeLauncher(_ script: String, for id: String, at site: any SessionSite) throws {
    if let host = site.hostName {
      throw APIError("can't start claude on \(host): sbd writes claude.sh on this Mac only")
    }
    let dir = try site.sessionFolder(id)
    try site.machine.createFolder(dir)
    try script.write(toFile: "\(dir)/claude.sh", atomically: true, encoding: .utf8)
  }

  /// The last word of the claude command, which names claude's process.
  var claudeProgram: String { (config.claude as NSString).lastPathComponent }

  /// The session's pane, from the snapshot of the session's site.
  func paneRow(_ id: String, _ pane: Pane) -> PaneRow? { mac.snapshot.panes[paneName(id, pane)] }

  /// The claude process in the session's Claude pane.
  func claudePid(_ id: String) -> Int? { mac.snapshot.claudePids[id] }

  /// The processes at the session's site, by parent pid.
  func processChildren(of id: String) -> [Int: [ProcessRow]] { mac.snapshot.children }

  /// Sends SIGTERM to the session's claude through the session's site.
  func stopClaude(_ id: String, _ pid: Int) throws {
    try site(of: id).stopClaude(pid, below: paneRow(id, .claude)?.pid ?? 0, program: claudeProgram)
  }

  /// Marks a pane that sbd just started as alive until the next snapshot, so
  /// a second request can't start it again. A snapshot that began before
  /// this can no longer replace it.
  func markStarting(_ name: String) {
    mac.snapshot.panes[name] = PaneRow(pid: 0, dead: false, clients: mac.snapshot.panes[name]?.clients ?? 0)
    mac.snapshot.taken = nowMs()
  }

  /// Drops a pane that sbd just killed. A snapshot that began before this can no longer show the pane again.
  func markKilled(_ name: String) {
    mac.snapshot.panes[name] = nil
    mac.snapshot.taken = nowMs()
  }

  /// Forgets the session's claude process until the next snapshot finds the one that a launch starts.
  func forgetClaudePid(_ id: String) { mac.snapshot.claudePids[id] = nil }

  /// Takes a newer snapshot, keeping what `markStarting` set since it was read.
  func install(_ s: Snapshot?) {
    if let s, s.taken >= mac.snapshot.taken { mac.snapshot = s }
  }
}
