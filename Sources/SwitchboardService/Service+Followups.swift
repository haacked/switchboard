import Foundation
import SwitchboardCore

extension Service {
  /// The follow-up requests. Each one takes the state queue itself, because
  /// `add` and `start` run git first.
  func followupRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "followup-add":
      return try JSON(encoding: addFollowup(args))
    case "followup-ls":
      return try JSON(encoding: queue.sync { summaries().filter(\.waitsToStart) })
    case "followup-start":
      return try JSON(encoding: startFollowup(args))
    case "followup-rm":
      return try removeFollowup(args)
    case "followup-import":
      return try importFollowups(args)
    case "pr-merged":
      guard let text = args["pr"]?.string, let pr = Wait.PullRequest(parsing: text), pr.repository != nil else {
        throw APIError("pr-merged needs a PR as owner/name#12 or a PR URL")
      }
      return try JSON(encoding: pullRequestMerged(pr))
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// Refuses to launch claude or open terminals for a session with no
  /// folder, which is a follow-up that hasn't started.
  func refuseNotStarted(_ session: Session) throws {
    guard session.cwd.isEmpty else { return }
    throw APIError("\(session.id) is a follow-up that hasn't started. Start it with: sb followup start \(session.id)")
  }

  // MARK: Adding

  func addFollowup(_ args: JSON) throws -> SessionSummary {
    guard let prompt = args["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
      throw APIError("a follow-up needs a prompt")
    }
    var repository = args["repository"]?.string
    var sourceBranch: String?
    if let repository, !Followup.isRepository(repository) {
      throw APIError("\(repository) isn't a repository. Use owner/name")
    }
    if repository == nil, let cwd = args["cwd"]?.string {
      (repository, sourceBranch) = gitContext(cwd)
    }
    let now = nowMs()
    let trigger = try makeTrigger(on: args["on"]?.string, after: args["after"]?.string, repository, now: now)
    return try queue.sync {
      let parent = try args["parent"]?.string.map { try lookup(["session": .string($0)]) }
      var session = Session(
        id: shortId("s", taken: entries.keys), name: args["title"]?.string ?? Followup.title(prompt), cwd: "",
        branch: args["branch"]?.string.flatMap { $0.isEmpty ? nil : $0 },
        claudeSessionId: UUID().uuidString.lowercased(),
        model: args["model"]?.string, created: now)
      session.parent = parent
      session.group = groupOfParent(parent)
      // A follow-up added by a session stays in that session's account.
      // Without a parent, it takes the active account when it starts.
      if let ref = args["account"]?.string {
        session.claudeConfigDir = try resolveAccount(ref)
      } else if let parent {
        session.claudeConfigDir = claudeAccount(of: parent)
      }
      session.followup = Followup(
        prompt: prompt, repository: repository, sourceBranch: sourceBranch,
        link: args["link"]?.string ?? Followup.firstLink(prompt), trigger: trigger)
      try save(session)
      return summary(session.id)
    }
  }

  private func save(_ session: Session) throws {
    entries[session.id] = Entry(session: session)
    try store.save(session)
    record(session.id, "followup", try JSON(encoding: session.followup))
  }

  /// The repository and branch of a folder: the `owner/name` of its
  /// `upstream` remote, else its `origin` remote, on github.com.
  private func gitContext(_ cwd: String) -> (String?, String?) {
    guard
      let repository = ["upstream", "origin"].lazy.compactMap({ try? self.gitOutput(cwd, ["remote", "get-url", $0]) })
        .compactMap(Followup.repository(remote:)).first
    else { return (nil, nil) }
    let branch = try? gitOutput(cwd, ["branch", "--show-current"])
    return (repository, branch?.isEmpty == false ? branch : nil)
  }

