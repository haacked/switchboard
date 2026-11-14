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
    /// The session's `LivePriority` rank. Higher is first.
    public var rank: Int
    /// When the user asked to start it now, by opening it or with
    /// `sb live --next`, or nil.
    public var jumped: Int64?

    public init(session: String, since: Int64, rank: Int = 0, jumped: Int64? = nil) {
      self.session = session
      self.since = since
      self.rank = rank
      self.jumped = jumped
    }

    /// A start that the user asked for, or a ranked one, doesn't wait for a
    /// stopped claude to exit.
    public var urgent: Bool { jumped != nil || rank > 0 }
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
  ///
  /// The newest jump goes first, then the highest rank, then the oldest
  /// start. An urgent start stops what it must and runs now. It may run while
  /// a stopped claude still exits, so the processes can exceed the cap by the
  /// claudes that are exiting. Any other start waits for a free slot.
  public static func make(
    cap: Int, live: [Process], queued: [Start], candidates: [String], mcpStarting: Bool,
    names: [String: String] = [:]
  ) -> LivePlan {
    var plan = LivePlan()
    let ordered = queued.sorted {
      (-($0.jumped ?? 0), -$0.rank, $0.since, $0.session) < (-($1.jumped ?? 0), -$1.rank, $1.since, $1.session)
    }
    plan.order = ordered.map(\.session)
    // `occupied` counts every live claude. `held` leaves out the claudes that
    // are exiting and counts each slot that a waiting start already claimed.
    var occupied = live.count
    var held = live.filter { !$0.exiting }.count
    var candidates = candidates[...]
    for start in ordered {
      let id = start.session
      var stopped: String?
      while held >= cap, let next = candidates.popFirst() {
        plan.stops.append(next)
        held -= 1
        stopped = next
      }
      if !mcpStarting, held < cap, start.urgent || occupied < cap {
        plan.starts.append(id)
        occupied += 1
        held += 1
        continue
      }
      guard held < cap else {
        let ahead = ordered.prefix { $0.session != id }.filter {
          plan.waits[$0.session] != nil && ($0.jumped != nil || $0.rank > start.rank)
        }.count
        plan.waits[id] =
          ahead > 0
          ? "behind \(ahead) higher-priority start\(ahead == 1 ? "" : "s")"
          : "the cap of \(cap) is full and no idle session can stop"
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
