import Foundation
import SwitchboardCore

/// The deploy waits that name a service, which PostHog/charts' state files and
/// deploy runs decide. `plans/deploy-poller.md` in the notes repo describes
/// them. A deploy wait without a service resolves from the PR's deploy
/// comment, which the status query already reads.
extension GitHubPoller {
  /// What the poller read for the deploy waits that name a service.
  struct Deploys {
    enum StateFile {
      case missing
      case read(ServiceDeployState)
      /// The file exists, and `ServiceDeployState.parse` can't read it.
      case unreadable
    }

    /// Each service's state file, its ETag, and when the poller last asked for it.
    var files: [String: (file: StateFile, etag: String?, checked: Int64)] = [:]
    /// The compare result of `<repository> <deployed> <merge>`. It never
    /// changes for two given commits.
    var ancestry: [String: DeployedAncestry] = [:]
    /// The PostHog/charts commit `deploy <service> from <repository>@<commit>`,
    /// by `<service> <repository> <commit>`.
    var chartsCommits: [String: String] = [:]
    /// The state-deploy.yml run on each charts commit.
    var runs: [String: (id: Int, url: String)] = [:]
    /// The environments that each target's last check decided, by target id.
    var progress: [String: [DeployEnvironment: EnvironmentDeploy]] = [:]
    /// When the poller first saw each deploy edge's target, by target id.
    var firstSeen: [String: Int64] = [:]
  }

  /// A merged PR whose deploy of a service the poller checks.
  struct DeployTarget {
    var id: String
    var service: String
    var pr: PullRequest
    var merge: String
    var environments: [DeployEnvironment]
    /// When the target appeared. A state file read before then doesn't decide it.
    var since: Int64
  }

  /// The open deploy waits that name a service and whose PR merged. The
  /// deploy edges that name one are in `edgeDeployTargets`.
  func deployTargets(_ interest: Interest) -> [DeployTarget] {
    interest.waits.compactMap { session, wait in
      guard wait.kind == .deploy, let service = wait.service, mayRead(Wait.chartsRepository, for: session.host),
        let id = prId(of: wait, session: session), let pr = prs[id]?.pr, pr.state == .merged,
        let merge = pr.mergeCommit
      else { return nil }
      return DeployTarget(
        id: wait.id, service: service, pr: pr, merge: merge, environments: wait.deployEnvironments,
        since: wait.created)
    }
  }

  /// Reads the state file of each service that a deploy target names, once
  /// per `deployMs`, and at once for a target that appeared since the last
  /// read. For each environment of each target, it compares the commit that
  /// the environment runs with the PR's merge commit, and reads the sync job
  /// of the charts run that deploys that commit.
  func checkDeploys(_ targets: [DeployTarget], all: Bool, now: Int64, stats: inout Stats) throws {
    let services = Set(targets.map(\.service))
    let ids = Set(targets.map(\.id))
    deploys.files = deploys.files.filter { services.contains($0.key) }
    deploys.progress = deploys.progress.filter { ids.contains($0.key) }
    deploys.firstSeen = deploys.firstSeen.filter { ids.contains($0.key) }
    if targets.isEmpty {
      deploys.ancestry = [:]
      deploys.chartsCommits = [:]
      deploys.runs = [:]
      return
    }
    var failure: Error?
    for service in services.sorted() {
      let group = targets.filter { $0.service == service }
      let checked = deploys.files[service]?.checked
      guard
        all || GitHub.elapsed(since: checked, settings.deployMs, now: now)
          || group.contains(where: { $0.since > checked ?? 0 })
      else { continue }
      // A failure stops only this service's check. The poll reports the first one.
      do {
        try checkService(service, group, now: now, stats: &stats)
      } catch {
        failure = failure ?? error
      }
    }
    if let failure { throw failure }
  }

  private func checkService(_ service: String, _ group: [DeployTarget], now: Int64, stats: inout Stats) throws {
    try readStateFile(service, now: now, stats: &stats)
    guard case .read(let state)? = deploys.files[service]?.file else { return }
    var commits: JSON?
    var jobs: [Int: JSON] = [:]
    for t in group {
      // A compare in the PR's repository would fail.
      guard state.builds(from: t.pr.repo) else { continue }
      var environments: [DeployEnvironment: EnvironmentDeploy] = [:]
      for environment in t.environments {
        guard let deployed = state.commit(for: environment) else { continue }
        let ancestry = try self.ancestry(t.pr.repo, deployed: deployed, merge: t.merge, stats: &stats)
        var run: (id: Int, url: String)?
        var sync: ChartsDeployJobs.State?
        if ancestry == .contains, state.needsSync(in: environment) {
          run = try self.run(service, t.pr.repo, deployed, commits: &commits, stats: &stats)
          if let run {
            let runJobs =
              try jobs[run.id]
              ?? get("repos/\(Wait.chartsRepository)/actions/runs/\(run.id)/jobs?per_page=100", stats: &stats)
            jobs[run.id] = runJobs
            sync = ChartsDeployJobs.states(runJobs, app: service)[environment]
          }
        }
        environments[environment] = EnvironmentDeploy(
          state: .of(state, in: environment, ancestry: ancestry, sync: sync), run: run?.url)
      }
      deploys.progress[t.id] = environments
    }
  }