  private func makeTrigger(on: String?, after: String?, _ repository: String?, now: Int64) throws
    -> Followup.Trigger
  {
    switch (on, after) {
    case (nil, nil):
      return .manual
    case (let on?, nil):
      guard let at = Wait.parseTime(on, now: now) else { throw APIError("can't read the time \(on)") }
      guard at > now else { throw APIError("\(on) has passed") }
      return .date(at)
    case (nil, let after?):
      guard var pr = Wait.PullRequest(parsing: after), let named = pr.repository ?? repository else {
        throw APIError("can't read the PR \(after). Use owner/name#12, a PR URL, or #12 with a repository")
      }
      pr.repository = named
      return .merge(pr)
    case (_?, _?):
      throw APIError("a follow-up takes --on or --after, not both")
    }
  }

  // MARK: Starting

  /// Makes the follow-up's worktree and launches claude there with its
  /// prompt. git and the wait for shared MCP servers run off the state queue.
  /// The session keeps its id. Until claude launches, `starting` holds the id,
  /// so `rm`, `followup rm`, another start, and the trigger leave the
  /// follow-up alone.
  func startFollowup(_ args: JSON) throws -> SessionSummary {
    let session: Session = try queue.sync {
      let id = try lookup(args)
      let s = entries[id]!.session
      guard s.waitsToStart else { throw APIError("\(id) isn't a follow-up that waits to start") }
      guard starting.insert(id).inserted else { throw APIError("\(id) is starting") }
      return s
    }
    defer { _ = queue.sync { starting.remove(session.id) } }
    return try start(session, args)
  }

  private func start(_ session: Session, _ args: JSON) throws -> SessionSummary {
    let repo =
      try args["path"]?.string.map { ($0.expandingTilde as NSString).standardizingPath }
      ?? checkout(of: session.followup?.repository)
    let named = [args["branch"]?.string, session.branch].compactMap { $0 }.first { !$0.isEmpty }
    let branch = named ?? config.branchPrefix + Followup.slug(session.name)
    if named == nil {
      guard branch != config.branchPrefix else {
        throw APIError("can't make a branch name from \"\(session.name)\". Pass --branch")
      }
      guard !branchExists(repo, branch) else {
        throw APIError("branch \(branch) exists in \(repo). Pass --branch to use it or to name another")
      }
    }
    let folder = try prepareFolder(NewSession(path: repo, branch: branch, base: args["base"]?.string))
    awaitMCPServers()
    return try queue.sync {
      try update(session.id) { s in
        s.cwd = folder.cwd
        s.branch = folder.branch
        s.repo = folder.repo
        s.model = s.model ?? config.model
        s.claudeConfigDir = s.claudeConfigDir ?? activeAccount
        s.done = false
        s.followup?.started = nowMs()
      }
      record(session.id, "followup-started", ["cwd": .string(folder.cwd), "branch": .string(branch)])
      try launch(session.id, prompt: session.followup?.prompt)
      return summary(session.id)
    }
  }

  /// Removes a follow-up that hasn't started. It has no panes, folder, or
  /// worktree, so only its row and events go.
  private func removeFollowup(_ args: JSON) throws -> JSON {
    try queue.sync {
      let id = try lookup(args)
      guard entries[id]!.session.waitsToStart else { throw APIError("\(id) has started. sb rm removes a session") }
      guard !starting.contains(id) else { throw APIError("\(id) is starting") }
      entries[id] = nil
      try store.delete(session: id)
      try detachPlans { $0.session == id }
      return ["removed": .string(id)]
    }
  }

