import Foundation
import SwitchboardCore
import os

/// Reads GitHub Event Streams: one subscription for each wanted PR, and one SSE stream for each subscription, all
/// on one `URLSession`. It reports each event as a signal, each stream that opens as live coverage with a gap, and
/// each stream that drops as down. Every request goes through the poller's `GitHubClient`, so the token, the 401
/// retry, the REST pause, and the usage counts are shared. Its state lives on its own queue, so a slow request
/// never holds the poller's queue.
final class EventStreamsProvider: NSObject, PRChangeProvider, URLSessionDataDelegate {
  let id = GitHubEventStream.provider
  /// A check run, a commit status, a comment, a label, and GitHub's merge queue send no event.
  let signals: ChangeSignals = [.head, .checkSuites, .reviews, .state, .conflict]

  private let client: GitHubClient
  private let settings: EventSettings
  private let queue = DispatchQueue(label: "sbd.events")
  private var session: URLSession!
  private var sink: (any PRChangeSink)?

  /// GitHub's keep-alive comes about every 10 s, so 45 s without a byte is about four missed keep-alives.
  static let idleTimeout: TimeInterval = 45
  /// How long the provider waits after a 403 says that the account can't subscribe.
  static let recheckMs: Int64 = 6 * 3_600_000
  /// How long the provider waits after GitHub refuses a subscription past the account's limit.
  static let limitRetryMs: Int64 = 600_000
  /// A stream that stayed open this long starts its next reconnect from the shortest backoff.
  static let steadyMs: Int64 = 60_000

  /// Failures in a row, and when the next attempt may run.
  private struct Backoff {
    var failures = 0
    var retryAt: Int64 = 0

    /// Counts a failure and returns when the next attempt may run.
    mutating func fail(now: Int64) -> Int64 {
      failures += 1
      retryAt = now + EventStreamsProvider.backoffMs(failures: failures)
      return retryAt
    }
  }

  /// One PR's stream. A stream without a task waits for its backoff.
  private struct Stream {
    var task: URLSessionDataTask?
    var parser = SSEParser()
    /// The status of the open task's answer, 0 until it arrives.
    var status = 0
    /// The body and headers of an answer that isn't 200.
    var body = Data()
    var headers: [String: String] = [:]
    /// When the stream last went live, while it is live.
    var liveSince: Int64?
    var backoff = Backoff()
    /// Whether a 401 on this stream already got a new token.
    var refreshed = false
  }

  private var availability: Availability = .available
  private var stopped = false
  /// The PRs that sbd wants, most wanted first, cut to `maxSubscriptions`.
  private var wanted: [PRRef] = []
  /// Whether the subscriptions that GitHub lists were read since the start or the last recheck.
  private var listed = false
  private var listBackoff = Backoff()
  /// The ids of the listed subscriptions with all five types that sbd hasn't used yet, by `InboxIssue.id`.
  private var found: [String: String] = [:]
  /// The ids of the subscriptions that sbd uses, by PR.
  private var subscriptions: [PRRef: String] = [:]
  private var streams: [PRRef: Stream] = [:]
  /// The PR of each running task, by task id.
  private var tasks: [Int: PRRef] = [:]
  /// The PRs whose create answered 404 or a validation error, until they leave the interest list.
  private var unsupported: Set<PRRef> = []
  /// The wanted PRs without a subscription because the account reached its limit.
  private var limited: Set<PRRef> = []
  private var limitedUntil: Int64 = 0
  /// The backoff of each PR whose create failed.
  private var createFailures: [PRRef: Backoff] = [:]
  private var reconnects = 0
  /// What `status` returns. The hub reads it from the poller's queue, so it sits behind a lock.
  private let published = OSAllocatedUnfairLock(initialState: ProviderStatus(availability: .available))

  private struct Cost: GitHubCost {
    var requests = 0
    var points = 0
  }

  init(client: GitHubClient, settings: EventSettings) {
    self.client = client
    self.settings = settings
    super.init()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = Self.idleTimeout
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    // Each stream holds a request open. Over HTTP/1.1 every stream needs its own connection.
    config.httpMaximumConnectionsPerHost = settings.maxSubscriptions + 4
    let delegateQueue = OperationQueue()
    delegateQueue.underlyingQueue = queue
    delegateQueue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
  }

