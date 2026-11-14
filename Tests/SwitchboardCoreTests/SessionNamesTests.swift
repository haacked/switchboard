import Foundation
import Testing

@testable import SwitchboardCore

private typealias Run = MarkdownText.Run
private typealias Piece = SessionNames.Piece
private typealias Match = SessionNames.Match

private let liveNames: [String: String] = [
  "seb4ec": "zsh-startup-for-switchboard",
  "sgcctv": "render-session-names",
  // A name that holds another session's id. The matcher must not scan it again.
  "sn4mzz": "redo sgcctv",
  // A name with characters that a regular expression would read as syntax.
  "s23456": "v1.2+fix",
  // Ids with other `shortId` prefixes, and an id outside the alphabet. None of
  // them has the session id shape, so text that holds them stays as written.
  "g4rvrf": "a-group",
  "w3k9ap": "a-wait",
  "sl0ok1": "not-an-id",
]

private let removedNames: [String: String] = ["sq7kpm": "old-cleanup"]

private var names: SessionNames { SessionNames(live: liveNames, removed: removedNames) }

private func text(_ runs: Run...) -> MarkdownText { MarkdownText(runs) }

private func piece(_ text: String, _ style: MarkdownText.Style = [], link: String? = nil, image: String? = nil)
  -> Piece
{
  Piece(run: Run(text, style, link: link, image: image), match: nil)
}

/// The piece for a session in the test directory. A live entry wins over a removed one.
private func mention(
  _ id: String, _ style: MarkdownText.Style = [], live: [String: String] = liveNames,
  removed: [String: String] = removedNames
) -> Piece {
  let name = live[id] ?? removed[id] ?? "missing fixture \(id)"
  return Piece(run: Run(name, style), match: Match(id: id, name: name, removed: live[id] == nil))
}

private func unchanged(_ text: MarkdownText) -> [Piece] { text.runs.map { Piece(run: $0, match: nil) } }

/// The pieces that a row's expected text describes. `⟨id⟩` stands for the
/// session's name, matched. The rest is unstyled text.
private func expectedPieces(_ marked: String, live: [String: String] = liveNames) -> [Piece] {
  var pieces: [Piece] = []
  var rest = Substring(marked)
  while let open = rest.firstIndex(of: "⟨"), let close = rest[open...].firstIndex(of: "⟩") {
    if open > rest.startIndex { pieces.append(piece(String(rest[..<open]))) }
    pieces.append(mention(String(rest[rest.index(after: open)..<close]), live: live))
    rest = rest[rest.index(after: close)...]
  }
  if !rest.isEmpty { pieces.append(piece(String(rest))) }
  return pieces
}

/// The plain text that a row's expected text describes.
private func expectedPlain(_ marked: String, live: [String: String] = liveNames) -> String {
  expectedPieces(marked, live: live).map(\.run.text).joined()
}

private func paragraph(_ markdown: String) throws -> MarkdownText {
  let blocks = MarkdownBlock.parse(markdown)
  try #require(blocks.count == 1, "\(markdown) parses to \(blocks)")
  guard case .paragraph(let text) = blocks[0] else {
    Issue.record("\(markdown) parses to \(blocks[0]), not a paragraph")
    return MarkdownText()
  }
  return text
}

