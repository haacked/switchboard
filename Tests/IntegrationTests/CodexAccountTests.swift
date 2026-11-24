import Foundation
import SwitchboardCore
import Testing

/// `sb account` and `sb account add` with Codex accounts: discovery by name,
/// the `codexHomes` override, names that keep the agent, the `agent` key, and
/// folder classification (Risk 3).
@Suite(.blocking(timeLimit: .seconds(120))) struct CodexAccountTests {
  /// The fields of an `account-add` request. This is the one place that names them.
  func addRequest(_ name: String, agent: String) -> [String: JSON] {
    ["name": .string(name), "agent": .string(agent)]
  }

  // MARK: Listing

  @Test func listsTheClaudeAndCodexAccountsInTheHomeWithTheirAgent() throws {
    let sbd = try Instance.discovering { home in
      try makeFolder("\(home)/.claude-a", holding: [".claude.json"])
      try makeFolder("\(home)/.codex")
      try makeFolder("\(home)/.codex-work")
    }
    let home = sbd.userHome

    let rows = try sbd.accountRows(env: sbd.userHomeEnvironment)

    #expect(try sbd.row(rows, "\(home)/.claude-a")["name"]?.string == "a")
    #expect(try sbd.row(rows, "\(home)/.claude-a")["agent"]?.string == "claude")
    #expect(try sbd.row(rows, "\(home)/.codex")["name"]?.string == "codex")
    #expect(try sbd.row(rows, "\(home)/.codex")["agent"]?.string == "codex")
    #expect(try sbd.row(rows, "\(home)/.codex-work")["name"]?.string == "codex-work")
    #expect(try sbd.row(rows, "\(home)/.codex-work")["agent"]?.string == "codex")
    #expect(try sbd.row(rows, "\(home)/.claude")["agent"]?.string == "claude")
    #expect(rows.allSatisfy { $0.object?["agent"] != nil }, "\(rows)")
  }

  /// New sessions keep using a Claude account, whatever Codex folders exist.
  @Test func theActiveAccountIsAClaudeAccount() throws {
    let sbd = try Instance.discovering { home in
      try makeFolder("\(home)/.codex")
      try makeFolder("\(home)/.codex-work")
    }

    let active = try sbd.accountRows(env: sbd.userHomeEnvironment).filter { $0["active"]?.bool == true }

    #expect(active.map { $0["agent"]?.string } == ["claude"])
    #expect(active.map { $0["folder"]?.string } == ["\(sbd.userHome)/.claude"])
  }

  /// A Codex folder needs no file to count, because a keyring login leaves none.
  @Test(arguments: [[], ["config.toml"], ["auth.json"]])
  func aCodexFolderIsListedWithOrWithoutItsFiles(_ files: [String]) throws {
    let sbd = try Instance.discovering { home in try makeFolder("\(home)/.codex-x", holding: files) }

    let rows = try sbd.accountRows(env: sbd.userHomeEnvironment)

    #expect(try sbd.row(rows, "\(sbd.userHome)/.codex-x")["agent"]?.string == "codex", "\(files)")
  }

  /// Risk 3: sbd refuses a folder that matches both kinds and never guesses its kind.
  @Test func aCodexFolderThatHoldsAClaudeLoginIsNotListed() throws {
    let sbd = try Instance.discovering { home in
      try makeFolder("\(home)/.codex-x", holding: [".claude.json"])
      try makeFolder("\(home)/.codex-y")
    }

    let rows = try sbd.accountRows(env: sbd.userHomeEnvironment)

    #expect(!rows.contains { $0["folder"]?.string == "\(sbd.userHome)/.codex-x" }, "\(rows)")
    #expect(try sbd.row(rows, "\(sbd.userHome)/.codex-y")["agent"]?.string == "codex")
  }

  @Test func aFolderNamedLikeButNotACodexFolderIsNotListed() throws {
    let sbd = try Instance.discovering { home in
      try makeFolder("\(home)/.codexfoo", holding: ["config.toml"])
      FileManager.default.createFile(atPath: "\(home)/.codex-notes", contents: Data("x".utf8))
    }

    let folders = try sbd.accountRows(env: sbd.userHomeEnvironment).compactMap { $0["folder"]?.string }

    #expect(!folders.contains("\(sbd.userHome)/.codexfoo"))
    #expect(!folders.contains("\(sbd.userHome)/.codex-notes"))
  }

  /// `codexHomes` replaces discovery, as `claudeConfigDirs` does.
  @Test func codexHomesReplacesDiscovery() throws {
    let sbd = try Instance(accounts: ["A"], codexAccounts: ["W"], inheriting: .unset, startingSbd: false)
    try makeFolder("\(sbd.userHome)/.codex-found")
    sbd.sbdEnvironment.merge(sbd.userHomeEnvironment) { $1 }
    try sbd.startSbd()

    let rows = try sbd.accountRows()

    #expect(try sbd.row(rows, sbd.account("W"))["agent"]?.string == "codex")
    #expect(!rows.contains { $0["folder"]?.string == "\(sbd.userHome)/.codex-found" }, "\(rows)")
  }

  /// Risk 3: a `codexHomes` entry that names a Claude folder is not a Codex
  /// account. One entry holds a Claude login, one is named like a Claude
  /// folder, and one is both.
  @Test(arguments: [("cx", [".claude.json"]), (".claude-x", []), (".claude-y", [".claude.json"])])
  func aCodexHomesEntryThatNamesAClaudeFolderIsNotACodexAccount(_ name: String, _ files: [String]) throws {
    let sbd = try Instance(accounts: ["A"], inheriting: .unset, startingSbd: false)
    let folder = try makeFolder(sbd.account(name), holding: files)
    try sbd.set("codexHomes", to: [.string(folder)])
    try sbd.startSbd()

    let rows = try sbd.accountRows()

    #expect(!rows.contains { $0["folder"]?.string == folder && $0["agent"]?.string == "codex" }, "\(rows)")
    #expect(try sbd.row(rows, sbd.account("A"))["agent"]?.string == "claude")
  }

  /// Risk 3: a `claudeConfigDirs` entry that names a Codex folder is not a
  /// Claude account, with or without a Claude login in it.
  @Test(arguments: [[], [".claude.json"]])
  func aClaudeConfigDirsEntryThatNamesACodexFolderIsNotAClaudeAccount(_ files: [String]) throws {
    let sbd = try Instance(accounts: ["A"], inheriting: .unset, startingSbd: false)
    let folder = try makeFolder(sbd.account(".codex-x"), holding: files)
    try sbd.set("claudeConfigDirs", to: [.string(sbd.account("A")), .string(folder)])
    try sbd.startSbd()

    let rows = try sbd.accountRows()

    #expect(!rows.contains { $0["folder"]?.string == folder && $0["agent"]?.string == "claude" }, "\(rows)")
    #expect(try sbd.row(rows, sbd.account("A"))["agent"]?.string == "claude")
  }

  /// A Claude folder named `.claude-codex-work` and a Codex folder named
  /// `.codex-work` both answer to `codex-work`, so that name picks neither.
  @Test func anAmbiguousNameIsRefusedAndEachFolderStillWorks() throws {
    let sbd = try Instance.discovering { home in
      try makeFolder("\(home)/.claude-codex-work", holding: [".claude.json"])
      try makeFolder("\(home)/.codex-work")
    }
    let claudeFolder = "\(sbd.userHome)/.claude-codex-work"
    let before = try sbd.sb(["account", "--json"], env: sbd.userHomeEnvironment)

    let r = try sbd.run(["account", "use", "codex-work"], env: sbd.userHomeEnvironment)

    #expect(r.status != 0, "sb account use codex-work succeeded: \(r.stdout)")
    #expect(r.stderr.contains("codex-work"), "\(r.stderr)")
    #expect(try sbd.sb(["account", "--json"], env: sbd.userHomeEnvironment) == before)
    try sbd.sb(["account", "use", claudeFolder], env: sbd.userHomeEnvironment)
    let active = try sbd.accountRows(env: sbd.userHomeEnvironment).filter { $0["active"]?.bool == true }
    #expect(active.map { $0["folder"]?.string } == [claudeFolder])
  }

  // MARK: sb account add

  @Test func addCreatesACodexFolderAndPrintsItsLoginCommand() throws {
    let sbd = try Instance.discovering()
    let folder = "\(sbd.userHome)/.codex-work"

    let out = try sbd.sb(["account", "add", "work", "--agent", "codex"], env: sbd.userHomeEnvironment)

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue)
    #expect(out.contains("CODEX_HOME="), "\(out)")
    #expect(out.contains("codex login"), "\(out)")
    #expect(out.contains(".codex-work"), "\(out)")
    let rows = try sbd.accountRows(env: sbd.userHomeEnvironment)
    #expect(try sbd.row(rows, folder)["name"]?.string == "codex-work")
    #expect(try sbd.row(rows, folder)["agent"]?.string == "codex")
  }

  /// Login is interactive, so `add` prints the command and never runs it.
  @Test func addNeverRunsTheLogin() throws {
    let sbd = try Instance.discovering()

    try sbd.sb(["account", "add", "work", "--agent", "codex"], env: sbd.userHomeEnvironment)

    let logins = sbd.codexCalls().filter { $0.args.hasPrefix("login") && $0.args != "login status" }
    #expect(logins.isEmpty, "\(logins)")
  }

  @Test func addCreatesAClaudeFolderAndPrintsTheClaudeLoginLine() throws {
    let sbd = try Instance.discovering()
    let folder = "\(sbd.userHome)/.claude-work"

    let out = try sbd.sb(["account", "add", "work", "--agent", "claude"], env: sbd.userHomeEnvironment)

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue)
    #expect(out.contains("CLAUDE_CONFIG_DIR="), "\(out)")
    #expect(out.contains("claude"), "\(out)")
    #expect(out.contains(".claude-work"), "\(out)")
    #expect(!FileManager.default.fileExists(atPath: "\(sbd.userHome)/.codex-work"))
  }

  /// A name becomes part of a folder name in the home. `add` refuses a name
  /// that would escape `~/.codex-<name>` or `~/.claude-<name>`, or that `sb`
  /// could read as a flag, both from the CLI and in the raw request.
  @Test(arguments: ["../x", "a/b", "", "-x", ".", "..", "x/../../y", "/abs"])
  func addRefusesAHostileName(_ name: String) throws {
    let sbd = try Instance.discovering()
    let homeBefore = sbd.tree(sbd.userHome)
    let topBefore = topLevel(sbd.home.path)

    for agent in ["codex", "claude"] {
      let cli = try sbd.run(["account", "add", name, "--agent", agent], env: sbd.userHomeEnvironment)
      #expect(cli.status != 0, "sb account add \(name) --agent \(agent) succeeded: \(cli.stdout)")
      #expect(failure(sbd, "account-add", addRequest(name, agent: agent)) != "no error", "\(name) \(agent)")
    }

    #expect(sbd.tree(sbd.userHome) == homeBefore)
    #expect(topLevel(sbd.home.path) == topBefore)
  }

  /// The names in the folder, without logs, which sb and sbd add as they run.
  /// `x/../../y` would land here.
  func topLevel(_ folder: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasSuffix(".log") }.sorted()
  }

  /// An existing folder may hold a login, so `add` refuses it and leaves its files.
  @Test(arguments: [("codex", ".codex-work", "config.toml"), ("claude", ".claude-work", ".claude.json")])
  func addRefusesAnExistingFolderAndLeavesItsFiles(_ agent: String, _ folderName: String, _ file: String) throws {
    let sbd = try Instance.discovering { home in
      try makeFolder("\(home)/\(folderName)")
      try "keep me".write(toFile: "\(home)/\(folderName)/\(file)", atomically: true, encoding: .utf8)
    }
    let path = "\(sbd.userHome)/\(folderName)/\(file)"

    let r = try sbd.run(["account", "add", "work", "--agent", agent], env: sbd.userHomeEnvironment)

    #expect(r.status != 0, "sb account add work --agent \(agent) succeeded: \(r.stdout)")
    #expect(failure(sbd, "account-add", addRequest("work", agent: agent)) != "no error")
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep me")
    #expect(sbd.tree("\(sbd.userHome)/\(folderName)") == [file])
  }

  /// `~/.claude-codex-work` would share the name `codex-work` with `~/.codex-work`, which picks neither.
  @Test func addRefusesANameThatAnotherAccountHas() throws {
    let sbd = try Instance.discovering { home in try makeFolder("\(home)/.codex-work") }

    let r = try sbd.run(["account", "add", "codex-work", "--agent", "claude"], env: sbd.userHomeEnvironment)

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains(".codex-work"), "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: "\(sbd.userHome)/.claude-codex-work"))
  }

  /// `--agent` is required, and only claude and codex are agents.
  @Test func addNeedsAKnownAgent() throws {
    let sbd = try Instance.discovering()
    let before = sbd.tree(sbd.userHome)

    let missing = try sbd.run(["account", "add", "work"], env: sbd.userHomeEnvironment)
    let unknown = try sbd.run(["account", "add", "work", "--agent", "gemini"], env: sbd.userHomeEnvironment)

    #expect(missing.status != 0, "\(missing.stdout)")
    #expect(unknown.status != 0, "\(unknown.stdout)")
    #expect(failure(sbd, "account-add", ["name": "work"]) != "no error")
    #expect(failure(sbd, "account-add", addRequest("work", agent: "gemini")) != "no error")
    #expect(sbd.tree(sbd.userHome) == before)
  }

  // MARK: Parity for Claude accounts

  /// A Claude row keeps every key it had and gains only `agent`.
  @Test func aClaudeRowGainsOnlyTheAgentKey() throws {
    let sbd = try Instance(accounts: ["A"], codexAccounts: [".codex-work"], inheriting: .unset)
    try sbd.sb("account", "use", "A")

    let a = try sbd.row(try sbd.accountRows(), sbd.account("A"))

    #expect(Set(a.object?.keys.map { $0 } ?? []) == ["name", "folder", "active", "sessions", "agent"])
    #expect(a["name"]?.string == "A")
    #expect(a["active"]?.bool == true)
    #expect(a["sessions"]?.int == 0)
    #expect(a["agent"]?.string == "claude")
  }

  @Test func aCodexRowHasTheSameKeysAsAClaudeRow() throws {
    let sbd = try Instance(accounts: ["A"], codexAccounts: [".codex-work"], inheriting: .unset)
    try sbd.sb("account", "use", "A")

    let row = try sbd.row(try sbd.accountRows(), sbd.account(".codex-work"))

    #expect(Set(row.object?.keys.map { $0 } ?? []) == ["name", "folder", "active", "sessions", "agent"])
    #expect(row["name"]?.string == "codex-work")
    #expect(row["active"]?.bool == false)
    #expect(row["sessions"]?.int == 0)
  }

  /// The text output has an agent column. The folders' names hold no agent
  /// word, so a line names its agent only through that column.
  @Test func theTextOutputNamesEachAccountsAgent() throws {
    let sbd = try Instance(accounts: ["A"], codexAccounts: ["W"], inheriting: .unset)
    try sbd.sb("account", "use", "A")

    let lines = try sbd.sb("account").split(separator: "\n").map(String.init)

    let a = try #require(lines.first { $0.contains(sbd.account("A")) }, "\(lines)")
    let w = try #require(lines.first { $0.contains(sbd.account("W")) }, "\(lines)")
    #expect(a.contains("claude"), "\(a)")
    #expect(!a.contains("codex"), "\(a)")
    #expect(w.contains("codex"), "\(w)")
    #expect(!w.contains("claude"), "\(w)")
    #expect(a.hasPrefix("*"), "\(a)")
    #expect(a.contains("0 sessions"), "\(a)")
    #expect(w.contains("0 sessions"), "\(w)")
  }
}
