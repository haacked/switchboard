import Foundation
import cmark_gfm
import cmark_gfm_extensions

private typealias Node = UnsafeMutablePointer<cmark_node>

/// Text with inline styles: the content of a paragraph, heading, or table cell.
public struct MarkdownText: Equatable, Sendable, ExpressibleByStringLiteral {
  public struct Style: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let emphasis = Style(rawValue: 1 << 0)
    public static let strong = Style(rawValue: 1 << 1)
    public static let strikethrough = Style(rawValue: 1 << 2)
    public static let code = Style(rawValue: 1 << 3)
    /// A footnote reference. The run's text is the footnote's number.
    public static let footnote = Style(rawValue: 1 << 4)
  }

  public struct Run: Equatable, Sendable {
    public var text: String
    public var style: Style
    public var link: String?
    /// An image's source. The run's text is the image's alt text.
    public var image: String?

    public init(_ text: String, _ style: Style = [], link: String? = nil, image: String? = nil) {
      self.text = text
      self.style = style
      self.link = link
      self.image = image
    }
  }

  public var runs: [Run]

  public init(_ runs: [Run] = []) { self.runs = runs }
  public init(stringLiteral value: String) { self.init(value.isEmpty ? [] : [Run(value)]) }

  /// The text without its styles and links. An image gives its alt text.
  public var plain: String { runs.map(\.text).joined() }

  /// Appends a run, and joins it to the last run when the two differ only in text.
  mutating func append(_ run: Run) {
    guard !run.text.isEmpty || run.image != nil else { return }
    if let last = runs.last, last.image == nil, run.image == nil, !run.style.contains(.footnote),
      last.style == run.style, last.link == run.link
    {
      runs[runs.count - 1].text += run.text
    } else {
      runs.append(run)
    }
  }

  /// Removes the whitespace at the start and the end.
  func trimmed() -> MarkdownText {
    var runs = runs
    while let first = runs.first, first.image == nil, first.text.first?.isWhitespace ?? true {
      if let start = first.text.firstIndex(where: { !$0.isWhitespace }) {
        runs[0].text = String(first.text[start...])
      } else {
        runs.removeFirst()
      }
    }
    while let last = runs.last, last.image == nil, last.text.last?.isWhitespace ?? true {
      if let end = last.text.lastIndex(where: { !$0.isWhitespace }) {
        runs[runs.count - 1].text = String(last.text[...end])
      } else {
        runs.removeLast()
      }
    }
    return MarkdownText(runs)
  }
}

/// A block of GitHub Flavored Markdown. `parse` reads a reply with cmark-gfm,
/// GitHub's own parser, and turns its tree into these blocks for the app to draw.
public enum MarkdownBlock: Equatable, Sendable {
  /// A list item. `checked` is nil unless the item is a task.
  public struct Item: Equatable, Sendable {
    public var checked: Bool?
    public var blocks: [MarkdownBlock]

    public init(checked: Bool?, blocks: [MarkdownBlock]) {
      self.checked = checked
      self.blocks = blocks
    }
  }

  public enum Alignment: Equatable, Sendable {
    case leading, center, trailing
  }

  public struct Image: Equatable, Sendable {
    public var source: String
    public var alt: String
    public var link: String?

    public init(source: String, alt: String, link: String?) {
      self.source = source
      self.alt = alt
      self.link = link
    }
  }

  public struct Footnote: Equatable, Sendable {
    public var number: Int
    public var blocks: [MarkdownBlock]

    public init(number: Int, blocks: [MarkdownBlock]) {
      self.number = number
      self.blocks = blocks
    }
  }