/// Unstyled text that the matcher must leave exactly as written.
private let unchangedPlain: [String] = [
  "",
  "no session ids here",
  // Unknown ids and look-alike words that no session has as its id.
  "sx2zzz", "Ask sx2zzz to rebase", "stream", "switch", "submit", "street", "the stream and the street",
  // Other `shortId` prefixes and an id outside the alphabet, all in the directory.
  "g4rvrf", "w3k9ap", "group g4rvrf and wait w3k9ap", "sl0ok1",
  // Case and length.
  "SEB4EC", "Seb4ec", "seb4ecx", "xseb4ec", "2seb4ec", "seb4ec2",
  // Unicode letters and digits.
  "éseb4ec", "seb4ecé", "seb4ecü", "٣seb4ec", "seb4ec٣",
  // A combining mark joins the id to the letter it modifies.
  "e\u{0301}seb4ec", "seb4ec\u{0301}",
  // Pane names, paths, assignments, tags, and URLs.
  "seb4ec-claude", "sessions/seb4ec/claude.sh", "SB_SESSION_ID=seb4ec", "#seb4ec", "@seb4ec",
  "https://example.com/seb4ec", "C:\\seb4ec", "host:seb4ec",
  // `.ext` and `:suffix`.
  "seb4ec.jsonl", "seb4ec:card", "seb4ec:5", "seb4ec.2", "seb4ec.é", ".seb4ec", ":seb4ec",
  // A `.` or `:` followed by something other than whitespace, a closing mark, or the end.
  "seb4ec:/tmp", "seb4ec._x", "seb4ec.*", "seb4ec:-x", "seb4ec../x", "seb4ec::x",
  // Each character that the boundary rules forbid, on each side.
  "_seb4ec", "seb4ec_", "-seb4ec", "seb4ec-", "/seb4ec", "seb4ec/", "\\seb4ec", "seb4ec\\", "seb4ec@",
  "seb4ec#", "$seb4ec", "seb4ec$", "=seb4ec", "seb4ec=1", "~seb4ec", "seb4ec~", "&seb4ec", "seb4ec&",
  "%seb4ec", "seb4ec%", "+seb4ec", "seb4ec+",
  // The same shapes with the removed session's id.
  "sq7kpm-claude", "sessions/sq7kpm/claude.sh", "sq7kpm.jsonl",
]

