import Foundation
import SwitchboardCore

/// Which account each session runs under. A session records its
/// account when sbd creates or imports it, and keeps it, because the
/// conversation's transcript lives in the account's folder. Sessions run
/// only on Claude accounts. sbd lists Codex accounts and reads their usage.
extension Service {
  /// The account that a new session without a parent uses: the one that
  /// `sb account use` chose, else CLAUDE_CONFIG_DIR from config.env or from
  /// sbd's environment, else Claude's default account. It skips a
  /// CLAUDE_CONFIG_DIR that names a Codex folder.
  var activeAccount: ClaudeAccount {
    if let chosenAccount { return chosenAccount }
    let configured = config.env["CLAUDE_CONFIG_DIR"] ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    return configured.flatMap { claudeAccount(folder: $0) } ?? ClaudeAccount(folder: ClaudeAccount.defaultFolder)
  }

  /// Reads the account that `sb account use` chose. It ignores a folder that
  /// no longer holds a Claude account or that is now a Codex folder, so a
  /// removed or reconfigured account doesn't stop sessions from starting.
  func loadChosenAccount() {
    guard let text = try? String(contentsOfFile: home.activeAccount, encoding: .utf8) else { return }
    let folder = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let account = ClaudeAccount(folder: folder)
    if let name = codexName(folder) {
      logLine("ignoring the chosen account \(folder): \(name) is a Codex account")
    } else if account.holdsAccount {
      chosenAccount = account
    } else {
      logLine("ignoring the chosen account \(folder): it holds no Claude account")
    }
  }

  /// The account that `ref` names. A folder that `codexHomes` lists never
  /// resolves to a Claude account, even when it holds a Claude login.
  func resolveAccount(_ ref: String) throws -> Account {
    try Account.resolve(ref, among: accounts, codexHomes: config.codexHomes)
  }

  /// The account that `ref` names, for a request that only a Claude account can serve, such as `account use` or
  /// `account move`.
  func resolveClaudeAccount(_ ref: String) throws -> ClaudeAccount {
    switch try resolveAccount(ref) {
    case .claude(let account): account
    case .codex(let account): throw APIError(Self.codexRefusal(account.name))
    }
  }

  /// The Codex account's name when `CodexAccount.whyCodex` claims the folder, else nil. A Claude-only consumer
  /// refuses such a folder, or falls back to a Claude account. The folder may also hold a Claude login, which
  /// makes it neither kind.
  func codexName(_ folder: String) -> String? {
    CodexAccount.whyCodex(folder, codexHomes: config.codexHomes) == nil ? nil : CodexAccount(folder: folder).name
  }

  /// The Claude account in `folder`, or nil when `codexName` claims the folder.
  func claudeAccount(folder: String) -> ClaudeAccount? {
    codexName(folder) == nil ? ClaudeAccount(folder: folder) : nil
  }

  /// Why a session can't start, or a request can't use, the Codex account `name`.
  static func codexRefusal(_ name: String) -> String {
    "\(name) is a Codex account, and \(Agent.onlyClaudeRunsSessions)"
  }

  /// Why claude can't launch for the local session `id`: the account that its pane would set is a Codex folder.
  /// The stored account, config.env, or sbd's own CLAUDE_CONFIG_DIR may name a folder that became one. A pane
  /// without CLAUDE_CONFIG_DIR runs claude under the default account.
  func codexLaunchRefusal(_ id: String) -> String? {
    guard entries[id]?.session.host == nil, let name = codexName(paneAccountFolder(id)) else { return nil }
    return Self.codexRefusal(name)
  }

  /// The folder of the Claude account that the session's pane sets. A pane without CLAUDE_CONFIG_DIR runs claude
  /// under the default account.
  func paneAccountFolder(_ id: String) -> String {
    paneEnv(id)["CLAUDE_CONFIG_DIR"] ?? ClaudeAccount.defaultFolder
  }

