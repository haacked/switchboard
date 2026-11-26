import Foundation
import SwitchboardCore

/// A GitHub API on 127.0.0.1 for one test. It answers the poller's GraphQL
/// lookup, status, and body queries from the PR nodes and comment bodies that
/// Fixtures/github-*.json recorded, which a test can change between polls,
/// its code owner queries from the configs and changed files that a test
/// sets, and its reference queries from the items that a test puts. It
/// answers a REST GET from the routes that a test sets, and 404 for any other
/// path. It also serves issues and contents files that GET, PATCH, and PUT
/// change, as GitHub does. It serves the Event Streams API under
/// /event-subscriptions, which answers 403 until a test sets
/// `eventsEnabled`. It records each request.
final class FakeGitHub {
  struct Request {
    /// lookup, status, base, bodies, codeowners, files, approvals, actions,
    /// mergeDetails, issues, or reference.
    var kind: String
    /// The node ids that a status, base, body, files, approvals, or actions query
    /// asked for, each lookup key as owner/name:branch or owner/name#number,
    /// the owner/name:branch of a codeowners query, the aliases of an issues
    /// query, r<i> for a repository and o<i> for an org search, or the
    /// lowercase owner/name#number of a reference query.
    var ids: [String]
    var authorization: String?
    var variables: [String: JSON]
  }

  struct Reply {
    var status: Int
    var headers: [String: String]
    var body: String
  }

  /// A REST request, with its path without the leading slash or the query.
  struct RESTRequest {
    var method: String
    var path: String
    var query: [String: String]
    var ifNoneMatch: String?
    var body: String
    var authorization: String?
  }

  /// An issue that a PATCH of its body changes. Each change moves
  /// `updated_at` and the ETag.
  struct Issue {
    var number: Int
    var body: String
    var revision: Int
  }

  /// A file on one branch that a PUT with its blob SHA changes. Each change
  /// gives it a new SHA and ETag.
  struct File {
    var path: String
    var branch: String
    var content: String
    var revision: Int
  }

  /// The answer to a REST GET of one path.
  struct Route {
    var status: Int
    var body: String
    /// The ETag of a 200. A request whose If-None-Match equals it gets a 304.
    var etag: String?
    var contentType: String
  }

  /// The queries that ask for PR nodes.
  enum PRQuery: String {
    case status, base, files, approvals, actions, mergeDetails

    /// The queries whose answer projects each PR node through the query's selection, by operation name.
    static let selecting: [String: PRQuery] = [
      "Status": .status, "Base": .base, "Actions": .actions, "ApprovalTeams": .approvals, "MergeDetails": .mergeDetails,
    ]
  }

  /// A base branch's code owner settings, as the codeowners query reads them.
  struct CodeOwnerConfig {
    var rules: [JSON]
    var protection: JSON?
    /// The CODEOWNERS text by its path in the repo.
    var files: [String: String]
    /// nil answers `codeowners: null`.
    var errors: [JSON]?
  }

  static let fixtures = Instance.root.appendingPathComponent("Tests/IntegrationTests/Fixtures").path

  private let fd: Int32
  let port: Int
  private let lock = NSLock()
  private var prs: [String: [String: JSON]] = [:]
  private var bodies: [String: JSON] = [:]
  /// The PRs whose node answers null with an error other than NOT_FOUND,
  /// by the query that fails, and the comments whose body node does.
  private var failingPRs: [PRQuery: Set<Int>] = [:]
  private var failingComments: Set<String> = []
  private var log: [Request] = []
  private var queued: [Reply] = []
  private var routes: [(path: String, query: [String: String], route: Route)] = []
  private var restLog: [RESTRequest] = []
  private var nextComment = 0
  /// By REST path, such as repos/o/r/issues/5.
  private var issues: [String: Issue] = [:]
  /// By REST path, such as repos/o/r/contents/docs/plan.md.
  private var files: [String: File] = [:]
  private var revision = 0
  /// What to run after the next GET of each path.
  private var afterGET: [String: () -> Void] = [:]
  /// The status that the next GET of each path gets instead of its answer.
  private var failingGETs: [String: Int] = [:]
  /// By lowercase owner/name, a colon, and the branch.
  private var codeOwnerConfigs: [String: CodeOwnerConfig] = [:]
  /// The lowercase owner/name of each repo whose codeowners query answers a null repository and an error.
  private var failingCodeOwners: Set<String> = []
  /// By lowercase owner/name#number.
  private var listedIssues: [String: FakeIssue] = [:]
  /// The lowercase owner/name of each repository that a repository source can read.
  private var listedRepos: Set<String> = []
  private var viewer = "robin-k"
  /// Each PR's changed files, by number, with the `totalCount` that GitHub
  /// reports when it differs from the number of paths.
  private var changedFiles: [Int: (paths: [String], totalCount: Int?)] = [:]
  /// What to run after the next files query.
  private var afterFiles: (() -> Void)?
  private var eventsOn = false
  private var limit = 100
  private var eventSubscriptions: [EventSubscription] = []
  /// The answer to the next request to an event-subscriptions path.
  private var failingEventRequest: Reply?
  /// Guards `streams` and `keepAlives`, and serializes every write to a stream so that two writers' chunks never
  /// interleave. A holder of `lock` may take `streamLock`. A holder of `streamLock` never takes `lock`.
  private let streamLock = NSLock()
  private var streams: [EventStream] = []
  private var keepAlives = true

  /// An issue that the issues query reads.
  struct FakeIssue {
    var repo: String
    var number: Int
    var title: String
    var body = ""
    var open = true
    var labels: [String] = []
    var assignees: [String] = []
    /// The author's login, or nil for an issue whose author GitHub no longer has.
    var author: String? = "robin-k"
    var createdAt = "2026-11-01T10:00:00Z"
    var updatedAt = "2026-11-10T10:00:00Z"

    var node: JSON {
      [
        "number": .number(Double(number)), "title": .string(title), "body": .string(body),
        "url": .string("https://github.com/\(repo)/issues/\(number)"), "state": .string(open ? "OPEN" : "CLOSED"),
        "createdAt": .string(createdAt), "updatedAt": .string(updatedAt),
        "repository": ["nameWithOwner": .string(repo)],
        "labels": ["nodes": .array(labels.map { ["name": .string($0)] })],
        "assignees": ["nodes": .array(assignees.map { ["login": .string($0)] })],
        "author": author.map { ["login": .string($0)] } ?? .null,
      ]
    }
  }

  /// By lowercase owner/name#number.
  private var references: [String: FakeReference] = [:]

  /// An issue or PR that the reference query reads. The values are GitHub's, such as `MERGED`.
  struct FakeReference {
    var repo: String
    var number: Int
    var pull = false
    var title = "Totals round twice"
    var state = "OPEN"
    var draft = false
    var author: String? = "robin-k"
    var labels: [String] = []
    var createdAt = "2026-11-01T10:00:00Z"
    var updatedAt = "2026-11-10T10:00:00Z"
    var checks: String?
    var reviewDecision: String?
    var mergeable: String?

