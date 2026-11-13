import Foundation
import SwitchboardCore

/// Reads the Depot CI run of each open PR's head commit. The GitHub poller
/// calls it on its own queue after each GitHub read, so it sees the head
/// commit and rollup state that the read just gave.
final class DepotPoller {
  let settings: DepotSettings
  private var credentials: (token: String, org: String?)?
  /// What the poller last read for each PR, by node id.
  private var reads: [String: DepotRead] = [:]
  private var lastError: String?

  struct Result {
    /// What the poller read for each PR that it read this poll, by node id.
    var reads: [String: DepotRead] = [:]
    var requests = 0
    var error: String?
  }

  init(settings: DepotSettings) {
    self.settings = settings
  }

  /// Reads the due PRs among `prs`, or every open PR with `all`, and returns
  /// the run of each PR it read. The first failure ends the poll. The PRs
  /// that it didn't read keep their last run.
  func refresh(_ prs: [PullRequest], all: Bool, now: Int64, pendingMs: Int64, idleMs: Int64) -> Result {
    var result = Result()
    let open = prs.filter { $0.state == .open }
    let ids = Set(open.map(\.id))
    reads = reads.filter { ids.contains($0.key) }
    for pr in open
    where all || Depot.isDue(reads[pr.id], pr: pr, now: now, pendingMs: pendingMs, idleMs: idleMs) {
      do {
        let read = try self.read(pr, all: all, now: now, requests: &result.requests)
        reads[pr.id] = read
        result.reads[pr.id] = read
      } catch {
        // The PR keeps its last run and is due again at the next poll.
        reads[pr.id]?.at = 0
        if let error = error as? Unauthorized {
          credentials = nil
          result.error = error.message
        } else {
          result.error = "depot: \(error)"
        }
        // An unreachable Depot would make every PR wait for the timeout.
        break
      }
    }
    if result.error != lastError, let error = result.error { logLine(error) }
    lastError = result.error
    return result
  }

  /// A known run that hasn't ended needs only its status. Otherwise the PR's
  /// runs say which run tests the head commit. A run that ended keeps the
  /// status that the poller read unless the list shows that it changed.
  private func read(_ pr: PullRequest, all: Bool, now: Int64, requests: inout Int) throws -> DepotRead {
    let last = reads[pr.id].flatMap { $0.headSha == pr.headSha ? $0 : nil }
    var hasRuns = true
    var runId: String?
    var listed: String?
    if let run = last?.run, run.isRunning, !all {
      runId = run.id
    } else {
      let list = try call("ListRuns", Depot.listRunsBody(repo: pr.repo, number: pr.number), requests: &requests)
      hasRuns = Depot.hasRuns(list)
      let head = Depot.headRun(list, headSha: pr.headSha)
      runId = head?.id
      listed = head?.status
    }
    var run: DepotRun?
    if let runId {
      if let kept = last?.run, kept.id == runId, !kept.isRunning, kept.status == listed {
        run = kept
      } else {
        run = Depot.run(try call("GetRunStatus", ["runId": .string(runId)], requests: &requests), headSha: pr.headSha)
      }
    }
    return DepotRead(headSha: pr.headSha, checks: pr.checks, hasRuns: hasRuns, run: run, at: now)
  }

  struct Unauthorized: Error {
    var message: String
  }

  private func call(_ method: String, _ body: JSON, requests: inout Int) throws -> JSON {
    guard let url = URL(string: "\(settings.url)/\(Depot.service)/\(method)") else {
      throw APIError("bad depot url \(settings.url)")
    }
    let (token, org) = try currentCredentials()
    var headers = ["Authorization": "Bearer \(token)"]
    if let org { headers["x-depot-org"] = org }
    let (status, _, data) = try postJSON(url, headers: headers, body: body)
    requests += 1
    let json = JSON.parse(data)
    let message = oneLine(json?["message"]?.string ?? "", max: 120)
    if status == 401 {
      throw Unauthorized(message: "depot: \(message.isEmpty ? "unauthorized" : message); run `depot login`")
    }
    guard status == 200, let json else { throw APIError("Depot answered \(status) \(message)") }
    return json
  }

  private func currentCredentials() throws -> (token: String, org: String?) {
    if let credentials { return credentials }
    let found = settings.credentials(environment: ProcessInfo.processInfo.environment) {
      try? String(contentsOfFile: $0, encoding: .utf8)
    }
    guard let found else {
      throw Unauthorized(message: "depot: no token; run `depot login` or set depot.token in config.json")
    }
    credentials = found
    return found
  }
}