  /// Why a conversation can't move to or from the Codex account `name`.
  static func codexMoveRefusal(_ name: String) -> String {
    "\(name) is a Codex account, and a Codex conversation also lives in Codex's databases, which a move doesn't copy"
  }

  /// The account of a new session: its group's account, else the one named,
  /// else its parent's when the parent runs on this Mac, or nil when none of
  /// them applies. A parent on a host has the host's account, which no session
  /// on this Mac can use. It refuses a named
  /// account that differs from the group's, because the session's next launch
  /// would move it to the group's account. It refuses a Codex account, named or the parent's.
  func accountForNew(named ref: String?, parent: String?, for session: Session) throws -> String? {
    let named = try ref.flatMap { $0.isEmpty ? nil : try resolveClaudeAccount($0).folder }
    if let group = accountGroupForNew(session), let bound = group.account {
      if let named, named != bound {
        throw APIError(
          "the group \(group.name) runs its sessions under the account \(Account.name(ofFolder: bound)). Leave out the account, or pick another group"
        )
      }
      return bound
    }
    if let named { return named }
    guard let parent, entries[parent] != nil else { return nil }
    switch claudeAccount(of: parent) {
    case .local(let account): return account.folder
    case .codex(let account):
      throw APIError(
        "the parent \(mention(parent)) runs under \(Self.codexRefusal(account.name)). Name a Claude account")
    case .host: return nil
    }
  }

  /// The session's account group, while the group's folder still holds a
  /// Claude account. A new session in a group whose account folder went away,
  /// or became a Codex account, uses the account it would use without the group.
  func accountGroupForNew(_ session: Session) -> SessionGroup? {
    accountGroup(of: session).flatMap {
      claudeAccount(folder: $0.account!)?.holdsAccount == true ? $0 : nil
    }
  }

  /// The account that a follow-up starts under: its group's, else the one it stores, else the active account.
  func followupAccount(_ session: Session) -> String {
    accountGroupForNew(session)?.account ?? session.claudeConfigDir ?? activeAccount.folder
  }

  /// The group whose account the session runs under, or nil when that group
  /// names no account. A chat's group is the one it manages.
  func accountGroup(of session: Session) -> SessionGroup? {
    (session.chat ?? session.group).flatMap { groups[$0] }.flatMap { $0.account == nil ? nil : $0 }
  }

  /// The accounts that `sb account` lists: `accounts`, with the active account inserted first when `accounts`
  /// doesn't include it and `codexName` doesn't claim it.
  func listedAccounts() -> [Account] {
    let active = Account.claude(activeAccount)
    var all = accounts
    if !all.contains(active), codexName(active.folder) == nil { all.insert(active, at: 0) }
    return all
  }

  func accountList() -> [AccountInfo] {
    let active = Account.claude(activeAccount)
    let counts = Dictionary(grouping: entries.keys.filter { entries[$0]!.session.runsClaude }) {
      claudeAccount(of: $0).key
    }
    return listedAccounts().map {
      AccountInfo(
        name: $0.name, folder: $0.folder, active: $0 == active, sessions: counts[$0.folder]?.count ?? 0,
        agent: $0.agent)
    }
  }

  func accountRequest(_ op: String, _ args: JSON) throws -> JSON {
    if op == "account-move" { return try JSON(encoding: moveSessions(args)) }
    if op == "account-add" { return try addAccount(args) }
    if op == "account-use" {
      guard let ref = args["account"]?.string, !ref.isEmpty else { throw APIError("name an account") }
      let account = try resolveClaudeAccount(ref)
      try account.folder.write(toFile: home.activeAccount, atomically: true, encoding: .utf8)
      chosenAccount = account
      logLine("new sessions use the account \(account.folder)")
    }
    return try JSON(encoding: accountList())
  }

