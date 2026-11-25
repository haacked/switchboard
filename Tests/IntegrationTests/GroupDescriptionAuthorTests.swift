import Foundation
import SwitchboardCore
import Testing

/// Who wrote a group's description: `sb group add --description` and
/// `sb group describe` record the caller, Claude inside a session and the
/// user otherwise, and `sb group ls` marks a description that Claude wrote.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupDescriptionAuthorTests {
  let shared = GroupTests()

  static let claudeMarker = "(written by Claude)"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func add(_ sbd: Instance, _ name: String, description: String? = nil, env: [String: String] = [:]) throws
    -> GroupSummary
  {
    let flag = description.map { ["--description", $0] } ?? []
    return try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + flag, env: env))
  }

  func describe(_ sbd: Instance, _ group: String, _ text: String, env: [String: String] = [:]) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "describe", "--json", group, text], env: env))
  }

  func clear(_ sbd: Instance, _ group: String, env: [String: String] = [:]) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "describe", "--json", group, "--clear"], env: env))
  }

  func listed(_ sbd: Instance, _ id: String) throws -> GroupSummary {
    try #require(try shared.list(sbd).groups.first { $0.id == id })
  }

  /// The environment of a command that Claude runs inside a new session.
  func claude(_ sbd: Instance) throws -> [String: String] { shared.inside(try sbd.new(name: "alpha").id) }

  // MARK: add

  @Test func addWithADescriptionIsByYou() throws {
    let sbd = try Instance()

    let g = try add(sbd, "Flags", description: "Ship the cache.")

    #expect(g.descriptionBy == .you)
    #expect(try listed(sbd, g.id).descriptionBy == .you)
  }

  @Test func addWithADescriptionInsideClaudeIsByClaude() throws {
    let sbd = try Instance()
    let env = try claude(sbd)

    let g = try add(sbd, "Flags", description: "Ship the cache.", env: env)

    #expect(g.descriptionBy == .claude)
    #expect(try listed(sbd, g.id).descriptionBy == .claude)
  }

  /// A description's author goes with the description, so a group without one has no author.
  @Test(arguments: [false, true]) func addWithoutADescriptionHasNoAuthor(insideClaude: Bool) throws {
    let sbd = try Instance()
    let env = try insideClaude ? claude(sbd) : [:]

    let g = try add(sbd, "Flags", env: env)

    #expect(g.descriptionBy == nil)
    #expect(try listed(sbd, g.id).descriptionBy == nil)
  }

  @Test func aRawAddByClaudeIsByClaude() throws {
    let sbd = try Instance()

    let g = try sbd.client.call(
      "group-add", ["name": "Flags", "description": "Ship the cache.", "by": "claude"], as: GroupSummary.self)

    #expect(g.descriptionBy == .claude)
    #expect(try listed(sbd, g.id).descriptionBy == .claude)
  }

  // MARK: describe

  @Test func describeIsByYou() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags")

    let described = try describe(sbd, "Flags", "Ship the cache.")

    #expect(described.descriptionBy == .you)
    #expect(try listed(sbd, g.id).descriptionBy == .you)
  }

  @Test func describeInsideClaudeIsByClaude() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags")
    let env = try claude(sbd)

    let described = try describe(sbd, "Flags", "Ship the cache.", env: env)

    #expect(described.descriptionBy == .claude)
    #expect(try listed(sbd, g.id).descriptionBy == .claude)
  }

  @Test func aUserDescribeAfterAClaudeDescriptionIsByYou() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags", description: "Claude's text.", env: try claude(sbd))

    _ = try describe(sbd, "Flags", "The user's text.")

    let after = try listed(sbd, g.id)
    #expect(after.description == "The user's text.")
    #expect(after.descriptionBy == .you)
  }

  @Test func aClaudeDescribeAfterAUserDescriptionIsByClaude() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags", description: "The user's text.")

    _ = try describe(sbd, "Flags", "Claude's text.", env: try claude(sbd))

    let after = try listed(sbd, g.id)
    #expect(after.description == "Claude's text.")
    #expect(after.descriptionBy == .claude)
  }

  @Test(arguments: [false, true]) func clearingADescriptionClearsItsAuthor(insideClaude: Bool) throws {
    let sbd = try Instance()
    let env = try claude(sbd)
    let g = try add(sbd, "Flags", description: "Claude's text.", env: env)

    let cleared = try clear(sbd, "Flags", env: insideClaude ? env : [:])

    #expect(cleared.description == nil)
    #expect(cleared.descriptionBy == nil)
    #expect(try listed(sbd, g.id).descriptionBy == nil)
  }

  @Test func aRawDescribeByClaudeIsByClaude() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags")

    let described = try sbd.client.call(
      "group-describe", ["group": "Flags", "text": "Ship the cache.", "by": "claude"], as: GroupSummary.self)

    #expect(described.descriptionBy == .claude)
    #expect(try listed(sbd, g.id).descriptionBy == .claude)
  }

  /// An app older than Accept sends `group-describe` without `by`.
  @Test func aRawDescribeWithoutByReadsAsYou() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags", description: "Claude's text.", env: try claude(sbd))

    _ = try sbd.client.call("group-describe", ["group": "Flags", "text": "The app's text."])

    let after = try listed(sbd, g.id)
    #expect(after.description == "The app's text.")
    #expect((after.descriptionBy ?? .you) == .you)
  }

  /// The app's Accept sends the text it shows with `by: you`.
  @Test func acceptingAClaudeDescriptionKeepsTheTextAndMakesItYours() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags", description: "Claude's text.", env: try claude(sbd))

    _ = try sbd.client.call("group-describe", ["group": .string(g.id), "text": "Claude's text.", "by": "you"])

    let after = try listed(sbd, g.id)
    #expect(after.description == "Claude's text.")
    #expect(after.descriptionBy == .you)
  }

  @Test func aRawDescribeByAnUnknownAuthorIsRefusedAndKeepsTheDescription() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags", description: "Ship the cache.")

    let message = failure(sbd, "group-describe", ["group": "Flags", "text": "New text.", "by": "robot"])

    #expect(message != "no error")
    let after = try listed(sbd, g.id)
    #expect(after.description == "Ship the cache.")
    #expect(after.descriptionBy == .you)
  }

  // MARK: ls

  @Test func lsMarksADescriptionThatClaudeWrote() throws {
    let sbd = try Instance()
    _ = try add(sbd, "Flags", description: "Ship the cache.", env: try claude(sbd))

    let text = try sbd.sb("group", "ls")

    let line = try #require(text.split(separator: "\n").first { $0.contains("Ship the cache.") })
    #expect(line.contains(Self.claudeMarker))
  }

  @Test func lsDoesNotMarkADescriptionThatTheUserWrote() throws {
    let sbd = try Instance()
    _ = try add(sbd, "Flags", description: "Ship the cache.")

    let text = try sbd.sb("group", "ls")

    #expect(text.contains("Ship the cache."))
    #expect(!text.contains(Self.claudeMarker))
  }

  @Test func lsMarksOnlyTheGroupWhoseDescriptionClaudeWrote() throws {
    let sbd = try Instance()
    _ = try add(sbd, "Billing", description: "Retry payments.")
    _ = try add(sbd, "Flags", description: "Ship the cache.", env: try claude(sbd))

    let lines = try sbd.sb("group", "ls").split(separator: "\n")

    let billing = try #require(lines.first { $0.contains("Retry payments.") })
    let flags = try #require(lines.first { $0.contains("Ship the cache.") })
    #expect(!billing.contains(Self.claudeMarker))
    #expect(flags.contains(Self.claudeMarker))
  }

  @Test func lsDropsTheMarkAfterTheUserDescribes() throws {
    let sbd = try Instance()
    _ = try add(sbd, "Flags", description: "Claude's text.", env: try claude(sbd))
    _ = try describe(sbd, "Flags", "The user's text.")

    let text = try sbd.sb("group", "ls")

    #expect(!text.contains(Self.claudeMarker))
  }

  // MARK: Restart

  @Test func theDescriptionsAuthorSurvivesARestartOfSbd() throws {
    let sbd = try Instance()
    let env = try claude(sbd)
    let byClaude = try add(sbd, "Flags", description: "Claude's text.", env: env)
    let byYou = try add(sbd, "Billing", description: "The user's text.")
    let cleared = try add(sbd, "Docs", description: "Cleared later.", env: env)
    _ = try clear(sbd, "Docs")
    let before = try shared.list(sbd)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try shared.list(sbd) == before)
    #expect(try listed(sbd, byClaude.id).descriptionBy == .claude)
    #expect(try listed(sbd, byYou.id).descriptionBy == .you)
    #expect(try listed(sbd, cleared.id).descriptionBy == nil)
  }

  // MARK: Merges

  @Test func aMergeThatTakesTheAbsorbedDescriptionTakesItsAuthor() throws {
    let l = try shared.linkedGroups()
    _ = try describe(l.sbd, "Docs", "Write the docs.", env: shared.inside(l.lead.id))

    _ = try shared.accept(l.sbd, shared.mergeId(l.flags, l.docs))

    let survivor = try listed(l.sbd, l.flags.id)
    #expect(survivor.description == "Write the docs.")
    #expect(survivor.descriptionBy == .claude)
  }

  @Test func aMergeNotesAClaudeDescriptionAsByClaudeAndKeepsTheSurvivorsAuthor() throws {
    let l = try shared.linkedGroups()
    _ = try describe(l.sbd, "Flags", "Ship the cache.")
    _ = try describe(l.sbd, "Docs", "Write the docs.", env: shared.inside(l.lead.id))

    _ = try shared.accept(l.sbd, shared.mergeId(l.flags, l.docs))

    let survivor = try listed(l.sbd, l.flags.id)
    #expect(survivor.descriptionBy == .you)
    let note = try #require(survivor.notes.first { $0.text.contains("Write the docs.") })
    #expect(note.by == .claude)
  }

  @Test func aMergeNotesAUserDescriptionAsByYou() throws {
    let l = try shared.linkedGroups()
    _ = try describe(l.sbd, "Flags", "Ship the cache.", env: shared.inside(l.lead.id))
    _ = try describe(l.sbd, "Docs", "Write the docs.")

    _ = try shared.accept(l.sbd, shared.mergeId(l.flags, l.docs))

    let survivor = try listed(l.sbd, l.flags.id)
    #expect(survivor.descriptionBy == .claude)
    let note = try #require(survivor.notes.first { $0.text.contains("Write the docs.") })
    #expect(note.by == .you)
  }
}