  case heading(level: Int, text: MarkdownText)
  case paragraph(MarkdownText)
  /// A paragraph that holds only images.
  case images([Image])
  /// `number` is the first item's number for a numbered list, or nil for bullets.
  case list(number: Int?, items: [Item])
  case code(language: String?, text: String)
  case quote([MarkdownBlock])
  /// Every row has one cell for each header cell.
  case table(header: [MarkdownText], alignments: [Alignment], rows: [[MarkdownText]])
  case rule
  /// An HTML `<details>` element. `open` says whether it starts expanded.
  case details(summary: MarkdownText, open: Bool, blocks: [MarkdownBlock])
  /// The footnote definitions, in the order the text first cites them. cmark-gfm
  /// moves them to the end of the document and drops the ones nothing cites.
  case footnotes([Footnote])

  public static func parse(_ markdown: String) -> [MarkdownBlock] {
    withDocument(markdown) { blocks(of: $0, depth: 0) } ?? []
  }

  /// Parses `markdown` and passes the document to `body`, or returns nil when cmark-gfm fails.
  private static func withDocument<T>(
    _ markdown: String, options: Int32 = 0, _ body: (Node) -> T
  ) -> T? {
    _ = registered
    // A single tilde means "about" in replies, such as "~5 min", so only a
    // double tilde strikes text through.
    guard let parser = cmark_parser_new(options | CMARK_OPT_FOOTNOTES | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE) else {
      return nil
    }
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "tasklist", "autolink"] {
      if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
    }
    cmark_parser_feed(parser, markdown, markdown.utf8.count)
    guard let document = cmark_parser_finish(parser) else { return nil }
    defer { cmark_node_free(document) }
    return body(document)
  }

  /// cmark-gfm registers its extensions in a global list without a lock, so
  /// this registers them once.
  private static let registered: Void = cmark_gfm_core_extensions_ensure_registered()

  /// Blocks nest this deep at most. A deeper container becomes one paragraph of
  /// its text. The limit keeps the recursion here and in the view from
  /// overflowing the stack on a reply such as ten thousand `>`.
  static let maxDepth = 32

  /// A table has this many columns at most. A wider table loses the columns past it.
  static let maxColumns = 64

  private static func blocks(of parent: Node, depth: Int) -> [MarkdownBlock] {
    guard depth <= maxDepth else {
      let text = plainText(parent)
      return text.isEmpty ? [] : [.paragraph(MarkdownText(stringLiteral: text))]
    }
    var builder = BlockBuilder(depth: depth)
    var footnotes: [Footnote] = []
    for node in children(parent) {
      switch kind(node) {
      case "html_block":
        builder.html(literal(node))
      case "footnote_definition":
        footnotes.append(Footnote(number: footnotes.count + 1, blocks: blocks(of: node, depth: depth + 1)))
      default:
        if let block = block(node, depth: builder.depth) { builder.append(block) }
      }
    }
    var blocks = builder.finish()
    if !footnotes.isEmpty { blocks.append(.footnotes(footnotes)) }
    return blocks
  }

  private static func block(_ node: Node, depth: Int) -> MarkdownBlock? {
    switch kind(node) {
    case "paragraph":
      return textBlock(inlines(node))
    case "heading":
      return .heading(level: Int(cmark_node_get_heading_level(node)), text: inlines(node))
    case "list":
      let number = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST ? Int(cmark_node_get_list_start(node)) : nil
      let items = children(node).map { item in
        Item(
          checked: kind(item) == "tasklist" ? cmark_gfm_extensions_get_tasklist_item_checked(item) : nil,
          blocks: blocks(of: item, depth: depth + 1))
      }
      return .list(number: number, items: items)
    case "code_block":
      let info = string(cmark_node_get_fence_info(node)).split(whereSeparator: \.isWhitespace).first.map(String.init)
      return .code(language: info, text: codeText(node))
    case "block_quote":
      return .quote(blocks(of: node, depth: depth + 1))
    case "thematic_break":
      return .rule
    case "table":
      return table(node)
    default:
      return nil
    }
  }

  /// A paragraph of only images and whitespace becomes `.images`.
  fileprivate static func textBlock(_ text: MarkdownText) -> MarkdownBlock? {
    let text = text.trimmed()
    if text.runs.isEmpty { return nil }
    let images = text.runs.compactMap { run in run.image.map { Image(source: $0, alt: run.text, link: run.link) } }
    if !images.isEmpty, text.runs.allSatisfy({ $0.image != nil || $0.text.allSatisfy(\.isWhitespace) }) {
      return .images(images)
    }
    return .paragraph(text)
  }

  private static func table(_ node: Node) -> MarkdownBlock {
    let count = Int(cmark_gfm_extensions_get_table_columns(node))
    let columns = min(count, maxColumns)
    let marks = cmark_gfm_extensions_get_table_alignments(node)
    let alignments: [Alignment] = (0..<columns).map { i in
      switch marks?[i] {
      case UInt8(ascii: "c"): .center
      case UInt8(ascii: "r"): .trailing
      default: .leading
      }
    }
    var rows = children(node).map { row in
      let cells = children(row).prefix(columns).map { inlines($0) }
      return cells + Array(repeating: MarkdownText(), count: columns - cells.count)
    }
    let header = rows.isEmpty ? [] : rows.removeFirst()
    return .table(header: header, alignments: alignments, rows: rows)
  }

  /// The text of a node's inlines, with their styles and links. It walks the
  /// tree with cmark's iterator, so deep emphasis needs no recursion.
  private static func inlines(_ parent: Node) -> MarkdownText {
    var builder = InlineBuilder()
    guard let iterator = cmark_iter_new(parent) else { return MarkdownText() }
    defer { cmark_iter_free(iterator) }
    // The first event enters the parent itself.
    _ = cmark_iter_next(iterator)
    while case let event = cmark_iter_next(iterator), event != CMARK_EVENT_DONE {
      guard let node = cmark_iter_get_node(iterator), node != parent else { continue }
      let entering = event == CMARK_EVENT_ENTER
      switch kind(node) {
      // cmark-gfm's iterator also exits a footnote reference, so leaves act on entering.
      case "text": if entering { builder.add(literal(node)) }
      case "softbreak", "linebreak": if entering { builder.add("\n") }
      case "code": if entering { builder.add(literal(node), .code) }
      case "html_inline": if entering { builder.tag(literal(node)) }
      case "footnote_reference": if entering { builder.add(literal(node), .footnote) }
      case "emph": entering ? builder.push(style: .emphasis) : builder.pop()
      case "strong": entering ? builder.push(style: .strong) : builder.pop()
      case "strikethrough": entering ? builder.push(style: .strikethrough) : builder.pop()
      case "link": entering ? builder.push(link: string(cmark_node_get_url(node))) : builder.pop()
      case "image": entering ? builder.beginImage() : builder.endImage(source: string(cmark_node_get_url(node)))
      default: break
      }
    }
    return builder.text
  }

  /// The text of every node under `parent`, without styles.
  private static func plainText(_ parent: Node) -> String {
    guard let text = cmark_render_plaintext(parent, CMARK_OPT_DEFAULT, 0) else { return "" }
    defer { free(text) }
    return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static func children(_ node: Node) -> [Node] {
    var nodes: [Node] = []
    var child = cmark_node_first_child(node)
    while let node = child {
      nodes.append(node)
      child = cmark_node_next(node)
    }
    return nodes
  }

  /// cmark-gfm's name for the node's type. It names no footnote type, so
  /// those get names here.
  private static func kind(_ node: Node) -> String {
    switch cmark_node_get_type(node) {
    case CMARK_NODE_FOOTNOTE_DEFINITION: "footnote_definition"
    case CMARK_NODE_FOOTNOTE_REFERENCE: "footnote_reference"
    default: string(cmark_node_get_type_string(node))
    }
  }
  private static func literal(_ node: Node) -> String { string(cmark_node_get_literal(node)) }
  /// A code block's text without the newline that cmark-gfm keeps after its last line.
  private static func codeText(_ node: Node) -> String {
    var text = literal(node)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
  }
  private static func string(_ c: UnsafePointer<CChar>?) -> String { c.map { String(cString: $0) } ?? "" }
}

