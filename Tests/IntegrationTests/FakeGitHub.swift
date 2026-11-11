import Foundation
import SwitchboardCore

/// A GitHub API on 127.0.0.1 for one test. It answers the poller's GraphQL
/// lookup, status, and body queries from the PR nodes and comment bodies that
/// Fixtures/github-*.json recorded, which a test can change between polls,
/// and its code owner queries from the configs and changed files that a test
/// sets. It
/// answers a REST GET from the routes that a test sets, and 404 for any other
/// path. It also serves issues and contents files that GET, PATCH, and PUT
/// change, as GitHub does. It records each request.
final class FakeGitHub {
  struct Request {
    /// lookup, status, base, bodies, codeowners, files, approvals, actions,
    /// or mergeDetails.
    var kind: String
    /// The node ids that a status, base, body, files, approvals, or actions query
    /// asked for, each lookup key as owner/name:branch or owner/name#number,
    /// or the owner/name:branch of a codeowners query.
    var ids: [String]
    var authorization: String?
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
  /// By owner/name:branch.
  private var codeOwnerConfigs: [String: CodeOwnerConfig] = [:]
  /// The repos whose codeowners query answers a null repository and an error.
  private var failingCodeOwners: Set<String> = []
  /// Each PR's changed files, by number, with the `totalCount` that GitHub
  /// reports when it differs from the number of paths.
  private var changedFiles: [Int: (paths: [String], totalCount: Int?)] = [:]
  /// What to run after the next files query.
  private var afterFiles: (() -> Void)?

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
    // The thread holds the fake weakly, so deinit closes the socket, which
    // ends the thread's accept.
    Thread.detachNewThread { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        self?.handle(client)
        close(client)
      }
    }
  }

  deinit { close(fd) }

  var url: String { "http://127.0.0.1:\(port)" }

  /// The GraphQL requests.
  var requests: [Request] { lock.withLock { log } }

  var restRequests: [RESTRequest] { lock.withLock { restLog } }

  /// The REST requests to `path`, whatever their query.
  func restRequests(to path: String) -> [RESTRequest] { restRequests.filter { $0.path == path } }

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

  /// Gives the PR one review thread for each value, resolved or not, and
  /// `totalCount` as GitHub's count when it differs.
  func reviewThreads(_ number: Int, resolved: [Bool], totalCount: Int? = nil) {
    change(number) {
      $0["reviewThreads"] = [
        "totalCount": .number(Double(totalCount ?? resolved.count)),
        "nodes": .array(resolved.map { ["isResolved": .bool($0)] }),
      ]
    }
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
      codeOwnerConfigs["\(repo):\(base)"] = CodeOwnerConfig(
        rules: rules, protection: protection, files: files, errors: errors)
    }
  }

  /// Makes each codeowners query for `repo` answer a null repository with an error.
  func failCodeOwners(repo: String) {
    lock.withLock { _ = failingCodeOwners.insert(repo) }
  }

  func recoverCodeOwners(repo: String) {
    lock.withLock { _ = failingCodeOwners.remove(repo) }
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
      let bot = author.hasSuffix("[bot]")
      let node: JSON = [
        "id": .string(id),
        "author": ["__typename": bot ? "Bot" : "User", "login": .string(bot ? String(author.dropLast(5)) : author)],
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

  /// The blob SHA that GET returns for the file now.
  func fileSHA(_ repo: String, _ path: String) -> String? {
    lock.withLock { files[FakeGitHub.contentsPath(repo, path)].map { FakeGitHub.sha($0.revision) } }
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

  private func handle(_ client: Int32) {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    var requestLine = ""
    var headers: [String: String] = [:]
    var length = 0
    while true {
      let n = recv(client, &buffer, buffer.count, 0)
      if n <= 0 { return }
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
    let reply: Reply
    if method == "POST" {
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
  }

  /// GitHub sends this Cache-Control with an authenticated REST answer.
  static let cacheControl = "private, max-age=60, s-maxage=60"

  static let notFound = Reply(status: 404, headers: [:], body: #"{"message":"Not Found","status":"404"}"#)

  private func answerREST(method: String, target: String, headers: [String: String], body: String) -> Reply {
    let (bare, query) = FakeGitHub.split(target)
    let ifNoneMatch = headers["if-none-match"]
    let (reply, after): (Reply, (() -> Void)?) = lock.withLock {
      restLog.append(RESTRequest(method: method, path: bare, query: query, ifNoneMatch: ifNoneMatch, body: body))
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
      if query.contains("codeowners(") {
        kind = "codeowners"
        let owner = variables["owner"]?.string ?? ""
        let repo = "\(owner)/\(variables["name"]?.string ?? "")"
        let base = variables["ref"]?.string ?? ""
        ids = ["\(repo):\(base)"]
        if failingCodeOwners.contains(repo) {
          data["repository"] = .null
          errors.append(["type": "INTERNAL", "path": ["repository"], "message": "Failed"])
        } else {
          data["repository"] = codeOwnersRepository(base, codeOwnerConfigs["\(repo):\(base)"], variables)
        }
      } else if query.contains("files(") {
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
      } else if let selection = Selection(query: query, on: "PullRequest") {
        let prQuery: PRQuery
        if query.contains("onBehalfOf(") {
          prQuery = .approvals
        } else if query.contains("reviewThreads(") {
          prQuery = .mergeDetails
        } else if query.contains("reviews(") {
          prQuery = .status
        } else if query.contains("checkSuites(") {
          prQuery = .actions
        } else {
          prQuery = .base
        }
        kind = prQuery.rawValue
        ids = variables["ids"]?.array?.compactMap(\.string) ?? []
        let failing = failingPRs[prQuery, default: []]
        data["nodes"] = nodes(
          { prs[$0].map { selection.project(.object($0)) } },
          failing: { failing.contains(prs[$0]?["number"]?.int ?? 0) })
      } else if let selection = Selection(query: query, on: "IssueComment") {
        kind = "bodies"
        ids = variables["ids"]?.array?.compactMap(\.string) ?? []
        data["nodes"] = nodes({ bodies[$0].map(selection.project) }, failing: failingComments.contains)
      } else {
        kind = "lookup"
        var i = 0
        while let owner = variables["o\(i)"]?.string, let name = variables["n\(i)"]?.string {
          let repo = "\(owner)/\(name)"
          let mine = prs.values.filter { $0["repository"]?["nameWithOwner"]?.string == repo }
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
      }
      log.append(Request(kind: kind, ids: ids, authorization: authorization))
      let after = kind == PRQuery.files.rawValue ? afterFiles.take() : nil
      if !queued.isEmpty { return (queued.removeFirst(), after) }
      var response: [String: JSON] = ["data": .object(data)]
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
}
