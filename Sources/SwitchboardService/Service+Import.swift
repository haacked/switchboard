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
  /// claude may exit. A ref and a stop entry that name one session let its
  /// claude exit. That session must wait idle at its prompt in one other
  /// terminal. It then gets SIGTERM, and imports once its claude has exited. A
  /// busy or waiting session, a background job, and a session that several
  /// claudes run stay refused. So does a session whose claude also runs a
  /// listed session that is not imported, or that import can't exit.
  func importSessions(_ args: JSON) throws -> ImportResult {
    let refs = args["refs"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    guard !refs.isEmpty else { throw APIError("import needs a session") }
    let name = args["name"]?.string
    let stopRefs = args["stop"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    if name != nil && refs.count > 1 { throw APIError("a name fits only one imported session") }
    let candidates = try importCandidates()
    func named(_ refs: [String]) -> Set<String> {
      Set(
        refs.compactMap { ref in
          let found = Service.matches(ref, in: candidates)
          return found.count == 1 ? found[0].id : nil
        })
    }
    // The claude of a session exits only when a ref and a stop entry both name that one session.
    let stopped = named(refs).intersection(named(stopRefs))
    var refused: [Refusal] = []
    var chosen: [(ref: String, session: ClaudeSession)] = []
    queue.sync {
      for ref in refs {
        switch resolve(ref, in: candidates, stopped: stopped) {
        case .success(let c):
          if !chosen.contains(where: { $0.session.id == c.id }) { chosen.append((ref, c)) }
        case .failure(let error):
          refused.append(Refusal(ref: ref, reason: error.description))
        }
      }
    }
    refuseSharedClaudes(of: &chosen, among: candidates, into: &refused)
    // Only a stoppable session can still run here. Its claude exits off the state queue.
    let stuck = exitClaudes(of: chosen.map(\.session))
    refused += chosen.compactMap { item in stuck[item.session.id].map { Refusal(ref: item.ref, reason: $0) } }
    chosen.removeAll { stuck[$0.session.id] != nil }
    let sessions = withGitFacts(chosen.map(\.session))
    let tails = concurrentMap(sessions) { s in
      Transcript.find(s.id, account: s.account, cwd: s.cwd, on: mac.machine).map {
        Transcript.tail($0, on: mac.machine)
      }
        ?? TranscriptTail()
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
      let owned = Set(macConversations.map(\.claudeSessionId))
      let ids = Set(listed.map(\.id))
      remember(listed, owned: owned, ids: ids, now: now)
      return listed + exitedSessions(owned: owned, ids: ids, accounts: Set(accounts))
    }
  }

  /// The sessions that `claude agents --json` lists in each account. A row
  /// whose process is gone counts as a session that no claude runs. When two
  /// accounts list a session, the row whose claude runs wins, and it keeps the
  /// pids of both rows' claudes. A row whose claude can't be stopped wins over
  /// one whose claude can. A session that rows list with different pids has
  /// several claudes, so import refuses it.
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
        return try agentRows(claude, account: account, seen: now, on: mac.machine)
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
  /// claude and the account's folder are on `machine`.
  func agentRows(
    _ claude: String, account: String, seen: Int64, timeout: Double? = nil, on machine: any Machine
  ) throws -> [ClaudeSession] {
    var env = ProcessInfo.processInfo.environment
    ClaudeAccount.apply(account, to: &env)
    let r = try machine.run(claude, ["agents", "--json"], env: env, input: nil, timeout: timeout)
    guard r.status == 0 else {
      throw APIError("claude agents failed for \(account): \(oneLine(r.stderr, max: 200))")
    }
    return try ClaudeSession.list(fromAgents: r.stdout, account: account, seen: seen)
  }

  /// An interactive login shell gives claude the user's PATH and shell functions. The Claude pane and
  /// `agentRows(at:)` both start claude with these flags, so both find the same claude.
  static let claudeShellFlags = ["-l", "-i", "-c"]

  /// The rows of `claude agents --json` on a host, under the host's Claude login. The host's shell runs claude
  /// with `claudeShellFlags`, as the Claude pane does. The shell prints a token first, and the rows are what
  /// follows the token's line, so the output of a login or rc file is not read as rows. claude gets the
  /// environment of a pane's program and nothing from sbd's. It throws `HostUnread` unless the host answered
  /// the run. An interactive shell ignores SIGTERM, so the host's timeout ends a slow rc file only with the
  /// SIGKILL `RemoteSite.killGraceSeconds` later. The local deadline leaves room for that, because an answer
  /// after the deadline drops the link.
  func agentRows(at site: RemoteSite, seen: Int64, timeout: Double) throws -> [ClaudeSession] {
    let host = site.config.name
    let token = "sb-agents-\(UUID().uuidString)"
    let claude = shellQuote(claudeCommand(onHost: host))
    let slack = RemoteSite.deadlineSlack + RemoteSite.killGraceSeconds
    let r = try site.confirmed("claude agents", slack: slack) { machine in
      guard let facts = site.facts else { throw HostUnread(hostName: host, why: "setup has not run") }
      return try machine.run(
        facts.shell, Service.claudeShellFlags + ["printf '%s\\n' \(token); exec \(claude) agents --json"],
        env: RemoteSite.environment(for: facts), input: nil, timeout: timeout)
    }
    guard r.status == 0, let mark = r.stdout.range(of: token + "\n") else {
      throw APIError("claude agents failed on \(host): \(oneLine(r.stderr, max: 200))")
    }
    return try ClaudeSession.list(
      fromAgents: String(r.stdout[mark.upperBound...]), account: Service.hostAccount(host), seen: seen)
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

  /// Exits the claudes that run the sessions, and returns why a session can't
  /// import, by session id. It sends nothing until a fresh process list shows,
  /// for every pid of every session, a claude command that is neither sbd nor
  /// the claude of a Switchboard session, and that has no background task.
  /// `claude agents` can list a pid that another process has reused. It then
  /// sends SIGTERM to each verified pid once and waits up to five seconds for
  /// the claudes to exit. A session whose claude outlasts the signal is
  /// refused. A session that is not stoppable is refused here too. Every other
  /// session has one claude, so two sessions that share a pid get the same
  /// answer.
  private func exitClaudes(of sessions: [ClaudeSession]) -> [String: String] {
    let running = sessions.filter(\.running)
    guard !running.isEmpty else { return [:] }
    let snapshot: Snapshot
    do {
      snapshot = try mac.readSnapshot(claudeProgram: claudeProgram)
    } catch {
      return Dictionary(
        uniqueKeysWithValues: running.map {
          (
            $0.id,
            "\($0.label)'s claude stays running, because sbd can't list its own terminals to tell whether it owns that claude."
          )
        })
    }
    let program = (config.claude as NSString).lastPathComponent
    let owned = Set(snapshot.claudePids.values)
    var verified = Set<Int>()
    func problem(_ pid: Int, of s: ClaudeSession) -> String? {
      guard Processes.isValidPid(pid), pid != 1, pid != Int(getpid()) else { return notOutside(s, pid) }
      guard Processes.exists(pid) else { return nil }
      if owned.contains(pid) || !Service.isClaude(snapshot.processes.command(of: pid) ?? "", program: program) {
        return notOutside(s, pid)
      }
      if backgroundJobs(pid, in: snapshot.processes) > 0 {
        return
          "\(s.label)'s claude (pid \(pid)) runs a background task, and exiting claude would lose its result. Exit claude there, then import it."
      }
      verified.insert(pid)
      return nil
    }
    var refused: [String: String] = [:]
    for s in running {
      refused[s.id] = s.stoppable ? s.livePids.lazy.compactMap { problem($0, of: s) }.first : s.whereItRuns(s.label)
    }
    let exiting = running.filter { refused[$0.id] == nil }
    // Only a pid that passed the checks above gets a signal. A pid that did not exist then may name a process now.
    let alive = Set(exiting.flatMap(\.livePids)).intersection(verified)
    for pid in alive { kill(pid_t(pid), SIGTERM) }
    let stuck = Processes.waitForExit(alive, seconds: 5)
    for s in exiting {
      if let pid = s.livePids.first(where: stuck.contains) {
        refused[s.id] = "\(s.label)'s claude (pid \(pid)) didn't exit after SIGTERM. Exit it there, then import it."
      }
    }
    return refused.compactMapValues { $0 }
  }

  private func notOutside(_ s: ClaudeSession, _ pid: Int) -> String {
    "\(s.label)'s pid \(pid) is not a claude that runs outside Switchboard, so sbd leaves it running."
  }

  /// Moves each chosen session whose claude also runs a listed session that
  /// is not chosen to `refused`, because exiting that claude would end the
  /// other session too. Refusing one session can leave another without its
  /// companion, so this repeats until none moves.
  private func refuseSharedClaudes(
    of chosen: inout [(ref: String, session: ClaudeSession)], among candidates: [ClaudeSession],
    into refused: inout [Refusal]
  ) {
    var moved = true
    while moved {
      moved = false
      let ids = Set(chosen.map(\.session.id))
      for item in chosen {
        let s = item.session
        let shared = candidates.lazy.filter { $0.id != s.id && !ids.contains($0.id) }.compactMap { o in
          s.sharedPid(with: o).map { (o, $0) }
        }.first
        guard let (other, pid) = shared else { continue }
        refused.append(
          Refusal(
            ref: item.ref,
            reason:
              "\(s.label) shares its claude (pid \(pid)) with \(other.label), which isn't being imported. Import both together, or exit claude there, then import it."
          ))
        chosen.removeAll { $0.session.id == s.id }
        moved = true
        break
      }
    }
  }

  /// The candidates that the ref names: those whose id starts with it, or whose name it is.
  static func matches(_ ref: String, in candidates: [ClaudeSession]) -> [ClaudeSession] {
    candidates.filter { $0.id.hasPrefix(ref) || $0.name == ref }
  }

  /// The candidate that the ref names, or why it can't be imported. With
  /// `stopped`, an idle interactive session passes although a claude runs it.
  /// It is refused when a listed session that is not stoppable runs in a
  /// claude that also runs this one.
  private func resolve(_ ref: String, in candidates: [ClaudeSession], stopped: Set<String>) -> Result<
    ClaudeSession, APIError
  > {
    let matches = Service.matches(ref, in: candidates)
    guard matches.count == 1 else {
      if matches.isEmpty, let error = alreadyImported(ref, id: ref) { return .failure(error) }
      return .failure(
        APIError(
          matches.isEmpty ? "no Claude session matches \(ref)" : "\(ref) matches \(matches.count) Claude sessions"))
    }
    let c = matches[0]
    if let error = alreadyImported(ref, id: c.id) { return .failure(error) }
    let label = c.label
    // Exiting a claude ends every session that runs in it, so a session that
    // shares its claude with one that import can't exit is refused.
    if c.stoppable,
      let (other, pid) = candidates.lazy.filter({ !$0.stoppable }).compactMap({ o in
        c.sharedPid(with: o).map { (o, $0) }
      }).first
    {
      return .failure(
        APIError(
          "\(label) shares its claude (pid \(pid)) with \(other.label), which import can't exit. Exit claude there, then import it."
        ))
    }
    if !(stopped.contains(c.id) && c.stoppable), let runs = c.whereItRuns(label) { return .failure(APIError(runs)) }
    guard isDirectory(c.cwd) else { return .failure(APIError("\(label)'s folder \(c.cwd) no longer exists.")) }
    return .success(c)
  }

  /// The sessions whose conversation is one of this Mac's. A session on a host names a conversation of that
  /// host, and the host's SessionStart hook chooses the id. It owns no conversation that import lists.
  private var macConversations: [Session] { entries.values.map(\.session).filter { $0.host == nil } }

  /// A Switchboard session whose conversation `id` names. `id` is a Claude
  /// session id, or a prefix that only one conversation has. A `/clear` or
  /// `/resume` in a pane can switch a session to another session's
  /// conversation. Two sessions can then hold one conversation, and this
  /// returns either of them.
  private func owner(of id: String) -> String? {
    let owners = macConversations.filter { $0.claudeSessionId.hasPrefix(id) }
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
    let id = newSessionID()
    var session = Session(
      id: id, name: name ?? c.title, cwd: c.cwd, branch: c.branch, claudeSessionId: c.id, created: nowMs())
    session.started = true
    session.claudeConfigDir = c.account
    session.autoMode = config.autoMode
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
    let lines = (try? gitOutput(cwd, args, at: mac))?.split(separator: "\n").map(String.init) ?? []
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