  /// Throws when the target of `account-use` or `account-move` has no login,
  /// because claude would ask a session there for /login. A target whose last
  /// reading found no login is read again first, so an account that signed in
  /// since then is accepted. A reading that failed for another reason, such
  /// as a locked keychain, lets the account through. So does an account that
  /// sbd has not read. It must run off the state queue, because a read waits
  /// on the keychain and the network.
  func requireSignedIn(_ args: JSON) throws {
    guard let reader = usageReader, let ref = args["account"]?.string,
      let account = try? queue.sync(execute: { try resolveClaudeAccount(ref) }),
      Self.signedOutRefusal(reader.latest(account.folder)) != nil
    else { return }
    if let refusal = Self.signedOutRefusal(reader.read(.claude(account))) { throw APIError(refusal) }
  }

  /// Makes the folder ~/.codex-<name> or ~/.claude-<name> for a new account of
  /// the agent, and returns it with the command that signs it in. Login is
  /// interactive, so sbd never runs it. The name becomes part of a folder in
  /// the home, so it takes only letters, digits, `.`, `_`, and `-`, and starts
  /// with a letter or digit. It refuses an existing folder, because the
  /// folder may hold a login. It also refuses a name that a listed account
  /// already has, such as `codex-work` for ~/.claude-codex-work beside
  /// ~/.codex-work.
  private func addAccount(_ args: JSON) throws -> JSON {
    let name = args["name"]?.string ?? ""
    guard let raw = args["agent"]?.string, let agent = Agent(rawValue: raw) else {
      throw APIError("name the agent: \(Agent.allCases.map(\.rawValue).joined(separator: " or "))")
    }
    let plain = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
    guard let first = name.first, plain(first), name.allSatisfy({ plain($0) || "._-".contains($0) }) else {
      throw APIError(
        "\"\(name)\" can't name an account. Use letters, digits, '.', '_', and '-', starting with a letter or digit")
    }
    let account: Account
    let login: String
    switch agent {
    case .claude:
      let claude = ClaudeAccount(folder: "\(NSHomeDirectory())/.claude-\(name)")
      (account, login) = (.claude(claude), "\(claude.command(config.claude)), then /login")
    case .codex:
      let codex = CodexAccount(folder: "\(NSHomeDirectory())/.codex-\(name)")
      (account, login) = (.codex(codex), codex.loginCommand)
    }
    if let other = accounts.first(where: { $0.name == account.name }) {
      throw APIError("\(other.folder) is already named \(account.name), so the name would pick neither account")
    }
    do {
      try FileManager.default.createDirectory(
        atPath: account.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch {
      if FileManager.default.fileExists(atPath: account.folder) {
        throw APIError("\(account.folder) exists, and it may hold a login, so sbd leaves it alone")
      }
      throw APIError("can't make \(account.folder): \(error.localizedDescription)")
    }
    logLine("made the \(agent.rawValue) account folder \(account.folder)")
    return [
      "name": .string(account.name), "folder": .string(account.folder), "agent": .string(agent.rawValue),
      "login": .string(login),
    ]
  }

  /// The account's name followed by the reading's `SignedOut` error. That
  /// error names the login command.
  static func signedOutRefusal(_ reading: AccountUsage?) -> String? {
    guard let reading, reading.signedOut == true else { return nil }
    return "\(reading.name) is \(reading.error ?? "not signed in")"
  }
}

// MARK: Moving sessions

extension Service {
  /// Moves every session that is not on the account to it, or with `dryRun`
  /// lists the ones that would move. Only a session whose claude is stopped
  /// moves: a claude that runs, or a message on its way, keeps writing the
  /// old account's transcript, and a second claude that resumes the
  /// conversation forks it. `sessions`, a list of session refs, limits the
  /// move to those sessions. The result then lists each named session that
  /// stays in `blocked`, including one already on the account. `stop` needs
  /// `sessions`. Before a move with `stop` runs, sbd stops the claudes that
  /// `sessionsToStopForMove` picks. A dry run with `stop` lists a running
  /// named session as one that would move. `mcpDropped` names the MCP
  /// servers that each moved session's server list loses on the account.
  func moveSessions(_ args: JSON) throws -> AccountMove {
    let target = try moveTarget(args)
    let dryRun = args["dryRun"]?.bool ?? false
    let named = try namedForMove(args)
    let listsRunningAsMovable = dryRun && args["stop"]?.bool == true
    var result = AccountMove(account: target.folder)
    var dropped: [String: [String]] = [:]
    var available: [String: JSON]?
    for id in named ?? entries.keys.sorted() {
      guard let session = entries[id]?.session else { continue }
      let block = { (reason: String) in result.blocked.append(.init(session: id, name: session.name, reason: reason)) }
      let account = claudeAccount(of: id)
      if let reason = notMovable(session, account: account, to: target) {
        if named != nil { block(reason) }
        continue
      }
      if let reason = moveRefusal(id, account: account, to: target, listsRunningAsMovable: listsRunningAsMovable) {
        block(reason)
        continue
      }
      do {
        if !dryRun { try move(id, to: target) }
        result.moved.append(id)
        if let names = session.mcp {
          let servers = available ?? availableMCPServers(account: target)
          available = servers
          let missing = names.filter { servers[$0] == nil }.sorted()
          if !missing.isEmpty { dropped[id] = missing }
        }
      } catch {
        block("\(error)")
      }
    }
    if !dropped.isEmpty { result.mcpDropped = dropped }
    if !dryRun && !result.moved.isEmpty {
      logLine("moved \(result.moved.count) sessions to the account \(target.folder)")
    }
    return result
  }

  /// The sessions whose claude an `account-move` with `stop` stops: the named
  /// sessions that a dry run of the move lists and whose claude runs. A
  /// session that the move refuses for another reason keeps its claude. It
  /// runs on the state queue.
  func sessionsToStopForMove(_ args: JSON) throws -> [String] {
    var dryRun = args.object ?? [:]
    dryRun["dryRun"] = .bool(true)
    return try moveSessions(.object(dryRun)).moved.filter {
      if case .running = claudeState($0) { true } else { false }
    }
  }

  private func moveTarget(_ args: JSON) throws -> ClaudeAccount {
    guard let ref = args["account"]?.string, !ref.isEmpty else { throw APIError("name an account") }
    return try resolveClaudeAccount(ref)
  }

  /// The sessions that the request's `sessions` names, or nil when it names
  /// none. `stop` without `sessions` throws, so that it never stops every claude.
  private func namedForMove(_ args: JSON) throws -> [String]? {
    guard let value = args["sessions"] else {
      if args["stop"]?.bool == true { throw APIError("stop moves only named sessions. Name one with --session") }
      return nil
    }
    guard let refs = value.array, !refs.isEmpty else { throw APIError("sessions is a list of one or more sessions") }
    return try Set(refs.map { try lookup(["session": $0]) }).sorted()
  }

  /// Why the move does not consider the session: it has not started, or it
  /// already runs under the account. A bulk move skips such a session. A
  /// named move lists it in `blocked`.
  private func notMovable(_ session: Session, account: SessionAccount, to target: ClaudeAccount) -> String? {
    if session.cwd.isEmpty { return "it has not started" }
    if account == .local(target) { return "it already runs under \(target.name)" }
    return nil
  }

  /// Why the session cannot move now, so that `dryRun` lists the same
  /// sessions as a move. With `listsRunningAsMovable`, a running claude does not refuse the move.
  /// Only a dry run of a move with `stop` sets it, because the real move
  /// stops that claude before it runs and then refuses a claude that still runs.
  private func moveRefusal(
    _ id: String, account: SessionAccount, to target: ClaudeAccount, listsRunningAsMovable: Bool
  ) -> String? {
    guard let e = entries[id] else { return "no session \(id)" }
    switch account {
    case .local: break
    case .codex(let codex): return Self.codexMoveRefusal(codex.name)
    case .host(let host): return "it runs under the Claude login of \(host)"
    }
    if let group = accountGroup(of: e.session), let bound = group.account, bound != target.folder {
      return
        "its group \(group.name) runs its sessions under the account \(Account.name(ofFolder: bound)). Move it out of the group, or change the group's account with sb group account"
    }
    if starting.contains(id) { return "it is starting" }
    if let refusal = beingDeletedRefusal(id) { return "\(refusal)" }
    switch claudeState(id) {
    // A stopped claude's queue moves with the session, and its next launch reads the moved transcript.
    case .stopped: break
    case .running where listsRunningAsMovable:
      if e.hasMessageOnItsWay { return "a message is on its way to it" }
    default: return "its claude is running. Stop it first"
    }
    if let source = transcriptFile(e.session) {
      let dest = transcriptDestination(source, id: e.session.claudeSessionId, to: target)
      if let conflict = transcriptConflict(source, dest) { return conflict }
    }
    return nil
  }

  private func transcriptDestination(_ source: String, id: String, to target: ClaudeAccount) -> String {
    let folder = ((source as NSString).deletingLastPathComponent as NSString).lastPathComponent
    return "\(target.folder)/projects/\(folder)/\(id).jsonl"
  }

  /// Why the account's file at `dest` rules out a copy of `source`: it holds
  /// another transcript of the conversation.
  private func transcriptConflict(_ source: String, _ dest: String) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dest), !sameFile(source, dest), !fm.contentsEqual(atPath: source, andPath: dest),
      !startsWith(source, dest)
    else { return nil }
    return "the account already holds another transcript of this conversation, at \(dest)"
  }