extension MarkdownBlock {
  /// The block quotes and code blocks of `markdown`, in order, as a copy button copies them. A code block inside
  /// a quote is part of the quote.
  public static func sourceBlocks(in markdown: String) -> [SourceBlock] {
    // Swift reads "\r\n" as one character. cmark-gfm counts it as one line break.
    let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    var found: [SourceBlock] = []
    func walk(_ parent: Node, depth: Int) {
      guard depth <= maxDepth else { return }
      for node in children(parent) {
        switch kind(node) {
        case "code_block":
          found.append(SourceBlock(kind: .code, text: codeText(node)))
        case "block_quote":
          let first = Int(cmark_node_get_start_line(node)) - 1
          let last = min(Int(cmark_node_get_end_line(node)), lines.count) - 1
          guard first >= 0, first <= last else { continue }
          let column = Int(cmark_node_get_start_column(node)) - 1
          let text = (first...last).map { quoteLine(lines[$0], column: column, opening: $0 == first) }
          found.append(SourceBlock(kind: .quote, text: text.joined(separator: "\n")))
        default:
          walk(node, depth: depth + 1)
        }
      }
    }
    withDocument(markdown, options: CMARK_OPT_SOURCEPOS) { walk($0, depth: 0) }
    return found
  }

  /// A quote's line without its container's prefix, its `>`, and the one space after that. The prefix is the
  /// `column` characters before the quote, such as a list item's marker on the quote's first line or its
  /// indent on the others. A lazy continuation line has no `>` and keeps only its text.
  private static func quoteLine(_ line: Substring, column: Int, opening: Bool) -> String {
    let prefix = opening ? column : min(column, line.prefix { $0 == " " }.count)
    let rest = line.dropFirst(prefix).drop { $0 == " " }
    guard rest.first == ">" else { return String(rest) }
    let body = rest.dropFirst()
    return String(body.first == " " ? body.dropFirst() : body)
  }
}

