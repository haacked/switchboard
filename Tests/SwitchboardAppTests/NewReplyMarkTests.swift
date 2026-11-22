import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000
private let hour: Int64 = 3_600_000

private let markLabel = "New Slack reply"
private let markHelp = "Someone replied in a Slack thread since you last looked"

private func slackLink(_ id: String, status: SlackThreadStatus?) -> ExternalLink {
  var link = ExternalLink(
    id: id, title: "Slack thread in C0123ABCD", url: "https://acme.slack.com/archives/C0123ABCD/p1700000000123456",
    by: .found, t: now - 3 * hour)
  link.status = status
  return link
}

private func newReply(_ value: Bool, watched: Bool = true) throws -> SlackThreadStatus {
  try slackStatusFixture(
    replies: 1, lastReply: LastReplyFixture(t: now - hour), read: now - 60_000, watched: watched, newReply: value)
}

private func session(_ links: [ExternalLink]?, id: String = "a") -> SessionSummary {
  var s = needsItem(id)
  s.links = links
  return s
}

@Suite struct NewReplyMarkTests {
  // MARK: SessionSummary.hasNewReply

  @Suite struct HasNewReply {
    @Test func aSessionWithoutLinksHasNoNewReply() {
      #expect(!session(nil).hasNewReply)
    }

    @Test func aSessionWithAnEmptyLinkListHasNoNewReply() {
      #expect(!session([]).hasNewReply)
    }

    @Test func aLinkWithoutAStatusGivesNoNewReply() {
      #expect(!session([slackLink("l1", status: nil)]).hasNewReply)
    }

    @Test func aStatusWithoutANewReplyGivesNoNewReply() throws {
      #expect(!session([slackLink("l1", status: try newReply(false))]).hasNewReply)
    }

    @Test func aStatusBeforeTheFirstReadGivesNoNewReply() throws {
      #expect(!session([slackLink("l1", status: try slackStatusFixture())]).hasNewReply)
    }

    @Test func aStatusWithANewReplyGivesANewReply() throws {
      #expect(session([slackLink("l1", status: try newReply(true))]).hasNewReply)
    }

    /// Any link counts, not only the first or the newest.
    @Test(arguments: 0..<3)
    func aNewReplyOnAnyOfSeveralLinksGivesANewReply(_ marked: Int) throws {
      let links = try (0..<3).map { i in
        slackLink("l\(i)", status: try newReply(i == marked))
      }

      #expect(session(links).hasNewReply)
    }

    @Test func noNewReplyOnAnyOfSeveralLinksGivesNoNewReply() throws {
      let links = [
        slackLink("l1", status: try newReply(false)), slackLink("l2", status: nil),
        slackLink("l3", status: try slackStatusFixture(error: "slack poll failed")),
      ]

      #expect(!session(links).hasNewReply)
    }

    /// sbd stops reading a thread 3 days after its link entered the list. A reply that it read before then stays new
    /// until the user looks.
    @Test func aNewReplyOnAThreadNoLongerWatchedStillCounts() throws {
      #expect(session([slackLink("l1", status: try newReply(true, watched: false))]).hasNewReply)
    }

    /// The app decodes the session list that sbd encodes.
    @Test func aNewReplyKeepsThroughSbdsJSON() throws {
      let sent = session([slackLink("l1", status: try newReply(true))])

      let decoded = try JSONCoding.convert(sent, to: SessionSummary.self)

      #expect(decoded.hasNewReply)
    }
  }

  // MARK: The mark's text

  @Suite struct MarkText {
    @Test func theTooltipSaysSomeoneRepliedSinceYouLastLooked() {
      #expect(NewReplyMark.help == markHelp)
    }

    @Test func theAccessibilityLabelSaysNewSlackReply() {
      #expect(NewReplyMark.label == markLabel)
    }

    @Test func theSymbolResolves() {
      #expect(NSImage(systemSymbolName: NewReplyMark.symbol, accessibilityDescription: markLabel) != nil)
    }
  }

  // MARK: Where the mark shows

  @MainActor
  @Suite struct Placement {
    static func hasMark(_ hosted: HostedView) -> Bool {
      hosted.elements.contains { $0.label.contains(markLabel) }
    }

    static func sessionRow(_ s: SessionSummary) -> HostedView {
      HostedView(SessionRow(session: s, activeAccount: ClaudeAccount.defaultFolder).environmentObject(offlineModel()))
    }

    static func boardCard(_ s: SessionSummary) -> HostedView {
      HostedView(BoardCard(session: s).environmentObject(offlineModel()))
    }

    static func inboxRow(_ s: SessionSummary) -> HostedView {
      HostedView(TriageRow(session: s, repo: nil, current: false).environmentObject(offlineModel()))
    }

    @Test func theMarkCarriesItsAccessibilityLabel() {
      #expect(Self.hasMark(HostedView(NewReplyMark())))
    }

    @Test func aSidebarRowWithANewReplyShowsTheMark() throws {
      #expect(Self.hasMark(Self.sessionRow(session([slackLink("l1", status: try newReply(true))]))))
    }

    @Test func aSidebarRowWithoutANewReplyShowsNoMark() throws {
      #expect(!Self.hasMark(Self.sessionRow(session([slackLink("l1", status: try newReply(false))]))))
    }

    @Test func aBoardCardWithANewReplyShowsTheMark() throws {
      #expect(Self.hasMark(Self.boardCard(session([slackLink("l1", status: try newReply(true))]))))
    }

    @Test func aBoardCardWithoutANewReplyShowsNoMark() throws {
      #expect(!Self.hasMark(Self.boardCard(session([slackLink("l1", status: try newReply(false))]))))
    }

    @Test func anInboxRowWithANewReplyShowsTheMark() throws {
      #expect(Self.hasMark(Self.inboxRow(session([slackLink("l1", status: try newReply(true))]))))
    }

    @Test func anInboxRowWithoutANewReplyShowsNoMark() throws {
      #expect(!Self.hasMark(Self.inboxRow(session([slackLink("l1", status: try newReply(false))]))))
    }
  }
}
