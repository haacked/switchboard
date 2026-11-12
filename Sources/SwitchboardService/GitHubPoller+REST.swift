import Foundation
import SwitchboardCore

/// The poller's REST requests to the GitHub API.
extension GitHubPoller {
  /// A REST answer with its status, ETag, and JSON.
  struct RESTReply {
    var status: Int
    var etag: String?
    var json: JSON?
  }

  /// Sends one REST request. A request with `etag` gets a 304 when nothing changed.
  /// A non-empty `query` replaces any query that `path` carries.
  func rest(
    _ method: String, _ path: String, query: [String: String] = [:], etag: String? = nil, body: JSON? = nil,
    stats: inout Stats
  ) throws -> RESTReply {
    var req = try apiRequest(path)
    if !query.isEmpty, let url = req.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
      req.url = c.url
    }
    req.httpMethod = method
    if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = Data(body.text.utf8)
    }
    let (status, headers, _, json) = try send(req, stats: &stats)
    return RESTReply(status: status, etag: headers["etag"], json: json)
  }

  /// Sends a REST GET and returns its JSON. Anything but a 200 is an error.
  func get(_ path: String, stats: inout Stats) throws -> JSON {
    let reply = try rest("GET", path, stats: &stats)
    guard reply.status == 200, let json = reply.json else {
      throw APIError("GitHub answered \(reply.status) for \(path) \(GitHub.message(reply.json))")
    }
    return json
  }

  func failure(_ reply: RESTReply, _ what: String) -> APIError {
    APIError("GitHub answered \(reply.status) for \(what): \(GitHub.message(reply.json))")
  }
}