  /// What happened to a deploy wait, from its PR and comments, or from the
  /// last check of its service, with the time of the merge or close that settled it when one did. The state files
  /// are shared by every session, so a session on a host whose `repos` don't list the charts repo gets no outcome
  /// from them.
  func deployOutcome(_ wait: Wait, _ pr: PullRequest, _ comments: [PRComment], host: String?) -> Wait.Settlement? {
    if let settled = wait.deploySettlement(of: pr, comments: comments) { return settled }
    guard pr.state == .merged, let service = wait.service, mayRead(Wait.chartsRepository, for: host),
      let read = serviceRead(service, id: wait.id, since: wait.created)
    else { return nil }
    return wait.serviceDeploySettlement(read.state, pr: pr, environments: read.progress)
  }

  /// The service's state file and a target's progress from the last check,
  /// or nil when the poller has no read of the file since `since` or can't
  /// read it.
  func serviceRead(_ service: String, id: String, since: Int64) -> (
    state: ServiceDeployState?, progress: [DeployEnvironment: EnvironmentDeploy]
  )? {
    guard let read = deploys.files[service], read.checked >= since else { return nil }
    switch read.file {
    case .missing: return (nil, [:])
    case .read(let state): return (state, deploys.progress[id] ?? [:])
    case .unreadable: return nil
    }
  }

  /// Asks for `state/<service>.yaml` with the last ETag. A 304 keeps the last
  /// copy and costs no quota.
  private func readStateFile(_ service: String, now: Int64, stats: inout Stats) throws {
    let path = "repos/\(Wait.chartsRepository)/contents/state/\(service).yaml"
    let last = deploys.files[service]
    var req = try client.apiRequest(path)
    req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
    if let etag = last?.etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let (status, headers, body, _) = try client.send(req, stats: &stats)
    switch status {
    case 304 where last != nil:
      deploys.files[service]?.checked = now
    case 404:
      deploys.files[service] = (.missing, nil, now)
    case 200:
      let yaml = String(decoding: body, as: UTF8.self)
      let file = ServiceDeployState.parse(service: service, yaml: yaml).map(Deploys.StateFile.read) ?? .unreadable
      if case .unreadable = file { logLine("github: can't read state/\(service).yaml") }
      deploys.files[service] = (file, headers["etag"], now)
    default:
      throw APIError("GitHub answered \(status) for \(path)")
    }
  }

  private func ancestry(_ repository: String, deployed: String, merge: String, stats: inout Stats) throws
    -> DeployedAncestry
  {
    let key = "\(repository.lowercased()) \(deployed) \(merge)"
    if let known = deploys.ancestry[key] { return known }
    let path = DeployedAncestry.comparePath(repository: repository, deployed: deployed, merge: merge)
    let response = try get(path + "?per_page=1", stats: &stats)
    guard let status = response["status"]?.string, let ancestry = DeployedAncestry(compareStatus: status) else {
      throw APIError("GitHub's compare of \(deployed) and \(merge) has no known status")
    }
    deploys.ancestry[key] = ancestry
    return ancestry
  }

  /// The state-deploy.yml run on the charts commit `deploy <service> from
  /// <repository>@<commit>`, or nil while either doesn't exist yet. `commits`
  /// holds the state file's commit list once one check read it.
  private func run(
    _ service: String, _ repository: String, _ commit: String, commits: inout JSON?, stats: inout Stats
  ) throws -> (id: Int, url: String)? {
    let charts = "repos/\(Wait.chartsRepository)"
    let key = "\(service) \(repository.lowercased()) \(commit)"
    if deploys.chartsCommits[key] == nil {
      let list = try commits ?? get("\(charts)/commits?path=state/\(service).yaml&per_page=30", stats: &stats)
      commits = list
      deploys.chartsCommits[key] =
        list.array?.first(where: { c in
          guard let deploy = c["commit"]?["message"]?.string.flatMap(ChartsDeployCommit.init(message:)) else {
            return false
          }
          return deploy.app == service && deploy.commit == commit
            && Dependencies.sameRepo(deploy.repository, repository)
        })?["sha"]?.string
    }
    guard let sha = deploys.chartsCommits[key] else { return nil }
    if let known = deploys.runs[sha] { return known }
    let runs = try get("\(charts)/actions/workflows/state-deploy.yml/runs?head_sha=\(sha)&per_page=1", stats: &stats)
    guard let run = runs["workflow_runs"]?.array?.first, let id = run["id"]?.int else { return nil }
    let found = (id: id, url: run["html_url"]?.string ?? "")
    deploys.runs[sha] = found
    return found
  }
}
