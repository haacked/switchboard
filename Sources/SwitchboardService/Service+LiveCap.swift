import Foundation
import SwitchboardCore

extension Service {
  /// The sessions whose claude runs or is starting.
  func liveEntries() -> [Entry] { entries.values.filter { claudeState($0.session.id) != .stopped } }

  func liveCount() -> Int { liveEntries().count }

  /// Whether a launch would start claude now instead of queueing. A launch
  /// waits behind any queued start, so the oldest start takes the next free slot.
  func hasRoom() -> Bool { !entries.values.contains { $0.queuedSince != nil } && liveCount() < liveCap }

  var queuedReason: String { "queued: \(liveCount()) of \(liveCap) live" }

  /// The session, when its folder exists and its claude is stopped.
  func requireStartable(_ id: String) throws -> Session {
    guard let session = entries[id]?.session else { throw APIError("no session \(id)") }
    try requireFolder(session)
    guard claudeState(id) == .stopped else { throw APIError("\(id) is already running") }
    return session
  }

  /// Starts claude when the live cap has room. Otherwise the start queues
  /// until the tick finds a free slot, and its prompt becomes a queued
  /// message, so that a restart of sbd keeps it.
  func launch(_ id: String, prompt: String?) throws {
    if hasRoom() { return try startClaude(id, prompt: prompt) }
    _ = try requireStartable(id)
    if entries[id]?.queuedSince == nil {
      entries[id]?.queuedSince = nowMs()
      record(id, "start-queued", ["live": .number(Double(liveCount())), "cap": .number(Double(liveCap))])
    }
    if let prompt, !prompt.isEmpty { try queueMessage(id, prompt, byUser: true) }
  }

  /// Starts the queued starts that have a slot and stops the idle sessions
  /// that make room for the rest. The tick calls it after it reads the processes.
  func runQueuedStarts(now: Int64) {
    guard entries.values.contains(where: { $0.queuedSince != nil }) else { return }
    let plan = livePlan(now: now)
    for id in plan.starts {
      entries[id]?.queuedSince = nil
      do {
        try startClaude(id, prompt: nil)
      } catch {
        logLine("can't start queued \(id): \(error)")
      }
    }
    for id in plan.stops {
      try? stop(id, reason: "the live cap of \(liveCap) needs the slot")
    }
  }

  /// What the live cap does with the queued starts now.
  func livePlan(now: Int64) -> LivePlan {
    let queued = entries.values.compactMap { e in
      e.queuedSince.map { LivePlan.Start(session: e.session.id, since: $0) }
    }
    return LivePlan.make(
      cap: liveCap,
      live: liveEntries().map { LivePlan.Process(session: $0.session.id, exiting: $0.facts.exiting) },
      queued: queued, candidates: stoppable(now: now), mcpStarting: mcpStarting(now: now),
      names: entries.mapValues(\.session.name))
  }

  /// The sessions that sbd may stop to free a slot, in the order to stop them.
  private func stoppable(now: Int64) -> [String] {
    let running = entries.values.compactMap { e -> StopPolicy.Claude? in
      guard case .running(let pid) = claudeState(e.session.id) else { return nil }
      return stopInput(e, jobs: backgroundJobs(pid), now: now)
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
    let live = liveEntries().map { e in
      LiveStatus.LiveSession(
        session: e.session.id, name: e.session.name, pid: snapshot.claudePids[e.session.id],
        state: Attention.evaluate(e.session, e.facts, now: now, stateOf: lastState).state)
    }.sorted { ($0.name, $0.session) < ($1.name, $1.session) }
    let queued = livePlan(now: now).order.map { id in
      LiveStatus.QueuedStart(session: id, name: entries[id]!.session.name, since: entries[id]!.queuedSince!)
    }
    return try JSON(encoding: LiveStatus(cap: liveCap, live: live, queued: queued))
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
