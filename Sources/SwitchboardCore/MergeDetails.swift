import Foundation

/// What the merge card says about a PR beyond its status: its size, its
/// review threads, and its description. The poller reads them only for a PR
/// at a merge decision, once per head commit and again on each status read.
public struct MergeDetails: Codable, Equatable, Sendable {
  public var additions: Int
  public var deletions: Int
  public var changedFiles: Int
  /// GitHub's count of the PR's review threads.
  public var threads: Int
  /// How many threads the read holds. GitHub answers at most
  /// `GitHub.maxThreads`, so this can be less than `threads`.
  public var threadsRead: Int
  /// The unresolved threads among those read.
  public var openThreads: Int
  /// The body without its templates, checklists, and boilerplate, as plain
  /// text, at most `maxDescription` characters.
  public var description: String
  /// The body's first sentences, which the card shows until a model writes
  /// its summary. nil when the body has none.
  public var gist: String?
  /// The test plan's unchecked items, and its sentences that say something
  /// was not tested or not run.
  public var testGaps: [String]

  public init(
    additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0, threads: Int = 0, threadsRead: Int = 0,
    openThreads: Int = 0, description: String = "", gist: String? = nil, testGaps: [String] = []
  ) {
    self.additions = additions
    self.deletions = deletions
    self.changedFiles = changedFiles
    self.threads = threads
    self.threadsRead = threadsRead
    self.openThreads = openThreads
    self.description = description
    self.gist = gist
    self.testGaps = testGaps
  }

  public static let maxDescription = 4000
  static let maxGist = 300
  static let maxTestGaps = 5

