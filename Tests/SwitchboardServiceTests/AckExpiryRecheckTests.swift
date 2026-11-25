import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

// These tests never move `Clock`, because it is global to the test process. They move the PR's last read and the
// acknowledgment's time back instead.

private let sessionId = "s1"
private let repo = "acme/widgets"
private let prId = "PR_42"
private let hour: Int64 = 3_600_000

/// A GitHub GraphQL API that answers each status read with the session's PR. The PR is an open draft that conflicts
/// with main, so it polls at the idle rate, which the harness sets to a day.
private final class StatusReads: @unchecked Sendable {
  private let lock = NSLock()
  private var answered = 0
  private var down = false

  /// How many status reads named the PR and got an answer.
  var reads: Int { lock.withLock { answered } }

  /// While true, every request fails, as when GitHub can't be reached.
  var failing: Bool {
    get { lock.withLock { down } }
    set { lock.withLock { down = newValue } }
  }

  func answer(_ request: URLRequest) throws -> (Int, [String: String], Data) {
    if failing { throw URLError(.notConnectedToInternet) }
    let body = JSON.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
    let ids = body?["variables"]?["ids"]?.array?.compactMap(\.string) ?? []
    var data: [String: JSON] = ["rateLimit": ["cost": 1]]
    if body?["query"]?.string == GitHub.statusQuery, ids.contains(prId) {
      lock.withLock { answered += 1 }
      data["nodes"] = .array(ids.map { $0 == prId ? Self.node : .null })
    }
    return (200, [:], Data(JSON.object(["data": .object(data)]).text.utf8))
  }

  private static let node: JSON = [
    "id": .string(prId), "number": 42, "state": "OPEN", "isDraft": true, "mergeable": "CONFLICTING",
    "headRefName": "haacked/dlq", "baseRefName": "main", "body": "",
    "repository": ["nameWithOwner": .string(repo), "defaultBranchRef": ["name": "main"]],
  ]
}

/// A `Service` in a temporary home that never loads, with a GitHub poller that polls only when a test calls `poll`.
private final class AckHarness {
  let home: Home
  let service: Service
  let github = StatusReads()
  private(set) var poller: GitHubPoller

  init() throws {
    home = Home(path: try makeShortTempFolder())
    // gh is echo, so the token is "auth token".
    let config: JSON = [
      "claude": "/usr/bin/false", "tmux": "/usr/bin/true",
      "github": [
        "gh": "/bin/echo", "url": "http://127.0.0.1:9", "pollSeconds": 0, "idlePollSeconds": 86_400,
      ],
      "depot": ["enabled": false], "trunk": ["path": .string("\(home.path)/trunk")],
    ]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
    service = try Service(home: home, sbPath: "/usr/bin/true")
    poller = Self.poller(service, github)
  }

  deinit { try? FileManager.default.removeItem(atPath: home.path) }

  private static func poller(_ service: Service, _ github: StatusReads) -> GitHubPoller {
    let p = GitHubPoller(
      service: service, settings: service.config.github, depot: service.config.depot, trunk: service.config.trunk)
    p.client.transport = github.answer
    service.github = p
    return p
  }

  var acknowledgedMs: Int64 { service.config.recheck.acknowledgedMs }

  /// A session whose turn ended and whose PR conflicts with main.
  func addSession() throws {
    let cwd = "\(home.path)/work/\(sessionId)"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    var s = Session(id: sessionId, name: "widgets", cwd: cwd, claudeSessionId: "c-\(sessionId)", created: 5)
    s.started = true
    // The poller would otherwise look for the transcript in ~/.claude.
    s.claudeConfigDir = "\(cwd)/claude"
    try service.store.save(s)
    service.queue.sync { service.entries[sessionId] = Service.Entry(session: s) }
    record("UserPromptSubmit", ["hook_event_name": "UserPromptSubmit", "prompt": "Open the PR."])
    record("Stop", ["hook_event_name": "Stop", "last_assistant_message": "Opened #42."])
    let pr = PullRequest(
      id: prId, number: 42, url: "https://github.com/\(repo)/pull/42", repo: repo, title: "Count the DLQ lookups",
      head: "haacked/dlq", headSha: "abc123", mergeable: .conflicting, checks: "SUCCESS", author: "haacked")
    record("pr", ["pr": try JSON(encoding: pr), "comments": []])
  }

  func record(_ kind: String, _ data: JSON = [:]) {
    service.queue.sync { _ = service.record(sessionId, kind, data) }
  }