/// Unstyled text and the pieces the matcher gives for it, written as described in `expectedPieces`.
private let changedPlain: [(String, String)] = [
  // Position in the text.
  ("seb4ec", "⟨seb4ec⟩"),
  ("seb4ec is done", "⟨seb4ec⟩ is done"),
  ("Ask seb4ec to rebase", "Ask ⟨seb4ec⟩ to rebase"),
  ("waiting on seb4ec", "waiting on ⟨seb4ec⟩"),
  // Punctuation and whitespace neighbors.
  ("(seb4ec)", "(⟨seb4ec⟩)"),
  ("[seb4ec]", "[⟨seb4ec⟩]"),
  ("\"seb4ec\"", "\"⟨seb4ec⟩\""),
  ("'seb4ec'", "'⟨seb4ec⟩'"),
  ("seb4ec, then", "⟨seb4ec⟩, then"),
  ("a,seb4ec", "a,⟨seb4ec⟩"),
  (";seb4ec;", ";⟨seb4ec⟩;"),
  ("!seb4ec!", "!⟨seb4ec⟩!"),
  ("?seb4ec?", "?⟨seb4ec⟩?"),
  ("*seb4ec*", "*⟨seb4ec⟩*"),
  ("waiting on seb4ec.", "waiting on ⟨seb4ec⟩."),
  ("seb4ec. Next", "⟨seb4ec⟩. Next"),
  ("seb4ec.)", "⟨seb4ec⟩.)"),
  ("seb4ec: done", "⟨seb4ec⟩: done"),
  ("waiting on seb4ec:", "waiting on ⟨seb4ec⟩:"),
  ("seb4ec…", "⟨seb4ec⟩…"),
  ("seb4ec...", "⟨seb4ec⟩..."),
  ("seb4ec... then", "⟨seb4ec⟩... then"),
  ("'waiting on seb4ec.'", "'waiting on ⟨seb4ec⟩.'"),
  ("\"waiting on seb4ec.\"", "\"waiting on ⟨seb4ec⟩.\""),
  ("\u{2018}waiting on seb4ec.\u{2019}", "\u{2018}waiting on ⟨seb4ec⟩.\u{2019}"),
  ("[seb4ec.]", "[⟨seb4ec⟩.]"),
  ("\u{201C}waiting on seb4ec.\u{201D}", "\u{201C}waiting on ⟨seb4ec⟩.\u{201D}"),
  ("[seb4ec:]", "[⟨seb4ec⟩:]"),
  ("seb4ec.\u{00A0}now", "⟨seb4ec⟩.\u{00A0}now"),
  ("seb4ec's PR", "⟨seb4ec⟩'s PR"),
  ("seb4ec\u{2019}s PR", "⟨seb4ec⟩\u{2019}s PR"),
  ("a\nseb4ec\nb", "a\n⟨seb4ec⟩\nb"),
  ("a\tseb4ec\tb", "a\t⟨seb4ec⟩\tb"),
  ("a\u{2014}seb4ec\u{2014}b", "a\u{2014}⟨seb4ec⟩\u{2014}b"),
  ("seb4ec\u{00A0}now", "⟨seb4ec⟩\u{00A0}now"),
  ("🙂seb4ec🙂", "🙂⟨seb4ec⟩🙂"),
  // Commands in prose are not protected.
  ("sb send seb4ec hi", "sb send ⟨seb4ec⟩ hi"),
  // Several ids.
  ("seb4ec and seb4ec", "⟨seb4ec⟩ and ⟨seb4ec⟩"),
  ("sgcctv,seb4ec", "⟨sgcctv⟩,⟨seb4ec⟩"),
  ("sgcctv seb4ec", "⟨sgcctv⟩ ⟨seb4ec⟩"),
  ("sgcctv and sq7kpm", "⟨sgcctv⟩ and ⟨sq7kpm⟩"),
  ("sq7kpm", "⟨sq7kpm⟩"),
  // A replacement is not scanned again.
  ("sn4mzz", "⟨sn4mzz⟩"),
  ("s23456", "⟨s23456⟩"),
  // `name (id)` and `id (name)` collapse to one piece.
  ("zsh-startup-for-switchboard (seb4ec)", "⟨seb4ec⟩"),
  ("Ask zsh-startup-for-switchboard (seb4ec) to rebase", "Ask ⟨seb4ec⟩ to rebase"),
  ("seb4ec (zsh-startup-for-switchboard)", "⟨seb4ec⟩"),
  ("seb4ec (zsh-startup-for-switchboard) is done", "⟨seb4ec⟩ is done"),
  ("old-cleanup (sq7kpm)", "⟨sq7kpm⟩"),
  ("sq7kpm (old-cleanup)", "⟨sq7kpm⟩"),
  ("v1.2+fix (s23456)", "⟨s23456⟩"),
  ("redo sgcctv (sn4mzz)", "⟨sn4mzz⟩"),
  ("sn4mzz (redo sgcctv)", "⟨sn4mzz⟩"),
  ("zsh-startup-for-switchboard (seb4ec) and seb4ec", "⟨seb4ec⟩ and ⟨seb4ec⟩"),
  ("Ask zsh-startup-for-switchboard (seb4ec).", "Ask ⟨seb4ec⟩."),
  // A title capitalizes its first letter, so the name there may start with a capital.
  ("Zsh-startup-for-switchboard (seb4ec) is done", "⟨seb4ec⟩ is done"),
  ("Ask Zsh-startup-for-switchboard (seb4ec)", "Ask Zsh-startup-for-switchboard (⟨seb4ec⟩)"),
  ("Ask seb4ec (zsh-startup-for-switchboard).", "Ask ⟨seb4ec⟩."),
  // Text that touches the closing parenthesis: only the id changes.
  ("zsh-startup-for-switchboard (seb4ec)x", "zsh-startup-for-switchboard (⟨seb4ec⟩)x"),
  ("seb4ec (zsh-startup-for-switchboard)x", "⟨seb4ec⟩ (zsh-startup-for-switchboard)x"),
  ("zsh-startup-for-switchboard (seb4ec)-claude", "zsh-startup-for-switchboard (⟨seb4ec⟩)-claude"),
  ("seb4ec (zsh-startup-for-switchboard)/x", "⟨seb4ec⟩ (zsh-startup-for-switchboard)/x"),
  ("zsh-startup-for-switchboard (seb4ec).jsonl", "zsh-startup-for-switchboard (⟨seb4ec⟩).jsonl"),
  ("seb4ec (zsh-startup-for-switchboard):card", "⟨seb4ec⟩ (zsh-startup-for-switchboard):card"),
  // Another name, a longer word that ends with the name, or no space: only the id changes.
  ("The dotfiles session (seb4ec)", "The dotfiles session (⟨seb4ec⟩)"),
  ("render-session-names (seb4ec)", "render-session-names (⟨seb4ec⟩)"),
  ("my-zsh-startup-for-switchboard (seb4ec)", "my-zsh-startup-for-switchboard (⟨seb4ec⟩)"),
  ("zsh-startup-for-switchboard(seb4ec)", "zsh-startup-for-switchboard(⟨seb4ec⟩)"),
  ("v1x2+fix (s23456)", "v1x2+fix (⟨s23456⟩)"),
  ("seb4ec (zsh-startup-for-switchboard-v2)", "⟨seb4ec⟩ (zsh-startup-for-switchboard-v2)"),
  ("seb4ec (zsh-startup-for-switchboard and more)", "⟨seb4ec⟩ (zsh-startup-for-switchboard and more)"),
  ("sgcctv (seb4ec)", "⟨sgcctv⟩ (⟨seb4ec⟩)"),
]

