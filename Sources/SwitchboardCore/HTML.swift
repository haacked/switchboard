import Foundation
import cmark_gfm

/// The few parts of HTML that Markdown replies use. A tag that HTML doesn't
/// define, such as the `<T>` in `Array<T>`, stays as text.
enum HTML {
  struct Tag {
    var name: String
    var closing: Bool
    var selfClosing: Bool
    var attributes: [String: String]
  }

  enum Token {
    case text(String)
    /// Text that shows as written, such as an unknown tag.
    case literal(String)
    case tag(Tag)
  }

  static let styles: [String: MarkdownText.Style] = [
    "b": .strong, "strong": .strong, "i": .emphasis, "em": .emphasis, "cite": .emphasis, "var": .emphasis,
    "s": .strikethrough, "del": .strikethrough, "strike": .strikethrough,
    "code": .code, "kbd": .code, "samp": .code, "tt": .code, "pre": .code,
  ]
  static let void: Set = ["br", "hr", "img", "wbr", "input", "source", "col", "area", "meta", "link"]
  static let breaks: Set = ["br", "hr"]
  static let blocks: Set = [
    "p", "div", "li", "ul", "ol", "dl", "dt", "dd", "tr", "table", "thead", "tbody", "tfoot", "blockquote", "pre",
    "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer", "center", "figure", "figcaption",
  ]
  static let known: Set<String> = Set(styles.keys).union(void).union(blocks).union([
    "a", "abbr", "details", "summary", "span", "sub", "sup", "u", "ins", "mark", "small", "big", "q", "font",
    "picture", "th", "td", "caption", "colgroup", "nav", "main", "aside", "time", "dfn", "bdi", "bdo", "ruby", "rt",
    "rp",
  ])

  private static let tagPattern = try! NSRegularExpression(
    pattern:
      #"<!--[\s\S]*?(?:-->|$)|<[!?][^>]*(?:>|$)|<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\s+[^\s"'<>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(/?)>"#
  )
  private static let attributePattern = try! NSRegularExpression(
    pattern: #"([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)

  /// Splits HTML into text and tags. Comments and declarations drop out. An
  /// unclosed comment runs to the end, as in a browser. That also keeps the
  /// search linear when a block holds thousands of `<!--`.
  static func tokens(_ html: String) -> [Token] {
    let ns = html as NSString
    var tokens: [Token] = []
    var at = 0
    for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
      if match.range.location > at {
        tokens.append(.text(ns.substring(with: NSRange(location: at, length: match.range.location - at))))
      }
      at = match.range.location + match.range.length
      guard match.range(at: 2).location != NSNotFound else { continue }
      let name = ns.substring(with: match.range(at: 2)).lowercased()
      guard known.contains(name) else {
        tokens.append(.literal(ns.substring(with: match.range)))
        continue
      }
      var attributes: [String: String] = [:]
      let list = ns.substring(with: match.range(at: 3))
      let listNS = list as NSString
      for a in attributePattern.matches(in: list, range: NSRange(location: 0, length: listNS.length)) {
        let value = (2...4).lazy.map { a.range(at: $0) }.first { $0.location != NSNotFound }
        attributes[listNS.substring(with: a.range(at: 1)).lowercased()] =
          value.map { decode(listNS.substring(with: $0)) } ?? ""
      }
      tokens.append(
        .tag(
          Tag(
            name: name, closing: match.range(at: 1).length > 0, selfClosing: match.range(at: 4).length > 0,
            attributes: attributes)))
    }
    if at < ns.length { tokens.append(.text(ns.substring(from: at))) }
    return tokens
  }

  /// The text with each run of ASCII whitespace as one space. A no-break space stays.
  static func collapsed(_ string: String) -> String {
    var result = ""
    var space = false
    for c in string {
      if c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}" {
        space = true
      } else {
        if space { result.append(" ") }
        space = false
        result.append(c)
      }
    }
    return space ? result + " " : result
  }

  /// Replaces character references in text that came from an HTML block, with
  /// cmark-gfm's decoder. cmark-gfm already decodes them in Markdown text.
  static func decode(_ string: String) -> String {
    guard string.contains("&") else { return string }
    var buffer = cmark_strbuf()
    cmark_strbuf_init(cmark_get_default_mem_allocator(), &buffer, 0)
    defer { cmark_strbuf_free(&buffer) }
    var source = string
    source.withUTF8 { houdini_unescape_html_f(&buffer, $0.baseAddress, bufsize_t($0.count)) }
    return String(decoding: UnsafeBufferPointer(start: buffer.ptr, count: Int(buffer.size)), as: UTF8.self)
  }
}
