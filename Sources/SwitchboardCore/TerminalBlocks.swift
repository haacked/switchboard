import Foundation

/// A block quote or a code block in a message's Markdown.
public struct SourceBlock: Equatable, Sendable {
  public enum Kind: Sendable { case quote, code }
  public var kind: Kind
  /// What the copy button copies: a quote's Markdown without one level of `>`, or a code block's content.
  public var text: String

  init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// A block quote or code block that Claude Code drew on the terminal screen.
public struct TerminalBlock: Equatable, Sendable {
  public var kind: SourceBlock.Kind
  /// Visible rows, 0 being the top of the screen.
  public var rows: ClosedRange<Int>
  public var copyText: String

  public init(kind: SourceBlock.Kind, rows: ClosedRange<Int>, copyText: String) {
    self.kind = kind
    self.rows = rows
    self.copyText = copyText
  }
}

/// The quotes and code blocks of a session's recent assistant messages, with the keys that matching compares.
/// Building it parses the messages, so a caller that matches many screens builds it once per transcript read.
public struct BlockSources: Equatable, Sendable {
  struct Keyed: Equatable, Sendable {
    var text: String
    var key: String
  }
  var quotes: [Keyed]
  var codes: [Keyed]

  /// `messages` are assistant message texts, newest first.
  public init(messages: [String]) {
    var quotes: [Keyed] = []
    var codes: [Keyed] = []
    for block in messages.flatMap(MarkdownBlock.sourceBlocks) {
      switch block.kind {
      case .quote: quotes.append(Keyed(text: block.text, key: TerminalBlocks.quoteKey(block.text)))
      case .code:
        let key = ClaudeScreen.squeezed(block.text)
        if !key.isEmpty { codes.append(Keyed(text: block.text, key: key)) }
      }
    }
    self.quotes = quotes
    self.codes = codes
  }
}

/// Finds the block quotes and code blocks on a Claude Code screen, and the Markdown each came from.
///
/// Claude Code draws a quote as rows that start with `▎` after the message's margin, and hard-wraps every
/// paragraph to the pane's width. It draws a fenced code block as colored text with no frame, so only the
/// transcript can show where a code block is.
public enum TerminalBlocks {
  /// A visible part of a block at the screen's edge has at least this many compared characters.
  static let minimumPartial = 12

  /// The blocks on the screen, ordered by their first row. `messages` are assistant message texts, newest first.
  static func find(rows: [String], messages: [String]) -> [TerminalBlock] {
    find(rows: rows, sources: BlockSources(messages: messages))
  }

  /// The blocks on the screen, ordered by their first row.
  public static func find(rows: [String], sources: BlockSources) -> [TerminalBlock] {
    let rows = screenRows(rows)
    var taken = Array(repeating: false, count: rows.count)
    var found: [TerminalBlock] = []

    for run in quoteRuns(rows) {
      let quoteRows = Array(rows[run])
      let key = quoteKey(quoteRows.map(afterBar).joined(separator: " "))
      guard !key.isEmpty else { continue }
      let text = matchQuote(key, run: run, lastRow: rows.count - 1, quotes: sources.quotes)
      found.append(TerminalBlock(kind: .quote, rows: run, copyText: text ?? screenQuoteText(quoteRows)))
      for row in run { taken[row] = true }
    }

    let keys = rows.map(ClaudeScreen.squeezed)
    var start = 0
    while start < rows.count {
      if let match = matchCode(at: start, keys: keys, taken: taken, codes: sources.codes) {
        found.append(TerminalBlock(kind: .code, rows: match.rows, copyText: match.text))
        start = match.rows.upperBound + 1
      } else {
        start += 1
      }
    }
    return found.sorted { $0.rows.lowerBound < $1.rows.lowerBound }
  }

  /// The copy text of a screen quote with no transcript match. `rows` are the quote's rows as the screen shows them.
  static func screenQuoteText(_ rows: [String]) -> String {
    var paragraphs: [String] = []
    var current: String?
    for row in rows {
      let body = afterBar(row)
      let trimmed = body.drop { $0 == " " }
      if trimmed.isEmpty {
        if let paragraph = current { paragraphs.append(paragraph) }
        current = nil
      } else if let paragraph = current {
        current = paragraph + (startsWithListMarker(trimmed) ? "\n" + body : " " + trimmed)
      } else {
        current = body
      }
    }
    if let paragraph = current { paragraphs.append(paragraph) }
    return paragraphs.joined(separator: "\n\n")
  }

