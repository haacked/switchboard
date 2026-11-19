import Foundation
import SwitchboardCore
import Testing

/// The line that a running work session hears when its group's context changes. A change to the notes, the links,
/// or the user-written description marks the context as changed. At each member's next UserPromptSubmit, sbd adds
/// one line through `additionalContext` that names the group and `sb group show <id>`. A member hears each change
/// once, and a launch counts as hearing the current context, because the system prompt already has it.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupContextNoticeTests {
  let shared = GroupTests()
  let conversations = ManagerConversationsTests()

  static let rfc = "https://example.com/rfcs/flag-evaluations"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func addGroup(_ sbd: Instance, _ name: String, description: String? = nil) throws -> GroupSummary {
    let flag = description.map { ["--description", $0] } ?? []
    return try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + flag))
  }

  /// A work session that launched in the group and whose first turn ended.
  func member(_ sbd: Instance, _ group: GroupSummary, name: String = "alpha") throws -> SessionSummary {
    let s = try sbd.client.call(
      "new", ["path": .string(sbd.work), "name": .string(name), "prompt": "hello", "group": .string(group.id)],
      as: SessionSummary.self)
    return try sbd.waitFor(s.id, "the first reply of \(name)", timeout: 30) { $0.lastReply == "Done: hello" }
  }

  /// The additionalContext of each hook answer that the session's claude got, oldest first.
  func contexts(_ sbd: Instance, _ s: SessionSummary) -> [String] {
    sbd.hookOutputs(s.claudeSessionId).compactMap { $0["hookSpecificOutput"]?["additionalContext"]?.string }
  }

  /// The contexts after the first `count` that hold the group's notice.
  func notices(_ sbd: Instance, _ s: SessionSummary, _ g: GroupSummary, after count: Int) -> [String] {
    contexts(sbd, s).dropFirst(count).filter { $0.contains("sb group show \(g.id)") }
  }

  /// Sends the session a message and waits for its turn to end, which runs its UserPromptSubmit.
  func prompt(_ sbd: Instance, _ s: SessionSummary, _ text: String) throws {
    try sbd.sb("send", s.id, text)
    try sbd.waitFor(s.id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  /// The environment of a command that Claude runs inside a new session outside every group.
  func claude(_ sbd: Instance) throws -> [String: String] { shared.inside(try sbd.new(name: "writer").id) }

  /// One change to a group's context, made by the user unless it says otherwise.
  enum Change: String, CaseIterable, CustomTestStringConvertible {
    case note, claudeNote, linkAdd, linkRm, describe, clearDescription

    var testDescription: String { rawValue }

    /// Makes the change. `setUp` runs before the member launches, so the launch has heard it.
    func setUp(_ t: GroupContextNoticeTests, _ sbd: Instance) throws {
      switch self {
      case .linkRm: try sbd.sb("group", "link", "add", "Flags", GroupContextNoticeTests.rfc)
      case .clearDescription: try sbd.sb("group", "describe", "Flags", "Ship the flag cache.")
      default: break
      }
    }

    func make(_ t: GroupContextNoticeTests, _ sbd: Instance, _ g: GroupSummary) throws {
      switch self {
      case .note: try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
      case .claudeNote: try sbd.sb(["group", "note", "Flags", "Ask Ana before the rollout."], env: try t.claude(sbd))
      case .linkAdd: try sbd.sb("group", "link", "add", "Flags", GroupContextNoticeTests.rfc, "--title", "RFC")
      case .linkRm:
        let id = try #require(try t.shared.list(sbd).groups.first { $0.id == g.id }?.links?.first?.id)
        try sbd.sb("group", "link", "rm", "Flags", id)
      case .describe: try sbd.sb("group", "describe", "Flags", "Ship the flag cache.")
      case .clearDescription: try sbd.sb("group", "describe", "Flags", "--clear")
      }
    }
  }

  // MARK: A change is heard once

  @Test(arguments: Change.allCases)
  func aChangeIsHeardOnceAtTheNextPrompt(change: Change) throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    try change.setUp(self, sbd)
    let s = try member(sbd, g)
    let before = contexts(sbd, s).count

    try change.make(self, sbd, g)
    try prompt(sbd, s, "next")

    let heard = notices(sbd, s, g, after: before)
    #expect(heard.count == 1, "\(contexts(sbd, s))")
    let later = contexts(sbd, s).count
    try prompt(sbd, s, "again")
    #expect(notices(sbd, s, g, after: later).isEmpty, "\(contexts(sbd, s))")
  }

  @Test func theNoticeIsOneLineThatNamesTheGroupAndHoldsNoNoteBody() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    let before = contexts(sbd, s).count

    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try prompt(sbd, s, "next")

    let context = try #require(notices(sbd, s, g, after: before).first)
    let line = try #require(context.split(separator: "\n").first { $0.contains("sb group show \(g.id)") })
    #expect(line.hasPrefix("Switchboard:"), "\(line)")
    #expect(line.contains("Flags"), "\(line)")
    #expect(!context.contains("Ask Ana"), "\(context)")
  }

  @Test func twoChangesBeforeAPromptAreHeardAsOneLine() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    let before = contexts(sbd, s).count

    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try sbd.sb("group", "link", "add", "Flags", Self.rfc)
    try prompt(sbd, s, "next")

    let heard = notices(sbd, s, g, after: before)
    #expect(heard.count == 1, "\(heard)")
    let lines = heard.first?.split(separator: "\n").filter { $0.contains("sb group show \(g.id)") } ?? []
    #expect(lines.count == 1, "\(heard)")
  }

  @Test func aChangeAfterTheMemberHeardTheLastOneIsHeardAgain() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    try sbd.sb("group", "note", "Flags", "First.")
    try prompt(sbd, s, "next")
    let before = contexts(sbd, s).count

    try sbd.sb("group", "note", "Flags", "Second.")
    try prompt(sbd, s, "again")

    #expect(notices(sbd, s, g, after: before).count == 1, "\(contexts(sbd, s))")
  }

  @Test func everyMemberHearsTheChangeOnce() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let a = try member(sbd, g, name: "alpha")
    let b = try member(sbd, g, name: "bravo")
    let (beforeA, beforeB) = (contexts(sbd, a).count, contexts(sbd, b).count)

    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try prompt(sbd, a, "next")
    try prompt(sbd, b, "next")
    try prompt(sbd, a, "again")

    #expect(notices(sbd, a, g, after: beforeA).count == 1, "\(contexts(sbd, a))")
    #expect(notices(sbd, b, g, after: beforeB).count == 1, "\(contexts(sbd, b))")
  }

  /// A member that has not had a prompt since the change still hears it once another member has.
  @Test func oneMemberHearingTheChangeLeavesItUnheardForTheOthers() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let a = try member(sbd, g, name: "alpha")
    let b = try member(sbd, g, name: "bravo")
    let beforeB = contexts(sbd, b).count

    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try prompt(sbd, a, "next")
    try prompt(sbd, a, "again")
    try prompt(sbd, b, "next")

    #expect(notices(sbd, b, g, after: beforeB).count == 1, "\(contexts(sbd, b))")
  }

  // MARK: Who hears nothing

  @Test func aSessionOutsideTheGroupHearsNothing() throws {
    let sbd = try Instance()
    let flags = try addGroup(sbd, "Flags")
    let billing = try addGroup(sbd, "Billing")
    let loose = try sbd.idleSession(name: "loose")
    let other = try member(sbd, billing, name: "bravo")
    let (beforeLoose, beforeOther) = (contexts(sbd, loose).count, contexts(sbd, other).count)

    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try sbd.sb("group", "link", "add", "Flags", Self.rfc)
    try prompt(sbd, loose, "next")
    try prompt(sbd, other, "next")

    let heardLoose = contexts(sbd, loose).dropFirst(beforeLoose)
    let heardOther = contexts(sbd, other).dropFirst(beforeOther)
    #expect(!heardLoose.contains { $0.contains("sb group show") }, "\(Array(heardLoose))")
    #expect(!heardOther.contains { $0.contains("sb group show \(flags.id)") }, "\(Array(heardOther))")
  }

  /// A Claude-written description never goes into the system prompt, so writing one changes nothing a member reads.
  @Test func aClaudeDescriptionOnAGroupWithoutOneIsNotHeard() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    let env = try claude(sbd)
    let before = contexts(sbd, s).count

    try sbd.sb(["group", "describe", "Flags", "Claude's text."], env: env)
    try prompt(sbd, s, "next")

    #expect(notices(sbd, s, g, after: before).isEmpty, "\(contexts(sbd, s))")
  }

  /// Claude's text replaces the user's, so the user-written description that the block held is gone.
  @Test func aClaudeDescriptionThatReplacesTheUsersIsHeard() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags", description: "The user's text.")
    let s = try member(sbd, g)
    let env = try claude(sbd)
    let before = contexts(sbd, s).count

    try sbd.sb(["group", "describe", "Flags", "Claude's text."], env: env)
    try prompt(sbd, s, "next")

    let heard = notices(sbd, s, g, after: before)
    #expect(heard.count == 1, "\(contexts(sbd, s))")
    #expect(!heard.contains { $0.contains("Claude's text.") }, "\(heard)")
  }

  @Test func anArtifactIsNotAChangeToTheGroupsContext() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    let other = try member(sbd, g, name: "bravo")
    let before = contexts(sbd, s).count

    try sbd.postArtifactHook(other.id)
    try prompt(sbd, s, "next")

    #expect(notices(sbd, s, g, after: before).isEmpty, "\(contexts(sbd, s))")
  }

  // MARK: A launch counts as hearing

  @Test func aMemberThatLaunchesAfterTheChangeDoesNotHearIt() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try sbd.sb("group", "link", "add", "Flags", Self.rfc)

    let s = try member(sbd, g)
    try prompt(sbd, s, "next")

    #expect(notices(sbd, s, g, after: 0).isEmpty, "\(contexts(sbd, s))")
  }

  /// The change comes while claude runs or after it stopped. Either way the relaunch's system prompt has it.
  @Test(arguments: [false, true]) func aRelaunchAfterTheChangeCountsAsHearingIt(changeWhileStopped: Bool) throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    let before = contexts(sbd, s).count

    if !changeWhileStopped { try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.") }
    try sbd.stopClaude(s.id)
    if changeWhileStopped { try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.") }
    let launches = conversations.launches(sbd, s).count
    try prompt(sbd, s, "next")
    try conversations.launch(sbd, s, after: launches)
    try prompt(sbd, s, "again")

    #expect(notices(sbd, s, g, after: before).isEmpty, "\(contexts(sbd, s))")
  }

  @Test func aChangeAfterARelaunchIsHeard() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let s = try member(sbd, g)
    try sbd.stopClaude(s.id)
    try prompt(sbd, s, "next")
    let before = contexts(sbd, s).count

    try sbd.sb("group", "note", "Flags", "Ask Ana before the rollout.")
    try prompt(sbd, s, "again")

    #expect(notices(sbd, s, g, after: before).count == 1, "\(contexts(sbd, s))")
  }
}
