import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The Event Streams provider's entry in `sb sources --json`, or nil when sbd lists none.
  fileprivate func eventSource() throws -> JSON? {
    JSON.parse(try sb("sources", "--json"))?["providers"]?.array?.first { $0["id"]?.string == "github-events" }
  }

  /// Waits until the Event Streams provider's entry matches, and returns it.
  @discardableResult
  fileprivate func waitForEventSource(_ what: String, timeout: Double = 15, _ match: (JSON) -> Bool) throws -> JSON {
    try waitFor(what, timeout: timeout, fetch: { try eventSource() }, until: match)
  }

  /// Waits until `github` holds an open stream for PR `number` and sbd counts it, and returns its subscription
  /// id. The fake counts a stream once it answers, which is before sbd reads the answer.
  fileprivate func waitForStream(_ github: FakeGitHub, _ number: Int = EventStreamsTests.number) throws -> String {
    try waitFor("an open stream for #\(number)") {
      try github.openStreams(number) == 1 && (eventSource()?["counts"]?["streams"]?.int ?? 0) >= 1
    }
    return try #require(github.subscriptions.first { $0.number == number }?.id)
  }
}

extension FakeGitHub {
  fileprivate var creates: [RESTRequest] { restRequests(to: "event-subscriptions").filter { $0.method == "POST" } }

  /// The requests that opened a stream of the subscription.
  fileprivate func streamRequests(_ id: String) -> [RESTRequest] {
    restRequests(to: "event-subscriptions/\(id)/events")
  }
}

