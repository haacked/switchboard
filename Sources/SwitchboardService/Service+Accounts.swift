import Foundation
import SwitchboardCore

/// Which Claude account each session runs under. A session records its
/// account when sbd creates or imports it, and keeps it, because the
/// conversation's transcript lives in the account's folder.
extension Service {
  /// The account that a new session without a parent uses: the one that
  /// `sb account use` chose, else CLAUDE_CONFIG_DIR from config.env or from
  /// sbd's environment, else Claude's default account.
  var activeAccount: String {
    let configured = config.env["CLAUDE_CONFIG_DIR"] ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    return ClaudeAccount.normalize(chosenAccount ?? configured ?? ClaudeAccount.defaultFolder)
  }

  /// Reads the account that `sb account use` chose. A folder that no longer
  /// holds an account is ignored, so a removed account doesn't stop sessions
  /// from starting.
  func loadChosenAccount() {
    guard let text = try? String(contentsOfFile: home.activeAccount, encoding: .utf8) else { return }
    let folder = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if ClaudeAccount.holdsAccount(folder) {
      chosenAccount = ClaudeAccount.normalize(folder)
    } else {
      logLine("ignoring the chosen account \(folder): it holds no Claude account")
    }
  }

  func resolveAccount(_ ref: String) throws -> String {
    try ClaudeAccount.resolve(ref, among: accounts)
  }

  /// The account of a new session: the one named, else its parent's, else the
  /// active one.
  func accountForNew(named ref: String?, parent: String?) throws -> String {
    if let ref, !ref.isEmpty { return try resolveAccount(ref) }
    if let parent, entries[parent] != nil { return claudeAccount(of: parent) }
    return activeAccount
  }

  func accountList() -> [AccountInfo] {
    let active = activeAccount
    var folders = accounts
    if !folders.contains(active) { folders.insert(active, at: 0) }
    let counts = Dictionary(grouping: entries.keys.filter { !entries[$0]!.session.waitsToStart }) {
      claudeAccount(of: $0)
    }
    return folders.map {
      AccountInfo(name: ClaudeAccount.name($0), folder: $0, active: $0 == active, sessions: counts[$0]?.count ?? 0)
    }
  }

  func accountRequest(_ op: String, _ args: JSON) throws -> JSON {
    if op == "account-move" { return try JSON(encoding: moveSessions(args)) }
    if op == "account-use" {
      guard let ref = args["account"]?.string, !ref.isEmpty else { throw APIError("name an account") }
      let folder = try resolveAccount(ref)
      try folder.write(toFile: home.activeAccount, atomically: true, encoding: .utf8)
      chosenAccount = folder
      logLine("new sessions use the account \(folder)")
    }
    return try JSON(encoding: accountList())
  }
}

// MARK: Moving sessions

extension Service {
  /// Moves every session that is not on the account to it, or with `dryRun`
  /// lists the ones that would move. Only a session whose claude is stopped
  /// moves: a claude that runs, or a message on its way, keeps writing the
  /// old account's transcript, and a second claude that resumes the
  /// conversation forks it.
  func moveSessions(_ args: JSON) throws -> AccountMove {
    guard let ref = args["account"]?.string, !ref.isEmpty else { throw APIError("name an account") }
    let target = try resolveAccount(ref)
    let dryRun = args["dryRun"]?.bool ?? false
    var result = AccountMove(account: target)
    for id in entries.keys.sorted() {
      guard let session = entries[id]?.session, !session.cwd.isEmpty, claudeAccount(of: id) != target else { continue }
      if let reason = moveRefusal(id, to: target) {
        result.blocked.append(.init(session: id, name: session.name, reason: reason))
        continue
      }
      do {
        if !dryRun { try move(id, to: target) }
        result.moved.append(id)
      } catch {
        result.blocked.append(.init(session: id, name: session.name, reason: "\(error)"))
      }
    }
    if !dryRun && !result.moved.isEmpty { logLine("moved \(result.moved.count) sessions to the account \(target)") }
    return result
  }

  /// Why the session cannot move now, so that `dryRun` lists the same
  /// sessions as a move.
  private func moveRefusal(_ id: String, to target: String) -> String? {
    guard let e = entries[id] else { return "no session \(id)" }
    if starting.contains(id) { return "it is starting" }
    if claudeState(id) != .stopped { return "its claude is running. Stop it first" }
    if !e.pending.isEmpty || e.inFlight != nil { return "a message is on its way to it" }
    if let source = transcriptFile(e.session) {
      let dest = transcriptDestination(source, id: e.session.claudeSessionId, to: target)
      if let conflict = transcriptConflict(source, dest) { return conflict }
    }
    return nil
  }

  private func transcriptDestination(_ source: String, id: String, to target: String) -> String {
    let folder = ((source as NSString).deletingLastPathComponent as NSString).lastPathComponent
    return "\(target)/projects/\(folder)/\(id).jsonl"
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
  private func move(_ id: String, to target: String) throws {
    let session = entries[id]!.session
    let from = claudeAccount(of: id)
    if let source = transcriptFile(session) {
      try copyConversation(source, id: session.claudeSessionId, from: from, to: target)
    }
    try update(id) { $0.claudeConfigDir = target }
    record(id, "account-moved", ["from": .string(from), "to": .string(target)])
  }

  /// Puts the transcript at <to>/projects/<same folder>/<id>.jsonl, the
  /// conversation's folder beside it, which holds its subagent transcripts and
  /// tool results, and its file history, which a rewind needs. An account that
  /// shares a folder, such as through a symlink, already holds those files. A
  /// copy of the transcript that is a prefix of the source, left by an earlier
  /// move, is replaced. Another transcript makes this throw, because claude
  /// resumes the one it finds.
  private func copyConversation(_ source: String, id: String, from: String, to target: String) throws {
    let fm = FileManager.default
    let dest = transcriptDestination(source, id: id, to: target)
    let dir = (dest as NSString).deletingLastPathComponent
    if let conflict = transcriptConflict(source, dest) { throw APIError(conflict) }
    if !fm.fileExists(atPath: dest) || !fm.contentsEqual(atPath: source, andPath: dest) {
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      let partial = "\(dest).moving"
      try? fm.removeItem(atPath: partial)
      do {
        try fm.copyItem(atPath: source, toPath: partial)
        guard fm.contentsEqual(atPath: source, andPath: partial) else {
          throw APIError("the copy differs from \(source)")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial)
        if fm.fileExists(atPath: dest) {
          _ = try fm.replaceItemAt(URL(fileURLWithPath: dest), withItemAt: URL(fileURLWithPath: partial))
        } else {
          try fm.moveItem(atPath: partial, toPath: dest)
        }
      } catch {
        try? fm.removeItem(atPath: partial)
        throw error
      }
    }
    let sourceDir = (source as NSString).deletingPathExtension
    try copyMissing(sourceDir, to: (dest as NSString).deletingPathExtension)
    try copyMissing("\(from)/file-history/\(id)", to: "\(target)/file-history/\(id)")
  }

  /// Copies each file under `source` that `dest` lacks. Nothing happens when
  /// `source` does not exist.
  private func copyMissing(_ source: String, to dest: String) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: source, isDirectory: &isDir) else { return }
    guard !fm.fileExists(atPath: dest) else {
      guard isDir.boolValue else { return }
      for name in try fm.contentsOfDirectory(atPath: source) {
        try copyMissing("\(source)/\(name)", to: "\(dest)/\(name)")
      }
      return
    }
    try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try fm.copyItem(atPath: source, toPath: dest)
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
