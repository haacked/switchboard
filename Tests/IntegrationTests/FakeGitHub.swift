import Foundation
import SwitchboardCore

/// A GitHub GraphQL endpoint on 127.0.0.1 for one test. It answers the
/// poller's lookup, status, and body queries from the PR nodes and comment
/// bodies that Fixtures/github-*.json recorded, which a test can change
/// between polls. It records each request.
final class FakeGitHub {
  struct Request {
    /// lookup, status, base, or bodies.
    var kind: String
    /// The node ids that a status or body query asked for, or each lookup
    /// key as owner/name:branch or owner/name#number.
    var ids: [String]
    var authorization: String?
  }

  struct Reply {
    var status: Int
    var headers: [String: String]
    var body: String
  }

  /// The two queries that ask for PR nodes.
  enum PRQuery: String {
    case status, base
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

  var requests: [Request] { lock.withLock { log } }

  static func recorded(_ name: String) throws -> [JSON] {
    let text = try String(contentsOfFile: "\(fixtures)/\(name)", encoding: .utf8)
    return JSON.parse(text)?["data"]?["nodes"]?.array ?? []
  }

  /// The first recorded PR node.
  static func recordedPR() -> JSON { (try? recorded("github-status.json").first) ?? .null }

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

  /// Forgets the PR, as GitHub does after a deletion.
  func remove(_ number: Int) {
    lock.withLock { prs = prs.filter { $0.value["number"]?.int != number } }
  }

  /// Makes the PR's node in a status or base query fail with an internal
  /// error, as GitHub sometimes does.
  func fail(_ number: Int, in query: PRQuery = .status) {
    lock.withLock { _ = failingPRs[query, default: []].insert(number) }
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

  /// Answers the next request with this reply instead.
  func reply(_ status: Int, headers: [String: String] = [:], _ body: String) {
    lock.withLock { queued.append(Reply(status: status, headers: headers, body: body)) }
  }

  // MARK: HTTP

  private func handle(_ client: Int32) {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    var headers: [String: String] = [:]
    var length = 0
    while true {
      let n = recv(client, &buffer, buffer.count, 0)
      if n <= 0 { return }
      data.append(buffer, count: n)
      if headerEnd == nil, let range = data.range(of: separator) {
        headerEnd = range
        let lines = String(decoding: data[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        length = Int(headers["content-length"] ?? "0") ?? 0
      }
      if let end = headerEnd, data.count - end.upperBound >= length { break }
    }
    let body = data[headerEnd!.upperBound...]
    let request = JSON.parse(String(decoding: body, as: UTF8.self)) ?? [:]
    let reply = answer(request, authorization: headers["authorization"])
    var head = "HTTP/1.1 \(reply.status) Fake\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
    for (k, v) in reply.headers { head += "\(k): \(v)\r\n" }
    try? UnixSocket.write(client, Data((head + "\r\n" + reply.body).utf8))
  }

  private func answer(_ request: JSON, authorization: String?) -> Reply {
    let query = request["query"]?.string ?? ""
    let variables = request["variables"]?.object ?? [:]
    return lock.withLock {
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
      if query.contains("... on PullRequest") {
        let selection = Selection(query: query, on: "PullRequest")!
        let prQuery: PRQuery = query.contains("reviews(") ? .status : .base
        kind = prQuery.rawValue
        ids = variables["ids"]?.array?.compactMap(\.string) ?? []
        let failing = failingPRs[prQuery, default: []]
        data["nodes"] = nodes({ prs[$0].map { selection.project(.object($0)) } }, failing: { failing.contains(prs[$0]?["number"]?.int ?? 0) })
      } else if query.contains("... on IssueComment") {
        kind = "bodies"
        ids = variables["ids"]?.array?.compactMap(\.string) ?? []
        data["nodes"] = nodes({ bodies[$0] }, failing: failingComments.contains)
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
      if !queued.isEmpty { return queued.removeFirst() }
      var response: [String: JSON] = ["data": .object(data)]
      if !errors.isEmpty { response["errors"] = .array(errors) }
      return Reply(status: 200, headers: [:], body: JSON.object(response).text)
    }
  }
}
