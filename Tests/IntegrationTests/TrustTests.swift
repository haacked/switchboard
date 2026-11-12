import Foundation
import SwitchboardCore
import Testing

/// The entry that Claude Code 2.1.322's trust dialog writes for a folder that has none.
private let claudesDefaultEntry: [String: Any] = [
  "allowedTools": [Any](), "mcpContextUris": [Any](), "mcpServers": [String: Any](),
  "enabledMcpjsonServers": [Any](), "disabledMcpjsonServers": [Any](), "hasTrustDialogAccepted": true,
  "hasClaudeMdExternalIncludesApproved": false, "hasClaudeMdExternalIncludesWarningShown": false,
]

/// The parsed JSON as text with sorted keys, so that key order does not
/// count and a boolean never equals a number.
private func canonicalJSON(_ value: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

/// Claude Code's workspace trust dialog, as the stub draws it while
/// `$SB_HOME/ask-trust` exists. sbd trusts the folders that it creates for a
/// chat and the Manager before it launches claude. In any other folder, the
/// dialog opens a trust card, which Trust and Exit answer by typing.
///
/// Every test runs its sessions under the named accounts A and B, so sbd
/// never writes the user's ~/.claude.json.
@Suite(.blocking(timeLimit: .seconds(120))) struct TrustTests {
  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// A `.claude.json` with a login, numbers that the repo's `JSON` would
  /// change, non-ASCII text, and another project.
  static func seed(_ account: String) -> String {
    """
    {
      "oauthAccount": {"accountUuid": "acct-\(account)", "emailAddress": "\(account.lowercased())@example.com"},
      "numStartups": 9007199254740993,
      "tipsRatio": 0.1,
      "hasCompletedOnboarding": true,
      "name": "é",
      "projects": {"/Users/me/elsewhere": {"allowedTools": ["Bash(ls)"], "hasTrustDialogAccepted": true}}
    }
    """
  }

  /// A sbd with accounts A and B, each with a seeded `.claude.json`, A
  /// active, and the stub's trust dialog on. Nothing launches before the seed.
  func instance(idleStopSeconds: Int = 600, config extra: [String: JSON] = [:]) throws -> Instance {
    let sbd = try Instance(idleStopSeconds: idleStopSeconds, accounts: ["A", "B"], inheriting: .unset, config: extra)
    for account in ["A", "B"] {
      try Self.seed(account).write(toFile: configFile(sbd, account), atomically: true, encoding: .utf8)
    }
    try sbd.sb("account", "use", "A")
    FileManager.default.createFile(atPath: "\(sbd.home.path)/ask-trust", contents: nil)
    return sbd
  }

  func configFile(_ sbd: Instance, _ account: String) -> String { "\(sbd.account(account))/.claude.json" }

  func parsedConfig(_ sbd: Instance, _ account: String) throws -> [String: Any] {
    let data = try #require(FileManager.default.contents(atPath: configFile(sbd, account)))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// The seed of the account with Claude Code's default entry for each key.
  func seedPlus(_ account: String, keys: [String]) throws -> String {
    var root = try #require(
      try JSONSerialization.jsonObject(with: Data(Self.seed(account).utf8)) as? [String: Any])
    var projects = try #require(root["projects"] as? [String: Any])
    for key in keys { projects[key] = claudesDefaultEntry }
    root["projects"] = projects
    return try canonicalJSON(root)
  }

  /// The account's file as sorted JSON, so that key order does not count.
  func canonicalConfig(_ sbd: Instance, _ account: String) throws -> String {
    try canonicalJSON(try parsedConfig(sbd, account))
  }

  func addGroup(_ sbd: Instance, _ name: String = "Flags") throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb("group", "add", "--json", name))
  }

  func chatFolder(_ sbd: Instance, _ group: GroupSummary) -> String { "\(sbd.home.path)/chats/\(group.id)" }

  /// Sends a turn to the group's chat and returns sbd's JSON reply.
  func sendToChat(_ sbd: Instance, _ group: GroupSummary, _ text: String) throws -> JSON {
    try decode(JSON.self, sbd.sb("chat", group.id, "--send", text, "--json"))
  }

  func newWork(_ sbd: Instance, in folder: String? = nil, prompt: String = "hello") throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb("new", "--json", "--prompt", prompt, folder ?? sbd.work))
  }

  func events(_ sbd: Instance, _ id: String, _ kind: String) throws -> [Event] {
    try sbd.events(id).filter { $0.kind == kind }
  }

  /// The prompts that claude reported, oldest first.
  func prompts(_ sbd: Instance, _ id: String) throws -> [String] {
    try events(sbd, id, "UserPromptSubmit").compactMap { $0.data["prompt"]?.string }
  }

  /// Whether the session's pane shows the stub's trust dialog.
  func showsTheDialog(_ sbd: Instance, _ id: String) -> Bool {
    ((try? sbd.screen(id)) ?? "").contains("Accessing workspace:")
  }

  /// Waits for the session's one trust card and returns it.
  @discardableResult
  func waitForTrustCard(_ sbd: Instance, _ id: String) throws -> Card {
    let s = try sbd.waitFor(id, "the trust card") { $0.cards.contains { $0.kind == .trust } }
    return try #require(s.cards.first { $0.kind == .trust })
  }

  func answer(_ sbd: Instance, _ verb: String, _ id: String) throws -> JSON? {
    try JSON.parse(sbd.sb(verb, "--json", id))
  }

  // MARK: Stage 1: sbd trusts its own folders

  @Test func aChatStartsWithoutTheTrustDialog() throws {
    let sbd = try instance()
    let flags = try addGroup(sbd)

    let reply = try sendToChat(sbd, flags, "hi")
    // The chat request creates the folder, which realpath needs.
    let key = real(chatFolder(sbd, flags))

    #expect(reply["delivery"]?.string == "resumed")
    let id = try #require(reply["id"]?.string)
    try sbd.waitFor(id, "the reply to hi") { $0.lastReply == "Done: hi" }
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: [key]))
    #expect(try canonicalConfig(sbd, "B") == seedPlus("B", keys: []))
    let trusted = try events(sbd, id, "folder-trusted")
    #expect(trusted.count == 1)
    #expect(trusted.first?.data["key"]?.string == key)
    #expect(
      trusted.first?.data["account"]?.string.map(ClaudeAccount.normalize) == ClaudeAccount.normalize(sbd.account("A")))
    #expect(try sbd.get(id).cards.isEmpty)

    try sbd.sb("stop", id)
    try sbd.waitFor(id, "the stop") { $0.claudePid == nil }
    _ = try sendToChat(sbd, flags, "again")
    try sbd.waitFor(id, "the reply to again") { $0.lastReply == "Done: again" }

    #expect(try events(sbd, id, "folder-trusted").count == 1)
    #expect(try prompts(sbd, id) == ["hi", "again"])
  }

  @Test func aGroupsChatIsTrustedInTheGroupsAccount() throws {
    let sbd = try instance()
    let flags = try addGroup(sbd)
    try sbd.sb("group", "account", "--json", flags.id, "B")

    let id = try #require(try sendToChat(sbd, flags, "hi")["id"]?.string)
    let key = real(chatFolder(sbd, flags))

    try sbd.waitFor(id, "the reply to hi") { $0.lastReply == "Done: hi" }
    #expect(try canonicalConfig(sbd, "B") == seedPlus("B", keys: [key]))
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: []))
    #expect(
      try events(sbd, id, "folder-trusted").first?.data["account"]?.string.map(ClaudeAccount.normalize)
        == ClaudeAccount.normalize(sbd.account("B")))
  }

  @Test func theManagerStartsWithoutTheTrustDialog() throws {
    let sbd = try instance()

    let m = try decode(SessionSummary.self, sbd.sb("manager", "--json"))

    let live = try sbd.waitFor(m.id, "the Manager's claude") { $0.live }
    #expect(!live.cards.contains { $0.kind == .trust })
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: [real(sbd.home.managerFolder)]))
    #expect(try events(sbd, m.id, "folder-trusted").count == 1)
  }

  /// The stub's dialog shows in a work session's folder, which also shows
  /// that the dialog is on for the chat and Manager tests.
  @Test func aWorkSessionGetsNoWrite() throws {
    let sbd = try instance()

    let s = try newWork(sbd)

    try sbd.waitFor("the stub's trust dialog") { showsTheDialog(sbd, s.id) }
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: []))
    #expect(try events(sbd, s.id, "folder-trusted").isEmpty)
    #expect(try sbd.get(s.id).lastReply == nil)
  }

  /// A work session in a folder where sbd keeps a chat is still a user's
  /// folder. The folder exists before any chat could trust it.
  @Test func aWorkSessionInAChatsFolderGetsNoWrite() throws {
    let sbd = try instance()
    let folder = "\(sbd.home.path)/chats/zzzzzz"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

    let s = try newWork(sbd, in: folder)

    try sbd.waitFor("the stub's trust dialog") { showsTheDialog(sbd, s.id) }
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: []))
    #expect(try events(sbd, s.id, "folder-trusted").isEmpty)
  }

  /// A work session in the Manager's folder is still a user's folder.
  @Test func aWorkSessionInTheManagersFolderGetsNoWrite() throws {
    let sbd = try instance()
    try FileManager.default.createDirectory(atPath: sbd.home.managerFolder, withIntermediateDirectories: true)

    let s = try newWork(sbd, in: sbd.home.managerFolder)

    try sbd.waitFor("the stub's trust dialog") { showsTheDialog(sbd, s.id) }
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: []))
    #expect(try events(sbd, s.id, "folder-trusted").isEmpty)
  }

  /// An account folder without a `.claude.json` holds no login. sbd creates
  /// no file there, and the chat waits at the dialog for Stage 2's card.
  @Test func anAccountWithoutAConfigFileGetsNoFile() throws {
    let sbd = try Instance()
    let account = try #require(sbd.inheritedAccount)
    try #require(!ClaudeAccount.isDefault(account))
    FileManager.default.createFile(atPath: "\(sbd.home.path)/ask-trust", contents: nil)
    let flags = try addGroup(sbd)

    let c = try decode(SessionSummary.self, sbd.sb("chat", flags.id, "--json"))

    try #require(c.account.map(ClaudeAccount.normalize) == ClaudeAccount.normalize(account))
    try sbd.waitFor("the stub's trust dialog") { showsTheDialog(sbd, c.id) }
    try sbd.waitFor("sbd to log the skipped write") {
      let log = (try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? ""
      return log.split(separator: "\n").contains { $0.contains(c.cwd) && $0.contains("trust") }
    }
    #expect(!FileManager.default.fileExists(atPath: "\(account)/.claude.json"))
    #expect(!FileManager.default.fileExists(atPath: "\(account)/.claude.json.lock"))
    #expect(try events(sbd, c.id, "folder-trusted").isEmpty)
  }

  // MARK: Stage 2: the trust card

  @Test func aWorkSessionAtTheTrustDialogShowsATrustCard() throws {
    let sbd = try instance()

    let s = try newWork(sbd)

    try waitForTrustCard(sbd, s.id)
    let got = try decode(SessionSummary.self, sbd.sb("get", "--json", s.id))
    #expect(got.state == .needsYou)
    #expect(got.reason.hasPrefix("trust the folder"))
    let cards = try sbd.cards().filter { $0.session == s.id }
    #expect(cards.count == 1)
    #expect(cards.first?.kind == .trust)
    #expect(cards.first?.cwd == real(sbd.work))
    #expect(cards.first?.input == ["prompt": "hello"])
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: []))
  }

  /// Path (a): Trust starts claude, which reads the launch prompt as its
  /// argument and then gets the message that waited.
  @Test func trustDeliversTheLaunchPromptThenAQueuedMessage() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    try waitForTrustCard(sbd, s.id)

    let sent = try JSON.parse(sbd.sb("send", "--json", s.id, "second"))
    #expect(sent?["delivery"]?.string == "queued")
    let answer = try answer(sbd, "allow", s.id)

    #expect(answer?["delivery"]?.string == "terminal")
    try sbd.waitFor(s.id, "the reply to second") { $0.lastReply == "Done: second" }
    sleep(2)
    #expect(try prompts(sbd, s.id) == ["hello", "second"])
    #expect(try sbd.get(s.id).cards.isEmpty)
    #expect(try events(sbd, s.id, "trust_closed").isEmpty)
    // The stub writes no trust, and sbd writes none for a work session.
    #expect(try canonicalConfig(sbd, "A") == seedPlus("A", keys: []))
  }

  /// Paths (b) and (d): Exit keeps the prompt, and a restart of sbd keeps
  /// it at the front of the queue until the next launch's Trust.
  @Test func exitKeepsTheMessageForTheNextStart() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    try waitForTrustCard(sbd, s.id)

    let answer = try answer(sbd, "deny", s.id)

    #expect(answer?["delivery"]?.string == "terminal")
    let exited = try sbd.waitFor(s.id, "claude to exit") { $0.claudePid == nil }
    let mark = try #require(try sbd.events(s.id).last?.id)
    let closed = try events(sbd, s.id, "trust_closed")
    #expect(closed.count == 1)
    #expect(closed.first?.data["prompt"]?.string == "hello")
    let reason = try sbd.waitFor(s.id, "the exit's reason") {
      $0.reason.hasPrefix("claude exited at the folder trust prompt")
    }
    #expect(reason.state == .needsYou)
    #expect(exited.cards.isEmpty)
    sleep(6)
    #expect(try sbd.events(s.id, after: mark).filter { ["started", "resumed"].contains($0.kind) }.isEmpty)

    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try sbd.get(s.id).reason.hasPrefix("claude exited at the folder trust prompt"))
    try sbd.sb("open", s.id)
    try waitForTrustCard(sbd, s.id)
    _ = try self.answer(sbd, "allow", s.id)

    try sbd.waitFor(s.id, "the kept prompt's reply") { $0.lastReply == "Done: hello" }
    sleep(2)
    #expect(try prompts(sbd, s.id) == ["hello"])
    #expect(try events(sbd, s.id, "trust_closed").count == 1)
  }

  /// Path (c): Enter on the dialog's default item, No, exits claude in the
  /// terminal. The tick finds the dead pane with the card open.
  @Test func exitTypedInTheTerminalKeepsTheMessage() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    try waitForTrustCard(sbd, s.id)
    try #require(try sbd.highlighted(s.id) == "No, exit")

    try sbd.press(s.id, "Enter")

    try sbd.waitFor(s.id, "claude to exit") { $0.claudePid == nil }
    let closed = try sbd.waitFor("the trust_closed event", fetch: { try events(sbd, s.id, "trust_closed") }) {
      !$0.isEmpty
    }
    #expect(closed.count == 1)
    #expect(closed.first?.data["prompt"]?.string == "hello")
    #expect(try sbd.get(s.id).reason.hasPrefix("claude exited at the folder trust prompt"))
    #expect(try events(sbd, s.id, "answered").isEmpty)
    let mark = try #require(try sbd.events(s.id).last?.id)
    sleep(6)
    #expect(try sbd.events(s.id, after: mark).filter { ["started", "resumed"].contains($0.kind) }.isEmpty)
    #expect(try events(sbd, s.id, "trust_closed").count == 1)

    try sbd.sb("open", s.id)
    try waitForTrustCard(sbd, s.id)
    _ = try answer(sbd, "allow", s.id)
    try sbd.waitFor(s.id, "the kept prompt's reply") { $0.lastReply == "Done: hello" }
    sleep(2)
    #expect(try prompts(sbd, s.id) == ["hello"])
  }

  /// Path (e): `sb stop` at the dialog keeps the prompt once.
  @Test func stopAtTheDialogKeepsTheMessage() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    try waitForTrustCard(sbd, s.id)

    try sbd.sb("stop", s.id)

    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
    try sbd.waitFor("the trust_closed event") { try !events(sbd, s.id, "trust_closed").isEmpty }
    sleep(2)
    let closed = try events(sbd, s.id, "trust_closed")
    #expect(closed.count == 1)
    #expect(closed.first?.data["prompt"]?.string == "hello")
    #expect(try sbd.get(s.id).cards.isEmpty)

    try sbd.sb("open", s.id)
    try waitForTrustCard(sbd, s.id)
    _ = try answer(sbd, "allow", s.id)
    try sbd.waitFor(s.id, "the kept prompt's reply") { $0.lastReply == "Done: hello" }
    sleep(2)
    #expect(try prompts(sbd, s.id) == ["hello"])
  }

  /// A launch without a prompt keeps nothing when claude exits at the dialog.
  @Test func exitWithoutALaunchPromptKeepsNothing() throws {
    let sbd = try instance()
    let s = try decode(SessionSummary.self, sbd.sb("new", "--json", sbd.work))
    try waitForTrustCard(sbd, s.id)

    _ = try answer(sbd, "deny", s.id)

    try sbd.waitFor(s.id, "claude to exit") { $0.claudePid == nil }
    try sbd.sb("open", s.id)
    try waitForTrustCard(sbd, s.id)
    _ = try answer(sbd, "allow", s.id)
    try sbd.waitFor(s.id, "claude's start") { $0.live }
    sleep(3)
    #expect(try prompts(sbd, s.id).isEmpty)
  }

  /// The claude at the dialog holds the user's message, so the idle stop
  /// and the live cap leave it. The test moves the clock past the 10 s mark
  /// at which sbd records `running` and counts the claude as live.
  @Test func theIdleStopLeavesAClaudeAtTheTrustDialog() throws {
    let sbd = try instance(idleStopSeconds: 1)
    let s = try newWork(sbd)
    try waitForTrustCard(sbd, s.id)

    try sbd.waitFor("the running event") {
      try sbd.advanceClock(11_000)
      return try !events(sbd, s.id, "running").isEmpty
    }
    try #require(try sbd.get(s.id).live)
    sleep(3)
    try sbd.advanceClock(5_000)
    sleep(1)

    let after = try sbd.get(s.id)
    #expect(try events(sbd, s.id, "stopped").isEmpty)
    #expect(after.claudePid != nil)
    #expect(after.cards.map(\.kind) == [.trust])
    #expect(showsTheDialog(sbd, s.id))
  }

  /// The stub shows the folder in `$SB_HOME/trust-folder` while that file
  /// exists. A dialog that names another folder than the card's takes no
  /// keys, so claude stays at the dialog with No highlighted.
  @Test func allowRefusesWhenTheDialogShowsAnotherFolder() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    let card = try waitForTrustCard(sbd, s.id)
    let other = "/Users/me/dev/other"
    try other.write(toFile: "\(sbd.home.path)/trust-folder", atomically: true, encoding: .utf8)

    try sbd.press(s.id, "Up")

    try sbd.waitFor("the dialog to show the other folder") {
      ClaudeScreen.dialog(try sbd.screen(s.id)).flatMap(ClaudeScreen.trustFolder) == other
    }
    let result = try sbd.run("allow", s.id)
    #expect(result.status != 0)
    #expect(result.stderr.contains("Answer it in the terminal"))
    sleep(1)
    #expect(try sbd.highlighted(s.id) == "No, exit")
    #expect(try sbd.get(s.id).claudePid != nil)
    #expect(try events(sbd, s.id, "answered").isEmpty)
    #expect(try sbd.get(s.id).cards.map(\.id) == [card.id])
  }

  /// Exit has the same guard: a dialog for another folder takes no keys.
  @Test func denyRefusesWhenTheDialogShowsAnotherFolder() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    try waitForTrustCard(sbd, s.id)
    let other = "/Users/me/dev/other"
    try other.write(toFile: "\(sbd.home.path)/trust-folder", atomically: true, encoding: .utf8)
    try sbd.press(s.id, "Up")
    try sbd.waitFor("the dialog to show the other folder") {
      ClaudeScreen.dialog(try sbd.screen(s.id)).flatMap(ClaudeScreen.trustFolder) == other
    }

    let result = try sbd.run("deny", s.id)

    #expect(result.status != 0)
    #expect(result.stderr.contains("Answer it in the terminal"))
    sleep(1)
    #expect(try sbd.get(s.id).claudePid != nil)
    #expect(try events(sbd, s.id, "answered").isEmpty)
    #expect(try events(sbd, s.id, "trust_closed").isEmpty)
  }

  /// A deny message has no place in the trust dialog, and auto mode and
  /// answers belong to other cards.
  @Test func aTrustCardRefusesOtherAnswers() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    try waitForTrustCard(sbd, s.id)

    let auto = try sbd.run("allow", "--auto", s.id)
    let answers = try sbd.run("answer", s.id, "yes")

    #expect(auto.status != 0)
    #expect(answers.status != 0)
    #expect(try events(sbd, s.id, "answered").isEmpty)
    #expect(try sbd.get(s.id).cards.map(\.kind) == [.trust])
    #expect(try sbd.highlighted(s.id) == "No, exit")
  }

  /// The trust card stays across a restart of sbd while claude waits at the dialog.
  @Test func theTrustCardSurvivesARestartOfSbd() throws {
    let sbd = try instance()
    let s = try newWork(sbd)
    let card = try waitForTrustCard(sbd, s.id)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.get(s.id).cards.map(\.id) == [card.id])
    _ = try answer(sbd, "allow", s.id)
    try sbd.waitFor(s.id, "the reply to hello") { $0.lastReply == "Done: hello" }
    #expect(try prompts(sbd, s.id) == ["hello"])
  }
}
