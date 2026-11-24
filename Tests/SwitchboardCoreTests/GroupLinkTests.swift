import Testing

@testable import SwitchboardCore

/// A group's links and the author of its description, as `SessionGroup` holds
/// them and as a merge carries them over.
@Suite struct GroupLinkTests {
  func group(
    _ id: String, _ name: String, description: String? = nil, by author: Author? = nil, links: [ExternalLink]? = nil
  ) -> SessionGroup {
    var g = SessionGroup(id: id, name: name, description: description, created: 0)
    g.descriptionBy = author
    g.links = links
    return g
  }

  func link(_ id: String, _ url: String, title: String? = nil, by author: LinkAuthor = .you, t: Int64 = 1)
    -> ExternalLink
  {
    ExternalLink(id: id, title: title ?? url, url: url, by: author, t: t)
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
    let url = Self.url(ofLength: ExternalLink.titleLimit)

    #expect(try ExternalLink.cleanTitle(title, url: url) == url)
  }

  /// A session reads the title, so a long URL doesn't make the title pass its limit.
  @Test(arguments: [ExternalLink.titleLimit + 1, ExternalLink.urlLimit])
  func aURLOverTheTitleLimitIsCutForTheTitle(_ length: Int) throws {
    let url = Self.url(ofLength: length)

    let title = try ExternalLink.cleanTitle(nil, url: url)

    #expect(title.count == ExternalLink.titleLimit)
    #expect(title.hasSuffix("…"))
    #expect(url.hasPrefix(title.dropLast()))
  }

  @Test func aGivenTitleOverTheLimitIsRefused() {
    let title = String(repeating: "a", count: ExternalLink.titleLimit + 1)

    #expect(throws: (any Error).self) { try ExternalLink.cleanTitle(title, url: "https://a.example") }
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
    #expect(try ExternalLink.cleanURL(url) == expected)
  }

  @Test(arguments: [
    "https://example.com/a#b", "https://example.com/a/", "http://claude.ai/artifact/\(artifactShortId)",
    "https://claude.ai/chat/\(artifactShortId)", "https://claude.ai.evil.com/artifact/\(artifactShortId)",
  ])
  func cleanURLLeavesALinkThatIsNotAClaudeArtifactAsGiven(_ url: String) throws {
    #expect(try ExternalLink.cleanURL(url) == url)
  }

  // MARK: User and password parts

  /// URLs whose host as shown differs from the host they open, or that carry credentials.
  static let userinfoURLs = [
    "https://example.slack.com@evil.example/archives/C0EXAMPLE01/p1794965000000100",
    "https://user:pass@example.com/", "https://user@example.com", "http://user@example.com/rfcs",
    "https://:pass@example.com/", "https://user:@example.com/", "https://USER@Example.com:8443/rfcs",
    "https://user%40corp@example.com/", "https://claude.ai@evil.com/artifact/\(artifactShortId)",
  ]

  @Test(arguments: userinfoURLs) func cleanURLRefusesAUserOrPasswordPart(_ url: String) {
    let message = refusal { try ExternalLink.cleanURL(url) } ?? "no error"

    #expect(message.contains("can't hold a user name or password"), "\(url): \(message)")
  }

  /// Foundation may refuse a backslash before the userinfo check runs, so this test takes any refusal.
  @Test func cleanURLRefusesABackslashBeforeAnAt() {
    #expect(throws: (any Error).self) { try ExternalLink.cleanURL(#"https://claude.ai\@evil.com/artifact/x"#) }
  }

  /// An `@` outside the authority is no user part.
  @Test(arguments: [
    "https://example.com/users/@ana", "https://example.com/rfcs?by=ana@example.com",
    "https://example.com/rfcs#ana@example.com", "https://example.com:8443/rfcs",
  ])
  func cleanURLKeepsAnAtOutsideTheHost(_ url: String) throws {
    #expect(try ExternalLink.cleanURL(url) == url)
  }

  @Test func cleanURLAcceptsALookAlikeSlackHostAndItsLinkIsWeb() throws {
    let url = "https://example.slack.com.evil.example/archives/C0EXAMPLE01/p1794965000000100"

    let cleaned = try ExternalLink.cleanURL(url)

    #expect(cleaned == url)
    #expect(ExternalLink(id: "l1", title: url, url: cleaned, by: .you, t: 1).kind == .web)
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

  // MARK: Kind, channel, and thread

  static let rfc = "https://example.com/rfcs/flag-evaluations"
  static let storedKeys: Set<String> = ["id", "title", "url", "by", "t"]

  /// The link's JSON as `JSONCoding` writes it, for groups on disk and on the wire alike.
  func encoded(_ link: ExternalLink) throws -> [String: JSON] {
    try #require(JSON.parse(try JSONCoding.encode(link))?.object)
  }

  /// A group that main stored has links with the five stored keys and `by` of `you` or `claude`.
  @Test func aGroupStoredByMainDecodesItsLinksUnchanged() throws {
    let stored =
      #"{"id":"g1","name":"Flags","notes":[],"created":0,"links":["#
      + #"{"id":"l1","title":"Flags RFC","url":"https://example.com/rfcs/flag-evaluations","by":"you","t":7},"#
      + #"{"id":"l2","title":"https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv","#
      + #""url":"https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv","by":"claude","t":9}]}"#

    let g = try JSONCoding.decode(SessionGroup.self, from: stored)

    #expect(
      g.links == [
        ExternalLink(id: "l1", title: "Flags RFC", url: Self.rfc, by: .you, t: 7),
        ExternalLink(id: "l2", title: artifactShortURL, url: artifactShortURL, by: .claude, t: 9),
      ])
    #expect(g.links?.first?.by == .you)
  }