/// Markdown that the matcher must leave exactly as `MarkdownBlock.parse` gives it.
private let unchangedMarkdown: [String] = [
  // Code spans other than one exact, resolving id.
  "`sb send seb4ec hi`", "`seb4ec.`", "`sx2zzz`", "`g4rvrf`", "<kbd>sb send seb4ec</kbd>",
  // Links, autolinks, HTML links, and images.
  "[seb4ec](https://example.com)", "[the session](https://example.com/seb4ec)", "<https://example.com/seb4ec>",
  "see https://example.com/seb4ec now", "www.seb4ec.com", "<a href=\"https://x.example\">seb4ec</a>",
  "see ![seb4ec](x.png) now",
  // A letter in a neighboring run touches the id.
  "*a*seb4ec", "seb4ec*a*", "see`seb4ec`", "`seb4ec`s", "`x`seb4ec", "seb4ec`x`", "[x](u)seb4ec", "seb4ec[x](u)",
  // An escape or entity that puts a forbidden character next to the id.
  "seb4ec\\_x", "seb4ec&amp;x",
  // A `.` in the next run, followed by a word.
  "**seb4ec**.jsonl", "**seb4ec**:/tmp", "`seb4ec`:/tmp",
]

private let docsLink = "https://example.com/docs"

/// Markdown and the pieces the matcher gives for it.
private let changedMarkdown: [(String, [Piece])] = [
  ("`seb4ec`", [mention("seb4ec")]),
  ("`sq7kpm`", [mention("sq7kpm")]),
  ("<code>seb4ec</code>", [mention("seb4ec")]),
  ("*seb4ec*", [mention("seb4ec", .emphasis)]),
  ("**seb4ec**", [mention("seb4ec", .strong)]),
  ("~~seb4ec~~", [mention("seb4ec", .strikethrough)]),
  ("*`seb4ec`*", [mention("seb4ec", .emphasis)]),
  ("(*seb4ec*)", [piece("("), mention("seb4ec", .emphasis), piece(")")]),
  ("**Ask seb4ec now**", [piece("Ask ", .strong), mention("seb4ec", .strong), piece(" now", .strong)]),
  ("*x* seb4ec", [piece("x", .emphasis), piece(" "), mention("seb4ec")]),
  ("**bold** seb4ec", [piece("bold", .strong), piece(" "), mention("seb4ec")]),
  ("seb4ec [docs](\(docsLink))", [mention("seb4ec"), piece(" "), piece("docs", link: docsLink)]),
  ("\\*seb4ec\\*", [piece("*"), mention("seb4ec"), piece("*")]),
  ("seb4ec&nbsp;now", [mention("seb4ec"), piece("\u{00A0}now")]),
  ("*zsh-startup-for-switchboard (seb4ec)*", [mention("seb4ec", .emphasis)]),
  ("Ask **seb4ec**.", [piece("Ask "), mention("seb4ec", .strong), piece(".")]),
  // A word in the next run touches the closing parenthesis: only the id changes.
  (
    "zsh-startup-for-switchboard (seb4ec)*x*",
    [piece("zsh-startup-for-switchboard ("), mention("seb4ec"), piece(")"), piece("x", .emphasis)]
  ),
  (
    "seb4ec (zsh-startup-for-switchboard)`x`",
    [mention("seb4ec"), piece(" (zsh-startup-for-switchboard)"), piece("x", .code)]
  ),
  // The name and the id in different runs: only the id changes.
  (
    "**zsh-startup-for-switchboard** (seb4ec)",
    [piece("zsh-startup-for-switchboard", .strong), piece(" ("), mention("seb4ec"), piece(")")]
  ),
  (
    "seb4ec (*zsh-startup-for-switchboard*)",
    [mention("seb4ec"), piece(" ("), piece("zsh-startup-for-switchboard", .emphasis), piece(")")]
  ),
  ("zsh-startup-for-switchboard (`seb4ec`)", [piece("zsh-startup-for-switchboard ("), mention("seb4ec"), piece(")")]),
]

