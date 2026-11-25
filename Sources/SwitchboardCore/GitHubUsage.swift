import Foundation

/// Why the poller read a PR.
public enum ReadTrigger: String, CaseIterable, Sendable {
  /// `sb poll --all` read every PR.
  case poll
  /// A wait, a dependency edge, or a finished turn is newer than the PR's last read.
  case wait
  /// The poller had not read the PR yet.
  case first
  /// The pending interval passed: the PR's checks or review are pending, an open wait needs the PR read at the
  /// pending rate, or Trunk queued it.
  case pending
  /// The idle interval passed.
  case idle
  /// The PR isn't due, and the poller reads a comment body of it that an earlier poll failed to read.
  case retry
  /// A source of PR changes reported that the PR changed.
  case event
  /// A source of PR changes started reporting the PR's changes, and changes from before that may be lost.
  case catchup
  /// One read showed a `ci` wait's outcome, and a second read confirms it.
  case confirm
}

/// The GitHub requests and GraphQL points that sbd spent since it started. The totals count every request. The
/// PR reads split the poll's status, merged-base, and comment-body requests by why the poller read each PR and by
/// the owner of its repo. A request that reads several PRs counts an equal share for each of them. Other requests,
/// such as lookups, code owners, merge details, and Actions runs, count only in the totals.
public struct GitHubUsage: Equatable, Sendable {
  public struct Share: Equatable, Sendable {
    public var reads = 0
    public var requests = 0.0
    public var points = 0.0
  }

  /// One PR that a request read, with why the poller read it and its repo's owner.
  public struct Read: Equatable, Sendable {
    public var trigger: ReadTrigger
    public var owner: String

    public init(trigger: ReadTrigger, owner: String) {
      self.trigger = trigger
      self.owner = owner
    }
  }

  public var since: Int64
  public var requests = 0
  public var points = 0
  /// The PR reads by trigger, then by owner.
  public var reads: [ReadTrigger: [String: Share]] = [:]

  public init(since: Int64) { self.since = since }

  /// Shares a request's cost equally among the PRs it served. `countsReads` is false for a follow-up request,
  /// such as the comment bodies of PRs that a status request already read.
  public mutating func share(requests: Int, points: Int, among served: [Read], countsReads: Bool) {
    guard !served.isEmpty else { return }
    let n = Double(served.count)
    for read in served {
      reads[read.trigger, default: [:]][read.owner, default: Share()].reads += countsReads ? 1 : 0
      reads[read.trigger]?[read.owner]?.requests += Double(requests) / n
      reads[read.trigger]?[read.owner]?.points += Double(points) / n
    }
  }

  /// The counts with their rates an hour since `since`.
  public func report(now: Int64) -> Report {
    let hours = Double(max(now - since, 0)) / 3_600_000
    func rate(_ count: Double) -> Double { hours > 0 ? count / hours : 0 }
    var byTrigger: [String: [String: Report.Rates]] = [:]
    for (trigger, owners) in reads {
      byTrigger[trigger.rawValue] = owners.mapValues {
        Report.Rates(
          reads: $0.reads, requests: $0.requests, points: $0.points, requestsPerHour: rate($0.requests),
          pointsPerHour: rate($0.points))
      }
    }
    return Report(
      since: since, hours: hours, requests: requests, points: points,
      requestsPerHour: rate(Double(requests)), pointsPerHour: rate(Double(points)), reads: byTrigger)
  }

  public struct Report: Codable, Equatable, Sendable {
    public struct Rates: Codable, Equatable, Sendable {
      public var reads: Int
      public var requests: Double
      public var points: Double
      public var requestsPerHour: Double
      public var pointsPerHour: Double
    }

    public var since: Int64
    public var hours: Double
    public var requests: Int
    public var points: Int
    public var requestsPerHour: Double
    public var pointsPerHour: Double
    /// The PR reads by trigger, then by owner.
    public var reads: [String: [String: Rates]]
  }
}
