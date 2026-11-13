import Foundation
import SwitchboardCore

/// When sbd last asked docket about the open reviews, and whether it is asking now.
struct DocketPoll {
  var last: Int64 = 0
  var running = false
}

extension Service {
  static let docketQueue = DispatchQueue(label: "sbd.docket")

  /// Starts a docket review of `pr`, or tracks the open review that docket
  /// already has for it, and adds its row. A PR that an open row tracks
  /// returns that row. A review that docket could not start goes back
  /// through `start_review`, which restarts it. It takes the state queue
  /// itself, because docket runs for seconds.
  func startDocket(_ args: JSON) throws -> SessionSummary {
    guard let input = args["pr"]?.string?.trimmingCharacters(in: .whitespaces), !input.isEmpty else {
      throw APIError("name a pull request as a URL, org/repo#123, or a number that docket's default_repo completes")
    }
    let existing = args["existing"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    if let existing, !["append", "overwrite"].contains(existing) {
      throw APIError("--existing takes append or overwrite")
    }
    let placement = { [self] () throws -> (parent: String?, group: String?) in
      let parent = try args["parent"]?.string.map { try lookup(["session": .string($0)]) }
      return (parent, try groupOfNew(args["group"]?.string, parent: parent))
    }
    // A bad parent or group fails before docket starts a review that no row would track.
    _ = try queue.sync(execute: placement)
    // A bare number that sbd can't complete skips both checks. docket's start_review then names the PR.
    let wanted = DocketRef(input, defaultRepo: DocketRef.defaultRepo(docketHome: docketHome()))
    if let wanted, let tracked = queue.sync(execute: { trackedDocketRow(wanted) }) { return summary(tracked) }
    let review = try withDocket(timeout: config.docket.startTimeoutSeconds) { client in
      let listed = try client.listReviews().first { !$0.restartable && wanted?.names($0.pullRequest) == true }
      return try listed ?? client.startReview(input, existing: existing)
    }
    return try queue.sync {
      if let id = DocketRef(review.pullRequest).flatMap(openDocketRow) {
        if entries[id]?.facts.docket.review != review {
          record(id, "docket", ["review": try JSON(encoding: review)])
        }
        return summary(id)
      }
      let (parent, group) = try placement()
      var session = Session(
        id: newSessionID(), name: args["name"]?.string ?? "review \(review.pullRequest)", cwd: "",
        claudeSessionId: UUID().uuidString.lowercased(), created: nowMs())
      session.parent = parent
      session.group = group
      session.docket = DocketSession(pullRequest: review.pullRequest, url: review.url)
      entries[session.id] = Entry(session: session)
      try store.save(session)
      record(session.id, "docket", ["review": try JSON(encoding: review)])
      docketPoll.last = nowMs()
      return summary(session.id)
    }
  }

  /// Asks docket about the open reviews once `docket.pollSeconds` have passed
  /// on sbd's clock since the last ask. A `pollSeconds` of 0 never asks. The
  /// tick calls it on the state queue. The ask runs on a queue of its own and
  /// records what changed.
  func pollDocketsIfDue(now: Int64) {
    guard config.docket.pollSeconds > 0, !docketPoll.running,
      now - docketPoll.last >= Int64(config.docket.pollSeconds * 1000)
    else { return }
    let rows = openDocketRows()
    guard !rows.isEmpty else { return }
    docketPoll.running = true
    docketPoll.last = now
    Service.docketQueue.async { [self] in
      let result = Result { try withDocket(timeout: config.docket.timeoutSeconds) { try $0.listReviews() } }
      queue.sync {
        docketPoll.running = false
        applyDocketPoll(result, to: rows)
      }
    }
  }

  /// Applies a poll to the rows that were open when it started. A row that
  /// `sb docket` added during the poll may be missing from its list.
  private func applyDocketPoll(_ result: Result<[DocketReview], Error>, to rows: [String]) {
    let rows = Set(rows).intersection(openDocketRows()).sorted()
    let reviews: [DocketReview]
    switch result {
    case .failure(let error):
      for id in rows where entries[id]?.facts.docket.problem != "\(error)" {
        record(id, "docket", ["problem": .string("\(error)")])
      }
      return
    case .success(let listed):
      reviews = listed
    }
    let parsed = reviews.compactMap { r in DocketRef(r.pullRequest).map { ($0, r) } }
    for id in rows {
      guard let e = entries[id], let pr = e.session.docket.flatMap({ DocketRef($0.pullRequest) }) else { continue }
      guard let review = parsed.last(where: { pr.matches($0.0) })?.1 else {
        record(id, "docket", ["closed": true])
        continue
      }
      if review != e.facts.docket.review || e.facts.docket.problem != nil {
        record(id, "docket", ["review": (try? JSON(encoding: review)) ?? [:]])
      }
    }
  }

  /// The docket rows that docket still lists, leaving out rows marked done.
  private func openDocketRows() -> [String] {
    entries.filter { $0.value.session.docket != nil && !$0.value.facts.docket.closed && !$0.value.session.done }
      .keys.sorted()
  }

  /// The open row of `pullRequest`, unless docket could not start its review,
  /// which `start_review` restarts.
  private func trackedDocketRow(_ pullRequest: DocketRef) -> String? {
    openDocketRow(pullRequest).flatMap { entries[$0]?.facts.docket.review?.restartable == true ? nil : $0 }
  }

  private func openDocketRow(_ pullRequest: DocketRef) -> String? {
    openDocketRows().first { entries[$0]?.session.docket.map { pullRequest.names($0.pullRequest) } == true }
  }

  /// Runs `docket mcp` for at most `timeout` seconds and passes the client to `body`.
  private func withDocket<T>(timeout: Double, _ body: (DocketClient) throws -> T) throws -> T {
    let env = docketEnvironment()
    guard let docket = config.docket.executable(environment: env) else {
      throw APIError("can't find docket. Set docket.path in \(home.path)/config.json")
    }
    return try DocketClient.run(docket: docket, env: env, timeout: timeout, body)
  }

  /// The folder docket keeps its state and config.toml in, as docket resolves it.
  private func docketHome() -> String {
    docketEnvironment()["DOCKET_HOME"].flatMap { $0.isEmpty ? nil : $0.expandingTilde } ?? "~/.docket".expandingTilde
  }

  /// sbd's environment and `config.env`. docket checks at startup that git,
  /// gh, and claude are on PATH. sbd under launchd has only the system's
  /// folders on PATH. PATH therefore starts with the folders of the git, gh,
  /// and claude that sbd finds.
  private func docketEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for (key, value) in config.env { env[key] = value.expandingTilde }
    let tools = [git, findExecutable(config.github.gh), findExecutable(config.claude)].compactMap { $0 }
    let folders = tools.map { ($0 as NSString).deletingLastPathComponent }
    env["PATH"] = (folders + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
    return env
  }
}
