import SwitchboardCore

/// The fields that a GraphQL query selects from one type, so the fake can
/// answer with those fields and no others. A field answers under its alias
/// when it has one. Arguments don't filter anything, and a type condition
/// selects its fields whatever the node's type.
struct Selection {
  private var fields: [(key: String, sub: Selection?)] = []

  /// The selection that `query` makes inside `... on <type> { … }`.
  init?(query: String, on type: String) {
    var parser = Parser(tokens: Selection.tokens(query))
    guard let start = parser.firstIndex(of: ["...", "on", type, "{"]) else { return nil }
    parser.index = start + 4
    self = parser.selectionSet()
  }

  private init(fields: [(key: String, sub: Selection?)]) { self.fields = fields }

  /// The node without the fields that the query doesn't select. A selected
  /// field that the node lacks stays absent.
  func project(_ node: JSON) -> JSON {
    switch node {
    case .array(let items): return .array(items.map(project))
    case .object(let object):
      var out: [String: JSON] = [:]
      for (key, sub) in fields {
        guard let value = object[key] else { continue }
        out[key] = sub.map { $0.project(value) } ?? value
      }
      return .object(out)
    default: return node
    }
  }

  private static func tokens(_ text: String) -> [String] {
    var tokens: [String] = []
    var word = ""
    func flush() {
      if !word.isEmpty { tokens.append(word) }
      word = ""
    }
    var dots = 0
    for c in text {
      if c == "." {
        flush()
        dots += 1
        if dots == 3 {
          tokens.append("...")
          dots = 0
        }
        continue
      }
      dots = 0
      if c.isLetter || c.isNumber || c == "_" || c == "$" {
        word.append(c)
      } else {
        flush()
        if "{}():".contains(c) { tokens.append(String(c)) }
      }
    }
    flush()
    return tokens
  }

  private struct Parser {
    var tokens: [String]
    var index = 0
    var fragments: [String: Selection] = [:]

    init(tokens: [String]) {
      self.tokens = tokens
      var i = 0
      while i + 4 < tokens.count {
        if tokens[i] == "fragment", tokens[i + 2] == "on", tokens[i + 4] == "{" {
          index = i + 5
          fragments[tokens[i + 1]] = selectionSet()
        }
        i += 1
      }
    }

    func firstIndex(of pattern: [String]) -> Int? {
      tokens.indices.first { tokens[$0...].starts(with: pattern) }
    }

    /// Reads from the token after `{` through the matching `}`.
    mutating func selectionSet() -> Selection {
      var fields: [(key: String, sub: Selection?)] = []
      while index < tokens.count, tokens[index] != "}" {
        let token = tokens[index]
        index += 1
        if token == "..." {
          if tokens[index] == "on" {
            // Skips "on", the type name, and "{".
            index += 3
            fields += selectionSet().fields
          } else {
            fields += fragments[tokens[index]]?.fields ?? []
            index += 1
          }
          continue
        }
        // The alias is the key, so skip ":" and the field name.
        if index < tokens.count, tokens[index] == ":" { index += 2 }
        if index < tokens.count, tokens[index] == "(" { skipArguments() }
        var sub: Selection?
        if index < tokens.count, tokens[index] == "{" {
          index += 1
          sub = selectionSet()
        }
        fields.append((token, sub))
      }
      index += 1
      return Selection(fields: fields)
    }

    mutating func skipArguments() {
      var depth = 0
      repeat {
        if tokens[index] == "(" { depth += 1 }
        if tokens[index] == ")" { depth -= 1 }
        index += 1
      } while depth > 0
    }
  }
}