    var node: JSON {
      var node: [String: JSON] = [
        "__typename": .string(pull ? "PullRequest" : "Issue"), "number": .number(Double(number)),
        "title": .string(title), "url": .string("https://github.com/\(repo)/\(pull ? "pull" : "issues")/\(number)"),
        "state": .string(state), "createdAt": .string(createdAt), "updatedAt": .string(updatedAt),
        "author": author.map { ["login": .string($0)] } ?? .null,
        "labels": ["nodes": .array(labels.map { ["name": .string($0)] })],
      ]
      if pull {
        node["isDraft"] = .bool(draft)
        node["reviewDecision"] = reviewDecision.map(JSON.string) ?? .null
        node["mergeable"] = mergeable.map(JSON.string) ?? .null
        let rollup: JSON = checks.map { ["state": .string($0)] } ?? .null
        node["commits"] = ["nodes": [["commit": ["statusCheckRollup": rollup]]]]
      }
      return .object(node)
    }
  }

  /// Adds the item, or replaces the one with its repo and number, for the reference query.
  func putReference(_ reference: FakeReference) {
    lock.withLock { references["\(reference.repo.lowercased())#\(reference.number)"] = reference }
  }

  /// Adds the issue, or replaces the one with its repo and number. Its repo then exists for a repository source.
  func put(_ issue: FakeIssue) {
    lock.withLock {
      listedIssues["\(issue.repo.lowercased())#\(issue.number)"] = issue
      listedRepos.insert(issue.repo.lowercased())
    }
  }

  /// Makes a repository exist for a repository source, with no issues.
  func addRepo(_ repo: String) { _ = lock.withLock { listedRepos.insert(repo.lowercased()) } }

  /// The login that `viewer` answers.
  func setViewer(_ login: String) { lock.withLock { viewer = login } }

  /// The filter of one alias of an issues query: a repository's open issues or its issues updated
  /// since a time, or an org search's terms.
  private func issueRequest(_ repository: Bool, _ i: String, _ variables: [String: JSON]) -> (
    repo: String, filter: (FakeIssue) -> Bool
  ) {
    if repository {
      let repo = "\(variables["o\(i)"]?.string ?? "")/\(variables["n\(i)"]?.string ?? "")".lowercased()
      let since = variables["s\(i)"]?.string
      let label = variables["l\(i)"]?.array?.first?.string
      let person = variables["p\(i)"]?.string
      return (
        repo,
        { issue in
          issue.repo.lowercased() == repo && (since.map { issue.updatedAt >= $0 } ?? issue.open)
            && (label.map { issue.labels.contains($0) } ?? true)
            && (person.map { issue.assignees.contains($0) } ?? true)
        }
      )
    }
    let terms = variables["q\(i)"]?.string ?? ""
    let org = terms.firstMatch(of: #/org:(\S+)/#).map { String($0.1).lowercased() } ?? ""
    let label = terms.firstMatch(of: #/label:"([^"]*)"/#).map { String($0.1) }
    let person = terms.firstMatch(of: #/assignee:(\S+)/#).map { String($0.1) }
    let since = terms.firstMatch(of: #/updated:>=(\S+)/#).map { String($0.1) }
    let open = terms.contains("is:open")
    return (
      org,
      { issue in
        issue.repo.lowercased().hasPrefix(org + "/") && (label.map { issue.labels.contains($0) } ?? true)
          && (person.map { issue.assignees.contains($0) } ?? true) && (!open || issue.open)
          && (since.map { issue.updatedAt >= $0 } ?? true)
      }
    )
  }

  init() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
        bind(listener, p, len) == 0 && listen(listener, 16) == 0 && getsockname(listener, p, &len) == 0
      }
    }
    guard bound else {
      close(listener)
      throw TestError(description: "can't listen on 127.0.0.1")
    }
    fd = listener
    port = Int(UInt16(bigEndian: addr.sin_port))
    for node in try FakeGitHub.recorded("github-status.json") {
      if let id = node["id"]?.string, let object = node.object { prs[id] = object }
    }
    // GitHub answers both merge queue fields for every PR. The recording
    // predates the status query's ask for them.
    for id in prs.keys {
      if prs[id]!["isMergeQueueEnabled"] == nil { prs[id]!["isMergeQueueEnabled"] = false }
      if prs[id]!["isInMergeQueue"] == nil { prs[id]!["isInMergeQueue"] = false }
      // Nor the review requests, which GitHub answers as an empty list when nobody is asked.
      if prs[id]!["reviewRequests"] == nil { prs[id]!["reviewRequests"] = ["totalCount": 0, "nodes": []] }
      // Nor do they hold the fields that the merge details query reads.
      for (key, value) in [
        "additions": 12, "deletions": 3, "changedFiles": 2, "reviewThreads": ["totalCount": 0, "nodes": []],
      ] as [String: JSON] where prs[id]![key] == nil {
        prs[id]![key] = value
      }
    }
    for node in try FakeGitHub.recorded("github-bodies.json") {
      if let id = node["id"]?.string { bodies[id] = node }
    }
    _ = FakeGitHub.ignoreSIGPIPE
    // The thread holds the fake weakly, so deinit closes the socket, which
    // ends the thread's accept.
    Thread.detachNewThread { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if self?.handle(client) != true { close(client) }
      }
    }
    Thread.detachNewThread { [weak self] in
      while true {
        usleep(500_000)
        guard let self else { return }
        self.keepStreamsAlive()
      }
    }
  }

  deinit {
    close(fd)
    streamLock.withLock { for stream in streams { close(stream.fd) } }
  }

  /// A write to a client that closed its stream fails with EPIPE instead of ending the test process. macOS refuses
  /// SO_NOSIGPIPE on a socket whose peer has already closed.
  private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

  var url: String { "http://127.0.0.1:\(port)" }

  /// The GraphQL requests.
  var requests: [Request] { lock.withLock { log } }

  var restRequests: [RESTRequest] { lock.withLock { restLog } }

  /// The REST requests to `path`, whatever their query.
  func restRequests(to path: String) -> [RESTRequest] { restRequests.filter { $0.path == path } }

  /// The requests to event-subscriptions paths.
  var eventRequests: [RESTRequest] { restRequests.filter { FakeGitHub.isEventsPath($0.path) } }

  /// The REST requests to other paths. sbd's Event Streams provider sends its requests on its own schedule, so a
  /// test that counts the poller's REST requests counts these.
  var restRequestsWithoutEvents: [RESTRequest] { restRequests.filter { !FakeGitHub.isEventsPath($0.path) } }

  /// Whether a status request after the first `since` GraphQL requests read the PR with this node id.
  func readStatus(of id: String, since: Int = 0) -> Bool {
    requests.dropFirst(since).contains { $0.kind == "status" && $0.ids.contains(id) }
  }

  static func recorded(_ name: String) throws -> [JSON] {
    let text = try String(contentsOfFile: "\(fixtures)/\(name)", encoding: .utf8)
    return JSON.parse(text)?["data"]?["nodes"]?.array ?? []
  }

  /// The recorded PR with this number.
  func pr(_ number: Int) -> [String: JSON] {
    lock.withLock { prs.values.first { $0["number"]?.int == number }! }
  }

  func change(_ number: Int, _ edit: (inout [String: JSON]) -> Void) {
    lock.withLock {
      let id = prs.first { $0.value["number"]?.int == number }!.key
      edit(&prs[id]!)
    }
  }

  /// Adds PR `number` on `branch` with head `head`, a copy of PR `source` in the same repository otherwise, so a
  /// test can have two PRs that the lookup, status, and merge details queries answer alike.
  func addPR(copying source: Int, number: Int, branch: String, head: String) {
    lock.withLock {
      var pr = prs.values.first { $0["number"]?.int == source }!
      let repo = pr["repository"]?["nameWithOwner"]?.string ?? ""
      pr["id"] = .string("PR_copy_\(number)")
      pr["number"] = .number(Double(number))
      pr["url"] = .string("https://github.com/\(repo)/pull/\(number)")
      pr["headRefName"] = .string(branch)
      pr["headRefOid"] = .string(head)
      prs["PR_copy_\(number)"] = pr
    }
  }

