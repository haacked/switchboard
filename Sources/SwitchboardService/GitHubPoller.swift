import Foundation
import SwitchboardCore

/// Finds each session's PR and polls GitHub for its state. One poll runs at
/// a time, on `queue`. A poll reads the sessions from the service, asks
/// GitHub off the service's queue, and records a `pr` event for each session
/// whose PR changed, and a `worktree` event when a finished PR's folder
/// changes between clean and dirty.
final class GitHubPoller {
  unowned let service: Service
  let settings: GitHubSettings
  let depot: DepotPoller?
  let trunk: TrunkPoller
  let queue = DispatchQueue(label: "sbd.github")
  private var timer: DispatchSourceTimer?

  private var token: String?
  /// After GitHub's rate limit, no request to that quota goes out before this
  /// time. GitHub counts GraphQL and REST (`core`) requests separately. Other
  /// `gh` calls with the same token spend `core`.
  private var graphQLPausedUntil: Int64 = 0
  private var restPausedUntil: Int64 = 0
  var tracked: [String: Tracked] = [:]
  /// The PRs that this sbd has read, by node id, with their comments from
  /// `GitHub.bodyAuthors`.
  var prs: [String: (pr: PullRequest, comments: [PRComment], polled: Int64)] = [:]
  /// Comment bodies by comment id. A comment whose edit time changed is read again.
  private var bodies: [String: PRComment] = [:]
  /// The Depot run that the event log held for each PR, by node id, until the
  /// first GitHub read of the PR after a restart. A Depot read that fails
  /// then keeps it.
  private var recordedDepot: [String: DepotRun] = [:]

  /// The comments of a read, with the bodies that `bodies` holds.
  func keptComments(_ comments: [PRComment]) -> [PRComment] { comments.map { bodies[$0.id] ?? $0 } }

  /// Whether the PR's last deploy comment shows both prod regions deployed.
  func deployedToProd(_ comments: [PRComment]) -> Bool {
    keptComments(comments).compactMap { $0.body.flatMap(DeployComment.parse) }.last?.deployedToProd == true
  }
  /// The PRs that waits and merge triggers name, by the key they were looked up with.
  var targets: [PRKey: Target] = [:]
  /// The `ci` waits whose outcome one read showed, by wait id. The wait resolves
  /// when a later read shows the same head commit and outcome. `outcome` is
  /// "failed" for any failure.
  var confirming: [String: (sha: String, outcome: String, polled: Int64)] = [:]
  /// The `queue` waits whose PR a read showed in GitHub's merge queue.
  /// GitHub reports no removal state, so a later read that shows the open PR
  /// outside the queue means the queue dropped it.
  var queuedWaits: Set<String> = []
  var deploys = Deploys()
  /// The PRs of edges that left a session's list before the poller read
  /// their PR again. The next poll reads them whether or not they are due.
  var recheck: Set<String> = []
  /// What the poller knows about each plan document, by plan id.
  var trackedPlans: [String: TrackedPlan] = [:]
  var codeOwners = CodeOwnerReads()
  /// Each PR's merge details, by node id, with the head commit they belong
  /// to and when the poller read them.
  var mergeDetails: [String: (head: String, read: Int64, details: MergeDetails)] = [:]

  /// What the poller knows about one session.
  struct Tracked {
    var branch = Branch()
    var transcript: Transcript
    /// When the poller last counted the uncommitted files of a finished PR's
    /// folder, and the session's last activity at that time.
    var counted: (at: Int64, activity: Int64, prId: String)?
    /// The PR that the event log held when this sbd first saw the session. It
    /// keeps a restart from losing the PR of a session whose HEAD is detached
    /// or whose conversation `/clear` replaced. The poller drops it when the
    /// branch's lookup finds a PR. It also drops it when the lookup finds none
    /// and the recorded PR is in the branch's repo with another head branch.
    var recordedPRId: String?

