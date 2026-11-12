import Foundation
import Testing

@testable import SwitchboardCore

/// Screen rows built the way Claude Code 2.1.322 draws them: a 2-column
/// margin, `⏺ ` on a message's first row, `▎ ` on quote rows, and paragraphs
/// hard-wrapped to the pane width.
private enum Screen {
  static let bar = "\u{258E}"
  static let dot = "\u{23FA}"
  static let width = 90

  static func quote(_ text: String) -> String { "  \(bar) \(text)" }
  static let blankQuote = "  \(bar)"

  /// Pads a row with trailing spaces to the pane width, as the terminal reports it.
  static func padded(_ row: String) -> String {
    row + String(repeating: " ", count: max(0, width - row.count))
  }

  /// Row 0 as tmux draws it in copy mode, with `[n/m]` at the right end.
  static func withMarker(_ row: String, _ marker: String = "[0/57]") -> String {
    row + String(repeating: " ", count: max(1, width - marker.count - row.count)) + marker
  }

}

extension TerminalBlock {
  fileprivate static func quote(_ rows: ClosedRange<Int>, _ copyText: String) -> TerminalBlock {
    TerminalBlock(kind: .quote, rows: rows, copyText: copyText)
  }

  fileprivate static func code(_ rows: ClosedRange<Int>, _ copyText: String) -> TerminalBlock {
    TerminalBlock(kind: .code, rows: rows, copyText: copyText)
  }
}

