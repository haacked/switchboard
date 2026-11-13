import Foundation
import SwitchboardCore

extension Service {
  /// The cap of the site that `host` names: this Mac's cap for nil, and for a host its `liveCap` key, else
  /// config.json's `liveCap`. `sb live --set` changes only this Mac's.
  func liveCap(onHost host: String?) -> Int {
    guard let host else { return liveCap }
    return config.hosts[host]?.liveCap ?? config.liveCap
  }

  /// The sessions at the site that `host` names whose claude runs or is starting. A session whose host sbd
  /// can't read holds its slot while its claude may run there.
  func liveEntries(onHost host: String?) -> [Entry] {
    entries.values.filter { e in
      guard e.session.host == host else { return false }
      switch claudeState(e.session.id) {
      case .stopped: return false
      case .unknown: return e.facts.unread != nil || mayRunClaude(e)
      case .running, .starting: return true
      }
    }
  }

  func liveCount(onHost host: String?) -> Int { liveEntries(onHost: host).count }

  /// Whether a launch at the site would start claude now instead of queueing. A launch waits behind any queued
  /// start of its site, so the oldest start takes the site's next free slot.
  func hasRoom(onHost host: String?) -> Bool {
    !queuedStarts().contains { $0.session.host == host } && liveCount(onHost: host) < liveCap(onHost: host)
  }

  func queuedReason(onHost host: String?) -> String {
    "queued: \(liveCount(onHost: host)) of \(liveCap(onHost: host)) live\(host.map { " on \($0)" } ?? "")"
  }

  /// The session, when its folder exists, its claude is stopped, and no `rm` is removing it.
  func requireStartable(_ id: String) throws -> Session {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    guard !removing.contains(id) else { throw APIError("\(id) is being removed") }
    try requireRead(id)
    try requireFolder(session)
    guard claudeState(id) == .stopped else { throw APIError("\(id) is already running") }
    return session
  }

  /// Starts claude when the live cap of the session's site has room.
  /// Otherwise the start queues until the tick finds a free slot, and its
  /// prompt becomes a queued message, so that a restart of sbd keeps it.
  func launch(_ id: String, prompt: String?, trigger: LaunchTrigger) throws {
    let host = entries[id]?.session.host
    if hasRoom(onHost: host) { return try startClaude(id, prompt: prompt, trigger: trigger) }
    _ = try requireStartable(id)
    if entries[id]?.queued == nil {
      entries[id]?.queued = (nowMs(), trigger)
      record(
        id, "start-queued",
        ["live": .number(Double(liveCount(onHost: host))), "cap": .number(Double(liveCap(onHost: host)))])
    } else if trigger.userCaused, entries[id]?.queued?.trigger.userCaused == false {
      // The user now waits on the queued start, so the activity log records the user's trigger.
      entries[id]?.queued?.trigger = trigger
    }
    if let prompt, !prompt.isEmpty { try queueMessage(id, prompt, byUser: true) }
  }