  /// The top folder of a local checkout of `owner/name`: the `repos`
  /// setting, else <root>/<owner>/<name> under the first root in `repoRoots`
  /// that has that folder. The checkout needs a remote on github.com for the
  /// repository, so a folder that only shares the name is refused.
  func checkout(of repository: String?) throws -> String {
    guard let repository else { throw APIError("the follow-up has no repository. Pass --path") }
    let configured = config.repos.first { $0.key.lowercased() == repository.lowercased() }?.value
    let candidates = configured.map { [$0] } ?? config.repoRoots.map { "\($0)/\(repository)" }
    for path in candidates.map({ ($0.expandingTilde as NSString).standardizingPath }) {
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
      let remotes = ((try? gitOutput(path, ["remote", "-v"])) ?? "").split(separator: "\n").compactMap { line in
        line.split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap { Followup.repository(remote: String($0)) }
      }
      guard remotes.contains(where: { $0.lowercased() == repository.lowercased() }) else {
        throw APIError("\(path) has no remote on github.com for \(repository)")
      }
      return try gitOutput(path, ["rev-parse", "--show-toplevel"])
    }
    if let configured { throw APIError("repos sets \(repository) to \(configured), which isn't a folder") }
    throw APIError(
      "can't find a checkout of \(repository) under \(config.repoRoots.joined(separator: ", ")). Pass --path, or add it to repos in \(home.config)"
    )
  }

  // MARK: Triggers

  /// Marks each follow-up whose date trigger has passed as ready. `tick`
  /// calls it on the state queue.
  func readyDueFollowups(now: Int64) {
    for (id, e) in entries where waitsToFire(e.session) {
      if let at = e.session.followup?.trigger.at, at <= now { markReady(id, now: now) }
    }
  }

  /// The PRs that open merge triggers wait for. github-poller adds them to
  /// its query.
  func followupPullRequests() -> [Wait.PullRequest] {
    queue.sync {
      entries.values.map(\.session).filter(waitsToFire).compactMap { $0.followup?.trigger.pr }
    }
  }

  /// Marks the follow-ups that wait for this PR to merge as ready, and returns
  /// them. github-poller calls it when it sees the merge.
  func pullRequestMerged(_ pr: Wait.PullRequest) -> [SessionSummary] {
    queue.sync {
      let now = nowMs()
      return entries.keys.sorted().compactMap { id in
        guard let s = entries[id]?.session, waitsToFire(s), let waiting = s.followup?.trigger.pr, waiting.same(as: pr)
        else { return nil }
        markReady(id, now: now)
        return summary(id)
      }
    }
  }

  private func waitsToFire(_ session: Session) -> Bool {
    session.waitsToStart && !session.done && session.followup?.ready == nil && !starting.contains(session.id)
  }

  private func markReady(_ id: String, now: Int64) {
    do {
      try update(id) { $0.followup?.ready = now }
    } catch {
      logLine("can't mark \(id) ready: \(error)")
      return
    }
    let trigger = entries[id]?.session.followup?.trigger
    record(id, "followup-ready", ["trigger": (try? JSON(encoding: trigger)) ?? .null])
  }

  // MARK: Importing

  /// Adds a follow-up for each open item of a Followups.md file that no
  /// earlier import read. The file stays as it is.
  func importFollowups(_ args: JSON) throws -> JSON {
    let file = args["file"]?.string ?? config.followupsFile.expandingTilde
    let text: String
    do {
      text = try String(contentsOfFile: file, encoding: .utf8)
    } catch {
      throw APIError("can't read \(file): \(error.localizedDescription)")
    }
    let now = nowMs()
    let items = Followup.openItems(text).map { item in
      (
        item, Followup.title(item.prompt),
        Followup(
          prompt: item.prompt, repository: item.repository, sourceBranch: item.sourceBranch,
          link: Followup.firstLink(item.prompt))
      )
    }
    return try queue.sync {
      var seen = try store.importedLines()
      var imported: [SessionSummary] = []
      for (item, title, followup) in items where seen.insert(item.key).inserted {
        var session = Session(
          id: shortId("s", taken: entries.keys), name: title, cwd: "", claudeSessionId: UUID().uuidString.lowercased(),
          created: item.added ?? now)
        session.followup = followup
        try save(session)
        try store.recordImport(item.key)
        imported.append(summary(session.id))
      }
      return [
        "file": .string(file), "imported": try JSON(encoding: imported),
        "skipped": .number(Double(items.count - imported.count)),
      ]
    }
  }
}
