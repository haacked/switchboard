import CryptoKit
import Foundation
import SwitchboardCore

/// What sbd does when it can't read a host, and when it can again. While a host's link is down, each of its
/// sessions that may run a claude gets a `link_down`, which keeps the session's state. On each new connection
/// the reconcile reads what the session did meanwhile, in this order: the hook spool, `claude agents`, and
/// each transcript's tail. It then cuts the recorded lines from the spool, reads the panes, and records
/// `link_up`. Until it finishes on a connection, the host's sessions read `.unknown`.
extension Service {
  /// A spool above this size fails the reconcile.
  static let spoolLimitBytes = 64 * 1024 * 1024
  /// The timeout of the spool read and of the spool cut.
  static let spoolSeconds = 60.0
  /// How long the tick waits after a failed reconcile before it runs another on the same connection.
  static let reconcileRetryMs: Int64 = 30_000
  /// How often the tick cuts the recorded lines from the spool of a host that stays connected and reconciled.
  static let spoolCutIntervalMs: Int64 = 600_000

  // MARK: Link down

  /// Records `link_down` for each of the sessions that may have a running claude on record and whose facts
  /// hold none yet. So one drop gives one event, however long the link retries. It runs on the state queue.
  func recordLinkDown(_ sessions: [Entry], host: String, link: LinkState?, error: String?) {
    for e in sessions.sorted(by: { $0.session.id < $1.session.id }) where mayRunClaude(e) && e.facts.unread == nil {
      var data: [String: JSON] = ["host": .string(host)]
      if let link { data["link"] = .string(link.rawValue) }
      if let error { data["error"] = .string(error) }
      record(e.session.id, "link_down", .object(data))
    }
  }

  /// Whether a reconcile failed on the link's current connection less than `reconcileRetryMs` ago. It runs on
  /// the state queue.
  func reconcileFailedLately(_ host: String, now: Int64) -> Bool {
    guard let failed = reconcileFailures[host], failed.connection == remoteSites[host]?.link.status.connection
    else { return false }
    return (0..<Service.reconcileRetryMs).contains(now - failed.at)
  }

  // MARK: The reconcile

  /// Brings sbd up to date with the host on the link's current connection, unless a reconcile already finished
  /// on it. It runs setup first when the connection has none. It throws, and records no `link_up`, when a step
  /// got no answer from the host or failed. The next call starts again from the spool, and the recorded event
  /// ids stop sbd from recording an event twice. It runs on the host's queue, off the state queue.
  func reconcile(_ host: String) throws {
    let site = try remoteSite(host)
    var connection: Int?
    do {
      let facts = try site.prepare()
      connection = facts.epoch
      if queue.sync(execute: { isReconciled(host, on: facts.epoch) }) { return }
      try reconcileSpool(host, site, facts)
      try reconcileTurns(host, site, facts)
      try reconcileTranscripts(host, site)
      try finishReconcile(host, site, facts)
    } catch {
      logLine("host \(host): \(error)")
      if let connection {
        site.noteReconcile(failure: "\(error)", on: connection)
        queue.sync { reconcileFailures[host] = (connection, nowMs()) }
      }
      throw error
    }
  }

  private func unread(_ host: String, _ site: RemoteSite, during what: String) -> HostUnread {
    HostUnread(hostName: host, why: site.link.status.error ?? "the link dropped during \(what)")
  }

  // MARK: The spool

  /// Prints the first `$2` bytes of the file `$1` in base64. It exits 3 when the file is missing, 4 when it
  /// is not a regular file that the host can read or its size can't be read, and 5 when the file has `$2` bytes
  /// or more, before it prints.
  private static let spoolReadScript =
    #"[ -e "$1" ] || [ -L "$1" ] || exit 3; [ -f "$1" ] && [ -r "$1" ] || exit 4; "#
    + #"size=$(wc -c <"$1") || exit 4; [ "$size" -lt "$2" ]; case $? in 0) ;; 1) exit 5 ;; *) exit 4 ;; esac; exec <"$1"; head -c "$2" | base64"#