    /// The branch's PR comes first, then the transcript's.
    var prId: String? { branch.prId ?? transcript.prId ?? recordedPRId }
  }

  /// The folder's branch and its PR.
  struct Branch {
    var gitDir: String?
    var commonDir: String?
    var gitDirRead: Int64?
    /// The text of the HEAD file and the modification time of the repo's
    /// config when git last ran, which change with the branch or a remote.
    var head: String?
    var configStamp: Date?
    /// The branch that HEAD names, kept while HEAD is detached.
    var name: String?
    /// The session's branch in its GitHub repo, or nil outside one.
    var key: PRKey?
    /// The node id of the branch's PR.
    var prId: String?
    /// When the poller last looked the key up. nil until the first lookup.
    var lookedUp: Int64?
    /// The lowercased owner/name of each GitHub remote in the repo's config.
    /// It is empty outside git, until git first reads the config, and for a
    /// repo with no GitHub remote. A failed read keeps the remotes of the
    /// last good read.
    var repositories: Set<String> = []

    /// Whether a PR in `repo` can be the session's: one of the repo's
    /// remotes names it, or no GitHub remote is known.
    func allows(_ repo: String) -> Bool { repositories.isEmpty || repositories.contains(repo.lowercased()) }
  }

  /// The session's transcript and the PR of its last pr-link line.
  struct Transcript {
    var claudeSessionId: String
    /// The name of the project folder of the session's transcripts. A
    /// conversation that `/clear` starts writes its transcript there too.
    var folder: String?
    var path: String?
    /// The account whose folder `path` is in.
    var configDir: String?
    var offset = 0
    var link: PRKey?
    var prId: String?
    var lookedUp = false
  }

  /// The node id of a PR that an open wait or a merge trigger names, and when
  /// the poller last looked it up.
  struct Target {
    var prId: String?
    var lookedUp: Int64
  }

  /// A session as the poll sees it.
  struct Watched {
    var id: String
    var cwd: String
    var claudeSessionId: String
    var configDir: String
    /// The machine that holds the session's folder and transcript.
    var machine: any Machine
    /// The branch that sbd shows for the session.
    var branch: String?
    var facts: SessionFacts
  }

  struct Stats: Encodable {
    var lookups = 0
    var polled = 0
    var requests = 0
    var points = 0
    var changed = 0
    var resolved = 0
    var merged = 0
    var depotRequests = 0
    var depotRuns = 0
    var trunkRuns = 0
    var resumed = 0
    var planReads = 0
    var planWrites = 0
  }

  init(service: Service, settings: GitHubSettings, depot: DepotSettings, trunk: TrunkSettings) {
    self.service = service
    self.settings = settings
    self.depot = depot.enabled ? DepotPoller(settings: depot) : nil
    self.trunk = TrunkPoller(settings: trunk, intervalMs: settings.pendingMs)
  }

