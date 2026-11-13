import Foundation

extension GitHub {
  static let notFound = "NOT_FOUND"

  public static let statusQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id number url title state isDraft mergedAt closedAt mergeCommit { oid } body author { login }
          headRefName headRefOid baseRefName mergeable reviewDecision isMergeQueueEnabled isInMergeQueue
          repository { nameWithOwner defaultBranchRef { name } trunkConfig: object(expression: "HEAD:.trunk") { id } }
          labels(first: 20) { nodes { name } }
          reviewRequests(first: 20) {
            totalCount
            nodes {
              asCodeOwner
              requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Team { slug combinedSlug } }
            }
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

  /// The id of the GitHub Actions app on github.com. Each workflow run is a
  /// check suite of this app. A CI that isn't Actions has no suite here.
  private static let actionsAppId = 15368

  /// The GitHub Actions suites of each PR's last commit. The status query
  /// leaves them out. A PostHog/posthog PR has about 30 to 60 of them, and
  /// they made a status read of 20 such PRs take about twice as long.
  public static let actionsQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id
          commits(last: 1) {
            nodes {
              commit {
                oid
                statusCheckRollup { state }
                checkSuites(first: 100, filterBy: {appId: \(actionsAppId)}) { pageInfo { hasNextPage } nodes { status } }
              }
            }
          }
        }
      }
    }
    """

  /// Whether a base branch requires code owner review. It also reads the
  /// CODEOWNERS file in each place that GitHub looks. `$ref` is the branch name.
  /// `$github`, `$root`, and `$docs` are `<branch>:.github/CODEOWNERS`,
  /// `<branch>:CODEOWNERS`, and `<branch>:docs/CODEOWNERS`.
  public static let codeOwnersConfigQuery = """
    query($owner: String!, $name: String!, $ref: String!, $github: String!, $root: String!, $docs: String!) {
      rateLimit { cost }
      repository(owner: $owner, name: $name) {
        ref(qualifiedName: $ref) {
          branchProtectionRule { requiresCodeOwnerReviews }
          rules(first: 100) {
            totalCount
            nodes {
              type parameters { ... on PullRequestParameters { requireCodeOwnerReview } }
              repositoryRuleset { enforcement }
            }
          }
        }
        codeowners(refName: $ref) { errors { line kind } }
        github: object(expression: $github) { ...codeOwnersBlob }
        root: object(expression: $root) { ...codeOwnersBlob }
        docs: object(expression: $docs) { ...codeOwnersBlob }
      }
    }
    fragment codeOwnersBlob on Blob { text isTruncated isBinary }
    """

  /// The first page of each PR's changed files, with the head and base that
  /// the files belong to.
  public static let filesQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id headRefOid baseRefName
          files(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { path } }
        }
      }
    }
    """

  /// A later page of one PR's changed files.
  public static let filesPageQuery = """
    query($id: ID!, $after: String!) {
      rateLimit { cost }
      node(id: $id) {
        ... on PullRequest {
          id headRefOid baseRefName
          files(first: 100, after: $after) { totalCount pageInfo { hasNextPage endCursor } nodes { path } }
        }
      }
    }
    """

  /// The teams that each reviewer's last verdict was on behalf of. The
  /// status query leaves this out. It would raise a chunk's cost from 1
  /// point to about 5.
  public static let approvalTeamsQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id
          latestOpinionatedReviews(first: 20) {
            nodes { author { login } submittedAt onBehalfOf(first: 10) { nodes { combinedSlug } } }
          }
        }
      }
    }
    """

  /// Whether a config response's base branch requires code owner review, with
  /// its CODEOWNERS file. Throws on a response with errors, so a partial
  /// answer is a failed read. `off` when the requirement is absent. Also
  /// `off` when sbd cannot read the requirement as GitHub does. That holds
  /// for a rules list longer than its nodes, a chosen file that GitHub
  /// reports errors in, and a file that is truncated, binary, or uses syntax
  /// that GitHub does not support.
  public static func parseCodeOwnersConfig(_ response: JSON) throws -> CodeOwnersConfig {
    if response["errors"]?.array?.isEmpty == false {
      throw APIError("GitHub failed to read the code owner config: \(message(response))")
    }
    guard let repository = response["data"]?["repository"], repository != .null else {
      throw APIError("GitHub returned no repository for the code owner config")
    }
    guard let ref = repository["ref"], ref != .null else { return .off("no base branch") }
    let rules = nodes(ref["rules"])
    guard let total = ref["rules"]?["totalCount"]?.int, total <= rules.count else {
      return .off("more rules than read")
    }
    let required =
      ref["branchProtectionRule"]?["requiresCodeOwnerReviews"]?.bool == true
      || rules.contains {
        $0["type"]?.string == "PULL_REQUEST" && $0["parameters"]?["requireCodeOwnerReview"]?.bool == true
          && $0["repositoryRuleset"]?["enforcement"]?.string == "ACTIVE"
      }
    guard required else { return .off("no code owner review required") }
    guard let blob = ["github", "root", "docs"].lazy.compactMap({ repository[$0] }).first(where: { $0 != .null })
    else { return .off("no CODEOWNERS file") }
    guard repository["codeowners"]?["errors"]?.array?.isEmpty == true else { return .off("CODEOWNERS has errors") }
    guard blob["isTruncated"]?.bool == false, blob["isBinary"]?.bool == false, let text = blob["text"]?.string else {
      return .off("CODEOWNERS is unreadable")
    }
    guard let file = CodeOwnersFile.parse(text) else { return .off("CODEOWNERS uses unsupported syntax") }
    return .on(file)
  }

  /// One page of a PR's changed files, from a files response's node. It
  /// holds the paths, GitHub's count of all changed files, and the cursor of
  /// the next page. nil when the node has no files, as for a node that isn't a PR.
  public static func parseFiles(_ node: JSON) -> (paths: [String], total: Int, next: String?)? {
    guard let files = node["files"], let total = files["totalCount"]?.int else { return nil }
    let next = files["pageInfo"]?["hasNextPage"]?.bool == true ? files["pageInfo"]?["endCursor"]?.string : nil
    return (nodes(files).compactMap { $0["path"]?.string }, total, next)
  }

  /// The teams that each reviewer's last verdict was on behalf of, by the
  /// reviewer's login and the verdict's submission time.
  public static func parseApprovalTeams(_ node: JSON) -> [(author: String, submittedAt: String?, teams: [String])] {
    nodes(node["latestOpinionatedReviews"]).map {
      (
        login($0["author"]), $0["submittedAt"]?.string,
        nodes($0["onBehalfOf"]).compactMap { $0["combinedSlug"]?.string }
      )
    }
  }

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
    let repo = node["repository"]?["nameWithOwner"]?.string ?? ""
    // A decision that ReviewDecision doesn't know stays unread, so it never
    // reads as "no review required".
    let reviewDecision = node["reviewDecision"]?.string.flatMap(ReviewDecision.init(rawValue:))
    let pr = PullRequest(
      id: id, number: number, url: node["url"]?.string ?? "", repo: repo,
      title: node["title"]?.string ?? "", state: PRState(rawValue: node["state"]?.string ?? "") ?? .open,
      draft: node["isDraft"]?.bool ?? false, head: node["headRefName"]?.string ?? "",
      headSha: node["headRefOid"]?.string ?? "", base: node["baseRefName"]?.string ?? "",
      defaultBranch: node["repository"]?["defaultBranchRef"]?["name"]?.string,
      mergeable: node["mergeable"]?.string.flatMap(Mergeable.init(rawValue:)),
      reviewDecision: reviewDecision,
      verdicts: nodes(node["latestOpinionatedReviews"]).map(review), reviews: nodes(node["reviews"]).map(review),
      labels: nodes(node["labels"]).compactMap { $0["name"]?.string },
      checks: nodes(node["commits"]).first?["commit"]?["statusCheckRollup"]?["state"]?.string,
      mergedAt: node["mergedAt"]?.string, closedAt: node["closedAt"]?.string,
      reviewRequests: reviewRequests, mergeCommit: node["mergeCommit"]?["oid"]?.string,
      dependsOn: node["body"]?.string.map { Dependencies.refs(inBody: $0, repo: repo) },
      trunkConfig: node["repository"]?["trunkConfig"].map { $0 != .null },
      reviewDecisionRead: node["reviewDecision"] == .null || reviewDecision != nil ? true : nil,
      mergeQueue: node["isMergeQueueEnabled"]?.bool, inMergeQueue: node["isInMergeQueue"]?.bool,
      author: node["author"].map(login), codeOwnerRequests: node["reviewRequests"].flatMap(codeOwnerRequests),
      closesIssues: node["body"]?.string.flatMap { Issues.closingRefs(inBody: $0, repo: repo) })
    var seen: Set<String> = []
    let comments = (nodes(node["firstComments"]) + nodes(node["lastComments"])).compactMap(parseComment)
      .filter { seen.insert($0.id).inserted }.sorted { $0.createdAt < $1.createdAt }
    return (pr, comments)
  }

  /// The users and teams that GitHub asked to review as code owners, as
  /// `@login` or `@org/team`. nil when a request failed to read, a code
  /// owner request has no name, or the connection holds more requests than
  /// it returned.
  static func codeOwnerRequests(_ connection: JSON) -> [String]? {
    guard let all = connection["nodes"]?.array, !all.contains(.null) else { return nil }
    if let total = connection["totalCount"]?.int, total > all.count { return nil }
    var requests: [String] = []
    for request in all where request["asCodeOwner"]?.bool == true {
      let reviewer = request["requestedReviewer"]
      guard let name = reviewer?["combinedSlug"]?.string ?? reviewer?["login"]?.string else { return nil }
      requests.append("@" + name)
    }
    return requests
  }

  /// The PRs of a status response, and the ids that GitHub reports
  /// NOT_FOUND, as for a deleted PR. A node that failed in another way is in
  /// neither.
  public static func parseStatus(_ response: JSON, _ ids: [String]) -> (
    prs: [(pr: PullRequest, comments: [PRComment])], gone: Set<String>
  ) {
    let unread = trunkConfigErrors(response)
    let prs = (response["data"]?["nodes"]?.array ?? []).enumerated().compactMap { i, node in
      parsePR(node).map { parsed in
        var parsed = parsed
        if unread(i) { parsed.pr.trunkConfig = nil }
        return parsed
      }
    }
    return (prs, notFoundNodes(response, ids))
  }

  /// Whether GitHub reported an error for node `i` at or under its
  /// repository. GitHub then answers `trunkConfig` with null, which would
  /// read as a repository without a `.trunk` folder. An error without a path
  /// counts for every node.
  static func trunkConfigErrors(_ response: JSON) -> (Int) -> Bool {
    var nodes: Set<Int> = []
    for error in response["errors"]?.array ?? [] {
      guard let path = error["path"]?.array else { return { _ in true } }
      guard path.first?.string == "nodes", let i = path.dropFirst().first?.int else { continue }
      if path.count == 2 || path[2].string == "repository" { nodes.insert(i) }
    }
    return { nodes.contains($0) }
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

  /// One node of an actions response. nil when the node isn't a PR.
  public static func parseActions(_ node: JSON) -> (id: String, read: ActionsRead)? {
    guard let id = node["id"]?.string else { return nil }
    let commit = nodes(node["commits"]).first?["commit"]
    let suites = commit?["checkSuites"]
    let statuses = nodes(suites).map { $0["status"]?.string }
    let read = ActionsRead(
      sha: commit?["oid"]?.string ?? "", checks: commit?["statusCheckRollup"]?["state"]?.string,
      completed: suites?["pageInfo"]?["hasNextPage"]?.bool == false && !statuses.isEmpty
        && statuses.allSatisfy { $0 == "COMPLETED" })
    return (id, read)
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
      let (owner, name) = ownerAndName(repo)
      declarations += ["$o\(i): String!", "$n\(i): String!"]
      variables["o\(i)"] = .string(owner)
      variables["n\(i)"] = .string(name)
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
}

/// What one actions read shows about a PR's last commit.
public struct ActionsRead: Equatable, Sendable {
  public var sha: String
  /// The commit's rollup state.
  public var checks: String?
  /// Whether the commit has at least one GitHub Actions suite, the read's one
  /// page holds all of them, and each one completed.
  public var completed: Bool

  /// Whether the read shows that `pr`'s rollup state is the result of a
  /// GitHub Actions run of its head commit that completed. A read of another
  /// commit, or of another rollup state, shows nothing about `pr`.
  public func showsFinishedRun(of pr: PullRequest) -> Bool {
    completed && sha == pr.headSha && checks == pr.checks
  }
}
