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
    /// The session's `LivePriority` rank, or nil while sbd hasn't read the
    /// repository that would rank it. The live cap doesn't stop a session
    /// whose rank is unknown.
    public var rank: Int? = 0
    /// When a terminal last showed the session or the user last opened it, or 0.
    public var lastViewed: Int64 = 0
    /// Whether the user opened this session after every other one.
    public var openedLast = false

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
    /// hooks while it runs. Its process exits up to 1.3 s before claude starts
    /// the turn that reports it, so the wait counts from the tick that last
    /// saw a job.
    var idleSince: Int64 { max(facts.lastActivity, lastJobSeen) }
  }

  /// How long after the tick last saw a background job the live cap leaves
  /// the session running. A stop before claude reports the job loses the report.
  public static let capJobGraceMs: Int64 = 5_000

  public var idleStopSeconds: Int

  public init(idleStopSeconds: Int) { self.idleStopSeconds = idleStopSeconds }

  var idleStopMs: Int64 { Int64(idleStopSeconds) * 1000 }

  /// Whether claude sits idle with nothing that a stop would lose: no turn,
  /// prompt, trust dialog, queued or in-flight message, or background job,
  /// and no terminal on screen. The idle stop and the live cap both need it.
  func isQuiet(_ c: Claude) -> Bool {
    let f = c.facts
    return f.live && !f.turnRunning && f.openPermission == nil && f.openQuestion == nil && f.trustCard == nil
      && !c.messageWaiting && !c.attached && c.jobs == 0
  }

  /// Whether the idle stop is due for a running claude. A session with an
  /// open wait idles as long as any other before it stops.
  public func idleStopDue(_ c: Claude, now: Int64) -> Bool {
    guard isQuiet(c) else { return false }
    let idle = now - c.idleSince
    guard idle >= idleStopMs else { return false }
    // A running subagent's tool calls fire hooks. A subagent with no event
    // for twice the idle time lost its SubagentStop, as when sbd was down.
    return c.facts.subagents.isEmpty || idle >= 2 * idleStopMs
  }

  /// The running claudes that sbd may stop to free a slot, in the order to
  /// stop them. Each one is quiet, with no card open except a deferred one,
  /// no subagent, and no background job seen in the last `capJobGraceMs`.
  /// Its rank is known, and the user didn't open it last. The lowest rank
  /// goes first, then the one the user touched or viewed longest ago, then
  /// the one idle longest.
  public func capOrder(_ claudes: [Claude], now: Int64) -> [String] {
    let candidates = claudes.filter { c in
      now - c.lastJobSeen >= StopPolicy.capJobGraceMs && isQuiet(c) && c.facts.cards.allSatisfy(\.deferred)
        && c.facts.subagents.isEmpty && !c.openedLast && c.rank != nil
    }
    func key(_ c: Claude) -> (Int, Int64, Int64, String) {
      (c.rank ?? 0, c.facts.lastSeen(viewed: c.lastViewed), c.idleSince, c.id)
    }
    return candidates.sorted { key($0) < key($1) }.map(\.id)
  }
}