private let greetCode = #"""
  func greet(name: String) -> String {
      return "Hello, \(name)! This is a deliberately long line so that it has to wrap in a narrow terminal window somewhere."
  }
  """#

private let exampleQuote =
  "First paragraph of the quote with **bold** and `code` and a [link](https://example.com/x) in it, long enough to wrap around the terminal edge.\n\nSecond paragraph."

private let plainCode = "plain block\n  indented line"

private let exampleMarkdown = #"""
  Here is code:

  ```swift
  func greet(name: String) -> String {
      return "Hello, \(name)! This is a deliberately long line so that it has to wrap in a narrow terminal window somewhere."
  }
  ```

  And a quote:

  > First paragraph of the quote with **bold** and `code` and a [link](https://example.com/x) in it, long enough to wrap around the terminal edge.
  >
  > Second paragraph.

  ```
  plain block
    indented line
  ```
  """#

private let quoteOnlyMarkdown = #"""
  And a quote:

  > First paragraph of the quote with **bold** and `code` and a [link](https://example.com/x) in it, long enough to wrap around the terminal edge.
  >
  > Second paragraph.
  """#

private let greetRows = [
  "  func greet(name: String) -> String {",
  #"      return "Hello, \(name)! This is a deliberately long line so that it has to wrap in a"#,
  #"  narrow terminal window somewhere.""#,
  "  }",
]

private let quoteRows = [
  Screen.quote("First paragraph of the quote with bold and code and a link in it, long enough to wrap"),
  Screen.quote("around the terminal edge."),
  Screen.blankQuote,
  Screen.quote("Second paragraph."),
]

/// The spec's 90-column example screen, padded to the pane width.
private let exampleRows =
  ([
    "\(Screen.dot) Here is code:",
    "",
  ] + greetRows + [
    "",
    "  And a quote:",
    "",
  ] + quoteRows + [
    "",
    "  plain block",
    "    indented line",
  ]).map(Screen.padded)

@Suite struct TerminalBlocksTests {
  // MARK: - sourceBlocks

  @Test func sourceBlocksReturnsCodeAndQuotesInOrder() {
    #expect(
      MarkdownBlock.sourceBlocks(in: exampleMarkdown) == [
        SourceBlock(kind: .code, text: greetCode),
        SourceBlock(kind: .quote, text: exampleQuote),
        SourceBlock(kind: .code, text: plainCode),
      ])
  }

  @Test func sourceBlocksOfEmptyMarkdownIsEmpty() {
    #expect(MarkdownBlock.sourceBlocks(in: "") == [])
    #expect(MarkdownBlock.sourceBlocks(in: "Just a paragraph.\n\n- and a list") == [])
  }

  @Test func sourceBlocksFindsCodeNestedInAList() {
    let md = "1. Run:\n\n   ```sh\n   ls -la\n   echo hi\n   ```\n2. Done."
    #expect(MarkdownBlock.sourceBlocks(in: md) == [SourceBlock(kind: .code, text: "ls -la\necho hi")])
  }

  @Test func sourceBlocksFindsAnIndentedQuoteInAList() {
    let md = "- item\n\n  > quoted inside a list"
    #expect(MarkdownBlock.sourceBlocks(in: md) == [SourceBlock(kind: .quote, text: "quoted inside a list")])
  }

  @Test func sourceBlocksRemovesOnlyOneLevelOfQuoteMarker() {
    #expect(
      MarkdownBlock.sourceBlocks(in: "> outer\n> > inner") == [SourceBlock(kind: .quote, text: "outer\n> inner")])
  }

  @Test func sourceBlocksAcceptsAQuoteMarkerWithoutASpace() {
    #expect(MarkdownBlock.sourceBlocks(in: ">tight\n> loose") == [SourceBlock(kind: .quote, text: "tight\nloose")])
  }

  @Test func sourceBlocksReadsAQuoteWithWindowsLineEndings() {
    #expect(
      MarkdownBlock.sourceBlocks(in: "> one\r\n> two\r\n\r\nafter") == [SourceBlock(kind: .quote, text: "one\ntwo")])
  }

  @Test func sourceBlocksKeepsALazyContinuationLineInTheQuote() {
    #expect(MarkdownBlock.sourceBlocks(in: "> one\ntwo") == [SourceBlock(kind: .quote, text: "one\ntwo")])
  }

  @Test func sourceBlocksFindsAQuoteThatOpensAListItem() {
    #expect(MarkdownBlock.sourceBlocks(in: "- > one\n  > two") == [SourceBlock(kind: .quote, text: "one\ntwo")])
  }

  @Test func sourceBlocksSplitsQuotesAtABlankLine() {
    #expect(
      MarkdownBlock.sourceBlocks(in: "> one\n\n> two") == [
        SourceBlock(kind: .quote, text: "one"), SourceBlock(kind: .quote, text: "two"),
      ])
  }

  @Test func sourceBlocksIgnoresQuoteMarkersInsideFences() {
    #expect(
      MarkdownBlock.sourceBlocks(in: "```\n> not a quote\n```") == [SourceBlock(kind: .code, text: "> not a quote")])
  }

  // MARK: - find: the example screen

  @Test func findReturnsEveryBlockOfTheExampleScreenInRowOrder() {
    #expect(
      TerminalBlocks.find(rows: exampleRows, messages: [exampleMarkdown]) == [
        .code(2...5, greetCode),
        .quote(9...12, exampleQuote),
        .code(14...15, plainCode),
      ])
  }

  @Test func findOnAnEmptyScreenReturnsNothing() {
    #expect(TerminalBlocks.find(rows: [], messages: [exampleMarkdown]) == [])
  }

  @Test func findWithoutMessagesReportsNoCode() {
    let rows = ["\(Screen.dot) Here:", "", "  let x = 1", ""]
    #expect(TerminalBlocks.find(rows: rows, messages: []) == [])
  }

  // MARK: - find: quote detection

  @Test func quoteOnAMessageFirstRowIsDetected() {
    let rows = ["\(Screen.dot) \(Screen.bar) Quoted opening line", Screen.quote("second line"), "", "  After."]
    #expect(TerminalBlocks.find(rows: rows, messages: []) == [.quote(0...1, "Quoted opening line second line")])
  }

  @Test func blankQuoteRowsStayInsideTheQuote() {
    let rows = ["", Screen.quote("One."), Screen.blankQuote, "  \(Screen.bar)   ", Screen.quote("Two."), ""]
    #expect(TerminalBlocks.find(rows: rows, messages: []) == [.quote(1...4, "One.\n\nTwo.")])
  }

  @Test func quoteBarsAtDifferentColumnsAreSeparateQuotes() {
    let rows = ["\(Screen.dot) Text:", "", Screen.quote("outer quote line"), "    \(Screen.bar) inner quote line", ""]
    #expect(
      TerminalBlocks.find(rows: rows, messages: []) == [
        .quote(2...2, "outer quote line"), .quote(3...3, "inner quote line"),
      ])
  }

  @Test func barThatIsNotTheFirstCharacterIsNotAQuote() {
    let rows = ["\(Screen.dot) The \(Screen.bar) glyph marks quotes.", "  It \(Screen.bar) is drawn dim."]
    #expect(TerminalBlocks.find(rows: rows, messages: []) == [])
  }

  @Test func unmatchedQuoteCopiesTheScreenText() {
    let rows = ["", Screen.quote("Nobody wrote this."), ""]
    #expect(TerminalBlocks.find(rows: rows, messages: ["Plain answer."]) == [.quote(1...1, "Nobody wrote this.")])
  }

  // MARK: - find: code detection

  @Test func codeMatchesAcrossHardWrappedRows() {
    let rows = (["\(Screen.dot) Here is code:", ""] + greetRows + ["", "  Done."]).map(Screen.padded)
    #expect(TerminalBlocks.find(rows: rows, messages: [exampleMarkdown]) == [.code(2...5, greetCode)])
  }

  @Test func codeNestedInAListMatches() {
    let rows = ["\(Screen.dot) 1. Run:", "", "     make build-all", ""]
    #expect(
      TerminalBlocks.find(rows: rows, messages: ["1. Run:\n\n   ```\n   make build-all\n   ```"]) == [
        .code(2...2, "make build-all")
      ])
  }

  @Test func codeWithAnInteriorBlankLineMatchesAsOneBlock() {
    let rows = ["\(Screen.dot) Code:", "", "  let a = 1", "", "  let b = 2", "", "  Done."]
    #expect(
      TerminalBlocks.find(rows: rows, messages: ["```\nlet a = 1\n\nlet b = 2\n```"]) == [
        .code(2...4, "let a = 1\n\nlet b = 2")
      ])
  }

  @Test func theLongerOfTwoWholeCodeMatchesWins() {
    let rows = ["\(Screen.dot) Code:", "", "  let a = 1", "", "  let b = 2", "", "  Done."]
    let messages = ["```\nlet a = 1\n```", "```\nlet a = 1\n\nlet b = 2\n```"]
    #expect(TerminalBlocks.find(rows: rows, messages: messages) == [.code(2...4, "let a = 1\n\nlet b = 2")])
  }

  @Test func codeFromSeveralMessagesComesBackInRowOrder() {
    let rows = ["\(Screen.dot) Build:", "", "  make build-all", "", "\(Screen.dot) Test:", "", "  make test-all", ""]
    let messages = ["Test:\n\n```\nmake test-all\n```", "Build:\n\n```\nmake build-all\n```"]
    #expect(
      TerminalBlocks.find(rows: rows, messages: messages) == [
        .code(2...2, "make build-all"), .code(6...6, "make test-all"),
      ])
  }

  @Test func whitespaceOnlyRowsCountAsBlank() {
    let rows = [
      Screen.padded("  Run:"), Screen.padded(""), Screen.padded("  make build-all"), "      ", "  Then wait.",
    ]
    #expect(TerminalBlocks.find(rows: rows, messages: ["```\nmake build-all\n```"]) == [.code(2...2, "make build-all")])
  }

  // MARK: - find: the blank-row boundary rule

  @Test func oneLineCodeDoesNotMatchTheSameWordInsideAParagraph() {
    let rows = ["\(Screen.dot) First:", "", "  ls", "", "  Then run", "  ls", "  again."]
    #expect(TerminalBlocks.find(rows: rows, messages: ["First:\n\n```\nls\n```"]) == [.code(2...2, "ls")])
  }

  @Test func codeWithATextRowDirectlyAboveDoesNotMatch() {
    let rows = ["", "  Intro text", "  let x = compute(1)", "  let y = compute(2)", "", "  After."]
    #expect(TerminalBlocks.find(rows: rows, messages: ["```\nlet x = compute(1)\nlet y = compute(2)\n```"]) == [])
  }

  @Test func codeWithATextRowDirectlyBelowDoesNotMatch() {
    let rows = ["", "  let x = compute(1)", "  let y = compute(2)", "  Outro text", "", "  After."]
    #expect(TerminalBlocks.find(rows: rows, messages: ["```\nlet x = compute(1)\nlet y = compute(2)\n```"]) == [])
  }

  @Test func quoteRowsAreNotAlsoReportedAsCode() {
    let rows = ["", Screen.quote("alpha beta"), Screen.quote("gamma delta"), ""]
    let message = "```\n\(Screen.bar) alpha beta\n\(Screen.bar) gamma delta\n```"
    #expect(TerminalBlocks.find(rows: rows, messages: [message]) == [.quote(1...2, "alpha beta gamma delta")])
  }

  @Test func codeBlockTextIsNotUsedAsAQuoteCopy() {
    let rows = ["", Screen.quote("hello there general kenobi"), ""]
    #expect(
      TerminalBlocks.find(rows: rows, messages: ["```\nhello **there** general kenobi\n```"]) == [
        .quote(1...1, "hello there general kenobi")
      ])
  }

  // MARK: - find: partial blocks

  @Test func codeCutByTheTopMatchesItsSuffix() {
    let rows = [greetRows[2], greetRows[3], "", "  And a quote:"]
    #expect(TerminalBlocks.find(rows: rows, messages: [exampleMarkdown]) == [.code(0...1, greetCode)])
  }

  @Test func codeCutByTheBottomMatchesItsPrefix() {
    let rows = ["\(Screen.dot) Here is code:", "", greetRows[0], greetRows[1]]
    #expect(TerminalBlocks.find(rows: rows, messages: [exampleMarkdown]) == [.code(2...3, greetCode)])
  }

  @Test func codePrefixAtTheTopDoesNotMatch() {
    let rows = [greetRows[0], "", "  Next paragraph."]
    #expect(TerminalBlocks.find(rows: rows, messages: [exampleMarkdown]) == [])
  }

  @Test func codeSuffixAtTheBottomDoesNotMatch() {
    let rows = ["\(Screen.dot) Text.", "", greetRows[2], greetRows[3]]
    #expect(TerminalBlocks.find(rows: rows, messages: [exampleMarkdown]) == [])
  }

  @Test func partialCodeAwayFromTheEdgesDoesNotMatch() {
    let rows = ["\(Screen.dot) Text.", "", greetRows[0], "", "  More."]
    #expect(TerminalBlocks.find(rows: rows, messages: [exampleMarkdown]) == [])
  }

  @Test func partialCodeAtTheTopNeedsTwelveCharacters() {
    let rows12 = ["  abcdefghijkl", "", "  Next."]
    #expect(
      TerminalBlocks.find(rows: rows12, messages: ["```\nstart()\nabcdefghijkl\n```"]) == [
        .code(0...0, "start()\nabcdefghijkl")
      ])
    let rows11 = ["  abcdefghijk", "", "  Next."]
    #expect(TerminalBlocks.find(rows: rows11, messages: ["```\nstart()\nabcdefghijk\n```"]) == [])
  }

  @Test func aWholeCodeMatchWinsOverAPartialOne() {
    let rows = ["  abcdefghijkl", "", "  Next."]
    let messages = ["```\nstart()\nabcdefghijkl\n```", "```\nabcdefghijkl\n```"]
    #expect(TerminalBlocks.find(rows: rows, messages: messages) == [.code(0...0, "abcdefghijkl")])
  }

  @Test func partialCodeAtTheBottomNeedsTwelveCharacters() {
    let rows12 = ["\(Screen.dot) Text.", "", "  abcdefghijkl"]
    #expect(
      TerminalBlocks.find(rows: rows12, messages: ["```\nabcdefghijkl\nend()\n```"]) == [
        .code(2...2, "abcdefghijkl\nend()")
      ])
    let rows11 = ["\(Screen.dot) Text.", "", "  abcdefghijk"]
    #expect(TerminalBlocks.find(rows: rows11, messages: ["```\nabcdefghijk\nend()\n```"]) == [])
  }

  @Test func quoteCutByTheTopMatchesItsSuffix() {
    let rows = [quoteRows[1], quoteRows[2], quoteRows[3], "", "  After."]
    #expect(TerminalBlocks.find(rows: rows, messages: [quoteOnlyMarkdown]) == [.quote(0...2, exampleQuote)])
  }

  @Test func quoteCutByTheBottomMatchesItsPrefix() {
    let rows = ["\(Screen.dot) And a quote:", "", quoteRows[0]]
    #expect(TerminalBlocks.find(rows: rows, messages: [quoteOnlyMarkdown]) == [.quote(2...2, exampleQuote)])
  }

  @Test func quotePrefixAwayFromTheBottomFallsBackToScreenText() {
    let rows = ["\(Screen.dot) And a quote:", "", quoteRows[0], "", "  More text."]
    #expect(
      TerminalBlocks.find(rows: rows, messages: [quoteOnlyMarkdown]) == [
        .quote(2...2, "First paragraph of the quote with bold and code and a link in it, long enough to wrap")
      ])
  }

  @Test func quoteSuffixAwayFromTheTopFallsBackToScreenText() {
    let rows = ["\(Screen.dot) Text.", "", quoteRows[3], "", "  More text."]
    #expect(TerminalBlocks.find(rows: rows, messages: [quoteOnlyMarkdown]) == [.quote(2...2, "Second paragraph.")])
  }

  @Test func partialQuoteNeedsTwelveLettersAndDigits() {
    let rows12 = [Screen.quote("abcdef ghijkl."), "", "  After."]
    #expect(
      TerminalBlocks.find(rows: rows12, messages: ["> Intro words go here.\n>\n> **abcdef** ghijkl."]) == [
        .quote(0...0, "Intro words go here.\n\n**abcdef** ghijkl.")
      ])
    let rows11 = [Screen.quote("abcdef ghijk."), "", "  After."]
    #expect(
      TerminalBlocks.find(rows: rows11, messages: ["> Intro words go here.\n>\n> **abcdef** ghijk."]) == [
        .quote(0...0, "abcdef ghijk.")
      ])
  }

  @Test func partialQuoteThresholdIgnoresPunctuation() {
    let rows = [Screen.quote("a.b.c.d.e -- (f-g-h)!"), "", "  After."]
    #expect(
      TerminalBlocks.find(rows: rows, messages: ["> Intro words go here.\n>\n> **a.b.c.d.e** -- (f-g-h)!"]) == [
        .quote(0...0, "a.b.c.d.e -- (f-g-h)!")
      ])
  }

  // MARK: - find: the tmux copy-mode marker

  @Test func tmuxMarkerOnRowZeroDoesNotBreakACodeMatch() {
    let rows = [Screen.withMarker(greetRows[2]), greetRows[3], "", "  And a quote:"]
    #expect(TerminalBlocks.find(rows: rows, messages: [exampleMarkdown]) == [.code(0...1, greetCode)])
  }

  @Test func tmuxMarkerOnRowZeroDoesNotBreakAQuoteMatch() {
    let rows = [Screen.withMarker(quoteRows[1], "[12/340]"), quoteRows[2], quoteRows[3], ""]
    #expect(TerminalBlocks.find(rows: rows, messages: [quoteOnlyMarkdown]) == [.quote(0...2, exampleQuote)])
  }

  @Test func tmuxMarkerDoesNotLeakIntoFallbackText() {
    let rows = [Screen.withMarker(Screen.quote("Unmatched quote text here"), "[3/120]"), Screen.quote("and more."), ""]
    #expect(TerminalBlocks.find(rows: rows, messages: []) == [.quote(0...1, "Unmatched quote text here and more.")])
  }

  @Test func bracketedFractionInsideRowZeroIsKept() {
    let rows = ["  let half = values[3/4] + offset", "", "  After."]
    #expect(
      TerminalBlocks.find(rows: rows, messages: ["```\nlet half = values[3/4] + offset\n```"]) == [
        .code(0...0, "let half = values[3/4] + offset")
      ])
  }

  @Test func trailingBracketedFractionBelowRowZeroIsKept() {
    let rows = ["\(Screen.dot) Ratio:", "", "  ratio [1/2]", ""]
    #expect(TerminalBlocks.find(rows: rows, messages: ["```\nratio [1/2]\n```"]) == [.code(2...2, "ratio [1/2]")])
  }

  // MARK: - find: quote matching through markup

  @Test(arguments: [
    ("Use **bold** words in this quote", "Use bold words in this quote"),
    ("Use _italic_ words in this quote", "Use italic words in this quote"),
    ("Use `inline` code in this quote", "Use inline code in this quote"),
    ("Mixed CASE words in this quote", "mixed case words in this quote"),
    ("See [the docs](https://example.com/v2/abc123) for this quote", "See the docs for this quote"),
    (#"Escaped \*literal\* stars in this quote"#, "Escaped *literal* stars in this quote"),
  ])
  func quoteMatchesThroughMarkup(markdown: String, screen: String) {
    let rows = ["", Screen.quote(screen), ""]
    #expect(TerminalBlocks.find(rows: rows, messages: ["> \(markdown)"]) == [.quote(1...1, markdown)])
  }

  @Test func newestMessageWinsAQuoteMatch() {
    let rows = ["\(Screen.dot) \(Screen.bar) Use care here, friends and colleagues."]
    let bold = "> Use **care** here, friends and colleagues."
    let italic = "> Use *care* here, friends and colleagues."
    #expect(
      TerminalBlocks.find(rows: rows, messages: [bold, italic]) == [
        .quote(0...0, "Use **care** here, friends and colleagues.")
      ])
    #expect(
      TerminalBlocks.find(rows: rows, messages: [italic, bold]) == [
        .quote(0...0, "Use *care* here, friends and colleagues.")
      ])
  }

  // MARK: - screenQuoteText

  @Test func screenQuoteTextJoinsParagraphRowsWithASpace() {
    #expect(
      TerminalBlocks.screenQuoteText([Screen.quote("First line of the"), Screen.quote("paragraph wraps.")])
        == "First line of the paragraph wraps.")
  }

  @Test func screenQuoteTextSeparatesParagraphsWithABlankLine() {
    #expect(
      TerminalBlocks.screenQuoteText([Screen.quote("One."), Screen.blankQuote, Screen.quote("Two.")])
        == "One.\n\nTwo.")
  }

  @Test func screenQuoteTextTreatsABarWithTrailingSpacesAsABlankLine() {
    #expect(
      TerminalBlocks.screenQuoteText(["  \(Screen.bar) One.   ", "  \(Screen.bar)   ", "  \(Screen.bar) Two.  "])
        == "One.\n\nTwo.")
  }

  @Test func screenQuoteTextDropsPaddingSpaces() {
    #expect(
      TerminalBlocks.screenQuoteText([
        Screen.padded(Screen.quote("Padded text")), Screen.padded(Screen.quote("continues")),
      ])
        == "Padded text continues")
  }

  @Test func screenQuoteTextDropsTheMessageBullet() {
    #expect(
      TerminalBlocks.screenQuoteText(["\(Screen.dot) \(Screen.bar) Hello", Screen.quote("world")]) == "Hello world")
  }

  @Test(arguments: ["- ", "* ", "• ", "1. ", "3. "])
  func screenQuoteTextStartsANewLineAtAListMarker(marker: String) {
    #expect(
      TerminalBlocks.screenQuoteText([Screen.quote("Steps:"), Screen.quote("\(marker)do it")])
        == "Steps:\n\(marker)do it")
  }

  @Test func screenQuoteTextStartsANewLineAtAMultiDigitListMarker() {
    #expect(
      TerminalBlocks.screenQuoteText([Screen.quote("Steps:"), Screen.quote("10. do it")]) == "Steps:\n10. do it")
  }

  @Test func screenQuoteTextJoinsAWrappedListItem() {
    #expect(
      TerminalBlocks.screenQuoteText([
        Screen.quote("- first item that"), Screen.quote("wraps"), Screen.quote("- second"),
      ]) == "- first item that wraps\n- second")
  }

  @Test func screenQuoteTextJoinsADashWithoutASpace() {
    #expect(
      TerminalBlocks.screenQuoteText([Screen.quote("The low was"), Screen.quote("-5 degrees.")])
        == "The low was -5 degrees.")
  }
}
