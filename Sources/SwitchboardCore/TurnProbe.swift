import Foundation

/// Decides when sbd asks `claude agents` whether a running turn has ended.
/// Claude Code sends no hook when Escape interrupts a turn.
public struct TurnProbe: Equatable, Sendable {
  /// How long a turn runs with no event before the first check.
  public static let quietMs: Int64 = 10_000
  /// The longest wait between two checks.
  public static let maxWaitMs: Int64 = 60_000

  private var activity: Int64 = 0
  private var checkedAt: Int64 = 0
  private var checks = 0

  public init() {}

  /// Whether to check now. A check that returns true counts as made. Each
  /// check without an event in between doubles the wait for the next one, up
  /// to `maxWaitMs`. An event starts the wait again.
  public mutating func check(activity: Int64, now: Int64) -> Bool {
    if activity != self.activity {
      self.activity = activity
      checkedAt = 0
      checks = 0
    }
    let wait = min(TurnProbe.quietMs << min(checks, 3), TurnProbe.maxWaitMs)
    guard now - max(activity, checkedAt) >= wait else { return false }
    checkedAt = now
    checks += 1
    return true
  }
}
