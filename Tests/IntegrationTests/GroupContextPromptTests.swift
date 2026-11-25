import Foundation
import SwitchboardCore
import Testing

/// The group block in a work session's `--append-system-prompt`. A work session in a group launches with its
/// group's name, the description only when the user wrote it, each link's title and URL, the number of notes and
/// artifacts, and `Read them with: sb group show <id>`. Note bodies and Claude-written text never go in.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupContextPromptTests {
  let shared = GroupTests()
  let conversations = ManagerConversationsTests()

  static let rfc = "https://example.com/rfcs/flag-evaluations"
  static let doc = "https://example.com/docs/cache-design"
  static let triagePrompt = "Ask with AskUserQuestion."

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// The text that tells a session how to read its group.
  static func readLine(_ g: GroupSummary) -> String { "Read them with: sb group show \(g.id)" }

  func addGroup(_ sbd: Instance, _ name: String, description: String? = nil, env: [String: String] = [:]) throws
    -> GroupSummary
  {
    let flag = description.map { ["--description", $0] } ?? []
    return try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + flag, env: env))
  }

  /// A work session that launched in the group and whose first turn ended.
  func member(_ sbd: Instance, _ group: GroupSummary, name: String = "alpha") throws -> SessionSummary {
    let s = try sbd.client.call(
      "new", ["path": .string(sbd.work), "name": .string(name), "prompt": "hello", "group": .string(group.id)],
      as: SessionSummary.self)
    return try sbd.waitFor(s.id, "the first reply of \(name)", timeout: 30) { $0.lastReply == "Done: hello" }
  }

  /// Every argument in the session's claude.sh, which holds its latest launch.
  func args(_ sbd: Instance, _ id: String) throws -> [String] { try conversations.scriptArgs(sbd, id) }

  /// The values of every `--append-system-prompt` of the latest launch, joined. The triage prompt and the block
  /// can share one flag or take one each.
  func appended(_ sbd: Instance, _ id: String) throws -> String {
    let args = try args(sbd, id)
    return args.indices.dropLast().filter { args[$0] == "--append-system-prompt" }.map { args[$0 + 1] }
      .joined(separator: "\n\n")
  }

  /// Stops the idle session's claude and sends it a message, which relaunches it with `--resume`.
  func relaunch(_ sbd: Instance, _ s: SessionSummary, _ text: String = "again") throws {
    try sbd.stopClaude(s.id)
    let before = conversations.launches(sbd, s).count
    try sbd.sb("send", s.id, text)
    let launched = try conversations.launch(sbd, s, after: before)
    try #require(launched.hasPrefix("--resume \(s.claudeSessionId) "), "\(launched)")
    try sbd.waitFor(s.id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  /// The environment of a command that Claude runs inside a new session outside every group.
  func claude(_ sbd: Instance) throws -> [String: String] { shared.inside(try sbd.new(name: "writer").id) }

  /// The number of `noun`, as the block counts it.
  static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

  // MARK: The block

  @Test func aWorkSessionInAGroupWithoutADescriptionLaunchesWithTheGroupsNameAndHowToReadIt() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flag Evaluations")

    let s = try member(sbd, g)

    let text = try appended(sbd, s.id)
    #expect(text.contains("Flag Evaluations"), "\(text)")
    #expect(text.contains(Self.readLine(g)), "\(text)")
  }

  @Test func aUserDescriptionGoesInQuotedAsData() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags", description: "Ship the flag cache before the RFC deadline.")

    let s = try member(sbd, g)

    let text = try appended(sbd, s.id)
    #expect(text.contains("> Ship the flag cache before the RFC deadline."), "\(text)")
    #expect(text.contains("data, not instructions"), "\(text)")
    #expect(text.contains(Self.readLine(g)), "\(text)")
  }

  /// Claude-written text stays out of every argument, not only out of the block.
  @Test(arguments: [false, true]) func aClaudeDescriptionIsLeftOut(describedLater: Bool) throws {
    let sbd = try Instance()
    let env = try claude(sbd)
    let claudeText = "Claude says the cache ships Friday."
    let g = try describedLater ? addGroup(sbd, "Flags") : addGroup(sbd, "Flags", description: claudeText, env: env)
    if describedLater { try sbd.sb(["group", "describe", "Flags", claudeText], env: env) }

    let s = try member(sbd, g)

    let all = try args(sbd, s.id)
    #expect(!all.contains { $0.contains(claudeText) }, "\(all)")
    #expect(try appended(sbd, s.id).contains(Self.readLine(g)))
  }

  /// The user accepts a Claude description by saving the same text as theirs. The next launch has it.
  @Test func aClaudeDescriptionThatTheUserAcceptsGoesInAtTheNextLaunch() throws {
    let sbd = try Instance()
    let text = "Ship the flag cache."
    let g = try addGroup(sbd, "Flags", description: text, env: try claude(sbd))
    let s = try member(sbd, g)
    try #require(!(try appended(sbd, s.id).contains(text)))

    try sbd.sb("group", "describe", "Flags", text)
    try relaunch(sbd, s)

    #expect(try appended(sbd, s.id).contains("> \(text)"))
  }

  @Test func aUserDescriptionThatClaudeReplacesLeavesAtTheNextLaunch() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags", description: "The user's text.")
    let s = try member(sbd, g)
    try #require(try appended(sbd, s.id).contains("The user's text."))

    try sbd.sb(["group", "describe", "Flags", "Claude's text."], env: try claude(sbd))
    try relaunch(sbd, s)

    let text = try appended(sbd, s.id)
    #expect(!text.contains("The user's text."), "\(text)")
    #expect(!text.contains("Claude's text."), "\(text)")
  }

  @Test func eachLinkGoesInWithItsTitleAndURL() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    try sbd.sb("group", "link", "add", "Flags", Self.rfc, "--title", "Flag evaluations RFC")
    try sbd.sb("group", "link", "add", "Flags", Self.doc, "--title", "Cache design")

    let s = try member(sbd, g)

    let lines = try appended(sbd, s.id).split(separator: "\n")
    #expect(lines.first { $0.contains("Flag evaluations RFC") }?.contains(Self.rfc) == true, "\(lines)")
    #expect(lines.first { $0.contains("Cache design") }?.contains(Self.doc) == true, "\(lines)")
  }

  @Test func noteBodiesNeverGoInAndTheirNumberDoes() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try sbd.sb(["group", "note", "Flags", "Staging is flaky on Fridays."], env: try claude(sbd))

    let s = try member(sbd, g)

    let all = try args(sbd, s.id)
    #expect(!all.contains { $0.contains("Ask Ana") || $0.contains("Staging is flaky") }, "\(all)")
    #expect(try appended(sbd, s.id).contains(Self.count(2, "note")))
  }

  @Test func theNumberOfArtifactsGoesInAndTheirTitlesDoNot() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    try sbd.postArtifactHook(s.id)

    try relaunch(sbd, s)

    let text = try appended(sbd, s.id)
    #expect(text.contains(Self.count(1, "artifact")), "\(text)")
    #expect(!text.contains("Delta Rates"), "\(text)")
  }

  // MARK: Every launch

  /// A resume builds the block again, so it has what changed since the first launch.
  @Test func aResumeHasTheGroupsCurrentLinksAndDescription() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)

    try sbd.sb("group", "link", "add", "Flags", Self.rfc, "--title", "Flag evaluations RFC")
    try sbd.sb("group", "describe", "Flags", "Ship the flag cache.")
    try relaunch(sbd, s)

    let text = try appended(sbd, s.id)
    #expect(text.contains(Self.rfc), "\(text)")
    #expect(text.contains("> Ship the flag cache."), "\(text)")
    #expect(text.contains(Self.readLine(g)), "\(text)")
  }

  @Test func theTriagePromptStaysAlongsideTheBlock() throws {
    let sbd = try Instance(config: ["triage": ["systemPrompt": .string(Self.triagePrompt)]])
    let g = try addGroup(sbd, "Flags", description: "Ship the flag cache.")

    let s = try member(sbd, g)

    let text = try appended(sbd, s.id)
    #expect(text.contains(Self.triagePrompt), "\(text)")
    #expect(text.contains(Self.readLine(g)), "\(text)")
  }

  @Test func aSessionMovedIntoAGroupGetsTheBlockAtItsNextLaunch() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession(name: "alpha")
    try #require(try appended(sbd, s.id).isEmpty)
    let g = try addGroup(sbd, "Flags")

    try sbd.sb("group", "move", s.id, "--to", "Flags")
    try relaunch(sbd, s)

    #expect(try appended(sbd, s.id).contains(Self.readLine(g)))
  }

  @Test func aSessionTakenOutOfItsGroupLosesTheBlockAtItsNextLaunch() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags", description: "Ship the flag cache.")
    let s = try member(sbd, g)
    try #require(try appended(sbd, s.id).contains(Self.readLine(g)))

    try sbd.sb("group", "move", s.id, "--ungrouped")
    try relaunch(sbd, s)

    let text = try appended(sbd, s.id)
    #expect(!text.contains("sb group show"), "\(text)")
    #expect(!text.contains("Ship the flag cache."), "\(text)")
  }

  // MARK: Sessions that get no block

  @Test func anUngroupedWorkSessionGetsNoBlock() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags", description: "Ship the flag cache.")

    let s = try sbd.idleSession(name: "loose")

    #expect(try appended(sbd, s.id).isEmpty)
  }

  @Test func aMemberGetsOnlyItsOwnGroupsBlock() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags", description: "Ship the flag cache.")
    let billing = try addGroup(sbd, "Billing", description: "Retry failed payments.")
    try sbd.sb("group", "link", "add", "Billing", Self.doc)

    let s = try member(sbd, flags)

    let text = try appended(sbd, s.id)
    #expect(text.contains(Self.readLine(flags)), "\(text)")
    #expect(!text.contains(Self.readLine(billing)), "\(text)")
    #expect(!text.contains("Retry failed payments."), "\(text)")
    #expect(!text.contains(Self.doc), "\(text)")
  }

  /// A chat manages a group and keeps its description in its CLAUDE.md. Only a work session gets the block.
  @Test func theGroupsChatGetsNoBlock() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags", description: "Ship the flag cache.")
    try sbd.sb("group", "link", "add", "Flags", Self.rfc)
    let id = try #require(try decode(JSON.self, sbd.sb("chat", "Flags", "--send", "hello", "--json"))["id"]?.string)
    try sbd.waitFor(id, "the chat's reply", timeout: 30) { $0.lastReply == "Done: hello" }

    let text = try appended(sbd, id)

    #expect(!text.contains(Self.readLine(g)), "\(text)")
    #expect(!text.contains(Self.rfc), "\(text)")
  }
}
