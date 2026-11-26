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

  /// Sends the poller's requests to GitHub.
  let client: GitHubClient
  var tracked: [String: Tracked] = [:]
  /// The PRs that this sbd has read, by node id. `store` writes each entry.
  var prs: [String: CachedPR] = [:]
  /// Comment bodies by comment id. A comment whose edit time changed is read again.
  private var bodies: [String: PRComment] = [:]
  /// The Depot run that the event log held for each PR, by node id, until the
  /// first GitHub read of the PR after a restart. A Depot read that fails
  /// then keeps it.
  private var recordedDepot: [String: DepotRun] = [:]

  /// The comments of a read, with the bodies that `bodies` holds.
  func keptComments(_ comments: [PRComment]) -> [PRComment] { comments.map { bodies[$0.id] ?? $0 } }

  /// Whether the PR's last deploy comment shows it deployed to each environment.
  func deployed(_ comments: [PRComment], to environments: [DeployEnvironment] = DeployEnvironment.prod) -> Bool {
    keptComments(comments).compactMap { $0.body.flatMap(DeployComment.parse) }.last?.deployed(to: environments) == true
  }
  /// The PRs that waits and merge triggers name, by the key they were looked up with.
  var targets: [PRKey: Target] = [:]
  /// The `ci` waits whose outcome one read showed, by wait id. The wait resolves
  /// when a later read shows the same head commit and outcome. `outcome` is
  /// "failed" for any failure.
  var confirming: [String: (sha: String, outcome: String, polled: Int64)] = [:]
  /// How long after the poll that records a read in `confirming` the confirming read comes, in ms. With nil, the
  /// hub's delay applies to a PR that a provider is live for, and the PR's next due poll reads any other PR.
  var confirmReadAfter: Int64?
  /// The `queue` waits whose PR a read showed in GitHub's merge queue.
  /// GitHub reports no removal state, so a later read that shows the open PR
  /// outside the queue means the queue dropped it.
  var queuedWaits: Set<String> = []
  var deploys = Deploys()
  /// The PRs that a poll reads whether or not they are due. `requestRead` adds reads at a set time. The PRs of
  /// edges that left a session's list before the poller read their PR again are read at the next poll.
  var readRequests = ReadRequests()
  private var readTimer: DispatchSourceTimer?
  /// Schedules `readWake` at a time in ms, in place of the one scheduled before. Tests replace it.
  lazy var scheduleWake: (Int64) -> Void = { [unowned self] at in armReadTimer(at: at) }
  /// Turns what the sources of PR changes report into reads. Without a provider it does nothing.
  let hub: PRChangeHub
  /// What the poller knows about each plan document, by plan id.
  var trackedPlans: [String: TrackedPlan] = [:]
  var codeOwners = CodeOwnerReads()
  /// Each PR's merge details, by node id, with the head commit they belong
  /// to and when the poller read them.
  var mergeDetails: [String: (head: String, read: Int64, details: MergeDetails)] = [:]
  /// When the last issues poll started, in ms.
  var issuesReadAt: Int64?

  /// A PR that the poller read, with its comments from `GitHub.bodyAuthors`.
  struct CachedPR {
    var pr: PullRequest
    var comments: [PRComment]
    /// When the poller last read the PR from GitHub, in ms.
    var polled: Int64
    /// When sbd last applied a fact about the PR that came without a GitHub read, in ms. Nothing sets it yet.
    var factAt: Int64?
  }

  /// Caches a status read of a PR. The status query reads neither the merged base nor the Depot run. The PR
  /// therefore keeps the cached merged base while its base branch stays the same. It also keeps the cached Depot
  /// run, or else the one that the event log held.
  func store(_ pr: PullRequest, comments: [PRComment], polled: Int64) {
    var pr = pr
    let last = prs[pr.id]
    if let last, last.pr.base == pr.base { pr.mergedBase = last.pr.mergedBase }
    pr.depot = last?.pr.depot ?? recordedDepot.removeValue(forKey: pr.id)
    prs[pr.id] = CachedPR(pr: pr, comments: comments, polled: polled, factAt: last?.factAt)
  }

  /// What the poller knows about one session.
  struct Tracked {
    /// The session's host, or nil on this Mac.
    var host: String?
    var branch = Branch()
    var transcript: Transcript
    /// When the poller last counted the uncommitted files of a finished PR's
    /// folder, and the session's last activity at that time.
    var counted: (at: Int64, activity: Int64, prId: String)?
    /// The PR that the event log held when this sbd first saw the session. It
    /// keeps a restart from losing the PR of a session whose HEAD is detached
    /// or whose conversation `/clear` replaced. The poller drops it when the
    /// branch's lookup finds a PR. It also drops it when the lookup finds none
    /// and the recorded PR is the folder's earlier work, as `readPRs` decides.
    var recordedPRId: String?
    /// The linked or recorded PRs that are the folder's open earlier work and
    /// that the folder did not make on its current branch. They do not count,
    /// but the poller keeps reading them, so a later head that the folder
    /// made brings them back.
    var hidden: Set<String> = []

    /// The session's open PR while its branch has a different PR. A session works on one PR, so it keeps the first
    /// one until that PR closes. `record` sets it.
    var pinnedPRId: String?

    /// The PR that the session shows: the pinned PR, else the candidate.
    var prId: String? { pinnedPRId ?? candidatePRId }

    /// The branch's PR comes first, then the transcript's.
    var candidatePRId: String? {
      [branch.prId, transcript.prId, recordedPRId].compactMap { $0 }.first { !hidden.contains($0) }
    }

    /// The PRs that the poller reads for the session, hidden ones included.
    var readIds: [String] { [pinnedPRId, branch.prId, transcript.prId, recordedPRId].compactMap { $0 } }
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
    /// The branches that HEAD's reflog shows the folder had checked out, each
    /// by its local name and by the upstream name that its `merge` config
    /// gives. The poller reads it again when HEAD moves to a branch. It keeps
    /// the last value while HEAD is detached. It is empty when the reflog
    /// can't be read.
    var checkedOut: Set<String> = []
    /// The commits that the folder made on its branch since it switched to
    /// it, from HEAD's reflog. nil when the reflog shows no switch.
    var made: Set<String>?
    /// The size of HEAD's reflog when the poller last read it.
    var reflogSize: UInt64?
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
    /// The site that holds the session's folder and transcript.
    var site: any SessionSite
    /// The branch that sbd shows for the session.
    var branch: String?
    var facts: SessionFacts
  }

  struct Stats: Encodable, GitHubCost {
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
    var issueReads = 0
  }

  init(
    service: Service, settings: GitHubSettings, depot: DepotSettings, trunk: TrunkSettings,
    providers: [any PRChangeProvider] = []
  ) {
    self.service = service
    self.settings = settings
    let client = GitHubClient(settings: settings)
    self.client = client
    self.depot = depot.enabled ? DepotPoller(settings: depot) : nil
    self.trunk = TrunkPoller(settings: trunk, intervalMs: settings.pendingMs)
    let events: [any PRChangeProvider] =
      settings.events.mode == .off ? [] : [EventStreamsProvider(client: client, settings: settings.events)]
    let mode: PRChangeHub.Mode =
      switch settings.events.mode {
      case .shadow: .shadow
      case .off, .read: .read
      }
    self.hub = PRChangeHub(providers: providers + events, queue: queue, mode: mode)
    hub.reader = self
  }

  /// Starts the providers, and the poll timer unless `pollSeconds` is 0. A provider runs without the timer.
  func start() {
    hub.start()
    guard settings.pollSeconds > 0 else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + settings.pollSeconds, repeating: settings.pollSeconds)
    t.setEventHandler { [self] in _ = cycle(all: false) }
    t.resume()
    timer = t
  }

  /// Reads the PRs, whether or not they are due, at a poll `after` ms from now or later. The requests that come
  /// before that poll share it. A PR that no session, wait, or merge trigger names is not read. `sb poll --stats`
  /// counts each read under `trigger`. It runs on `queue`.
  func requestRead(_ ids: some Sequence<String>, after: Int64, trigger: ReadTrigger) {
    dispatchPrecondition(condition: .onQueue(queue))
    if let at = readRequests.request(ids, at: nowMs() + after, trigger: trigger) { scheduleWake(at) }
  }

  /// Reads the PRs at the next poll, whenever that runs, whether or not they are due. It runs on `queue`.
  func readAtNextPoll(_ ids: some Sequence<String>, trigger: ReadTrigger) {
    dispatchPrecondition(condition: .onQueue(queue))
    readRequests.readAtNextPoll(ids, trigger: trigger)
  }

  /// Withdraws the PR's timed read when it was requested with `trigger`. It runs on `queue`.
  func cancelRead(_ id: String, trigger: ReadTrigger) {
    dispatchPrecondition(condition: .onQueue(queue))
    readRequests.cancel(id, trigger: trigger)
  }

  /// Runs the poll that a request scheduled, unless an earlier poll read every due request. Then it schedules a
  /// wake for the requests that remain.
  func readWake() {
    dispatchPrecondition(condition: .onQueue(queue))
    if readRequests.fire(now: nowMs()) { _ = cycle(all: false) }
    if let at = readRequests.rearm() { scheduleWake(at) }
  }

  private func armReadTimer(at: Int64) {
    let t =
      readTimer
      ?? {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.readWake() }
        t.resume()
        readTimer = t
        return t
      }()
    t.schedule(deadline: .now() + .milliseconds(Int(max(0, at - nowMs()))))
  }

  /// The PRs that a session, a wait, or a merge trigger names. A poll reads only these.
  private var namedPRIds: Set<String> {
    Set(tracked.values.flatMap(\.readIds)).union(targets.values.compactMap(\.prId))
  }

  /// Whether this Mac's GitHub login may read `repo` for a session on `host`. A session on this Mac reads any repo.
  /// A box chooses the repo of its session through its git remotes, its transcript, its PR's body, and its waits. A
  /// session on a host therefore reads only a repo that `Service.hostMayRead` allows.
  func mayRead(_ repo: String, for host: String?) -> Bool {
    host.map { service.hostMayRead(repo, on: $0) } ?? true
  }

  /// The key when `mayRead` allows its repo for the session's host.
  private func readable(_ key: PRKey?, for host: String?) -> PRKey? {
    key.flatMap { mayRead($0.repo, for: host) ? $0 : nil }
  }

  /// Runs one poll and returns what it did. With `all`, it reads every PR,
  /// looks up every branch, and counts every finished PR's folder, due or not.
  func poll(all: Bool) -> JSON {
    queue.sync { cycle(all: all) }
  }

  /// The sources of PR changes, for `sb sources`. With `recheck`, each provider first tries again what made it
  /// unavailable.
  func sources(recheck: Bool = false) -> PRSources {
    guard !hub.providers.isEmpty else { return PRSources(providers: []) }
    if recheck { hub.providers.forEach { $0.recheck() } }
    return queue.sync { hub.report() }
  }

  /// The GitHub requests and points since sbd started, without polling.
  func usageReport() -> JSON {
    (try? JSON(encoding: client.usageReport())) ?? [:]
  }

  private func cycle(all: Bool) -> JSON {
    var stats = Stats()
    var failure: String?
    let sessions: [Watched] = service.queue.sync {
      service.entries.map { id, e in
        Watched(
          id: id, cwd: e.session.cwd, claudeSessionId: e.session.claudeSessionId,
          configDir: service.transcriptAccount(e.session),
          site: service.site(for: e.session), branch: e.branch, facts: e.facts)
      }
    }
    let now = nowMs()
    let requested = readRequests.take(now: now)
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
      var waited = waitedOn(interest)
      // A request's hold ends `readMs` after a turn ends. The PR reads once after each such turn, so the hold sees
      // a push that the turn made even when the PR polls at the idle rate.
      // The PR also reads once after an acknowledgment expires, so the item that returns to the Inbox shows what
      // GitHub shows now.
      let acknowledgedMs = service.config.recheck.acknowledgedMs
      for s in sessions {
        guard let id = s.facts.pr?.id else { continue }
        if let ended = s.facts.request?.ended { waited.created[id] = max(waited.created[id] ?? 0, ended) }
        if let at = s.facts.acknowledgment?.at, at + acknowledgedMs <= now {
          waited.created[id] = max(waited.created[id] ?? 0, at + acknowledgedMs)
        }
      }
      try readPRs(all: all, now: now, waited: waited, requested: requested, queued: queuedPRs(), stats: &stats)
      try checkDeploys(
        deployTargets(interest) + edgeDeployTargets(sessions, now: now), all: all, now: now, stats: &stats)
    } catch {
      failure = "\(error)"
      logLine("github: \(error)")
    }
    // The next poll reads the requested PRs that a failed poll didn't read and that a session, wait, or merge
    // trigger still names. A timed request would schedule a wake that fails again at once while GitHub keeps failing.
    if failure != nil {
      let named = namedPRIds
      for (id, trigger) in requested where named.contains(id) && prs[id]?.polled != now {
        readRequests.readAtNextPoll([id], trigger: trigger)
      }
    }
    let depotError = refreshDepot(all: all, now: now, stats: &stats)
    let issuesError = refreshIssues(all: all, now: now, stats: &stats)
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
    let kept = namedPRIds
    prs = prs.filter { kept.contains($0.key) }
    recordedDepot = recordedDepot.filter { kept.contains($0.key) }
    pruneCodeOwners()
    pruneMergeDetails()
    let comments = Set(prs.values.flatMap { $0.comments.map(\.id) })
    bodies = bodies.filter { comments.contains($0.key) }
    feedHub(sessions, interest)
    var result = (try? JSON(encoding: stats).object) ?? [:]
    if let failure { result["error"] = .string(failure) }
    if let depotError { result["depotError"] = .string(depotError) }
    if let issuesError { result["issuesError"] = .string(issuesError) }
    if let codeOwnersError { result["codeOwnersError"] = .string(codeOwnersError) }
    if let mergeDetailsError { result["mergeDetailsError"] = .string(mergeDetailsError) }
    if let problem = trunk.problem { result["trunkError"] = .string(problem) }
    let paused = client.pausedUntil
    if paused > nowMs() { result["pausedUntil"] = .number(Double(paused)) }
    return .object(result)
  }

  // MARK: Local facts

  /// What one poll reads once for every session: each config dir's project
  /// folders, and each repo's git config. A host can hold the paths that this Mac
  /// holds, so each read belongs to the path and its site.
  struct Shared {
    var projects: [SitePath: [String]] = [:]
    var configs: [SitePath: [String: String]] = [:]
  }

  /// Reads the session's branch and the new lines of its transcript. For a session on a host, it keeps the
  /// last values unless the host answered every read.
  func refreshLocal(_ s: Watched, all: Bool, now: Int64, shared: inout Shared) {
    let before = (tracked[s.id], shared)
    do {
      try s.site.confirmed("the poll of \(s.id)") { machine in
        refreshLocal(s, at: CheckedSite(s.site, machine: machine), all: all, now: now, shared: &shared)
      }
    } catch {
      (tracked[s.id], shared) = before
    }
  }

  private func refreshLocal(_ s: Watched, at site: any SessionSite, all: Bool, now: Int64, shared: inout Shared) {
    if tracked[s.id] == nil, let pr = s.facts.pr, let run = pr.depot, prs[pr.id] == nil { recordedDepot[pr.id] = run }
    let host = s.site.hostName
    var t =
      tracked[s.id]
      ?? Tracked(
        transcript: Transcript(claudeSessionId: s.claudeSessionId),
        recordedPRId: s.facts.pr.flatMap { mayRead($0.repo, for: host) ? $0.id : nil })
    t.host = host
    refreshBranch(
      &t.branch, cwd: s.cwd, at: site, all: all, now: now, watchReflog: !t.hidden.isEmpty, configs: &shared.configs)
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
    readTranscript(&t.transcript, configDir: s.configDir, cwd: s.cwd, at: site, projects: &shared.projects)
    tracked[s.id] = t
  }

  /// The git config keys that `GitHub.branchKey` reads, as a pattern of `git config --get-regexp`.
  static let branchKeyConfig =
    #"^(remote\..*\.(url|gh-resolved)|remote\.pushdefault|branch\..*\.(pushremote|remote|merge))$"#

  /// Reading the HEAD file and the config's modification time costs less
  /// than running git, so git runs only when either changed. A folder outside
  /// git is checked again once per idle interval. A commit changes HEAD's
  /// reflog but not the HEAD file, so `watchReflog` also checks the reflog's
  /// size. Only a session with a hidden PR needs that.
  private func refreshBranch(
    _ b: inout Branch, cwd: String, at site: any SessionSite, all: Bool, now: Int64, watchReflog: Bool,
    configs: inout [SitePath: [String: String]]
  ) {
    let machine = site.machine
    let read = machine.text
    var head = b.gitDir.flatMap { read("\($0)/HEAD") }
    if head == nil && (all || GitHub.elapsed(since: b.gitDirRead, settings.idleMs, now: now)) {
      let dirs = git(cwd, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], at: site)?
        .split(separator: "\n").map(String.init)
      b.gitDir = dirs?.first
      b.commonDir = dirs?.last
      b.gitDirRead = now
      head = b.gitDir.flatMap { read("\($0)/HEAD") }
    }
    let stamp = b.commonDir.flatMap { machine.modified("\($0)/config") }
    let reflogMoved = watchReflog && b.gitDir.flatMap { machine.size("\($0)/logs/HEAD") } != b.reflogSize
    guard all || head != b.head || stamp != b.configStamp || reflogMoved else { return }
    b.head = head
    b.configStamp = stamp
    // A rebase or a bisect detaches HEAD for a while, and the session keeps
    // its branch's PR meanwhile.
    var key = head != nil ? b.key : nil
    let branch = head.flatMap { GitHub.branch(head: $0) }
    if let branch { b.name = branch }
    if let branch, let common = b.commonDir {
      // The worktrees of a repo share its config, so git reads it once per poll.
      let repo = SitePath(common, at: site)
      // git exits 1 when no key matches. A read that fails in another way keeps the last known remotes.
      if configs[repo] == nil {
        let r = try? machine.run(site.git(), ["-C", cwd, "config", "--get-regexp", Self.branchKeyConfig])
        if let r, r.status <= 1 {
          configs[repo] = GitHub.gitConfig(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }
      let config = configs[repo] ?? [:]
      key = GitHub.branchKey(branch: branch, config: config) { remote in
        // A remote's HEAD is a symbolic ref, which git never packs.
        read("\(common)/refs/remotes/\(remote)/HEAD").flatMap {
          GitHub.branch(head: $0, under: "refs/remotes/\(remote)/")
        }
      }
      let reflogData = b.gitDir.flatMap { machine.read("\($0)/logs/HEAD", from: 0, count: nil) }
      b.reflogSize = reflogData.map { UInt64($0.count) }
      let reflog = reflogData.map { String(decoding: $0, as: UTF8.self) }
      let local = reflog.map(GitHub.checkedOutBranches) ?? []
      b.checkedOut = local.union(local.compactMap { GitHub.upstreamName(of: $0, config: config) })
      b.made = reflog.flatMap { GitHub.commitsSinceSwitch(reflog: $0, to: branch) }
    }
    if key != b.key {
      b.key = key
      b.prId = nil
      b.lookedUp = nil
    }
  }

  /// The folder's count of uncommitted files, or nil when git can't count them, and whether the folder is
  /// gone. For a session on a host, it is nil unless the host answered both reads, so the session keeps its
  /// last `worktree` facts.
  func worktreeCount(_ s: Watched) -> (dirty: Int?, gone: Bool)? {
    // Without the optional index lock, the count can't make a git commit
    // in the session fail.
    let count = { (site: any SessionSite) in
      self.git(s.cwd, ["--no-optional-locks", "status", "--porcelain"], at: site)
        .map { $0.split(separator: "\n").count }
    }
    do {
      let dirty = try s.site.confirmed("the count of \(s.id)'s uncommitted files") { machine in
        count(CheckedSite(s.site, machine: machine))
      }
      return (dirty, try dirty == nil && s.site.folderGone(s.cwd))
    } catch {
      return nil
    }
  }

  private func git(_ cwd: String, _ args: [String], at site: any SessionSite) -> String? {
    try? service.gitOutput(cwd, args, at: site)
  }

  /// Reads the transcript's lines since the last read. Until the poller knows
  /// the session's project folder, it searches every project folder. Then it
  /// looks only in the cwd's folder and that one.
  private func readTranscript(
    _ t: inout Transcript, configDir: String, cwd: String, at site: any SessionSite,
    projects: inout [SitePath: [String]]
  ) {
    let machine = site.machine
    if t.path == nil {
      let known = t.folder
      t.path = SwitchboardCore.Transcript.find(t.claudeSessionId, account: configDir, cwd: cwd, on: machine) { root in
        if let known { return [known] }
        let folder = SitePath(root, at: site)
        if projects[folder] == nil { projects[folder] = machine.list(root) }
        return projects[folder]!
      }
      if let path = t.path { t.folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    }
    guard let path = t.path, let size = machine.size(path), size != UInt64(t.offset) else { return }
    if size < UInt64(t.offset) { t.offset = 0 }
    guard let data = machine.read(path, from: UInt64(t.offset), count: nil), !data.isEmpty else { return }
    let (link, consumed) = GitHub.lastPRLink(in: data)
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
      if let key = readable(t.branch.key, for: t.host) {
        let ended = t.branch.prId.flatMap { prs[$0]?.pr.state }.map { $0 != .open } ?? false
        if (t.branch.prId == nil || ended)
          && (all || GitHub.elapsed(since: t.branch.lookedUp, settings.idleMs, now: now))
        {
          keys.insert(key)
        }
      }
      if let link = readable(t.transcript.link, for: t.host), !t.transcript.lookedUp { keys.insert(link) }
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
      found.merge(GitHub.parseLookup(try client.request(query, variables, stats: &stats), chunk)) { $1 }
    }
    stats.lookups = keys.count
    for key in interest.keys { if let result = found[key] { targets[key] = Target(prId: result, lookedUp: now) } }
    for (id, var t) in tracked {
      if let key = readable(t.branch.key, for: t.host), let result = found[key] {
        t.branch.prId = result
        t.branch.lookedUp = now
        if result != nil { t.recordedPRId = nil }
      }
      if let link = readable(t.transcript.link, for: t.host), let result = found[link] {
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
  private func readPRs(
    all: Bool, now: Int64, waited: Waited, requested: [String: ReadTrigger], queued: Set<String>, stats: inout Stats
  ) throws {
    // A PR that `waited.needs` names or that Trunk queued polls at the pending rate. A PR with any open wait also
    // polls at once when the wait is newer than the last read. That read can't show what happened after the wait
    // was set. A requested PR, such as an edge that `recordDependencies` kept, is read at once.
    var candidates: [String: ReadCandidate] = [:]
    for id in namedPRIds {
      candidates[id] = ReadCandidate(
        pr: prs[id]?.pr, lastPolled: prs[id]?.polled, waitedAt: waited.created[id], requested: requested[id],
        needs: waited.needs(of: id, queued: queued))
    }
    let triggers = GitHub.dueReads(candidates, all: all, now: now, policy: pollPolicy())
    let ids = triggers.keys.sorted()
    if !hub.providers.isEmpty {
      let pending = ids.filter { triggers[$0] == .pending }
      hub.countPendingReads(
        total: pending.count,
        reviewOnly: pending.count { GitHub.onlyAwaitsReview(prs[$0]?.pr, needs: candidates[$0]?.needs ?? []) })
    }
    // A request's cost goes to its PRs after the request returns, because a PR's repo is known only after its first read.
    func count(_ prIds: [String], from before: Stats, to after: Stats, countsReads: Bool) {
      let served = prIds.map { id in
        GitHubUsage.Read(
          trigger: triggers[id] ?? .retry,
          owner: prs[id].map { GitHub.ownerAndName($0.pr.repo).owner.lowercased() } ?? "unknown")
      }
      let requests = after.requests - before.requests
      let points = after.points - before.points
      client.share(requests: requests, points: points, among: served, countsReads: countsReads)
    }
    var stacked: [String] = []
    var gone: Set<String> = []
    for chunk in GitHub.chunks(ids) {
      let before = stats
      var parsed = false
      // A request that throws still cost what `send` counted, so the split keeps it.
      defer { count(chunk, from: before, to: stats, countsReads: parsed) }
      let (read, notFound) = GitHub.parseStatus(
        try client.request(GitHub.statusQuery, idsVariable(chunk), stats: &stats), chunk)
      gone.formUnion(notFound)
      for (pr, comments) in read {
        // A PR whose base query fails keeps the merged base that `store` carried over.
        store(pr, comments: comments.filter { GitHub.bodyAuthors.contains($0.author) }, polled: now)
        if pr.base != pr.defaultBranch { stacked.append(pr.id) }
      }
      stats.polled += read.count
      parsed = true
    }
    for (id, var t) in tracked {
      if let prId = t.branch.prId, gone.contains(prId) {
        t.branch.prId = nil
        t.branch.lookedUp = now
      }
      if let prId = t.transcript.prId, gone.contains(prId) { t.transcript.prId = nil }
      if let prId = t.recordedPRId, gone.contains(prId) { t.recordedPRId = nil }
      // A linked or recorded PR in the branch's repo whose head branch the
      // folder had checked out before belongs to the session's earlier work,
      // unless the folder made the PR's head commit on its current branch.
      // Earlier work stops counting once GitHub answers that the current
      // branch has no PR. A PR whose head another checkout made still counts,
      // in this repo or another, because a session can open its PR from
      // another worktree.
      t.hidden = []
      if t.branch.prId == nil, t.branch.lookedUp != nil, case .branch(let repo, let branch, _)? = t.branch.key {
        for id in [t.transcript.prId, t.recordedPRId].compactMap({ $0 }) {
          guard let pr = prs[id]?.pr else { continue }
          switch GitHub.earlierStanding(
            pr, repo: repo, branch: branch, checkedOut: t.branch.checkedOut, made: t.branch.made)
          {
          case .current: break
          case .hidden: t.hidden.insert(id)
          case .dropped:
            if t.transcript.prId == id { t.transcript.prId = nil }
            if t.recordedPRId == id { t.recordedPRId = nil }
          }
        }
      }
      tracked[id] = t
    }
    for (key, target) in targets {
      if let prId = target.prId, gone.contains(prId) { targets[key] = Target(prId: nil, lookedUp: now) }
    }
    for chunk in GitHub.chunks(stacked) {
      let before = stats
      defer { count(chunk, from: before, to: stats, countsReads: false) }
      let response = try client.request(GitHub.baseQuery, idsVariable(chunk), stats: &stats)
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
    let stale = prs.flatMap { id, read in read.comments.map { (prId: id, comment: $0) } }.filter { s in
      bodies[s.comment.id].map { ($0.editedAt ?? "") < (s.comment.editedAt ?? "") } ?? true
    }
    for chunk in GitHub.chunks(stale, size: GitHub.lightChunkSize) {
      let before = stats
      defer { count(Array(Set(chunk.map(\.prId))), from: before, to: stats, countsReads: false) }
      let ids = chunk.map(\.comment.id)
      let (read, gone) = GitHub.parseBodies(try client.request(GitHub.bodyQuery, idsVariable(ids), stats: &stats), ids)
      for comment in read { bodies[comment.id] = comment }
      for s in chunk where gone.contains(s.comment.id) { bodies[s.comment.id] = s.comment }
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

  func idsVariable(_ ids: [String], with more: [String: JSON] = [:]) -> JSON {
    .object(more.merging(["ids": .array(ids.map(JSON.string))]) { $1 })
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
    t.pinnedPRId = nil
    if let held = s.facts.pr, held.state == .open, let other = t.branch.prId, other != held.id,
      t.candidatePRId == other
    {
      t.pinnedPRId = held.id
    }
    if t.pinnedPRId != nil {
      if let number = t.branch.prId.flatMap({ prs[$0]?.pr.number }), number != s.facts.refusedPR {
        event(s.id, "pr-refused", ["number": .number(Double(number))])
      }
    } else if s.facts.refusedPR != nil, s.facts.pr?.state != .open || t.branch.prId == s.facts.pr?.id {
      event(s.id, "pr-refused", ["number": .null])
    }
    if let name = t.branch.name, name != s.branch { event(s.id, "branch", ["branch": .string(name)]) }
    if let pr = t.prId.flatMap({ prs[$0]?.pr }) ?? s.facts.pr, pr.state != .open,
      s.facts.cleanedUp == nil,
      shouldCount(t, s, pr.id, all, now), let (dirty, gone) = worktreeCount(s)
    {
      t.counted = (now, s.facts.lastActivity, pr.id)
      // The checks run 8 git commands, or 9 in a worktree that Supacode locked.
      // `sb cleanup` refuses a running turn, so the poller keeps the last result during one.
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
    let branchHasNoPR =
      t.branch.key != nil
      && (t.branch.lookedUp != nil || readable(t.branch.key, for: t.host) == nil)
      && (readable(t.transcript.link, for: t.host) == nil || t.transcript.lookedUp)
    if let id = t.prId {
      if let comments = prs[id]?.comments, let shown = shown(id, last: s.facts.pr) {
        let kept = keptComments(comments)
        if s.facts.pr?.id != shown.id, let owner = service.prOwner(of: shown.id, besides: s.id, onHost: t.host) {
          // Another live session owns this PR and keeps it. This session shows no PR.
          let dropsPR = s.facts.pr != nil
          if dropsPR { event(s.id, "pr", ["pr": .null, "comments": []]) }
          if dropsPR || s.facts.prOwner != owner {
            event(s.id, "pr-owned", ["owner": .string(owner)])
            changed = true
          }
        } else if shown != s.facts.pr || kept != s.facts.prComments {
          var data: [String: JSON] = ["pr": (try? JSON(encoding: shown)) ?? .null]
          if kept != s.facts.prComments { data["comments"] = (try? JSON(encoding: kept)) ?? [] }
          event(s.id, "pr", .object(data))
          changed = true
        }
      }
    } else if let pr = s.facts.pr, !mayRead(pr.repo, for: t.host) || branchHasNoPR {
      // GitHub answered that the branch has no PR. A branch or link in a repo
      // that `mayRead` refuses counts as one with no PR, because the poller
      // never looks it up. Without a branch, as in a folder outside git, the
      // session keeps the PR that it had. The session also drops a recorded
      // PR in a repo that `mayRead` refuses. An older sbd can record one, and
      // so can sbd while the host's `repos` still listed the repo.
      event(s.id, "pr", ["pr": .null, "comments": []])
      changed = true
    } else if s.facts.pr == nil, s.facts.prOwner != nil, branchHasNoPR {
      // The session left the PR that another session owns, so the owner no longer applies.
      event(s.id, "pr-owned", ["owner": .null])
      changed = true
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
