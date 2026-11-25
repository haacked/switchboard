import Foundation

/// The PRs that the GitHub poller reads whether or not they are due. A PR is read either at the next poll, whenever
/// that runs, or from a set time, for which the poller schedules a wake that runs a poll.
///
/// The poller schedules one wake at a time. A timed request for a PR that is already requested keeps the earlier
/// time, and a request at or after the scheduled wake needs no wake of its own. A burst of requests therefore
/// shares one wake and one poll, and a stream of requests can't put a PR's read off.
///
/// Each request keeps the reason for its read, which `sb poll --stats` reports. A PR that is requested twice keeps
/// the reason of the request that comes due first. On a tie the earlier request's reason stays. A PR with a next-poll
/// request and a later timed request reads twice: at the next poll for the next-poll reason, and at the timed
/// request's time for its own reason.
public struct ReadRequests: Equatable, Sendable {
  /// The PRs that the next poll reads, each with why it is read.
  public private(set) var nextPoll: [String: ReadTrigger] = [:]
  /// A read requested from a set time.
  public struct TimedRead: Equatable, Sendable {
    /// The time from which the read is due, in ms.
    public var at: Int64
    public var trigger: ReadTrigger
  }
  /// The PRs requested from a set time, by id.
  public private(set) var timedReads: [String: TimedRead] = [:]
  /// The time from which each timed request is due, in ms, by id.
  public var timed: [String: Int64] { timedReads.mapValues(\.at) }
  /// The time of the wake that the poller scheduled, in ms, or nil when none is scheduled.
  public private(set) var wake: Int64?

  public init() {}

  /// Requests a read of each PR at the next poll. It schedules no wake.
  public mutating func readAtNextPoll(_ ids: some Sequence<String>, trigger: ReadTrigger) {
    for id in ids where nextPoll[id] == nil { nextPoll[id] = trigger }
  }

  /// Requests a read of each PR at `at` or later. Returns `at` when the poller must schedule a wake for it, which is
  /// when no scheduled wake comes at or before `at`. The new wake replaces the scheduled one.
  public mutating func request(_ ids: some Sequence<String>, at: Int64, trigger: ReadTrigger) -> Int64? {
    for id in ids {
      guard timedReads[id].map({ at < $0.at }) ?? true else { continue }
      timedReads[id] = TimedRead(at: at, trigger: trigger)
    }
    guard at < (wake ?? .max) else { return nil }
    wake = at
    return at
  }

  /// Withdraws the PR's timed read when it was requested with `trigger`. The scheduled wake stays, and it runs no poll
  /// when nothing else is due.
  public mutating func cancel(_ id: String, trigger: ReadTrigger) {
    if timedReads[id]?.trigger == trigger { timedReads[id] = nil }
  }

  /// Removes and returns the PRs that a poll at `now` reads, each with why it is read. A poll calls it once as it
  /// starts.
  public mutating func take(now: Int64) -> [String: ReadTrigger] {
    let taken = timedReads.filter { $0.value.at <= now }.mapValues(\.trigger).merging(nextPoll) { $1 }
    nextPoll = [:]
    timedReads = timedReads.filter { $0.value.at > now }
    return taken
  }

  /// Records that the scheduled wake fired at `now`, and returns whether a timed request is due. A poll that ran
  /// before the wake can have taken them all, and then the wake runs no poll.
  public mutating func fire(now: Int64) -> Bool {
    wake = nil
    return timedReads.values.contains { $0.at <= now }
  }

  /// The time of a wake for the timed requests that remain, or nil when the scheduled wake comes no later than the
  /// first of them.
  public mutating func rearm() -> Int64? {
    guard let next = timedReads.values.map(\.at).min(), next < (wake ?? .max) else { return nil }
    wake = next
    return next
  }
}
