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
