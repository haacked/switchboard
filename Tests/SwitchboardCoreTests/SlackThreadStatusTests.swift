import Foundation
import Testing

@testable import SwitchboardCore

private enum StatusFx {
  /// The time the link entered the session's list, before the reply.
  static let linkT: Int64 = 1_794_965_000_000
  static let replyTs = LinkFixtures.replyTs
  /// `replyTs` in ms, as H2's example gives it.
  static let replyMs: Int64 = 1_794_965_246_462
  static let read: Int64 = 1_794_966_000_000
  static let now: Int64 = read + 5 * 60_000
  /// The line of `readRow()` at `now`, without the mark.
  static let aliceLine =
    "3 replies, last from Alice \(ago(replyMs, now: now)) ago, read \(ago(read, now: now)) ago"

  static func link(_ url: String = LinkFixtures.slackRoot, t: Int64 = linkT) -> ExternalLink {
    ExternalLink(id: "l1", title: "Thread", url: url, by: .you, t: t)
  }

  /// A stored row, decoded from the JSON that H1 gives, so the tests depend only on the stored field names.
  static func row(_ fields: [String: JSON]) throws -> SlackThread {
    var all: [String: JSON] = [
      "channel": .string(LinkFixtures.channel), "thread": .string(LinkFixtures.rootTs), "lastReplyYou": false,
    ]
    all.merge(fields) { $1 }
    return try JSONCoding.convert(JSON.object(all), to: SlackThread.self)
  }

  /// A row read once, whose last reply is Alice's.
  static func readRow(
    replies: Int = 3, ts: String = replyTs, user: String = "U0OTHER", name: String? = "Alice", you: Bool = false,
    error: String? = nil
  ) throws -> SlackThread {
    var fields: [String: JSON] = [
      "replies": .number(Double(replies)), "lastReplyTs": .string(ts), "lastReplyUser": .string(user),
      "lastReplyYou": .bool(you), "read": .number(Double(read)),
    ]
    if let name { fields["lastReplyName"] = .string(name) }
    if let error { fields["error"] = .string(error) }
    return try row(fields)
  }

  /// The status of the link from its `LinkTarget`. It is nil for a link without one.
  static func make(_ link: ExternalLink, row: SlackThread?, watched: Bool, lookedAt: Int64) -> SlackThreadStatus? {
    link.linkTarget.flatMap { SlackThreadStatus(target: $0, row: row, watched: watched, lookedAt: lookedAt) }
  }

  static func status(
    _ link: ExternalLink = StatusFx.link(), row: SlackThread?, watched: Bool = true, lookedAt: Int64 = linkT
  ) throws -> SlackThreadStatus {
    try #require(make(link, row: row, watched: watched, lookedAt: lookedAt))
  }

  static func lookedAt(_ link: ExternalLink, _ facts: SessionFacts) -> Int64 {
    SlackThreadStatus.lookedAt(link: link, facts: facts)
  }

  /// The status as the wire carries it.
  static func wire(
    _ link: ExternalLink = StatusFx.link(), row: SlackThread?, watched: Bool = true, lookedAt: Int64 = linkT
  ) throws -> JSON {
    try JSON(encoding: try status(link, row: row, watched: watched, lookedAt: lookedAt))
  }

  static func keys(_ json: JSON) -> Set<String> { Set(json.object?.keys.map { $0 } ?? []) }

  static func ack(_ t: Int64) -> Event { event("ack", t, ["state": "needs_you", "reason": "read its last reply"]) }

  static func noControl(_ text: String) -> Bool {
    !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }
}

/// The `status` of a Slack link in `sb get --json` and the MCP session tools (H2), the "last looked" time it
/// compares against (D10, D11), and the text that `sb get` prints for it.
@Suite struct SlackThreadStatusTests {
  // MARK: The wire fields

