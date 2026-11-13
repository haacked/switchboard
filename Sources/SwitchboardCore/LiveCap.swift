import Foundation

/// The answer to `sb live`: the cap on claude processes, the sessions whose
/// claude runs or is starting, and the starts that wait for a free slot.
public struct LiveStatus: Codable, Equatable, Sendable {
  public struct LiveSession: Codable, Equatable, Sendable {
    public var session: String
    public var name: String
    /// Nil while claude is starting.
    public var pid: Int?
    public var state: AttentionState
    /// The `livePriority` entry that ranks the session, or nil.
    public var priority: String?
    /// True while the claude that sbd stopped still exits.
    public var stopping: Bool?

    public init(session: String, name: String, pid: Int?, state: AttentionState) {
      self.session = session
      self.name = name
      self.pid = pid
      self.state = state
    }
  }

  public struct QueuedStart: Codable, Equatable, Sendable {
    public var session: String
    public var name: String
    /// When the start queued, in ms since the epoch.
    public var since: Int64
    /// The `livePriority` entry that ranks the session, or nil.
    public var priority: String?
    /// Why the start waits.
    public var reason: String?

    public init(session: String, name: String, since: Int64) {
      self.session = session
      self.name = name
      self.since = since
    }
  }

  public var cap: Int
  /// The `livePriority` setting, highest first. An sbd that predates it sends nil.
  public var priority: [String]?
  public var live: [LiveSession]
  /// In the order in which they start.
  public var queued: [QueuedStart]

  public init(cap: Int, live: [LiveSession], queued: [QueuedStart]) {
    self.cap = cap
    self.live = live
    self.queued = queued
  }
}