  @Test func aStoredFoundLinkDecodesAsFound() throws {
    let stored =
      #"{"id":"fab2cd","title":"Linear ENG-123","url":"https://linear.app/example/issue/ENG-123","by":"found","t":3}"#

    let link = try JSONCoding.decode(ExternalLink.self, from: stored)

    #expect(link.by == .found)
  }

  /// Decoding ignores a stored `kind`, `channel`, and `thread`. The URL alone gives them.
  @Test func aStoredKindChannelAndThreadAreIgnoredOnDecode() throws {
    let stored =
      #"{"id":"l1","title":"RFC","url":"https://example.com/rfcs/flag-evaluations","by":"you","t":7,"#
      + #""kind":"slack","channel":"C0EXAMPLE01","thread":"1794965000.000100"}"#

    let link = try JSONCoding.decode(ExternalLink.self, from: stored)

    #expect(link == ExternalLink(id: "l1", title: "RFC", url: Self.rfc, by: .you, t: 7))
    #expect(link.kind == .web)
    #expect(link.linkTarget?.channel == nil)
    #expect(link.linkTarget?.thread == nil)
  }

  @Test func aSlackLinksChannelAndThreadComeFromItsURL() {
    let link = ExternalLink(id: "l1", title: "Thread", url: LinkFixtures.slackReply, by: .you, t: 1)

    #expect(link.kind == .slack)
    #expect(link.linkTarget?.channel == LinkFixtures.channel)
    #expect(link.linkTarget?.thread == LinkFixtures.rootTs)
  }

  @Test func anEncodedSlackLinkHasExactlyTheStoredKeysAndKindChannelThread() throws {
    let link = ExternalLink(id: "l1", title: "Thread", url: LinkFixtures.slackReply, by: .you, t: 1)

    let json = try encoded(link)

    #expect(Set(json.keys) == Self.storedKeys.union(["kind", "channel", "thread"]))
    #expect(json["kind"]?.string == "slack")
    #expect(json["channel"]?.string == LinkFixtures.channel)
    #expect(json["thread"]?.string == LinkFixtures.rootTs)
  }

  @Test func anEncodedRFCLinkIsWebWithoutChannelOrThread() throws {
    let link = ExternalLink(id: "l1", title: "RFC", url: Self.rfc, by: .you, t: 7)

    let json = try encoded(link)

    #expect(Set(json.keys) == Self.storedKeys.union(["kind"]))
    #expect(json["kind"]?.string == "web")
  }

  /// The kind list has no `artifact`, so a claude.ai artifact link is `web`.
  @Test(arguments: [artifactShortURL, artifactCodeURL]) func anArtifactLinkIsWeb(_ url: String) throws {
    let link = ExternalLink(id: "l1", title: url, url: url, by: .claude, t: 7)

    let json = try encoded(link)

    #expect(link.kind == .web)
    #expect(json["kind"]?.string == "web")
    #expect(Set(json.keys) == Self.storedKeys.union(["kind"]))
  }

  @Test(arguments: [
    (LinkFixtures.linear, "linear"), (LinkFixtures.notion, "notion"), (LinkFixtures.google, "google"),
    (LinkFixtures.grafana, "grafana"), (LinkFixtures.githubPR, "web"),
  ])
  func anEncodedLinkOfAnotherKindHasItsKindAndNoChannelOrThread(_ url: String, _ kind: String) throws {
    let json = try encoded(ExternalLink(id: "l1", title: "Page", url: url, by: .you, t: 7))

    #expect(json["kind"]?.string == kind)
    #expect(Set(json.keys) == Self.storedKeys.union(["kind"]))
  }

  @Test(arguments: [
    ExternalLink(id: "l1", title: "Thread", url: LinkFixtures.slackReply, by: .you, t: 1),
    ExternalLink(id: "l2", title: "RFC", url: "https://example.com/rfcs/flag-evaluations", by: .you, t: 7),
    ExternalLink(id: "l3", title: artifactShortURL, url: artifactShortURL, by: .claude, t: 9),
    ExternalLink(id: "fab2cd", title: "Linear ENG-123", url: LinkFixtures.linear, by: .found, t: 11),
  ])
  func aLinkSurvivesEncoding(_ link: ExternalLink) throws {
    let decoded = try JSONCoding.decode(ExternalLink.self, from: try JSONCoding.encode(link))

    #expect(decoded == link)
  }

  /// A group that sbd saves after this change writes `kind` into its stored JSON, and decodes back equal.
  @Test func aGroupWithASlackLinkWritesItsKindAndDecodesEqual() throws {
    let g = group(
      "g1", "Flags", links: [ExternalLink(id: "l1", title: "Thread", url: LinkFixtures.slackRoot, by: .you, t: 1)])

    let text = try JSONCoding.encode(g)

    let link = try #require(JSON.parse(text)?["links"]?.array?.first)
    #expect(link["kind"]?.string == "slack")
    #expect(link["thread"]?.string == LinkFixtures.rootTs)
    #expect(try JSONCoding.decode(SessionGroup.self, from: text) == g)
  }

  @Test func aGroupSummaryWritesTheKindOfEachLink() throws {
    let g = group(
      "g1", "Flags",
      links: [
        ExternalLink(id: "l1", title: "Thread", url: LinkFixtures.slackRoot, by: .you, t: 1),
        ExternalLink(id: "l2", title: "RFC", url: Self.rfc, by: .you, t: 2),
      ])

    let json = try #require(JSON.parse(try JSONCoding.encode(GroupSummary(g, sessions: []))))

    #expect(json["links"]?.array?.compactMap { $0["kind"]?.string } == ["slack", "web"])
  }
}