/// sbd's Event Streams provider in shadow mode, against the Event Streams API
/// of FakeGitHub. In shadow mode the provider subscribes and counts signals,
/// and sbd's reads stay what they are with the provider off.
@Suite(.blocking(timeLimit: .seconds(180))) struct EventStreamsTests {
  static let number = StatsPR.charts.number
  /// How long a test waits for the provider to open a stream again. Its backoff after a drop is jittered from 1 s.
  static let reconnectTimeout: Double = 30

  /// A session on the branch of PostHog/charts#18303, whose PR the poller has read, so the provider wants it.
  @discardableResult
  func prSession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: StatsPR.charts.repo, branch: StatsPR.charts.branch)
    try sbd.poll()
    return s
  }

  /// A fake GitHub whose account has Event Streams, and a shadow-mode sbd with a session on #18303.
  func enabled() throws -> (github: FakeGitHub, sbd: Instance) {
    let github = try FakeGitHub()
    github.eventsEnabled = true
    let sbd = try Instance.withGitHub(github)
    try prSession(sbd)
    return (github, sbd)
  }

  // MARK: An account without Event Streams

  @Test func anAccountWithoutEventStreamsIsUnavailableForSixHours() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try prSession(sbd)

    let source = try sbd.waitForEventSource("github-events to be unavailable") {
      $0["state"]?.string == "unavailable"
    }

    #expect(source["reason"]?.string == FakeGitHub.eventsDisabledMessage)
    let retryAt = try #require(source["retryAt"]?.int, "\(source.text)")
    let now = Int(try sbd.now())
    #expect(abs(retryAt - now - 6 * 3_600_000) < 60_000, "\(source.text)")
  }

  @Test func anAccountWithoutEventStreamsGetsOneRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try prSession(sbd)
    try sbd.waitFor("the first request for event subscriptions") { !github.eventRequests.isEmpty }

    for _ in 0..<3 { try sbd.poll(all: true) }
    // A request that a poll caused can arrive after the poll returns.
    usleep(1_000_000)

    #expect(github.eventRequests.count == 1, "\(github.eventRequests.map { "\($0.method) \($0.path)" })")
  }

  @Test func aRecheckAsksGitHubAgain() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try prSession(sbd)
    try sbd.waitFor("the first request for event subscriptions") { !github.eventRequests.isEmpty }

    try sbd.sb("sources", "--recheck")

    try sbd.waitFor("a second request for event subscriptions") { github.eventRequests.count >= 2 }
  }

  @Test func anAccountWithoutEventStreamsIsAskedAgainAfterSixHours() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try prSession(sbd)
    try sbd.waitFor("the first request for event subscriptions") { !github.eventRequests.isEmpty }

    try sbd.advanceClock(6 * 3_600_000 + 1_000)
    try sbd.poll()

    try sbd.waitFor("a second request for event subscriptions") { github.eventRequests.count >= 2 }
  }

  @Test func aCIWaitResolvesByPollingWithoutEventStreams() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try prSession(sbd)
    try sbd.waitForEventSource("github-events to be unavailable") { $0["state"]?.string == "unavailable" }
    github.checks(EventStreamsTests.number, "PENDING")
    try sbd.sb("wait", s.id, "--kind", "ci", "--note", "then merge")

    #expect(try sbd.poll()["resolved"]?.int == 0)
    github.checks(EventStreamsTests.number, "SUCCESS")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    try resumed(sbd, s, with: "CI on the session's PR: the checks passed. Your note: then merge.")
  }

  // MARK: Shadow mode

  /// Runs the same steps against a fake whose account has Event Streams: a session on #18303, a check suite and a
  /// review event, a dropped stream, a clock 120 s after the first poll, and a poll after the checks pass. Only a
  /// shadow-mode sbd opens streams, so only it waits for them.
  private func shadowScenario(events: String) throws -> (github: FakeGitHub, sbd: Instance) {
    let github = try FakeGitHub()
    github.eventsEnabled = true
    let sbd = try Instance.withGitHub(github, events: events)
    let shadow = events == "shadow"
    // A PR with pending checks polls every 30 s, so the last plain poll reads it.
    github.checks(EventStreamsTests.number, "PENDING")
    try prSession(sbd)
    let start = try sbd.now()
    let id = try shadow ? sbd.waitForStream(github) : ""
    github.emit(EventStreamsTests.number, type: FakeGitHub.checkSuiteEvent, conclusion: "failure")
    github.emit(EventStreamsTests.number, type: FakeGitHub.reviewEvent)
    if shadow { try sbd.waitForEventSource("the two signals") { ($0["signals"]?.int ?? 0) >= 2 } }
    github.dropStreams()
    if shadow {
      try sbd.waitFor("the stream to reopen", timeout: EventStreamsTests.reconnectTimeout) {
        github.streamRequests(id).count == 2 && github.openStreams(EventStreamsTests.number) == 1
      }
    }
    // Both runs move sbd's clock to the same time after the first poll, however long the shadow run waited.
    try sbd.advanceClock(max(61_000, start + 120_000 - (try sbd.now())))
    github.checks(EventStreamsTests.number, "SUCCESS")
    try sbd.poll()
    return (github, sbd)
  }

  @Test func shadowModeSendsTheSameGraphQLRequestsAsOff() throws {
    let graphQL = { (github: FakeGitHub) in github.requests.map { "\($0.kind) \($0.ids.joined(separator: ","))" } }
    let off = graphQL(try shadowScenario(events: "off").github)

    let shadow = try shadowScenario(events: "shadow")

    #expect(graphQL(shadow.github) == off)
    #expect(off.filter { $0.hasPrefix("status ") }.count >= 2, "\(off)")
    let source = try #require(try shadow.sbd.eventSource())
    #expect(source["shadow"]?.bool == true, "\(source.text)")
    #expect(source["reads"]?.int == 0, "\(source.text)")
  }

  /// The read after the stream opens makes the review read's previous read one of a live PR, so only the signal keeps
  /// the review read from counting a miss.
  @Test func aSignalThatALaterReadShowsCountsAsMatched() throws {
    let (github, sbd) = try enabled()
    _ = try sbd.waitForStream(github)
    try sbd.poll(all: true)
    github.emit(EventStreamsTests.number, type: FakeGitHub.reviewEvent)
    try sbd.waitForEventSource("the review signal") { $0["signals"]?.int == 1 }
    github.review(EventStreamsTests.number, by: "alice", "COMMENTED", at: stamp(0))

    try sbd.poll(all: true)
    // The hub tallies a poll's reads when the next poll ends.
    try sbd.poll()

    let source = try sbd.waitForEventSource("the matched signal") { $0["matched"]?.int == 1 }
    #expect(source["misses"]?.int == 0, "\(source.text)")
  }

  @Test func aChangeWithoutASignalOnALivePRCountsAMiss() throws {
    let (github, sbd) = try enabled()
    _ = try sbd.waitForStream(github)
    try sbd.poll(all: true)
    github.change(EventStreamsTests.number) { $0["headRefOid"] = "pushed" }

    try sbd.poll(all: true)
    try sbd.poll()

    try sbd.waitForEventSource("the miss") { $0["misses"]?.int == 1 }
  }

  /// The read before this one came before the stream opened, so the change may have come before the stream did.
  @Test func aChangeOnTheFirstReadAfterTheStreamOpensCountsNoMiss() throws {
    let (github, sbd) = try enabled()
    _ = try sbd.waitForStream(github)
    github.change(EventStreamsTests.number) { $0["headRefOid"] = "pushed" }

    try sbd.poll(all: true)
    try sbd.poll()

    let source = try #require(try sbd.eventSource())
    #expect(source["misses"]?.int == 0, "\(source.text)")
  }

  // MARK: Subscriptions and streams

  @Test(arguments: ["subscription_ended", "expired"])
  func aSubscriptionThatEndsIsCreatedAgain(_ end: String) throws {
    let (github, sbd) = try enabled()
    let first = try sbd.waitForStream(github)

    if end == "expired" {
      github.expire(EventStreamsTests.number)
    } else {
      github.endStream(EventStreamsTests.number, outcome: end)
    }

    let second = try sbd.waitFor(
      "a new subscription with an open stream", timeout: EventStreamsTests.reconnectTimeout,
      fetch: { github.subscriptions.first?.id },
      until: { $0 != first && github.openStreams(EventStreamsTests.number) == 1 })
    #expect(github.creates.count == 2)
    #expect(github.streamRequests(second).count == 1)
  }

  @Test func aReconnectReopensTheSameSubscription() throws {
    let (github, sbd) = try enabled()
    let id = try sbd.waitForStream(github)

    github.endStream(EventStreamsTests.number, outcome: "reconnect")

    try sbd.waitFor("the stream to reopen", timeout: EventStreamsTests.reconnectTimeout) {
      github.streamRequests(id).count == 2 && github.openStreams(EventStreamsTests.number) == 1
    }
    #expect(github.creates.count == 1)
    #expect(github.subscriptions.map(\.id) == [id])
  }

  @Test func theSubscriptionLimitLeavesTheOtherPRPolling() throws {
    let github = try FakeGitHub()
    github.eventsEnabled = true
    github.subscriptionLimit = 1
    let sbd = try Instance.withGitHub(github)
    for pr in [StatsPR.charts, StatsPR.haacked] { _ = try sbd.session(in: pr.repo, branch: pr.branch) }
    try sbd.poll()

    try sbd.waitForEventSource("one PR over the limit") { $0["counts"]?["limited"]?.int == 1 }
    #expect(github.subscriptions.count == 1)
    let mark = github.requests.count
    try sbd.poll(all: true)
    for pr in [StatsPR.charts, StatsPR.haacked] {
      let id = try #require(github.pr(pr.number)["id"]?.string)
      #expect(github.readStatus(of: id, since: mark), "\(pr)")
    }
  }

  /// The 401 falls on the stream's reopen after a drop. A 401 on the list or the create would reach the shared
  /// client, which gets a new token itself.
  @Test func aStreamGetsANewTokenAfterA401() throws {
    let (github, sbd) = try enabled()
    let id = try sbd.waitForStream(github)
    let mark = github.eventRequests.count
    github.failNextEventRequest(401, body: #"{"message":"Bad credentials"}"#)

    github.dropStreams()

    try sbd.waitFor("the stream to reopen", timeout: EventStreamsTests.reconnectTimeout) {
      github.openStreams(EventStreamsTests.number) == 1
    }
    let after = Array(github.eventRequests.dropFirst(mark))
    let stream = "event-subscriptions/\(id)/events"
    try #require(after.map(\.path) == [stream, stream], "\(after.map { "\($0.method) \($0.path)" })")
    #expect(after[0].authorization == github.streamRequests(id).first?.authorization)
    #expect(after[1].authorization != after[0].authorization)
  }

  @Test func aMergedPRsSubscriptionIsDeleted() throws {
    let (github, sbd) = try enabled()
    let id = try sbd.waitForStream(github)
    github.change(EventStreamsTests.number) { $0["state"] = "MERGED" }

    try sbd.poll(all: true)

    try sbd.waitFor("the subscription's deletion") { github.subscriptions.isEmpty }
    #expect(github.restRequests(to: "event-subscriptions/\(id)").map(\.method) == ["DELETE"])
  }

  @Test func aFailedDeleteIsTriedAgainAtTheNextPoll() throws {
    let (github, sbd) = try enabled()
    let id = try sbd.waitForStream(github)
    github.change(EventStreamsTests.number) { $0["state"] = "MERGED" }
    github.failNextEventRequest(500, body: #"{"message":"Server Error"}"#)
    try sbd.poll(all: true)
    try sbd.waitFor("the failed delete") { github.restRequests(to: "event-subscriptions/\(id)").count == 1 }
    #expect(github.subscriptions.count == 1)

    try sbd.poll()

    try sbd.waitFor("the subscription's deletion") { github.subscriptions.isEmpty }
    #expect(github.restRequests(to: "event-subscriptions/\(id)").map(\.method) == ["DELETE", "DELETE"])
  }

  /// A 403 on a delete makes the source unavailable, so the same update opens no other stream.
  @Test func aRefusedDeleteSendsNoOtherRequest() throws {
    let github = try FakeGitHub()
    github.eventsEnabled = true
    let sbd = try Instance.withGitHub(github)
    for pr in [StatsPR.charts, StatsPR.haacked] { _ = try sbd.session(in: pr.repo, branch: pr.branch) }
    try sbd.poll()
    _ = try sbd.waitForStream(github, StatsPR.charts.number)
    let other = try sbd.waitForStream(github, StatsPR.haacked.number)
    github.change(StatsPR.charts.number) { $0["state"] = "MERGED" }
    github.failNextEventRequest(403, body: FakeGitHub.eventsDisabled.body)

    try sbd.poll(all: true)

    try sbd.waitForEventSource("github-events to be unavailable") { $0["state"]?.string == "unavailable" }
    usleep(1_000_000)
    #expect(github.streamRequests(other).count == 1)
  }

  @Test func aRestartReusesTheListedSubscription() throws {
    let (github, sbd) = try enabled()
    let id = try sbd.waitForStream(github)
    sbd.stopSbd()
    let mark = github.eventRequests.count

    try sbd.startSbd()
    try sbd.poll(all: true)

    try sbd.waitFor("a stream of the same subscription") {
      github.streamRequests(id).count == 2 && github.openStreams(EventStreamsTests.number) == 1
    }
    #expect(!github.eventRequests.dropFirst(mark).contains { $0.method == "POST" })
    #expect(github.subscriptions.map(\.id) == [id])
  }
}
