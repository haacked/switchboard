import Foundation
import SwitchboardCore

/// Depot's Connect API on 127.0.0.1 for one test. It answers ListRuns and
/// GetRunStatus from the responses that Fixtures/depot-*.json recorded, which
/// a test can change between polls. It records each request.
final class FakeDepot {
  struct Request {
    /// ListRuns or GetRunStatus, or the path's last part for another call.
    var method: String
    var body: JSON
    var authorization: String?
    var org: String?
  }

  struct Reply {
    var status: Int
    var body: String
  }

  static let service = "depot.ci.v1.CIService"
  /// The PR whose runs Fixtures/depot-runs.json recorded.
  static let recordedRepo = "PostHog/posthog"
  static let recordedPR = 127964
  /// The run and head commit of Fixtures/depot-status-failed.json.
  static let failedRun = "jtrfd10d8p"
  static let failedHead = "4c4295abbbc12c11be1407d5e10705cb74cf28fd"
  /// The run of Fixtures/depot-status-running.json, which no recorded listing names.
  static let runningRun = "bts9lt0vbr"
  /// The failed jobs of `failedRun`, in the response's order.
  static let failedJobs = [
    "Django Tests Pass on Depot",
    "Django tests – Core (persons-on-events on, events schema legacy), Py 3.14.7, clickhouse/clickhouse-server:26.6.2 (6/10)",
    "Django tests – Core json-targets (persons-on-events on, events schema json), Py 3.14.7, clickhouse/clickhouse-server:26.6.2 (7/9)",
  ]

  private let fd: Int32
  let port: Int
  /// The token that the fake accepts. Any other gets Depot's 401.
  let token: String
  private let lock = NSLock()
  /// Each PR's runs, newest first, by `owner/name#number`.
  private var runs: [String: [JSON]] = [:]
  /// Each run's GetRunStatus response, by run id.
  private var statuses: [String: JSON] = [:]
  private var log: [Request] = []
  private var queued: [Reply] = []
  /// Makes each added run newer than the recorded ones and the runs added before it.
  private var added = 0

