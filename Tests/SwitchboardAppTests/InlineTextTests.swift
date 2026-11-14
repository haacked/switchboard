import Foundation
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct InlineTextTests {
  /// The `AttributedString` that `MarkdownView` drew for the same runs before
  /// the conversion moved into `InlineText.swift`.
  @Test func attributedKeepsEmphasisCodeLinksAndFootnotes() {
    typealias Run = MarkdownText.Run
    let text = MarkdownText([
      Run("Read "), Run("this", .emphasis), Run(", run "), Run("sb ls", .code), Run(", see "),
      Run("the docs", link: "https://example.com/docs"), Run("."), Run("1", .footnote),
    ])

    let result = text.attributed

    var emphasis = AttributedString("this")
    emphasis.inlinePresentationIntent = .emphasized
    var code = AttributedString("sb ls")
    code.inlinePresentationIntent = .code
    var link = AttributedString("the docs")
    link.link = URL(string: "https://example.com/docs")
    var footnote = AttributedString("1")
    footnote.baselineOffset = 6
    footnote.font = .caption2
    var expected = AttributedString("Read ")
    expected += emphasis
    expected += AttributedString(", run ")
    expected += code
    expected += AttributedString(", see ")
    expected += link
    expected += AttributedString(".")
    expected += footnote
    #expect(result == expected)
  }

  /// `InlineText(plain:)` replaced `Text(String)`, which reads no Markdown.
  @Test(arguments: ["**x**", "[a](https://example.com)", "`c`", "<a href=\"x\">y</a>", "one\ntwo", "_y_ ~z~", ""])
  func plainKeepsTheTextVerbatim(_ s: String) {
    #expect(MarkdownText(stringLiteral: s).attributed == AttributedString(s))
  }
}

// MARK: - Session names

private let liveID = "seb4ec"
private let liveName = "zsh-startup-for-switchboard"
private let removedID = "sgcctv"
private let removedName = "old-flag-cleanup"
private let otherID = "s3k9ap"
private let otherName = "flag-cache-race"

private let names = SessionNames(
  live: [liveID: liveName, otherID: otherName], removed: [removedID: removedName])
private let noNames = SessionNames(live: [:], removed: [:])

private func render(_ text: MarkdownText, names: SessionNames = names, links: Bool = true) -> (
  text: AttributedString, help: String?
) {
  let (attributed, help) = InlineText.attributed(text, names: names, links: links)
  return (attributed, help)
}

private func render(plain: String, names: SessionNames = names, links: Bool = true) -> (
  text: AttributedString, help: String?
) {
  render(MarkdownText(stringLiteral: plain), names: names, links: links)
}

/// Each distinct link in the part of `text` that reads `substring`, nil for a run with no link.
private func links(in text: AttributedString, of substring: String) throws -> Set<URL?> {
  let range = try #require(text.range(of: substring))
  return Set(text[range].runs.map { $0.link })
}

/// Each distinct link anywhere in `text`.
private func allLinks(_ text: AttributedString) -> Set<URL?> { Set(text.runs.map { $0.link }) }

extension InlineTextTests {
  @Suite struct Names {
    // MARK: Links

    @Test func aLiveIdReadsAsTheSessionsName() {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(String(result.text.characters) == "Ask \(liveName) to rebase.")
    }

    @Test func aLiveNameLinksToTheSessionURL() throws {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(try links(in: result.text, of: liveName) == [URL(string: "switchboard-session:\(liveID)")])
    }

    @Test func aLiveNameLinksToTheURLThatSessionLinkMakes() throws {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(try links(in: result.text, of: liveName) == [SessionLink.url(for: liveID)])
    }

    @Test func theTextAroundALiveNameHasNoLink() throws {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(try links(in: result.text, of: "Ask ") == [nil])
      #expect(try links(in: result.text, of: " to rebase.") == [nil])
    }

    @Test func twoLiveIdsEachLinkToTheirOwnSession() throws {
      let result = render(plain: "\(liveID),\(otherID)")

      #expect(try links(in: result.text, of: liveName) == [SessionLink.url(for: liveID)])
      #expect(try links(in: result.text, of: otherName) == [SessionLink.url(for: otherID)])
    }

    @Test func aRemovedIdReadsAsItsNameWithNoLink() {
      let result = render(plain: "Ask \(removedID) to rebase.")

      #expect(String(result.text.characters) == "Ask \(removedName) to rebase.")
      #expect(allLinks(result.text) == [nil])
    }

    @Test func withoutLinksALiveIdReadsAsItsNameWithNoLink() {
      let result = render(plain: "Ask \(liveID) to rebase.", links: false)

      #expect(String(result.text.characters) == "Ask \(liveName) to rebase.")
      #expect(allLinks(result.text) == [nil])
    }

    @Test func aCollapsedNameAndIdLinksOnce() throws {
      let result = render(plain: "\(liveName) (\(liveID)) is done")

      #expect(String(result.text.characters) == "\(liveName) is done")
      #expect(try links(in: result.text, of: liveName) == [SessionLink.url(for: liveID)])
    }

    @Test func anUnknownLookAlikeWordStaysAsWrittenWithNoLink() {
      let result = render(plain: "stream the switch to sgxxxx")

      #expect(String(result.text.characters) == "stream the switch to sgxxxx")
      #expect(allLinks(result.text) == [nil])
    }

