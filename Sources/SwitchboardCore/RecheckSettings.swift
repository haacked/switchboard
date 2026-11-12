import Foundation

/// The `recheckSeconds` object of config.json. It sets how long each kind of
/// wait, and an acknowledgment, holds a session out of the Inbox before sbd
/// moves the session to Needs you. The keys are wait kinds plus
/// `acknowledged`, and the values are whole seconds.
public struct RecheckSettings: Codable, Equatable, Sendable {
  public static let acknowledged = "acknowledged"

  public static let defaults: [String: Int] = [
    Wait.Kind.ci.rawValue: 7200,
    Wait.Kind.botReview.rawValue: 3600,
    Wait.Kind.review.rawValue: 86400,
    Wait.Kind.approval.rawValue: 86400,
    Wait.Kind.queue.rawValue: 14400,
    Wait.Kind.merge.rawValue: 86400,
    Wait.Kind.deploy.rawValue: 14400,
    Wait.Kind.session.rawValue: 86400,
    Wait.Kind.manual.rawValue: 86400,
    acknowledged: 3600,
  ]

  /// Seconds by key. Every key in `defaults` has a value.
  public private(set) var seconds = RecheckSettings.defaults

  public init() {}

  /// A bad entry is logged and keeps its default. Throwing would make sbd
  /// ignore all of config.json.
  public init(from decoder: Decoder) throws {
    let value = try? decoder.singleValueContainer().decode(JSON.self)
    guard case .object(let entries)? = value else {
      if value != .null { logLine("skipping recheckSeconds: its value must be an object") }
      return
    }
    for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
      guard seconds[key] != nil else {
        logLine("skipping recheckSeconds.\(key): it is not a wait kind with a recheck time or \(Self.acknowledged)")
        continue
      }
      guard let n = value.int, n > 0 else {
        logLine("skipping recheckSeconds.\(key): its value must be a positive whole number of seconds")
        continue
      }
      seconds[key] = n
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(seconds)
  }

  /// The wait with its recheck time, counted from `start`, which defaults to
  /// when the wait was set. A manual wait without `until` gets it as its
  /// `until`, and every other kind but `date` gets it as its `recheck`. A wait
  /// that already has its time keeps it.
  public func stamped(_ wait: Wait, from start: Int64? = nil) -> Wait {
    var out = wait
    let time = (start ?? wait.created) + Int64(seconds[wait.kind.rawValue] ?? 0) * 1000
    switch wait.kind {
    case .date: break
    case .manual: out.until = out.until ?? time
    default: out.recheck = out.recheck ?? time
    }
    return out
  }

  /// How long an acknowledgment holds a session in Waiting.
  public var acknowledgedMs: Int64 { Int64(seconds[Self.acknowledged] ?? 0) * 1000 }
}
