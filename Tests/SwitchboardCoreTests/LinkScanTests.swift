import Testing

@testable import SwitchboardCore

/// `LinkScan.urls(in:)` finds each `https://` link in prompt text, ends it at the characters that wrap links in
/// Slack and Markdown text, and trims trailing sentence punctuation.
@Suite struct LinkScanTests {
  static let a = "https://a.example/x"
  static let b = "https://b.example/y"

  @Test(arguments: ["", "no links here", "see a.example/x", "mailto:someone@example.com"])
  func textWithoutASchemeSeparatorHasNoLinks(_ text: String) {
    #expect(LinkScan.urls(in: text) == [])
  }

  @Test func oneLinkMidSentenceIsFound() {
    #expect(LinkScan.urls(in: "Please review \(Self.a) before lunch") == [Self.a])
  }

  @Test func aLinkAtTheEndOfTheTextIsFound() {
    #expect(LinkScan.urls(in: "Please review \(Self.a)") == [Self.a])
  }

  @Test func aLinkThatIsTheWholeTextIsFound() {
    #expect(LinkScan.urls(in: Self.a) == [Self.a])
  }

  @Test(arguments: ["\n", "\r\n", "\t", " ", "\u{0}", "\u{7F}", "\u{1B}"])
  func whitespaceOrAControlCharacterEndsALink(_ separator: String) {
    #expect(LinkScan.urls(in: "\(Self.a)\(separator)next line") == [Self.a])
  }

  @Test(arguments: [".", ",", ";", ":", "!", "?", "*", "~", "**", "...", "?!", "~*.", ".)"])
  func trailingPunctuationIsTrimmed(_ trailing: String) {
    #expect(LinkScan.urls(in: "Look at \(Self.a)\(trailing)") == [Self.a])
  }

  @Test(arguments: ["<", ">", "\"", "'", "`", "|", "(", ")", "[", "]", "{", "}", "\\", "^"])
  func eachTerminatorEndsALink(_ terminator: String) {
    #expect(LinkScan.urls(in: "\(Self.a)\(terminator)rest") == [Self.a])
  }

  @Test func aLinkInParenthesesLeavesTheClosingParenthesisOut() {
    #expect(LinkScan.urls(in: "(see \(Self.a))") == [Self.a])
  }

  @Test func aBoldLinkLeavesTheAsterisksOut() {
    #expect(LinkScan.urls(in: "**\(Self.a)**") == [Self.a])
  }

  @Test(arguments: ["*", "**", "_", "__", "~", "~~"])
  func emphasisAroundALinkIsLeftOut(_ marker: String) {
    #expect(LinkScan.urls(in: "See \(marker)\(Self.a)\(marker).") == [Self.a])
  }

  @Test(arguments: ["**", "~~"])
  func emphasisAroundAPhraseThatEndsInALinkIsLeftOut(_ marker: String) {
    #expect(LinkScan.urls(in: "\(marker)Review \(Self.a)\(marker)") == [Self.a])
  }

  @Test func aLinkWithoutTrailingUnderscoresDropsThemAndThePunctuationAroundThem() {
    #expect(LinkScan.withoutTrailingUnderscores("\(Self.a)_.__") == Self.a)
    #expect(LinkScan.withoutTrailingUnderscores(Self.a) == Self.a)
  }

  /// A Grafana uid can end in `_`, so an unpaired trailing `_` stays part of the link.
  @Test(arguments: ["Look at \(grafanaUnderscore)", "[dashboard](\(grafanaUnderscore))", "*\(grafanaUnderscore)*"])
  func aTrailingUnderscoreWithoutAnOpeningOneStays(_ text: String) {
    #expect(LinkScan.urls(in: text) == [grafanaUnderscore])
  }

  @Test func aSlackLinkWithALabelLeavesTheLabelOut() {
    #expect(LinkScan.urls(in: "<\(Self.a)|the thread>") == [Self.a])
  }

  @Test func aSlackLinkWithoutALabelLeavesTheBracketsOut() {
    #expect(LinkScan.urls(in: "<\(Self.a)>") == [Self.a])
  }

  @Test func aMarkdownLinkGivesItsURL() {
    #expect(LinkScan.urls(in: "[the plan](\(Self.a))") == [Self.a])
  }

  @Test func twoLinksJoinedByACommaAreTwoLinks() {
    #expect(LinkScan.urls(in: "\(Self.a),\(Self.b)") == [Self.a, Self.b])
  }

  @Test func twoLinksWithNothingBetweenThemAreTwoLinks() {
    #expect(LinkScan.urls(in: "\(Self.a)\(Self.b)") == [Self.a, Self.b])
  }

  @Test func anUppercaseSchemeIsFoundAsWritten() {
    #expect(LinkScan.urls(in: "see HTTPS://A.EXAMPLE/x now") == ["HTTPS://A.EXAMPLE/x"])
  }

  @Test func aMixedCaseSchemeIsFoundAsWritten() {
    #expect(LinkScan.urls(in: "see HtTpS://a.example/x now") == ["HtTpS://a.example/x"])
  }

  @Test func anHTTPLinkIsNotFound() {
    #expect(LinkScan.urls(in: "see http://a.example/x and \(Self.b)") == [Self.b])
  }

  @Test func linksComeInOrderWithRepeats() {
    #expect(LinkScan.urls(in: "\(Self.b) then \(Self.a) then \(Self.b)") == [Self.b, Self.a, Self.b])
  }

  /// A Slack reply's link keeps its query, and a Google Sheet's keeps its fragment, because the user opens them.
  @Test(arguments: [LinkFixtures.slackReply, "\(LinkFixtures.google)#gid=0", LinkFixtures.grafana])
  func aLinkKeepsItsQueryAndFragment(_ url: String) {
    #expect(LinkScan.urls(in: "Review \(url) please") == [url])
  }

  /// A colon inside the link, such as before a port, is part of it. Only a trailing one is trimmed.
  @Test func aColonInsideALinkStays() {
    #expect(
      LinkScan.urls(in: "see https://grafana.example.com:3000/d/abc: done") == [
        "https://grafana.example.com:3000/d/abc"
      ])
  }

  @Test func aLinkInsideASlackMessageWithLabelAndSentenceIsFound() {
    let text = "Can you check <\(LinkFixtures.slackReply)|this thread>? Also **\(LinkFixtures.linear)**."

    #expect(LinkScan.urls(in: text) == [LinkFixtures.slackReply, LinkFixtures.linear])
  }
}

private let grafanaUnderscore = "https://grafana.example.com/d/api_"
