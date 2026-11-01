import Foundation

/// A block of Markdown. The app draws each block with SwiftUI's inline
/// Markdown, which handles emphasis, code spans, and links but no blocks.
public enum MarkdownBlock: Equatable, Sendable {
  /// A list item. `checked` is nil unless the item starts with `[ ]` or `[x]`.
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

  case heading(level: Int, text: String)
  case paragraph(String)
  /// `number` is the first item's number for a numbered list, or nil for bullets.
  case list(number: Int?, items: [Item])
  case code(language: String?, text: String)
  case quote([MarkdownBlock])
  /// Every row has one cell for each header cell.
  case table(header: [String], alignments: [Alignment], rows: [[String]])
  case rule

  /// Reads the blocks of a reply. Text that no rule below recognizes becomes a
  /// paragraph, so nothing is lost.
  public static func parse(_ markdown: String) -> [MarkdownBlock] {
    blocks(of: markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"), depth: 0)
  }

  /// Lists and quotes nest this deep at most. Deeper text becomes one paragraph,
  /// which keeps the recursion in the parser and in the view from overflowing
  /// the stack on a reply such as ten thousand `>`.
  private static let maxDepth = 32

  private static func blocks(of lines: [String], depth: Int) -> [MarkdownBlock] {
    guard depth <= maxDepth else {
      let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      return text.isEmpty ? [] : [.paragraph(text.joined(separator: "\n"))]
    }
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    func endParagraph() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
      paragraph = []
    }
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      i += 1
      if let fence = Self.fence(trimmed) {
        endParagraph()
        var body: [String] = []
        // An unclosed fence runs to the end, as a reply cut off mid-block does.
        while i < lines.count, !fence.closes(lines[i].trimmingCharacters(in: .whitespaces)) {
          body.append(Self.dedent(lines[i], by: Self.indent(line)))
          i += 1
        }
        i += 1
        blocks.append(.code(language: fence.info.isEmpty ? nil : fence.info, text: body.joined(separator: "\n")))
      } else if trimmed.isEmpty {
        endParagraph()
      } else if let heading = Self.heading(trimmed) {
        endParagraph()
        blocks.append(heading)
      } else if Self.isRule(trimmed) {
        endParagraph()
        blocks.append(.rule)
      } else if trimmed.hasPrefix(">") {
        endParagraph()
        var quoted = [Self.unquoted(trimmed)]
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
          quoted.append(Self.unquoted(lines[i].trimmingCharacters(in: .whitespaces)))
          i += 1
        }
        blocks.append(.quote(Self.blocks(of: quoted, depth: depth + 1)))
      } else if i < lines.count, let table = Self.table(header: trimmed, delimiter: lines[i]) {
        endParagraph()
        i += 1
        var rows: [[String]] = []
        while i < lines.count {
          let row = lines[i].trimmingCharacters(in: .whitespaces)
          guard row.contains("|"), !Self.startsBlock(row) else { break }
          let cells = Self.cells(row)
          rows.append((0..<table.header.count).map { $0 < cells.count ? cells[$0] : "" })
          i += 1
        }
        blocks.append(.table(header: table.header, alignments: table.alignments, rows: rows))
      } else if let first = Self.listItem(line) {
        endParagraph()
        let (list, next) = Self.list(lines, from: i - 1, first: first, depth: depth)
        blocks.append(list)
        i = next
      } else {
        paragraph.append(trimmed)
      }
    }
    endParagraph()
    return blocks
  }

  /// Whether a line begins a block of its own, which ends a table. A rule
  /// is not listed, because a table row contains a `|` and a rule does not.
  private static func startsBlock(_ trimmed: String) -> Bool {
    fence(trimmed) != nil || heading(trimmed) != nil || trimmed.hasPrefix(">") || listItem(trimmed) != nil
  }

  /// Reads the list that starts at `lines[start]`, and returns it with the
  /// index of the first line after it. A line indented deeper than the first
  /// item belongs to the item above it, and the item's lines are read as
  /// blocks of their own. A list item of the same kind that is not deeper
  /// starts the next item, even after blank lines. Any other line ends the list.
  private static func list(_ lines: [String], from start: Int, first: ListMarker, depth: Int) -> (MarkdownBlock, Int) {
    let base = indent(lines[start])
    func sibling(_ line: String) -> ListMarker? {
      listItem(line).flatMap { $0.numbered == first.numbered ? $0 : nil }
    }
    var items: [Item] = []
    // `indent` is how far the item's first deeper line is indented, up to the
    // marker's width. Every later line of the item loses the same amount, so
    // the lines keep their indentation relative to each other.
    var current: (marker: ListMarker, body: [String], indent: Int?)?
    func endItem() {
      guard let (marker, body, _) = current else { return }
      let checkbox = Self.checkbox(marker.text)
      items.append(Item(checked: checkbox.checked, blocks: Self.blocks(of: [checkbox.text] + body, depth: depth + 1)))
    }
    var i = start
    while i < lines.count {
      let line = lines[i]
      if line.isBlank {
        var next = i
        while next < lines.count, lines[next].isBlank { next += 1 }
        guard next < lines.count else { break }
        if indent(lines[next]) > base {
          current?.body += repeatElement("", count: next - i)
        } else if sibling(lines[next]) == nil {
          break
        }
        i = next
        continue
      }
      if indent(line) > base, let marker = current?.marker {
        let width = current?.indent ?? min(indent(line), marker.width)
        current?.indent = width
        current?.body.append(dedent(line, by: width))
      } else if let marker = sibling(line) {
        endItem()
        current = (marker, [], nil)
      } else {
        break
      }
      i += 1
    }
    endItem()
    return (.list(number: first.number, items: items), i)
  }

  private static func indent(_ line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.count
  }

  /// Removes up to `width` leading whitespace characters.
  private static func dedent(_ line: String, by width: Int) -> String {
    String(line.dropFirst(min(indent(line), width)))
  }

  private static func heading(_ line: String) -> MarkdownBlock? {
    let hashes = line.prefix { $0 == "#" }
    guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
    return .heading(level: hashes.count, text: line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces))
  }

  private static func isRule(_ line: String) -> Bool {
    let chars = line.filter { $0 != " " }
    return chars.count >= 3
      && (chars.allSatisfy { $0 == "-" } || chars.allSatisfy { $0 == "*" } || chars.allSatisfy { $0 == "_" })
  }

  /// Removes the `>` and the one space after it. The rest keeps its
  /// indentation, which a quoted code block needs.
  private static func unquoted(_ line: String) -> String {
    let rest = line.dropFirst()
    return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
  }

  private struct Fence {
    let character: Character
    let length: Int
    let info: String

    /// A fence closes on a line of only its character, at least as long as the opening.
    func closes(_ trimmed: String) -> Bool {
      let run = trimmed.prefix { $0 == character }
      return run.count >= length && run.count == trimmed.count
    }
  }

  /// A backtick fence's info text can't hold a backtick, so "```x``` y" is
  /// text with code spans.
  private static func fence(_ trimmed: String) -> Fence? {
    guard let character = trimmed.first, character == "`" || character == "~" else { return nil }
    let run = trimmed.prefix { $0 == character }
    let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
    guard run.count >= 3, !(character == "`" && info.contains("`")) else { return nil }
    return Fence(character: character, length: run.count, info: info)
  }

  /// A table has this many columns at most. Every row is padded to the header's
  /// width, so a wider header would let a few bytes of `|` rows build millions of cells.
  private static let maxColumns = 64

  /// A header row and the delimiter row under it that has one cell for each
  /// header cell. Both rows need a `|`.
  private static func table(header: String, delimiter: String) -> (header: [String], alignments: [Alignment])? {
    let delimiter = delimiter.trimmingCharacters(in: .whitespaces)
    guard header.contains("|"), delimiter.contains("|") else { return nil }
    let head = cells(header)
    let marks = cells(delimiter)
    guard !head.isEmpty, head.count <= maxColumns, marks.count == head.count else { return nil }
    var alignments: [Alignment] = []
    for mark in marks {
      let left = mark.hasPrefix(":")
      let right = mark.hasSuffix(":") && mark.count > 1
      let dashes = mark.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
      guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
      alignments.append(left && right ? .center : right ? .trailing : .leading)
    }
    return (head, alignments)
  }

  /// The cells of a row, split at each `|` that a backslash doesn't escape.
  private static func cells(_ row: String) -> [String] {
    var cells: [String] = []
    var cell = ""
    var characters = Substring(row).makeIterator()
    var escaped = false
    while let c = characters.next() {
      if escaped {
        cell.append(c == "|" ? "|" : "\\\(c)")
        escaped = false
      } else if c == "\\" {
        escaped = true
      } else if c == "|" {
        cells.append(cell)
        cell = ""
      } else {
        cell.append(c)
      }
    }
    if escaped { cell.append("\\") }
    cells.append(cell)
    // A leading and a trailing `|` frame the row and hold no cell.
    if row.hasPrefix("|") { cells.removeFirst() }
    if row.hasSuffix("|"), !row.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func checkbox(_ text: String) -> (checked: Bool?, text: String) {
    for (mark, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(mark) {
      return (checked, String(text.dropFirst(mark.count)))
    }
    return (nil, text)
  }

  private struct ListMarker {
    let text: String
    let number: Int?
    var numbered: Bool { number != nil }
    /// The column where the item's text starts: the line's own indentation,
    /// the marker, and the space after it. A line of the item that is indented
    /// at least this far lies inside the item's text.
    let width: Int
  }

  private static func listItem(_ line: String) -> ListMarker? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let lead = indent(line)
    for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
      return ListMarker(text: String(trimmed.dropFirst(2)), number: nil, width: lead + 2)
    }
    let digits = trimmed.prefix { $0.isNumber }
    let rest = trimmed.dropFirst(digits.count)
    if !digits.isEmpty, digits.count <= 9, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
      return ListMarker(
        text: String(rest.dropFirst(2)), number: Int(digits), width: lead + digits.count + 2)
    }
    return nil
  }
}

extension String {
  fileprivate var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}