  /// The bytes of the host's spool, read in one command. A missing file is an empty spool. It throws for a
  /// spool above `spoolLimitBytes` and for a file that it can't read.
  static func readSpool(_ machine: any Machine, facts: BoxFacts, host: String) throws -> Data {
    let path = "\(facts.folder)/spool.jsonl"
    let r = try machine.run(
      "/bin/sh", ["-c", spoolReadScript, "sb", path, String(spoolLimitBytes + 1)], env: nil, input: nil,
      timeout: spoolSeconds)
    if r.status == 3 { return Data() }
    if r.status == 5 { throw oversizedSpool(path, host) }
    // `Data(base64Encoded:)` gives nil for text with no base64 digit, which is what an empty file prints.
    let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard r.status == 0, let data = text.isEmpty ? Data() : Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    else { throw APIError("can't read \(path) on \(host): \(r.problem)") }
    // The script refuses a larger file before it prints, but the file can grow between `wc` and `head`.
    guard data.count <= spoolLimitBytes else { throw oversizedSpool(path, host) }
    return data
  }

  private static func oversizedSpool(_ path: String, _ host: String) -> APIError {
    APIError(
      "\(path) on \(host) holds more than \(spoolLimitBytes / (1024 * 1024)) MB, so sbd did not load it. "
        + "Move the file away on \(host) to let its sessions reconnect")
  }

  /// Step 1: records the events of the spool's lines, then cuts the recorded lines from the spool. With
  /// `recording` false, it records nothing and cuts the lines that the store already holds. A spooled
  /// PermissionRequest that sbd recorded before its live hook arrived would make the live hook dedup to an
  /// empty answer, so only the reconcile records.
  func reconcileSpool(_ host: String, _ site: RemoteSite, _ facts: BoxFacts, recording: Bool = true) throws {
    queue.sync { spoolReadFloors[host] = .some(nil) }
    defer { queue.sync { spoolReadFloors[host] = nil } }
    let data = try site.confirmed("the read of the spool") { try Service.readSpool($0, facts: facts, host: host) }
    let parsed = Spool.parse(data)
    if !data.isEmpty { logLine("host \(host): read \(data.count) bytes of spool in \(parsed.lines.count) lines") }
    let cut = queue.sync { () -> Int in
      if recording { recordSpool(parsed.lines, from: host) }
      let cut = spoolCut(parsed.lines, from: host)
      setSpoolFloor(host, keeping: parsed.lines)
      return cut
    }
    if recording, cut < parsed.complete {
      let why = parsed.firstUnreadable == cut ? "is not a spool line" : "holds an event that sbd did not record"
      logLine("host \(host): the spool line at byte \(cut) \(why), so it and the lines behind it stay in the spool")
    }
    guard cut > 0 else { return }
    let digest = SHA256.hash(data: data.prefix(cut)).map { String(format: "%02x", $0) }.joined()
    // An unanswered cut throws here. The cut may then have run, which the next reconcile finds out.
    let r = try site.confirmed("the spool cut") { machine in
      try machine.run(
        facts.python, [BoxShim.shimPath(for: facts), "spool-drop", String(cut), digest],
        env: ["HOME": facts.home, "SB_HOME": facts.folder, "PATH": "/usr/bin:/bin"], input: nil,
        timeout: Service.spoolSeconds)
    }
    guard r.status == 0 else {
      logLine("host \(host): the shim refused to cut \(cut) bytes from the spool, so the spool is as it was")
      return
    }
    queue.sync { setSpoolFloor(host, keeping: parsed.lines.filter { $0.bytes.lowerBound >= cut }) }
  }

  /// Sets the host's spool floor after a read of its spool. `lines` are the read's lines that are still in the
  /// spool. The floor is at or below the id of each line whose id the store holds, or that the store can't
  /// answer for. The ids recorded since the read began count as well, because the read may not hold their
  /// lines. It runs on the state queue.
  func setSpoolFloor(_ host: String, keeping lines: [SpoolLine]) {
    // The cut counts a line that the store can't answer for as not recorded. The floor counts it as recorded,
    // because a floor above a recorded id lets the prune forget that id while its line is still in the spool.
    // The floor matches the id alone, as the dedup in `recordSpool` does.
    let kept = lines.filter { (try? store.hasHostEvent($0.id)) != false }
    let ids = kept.map(\.id) + [spoolReadFloors[host] ?? nil].compactMap { $0 }
    spoolFloors[host] = .some(ids.min())
  }