/// Collects a container's blocks, and nests the blocks between an HTML
/// `<details>` and its `</details>` inside a `.details` block. cmark-gfm leaves
/// each tag in an HTML block of its own when blank lines surround the Markdown
/// between them.
private struct BlockBuilder {
  private struct Frame {
    var summary: MarkdownText?
    var open = false
    var blocks: [MarkdownBlock] = []
  }

  /// The bottom frame is the container. Each frame above it is an open `<details>`.
  private var frames = [Frame()]
  /// The `<details>` tags that went past the depth limit and opened no frame.
  private var skipped = 0
  private let base: Int

  init(depth: Int) { base = depth }

  /// The depth of a block that is appended now.
  var depth: Int { base + frames.count - 1 }

  mutating func append(_ block: MarkdownBlock) { frames[frames.count - 1].blocks.append(block) }

  /// Reads an HTML block's tags. The text between them becomes a paragraph.
  mutating func html(_ html: String) {
    var text = InlineBuilder(collapsesWhitespace: true)
    var summary: InlineBuilder?
    func flush() {
      if let block = MarkdownBlock.textBlock(text.text) { append(block) }
      text = InlineBuilder(collapsesWhitespace: true)
    }
    func endSummary() {
      if let s = summary, frames.count > 1 { frames[frames.count - 1].summary = s.text.trimmed() }
      summary = nil
    }
    for token in HTML.tokens(html) {
      guard case .tag(let tag) = token, ["details", "summary"].contains(tag.name) else {
        if summary != nil { summary?.feed(token) } else { text.feed(token) }
        continue
      }
      switch (tag.name, tag.closing) {
      case ("details", false):
        flush()
        endSummary()
        if depth < MarkdownBlock.maxDepth {
          frames.append(Frame(open: tag.attributes["open"] != nil))
        } else {
          skipped += 1
        }
      case ("details", true):
        flush()
        endSummary()
        if skipped > 0 { skipped -= 1 } else { close() }
      case ("summary", false):
        // A summary outside an open `<details>` stays as text.
        guard frames.count > 1, skipped == 0 else { continue }
        flush()
        summary = InlineBuilder(collapsesWhitespace: true)
      default:
        endSummary()
      }
    }
    endSummary()
    flush()
  }

