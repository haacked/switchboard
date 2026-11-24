import Foundation
import SwitchboardCore
import Testing

/// Helpers for the Codex account tests. They read `--json` output as raw
/// JSON, so a test can tell a missing key from a null one and needs no
/// Swift name for the `agent` and `source` keys.
extension Instance {
  /// A rollout whose last `token_count` reports 12.5% of the 5-hour window
  /// and 34% of the week at 2025-01-02T03:04:05.678Z.
  static let codexRollout = root.appendingPathComponent(
    "Tests/SwitchboardCoreTests/Fixtures/codex/rollout-token-count.jsonl"
  ).path

  /// The time of the fixture rollout's last `token_count`, in ms since the epoch.
  static let codexRolloutAt: Int64 = 1_735_787_045_678

  /// `sb account --json`, one object per account.
  func accountRows(env: [String: String] = [:]) throws -> [JSON] {
    try #require(JSON.parse(try sb(["account", "--json"], env: env))?.array)
  }

  /// `sb usage --json`, which reads every account first, one object per account.
  func usageRows() throws -> [JSON] {
    try #require(JSON.parse(try sb("usage", "--json"))?.array)
  }

  /// The row whose `folder` is the folder.
  func row(_ rows: [JSON], _ folder: String) throws -> JSON {
    try #require(rows.first { $0["folder"]?.string == folder }, "no row for \(folder) in \(rows)")
  }

  /// Copies the fixture rollout into the Codex folder, where Codex keeps a
  /// rollout of 2026-11-20.
  func writeCodexRollout(_ folder: String, text: String? = nil) throws {
    let dir = "\(folder)/sessions/2026/11/20"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let content = try text ?? String(contentsOfFile: Instance.codexRollout, encoding: .utf8)
    try content.write(
      toFile: "\(dir)/rollout-2026-11-20T09-15-02-01941d3a-7c00-7000-8000-000000000001.jsonl", atomically: true,
      encoding: .utf8)
  }

  /// Makes `codex login status` report the Codex folder as signed out.
  func signOutOfCodex(_ folder: String) {
    FileManager.default.createFile(atPath: "\(folder)/stub-signed-out", contents: nil)
  }

  /// One run of the codex stub, as `codex-calls.log` records it.
  typealias CodexCall = (home: String, args: String)

  /// Each run of the codex stub: its CODEX_HOME and its arguments. The runs
  /// in SB_HOME's log come first, oldest first. Then come the runs that each
  /// Codex folder of the config logged, because the stub logs there when it
  /// runs without SB_HOME.
  func codexCalls() -> [CodexCall] {
    let homes = ((try? config())?["codexHomes"]?.array ?? []).compactMap(\.string)
    let logs = ["\(home.path)/codex-calls.log"] + homes.map { "\($0)/stub-codex-calls.log" }
    return logs.flatMap { log in
      let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
      return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map { record in
        let fields = record.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (home: fields[0], args: fields.count > 1 ? fields[1] : "")
      }
    }
  }

  /// Makes the Claude account `name`, which `init` created, a Codex account,
  /// as when the user renames or reconfigures a folder that sessions,
  /// follow-ups, or groups already store. It stops sbd, removes the folder's
  /// .claude.json, moves the folder from `claudeConfigDirs` to `codexHomes`,
  /// applies `settings`, and starts sbd again.
  func makeCodex(_ name: String, settings: [String: JSON] = [:]) throws {
    let folder = account(name)
    stopSbd()
    try? FileManager.default.removeItem(atPath: "\(folder)/.claude.json")
    var config = try config()
    config["claudeConfigDirs"] = .array((config["claudeConfigDirs"]?.array ?? []).filter { $0.string != folder })
    config["codexHomes"] = .array((config["codexHomes"]?.array ?? []) + [.string(folder)])
    config.merge(settings) { $1 }
    try JSON.object(config).text.write(toFile: home.config, atomically: true, encoding: .utf8)
    try startSbd()
  }

  /// The CLAUDE_CONFIG_DIR of each `claude -p` run of the stub, oldest
  /// first. An unset variable reads as empty.
  func headlessAccounts() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/headless-accounts.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
  }

  /// Every path under the folder, relative to it, sorted, without the codex
  /// stub's own files, whose names start with `stub-`. A missing folder has none.
  func tree(_ folder: String) -> [String] {
    let paths = FileManager.default.enumerator(atPath: folder)?.compactMap { $0 as? String } ?? []
    return paths.filter { !($0 as NSString).lastPathComponent.hasPrefix("stub-") }.sorted()
  }

  /// The property that every Risk 1 guard keeps: no run of the claude stub
  /// had CLAUDE_CONFIG_DIR set to one of the Codex folders, and no Codex
  /// folder holds a .claude.json or a projects folder that wasn't there
  /// before. `since` skips the first runs in stub-calls.log, and
  /// `headlessSince` the first runs in headless-accounts.log, which ran while
  /// a folder that `makeCodex` changed was still a Claude account.
  func expectClaudeNeverRan(
    in codexFolders: [String], since: Int = 0, headlessSince: Int = 0, before: [String: [String]] = [:],
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let runs = stubCalls().dropFirst(since).filter { codexFolders.contains($0.account) }
    #expect(runs.isEmpty, "claude ran under a Codex account: \(runs.map(\.args))", sourceLocation: sourceLocation)
    let headless = headlessAccounts().dropFirst(headlessSince).filter { codexFolders.contains($0) }
    #expect(headless.isEmpty, "claude -p ran under a Codex account: \(headless)", sourceLocation: sourceLocation)
    for folder in codexFolders {
      let added = Set(tree(folder)).subtracting(before[folder] ?? [])
      let claudeFiles = added.filter { $0 == ".claude.json" || $0 == "projects" || $0.hasPrefix("projects/") }
      #expect(claudeFiles.isEmpty, "Claude files in \(folder): \(claudeFiles)", sourceLocation: sourceLocation)
    }
  }

  /// A private sbd that finds its accounts in a home of its own, as a user's
  /// sbd does, instead of from `claudeConfigDirs` and `codexHomes`. `prepare`
  /// fills that home before sbd starts. sbd and each `sb` run get it as HOME
  /// and as CFFIXED_USER_HOME, because Foundation expands `~` with the second.
  /// The home is a folder in the instance's SB_HOME, so the test never reads
  /// the user's ~/.claude* or ~/.codex*.
  static func discovering(_ prepare: (String) throws -> Void = { _ in }) throws -> Instance {
    let sbd = try Instance(
      inheriting: .unset, config: ["claudeConfigDirs": .null, "codexHomes": .null], startingSbd: false)
    try FileManager.default.createDirectory(atPath: sbd.userHome, withIntermediateDirectories: true)
    try prepare(sbd.userHome)
    sbd.sbdEnvironment.merge(sbd.userHomeEnvironment) { $1 }
    try sbd.startSbd()
    return sbd
  }

  /// The home that `discovering` gives sbd.
  var userHome: String { "\(home.path)/u" }

  var userHomeEnvironment: [String: String] { ["HOME": userHome, "CFFIXED_USER_HOME": userHome] }
}

/// Makes a folder in a home, with an empty JSON object in each of `files`.
@discardableResult
func makeFolder(_ path: String, holding files: [String] = []) throws -> String {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  for file in files { FileManager.default.createFile(atPath: "\(path)/\(file)", contents: Data("{}".utf8)) }
  return path
}