  /// Gives the PR one review thread for each value, resolved or not, and
  /// `totalCount` as GitHub's count when it differs. Each thread has one
  /// comment by another user.
  func reviewThreads(_ number: Int, resolved: [Bool], totalCount: Int? = nil) {
    reviewThreads(
      number,
      details: resolved.enumerated().map { i, resolved in
        FakeThread(resolved: resolved, path: "file\(i).yaml", discussionId: 2_512_345_678 + Int64(i))
      }, totalCount: totalCount)
  }

  /// A review thread with the first and last comments that the merge details
  /// query reads when its `threads` variable is true.
  struct FakeThread {
    var resolved = false
    var outdated = false
    var path = "charts/posthog/values.yaml"
    var line: Int? = 12
    var originalLine: Int? = 12
    /// An author that ends in [bot] is a GitHub App, which GraphQL shows as
    /// a Bot without the suffix.
    var author = "mariusandra"
    var body = "Should this default change?"
    /// The number in the first comment's `#discussion_r` URL fragment.
    var discussionId: Int64 = 2_512_345_678
    var comments = 1
    /// Whether the viewer wrote the thread's last comment.
    var viewerWroteLast = false
  }

  /// Gives the PR these review threads, stored under the merge details
  /// query's `first` and `last` aliases, and `totalCount` as GitHub's count
  /// when it differs.
  func reviewThreads(_ number: Int, details threads: [FakeThread], totalCount: Int? = nil) {
    change(number) { pr in
      let repo = pr["repository"]?["nameWithOwner"]?.string ?? ""
      pr["reviewThreads"] = [
        "totalCount": .number(Double(totalCount ?? threads.count)),
        "nodes": .array(
          threads.map { t in
            [
              "isResolved": .bool(t.resolved), "isOutdated": .bool(t.outdated), "path": .string(t.path),
              "line": t.line.map { .number(Double($0)) } ?? .null,
              "originalLine": t.originalLine.map { .number(Double($0)) } ?? .null,
              "first": [
                "nodes": [
                  [
                    "url": .string("https://github.com/\(repo)/pull/\(number)#discussion_r\(t.discussionId)"),
                    "body": .string(t.body), "author": FakeGitHub.author(t.author),
                  ]
                ]
              ],
              "last": [
                "totalCount": .number(Double(t.comments)), "nodes": [["viewerDidAuthor": .bool(t.viewerWroteLast)]],
              ],
            ]
          }),
      ]
    }
  }

  /// A review that the merge details query reads with its body and inline comments.
  struct FakeReview {
    var author = "stamphog"
    var state = "APPROVED"
    var body = ""
    /// nil gives a review whose commit GitHub answers as null.
    var commit: String?
    var submittedAt = "2026-10-25T20:56:17Z"
    var reviewId: Int64 = 3_400_000_001
    /// Each inline comment's path, line, and body.
    var notes: [(path: String, line: Int, body: String)] = []
    /// GitHub's count of the inline comments, when it differs from `notes`.
    var noteCount: Int?
  }

  /// Sets the PR's latest opinionated reviews, which both the status query
  /// and the merge details query read.
  func reviews(_ number: Int, _ reviews: [FakeReview]) {
    change(number) { pr in
      let repo = pr["repository"]?["nameWithOwner"]?.string ?? ""
      let url = "https://github.com/\(repo)/pull/\(number)"
      pr["latestOpinionatedReviews"] = [
        "nodes": .array(
          reviews.map { r in
            [
              "author": FakeGitHub.author(r.author), "state": .string(r.state), "body": .string(r.body),
              "url": .string("\(url)#pullrequestreview-\(r.reviewId)"), "submittedAt": .string(r.submittedAt),
              "commit": r.commit.map { ["oid": .string($0)] } ?? .null,
              "comments": [
                "totalCount": .number(Double(r.noteCount ?? r.notes.count)),
                "nodes": .array(
                  r.notes.enumerated().map { i, note in
                    [
                      "path": .string(note.path), "line": .number(Double(note.line)),
                      "originalLine": .number(Double(note.line)), "body": .string(note.body),
                      "url": .string("\(url)#discussion_r\(r.reviewId + 1 + Int64(i))"),
                    ]
                  }),
              ],
            ]
          })
      ]
    }
  }

  /// Sets the PR's commits, oldest first, so the last one should be its
  /// head. The fake ignores `last:`, so the status query's `commits(last: 1)`
  /// gets every node and reads the first. Each node keeps the recorded check
  /// state so that read doesn't change.
  func commits(_ number: Int, oids: [String]) {
    change(number) { pr in
      let rollup = pr["commits"]?["nodes"]?.array?.first?["commit"]?["statusCheckRollup"] ?? .null
      pr["commits"] = [
        "nodes": .array(oids.map { ["commit": ["oid": .string($0), "statusCheckRollup": rollup]] })
      ]
    }
  }

  /// An author node. A login that ends in [bot] is a Bot without the suffix.
  static func author(_ login: String) -> JSON {
    let bot = login.hasSuffix("[bot]")
    return ["__typename": bot ? "Bot" : "User", "login": .string(bot ? String(login.dropLast(5)) : login)]
  }

  /// Forgets the PR, as GitHub does after a deletion.
  func remove(_ number: Int) {
    lock.withLock { prs = prs.filter { $0.value["number"]?.int != number } }
  }

  /// Makes the PR's node in a status or base query fail with an internal
  /// error, as GitHub sometimes does.
  func fail(_ number: Int, in query: PRQuery = .status) {
    lock.withLock { _ = failingPRs[query, default: []].insert(number) }
  }

  func recover(_ number: Int, in query: PRQuery = .status) {
    lock.withLock { _ = failingPRs[query, default: []].remove(number) }
  }

  /// Sets the code owner config of `repo`'s `base`, in place of an earlier
  /// one. `rules` are `ref.rules.nodes`, and `protection` is
  /// `ref.branchProtectionRule`. `files` holds the CODEOWNERS text by its
  /// path. `errors` are `codeowners.errors`. A repo with no config answers
  /// no rules, null protection, null codeowners, and no files, as
  /// haacked/switchboard does.
  func codeOwners(
    repo: String, base: String, rules: [JSON], protection: JSON?, files: [String: String], errors: [JSON]?
  ) {
    lock.withLock {
      codeOwnerConfigs["\(repo.lowercased()):\(base)"] = CodeOwnerConfig(
        rules: rules, protection: protection, files: files, errors: errors)
    }
  }

  /// Makes each codeowners query for `repo` answer a null repository with an error.
  func failCodeOwners(repo: String) {
    lock.withLock { _ = failingCodeOwners.insert(repo.lowercased()) }
  }

  func recoverCodeOwners(repo: String) {
    lock.withLock { _ = failingCodeOwners.remove(repo.lowercased()) }
  }

  /// Sets the PR's changed files. A files query reads them in pages of its
  /// `first`, with the index of the next path as the cursor. `totalCount`
  /// replaces the number of paths in the answer.
  func changedFiles(_ number: Int, _ paths: [String], totalCount: Int? = nil) {
    lock.withLock { changedFiles[number] = (paths, totalCount) }
  }

  /// Runs `action` once, after the fake answers the next files query and
  /// before it answers any other request, as a push between two pages does.
  func afterNextFiles(_ action: @escaping () -> Void) {
    lock.withLock { afterFiles = action }
  }

