import Foundation
import SwitchboardCore

/// Lists the Claude sessions that run outside Switchboard, and imports them.
/// Import never stops another claude, so a session imports only once no claude
/// runs it. An interactive session leaves `claude agents` when its claude
/// exits. So sbd remembers each session that it lists, and offers one that
/// left the list for a day after it last listed it.
extension Service {
  static let rememberMs: Int64 = 24 * 3600 * 1000

  /// The accounts whose sessions sbd lists.
  var accounts: [String] { (config.claudeConfigDirs ?? ClaudeAccount.discover()).map(ClaudeAccount.normalize) }

  /// The sessions that Switchboard doesn't have and that run in a linked
  /// worktree, or with `all`, every one.
  func importList(all: Bool) throws -> ImportList {
    let listed = try importCandidates()
    let candidates = withGitFacts(queue.sync { listed.filter { owner(of: $0.id) == nil } })
    let shown = all ? candidates : candidates.filter(\.worktree)
    return ImportList(sessions: shown.sorted(by: ClaudeSession.importOrder), hidden: candidates.count - shown.count)
  }

  /// Imports the sessions that the refs name. A ref is a Claude session id, a
  /// unique prefix of one, or a unique Claude name. git and the transcripts
  /// run off the state queue. A second check on the queue refuses a session
  /// that another request imported meanwhile.
  func importSessions(_ args: JSON) throws -> ImportResult {
    let refs = args["refs"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    guard !refs.isEmpty else { throw APIError("import needs a session") }
    let name = args["name"]?.string
    if name != nil && refs.count > 1 { throw APIError("a name fits only one imported session") }
    let candidates = try importCandidates()
    var refused: [Refusal] = []
    var chosen: [(ref: String, session: ClaudeSession)] = []
    queue.sync {
      for ref in refs {
        switch resolve(ref, in: candidates) {
        case .success(let c):
          if !chosen.contains(where: { $0.session.id == c.id }) { chosen.append((ref, c)) }
        case .failure(let error):
          refused.append(Refusal(ref: ref, reason: error.description))
        }
      }
    }
    let sessions = withGitFacts(chosen.map(\.session))
    let tails = concurrentMap(sessions) { s in
      Transcript.find(s.id, account: s.account, cwd: s.cwd).map(Transcript.tail) ?? TranscriptTail()
    }
    var imported: [SessionSummary] = []
    try queue.sync {
      for ((ref, session), tail) in zip(zip(chosen.map(\.ref), sessions), tails) {
        if let error = alreadyImported(ref, id: session.id) {
          refused.append(Refusal(ref: ref, reason: error.description))
        } else {
          imported.append(try adopt(session, name: name, tail: tail))
        }
      }
    }
    return ImportResult(imported: imported, refused: refused)
  }

  /// The sessions that `claude agents` lists now, and the remembered ones that
  /// have left the list, which no claude runs. The listed ones include those
  /// that Switchboard has, so that a ref to one by Claude's name gets the
  /// refusal that it is already in Switchboard. It runs claude off the state
  /// queue.
  func importCandidates() throws -> [ClaudeSession] {
    let now = nowMs()
    let accounts = self.accounts
    let listed = try listAgents(accounts, now: now)
    return queue.sync {
      let owned = Set(entries.values.map(\.session.claudeSessionId))
      let ids = Set(listed.map(\.id))
      remember(listed, owned: owned, ids: ids, now: now)
      return listed + exitedSessions(owned: owned, ids: ids, accounts: Set(accounts))
    }
  }

  /// The sessions that `claude agents --json` lists in each account. A row
  /// whose process is gone counts as a session that no claude runs. When two
  /// accounts list a session, the row whose claude runs wins.
  private func listAgents(_ accounts: [String], now: Int64) throws -> [ClaudeSession] {
    guard let claude = findExecutable(config.claude) else {
      throw APIError("can't find \(config.claude). Set \"claude\" in \(home.config)")
    }
    let lists = concurrentMap(accounts) { account in
      Result { () throws -> [ClaudeSession] in
        // claude creates a missing config folder and lists nothing.
        if !ClaudeAccount.holdsAccount(account) {
          throw APIError(
            "\(account) holds no Claude account (no .claude.json). Check claudeConfigDirs in \(home.config)")
        }
        var env = ProcessInfo.processInfo.environment
        ClaudeAccount.apply(account, to: &env)
        let r = try runCommand(claude, ["agents", "--json"], env: env)
        guard r.status == 0 else {
          throw APIError("claude agents failed for \(account): \(oneLine(r.stderr, max: 200))")
        }
        return try ClaudeSession.list(fromAgents: r.stdout, account: account, seen: now)
      }
    }
    var byId: [String: ClaudeSession] = [:]
    for var s in try lists.flatMap({ try $0.get() }) {
      if let pid = s.pid, !Processes.exists(pid) { s.clearProcess() }
      if byId[s.id]?.running != true { byId[s.id] = s }
    }
    return Array(byId.values)
  }

  /// Remembers the listed sessions that Switchboard doesn't own, and forgets
  /// the ones that left the list more than a day ago. `ids` are the listed ones.
  private func remember(_ listed: [ClaudeSession], owned: Set<String>, ids: Set<String>, now: Int64) {
    let fresh = listed.filter { !owned.contains($0.id) }
    for s in fresh { remembered[s.id] = s }
    do { try store.save(claudeSessions: fresh) } catch { logLine("can't remember Claude sessions: \(error)") }
    for s in remembered.values where !ids.contains(s.id) && now - s.seen > Service.rememberMs { forget(s.id) }
  }

  /// The remembered sessions that left the list, which no claude runs. A
  /// remembered session counts as exited only when sbd ran `claude agents` in
  /// its account this time. sbd doesn't ask an account that the config no
  /// longer names. That account's claude may still run the session.
  private func exitedSessions(owned: Set<String>, ids: Set<String>, accounts: Set<String>) -> [ClaudeSession] {
    return remembered.values.filter {
      !ids.contains($0.id) && !owned.contains($0.id) && accounts.contains($0.account)
    }.map { s in
      var s = s
      s.clearProcess()
      return s
    }
  }

  private func forget(_ claudeSessionId: String) {
    remembered[claudeSessionId] = nil
    do { try store.delete(claudeSession: claudeSessionId) } catch {
      logLine("can't forget \(claudeSessionId): \(error)")
    }
  }

  /// The candidate that the ref names, or why it can't be imported.
  private func resolve(_ ref: String, in candidates: [ClaudeSession]) -> Result<ClaudeSession, APIError> {
    let matches = candidates.filter { $0.id.hasPrefix(ref) || $0.name == ref }
    guard matches.count == 1 else {
      if matches.isEmpty, let error = alreadyImported(ref, id: ref) { return .failure(error) }
      return .failure(
        APIError(
          matches.isEmpty ? "no Claude session matches \(ref)" : "\(ref) matches \(matches.count) Claude sessions"))
    }
    let c = matches[0]
    if let error = alreadyImported(ref, id: c.id) { return .failure(error) }
    let label = c.name ?? c.idPrefix
    if let runs = c.whereItRuns(label) { return .failure(APIError(runs)) }
    guard isDirectory(c.cwd) else { return .failure(APIError("\(label)'s folder \(c.cwd) no longer exists.")) }
    return .success(c)
  }

  /// A Switchboard session whose conversation `id` names. `id` is a Claude
  /// session id, or a prefix that only one conversation has. A `/clear` or
  /// `/resume` in a pane can switch a session to another session's
  /// conversation. Two sessions can then hold one conversation, and this
  /// returns either of them.
  private func owner(of id: String) -> String? {
    let owners = entries.values.map(\.session).filter { $0.claudeSessionId.hasPrefix(id) }
    return Set(owners.map(\.claudeSessionId)).count == 1 ? owners.first?.id : nil
  }

  private func alreadyImported(_ ref: String, id: String) -> APIError? {
    owner(of: id).map { APIError("\(ref) is already in Switchboard as \($0)") }
  }

  /// Records a Switchboard session for the Claude session, without starting
  /// claude. Opening the session or sending it a message resumes the
  /// conversation under its account. Its repo stays nil, because sbd didn't
  /// create its worktree. `rm --worktree` then leaves the worktree.
  private func adopt(_ c: ClaudeSession, name: String?, tail: TranscriptTail) throws -> SessionSummary {
    let id = shortId("s", taken: entries.keys)
    var session = Session(
      id: id, name: name ?? c.title, cwd: c.cwd, branch: c.branch, claudeSessionId: c.id, created: nowMs())
    session.started = true
    session.claudeConfigDir = c.account
    entries[id] = Entry(session: session)
    try store.save(session)
    forget(c.id)
    record(
      id, "imported",
      [
        "account": .string(c.account), "lastReply": tail.lastReply.map(JSON.string) ?? .null,
        "lastActivity": tail.lastActivity.map { .number(Double($0)) } ?? .null, "hasReplies": .bool(tail.hasReplies),
      ])
    return summary(id)
  }

  /// Adds each session's repo, its branch, and whether its folder is a linked
  /// worktree. git runs once for each folder.
  private func withGitFacts(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
    let folders = Array(Set(sessions.map(\.cwd)))
    let facts = Dictionary(uniqueKeysWithValues: zip(folders, concurrentMap(folders, gitFacts)))
    return sessions.map { s in
      var s = s
      (s.repo, s.branch, s.worktree) = facts[s.cwd] ?? (nil, nil, false)
      return s
    }
  }

  /// A folder's repo, its branch, and whether it is a linked worktree, whose
  /// git folder differs from the repo's common one. A folder outside git has
  /// none of them.
  private func gitFacts(_ cwd: String) -> (repo: String?, branch: String?, worktree: Bool) {
    let args = ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--abbrev-ref", "HEAD"]
    let lines = (try? gitOutput(cwd, args))?.split(separator: "\n").map(String.init) ?? []
    guard lines.count == 3 else { return (nil, nil, false) }
    let (gitDir, commonDir, head) = (lines[0], lines[1], lines[2])
    return (Service.repoName(commonDir: commonDir), head == "HEAD" ? nil : head, gitDir != commonDir)
  }

  /// The folder name of the main checkout, whose common git folder is its
  /// .git, or of a bare repo without its .git suffix.
  static func repoName(commonDir: String) -> String {
    let path = commonDir as NSString
    if path.lastPathComponent == ".git" { return (path.deletingLastPathComponent as NSString).lastPathComponent }
    return path.lastPathComponent.hasSuffix(".git")
      ? String(path.lastPathComponent.dropLast(4)) : path.lastPathComponent
  }
}

/// Maps the items on concurrent threads and keeps their order.
private func concurrentMap<T, U>(_ items: [T], _ transform: (T) -> U) -> [U] {
  var results = [U?](repeating: nil, count: items.count)
  let lock = NSLock()
  DispatchQueue.concurrentPerform(iterations: items.count) { i in
    let value = transform(items[i])
    lock.lock()
    results[i] = value
    lock.unlock()
  }
  return results.map { $0! }
}
