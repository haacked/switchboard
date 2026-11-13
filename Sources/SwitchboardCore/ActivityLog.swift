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

/// A count of one name, such as a navigation's `via`.
public struct ActivityCount: Codable, Equatable, Sendable {
  public var name: String
  public var count: Int
}

/// How long one kind of wait took.
public struct ActivityTiming: Codable, Equatable, Sendable {
  public var name: String
  public var count: Int
  public var medianMs: Int64
  public var p90Ms: Int64
  public var maxMs: Int64
}

/// The time spent in one kind of place while the app was in front.
public struct PlaceTime: Codable, Equatable, Sendable {
  public var place: String
  public var visits: Int
  public var ms: Int64
}

/// How often one command ran, by the input that ran it.
public struct CommandUse: Codable, Equatable, Sendable {
  public var name: String
  public var count: Int
  public var vias: [String: Int]
}

/// One message text that the user sent more than once.
public struct RepeatedSend: Codable, Equatable, Sendable {
  public var count: Int
  public var sessions: Int
  public var minGapMs: Int64
}

/// What `sb activity report` prints.
public struct ActivityReport: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var since: Int64?
  public var events: Int
  public var resumes: [ResumeTiming]
  public var places: [PlaceTime] = []
  public var navigation: [ActivityCount] = []
  /// `terminal.ready` by whether claude was already live, and the waits the user left before claude was ready.
  public var terminalReady: [ActivityTiming] = []
  public var commands: [CommandUse] = []
  public var sends = 0
  public var repeatedSends: [RepeatedSend] = []
  public var errors: [ActivityCount] = []
  public var windowSizes: [ActivityCount] = []

  /// A visit counts for at most this long, so a window left open overnight doesn't fill the report.
  public static let visitCapMs: Int64 = 30 * 60 * 1000

  /// `resumes` counts the `resume.ready` events that have a string `trigger` and a numeric `ms`, one row per
  /// trigger, most frequent first.
  public static func build(_ events: [ActivityEvent], enabled: Bool, since: Int64?) -> ActivityReport {
    var report = ActivityReport(enabled: enabled, since: since, events: events.count, resumes: resumes(events))
    let ordered = events.sorted { ($0.t, $0.id ?? 0) < ($1.t, $1.id ?? 0) }
    report.places = places(ordered)
    report.navigation = counts(events.filter { $0.kind == "nav" }.compactMap { $0.data["via"]?.string })
    report.terminalReady = terminalReady(events)
    report.commands = commands(events)
    let sends = events.filter { $0.kind == "send" && $0.data["via"]?.string != "option" }
    report.sends = sends.count
    report.repeatedSends = repeatedSends(sends)
    report.errors = counts(
      events.filter { $0.kind == "error" }.compactMap { e in
        e.data["where"]?.string.map { "\($0) \(e.data["code"]?.string ?? "?")" }
      })
    report.windowSizes = counts(
      events.filter { $0.kind == "window" }.compactMap { e in
        guard let w = e.data["width"]?.int, let h = e.data["height"]?.int else { return nil }
        return "\(w)x\(h)"
      })
    return report
  }

  private static func resumes(_ events: [ActivityEvent]) -> [ResumeTiming] {
    var byTrigger: [String: [Int64]] = [:]
    for e in events where e.kind == "resume.ready" {
      guard let trigger = e.data["trigger"]?.string, case .number(let ms)? = e.data["ms"] else { continue }
      byTrigger[trigger, default: []].append(Int64(ms))
    }
    return byTrigger.map { trigger, values in
      let t = timing(trigger, values)
      return ResumeTiming(
        trigger: trigger, userCaused: LaunchTrigger(rawValue: trigger)?.userCaused ?? false, count: t.count,
        medianMs: t.medianMs, p90Ms: t.p90Ms, maxMs: t.maxMs)
    }
    .sorted { ($1.count, $0.trigger) < ($0.count, $1.trigger) }
  }

  /// Each `nav` starts a visit to its `to` place, and the next `nav` ends it. The clock stops while the app is
  /// in the background: a `deactivate` stops it, and an `activate` starts it again on the same visit. A `quit`
  /// stops it, and a `launch` ends the visit, because the app records its first place after a launch.
  private static func places(_ ordered: [ActivityEvent]) -> [PlaceTime] {
    var visits: [String: Int] = [:]
    var time: [String: Int64] = [:]
    var current: (place: String, since: Int64, spent: Int64)?
    var active = true
    func pause(at t: Int64) {
      guard let c = current, active else { return }
      current = (c.place, t, c.spent + max(0, t - c.since))
    }
    func endVisit() {
      guard let c = current else { return }
      time[c.place, default: 0] += min(c.spent, visitCapMs)
    }
    for e in ordered {
      switch (e.kind, e.data["event"]?.string) {
      case ("nav", _):
        guard let to = e.data["to"]?.string else { continue }
        pause(at: e.t)
        endVisit()
        current = (to, e.t, 0)
        visits[to, default: 0] += 1
        active = true
      case ("app", "deactivate"), ("app", "quit"):
        pause(at: e.t)
        active = false
      case ("app", "launch"):
        pause(at: e.t)
        endVisit()
        current = nil
        active = true
      case ("app", "activate"):
        if let c = current { current = (c.place, e.t, c.spent) }
        active = true
      default:
        continue
      }
    }
    endVisit()
    return visits.map { PlaceTime(place: $0.key, visits: $0.value, ms: time[$0.key] ?? 0) }
      .sorted { ($1.ms, $0.place) < ($0.ms, $1.place) }
  }

  private static func terminalReady(_ events: [ActivityEvent]) -> [ActivityTiming] {
    var groups: [String: [Int64]] = [:]
    for e in events where e.kind == "terminal.ready" {
      guard case .number(let ms)? = e.data["ms"] else { continue }
      let name =
        e.data["timedOut"]?.bool == true
        ? "not ready after 30 s"
        : e.data["left"]?.bool == true ? "left before ready" : e.data["wasLive"]?.bool == true ? "live" : "stopped"
      groups[name, default: []].append(Int64(ms))
    }
    return groups.map { timing($0.key, $0.value) }.sorted { ($1.count, $0.name) < ($0.count, $1.name) }
  }

  private static func commands(_ events: [ActivityEvent]) -> [CommandUse] {
    var uses: [String: [String: Int]] = [:]
    for e in events where e.kind == "command" {
      guard let name = e.data["name"]?.string else { continue }
      uses[name, default: [:]][e.data["via"]?.string ?? "other", default: 0] += 1
    }
    return uses.map { CommandUse(name: $0.key, count: $0.value.values.reduce(0, +), vias: $0.value) }
      .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
  }

  private static func repeatedSends(_ sends: [ActivityEvent]) -> [RepeatedSend] {
    var byHash: [String: [ActivityEvent]] = [:]
    for e in sends { if let hash = e.data["textHash"]?.string { byHash[hash, default: []].append(e) } }
    return byHash.values.filter { $0.count > 1 }.map { group in
      let times = group.map(\.t).sorted()
      let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
      return RepeatedSend(
        count: group.count, sessions: Set(group.compactMap(\.session)).count, minGapMs: gaps.min() ?? 0)
    }
    .sorted { ($1.count, $0.minGapMs) < ($0.count, $1.minGapMs) }
  }

  private static func counts(_ names: [String]) -> [ActivityCount] {
    Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).map { ActivityCount(name: $0.key, count: $0.value) }
      .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
  }

  private static func timing(_ name: String, _ values: [Int64]) -> ActivityTiming {
    let sorted = values.sorted()
    return ActivityTiming(
      name: name, count: sorted.count, medianMs: nearestRank(sorted, 0.5), p90Ms: nearestRank(sorted, 0.9),
      maxMs: sorted.last!)
  }

  private static func nearestRank(_ sorted: [Int64], _ p: Double) -> Int64 {
    sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
  }
}