@Suite struct SessionNamesTests {
  @Test func mentionPutsTheNameFirst() {
    #expect(sessionMention(name: "zsh-startup-for-switchboard", id: "seb4ec") == "zsh-startup-for-switchboard (seb4ec)")
  }

  @Test func entryResolvesALiveSession() {
    let entry = names.entry("seb4ec")

    #expect(entry?.name == "zsh-startup-for-switchboard")
    #expect(entry?.removed == false)
  }

  @Test func entryResolvesARemovedSession() {
    let entry = names.entry("sq7kpm")

    #expect(entry?.name == "old-cleanup")
    #expect(entry?.removed == true)
  }

  @Test func entryOfAnUnknownIdIsNil() {
    #expect(names.entry("sx2zzz") == nil)
  }

  @Test func liveEntryWinsOverATombstone() {
    let names = SessionNames(live: ["seb4ec": "new-name"], removed: ["seb4ec": "old-name"])

    let entry = names.entry("seb4ec")

    #expect(entry?.name == "new-name")
    #expect(entry?.removed == false)
  }

  @Test func liveEntryWinsOverATombstoneInText() {
    let live = ["seb4ec": "new-name"]
    let names = SessionNames(live: live, removed: ["seb4ec": "old-name"])

    let pieces = names.pieces("old-name (seb4ec)")

    #expect(pieces == [piece("old-name ("), mention("seb4ec", live: live, removed: [:]), piece(")")])
  }

  @Test func emptyDirectoryIsEmpty() {
    #expect(SessionNames(live: [:], removed: [:]).isEmpty)
  }

  @Test(arguments: [(["seb4ec": "a"], [String: String]()), ([:], ["sq7kpm": "b"])])
  func directoryWithAnEntryIsNotEmpty(_ live: [String: String], _ removed: [String: String]) {
    #expect(!SessionNames(live: live, removed: removed).isEmpty)
  }

  @Test func directoriesWithTheSameEntriesAreEqual() {
    #expect(SessionNames(live: liveNames, removed: removedNames) == names)
  }

  @Test(arguments: [
    (["seb4ec": "a"], ["seb4ec": "b"]),
    (["seb4ec": "a"], ["sgcctv": "a"]),
  ])
  func directoriesWithDifferentLiveEntriesAreNotEqual(_ a: [String: String], _ b: [String: String]) {
    #expect(SessionNames(live: a, removed: [:]) != SessionNames(live: b, removed: [:]))
  }

  @Test func directoriesThatDifferInRemovalAreNotEqual() {
    #expect(SessionNames(live: ["seb4ec": "a"], removed: [:]) != SessionNames(live: [:], removed: ["seb4ec": "a"]))
  }

  @Test(arguments: unchangedPlain)
  func plainTextThatMustNotChangePassesThrough(_ input: String) {
    let text = MarkdownText(stringLiteral: input)

    #expect(names.pieces(text) == unchanged(text))
  }

  @Test(arguments: unchangedPlain)
  func plainStringThatMustNotChangeComesBackAsWritten(_ input: String) {
    #expect(names.replacingIDs(in: input) == input)
  }