  var status: ProviderStatus { published.withLock { $0 } }

  func start(sink: any PRChangeSink) {
    queue.async { [self] in
      self.sink = sink
      sink.availability(id, availability)
    }
  }

  func setInterest(_ prs: [PRRef]) {
    let cut = Array(prs.prefix(settings.maxSubscriptions))
    queue.async { [self] in
      let left = Set(wanted).subtracting(cut)
      unsupported.subtract(left)
      wanted = cut
      update()
    }
  }

  /// Runs on the provider's queue before it returns, so `sb sources --recheck` shows the new state.
  func recheck() {
    queue.sync { [self] in
      guard case .unavailable = availability else { return }
      (listBackoff, limitedUntil) = (Backoff(), 0)
      createFailures = [:]
      setAvailability(.available)
      update()
    }
  }

  func stop() {
    queue.async { [self] in
      stopped = true
      for ref in Array(streams.keys) { close(ref, reason: "sbd stopped") }
      session.invalidateAndCancel()
      publish()
    }
  }

  // MARK: Subscriptions

  /// Brings the subscriptions and streams to the wanted PRs: deletes each subscription whose PR left, creates one
  /// for each wanted PR without one, and opens each stream that isn't open and whose retry time has come.
  private func update() {
    defer { publish() }
    guard !stopped else { return }
    let now = nowMs()
    if case .unavailable(_, let retryAt) = availability {
      guard let retryAt, now >= retryAt else { return }
      setAvailability(.available)
    }
    if !listed {
      guard now >= listBackoff.retryAt, !wanted.isEmpty, list() else { return }
    }
    let keep = Set(wanted)
    for (ref, sub) in subscriptions where !keep.contains(ref) {
      close(ref, reason: "sbd no longer wants the PR")
      // A delete that fails keeps the subscription, so the next update tries it again.
      if delete(sub, of: ref) { subscriptions[ref] = nil }
      guard availability == .available else { return }
    }
    createFailures = createFailures.filter { keep.contains($0.key) }
    limited = []
    for ref in wanted where !unsupported.contains(ref) {
      if subscriptions[ref] == nil {
        if let sub = found.removeValue(forKey: InboxIssue.id(ref.repo, ref.number)) {
          subscriptions[ref] = sub
        } else if limitedUntil > now {
          limited.insert(ref)
          continue
        } else if (createFailures[ref]?.retryAt ?? 0) > now {
          continue
        } else {
          create(ref)
          guard availability == .available else { return }
          if subscriptions[ref] == nil { continue }
        }
      }
      if streams[ref]?.task == nil, (streams[ref]?.backoff.retryAt ?? 0) <= now { open(ref) }
    }
  }