  /// Lowers the host's spool floors to an id that sbd just recorded. The shim appended the id's line to the
  /// spool before it sent the hook, and only a later read of the spool shows that the line is gone. It runs on
  /// the state queue.
  func lowerSpoolFloors(_ id: HostEventID, host: String) {
    if let floor = spoolFloors[host] { spoolFloors[host] = .some(min(floor ?? id, id)) }
    if let floor = spoolReadFloors[host] { spoolReadFloors[host] = .some(min(floor ?? id, id)) }
  }

  /// Records each line's event, lowest id first within a session, merged with the session's events that
  /// arrived on the socket and still wait for their turn. Each line passes the checks of a hook from the
  /// host's socket: `hostSession(_:on:)`, then `applyHostEvent`. A line that fails one is logged and not
  /// recorded. It runs on the state queue.
  private func recordSpool(_ lines: [SpoolLine], from host: String) {
    // A host can fill its spool with lines that sbd refuses, so the log gets their count and the first reason.
    var refused = 0
    var reason: Error?
    for (name, lines) in Dictionary(grouping: lines, by: \.session).sorted(by: { $0.key < $1.key }) {
      do {
        let session = try hostSession(["session": .string(name)], on: host)
        var buffer = hostEvents[session.id] ?? HostEventBuffer()
        for line in lines where try !store.hasHostEvent(line.id) { buffer.add(line.id, line.payload, at: 0) }
        let due = buffer.flush()
        hostEvents[session.id] = buffer
        for (id, payload) in due {
          do { _ = try applyHostEvent(session.id, id, payload) } catch {
            refused += 1
            reason = reason ?? error
          }
        }
      } catch {
        refused += lines.count
        reason = reason ?? error
      }
    }
    if let reason { logLine("host \(host): sbd did not record \(refused) spool lines. The first reason: \(reason)") }
  }

  /// The count of bytes at the start of the spool that sbd may remove. A line counts only when the store
  /// holds its id for this host and its session, or the store lists its session as one that sbd removed from
  /// this host and sbd holds no session of that id. A store that can't answer counts as no. It runs on the
  /// state queue.
  func spoolCut(_ data: Data, from host: String) -> Int { spoolCut(Spool.parse(data).lines, from: host) }

  /// `spoolCut` of the spool whose `Spool.parse` gave `lines`.
  func spoolCut(_ lines: [SpoolLine], from host: String) -> Int {
    let removed = (try? store.removedHostSessions(host: host)) ?? []
    return Spool.cutLength(
      lines, recorded: { (try? store.hasHostEvent($0.id, host: host, session: $0.session)) == true },
      removed: { removed.contains($0) && entries[$0] == nil })
  }

  // MARK: claude agents

  /// Step 2: asks `claude agents` on the host about the sessions whose facts show a running turn, and ends
  /// the turns that it reports idle, as `endIdleTurns` does. A run that failed on a link that is still up is
  /// logged and changes nothing.
  private func reconcileTurns(_ host: String, _ site: RemoteSite, _ facts: BoxFacts) throws {
    let checks = queue.sync {
      entries.values.filter { $0.session.host == host && $0.session.started && $0.facts.turnRunning }.map {
        TurnCheck(id: $0.session.id, claudeSessionId: $0.session.claudeSessionId, activity: $0.facts.lastActivity)
      }.sorted { $0.id < $1.id }
    }
    guard !checks.isEmpty else { return }
    let rows: [ClaudeSession]
    do {
      rows = try agentRows(at: site, seen: nowMs(), timeout: Service.turnCheckTimeout)
    } catch {
      let status = site.link.status
      guard status.state == .connected, status.connection == facts.epoch else { throw error }
      logLine("can't check the turns on \(host): \(error)")
      return
    }
    let idle = Service.idleTurns(rows)
    queue.sync {
      for check in checks where idle.contains(check.claudeSessionId) {
        endTurn(check, account: claudeAccount(of: check.id))
      }
    }
  }