  /// Records an `ack` of the current item, as the app's Acknowledge does, whose `acknowledgedMs` ends `ago` ms
  /// before now. A negative `ago` ends it in the future.
  func acknowledge(expiredAgo ago: Int64) throws {
    let (verdict, facts) = service.queue.sync {
      let e = service.entries[sessionId]!
      return (Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: service.lastState), e.facts)
    }
    record("ack", try JSON(encoding: Acknowledgment(verdict, facts)))
    let at = nowMs() - acknowledgedMs - ago
    service.queue.sync { service.entries[sessionId]!.facts.acknowledgment?.at = at }
  }

  func poll() { _ = poller.poll(all: false) }

  /// Moves the time of the poller's last read of the PR `ms` back.
  func ageLastRead(_ ms: Int64) {
    poller.queue.sync { poller.prs[prId]?.polled -= ms }
  }

  /// A new poller, as sbd builds when it starts again. It has read no PR.
  func restart() { poller = Self.poller(service, github) }

  /// A session whose PR the poller read `lastReadAgo` ms ago, and an acknowledgment that expired `expiredAgo` ms
  /// ago.
  static func read(lastReadAgo: Int64, expiredAgo: Int64) throws -> AckHarness {
    let h = try AckHarness()
    try h.addSession()
    h.poll()
    try #require(h.github.reads == 1, "the first poll reads the PR")
    h.ageLastRead(lastReadAgo)
    try h.acknowledge(expiredAgo: expiredAgo)
    return h
  }
}

/// When the user's acknowledgment expires, the next poll reads the session's PR once, whether or not it is due, so
/// the item that returns to the Inbox shows what GitHub shows now. The PR's last read decides it, so nothing that
/// sbd holds in memory can read it twice or lose the read.
@Suite(.timeLimit(.minutes(1))) struct AckExpiryRecheckTests {
  @Test func anExpiredAcknowledgmentMakesTheNextPollReadThePR() throws {
    let h = try AckHarness.read(lastReadAgo: 2 * hour, expiredAgo: hour)

    h.poll()

    #expect(h.github.reads == 2)
  }

  /// The PR read two hours ago is not due at the idle rate, so this shows that the other tests' reads come from
  /// the acknowledgment.
  @Test func anAcknowledgmentThatHasNotExpiredReadsNothing() throws {
    let h = try AckHarness.read(lastReadAgo: 2 * hour, expiredAgo: -hour)

    h.poll()

    #expect(h.github.reads == 1)
  }

  @Test func anAcknowledgmentThatExpiredBeforeTheLastReadReadsNothing() throws {
    let h = try AckHarness.read(lastReadAgo: 2 * hour, expiredAgo: 3 * hour)

    h.poll()

    #expect(h.github.reads == 1)
  }

  @Test func theExpiredAcknowledgmentReadsThePROnce() throws {
    let h = try AckHarness.read(lastReadAgo: 2 * hour, expiredAgo: hour)
    h.poll()
    try #require(h.github.reads == 2)

    h.poll()
    h.poll()

    #expect(h.github.reads == 2)
  }

  /// A new poller reads every PR at its first poll. The acknowledgment adds no read after that.
  @Test func afterARestartTheExpiredAcknowledgmentReadsNoMore() throws {
    let h = try AckHarness.read(lastReadAgo: 2 * hour, expiredAgo: hour)
    h.poll()
    try #require(h.github.reads == 2)

    h.restart()
    h.poll()
    let afterRestart = h.github.reads
    h.poll()
    h.poll()

    #expect(afterRestart == 3)
    #expect(h.github.reads == afterRestart)
  }

  @Test func aFailedPollReadsThePRAtTheNextPoll() throws {
    let h = try AckHarness.read(lastReadAgo: 2 * hour, expiredAgo: hour)
    h.github.failing = true
    h.poll()
    try #require(h.github.reads == 1)
    h.github.failing = false

    h.poll()

    #expect(h.github.reads == 2)
  }

  @Test func aLaterAcknowledgmentThatExpiresReadsThePRAgain() throws {
    let h = try AckHarness.read(lastReadAgo: 4 * hour, expiredAgo: 3 * hour)
    h.poll()
    try #require(h.github.reads == 2)
    h.ageLastRead(2 * hour)
    try h.acknowledge(expiredAgo: hour)

    h.poll()

    #expect(h.github.reads == 3)
  }
}