  private mutating func close() {
    guard frames.count > 1 else { return }
    let frame = frames.removeLast()
    let summary = frame.summary.flatMap { $0.runs.isEmpty ? nil : $0 } ?? "Details"
    append(.details(summary: summary, open: frame.open, blocks: frame.blocks))
  }

  /// Closes every `<details>` that is still open, as a browser does at the end
  /// of a document.
  mutating func finish() -> [MarkdownBlock] {
    while frames.count > 1 { close() }
    return frames[0].blocks
  }
}

/// Builds styled text from text and the tags around it, from both Markdown and HTML.
private struct InlineBuilder {
  private struct Frame {
    /// The HTML tag that opened the frame, or nil for a Markdown span.
    var tag: String?
    var style: MarkdownText.Style
    var link: String?
  }

  private(set) var text = MarkdownText()
  private var frames: [Frame] = []
  /// The alt text of the image that is open, which collects its text as plain text.
  private var alt: String?
  /// The images open inside the image whose alt text is collecting. Their text joins its alt.
  private var innerImages = 0
  /// The `<pre>` elements that are open. Their text keeps its whitespace.
  private var preformatted = 0
  /// HTML text collapses each run of whitespace to one space, as a browser shows it.
  let collapsesWhitespace: Bool

  init(collapsesWhitespace: Bool = false) { self.collapsesWhitespace = collapsesWhitespace }

  /// Spans nest this deep at most. The limit keeps the style of each run quick
  /// to find. A deeper span adds no style.
  private static let maxFrames = 64
  /// The Markdown spans that opened past `maxFrames` and pushed no frame.
  /// `pop` ends these before it removes a frame.
  private var skipped = 0

  private var style: MarkdownText.Style { frames.reduce([]) { $0.union($1.style) } }
  private var link: String? { frames.last { $0.link != nil }?.link }

  mutating func add(_ string: String, _ extra: MarkdownText.Style = []) {
    if alt != nil {
      alt? += string
      return
    }
    text.append(MarkdownText.Run(string, style.union(extra), link: link))
  }

  mutating func image(source: String, alt: String) {
    text.append(MarkdownText.Run(alt, style, link: link, image: source))
  }

  mutating func beginImage() {
    if alt == nil { alt = "" } else { innerImages += 1 }
  }

  mutating func endImage(source: String) {
    guard innerImages == 0 else {
      innerImages -= 1
      return
    }
    image(source: source, alt: alt ?? "")
    alt = nil
  }

  mutating func push(style: MarkdownText.Style = [], link: String? = nil, tag: String? = nil) {
    guard frames.count < Self.maxFrames else {
      if tag == nil { skipped += 1 }
      return
    }
    frames.append(Frame(tag: tag, style: style, link: link))
  }

  /// Ends the innermost Markdown span. An HTML tag that is still open inside it stays open.
  mutating func pop() {
    if skipped > 0 {
      skipped -= 1
    } else if let i = frames.lastIndex(where: { $0.tag == nil }) {
      frames.remove(at: i)
    }
  }

  /// Reads an inline HTML node, which cmark-gfm gives one tag at a time.
  mutating func tag(_ html: String) {
    for token in HTML.tokens(html) { feed(token) }
  }