  /// The sections whose heading has a word that starts with one of these
  /// are boilerplate. A match inside a word, as in "Latest", does not count.
  static let boilerplate = try! NSRegularExpression(
    pattern: #"\b(?:test|release|docs|documentation|agent|checklist|screenshot|changelog)"#,
    options: [.caseInsensitive])
  static let testHeading = try! NSRegularExpression(pattern: #"\btest"#, options: [.caseInsensitive])

  static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  static let gap = try! NSRegularExpression(
    pattern:
      #"(?:\b(?:not|never)|n['’]t)\s+(?:been\s+)?(?:tested|run|verified)\b|\buntested\b|\b(?:did|could)(?:\s+not|n['’]t)\s+(?:test|run|verify)\b"#,
    options: [.caseInsensitive])
  static let urlOnly = try! NSRegularExpression(pattern: #"^\s*<?https?://\S+>?\s*$"#)

  /// One paragraph, list item, or table of the body, with the heading that
  /// it falls under.
  struct Unit {
    var text: String
    var section: Int
    /// A table is not prose, so the gist skips it.
    var prose: Bool
  }

  /// Reads the body into the description, the gist, and the test gaps.
  /// `title` is the PR's title, which the gist never repeats.
  public static func read(body: String, title: String) -> (description: String, gist: String?, testGaps: [String]) {
    let text = Issues.htmlComment.stringByReplacingMatches(
      in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
    var headings: [(level: Int, text: String)] = []
    var section = 0
    var inBoilerplate = false
    var inTests = false
    var units: [Unit] = []
    var lines: [String] = []
    var gaps: [String] = []
    for block in MarkdownBlock.parse(text) {
      if case .heading(let level, let heading) = block {
        headings.removeAll { $0.level >= level }
        headings.append((level, heading.plain.lowercased()))
        section += 1
        inBoilerplate = headings.contains { matches(boilerplate, $0.text) }
        inTests = headings.contains { matches(testHeading, $0.text) }
        if !inBoilerplate { lines.append(heading.plain) }
        continue
      }
      if inTests { gaps += testGaps(block) }
      guard !inBoilerplate else { continue }
      for unit in self.units(block, section: section) {
        units.append(unit)
        lines.append(unit.text)
      }
    }
    let description = String(lines.joined(separator: "\n").prefix(maxDescription))
    return (description, gist(units, title: title), Array(gaps.prefix(maxTestGaps)))
  }

  /// The block's text units. A task list, an image, a `<details>` block, a
  /// code block, a lone URL, and a lone closing keyword give none.
  static func units(_ block: MarkdownBlock, section: Int) -> [Unit] {
    switch block {
    case .paragraph(let text):
      let plain = collapsed(text.plain)
      return kept(plain) ? [Unit(text: plain, section: section, prose: true)] : []
    case .list(_, let items):
      return items.filter { $0.checked == nil }.compactMap { item in
        let plain = itemText(item)
        return kept(plain) ? Unit(text: plain, section: section, prose: true) : nil
      }
    case .quote(let blocks):
      return blocks.flatMap { units($0, section: section) }
    case .table(let header, _, let rows):
      let text = ([header] + rows).map { $0.map(\.plain).joined(separator: " | ") }.joined(separator: "\n")
      return [Unit(text: text, section: section, prose: false)]
    default:
      return []
    }
  }

  /// The unchecked task items and the sentences that say something was not
  /// tested, in a block of a test section.
  static func testGaps(_ block: MarkdownBlock) -> [String] {
    switch block {
    case .paragraph(let text):
      return gapSentences(collapsed(text.plain))
    case .list(_, let items):
      return items.flatMap { item -> [String] in
        let plain = itemText(item)
        if item.checked == false { return plain.isEmpty ? [] : [oneLine(plain, max: TriageCard.lineLength)] }
        return gapSentences(plain)
      }
    case .quote(let blocks):
      return blocks.flatMap(testGaps)
    default:
      return []
    }
  }

  /// The first sentence of each of the first two sections that have prose,
  /// or of the first two units when the body has one section.
  static func gist(_ units: [Unit], title: String) -> String? {
    let prose = units.filter(\.prose)
    var picked: [Unit] = []
    for unit in prose where !picked.contains(where: { $0.section == unit.section }) {
      picked.append(unit)
      if picked.count == 2 { break }
    }
    if picked.count < 2 { picked = Array(prose.prefix(2)) }
    var chosen: [String] = []
    for unit in picked {
      guard var first = Attention.sentences(unit.text, trimming: .whitespaces).first else { continue }
      if first.hasSuffix(":") { first = String(first.dropLast()) + "." }
      if !".!?".contains(first.last ?? ".") { first += "." }
      if !repeats(first, title) { chosen.append(first) }
    }
    guard !chosen.isEmpty else { return nil }
    var gist = chosen[0]
    for sentence in chosen.dropFirst() where gist.count + 1 + sentence.count <= maxGist {
      gist += " " + sentence
    }
    return oneLine(gist, max: maxGist)
  }

  /// The text's sentences that say something was not tested, each cut to one line.
  static func gapSentences(_ text: String) -> [String] {
    Attention.sentences(text, trimming: .whitespaces).filter {
      gap.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
    }
    .map { oneLine($0, max: TriageCard.lineLength) }
  }

  /// Whether `text` says only what `title` says, ignoring case, spaces, and
  /// the closing punctuation.
  static func repeats(_ text: String, _ title: String) -> Bool {
    let bare = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")).lowercased() }
    return bare(text) == bare(title)
  }

  static func itemText(_ item: MarkdownBlock.Item) -> String {
    collapsed(item.blocks.map(\.plainText).joined(separator: " "))
  }

  /// Whether a unit's text says something: it is not a lone URL or a lone
  /// closing keyword such as `Closes #12`.
  static func kept(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    if text.isEmpty || urlOnly.firstMatch(in: text, range: range) != nil { return false }
    let rest = Issues.closingRef.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    return !rest.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).allSatisfy { $0.lowercased() == "and" }
  }

  static func collapsed(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
}

extension GitHub {
  /// GitHub answers at most this many review threads in one read.
  public static let maxThreads = 100

  /// What the merge card needs of each PR at a merge decision. The status
  /// query leaves it out, because a PR's review threads would slow every
  /// status read.
  public static let mergeDetailsQuery = """
    query($ids: [ID!]!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id headRefOid title body additions deletions changedFiles
          reviewThreads(first: \(maxThreads)) { totalCount nodes { isResolved } }
        }
      }
    }
    """

  /// The details of one node of a merge details response, and the head
  /// commit they belong to. nil when the node lacks a field.
  public static func parseMergeDetails(_ node: JSON) -> (head: String, details: MergeDetails)? {
    guard let head = node["headRefOid"]?.string, let additions = node["additions"]?.int,
      let deletions = node["deletions"]?.int, let files = node["changedFiles"]?.int,
      let total = node["reviewThreads"]?["totalCount"]?.int
    else { return nil }
    let threads = nodes(node["reviewThreads"])
    let read = MergeDetails.read(body: node["body"]?.string ?? "", title: node["title"]?.string ?? "")
    return (
      head,
      MergeDetails(
        additions: additions, deletions: deletions, changedFiles: files, threads: total, threadsRead: threads.count,
        openThreads: threads.filter { $0["isResolved"]?.bool == false }.count, description: read.description,
        gist: read.gist, testGaps: read.testGaps)
    )
  }
}
