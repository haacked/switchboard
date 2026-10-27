import Foundation

/// Reads the scalars in a YAML document's block mappings into a dictionary
/// from each scalar's dotted key path to its value. It reads what PostHog/charts
/// state files use: nested mappings, plain and quoted scalars, block scalars,
/// and comments. It skips sequences, flow collections, and nulls. It isn't a
/// general YAML parser.
enum YAMLScalars {
  static func read(_ text: String) -> [String: String] {
    var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    var result: [String: String] = [:]
    var parents: [(indent: Int, key: String)] = []
    var i = 0

    /// Consumes the lines after line `i - 1` that are blank or indented more
    /// than `indent`. They belong to the entry that line `i - 1` starts.
    func takeNested(deeperThan indent: Int) -> [String] {
      var taken: [String] = []
      while i < lines.count, isBlank(lines[i]) || indentation(lines[i]) > indent {
        taken.append(lines[i])
        i += 1
      }
      return taken
    }

    while i < lines.count {
      let line = lines[i]
      i += 1
      let indent = indentation(line)
      let content = line.dropFirst(indent)
      if content.isEmpty || content.hasPrefix("#") { continue }
      if content.hasPrefix("-") {
        _ = takeNested(deeperThan: indent)
        continue
      }
      guard let (key, rest) = splitKey(content) else { continue }
      while let last = parents.last, last.indent >= indent { parents.removeLast() }
      let path = (parents.map(\.key) + [key]).joined(separator: ".")

      if rest.isEmpty || rest.hasPrefix("#") {
        parents.append((indent, key))
      } else if let header = BlockHeader(rest) {
        result[path] = header.value(of: takeNested(deeperThan: indent))
      } else if rest.first == "\"" || rest.first == "'" {
        var quoted = rest
        while unquote(quoted) == nil, i < lines.count {
          quoted += "\n" + lines[i]
          i += 1
        }
        result[path] = unquote(quoted)
      } else {
        let continued = takeNested(deeperThan: indent).filter { !isBlank($0) }
        let value = ([stripComment(rest)] + continued.map { stripComment($0.trimmingCharacters(in: .whitespaces)) })
          .joined(separator: " ")
        if !["null", "~"].contains(value) && !value.hasPrefix("[") && !value.hasPrefix("{") {
          result[path] = value
        }
      }
    }
    return result
  }

  private static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }

  private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " } }

  /// The key and the rest of the line after `key:`, or nil when the line
  /// holds no key.
  private static func splitKey(_ content: Substring) -> (String, String)? {
    let end: Substring.Index
    if content.first == "\"" || content.first == "'" {
      guard let close = content.dropFirst().firstIndex(of: content.first!) else { return nil }
      end = content.index(after: close)
      guard end < content.endIndex, content[end] == ":" else { return nil }
    } else {
      guard let colon = content.firstMatch(of: #/:(?= |$)/#)?.range.lowerBound else { return nil }
      end = colon
    }
    let rawKey = String(content[..<end]).trimmingCharacters(in: .whitespaces)
    let key = unquote(rawKey) ?? rawKey
    let rest = content[content.index(after: end)...].trimmingCharacters(in: .whitespaces)
    return (key, rest)
  }

  private static func stripComment(_ plain: String) -> String {
    guard let hash = plain.range(of: " #") else { return plain }
    return String(plain[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
  }

  /// The value of a single- or double-quoted scalar, or nil when its closing
  /// quote is missing. A line break inside the quotes reads as one space.
  private static func unquote(_ text: String) -> String? {
    guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
    var value = ""
    var chars = text.dropFirst()[...]
    while let c = chars.popFirst() {
      switch c {
      case quote where quote == "'" && chars.first == "'":
        chars.removeFirst()
        value.append("'")
      case quote:
        return value
      case "\\" where quote == "\"":
        guard let e = chars.popFirst() else { return nil }
        switch e {
        case "n": value.append("\n")
        case "t": value.append("\t")
        case "r": value.append("\r")
        case "0": value.append("\0")
        case "u":
          let hex = String(chars.prefix(4))
          chars = chars.dropFirst(4)
          if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
            value.unicodeScalars.append(scalar)
          }
        default: value.append(e)
        }
      case "\n":
        while let last = value.last, last == " " { value.removeLast() }
        while chars.first == " " { chars.removeFirst() }
        value.append(" ")
      default:
        value.append(c)
      }
    }
    return nil
  }

  /// The `|` or `>` that starts a block scalar, with its chomping indicator.
  private struct BlockHeader {
    var folded: Bool
    /// "-" strips the final line breaks, "+" keeps them all, and none keeps one.
    var chomping: Character?

    init?(_ rest: String) {
      guard let style = rest.first, style == "|" || style == ">" else { return nil }
      let indicators = rest.dropFirst().prefix { "+-0123456789".contains($0) }
      let after = rest.dropFirst(1 + indicators.count).trimmingCharacters(in: .whitespaces)
      guard after.isEmpty || after.hasPrefix("#") else { return nil }
      folded = style == ">"
      chomping = indicators.first { $0 == "-" || $0 == "+" }
    }

    func value(of body: [String]) -> String {
      let contentIndent = body.first { !isBlank($0) }.map(indentation) ?? 0
      var lines = body.map { String($0.dropFirst(contentIndent)) }
      var trailingBlanks = 0
      while lines.last?.isEmpty == true {
        lines.removeLast()
        trailingBlanks += 1
      }
      if lines.isEmpty { return "" }
      // Folding joins each run of text lines with spaces. Each blank line becomes a line break.
      let text =
        folded
        ? lines.split(separator: "", omittingEmptySubsequences: false).map { $0.joined(separator: " ") }
          .joined(separator: "\n")
        : lines.joined(separator: "\n")
      switch chomping {
      case "-": return text
      case "+": return text + String(repeating: "\n", count: 1 + trailingBlanks)
      default: return text + "\n"
      }
    }
  }
}
