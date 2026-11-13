import Foundation
import SwitchboardCore
import Testing

/// `sb slash <session> --json` answers the session's slash commands: its
/// transcript's latest skill listing, the skills and commands that the
/// account and the cwd hold, and Claude Code's built-ins. The stub writes
/// `$SB_HOME/skill-listing.jsonl` into the transcript before the first prompt
/// of each launch, as claude writes its initial listing.
@Suite(.blocking(timeLimit: .seconds(120))) struct SlashCommandTests {
  static let fixtures = Instance.root.appendingPathComponent("Tests/SwitchboardCoreTests/Fixtures/SkillListing")

  /// The names that manager-launches.jsonl folds to.
  static let managerSet: Set<String> = ["commit", "go", "code-review", "claude-api", "explain-open"]

  /// One row of the answer, read from the raw JSON so that the test pins the wire format.
  struct Row: Hashable {
    let name: String
    let description: String?
    let source: String
  }

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// Makes the stub write the fixture into each launch's transcript.
  func useListing(_ sbd: Instance, _ fixture: String) throws {
    try FileManager.default.copyItem(
      atPath: Self.fixtures.appendingPathComponent(fixture).path, toPath: "\(sbd.home.path)/skill-listing.jsonl")
  }

  func slash(_ sbd: Instance, _ ref: String) throws -> JSON {
    try #require(JSON.parse(try sbd.sb("slash", ref, "--json")))
  }

  func rows(_ answer: JSON) throws -> [Row] {
    try #require(answer["commands"]?.array).map { c in
      Row(
        name: try #require(c["name"]?.string), description: c["description"]?.string,
        source: try #require(c["source"]?.string))
    }
  }

  func row(_ name: String, _ rows: [Row]) -> Row? { rows.first { $0.name == name } }

  /// The rows that are not built-ins.
  func own(_ rows: [Row]) -> [Row] { rows.filter { $0.source != "builtIn" } }

  /// The session's transcript, which the stub writes in its account's projects folder.
  func transcript(_ sbd: Instance, _ s: SessionSummary) -> String? {
    let files = FileManager.default.enumerator(atPath: sbd.home.path)?.compactMap { $0 as? String } ?? []
    return files.first { $0.hasSuffix("/\(s.claudeSessionId).jsonl") }.map { "\(sbd.home.path)/\($0)" }
  }

  func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
  }

  /// A session whose first turn, for "hello", has ended.
  func repliedSession(_ sbd: Instance, name: String = "t") throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    return try sbd.waitFor(s.id, "the reply to hello", timeout: 30) { $0.lastReply == "Done: hello" }
  }

  @Test func sessionWithAListingAnswersTheFoldedListingAndTheBuiltIns() throws {
    let sbd = try Instance()
    try useListing(sbd, "manager-launches.jsonl")
    let s = try repliedSession(sbd)

    let answer = try slash(sbd, s.id)

    let rows = try rows(answer)
    #expect(answer["listing"]?.bool == true)
    #expect(Set(own(rows).map(\.name)) == Self.managerSet)
    #expect(own(rows).allSatisfy { $0.source == "listing" })
    #expect(
      Set(rows.filter { $0.source == "builtIn" }.map(\.name))
        == Set(SlashCommand.builtIns.map(\.name)).subtracting(Self.managerSet))
    #expect(rows.count == Set(rows.map(\.name)).count)
    #expect(row("go", rows)?.description?.contains("when its approval alone can unblock the merge") == true)
  }

  @Test func sessionNameAndPlainOutputAnswerTheSameRows() throws {
    let sbd = try Instance()
    try useListing(sbd, "manager-launches.jsonl")
    let s = try repliedSession(sbd, name: "slash-by-name")

    let byId = try rows(try slash(sbd, s.id))
    let byName = try rows(try slash(sbd, s.name))
    let text = try sbd.sb("slash", s.id)

    #expect(Set(byName) == Set(byId))
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.contains("/commit  Commit staged/unstaged changes with a well-crafted commit message."))
    #expect(lines.count == byId.count)
  }

  @Test func sessionBeforeItsFirstPromptAnswersTheScan() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "t")
    let live = try sbd.waitFor(s.id, "the stub") { $0.live }
    let account = try #require(live.account ?? sbd.inheritedAccount)
    try write(
      "---\nname: x\ndescription: Account skill x.\n---\nSay hi.\n", to: "\(account)/skills/x/SKILL.md")
    try write("Repo command y.\n", to: "\(sbd.work)/.claude/commands/y.md")

    let answer = try slash(sbd, s.id)

    let rows = try rows(answer)
    #expect(answer["listing"]?.bool == false)
    #expect(
      Set(own(rows)) == [
        Row(name: "x", description: "Account skill x.", source: "scan"),
        Row(name: "y", description: "Repo command y.", source: "scan"),
      ])
    #expect(Set(rows.filter { $0.source == "builtIn" }.map(\.name)) == Set(SlashCommand.builtIns.map(\.name)))
  }

  @Test func groupChatAndManagerConversationAnswer() throws {
    let sbd = try Instance()
    try useListing(sbd, "manager-launches.jsonl")
    _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags"))
    let sent = try decode(JSON.self, sbd.sb("chat", "Flags", "--send", "hello", "--json"))
    let chat = try #require(sent["id"]?.string)
    try sbd.waitFor(chat, "the chat's reply", timeout: 30) { $0.lastReply == "Done: hello" }
    let manager = try decode(SessionSummary.self, sbd.sb("manager", "new", "--json"))
    try sbd.waitFor(manager.id, "the Manager's stub") { $0.live }
    try sbd.sb("send", manager.id, "hello")
    try sbd.waitFor(manager.id, "the Manager's reply", timeout: 30) { $0.lastReply == "Done: hello" }

    for id in [chat, manager.id] {
      let answer = try slash(sbd, id)

      #expect(answer["listing"]?.bool == true, "\(id)")
      #expect(Set(try rows(answer).map(\.name)).isSuperset(of: Self.managerSet), "\(id)")
    }
  }

  @Test func deltaAppendedToTheTranscriptReachesTheNextRequestAsAFreshSbdReadsIt() throws {
    let sbd = try Instance()
    try useListing(sbd, "manager-launches.jsonl")
    let s = try repliedSession(sbd)
    let before = try rows(try slash(sbd, s.id))
    #expect(row("added-later", before) == nil)
    let path = try #require(transcript(sbd, s))
    let delta: JSON = [
      "type": "attachment", "isSidechain": false,
      "attachment": [
        "type": "skill_listing", "content": "- added-later: Added after the first request.", "skillCount": 1,
        "isInitial": false, "names": ["added-later"],
      ],
    ]
    let handle = try #require(FileHandle(forWritingAtPath: path))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((delta.text + "\n").utf8))
    try handle.close()

    let after = try rows(try slash(sbd, s.id))
    sbd.stopSbd()
    try sbd.startSbd()
    let fresh = try rows(try slash(sbd, s.id))

    #expect(
      row("added-later", after)
        == Row(name: "added-later", description: "Added after the first request.", source: "listing"))
    #expect(Set(after) == Set(fresh))
  }

  @Test func unknownSessionFails() throws {
    let sbd = try Instance()

    let r = try sbd.run("slash", "nope", "--json")

    #expect(r.status != 0)
    #expect(r.stderr.contains("no session nope"))
  }
}
