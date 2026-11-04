import Foundation
import SwitchboardCore

/// Reads and writes the plan documents that groups and sessions have
/// attached. `plans/plan-documents.md` in the notes repo describes them.
extension GitHubPoller {
  /// What the poller remembers about one plan: its last read and its last auto update write.
  struct TrackedPlan {
    var checked: Int64 = 0
    var modified: Date?
    var etag: String?
    var pullEtag: String?
    /// The repo and branch that hold a PR plan's file.
    var head: (repo: String, branch: String)?
    /// When auto update last tried to write the table.
    var tried: Int64?
  }

  /// A REST answer with its status, ETag, and JSON.
  struct RESTReply {
    var status: Int
    var etag: String?
    var json: JSON?
  }

  static let maxWriteAttempts = 3

  // MARK: Reads

  /// Reads each plan that is due: a file whose modification time changed,
  /// and a GitHub plan once per idle interval. A failed read records its
  /// error on the plan and doesn't stop the others.
  func refreshPlans(all: Bool, now: Int64, stats: inout Stats) {
    let plans = service.queue.sync { Array(service.plans.values) }
    trackedPlans = trackedPlans.filter { id, _ in plans.contains { $0.id == id } }
    for plan in plans {
      let due =
        plan.source.kind == .file || all
        || GitHub.elapsed(since: trackedPlans[plan.id]?.checked, settings.idleMs, now: now)
      guard due else { continue }
      do {
        guard let text = try fetchPlan(plan, all: all, now: now, stats: &stats) else { continue }
        stats.planReads += 1
        service.queue.sync { service.updatePlan(plan.id) { $0.update(from: text, now: now) } }
      } catch {
        // Without the ETags, the next read gets a 200. That read clears the error even when the document hasn't changed.
        trackedPlans[plan.id]?.etag = nil
        trackedPlans[plan.id]?.pullEtag = nil
        service.queue.sync { service.recordPlanError(plan.id, error) }
      }
    }
  }

