import Foundation

/// The `github` object in config.json.
public struct GitHubSettings: Codable, Equatable, Sendable {
  /// The gh that `gh auth token` runs from. A name without a slash is looked
  /// up on PATH, then in Homebrew's and the system's bin folders.
  public var gh: String = "gh"
  /// The API base. The GraphQL endpoint is <url>/graphql.
  public var url: String = "https://api.github.com"
  /// How often a pending PR polls, and how often sbd polls. 0 turns off the
  /// timer. Each `sb poll` then reads every pending PR.
  public var pollSeconds: Double = 30
  /// How often a settled PR polls, and how often sbd looks up a branch that
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

  static let notFound = "NOT_FOUND"

  public static let statusQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id number url title state isDraft mergedAt closedAt mergeCommit { oid }
          headRefName headRefOid baseRefName mergeable reviewDecision
          repository { nameWithOwner defaultBranchRef { name } }
          labels(first: 20) { nodes { name } }
          reviewRequests(first: 20) {
            nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Team { slug } } }
          }
          latestOpinionatedReviews(first: 20) { nodes { author { __typename login } state submittedAt commit { oid } } }
          reviews(last: 20) { nodes { author { __typename login } state submittedAt } }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          firstComments: comments(first: 5) { nodes { ...comment } }
          lastComments: comments(last: 20) { nodes { ...comment } }
        }
      }
    }
    fragment comment on IssueComment { id author { __typename login } createdAt lastEditedAt includesCreatedEdit }
    """

  public static let bodyQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on IssueComment { id author { __typename login } createdAt lastEditedAt includesCreatedEdit body }
      }
    }
    """

  /// The base branch's newest merged PR, for the PRs whose base isn't the
  /// default branch. Phase 0 test 6 measured `associatedPullRequests` at
  /// about 1 s per 50 PRs, so the status query leaves it out.
  public static let baseQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id baseRefName repository { defaultBranchRef { name } }
          baseRef {
            target { oid }
            associatedPullRequests(first: 1, states: MERGED, orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes { number headRefOid }
            }
          }
        }
      }
    }
    """

  /// One node of a status response: the PR, and its comments oldest first
  /// without duplicates. nil when the node isn't a PR, as for a deleted one.
  public static func parsePR(_ node: JSON) -> (pr: PullRequest, comments: [PRComment])? {
    guard let id = node["id"]?.string, let number = node["number"]?.int else { return nil }
    let review = { (n: JSON) in
      Review(
        author: login(n["author"]), state: n["state"]?.string ?? "", submittedAt: n["submittedAt"]?.string,
        commit: n["commit"]?["oid"]?.string, bot: n["author"]?["__typename"]?.string == "Bot" ? true : nil)
    }
    let reviewRequests = node["reviewRequests"].map {
      nodes($0).compactMap { $0["requestedReviewer"].flatMap { $0["login"]?.string ?? $0["slug"]?.string } }
    }
    let pr = PullRequest(
      id: id, number: number, url: node["url"]?.string ?? "", repo: node["repository"]?["nameWithOwner"]?.string ?? "",
      title: node["title"]?.string ?? "", state: PRState(rawValue: node["state"]?.string ?? "") ?? .open,
      draft: node["isDraft"]?.bool ?? false, head: node["headRefName"]?.string ?? "",
      headSha: node["headRefOid"]?.string ?? "", base: node["baseRefName"]?.string ?? "",
      defaultBranch: node["repository"]?["defaultBranchRef"]?["name"]?.string,
      mergeable: node["mergeable"]?.string.flatMap(Mergeable.init(rawValue:)),
      reviewDecision: node["reviewDecision"]?.string.flatMap(ReviewDecision.init(rawValue:)),
      verdicts: nodes(node["latestOpinionatedReviews"]).map(review), reviews: nodes(node["reviews"]).map(review),
      labels: nodes(node["labels"]).compactMap { $0["name"]?.string },
      checks: nodes(node["commits"]).first?["commit"]?["statusCheckRollup"]?["state"]?.string,
      mergedAt: node["mergedAt"]?.string, closedAt: node["closedAt"]?.string,
      reviewRequests: reviewRequests, mergeCommit: node["mergeCommit"]?["oid"]?.string)
    var seen: Set<String> = []
    let comments = (nodes(node["firstComments"]) + nodes(node["lastComments"])).compactMap(parseComment)
      .filter { seen.insert($0.id).inserted }.sorted { $0.createdAt < $1.createdAt }
    return (pr, comments)
  }

  /// The PRs of a status response, and the ids that GitHub reports
  /// NOT_FOUND, as for a deleted PR. A node that failed in another way is in
  /// neither.
  public static func parseStatus(_ response: JSON, _ ids: [String]) -> (
    prs: [(pr: PullRequest, comments: [PRComment])], gone: Set<String>
  ) {
    ((response["data"]?["nodes"]?.array ?? []).compactMap(parsePR), notFoundNodes(response, ids))
  }

  /// The comments of a body response, and the ids that GitHub reports
  /// NOT_FOUND, as for a deleted comment. A node that failed in another way
  /// is in neither.
  public static func parseBodies(_ response: JSON, _ ids: [String]) -> (comments: [PRComment], gone: Set<String>) {
    ((response["data"]?["nodes"]?.array ?? []).compactMap(parseComment), notFoundNodes(response, ids))
  }

  /// The ids whose node in a `nodes(ids:)` response failed with NOT_FOUND.
  static func notFoundNodes(_ response: JSON, _ ids: [String]) -> Set<String> {
    let errors = errorTypes(response)
    return Set(ids.indices.filter { errors["nodes.\($0)"] == notFound }.map { ids[$0] })
  }

  /// The number of the PR that merged from the base branch, when nothing
  /// landed on the base after that merge: the base branch's tip is the merged
  /// PR's head. A PR on the default branch, or on a long-lived base such as
  /// develop that moved on, has no merged base. nil when the node isn't a PR.
  public static func parseMergedBase(_ node: JSON) -> (id: String, mergedBase: Int?)? {
    guard let id = node["id"]?.string else { return nil }
    let merged = nodes(node["baseRef"]?["associatedPullRequests"]).first
    let tip = node["baseRef"]?["target"]?["oid"]?.string
    let onDefault = node["baseRefName"]?.string == node["repository"]?["defaultBranchRef"]?["name"]?.string
    return (id, !onDefault && tip != nil && merged?["headRefOid"]?.string == tip ? merged?["number"]?.int : nil)
  }

  /// One node of a body response, or of a status response's comments. A
  /// GitHub App's author gets the login that GitHub's REST API shows, with
  /// [bot] at the end. GraphQL gives the same login to the app and to a user.
  public static func parseComment(_ node: JSON) -> PRComment? {
    guard let id = node["id"]?.string else { return nil }
    let bot = node["author"]?["__typename"]?.string == "Bot"
    return PRComment(
      id: id, author: login(node["author"]) + (bot ? "[bot]" : ""), createdAt: node["createdAt"]?.string ?? "",
      editedAt: node["lastEditedAt"]?.string, edited: node["includesCreatedEdit"]?.bool ?? false,
      body: node["body"]?.string)
  }

  /// The type of each error in a GraphQL response, such as NOT_FOUND, by
  /// the alias it names, or by "nodes.<index>" for a node of `nodes(ids:)`.
  static func errorTypes(_ response: JSON) -> [String: String] {
    var types: [String: String] = [:]
    for error in response["errors"]?.array ?? [] {
      guard let path = error["path"]?.array, let first = path.first?.string else { continue }
      types[first + (path.dropFirst().first?.int.map { ".\($0)" } ?? "")] = error["type"]?.string ?? ""
    }
    return types
  }

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

  /// GitHub reports a deleted account's author as null and shows it as ghost.
  static func login(_ author: JSON?) -> String { author?["login"]?.string ?? "ghost" }

  static func nodes(_ connection: JSON?) -> [JSON] {
    (connection?["nodes"]?.array ?? []).filter { $0 != .null }
  }

  /// One query with an alias per key. Each key's values go in variables, so
  /// no branch name appears in the query text.
  public static func lookupQuery(_ keys: [PRKey]) -> (query: String, variables: JSON) {
    var declarations: [String] = []
    var fields: [String] = []
    var variables: [String: JSON] = [:]
    for (i, key) in keys.enumerated() {
      let repo: String
      let field: String
      switch key {
      case .branch(let r, let branch, _):
        repo = r
        declarations.append("$b\(i): String!")
        variables["b\(i)"] = .string(branch)
        field =
          "pullRequests(headRefName: $b\(i), first: 5, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { id state headRepositoryOwner { login } } }"
      case .number(let r, let number):
        repo = r
        declarations.append("$k\(i): Int!")
        variables["k\(i)"] = .number(Double(number))
        field = "pullRequest(number: $k\(i)) { id }"
      }
      let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
      declarations += ["$o\(i): String!", "$n\(i): String!"]
      variables["o\(i)"] = .string(parts.first ?? "")
      variables["n\(i)"] = .string(parts.count > 1 ? parts[1] : "")
      fields.append("  q\(i): repository(owner: $o\(i), name: $n\(i)) { \(field) }")
    }
    let query =
      "query(\(declarations.joined(separator: ", "))) {\n  rateLimit { cost }\n"
      + fields.joined(separator: "\n") + "\n}"
    return (query, .object(variables))
  }

  /// The node id of each key's PR, or nil for a key with no PR, as for a
  /// repo or a PR that doesn't exist. A key whose alias failed in another way
  /// is left out, so the poller asks again. For a branch, an open PR wins over
  /// a merged or closed one, then the newest, and a PR from another owner's
  /// fork doesn't count.
  public static func parseLookup(_ response: JSON, _ keys: [PRKey]) -> [PRKey: String?] {
    let errors = errorTypes(response)
    var found: [PRKey: String?] = [:]
    for (i, key) in keys.enumerated() {
      if let type = errors["q\(i)"], type != notFound { continue }
      let repository = response["data"]?["q\(i)"]
      switch key {
      case .branch(_, _, let owner):
        let mine = nodes(repository?["pullRequests"]).filter {
          $0["headRepositoryOwner"]?["login"]?.string?.lowercased() == owner.lowercased()
        }
        found[key] = .some((mine.first { $0["state"]?.string == PRState.open.rawValue } ?? mine.first)?["id"]?.string)
      case .number:
        found[key] = .some(repository?["pullRequest"]?["id"]?.string)
      }
    }
    return found
  }

  public static func chunks<T>(_ items: [T], size: Int = chunkSize) -> [[T]] {
    stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
  }

  /// GitHub's SSH host for port 443 counts as github.com.
  static let githubHosts: Set<String> = ["github.com", "ssh.github.com"]

  /// owner/name for a GitHub remote URL in the https, ssh, or scp form, or
  /// nil for any other host. As in git, an address with a slash before its
  /// first colon is a local path, not the scp form.
  public static func repo(remoteURL: String) -> String? {
    let authority: Substring
    var path: Substring
    if let scheme = remoteURL.range(of: "://") {
      let rest = remoteURL[scheme.upperBound...]
      let slash = rest.firstIndex(of: "/") ?? rest.endIndex
      authority = rest[..<slash]
      path = rest[slash...]
    } else if let colon = remoteURL.firstIndex(of: ":"), !remoteURL[..<colon].contains("/") {
      authority = remoteURL[..<colon]
      path = remoteURL[remoteURL.index(after: colon)...]
    } else {
      return nil
    }
    var host = authority.split(separator: "@").last ?? ""
    if let port = host.firstIndex(of: ":") { host = host[..<port] }
    guard githubHosts.contains(host.lowercased()) else { return nil }
    path = path.drop { $0 == "/" }
    if path.hasSuffix("/") { path = path.dropLast() }
    if path.hasSuffix(".git") { path = path.dropLast(4) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return parts.joined(separator: "/")
  }

  /// The branch that a HEAD file names, or nil for a detached HEAD. A
  /// remote's HEAD file names a branch under refs/remotes/<remote>/.
  public static func branch(head: String, under refs: String = "refs/heads/") -> String? {
    let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("ref: \(refs)") else { return nil }
    return String(text.dropFirst("ref: \(refs)".count))
  }

  /// The values of `git config --get-regexp` output, by key.
  public static func gitConfig(_ text: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
      values[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return values
  }

  /// The key of the branch's PR, as `git pr` finds it: the PR from the
  /// branch's upstream name in gh's base repo, whose head repository belongs
  /// to the owner of the branch's push remote. `config` holds the git config
  /// values by key, and `remoteHead` gives a remote's default branch. nil
  /// when the push remote isn't on GitHub, or when the branch is the push
  /// remote's default branch.
  public static func branchKey(branch: String, config: [String: String], remoteHead: (String) -> String?) -> PRKey? {
    let b = "branch.\(branch)"
    var push = config["\(b).pushremote"] ?? config["remote.pushdefault"] ?? config["\(b).remote"] ?? "origin"
    let heads = "refs/heads/"
    var upstream = config["\(b).merge"].map { String($0.dropFirst($0.hasPrefix(heads) ? heads.count : 0)) } ?? branch
    // "." means that the branch tracks a local branch.
    if push == "." {
      push = "origin"
      upstream = branch
    }
    guard let head = config["remote.\(push).url"].flatMap(repo(remoteURL:)), remoteHead(push) != upstream else {
      return nil
    }
    // gh asks the remote that `gh repo set-default` marked, then upstream,
    // then origin. A branch pushed to a fork has its PR in that repo.
    let remotes = config.keys.compactMap { key -> String? in
      guard key.hasPrefix("remote."), key.hasSuffix(".url") else { return nil }
      return String(key.dropFirst("remote.".count).dropLast(".url".count))
    }
    let base =
      remotes.first { config["remote.\($0).gh-resolved"] == "base" }
      ?? ["upstream", "origin"].first(where: remotes.contains)
    let baseRepo = base.flatMap { config["remote.\($0).url"] }.flatMap(repo(remoteURL:)) ?? head
    return .branch(repo: baseRepo, branch: upstream, owner: String(head.split(separator: "/")[0]))
  }

  /// The PR as its session shows it, with the queue state that its comments
  /// give. GitHub answers UNKNOWN while it computes mergeability again, as
  /// after the base branch moved. The PR then keeps the mergeability that
  /// `last` showed for the same head commit, so a conflict doesn't leave
  /// Needs you and come back.
  public static func shown(_ pr: PullRequest, _ comments: [PRComment], last: PullRequest?) -> PullRequest {
    var shown = pr
    let change = TrunkComments.change(of: pr, comments)
    shown.queue = change?.state
    shown.queueAt = change?.at.flatMap(Transcript.milliseconds)
    if pr.mergeable == .unknown, let last, last.id == pr.id, last.headSha == pr.headSha, let kept = last.mergeable {
      shown.mergeable = kept
    }
    return shown
  }

  /// Whether `interval` ms have passed since `since`, or `since` is nil.
  public static func elapsed(since: Int64?, _ interval: Int64, now: Int64) -> Bool {
    since.map { now - $0 >= interval } ?? true
  }

  /// Whether a PR is due to poll at `now`. A PR that was never read is due.
  /// A pending PR is due after `pendingMs`, and any other after `idleMs`.
  public static func isDue(_ pr: PullRequest?, lastPolled: Int64?, now: Int64, pendingMs: Int64, idleMs: Int64)
    -> Bool
  {
    guard let pr else { return true }
    return elapsed(since: lastPolled, pr.isPending ? pendingMs : idleMs, now: now)
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