  // MARK: Transcripts

  private struct TranscriptCheck {
    var session: Session
    var named: String?
    var pastes: [UncertainPaste]
  }

  /// Step 3: reads the tail of the transcript of each started session on the host, and settles the messages
  /// whose paste may have landed before sbd stopped.
  private func reconcileTranscripts(_ host: String, _ site: RemoteSite) throws {
    let checks = try queue.sync {
      try entries.values.filter { $0.session.host == host && $0.session.started }.sorted {
        $0.session.id < $1.session.id
      }.map { e in
        TranscriptCheck(
          session: e.session, named: e.facts.transcriptPath,
          pastes: try unsettled[e.session.id].map { try uncertainPastes(e.session.id, $0) } ?? [])
      }
    }
    for check in checks {
      let id = check.session.id
      let (tail, landed): (TranscriptTail?, [Bool]) = try site.confirmed("the transcript of \(id)") { machine in
        let path = try transcriptFile(check.session, named: check.named, on: machine)
        return (
          path.map { Transcript.tail($0, on: machine) },
          check.pastes.map { $0.landed(in: $0.transcript ?? path, on: machine) }
        )
      }
      queue.sync {
        guard entries[id] != nil else { return }
        for (paste, landed) in zip(check.pastes, landed) {
          record(id, landed ? "delivered" : "delivery_unknown", ["text": .string(paste.text)])
        }
        unsettled[id] = nil
        if let tail { applyTail(tail, to: id, offset: site.clockOffsetMs ?? 0) }
      }
    }
  }

  /// Records what the transcript's tail shows and the events did not. `reconciled` carries the tail's last
  /// reply and last activity when the tail's activity is after the session's, or when its reply differs and
  /// no turn runs. The tail ends no turn, because claude also writes text in the middle of a turn. Only
  /// `claude agents` ends a turn whose Stop never reached sbd. The tail's time is the host's clock, moved to
  /// this Mac's clock and held at now. It runs on the state queue.
  private func applyTail(_ tail: TranscriptTail, to id: String, offset: Int64) {
    guard let e = entries[id] else { return }
    let before = e.facts.lastActivity
    let activity = tail.lastActivity.map { min($0 &+ offset, nowMs()) } ?? 0
    let newer = activity > before
    let differs = tail.lastReply != nil && tail.lastReply != e.facts.lastReply
    guard newer || (differs && !e.facts.turnRunning) else { return }
    record(
      id, "reconciled",
      [
        "lastReply": (tail.lastReply ?? e.facts.lastReply).map(JSON.string) ?? .null,
        "lastActivity": .number(Double(max(before, activity))),
      ])
  }

  // MARK: link_up

  /// Step 4: reads the panes and processes, then records `link_up` for each session that a `link_down` froze,
  /// installs the read, and delivers the queued messages of each running claude. It throws, and changes
  /// nothing, unless the link is still on the connection that every step ran on.
  private func finishReconcile(_ host: String, _ site: RemoteSite, _ facts: BoxFacts) throws {
    let read = try readSnapshot(onHost: host)
    try queue.sync {
      let status = site.link.status
      guard status.state == .connected, status.connection == facts.epoch, read.connection == facts.epoch else {
        throw unread(host, site, during: "the reconcile")
      }
      reconciledOn[host] = facts.epoch
      spoolCutAt[host] = nowMs()
      reconcileFailures[host] = nil
      site.noteReconcile(failure: nil, on: facts.epoch)
      let ids = entries.values.filter { $0.session.host == host }.map(\.session.id).sorted()
      for id in ids where entries[id]?.facts.unread != nil { record(id, "link_up", ["host": .string(host)]) }
      install(read, onHost: host)
      for id in ids {
        if case .running = claudeState(id) { deliverPending(id, after: 0) }
      }
    }
  }
}
