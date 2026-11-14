import Foundation
import SwitchboardCore

/// The Issues view: open issues from the configured sources, which the GitHub poller caches in issues.json.
extension Service {
  /// The requests that change only sbd's state. They run on the state queue.
  func issuesRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "issues":
      return try JSON(encoding: issueList())
    case "issues-source-add":
      let source = try IssueSource.parse(
        args["source"]?.string ?? "", label: args["label"]?.string, person: args["person"]?.string)
      try updateIssueSettings { settings in
        guard !settings.sources.contains(where: { $0.key == source.key }) else {
          throw APIError("\(source.key) is already a source")
        }
        settings.sources.append(source)
      }
      return try JSON(encoding: issueSettings.sources)
    case "issues-source-rm":
      let source = try issueSource(args)
      try updateIssueSettings { $0.sources.removeAll { $0 == source } }
      issueCache.remove(source: source.key)
      saveIssueCache()
      return try JSON(encoding: issueSettings.sources)
    case "issues-settings":
      try updateIssueSettings { settings in
        if let labels = args["labels"]?.array { settings.team.labels = labels.compactMap(\.string) }
        if let people = args["people"]?.array { settings.team.people = people.compactMap(\.string) }
        if let preset = args["defaultPreset"]?.string {
          _ = try IssuePreset.named(preset, in: settings.allPresets)
          settings.defaultPreset = preset
        }
      }
      return try JSON(encoding: issueList())
    case "issues-dismiss":
      let issue = try cachedIssue(args["issue"]?.string ?? "")
      issueCache.dismissed[issue.id] = issue.updatedAt
      saveIssueCache()
      return try JSON(encoding: issueList())
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// The requests that wait on GitHub, gh, or git. They run off the state queue.
  func issueWorkRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "issues-refresh":
      // The Issues view sends it as it opens. Presets edited in config.json then show without a restart.
      reloadIssueSettings()
      // A refresh waits for a running poll. The reply includes that poll's issues. A recent poll needs no refresh.
      let age = Int64(args["maxAgeSeconds"]?.int ?? 0) * 1000
      if GitHub.elapsed(since: queue.sync(execute: { issueCache.polledAt }), age, now: nowMs()) {
        github?.refreshIssues(olderThan: age)
      }
      return try queue.sync { try JSON(encoding: issueList()) }
    case "issues-start":
      return try JSON(encoding: startIssue(args))
    case "issues-clone":
      return ["path": .string(try cloneRepository(args["repo"]?.string ?? ""))]
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// The cached issues with their buckets. It runs on the state queue.
  func issueList() -> IssueList {
    let inbox = IssueInbox(viewer: issueCache.viewer, team: issueSettings.team)
    let sessions = summaries().filter { !$0.waitsToStart }
    let issues = inbox.list(
      issueCache.issues, sessions: sessions, marks: issueCache.marks, dismissed: issueCache.dismissed)
    return IssueList(
      viewer: issueCache.viewer, issues: issues, sources: issueSettings.sources, team: issueSettings.team,
      presets: issueSettings.allPresets, defaultPreset: issueSettings.defaultPreset,
      branchPrefix: config.branchPrefix, polledAt: issueCache.polledAt,
      error: issueCache.error, sourceErrors: issueCache.sourceErrors,
      pausedUntil: issueCache.pausedUntil.flatMap { $0 > nowMs() ? $0 : nil })
  }

  /// Stores an "addressed by merged #N" mark for each of the removed session's issues that is still open, when its
  /// PR merged. `forgetSession` calls it on the state queue.
  func markAddressedIssues(_ removed: SessionSummary) {
    let marks = IssueMark.marks(removing: removed, open: issueCache.issues)
    guard !marks.isEmpty else { return }
    issueCache.marks += marks.filter { mark in !issueCache.marks.contains { $0.id == mark.id } }
    saveIssueCache()
  }

  /// Folds in a poll of the sources and saves the cache. The poller calls it on the state queue.
  func applyIssuePoll(_ poll: IssuePoll) {
    var cache = issueCache
    cache.apply(poll, sources: Set(issueSettings.sources.map(\.key)))
    guard cache != issueCache else { return }
    issueCache = cache
    saveIssueCache()
  }

  func loadIssueCache() {
    guard let text = try? String(contentsOfFile: home.issues, encoding: .utf8) else { return }
    do {
      issueCache = try JSONCoding.decode(IssueCache.self, from: text)
    } catch {
      logLine("ignoring \(home.issues): \(error)")
    }
  }

  func saveIssueCache() {
    do {
      try (JSONCoding.encode(issueCache) + "\n").write(toFile: home.issues, atomically: true, encoding: .utf8)
    } catch {
      logLine("can't save \(home.issues): \(error)")
    }
  }