  /// Makes the comment's node in a body query fail with an internal error.
  func fail(comment id: String) {
    lock.withLock { _ = failingComments.insert(id) }
  }

  func recover(comment id: String) {
    lock.withLock { _ = failingComments.remove(id) }
  }

  /// Gives a comment a new body and edit time, both in its PR's comment lists
  /// and in the body query's answer.
  func edit(comment id: String, body: String, at time: String) {
    lock.withLock {
      bodies[id] = .object(
        (bodies[id]?.object ?? [:]).merging([
          "body": .string(body), "lastEditedAt": .string(time), "includesCreatedEdit": true,
        ]) { $1 })
      for (pr, var node) in prs {
        for list in ["firstComments", "lastComments"] {
          guard let comments = node[list]?["nodes"]?.array else { continue }
          let edited = comments.map { c -> JSON in
            guard c["id"]?.string == id, var o = c.object else { return c }
            o["lastEditedAt"] = .string(time)
            o["includesCreatedEdit"] = true
            return .object(o)
          }
          node[list] = ["nodes": .array(edited)]
        }
        prs[pr] = node
      }
    }
  }

  /// Adds a comment with a body to the PR's last comments and to the body
  /// query's answer, and returns its id. An author that ends in [bot] is a
  /// GitHub App, which GraphQL shows as a Bot without the suffix.
  @discardableResult
  func comment(on number: Int, by author: String, body: String, at time: String) -> String {
    lock.withLock {
      nextComment += 1
      let id = "IC_fake\(nextComment)"
      let node: JSON = [
        "id": .string(id), "author": Self.author(author),
        "createdAt": .string(time), "lastEditedAt": .null, "includesCreatedEdit": false,
      ]
      let pr = prs.first { $0.value["number"]?.int == number }!.key
      prs[pr]!["lastComments"] = ["nodes": .array((prs[pr]!["lastComments"]?["nodes"]?.array ?? []) + [node])]
      var withBody = node.object!
      withBody["body"] = .string(body)
      bodies[id] = .object(withBody)
      return id
    }
  }

  /// Answers a REST GET of `target` with this status and body, in place of
  /// an earlier route for the same target. `target` is a path, without the
  /// leading slash, and optionally a query. A request matches when its path
  /// is the same and its query has each of the target's query items, so a
  /// route ignores the query items that it doesn't name.
  func route(
    _ target: String, status: Int = 200, etag: String? = nil, contentType: String = "application/json",
    _ body: String
  ) {
    let (path, query) = FakeGitHub.split(target)
    lock.withLock {
      routes.removeAll { $0.path == path && $0.query == query }
      routes.append((path, query, Route(status: status, body: body, etag: etag, contentType: contentType)))
    }
  }

  /// A path without its leading slash, percent-decoded, and its query items.
  static func split(_ target: String) -> (path: String, query: [String: String]) {
    let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    var path = String(parts[0])
    while path.hasPrefix("/") { path.removeFirst() }
    var query: [String: String] = [:]
    if parts.count > 1 {
      var c = URLComponents()
      c.percentEncodedQuery = String(parts[1])
      for item in c.queryItems ?? [] { query[item.name] = item.value ?? "" }
    }
    return (path.removingPercentEncoding ?? path, query)
  }

  static func issuePath(_ repo: String, _ number: Int) -> String { "repos/\(repo)/issues/\(number)" }

  static func contentsPath(_ repo: String, _ path: String) -> String { "repos/\(repo)/contents/\(path)" }

  /// Serves the issue at GET and PATCH /repos/{repo}/issues/{number}.
  func serveIssue(_ repo: String, _ number: Int, body: String) {
    lock.withLock {
      revision += 1
      issues[FakeGitHub.issuePath(repo, number)] = Issue(number: number, body: body, revision: revision)
    }
  }

  /// Changes the issue's body as a person who edits it on GitHub does.
  func editIssue(_ repo: String, _ number: Int, body: String) {
    lock.withLock {
      revision += 1
      let path = FakeGitHub.issuePath(repo, number)
      issues[path]!.body = body
      issues[path]!.revision = revision
    }
  }

  func issueBody(_ repo: String, _ number: Int) -> String? {
    lock.withLock { issues[FakeGitHub.issuePath(repo, number)]?.body }
  }

  /// Serves the file at GET and PUT /repos/{repo}/contents/{path} on
  /// `branch`. A GET whose ref names another branch gets a 404.
  func serveFile(_ repo: String, _ path: String, branch: String, content: String) {
    lock.withLock {
      revision += 1
      files[FakeGitHub.contentsPath(repo, path)] = File(
        path: path, branch: branch, content: content, revision: revision)
    }
  }

  /// Changes the file as another commit to its branch does.
  func editFile(_ repo: String, _ path: String, content: String) {
    lock.withLock {
      revision += 1
      let key = FakeGitHub.contentsPath(repo, path)
      files[key]!.content = content
      files[key]!.revision = revision
    }
  }

  func fileContent(_ repo: String, _ path: String) -> String? {
    lock.withLock { files[FakeGitHub.contentsPath(repo, path)]?.content }
  }

  /// Runs `action` once, after the fake answers the next GET of `path` and
  /// before it answers any other request, as a concurrent edit on GitHub
  /// does. `path` has no leading slash and no query.
  func afterNextGET(_ path: String, _ action: @escaping () -> Void) {
    lock.withLock { afterGET[path] = action }
  }

  /// Answers the next GET of `path` with `status` and no ETag, as a GitHub
  /// outage does. `path` has no leading slash and no query.
  func failNextGET(_ path: String, status: Int = 502) {
    lock.withLock { failingGETs[path] = status }
  }

  static func sha(_ revision: Int) -> String { String(format: "%040x", revision) }

  static func timestamp(_ revision: Int) -> String {
    let f = ISO8601DateFormatter()
    return f.string(from: Date(timeIntervalSince1970: 1_793_491_200 + Double(revision) * 60))
  }

