import Foundation
import SwitchboardCore

/// Each session's site, and the reads and writes of a site's snapshot. They run on the state queue.
extension Service {
  /// The site that the session runs at: this Mac, or its host's site. A session whose host has no link in
  /// config.json gets a site that answers nothing, never this Mac.
  func site(for session: Session) -> any SessionSite {
    guard let host = session.host else { return mac }
    return remoteSites[host]
      ?? UnlistedSite(hostName: host, why: "\(home.config) lists no host of that name that sbd can connect to")
  }

  /// The site of the session with the id. It throws when sbd has no such session.
  func site(of id: String) throws -> any SessionSite {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    return site(for: session)
  }

  /// Writes the session's `claude.sh` in its launcher folder at the site. For a site that names a host, the
  /// write runs on the host, and nothing is written on this Mac.
  func writeLauncher(_ script: String, for id: String, at site: any SessionSite) throws {
    let dir = try site.sessionFolder(id)
    guard site.hostName != nil else {
      try site.machine.createFolder(dir)
      try script.write(toFile: "\(dir)/claude.sh", atomically: true, encoding: .utf8)
      return
    }
    try site.confirmed("the write of claude.sh") { machine in
      let write = #"umask 077; mkdir -p "$1" && cat >"$1/claude.sh.new" && mv "$1/claude.sh.new" "$1/claude.sh""#
      let r = try machine.run("/bin/sh", ["-c", write, "sb", dir], env: nil, input: Data(script.utf8), timeout: nil)
      guard r.status == 0 else {
        throw APIError("can't write \(dir)/claude.sh: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
    }
  }

  /// The last word of the claude command, which names claude's process on this Mac.
  var claudeProgram: String { (config.claude as NSString).lastPathComponent }

  /// The claude command at the session's site: the host's `claude` key, or `claude`, for a session on a host.
  func claudeCommand(for session: Session) -> String {
    guard let host = session.host else { return config.claude }
    return config.hosts[host]?.claude ?? "claude"
  }

  /// The last word of the claude command at the session's site.
  func claudeProgram(for session: Session) -> String {
    (claudeCommand(for: session) as NSString).lastPathComponent
  }

  /// The last word of the host's claude command.
  private func claudeProgram(onHost host: String) -> String {
    ((config.hosts[host]?.claude ?? "claude") as NSString).lastPathComponent
  }

  /// The folder that holds the session's transcripts: its Claude account's folder on this Mac, or `~/.claude`
  /// on its host, which stays unexpanded while the host's site is not ready.
  func transcriptAccount(_ session: Session) -> String {
    guard session.host != nil else {
      return (paneEnv(session.id)["CLAUDE_CONFIG_DIR"] ?? "~/.claude").expandingTilde
    }
    return (try? boxHome(session)).map { "\($0)/.claude" } ?? "~/.claude"
  }

  /// The snapshot of the session's site. It is nil for a session on a host unless the host answered a read on
  /// the link's current connection.
  private func snapshot(of id: String) -> Snapshot? {
    guard let host = entries[id]?.session.host else { return mac.snapshot }
    guard let read = remoteSnapshots[host], let connection = read.connection,
      remoteSites[host]?.facts?.epoch == connection
    else { return nil }
    return read
  }

  /// Whether the session runs on a host that has no answered snapshot on the link's current connection.
  func isUnread(_ id: String) -> Bool { snapshot(of: id) == nil }

  /// Throws why sbd can't read the session's host when the session's claude state is unknown.
  func requireRead(_ id: String) throws {
    guard isUnread(id), let host = entries[id]?.session.host else { return }
    try site(of: id).confirmed("the panes of \(id)") { _ in }
    throw HostUnread(hostName: host, why: "it has not answered a read of its panes yet")
  }

  /// The session's pane, from the snapshot of the session's site.
  func paneRow(_ id: String, _ pane: Pane) -> PaneRow? { snapshot(of: id)?.panes[paneName(id, pane)] }

  /// The claude process in the session's Claude pane.
  func claudePid(_ id: String) -> Int? { snapshot(of: id)?.claudePids[id] }

  /// The processes at the session's site, by parent pid.
  func processChildren(of id: String) -> [Int: [ProcessRow]] { snapshot(of: id)?.children ?? [:] }

  /// Sends SIGTERM to the session's claude through the session's site.
  func stopClaude(_ id: String, _ pid: Int) throws {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    try site(for: session).stopClaude(
      pid, below: paneRow(id, .claude)?.pid ?? 0, program: claudeProgram(for: session))
  }

  /// The host of the session that owns the pane, or nil for a pane on this Mac.
  private func host(ofPane name: String) -> String? {
    guard let dash = name.lastIndex(of: "-") else { return nil }
    return entries[String(name[..<dash])]?.session.host
  }

  /// Marks a pane that sbd just started as alive until the next snapshot, so
  /// a second request can't start it again. A snapshot that began before
  /// this can no longer replace it.
  func markStarting(_ name: String) {
    if let host = host(ofPane: name) {
      let clients = remoteSnapshots[host]?.panes[name]?.clients ?? 0
      remoteSnapshots[host]?.panes[name] = PaneRow(pid: 0, dead: false, clients: clients)
      remotePaneChanges[host] = nowMs()
      return
    }
    mac.snapshot.panes[name] = PaneRow(pid: 0, dead: false, clients: mac.snapshot.panes[name]?.clients ?? 0)
    mac.snapshot.taken = nowMs()
  }

  /// Drops a pane that sbd just killed. A snapshot that began before this can no longer show the pane again.
  func markKilled(_ name: String) {
    if let host = host(ofPane: name) {
      remoteSnapshots[host]?.panes[name] = nil
      remotePaneChanges[host] = nowMs()
      return
    }
    mac.snapshot.panes[name] = nil
    mac.snapshot.taken = nowMs()
  }

  /// Forgets the session's claude process until the next snapshot finds the one that a launch starts.
  func forgetClaudePid(_ id: String) {
    if let host = entries[id]?.session.host {
      remoteSnapshots[host]?.claudePids[id] = nil
    } else {
      mac.snapshot.claudePids[id] = nil
    }
  }

  /// Takes a newer snapshot, keeping what `markStarting` set since it was read.
  func install(_ s: Snapshot?) {
    if let s, s.taken >= mac.snapshot.taken { mac.snapshot = s }
  }

  /// Takes the host's answered snapshot unless sbd started or killed a pane there after the read began, or
  /// holds a snapshot that it read later. A nil snapshot means that a read got no answer: the host's sessions
  /// then read `.unknown`.
  func install(_ s: Snapshot?, onHost host: String) {
    guard let s else {
      remoteSnapshots[host] = nil
      return
    }
    guard s.taken >= remotePaneChanges[host] ?? 0, s.taken >= remoteSnapshots[host]?.taken ?? 0 else { return }
    remoteSnapshots[host] = s
  }

  // MARK: Hosts

  /// Connects the session's host and waits up to `seconds` for its site to be ready. It throws the reason when
  /// the host is still not ready, and does nothing for a session on this Mac. It runs off the state queue.
  func awaitSite(_ site: any SessionSite, seconds: Double = 15) throws {
    if let remote = site as? RemoteSite {
      try remote.awaitReady(seconds: seconds)
    } else if site.hostName != nil {
      _ = try site.terminals()
    }
  }

  /// A fresh snapshot of the host, read off the state queue.
  func readSnapshot(onHost host: String) throws -> Snapshot {
    guard let site = remoteSites[host] else { throw APIError("no host named \(host) in \(home.config)") }
    return try site.readSnapshot(claudeProgram: claudeProgram(onHost: host))
  }

  /// Whether the session may have a running claude on record, or has a queued message.
  private func wantsItsHost(_ e: Entry) -> Bool {
    let launched = e.facts.lastLaunch.map { $0 > (e.facts.lastStart ?? 0) && $0 > (e.facts.lastExit ?? 0) } ?? false
    return e.facts.live || launched || !e.pending.isEmpty
  }

  /// Connects each host that a session needs and whose link is disconnected. For each connected host, it runs
  /// setup when the connection has none, and reads the panes and processes when the host has a started session.
  /// Both run off the state queue, one at a time per host. `tick` and `load` call it.
  func superviseSites(now: Int64) {
    for (host, site) in remoteSites {
      let sessions = entries.values.filter { $0.session.host == host }
      let state = site.link.status.state
      if state == .disconnected, sessions.contains(where: wantsItsHost) { site.link.connect() }
      guard state == .connected, !siteReads.contains(host) else { continue }
      let reads = sessions.contains { $0.session.started }
      let setsUp = site.facts == nil && site.setupError == nil
      guard reads || setsUp else { continue }
      siteReads.insert(host)
      DispatchQueue.global().async { [self] in
        var read: Snapshot?
        do {
          if setsUp { try site.prepare() }
          if reads { read = try readSnapshot(onHost: host) }
        } catch {
          if setsUp || !(error is HostUnread) { logLine("host \(host): \(error)") }
        }
        queue.async { [self] in
          siteReads.remove(host)
          if reads { install(read, onHost: host) }
        }
      }
    }
  }
}