  /// Sends a REST request to an Event Streams path and returns its status and body. A 403 that isn't a rate limit
  /// makes the provider unavailable with GitHub's message, and the method then returns nil.
  private func rest(_ method: String, _ path: String, body: JSON? = nil) throws -> (status: Int, json: JSON?)? {
    var req = try client.apiRequest(path)
    req.httpMethod = method
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = Data(body.text.utf8)
    }
    var cost = Cost()
    let (status, _, _, json) = try client.send(req, stats: &cost)
    if status == 403 {
      refuse(GitHub.message(json))
      return nil
    }
    return (status, json)
  }

  /// Reads GitHub's list of the account's subscriptions and keeps the ones on a PR with all five types, so a
  /// restart reuses them. Returns whether it read the list.
  private func list() -> Bool {
    do {
      guard let (status, json) = try rest("GET", "event-subscriptions") else { return false }
      guard status == 200 else { throw APIError("GitHub answered \(status) \(GitHub.message(json))") }
      found = [:]
      for s in json?["subscriptions"]?.array ?? [] {
        guard let id = s["id"]?.string, let pr = s["resource_url"]?.string.flatMap(GitHubRef.init(url:)), pr.isPull,
          Set(s["event_types"]?.array?.compactMap(\.string) ?? []) == Set(GitHubEventStream.eventTypes)
        else { continue }
        found[InboxIssue.id(pr.repo, pr.number)] = id
      }
      (listed, listBackoff) = (true, Backoff())
      return true
    } catch {
      retry(at: listBackoff.fail(now: nowMs()))
      logLine("github: \(id) can't list the subscriptions: \(error)")
      return false
    }
  }

  private func create(_ ref: PRRef) {
    let body: JSON = [
      "resource_url": .string("https://github.com/\(ref.repo)/pull/\(ref.number)"),
      "event_types": .array(GitHubEventStream.eventTypes.map(JSON.string)),
    ]
    do {
      guard let (status, json) = try rest("POST", "event-subscriptions", body: body) else { return }
      switch status {
      case 200, 201:
        guard let id = json?["id"]?.string else { throw APIError("GitHub answered \(status) without an id") }
        subscriptions[ref] = id
        createFailures[ref] = nil
      case 404:
        unsupported.insert(ref)
      case 422 where GitHub.message(json).localizedCaseInsensitiveContains("limit"):
        limitedUntil = nowMs() + Self.limitRetryMs
        limited.insert(ref)
      case 422:
        unsupported.insert(ref)
      default:
        throw APIError("GitHub answered \(status) \(GitHub.message(json))")
      }
    } catch {
      retry(at: createFailures[ref, default: Backoff()].fail(now: nowMs()))
      logLine("github: \(id) can't subscribe to \(ref.repo)#\(ref.number): \(error)")
    }
  }

  /// Deletes a subscription that sbd no longer wants. GitHub ends every stream of the subscription, including a
  /// `gh event listen` that uses the same one. A delete frees a place under the account's limit, so the next update
  /// tries the creates that the limit refused.
  /// Returns whether GitHub no longer has the subscription.
  private func delete(_ sub: String, of ref: PRRef) -> Bool {
    do {
      guard let (status, json) = try rest("DELETE", "event-subscriptions/\(sub)") else { return false }
      guard status == 204 || status == 404 else {
        throw APIError("GitHub answered \(status) \(GitHub.message(json))")
      }
      limitedUntil = 0
      return true
    } catch {
      logLine("github: \(id) can't delete the subscription of \(ref.repo)#\(ref.number): \(error)")
      return false
    }
  }

  /// Makes the provider unavailable with GitHub's reason until `recheckMs` passes or `sb sources --recheck`.
  private func refuse(_ reason: String) {
    for ref in Array(streams.keys) { close(ref, reason: reason) }
    listed = false
    setAvailability(.unavailable(reason: reason, retryAt: nowMs() + Self.recheckMs))
  }

  private func setAvailability(_ a: Availability) {
    guard availability != a else { return }
    availability = a
    sink?.availability(id, a)
  }

  // MARK: Streams

  private func open(_ ref: PRRef) {
    guard let sub = subscriptions[ref] else { return }
    var stream = streams[ref] ?? Stream()
    do {
      let req = try client.streamRequest("event-subscriptions/\(sub)/events", idleTimeout: Self.idleTimeout)
      let task = session.dataTask(with: req)
      (stream.task, stream.parser, stream.status, stream.body, stream.headers) = (task, SSEParser(), 0, Data(), [:])
      tasks[task.taskIdentifier] = ref
      streams[ref] = stream
      task.resume()
    } catch {
      streams[ref] = stream
      failed(ref, reason: "\(error)")
    }
  }

  /// Cancels the PR's running task, and reports the stream down when it was live. Returns when the stream went
  /// live, or nil when it wasn't live.
  private func endTask(_ ref: PRRef, reason: String) -> Int64? {
    guard let stream = streams[ref] else { return nil }
    if let task = stream.task {
      tasks[task.taskIdentifier] = nil
      task.cancel()
    }
    streams[ref]?.task = nil
    streams[ref]?.liveSince = nil
    if stream.liveSince != nil { sink?.coverage(.down(.pr(ref), reason: reason)) }
    return stream.liveSince
  }

  /// Ends the PR's stream and forgets it.
  private func close(_ ref: PRRef, reason: String) {
    _ = endTask(ref, reason: reason)
    streams[ref] = nil
  }

  /// Ends the PR's stream and keeps it for its next attempt. A stream that was live counts a reconnect.
  private func drop(_ ref: PRRef, reason: String) {
    guard let since = endTask(ref, reason: reason) else { return }
    reconnects += 1
    if nowMs() - since >= Self.steadyMs { streams[ref]?.backoff.failures = 0 }
  }

  /// Drops the stream and tries again after the backoff of its failures. With `resubscribe`, the subscription is
  /// gone, so the next attempt creates a new one.
  private func failed(_ ref: PRRef, reason: String, resubscribe: Bool = false) {
    drop(ref, reason: reason)
    if resubscribe { subscriptions[ref] = nil }
    guard let at = streams[ref]?.backoff.fail(now: nowMs()) else { return }
    retry(at: at)
  }

  private func retry(at: Int64) {
    queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, at - nowMs())))) { [weak self] in self?.update() }
  }

  /// The wait after the failures, from 1 s up to 60 s as `retryDelayMs` gives it. A random amount of up to half of it is
  /// subtracted, so streams that dropped together don't reconnect together.
  static func backoffMs(failures: Int) -> Int64 {
    let full = retryDelayMs(failuresInARow: failures + 1)
    return full / 2 + Int64.random(in: 0...(full / 2))
  }

  private func handle(_ message: GitHubEventStream.Message, _ ref: PRRef) {
    switch message {
    case .signal(let s): sink?.signal(s)
    case .ignored: break
    case .end(let outcome, let reason):
      // A stream that GitHub ends again as soon as it opens backs off like any other failure.
      failed(
        ref, reason: "GitHub ended the stream: \(outcome)" + (reason.map { " (\($0))" } ?? ""),
        resubscribe: outcome != "reconnect")
    }
  }

  // MARK: URLSessionDataDelegate

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let ref = tasks[dataTask.taskIdentifier], var stream = streams[ref] else { return completionHandler(.cancel) }
    let http = response as? HTTPURLResponse
    stream.status = http?.statusCode ?? 0
    if stream.status == 200 {
      let now = nowMs()
      (stream.liveSince, stream.refreshed) = (now, false)
      sink?.coverage(.live(.pr(ref), since: now, gap: true))
    } else {
      // `GitHub.rateLimit` reads lowercase header names.
      for (k, v) in http?.allHeaderFields ?? [:] { stream.headers["\(k)".lowercased()] = "\(v)" }
    }
    streams[ref] = stream
    publish()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let ref = tasks[dataTask.taskIdentifier], let status = streams[ref]?.status else { return }
    guard status == 200 else {
      streams[ref]?.body.append(data)
      return
    }
    for e in streams[ref]?.parser.feed(data) ?? [] {
      handle(GitHubEventStream.decode(e, pr: ref), ref)
      // An end message replaces or forgets the task.
      guard tasks[dataTask.taskIdentifier] != nil else { break }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    guard let ref = tasks.removeValue(forKey: task.taskIdentifier), let stream = streams[ref] else { return }
    defer { publish() }
    streams[ref]?.task = nil
    let status = stream.status
    let json = JSON.parse(String(decoding: stream.body, as: UTF8.self))
    switch status {
    case 200, 0:
      failed(ref, reason: error.map { "the stream dropped: \($0.localizedDescription)" } ?? "the stream closed")
    default:
      let rateLimited = client.streamFailed(status: status, headers: stream.headers, json: json)
      switch status {
      case 401 where !stream.refreshed:
        streams[ref]?.refreshed = true
        open(ref)
      case 403 where !rateLimited:
        refuse(GitHub.message(json))
      case 404:
        // The subscription expired or someone deleted it, so the next update creates a new one.
        failed(ref, reason: "the subscription is gone", resubscribe: true)
      default:
        failed(ref, reason: "GitHub answered \(status) \(GitHub.message(json))")
      }
    }
  }

  private func publish() {
    let counts = [
      "subscriptions": subscriptions.count, "streams": streams.values.count { $0.liveSince != nil },
      "reconnects": reconnects, "limited": limited.count, "unsupported": unsupported.count,
    ]
    let status = ProviderStatus(availability: availability, counts: counts)
    published.withLock { $0 = status }
  }
}
