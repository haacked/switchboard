import Foundation
import SwitchboardCore
import Testing
import os

@testable import SwitchboardService

// These tests never move `Clock`. It is global to the test process, so a move would shift the time of every test
// that runs beside them. The integration suite `RefDetailsTests` covers the TTLs with sbd's own clock.

private let repo = "acme/widgets"

/// A gh that logs each call beside itself and answers `auth token` with `token-<n>`, where n counts the calls.
private let fakeGh = """
  #!/bin/sh
  log="$(dirname "$0")/gh-calls.log"
  printf '%s\\n' "$*" >>"$log"
  [ "$1 $2" = "auth token" ] || exit 1
  echo "token-$(wc -l <"$log" | tr -d ' ')"
  """

/// The `issueOrPullRequest` node of an open issue.
private func issueNode(_ number: Int, title: String = "Fetched title", in repo: String = repo) -> JSON {
  [
    "__typename": "Issue", "number": .number(Double(number)), "title": .string(title),
    "url": .string("https://github.com/\(repo)/issues/\(number)"), "state": "OPEN",
    "createdAt": "2026-11-01T10:00:00Z", "updatedAt": "2026-11-10T10:00:00Z", "author": ["login": "robin-k"],
    "labels": ["nodes": [["name": "bug"]]],
  ]
}

/// GitHub's GraphQL endpoint on 127.0.0.1, for the reference query only. It answers each connection on its own
/// thread, so requests overlap as they do against GitHub. It reads the item from the variables `o`, `n`, and `num`,
/// as `GitHub.referenceQuery` names them, and records each request.
private final class FakeReferenceAPI {
  struct Logged {
    /// The lowercase owner/name#N that the variables name.
    var key: String
    var authorization: String?
  }

  struct Reply {
    var status: Int
    var headers: [String: String] = [:]
    var body: String
    /// Seconds that the fake waits before it answers.
    var delay: Double = 0
  }

  private let fd: Int32
  let port: Int
  private let lock = NSLock()
  private var items: [String: JSON] = [:]
  private var log: [Logged] = []
  private var unauthorized = 0
  private var queued: [Reply] = []
  private var holding = false
  private let released = DispatchSemaphore(value: 0)