  /// Copies the conversation's transcript to the account, then switches the
  /// session to it. The old copy stays. A session whose claude never wrote a
  /// transcript has none to copy, and starts its conversation in the account.
  private func move(_ id: String, to target: ClaudeAccount) throws {
    let session = entries[id]!.session
    let from: ClaudeAccount
    switch claudeAccount(of: id) {
    case .local(let account): from = account
    case .codex(let account): throw APIError(Self.codexMoveRefusal(account.name))
    case .host(let host): throw APIError("it runs under the Claude login of \(host)")
    }
    if let name = codexName(target.folder) { throw APIError(Self.codexMoveRefusal(name)) }
    if let source = transcriptFile(session) {
      try copyConversation(source, id: session.claudeSessionId, from: from, to: target)
    }
    try update(id) { $0.claudeConfigDir = target.folder }
    record(id, "account-moved", ["from": .string(from.folder), "to": .string(target.folder)])
  }

  /// Moves a stopped session to its group's account before claude launches.
  /// The caller has checked that no claude runs for the session. A pending
  /// message waits for this launch, so it does not stop the move. The move
  /// fails when the account holds no login, when its last reading found it
  /// signed out, or when the copy fails. The copy fails when the account holds
  /// another transcript of the conversation. After a failure, the session stays
  /// on its account, and an `account-move-skipped` event records why. Its next
  /// launch tries again.
  func moveToGroupAccount(_ id: String) {
    guard let session = entries[id]?.session, let target = accountGroup(of: session)?.account else { return }
    let own = claudeAccount(of: id)
    let from = own.key
    guard from != target else { return }
    let account = ClaudeAccount(folder: target)
    let reason: String?
    if case .codex(let codex) = own {
      reason = Self.codexMoveRefusal(codex.name)
    } else if let name = codexName(target) {
      reason = Self.codexMoveRefusal(name)
    } else if !account.holdsAccount {
      reason = "\(target) holds no Claude account"
    } else if let refusal = Self.signedOutRefusal(usageReader?.latest(target)) {
      reason = refusal
    } else {
      do {
        try move(id, to: account)
        reason = nil
      } catch {
        reason = "\(error)"
      }
    }
    guard let reason else { return }
    logLine("\(id) stays on the account \(from) instead of its group's \(target): \(reason)")
    record(id, "account-move-skipped", ["from": .string(from), "to": .string(target), "reason": .string(reason)])
  }