  @Test(arguments: changedPlain)
  func plainTextIdsBecomeNames(_ input: String, _ expected: String) {
    #expect(names.pieces(MarkdownText(stringLiteral: input)) == expectedPieces(expected))
  }

  @Test(arguments: changedPlain)
  func plainStringIdsBecomeNames(_ input: String, _ expected: String) {
    #expect(names.replacingIDs(in: input) == expectedPlain(expected))
  }

  @Test(arguments: unchangedPlain + changedPlain.map(\.0))
  func emptyDirectoryChangesNothing(_ input: String) {
    let names = SessionNames(live: [:], removed: [:])
    let text = MarkdownText(stringLiteral: input)

    #expect(names.pieces(text) == unchanged(text))
    #expect(names.replacingIDs(in: input) == input)
  }

  @Test(arguments: [
    ("Fix the stream reader", "Fix the ⟨stream⟩ reader"),
    ("streams", "streams"),
    ("upstream", "upstream"),
  ])
  func sessionWhoseIdIsAWordRewritesThatWord(_ input: String, _ expected: String) {
    let live = ["stream": "stream-fix"]
    let names = SessionNames(live: live, removed: [:])

    #expect(names.pieces(MarkdownText(stringLiteral: input)) == expectedPieces(expected, live: live))
  }

  @Test(arguments: unchangedMarkdown)
  func markdownThatMustNotChangePassesThrough(_ markdown: String) throws {
    let text = try paragraph(markdown)

    #expect(names.pieces(text) == unchanged(text))
  }

  @Test(arguments: changedMarkdown)
  func markdownIdsBecomeNames(_ markdown: String, _ expected: [SessionNames.Piece]) throws {
    let text = try paragraph(markdown)

    #expect(names.pieces(text) == expected)
  }

  /// A code block never becomes a paragraph's `MarkdownText`, so its ids never reach `pieces`.
  @Test(arguments: ["```\nseb4ec\n```", "    seb4ec"])
  func codeBlockIsNotInlineText(_ markdown: String) {
    let blocks = MarkdownBlock.parse(markdown)

    #expect(blocks.count == 1)
    guard case .code(_, let code) = blocks.first else {
      Issue.record("\(markdown) parses to \(blocks), not a code block")
      return
    }
    #expect(code.contains("seb4ec"))
  }

  @Test func aClosingParenthesisInAnotherRunKeepsTheNameAsWritten() {
    let text = text(Run("zsh-startup-for-switchboard (seb4ec"), Run(")", .emphasis))

    #expect(names.pieces(text) == [piece("zsh-startup-for-switchboard ("), mention("seb4ec"), piece(")", .emphasis)])
  }

  @Test func footnoteRunPassesThrough() {
    let text = text(Run("See "), Run("seb4ec", .footnote))

    #expect(names.pieces(text) == unchanged(text))
  }

  @Test func imageRunPassesThrough() {
    let text = text(Run("seb4ec", image: "x.png"), Run(" seb4ec"))

    #expect(names.pieces(text) == [piece("seb4ec", image: "x.png"), piece(" "), mention("seb4ec")])
  }

  @Test func linkRunPassesThrough() {
    let text = text(Run("seb4ec", link: "https://example.com"), Run(" and seb4ec"))

    #expect(names.pieces(text) == [piece("seb4ec", link: "https://example.com"), piece(" and "), mention("seb4ec")])
  }

  @Test func exactIdCodeSpanKeepsItsOtherStyles() {
    let text = text(Run("seb4ec", [.code, .strong]))

    #expect(names.pieces(text) == [mention("seb4ec", .strong)])
  }

  @Test func exactIdCodeSpanOfAnUnknownIdKeepsItsCodeStyle() {
    let text = text(Run("sx2zzz", .code))

    #expect(names.pieces(text) == unchanged(text))
  }

  @Test func idSplitAcrossRunsPassesThrough() {
    let text = text(Run("seb"), Run("4ec"))

    #expect(names.pieces(text) == unchanged(text))
  }

