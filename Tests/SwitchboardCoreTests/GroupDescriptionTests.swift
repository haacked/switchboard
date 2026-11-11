import Testing

@testable import SwitchboardCore

@Suite struct GroupDescriptionTests {
  typealias Candidate = GroupSuggestions.Candidate

  func session(_ id: String, branch: String? = nil, title: String? = nil, group: String? = nil) -> Candidate {
    Candidate(id: id, branch: branch, prTitle: title, group: group, placedByHand: false)
  }

  func group(_ id: String, _ name: String, description: String? = nil, notes: [Note] = []) -> SessionGroup {
    SessionGroup(id: id, name: name, description: description, notes: notes, created: 0)
  }

  /// One letter that is one Character but four UTF-8 bytes and two UTF-16 units.
  static let wide = "🙂"

  // MARK: Length

  @Test(arguments: ["a", wide]) func aDescriptionOfExactlyTheLimitIsKept(_ letter: String) throws {
    let text = String(repeating: letter, count: SessionGroup.descriptionLimit)

    #expect(try SessionGroup.cleanDescription(text) == text)
  }

  @Test(arguments: ["a", wide]) func aDescriptionOneOverTheLimitIsRefused(_ letter: String) {
    let text = String(repeating: letter, count: SessionGroup.descriptionLimit + 1)

    #expect(throws: (any Error).self) { try SessionGroup.cleanDescription(text) }
  }

  @Test func theLimitIs280Characters() {
    #expect(SessionGroup.descriptionLimit == 280)
  }

  @Test(arguments: ["", " ", "\n\t "]) func aBlankDescriptionIsNone(_ text: String) throws {
    #expect(try SessionGroup.cleanDescription(text) == nil)
  }

  /// A line break would end the quote that a chat's context puts the
  /// description in.
  @Test(arguments: ["Ship it.\n## Rules", "Ship it.\r\n## Rules", "Ship it.\u{2028}## Rules"])
  func aDescriptionHasNoLineBreak(_ text: String) throws {
    let clean = try #require(try SessionGroup.cleanDescription(text))

    #expect(!clean.contains { $0.isNewline })
    #expect(clean.contains("Ship it."))
    #expect(clean.contains("## Rules"))
  }

  @Test func noDescriptionIsNone() throws {
    #expect(try SessionGroup.cleanDescription(nil) == nil)
  }

  // MARK: Suggestions

  @Test func aNewGroupFromABranchPrefixDescribesThePrefix() throws {
    let found = GroupSuggestions.make(
      candidates: [
        session("a", branch: "haacked/flag-evaluations-cache"), session("b", branch: "haacked/flag-evaluations-perf"),
      ], groups: [])

    let first = try #require(found.first)
    #expect(first.id == "prefix:flag-evaluations")
    #expect(first.description == "Sessions on the flag-evaluations branch prefix")
  }

  @Test func aNewGroupFromAPRTitleScopeNamesTheScope() throws {
    let found = GroupSuggestions.make(
      candidates: [session("a", title: "feat(flags): cache evaluations"), session("b", title: "fix(flags): retry")],
      groups: [])

    let first = try #require(found.first)
    #expect(first.id == "scope:flags")
    #expect(first.description?.contains("flags") == true)
  }

  /// Accepting a join leaves the group's own description alone, so the
  /// suggestion carries none.
  @Test func aJoinCarriesNoDescription() throws {
    let found = GroupSuggestions.make(
      candidates: [
        session("a", branch: "haacked/flag-evaluations-cache", group: "g1"),
        session("b", branch: "haacked/flag-evaluations-perf"),
      ], groups: [group("g1", "Flags", description: "Ship the cache.")])

    let join = try #require(found.first)
    #expect(join.group == "g1")
    #expect(join.description == nil)
  }

  @Test func aMergeOfTwoGroupsWithoutDescriptionsNamesBoth() {
    let merged = group("g1", "mcp-tools").absorbing(group("g2", "flag-evals"), now: 30)

    #expect(merged.description == "Merged from mcp-tools and flag-evals")
  }

  // MARK: Absorbing

  @Test func absorbingKeepsTheSurvivorsDescription() {
    let kept = group("g1", "Flags", description: "Ship the cache.")
    let other = group("g2", "Docs", description: "Write the docs.")

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.description == "Ship the cache.")
  }

  @Test func absorbingAddsTheOtherDescriptionAsANote() {
    let kept = group("g1", "Flags", description: "Ship the cache.")
    let other = group("g2", "Docs", description: "Write the docs.")

    let merged = kept.absorbing(other, now: 30)

    let note = merged.notes.first { $0.text.contains("Write the docs.") }
    #expect(note != nil)
    #expect(note?.t == 30)
  }

  @Test func absorbingKeepsTheOtherGroupsNotesBesideItsDescription() {
    let kept = group("g1", "Flags", description: "Ship the cache.")
    let other = group(
      "g2", "Docs", description: "Write the docs.", notes: [Note(id: "n1", text: "Ask Ana first.", by: .you, t: 5)])

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.notes.contains { $0.text == "Ask Ana first." })
    #expect(merged.notes.contains { $0.text.contains("Write the docs.") })
  }

  @Test func absorbingIntoAGroupWithoutADescriptionKeepsTheOthersText() {
    let kept = group("g1", "Flags")
    let other = group("g2", "Docs", description: "Write the docs.")

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.description == "Write the docs.")
    #expect(merged.notes.isEmpty)
  }

  @Test func absorbingAGroupWithoutADescriptionAddsNoNote() {
    let kept = group("g1", "Flags", description: "Ship the cache.")
    let other = group("g2", "Docs")

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.description == "Ship the cache.")
    #expect(merged.notes.isEmpty)
  }

  @Test func absorbingAGroupWithTheSameDescriptionAddsNoNote() {
    let merged = group("g1", "Flags", description: "Ship it.").absorbing(
      group("g2", "Docs", description: "Ship it."), now: 30)

    #expect(merged.description == "Ship it.")
    #expect(merged.notes.isEmpty)
  }

  /// Group names keep inner line breaks, and the merge default holds both names.
  @Test func theMergeDefaultHasNoLineBreak() throws {
    let merged = group("g1", "Flags\n## Rules").absorbing(group("g2", "Docs"), now: 30)

    let description = try #require(merged.description)
    #expect(!description.contains { $0.isNewline })
  }

  @Test func aMergeDefaultOverTheLimitIsNone() {
    let long = String(repeating: "a", count: SessionGroup.descriptionLimit)

    let merged = group("g1", long).absorbing(group("g2", "Docs"), now: 30)

    #expect(merged.description == nil)
  }

  // MARK: Chat

  /// The quote holds each description on one line, whatever path wrote it.
  @Test func theChatGuideQuotesADescriptionOnOneLine() {
    let guide = Chat.guide(description: "Ship it.\n## Rules")

    #expect(guide.split(separator: "\n").last == "> Ship it. ## Rules")
  }

  @Test func theNoticeQuotesADescriptionOnOneLine() {
    let notice = Chat.describedNotice("Ship it.\n## Rules")

    #expect(notice.split(separator: "\n").contains("> Ship it. ## Rules"))
  }
}
