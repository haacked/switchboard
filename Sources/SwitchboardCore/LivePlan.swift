import Foundation

/// What the live cap does now: which queued starts run, which idle sessions
/// stop to make room, and why each other start waits. The tick and `sb live`
/// both read it, so they can't disagree.
public struct LivePlan: Equatable, Sendable {
  /// A session whose claude runs or is starting.
  public struct Process: Equatable, Sendable {
    public var session: String
    /// sbd stopped it, and its claude hasn't exited yet. It keeps its slot until it exits.
    public var exiting: Bool

    public init(session: String, exiting: Bool = false) {
      self.session = session
      self.exiting = exiting
    }
  }

  /// A start that waits for a slot.
  public struct Start: Equatable, Sendable {
    public var session: String
    /// When the start queued, in ms since the epoch.
    public var since: Int64

    public init(session: String, since: Int64) {
      self.session = session
      self.since = since
    }
  }

  /// The sessions to start now, in order.
  public var starts: [String] = []
  /// The sessions to stop to make room, in order.
  public var stops: [String] = []
  /// Why each start that doesn't run now waits, by session.
  public var waits: [String: String] = [:]
  /// Every queued start in the order in which it gets a slot.
  public var order: [String] = []

  public init(starts: [String] = [], stops: [String] = [], waits: [String: String] = [:], order: [String] = []) {
    self.starts = starts
    self.stops = stops
    self.waits = waits
    self.order = order
  }

  /// `candidates` are the sessions that sbd may stop, in the order to stop
  /// them. `names` gives the reasons readable names and falls back to the id.
  public static func make(
    cap: Int, live: [Process], queued: [Start], candidates: [String], mcpStarting: Bool,
    names: [String: String] = [:]
  ) -> LivePlan {
    var plan = LivePlan()
    let ordered = queued.sorted { ($0.since, $0.session) < ($1.since, $1.session) }
    plan.order = ordered.map(\.session)
    // `occupied` counts every live claude. `held` leaves out the claudes that
    // are exiting and counts each slot that a waiting start already claimed.
    var occupied = live.count
    var held = live.filter { !$0.exiting }.count
    var candidates = candidates[...]
    for start in ordered {
      let id = start.session
      if !mcpStarting, occupied < cap, held < cap {
        plan.starts.append(id)
        occupied += 1
        held += 1
        continue
      }
      var stopped: String?
      while held >= cap, let next = candidates.popFirst() {
        plan.stops.append(next)
        held -= 1
        stopped = next
      }
      guard held < cap else {
        plan.waits[id] = "the cap of \(cap) is full and no idle session can stop"
        continue
      }
      held += 1
      if mcpStarting {
        plan.waits[id] = "the shared MCP servers are starting"
      } else if let stopped {
        plan.waits[id] = "waits for \(names[stopped] ?? stopped) to stop"
      } else {
        plan.waits[id] = "waits for a stopped session to exit"
      }
    }
    return plan
  }
}
