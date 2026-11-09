import Foundation
import Testing

@testable import SwitchboardCore

private typealias Run = MarkdownText.Run

private func item(_ text: MarkdownText, _ more: MarkdownBlock...) -> MarkdownBlock.Item {
  .init(checked: nil, blocks: [.paragraph(text)] + more)
}

private func text(_ runs: Run...) -> MarkdownText { MarkdownText(runs) }

@Suite struct MarkdownTests {
  @Test func headings() {
    let md = "# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n\nSetext one\n===\n\nSetext two\n---"
    #expect(
      MarkdownBlock.parse(md) == [
        .heading(level: 1, text: "One"), .heading(level: 2, text: "Two"), .heading(level: 3, text: "Three"),
        .heading(level: 4, text: "Four"), .heading(level: 5, text: "Five"), .heading(level: 6, text: "Six"),
        .heading(level: 1, text: "Setext one"), .heading(level: 2, text: "Setext two"),
      ])
    #expect(
      MarkdownBlock.parse("## The **plan**") == [.heading(level: 2, text: text(Run("The "), Run("plan", .strong)))])
    #expect(MarkdownBlock.parse("#hashtag\n####### seven") == [.paragraph("#hashtag\n####### seven")])
  }

  @Test func paragraphsKeepTheirLineBreaks() {
    #expect(
      MarkdownBlock.parse("The merge loses findings:\nthe old pipeline found 6.\n\nNext") == [
        .paragraph("The merge loses findings:\nthe old pipeline found 6."), .paragraph("Next"),
      ])
    #expect(MarkdownBlock.parse("") == [])
  }

  @Test func emphasis() {
    #expect(
      MarkdownBlock.parse("*it* **bold** ***both*** _u_") == [
        .paragraph(
          text(
            Run("it", .emphasis), Run(" "), Run("bold", .strong), Run(" "), Run("both", [.emphasis, .strong]),
            Run(" "), Run("u", .emphasis)))
      ])
  }

  @Test func nestedAndOrderedLists() {
    let md = "3. a\n   1. x\n   2. y\n      - deep\n4. b\n   + bullet in ordered\n\n1) paren"
    #expect(
      MarkdownBlock.parse(md) == [
        .list(
          number: 3,
          items: [
            item("a", .list(number: 1, items: [item("x"), item("y", .list(number: nil, items: [item("deep")]))])),
            item("b", .list(number: nil, items: [item("bullet in ordered")])),
          ]),
        .list(number: 1, items: [item("paren")]),
      ])
    #expect(
      MarkdownBlock.parse("1. a\n\n   detail\n\n2. b\n\n3. c") == [
        .list(number: 1, items: [item("a", .paragraph("detail")), item("b"), item("c")])
      ])
    #expect(MarkdownBlock.parse("- a\n\nafter") == [.list(number: nil, items: [item("a")]), .paragraph("after")])
    #expect(MarkdownBlock.parse("- one\n  wrapped") == [.list(number: nil, items: [item("one\nwrapped")])])
  }

  @Test func taskLists() {
    #expect(
      MarkdownBlock.parse("- [ ] todo\n- [x] done\n- [X] also\n  - [ ] nested\n- [link](u)") == [
        .list(
          number: nil,
          items: [
            .init(checked: false, blocks: [.paragraph("todo")]),
            .init(checked: true, blocks: [.paragraph("done")]),
            .init(
              checked: true,
              blocks: [
                .paragraph("also"),
                .list(number: nil, items: [.init(checked: false, blocks: [.paragraph("nested")])]),
              ]),
            item(text(Run("link", link: "u"))),
          ])
      ])
  }

  @Test func tablesWithAlignment() {
    let md =
      "intro\n\n| None | Left | Center | Right |\n| --- | :-- | :-: | --: |\n| a | **b** | `c\\|d` | 1 |\n| short |\n\nafter"
    #expect(
      MarkdownBlock.parse(md) == [
        .paragraph("intro"),
        .table(
          header: ["None", "Left", "Center", "Right"], alignments: [.leading, .leading, .center, .trailing],
          rows: [["a", text(Run("b", .strong)), text(Run("c|d", .code)), "1"], ["short", "", "", ""]]),
        .paragraph("after"),
      ])
    #expect(
      MarkdownBlock.parse("a | b\n-|-\nc | d | extra") == [
        .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["c", "d"]])
      ])
    #expect(
      MarkdownBlock.parse("| a | b |\n| --- |\n| 1 | 2 |").allSatisfy { if case .table = $0 { false } else { true } })
  }

  @Test func aTableHasAtMostSixtyFourColumns() {
    let head = "|" + String(repeating: " a |", count: 65)
    let md = "\(head)\n|" + String(repeating: "---|", count: 65) + "\n\(head)"
    guard case .table(let header, let alignments, let rows) = MarkdownBlock.parse(md).first else {
      Issue.record("65 columns should be a table")
      return
    }
    #expect(header.count == 64)
    #expect(alignments.count == 64)
    #expect(rows.map(\.count) == [64])
  }

  @Test func fencedAndIndentedCode() {
    #expect(
      MarkdownBlock.parse("```swift title=x\nlet x = 1\n\nlet y = 2\n```") == [
        .code(language: "swift", text: "let x = 1\n\nlet y = 2")
      ])
    #expect(MarkdownBlock.parse("~~~\n```\n~~~") == [.code(language: nil, text: "```")])
    #expect(
      MarkdownBlock.parse("````md\n```sh\nx\n```\n````\nafter") == [
        .code(language: "md", text: "```sh\nx\n```"), .paragraph("after"),
      ])
    #expect(MarkdownBlock.parse("```\nabc\ndef") == [.code(language: nil, text: "abc\ndef")])
    #expect(
      MarkdownBlock.parse("text\n\n    indented\n      more") == [
        .paragraph("text"), .code(language: nil, text: "indented\n  more"),
      ])
    #expect(
      MarkdownBlock.parse("10. a\n    ```\n    if x:\n        y\n    ```") == [
        .list(number: 10, items: [item("a", .code(language: nil, text: "if x:\n    y"))])
      ])
  }

  @Test func nestedBlockquotes() {
    let md = "> intro\n>\n> - one\n> - two\n>\n> ```\n>     code\n> ```\n>> inner\n>> > innermost"
    #expect(
      MarkdownBlock.parse(md) == [
        .quote([
          .paragraph("intro"), .list(number: nil, items: [item("one"), item("two")]),
          .code(language: nil, text: "    code"), .quote([.paragraph("inner"), .quote([.paragraph("innermost")])]),
        ])
      ])
  }

  @Test func horizontalRules() {
    #expect(MarkdownBlock.parse("a\n\n---\n\n***\n\n___\n\n- - -") == [.paragraph("a"), .rule, .rule, .rule, .rule])
  }

  @Test func strikethrough() {
    #expect(MarkdownBlock.parse("~~gone~~ kept") == [.paragraph(text(Run("gone", .strikethrough), Run(" kept")))])
    // A single tilde means "about" in replies, so only a double tilde strikes.
    #expect(MarkdownBlock.parse("takes ~5 min, not ~10 min") == [.paragraph("takes ~5 min, not ~10 min")])
  }

  @Test func autolinksAndBareURLs() {
    #expect(
      MarkdownBlock.parse("<https://a.example> https://b.example/x?y=1 www.c.example me@d.example.") == [
        .paragraph(
          text(
            Run("https://a.example", link: "https://a.example"), Run(" "),
            Run("https://b.example/x?y=1", link: "https://b.example/x?y=1"), Run(" "),
            Run("www.c.example", link: "http://www.c.example"), Run(" "),
            Run("me@d.example", link: "mailto:me@d.example"), Run(".")))
      ])
  }

  @Test func inlineCode() {
    #expect(
      MarkdownBlock.parse("run `make **test**` and ``a ` b``") == [
        .paragraph(text(Run("run "), Run("make **test**", .code), Run(" and "), Run("a ` b", .code)))
      ])
  }

  @Test func linksAndImages() {
    let md = """
      [inline](https://a.example "title") and [ref][r] and [collapsed][]

      [r]: https://r.example
      [collapsed]: https://c.example
      """
    #expect(
      MarkdownBlock.parse(md) == [
        .paragraph(
          text(
            Run("inline", link: "https://a.example"), Run(" and "), Run("ref", link: "https://r.example"),
            Run(" and "), Run("collapsed", link: "https://c.example")))
      ])
    #expect(
      MarkdownBlock.parse(
        "![diagram](https://i.example/d.png)\n[![badge](https://i.example/b.svg)](https://ci.example)")
        == [
          .images([
            .init(source: "https://i.example/d.png", alt: "diagram", link: nil),
            .init(source: "https://i.example/b.svg", alt: "badge", link: "https://ci.example"),
          ])
        ])
    #expect(
      MarkdownBlock.parse("See ![the *chart*](c.png) here") == [
        .paragraph(text(Run("See "), Run("the chart", image: "c.png"), Run(" here")))
      ])
  }

  @Test func hardLineBreaks() {
    #expect(
      MarkdownBlock.parse("two spaces  \nbackslash\\\nsoft\nend") == [.paragraph("two spaces\nbackslash\nsoft\nend")])
  }

  @Test func escapedCharactersAndEntities() {
    #expect(
      MarkdownBlock.parse("\\*not em\\* \\# \\`tick\\` \\[x\\](y) &amp; &copy; &#35;") == [
        .paragraph("*not em* # `tick` [x](y) & © #")
      ])
    #expect(MarkdownBlock.parse("\\# not a heading") == [.paragraph("# not a heading")])
  }

  @Test func footnotes() {
    #expect(
      MarkdownBlock.parse("Both[^x][^y]\n\n[^x]: X\n[^y]: Y").first
        == .paragraph(text(Run("Both"), Run("1", .footnote), Run("2", .footnote))))
    let md =
      "First[^a] and second[^2] and first again[^a].\n\n[^2]: Two **bold**.\n[^a]: Alpha.\n\n    More of alpha.\n[^unused]: Nobody cites this."
    #expect(
      MarkdownBlock.parse(md) == [
        .paragraph(
          text(
            Run("First"), Run("1", .footnote), Run(" and second"), Run("2", .footnote), Run(" and first again"),
            Run("1", .footnote), Run("."))),
        .footnotes([
          .init(number: 1, blocks: [.paragraph("Alpha."), .paragraph("More of alpha.")]),
          .init(number: 2, blocks: [.paragraph(text(Run("Two "), Run("bold", .strong), Run(".")))]),
        ]),
      ])
  }

  @Test func detailsAndSummary() {
    let md = """
      <details>
      <summary>Why it <b>failed</b></summary>

      The **cache** was cold.

      - one

      </details>

      after
      """
    #expect(
      MarkdownBlock.parse(md) == [
        .details(
          summary: text(Run("Why it "), Run("failed", .strong)), open: false,
          blocks: [
            .paragraph(text(Run("The "), Run("cache", .strong), Run(" was cold."))),
            .list(number: nil, items: [item("one")]),
          ]),
        .paragraph("after"),
      ])
    #expect(
      MarkdownBlock.parse("<details open><summary>Log</summary>line one</details>") == [
        .details(summary: "Log", open: true, blocks: [.paragraph("line one")])
      ])
    #expect(
      MarkdownBlock.parse(
        "<details>\n\nno summary\n\n<details><summary>inner</summary>\n\ndeep\n\n</details>\n</details>") == [
          .details(
            summary: "Details", open: false,
            blocks: [.paragraph("no summary"), .details(summary: "inner", open: false, blocks: [.paragraph("deep")])])
        ])
    #expect(
      MarkdownBlock.parse("<details><summary>cut off</summary>\n\nrest") == [
        .details(summary: "cut off", open: false, blocks: [.paragraph("rest")])
      ])
  }

  @Test func aSummaryOutsideDetailsKeepsItsText() {
    #expect(
      MarkdownBlock.parse("Intro\n\n<summary>Orphan text</summary>\n\nEnd") == [
        .paragraph("Intro"), .paragraph("Orphan text"), .paragraph("End"),
      ])
  }

  @Test func anImageInAnImagesAltIsPartOfTheAlt() {
    #expect(MarkdownBlock.parse("![a ![b](x) c](y)") == [.images([.init(source: "y", alt: "a b c", link: nil)])])
  }

  @Test func preformattedHTMLKeepsItsLines() {
    #expect(
      MarkdownBlock.parse("<pre>\nline1\n    indented\n</pre>") == [.paragraph(text(Run("line1\n    indented", .code)))]
    )
  }

  @Test func inlineAndBlockHTML() {
    #expect(
      MarkdownBlock.parse(
        "Press <kbd>⌘</kbd>+<kbd>K</kbd>,<br>then <b>bold</b> <em>it</em> <del>no</del> <a href=\"https://x.example\">x</a> <span>plain</span><!-- hidden -->."
      )
        == [
          .paragraph(
            text(
              Run("Press "), Run("⌘", .code), Run("+"), Run("K", .code), Run(",\nthen "), Run("bold", .strong),
              Run(" "), Run("it", .emphasis), Run(" "), Run("no", .strikethrough), Run(" "),
              Run("x", link: "https://x.example"), Run(" plain.")))
        ])
    #expect(
      MarkdownBlock.parse("<div align=\"center\">\n  <p>Hello &amp;\n  <i>world</i></p>\n</div>\n\n<!-- note -->") == [
        .paragraph(text(Run("Hello & "), Run("world", .emphasis)))
      ])
    #expect(MarkdownBlock.parse("<p>&rsquo;&nbsp;&euro;&#x41;&#0;</p>") == [.paragraph("’\u{00A0}€A\u{FFFD}")])
    #expect(
      MarkdownBlock.parse("<img src=\"https://i.example/a.png\" alt=\"logo\">") == [
        .images([.init(source: "https://i.example/a.png", alt: "logo", link: nil)])
      ])
  }

  @Test func crlfReadsAsLF() {
    let md = "# T\r\n\r\n- a\r\n  - b\r\n\r\n```\r\nc\r\n```\r\n"
    #expect(MarkdownBlock.parse(md) == MarkdownBlock.parse(md.replacingOccurrences(of: "\r\n", with: "\n")))
  }

  @Test func deepNestingStaysBoundedAndKeepsItsText() {
    func depth(_ blocks: [MarkdownBlock]) -> Int {
      1
        + (blocks.map { block -> Int in
          switch block {
          case .quote(let inner), .details(_, _, let inner): depth(inner)
          case .list(_, let items): items.map { depth($0.blocks) }.max() ?? 0
          default: 0
          }
        }.max() ?? 0)
    }
    let quotes = MarkdownBlock.parse(String(repeating: ">", count: 10_000) + " deep text")
    let lists = MarkdownBlock.parse(String(repeating: "- ", count: 10_000) + "deep text")
    let staircase = MarkdownBlock.parse(
      (0..<600).map { String(repeating: " ", count: $0 * 2) + "- item\($0)" }.joined(separator: "\n"))
    let details = MarkdownBlock.parse(String(repeating: "<details>\n\n", count: 1_000) + "deep text")
    let emphasis = MarkdownBlock.parse(
      String(repeating: "*", count: 10_000) + "deep text" + String(repeating: "*", count: 10_000))
    for blocks in [quotes, lists, staircase, details, emphasis] { #expect(depth(blocks) <= 34) }
    #expect("\(quotes)".contains("deep text"))
    #expect("\(lists)".contains("deep text"))
    #expect("\(staircase)".contains("item599"))
    #expect("\(details)".contains("deep text"))
    #expect("\(emphasis)".contains("deep text"))
  }

  /// Each input takes well under a second, and over two minutes when the work
  /// grows with the square of the input. The limit leaves room for a loaded runner.
  @Test func hostileHTMLParsesQuickly() {
    for unit in ["<!--", "<!x ", "<a b c ", "<a b=\"", "<b>x", "<details>"] {
      let md = "<div>\n" + String(repeating: unit, count: 20_000)
      let start = Date()
      _ = MarkdownBlock.parse(md)
      #expect(Date().timeIntervalSince(start) < 10, "\(unit)")
    }
  }

  @Test func aLongReplyParsesQuickly() {
    let section =
      "## Step\n\nSome **bold** text with `code` and a [link](https://x.example).\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\n"
    let md = String(repeating: section, count: 500)
    let start = Date()
    let blocks = MarkdownBlock.parse(md)
    #expect(blocks.count == 2_500)
    #expect(Date().timeIntervalSince(start) < 5)
  }
}
