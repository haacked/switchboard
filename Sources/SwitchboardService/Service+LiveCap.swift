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

  /// Starts the oldest queued starts while slots are free. When starts still
  /// wait, it stops enough idle sessions to make room for them. The tick
  /// calls it after it reads the processes.
  func runQueuedStarts(now: Int64) {
    var queued = queuedStarts()[...]
    guard !queued.isEmpty else { return }
    var live = liveEntries()
    // A start needs the shared MCP servers, as the tick's other launches do.
    while !mcpStarting(now: now), live.count < liveCap, let next = queued.popFirst() {
      let id = next.session.id
      entries[id]?.queuedSince = nil
      do {
        try startClaude(id, prompt: nil)
        live.append(entries[id]!)
      } catch {
        logLine("can't start queued \(id): \(error)")
      }
    }
    // A session that sbd stopped keeps its slot until its claude exits.
    let needed = queued.count - (liveCap - live.count) - live.filter(\.facts.exiting).count
    guard needed > 0 else { return }
    for id in stoppable(now: now).prefix(needed) {
      try? stop(id, reason: "the live cap of \(liveCap) needs the slot")
    }
  }

  /// The sessions whose start queued, oldest first.
  private func queuedStarts() -> [Entry] {
    entries.values.filter { $0.queuedSince != nil }.sorted {
      ($0.queuedSince!, $0.session.id) < ($1.queuedSince!, $1.session.id)
    }
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
    let queued = queuedStarts().map {
      LiveStatus.QueuedStart(session: $0.session.id, name: $0.session.name, since: $0.queuedSince!)
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
