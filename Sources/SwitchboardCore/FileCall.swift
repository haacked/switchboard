import Foundation

/// An Edit, Write, or Read call, as its permission dialog shows it. The rules
/// come from Claude Code 2.1.322's dialogs:
///
/// - The dialog's title names the action: `Edit file`, `Create file`,
///   `Overwrite file`, or `Read file`.
/// - Edit and Write show the file's path below the title, relative to the
///   session's cwd. Read shows `Read(<path>)` between the dashed rules.
/// - Between the dashed rules, Edit and Write show numbered rows. A diff row
///   has a marker after its number: a space for a context line, `-` for a
///   removed line, and `+` for an added one. A new file's rows have no
///   marker. A row that Claude Code wraps continues on a row without a
///   number, and the break can fall inside a word.
///
/// Claude Code pads rows with spaces and breaks them inside words, so every
/// comparison ignores white space. A dialog taller than the pane has lost its
/// title, so it is never the card's.
struct FileCall {
  enum Change {
    /// The old and new strings, without white space.
    case edit(old: String, new: String, everywhere: Bool)
    /// The file's whole content, without white space.
    case write(String)
    case read
  }

  var path: String
  var change: Change

  /// The card's call, or nil when the card's tool isn't one of these or its
  /// input lacks what the dialog must show. An Edit whose strings differ
  /// only in white space is nil, because its dialog would match every edit
  /// of the same text. A Read with any parameter besides the path is nil,
  /// because its dialog wasn't captured.
  init?(_ card: Card) {
    guard card.kind == .permission, let file = card.input["file_path"]?.string, file.hasPrefix("/") else {
      return nil
    }
    path = FileCall.normalized(file)
    let squeezed = ClaudeScreen.squeezed
    switch card.tool {
    case "Edit":
      guard let old = card.input["old_string"]?.string.map(squeezed),
        let new = card.input["new_string"]?.string.map(squeezed),
        !old.isEmpty, old != new
      else { return nil }
      change = .edit(old: old, new: new, everywhere: card.input["replace_all"]?.bool == true)
    case "Write":
      guard let content = card.input["content"]?.string.map(squeezed), !content.isEmpty else { return nil }
      change = .write(content)
    case "Read":
      guard card.input.object?.keys.allSatisfy({ $0 == "file_path" }) == true else { return nil }
      change = .read
    default:
      return nil
    }
  }

  /// Whether the dialog names this call's file and shows its change. `cwd`
  /// resolves a relative path. Without it, only an absolute path matches.
  func shows(_ dialog: [String], cwd: String?) -> Bool {
    guard let (head, rows) = ClaudeScreen.dashedBlock(dialog), let title = head.first else { return false }
    let shownPath = head.dropFirst().joined()
    switch change {
    case .read:
      let call = rows.map { $0.trimmingCharacters(in: .whitespaces) }.joined()
      guard title == "Read file", head.count == 1, call.hasPrefix("Read("), call.hasSuffix(")") else { return false }
      return names(String(call.dropFirst(5).dropLast()), cwd)
    case .edit(let old, let new, let everywhere):
      guard title == "Edit file", names(shownPath, cwd), let diff = FileCall.diff(rows) else {
        return false
      }
      return FileCall.replaces(old, new, everywhere: everywhere, in: diff.old, giving: diff.new)
    case .write(let content):
      guard names(shownPath, cwd) else { return false }
      switch title {
      case "Create file": return FileCall.numbered(rows).map { ClaudeScreen.squeezed($0.joined()) } == content
      case "Overwrite file": return FileCall.diff(rows)?.new == content
      default: return false
      }
    }
  }

  /// Whether a path that the dialog shows resolves to this call's file.
  private func names(_ shown: String, _ cwd: String?) -> Bool {
    if shown.hasPrefix("/") { return FileCall.normalized(shown) == path }
    guard !shown.isEmpty, let cwd, cwd.hasPrefix("/") else { return false }
    return FileCall.normalized(URL(fileURLWithPath: cwd).appendingPathComponent(shown).path) == path
  }

  /// The path with `.` and `..` resolved. Symbolic links stay as they are,
  /// because Claude Code shows the path that it was given.
  private static func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardized.path
  }

  /// Whether replacing `old` in the old side gives the new side. Every
  /// occurrence is replaced when `everywhere` is set. Otherwise one
  /// occurrence is, and the context around it must match on both sides.
  static func replaces(_ old: String, _ new: String, everywhere: Bool, in before: String, giving after: String) -> Bool
  {
    if everywhere { return before.contains(old) && before.replacingOccurrences(of: old, with: new) == after }
    var start = before.startIndex
    while let found = before.range(of: old, range: start..<before.endIndex) {
      if before.replacingCharacters(in: found, with: new) == after { return true }
      start = before.index(after: found.lowerBound)
    }
    return false
  }

  /// A diff's old side (context and removed rows) and new side (context and
  /// added rows), without white space. It is nil when a row has no marker.
  static func diff(_ rows: ArraySlice<String>) -> (old: String, new: String)? {
    guard let texts = numbered(rows) else { return nil }
    var old = ""
    var new = ""
    for text in texts {
      guard let marker = text.first, " +-".contains(marker) else { return nil }
      let body = ClaudeScreen.squeezed(String(text.dropFirst()))
      if marker != "+" { old += body }
      if marker != "-" { new += body }
    }
    return (old, new)
  }

  /// The text of each row after its gutter. The first row's gutter is
  /// spaces, its line number, and a space, and every row's gutter has that
  /// width. A row that continues a wrapped row has spaces in place of the
  /// number. It is nil when a row doesn't fit, as when the block isn't
  /// numbered.
  static func numbered(_ rows: ArraySlice<String>) -> [String]? {
    guard let first = rows.first, let gutter = first.range(of: "^ *[0-9]+ ", options: .regularExpression) else {
      return nil
    }
    let width = first.distance(from: first.startIndex, to: gutter.upperBound)
    var texts: [String] = []
    for row in rows {
      let padded = row.count > width ? row : row.padding(toLength: width + 1, withPad: " ", startingAt: 0)
      guard padded.prefix(width).range(of: "^ *[0-9]* $", options: .regularExpression) != nil else { return nil }
      texts.append(String(padded.dropFirst(width)))
    }
    return texts
  }
}
