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
  /// returns that row. It takes the state queue itself, because docket runs
  /// for seconds.
  func startDocket(_ args: JSON) throws -> SessionSummary {
    guard let input = args["pr"]?.string?.trimmingCharacters(in: .whitespaces), !input.isEmpty else {
      throw APIError("name a pull request as a URL, org/repo#123, or a number that docket's default_repo completes")
    }
    let existing = args["existing"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    if let existing, !["append", "overwrite"].contains(existing) {
      throw APIError("--existing takes append or overwrite")
    }
    let wanted = DocketRef.normalize(input)
    if let id = queue.sync(execute: { openDocketRow(wanted) }) { return queue.sync { summary(id) } }
    let review = try withDocket { client in
      if let open = try client.listReviews().first(where: { $0.pullRequest == wanted }) { return open }
      var arguments: [String: JSON] = ["pull_request": .string(input)]
      if let existing { arguments["existing"] = .string(existing) }
      guard let started = try client.call("start_review", .object(arguments))["review"] else {
        throw APIError("docket's start_review returned no review")
      }
      return try DocketClient.review(started)
    }
    return try queue.sync {
      // A bare number only matches once docket names the PR.
      if let id = openDocketRow(review.pullRequest) { return summary(id) }
      let parent = try args["parent"]?.string.map { try lookup(["session": .string($0)]) }
      var session = Session(
        id: shortId("s", taken: entries.keys), name: args["name"]?.string ?? "review \(review.pullRequest)", cwd: "",
        claudeSessionId: UUID().uuidString.lowercased(), created: nowMs())
      session.parent = parent
      session.group = try groupOfNew(args["group"]?.string, parent: parent)
      session.docket = DocketSession(pullRequest: review.pullRequest, url: review.url)
      entries[session.id] = Entry(session: session)
      try store.save(session)
      record(session.id, "docket", ["review": try JSON(encoding: review)])
      docketPoll.last = nowMs()
      return summary(session.id)
    }
  }

  /// Asks docket about the open reviews once `docket.pollSeconds` have passed
  /// on sbd's clock since the last ask. The tick calls it on the state queue.
  /// The ask runs on a queue of its own and records what changed.
  func pollDocketsIfDue(now: Int64) {
    guard !docketPoll.running, now - docketPoll.last >= Int64(config.docket.pollSeconds * 1000) else { return }
    let rows = openDocketRows()
    guard !rows.isEmpty else { return }
    docketPoll.running = true
    docketPoll.last = now
    Service.docketQueue.async { [self] in
      let result = Result { try withDocket { try $0.listReviews() } }
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
    for id in rows {
      guard let e = entries[id], let pr = e.session.docket?.pullRequest else { continue }
      guard let review = reviews.last(where: { $0.pullRequest == pr }) else {
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

  private func openDocketRow(_ pullRequest: String) -> String? {
    openDocketRows().first { entries[$0]?.session.docket?.pullRequest == pullRequest }
  }

  /// Runs `docket mcp` and passes the client to `body`.
  private func withDocket<T>(_ body: (DocketClient) throws -> T) throws -> T {
    guard let docket = findExecutable(config.docket.path) else {
      throw APIError("can't find docket. Set docket.path in \(home.path)/config.json")
    }
    return try DocketClient.run(docket: docket, env: docketEnvironment(), timeout: config.docket.timeoutSeconds, body)
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
