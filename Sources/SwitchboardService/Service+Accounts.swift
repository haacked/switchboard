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
