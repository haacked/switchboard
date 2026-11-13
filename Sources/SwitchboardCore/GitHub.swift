import Foundation

/// The `github` object in config.json.
public struct GitHubSettings: Codable, Equatable, Sendable {
  /// The gh that `gh auth token` runs from. A name without a slash is looked
  /// up on PATH, then in Homebrew's and the system's bin folders.
  public var gh: String = "gh"
  /// The API base. The GraphQL endpoint is <url>/graphql.
  public var url: String = "https://api.github.com"
  /// How often a pending PR or a PR that awaits a review polls, and how
  /// often sbd polls. 0 turns off the timer. Each `sb poll` then reads every
  /// such PR.
  public var pollSeconds: Double = 30
  /// How often any other PR polls, and how often sbd looks up a branch that
  /// had no PR.
  public var idlePollSeconds: Double = 300
  /// How often a named service's deploy state is read while a deploy wait
  /// names the service.
  public var deployPollSeconds: Double = 120

  /// A timer cycle can start a few ms less than one period after the last
  /// one. Each interval therefore ends half a timer period early, so a PR
  /// that is due at a tick polls at that tick and not at the next one.
  var slackMs: Int64 { Int64(pollSeconds * 500) }
  public var pendingMs: Int64 { Int64(pollSeconds * 1000) - slackMs }
  public var idleMs: Int64 { Int64(idlePollSeconds * 1000) - slackMs }
  public var deployMs: Int64 { Int64(deployPollSeconds * 1000) - slackMs }

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = GitHubSettings()
    gh = try c.decodeIfPresent(String.self, forKey: .gh) ?? d.gh
    url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
    pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? d.pollSeconds
    idlePollSeconds = try c.decodeIfPresent(Double.self, forKey: .idlePollSeconds) ?? d.idlePollSeconds
    deployPollSeconds = try c.decodeIfPresent(Double.self, forKey: .deployPollSeconds) ?? d.deployPollSeconds
  }
}

/// What the poller looks a session's PR up by.
public enum PRKey: Hashable, Sendable {
  /// The PR from `branch` in `repo` (owner/name) whose head repository
  /// belongs to `owner`, the owner of the branch's push remote.
  case branch(repo: String, branch: String, owner: String)
  case number(repo: String, number: Int)
}

/// The GraphQL queries and the pure parts of the GitHub poller. Phase 0 test
/// 6 measured the query: a chunk of 20 PRs costs 1 point and answers in
/// about 3 s, and 100 PRs in one request pass GitHub's 10 s limit.
public enum GitHub {
  public static let chunkSize = 20
  /// The chunk size of the lookup and body queries, which ask for little per
  /// item. Phase 0 test 6 looked up 100 branches for 1 point in under 2 s.
  /// `nodes(ids:)` takes at most 100 ids.
  public static let lightChunkSize = 100

  /// The authors whose comment bodies the poller reads: Trunk's queue status
  /// and PostHog's deploy table. Only a GitHub App's login ends in [bot], so
  /// no user can pass for either.
  public static let bodyAuthors: Set<String> = [TrunkComments.author, DeployComment.author]

  /// How a response limits the next request. `limited` means that GitHub
  /// refused the request for a rate limit: a 403 or 429 with `retry-after` or
  /// a rate limit message, or a 200 with a RATE_LIMITED error. `pause` is the
  /// number of seconds before the next request may go out: `retry-after`, the
  /// time until `x-ratelimit-reset` once no points are left, or 60 without
  /// either. A request that spent the last point succeeds, and only the next
  /// one waits. `headers` has lowercase names.
  public static func rateLimit(status: Int, headers: [String: String], response: JSON?, now: Double) -> (
    limited: Bool, pause: Double?
  ) {
    let message = (response?["message"]?.string ?? "").lowercased()
    let spent = headers["x-ratelimit-remaining"] == "0"
    let reset = spent ? headers["x-ratelimit-reset"].flatMap(Double.init).map { max(0, $0 - now) } : nil
    let retry = [headers["retry-after"].flatMap(Double.init), reset].compactMap { $0 }.max()
    let refused = status == 403 || status == 429
    let limited =
      response?["errors"]?.array?.contains { $0["type"]?.string == "RATE_LIMITED" } == true
      || (refused && (retry != nil || message.contains("rate limit")))
    return (limited, (limited || spent) ? (retry ?? 60) : nil)
  }

