import Foundation
import SwitchboardCore
import Testing

/// `sb group show [<group>]` and the `group-show` request. With no group, it shows the group of `$SB_SESSION_ID`.
/// It prints the description and its author, every link, every note in full, the artifacts, and the plans, and
/// `--json` prints one `GroupSummary`.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupShowTests {
  let shared = GroupTests()

  static let rfc = "https://example.com/rfcs/flag-evaluations"
  static let claudeMarker = "(written by Claude)"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func show(_ sbd: Instance, _ group: String? = nil, env: [String: String] = [:]) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "show", "--json"] + (group.map { [$0] } ?? []), env: env))
  }

  func listed(_ sbd: Instance, _ id: String) throws -> GroupSummary {
    try #require(try shared.list(sbd).groups.first { $0.id == id })
  }

  // MARK: Which group

  @Test func showByNameIsTheGroupAsLsListsIt() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try decode(
      GroupSummary.self,
      sbd.sb("group", "add", "--json", "Flags", a.id, "--description", "Ship the cache.", "--note", "Ask Ana first."))
    try sbd.sb("group", "link", "add", "Flags", Self.rfc, "--title", "RFC")
    _ = try shared.add(sbd, "Billing")

    let shown = try show(sbd, "Flags")

    #expect(shown == (try listed(sbd, g.id)))
  }

  @Test func showFindsTheGroupByItsIdAndByAPrefixOfIt() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    _ = try shared.add(sbd, "Billing")

    #expect(try show(sbd, g.id).id == g.id)
    #expect(try show(sbd, String(g.id.prefix(4))).id == g.id)
  }

  /// Inside Claude and in the session's own shell, which sets `SB_SESSION_ID` without `CLAUDECODE`.
  @Test(arguments: [true, false]) func showWithoutAGroupShowsTheGroupOfTheSession(insideClaude: Bool) throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try shared.add(sbd, "Billing", b.id)
    let g = try shared.add(sbd, "Flags", a.id)
    let env = insideClaude ? shared.inside(a.id) : ["SB_SESSION_ID": a.id]

    let shown = try show(sbd, env: env)

    #expect(shown.id == g.id)
    #expect(shown == (try listed(sbd, g.id)))
  }

  @Test func aNamedGroupWinsOverTheGroupOfTheSession() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try shared.add(sbd, "Flags", a.id)
    let billing = try shared.add(sbd, "Billing")

    let shown = try show(sbd, "Billing", env: ["SB_SESSION_ID": a.id])

    #expect(shown.id == billing.id)
  }

  /// The server finds the session's group, so a client that may not list groups, such as a host, never needs to.
  @Test func aRawRequestWithOnlyASessionAnswersItsGroup() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try shared.add(sbd, "Billing")
    let g = try shared.add(sbd, "Flags", a.id)

    let shown = try sbd.client.call("group-show", ["session": .string(a.id)], as: GroupSummary.self)

    #expect(shown == (try listed(sbd, g.id)))
  }

  // MARK: Refusals

  @Test func showWithoutAGroupOrASessionFails() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")

    let r = try sbd.run(["group", "show", "--json"])

    #expect(r.status != 0)
    #expect(!r.stderr.isEmpty)
  }

  @Test func aRawRequestWithNeitherAGroupNorASessionFails() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")

    #expect(failure(sbd, "group-show", [:]) != "no error")
  }

  @Test(arguments: [true, false]) func showWithoutAGroupForASessionInNoGroupFails(insideClaude: Bool) throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try shared.add(sbd, "Flags")
    let env = insideClaude ? shared.inside(a.id) : ["SB_SESSION_ID": a.id]

    let r = try sbd.run(["group", "show", "--json"], env: env)

    #expect(r.status != 0)
    #expect(!r.stdout.contains("Flags"), "\(r.stdout)")
  }

  @Test func showWithoutAGroupForAnUnknownSessionFails() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")

    let r = try sbd.run(["group", "show", "--json"], env: ["SB_SESSION_ID": "nope-nope"])

    #expect(r.status != 0)
  }

  @Test func showOfAGroupItCantFindFails() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")

    let r = try sbd.run(["group", "show", "--json", "Nowhere"])

    #expect(r.status != 0)
  }

  // MARK: The text

  @Test func showPrintsTheNameIdAndAUserDescriptionWithoutTheClaudeMark() throws {
    let sbd = try Instance()
    let g = try decode(
      GroupSummary.self, sbd.sb("group", "add", "--json", "Flags", "--description", "Ship the flag cache."))

    let text = try sbd.sb("group", "show", "Flags")

    #expect(text.contains("Flags"), "\(text)")
    #expect(text.contains(g.id), "\(text)")
    #expect(text.contains("Ship the flag cache."), "\(text)")
    #expect(!text.contains(Self.claudeMarker), "\(text)")
  }

  @Test func showMarksADescriptionThatClaudeWrote() throws {
    let sbd = try Instance()
    let env = shared.inside(try sbd.new(name: "writer").id)
    try sbd.sb(["group", "add", "Flags", "--description", "Claude's text."], env: env)

    let text = try sbd.sb("group", "show", "Flags")

    let line = try #require(text.split(separator: "\n").first { $0.contains("Claude's text.") })
    #expect(line.contains(Self.claudeMarker), "\(text)")
  }

  @Test func showPrintsEveryLinkWithItsTitleAndURL() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")
    let doc = "https://example.com/docs/cache-design"
    try sbd.sb("group", "link", "add", "Flags", Self.rfc, "--title", "Flag evaluations RFC")
    try sbd.sb("group", "link", "add", "Flags", doc, "--title", "Cache design")

    let lines = try sbd.sb("group", "show", "Flags").split(separator: "\n")

    #expect(lines.first { $0.contains("Flag evaluations RFC") }?.contains(Self.rfc) == true, "\(lines)")
    #expect(lines.first { $0.contains("Cache design") }?.contains(doc) == true, "\(lines)")
  }

  /// `sb group ls` cuts a note to one line of 200 characters. `show` prints it whole.
  @Test func showPrintsEveryNoteInFull() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")
    let long = (1...40).map { "word\($0)" }.joined(separator: " ") + " the end."
    try #require(long.count > 200)
    try sbd.sb("group", "note", "Flags", long)
    try sbd.sb("group", "note", "Flags", "Ask Ana first.")

    let text = try sbd.sb("group", "show", "Flags")

    #expect(text.contains(long), "\(text)")
    #expect(text.contains("Ask Ana first."), "\(text)")
  }

  /// `show` keeps a note's line breaks, indents each later line, and names who wrote each note.
  @Test func showIndentsANotesLaterLinesAndNamesItsAuthor() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")
    try sbd.sb("group", "note", "Flags", "First line.\nSecond line.")
    try sbd.sb(["group", "note", "Flags", "Ask Ana first."], env: shared.inside(try sbd.new(name: "writer").id))

    let lines = try sbd.sb("group", "show", "Flags").split(separator: "\n")

    #expect(lines.contains("  note by you: First line."), "\(lines)")
    #expect(lines.contains("    Second line."), "\(lines)")
    #expect(lines.contains("  note by Claude: Ask Ana first."), "\(lines)")
  }

  @Test func showPrintsTheArtifactsOfTheGroupsSessions() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try shared.add(sbd, "Flags", a.id)
    try sbd.postArtifactHook(a.id)

    let text = try sbd.sb("group", "show", "Flags")

    let line = try #require(text.split(separator: "\n").first { $0.contains("Delta Rates") })
    #expect(line.contains(artifactPageURL), "\(text)")
  }

  @Test func showPrintsThePlansOfTheGroup() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")
    try sbd.writePlan(sbd.planFile, "# Flag evaluations\n\n| Session | State |\n| --- | --- |\n| 1 | Not started |\n")
    let plan = try sbd.attachPlan(sbd.planFile, group: "Flags")

    let text = try sbd.sb("group", "show", "Flags")

    #expect(text.contains(plan), "\(text)")
  }

  @Test func showPrintsOnlyTheOneGroup() throws {
    let sbd = try Instance()
    _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Billing", "--note", "Retry payments."))
    _ = try shared.add(sbd, "Flags")

    let text = try sbd.sb("group", "show", "Flags")

    #expect(!text.contains("Billing"), "\(text)")
    #expect(!text.contains("Retry payments."), "\(text)")
  }
}
