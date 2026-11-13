import Foundation

/// The `depot` object in config.json.
public struct DepotSettings: Codable, Equatable, Sendable {
  /// The API base. A call is a POST to <url>/depot.ci.v1.CIService/<method>.
  public var url = "https://api.depot.dev"
  /// The API token. Without it, sbd reads DEPOT_TOKEN, then `api_token` from
  /// the depot CLI's config.
  public var token: String?
  /// The organization, sent as x-depot-org. Depot needs it only when the
  /// token's user belongs to several organizations.
  public var org: String?
  /// The depot CLI's config, which `depot login` writes.
  public var config = "~/Library/Application Support/depot/depot.yaml"
  public var enabled = true

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = DepotSettings()
    url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
    token = try c.decodeIfPresent(String.self, forKey: .token)
    org = try c.decodeIfPresent(String.self, forKey: .org)
    config = try c.decodeIfPresent(String.self, forKey: .config) ?? d.config
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
  }

  /// The token and organization from the settings, then DEPOT_TOKEN, then the
  /// depot CLI's config. The organization from the CLI's config counts only
  /// with that file's token.
  public func credentials(environment: [String: String], readConfig: (String) -> String?) -> (
    token: String, org: String?
  )? {
    if let token, !token.isEmpty { return (token, org) }
    if let token = environment["DEPOT_TOKEN"], !token.isEmpty { return (token, org) }
    guard let text = readConfig(config.expandingTilde) else { return nil }
    let values = YAMLScalars.read(text)
    guard let token = values["api_token"], !token.isEmpty else { return nil }
    return (token, org ?? values["org_id"])
  }
}

/// A Depot CI run of a PR's head commit, as the Depot poller last read it.
public struct DepotRun: Codable, Equatable, Sendable {
  public struct Job: Codable, Equatable, Sendable {
    public var name: String
    /// The job's page on depot.dev.
    public var url: String?

    public init(name: String, url: String? = nil) {
      self.name = name
      self.url = url
    }
  }

  public var id: String
  /// The PR head commit that the run tests.
  public var headSha: String
  /// queued, running, finished, failed, or cancelled.
  public var status: String
  /// The number of jobs. It leaves out how many ended, which changes as each
  /// job finishes and would record a `pr` event on every poll of a run.
  public var jobs: Int
  /// The failed jobs, in Depot's order.
  public var failed: [Job]
  /// The error messages of the workflows that failed to start, such as a
  /// workflow file that doesn't compile.
  public var errors: [String]

  public init(
    id: String, headSha: String, status: String, jobs: Int = 0, failed: [Job] = [], errors: [String] = []
  ) {
    self.id = id
    self.headSha = headSha
    self.status = status
    self.jobs = jobs
    self.failed = failed
    self.errors = errors
  }

  public var isRunning: Bool { status == "queued" || status == "running" }

  /// A failed job is final while the run still runs, so a failure counts
  /// before the run ends.
  public var hasFailure: Bool { !failed.isEmpty || status == "failed" }

  /// The failure in a few words, such as "Django tests – Core and 2 more",
  /// in at most `max` characters. A long job name is cut, not the count.
  public func failureSummary(max: Int = .max) -> String {
    guard let first = failed.first else { return oneLine(errors.first ?? "the run failed", max: max) }
    let more = failed.count == 1 ? "" : " and \(failed.count - 1) more"
    return oneLine(first.name, max: Swift.max(max - more.count, 10)) + more
  }

  /// The outcome of a `ci` wait that this run's failure resolves. It names
  /// the run, which `depot ci diagnose --run` takes.
  public var outcome: String { "Depot CI failed: \(failureSummary()) (run \(id))" }

  /// The run in one line, such as "failed, 90 jobs, 3 failed: … (run x)".
  public var line: String {
    var text = status
    if jobs > 0 { text += ", \(jobs) jobs" }
    if hasFailure { text += ", \(failed.count) failed: \(failureSummary())" }
    return text + " (run \(id))"
  }
}

/// What the Depot poller last read for one PR.
public struct DepotRead: Equatable, Sendable {
  /// The PR's head commit and rollup state at the read.
  public var headSha: String
  public var checks: String?
  /// Whether Depot has any run of the PR. A repo that doesn't use Depot has none.
  public var hasRuns: Bool
  /// The run of the head commit.
  public var run: DepotRun?
  public var at: Int64