  init(token: String = "depot-token-1") throws {
    self.token = token
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
    runs[FakeDepot.key(FakeDepot.recordedRepo, FakeDepot.recordedPR)] =
      try FakeDepot.recorded("depot-runs.json")["runs"]?.array ?? []
    statuses[FakeDepot.failedRun] = try FakeDepot.recorded("depot-status-failed.json")
    statuses[FakeDepot.runningRun] = try FakeDepot.recorded("depot-status-running.json")
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

  func requests(_ method: String) -> [Request] { requests.filter { $0.method == method } }

  static func recorded(_ name: String) throws -> JSON {
    let text = try String(contentsOfFile: "\(FakeGitHub.fixtures)/\(name)", encoding: .utf8)
    guard let json = JSON.parse(text) else { throw TestError(description: "can't parse \(name)") }
    return json
  }

  static func key(_ repo: String, _ number: Int) -> String { "\(repo.lowercased())#\(number)" }

  /// Gives the PR these runs, newest first. An empty list makes ListRuns
  /// answer `{}`, as Depot does for a PR without runs.
  func setRuns(_ repo: String, _ number: Int, _ list: [JSON]) {
    lock.withLock { runs[FakeDepot.key(repo, number)] = list }
  }

  /// Gives the PR the recorded runs of PostHog/posthog#127964 as they stood
  /// when the failed run was the newest.
  func useRecordedRuns(for repo: String, _ number: Int) throws {
    let runs = try FakeDepot.recorded("depot-runs.json")["runs"]?.array ?? []
    setRuns(repo, number, Array(runs.drop { $0["runId"]?.string != FakeDepot.failedRun }))
  }

  /// Adds a run of `headSha` as the PR's newest.
  func addRun(_ repo: String, _ number: Int, id: String, headSha: String, status: String = "running") {
    lock.withLock {
      added += 1
      let run: JSON = [
        "runId": .string(id), "repo": .string(repo), "trigger": "pull_request", "sha": .string("merge-\(id)"),
        "status": .string(status), "createdAt": .string(String(format: "2030-01-01T00:%02d:00Z", added)),
        "ref": .string("refs/pull/\(number)/merge"), "headSha": .string(headSha),
      ]
      runs[FakeDepot.key(repo, number), default: []].insert(run, at: 0)
    }
  }

  /// Answers GetRunStatus for `runId` with the recorded response in `file`,
  /// under that run id. `status` replaces the run's status there and in the
  /// listings. `edit` changes each job before the fake serves it.
  func setStatus(
    _ runId: String, from file: String, status: String? = nil, editingJobs edit: ((inout [String: JSON]) -> Void)? = nil
  ) throws {
    var response = try FakeDepot.recorded(file).object ?? [:]
    response["runId"] = .string(runId)
    if let status {
      response["status"] = .string(status)
      lock.withLock {
        for (pr, list) in runs {
          runs[pr] = list.map { run in
            guard run["runId"]?.string == runId, var o = run.object else { return run }
            o["status"] = .string(status)
            return .object(o)
          }
        }
      }
    }
    if let edit {
      response["workflows"] = .array(
        (response["workflows"]?.array ?? []).map { workflow in
          var w = workflow.object ?? [:]
          w["jobs"] = .array(
            (w["jobs"]?.array ?? []).map { job in
              var o = job.object ?? [:]
              edit(&o)
              return .object(o)
            })
          return .object(w)
        })
    }
    lock.withLock { statuses[runId] = .object(response) }
  }

  /// Answers the next request with this reply instead.
  func reply(_ status: Int, _ body: String) {
    lock.withLock { queued.append(Reply(status: status, body: body)) }
  }

  // MARK: HTTP

  private func handle(_ client: Int32) {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    var path = ""
    var headers: [String: String] = [:]
    var length = 0
    while true {
      let n = recv(client, &buffer, buffer.count, 0)
      if n <= 0 { return }
      data.append(buffer, count: n)
      if headerEnd == nil, let range = data.range(of: separator) {
        headerEnd = range
        let lines = String(decoding: data[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        length = Int(headers["content-length"] ?? "0") ?? 0
      }
      if let end = headerEnd, data.count - end.upperBound >= length { break }
    }
    let body = JSON.parse(String(decoding: data[headerEnd!.upperBound...], as: UTF8.self)) ?? .null
    let reply = answer(path: path, body: body, headers: headers)
    var head = "HTTP/1.1 \(reply.status) Fake\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
    try? UnixSocket.write(client, Data((head + "\r\n" + reply.body).utf8))
  }

  private func answer(path: String, body: JSON, headers: [String: String]) -> Reply {
    let method = path.split(separator: "/").last.map(String.init) ?? ""
    return lock.withLock {
      log.append(
        Request(method: method, body: body, authorization: headers["authorization"], org: headers["x-depot-org"]))
      if !queued.isEmpty { return queued.removeFirst() }
      guard headers["authorization"] == "Bearer \(token)" else {
        return Reply(status: 401, body: #"{"code":"unauthenticated","message":"Invalid token"}"#)
      }
      guard path.hasPrefix("/\(FakeDepot.service)/") else {
        return Reply(status: 404, body: #"{"code":"unimplemented","message":"no such method"}"#)
      }
      switch method {
      case "ListRuns":
        // Connect JSON sends an int64 as a string.
        let number = body["pr"]?.int ?? body["pr"]?.string.flatMap { Int($0) } ?? 0
        // Without a status filter, Depot lists only queued and running runs.
        let wanted = Set(body["status"]?.array?.compactMap(\.string) ?? [])
        let list = (runs[FakeDepot.key(body["repo"]?.string ?? "", number)] ?? []).filter {
          (wanted.isEmpty ? ["queued", "running"] : wanted).contains($0["status"]?.string ?? "")
        }
        return Reply(status: 200, body: list.isEmpty ? "{}" : JSON.object(["runs": .array(list)]).text)
      case "GetRunStatus":
        guard let status = body["runId"]?.string.flatMap({ statuses[$0] }) else {
          return Reply(status: 404, body: #"{"code":"not_found","message":"run not found"}"#)
        }
        return Reply(status: 200, body: status.text)
      default:
        return Reply(status: 404, body: #"{"code":"unimplemented","message":"no such method"}"#)
      }
    }
  }
}