  /// Puts the transcript at <to>/projects/<same folder>/<id>.jsonl, the
  /// conversation's folder beside it, which holds its subagent transcripts and
  /// tool results, and its file history, which a rewind needs. An account that
  /// shares a folder, such as through a symlink, already holds those files. A
  /// copy of the transcript that is a prefix of the source, left by an earlier
  /// move, is replaced. Another transcript makes this throw, because claude
  /// resumes the one it finds.
  private func copyConversation(_ source: String, id: String, from: ClaudeAccount, to target: ClaudeAccount) throws {
    let fm = FileManager.default
    let dest = transcriptDestination(source, id: id, to: target)
    let dir = (dest as NSString).deletingLastPathComponent
    if let conflict = transcriptConflict(source, dest) { throw APIError(conflict) }
    if !fm.fileExists(atPath: dest) || !fm.contentsEqual(atPath: source, andPath: dest) {
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try replaceFile(dest, with: source)
    }
    let sourceDir = (source as NSString).deletingPathExtension
    try copyMissing(sourceDir, to: (dest as NSString).deletingPathExtension)
    try copyMissing("\(from.folder)/file-history/\(id)", to: "\(target.folder)/file-history/\(id)")
  }

  /// Copies each file under `source` that `dest` lacks. A file at `dest` that
  /// is the first bytes of the one at `source`, left by an earlier move, is
  /// replaced. Any other file at `dest` stays. Nothing happens when `source`
  /// does not exist.
  private func copyMissing(_ source: String, to dest: String) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: source, isDirectory: &isDir) else { return }
    guard !fm.fileExists(atPath: dest) else {
      if isDir.boolValue {
        for name in try fm.contentsOfDirectory(atPath: source) {
          try copyMissing("\(source)/\(name)", to: "\(dest)/\(name)")
        }
      } else if !fm.contentsEqual(atPath: source, andPath: dest), startsWith(source, dest) {
        try replaceFile(dest, with: source)
      }
      return
    }
    try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try fm.copyItem(atPath: source, toPath: dest)
  }

  /// Copies `source` to `dest` through `<dest>.moving`, so `dest` never holds part of a copy. The copy is
  /// checked against `source` and readable only by its owner.
  private func replaceFile(_ dest: String, with source: String) throws {
    let fm = FileManager.default
    let partial = "\(dest).moving"
    try? fm.removeItem(atPath: partial)
    do {
      try fm.copyItem(atPath: source, toPath: partial)
      guard fm.contentsEqual(atPath: source, andPath: partial) else {
        throw APIError("the copy differs from \(source)")
      }
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial)
      if fm.fileExists(atPath: dest) {
        _ = try fm.replaceItemAt(
          URL(fileURLWithPath: dest), withItemAt: URL(fileURLWithPath: partial),
          backupItemName: nil, options: .usingNewMetadataOnly)
      } else {
        try fm.moveItem(atPath: partial, toPath: dest)
      }
    } catch {
      try? fm.removeItem(atPath: partial)
      throw error
    }
  }

  /// Whether the file at `prefix` is the first bytes of the file at `path`.
  private func startsWith(_ path: String, _ prefix: String) -> Bool {
    guard let file = FileHandle(forReadingAtPath: path), let head = FileHandle(forReadingAtPath: prefix) else {
      return false
    }
    defer {
      try? file.close()
      try? head.close()
    }
    while let expected = try? head.read(upToCount: 1 << 20), !expected.isEmpty {
      guard let actual = try? file.read(upToCount: expected.count), actual == expected else { return false }
    }
    return true
  }

  private func sameFile(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).resolvingSymlinksInPath() == URL(fileURLWithPath: b).resolvingSymlinksInPath()
  }
}