  public init(headSha: String, checks: String?, hasRuns: Bool, run: DepotRun?, at: Int64) {
    self.headSha = headSha
    self.checks = checks
    self.hasRuns = hasRuns
    self.run = run
    self.at = at
  }
}

/// The pure parts of the Depot poller. It reads Depot's Connect API, whose
/// unary calls take and return JSON over HTTP/1.1.
public enum Depot {
  public static let service = "depot.ci.v1.CIService"
  static let statuses: [JSON] = ["queued", "running", "finished", "failed", "cancelled"]

  /// The ListRuns body for a PR. Without `status`, Depot lists only queued
  /// and running runs.
  public static func listRunsBody(repo: String, number: Int) -> JSON {
    ["repo": .string(repo), "pr": .string(String(number)), "status": .array(statuses), "pageSize": 20]
  }

  /// The runs in a ListRuns response.
  static func runs(_ response: JSON) -> [JSON] { response["runs"]?.array ?? [] }

  public static func hasRuns(_ response: JSON) -> Bool { !runs(response).isEmpty }

  /// The id and status of the PR's newest run in a ListRuns response, when
  /// it tests `headSha`. A newer run of another commit means that GitHub's
  /// read still shows the head commit from before a push, so no run counts.
  public static func headRun(_ response: JSON, headSha: String) -> (id: String, status: String?)? {
    let newest = runs(response).max { ($0["createdAt"]?.string ?? "") < ($1["createdAt"]?.string ?? "") }
    guard let newest, newest["headSha"]?.string == headSha, let id = newest["runId"]?.string else { return nil }
    return (id, newest["status"]?.string)
  }

  /// The run in a GetRunStatus response.
  public static func run(_ response: JSON, headSha: String) -> DepotRun? {
    guard let id = response["runId"]?.string, let status = response["status"]?.string else { return nil }
    let org = response["orgId"]?.string
    var run = DepotRun(id: id, headSha: headSha, status: status)
    for workflow in response["workflows"]?.array ?? [] {
      if let message = workflow["errorMessage"]?.string, !message.isEmpty { run.errors.append(message) }
      for job in workflow["jobs"]?.array ?? [] {
        run.jobs += 1
        guard job["status"]?.string == "failed" else { continue }
        let name = job["jobDisplayName"]?.string ?? job["jobKey"]?.string ?? "a job"
        var url: String?
        if let org, let workflowId = workflow["workflowId"]?.string, let jobId = job["jobId"]?.string {
          url = "https://depot.dev/orgs/\(org)/workflows/\(workflowId)?job=\(jobId)"
        }
        run.failed.append(DepotRun.Job(name: name, url: url))
      }
    }
    return run
  }

  /// Whether an open PR is due for a Depot read at `now`. A new head commit
  /// or rollup state is due at once. A run that hasn't ended, or a PR whose
  /// head commit has no run yet, is due after `pendingMs`. A PR with no runs,
  /// as in a repo that doesn't use Depot, or a run that ended, is due after
  /// `idleMs`, since a retry can start a finished run again.
  public static func isDue(_ last: DepotRead?, pr: PullRequest, now: Int64, pendingMs: Int64, idleMs: Int64)
    -> Bool
  {
    guard let last, last.headSha == pr.headSha, last.checks == pr.checks else { return true }
    let pending = last.hasRuns && (last.run?.isRunning ?? true)
    return GitHub.elapsed(since: last.at, pending ? pendingMs : idleMs, now: now)
  }
}

extension PullRequest {
  /// The Depot run of the head commit. `depot` can hold an earlier one's.
  public var headDepot: DepotRun? { depot?.headSha == headSha ? depot : nil }

  /// The Depot run of the open PR's head commit when it has a failure, while
  /// GitHub's rollup doesn't show that every check passed.
  public var depotFailure: DepotRun? {
    guard state == .open, !checksPassed, let run = headDepot, run.hasFailure else { return nil }
    return run
  }

  /// `depotFailure`, unless Trunk has queued the PR. Trunk queues a PR only
  /// after its required checks pass, so the merge does not need a job that
  /// failed on a queued PR.
  public var blockingDepotFailure: DepotRun? { queue?.isQueued == true ? nil : depotFailure }

  /// Whether GitHub's rollup failed, or a Depot job failed on the head commit.
  public var ciFailed: Bool { checksFailed || depotFailure != nil }
}
