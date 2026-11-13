import Foundation
import SwitchboardCore
import Testing

/// sbd pins the auto-memory of every local session to one folder per repo,
/// through `autoMemoryDirectory` in the settings file that it writes at each
/// launch, until a SessionStart shows that Claude's folder names disagree
/// with `ClaudeFolder.name`.
@Suite(.blocking(timeLimit: .seconds(120))) struct MemoryPinTests {
  let key = "autoMemoryDirectory"

  func pinned(_ base: String) -> String { ClaudeFolder.memoryDirectory(base) }

  func instance() throws -> Instance {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    return sbd
  }

  /// A session in `path` that answered one prompt.
  func start(_ sbd: Instance, in path: String, account: String? = nil) throws -> SessionSummary {
    let extra = account.map { ["--account", $0] } ?? []
    let s = try JSONCoding.decode(
      SessionSummary.self, from: try sbd.sb(["new", "--json"] + extra + ["--prompt", "hello", path]))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    return s
  }

  func settings(_ sbd: Instance, _ s: SessionSummary) throws -> [String: JSON] {
    let text = try String(contentsOfFile: sbd.home.claudeSettings(s.id), encoding: .utf8)
    return try #require(JSON.parse(text)?.object)
  }

  func memory(_ sbd: Instance, _ s: SessionSummary) throws -> String? {
    try settings(sbd, s)[key]?.string
  }

  /// Stops the session and sends it a message, which launches its claude again, and waits for that launch. sbd
  /// writes the settings file before the launch.
  func stopAndRelaunch(_ sbd: Instance, _ s: SessionSummary) throws {
    let launches = { sbd.stubCalls().filter { $0.args.contains(s.claudeSessionId) }.count }
    let before = launches()
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
    try sbd.sb("send", s.id, "again")
    try sbd.waitFor("the relaunch of \(s.id)") { launches() > before }
  }

  // MARK: Where the folder is

  @Test func aSessionInALinkedWorktreeGetsTheMainCheckoutsMemoryFolder() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let tree = try sbd.addWorktree(repo, "feature")

    let s = try start(sbd, in: tree)

    #expect(try memory(sbd, s) == pinned(real(repo)))
  }

  @Test func sessionsOfOneRepoOnDifferentAccountsGetTheSameFolder() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let tree = try sbd.addWorktree(repo, "feature")

    let onA = try start(sbd, in: repo, account: "A")
    let onB = try start(sbd, in: tree, account: "B")

    #expect(try memory(sbd, onA) == pinned(real(repo)))
    #expect(try memory(sbd, onB) == pinned(real(repo)))
  }

  @Test func theDefaultAccountGetsTheSameFolderAsAnotherAccount() throws {
    let sbd = try Instance(accounts: ["A"], inheriting: .unset)
    let repo = try sbd.makeRepo()
    try sbd.sb("account", "use", ClaudeAccount.defaultFolder)
    let onDefault = try start(sbd, in: repo)
    try sbd.sb("account", "use", "A")

    let onA = try start(sbd, in: repo, account: "A")

    #expect(try memory(sbd, onDefault) == pinned(real(repo)))
    #expect(try memory(sbd, onA) == pinned(real(repo)))
  }

  @Test func aSessionOutsideAnyGitRepoGetsTheFolderNamedAfterItsCwdsRealPath() throws {
    let sbd = try instance()

    let s = try start(sbd, in: sbd.work)

    #expect(try memory(sbd, s) == pinned(real(s.cwd)))
  }

  @Test func aLongRepoPathGetsClaudesCutAndHashedName() throws {
    let sbd = try instance()
    let parts = (1...3).map { String(repeating: String($0), count: 90) }
    let repo = try Repos.create(([sbd.home.path] + parts).joined(separator: "/"))
    let resolved = real(repo)
    try #require(resolved.utf16.count > 200)

    let s = try start(sbd, in: repo)

    #expect(try memory(sbd, s) == pinned(resolved))
    try stopAndRelaunch(sbd, s)
    #expect(try memory(sbd, s) == pinned(resolved))
  }

  @Test func aSessionInAWorktreeOfABareRepoGetsNoMemoryFolder() throws {
    let sbd = try instance()
    let bare = "\(sbd.home.path)/bare.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", bare)
    let seed = try sbd.makeRepo("seed")
    try sbd.git(seed, "push", "-q", bare, "main")
    let tree = "\(sbd.home.path)/trees/bare/main"
    try sbd.git(bare, "worktree", "add", "-q", tree, "main")

    let s = try start(sbd, in: tree)

    #expect(try memory(sbd, s) == nil)
    #expect(try settings(sbd, s)["hooks"]?.object?.isEmpty == false)
  }

  // MARK: Later launches

  @Test func movingAStoppedSessionToAnotherAccountKeepsTheSettingAtItsNextLaunch() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let tree = try sbd.addWorktree(repo, "feature")
    let s = try start(sbd, in: tree, account: "A")
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }

    try sbd.sb("account", "move", "--json", "B")
    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the reply after the move") { $0.lastReply == "Done: again" }

    #expect(try memory(sbd, s) == pinned(real(repo)))
  }

  // MARK: The guard

  /// Sends a SessionStart for `s` whose transcript sits in a folder that `ClaudeFolder.name` doesn't give
  /// for the session's cwd, and waits until sbd has recorded it.
  func sendMisplacedStart(_ sbd: Instance, _ s: SessionSummary, source: String) throws {
    let elsewhere = "\(sbd.account("A"))/projects/-not-the-folder-claude-names/\(s.claudeSessionId).jsonl"
    let marker = "misplaced-\(source)"
    let payload = JSON.object([
      "hook_event_name": "SessionStart", "session_id": .string(s.claudeSessionId), "source": .string(source),
      "permission_mode": "default", "probe": .string(marker), "transcript_path": .string(elsewhere),
      "cwd": .string(s.cwd),
    ])
    let answer = try sbd.sendLine(
      Instance.hookLine(session: .string(s.id), payload: payload, id: Instance.eventId(ns: Instance.clockNs())),
      to: sbd.home.socket)
    try #require(answer?["ok"] == true, "\(answer?.text ?? "no answer")")
    try sbd.waitFor("the SessionStart event") { try !sbd.probes(marker).isEmpty }
  }

  @Test(arguments: ["startup", "clear"])
  func aNewConversationInAnotherFolderStopsTheSettingAtLaterLaunches(source: String) throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let s = try start(sbd, in: repo)
    try #require(try memory(sbd, s) != nil)

    try sendMisplacedStart(sbd, s, source: source)
    try stopAndRelaunch(sbd, s)

    let after = try settings(sbd, s)
    #expect(after[key] == nil)
    #expect(after["hooks"]?.object?.isEmpty == false)
  }

  @Test func aResumedConversationInAnotherFolderKeepsTheSetting() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let s = try start(sbd, in: repo)

    try sendMisplacedStart(sbd, s, source: "resume")
    try stopAndRelaunch(sbd, s)

    #expect(try memory(sbd, s) == pinned(real(repo)))
  }

  @Test func theGuardStopsTheSettingForOtherSessionsToo() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let tripped = try start(sbd, in: repo)
    let other = try start(sbd, in: repo, account: "B")

    try sendMisplacedStart(sbd, tripped, source: "startup")
    try stopAndRelaunch(sbd, other)

    #expect(try memory(sbd, other) == nil)
  }

  // MARK: Remote sessions

  @Test func aRemoteSessionLaunchNamesTheHostsSettingsFileWhichHasNoMemoryDirectory() throws {
    let sbd = try Instance.remote()

    let s = try sbd.startOnHost()

    let args = try #require(sbd.boxStubArgs().first { $0.contains(s.claudeSessionId) }).split(separator: " ").map(
      String.init)
    let file = try #require(args.firstIndex(of: "--settings").map { args[$0 + 1] }, "\(args)")
    #expect(real(file) == real(sbd.boxSettings))
    #expect(!args.contains { $0.contains(key) })
    #expect(try !String(contentsOfFile: sbd.boxSettings, encoding: .utf8).contains(key))
  }
}