  /// The error message of a response, on one line.
  public static func message(_ response: JSON?) -> String {
    oneLine(response?["message"]?.string ?? response?["errors"]?.array?.first?["message"]?.string ?? "", max: 120)
  }

  public static func chunks<T>(_ items: [T], size: Int = chunkSize) -> [[T]] {
    stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
  }

  /// The PR as its session shows it, with the queue state that its comments
  /// give. GitHub answers UNKNOWN while it computes mergeability again, as
  /// after the base branch moved. The PR then keeps the mergeability that
  /// `last` showed for the same head commit, so a conflict doesn't leave
  /// Needs you and come back.
  ///
  /// `trunk` is what `trunk merge status` printed about the PR. A timeline
  /// gives an open PR's queue state in place of the comments while the
  /// comments show that Trunk holds the PR, show a state that didn't load, or
  /// show the state that the timeline ends in. trunk reads the queue itself.
  /// The comments lag it. Comments that show another final state, or none,
  /// changed after trunk printed the timeline.
  public static func shown(
    _ pr: PullRequest, _ comments: [PRComment], trunk: TrunkTimeline.Result? = nil, last: PullRequest?
  ) -> PullRequest {
    var shown = pr
    let change = TrunkComments.change(of: pr, comments)
    shown.queue = change?.state
    shown.queueAt = change?.at.flatMap(Transcript.milliseconds)
    if pr.state == .open {
      switch trunk {
      case .found(let timeline)?:
        if let entry = timeline.entries.last,
          let comments = change?.state, comments.isHeld || comments == .unknown || comments == entry.state
        {
          shown.queue = entry.state
          shown.queueAt = entry.time
          shown.queueLabel = entry.label
          shown.queueText = entry.text
        }
      case .notLoggedIn?:
        shown.trunkLoginNeeded = true
      default:
        break
      }
    }
    if pr.mergeable == .unknown, let last, last.id == pr.id, last.headSha == pr.headSha, let kept = last.mergeable {
      shown.mergeable = kept
    }
    return shown
  }

  /// Whether a PR is due to poll at `now`. A PR that was never read is due.
  /// A pending PR, or one that awaits a review, is due after `pendingMs`, so
  /// an approval shows within one poll. Any other PR is due after `idleMs`.
  public static func isDue(_ pr: PullRequest?, lastPolled: Int64?, now: Int64, pendingMs: Int64, idleMs: Int64)
    -> Bool
  {
    guard let pr else { return true }
    return elapsed(since: lastPolled, pr.isPending || pr.awaitsReview ? pendingMs : idleMs, now: now)
  }

  static let prLinkMarker = Data(#""pr-link""#.utf8)

  /// The PR of the last `pr-link` line among the complete lines of `data`,
  /// and the number of bytes up to the end of the last complete line. A
  /// reader that keeps an offset reads the rest again once the line ends.
  public static func lastPRLink(in data: Data) -> (key: PRKey?, consumed: Int) {
    guard let end = data.lastIndex(of: 0x0A) else { return (nil, 0) }
    let complete = data[data.startIndex...end]
    // A transcript reaches 24 MB, so the search runs backwards from its end
    // and parses only the lines that hold the marker.
    var searchEnd = complete.endIndex
    while let marker = complete.range(of: prLinkMarker, options: .backwards, in: complete.startIndex..<searchEnd) {
      let start = complete[..<marker.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? complete.startIndex
      let stop = complete[marker.upperBound...].firstIndex(of: 0x0A) ?? complete.endIndex
      if let json = try? JSONCoding.decoder.decode(JSON.self, from: Data(complete[start..<stop])),
        json["type"]?.string == "pr-link", let repo = json["prRepository"]?.string, let number = json["prNumber"]?.int
      {
        return (.number(repo: repo, number: number), complete.count)
      }
      searchEnd = start
    }
    return (nil, complete.count)
  }
}
