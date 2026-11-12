import Foundation

/// When sbd stops an idle claude, and the order in which the live cap stops
/// idle claudes to free a slot.
public struct StopPolicy: Sendable {
  /// A session whose claude runs, as the stop rules see it.
  public struct Claude {
    public var session: Session
    public var facts: SessionFacts
    /// When the tick last saw a background job under claude.
    public var lastJobSeen: Int64
    /// The background jobs under claude now.
    public var jobs: Int
    /// Whether a message is queued for the session or on its way.
    public var messageWaiting: Bool
    /// Whether a terminal shows the session's Claude pane.
    public var attached: Bool

    public init(
      session: Session, facts: SessionFacts, lastJobSeen: Int64 = 0, jobs: Int = 0, messageWaiting: Bool = false,
      attached: Bool = false
    ) {
      self.session = session
      self.facts = facts
      self.lastJobSeen = lastJobSeen
      self.jobs = jobs
      self.messageWaiting = messageWaiting
      self.attached = attached
    }

    var id: String { session.id }

    /// The time that the idle wait counts from. A background job sends no
    /// hooks while it runs, so the wait counts from the tick that last saw one.
    public var idleSince: Int64 { max(facts.lastActivity, lastJobSeen) }

    var hasWaits: Bool { !(session.waits ?? []).isEmpty }
  }

  /// How long after its launch a claude with no SessionStart can still be
  /// starting. sbd counts such a claude as live after 10 s, because its hook
  /// may have failed, but a slow start's prompt hasn't reached it yet.
  public static let startingMs: Int64 = 60_000
  /// A background job's process exits up to 1.3 s before claude starts the
  /// turn that reports it. A stop in that gap loses the report.
  public static let jobReportMs: Int64 = 5_000

  public var idleStopSeconds: Int

  public init(idleStopSeconds: Int) { self.idleStopSeconds = idleStopSeconds }

  /// How long a session sits idle before sbd stops it. A session with an open
  /// wait gets as long as any other, and the live cap stops it first.
  public var idleStopMs: Int64 { Int64(idleStopSeconds) * 1000 }

  /// Whether claude sits idle with nothing that a stop would lose: no turn,
  /// prompt, trust dialog, queued or in-flight message, background job, or
  /// start that may still be under way, and no terminal on screen. The idle
  /// stop and the live cap both need it.
  public func isQuiet(_ c: Claude, now: Int64) -> Bool {
    let f = c.facts
    return f.live && !f.turnRunning && f.openPermission == nil && f.openQuestion == nil && f.trustCard == nil
      && !c.messageWaiting && !c.attached && c.jobs == 0
      && (f.startedSinceLaunch || now - (f.lastLaunch ?? 0) >= StopPolicy.startingMs)
  }

  /// Whether the idle stop is due for a running claude.
  public func idleStopDue(_ c: Claude, now: Int64) -> Bool {
    guard isQuiet(c, now: now) else { return false }
    // A background job's process exits up to 1.3 s before claude starts the
    // turn that reports it, so the wait starts again when the job exits.
    let idle = now - c.idleSince
    guard idle >= idleStopMs else { return false }
    // A running subagent's tool calls fire hooks. A subagent with no event
    // for twice the idle time lost its SubagentStop, as when sbd was down.
    return c.facts.subagents.isEmpty || idle >= 2 * idleStopMs
  }

  /// The running claudes that sbd may stop to free a slot, in the order to
  /// stop them. Each one is quiet, with no card open except a deferred one,
  /// no subagent, and no background job seen in the last `jobReportMs`.
  /// Sessions in Done or with an open wait come first, then the rest, each
  /// longest idle first.
  public func capOrder(_ claudes: [Claude], now: Int64) -> [String] {
    let candidates = claudes.filter { c in
      now - c.lastJobSeen >= StopPolicy.jobReportMs && isQuiet(c, now: now) && c.facts.cards.allSatisfy(\.deferred)
        && c.facts.subagents.isEmpty
    }
    func tier(_ c: Claude) -> Int { c.session.done || c.facts.lastState == .done || c.hasWaits ? 0 : 1 }
    return candidates.sorted { (tier($0), $0.idleSince, $0.id) < (tier($1), $1.idleSince, $1.id) }.map(\.id)
  }
}