  @Test func sessionWithAnEmptyNameResolvesNothing() {
    let names = SessionNames(live: ["seb4ec": ""], removed: ["sq7kpm": ""])

    #expect(names.isEmpty)
    #expect(names.entry("seb4ec") == nil)
    #expect(names.replacingIDs(in: "seb4ec () and sq7kpm") == "seb4ec () and sq7kpm")
  }

  @Test func collapseThatOverlapsAnEarlierOneStillReplacesItsId() {
    let live = ["sa2222": "b", "sb3333": "b)"]
    let names = SessionNames(live: live, removed: [:])

    #expect(names.pieces("sa2222 (b) (sb3333)") == expectedPieces("⟨sa2222⟩ (⟨sb3333⟩)", live: live))
  }

  @Test func idAtTheEdgeOfAnEmphasisRunMatches() {
    let text = text(Run("Ask "), Run("seb4ec", .emphasis), Run(" now"))

    #expect(names.pieces(text) == [piece("Ask "), mention("seb4ec", .emphasis), piece(" now")])
  }

  @Test(arguments: unchangedPlain)
  func textWithoutIdsHasNoMatches(_ input: String) {
    #expect(names.pieces(MarkdownText(stringLiteral: input)).allSatisfy { $0.match == nil })
  }

  @Test func matchesReportLiveAndRemovedSessions() {
    let matches = names.pieces("sgcctv and sq7kpm").compactMap(\.match)

    #expect(
      matches == [
        Match(id: "sgcctv", name: "render-session-names", removed: false),
        Match(id: "sq7kpm", name: "old-cleanup", removed: true),
      ])
  }

  @Test func removedSessionDecodesFromJSON() throws {
    let json = Data(#"{"id":"sq7kpm","name":"old-cleanup","removed":1762900000000}"#.utf8)

    let session = try JSONDecoder().decode(RemovedSession.self, from: json)

    #expect(session == RemovedSession(id: "sq7kpm", name: "old-cleanup", removed: 1_762_900_000_000))
  }

  @Test func removedSessionRoundTripsThroughJSON() throws {
    let session = RemovedSession(id: "sq7kpm", name: "old-cleanup", removed: 1_762_900_000_000)

    let decoded = try JSONDecoder().decode(RemovedSession.self, from: JSONEncoder().encode(session))

    #expect(decoded == session)
  }

  /// 2,000 distinct ids in the session id alphabet.
  private static let manyIds: [String] = {
    let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
    return (0..<2_000).map { i in
      var n = i
      var id = "s"
      for _ in 0..<5 {
        id.append(alphabet[n % alphabet.count])
        n /= alphabet.count
      }
      return id
    }
  }()

  private static func manyNames() -> SessionNames {
    SessionNames(
      live: Dictionary(uniqueKeysWithValues: manyIds.enumerated().map { ($1, "session-\($0)") }), removed: [:])
  }

  /// Text around each id: look-alike words, punctuation, and multibyte characters.
  private static let filler =
    " to rebase, then check the café ☕ build log for the stream, switch, and submit steps on main street; "

  @Test func matchingTwoThousandIdsInOneRunIsFast() {
    let string = Self.manyIds.map { "Ask \($0)\(Self.filler)" }.joined()
    let text = MarkdownText(stringLiteral: string)
    let names = Self.manyNames()
    var matched = 0

    let elapsed = ContinuousClock().measure { matched = names.pieces(text).count(where: { $0.match != nil }) }

    #expect(string.utf8.count >= 200_000)
    #expect(matched == 2_000)
    #expect(elapsed < .seconds(1))
  }

  @Test func matchingTwoThousandIdsAcrossManyRunsIsFast() {
    let runs = Self.manyIds.flatMap { [Run("Ask "), Run($0, .emphasis), Run(Self.filler)] }
    let text = MarkdownText(runs)
    let names = Self.manyNames()
    var matched = 0

    let elapsed = ContinuousClock().measure { matched = names.pieces(text).count(where: { $0.match != nil }) }

    #expect(text.plain.utf8.count >= 200_000)
    #expect(matched == 2_000)
    #expect(elapsed < .seconds(1))
  }
}