  /// The document's text, or nil when it hasn't changed since the last read.
  /// With `all`, a file is read whether or not it changed.
  func fetchPlan(_ plan: PlanDocument, all: Bool, now: Int64, stats: inout Stats) throws -> String? {
    var read = trackedPlans[plan.id] ?? TrackedPlan()
    defer { trackedPlans[plan.id] = read }
    read.checked = now
    let source = plan.source
    switch source.kind {
    case .file:
      let path = source.path ?? ""
      let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
      guard all || modified == nil || modified != read.modified else { return nil }
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw APIError("can't read \(path)") }
      read.modified = modified
      return text
    case .issue:
      let reply = try rest("GET", issuePath(source), etag: read.etag, stats: &stats)
      if reply.status == 304 { return nil }
      guard reply.status == 200, let body = reply.json?["body"] else { throw failure(reply, "issue \(source.text)") }
      read.etag = reply.etag
      return body.string ?? ""
    case .pr:
      let pull = try rest("GET", pullPath(source), etag: read.pullEtag, stats: &stats)
      if pull.status != 304 {
        guard pull.status == 200, let json = pull.json else { throw failure(pull, "PR \(source.ref)") }
        read.head = try head(json, source)
        read.pullEtag = pull.etag
        read.etag = nil
      }
      guard let head = read.head else { throw APIError("no head branch for PR \(source.ref)") }
      let file = try rest(
        "GET", contentsPath(head.repo, source), query: ["ref": head.branch], etag: read.etag, stats: &stats)
      if file.status == 304 { return nil }
      let (text, _) = try contents(file, source)
      read.etag = file.etag
      return text
    }
  }

  /// The PRs that the plans' rows link, for the poll to read. It leaves out a
  /// deployed PR, because a deployed PR stays deployed.
  func planKeys() -> Set<PRKey> {
    Set(planLinks { $0.now != .deployed }.map { .number(repo: $0.repo, number: $0.number) })
  }

  private func planLinks(_ include: (PlanRow.PR) -> Bool = { _ in true }) -> Set<PlanLink> {
    service.queue.sync { Set(service.plans.values.flatMap { $0.rows.flatMap(\.prs) }.filter(include).map(\.link)) }
  }

  /// Updates each row PR's stage from this poll's reads, moves the sessions
  /// that group plans link into their groups, and writes the generated table
  /// of each plan with auto update that changed.
  func updatePlans(all: Bool, now: Int64, stats: inout Stats) {
    var stages: [PlanLink: PlanStage] = [:]
    for link in planLinks() { stages[link] = stage(of: link) }
    service.queue.sync {
      for id in service.plans.keys { service.updatePlan(id) { $0.setStages { stages[$0] } } }
      service.joinPlanGroups()
    }
    // Auto update writes at most once per idle interval. Otherwise a busy group adds a commit to a PR at every poll.
    let due = service.queue.sync {
      service.plans.values.filter { p in
        p.autoUpdate && p.statusBlock != nil
          && (all || GitHub.elapsed(since: trackedPlans[p.id]?.tried, settings.idleMs, now: now))
          && Plans.block(service.planTable(p)) != p.statusBlock
      }.map(\.id)
    }
    for id in due.sorted() {
      trackedPlans[id, default: TrackedPlan()].tried = now
      if (try? writePlan(id, now: now, stats: &stats)) == true { stats.planWrites += 1 }
    }
  }

  /// The PR's stage as this poller last read it, or nil when it hasn't read
  /// the PR. A merged PR is deployed once its deploy comment shows both prod
  /// regions deployed.
  private func stage(of link: PlanLink) -> PlanStage? {
    guard let id = targets[.number(repo: link.repo, number: link.number)]?.prId, let read = prs[id] else {
      return nil
    }
    switch read.pr.state {
    case .open: return .open
    case .closed: return .closed
    case .merged: return deployedToProd(read.comments) ? .deployed : .merged
    }
  }

  // MARK: Writes

  /// Writes the plan's generated table, and returns false when the document
  /// already held it. It takes the table from the service's state when it
  /// starts. It records a failure on the plan before it throws.
  @discardableResult
  func writePlan(_ id: String, now: Int64, stats: inout Stats) throws -> Bool {
    guard let (plan, table) = service.queue.sync(execute: { service.plans[id].map { ($0, service.planTable($0)) } })
    else { throw APIError("no plan \(id)") }
    let written: String?
    do {
      switch plan.source.kind {
      case .file: written = try writeFile(plan.source, table)
      case .issue: written = try writeIssue(plan.source, table, stats: &stats)
      case .pr: written = try writePRFile(plan.source, table, stats: &stats)
      }
    } catch {
      service.queue.sync { service.recordPlanError(id, error) }
      throw error
    }
    guard let written else { return false }
    service.queue.sync { service.updatePlan(id) { $0.update(from: written, now: now) } }
    return true
  }

  /// Each write returns the new text, or nil when the document already held the table.
  private func writeFile(_ source: PlanSource, _ table: String) throws -> String? {
    let path = source.path ?? ""
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw APIError("can't read \(path)") }
    let new = try Plans.splice(text, table)
    guard new != text else { return nil }
    try new.write(toFile: path, atomically: true, encoding: .utf8)
    return new
  }

  /// GitHub has no conditional PATCH. Before the PATCH, a GET with the first
  /// read's ETag checks that nobody edited the body since. When `updated_at`
  /// moved, the table goes into the new body, which is checked again.
  private func writeIssue(_ source: PlanSource, _ table: String, stats: inout Stats) throws -> String? {
    let path = issuePath(source)
    var reply = try rest("GET", path, stats: &stats)
    for _ in 0..<GitHubPoller.maxWriteAttempts {
      guard reply.status == 200, let json = reply.json else { throw failure(reply, "issue \(source.text)") }
      let body = json["body"]?.string ?? ""
      let new = try Plans.splice(body, table)
      guard new != body else { return nil }
      let check = try rest("GET", path, etag: reply.etag, stats: &stats)
      if check.status == 304 || (check.status == 200 && check.json?["updated_at"] == json["updated_at"]) {
        let patched = try rest("PATCH", path, body: ["body": .string(new)], stats: &stats)
        guard patched.status == 200 else { throw failure(patched, "issue \(source.text)") }
        return new
      }
      reply = check
    }
    throw APIError("issue \(source.text) kept changing. Try again")
  }

  /// The contents API refuses a write whose blob SHA is stale with a 409.
  /// The write then reads the file again and retries.
  private func writePRFile(_ source: PlanSource, _ table: String, stats: inout Stats) throws -> String? {
    let pull = try rest("GET", pullPath(source), stats: &stats)
    guard pull.status == 200, let json = pull.json else { throw failure(pull, "PR \(source.ref)") }
    guard json["state"]?.string == "open" else { throw APIError("PR \(source.ref) is not open") }
    let head = try head(json, source)
    let path = contentsPath(head.repo, source)
    for _ in 0..<GitHubPoller.maxWriteAttempts {
      let file = try rest("GET", path, query: ["ref": head.branch], stats: &stats)
      let (text, sha) = try contents(file, source)
      let new = try Plans.splice(text, table)
      guard new != text else { return nil }
      let body: JSON = [
        "message": "Update the Switchboard status table", "content": .string(Data(new.utf8).base64EncodedString()),
        "sha": .string(sha), "branch": .string(head.branch),
      ]
      let put = try rest("PUT", path, body: body, stats: &stats)
      if put.status == 200 || put.status == 201 { return new }
      guard put.status == 409 else { throw failure(put, "\(source.path ?? "") in PR \(source.ref)") }
    }
    throw APIError("\(source.path ?? "") in PR \(source.ref) kept changing. Try again")
  }

  // MARK: REST

  private func issuePath(_ s: PlanSource) -> String { "repos/\(s.repo ?? "")/issues/\(s.number ?? 0)" }
  private func pullPath(_ s: PlanSource) -> String { "repos/\(s.repo ?? "")/pulls/\(s.number ?? 0)" }

  private func contentsPath(_ repo: String, _ s: PlanSource) -> String {
    let file = (s.path ?? "").split(separator: "/").map {
      $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? String($0)
    }
    return "repos/\(repo)/contents/" + file.joined(separator: "/")
  }

  /// The repo and branch of a PR's head. A fork that was deleted has none.
  private func head(_ pull: JSON, _ source: PlanSource) throws -> (repo: String, branch: String) {
    guard let repo = pull["head"]?["repo"]?["full_name"]?.string, let branch = pull["head"]?["ref"]?.string else {
      throw APIError("PR \(source.ref) has no head branch")
    }
    return (repo, branch)
  }

  /// The text and blob SHA of a contents answer.
  private func contents(_ reply: RESTReply, _ source: PlanSource) throws -> (String, String) {
    let what = "\(source.path ?? "") in PR \(source.ref)"
    guard reply.status == 200, let json = reply.json else { throw failure(reply, what) }
    // For a file over 1 MB, the contents API sends empty content with the encoding "none".
    guard json["encoding"]?.string == "base64", let encoded = json["content"]?.string, let sha = json["sha"]?.string,
      let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
    else { throw APIError("GitHub sent no content for \(what)") }
    return (String(decoding: data, as: UTF8.self), sha)
  }

  private func failure(_ reply: RESTReply, _ what: String) -> APIError {
    APIError("GitHub answered \(reply.status) for \(what): \(GitHub.message(reply.json))")
  }

  /// Sends one REST request. A request with `etag` gets a 304 when nothing changed.
  private func rest(
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
}
