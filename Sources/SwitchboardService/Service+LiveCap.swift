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
  /// start of its site, so the live plan's order decides which start takes the site's next free slot.
  func hasRoom(onHost host: String?) -> Bool {
    !entries.values.contains { $0.queuedSince != nil && $0.session.host == host }
      && liveCount(onHost: host) < liveCap(onHost: host)
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
  /// Otherwise the start queues, and its prompt becomes a queued message, so
  /// that a restart of sbd keeps it. A start that the user opened or that
  /// `livePriority` ranks runs the live plan at once, so it stops an idle
  /// session and starts now. Other starts wait for the tick to find a free slot.
  func launch(_ id: String, prompt: String?) throws {
    let host = entries[id]?.session.host
    if hasRoom(onHost: host) { return try startClaude(id, prompt: prompt) }
    _ = try requireStartable(id)
    if entries[id]?.queuedSince == nil {
      entries[id]?.queuedSince = nowMs()
      record(
        id, "start-queued",
        ["live": .number(Double(liveCount(onHost: host))), "cap": .number(Double(liveCap(onHost: host)))])
    }
    if let prompt, !prompt.isEmpty { try queueMessage(id, prompt, byUser: true) }
    if entries[id].flatMap(liveStart)?.urgent == true { runQueuedStarts(now: nowMs()) }
  }

  /// Runs each site's live plan: it starts the queued starts that have a slot
  /// and stops the idle sessions that make room for the rest. The tick calls
  /// it after it reads the processes.
  func runQueuedStarts(now: Int64) {
    let hosts = Set(entries.values.filter { $0.queuedSince != nil }.map(\.session.host))
    for host in hosts.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
      let plan = livePlan(onHost: host, now: now)
      let reason = "the live cap of \(liveCap(onHost: host))\(host.map { " on \($0)" } ?? "") needs the slot"
      for id in plan.stops { try? stop(id, reason: reason) }
      for id in plan.starts {
        let since = entries[id]?.queuedSince
        entries[id]?.queuedSince = nil
        do {
          try startClaude(id, prompt: nil)
        } catch let error as HostUnread {
          // The host may answer later, so the start keeps its place.
          entries[id]?.queuedSince = since
          logLine("can't start queued \(id) yet: \(error)")
        } catch {
          logLine("can't start queued \(id): \(error)")
        }
      }
    }
  }

  /// What the live cap of the site does with its queued starts now. A start on
  /// a host that sbd can't read would fail and lose its place, so the plan
  /// leaves it out until the reconcile.
  func livePlan(onHost host: String?, now: Int64) -> LivePlan {
    let queued = entries.values.filter {
      $0.session.host == host && claudeState($0.session.id) != .unknown && !removing.contains($0.session.id)
    }.compactMap(liveStart)
    return LivePlan.make(
      cap: liveCap(onHost: host),
      live: liveEntries(onHost: host).map { LivePlan.Process(session: $0.session.id, exiting: $0.facts.exiting) },
      queued: queued, candidates: stoppable(onHost: host, now: now), mcpStarting: mcpStarting(now: now),
      names: entries.mapValues(\.session.name))
  }

  /// The session's queued start, as the live plan sees it.
  func liveStart(_ e: Entry) -> LivePlan.Start? {
    e.queuedSince.map { LivePlan.Start(session: e.session.id, since: $0, rank: liveRank(e) ?? 0, jumped: e.jumpedAt) }
  }

  var livePriority: LivePriority { LivePriority(entries: config.livePriority) }

  /// The session's `livePriority` rank, or nil while sbd hasn't read its
  /// repository. A session that isn't work in a repository ranks 0.
  func liveRank(_ e: Entry) -> Int? {
    let priority = livePriority
    guard !priority.entries.isEmpty, e.session.kind == .work else { return 0 }
    let checkout = checkout(e.session)
    // `repository` starts the lookup that `repositoryRead` waits for, so it runs first.
    let name = checkout.flatMap { repository($0, of: e.session) }
    guard repositoryRead(e.session, checkout: checkout) else { return nil }
    return priority.rank(of: name)
  }

  /// The `livePriority` entry that ranks the session, or nil.
  func livePriorityEntry(_ e: Entry) -> String? {
    let priority = livePriority
    guard !priority.entries.isEmpty, e.session.kind == .work else { return nil }
    return priority.entry(of: checkout(e.session).flatMap { repository($0, of: e.session) })
  }

  /// The sessions of the site that sbd may stop to free a slot, in the order to stop them. A session whose
  /// host sbd can't read has no `.running` state, so it is never one of them.
  private func stoppable(onHost host: String?, now: Int64) -> [String] {
    let lastOpened = entries.values.filter { $0.lastOpened > 0 }
      .max { ($0.lastOpened, $0.session.id) < ($1.lastOpened, $1.session.id) }?.session.id
    let running = entries.values.compactMap { e -> StopPolicy.Claude? in
      guard e.session.host == host, case .running(let pid) = claudeState(e.session.id) else { return nil }
      var c = stopInput(e, jobs: backgroundJobs(pid, in: processChildren(of: e.session.id)), now: now)
      c.rank = liveRank(e)
      c.lastViewed = e.lastViewed
      c.openedLast = e.session.id == lastOpened
      return c
    }
    return stopPolicy.capOrder(running, now: now)
  }

  /// Records that the user opened the session now, and starts a stopped one
  /// ahead of every queued start. It moves `lastOpened` to this session before
  /// it launches, so the session opened before it loses its protection, and
  /// this launch may stop it to make room. It refuses a session that can't
  /// start before it records anything.
  func openSession(_ id: String) throws {
    let stopped = claudeState(id) == .stopped
    if stopped { _ = try requireStartable(id) }
    let now = nowMs()
    entries[id]?.lastViewed = now
    entries[id]?.lastOpened = now
    guard stopped else { return }
    entries[id]?.jumpedAt = now
    try launch(id, prompt: nil)
  }

  /// Sets the cap when the request names `cap`, and returns the status. A
  /// new cap is saved in config.json and holds at once.
  func liveRequest(_ args: JSON) throws -> JSON {
    if let value = args["cap"] {
      guard let cap = value.int, cap >= 1 else { throw APIError("the live cap is a whole number of at least 1") }
      try saveSetting("liveCap", .number(Double(cap)))
      liveCap = cap
      logLine("the live cap is \(cap)")
    }
    let now = nowMs()
    func live(_ host: String?) -> [LiveStatus.LiveSession] {
      liveEntries(onHost: host).map { e in
        var s = LiveStatus.LiveSession(
          session: e.session.id, name: e.session.name, pid: claudePid(e.session.id),
          state: Attention.evaluate(e.session, e.facts, now: now, stateOf: lastState).state)
        s.priority = livePriorityEntry(e)
        if e.facts.exiting { s.stopping = true }
        return s
      }.sorted { ($0.name, $0.session) < ($1.name, $1.session) }
    }
    func queued(_ host: String?) -> [LiveStatus.QueuedStart] {
      let plan = livePlan(onHost: host, now: now)
      // A start on a host that sbd can't read isn't in the plan. It waits after the others.
      let unread = entries.values.filter {
        $0.queuedSince != nil && $0.session.host == host && !plan.order.contains($0.session.id)
      }.sorted { ($0.queuedSince!, $0.session.id) < ($1.queuedSince!, $1.session.id) }.map(\.session.id)
      return (plan.order + unread).map { id in
        let e = entries[id]!
        var s = LiveStatus.QueuedStart(session: id, name: e.session.name, since: e.queuedSince!)
        s.priority = livePriorityEntry(e)
        s.reason = plan.waits[id] ?? "sbd can't read its host yet"
        return s
      }
    }
    var status = LiveStatus(cap: liveCap, live: live(nil), queued: queued(nil))
    status.priority = livePriority.entries
    let hosts = Set(entries.values.compactMap(\.session.host)).sorted()
    if !hosts.isEmpty {
      status.hosts = hosts.map {
        HostLive(host: $0, cap: liveCap(onHost: $0), live: live($0), queued: queued($0))
      }
    }
    return try JSON(encoding: status)
  }

}
