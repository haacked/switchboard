import Foundation

/// What made sbd start claude in a session. `resumed` and `started` events record it as `trigger`.
public enum LaunchTrigger: String, Codable, Sendable, CaseIterable {
  /// The app showed the session, `sb open` ran, or a terminals request found the Claude pane missing.
  case open
  case send
  /// Another session sent the message, as the Manager does.
  case session
  /// The Resume button or `sb resume`.
  case resume
  case create
  case followup
  /// A notice to a parent that sessions it started changed.
  case notice
  case wait
  case dependency
  case autoContinue = "auto-continue"
  case chat
  case merge
  /// The answer to a deferred card.
  case card
  /// The answers that the decision wizard submits.
  case decision
  case group
  /// A relaunch that picks up changed MCP servers.
  case mcp
  /// A relaunch that delivers messages queued while claude exited.
  case pending

  /// Whether the user's own action started claude. It differs from `byUser` on a `sent` event, which says who
  /// wrote the message: a card's answer and a group message are the user's, though sbd writes their text.
  public var userCaused: Bool {
    switch self {
    case .open, .send, .resume, .create, .followup, .card, .decision, .group, .merge: return true
    case .session, .notice, .wait, .dependency, .autoContinue, .chat, .mcp, .pending: return false
    }
  }
}

/// One row of the opt-in activity log. The log never holds message text,
/// transcript text, search queries, file paths, or error messages.
public struct ActivityEvent: Codable, Equatable, Sendable {
  public var id: Int64?
  public var t: Int64
  public var kind: String
  public var session: String?
  public var data: JSON

  public init(id: Int64? = nil, t: Int64, kind: String, session: String? = nil, data: JSON = [:]) {
    self.id = id
    self.t = t
    self.kind = kind
    self.session = session
    self.data = data
  }
}

public enum ActivityLog {
  /// sbd deletes activity rows older than this, once every `pruneEveryMs`.
  public static let retentionMs: Int64 = 30 * Attention.dayMs
  public static let pruneEveryMs = Attention.dayMs
}

/// The number of resumes for one trigger, and how long claude took from the launch to its SessionStart.
public struct ResumeTiming: Codable, Equatable, Sendable {
  public var trigger: String
  public var userCaused: Bool
  public var count: Int
  public var medianMs: Int64
  public var p90Ms: Int64
  public var maxMs: Int64
}

public struct ActivityStatus: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var events: Int
  public var oldest: Int64?

  public init(enabled: Bool, events: Int, oldest: Int64?) {
    self.enabled = enabled
    self.events = events
    self.oldest = oldest
  }
}

/// What `sb activity report` prints.
public struct ActivityReport: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var since: Int64?
  public var events: Int
  public var resumes: [ResumeTiming]

  /// `resumes` counts the `resume.ready` events that have a string `trigger` and a numeric `ms`, one row per
  /// trigger, most frequent first.
  public static func build(_ events: [ActivityEvent], enabled: Bool, since: Int64?) -> ActivityReport {
    var byTrigger: [String: [Int64]] = [:]
    for e in events where e.kind == "resume.ready" {
      guard let trigger = e.data["trigger"]?.string, case .number(let ms)? = e.data["ms"] else { continue }
      byTrigger[trigger, default: []].append(Int64(ms))
    }
    let resumes = byTrigger.map { trigger, values in
      let sorted = values.sorted()
      return ResumeTiming(
        trigger: trigger, userCaused: LaunchTrigger(rawValue: trigger)?.userCaused ?? false, count: sorted.count,
        medianMs: nearestRank(sorted, 0.5), p90Ms: nearestRank(sorted, 0.9), maxMs: sorted.last!)
    }
    .sorted { ($1.count, $0.trigger) < ($0.count, $1.trigger) }
    return ActivityReport(enabled: enabled, since: since, events: events.count, resumes: resumes)
  }

  private static func nearestRank(_ sorted: [Int64], _ p: Double) -> Int64 {
    sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
  }
}
