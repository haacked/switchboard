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
      do {
        if let reason = moveRefusal(id) { throw APIError(reason) }
        if !dryRun { try move(id, to: target) }
        result.moved.append(id)
      } catch {
        result.blocked.append(.init(session: id, name: session.name, reason: "\(error)"))
      }
    }
    if !dryRun && !result.moved.isEmpty { logLine("moved \(result.moved.count) sessions to the account \(target)") }
    return result
  }

  private func moveRefusal(_ id: String) -> String? {
    guard let e = entries[id] else { return "no session \(id)" }
    if claudeState(id) != .stopped { return "its claude is running. Stop it first" }
    if !e.pending.isEmpty || e.inFlight != nil { return "a message is on its way to it" }
    return nil
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

  /// Puts the transcript at <to>/projects/<same folder>/<id>.jsonl, and the
  /// conversation's file history beside it, which a rewind needs. An account
  /// that shares the folder, such as through a symlink, already holds them. An
  /// account that holds another transcript for the conversation makes this
  /// throw, because claude resumes the one it finds.
  private func copyConversation(_ source: String, id: String, from: String, to target: String) throws {
    let fm = FileManager.default
    let folder = ((source as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let dir = "\(target)/projects/\(folder)"
    let dest = "\(dir)/\(id).jsonl"
    if fm.fileExists(atPath: dest) {
      guard sameFile(source, dest) || fm.contentsEqual(atPath: source, andPath: dest) else {
        throw APIError("the account already holds another transcript of this conversation, at \(dest)")
      }
    } else {
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      let partial = "\(dest).moving"
      try? fm.removeItem(atPath: partial)
      do {
        try fm.copyItem(atPath: source, toPath: partial)
        guard fm.contentsEqual(atPath: source, andPath: partial) else {
          throw APIError("the copy differs from \(source)")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial)
        try fm.moveItem(atPath: partial, toPath: dest)
      } catch {
        try? fm.removeItem(atPath: partial)
        throw error
      }
    }
    let history = "file-history/\(id)"
    if fm.fileExists(atPath: "\(from)/\(history)"), !fm.fileExists(atPath: "\(target)/\(history)") {
      try fm.createDirectory(atPath: "\(target)/file-history", withIntermediateDirectories: true)
      try fm.copyItem(atPath: "\(from)/\(history)", toPath: "\(target)/\(history)")
    }
  }

  private func sameFile(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).resolvingSymlinksInPath() == URL(fileURLWithPath: b).resolvingSymlinksInPath()
  }
}