  func start() {
    guard settings.pollSeconds > 0 else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + settings.pollSeconds, repeating: settings.pollSeconds)
    t.setEventHandler { [self] in _ = cycle(all: false) }
    t.resume()
    timer = t
  }

  /// Runs one poll and returns what it did. With `all`, it reads every PR,
  /// looks up every branch, and counts every finished PR's folder, due or not.
  func poll(all: Bool) -> JSON {
    queue.sync { cycle(all: all) }
  }

  private func cycle(all: Bool) -> JSON {
    var stats = Stats()
    var failure: String?
    let sessions: [Watched] = service.queue.sync {
      service.entries.map { id, e in
        Watched(
          id: id, cwd: e.session.cwd, claudeSessionId: e.session.claudeSessionId,
          configDir: (service.paneEnv(id)["CLAUDE_CONFIG_DIR"] ?? "~/.claude").expandingTilde,
          machine: service.machine(for: e.session), branch: e.branch, facts: e.facts)
      }
    }
    let now = nowMs()
    let ids = Set(sessions.map(\.id))
    tracked = tracked.filter { ids.contains($0.key) }
    var shared = Shared()
    for s in sessions { refreshLocal(s, all: all, now: now, shared: &shared) }
    refreshPlans(all: all, now: now, stats: &stats)
    var interest = interests()
    interest.keys.formUnion(dependencyKeys(sessions))
    interest.keys.formUnion(planKeys())
    targets = targets.filter { interest.keys.contains($0.key) }
    do {
      try lookUp(all: all, now: now, interest: interest, stats: &stats)
      // An edge that `recordDependencies` kept reads its PR at once, as a new wait does.
      var waited = waitedOn(interest)
      for id in recheck { waited.created[id] = max(waited.created[id] ?? 0, now) }
      try readPRs(all: all, now: now, waited: waited, queued: queuedPRs(), stats: &stats)
      try checkDeploys(interest, all: all, now: now, stats: &stats)
    } catch {
      failure = "\(error)"
      logLine("github: \(error)")
    }
    let depotError = refreshDepot(all: all, now: now, stats: &stats)
    // Each status read rebuilds its PR without a requirement. The reads
    // above can throw after they rebuild some PRs, so the apply runs after
    // the catch and before `record` compares each PR.
    let codeOwnersError = readCodeOwners(all: all, now: now, stats: &stats)
    applyCodeOwners()
    stats.trunkRuns = readTrunk(sessions, all: all, now: now)
    let mergeDetailsError = readMergeDetails(sessions, now: now, stats: &stats)
    applyMergeDetails()
    for s in sessions { stats.changed += record(s, all: all, now: now) ? 1 : 0 }
    resolveWaits(interest, stats: &stats)
    recordDependencies(sessions, now: now, stats: &stats)
    updatePlans(all: all, now: now, stats: &stats)
    let kept = Set(tracked.values.compactMap(\.prId)).union(targets.values.compactMap(\.prId))
    prs = prs.filter { kept.contains($0.key) }
    recordedDepot = recordedDepot.filter { kept.contains($0.key) }
    pruneCodeOwners()
    pruneMergeDetails()
    let comments = Set(prs.values.flatMap { $0.comments.map(\.id) })
    bodies = bodies.filter { comments.contains($0.key) }
    var result = (try? JSON(encoding: stats).object) ?? [:]
    if let failure { result["error"] = .string(failure) }
    if let depotError { result["depotError"] = .string(depotError) }
    if let codeOwnersError { result["codeOwnersError"] = .string(codeOwnersError) }
    if let mergeDetailsError { result["mergeDetailsError"] = .string(mergeDetailsError) }
    if let problem = trunk.problem { result["trunkError"] = .string(problem) }
    let paused = max(graphQLPausedUntil, restPausedUntil)
    if paused > nowMs() { result["pausedUntil"] = .number(Double(paused)) }
    return .object(result)
  }

  // MARK: Local facts

  /// What one poll reads once for every session: each config dir's project
  /// folders, and each repo's git config.
  private struct Shared {
    var projects: [String: [String]] = [:]
    var configs: [String: [String: String]] = [:]
  }

  /// Reads the session's branch and the new lines of its transcript.
  private func refreshLocal(_ s: Watched, all: Bool, now: Int64, shared: inout Shared) {
    if tracked[s.id] == nil, let pr = s.facts.pr, let run = pr.depot, prs[pr.id] == nil { recordedDepot[pr.id] = run }
    var t =
      tracked[s.id] ?? Tracked(transcript: Transcript(claudeSessionId: s.claudeSessionId), recordedPRId: s.facts.pr?.id)
    let repositories = t.branch.repositories
    refreshBranch(&t.branch, cwd: s.cwd, on: s.machine, all: all, now: now, configs: &shared.configs)
    // A link that the old remotes refused can count under the new ones. A
    // link that they allowed may not. The poller reads the transcript again
    // from its start. It keeps a link that the new remotes still allow,
    // because a link from before `/clear` is not in the current transcript.
    if t.branch.repositories != repositories {
      t.transcript.offset = 0
      if case .number(let repo, _)? = t.transcript.link, !t.branch.allows(repo) {
        t.transcript.link = nil
        t.transcript.prId = nil
        t.transcript.lookedUp = false
      }
    }
    if let id = t.recordedPRId, let repo = prs[id]?.pr.repo ?? s.facts.pr.flatMap({ $0.id == id ? $0.repo : nil }),
      !t.branch.allows(repo)
    {
      t.recordedPRId = nil
    }
    // `/clear` starts another conversation, with its own transcript. The
    // session keeps the PR that the old one linked until the new one links
    // another.
    if t.transcript.claudeSessionId != s.claudeSessionId {
      t.transcript.claudeSessionId = s.claudeSessionId
      t.transcript.path = nil
      t.transcript.offset = 0
    }
    // A move to another account copies the transcript. The new copy is the
    // one that grows.
    if t.transcript.configDir != s.configDir {
      t.transcript.configDir = s.configDir
      t.transcript.folder = nil
      t.transcript.path = nil
    }
    readTranscript(
      &t.transcript, configDir: s.configDir, cwd: s.cwd, on: s.machine, projects: &shared.projects,
      accepting: t.branch.allows)
    tracked[s.id] = t
  }

  /// Reading the HEAD file and the config's modification time costs less
  /// than running git, so git runs only when either changed. A folder outside
  /// git is checked again once per idle interval.
  private func refreshBranch(
    _ b: inout Branch, cwd: String, on machine: any Machine, all: Bool, now: Int64,
    configs: inout [String: [String: String]]
  ) {
    let read = machine.text
    var head = b.gitDir.flatMap { read("\($0)/HEAD") }
    if head == nil && (all || GitHub.elapsed(since: b.gitDirRead, settings.idleMs, now: now)) {
      let dirs = git(cwd, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], on: machine)?
        .split(separator: "\n").map(String.init)
      b.gitDir = dirs?.first
      b.commonDir = dirs?.last
      b.gitDirRead = now
      head = b.gitDir.flatMap { read("\($0)/HEAD") }
    }
    let stamp = b.commonDir.flatMap { machine.modified("\($0)/config") }
    guard all || head != b.head || stamp != b.configStamp else { return }
    b.head = head
    b.configStamp = stamp
    // A rebase or a bisect detaches HEAD for a while, and the session keeps
    // its branch's PR meanwhile.
    var key = head != nil ? b.key : nil
    let branch = head.flatMap { GitHub.branch(head: $0) }
    if let branch { b.name = branch }
    if let common = b.commonDir {
      // The worktrees of a repo share its config, so git reads it once per poll.
      // git exits 1 when no key matches. A read that fails in another way keeps the last known remotes.
      if configs[common] == nil {
        let pattern = #"^(remote\..*\.(url|gh-resolved)|remote\.pushdefault|branch\..*\.(pushremote|remote|merge))$"#
        let r = try? machine.run(service.git, ["-C", cwd, "config", "--get-regexp", pattern])
        if let r, r.status <= 1 {
          configs[common] = GitHub.gitConfig(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }
      let config = configs[common] ?? [:]
      if configs[common] != nil { b.repositories = GitHub.repositories(config: config) }
      if let branch {
        key = GitHub.branchKey(branch: branch, config: config) { remote in
          // A remote's HEAD is a symbolic ref, which git never packs.
          read("\(common)/refs/remotes/\(remote)/HEAD").flatMap {
            GitHub.branch(head: $0, under: "refs/remotes/\(remote)/")
          }
        }
      }
    }
    if key != b.key {
      b.key = key
      b.prId = nil
      b.lookedUp = nil
    }
  }

  private func git(_ cwd: String, _ args: [String], on machine: any Machine) -> String? {
    try? service.gitOutput(cwd, args, on: machine)
  }

  /// Reads the transcript's lines since the last read. Until the poller knows
  /// the session's project folder, it searches every project folder. Then it
  /// looks only in the cwd's folder and that one.
  private func readTranscript(
    _ t: inout Transcript, configDir: String, cwd: String, on machine: any Machine,
    projects: inout [String: [String]], accepting: (String) -> Bool
  ) {
    if t.path == nil {
      let known = t.folder
      t.path = SwitchboardCore.Transcript.find(t.claudeSessionId, account: configDir, cwd: cwd, on: machine) { root in
        if let known { return [known] }
        if projects[root] == nil { projects[root] = machine.list(root) }
        return projects[root]!
      }
      if let path = t.path { t.folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    }
    guard let path = t.path, let size = machine.size(path), size != UInt64(t.offset) else { return }
    if size < UInt64(t.offset) { t.offset = 0 }
    guard let data = machine.read(path, from: UInt64(t.offset), count: nil), !data.isEmpty else { return }
    let (link, consumed) = GitHub.lastPRLink(in: data, accepting: accepting)
    t.offset += consumed
    if let link, link != t.link {
      t.link = link
      t.prId = nil
      t.lookedUp = false
    }
  }

  // MARK: GitHub

  /// Looks up the node ids of the branches with no known PR, and of new
  /// pr-link lines. A branch with no PR is looked up again after the idle
  /// interval, and so is a branch whose PR closed or merged, because the
  /// branch may have a new PR.
  private func lookUp(all: Bool, now: Int64, interest: Interest, stats: inout Stats) throws {
    var keys: Set<PRKey> = []
    for t in tracked.values {
      if let key = t.branch.key {
        let ended = t.branch.prId.flatMap { prs[$0]?.pr.state }.map { $0 != .open } ?? false
        if (t.branch.prId == nil || ended)
          && (all || GitHub.elapsed(since: t.branch.lookedUp, settings.idleMs, now: now))
        {
          keys.insert(key)
        }
      }
      if let link = t.transcript.link, !t.transcript.lookedUp { keys.insert(link) }
    }
    for key in interest.keys
    where all
      || targets[key].map({ $0.prId == nil && GitHub.elapsed(since: $0.lookedUp, settings.idleMs, now: now) })
        ?? true
    {
      keys.insert(key)
    }
    guard !keys.isEmpty else { return }
    var found: [PRKey: String?] = [:]
    for chunk in GitHub.chunks(Array(keys), size: GitHub.lightChunkSize) {
      let (query, variables) = GitHub.lookupQuery(chunk)
      found.merge(GitHub.parseLookup(try request(query, variables, stats: &stats), chunk)) { $1 }
    }
    stats.lookups = keys.count
    for key in interest.keys { if let result = found[key] { targets[key] = Target(prId: result, lookedUp: now) } }
    for (id, var t) in tracked {
      if let key = t.branch.key, let result = found[key] {
        t.branch.prId = result
        t.branch.lookedUp = now
        if result != nil { t.recordedPRId = nil }
      }
      if let link = t.transcript.link, let result = found[link] {
        t.transcript.prId = result
        t.transcript.lookedUp = true
      }
      tracked[id] = t
    }
  }

  /// Reads the due PRs in chunks, one request after another, then the
  /// merged base of those whose base isn't the default branch, then the
  /// bodies of the new or edited comments from `GitHub.bodyAuthors`. A PR
  /// that GitHub reports NOT_FOUND, as after a deletion, leaves its sessions,
  /// which look their PR up again after the idle interval. A PR that failed
  /// in another way keeps what the poller last read.
  private func readPRs(all: Bool, now: Int64, waited: Waited, queued: Set<String>, stats: inout Stats) throws {
    // A PR in `waited.pending` or in Trunk's queue polls like a pending PR. A
    // PR with any open wait also polls at once when the wait is newer than the
    // last read. That read can't show what happened after the wait was set.
    let ids = Set(tracked.values.compactMap(\.prId)).union(targets.values.compactMap(\.prId)).sorted().filter {
      all || (waited.created[$0] ?? 0) > (prs[$0]?.polled ?? 0)
        || GitHub.isDue(
          prs[$0]?.pr, lastPolled: prs[$0]?.polled, now: now, pendingMs: settings.pendingMs,
          idleMs: waited.pending.contains($0) || queued.contains($0) ? settings.pendingMs : settings.idleMs)
    }
    var stacked: [String] = []
    var gone: Set<String> = []
    for chunk in GitHub.chunks(ids) {
      let (read, notFound) = GitHub.parseStatus(
        try request(GitHub.statusQuery, idsVariable(chunk), stats: &stats), chunk)
      gone.formUnion(notFound)
      for (parsed, comments) in read {
        var pr = parsed
        // Only the base query reads the merged base. A PR whose base query
        // fails keeps the merged base that the poller last read.
        if let last = prs[pr.id]?.pr, last.base == pr.base { pr.mergedBase = last.mergedBase }
        pr.depot = prs[pr.id]?.pr.depot ?? recordedDepot.removeValue(forKey: pr.id)
        prs[pr.id] = (pr, comments.filter { GitHub.bodyAuthors.contains($0.author) }, now)
        if pr.base != pr.defaultBranch { stacked.append(pr.id) }
      }
      stats.polled += read.count
    }
    for (id, var t) in tracked {
      if let prId = t.branch.prId, gone.contains(prId) {
        t.branch.prId = nil
        t.branch.lookedUp = now
      }
      if let prId = t.transcript.prId, gone.contains(prId) { t.transcript.prId = nil }
      if let prId = t.recordedPRId, gone.contains(prId) { t.recordedPRId = nil }
      // A linked or recorded PR from another branch of the branch's repo
      // belongs to the session's earlier work. It no longer counts once
      // GitHub answers that the current branch has no PR. A PR in another
      // repo that a remote names, such as a fork's upstream, still counts.
      if t.branch.prId == nil, t.branch.lookedUp != nil, case .branch(let repo, let branch, _)? = t.branch.key {
        let earlier = { (id: String?) -> Bool in
          guard let pr = id.flatMap({ self.prs[$0]?.pr }) else { return false }
          return pr.repo.lowercased() == repo.lowercased() && pr.head != branch
        }
        if earlier(t.transcript.prId) { t.transcript.prId = nil }
        if earlier(t.recordedPRId) { t.recordedPRId = nil }
      }
      tracked[id] = t
    }
    for (key, target) in targets {
      if let prId = target.prId, gone.contains(prId) { targets[key] = Target(prId: nil, lookedUp: now) }
    }
    for chunk in GitHub.chunks(stacked) {
      let response = try request(GitHub.baseQuery, idsVariable(chunk), stats: &stats)
      for (id, base) in (response["data"]?["nodes"]?.array ?? []).compactMap(GitHub.parseMergedBase) {
        prs[id]?.pr.mergedBase = base
      }
    }
    // A body that the poller read after its PR's status can carry a newer
    // edit time. A comment that GitHub reports NOT_FOUND, as after a
    // deletion, keeps the status response's copy, which has no body. The
    // poller reads either again only when a status response shows a newer
    // edit time. A body that failed in another way is read again at the next
    // poll.
    let stale = prs.values.flatMap(\.comments).filter { c in
      bodies[c.id].map { ($0.editedAt ?? "") < (c.editedAt ?? "") } ?? true
    }
    for chunk in GitHub.chunks(stale.map(\.id), size: GitHub.lightChunkSize) {
      let (read, gone) = GitHub.parseBodies(try request(GitHub.bodyQuery, idsVariable(chunk), stats: &stats), chunk)
      for comment in read { bodies[comment.id] = comment }
      for comment in stale where gone.contains(comment.id) { bodies[comment.id] = comment }
    }
  }

  /// Sets the Depot run of each PR that the Depot poller read, and returns
  /// the Depot poller's error.
  private func refreshDepot(all: Bool, now: Int64, stats: inout Stats) -> String? {
    guard let depot else { return nil }
    let result = depot.refresh(
      prs.values.map(\.pr), all: all, now: now, pendingMs: settings.pendingMs, idleMs: settings.idleMs)
    for (id, read) in result.reads { prs[id]?.pr.depot = read.run }
    stats.depotRequests = result.requests
    stats.depotRuns = result.reads.values.count { $0.run != nil }
    return result.error
  }

  func idsVariable(_ ids: [String]) -> JSON { ["ids": .array(ids.map(JSON.string))] }

  /// Sends one GraphQL request and returns the response, whose `data` isn't
  /// null.
  func request(_ query: String, _ variables: JSON, stats: inout Stats) throws -> JSON {
    var req = try apiRequest("graphql")
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(JSON.object(["query": .string(query), "variables": variables]).text.utf8)
    let (status, _, _, json) = try send(req, stats: &stats)
    guard status == 200, let json, let data = json["data"], data != .null else {
      throw APIError("GitHub answered \(status) \(GitHub.message(json))")
    }
    if json["errors"] != nil { logLine("github: \(GitHub.message(json))") }
    stats.points += data["rateLimit"]?["cost"]?.int ?? 0
    return json
  }

  /// A request to `path` under the API base.
  func apiRequest(_ path: String) throws -> URLRequest {
    guard let url = URL(string: "\(settings.url)/\(path)") else { throw APIError("bad github url \(settings.url)") }
    // URLSession's cache would answer a conditional request itself and hide the 304.
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
  }

  /// Sends the request with the token, and returns the status, the headers
  /// with lowercase names, the body, and the body as JSON. A 401 gets a new
  /// token from gh and one retry. A rate limit pauses the requests to the
  /// same quota, GraphQL or REST, for as long as `GitHub.rateLimit` says.
  func send(_ request: URLRequest, stats: inout Stats) throws -> (
    status: Int, headers: [String: String], body: Data, json: JSON?
  ) {
    let graphQL = request.url?.lastPathComponent == "graphql"
    if (graphQL ? graphQLPausedUntil : restPausedUntil) > nowMs() {
      throw APIError("paused after a GitHub \(graphQL ? "GraphQL" : "core") rate limit")
    }
    func attempt() throws -> (Int, [String: String], Data) {
      var req = request
      req.setValue("bearer \(try currentToken())", forHTTPHeaderField: "Authorization")
      stats.requests += 1
      return try httpRequest(req)
    }
    var (status, headers, body) = try attempt()
    if status == 401 {
      token = nil
      (status, headers, body) = try attempt()
    }
    let json = JSON.parse(String(decoding: body, as: UTF8.self))
    let limit = GitHub.rateLimit(status: status, headers: headers, response: json, now: Date().timeIntervalSince1970)
    if let pause = limit.pause {
      let until = nowMs() + Int64(pause * 1000)
      if graphQL { graphQLPausedUntil = until } else { restPausedUntil = until }
    }
    if limit.limited { throw APIError("GitHub rate limit: \(GitHub.message(json))") }
    return (status, headers, body, json)
  }

  private func currentToken() throws -> String {
    if let token { return token }
    guard let gh = findExecutable(settings.gh) else { throw APIError("can't find \(settings.gh)") }
    let r = try runCommand(gh, ["auth", "token"])
    let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard r.status == 0, !t.isEmpty else {
      throw APIError("gh auth token failed: \(oneLine(r.stderr, max: 120))")
    }
    token = t
    return t
  }

  // MARK: Events

  /// Records the folder's branch when it differs from the branch that sbd
  /// shows. Once the PR has merged or closed, it records the folder's count of
  /// uncommitted files and whether the folder is gone. It records the
  /// session's PR when the PR changed. The count comes before the PR, so the
  /// attention rules never judge a finished PR by the count of the session's
  /// previous PR. Returns whether it recorded a `pr` event.
  private func record(_ s: Watched, all: Bool, now: Int64) -> Bool {
    guard var t = tracked[s.id] else { return false }
    defer { tracked[s.id] = t }
    if let name = t.branch.name, name != s.branch { event(s.id, "branch", ["branch": .string(name)]) }
    if let pr = t.prId.flatMap({ prs[$0]?.pr }) ?? s.facts.pr, pr.state != .open,
      s.facts.cleanedUp == nil,
      shouldCount(t, s, pr.id, all, now)
    {
      // Without the optional index lock, the count can't make a git commit
      // in the session fail.
      let dirty = git(s.cwd, ["--no-optional-locks", "status", "--porcelain"], on: s.machine)
        .map { $0.split(separator: "\n").count }
      t.counted = (now, s.facts.lastActivity, pr.id)
      // Only ENOENT counts as gone. A permission error or a hung mount leaves
      // the folder unread, which stays unsafe.
      var info = stat()
      let gone = dirty == nil && stat(s.cwd, &info) != 0 && errno == ENOENT
      // The checks run 8 git commands. `sb cleanup` refuses a running turn, so the poller keeps the last result during one.
      let checked: CleanupStatus? =
        dirty != 0 || pr.state != .merged
        ? nil
        : s.facts.turnRunning ? s.facts.cleanupChecked : CleanupStatus(blocker: service.cleanupBlocker(s.id, pr: pr))
      if dirty != s.facts.dirty || gone != s.facts.folderGone || checked != s.facts.cleanupChecked {
        var data: [String: JSON] = ["dirty": dirty.map { .number(Double($0)) } ?? .null, "gone": .bool(gone)]
        if let checked { data["cleanup"] = checked.reason.map(JSON.string) ?? .null }
        event(s.id, "worktree", .object(data))
      }
    }
    var changed = false
    if let id = t.prId {
      if let comments = prs[id]?.comments, let shown = shown(id, last: s.facts.pr) {
        let kept = keptComments(comments)
        if shown != s.facts.pr || kept != s.facts.prComments {
          var data: [String: JSON] = ["pr": (try? JSON(encoding: shown)) ?? .null]
          if kept != s.facts.prComments { data["comments"] = (try? JSON(encoding: kept)) ?? [] }
          event(s.id, "pr", .object(data))
          changed = true
        }
      }
    } else if let pr = s.facts.pr {
      let noRemoteNamesIt = !t.branch.allows(pr.repo)
      let branchHasNoPR =
        t.branch.key != nil && t.branch.lookedUp != nil && (t.transcript.link == nil || t.transcript.lookedUp)
      // A session without a branch, as in a folder outside git or with HEAD
      // detached, keeps its PR only while its remotes are unknown or one of
      // them names the PR's repo.
      if noRemoteNamesIt || branchHasNoPR {
        event(s.id, "pr", ["pr": .null, "comments": []])
        changed = true
      }
    }
    return changed
  }

  /// A finished PR's folder is counted when the PR finishes, after the
  /// session's next activity, and once per idle interval while it is dirty.
  /// `git status` takes 0.1 to 0.3 s in a large repo, so a clean or missing
  /// folder isn't counted again on its own.
  private func shouldCount(_ t: Tracked, _ s: Watched, _ prId: String, _ all: Bool, _ now: Int64) -> Bool {
    guard !all, let counted = t.counted, counted.prId == prId else { return true }
    if s.facts.lastActivity > counted.activity { return true }
    return (s.facts.dirty ?? 0) > 0 && GitHub.elapsed(since: counted.at, settings.idleMs, now: now)
  }

  func event(_ id: String, _ kind: String, _ data: JSON) {
    service.queue.sync {
      guard service.entries[id] != nil else { return }
      service.record(id, kind, data)
    }
  }
}

extension Service {
  /// Starts the pollers' timers. sbd calls it once the server listens.
  public func startPollers() {
    github?.start()
    usageReader?.start()
  }
}