  /// Base64 in lines of 60 characters, as the contents API sends it.
  static func wrappedBase64(_ text: String) -> String {
    let encoded = Data(text.utf8).base64EncodedString()
    var lines: [Substring] = []
    var rest = Substring(encoded)
    while !rest.isEmpty {
      lines.append(rest.prefix(60))
      rest = rest.dropFirst(60)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Answers the next GraphQL request with this reply instead.
  func reply(_ status: Int, headers: [String: String] = [:], _ body: String) {
    lock.withLock { queued.append(Reply(status: status, headers: headers, body: body)) }
  }

  // MARK: HTTP

  /// Answers one request on `client`. Returns true when `client` stays open as an event stream.
  private func handle(_ client: Int32) -> Bool {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    var requestLine = ""
    var headers: [String: String] = [:]
    var length = 0
    while true {
      let n = recv(client, &buffer, buffer.count, 0)
      if n <= 0 { return false }
      data.append(buffer, count: n)
      if headerEnd == nil, let range = data.range(of: separator) {
        headerEnd = range
        let lines = String(decoding: data[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        requestLine = lines.first ?? ""
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        length = Int(headers["content-length"] ?? "0") ?? 0
      }
      if let end = headerEnd, data.count - end.upperBound >= length { break }
    }
    // GET /repos/a/b/compare/x...y?per_page=1 HTTP/1.1
    let words = requestLine.split(separator: " ").map(String.init)
    let method = words.first ?? ""
    let target = words.count > 1 ? words[1] : ""
    let body = String(decoding: data[headerEnd!.upperBound...], as: UTF8.self)
    let (path, query) = FakeGitHub.split(target)
    let reply: Reply
    if FakeGitHub.isEventsPath(path) {
      guard let events = answerEvents(client, method: method, path: path, query: query, headers: headers, body: body)
      else { return true }
      reply = events
    } else if method == "POST", path == "graphql" {
      reply = answer(JSON.parse(body) ?? [:], authorization: headers["authorization"])
    } else {
      reply = answerREST(method: method, target: target, headers: headers, body: body)
    }
    var head = "HTTP/1.1 \(reply.status) Fake\r\n"
    if reply.headers.keys.allSatisfy({ $0.lowercased() != "content-type" }) {
      head += "Content-Type: application/json\r\n"
    }
    head += "Content-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
    for (k, v) in reply.headers { head += "\(k): \(v)\r\n" }
    try? UnixSocket.write(client, Data((head + "\r\n" + reply.body).utf8))
    return false
  }

  /// GitHub sends this Cache-Control with an authenticated REST answer.
  static let cacheControl = "private, max-age=60, s-maxage=60"

  static let notFound = Reply(status: 404, headers: [:], body: #"{"message":"Not Found","status":"404"}"#)

  private func answerREST(method: String, target: String, headers: [String: String], body: String) -> Reply {
    let (bare, query) = FakeGitHub.split(target)
    let ifNoneMatch = headers["if-none-match"]
    let (reply, after): (Reply, (() -> Void)?) = lock.withLock {
      restLog.append(
        RESTRequest(
          method: method, path: bare, query: query, ifNoneMatch: ifNoneMatch, body: body,
          authorization: headers["authorization"]))
      let reply: Reply
      if method == "GET", let status = failingGETs.removeValue(forKey: bare) {
        reply = Reply(status: status, headers: [:], body: #"{"message":"Server Error"}"#)
      } else if issues[bare] != nil {
        reply = answerIssue(bare, method: method, ifNoneMatch: ifNoneMatch, body: body)
      } else if files[bare] != nil {
        reply = answerFile(bare, method: method, query: query, ifNoneMatch: ifNoneMatch, body: body)
      } else {
        reply = answerRoute(bare, method: method, query: query, ifNoneMatch: ifNoneMatch)
      }
      return (reply, method == "GET" ? afterGET.removeValue(forKey: bare) : nil)
    }
    // The accept loop answers one request at a time, so the next request
    // sees this change.
    after?()
    return reply
  }

  /// A 200 with the ETag, or a 304 when If-None-Match has it. The caller
  /// holds the lock.
  private func conditional(_ etag: String, ifNoneMatch: String?, _ body: JSON) -> Reply {
    let headers = ["ETag": etag, "Cache-Control": FakeGitHub.cacheControl]
    if ifNoneMatch == etag { return Reply(status: 304, headers: headers, body: "") }
    return Reply(status: 200, headers: headers, body: body.text)
  }

  private func issueJSON(_ path: String) -> JSON {
    let issue = issues[path]!
    let repo = path.dropFirst("repos/".count).components(separatedBy: "/issues/")[0]
    return [
      "number": .number(Double(issue.number)), "title": "Plan", "state": "open", "body": .string(issue.body),
      "updated_at": .string(FakeGitHub.timestamp(issue.revision)),
      "html_url": .string("https://github.com/\(repo)/issues/\(issue.number)"),
    ]
  }

  private func answerIssue(_ path: String, method: String, ifNoneMatch: String?, body: String) -> Reply {
    switch method {
    case "GET":
      return conditional("\"issue-\(issues[path]!.revision)\"", ifNoneMatch: ifNoneMatch, issueJSON(path))
    case "PATCH":
      if let text = JSON.parse(body)?["body"]?.string {
        revision += 1
        issues[path]!.body = text
        issues[path]!.revision = revision
      }
      return Reply(status: 200, headers: [:], body: issueJSON(path).text)
    default:
      return FakeGitHub.notFound
    }
  }

  private func answerFile(_ path: String, method: String, query: [String: String], ifNoneMatch: String?, body: String)
    -> Reply
  {
    let file = files[path]!
    let sha = FakeGitHub.sha(file.revision)
    switch method {
    case "GET":
      guard query["ref"] == file.branch else { return FakeGitHub.notFound }
      let name = (file.path as NSString).lastPathComponent
      return conditional(
        "\"contents-\(file.revision)\"", ifNoneMatch: ifNoneMatch,
        [
          "type": "file", "encoding": "base64", "name": .string(name), "path": .string(file.path),
          "sha": .string(sha), "size": .number(Double(file.content.utf8.count)),
          "content": .string(FakeGitHub.wrappedBase64(file.content)),
        ])
    case "PUT":
      let request = JSON.parse(body) ?? [:]
      guard request["branch"]?.string == file.branch else {
        return Reply(status: 404, headers: [:], body: #"{"message":"Branch not found","status":"404"}"#)
      }
      guard let given = request["sha"]?.string else {
        return Reply(status: 422, headers: [:], body: #"{"message":"\"sha\" wasn't supplied.","status":"422"}"#)
      }
      guard given == sha else {
        return Reply(
          status: 409, headers: [:],
          body: JSON.object(["message": .string("\(file.path) does not match \(given)"), "status": "409"]).text)
      }
      guard let encoded = request["content"]?.string,
        let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
      else {
        return Reply(status: 422, headers: [:], body: #"{"message":"Invalid request.","status":"422"}"#)
      }
      revision += 1
      files[path]!.content = String(decoding: data, as: UTF8.self)
      files[path]!.revision = revision
      let name = (file.path as NSString).lastPathComponent
      let reply: JSON = [
        "content": ["name": .string(name), "path": .string(file.path), "sha": .string(FakeGitHub.sha(revision))],
        "commit": ["sha": .string("c" + FakeGitHub.sha(revision).dropFirst()), "message": request["message"] ?? ""],
      ]
      return Reply(status: 200, headers: [:], body: reply.text)
    default:
      return FakeGitHub.notFound
    }
  }

  private func answerRoute(_ bare: String, method: String, query: [String: String], ifNoneMatch: String?) -> Reply {
    let match = routes.last { r in
      r.path == bare && r.query.allSatisfy { query[$0.key] == $0.value }
    }
    guard method == "GET", let route = match?.route else { return FakeGitHub.notFound }
    var replyHeaders = ["Content-Type": route.contentType, "Cache-Control": FakeGitHub.cacheControl]
    if let etag = route.etag {
      replyHeaders["ETag"] = etag
      if route.status == 200, ifNoneMatch == etag {
        return Reply(status: 304, headers: replyHeaders.filter { $0.key != "Content-Type" }, body: "")
      }
    }
    return Reply(status: route.status, headers: replyHeaders, body: route.body)
  }

  private func answer(_ request: JSON, authorization: String?) -> Reply {
    let query = request["query"]?.string ?? ""
    let operation = query.firstMatch(of: #/^\s*query\s+(\w+)/#).map { String($0.1) }
    let variables = request["variables"]?.object ?? [:]
    let (reply, after): (Reply, (() -> Void)?) = lock.withLock {
      var data: [String: JSON] = ["rateLimit": ["cost": 1]]
      var errors: [JSON] = []
      let kind: String
      var ids: [String] = []
      // A `nodes(ids:)` answer: NOT_FOUND for an unknown id, and INTERNAL
      // for a failing one.
      func nodes(_ node: (String) -> JSON?, failing: (String) -> Bool) -> JSON {
        .array(
          ids.enumerated().map { i, id in
            let found = node(id)
            let type = found == nil ? "NOT_FOUND" : failing(id) ? "INTERNAL" : nil
            guard let found, type == nil else {
              errors.append(["type": .string(type!), "path": ["nodes", .number(Double(i))], "message": "Failed"])
              return .null
            }
            return found
          })
      }
      switch operation {
      case "CodeOwnersConfig":
        kind = "codeowners"
        let owner = variables["owner"]?.string ?? ""
        let repo = "\(owner)/\(variables["name"]?.string ?? "")"
        let base = variables["ref"]?.string ?? ""
        ids = ["\(repo):\(base)"]
        let lowercased = repo.lowercased()
        if failingCodeOwners.contains(lowercased) {
          data["repository"] = .null
          errors.append(["type": "INTERNAL", "path": ["repository"], "message": "Failed"])
        } else {
          data["repository"] = codeOwnersRepository(base, codeOwnerConfigs["\(lowercased):\(base)"], variables)
        }
      case "Files", "FilesPage":
        kind = PRQuery.files.rawValue
        let first = query.firstMatch(of: #/files\(first: (\d+)/#).flatMap { Int($0.1) } ?? 100
        let failing = failingPRs[.files, default: []]
        let page = { (id: String) -> JSON? in
          self.prs[id].map { self.filesNode($0, first: first, after: variables["after"]?.string) }
        }
        if let id = variables["id"]?.string {
          ids = [id]
          let found = page(id)
          if found == nil || failing.contains(prs[id]?["number"]?.int ?? 0) {
            errors.append(["type": found == nil ? "NOT_FOUND" : "INTERNAL", "path": ["node"], "message": "Failed"])
            data["node"] = .null
          } else {
            data["node"] = found!
          }
        } else {
          ids = variables["ids"]?.array?.compactMap(\.string) ?? []
          data["nodes"] = nodes(page, failing: { failing.contains(self.prs[$0]?["number"]?.int ?? 0) })
        }
      case "Issues":
        kind = "issues"
        data["viewer"] = ["login": .string(viewer)]
        for match in query.matches(of: #/([ro])(\d+): \w+\([^\n]*?first: (\d+)/#) {
          let alias = "\(match.1)\(match.2)"
          let i = String(match.2)
          let (repo, filter) = issueRequest(match.1 == "r", i, variables)
          ids.append(alias)
          if match.1 == "r", !listedRepos.contains(repo.lowercased()) {
            data[alias] = .null
            errors.append(["type": "NOT_FOUND", "path": [.string(alias)], "message": "Could not resolve"])
            continue
          }
          let matching = listedIssues.values.filter(filter).sorted { $0.updatedAt > $1.updatedAt }
          let start = variables["a\(i)"]?.string.flatMap(Int.init) ?? 0
          let page = Array(matching.dropFirst(start).prefix(Int(match.3) ?? 100))
          let end = start + page.count
          let connection: JSON = [
            "pageInfo": ["hasNextPage": .bool(end < matching.count), "endCursor": .string(String(end))],
            "nodes": .array(page.map(\.node)),
          ]
          data[alias] = match.1 == "r" ? ["issues": connection] : connection
        }
      case "Reference":
        kind = "reference"
        let repo = "\(variables["o"]?.string ?? "")/\(variables["n"]?.string ?? "")".lowercased()
        let key = "\(repo)#\(variables["num"]?.int ?? 0)"
        ids = [key]
        if !references.keys.contains(where: { $0.hasPrefix("\(repo)#") }) {
          data["repository"] = .null
          errors.append(["type": "NOT_FOUND", "path": ["repository"], "message": "Could not resolve to a Repository"])
        } else if let reference = references[key] {
          data["repository"] = ["issueOrPullRequest": reference.node]
        } else {
          data["repository"] = ["issueOrPullRequest": .null]
          errors.append(
            ["type": "NOT_FOUND", "path": ["repository", "issueOrPullRequest"], "message": "Could not resolve"])
        }
      case let name? where PRQuery.selecting[name] != nil:
        let prQuery = PRQuery.selecting[name]!
        let selection = Selection(query: query, on: "PullRequest", variables: variables)!
        kind = prQuery.rawValue
        ids = variables["ids"]?.array?.compactMap(\.string) ?? []
        let failing = failingPRs[prQuery, default: []]
        data["nodes"] = nodes(
          { prs[$0].map { selection.project(.object($0)) } },
          failing: { failing.contains(prs[$0]?["number"]?.int ?? 0) })
      case "Bodies":
        let selection = Selection(query: query, on: "IssueComment")!
        kind = "bodies"
        ids = variables["ids"]?.array?.compactMap(\.string) ?? []
        data["nodes"] = nodes({ bodies[$0].map(selection.project) }, failing: failingComments.contains)
      case "Lookup":
        kind = "lookup"
        var i = 0
        while let owner = variables["o\(i)"]?.string, let name = variables["n\(i)"]?.string {
          let repo = "\(owner)/\(name)"
          let mine = prs.values.filter { Dependencies.sameRepo($0["repository"]?["nameWithOwner"]?.string ?? "", repo) }
          if let branch = variables["b\(i)"]?.string {
            ids.append("\(repo):\(branch)")
            let found = mine.filter { $0["headRefName"]?.string == branch }
              .sorted { ($0["number"]?.int ?? 0) > ($1["number"]?.int ?? 0) }
              .map { pr -> JSON in
                ["id": pr["id"]!, "state": pr["state"]!, "headRepositoryOwner": ["login": .string(owner)]]
              }
            data["q\(i)"] = ["pullRequests": ["nodes": .array(found)]]
          } else if let number = variables["k\(i)"]?.int {
            ids.append("\(repo)#\(number)")
            let found = mine.first { $0["number"]?.int == number }
            data["q\(i)"] = ["pullRequest": found.map { ["id": $0["id"]!] } ?? .null]
          }
          i += 1
        }
      default:
        kind = "unknown"
        errors.append(["message": .string("FakeGitHub has no answer for operation \(operation ?? "(unnamed)")")])
      }
      log.append(Request(kind: kind, ids: ids, authorization: authorization, variables: variables))
      let after = kind == PRQuery.files.rawValue ? afterFiles.take() : nil
      if !queued.isEmpty { return (queued.removeFirst(), after) }
      // GitHub answers a validation error without data. sbd's request throws when data is missing or null.
      var response: [String: JSON] = ["data": kind == "unknown" ? .null : .object(data)]
      if !errors.isEmpty { response["errors"] = .array(errors) }
      return (Reply(status: 200, headers: [:], body: JSON.object(response).text), after)
    }
    // The accept loop answers one request at a time, so the next request
    // sees this change.
    after?()
    return reply
  }

  /// The repository of a codeowners answer. Each of the github, root, and
  /// docs aliases answers the file that its `<branch>:<path>` variable names.
  /// The caller holds the lock.
  private func codeOwnersRepository(_ base: String, _ config: CodeOwnerConfig?, _ variables: [String: JSON]) -> JSON {
    var repository: [String: JSON] = [
      "ref": [
        "branchProtectionRule": config?.protection ?? .null,
        "rules": ["totalCount": .number(Double(config?.rules.count ?? 0)), "nodes": .array(config?.rules ?? [])],
      ],
      "codeowners": config?.errors.map { ["errors": .array($0)] } ?? .null,
    ]
    for alias in ["github", "root", "docs"] {
      let expression = variables[alias]?.string ?? ""
      let text = expression.hasPrefix("\(base):") ? config?.files[String(expression.dropFirst(base.count + 1))] : nil
      repository[alias] = text.map { ["text": .string($0), "isTruncated": false, "isBinary": false] } ?? .null
    }
    return .object(repository)
  }

  /// One page of the PR's changed files, from the path at index `after`.
  /// The caller holds the lock.
  private func filesNode(_ pr: [String: JSON], first: Int, after: String?) -> JSON {
    let changed = changedFiles[pr["number"]?.int ?? 0] ?? ([], nil)
    let start = min(after.flatMap(Int.init) ?? 0, changed.paths.count)
    let end = min(start + first, changed.paths.count)
    return [
      "id": pr["id"] ?? .null, "headRefOid": pr["headRefOid"] ?? .null, "baseRefName": pr["baseRefName"] ?? .null,
      "files": [
        "totalCount": .number(Double(changed.totalCount ?? changed.paths.count)),
        "pageInfo": ["hasNextPage": .bool(end < changed.paths.count), "endCursor": .string(String(end))],
        "nodes": .array(changed.paths[start..<end].map { ["path": .string($0)] }),
      ],
    ]
  }

  // MARK: Event Streams

  /// The five event types of a PR subscription, sorted, as GitHub lists them.
  static let eventTypes = [checkSuiteEvent, headEvent, conflictEvent, reviewEvent, stateEvent]
  static let checkSuiteEvent = "com.github.pull_request.check_suite.status.changed.v1"
  static let headEvent = "com.github.pull_request.head.changed.v1"
  static let conflictEvent = "com.github.pull_request.merge_conflict.v1"
  static let reviewEvent = "com.github.pull_request.review.submitted.v1"
  static let stateEvent = "com.github.pull_request.state.changed.v1"

  /// GitHub's message for an account without Event Streams.
  static let eventsDisabledMessage = "Event subscriptions are not enabled for this account."

  static let eventsDisabled = Reply(
    status: 403, headers: [:],
    body: JSON.object([
      "message": .string(eventsDisabledMessage), "documentation_url": "https://docs.github.com/rest", "status": "403",
    ]).text)

  static let subscriptionLimitExceeded = Reply(
    status: 422, headers: [:],
    body:
      #"{"message":"Subscription limit exceeded.","documentation_url":"https://docs.github.com/rest","status":"422"}"#)

  /// A subscription of the Event Streams API.
  struct EventSubscription {
    var id: String
    /// The owner/name of the fake's PR.
    var repo: String
    var number: Int
    /// Sorted.
    var eventTypes: [String]
    /// The `resource_url` of the request that created it.
    var resourceURL: String
    var createdAt: Date
  }

  /// A client's open stream of one subscription's events.
  private struct EventStream {
    var fd: Int32
    var subscription: String
    var number: Int
  }

  static func isEventsPath(_ path: String) -> Bool {
    path == "event-subscriptions" || path.hasPrefix("event-subscriptions/")
  }

  /// Whether the account has Event Streams. Without it, every request to an event-subscriptions path gets GitHub's
  /// 403.
  var eventsEnabled: Bool {
    get { lock.withLock { eventsOn } }
    set { lock.withLock { eventsOn = newValue } }
  }

  /// How many subscriptions the account may hold. A create past it gets GitHub's 422.
  var subscriptionLimit: Int {
    get { lock.withLock { limit } }
    set { lock.withLock { limit = newValue } }
  }

  var subscriptions: [EventSubscription] { lock.withLock { eventSubscriptions } }

  /// The open streams. A stream whose client closed its end doesn't count.
  var openStreams: Int {
    streamLock.withLock {
      pruneStreams()
      return streams.count
    }
  }

  /// The open streams of PR `number`'s subscriptions.
  func openStreams(_ number: Int) -> Int {
    streamLock.withLock {
      pruneStreams()
      return streams.filter { $0.number == number }.count
    }
  }

  /// Writes one event of `type` to each open stream of PR `number`'s subscriptions, in the shape that GitHub
  /// sends. A check suite event carries `conclusion`, which is success by default.
  func emit(_ number: Int, type: String, conclusion: String? = nil) {
    let id = UUID().uuidString.lowercased()
    let repository = "https://api.github.com/repositories/\(number)"
    let suite = type == FakeGitHub.checkSuiteEvent
    var data: [String: JSON] = [:]
    switch type {
    case FakeGitHub.checkSuiteEvent:
      data["api_url"] = .string("\(repository)/check-suites/\(Int.random(in: 100_000_000...999_999_999))")
    case FakeGitHub.reviewEvent:
      data["api_url"] = .string("\(repository)/pulls/\(number)/reviews/\(Int.random(in: 100_000_000...999_999_999))")
    default:
      data["api_url"] = .string("\(repository)/pulls/\(number)")
    }
    if let conclusion = conclusion ?? (suite ? "success" : nil) { data["conclusion"] = .string(conclusion) }
    let schema = suite ? "pull-request-check-suite-status-changed" : "thin-resource-change"
    let event: JSON = [
      "specversion": "1.0", "id": .string(id), "source": .string(repository), "type": .string(type),
      "subject": .string("pulls/\(number)"), "datacontenttype": "application/json",
      "dataschema": .string("https://api.github.com/schemas/events/\(schema)/1.0.0/schema.json"),
      "time": .string(FakeGitHub.eventTime(Date())), "data": .object(data),
    ]
    let text = "id: \(id)\nevent: \(type)\ndata: \(event.text)\n\n"
    streamLock.withLock { writeStreams(FakeGitHub.chunk(text)) { $0.number == number } }
  }

  /// Closes every open stream without a github.stream.end, as a network failure does.
  func dropStreams() {
    streamLock.withLock {
      for stream in streams {
        shutdown(stream.fd, SHUT_RDWR)
        close(stream.fd)
      }
      streams = []
    }
  }

  /// Sends github.stream.end with `outcome` to the open streams of PR `number`, or to every open stream, and
  /// closes them. `subscription_ended` also deletes their subscriptions.
  func endStream(_ number: Int? = nil, outcome: String) {
    let matches = { (stream: EventStream) in number == nil || stream.number == number }
    lock.withLock {
      streamLock.withLock {
        if outcome == "subscription_ended" {
          let ended = Set(streams.filter(matches).map(\.subscription))
          eventSubscriptions.removeAll { ended.contains($0.id) || $0.number == number }
        }
        endStreams(where: matches, outcome: outcome, reason: nil)
      }
    }
  }

  /// Stops the keep-alive comments, so an open stream sends no bytes until an event.
  func stopKeepAlives() {
    streamLock.withLock { keepAlives = false }
  }

  /// Deletes PR `number`'s subscriptions, as their 24 hours running out does. Their open streams get
  /// github.stream.end with `subscription_ended` and the reason `expired`.
  func expire(_ number: Int) {
    lock.withLock {
      let ids = Set(eventSubscriptions.filter { $0.number == number }.map(\.id))
      eventSubscriptions.removeAll { ids.contains($0.id) }
      streamLock.withLock {
        endStreams(where: { ids.contains($0.subscription) }, outcome: "subscription_ended", reason: "expired")
      }
    }
  }

  /// Answers the next request to any event-subscriptions path with this status and body.
  func failNextEventRequest(_ status: Int, body: String) {
    lock.withLock { failingEventRequest = Reply(status: status, headers: [:], body: body) }
  }

  /// The answer to a request to an event-subscriptions path, or nil when the request opened a stream that keeps
  /// `client`.
  private func answerEvents(
    _ client: Int32, method: String, path: String, query: [String: String], headers: [String: String], body: String
  ) -> Reply? {
    lock.withLock { () -> Reply? in
      restLog.append(
        RESTRequest(
          method: method, path: path, query: query, ifNoneMatch: headers["if-none-match"], body: body,
          authorization: headers["authorization"]))
      if let reply = failingEventRequest.take() { return reply }
      guard eventsOn else { return FakeGitHub.eventsDisabled }
      let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      let found = parts.count > 1 ? eventSubscriptions.first(where: { $0.id == parts[1] }) : nil
      switch (method, parts.count) {
      case ("GET", 1):
        let list: JSON = ["subscriptions": .array(eventSubscriptions.map(subscriptionJSON))]
        return Reply(status: 200, headers: [:], body: list.text)
      case ("POST", 1):
        return createSubscription(body)
      case ("GET", 2):
        return found.map { Reply(status: 200, headers: [:], body: subscriptionJSON($0).text) } ?? FakeGitHub.notFound
      case ("DELETE", 2):
        guard let found else { return FakeGitHub.notFound }
        eventSubscriptions.removeAll { $0.id == found.id }
        streamLock.withLock {
          endStreams(where: { $0.subscription == found.id }, outcome: "subscription_ended", reason: "deleted")
        }
        return Reply(status: 204, headers: [:], body: "")
      case ("GET", 3) where parts[2] == "events":
        guard let found else { return FakeGitHub.notFound }
        openStream(client, found)
        return nil
      default:
        return FakeGitHub.notFound
      }
    }
  }

  /// The answer to POST /event-subscriptions. The caller holds the lock.
  private func createSubscription(_ body: String) -> Reply {
    let request = JSON.parse(body) ?? [:]
    let resource = request["resource_url"]?.string ?? ""
    let types = request["event_types"]?.array?.compactMap(\.string) ?? []
    guard let target = FakeGitHub.pullRequest(resource) else { return FakeGitHub.validationFailed("resource_url") }
    let unsupported = types.filter { !FakeGitHub.eventTypes.contains($0) }
    guard !types.isEmpty, unsupported.isEmpty else {
      return FakeGitHub.validationFailed(
        "event_types", message: "Unsupported event types: \(unsupported.joined(separator: ", "))")
    }
    let repo = target.repo.lowercased()
    guard
      let pr = prs.values.first(where: {
        ($0["repository"]?["nameWithOwner"]?.string ?? "").lowercased() == repo && $0["number"]?.int == target.number
      })
    else { return FakeGitHub.notFound }
    let sorted = Set(types).sorted()
    let same = eventSubscriptions.first {
      $0.repo.lowercased() == repo && $0.number == target.number && $0.eventTypes == sorted
    }
    if let same { return Reply(status: 200, headers: [:], body: subscriptionJSON(same).text) }
    guard eventSubscriptions.count < limit else { return FakeGitHub.subscriptionLimitExceeded }
    let id = "sub_" + (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    let subscription = EventSubscription(
      id: id, repo: pr["repository"]?["nameWithOwner"]?.string ?? target.repo, number: target.number,
      eventTypes: sorted, resourceURL: resource, createdAt: Date())
    eventSubscriptions.append(subscription)
    return Reply(status: 201, headers: [:], body: subscriptionJSON(subscription).text)
  }

  /// A subscription as GitHub answers it, with its URLs on the fake.
  private func subscriptionJSON(_ s: EventSubscription) -> JSON {
    let api = "\(url)/event-subscriptions/\(s.id)"
    return [
      "created_at": .string(FakeGitHub.eventTime(s.createdAt)), "event_types": .array(s.eventTypes.map(JSON.string)),
      "events_url": .string("\(api)/events"),
      "expires_at": .string(FakeGitHub.eventTime(s.createdAt.addingTimeInterval(86_400))), "id": .string(s.id),
      "resource_url": .string(s.resourceURL), "url": .string(api),
    ]
  }

  /// The owner/name and number of a PR's web URL, https://github.com/<owner>/<name>/pull/<number>.
  static func pullRequest(_ url: String) -> (repo: String, number: Int)? {
    let prefix = "https://github.com/"
    guard url.hasPrefix(prefix) else { return nil }
    let parts = url.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 4, !parts[0].isEmpty, !parts[1].isEmpty, parts[2] == "pull", let number = Int(parts[3]),
      number > 0
    else { return nil }
    return ("\(parts[0])/\(parts[1])", number)
  }

  private static func validationFailed(_ field: String, message: String? = nil) -> Reply {
    var error: [String: JSON] = ["resource": "EventSubscription", "field": .string(field), "code": "invalid"]
    if let message { error["message"] = .string(message) }
    let body: JSON = [
      "message": "Validation Failed", "errors": [.object(error)], "documentation_url": "https://docs.github.com/rest",
      "status": "422",
    ]
    return Reply(status: 422, headers: [:], body: body.text)
  }

  /// A time as GitHub writes it in Event Streams, with nine digits of fraction.
  static func eventTime(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    let whole = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    let nanos = Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000)
    return String(whole.dropLast()) + "." + String(format: "%09d", nanos) + "Z"
  }

  /// One chunk of a chunked answer. URLSession hands each chunk to sbd when it arrives.
  private static func chunk(_ text: String) -> Data {
    Data((String(text.utf8.count, radix: 16) + "\r\n" + text + "\r\n").utf8)
  }

  /// Answers a stream request with the stream's headers and keeps `client` open. The stream has no
  /// Content-Length. The caller holds the lock.
  private func openStream(_ client: Int32, _ subscription: EventSubscription) {
    let head =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
      + "X-Content-Type-Options: nosniff\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    streamLock.withLock {
      do {
        try UnixSocket.write(client, Data(head.utf8))
        streams.append(EventStream(fd: client, subscription: subscription.id, number: subscription.number))
      } catch {
        close(client)
      }
    }
  }

  /// Writes `data` to each matching stream, and closes a stream whose write fails. The caller holds `streamLock`.
  private func writeStreams(_ data: Data, where match: (EventStream) -> Bool) {
    var open: [EventStream] = []
    for stream in streams {
      if match(stream), (try? UnixSocket.write(stream.fd, data)) == nil {
        close(stream.fd)
      } else {
        open.append(stream)
      }
    }
    streams = open
  }

  /// Sends github.stream.end to each matching stream, ends its chunked answer, and closes it. The caller holds
  /// `streamLock`.
  private func endStreams(where match: (EventStream) -> Bool, outcome: String, reason: String?) {
    var data: [String: JSON] = ["outcome": .string(outcome)]
    if let reason { data["reason"] = .string(reason) }
    let end = FakeGitHub.chunk("event: github.stream.end\ndata: \(JSON.object(data).text)\n\n") + Data("0\r\n\r\n".utf8)
    for stream in streams where match(stream) {
      try? UnixSocket.write(stream.fd, end)
      close(stream.fd)
    }
    streams.removeAll(where: match)
  }

  /// Forgets the streams whose client closed its end. The caller holds `streamLock`.
  private func pruneStreams() {
    streams.removeAll { stream in
      guard UnixSocket.peerClosed(stream.fd) else { return false }
      close(stream.fd)
      return true
    }
  }

  private func keepStreamsAlive() {
    streamLock.withLock {
      pruneStreams()
      if keepAlives { writeStreams(FakeGitHub.chunk(": keep-alive\n\n")) { _ in true } }
    }
  }
}