  mutating func feed(_ token: HTML.Token) {
    switch token {
    case .text(let string):
      guard collapsesWhitespace, preformatted == 0 else { return add(HTML.decode(string)) }
      var string = HTML.collapsed(HTML.decode(string))
      if string.hasPrefix(" "), text.runs.last.map({ $0.image == nil && $0.text.last?.isWhitespace == true }) ?? true {
        string.removeFirst()
      }
      add(string)
    case .literal(let string):
      add(string)
    case .tag(let tag):
      if tag.name == "pre", !tag.selfClosing { preformatted = max(0, preformatted + (tag.closing ? -1 : 1)) }
      if HTML.breaks.contains(tag.name) {
        lineBreak()
      } else if tag.name == "img" {
        if let source = tag.attributes["src"] { image(source: source, alt: tag.attributes["alt"] ?? "") }
      } else {
        if tag.closing, let i = frames.lastIndex(where: { $0.tag == tag.name }) { frames.remove(at: i) }
        if HTML.blocks.contains(tag.name) { lineBreak() }
        if !tag.closing, !tag.selfClosing, !HTML.void.contains(tag.name) {
          push(style: HTML.styles[tag.name] ?? [], link: tag.name == "a" ? tag.attributes["href"] : nil, tag: tag.name)
        }
      }
    }
  }

  /// Starts a new line, unless the text is empty or already ends one.
  private mutating func lineBreak() {
    if let i = text.runs.indices.last, text.runs[i].image == nil {
      while text.runs[i].text.last == " " { text.runs[i].text.removeLast() }
      if text.runs[i].text.isEmpty { text.runs.removeLast() }
    }
    if let last = text.runs.last, last.image != nil || last.text.last != "\n" { add("\n") }
  }
}

extension MarkdownText {
  /// The text with a backslash before each character that could start
  /// Markdown syntax, so that Markdown shows it as it is and makes no link,
  /// image, emphasis, list, or HTML of it. Other punctuation stays bare, so
  /// that `sb --json` shows readable text.
  /// cmark-gfm finds email addresses after it resolves the backslashes, so a
  /// word joiner, which draws nothing, goes before each `@`.
  /// It walks Unicode scalars, as cmark-gfm does. A grapheme cluster would
  /// hide a bracket behind a prepend or combining mark.
  public static func escaped(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var word = ""
    var lineStart = true
    var number = false
    for (i, c) in scalars.enumerated() {
      let next = i + 1 < scalars.count ? scalars[i + 1] : nil
      var escape = alwaysEscaped.contains(c)
      // A list marker, a heading underline, or an ordered list number at the start of a line.
      if lineStart, "-+=".unicodeScalars.contains(c) { escape = true }
      if number, ".)".unicodeScalars.contains(c) { escape = true }
      // GFM turns `scheme://`, `mailto:`, `xmpp:`, and `www.` into links.
      if c == ":", next == "/" || ["mailto", "xmpp"].contains(word.lowercased()) { escape = true }
      if c == ".", word.lowercased() == "www" { escape = true }
      if c == "@" { out.append("\u{2060}") }
      if escape { out.append("\\") }
      out.append(c)
      number = (lineStart || number) && ("0"..."9").contains(c)
      if c == "\n" || c == "\r" {
        lineStart = true
      } else if !c.properties.isWhitespace {
        lineStart = false
      }
      word = c.properties.isAlphabetic ? word + String(c) : ""
    }
    return String(out)
  }

  static let alwaysEscaped = Set("\\`*_[]<>!#|~&".unicodeScalars)
}

extension MarkdownBlock {
  /// The block's text without styles, for a paragraph, a heading, a list,
  /// or a quote. Other blocks give none.
  public var plainText: String {
    switch self {
    case .paragraph(let text), .heading(_, let text): text.plain
    case .list(_, let items): items.flatMap(\.blocks).map(\.plainText).joined(separator: " ")
    case .quote(let blocks): blocks.map(\.plainText).joined(separator: " ")
    default: ""
    }
  }
}
