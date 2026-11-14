/// How sbd names a session in text that a person or an agent reads. The id
/// stays because an agent needs it to run `sb` commands.
public func sessionMention(name: String, id: String) -> String { "\(name) (\(id))" }

extension Session {
  public var mention: String { sessionMention(name: name, id: id) }
}

/// A session that sbd removed, with the name it had then.
public struct RemovedSession: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  /// When sbd removed the session, in ms since the epoch.
  public var removed: Int64

  public init(id: String, name: String, removed: Int64) {
    self.id = id
    self.name = name
    self.removed = removed
  }
}

/// The names of live and removed sessions, and the matcher that finds their
/// ids in text that sbd or Claude wrote.
public struct SessionNames: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let name: String
    public let removed: Bool
  }

  public struct Match: Equatable, Sendable {
    public var id: String
    public var name: String
    public var removed: Bool

    public init(id: String, name: String, removed: Bool) {
      self.id = id
      self.name = name
      self.removed = removed
    }
  }

  /// A run of the text. A matched run's text is the session's name.
  public struct Piece: Equatable, Sendable {
    public var run: MarkdownText.Run
    public var match: Match?

    public init(run: MarkdownText.Run, match: Match?) {
      self.run = run
      self.match = match
    }
  }

  private let entries: [String: Entry]

  /// A live name wins over a removed one. An empty name resolves nothing,
  /// because the id would then vanish from the text.
  public init(live: [String: String], removed: [String: String]) {
    var entries: [String: Entry] = [:]
    for (id, name) in removed where !name.isEmpty { entries[id] = Entry(name: name, removed: true) }
    for (id, name) in live where !name.isEmpty { entries[id] = Entry(name: name, removed: false) }
    self.entries = entries
  }

  public static let empty = SessionNames(live: [:], removed: [:])

  public var isEmpty: Bool { entries.isEmpty }

  /// Whether `s` has the format of a session id: `s` and then `ShortId.length` characters from `ShortId.alphabet`.
  public static func isSessionID(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    return scalars.count == idLength && scalars[0] == "s" && scalars[1...].allSatisfy(inIdAlphabet)
  }

  public func entry(_ id: String) -> Entry? { entries[id] }

  /// The session's name, or `id` when no session has it.
  public func name(_ id: String) -> String { entries[id]?.name ?? id }

  /// The text split at each session id that is a whole token and resolves. A
  /// link, image, or footnote run is never rewritten, and a code run only when
  /// its whole text is one id. A run with no match comes back as it was.
  public func pieces(_ text: MarkdownText) -> [Piece] {
    guard !isEmpty else { return text.runs.map { Piece(run: $0, match: nil) } }
    // Every run's scalars, so that the boundary rules read the real neighbor
    // even when it sits in a link, code, or image run.
    var scalars: [Unicode.Scalar] = []
    var bounds: [Range<Int>] = []
    for run in text.runs {
      let start = scalars.count
      scalars.append(contentsOf: run.text.unicodeScalars)
      bounds.append(start..<scalars.count)
    }
    var pieces: [Piece] = []
    for (run, range) in zip(text.runs, bounds) {
      let spans = spans(in: run, range, scalars)
      guard !spans.isEmpty else {
        pieces.append(Piece(run: run, match: nil))
        continue
      }
      var style = run.style
      style.remove(.code)
      var at = range.lowerBound
      for span in spans {
        if at < span.range.lowerBound { pieces.append(plainPiece(scalars[at..<span.range.lowerBound], run)) }
        pieces.append(Piece(run: MarkdownText.Run(span.match.name, style), match: span.match))
        at = span.range.upperBound
      }
      if at < range.upperBound { pieces.append(plainPiece(scalars[at..<range.upperBound], run)) }
    }
    return pieces
  }

  public func matches(_ text: MarkdownText) -> [Match] { pieces(text).compactMap(\.match) }

  public func plainText(_ string: String) -> String {
    pieces(MarkdownText(stringLiteral: string)).map(\.run.text).joined()
  }

  private struct Span {
    var range: Range<Int>
    var match: Match
  }

  private func plainPiece(_ scalars: ArraySlice<Unicode.Scalar>, _ run: MarkdownText.Run) -> Piece {
    var run = run
    run.text = String(String.UnicodeScalarView(scalars))
    return Piece(run: run, match: nil)
  }

  /// The non-overlapping spans in one run that become names, in order.
  private func spans(in run: MarkdownText.Run, _ range: Range<Int>, _ s: [Unicode.Scalar]) -> [Span] {
    guard run.link == nil, run.image == nil, !run.style.contains(.footnote) else { return [] }
    if run.style.contains(.code) {
      // A code span is rewritten only when its whole text is one id.
      guard range.count == Self.idLength, let match = match(at: range.lowerBound, s) else { return [] }
      return [Span(range: range, match: match)]
    }
    var candidates: [Span] = []
    var i = range.lowerBound
    while i + Self.idLength <= range.upperBound {
      if let match = match(at: i, s) {
        let bare = Span(range: i..<i + Self.idLength, match: match)
        let wide = collapsed(bare, within: range, s)
        candidates.append(bare)
        if wide.range != bare.range { candidates.append(wide) }
      }
      i += 1
    }
    // A collapsed `name (id)` wins over an id found inside its name. When an
    // earlier span takes part of a collapsed one, the bare id still matches.
    candidates.sort { ($0.range.lowerBound, -$0.range.count) < ($1.range.lowerBound, -$1.range.count) }
    var kept: [Span] = []
    for span in candidates where span.range.lowerBound >= (kept.last?.range.upperBound ?? 0) {
      kept.append(span)
    }
    return kept
  }

  /// The session whose id starts at `i`, when the id is a whole token and resolves.
  private func match(at i: Int, _ s: [Unicode.Scalar]) -> Match? {
    let end = i + Self.idLength
    guard end <= s.count, s[i] == "s", s[i + 1..<end].allSatisfy(Self.inIdAlphabet),
      i == 0 || Self.allowedBefore(s[i - 1]),
      Self.allowedAfter(end, s)
    else { return nil }
    let id = String(String.UnicodeScalarView(s[i..<end]))
    guard let entry = entries[id] else { return nil }
    return Match(id: id, name: entry.name, removed: entry.removed)
  }

  /// The span widened to `<name> (<id>)` or `<id> (<name>)` when the session's
  /// name sits there within the same run and the widened span is a whole token.
  private func collapsed(_ span: Span, within run: Range<Int>, _ s: [Unicode.Scalar]) -> Span {
    let name = Array(span.match.name.unicodeScalars)
    let id = span.range
    let before = name + [" ", "("]
    let start = id.lowerBound - before.count
    if start >= run.lowerBound, id.upperBound < run.upperBound, s[id.upperBound] == ")",
      s[start..<id.lowerBound].elementsEqual(before), start == 0 || Self.allowedBefore(s[start - 1]),
      Self.allowedAfter(id.upperBound + 1, s)
    {
      return Span(range: start..<id.upperBound + 1, match: span.match)
    }
    let after = [" ", "("] + name + [")"]
    let end = id.upperBound + after.count
    if end <= run.upperBound, s[id.upperBound..<end].elementsEqual(after), Self.allowedAfter(end, s) {
      return Span(range: id.lowerBound..<end, match: span.match)
    }
    return span
  }

  /// The `s` prefix and the characters that `shortId` adds.
  private static let idLength = 1 + ShortId.length

  /// A table indexed by ASCII code, so that the matcher's test for each scalar does not hash.
  private static let idAlphabet: [Bool] = {
    var table = [Bool](repeating: false, count: 128)
    for c in ShortId.alphabet.unicodeScalars { table[Int(c.value)] = true }
    return table
  }()

  private static func inIdAlphabet(_ c: Unicode.Scalar) -> Bool { c.value < 128 && idAlphabet[Int(c.value)] }

  /// A letter, digit, or combining mark joins the id to a longer word.
  private static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
    switch c.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
      .decimalNumber, .letterNumber, .otherNumber,
      .nonspacingMark, .spacingMark, .enclosingMark:
      true
    default: false
    }
  }

  private static let forbiddenBefore: Set<Unicode.Scalar> = [
    "_", "-", "/", "\\", "@", ":", ".", "#", "$", "=", "~", "&", "%", "+",
  ]
  private static let forbiddenAfter: Set<Unicode.Scalar> = [
    "_", "-", "/", "\\", "@", "=", "#", "$", "%", "+", "~", "&",
  ]

  private static func allowedBefore(_ c: Unicode.Scalar) -> Bool { !isWordScalar(c) && !forbiddenBefore.contains(c) }

  private static let closing: Set<Unicode.Scalar> = [")", "]", "\"", "'", "\u{2019}", "\u{201D}"]

  /// A `.` or `:` ends a clause only when the text ends or whitespace or a
  /// closing mark follows it. So `seb4ec.jsonl`, `seb4ec:/tmp`, and
  /// `seb4ec._x` do not match. A run of dots counts as one `.`, as in `seb4ec...`.
  private static func allowedAfter(_ i: Int, _ s: [Unicode.Scalar]) -> Bool {
    guard i < s.count else { return true }
    let c = s[i]
    if c == "." || c == ":" {
      var next = i + 1
      if c == "." { while next < s.count, s[next] == "." { next += 1 } }
      return next == s.count || s[next].properties.isWhitespace || closing.contains(s[next])
    }
    return !isWordScalar(c) && !forbiddenAfter.contains(c)
  }
}