  init() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
        bind(listener, p, len) == 0 && listen(listener, 64) == 0 && getsockname(listener, p, &len) == 0
      }
    }
    guard bound else {
      close(listener)
      throw APIError("can't listen on 127.0.0.1")
    }
    fd = listener
    port = Int(UInt16(bigEndian: addr.sin_port))
    // The thread holds the fake weakly, so deinit closes the socket, which ends the accept.
    Thread.detachNewThread { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        Thread.detachNewThread { [weak self] in
          self?.handle(client)
          close(client)
        }
      }
    }
  }

  deinit {
    release()
    close(fd)
  }

  var url: String { "http://127.0.0.1:\(port)" }

  var requests: [Logged] { lock.withLock { log } }

  func put(_ number: Int, _ node: JSON, in repo: String = repo) {
    lock.withLock { items["\(repo.lowercased())#\(number)"] = node }
  }

  /// Answers the next request with 401, as GitHub does for an expired token.
  func unauthorizeNext() { lock.withLock { unauthorized += 1 } }

  /// Answers the next request with this reply.
  func queue(_ reply: Reply) { lock.withLock { queued.append(reply) } }

  /// Holds every answer until `release`. Each request is logged as it arrives.
  func hold() { lock.withLock { holding = true } }

  func release() {
    let wasHolding = lock.withLock {
      defer { holding = false }
      return holding
    }
    // A held request waits on the semaphore. A count well above any test's callers frees every one of them.
    if wasHolding { for _ in 0..<64 { released.signal() } }
  }

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
    let request = JSON.parse(String(decoding: data[headerEnd!.upperBound...], as: UTF8.self)) ?? [:]
    let reply = answer(request, authorization: headers["authorization"])
    var head = "HTTP/1.1 \(reply.status) Fake\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
    for (k, v) in reply.headers { head += "\(k): \(v)\r\n" }
    try? UnixSocket.write(client, Data((head + "\r\n" + reply.body).utf8))
  }

  private func answer(_ request: JSON, authorization: String?) -> Reply {
    let variables = request["variables"]
    let owner = variables?["o"]?.string ?? ""
    let name = variables?["n"]?.string ?? ""
    let number = variables?["num"]?.int ?? 0
    let key = "\(owner)/\(name)#\(number)".lowercased()
    let (reply, held): (Reply, Bool) = lock.withLock {
      log.append(Logged(key: key, authorization: authorization))
      if unauthorized > 0 {
        unauthorized -= 1
        return (Reply(status: 401, body: #"{"message":"Bad credentials"}"#), holding)
      }
      if !queued.isEmpty { return (queued.removeFirst(), holding) }
      let repository: JSON
      if !items.keys.contains(where: { $0.hasPrefix("\(owner)/\(name)#".lowercased()) }) {
        repository = .null
      } else {
        repository = ["issueOrPullRequest": items[key] ?? .null]
      }
      var response: [String: JSON] = ["data": ["rateLimit": ["cost": 1], "repository": repository]]
      if repository == .null || repository["issueOrPullRequest"] == .null {
        response["errors"] = [["type": "NOT_FOUND", "path": ["repository"], "message": "Could not resolve"]]
      }
      return (Reply(status: 200, body: JSON.object(response).text), holding)
    }
    if held { released.wait() }
    if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
    return reply
  }
}

/// A `Service` in a temporary home that never loads, so it starts no tmux server and no claude. Its GitHub poller
/// asks `api` and runs `fakeGh` for tokens. With `poller` false, the service has no poller, as when GitHub is off.
private final class Harness {
  let home: Home
  let api: FakeReferenceAPI
  let service: Service

  init(poller: Bool = true) throws {
    home = Home(path: try makeShortTempFolder())
    api = try FakeReferenceAPI()
    let gh = "\(home.path)/gh"
    try fakeGh.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    let config: JSON = [
      "claude": "/usr/bin/false", "github": ["gh": .string(gh), "url": .string(api.url), "pollSeconds": 0],
      "depot": ["enabled": false], "trunk": ["path": .string("\(home.path)/trunk")],
    ]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
    service = try Service(home: home, sbPath: "/usr/bin/true")
    if poller {
      service.github = GitHubPoller(
        service: service, settings: service.config.github, depot: service.config.depot, trunk: service.config.trunk)
    }
  }

  deinit { try? FileManager.default.removeItem(atPath: home.path) }

  /// The `gh` calls that `fakeGh` logged.
  var ghCalls: Int {
    let text = (try? String(contentsOfFile: "\(home.path)/gh-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").count
  }

  /// Adds a session whose PR the poller read at `polled`, in milliseconds since the epoch.
  func addSession(_ id: String, pr: PullRequest, polled: Int64? = nil) {
    service.queue.sync {
      let s = Session(id: id, name: id, cwd: home.path, claudeSessionId: "uuid-\(id)", created: 0)
      var entry = Service.Entry(session: s)
      entry.facts.pr = pr
      entry.facts.prRead = polled
      service.entries[id] = entry
    }
  }

  func cache(_ issues: [InboxIssue]) {
    service.queue.sync { service.issueCache.issues += issues }
  }

  func call(_ args: JSON) -> Response { service.handle(Request(op: "ref-details", args: args)) }

  /// The reply's fields, without nulls. It fails the test when the op fails.
  func details(_ args: JSON) throws -> [String: JSON] {
    let r = call(args)
    try #require(r.ok, "ref-details \(args.text) failed: \(r.error ?? "")")
    return try #require(r.result?.object, "ref-details answered \(r.result?.text ?? "nothing")").filter {
      $0.value != .null
    }
  }

  func details(_ ref: String) throws -> [String: JSON] { try details(["ref": .string(ref)]) }

  /// The op's error message. It fails the test when the op answers.
  func refusal(_ args: JSON) throws -> String {
    let r = call(args)
    try #require(!r.ok, "ref-details \(args.text) answered \(r.result?.text ?? "")")
    return r.error ?? ""
  }

  func refusal(_ ref: String) throws -> String { try refusal(["ref": .string(ref)]) }
}

private func pullRequest(_ number: Int, in repo: String = repo, title: String = "Polled title") -> PullRequest {
  PullRequest(
    id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo, title: title,
    labels: ["bug"], checks: "SUCCESS", author: "robin-k")
}

private func inboxIssue(_ number: Int, in repo: String = repo, title: String = "Cached title") -> InboxIssue {
  InboxIssue(
    repo: repo, number: number, title: title, url: "https://github.com/\(repo)/issues/\(number)", labels: ["bug"],
    author: "robin-k", createdAt: "2026-11-01T10:00:00Z", updatedAt: "2026-11-10T10:00:00Z", sources: [repo])
}

/// Runs `body` for each index on its own thread, all at once, and returns the results in index order.
private func concurrently<T>(_ count: Int, _ body: @escaping (Int) -> T) throws -> [T] {
  let results = OSAllocatedUnfairLock<[Int: T]>(uncheckedState: [:])
  let group = DispatchGroup()
  for i in 0..<count {
    group.enter()
    Thread.detachNewThread {
      let result = body(i)
      results.withLockUnchecked { $0[i] = result }
      group.leave()
    }
  }
  try #require(group.wait(timeout: .now() + 60) == .success, "the calls did not finish in 60 s")
  return results.withLockUnchecked { all in (0..<count).map { all[$0]! } }
}

/// On its own thread: waits until the fake has logged more than `logged` requests, or 10 s, then gives the callers
/// 0.5 s to reach the op and send their requests, then frees the fake. A failed `#require` on that thread would
/// belong to no test, so it only gives up.
private func releaseLater(_ api: FakeReferenceAPI, after logged: Int = 0) {
  Thread.detachNewThread {
    let deadline = Date().addingTimeInterval(10)
    while api.requests.count <= logged, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    Thread.sleep(forTimeInterval: 0.5)
    api.release()
  }
}

@Suite struct ReferenceDetailsServiceTests {

  // MARK: Harness controls

  /// The poller reaches the fake and reads its answer. A failure here is the harness, not `ref-details`.
  @Test func controlThePollerReachesTheFake() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    var stats = GitHubPoller.Stats()

    let response = try h.service.github!.client.request(
      GitHub.referenceQuery, ["o": "acme", "n": "widgets", "num": 7], stats: &stats)

    #expect(response["data"]?["repository"]?["issueOrPullRequest"]?["title"] == "Fetched title")
    #expect(h.api.requests.map(\.key) == ["acme/widgets#7"])
  }

  /// A 401 gets a new token from the fake gh and one retry.
  @Test func controlA401RunsGhOnceMoreAndRetries() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.unauthorizeNext()
    var stats = GitHubPoller.Stats()

    _ = try h.service.github!.client.request(
      GitHub.referenceQuery, ["o": "acme", "n": "widgets", "num": 7], stats: &stats)

    #expect(h.ghCalls == 2)
    #expect(h.api.requests.map(\.authorization) == ["bearer token-1", "bearer token-2"])
  }

  // MARK: Source order

  /// Each source answers before the ones after it: the session's PR, the Issues cache, sbd's cache, then a fetch.
  @Test func eachSourceAnswersBeforeTheNext() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7, title: "Fetched title"))

    let fetched = try h.details("acme/widgets#7")
    h.cache([inboxIssue(7, title: "Cached title")])
    let cached = try h.details("acme/widgets#7")
    h.addSession("s1", pr: pullRequest(7, title: "Polled title"))
    let polled = try h.details("acme/widgets#7")

    #expect([fetched["source"], cached["source"], polled["source"]] == ["fetch", "issues", "session"])
    #expect([fetched["title"], cached["title"], polled["title"]] == ["Fetched title", "Cached title", "Polled title"])
    #expect(h.api.requests.count == 1)
  }

  @Test func aSessionsPRAnswersWithoutARequest() throws {
    let h = try Harness()
    h.addSession("s1", pr: pullRequest(42))
    h.api.put(42, issueNode(42))

    let details = try h.details("acme/widgets#42")

    #expect(details["source"] == "session")
    #expect(details["kind"] == "pr")
    #expect(details["read"] == nil)
    #expect(h.api.requests.isEmpty)
  }

  @Test func aCachedIssueAnswersWithoutARequest() throws {
    let h = try Harness()
    h.cache([inboxIssue(7)])
    h.api.put(7, issueNode(7))

    let details = try h.details("acme/widgets#7")

    #expect(details["source"] == "issues")
    #expect(details["kind"] == "issue")
    #expect(h.api.requests.isEmpty)
  }

  /// The Issues cache read the issue when its last poll of the sources ended.
  @Test func aCachedIssueAnswersWithTheTimeOfTheLastIssuesPoll() throws {
    let h = try Harness()
    h.cache([inboxIssue(7)])
    h.service.queue.sync { h.service.issueCache.polledAt = 1_794_000_000_000 }

    #expect(try h.details("acme/widgets#7")["read"] == 1_794_000_000_000)
  }

  /// GitHub sends `/issues/N` on to the PR, and a repository's name has no case.
  @Test(arguments: [
    "ACME/Widgets#42", "https://github.com/acme/widgets/issues/42", "https://github.com/acme/widgets/pull/42/files",
    "https://github.com/Acme/Widgets/pull/42#discussion_r1",
  ])
  func aSessionsPRAnswersEveryFormOfItsReference(_ ref: String) throws {
    let h = try Harness()
    h.addSession("s1", pr: pullRequest(42))

    #expect(try h.details(ref)["source"] == "session")
    #expect(h.api.requests.isEmpty)
  }

  @Test func aSessionsPRWithTheSameNumberInAnotherRepoDoesNotAnswer() throws {
    let h = try Harness()
    h.addSession("s1", pr: pullRequest(42, in: "acme/other"))
    h.api.put(42, issueNode(42))

    #expect(try h.details("acme/widgets#42")["source"] == "fetch")
  }

  @Test func aCachedIssueWithTheSameNumberInAnotherRepoDoesNotAnswer() throws {
    let h = try Harness()
    h.cache([inboxIssue(7, in: "acme/other")])
    h.api.put(7, issueNode(7))

    #expect(try h.details("acme/widgets#7")["source"] == "fetch")
  }

  @Test func localSourcesAnswerWithoutAPoller() throws {
    let h = try Harness(poller: false)
    h.addSession("s1", pr: pullRequest(42))
    h.cache([inboxIssue(7)])

    #expect(try h.details("acme/widgets#42")["source"] == "session")
    #expect(try h.details("acme/widgets#7")["source"] == "issues")
  }

  // MARK: Fetch

  @Test func anUnknownItemIsFetchedWithItsReadTime() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    let before = nowMs()

    let details = try h.details("acme/widgets#7")

    let read = try #require(details["read"]?.int)
    #expect(details["source"] == "fetch")
    #expect(h.api.requests.map(\.key) == ["acme/widgets#7"])
    #expect((Int(before)...Int(nowMs())).contains(read))
  }

  @Test func aSecondCallAnswersFromSbdsCacheWithTheFirstReadTime() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    let first = try h.details("acme/widgets#7")

    let second = try h.details("Acme/Widgets#7")

    #expect(h.api.requests.count == 1)
    #expect(second == first)
  }

  @Test func withoutAPollerAFetchFailsWithTheReason() throws {
    let h = try Harness(poller: false)

    #expect(try h.refusal("acme/widgets#7").contains("GitHub polling is off"))
  }

  @Test func anItemThatGitHubDoesNotHaveIsNotFound() throws {
    let h = try Harness()
    h.api.put(1, issueNode(1))

    #expect(try h.details("acme/widgets#7") == ["notFound": true, "repo": "acme/widgets", "number": 7])
  }

  @Test func aRepositoryThatGitHubDoesNotHaveIsNotFound() throws {
    let h = try Harness()

    #expect(try h.details("acme/missing#7") == ["notFound": true, "repo": "acme/missing", "number": 7])
  }

  /// The reply names the item as the request wrote it.
  @Test func notFoundNamesTheItemAsWritten() throws {
    let h = try Harness()

    #expect(try h.details("Acme/Missing#7")["repo"] == "Acme/Missing")
  }

  @Test func notFoundIsCached() throws {
    let h = try Harness()
    h.api.put(1, issueNode(1))
    let first = try h.details("acme/widgets#7")

    let second = try h.details("acme/widgets#7")

    #expect(second == first)
    #expect(h.api.requests.count == 1)
  }

  @Test func aGitHubErrorFailsWithItsStatus() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.queue(.init(status: 502, body: #"{"message":"Server Error"}"#))

    #expect(try h.refusal("acme/widgets#7").contains("502"))
  }

  @Test func aGitHubErrorIsCached() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.queue(.init(status: 502, body: #"{"message":"Server Error"}"#))
    let first = try h.refusal("acme/widgets#7")

    let second = try h.refusal("acme/widgets#7")

    #expect(second == first)
    #expect(h.api.requests.count == 1)
  }

  // MARK: Input forms

  /// Every way to name one item gives the same answer.
  @Test(
    arguments: [
      ["ref": "acme/widgets#7"], ["ref": "Acme/Widgets#7"], ["ref": " acme/widgets#7 "],
      ["ref": "https://github.com/acme/widgets/issues/7"],
      ["ref": "https://github.com/acme/widgets/issues/7#issuecomment-1"],
      ["ref": "https://github.com/acme/widgets/issues/7?x=1"], ["ref": "http://github.com/acme/widgets/issues/7"],
      ["ref": "https://GitHub.com/acme/widgets/issues/7"], ["ref": "https://github.com/acme/widgets/pull/7"],
      ["repo": "acme/widgets", "number": 7], ["repo": "Acme/Widgets", "number": 7],
    ] as [JSON])
  func everyFormOfAReferenceGivesTheSameItem(_ args: JSON) throws {
    let h = try Harness()
    h.cache([inboxIssue(7)])
    let expected = try h.details("acme/widgets#7").filter { $0.key != "read" }

    let details = try h.details(args).filter { $0.key != "read" }

    #expect(details == expected)
  }

  // MARK: Guard (bad references)

  /// Each input names no item that the app would link. The op refuses it with a message and asks GitHub nothing.
  /// The fake holds acme/widgets#7, so an input that slipped through as #7 would answer.
  @Test(
    arguments: [
      [:], ["ref": ""], ["ref": "   "], ["ref": "#7"], ["ref": "7"], ["ref": "acme/widgets"], ["ref": "acme/widgets#"],
      ["ref": "acme/widgets#0"], ["ref": "acme/widgets#1234567890"], ["ref": "acme/wid gets#7"],
      ["ref": "acme/widgets/x#7"], ["ref": "/widgets#7"], ["ref": "acme/#7"],
      ["ref": "https://example.com/acme/widgets/issues/7"], ["ref": "https://www.github.com/acme/widgets/issues/7"],
      ["ref": "https://github.com/acme/widgets/discussions/7"], ["ref": "https://github.com/acme/widgets/pull/new/x"],
      ["ref": "https://github.com/acme/widgets/issues"], ["ref": "https://github.com/acme/widgets/pulls/7"],
      ["ref": "https://github.com/acme/widgets/issues/0"], ["ref": "https://github.com/acme/widgets/issues/07"],
      ["ref": "https://github.com/acme/widgets/issues/1234567890"],
      ["ref": "https://github.com:8443/acme/widgets/issues/7"],
      ["ref": "https://user@github.com/acme/widgets/issues/7"],
      ["ref": "https://github.com/acme/widgets/pull/%37"], ["ref": "https://github.com/acme/./widgets/issues/7"],
      ["ref": "ftp://github.com/acme/widgets/issues/7"],
      ["repo": "acme/widgets"], ["number": 7], ["repo": "acme", "number": 7], ["repo": "acme/wid gets", "number": 7],
      ["repo": "acme/widgets/x", "number": 7], ["repo": "", "number": 7], ["repo": "acme/widgets", "number": 0],
      ["repo": "acme/widgets", "number": -7], ["repo": "acme/widgets", "number": 7.5],
      ["repo": "acme/widgets", "number": 1_234_567_890], ["repo": "acme/widgets", "number": "7"], ["ref": 7],
      ["ref": "acme/widgets#7", "repo": "acme/widgets", "number": 7], ["ref": "acme/widgets#7", "number": 8],
    ] as [JSON])
  func aBadReferenceIsRefusedWithoutARequest(_ args: JSON) throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))

    let message = try h.refusal(args)

    #expect(!message.isEmpty)
    #expect(h.api.requests.isEmpty)
  }

  // MARK: Fresh reads

  /// GitHub's title changes after the first read. A plain call answers from sbd's cache, a fresh call reads GitHub,
  /// and sbd stores the fresh answer for the next plain call.
  @Test func aFreshCallReadsGitHubAndStoresTheAnswer() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7, title: "Old title"))
    _ = try h.details("acme/widgets#7")
    h.api.put(7, issueNode(7, title: "New title"))

    let cached = try h.details("acme/widgets#7")
    let fresh = try h.details(["ref": "acme/widgets#7", "fresh": true])
    let after = try h.details("acme/widgets#7")

    #expect([cached["title"], fresh["title"], after["title"]] == ["Old title", "New title", "New title"])
    #expect(h.api.requests.count == 2)
  }

  /// "Check now" on a wait for the session's own PR must read GitHub, not the poll that sbd stored.
  @Test func aFreshCallSkipsASessionsPR() throws {
    let h = try Harness()
    h.addSession("s1", pr: pullRequest(42, title: "Polled title"))
    h.api.put(42, issueNode(42, title: "Fetched title"))

    let details = try h.details(["ref": "acme/widgets#42", "fresh": true])

    #expect(details["source"] == "fetch")
    #expect(details["title"] == "Fetched title")
    #expect(h.api.requests.map(\.key) == ["acme/widgets#42"])
  }

  /// "Check now" stores a read that is newer than the poll, so a later plain call must not undo it.
  @Test func aPlainCallAfterAFreshReadAnswersWithTheFreshRead() throws {
    let h = try Harness()
    h.addSession("s1", pr: pullRequest(42, title: "Polled title"), polled: nowMs() - 30_000)
    h.api.put(42, issueNode(42, title: "Fetched title"))
    _ = try h.details(["ref": "acme/widgets#42", "fresh": true])

    let after = try h.details("acme/widgets#42")

    #expect(after["title"] == "Fetched title")
    #expect(after["source"] == "fetch")
    #expect(h.api.requests.count == 1)
  }

  @Test func aPollNewerThanTheFreshReadAnswersAgain() throws {
    let h = try Harness()
    h.addSession("s1", pr: pullRequest(42, title: "Polled title"), polled: nowMs() - 30_000)
    h.api.put(42, issueNode(42, title: "Fetched title"))
    _ = try h.details(["ref": "acme/widgets#42", "fresh": true])
    h.addSession("s1", pr: pullRequest(42, title: "Newer poll"), polled: nowMs() + 1_000)

    let after = try h.details("acme/widgets#42")

    #expect(after["title"] == "Newer poll")
    #expect(after["source"] == "session")
  }

  @Test func aPlainCallAfterAFreshReadAnswersWithTheFreshReadOfACachedIssue() throws {
    let h = try Harness()
    h.cache([inboxIssue(7, title: "Cached title")])
    h.service.queue.sync { h.service.issueCache.polledAt = nowMs() - 30_000 }
    h.api.put(7, issueNode(7, title: "Fetched title"))
    _ = try h.details(["ref": "acme/widgets#7", "fresh": true])

    let after = try h.details("acme/widgets#7")

    #expect(after["title"] == "Fetched title")
  }

  @Test func aFreshCallSkipsACachedIssue() throws {
    let h = try Harness()
    h.cache([inboxIssue(7, title: "Cached title")])
    h.api.put(7, issueNode(7, title: "Fetched title"))

    let details = try h.details(["ref": "acme/widgets#7", "fresh": true])

    #expect(details["source"] == "fetch")
    #expect(details["title"] == "Fetched title")
    #expect(h.api.requests.count == 1)
  }

  /// A cached GitHub error does not stop a fresh read, and the fresh answer replaces it.
  @Test func aFreshCallReplacesACachedError() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.queue(.init(status: 502, body: #"{"message":"Server Error"}"#))
    _ = try h.refusal("acme/widgets#7")

    let fresh = try h.details(["ref": "acme/widgets#7", "fresh": true])
    let after = try h.details("acme/widgets#7")

    #expect(fresh["title"] == "Fetched title")
    #expect(after == fresh)
    #expect(h.api.requests.count == 2)
  }

  @Test func aFreshCallOfAnItemGitHubDoesNotHaveIsNotFound() throws {
    let h = try Harness()
    h.api.put(1, issueNode(1))

    #expect(
      try h.details(["ref": "acme/widgets#7", "fresh": true]) == [
        "notFound": true, "repo": "acme/widgets", "number": 7,
      ])
  }

  /// Every way to name a session's PR reads GitHub when the call is fresh.
  @Test(
    arguments: [
      ["ref": "acme/widgets#42"], ["ref": "ACME/Widgets#42"], ["ref": "https://github.com/acme/widgets/pull/42"],
      ["ref": "https://github.com/acme/widgets/issues/42"], ["repo": "acme/widgets", "number": 42],
      ["repo": "Acme/Widgets", "number": 42],
    ] as [JSON])
  func everyFormOfAFreshReferenceReadsGitHub(_ args: JSON) throws {
    let h = try Harness()
    h.addSession("s1", pr: pullRequest(42))
    h.api.put(42, issueNode(42))
    var fresh = args.object ?? [:]
    fresh["fresh"] = true

    let details = try h.details(.object(fresh))

    #expect(details["source"] == "fetch")
    #expect(h.api.requests.count == 1)
  }

  /// Without `fresh`, and with `fresh: false`, the order stays: the session's PR, the Issues cache, sbd's cache.
  @Test(arguments: [nil, false] as [Bool?])
  func aCallThatIsNotFreshKeepsTheSourceOrder(_ flag: Bool?) throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.put(42, issueNode(42))
    h.addSession("s1", pr: pullRequest(42))
    h.cache([inboxIssue(8)])
    func args(_ ref: String) -> JSON {
      var a: [String: JSON] = ["ref": .string(ref)]
      if let flag { a["fresh"] = .bool(flag) }
      return .object(a)
    }
    _ = try h.details(args("acme/widgets#7"))

    let sources = try ["acme/widgets#42", "acme/widgets#8", "acme/widgets#7"].map { try h.details(args($0))["source"] }

    #expect(sources == ["session", "issues", "fetch"])
    #expect(h.api.requests.count == 1)
  }

  /// A fresh call still refuses a bad reference before it asks GitHub.
  @Test(arguments: [["ref": "acme/widgets"], ["ref": "acme/widgets#0"], ["repo": "acme/widgets"]] as [JSON])
  func aFreshCallRefusesABadReferenceWithoutARequest(_ args: JSON) throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    var fresh = args.object ?? [:]
    fresh["fresh"] = true

    let message = try h.refusal(.object(fresh))

    #expect(!message.isEmpty)
    #expect(h.api.requests.isEmpty)
  }

  /// Fresh calls that arrive while a read for their key runs wait for that read, so "Check now" clicked twice costs
  /// one request.
  @Test func concurrentFreshCallsShareOneRead() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.hold()
    releaseLater(h.api)

    let results = try concurrently(20) { _ in h.call(["ref": "acme/widgets#7", "fresh": true]) }

    #expect(results.compactMap(\.error) == [])
    #expect(results.map { $0.result?["title"] } == Array(repeating: "Fetched title", count: 20))
    #expect(h.api.requests.count == 1)
  }

  /// A fresh call that arrives while a plain read for its key runs joins that read, which started after the click.
  @Test func aFreshCallJoinsAPlainReadThatRuns() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.hold()
    releaseLater(h.api)

    let results = try concurrently(10) { i in
      h.call(i == 0 ? ["ref": "acme/widgets#7"] : ["ref": "acme/widgets#7", "fresh": true])
    }

    #expect(results.compactMap(\.error) == [])
    #expect(h.api.requests.count == 1)
  }

  // MARK: In-flight sharing

  /// Callers that ask while a fetch for their key runs wait for it and get its answer. The fake holds its answer
  /// until the fetch is in flight and the other callers have had time to reach it.
  @Test func concurrentCallsForOneKeyShareOneFetch() throws {
    let h = try Harness()
    h.api.put(7, issueNode(7))
    h.api.hold()
    releaseLater(h.api)
    let refs = ["acme/widgets#7", "ACME/widgets#7", "https://github.com/acme/widgets/issues/7"]

    let results = try concurrently(20) { i in h.call(["ref": .string(refs[i % refs.count])]) }

    #expect(results.compactMap(\.error) == [])
    #expect(results.map { $0.result?["title"] } == Array(repeating: "Fetched title", count: 20))
    #expect(h.api.requests.count == 1)
  }

  @Test func concurrentCallsForOneKeyShareOneFailure() throws {
    let h = try Harness()
    h.api.queue(.init(status: 502, body: #"{"message":"Server Error"}"#))
    h.api.hold()
    releaseLater(h.api)

    let results = try concurrently(20) { _ in h.call(["ref": "acme/widgets#7"]) }

    let errors = results.map { $0.error ?? "" }
    #expect(errors.filter { $0.contains("502") }.count == 20, "\(errors)")
    #expect(h.api.requests.count == 1)
  }

  // MARK: Concurrent fetches

  /// 20 fetches of different items run at once, and GitHub answers one of them 401. Every call answers, and the
  /// refresh runs gh a few times at most. A warm-up fetch first stores a token, because 20 callers that find no
  /// token each run gh. The fake holds its answers until every caller has sent its request with the old token.
  @Test func twentyConcurrentFetchesSurviveA401() throws {
    let h = try Harness()
    for n in 1...21 { h.api.put(n, issueNode(n, title: "Item \(n)")) }
    _ = try h.details("acme/widgets#21")
    let ghBefore = h.ghCalls
    h.api.unauthorizeNext()
    h.api.hold()
    releaseLater(h.api, after: 1)

    let results = try concurrently(20) { i in h.call(["ref": .string("acme/widgets#\(i + 1)")]) }

    #expect(results.compactMap(\.error) == [])
    #expect(results.map { $0.result?["title"] } == (1...20).map { JSON.string("Item \($0)") })
    #expect((1...5).contains(h.ghCalls - ghBefore), "gh ran \(h.ghCalls - ghBefore) times")
    #expect(h.api.requests.count == 1 + 20 + 1)
  }

  /// Two requests run at once. The first answer pauses GraphQL for 10 minutes, and the second, which arrives later,
  /// spent the last point of a window that resets in a minute. The pause keeps the later end.
  @Test func aLaterAnswerDoesNotShortenAPause() throws {
    let h = try Harness()
    let now = Int(Date().timeIntervalSince1970)
    h.api.queue(
      .init(
        status: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(now + 600)"],
        body: #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#, delay: 0.5))
    h.api.queue(
      .init(
        status: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(now + 60)"],
        body: #"{"data":{"rateLimit":{"cost":1},"repository":null}}"#, delay: 1.5))
    let poller = try #require(h.service.github)

    _ = try concurrently(2) { _ in
      var stats = GitHubPoller.Stats()
      let variables: JSON = ["o": "acme", "n": "widgets", "num": 7]
      return (try? poller.client.request(GitHub.referenceQuery, variables, stats: &stats)) != nil
    }

    #expect(h.api.requests.count == 2)
    #expect(poller.client.graphQLPausedUntil > nowMs() + 500_000)
  }

  /// A rate limit that one of 20 concurrent fetches meets pauses the next fetch, which fails without a request.
  @Test func aRateLimitDuringConcurrentFetchesPausesTheNextFetch() throws {
    let h = try Harness()
    for n in 1...21 { h.api.put(n, issueNode(n)) }
    _ = try h.details("acme/widgets#21")
    let reset = Int(Date().timeIntervalSince1970) + 600
    h.api.queue(
      .init(
        status: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"],
        body: #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#))

    _ = try concurrently(20) { i in h.call(["ref": .string("acme/widgets#\(i + 1)")]) }
    let sent = h.api.requests.count

    #expect(try h.refusal(["repo": "acme/widgets", "number": 99]).contains("paused after a GitHub GraphQL rate limit"))
    #expect(h.api.requests.count == sent)
  }
}
