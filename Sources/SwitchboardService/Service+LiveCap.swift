import Foundation
import SwitchboardCore

extension Service {
  /// The sessions whose claude runs or is starting.
  func liveEntries() -> [Entry] { entries.values.filter { claudeState($0.session.id) != .stopped } }

  func liveCount() -> Int { liveEntries().count }

  /// Whether a launch would start claude now instead of queueing. A launch
  /// waits behind any queued start, so the live plan's order decides which
  /// start takes the next free slot.
  func hasRoom() -> Bool { !entries.values.contains { $0.queuedSince != nil } && liveCount() < liveCap }

  var queuedReason: String { "queued: \(liveCount()) of \(liveCap) live" }

  /// The session, when its folder exists and its claude is stopped.
  func requireStartable(_ id: String) throws -> Session {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    try requireFolder(session)
    guard claudeState(id) == .stopped else { throw APIError("\(id) is already running") }
    return session
  }

  /// Starts claude when the live cap has room. Otherwise the start queues,
  /// and its prompt becomes a queued message, so that a restart of sbd keeps
  /// it. A start that the user opened or that `livePriority` ranks runs the
  /// live plan at once, so it stops an idle session and starts now. Other
  /// starts wait for the tick to find a free slot.
  func launch(_ id: String, prompt: String?) throws {
    if hasRoom() { return try startClaude(id, prompt: prompt) }
    _ = try requireStartable(id)
    if entries[id]?.queuedSince == nil {
      entries[id]?.queuedSince = nowMs()
      record(id, "start-queued", ["live": .number(Double(liveCount())), "cap": .number(Double(liveCap))])
    }
    if let prompt, !prompt.isEmpty { try queueMessage(id, prompt, byUser: true) }
    if entries[id].flatMap(liveStart)?.urgent == true { runQueuedStarts(now: nowMs()) }
  }

  /// Starts the queued starts that have a slot and stops the idle sessions
  /// that make room for the rest. The tick calls it after it reads the processes.
  func runQueuedStarts(now: Int64) {
    guard entries.values.contains(where: { $0.queuedSince != nil }) else { return }
    let plan = livePlan(now: now)
    for id in plan.stops {
      try? stop(id, reason: "the live cap of \(liveCap) needs the slot")
    }
    for id in plan.starts {
      entries[id]?.queuedSince = nil
      entries[id]?.jumpedAt = nil
      do {
        try startClaude(id, prompt: nil)
      } catch {
        logLine("can't start queued \(id): \(error)")
      }
    }
  }

  /// What the live cap does with the queued starts now.
  func livePlan(now: Int64) -> LivePlan {
    let queued = entries.values.compactMap(liveStart)
    return LivePlan.make(
      cap: liveCap,
      live: liveEntries().map { LivePlan.Process(session: $0.session.id, exiting: $0.facts.exiting) },
      queued: queued, candidates: stoppable(now: now), mcpStarting: mcpStarting(now: now),
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

  /// The sessions that sbd may stop to free a slot, in the order to stop them.
  private func stoppable(now: Int64) -> [String] {
    let lastOpened = entries.values.filter { $0.lastOpened > 0 }
      .max { ($0.lastOpened, $0.session.id) < ($1.lastOpened, $1.session.id) }?.session.id
    let running = entries.values.compactMap { e -> StopPolicy.Claude? in
      guard case .running(let pid) = claudeState(e.session.id) else { return nil }
      var c = stopInput(e, jobs: backgroundJobs(pid), now: now)
      c.rank = liveRank(e)
      c.lastViewed = e.lastViewed
      c.openedLast = e.session.id == lastOpened
      return c
    }
    return stopPolicy.capOrder(running, now: now)
  }

  /// Starts the session now, or moves its start to the front of the queue.
  /// When the cap is full, it stops the lowest-ranked idle session first.
  /// The request counts as an open, so the next start doesn't stop the session again.
  func startNow(_ id: String) throws {
    guard let e = entries[id] else { throw APIError("no session \(id)") }
    guard claudeState(id) == .stopped else { throw APIError("\(e.session.name) is already running") }
    try openSession(id)
  }

  /// Records that the user opened the session now, and starts a stopped one
  /// ahead of every queued start. The record comes before the start, so the
  /// cap may stop the session that the user left. It refuses a session that
  /// can't start before it records anything.
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
      try saveLiveCap(cap)
      liveCap = cap
      logLine("the live cap is \(cap)")
    }
    let now = nowMs()
    let live = liveEntries().map { e in
      var s = LiveStatus.LiveSession(
        session: e.session.id, name: e.session.name, pid: snapshot.claudePids[e.session.id],
        state: Attention.evaluate(e.session, e.facts, now: now, stateOf: lastState).state)
      s.priority = livePriorityEntry(e)
      if e.facts.exiting { s.stopping = true }
      return s
    }.sorted { ($0.name, $0.session) < ($1.name, $1.session) }
    let plan = livePlan(now: now)
    let queued = plan.order.map { id in
      let e = entries[id]!
      var s = LiveStatus.QueuedStart(session: id, name: e.session.name, since: e.queuedSince!)
      s.priority = livePriorityEntry(e)
      s.reason = plan.waits[id]
      return s
    }
    var status = LiveStatus(cap: liveCap, live: live, queued: queued)
    status.priority = livePriority.entries
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