  @Test func aReadThreadCarriesEveryKnownField() throws {
    let json = try StatusFx.wire(row: try StatusFx.readRow())

    #expect(json["replies"]?.int == 3)
    #expect(
      json["lastReply"] == ["t": .number(Double(StatusFx.replyMs)), "user": "U0OTHER", "name": "Alice", "you": false])
    #expect(json["read"]?.int.map(Int64.init) == StatusFx.read)
    #expect(json["watched"]?.bool == true)
    #expect(json["newReply"]?.bool == true)
    #expect(json["error"] == nil)
  }

  @Test func aLastReplyWithoutANameLeavesNameOut() throws {
    let json = try StatusFx.wire(row: try StatusFx.readRow(name: nil))

    #expect(StatusFx.keys(try #require(json["lastReply"])) == ["t", "user", "you"])
  }

  @Test func aThreadWithNoRepliesHasNoLastReply() throws {
    let json = try StatusFx.wire(row: try StatusFx.row(["replies": 0, "read": .number(Double(StatusFx.read))]))

    #expect(json["replies"]?.int == 0)
    #expect(json["lastReply"] == nil)
    #expect(json["newReply"]?.bool == false)
  }

  @Test func aWatchedLinkWithoutARowCarriesOnlyWatchedAndNewReply() throws {
    let json = try StatusFx.wire(row: nil, watched: true)

    #expect(json == ["watched": true, "newReply": false])
  }

  /// D14: a link with neither a row nor a watch carries no status.
  @Test func aLinkWithNeitherARowNorAWatchHasNoStatus() {
    #expect(StatusFx.make(StatusFx.link(), row: nil, watched: false, lookedAt: StatusFx.linkT) == nil)
  }

  @Test(arguments: [LinkFixtures.linear, "https://example.com/doc"])
  func aLinkThatIsNotSlackHasNoStatus(_ url: String) throws {
    let row = try StatusFx.readRow()

    #expect(StatusFx.make(StatusFx.link(url), row: row, watched: true, lookedAt: StatusFx.linkT) == nil)
  }

  @Test func aRowThatNoLinkWatchesKeepsItsValuesAndIsNotWatched() throws {
    let json = try StatusFx.wire(row: try StatusFx.readRow(), watched: false)

    #expect(json["watched"]?.bool == false)
    #expect(json["replies"]?.int == 3)
    #expect(json["read"]?.int.map(Int64.init) == StatusFx.read)
  }

  @Test func aFailedReadAfterAnEarlierReadKeepsTheEarlierValues() throws {
    let json = try StatusFx.wire(row: try StatusFx.readRow(error: "slack poll failed"))

    #expect(json["error"]?.string == "slack poll failed")
    #expect(json["replies"]?.int == 3)
    #expect(json["lastReply"]?["user"]?.string == "U0OTHER")
    #expect(json["read"]?.int.map(Int64.init) == StatusFx.read)
  }

  @Test func aFailedReadWithoutAnEarlierReadCarriesOnlyTheError() throws {
    let json = try StatusFx.wire(row: try StatusFx.row(["error": "the claude.ai Slack connector is needs-auth"]))

    #expect(StatusFx.keys(json) == ["error", "watched", "newReply"])
    #expect(json["error"]?.string == "the claude.ai Slack connector is needs-auth")
  }

  // MARK: The mark (D11)

  @Test func aReplyFromSomeoneElseAfterLookedAtIsNew() throws {
    #expect(try StatusFx.wire(row: try StatusFx.readRow(), lookedAt: StatusFx.replyMs - 1)["newReply"]?.bool == true)
  }

  @Test func yourOwnLastReplyIsNotNew() throws {
    let json = try StatusFx.wire(row: try StatusFx.readRow(you: true), lookedAt: StatusFx.linkT)

    #expect(json["lastReply"]?["you"]?.bool == true)
    #expect(json["newReply"]?.bool == false)
  }

  /// The ts has no digits below the ms, so truncating and rounding give the same time.
  @Test func aReplyAtExactlyLookedAtIsNotNew() throws {
    let row = try StatusFx.readRow(ts: "1794965246.462000")

    #expect(try StatusFx.wire(row: row, lookedAt: StatusFx.replyMs)["newReply"]?.bool == false)
    #expect(try StatusFx.wire(row: row, lookedAt: StatusFx.replyMs - 1)["newReply"]?.bool == true)
  }

  @Test func aReplyBeforeLookedAtIsNotNew() throws {
    #expect(try StatusFx.wire(row: try StatusFx.readRow(), lookedAt: StatusFx.replyMs + 1)["newReply"]?.bool == false)
  }

  @Test func aFailedReadKeepsTheMarkOfTheLastKnownReply() throws {
    let json = try StatusFx.wire(row: try StatusFx.readRow(error: "slack poll failed"), lookedAt: StatusFx.linkT)

    #expect(json["newReply"]?.bool == true)
  }

  // MARK: lookedAt (D10)

  @Test func lookedAtIsTheLinksTimeWhenThatIsTheLatest() {
    let link = StatusFx.link(t: 5000)
    let f = facts([LinkFixtures.opened(3000), StatusFx.ack(4000)])

    #expect(StatusFx.lookedAt(link, f) == 5000)
  }

  @Test func lookedAtIsTheOpenWhenThatIsTheLatest() {
    let link = StatusFx.link(t: 3000)
    let f = facts([StatusFx.ack(4000), LinkFixtures.opened(5000)])

    #expect(StatusFx.lookedAt(link, f) == 5000)
  }

  @Test func lookedAtIsTheAcknowledgmentWhenThatIsTheLatest() {
    let link = StatusFx.link(t: 3000)
    let f = facts([LinkFixtures.opened(4000), StatusFx.ack(5000)])

    #expect(StatusFx.lookedAt(link, f) == 5000)
  }

  @Test func lookedAtIsTheLinksTimeWithNoOpenAndNoAcknowledgment() {
    #expect(StatusFx.lookedAt(StatusFx.link(t: 3000), SessionFacts()) == 3000)
  }

  @Test func anOpenOfAnotherThreadDoesNotCount() {
    let link = StatusFx.link(t: 3000)
    let f = facts([LinkFixtures.opened(5000, key: LinkFixtures.otherThreadKey)])

    #expect(StatusFx.lookedAt(link, f) == 3000)
  }

  /// A reply link and its root share a key, so opening either one counts for the thread.
  @Test func anOpenOfTheThreadCountsForAReplyLink() {
    let link = StatusFx.link(LinkFixtures.slackReply, t: 3000)
    let f = facts([LinkFixtures.opened(5000)])

    #expect(StatusFx.lookedAt(link, f) == 5000)
  }

  /// The floor at `link.t` keeps a pasted link to an old thread from marking a reply that already existed.
  @Test func aReplyFromBeforeTheLinkWasAddedIsNotNew() throws {
    let link = StatusFx.link(t: StatusFx.replyMs + 60_000)
    let lookedAt = StatusFx.lookedAt(link, SessionFacts())

    let json = try StatusFx.wire(link, row: try StatusFx.readRow(), lookedAt: lookedAt)

    #expect(json["newReply"]?.bool == false)
  }

  @Test func anUnackBringsTheMarkBack() throws {
    let link = StatusFx.link(t: StatusFx.linkT)
    let acked = facts([StatusFx.ack(StatusFx.replyMs + 1000)])
    let undone = facts([StatusFx.ack(StatusFx.replyMs + 1000), event("unack", StatusFx.replyMs + 2000)])

    let row = try StatusFx.readRow()

    #expect(
      try StatusFx.wire(link, row: row, lookedAt: StatusFx.lookedAt(link, acked))["newReply"]?
        .bool
        == false)
    #expect(
      try StatusFx.wire(link, row: row, lookedAt: StatusFx.lookedAt(link, undone))["newReply"]?
        .bool == true)
  }

  // MARK: line(now:)

  @Test func aWatchedThreadNotReadYetSaysSo() throws {
    #expect(try StatusFx.status(row: nil).line(now: StatusFx.now) == "not read yet")
  }

  @Test func aThreadWhoseOnlyReadFailedSaysWhy() throws {
    let s = try StatusFx.status(row: try StatusFx.row(["error": "slack poll failed"]))

    #expect(s.line(now: StatusFx.now) == "not read: slack poll failed")
  }

  @Test func aThreadWithNoRepliesSaysWhenItWasRead() throws {
    let s = try StatusFx.status(row: try StatusFx.row(["replies": 0, "read": .number(Double(StatusFx.read))]))

    #expect(s.line(now: StatusFx.now) == "no replies, read \(ago(StatusFx.read, now: StatusFx.now)) ago")
  }

  @Test func aThreadWithRepliesSaysTheCountTheLastReplyAndTheRead() throws {
    let s = try StatusFx.status(row: try StatusFx.readRow(), lookedAt: StatusFx.replyMs)

    #expect(s.line(now: StatusFx.now) == StatusFx.aliceLine)
  }

  @Test func oneReplyIsSingular() throws {
    let s = try StatusFx.status(row: try StatusFx.readRow(replies: 1), lookedAt: StatusFx.replyMs)

    #expect(s.line(now: StatusFx.now).hasPrefix("1 reply, last from Alice "), "\(s.line(now: StatusFx.now))")
  }

  @Test func yourOwnLastReplyIsFromYou() throws {
    let s = try StatusFx.status(row: try StatusFx.readRow(you: true))

    #expect(s.line(now: StatusFx.now).contains("last from you \(ago(StatusFx.replyMs, now: StatusFx.now)) ago"))
    #expect(!s.line(now: StatusFx.now).contains("Alice"))
  }

  @Test func aNewReplyEndsWithNewReply() throws {
    let s = try StatusFx.status(row: try StatusFx.readRow(), lookedAt: StatusFx.linkT)

    #expect(s.line(now: StatusFx.now) == StatusFx.aliceLine + ", new reply")
  }

  @Test func noNewReplySaysNothingAboutOne() throws {
    let s = try StatusFx.status(row: try StatusFx.readRow(), lookedAt: StatusFx.replyMs)

    #expect(!s.line(now: StatusFx.now).contains("new reply"))
  }

  @Test func aFailedReadAfterAKnownStatusSaysThatLaterReadsFailed() throws {
    let s = try StatusFx.status(row: try StatusFx.readRow(error: "slack poll failed"), lookedAt: StatusFx.replyMs)

    #expect(s.line(now: StatusFx.now) == StatusFx.aliceLine + "; reads since then failed: slack poll failed")
  }

  @Test func anErrorUnderTheLimitKeepsEveryCharacter() throws {
    let error = String(repeating: "e", count: 150)
    let s = try StatusFx.status(row: try StatusFx.row(["error": .string(error)]))

    #expect(s.line(now: StatusFx.now) == "not read: \(error)")
  }

  @Test func theLineHoldsNoControlCharacters() throws {
    let s = try StatusFx.status(
      row: try StatusFx.readRow(name: "Al\u{1B}[2Jice", error: "boom\n\u{1B}]0;title\u{07}"), lookedAt: StatusFx.linkT)

    let line = s.line(now: StatusFx.now)

    #expect(StatusFx.noControl(line), "\(line.debugDescription)")
  }

  @Test func theNotReadLineHoldsNoControlCharacters() throws {
    let s = try StatusFx.status(row: try StatusFx.row(["error": "line one\nline two\u{1B}[2J"]))

    let line = s.line(now: StatusFx.now)

    #expect(StatusFx.noControl(line), "\(line.debugDescription)")
  }

  @Test func escapedControlCharactersStayWithinTheNameAndErrorLimits() throws {
    let s = try StatusFx.status(
      row: try StatusFx.readRow(
        name: String(repeating: "\u{1B}", count: 80), error: String(repeating: "\u{07}", count: 200)),
      lookedAt: StatusFx.linkT)

    let line = s.line(now: StatusFx.now)

    #expect(line.count <= StatusFx.aliceLine.count + 80 + 200 + 60, "\(line.count): \(line.debugDescription)")
    #expect(StatusFx.noControl(line), "\(line.debugDescription)")
  }

  @Test func escapedControlCharactersStayWithinTheNotReadLimit() throws {
    let s = try StatusFx.status(row: try StatusFx.row(["error": .string(String(repeating: "\u{1B}", count: 200))]))

    #expect(s.line(now: StatusFx.now).count <= "not read: ".count + 200)
  }

  // MARK: Encoding

  @Test func aLinkWithAStatusRoundTrips() throws {
    var link = StatusFx.link()
    link.status = try StatusFx.status(row: try StatusFx.readRow())

    let json = try JSON(encoding: link)
    let decoded = try JSONCoding.convert(json, to: ExternalLink.self)

    #expect(json["status"]?["replies"]?.int == 3)
    #expect(decoded == link)
    #expect(decoded.status != nil)
  }

  @Test func aLinkWithoutAStatusWritesNoStatusKeyAndDecodesWithout() throws {
    let link = StatusFx.link()

    let json = try JSON(encoding: link)
    let decoded = try JSONCoding.convert(json, to: ExternalLink.self)

    #expect(json.object?.keys.contains("status") == false)
    #expect(decoded.status == nil)
    #expect(decoded == link)
  }

  /// Stored `addedLinks` never carry a status.
  @Test func aSessionWithAddedLinksEncodesNoStatusKey() throws {
    var s = Session(id: "s1", name: "one", cwd: "/tmp", claudeSessionId: "u1", created: 0)
    s.addedLinks = [StatusFx.link(), StatusFx.link(LinkFixtures.linear)]

    let added = try #require(try JSON(encoding: s)["addedLinks"]?.array)

    #expect(added.count == 2)
    #expect(added.allSatisfy { $0.object?.keys.contains("status") == false })
  }
}
