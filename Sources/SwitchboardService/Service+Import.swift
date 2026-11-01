import Foundation
import SwitchboardCore

/// Lists the Claude sessions that run outside Switchboard, and imports them.
/// Import stops no claude unless asked to, so a session imports once no claude
/// runs it. An interactive session leaves `claude agents` when its claude
/// exits. So sbd remembers each session that it lists, and offers one that
/// left the list for a day after it last listed it.
extension Service {
  static let rememberMs: Int64 = 24 * 3600 * 1000

  /// The accounts whose sessions sbd lists.
  var accounts: [String] { (config.claudeConfigDirs ?? ClaudeAccount.discover()).map(ClaudeAccount.normalize) }

  /// The sessions that Switchboard doesn't have and that run in a linked
  /// worktree, or with `all`, every one. With `repo`, only the sessions of the
  /// repo with that name.
  func importList(all: Bool, repo: String?) throws -> ImportList {
    let listed = try importCandidates()
    let candidates = withGitFacts(queue.sync { listed.filter { owner(of: $0.id) == nil } })
    return ImportList.make(from: candidates, all: all, repo: repo)
  }

  /// Imports the sessions that the refs name. A ref is a Claude session id, a
  /// unique prefix of one, or a unique Claude name. git and the transcripts
  /// run off the state queue. A second check on the queue refuses a session
  /// that another request imported meanwhile. `stop` lists the refs whose
  /// claude may exit. A listed session that waits idle at its prompt in
  /// another terminal gets SIGTERM, and imports once its claude has exited. A
  /// busy or waiting session, a background job, and a session whose pid another
  /// listed session that is not stoppable shares stay refused.
  func importSessions(_ args: JSON) throws -> ImportResult {
    let refs = args["refs"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    guard !refs.isEmpty else { throw APIError("import needs a session") }
    let name = args["name"]?.string
    let stop = Set(args["stop"]?.array?.compactMap(\.string) ?? [])
    if name != nil && refs.count > 1 { throw APIError("a name fits only one imported session") }
    let candidates = try importCandidates()
    var refused: [Refusal] = []
    var chosen: [(ref: String, session: ClaudeSession)] = []
    queue.sync {
      for ref in refs {
        switch resolve(ref, in: candidates, stop: stop.contains(ref)) {
        case .success(let c):
          if !chosen.contains(where: { $0.session.id == c.id }) { chosen.append((ref, c)) }
        case .failure(let error):
          refused.append(Refusal(ref: ref, reason: error.description))
        }
      }
    }
    // Only a stoppable session can still run here. Its claude exits off the state queue.
    let snapshot = chosen.contains { $0.session.running } ? buildSnapshot() : Snapshot()
    let exits = concurrentMap(chosen.map(\.session)) { $0.running ? exitClaude(of: $0, in: snapshot) : nil }
    refused += zip(chosen, exits).compactMap { item, why in why.map { Refusal(ref: item.ref, reason: $0) } }
    chosen = zip(chosen, exits).filter { $0.1 == nil }.map(\.0)
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
  /// accounts list a session, the row whose claude runs wins, and it keeps the
  /// pids of both rows' claudes. A row whose claude can't be stopped wins over
  /// one whose claude can, so that `stop` never exits a claude that another
  /// account lists as busy.
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
        return try agentRows(claude, account: account, seen: now)
      }
    }
    var byId: [String: ClaudeSession] = [:]
    for var s in try lists.flatMap({ try $0.get() }) {
      if let pid = s.pid, !Processes.exists(pid) { s.clearProcess() }
      guard let existing = byId[s.id], existing.running else {
        byId[s.id] = s
        continue
      }
      var (winner, loser) = s.keepRank > existing.keepRank ? (s, existing) : (existing, s)
      let others = Set(winner.livePids + loser.livePids).subtracting(winner.pid.map { [$0] } ?? [])
      winner.otherPids = others.isEmpty ? nil : others.sorted()
      byId[s.id] = winner
    }
    return Array(byId.values)
  }

  /// The rows of `claude agents --json` under one account. With `timeout`,
  /// a claude that hangs fails the call.
  func agentRows(_ claude: String, account: String, seen: Int64, timeout: Double? = nil) throws -> [ClaudeSession] {
    var env = ProcessInfo.processInfo.environment
    ClaudeAccount.apply(account, to: &env)
    let r = try runCommand(claude, ["agents", "--json"], env: env, timeout: timeout)
    guard r.status == 0 else {
      throw APIError("claude agents failed for \(account): \(oneLine(r.stderr, max: 200))")
    }
    return try ClaudeSession.list(fromAgents: r.stdout, account: account, seen: seen)
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

  /// Sends SIGTERM to every claude that runs the session, and waits up to five
  /// seconds for them to exit. Returns why one didn't exit, or nil once all
  /// have. It sends nothing unless a fresh process list shows, for each pid, a
  /// claude command that is neither sbd nor the claude of a Switchboard
  /// session. `claude agents` can list a pid that another process has reused.
  private func exitClaude(of s: ClaudeSession, in snapshot: Snapshot) -> String? {
    let pids = s.livePids
    if let bad = pids.first(where: { $0 <= 1 || $0 == Int(getpid()) || $0 > Int(Int32.max) }) {
      return refuseToSignal(s, bad)
    }
    let alive = pids.filter(Processes.exists)
    let program = (config.claude as NSString).lastPathComponent
    let rows = snapshot.children.values.joined()
    for pid in alive {
      let isClaude = rows.contains { $0.pid == pid && Service.isClaude($0, program: program) }
      if !isClaude || snapshot.claudePids.values.contains(pid) { return refuseToSignal(s, pid) }
    }
    for pid in alive { kill(pid_t(pid), SIGTERM) }
    for _ in 0..<50 {
      if alive.allSatisfy({ !Processes.exists($0) }) { return nil }
      Thread.sleep(forTimeInterval: 0.1)
    }
    let stuck = alive.first(where: Processes.exists) ?? alive[0]
    return "\(s.name ?? s.idPrefix)'s claude (pid \(stuck)) didn't exit after SIGTERM. Exit it there, then import it."
  }

  private func refuseToSignal(_ s: ClaudeSession, _ pid: Int) -> String {
    "\(s.name ?? s.idPrefix)'s pid \(pid) is not a claude that runs outside Switchboard, so sbd leaves it running."
  }

  /// The candidate that the ref names, or why it can't be imported. With
  /// `stop`, an idle interactive session passes although a claude runs it,
  /// unless a listed session that is not stoppable runs in a claude that also
  /// runs this one.
  private func resolve(_ ref: String, in candidates: [ClaudeSession], stop: Bool) -> Result<ClaudeSession, APIError> {
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
    let sharesBusyPid = candidates.contains {
      $0.id != c.id && !$0.stoppable && !Set($0.livePids).isDisjoint(with: c.livePids)
    }
    if !(stop && c.stoppable && !sharesBusyPid), let runs = c.whereItRuns(label) { return .failure(APIError(runs)) }
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
  /// create its worktree. `rm --worktree` then refuses and removes nothing.
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
func concurrentMap<T, U>(_ items: [T], _ transform: (T) -> U) -> [U] {
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
