import Foundation

/// The CLI that an account's sessions run. `--json` output writes it by its raw value.
public enum Agent: String, Codable, Hashable, Sendable, CaseIterable {
  case claude, codex

  /// The agent's name in text for the user, such as `Codex`.
  public var displayName: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }

  /// Whether Switchboard runs sessions on the agent's accounts.
  public var runsSessions: Bool {
    switch self {
    case .claude: true
    case .codex: false
    }
  }

  /// Why no session runs on a Codex account.
  public static let onlyClaudeRunsSessions =
    "Switchboard runs sessions only on Claude accounts until Codex sessions arrive in a later release"
}

/// An account that sessions run under. Each case is one agent's config
/// folder.
public enum Account: Hashable, Sendable {
  case claude(ClaudeAccount)
  case codex(CodexAccount)

  /// The normalized config folder.
  public var folder: String {
    switch self {
    case .claude(let account): account.folder
    case .codex(let account): account.folder
    }
  }

  /// The short name that `--account` and `sb account use` take.
  public var name: String {
    switch self {
    case .claude(let account): account.name
    case .codex(let account): account.name
    }
  }

  public var agent: Agent {
    switch self {
    case .claude: .claude
    case .codex: .codex
    }
  }

  /// The Claude account, or nil when the account runs another agent.
  public var claude: ClaudeAccount? {
    switch self {
    case .claude(let account): account
    case .codex: nil
    }
  }

  /// The Codex account, or nil when the account runs another agent.
  public var codex: CodexAccount? {
    switch self {
    case .claude: nil
    case .codex(let account): account
    }
  }

  /// The short name of a stored folder. It judges the folder by its name alone, because the app and `sb` have
  /// no config to read `codexHomes` from. It matches `name` for every listed account, because no list holds a
  /// `codexHomes` entry named like a Claude folder.
  public static func name(ofFolder folder: String) -> String {
    CodexAccount.isNamedLikeCodex(folder) ? CodexAccount(folder: folder).name : ClaudeAccount(folder: folder).name
  }

  /// The accounts that sbd lists, and a reason for each other folder that a list names or discovery finds. sbd
  /// logs the reasons. `claudeConfigDirs` and `codexHomes` replace discovery of their kind when set. A folder that
  /// `CodexAccount.whyCodex` claims is never a Claude account. A Codex folder that holds a Claude login or is
  /// named like a Claude folder is neither kind.
  public static func survey(
    claudeConfigDirs: [String]?, codexHomes: [String]?, home: String = NSHomeDirectory()
  ) -> (accounts: [Account], refusals: [String]) {
    let found = candidates(claudeConfigDirs: claudeConfigDirs, codexHomes: codexHomes, home: home)
    let claude = found.claude.map { (account: $0, clash: claudeClash($0, codexHomes: codexHomes)) }
    let codex = found.codex.map { (account: $0, clash: $0.clash) }
    var seen = Set<String>()
    let accounts =
      (claude.filter { $0.clash == nil }.map { Account.claude($0.account) }
      + codex.filter { $0.clash == nil }.map { Account.codex($0.account) }).filter { seen.insert($0.folder).inserted }
    return (accounts, claude.compactMap(\.clash) + codex.compactMap(\.clash))
  }

  /// The accounts that `survey` lists.
  public static func listed(
    claudeConfigDirs: [String]?, codexHomes: [String]?, home: String = NSHomeDirectory()
  ) -> [Account] {
    survey(claudeConfigDirs: claudeConfigDirs, codexHomes: codexHomes, home: home).accounts
  }

  /// The folders that the lists name, or else that discovery finds. Discovery lists the home folder once for
  /// both kinds.
  private static func candidates(
    claudeConfigDirs: [String]?, codexHomes: [String]?, home: String
  ) -> (claude: [ClaudeAccount], codex: [CodexAccount]) {
    let names =
      claudeConfigDirs != nil && codexHomes != nil
      ? [] : (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
    return (
      claudeConfigDirs?.map(ClaudeAccount.init(folder:)) ?? ClaudeAccount.discover(names, in: home),
      codexHomes?.map(CodexAccount.init(folder:)) ?? CodexAccount.discover(names, in: home)
    )
  }

  /// Why a Claude folder is no Claude account: `CodexAccount.whyCodex` claims it.
  private static func claudeClash(_ account: ClaudeAccount, codexHomes: [String]?) -> String? {
    CodexAccount.whyCodex(account.folder, codexHomes: codexHomes).map { "\($0), so it is no Claude account" }
  }

  /// The account that `ref` names: a short name, or a folder. It refuses a
  /// name that two known accounts share, so that it never picks one
  /// silently. A folder of a known Codex account is that account. Any other
  /// folder is a Codex account when `CodexAccount.whyCodex` claims it, and a
  /// Claude account when it holds a Claude login, even when a known Claude
  /// account has the folder.
  public static func resolve(_ ref: String, among known: [Account], codexHomes: [String]? = nil) throws -> Account {
    let named = known.filter { $0.name == ref }
    if named.count > 1 {
      let folders = named.map(\.folder).joined(separator: ", ")
      throw APIError("\(ref) names more than one account (\(folders)). Name the account by its folder")
    }
    if let match = named.first { return match }
    let folder = ClaudeAccount.normalize(ref)
    if let match = known.first(where: { $0.codex != nil && $0.folder == folder }) { return match }
    if CodexAccount.whyCodex(folder, codexHomes: codexHomes) != nil {
      let account = CodexAccount(folder: folder)
      if let clash = account.clash { throw APIError(clash) }
      guard isDirectory(folder) else {
        throw APIError("\(ref) is no Codex account (no folder \(folder))")
      }
      return .codex(account)
    }
    let account = ClaudeAccount(folder: folder)
    guard account.holdsAccount else {
      let names = known.map(\.name).joined(separator: ", ")
      throw APIError(
        "\(ref) is no Claude account (no .claude.json in \(account.folder)). Known accounts: \(names)")
    }
    return .claude(account)
  }
}
