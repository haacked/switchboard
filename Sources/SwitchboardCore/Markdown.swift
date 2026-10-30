import Foundation

/// A block of Markdown. The app draws each block with SwiftUI's inline
/// Markdown, which handles emphasis, code spans, and links but no blocks.
public enum MarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  /// `number` is the first item's number for a numbered list, or nil for bullets.
  case list(number: Int?, items: [String])
  case code(language: String?, text: String)
  case quote(String)
  case rule

  /// Reads the blocks of a reply. Text that no rule below recognizes becomes a
  /// paragraph, so nothing is lost.
  public static func parse(_ markdown: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    func endParagraph() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
      paragraph = []
    }
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      i += 1
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        endParagraph()
        let fence = String(trimmed.prefix(3))
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        // An unclosed fence runs to the end, as a reply cut off mid-block does.
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
          body.append(lines[i])
          i += 1
        }
        i += 1
        blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
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
        blocks.append(.quote(quoted.joined(separator: "\n")))
      } else if let first = Self.listItem(line) {
        endParagraph()
        var items = [first.text]
        while i < lines.count {
          let indented = lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t")
          let next = Self.listItem(lines[i])
          if !indented, let next, next.numbered == first.numbered {
            items.append(next.text)
          } else if indented, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            // An indented item stays in its parent, as a line of its own. An
            // indented plain line continues the item above it.
            let text = lines[i].trimmingCharacters(in: .whitespaces)
            items[items.count - 1] += "\n" + (next.map { ($0.numbered ? "" : "• ") + $0.text } ?? text)
          } else {
            break
          }
          i += 1
        }
        blocks.append(.list(number: first.number, items: items))
      } else {
        paragraph.append(trimmed)
      }
    }
    endParagraph()
    return blocks
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

  private static func unquoted(_ line: String) -> String {
    String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
  }

  private static func listItem(_ line: String) -> (text: String, numbered: Bool, number: Int?)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
      return (String(trimmed.dropFirst(2)), false, nil)
    }
    let digits = trimmed.prefix { $0.isNumber }
    let rest = trimmed.dropFirst(digits.count)
    if !digits.isEmpty, digits.count <= 9, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
      return (String(rest.dropFirst(2)), true, Int(digits))
    }
    return nil
  }
}