  /// The source that `args` names: by its name and filters when it has a label or a person, else by a name that
  /// only one source has.
  private func issueSource(_ args: JSON) throws -> IssueSource {
    let name = args["source"]?.string ?? ""
    let label = args["label"]?.string
    let person = args["person"]?.string
    if label != nil || person != nil {
      let key = IssueSource(name: name, label: label, person: person).key
      guard let source = issueSettings.sources.first(where: { $0.key == key }) else {
        throw APIError("no source \(key)")
      }
      return source
    }
    let named = issueSettings.sources.filter { $0.name.lowercased() == name.lowercased() }
    guard named.count == 1 else {
      throw APIError(
        named.isEmpty ? "no source \(name)" : "\(name) names \(named.count) sources. Pass --label or --person")
    }
    return named[0]
  }

  /// Changes config.json's `issues` with one read and one write, then keeps the result as `issueSettings`. It starts
  /// from the file, so edits made there by hand, such as new presets, come along.
  private func updateIssueSettings(_ change: (inout IssueSettings) throws -> Void) throws {
    var updated = IssueSettings()
    try updateSettings { settings in
      updated = try settings["issues"].map { try JSONCoding.convert($0, to: IssueSettings.self) } ?? IssueSettings()
      try change(&updated)
      settings["issues"] = try JSON(encoding: updated)
    }
    issueSettings = updated
  }

  /// Reads config.json's `issues` into `issueSettings`. A file that doesn't read keeps the current settings. It runs
  /// off the state queue.
  private func reloadIssueSettings() {
    guard let text = try? String(contentsOfFile: home.config, encoding: .utf8), let object = JSON.parse(text)?.object,
      let settings = try? object["issues"].map({ try JSONCoding.convert($0, to: IssueSettings.self) })
        ?? IssueSettings()
    else { return }
    queue.sync { issueSettings = settings }
  }

  /// The cached issue that `text` names as owner/name#N or an issue URL.
  private func cachedIssue(_ text: String) throws -> InboxIssue {
    let ref = try IssueRef.parse(text)
    guard let repo = ref.repo else { throw APIError("name the issue as owner/name#N or by its URL") }
    guard let issue = issueCache.issues.first(where: { $0.id == InboxIssue.id(repo, ref.number) }) else {
      throw APIError("\(repo)#\(ref.number) isn't among the open issues from the sources. sb poll --all reads them")
    }
    return issue
  }

  /// Starts a session on a cached issue: a worktree on `<branchPrefix><number>-<slug>` in the repository's checkout,
  /// the session's issue set to the issue, and the preset's prompt as its first message. An issue that the viewer or a
  /// teammate didn't write starts its session without auto mode.
  private func startIssue(_ args: JSON) throws -> SessionSummary {
    let (issue, presets, defaultPreset, trusted) = try queue.sync {
      let issue = try cachedIssue(args["issue"]?.string ?? "")
      let inbox = IssueInbox(viewer: issueCache.viewer, team: issueSettings.team)
      return (issue, issueSettings.allPresets, issueSettings.defaultPreset, inbox.trusts(issue))
    }
    let preset =
      try args["preset"]?.string.map { try IssuePreset.named($0, in: presets) }
      ?? IssuePreset.choose(presets, last: nil, default: defaultPreset) ?? presets[0]
    let repo: String
    if let path = args["path"]?.string {
      repo = (path.expandingTilde as NSString).standardizingPath
      guard hasRemote(repo, for: issue.repo) else {
        throw APIError("\(repo) has no remote on github.com for \(issue.repo)")
      }
    } else {
      repo = try checkout(of: issue.repo, hint: "Clone it or choose its folder")
    }
    let branch = issue.branch(prefix: config.branchPrefix)
    guard !branchOrFolderTaken(repo, branch, at: mac) else {
      throw APIError("branch \(branch) or its worktree exists in \(repo)")
    }
    return try newSession(
      NewSession(
        path: repo, branch: branch, name: issueSessionName(issue),
        worktree: true, prompt: preset.prompt(for: issue), group: args["group"]?.string,
        autoMode: trusted ? nil : false, issue: IssueRef(repo: issue.repo, number: issue.number)))
  }

  /// A slug of the title, or `issue-<N>` for a title with no ASCII letters or digits.
  private func issueSessionName(_ issue: InboxIssue) -> String {
    let slug = Followup.slug(issue.title, max: 30)
    return slug.isEmpty ? "issue-\(issue.number)" : slug
  }

  /// Clones `owner/name` with gh into the first folder of `repoRoots`, and returns the checkout's path.
  private func cloneRepository(_ repo: String) throws -> String {
    guard Issues.validRepo(repo) else { throw APIError("can't read \"\(repo)\" as owner/name") }
    guard let root = config.repoRoots.first else { throw APIError("repoRoots in \(home.config) lists no folder") }
    let path = ("\(root)/\(repo)".expandingTilde as NSString).standardizingPath
    guard !FileManager.default.fileExists(atPath: path) else { throw APIError("\(path) exists") }
    // A clone of a large repository takes minutes. `sb issues start` waits as long.
    _ = try runGh(["repo", "clone", repo, path], timeout: 300)
    return path
  }
}
