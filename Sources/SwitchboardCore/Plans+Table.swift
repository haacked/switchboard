import Foundation

extension Plans {
  static let separatorCell = try! NSRegularExpression(pattern: #"^\s*:?-+:?\s*$"#)

  /// The ranges of the first start marker and the first end marker after
  /// it. An end marker before the first start marker leaves no end.
  static func markers(_ markdown: String) -> (start: Range<String.Index>, end: Range<String.Index>?)? {
    guard let start = markdown.range(of: startMarker) else { return nil }
    if let stray = markdown.range(of: endMarker), stray.lowerBound < start.lowerBound { return (start, nil) }
    return (start, markdown.range(of: endMarker, range: start.upperBound..<markdown.endIndex))
  }

  /// The PR links and table rows outside the generated table, and the text
  /// inside it.
  public static func parse(_ markdown: String) -> Content {
    var outside = markdown
    var block: String?
    if let (start, end) = markers(markdown), let end {
      block = String(markdown[start.upperBound..<end.lowerBound])
      outside = String(markdown[..<start.lowerBound]) + "\n" + String(markdown[end.upperBound...])
    }
    let lines = outside.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    var rows: [Content.Row] = []
    var columns: Columns?
    // The work table is the table with Item and Status columns that holds
    // the most rows. A later table wins a tie.
    var table: (table: PlanTable, rows: Int)?
    var work: (table: PlanTable, rows: Int)?
    func endTable() {
      if let t = table, t.rows >= (work?.rows ?? 0) { work = t }
      table = nil
    }
    for (i, line) in lines.enumerated() {
      guard line.hasPrefix("|") else {
        columns = nil
        endTable()
        continue
      }
      if isSeparator(line) {
        table?.table.last = line
        continue
      }
      let row = cells(line)
      // The line above a separator is the table's header.
      if i + 1 < lines.count, isSeparator(lines[i + 1]) {
        endTable()
        columns = Columns(header: row)
        if columns?.status != nil { table = (PlanTable(header: row, last: line), 0) }
        continue
      }
      table?.table.last = line
      if let n = columns?.number, n < row.count, let value = Int(row[n]) {
        let last = table?.table.lastNumber ?? 0
        table?.table.lastNumber = max(last, value)
      }
      let links = links(in: line)
      func cell(_ index: Int?) -> String? { index.flatMap { $0 < row.count && !row[$0].isEmpty ? row[$0] : nil } }
      let item = cell(columns?.item)
      let status = cell(columns?.status)
      guard !links.isEmpty || notStarted(item: item, status: status) else { continue }
      table?.rows += 1
      rows.append(
        Content.Row(
          text: line, links: links, number: cell(columns?.number), item: item, status: status,
          statusColumn: columns?.status.flatMap { $0 < row.count ? $0 : nil }))
    }
    endTable()
    return Content(links: links(in: outside), rows: rows, statusBlock: block, workTable: work?.table)
  }

  /// Where a table's `#`, `Item`, and `Status` columns are. A table without
  /// both `Item` and `Status` has none of them.
  struct Columns {
    var number: Int?
    var item: Int?
    var status: Int?

    init(header: [String]) {
      let names = header.map { $0.lowercased() }
      guard let item = names.firstIndex(of: "item"), let status = names.firstIndex(of: "status") else { return }
      self.item = item
      self.status = status
      number = names.firstIndex(of: "#")
    }
  }

  /// The trimmed cells of a table line, which starts with `|`. A `|` after
  /// a backslash belongs to its cell and reads as `|`.
  static func cells(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var escaped = false
    for ch in line.dropFirst() {
      if escaped {
        if ch != "|" { current.append("\\") }
        current.append(ch)
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else if ch == "|" {
        cells.append(current)
        current = ""
      } else {
        current.append(ch)
      }
    }
    if escaped { current.append("\\") }
    // The text after the last `|` is a cell only when the line has no trailing `|`.
    if !current.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(current) }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// The line with the text of cell `index` replaced by `text` and every
  /// other character kept, or nil when the line has no such cell. Cells
  /// count as `cells(_:)` counts them.
  static func replacingCell(_ line: String, _ index: Int, with text: String) -> String? {
    var bars: [String.Index] = []
    var escaped = false
    for i in line.indices {
      if escaped {
        escaped = false
      } else if line[i] == "\\" {
        escaped = true
      } else if line[i] == "|" {
        bars.append(i)
      }
    }
    guard bars.first == line.startIndex, index >= 0, index < bars.count else { return nil }
    let start = line.index(after: bars[index])
    let end: String.Index
    if index + 1 < bars.count {
      end = bars[index + 1]
    } else if !line[start...].trimmingCharacters(in: .whitespaces).isEmpty {
      end = line.endIndex
    } else {
      return nil
    }
    return String(line[..<start]) + " \(text) " + String(line[end...])
  }

  /// Whether a row names an item and its status cell reads Not started,
  /// ignoring case and the marks around it, such as `**Not started**` or
  /// `Not started.`.
  static func notStarted(item: String?, status: String?) -> Bool {
    guard item?.isEmpty == false, let status else { return false }
    return status.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased() == "not started"
  }

  static func isSeparator(_ line: String) -> Bool {
    guard line.hasPrefix("|") else { return false }
    let cells = line.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
    return !cells.isEmpty
      && cells.allSatisfy { separatorCell.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
  }

  /// The row that `ref` names: by its whole text, else by its `#` cell, else
  /// by its item, else by a prefix of its item that no other row has. Items
  /// compare without case.
  public static func row(_ ref: String, in rows: [PlanRow]) throws -> PlanRow {
    let key = ref.trimmingCharacters(in: .whitespaces)
    let number = key.hasPrefix("#") ? String(key.dropFirst()) : key
    let item = key.lowercased()
    let tries: [(PlanRow) -> Bool] = [
      { $0.text == key },
      { $0.number == number },
      { $0.item?.lowercased() == item },
      { $0.item?.lowercased().hasPrefix(item) == true },
    ]
    for matches in tries {
      let found = rows.filter(matches)
      if found.count == 1 { return found[0] }
      if found.count > 1 {
        throw APIError("\(key) names \(found.count) rows: \(found.map(\.label).joined(separator: ", "))")
      }
    }
    throw APIError("the plan has no row \(key) that links a PR or reads Not started")
  }

  /// The first of the row's `#` and item that `row(_:in:)` resolves to this
  /// row alone, else the row's text. A `#` that two tables share names more
  /// than one row.
  static func ref(of row: PlanRow, in rows: [PlanRow]) -> String {
    [row.number, row.item].compactMap { $0 }.first { (try? Plans.row($0, in: rows))?.text == row.text } ?? row.text
  }

  /// The text that `splice` puts between the markers for this table.
  public static func block(_ table: String) -> String { "\n\(table)\n" }

  /// The document with the text between its first pair of status markers
  /// replaced by the table.
  public static func splice(_ markdown: String, _ table: String) throws -> String {
    guard let (start, end) = markers(markdown) else {
      throw APIError("the plan has no \(startMarker) line. Add \(startMarker) and \(endMarker) where the table goes")
    }
    guard let end else {
      throw APIError("the plan needs one \(endMarker) after its first \(startMarker), and none before it")
    }
    return String(markdown[..<start.upperBound]) + block(table) + String(markdown[end.lowerBound...])
  }

  /// The generated table: one row per session, sorted by name. Nothing in it
  /// changes unless a session's state, wait, or PR does.
  public static func table(_ sessions: [SessionSummary]) -> String {
    var lines = ["| Session | State | Wait | PR |", "| --- | --- | --- | --- |"]
    for s in sessions.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) {
      let pr = s.pr.map { "[\($0.repo)#\($0.number)](\($0.url)) \($0.state.rawValue.lowercased())" } ?? ""
      let cells = [s.name, s.state.title, s.waits.first?.line ?? "", pr].map { cell($0) }
      lines.append("| " + cells.joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n")
  }

  /// A table cell on one line. It escapes `<` as `&lt;`, so that no cell can
  /// hold a status marker.
  static func cell(_ text: String, max: Int = 200) -> String {
    oneLine(text, max: max).replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "|", with: "\\|")
  }
}
