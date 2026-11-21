import Testing

@testable import SwitchboardCore

/// A group's links and the author of its description, as `SessionGroup` holds
/// them and as a merge carries them over.
@Suite struct GroupLinkTests {
  func group(
    _ id: String, _ name: String, description: String? = nil, by author: Author? = nil, links: [GroupLink]? = nil
  ) -> SessionGroup {
    var g = SessionGroup(id: id, name: name, description: description, created: 0)
    g.descriptionBy = author
    g.links = links
    return g
  }

  func link(_ id: String, _ url: String, title: String? = nil, by author: Author = .you, t: Int64 = 1) -> GroupLink {
    GroupLink(id: id, title: title ?? url, url: url, by: author, t: t)
  }

  // MARK: Links in a merge

  @Test func absorbingKeepsThisGroupsLinksThenAddsTheOthers() {
    let kept = group("g1", "Flags", links: [link("l1", "https://a.example"), link("l2", "https://b.example")])
    let other = group("g2", "Docs", links: [link("l3", "https://c.example"), link("l4", "https://d.example")])

    let merged = kept.absorbing(other, now: 30)

    #expect(
      merged.links?.map(\.url) == ["https://a.example", "https://b.example", "https://c.example", "https://d.example"])
  }

  @Test func absorbingSkipsALinkWhoseURLThisGroupHasAndKeepsThisGroupsTitle() {
    let kept = group("g1", "Flags", links: [link("l1", "https://rfc.example/1", title: "Flags RFC")])
    let other = group("g2", "Docs", links: [link("l2", "https://rfc.example/1", title: "The RFC")])

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.links == [link("l1", "https://rfc.example/1", title: "Flags RFC")])
  }

  @Test func absorbingAddsTheOthersLinksAroundADuplicateURL() {
    let kept = group("g1", "Flags", links: [link("l1", "https://b.example")])
    let other = group(
      "g2", "Docs",
      links: [link("l2", "https://a.example"), link("l3", "https://b.example"), link("l4", "https://c.example")])

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.links?.map(\.url) == ["https://b.example", "https://a.example", "https://c.example"])
    #expect(merged.links?.map(\.id) == ["l1", "l2", "l4"])
  }

  @Test func anAbsorbedLinkWhoseIdIsTakenGetsANewId() throws {
    let mine = link("l1", "https://a.example", title: "Mine", by: .you, t: 5)
    let theirs = link("l1", "https://b.example", title: "Theirs", by: .claude, t: 9)
    let kept = group("g1", "Flags", links: [mine])

    let merged = kept.absorbing(group("g2", "Docs", links: [theirs]), now: 30)

    let links = try #require(merged.links)
    #expect(links.first == mine)
    let absorbed = try #require(links.first { $0.url == "https://b.example" })
    #expect(absorbed.id != "l1")
    #expect(absorbed.title == "Theirs")
    #expect(absorbed.by == .claude)
    #expect(absorbed.t == 9)
  }

  /// Each absorbed id is checked against the ids already merged, so a new id
  /// can't collide with a later link of either group.
  @Test func everyMergedLinkHasADistinctId() throws {
    let kept = group("g1", "Flags", links: [link("la", "https://a.example"), link("lb", "https://b.example")])
    let other = group(
      "g2", "Docs",
      links: [link("la", "https://c.example"), link("lb", "https://d.example"), link("lc", "https://e.example")])

    let merged = kept.absorbing(other, now: 30)

    let ids = try #require(merged.links).map(\.id)
    #expect(ids.count == 5)
    #expect(Set(ids).count == ids.count)
  }

  /// A link whose URL this group has is skipped before its id matters, so it
  /// doesn't come back under a new id.
  @Test func aDuplicateURLWithATakenIdIsSkippedNotRenamed() {
    let kept = group("g1", "Flags", links: [link("l1", "https://a.example", title: "Mine")])
    let other = group("g2", "Docs", links: [link("l1", "https://a.example", title: "Theirs")])

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.links == [link("l1", "https://a.example", title: "Mine")])
  }

  @Test func absorbingIntoAGroupWithoutLinksTakesTheOthers() {
    let theirs = [link("l1", "https://a.example"), link("l2", "https://b.example")]

    let merged = group("g1", "Flags").absorbing(group("g2", "Docs", links: theirs), now: 30)

    #expect(merged.links == theirs)
  }

  @Test func absorbingAGroupWithoutLinksKeepsThisGroupsLinks() {
    let mine = [link("l1", "https://a.example")]

    let merged = group("g1", "Flags", links: mine).absorbing(group("g2", "Docs"), now: 30)

    #expect(merged.links == mine)
  }

  @Test func absorbingBetweenGroupsWithoutLinksLeavesNone() {
    let merged = group("g1", "Flags").absorbing(group("g2", "Docs", links: []), now: 30)

    #expect((merged.links ?? []).isEmpty)
  }

  // MARK: The description's author in a merge

  @Test(arguments: [Author.you, .claude, nil])
  func takingTheOthersDescriptionTakesItsAuthor(_ author: Author?) {
    let other = group("g2", "Docs", description: "Write the docs.", by: author)

    let merged = group("g1", "Flags").absorbing(other, now: 30)

    #expect(merged.description == "Write the docs.")
    #expect((merged.descriptionBy ?? .you) == (author ?? .you))
  }

  @Test(arguments: [(Author.claude, Author.you), (.you, .claude), (.claude, .claude)])
  func keepingThisGroupsDescriptionKeepsItsAuthor(_ mine: Author, _ theirs: Author) {
    let kept = group("g1", "Flags", description: "Ship the cache.", by: mine)
    let other = group("g2", "Docs", description: "Write the docs.", by: theirs)

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.description == "Ship the cache.")
    #expect(merged.descriptionBy == mine)
  }

  @Test func aDescriptionWithNoRecordedAuthorStaysYoursInAMerge() {
    let kept = group("g1", "Flags", description: "Ship the cache.")
    let other = group("g2", "Docs", description: "Write the docs.", by: .claude)

    let merged = kept.absorbing(other, now: 30)

    #expect((merged.descriptionBy ?? .you) == .you)
  }

  @Test(arguments: [(Author?.some(.claude), Author.claude), (.some(.you), .you), (nil, .you)])
  func theNoteOfTheOthersDescriptionIsByItsAuthor(_ theirs: Author?, _ expected: Author) throws {
    let kept = group("g1", "Flags", description: "Ship the cache.", by: .you)
    let other = group("g2", "Docs", description: "Write the docs.", by: theirs)

    let merged = kept.absorbing(other, now: 30)

    let note = try #require(merged.notes.first { $0.text.contains("Write the docs.") })
    #expect(note.by == expected)
  }

  @Test func theNoteOfAClaudeDescriptionIsByClaudeWhenThisGroupsIsByClaudeToo() throws {
    let kept = group("g1", "Flags", description: "Ship the cache.", by: .claude)
    let other = group("g2", "Docs", description: "Write the docs.", by: .claude)

    let merged = kept.absorbing(other, now: 30)

    let note = try #require(merged.notes.first { $0.text.contains("Write the docs.") })
    #expect(note.by == .claude)
  }

  @Test func theSameDescriptionAddsNoNoteAndKeepsThisGroupsAuthor() {
    let kept = group("g1", "Flags", description: "Ship it.", by: .you)
    let other = group("g2", "Docs", description: "Ship it.", by: .claude)

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.notes.isEmpty)
    #expect(merged.descriptionBy == .you)
  }

  // MARK: Storage and summaries

  /// A group that an older sbd stored has neither field.
  @Test func aGroupStoredWithoutTheNewFieldsDecodesWithNeither() throws {
    let stored = #"{"id":"g1","name":"Flags","description":"Ship it.","notes":[],"created":0}"#

    let g = try JSONCoding.decode(SessionGroup.self, from: stored)

    #expect(g.description == "Ship it.")
    #expect(g.descriptionBy == nil)
    #expect(g.links == nil)
  }

  @Test func aGroupWithLinksAndAnAuthorSurvivesEncoding() throws {
    let g = group(
      "g1", "Flags", description: "Ship it.", by: .claude,
      links: [link("l1", "https://a.example", title: "RFC", by: .you, t: 7)])

    let encoded = try JSONCoding.encode(g)
    let decoded = try JSONCoding.decode(SessionGroup.self, from: encoded)

    #expect(decoded == g)
  }

  @Test func aSummaryCarriesTheLinksAndTheDescriptionsAuthor() {
    let links = [link("l1", "https://a.example", title: "RFC")]
    let g = group("g1", "Flags", description: "Ship it.", by: .claude, links: links)

    let summary = GroupSummary(g, sessions: [])

    #expect(summary.descriptionBy == .claude)
    #expect(summary.links == links)
  }

  // MARK: Titles

  /// An https URL of exactly `count` characters.
  static func url(ofLength count: Int) -> String {
    let base = "https://example.com/"
    return base + String(repeating: "a", count: count - base.count)
  }

  @Test(arguments: [nil, "", "  \n "]) func withoutATitleTheTitleIsTheURL(_ title: String?) throws {
    let url = Self.url(ofLength: GroupLink.titleLimit)

    #expect(try GroupLink.cleanTitle(title, url: url) == url)
  }

  /// A session reads the title, so a long URL doesn't make the title pass its limit.
  @Test(arguments: [GroupLink.titleLimit + 1, GroupLink.urlLimit])
  func aURLOverTheTitleLimitIsCutForTheTitle(_ length: Int) throws {
    let url = Self.url(ofLength: length)

    let title = try GroupLink.cleanTitle(nil, url: url)

    #expect(title.count == GroupLink.titleLimit)
    #expect(title.hasSuffix("…"))
    #expect(url.hasPrefix(title.dropLast()))
  }

  @Test func aGivenTitleOverTheLimitIsRefused() {
    let title = String(repeating: "a", count: GroupLink.titleLimit + 1)

    #expect(throws: (any Error).self) { try GroupLink.cleanTitle(title, url: "https://a.example") }
  }

  // MARK: Links to claude.ai artifacts

  @Test(arguments: [
    ("\(artifactShortURL)#section-2", artifactShortURL),
    ("\(artifactShortURL)?tab=preview", artifactShortURL),
    ("\(artifactShortURL)/", artifactShortURL),
    ("https://claude.ai//artifact/\(artifactShortId)", artifactShortURL),
    ("https://CLAUDE.AI/artifact/\(artifactShortId)", artifactShortURL),
    ("  \(artifactShortURL)#top \n", artifactShortURL),
    ("\(artifactCodeURL)/?x=1#y", artifactCodeURL),
  ])
  func cleanURLNormalizesAClaudeArtifactLink(_ url: String, _ expected: String) throws {
    #expect(try GroupLink.cleanURL(url) == expected)
  }

  @Test(arguments: [
    "https://example.com/a#b", "https://example.com/a/", "http://claude.ai/artifact/\(artifactShortId)",
    "https://claude.ai/chat/\(artifactShortId)", "https://claude.ai.evil.com/artifact/\(artifactShortId)",
  ])
  func cleanURLLeavesALinkThatIsNotAClaudeArtifactAsGiven(_ url: String) throws {
    #expect(try GroupLink.cleanURL(url) == url)
  }

  /// Links already stored keep their form, so `addLink` compares artifact links by their normalized form.
  @Test(arguments: [
    (artifactShortURL, "\(artifactShortURL)#frag"),
    ("\(artifactShortURL)/", artifactShortURL),
    (artifactShortURL, "https://Claude.ai/artifact/\(artifactShortId)"),
    ("\(artifactShortURL)?tab=preview", "\(artifactShortURL)#top"),
    (artifactCodeURL, "\(artifactCodeURL)/"),
  ])
  func addLinkRefusesASecondFormOfTheSameArtifact(_ stored: String, _ added: String) {
    var g = group("g1", "Flags", links: [link("l1", stored)])

    let result = g.addLink(link("l2", added))

    #expect(!result)
    #expect(g.links?.map(\.id) == ["l1"])
  }

  /// sbd cannot tell that a short link and a code link name one page. Links that are not artifacts, an `http`
  /// claude.ai link among them, compare exactly.
  @Test(arguments: [
    (artifactShortURL, artifactCodeURL),
    ("https://example.com/a#b", "https://example.com/a"),
    ("http://claude.ai/artifact/\(artifactShortId)", artifactShortURL),
  ])
  func addLinkAddsALinkThatNamesAnotherURL(_ stored: String, _ added: String) {
    var g = group("g1", "Flags", links: [link("l1", stored)])

    let result = g.addLink(link("l2", added))

    #expect(result)
    #expect(g.links?.map(\.url) == [stored, added])
  }

  /// `absorbing` adds each link through `addLink`, so both refuse the same links.
  @Test(arguments: [
    (artifactShortURL, "\(artifactShortURL)#frag"),
    ("\(artifactShortURL)/", artifactShortURL),
    (artifactShortURL, artifactCodeURL),
    ("https://example.com/a#b", "https://example.com/a"),
    ("https://example.com/a", "https://example.com/a"),
    ("http://claude.ai/artifact/\(artifactShortId)", artifactShortURL),
  ])
  func absorbingRefusesTheLinksThatAddLinkRefuses(_ stored: String, _ incoming: String) {
    var g = group("g1", "Flags", links: [link("l1", stored)])
    let added = g.addLink(link("l2", incoming))

    let merged = group("g1", "Flags", links: [link("l1", stored)]).absorbing(
      group("g2", "Docs", links: [link("l2", incoming)]), now: 30)

    #expect(merged.links?.count == (added ? 2 : 1))
  }

  /// A merge keeps your titled link over Claude's link to the same artifact, in either direction.
  @Test(arguments: [false, true])
  func absorbingKeepsYourLinkOverClaudesLinkToTheSameArtifact(_ yoursInKept: Bool) {
    let yours = link("l1", artifactShortURL + "#top", title: "Tracker")
    let claudes = link("l2", artifactShortURL, by: .claude)

    let merged = group("g1", "Flags", links: [yoursInKept ? yours : claudes]).absorbing(
      group("g2", "Docs", links: [yoursInKept ? claudes : yours]), now: 30)

    #expect(merged.links?.map(\.title) == ["Tracker"])
    #expect(merged.links?.map(\.by) == [.you])
  }
}
