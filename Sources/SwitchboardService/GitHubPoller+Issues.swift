import Foundation
import SwitchboardCore

/// Polls the issue sources into the service's issue cache.
extension GitHubPoller {
  /// A full read of each source's open issues happens once an hour. An org source's incremental search misses an
  /// issue that stopped matching its filter, such as one whose label was removed, and the full read drops it.
  static let issuesFullReadMs: Int64 = 3_600_000
  /// The most pages that one poll reads of a source. GitHub's search returns at most 1,000 results.
  static let issuePageLimit = 10
  /// Each incremental read asks for updates since a minute before the last poll started, so an update that GitHub
  /// stored during that poll isn't missed.
  static let issuesSinceSlackMs: Int64 = 60_000

  /// Polls the sources when the last poll is at least `age` old. It waits for a poll that is running.
  func refreshIssues(olderThan age: Int64) {
    queue.sync {
      var stats = Stats()
      let now = nowMs()
      guard GitHub.elapsed(since: issuesReadAt, age, now: now) else { return }
      _ = readIssues(now: now, stats: &stats)
    }
  }

  /// Polls the sources every `idlePollSeconds`, or at once with `all`. It returns the poll's error.
  func refreshIssues(all: Bool, now: Int64, stats: inout Stats) -> String? {
    guard all || GitHub.elapsed(since: issuesReadAt, settings.idleMs, now: now) else { return nil }
    return readIssues(now: now, stats: &stats)
  }

  private func readIssues(now: Int64, stats: inout Stats) -> String? {
    let (settings, polls) = service.queue.sync { (service.issueSettings, service.issueCache.polls) }
    guard !settings.sources.isEmpty else { return nil }
    issuesReadAt = now
    let (sources, invalid) = settings.checkedSources
    var poll = IssuePoll(started: now, ended: now, since: Self.isoTime(now - Self.issuesSinceSlackMs))
    poll.sourceErrors = invalid
    poll.full = Set(
      sources.filter { polls[$0.key].map { now - $0.fullAt >= Self.issuesFullReadMs } ?? true }.map(\.key))
    var requests = sources.map {
      IssuePageRequest(source: $0, since: poll.full.contains($0.key) ? nil : polls[$0.key]?.since)
    }
    for _ in 0..<Self.issuePageLimit where !requests.isEmpty {
      let (query, variables) = GitHub.issuesQuery(requests)
      let data: JSON
      do {
        data = try request(query, variables, stats: &stats)["data"] ?? .null
      } catch {
        poll.error = "\(error)"
        break
      }
      stats.issueReads += 1
      let parsed = GitHub.parseIssues(data, requests)
      poll.viewer = parsed.viewer ?? poll.viewer
      var next: [IssuePageRequest] = []
      for (request, page) in zip(requests, parsed.pages) {
        if let problem = page.error {
          poll.sourceErrors[request.source.key] = problem
          continue
        }
        poll.read[request.source.key, default: []] += page.issues
        if let after = page.next {
          next.append(IssuePageRequest(source: request.source, since: request.since, after: after))
        }
      }
      requests = next
    }
    poll.unfinished = Set(requests.map(\.source.key))
    poll.ended = nowMs()
    poll.pausedUntil = graphQLPausedUntil > poll.ended ? graphQLPausedUntil : nil
    service.queue.sync { service.applyIssuePoll(poll) }
    let problems = poll.sourceErrors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    return ([poll.error].compactMap { $0 } + problems).nonEmptyJoined
  }

  private static let isoFormatter = ISO8601DateFormatter()

  static func isoTime(_ ms: Int64) -> String {
    isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
  }
}

extension Array where Element == String {
  fileprivate var nonEmptyJoined: String? { isEmpty ? nil : joined(separator: " ") }
}
