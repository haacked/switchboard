import Foundation
import SwitchboardCore
import os

/// The requests and GraphQL points that a caller spent. `GitHubClient` adds to it as it sends.
protocol GitHubCost {
  var requests: Int { get set }
  var points: Int { get set }
}

/// Sends requests to GitHub's API with the user's `gh` token. Every caller shares one token, the 401 retry, the
/// rate limit pauses, and the usage counts. A request can run off the caller's queue, so the state sits behind
/// locks. No request or `gh` call runs while a lock is held.
final class GitHubClient {
  let settings: GitHubSettings

  private struct HTTPState {
    var token: String?
    /// After GitHub's rate limit, no request to that quota goes out before
    /// this time. GitHub counts GraphQL and REST (`core`) requests separately.
    /// Other `gh` calls with the same token spend `core`.
    var graphQLPausedUntil: Int64 = 0
    var restPausedUntil: Int64 = 0
  }
  private let http = OSAllocatedUnfairLock(initialState: HTTPState())
  /// The requests and points since sbd started.
  private let usage = OSAllocatedUnfairLock(initialState: GitHubUsage(since: nowMs()))

  /// Sends one HTTP request and returns the status, the headers, and the body. Tests replace it.
  var transport: (URLRequest) throws -> (Int, [String: String], Data) = httpRequest

  init(settings: GitHubSettings) {
    self.settings = settings
  }

  var graphQLPausedUntil: Int64 { http.withLock { $0.graphQLPausedUntil } }

  /// The later of the GraphQL and REST pauses.
  var pausedUntil: Int64 { http.withLock { max($0.graphQLPausedUntil, $0.restPausedUntil) } }

  /// The GitHub requests and points since sbd started.
  func usageReport() -> GitHubUsage.Report { usage.withLock { $0 }.report(now: nowMs()) }

  /// Shares a request's cost among the PRs it read, as `GitHubUsage.share` does.
  func share(requests: Int, points: Int, among served: [GitHubUsage.Read], countsReads: Bool) {
    usage.withLock { $0.share(requests: requests, points: points, among: served, countsReads: countsReads) }
  }

  /// Sends one GraphQL request and returns the response, whose `data` isn't
  /// null.
  func request(_ query: String, _ variables: JSON, stats: inout some GitHubCost) throws -> JSON {
    var req = try apiRequest("graphql")
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(JSON.object(["query": .string(query), "variables": variables]).text.utf8)
    let (status, _, _, json) = try send(req, stats: &stats)
    guard status == 200, let json, let data = json["data"], data != .null else {
      throw APIError("GitHub answered \(status) \(GitHub.message(json))")
    }
    if json["errors"] != nil { logLine("github: \(GitHub.message(json))") }
    let cost = data["rateLimit"]?["cost"]?.int ?? 0
    stats.points += cost
    usage.withLock { $0.points += cost }
    return json
  }

  /// A request to `path` under the API base.
  func apiRequest(_ path: String) throws -> URLRequest {
    guard let url = URL(string: "\(settings.url)/\(path)") else { throw APIError("bad github url \(settings.url)") }
    // URLSession's cache would answer a conditional request itself and hide the 304.
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
  }

  /// Sends the request with the token, and returns the status, the headers
  /// with lowercase names, the body, and the body as JSON. A 401 gets a new
  /// token from gh and one retry. A rate limit pauses the requests to the
  /// same quota, GraphQL or REST, for as long as `GitHub.rateLimit` says.
  func send(_ request: URLRequest, stats: inout some GitHubCost) throws -> (
    status: Int, headers: [String: String], body: Data, json: JSON?
  ) {
    let graphQL = request.url?.lastPathComponent == "graphql"
    func attempt() throws -> (Int, [String: String], Data) {
      let req = try authorized(request, graphQL: graphQL)
      stats.requests += 1
      return try transport(req)
    }
    var (status, headers, body) = try attempt()
    if status == 401 {
      dropToken()
      (status, headers, body) = try attempt()
    }
    let json = JSON.parse(String(decoding: body, as: UTF8.self))
    if pauses(after: status, headers: headers, json: json, graphQL: graphQL) {
      throw APIError("GitHub rate limit: \(GitHub.message(json))")
    }
    return (status, headers, body, json)
  }

  /// A GET of an Event Streams stream, with the token. A stream answers as it goes, so `send` can't run it: the
  /// caller opens it and passes a failed answer to `streamFailed`. It throws while the REST quota is paused.
  func streamRequest(_ path: String, idleTimeout: TimeInterval) throws -> URLRequest {
    var req = try apiRequest(path)
    req.timeoutInterval = idleTimeout
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    return try authorized(req, graphQL: false)
  }

  /// The request with the token, counted in the usage. It throws while the request's quota is paused.
  private func authorized(_ request: URLRequest, graphQL: Bool) throws -> URLRequest {
    if http.withLock({ graphQL ? $0.graphQLPausedUntil : $0.restPausedUntil }) > nowMs() {
      throw APIError("paused after a GitHub \(graphQL ? "GraphQL" : "core") rate limit")
    }
    var req = request
    req.setValue("bearer \(try currentToken())", forHTTPHeaderField: "Authorization")
    usage.withLock { $0.requests += 1 }
    return req
  }

  /// Takes a stream's answer that isn't 200. A 401 drops the token, so the next request gets a new one from gh. A
  /// rate limit pauses the REST quota. Returns whether the answer was a rate limit.
  func streamFailed(status: Int, headers: [String: String], json: JSON?) -> Bool {
    if status == 401 { dropToken() }
    return pauses(after: status, headers: headers, json: json, graphQL: false)
  }

  private func dropToken() { http.withLock { $0.token = nil } }

  /// Pauses the requests to the answer's quota for as long as `GitHub.rateLimit` says, and returns whether the
  /// answer was a rate limit.
  private func pauses(after status: Int, headers: [String: String], json: JSON?, graphQL: Bool) -> Bool {
    let limit = GitHub.rateLimit(status: status, headers: headers, response: json, now: Date().timeIntervalSince1970)
    if let pause = limit.pause {
      let until = nowMs() + Int64(pause * 1000)
      // Requests run at once, so a later answer must not shorten the pause that an earlier one set.
      http.withLock {
        if graphQL {
          $0.graphQLPausedUntil = max($0.graphQLPausedUntil, until)
        } else {
          $0.restPausedUntil = max($0.restPausedUntil, until)
        }
      }
    }
    return limit.limited
  }

  private func currentToken() throws -> String {
    if let token = http.withLock({ $0.token }) { return token }
    guard let gh = findExecutable(settings.gh) else { throw APIError("can't find \(settings.gh)") }
    let r = try runCommand(gh, ["auth", "token"])
    let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard r.status == 0, !t.isEmpty else {
      throw APIError("gh auth token failed: \(oneLine(r.stderr, max: 120))")
    }
    http.withLock { $0.token = t }
    return t
  }
}