  /// Starts the oldest queued starts of each site while its slots are free.
  /// When starts still wait, it stops enough idle sessions of the same site
  /// to make room for them. The tick calls it after it reads the processes.
  func runQueuedStarts(now: Int64) {
    let byHost = Dictionary(grouping: queuedStarts(), by: \.session.host)
    for host in byHost.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
      runQueuedStarts(byHost[host] ?? [], onHost: host, now: now)
    }
  }

  /// `starts` are the site's queued starts, oldest first.
  private func runQueuedStarts(_ starts: [Entry], onHost host: String?, now: Int64) {
    // A start on a host that sbd can't read would fail and lose its place, so it waits for the reconcile.
    var queued = starts.filter { claudeState($0.session.id) != .unknown && !removing.contains($0.session.id) }[...]
    guard !queued.isEmpty else { return }
    var live = liveEntries(onHost: host)
    let cap = liveCap(onHost: host)
    // A start needs the shared MCP servers, as the tick's other launches do.
    while !mcpStarting(now: now), live.count < cap, let next = queued.popFirst() {
      let id = next.session.id
      entries[id]?.queued = nil
      do {
        try startClaude(id, prompt: nil, trigger: next.queued!.trigger)
        live.append(entries[id]!)
      } catch let error as HostUnread {
        // The host may answer later, so the start keeps its place.
        entries[id]?.queued = next.queued
        logLine("can't start queued \(id) yet: \(error)")
      } catch {
        logLine("can't start queued \(id): \(error)")
      }
    }
    // A session that sbd stopped keeps its slot until its claude exits.
    let needed = queued.count - (cap - live.count) - live.filter(\.facts.exiting).count
    guard needed > 0 else { return }
    let reason = "the live cap of \(cap)\(host.map { " on \($0)" } ?? "") needs the slot"
    for id in stoppable(onHost: host, now: now).prefix(needed) { try? stop(id, reason: reason) }
  }

  /// The sessions whose start queued, oldest first.
  private func queuedStarts() -> [Entry] {
    entries.values.filter { $0.queued != nil }.sorted {
      ($0.queued!.since, $0.session.id) < ($1.queued!.since, $1.session.id)
    }
  }

  /// The sessions of the site that sbd may stop to free a slot, in the order to stop them. A session whose
  /// host sbd can't read has no `.running` state, so it is never one of them.
  private func stoppable(onHost host: String?, now: Int64) -> [String] {
    let running = entries.values.compactMap { e -> StopPolicy.Claude? in
      guard e.session.host == host, case .running(let pid) = claudeState(e.session.id) else { return nil }
      return stopInput(e, jobs: backgroundJobs(pid, in: processChildren(of: e.session.id)), now: now)
    }
    return stopPolicy.capOrder(running, now: now)
  }

  /// Sets the cap when the request names `cap`, and returns the status. A
  /// new cap is saved in config.json and holds at once.
  func liveRequest(_ args: JSON) throws -> JSON {
    if let value = args["cap"] {
      guard let cap = value.int, cap >= 1 else { throw APIError("the live cap is a whole number of at least 1") }
      try saveLiveCap(cap)
      liveCap = cap
      logLine("the live cap is \(cap)")
    }
    let now = nowMs()
    let live = { (host: String?) in
      self.liveEntries(onHost: host).map { e in
        LiveStatus.LiveSession(
          session: e.session.id, name: e.session.name, pid: self.claudePid(e.session.id),
          state: Attention.evaluate(e.session, e.facts, now: now, stateOf: self.lastState).state)
      }.sorted { ($0.name, $0.session) < ($1.name, $1.session) }
    }
    let queued = { (host: String?) in
      self.queuedStarts().filter { $0.session.host == host }.map {
        LiveStatus.QueuedStart(session: $0.session.id, name: $0.session.name, since: $0.queued!.since)
      }
    }
    var status = LiveStatus(cap: liveCap, live: live(nil), queued: queued(nil))
    let hosts = Set(entries.values.compactMap(\.session.host)).sorted()
    if !hosts.isEmpty {
      status.hosts = hosts.map {
        HostLive(host: $0, cap: liveCap(onHost: $0), live: live($0), queued: queued($0))
      }
    }
    return try JSON(encoding: status)
  }

  /// Writes the cap into config.json and keeps every other setting there.
  /// It refuses to rewrite a file that it can't read as a JSON object.
  private func saveLiveCap(_ cap: Int) throws {
    var settings: [String: JSON] = [:]
    if FileManager.default.fileExists(atPath: home.config) {
      let text = try String(contentsOfFile: home.config, encoding: .utf8)
      guard let object = JSON.parse(text)?.object else {
        throw APIError("\(home.config) isn't a JSON object, so the cap can't be saved there")
      }
      settings = object
    }
    settings["liveCap"] = .number(Double(cap))
    try (JSON.object(settings).prettyText + "\n").write(toFile: home.config, atomically: true, encoding: .utf8)
  }
}