  /// The rows without tmux's copy-mode position marker, `[n/m]` at the end of row 0, and without the `⏺` that
  /// starts a message's first row.
  static func screenRows(_ rows: [String]) -> [String] {
    rows.enumerated().map { index, row in
      var row = row
      if index == 0, let marker = row.range(of: #"\s*\[\d+/\d+\]\s*$"#, options: .regularExpression) {
        row.removeSubrange(marker)
      }
      if row.first == "⏺" { row = " " + row.dropFirst() }
      return row
    }
  }

  /// Runs of rows whose first character other than a space is `▎`, at the same column. A quote nested in a list
  /// item has its bar further right than a quote beside it.
  static func quoteRuns(_ rows: [String]) -> [ClosedRange<Int>] {
    var runs: [ClosedRange<Int>] = []
    var current: (start: Int, column: Int)?
    for (index, row) in rows.enumerated() {
      let column = row.firstIndex { $0 != " " }.flatMap {
        row[$0] == "▎" ? row.distance(from: row.startIndex, to: $0) : nil
      }
      if let open = current, open.column != column {
        runs.append(open.start...(index - 1))
        current = nil
      }
      if current == nil, let column { current = (index, column) }
    }
    if let open = current { runs.append(open.start...(rows.count - 1)) }
    return runs
  }

  /// A quote row's text after the bar and the one space that follows it, without trailing spaces.
  static func afterBar(_ row: String) -> String {
    guard let bar = row.firstIndex(of: "▎") else { return row }
    var body = row[row.index(after: bar)...]
    if body.first == " " { body = body.dropFirst() }
    return String(body.reversed().drop(while: \.isWhitespace).reversed())
  }

  private static func startsWithListMarker(_ text: Substring) -> Bool {
    text.range(of: #"^([-*•]|\d+[.)]) "#, options: .regularExpression) != nil
  }

  /// The letters and digits of a quote, lowercased, with each Markdown link reduced to its text. Claude Code drops
  /// the Markdown markup and a link's URL when it draws a quote, and wraps the text anywhere.
  static func quoteKey(_ text: String) -> String {
    let linkless = text.replacingOccurrences(
      of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    return String(linkless.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  /// The text of the transcript quote that the screen quote shows. A whole match in any message wins over a part
  /// cut by the screen's edge.
  private static func matchQuote(
    _ key: String, run: ClosedRange<Int>, lastRow: Int, quotes: [BlockSources.Keyed]
  ) -> String? {
    if let whole = quotes.first(where: { $0.key == key }) { return whole.text }
    guard key.count >= minimumPartial else { return nil }
    return quotes.first { quote in
      (run.lowerBound == 0 && quote.key.hasSuffix(key)) || (run.upperBound == lastRow && quote.key.hasPrefix(key))
    }?.text
  }

  /// The code block whose text the rows from `start` show. A whole block has a blank row or the screen's edge
  /// above and below it, because Claude Code puts a blank line around a fenced block. A block cut by the top of
  /// the screen starts at row 0 and shows the block's end. A block cut by the bottom ends at the last row and
  /// shows the block's start.
  private static func matchCode(
    at start: Int, keys: [String], taken: [Bool], codes: [BlockSources.Keyed]
  ) -> (rows: ClosedRange<Int>, text: String)? {
    guard !taken[start], !keys[start].isEmpty, start == 0 || keys[start - 1].isEmpty else { return nil }
    let last = keys.count - 1
    func endsBlock(_ row: Int) -> Bool { !keys[row].isEmpty && (row == last || keys[row + 1].isEmpty) }

    var candidates: [(rows: ClosedRange<Int>, text: String, whole: Bool)] = []
    for code in codes {
      var shown = ""
      for row in start...last {
        if taken[row] { break }
        shown += keys[row]
        // Only rows from the top of the screen can show a block's end without its start.
        let prefix = code.key.hasPrefix(shown)
        if !prefix, start != 0 || shown.utf8.count > code.key.utf8.count { break }
        if shown == code.key, endsBlock(row) {
          candidates.append((start...row, code.text, true))
          break
        }
        if start == 0, shown.count >= minimumPartial, code.key.hasSuffix(shown), endsBlock(row) {
          candidates.append((start...row, code.text, false))
        }
        if row == last, prefix, shown.count >= minimumPartial {
          candidates.append((start...row, code.text, false))
        }
      }
    }
    // A longer block that starts with a shorter block's text is the one the rows show.
    let wholes = candidates.filter(\.whole)
    guard let best = (wholes.isEmpty ? candidates : wholes).max(by: { $0.rows.count < $1.rows.count }) else {
      return nil
    }
    return (best.rows, best.text)
  }
}