    /// A Markdown link keeps its own URL, so the window's handler passes it to the browser.
    @Test func aMarkdownLinkWhoseTextIsAnIdKeepsItsTextAndURL() {
      let text = MarkdownText([MarkdownText.Run(liveID, link: "https://example.com/x")])

      let result = render(text)

      #expect(String(result.text.characters) == liveID)
      #expect(allLinks(result.text) == [URL(string: "https://example.com/x")])
    }

    // MARK: Styles

    @Test func aStrongIdKeepsItsStrongStyleAndLinks() throws {
      let text = MarkdownText([MarkdownText.Run("Ask "), MarkdownText.Run(liveID, .strong)])

      let result = render(text)

      let range = try #require(result.text.range(of: liveName))
      #expect(result.text[range].inlinePresentationIntent == .stronglyEmphasized)
      #expect(result.text[range].link == SessionLink.url(for: liveID))
    }

    @Test func anExactIdCodeSpanDropsTheCodeStyle() throws {
      let text = MarkdownText([MarkdownText.Run("Ask "), MarkdownText.Run(liveID, .code)])

      let result = render(text)

      let range = try #require(result.text.range(of: liveName))
      #expect(result.text[range].inlinePresentationIntent?.contains(.code) != true)
    }

    @Test func aCommandCodeSpanStaysAsWritten() {
      let text = MarkdownText([MarkdownText.Run("sb send \(liveID) hi", .code)])

      let result = render(text)

      var expected = AttributedString("sb send \(liveID) hi")
      expected.inlinePresentationIntent = .code
      #expect(result.text == expected)
    }

    // MARK: Unchanged output

    /// The Stage 1 fixture: emphasis, code, a link, and a footnote, with no id.
    static let styled = MarkdownText([
      MarkdownText.Run("Read "), MarkdownText.Run("this", .emphasis), MarkdownText.Run(", run "),
      MarkdownText.Run("sb ls", .code), MarkdownText.Run(", see "),
      MarkdownText.Run("the docs", link: "https://example.com/docs"), MarkdownText.Run("."),
      MarkdownText.Run("1", .footnote),
    ])

    @Test(arguments: [true, false])
    func aTextWithoutIdsDrawsWhatStageOneDrew(_ links: Bool) {
      let result = render(Self.styled, links: links)

      #expect(result.text == Self.styled.attributed)
    }

    /// Risk 1's rollback: an empty directory draws today's text.
    @Test func anEmptyDirectoryDrawsTheTextAsWritten() {
      let text = MarkdownText(stringLiteral: "Ask \(liveID) to rebase.")

      let result = render(text, names: noNames)

      #expect(result.text == text.attributed)
    }

    @Test func anEmptyDirectoryAddsNoHelp() {
      let result = render(plain: "Ask \(liveID) to rebase.", names: noNames)

      #expect(result.help == nil)
    }

    // MARK: Parity

    /// The same text with and without links gives the same characters.
    @Test(arguments: [
      "Ask \(liveID) to rebase.",
      "\(liveName) (\(liveID)) is done",
      "\(liveID) (\(liveName)) is done",
      "The dotfiles session (\(liveID))",
      "\(liveID),\(otherID) and \(removedID).",
      "\(liveID)'s PR",
      "sessions/\(liveID)/claude.sh",
      "stream",
      "",
    ])
    func withAndWithoutLinksGiveTheSameCharacters(_ s: String) {
      let linked = render(plain: s, links: true)
      let unlinked = render(plain: s, links: false)

      #expect(String(linked.text.characters) == String(unlinked.text.characters))
    }

    @Test(arguments: [
      "Ask \(liveID) to rebase.",
      "\(liveName) (\(liveID)) is done",
      "\(liveID),\(otherID) and \(removedID).",
      "sessions/\(liveID)/claude.sh",
    ])
    func linkedCharactersMatchThePlainTextPath(_ s: String) {
      let linked = render(plain: s, links: true)

      #expect(String(linked.text.characters) == names.plainText(s))
    }

    // MARK: Help

    @Test func helpNamesALiveSessionAndItsId() {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(result.help == "\(liveName): \(liveID)")
    }

    @Test func helpMarksARemovedSession() {
      let result = render(plain: "Ask \(removedID) to rebase.")

      #expect(result.help == "\(removedName): \(removedID), removed")
    }

    /// Assumes the lines follow the order in which each session first appears.
    @Test func helpListsEachSessionOnItsOwnLine() {
      let result = render(plain: "\(liveID) waits on \(removedID) and \(otherID)")

      #expect(
        result.help
          == "\(liveName): \(liveID)\n\(removedName): \(removedID), removed\n\(otherName): \(otherID)")
    }

    /// Assumes a session that the text names twice gets one line.
    @Test func helpListsARepeatedSessionOnce() {
      let result = render(plain: "\(liveID) then \(liveID) again")

      #expect(result.help == "\(liveName): \(liveID)")
    }

    @Test func aTextWithNoMatchHasNoHelp() {
      let result = render(plain: "stream the switch to sgxxxx")

      #expect(result.help == nil)
    }

    @Test func withoutLinksThereIsNoHelp() {
      let result = render(plain: "Ask \(liveID) to rebase.", links: false)

      #expect(result.help == nil)
    }

    // MARK: Environment

    /// A host that never sets the value draws today's text.
    @Test func theEnvironmentDirectoryStartsEmpty() {
      #expect(EnvironmentValues().sessionNames == SessionNames(live: [:], removed: [:]))
    }
  }
}
