import Foundation
import Testing

@testable import SwitchboardCore

/// A screen that `TerminalHost.screen` captured from Claude Code 2.1.317.
/// The `prompt-*` screens come from 2.1.322 with their colors. Their files
/// store each ESC as ␛, because `gh pr diff` refuses a diff that holds raw
/// escape sequences.
func screenFixture(_ name: String) throws -> String {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/screens")
  return try String(contentsOf: dir.appendingPathComponent("\(name).txt"), encoding: .utf8)
    .replacingOccurrences(of: "␛", with: "\u{1B}")
}

/// The data of a hook event that Claude Code sent, with the user's name
/// written as "someone".
func eventFixture(_ name: String) throws -> JSON {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/events")
  let text = try String(contentsOf: dir.appendingPathComponent("\(name).json"), encoding: .utf8)
  return try JSONCoding.decode(JSON.self, from: text)
}

/// The command that the captured permission dialogs ask about.
let capturedCommand = "touch SB800284.txt"

func bashCard(_ command: String) -> Card {
  let input: [String: JSON] = ["command": .string(command)]
  return facts(promptTurn(tool("Bash", input, id: "b1"), tool("Bash", input))).cards[0]
}

func fruitCard() -> Card { facts(questionTurn()).cards[0] }

/// The captured open permission dialog, redrawn for another command. The
/// conversation above it still shows the captured command.
func otherCommandsScreen(_ lines: String = " rm other.txt") throws -> String {
  let screen = try screenFixture("perm-open")
  let line = "\n \(capturedCommand)\n"
  #expect(screen.components(separatedBy: line).count == 2)
  return screen.replacingOccurrences(of: line, with: "\n\(lines)\n")
}

func dialog(_ fixture: String) throws -> [String] {
  try #require(ClaudeScreen.dialog(screenFixture(fixture)))
}

/// The cwd of the session whose Edit, Write, and Read dialogs Claude Code
/// 2.1.322 drew in the captured screens.
let capturedCwd = "/private/tmp/sbt.Cap173/work"
let capturedNotes = "\(capturedCwd)/notes.txt"

/// A card for a file tool. The cwd goes in the PermissionRequest, as Claude
/// Code sends it.
func fileCard(_ name: String, _ input: [String: JSON], cwd: String? = capturedCwd) -> Card {
  var request = tool(name, input)
  if let cwd { request["cwd"] = .string(cwd) }
  return facts(promptTurn(tool(name, input, id: "e1"), request)).cards[0]
}

/// By default the edit of edit-open.txt: "beta" becomes "BETA" in notes.txt,
/// which holds alpha, beta, and gamma.
func editCard(
  _ path: String = capturedNotes, old: String = "beta", new: String = "BETA", replaceAll: Bool? = nil,
  cwd: String? = capturedCwd
) -> Card {
  var input: [String: JSON] = ["file_path": .string(path), "old_string": .string(old), "new_string": .string(new)]
  if let replaceAll { input["replace_all"] = .bool(replaceAll) }
  return fileCard("Edit", input, cwd: cwd)
}

/// The edit of edit-multi.txt. The prompt asked for 60 words, but the model
/// wrote 75, and the screen shows 75.
func multiEditCard(words: Int = 75) -> Card {
  let line = Array(repeating: "word", count: words).joined(separator: " ")
  return editCard(old: "alpha\nbeta", new: "first line\n\(line)\nlast line")
}

func writeCard(_ path: String, _ content: String, cwd: String? = capturedCwd) -> Card {
  fileCard("Write", ["file_path": .string(path), "content": .string(content)], cwd: cwd)
}

/// The write of write-open.txt.
func createCard() -> Card { writeCard("\(capturedCwd)/sub/new.txt", "one\ntwo") }

/// The write of write-overwrite.txt.
func overwriteCard() -> Card { writeCard(capturedNotes, "alpha\nBETA\ngamma\ndelta") }

/// The 80-line write of write-long.txt, from `first` to line 80.
func longWriteCard(from first: Int = 1) -> Card {
  writeCard("\(capturedCwd)/long.txt", (first...80).map { "line \($0)" }.joined(separator: "\n"))
}

func readCard(_ path: String = "/etc/hosts", _ extra: [String: JSON] = [:], cwd: String? = capturedCwd) -> Card {
  fileCard("Read", extra.merging(["file_path": .string(path)]) { a, _ in a }, cwd: cwd)
}

/// The dialog of a captured screen with some lines drawn differently. Each
/// line is named by its text without trailing spaces, and the name must
/// match exactly one line of the screen. That line becomes the given rows.
func redrawnDialog(_ fixture: String, _ rows: [(String, [String])]) throws -> [String] {
  var lines = try screenFixture(fixture).components(separatedBy: "\n")
  for (line, drawn) in rows {
    let hits = lines.indices.filter {
      lines[$0].replacingOccurrences(of: " +$", with: "", options: .regularExpression) == line
    }
    try #require(hits.count == 1, "\"\(line)\" is on \(hits.count) lines of \(fixture)")
    lines.replaceSubrange(hits[0]...hits[0], with: drawn)
  }
  return try #require(ClaudeScreen.dialog(lines.joined(separator: "\n")))
}

func redrawnDialog(_ fixture: String, _ line: String, _ rows: [String]) throws -> [String] {
  try redrawnDialog(fixture, [(line, rows)])
}

@Suite struct ClaudeScreenDialog {
  @Test(arguments: [
    "perm-open", "perm-down", "q-open", "edit-open", "edit-down", "edit-multi", "write-open", "write-overwrite",
    "write-long", "read-open", "write-memory", "write-cut-path", "write-symlink", "write-overwrite-symlink",
    "edit-symlink", "read-symlink", "write-restart", "write-restart-tall", "write-restart-cut-path",
    "write-restart-narrow",
  ])
  func anOpenDialogEndsAtItsFooter(_ fixture: String) throws {
    #expect(try dialog(fixture).last?.contains("Esc to cancel") == true)
  }

  @Test(arguments: ["perm-after-yes", "perm-after-esc", "q-after-esc", "edit-after-esc", "write-restart-after-esc"])
  func aScreenWithThePromptBoxShowsNoDialog(_ fixture: String) throws {
    #expect(ClaudeScreen.dialog(try screenFixture(fixture)) == nil)
  }

  @Test func aPermissionDialogHoldsItsCommandAndNotTheConversation() throws {
    let lines = try dialog("perm-open")
    #expect(lines.contains(" Bash command"))
    #expect(lines.contains(" \(capturedCommand)"))
    #expect(!lines.contains { $0.contains("⎿") || $0.contains("Run exactly this command") })
  }

  @Test func anEditDialogHoldsItsTitleAndNotTheToolCall() throws {
    let lines = try dialog("edit-open")
    #expect(lines.contains(" Edit file"))
    #expect(!lines.contains("⏺ Update(notes.txt)"))
  }

  @Test func anOverwriteDialogLeavesOutTheRejectedEditAboveIt() throws {
    let lines = try dialog("write-overwrite").map {
      $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }
    #expect(lines.first?.hasPrefix("─") == true)
    #expect(!lines.contains("      2 +BETA"))
  }

  @Test func aQuestionDialogStartsBelowThePastPrompt() throws {
    let lines = try dialog("q-open")
    #expect(lines.contains("←  ☐ Fruit  ☐ Colors  ✔ Submit  →"))
    #expect(lines.contains("Which fruit?"))
    #expect(!lines.contains { $0.hasPrefix("❯ Use the AskUserQuestion tool") })
  }

  @Test func aQuestionDialogKeepsTheLinesBelowItsSecondRule() throws {
    #expect(try dialog("q-open").contains("  4. Chat about this"))
  }

  @Test func aDialogWithoutARuleStartsBelowTheConversation() {
    let screen = """
      ❯ touch x

      ⏺ Bash(touch x)
       Do you want to proceed?
       ❯ 1. Yes
         2. No
       Esc to cancel


      """
    #expect(
      ClaudeScreen.dialog(screen) == [" Do you want to proceed?", " ❯ 1. Yes", "   2. No", " Esc to cancel"])
  }

  @Test func aFooterAboveThePromptBoxIsNoDialog() {
    let screen = """
      ❯ print the footer

      ⏺ Bash(echo "Esc to cancel")
        ⎿  Esc to cancel

      ──────────────────────────────
      ❯
      ──────────────────────────────
        /tmp/work | Haiku 5.5
      """
    #expect(ClaudeScreen.dialog(screen) == nil)
  }

  @Test(arguments: ["", "\n\n\n"])
  func aBlankScreenShowsNoDialog(_ screen: String) {
    #expect(ClaudeScreen.dialog(screen) == nil)
  }
}

@Suite struct ClaudeScreenShows {
  @Test func thePermissionDialogShowsItsCard() throws {
    #expect(ClaudeScreen.shows(bashCard(capturedCommand), try dialog("perm-open")))
  }

  /// Claude Code 2.1.322 adds these suffixes to the title of a command that
  /// bypasses the sandbox or runs on another machine.
  @Test(arguments: [" Bash command (unsandboxed)", " Bash command (runs on build-box)"])
  func aPermissionDialogWithASuffixedTitleShowsItsCard(_ title: String) throws {
    let lines = try redrawnDialog("perm-open", " Bash command", [title])
    #expect(ClaudeScreen.shows(bashCard(capturedCommand), lines))
    #expect(ClaudeScreen.mayShow(bashCard(capturedCommand), lines))
  }

  @Test(arguments: [" Bash commander", " Edit file"])
  func aPermissionDialogWithAnotherTitleIsNotShown(_ title: String) throws {
    let lines = try redrawnDialog("perm-open", " Bash command", [title])
    #expect(!ClaudeScreen.shows(bashCard(capturedCommand), lines))
    #expect(!ClaudeScreen.mayShow(bashCard(capturedCommand), lines))
  }

  @Test func theQuestionDialogShowsItsCard() throws {
    #expect(ClaudeScreen.shows(fruitCard(), try dialog("q-open")))
  }

  @Test func aCommandThatShowsOnlyAboveAnotherCommandsDialogIsNotShown() throws {
    let lines = try #require(ClaudeScreen.dialog(try otherCommandsScreen()))
    #expect(!ClaudeScreen.shows(bashCard(capturedCommand), lines))
  }

  @Test(arguments: ["touch SB800284.txt.bak", "touch SB800284.txt && rm -rf ~", "touch"])
  func aDialogForACommandThatOnlySharesTheCardsTextIsNotShown(_ shown: String) throws {
    let lines = try #require(ClaudeScreen.dialog(try otherCommandsScreen(" \(shown)")))
    #expect(!ClaudeScreen.shows(bashCard(capturedCommand), lines))
  }

  @Test func aWrappedCommandShowsItsCard() throws {
    let lines = try #require(ClaudeScreen.dialog(try otherCommandsScreen(" git commit -m \"one\n two\"")))
    #expect(ClaudeScreen.shows(bashCard("git commit -m \"one two\""), lines))
    #expect(ClaudeScreen.shows(bashCard("git commit -m \"one\ntwo\""), lines))
  }

  @Test func aCommandBrokenInsideAWordIsNotShown() throws {
    let lines = try #require(ClaudeScreen.dialog(try otherCommandsScreen(" touch SB8002\n84.txt")))
    #expect(!ClaudeScreen.shows(bashCard(capturedCommand), lines))
  }

  @Test func aCommandBrokenInsideAWordMayShowItsCard() throws {
    let lines = try #require(ClaudeScreen.dialog(try otherCommandsScreen(" touch SB8002\n84.txt")))
    #expect(ClaudeScreen.mayShow(bashCard(capturedCommand), lines))
  }

  @Test func anotherCommandsDialogMayNotShowTheCard() throws {
    let lines = try #require(ClaudeScreen.dialog(try otherCommandsScreen()))
    #expect(!ClaudeScreen.mayShow(bashCard(capturedCommand), lines))
  }

  @Test func theOtherCommandsDialogShowsItsOwnCard() throws {
    let lines = try #require(ClaudeScreen.dialog(try otherCommandsScreen()))
    #expect(ClaudeScreen.shows(bashCard("rm other.txt"), lines))
  }

  @Test func questionsThatShowOnlyInThePromptAboveAnotherQuestionAreNotShown() throws {
    let screen = try screenFixture("q-open")
      .replacingOccurrences(of: "←  ☐ Fruit  ☐ Colors  ✔ Submit  →", with: "←  ☐ Snack  ✔ Submit  →")
      .replacingOccurrences(of: "\nWhich fruit?\n", with: "\nWhich snack?\n")
    let lines = try #require(ClaudeScreen.dialog(screen))
    #expect(!ClaudeScreen.shows(fruitCard(), lines))
  }

  @Test func aQuestionCardIsNotShownByAPermissionDialog() throws {
    #expect(!ClaudeScreen.shows(fruitCard(), try dialog("perm-open")))
  }

  @Test func anUnfindableCardIsNeverShown() throws {
    let fetch = facts(promptTurn(touchCall, tool("WebFetch", ["url": "https://example.com"]))).cards[0]
    #expect(!ClaudeScreen.shows(fetch, try dialog("perm-open")))
  }
}

@Suite struct ClaudeScreenHighlighted {
  @Test(arguments: [
    ("perm-open", "1. Yes"), ("perm-down", "2. No"), ("q-open", "1. apple"), ("edit-open", "1. Yes"),
    ("edit-multi", "1. Yes"), ("read-open", "1. Yes"),
    (
      "edit-down",
      "2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)"
    ),
  ])
  func theHighlightedItemIsTheCursorsLine(_ fixture: String, _ item: String) throws {
    #expect(ClaudeScreen.highlighted(try dialog(fixture)) == item)
  }

  @Test func theHighlightedItemIsOnTheLastCursorLine() {
    let lines = [
      "────", " Bash command", " ❯ echo hi", " Do you want to proceed?", "   1. Yes", " ❯ 2. No", " Esc to cancel",
    ]
    #expect(ClaudeScreen.highlighted(lines) == "2. No")
  }

  @Test func aDialogWithoutACursorHighlightsNothing() {
    #expect(ClaudeScreen.highlighted([" Do you want to proceed?", " Esc to cancel"]) == nil)
  }

  @Test(arguments: [
    ("1. Yes", true), ("Yes", true), ("2. Yes, and don't ask again for touch commands in /tmp", false),
    ("2. No", false),
  ])
  func onlyThePlainYesIsYes(_ item: String, _ yes: Bool) {
    #expect(ClaudeScreen.isYes(item) == yes)
  }
}

@Suite struct CardMarks {
  @Test(arguments: ["touch x", "  make test  \n  && echo done"])
  func aBashCardIsFindable(_ command: String) {
    #expect(bashCard(command).findable)
  }

  @Test func aQuestionCardIsFindable() {
    #expect(fruitCard().findable)
  }

  @Test(arguments: ["", "   ", "\n  "])
  func aBashCardWithABlankCommandIsNotFindable(_ command: String) {
    #expect(!bashCard(command).findable)
  }

  @Test func aQuestionCardsMarksAreItsQuestionsAndHeaders() {
    #expect(Set(fruitCard().marks) == ["Which fruit?", "Fruit", "Which colors?", "Colors"])
  }

  @Test func aQuestionsMarkIsCutToFortyCharacters() {
    let text = "Which of these fruits should go into the salad tonight?"
    let card = facts(promptTurn(ask(), ask(["questions": [["question": .string(text), "options": []]]], id: nil)))
      .cards[0]
    #expect(card.marks == [String(text.prefix(40))])
  }

  @Test func aBlankHeaderIsNoMark() {
    let input: JSON = ["questions": [["question": "Which fruit?", "header": "", "options": []]]]
    #expect(facts(promptTurn(ask(), ask(input, id: nil))).cards[0].marks == ["Which fruit?"])
  }

  @Test(arguments: [
    tool("WebFetch", ["url": "https://example.com"]), tool("Edit", ["file_path": "/tmp/a", "old_string": "a"]),
    tool("mcp__github__create_issue", ["title": "a"]),
  ])
  func otherToolsAreNotFindable(_ request: [String: JSON]) {
    #expect(!facts(promptTurn(touchCall, request)).cards[0].findable)
  }
}

@Suite struct DialogWatchChecks {
  func results(_ watch: inout DialogWatch, _ open: [Card], _ screens: [String]) -> [[Int64]] {
    screens.map { watch.check(open, screen: $0) }
  }

  func shown() throws -> String { try screenFixture("perm-open") }
  func gone() throws -> String { try screenFixture("perm-after-yes") }

  @Test func aCardWhoseDialogIsNotDrawnYetStays() throws {
    var watch = DialogWatch()
    #expect(results(&watch, [bashCard(capturedCommand)], [try gone(), try gone(), try gone()]) == [[], [], []])
  }

  @Test func aDialogThatWasSeenHasLeftAfterTwoMisses() throws {
    var watch = DialogWatch()
    let card = bashCard(capturedCommand)
    #expect(results(&watch, [card], [try shown(), try gone(), try gone()]) == [[], [], [card.id]])
  }

  @Test func oneMissBetweenSightingsIsARedraw() throws {
    var watch = DialogWatch()
    let screens = [try shown(), try gone(), try shown(), try gone()]
    #expect(results(&watch, [bashCard(capturedCommand)], screens) == [[], [], [], []])
  }

  @Test func aClosedHooksDialogHasLeftAfterTwoMissesThoughNoCheckSawIt() throws {
    var watch = DialogWatch()
    var card = bashCard(capturedCommand)
    card.hookClosed = true
    #expect(results(&watch, [card], [try gone(), try gone()]) == [[], [card.id]])
  }

  @Test func aClosedHooksCardStaysWhileItsDialogShows() throws {
    var watch = DialogWatch()
    var card = bashCard(capturedCommand)
    card.hookClosed = true
    #expect(results(&watch, [card], [try shown(), try shown(), try shown()]) == [[], [], []])
  }

  @Test func aCardThatIsNoLongerOpenIsNotReported() throws {
    var watch = DialogWatch()
    let card = bashCard(capturedCommand)
    #expect(watch.check([card], screen: try shown()).isEmpty)
    #expect(watch.check([card], screen: try gone()).isEmpty)
    #expect(watch.check([], screen: try gone()).isEmpty)
    #expect(watch.check([card], screen: try gone()).isEmpty)
  }

  @Test func aSeenDialogThatANarrowerPaneBreaksInsideAWordStays() throws {
    var watch = DialogWatch()
    let card = bashCard(capturedCommand)
    let narrow = try otherCommandsScreen(" touch SB8002\n84.txt")
    #expect(results(&watch, [card], [try shown(), narrow, narrow]) == [[], [], []])
  }

  @Test func eachCardIsJudgedByItsOwnDialog() throws {
    var watch = DialogWatch()
    let shownCard = bashCard(capturedCommand)
    var other = bashCard("rm other.txt")
    other.id = 5
    other.hookClosed = true
    #expect(results(&watch, [shownCard, other], [try shown(), try shown()]) == [[], [5]])
  }

  @Test func anUnfindableCardIsNeverReported() throws {
    var watch = DialogWatch()
    var fetch = facts(promptTurn(touchCall, tool("WebFetch", ["url": "https://example.com"]))).cards[0]
    fetch.hookClosed = true
    #expect(results(&watch, [fetch], [try gone(), try gone(), try gone()]) == [[], [], []])
  }

  @Test func anEditDialogThatWasSeenHasLeftAfterTwoMisses() throws {
    var watch = DialogWatch()
    let card = editCard()
    let screens = try ["edit-open", "edit-after-esc", "edit-after-esc"].map(screenFixture)
    #expect(results(&watch, [card], screens) == [[], [], [card.id]])
  }

  @Test func anEditDialogWhoseCursorMovedStays() throws {
    var watch = DialogWatch()
    let screens = try ["edit-open", "edit-down", "edit-down"].map(screenFixture)
    #expect(results(&watch, [editCard()], screens) == [[], [], []])
  }

  @Test func aClosedHooksEditCardHasLeftAfterTwoMissesThoughNoCheckSawIt() throws {
    var watch = DialogWatch()
    var card = editCard()
    card.hookClosed = true
    let screens = try ["edit-after-esc", "edit-after-esc"].map(screenFixture)
    #expect(results(&watch, [card], screens) == [[], [card.id]])
  }

  /// edit-open with every line through the dialog's first dashed rule
  /// scrolled off the pane, so the title and path no longer show.
  func editWithItsTopScrolledOff() throws -> String {
    let lines = try screenFixture("edit-open").components(separatedBy: "\n")
    let open = try #require(lines.firstIndex(where: ClaudeScreen.isDashedRule))
    return lines[(open + 1)...].joined(separator: "\n")
  }

  @Test func aSeenEditDialogWhoseTopScrolledOffStaysWhileItsHookIsOpen() throws {
    var watch = DialogWatch()
    let screens = [try screenFixture("edit-open"), try editWithItsTopScrolledOff(), try editWithItsTopScrolledOff()]
    #expect(results(&watch, [editCard()], screens) == [[], [], []])
  }

  @Test func aReadCardStaysWhileItsDialogShows() throws {
    var watch = DialogWatch()
    var card = readCard()
    card.hookClosed = true
    let screens = try ["read-open", "read-open", "read-open"].map(screenFixture)
    #expect(results(&watch, [card], screens) == [[], [], []])
  }

  @Test func aDeferredCardIsNeverReported() throws {
    var watch = DialogWatch()
    var card = fruitCard()
    card.deferred = true
    let screens = [try screenFixture("q-open"), try screenFixture("q-after-esc"), try screenFixture("q-after-esc")]
    #expect(results(&watch, [card], screens) == [[], [], []])
  }

  @Test(arguments: [false, true])
  func anUnmatchedDialogResetsTheRunOfMisses(_ hookClosed: Bool) throws {
    var watch = DialogWatch()
    var card = editCard()
    card.hookClosed = hookClosed
    let gone = try screenFixture("edit-after-esc")
    let screens = [try screenFixture("edit-open"), gone, try editWithItsTopScrolledOff(), gone, gone]
    #expect(results(&watch, [card], screens) == [[], [], [], [], [card.id]])
  }

  @Test(arguments: [("perm-open", "perm-after-yes"), ("edit-open", "edit-after-esc")], [false, true])
  func aDialogThatTwoCardsMatchIsASightingForBoth(_ fixtures: (String, String), _ hookClosed: Bool) throws {
    var watch = DialogWatch()
    var first = fixtures.0 == "perm-open" ? bashCard(capturedCommand) : editCard()
    first.hookClosed = hookClosed
    let second = DialogWatchChecks.withId(first, 5)
    let shown = try screenFixture(fixtures.0)
    let gone = try screenFixture(fixtures.1)
    #expect(results(&watch, [first, second], [shown, shown, gone, gone]) == [[], [], [], [first.id, 5]])
  }

  /// Whether the card's hook closed, and whether a check saw its dialog first.
  static let hookAndSeen: [(Bool, Bool)] = [(false, false), (false, true), (true, false), (true, true)]

  /// A captured screen, or one that this suite redraws from a capture.
  func screen(_ name: String) throws -> String {
    switch name {
    case "perm-open-other": return try otherCommandsScreen()
    case "edit-open-top-scrolled-off": return try editWithItsTopScrolledOff()
    default: return try screenFixture(name)
    }
  }

  /// The card's own dialog when `seen` holds, then `rest`.
  func run(_ shown: String, seen: Bool, _ rest: [String]) throws -> [String] {
    try ((seen ? [shown] : []) + rest).map(screen)
  }

  /// Expects the card to leave after two checks of `miss` when its hook
  /// closed or a check saw its dialog, and to stay otherwise. `others` are
  /// open beside it.
  func expectLeavesAfterTwoMisses(
    _ card: Card, _ own: String, _ miss: String, _ state: (Bool, Bool), others: [Card] = [],
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    var watch = DialogWatch()
    var card = card
    card.hookClosed = state.0
    let screens = try run(own, seen: state.1, [miss, miss])
    let leaves = state.0 || state.1
    let expected: [[Int64]] = (state.1 ? [[]] : []) + [[], leaves ? [card.id] : []]
    #expect(results(&watch, [card] + others, screens) == expected, sourceLocation: sourceLocation)
  }

  /// Expects the card to stay through three checks of `dialog`. `others` are
  /// open beside it.
  func expectStays(
    _ card: Card, _ own: String, _ dialog: String, _ state: (Bool, Bool), others: [Card] = [],
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    var watch = DialogWatch()
    var card = card
    card.hookClosed = state.0
    let screens = try run(own, seen: state.1, Array(repeating: dialog, count: 3))
    #expect(
      results(&watch, [card] + others, screens) == Array(repeating: [], count: screens.count),
      sourceLocation: sourceLocation)
  }

  /// A lone card, its own dialog, and a dialog that no open card may show.
  static let unmatchedDialogs: [(Card, String, String)] = [
    (bashCard(capturedCommand), "perm-open", "perm-open-other"), (bashCard(capturedCommand), "perm-open", "edit-open"),
    (bashCard(capturedCommand), "perm-open", "q-open"), (bashCard(capturedCommand), "perm-open", "trust-open"),
    (editCard(), "edit-open", "edit-open-top-scrolled-off"), (editCard(), "edit-open", "edit-multi"),
    (editCard(), "edit-open", "read-open"), (editCard(), "edit-open", "perm-open-other"),
  ]

  @Test(arguments: unmatchedDialogs, hookAndSeen)
  func noUnmatchedDialogIsAMiss(_ shape: (Card, String, String), _ state: (Bool, Bool)) throws {
    try expectStays(shape.0, shape.1, shape.2, state)
  }

  /// A card, its own dialog, and a screen without a dialog.
  static let screensWithoutADialog: [(Card, String, String)] = [
    (bashCard(capturedCommand), "perm-open", "perm-after-yes"),
    (bashCard(capturedCommand), "perm-open", "perm-after-esc"),
    (bashCard(capturedCommand), "perm-open", "prompt-empty"), (editCard(), "edit-open", "edit-after-esc"),
    (editCard(), "edit-open", "prompt-typed"),
  ]

  @Test(arguments: screensWithoutADialog, hookAndSeen)
  func aScreenWithoutADialogIsAMiss(_ shape: (Card, String, String), _ state: (Bool, Bool)) throws {
    try expectLeavesAfterTwoMisses(shape.0, shape.1, shape.2, state)
  }

  static func withId(_ card: Card, _ id: Int64) -> Card {
    var card = card
    card.id = id
    return card
  }

  /// A card, its own dialog, another open card with id 5, and that card's dialog.
  static let otherCardsDialogs: [(Card, String, Card, String)] = [
    (bashCard(capturedCommand), "perm-open", withId(bashCard("rm other.txt"), 5), "perm-open-other"),
    (editCard(), "edit-open", withId(multiEditCard(), 5), "edit-multi"),
    (editCard(), "edit-open", withId(bashCard(capturedCommand), 5), "perm-open"),
    (bashCard(capturedCommand), "perm-open", withId(editCard(), 5), "edit-open"),
  ]

  @Test(arguments: otherCardsDialogs, hookAndSeen)
  func anotherOpenCardsDialogIsAMiss(_ shape: (Card, String, Card, String), _ state: (Bool, Bool)) throws {
    try expectLeavesAfterTwoMisses(shape.0, shape.1, shape.3, state, others: [shape.2])
  }

  /// A card, its own dialog, and another open card with id 5 whose dialog
  /// sbd doesn't watch, with that dialog.
  static let unwatchedCardsDialogs: [(Card, String, Card, String)] = [
    (bashCard(capturedCommand), "perm-open", deferred(withId(fruitCard(), 5)), "q-open"),
    (bashCard(capturedCommand), "perm-open", deferred(withId(bashCard("rm other.txt"), 5)), "perm-open-other"),
  ]

  static func deferred(_ card: Card) -> Card {
    var card = card
    card.deferred = true
    return card
  }

  @Test(arguments: unwatchedCardsDialogs, hookAndSeen)
  func aDialogThatOnlyAnUnwatchedCardMayShowIsNotAMiss(
    _ shape: (Card, String, Card, String), _ state: (Bool, Bool)
  ) throws {
    try expectStays(shape.0, shape.1, shape.3, state, others: [shape.2])
  }

  @Test(arguments: [false, true])
  func aCardsOwnDialogIsNeverAMiss(_ hookClosed: Bool) throws {
    var watch = DialogWatch()
    var card = editCard()
    card.hookClosed = hookClosed
    let screens = try ["edit-open", "edit-down", "edit-open", "edit-down"].map(screenFixture)
    #expect(results(&watch, [card], screens) == [[], [], [], []])
  }

  /// A question whose header is a word of the file that the Edit dialog shows.
  static func gammaQuestion() -> Card {
    let questions: JSON = [
      "questions": [["question": "Which letter?", "header": "gamma", "options": [["label": "a"], ["label": "b"]]]]
    ]
    return withId(facts(promptTurn(ask(questions), ask(questions, id: nil))).cards[0], 5)
  }

  @Test(arguments: [false, true])
  func aQuestionDoesNotClaimAPermissionDialogWhoseTopScrolledOff(_ hookClosed: Bool) throws {
    var watch = DialogWatch()
    var card = editCard()
    card.hookClosed = hookClosed
    let question = DialogWatchChecks.gammaQuestion()
    let scrolled = try editWithItsTopScrolledOff()
    #expect(scrolled.contains("gamma"))
    let screens = [try screenFixture("edit-open"), scrolled, scrolled, scrolled]
    #expect(results(&watch, [card, question], screens) == [[], [], [], []])
  }

  @Test func aQuestionsOwnDialogIsAMissForAnOpenPermissionCard() throws {
    var watch = DialogWatch()
    let card = bashCard(capturedCommand)
    let question = DialogWatchChecks.withId(fruitCard(), 5)
    let screens = try ["perm-open", "q-open", "q-open"].map(screenFixture)
    #expect(results(&watch, [card, question], screens) == [[], [], [card.id]])
  }
}

/// The Write prompt of session shtw8y, whose card left the Inbox after sbd
/// restarted while the pane was too short for the dialog. Claude Code 2.1.322
/// drew the `write-restart` screens for it.
func writeRestartCard(restarted: Bool = true) throws -> Card {
  let request = Event(id: 3, session: "s1", t: 2, kind: "PermissionRequest", data: try eventFixture("write-restart"))
  var replay = SessionReplay.replaying([request], session: session())
  if restarted { replay.restarted() }
  return try #require(replay.facts.cards.first)
}

@Suite struct WriteRestartDialog {
  /// The dialog with its title scrolled off, with its path cut by the
  /// pane's width, and with both.
  static let cutDialogs = ["write-restart-tall", "write-restart-cut-path", "write-restart-narrow"]

  func results(_ watch: inout DialogWatch, _ card: Card, _ fixtures: [String]) throws -> [[Int64]] {
    try fixtures.map { watch.check([card], screen: try screenFixture($0)) }
  }

  @Test func theRestartClosesTheCardsHook() throws {
    #expect(try writeRestartCard().hookClosed)
  }

  @Test func theFullDialogShowsTheCard() throws {
    #expect(ClaudeScreen.shows(try writeRestartCard(), try dialog("write-restart")))
  }

  @Test(arguments: cutDialogs)
  func eachCutDialogIsStillADialog(_ fixture: String) throws {
    let lines = ClaudeScreen.dialog(try screenFixture(fixture))
    #expect(lines != nil)
    #expect(!ClaudeScreen.mayShow(try writeRestartCard(), lines ?? []))
  }

  @Test(arguments: cutDialogs)
  func aRestartedCardStaysThroughCutDialogs(_ fixture: String) throws {
    var watch = DialogWatch()
    let card = try writeRestartCard()
    let left = try results(&watch, card, Array(repeating: fixture, count: 4))
    #expect(left == [[], [], [], []])
    #expect(ClaudeScreen.shows(card, try dialog("write-restart")))
  }

  @Test func aRestartedCardStaysThroughEachCutDialogInTurn() throws {
    var watch = DialogWatch()
    let fixtures = WriteRestartDialog.cutDialogs + WriteRestartDialog.cutDialogs
    let left = try results(&watch, try writeRestartCard(), fixtures)
    #expect(left == Array(repeating: [], count: fixtures.count))
  }

  @Test func aRestartedCardLeavesAfterEscape() throws {
    var watch = DialogWatch()
    let fixtures = ["write-restart-after-esc", "write-restart-after-esc"]
    let left = try results(&watch, try writeRestartCard(), fixtures)
    #expect(left == [[], [3]])
  }

  @Test(arguments: cutDialogs)
  func aRestartedCardLeavesAfterEscapeThatFollowsACutDialog(_ fixture: String) throws {
    var watch = DialogWatch()
    let fixtures = [fixture, fixture, "write-restart-after-esc", "write-restart-after-esc"]
    let left = try results(&watch, try writeRestartCard(), fixtures)
    #expect(left == [[], [], [], [3]])
  }

  @Test func aSeenCardWithAnOpenHookStaysWhenThePaneNarrows() throws {
    var watch = DialogWatch()
    let card = try writeRestartCard(restarted: false)
    let fixtures = ["write-restart", "write-restart-cut-path", "write-restart-cut-path", "write-restart-narrow"]
    #expect(!card.hookClosed)
    let left = try results(&watch, card, fixtures)
    #expect(left == [[], [], [], []])
  }
}

@Suite struct TypingRefusal {
  /// A question whose question text is the command that perm-open shows.
  static func touchQuestion() -> Card {
    let questions: JSON = [
      "questions": [["question": .string(capturedCommand), "options": [["label": "a"], ["label": "b"]]]]
    ]
    return facts(promptTurn(ask(questions), ask(questions, id: nil))).cards[0]
  }

  /// A question card, a permission dialog that shows one of its marks, and that mark.
  static func questionMarksInPermissionDialogs() throws -> [(Card, [String], String)] {
    let scrolled = try #require(ClaudeScreen.dialog(try DialogWatchChecks().editWithItsTopScrolledOff()))
    return [
      (DialogWatchChecks.gammaQuestion(), try dialog("edit-open"), "gamma"),
      (DialogWatchChecks.gammaQuestion(), scrolled, "gamma"),
      (touchQuestion(), try dialog("perm-open"), capturedCommand),
    ]
  }

  @Test func aQuestionCardIsNotShownByAPermissionDialogThatHoldsItsMark() throws {
    for (card, lines, mark) in try TypingRefusal.questionMarksInPermissionDialogs() {
      try #require(card.marks.contains(mark))
      try #require(lines.contains { $0.contains(mark) })
      #expect(!ClaudeScreen.shows(card, lines))
    }
  }

  @Test func aQuestionCardIsStillShownByItsOwnDialog() throws {
    #expect(ClaudeScreen.shows(fruitCard(), try dialog("q-open")))
  }

  static func doesNotShow(_ id: Int64) -> String {
    "the terminal doesn't show card \(id)'s dialog. Answer it in the terminal"
  }

  static func scrolledOff(_ id: Int64) -> String {
    "the top of card \(id)'s dialog scrolled off the terminal, so sbd can't check which call it answers. "
      + "Make the terminal taller, or answer it there"
  }

  static func cantMatch(_ id: Int64) -> String {
    "the terminal shows a dialog that sbd can't match to card \(id), such as one whose path the pane cuts. "
      + "Widen the terminal, or answer it there"
  }

  /// Why `typingDialog` refuses the card's dialog on the screen, or nil when it returns the dialog.
  private func typingRefusal(_ card: Card, screen: String?) -> String? {
    do {
      _ = try ClaudeScreen.typingDialog(card, screen: screen)
      return nil
    } catch {
      return "\(error)"
    }
  }

  @Test func theWholeDialogIsNotRefused() throws {
    #expect(typingRefusal(try writeRestartCard(), screen: try screenFixture("write-restart")) == nil)
  }

  @Test(arguments: ["write-restart-tall", "write-restart-narrow"])
  func aDialogWhoseTopScrolledOffIsRefusedAsScrolledOff(_ fixture: String) throws {
    let card = try writeRestartCard()

    let refusal = typingRefusal(card, screen: try screenFixture(fixture))

    #expect(refusal == TypingRefusal.scrolledOff(card.id))
  }

  @Test func aDialogWhosePathThePaneCutsIsRefusedAsUnmatched() throws {
    let card = try writeRestartCard()

    let refusal = typingRefusal(card, screen: try screenFixture("write-restart-cut-path"))

    #expect(refusal == TypingRefusal.cantMatch(card.id))
  }

  @Test(arguments: ["write-restart-after-esc", nil] as [String?])
  func aScreenWithoutTheDialogIsRefusedAsNotShown(_ fixture: String?) throws {
    let card = try writeRestartCard()

    let refusal = typingRefusal(card, screen: try fixture.map(screenFixture))

    #expect(refusal == TypingRefusal.doesNotShow(card.id))
  }

  @Test func eachCauseGetsItsOwnRefusal() throws {
    let card = try writeRestartCard()
    let fixtures = ["write-restart-after-esc", "write-restart-tall", "write-restart-cut-path"]

    let refusals = try fixtures.map { try #require(typingRefusal(card, screen: try screenFixture($0))) }

    #expect(Set(refusals).count == fixtures.count)
  }

  @Test func anEditDialogWhoseTopScrolledOffIsRefusedAsScrolledOff() throws {
    let card = editCard()

    let refusal = typingRefusal(card, screen: try DialogWatchChecks().editWithItsTopScrolledOff())

    #expect(refusal == TypingRefusal.scrolledOff(card.id))
  }

  @Test(arguments: [" rm other.txt", " touch SB8002\n84.txt"])
  func anotherCommandsWholeDialogIsRefusedAsUnmatched(_ lines: String) throws {
    let card = bashCard(capturedCommand)

    let refusal = typingRefusal(card, screen: try otherCommandsScreen(lines))

    #expect(refusal == TypingRefusal.cantMatch(card.id))
  }

  @Test func aQuestionCardIsRefusedOnAPermissionDialogThatHoldsItsMark() throws {
    let card = DialogWatchChecks.gammaQuestion()

    let refusal = typingRefusal(card, screen: try screenFixture("edit-open"))

    #expect(refusal == TypingRefusal.cantMatch(card.id))
  }

  /// A card and a screen, captured or redrawn by `DialogWatchChecks.screen`.
  static let shapes: [(Card, String)] = [
    (bashCard(capturedCommand), "perm-open"), (bashCard(capturedCommand), "perm-open-other"),
    (bashCard(capturedCommand), "edit-open"), (bashCard(capturedCommand), "perm-after-yes"),
    (bashCard("rm other.txt"), "perm-open-other"), (editCard(), "edit-open"), (editCard(), "edit-down"),
    (editCard(), "edit-open-top-scrolled-off"), (editCard(), "edit-multi"), (editCard(), "edit-after-esc"),
    (createCard(), "write-open"), (readCard(), "read-open"), (fruitCard(), "q-open"), (fruitCard(), "perm-open"),
    (DialogWatchChecks.gammaQuestion(), "edit-open"), (DialogWatchChecks.gammaQuestion(), "edit-open-top-scrolled-off"),
    (TypingRefusal.touchQuestion(), "perm-open"),
  ]

  /// sbd types only when `typingDialog` returns a dialog, and `shows` is the typing guard.
  @Test(arguments: shapes)
  func theRefusalIsNilExactlyWhenTheDialogShowsTheCard(_ shape: (Card, String)) throws {
    let screen = try DialogWatchChecks().screen(shape.1)
    let shown = ClaudeScreen.dialog(screen).map { ClaudeScreen.shows(shape.0, $0) } ?? false

    let refusal = typingRefusal(shape.0, screen: screen)

    #expect((refusal == nil) == shown)
  }
}

@Suite struct FileCardCwd {
  @Test(arguments: [capturedCwd, nil] as [String?])
  func aCardKeepsItsRequestsCwd(_ cwd: String?) {
    #expect(editCard(cwd: cwd).cwd == cwd)
  }
}

/// Edit, Write, and Read dialogs from Claude Code 2.1.322.
@Suite struct FileDialogShows {
  @Test(arguments: [
    (editCard(), "edit-open"), (editCard(replaceAll: true), "edit-open"), (editCard(replaceAll: false), "edit-open"),
    (editCard(), "edit-down"), (multiEditCard(), "edit-multi"), (createCard(), "write-open"),
    (writeCard("\(capturedCwd)/sub/new.txt", "one\ntwo\n"), "write-open"), (overwriteCard(), "write-overwrite"),
    (writeCard(capturedNotes, "alpha\nBETA\ngamma\ndelta\n"), "write-overwrite"), (readCard(), "read-open"),
  ])
  func aFileDialogShowsItsCard(_ card: Card, _ fixture: String) throws {
    #expect(ClaudeScreen.shows(card, try dialog(fixture)))
  }

  @Test(arguments: [
    "\(capturedCwd)/other.txt", "\(capturedCwd)/notes.txt.bak", "\(capturedCwd)/sub/notes.txt",
    "/private/tmp/sbt.Cap173/notes.txt", "/tmp/notes.txt",
  ])
  func anEditOfAnotherFileIsNotShown(_ path: String) throws {
    #expect(!ClaudeScreen.shows(editCard(path), try dialog("edit-open")))
  }

  @Test(arguments: [" other.txt", " notes.txt.bak", " sub/notes.txt", " /tmp/notes.txt"])
  func aDialogThatNamesAnotherFileIsNotShown(_ path: String) throws {
    #expect(!ClaudeScreen.shows(editCard(), try redrawnDialog("edit-open", " notes.txt", [path])))
  }

  @Test(arguments: [capturedCwd, nil] as [String?])
  func anAbsolutePathOnTheScreenIsComparedAsIs(_ cwd: String?) throws {
    let lines = try redrawnDialog("edit-open", " notes.txt", [" \(capturedNotes)"])
    #expect(ClaudeScreen.shows(editCard(cwd: cwd), lines))
  }

  @Test func aRelativePathWithoutACwdIsNotShown() throws {
    #expect(!ClaudeScreen.shows(editCard(cwd: nil), try dialog("edit-open")))
  }

  @Test func aRelativePathResolvesAgainstTheCardsCwd() throws {
    #expect(!ClaudeScreen.shows(editCard(cwd: "/private/tmp/sbt.Cap173/other"), try dialog("edit-open")))
  }

  @Test(arguments: [
    ("/a/b/../c", "/a/c"), ("/a/./b/", "/a/b"), ("/a/../../../b", "/b"), ("//a//b", "/a/b"), ("/..", "/"),
  ])
  func aPathResolvesItsDotsAsPOSIXDoes(_ path: String, _ resolved: String) {
    #expect(FileCall.normalized(path) == resolved)
  }

  /// More `..` steps than the cwd has folders stop at the root.
  @Test func aRelativePathThatClimbsPastTheRootStopsThere() throws {
    let outside = "/Users/someone/sbcap173.txt"
    #expect(
      ClaudeScreen.shows(editCard(outside, old: "TWO", new: "2", cwd: "/private/tmp"), try dialog("edit-outside")))
  }

  /// A path wider than the pane wraps onto a second row.
  @Test func aWrappedPathShowsItsCard() {
    let dialog = [
      "────────────", " Edit file", " sub/a-long-folder-na", " me/notes.txt", "╌╌╌╌╌╌╌╌╌╌╌╌", " 1  alpha", " 2 -beta",
      " 2 +BETA",
      "╌╌╌╌╌╌╌╌╌╌╌╌", " Do you want to make this edit to notes.txt?", " ❯ 1. Yes", "   3. No", " Esc to cancel",
    ]
    #expect(ClaudeScreen.shows(editCard("\(capturedCwd)/sub/a-long-folder-name/notes.txt"), dialog))
    #expect(!ClaudeScreen.shows(editCard("\(capturedCwd)/sub/a-long-folder-na/notes.txt"), dialog))
  }

  /// Claude Code shows a file outside the cwd as a path that climbs out of it.
  @Test func anEditOutsideTheCwdShowsItsCard() throws {
    let outside = "/Users/someone/sbcap173.txt"
    #expect(ClaudeScreen.shows(editCard(outside, old: "TWO", new: "2"), try dialog("edit-outside")))
    #expect(
      !ClaudeScreen.shows(
        editCard(outside, old: "TWO", new: "2", cwd: "/private/tmp/sbt.Cap173/work/sub"),
        try dialog("edit-outside")))
    #expect(
      !ClaudeScreen.shows(editCard("/Users/other/sbcap173.txt", old: "TWO", new: "2"), try dialog("edit-outside")))
  }

  @Test(arguments: ["Beta", "BETAX", "BET"])
  func anotherEditOfTheSameFileIsNotShown(_ new: String) throws {
    #expect(!ClaudeScreen.shows(editCard(new: new), try dialog("edit-open")))
  }

  @Test func theReversedEditIsNotShown() throws {
    #expect(!ClaudeScreen.shows(editCard(old: "BETA", new: "beta"), try dialog("edit-open")))
  }

  /// Each string is on the dialog's screen, but not as the change.
  @Test(arguments: [("alpha", "ALPHA"), ("gamma", "GAMMA"), ("gamma", "BETA"), ("alpha", "BETA")])
  func anEditWhoseOldStringIsOnlyInTheContextIsNotShown(_ old: String, _ new: String) throws {
    #expect(!ClaudeScreen.shows(editCard(old: old, new: new), try dialog("edit-open")))
  }

  /// notes.txt holds beta, beta, and gamma, and the second beta becomes BETA.
  @Test func anEditOfALaterOccurrenceShowsItsCard() throws {
    #expect(ClaudeScreen.shows(editCard(), try redrawnDialog("edit-open", " 1  alpha", [" 1  beta"])))
  }

  /// The capture ends a blank line's row at its line number.
  @Test(arguments: [" 1  alpha", " 3  gamma"])
  func aBlankFileLineShowsTheCard(_ line: String) throws {
    let blank = String(line.prefix(2))
    #expect(ClaudeScreen.shows(editCard(), try redrawnDialog("edit-open", line, [blank])))
  }

  @Test(arguments: [60, 74, 76])
  func aWrappedRowMustHoldTheWholeNewString(_ words: Int) throws {
    #expect(!ClaudeScreen.shows(multiEditCard(words: words), try dialog("edit-multi")))
  }

  /// notes.txt holds beta, alpha, and beta, and both betas become BETA.
  func replaceAllDialog() throws -> [String] {
    try redrawnDialog(
      "edit-open",
      [
        (" 1  alpha", [" 1 -beta", " 1 +BETA", " 2  alpha"]), (" 2 -beta", [" 3 -beta"]), (" 2 +BETA", [" 3 +BETA"]),
        (" 3  gamma", []),
      ])
  }

  @Test func aReplaceAllEditShowsItsCard() throws {
    #expect(ClaudeScreen.shows(editCard(replaceAll: true), try replaceAllDialog()))
  }

  @Test(arguments: [nil, false] as [Bool?])
  func anEditOfOneOccurrenceIsNotShownByAReplaceAllDialog(_ replaceAll: Bool?) throws {
    #expect(!ClaudeScreen.shows(editCard(replaceAll: replaceAll), try replaceAllDialog()))
  }

  @Test func aReplaceAllEditThatChangesMoreThanTheDialogShowsIsNotShown() throws {
    #expect(!ClaudeScreen.shows(editCard(old: "a", new: "A", replaceAll: true), try dialog("edit-open")))
  }

  @Test(arguments: ["one\ntwo\nthree", "one", "two\none"])
  func aWriteOfOtherContentIsNotShown(_ content: String) throws {
    #expect(!ClaudeScreen.shows(writeCard("\(capturedCwd)/sub/new.txt", content), try dialog("write-open")))
  }

  /// The question line names only new.txt, and the path line names sub/new.txt.
  @Test(arguments: ["\(capturedCwd)/new.txt", "\(capturedCwd)/sub/other.txt", "/tmp/sub/new.txt"])
  func aWriteOfAnotherFileIsNotShown(_ path: String) throws {
    #expect(!ClaudeScreen.shows(writeCard(path, "one\ntwo"), try dialog("write-open")))
  }

  @Test(arguments: ["alpha\nbeta\ngamma", "alpha\nBETA\ngamma", "alpha\nBETA\ngamma\ndelta\nepsilon"])
  func anOverwriteWithOtherContentIsNotShown(_ content: String) throws {
    #expect(!ClaudeScreen.shows(writeCard(capturedNotes, content), try dialog("write-overwrite")))
  }

  /// The dialog's title and path scrolled off the screen.
  @Test(arguments: [1, 38])
  func aDialogTallerThanThePaneIsNotShown(_ first: Int) throws {
    #expect(!ClaudeScreen.shows(longWriteCard(from: first), try dialog("write-long")))
  }

  @Test func aReadWithoutACwdOfAnAbsolutePathIsShown() throws {
    #expect(ClaudeScreen.shows(readCard(cwd: nil), try dialog("read-open")))
  }

  @Test(arguments: ["/etc/hosts.bak", "/etc/host", "/etc", "hosts"])
  func aReadOfAnotherFileIsNotShown(_ path: String) throws {
    #expect(!ClaudeScreen.shows(readCard(path), try dialog("read-open")))
  }

  @Test func aReadDialogThatNamesASecondFileIsNotShown() throws {
    let lines = try redrawnDialog("read-open", " Read(/etc/hosts)", [" Read(/etc/hosts)", " Read(/etc/passwd)"])
    #expect(!ClaudeScreen.shows(readCard(), lines))
  }

  @Test(arguments: [["offset": 10], ["limit": 5], ["offset": 1, "limit": 5]] as [[String: JSON]])
  func aReadOfPartOfAFileIsNotShown(_ part: [String: JSON]) throws {
    #expect(!ClaudeScreen.shows(readCard("/etc/hosts", part), try dialog("read-open")))
  }

  /// Each card's content would match the dialog's rows, so only the title
  /// tells the tools apart. A Bash card's command equals the words between
  /// the dashed rules.
  @Test(arguments: [
    (writeCard(capturedNotes, "alpha\nBETA\ngamma"), "edit-open"),
    (editCard(old: "beta\ngamma", new: "BETA\ngamma\ndelta"), "write-overwrite"),
    (readCard(capturedNotes), "edit-open"), (editCard(), "perm-open"), (createCard(), "perm-open"),
    (readCard(), "perm-open"), (bashCard("1 alpha 2 -beta 2 +BETA 3 gamma"), "edit-open"),
    (bashCard("1 one 2 two"), "write-open"), (bashCard("Read(/etc/hosts)"), "read-open"),
  ])
  func aCardIsNotShownByAnotherToolsDialog(_ card: Card, _ fixture: String) throws {
    #expect(!ClaudeScreen.shows(card, try dialog(fixture)))
  }

  @Test(arguments: [
    (bashCard("1 alpha 2 -beta 2 +BETA 3 gamma"), "edit-open"), (bashCard("1 one 2 two"), "write-open"),
    (bashCard("Read(/etc/hosts)"), "read-open"),
  ])
  func aBashCardMayNotShowAFileDialog(_ card: Card, _ fixture: String) throws {
    #expect(!ClaudeScreen.mayShow(card, try dialog(fixture)))
  }

  @Test func aFileCardIsNotShownByAQuestionDialog() throws {
    #expect(!ClaudeScreen.shows(editCard(), try dialog("q-open")))
  }

  /// Rows that hold the captured content once white space is removed, but
  /// don't fit the gutter shape.
  static let misdrawnRows: [(String, String, [String], Card)] = [
    ("edit-open", " 2 +BETA", [" 2 +BE", "TA"], editCard()), ("edit-open", " 3  gamma", ["gamma"], editCard()),
    ("edit-open", " 3  gamma", [" 3 gamma"], editCard()), ("write-open", "  2 two", ["two"], createCard()),
    ("write-overwrite", "  4 +delta", ["delta"], overwriteCard()),
  ]

  @Test(arguments: misdrawnRows)
  func aRowOutsideTheGutterShapeIsNotShown(_ fixture: String, _ line: String, _ rows: [String], _ card: Card) throws {
    #expect(!ClaudeScreen.shows(card, try redrawnDialog(fixture, line, rows)))
  }

  /// The redraw keeps the rows, so the screen still shows the card.
  @Test(arguments: [
    ("edit-open", " 3  gamma", editCard()), ("write-open", "  2 two", createCard()),
    ("write-overwrite", "  4 +delta", overwriteCard()),
  ])
  func aRedrawThatKeepsTheRowShowsTheCard(_ fixture: String, _ line: String, _ card: Card) throws {
    #expect(ClaudeScreen.shows(card, try redrawnDialog(fixture, line, [line])))
  }

  static let parityCards: [Card] = [
    editCard(), editCard(replaceAll: true), editCard(new: "Beta"), editCard(old: "gamma", new: "BETA"),
    editCard(cwd: nil), multiEditCard(), multiEditCard(words: 60), createCard(), writeCard(capturedNotes, "one\ntwo"),
    overwriteCard(), longWriteCard(), readCard(), readCard(cwd: nil), readCard("/etc/hosts.bak"),
  ]

  @Test(
    arguments: try parityCards + [writeRestartCard()],
    [
      "edit-open", "edit-down", "edit-multi", "write-open", "write-overwrite", "write-long", "read-open", "perm-open",
      "write-restart", "write-restart-tall", "write-restart-cut-path", "write-restart-narrow",
    ])
  func aFileCardMayShowExactlyTheDialogsThatShowIt(_ card: Card, _ fixture: String) throws {
    let lines = try dialog(fixture)
    #expect(ClaudeScreen.mayShow(card, lines) == ClaudeScreen.shows(card, lines))
  }

  @Test(arguments: misdrawnRows)
  func aFileCardMayNotShowARowOutsideTheGutterShape(
    _ fixture: String, _ line: String, _ rows: [String], _ card: Card
  ) throws {
    #expect(!ClaudeScreen.mayShow(card, try redrawnDialog(fixture, line, rows)))
  }
}

@Suite struct FileCardMarks {
  @Test(arguments: [
    tool("Edit", ["file_path": "/tmp/a", "old_string": "a", "new_string": "b"]),
    tool("Edit", ["file_path": "/tmp/a", "old_string": "a", "new_string": "b", "replace_all": true]),
    tool("Write", ["file_path": "/tmp/a", "content": "a"]), tool("Read", ["file_path": "/etc/hosts"]),
  ])
  func aFileToolCardIsFindable(_ request: [String: JSON]) {
    #expect(facts(promptTurn(touchCall, request)).cards[0].findable)
  }

  @Test(arguments: [
    tool("Edit", ["old_string": "a", "new_string": "b"]), tool("Edit", ["file_path": "/tmp/a", "new_string": "b"]),
    tool("Edit", ["file_path": "/tmp/a", "old_string": "a", "new_string": 1]),
    tool("Write", ["file_path": "/tmp/a"]), tool("Write", ["content": "a"]), tool("Read", [:]),
    tool("Read", ["file_path": "/etc/hosts", "offset": 10]), tool("Read", ["file_path": "/etc/hosts", "limit": 5]),
  ])
  func aFileToolCardWithoutWhatTheMatchNeedsIsNotFindable(_ request: [String: JSON]) {
    #expect(!facts(promptTurn(touchCall, request)).cards[0].findable)
  }

  @Test(arguments: [("beta", "beta "), ("a b", "a  b"), ("x", "x"), ("a\nb", "a b"), ("a\tb", "ab")])
  func anEditWhoseStringsDifferOnlyInWhiteSpaceIsNotFindable(_ old: String, _ new: String) {
    #expect(!editCard(old: old, new: new).findable)
  }
}

/// The folder that the trust dialog in trust-open.txt names. Claude Code
/// 2.1.322 drew it for a chat folder, and the fixture writes the user's home
/// as /Users/me.
let capturedTrustFolder = "/Users/me/.sb/chats/g4rvrf"

/// The path line of the captured trust dialog, as `redrawnDialog` names it.
let capturedTrustLine = " \(capturedTrustFolder)"

@Suite struct ClaudeScreenTrust {
  @Test func findsTheTrustDialogAndItsFolder() throws {
    #expect(ClaudeScreen.trustFolder(try dialog("trust-open")) == capturedTrustFolder)
  }

  /// The login shell's lines above the dialog are not conversation lines, so
  /// the dialog starts at its own rule.
  @Test func theTrustDialogStartsAtItsRuleBelowTheShellsLines() throws {
    let lines = try dialog("trust-open")

    #expect(lines.first.map(ClaudeScreen.isRule) == true)
    #expect(lines.dropFirst().first == " Accessing workspace:")
    #expect(!lines.contains { $0.contains("Mencken") || $0.contains("(oo)") })
  }

  /// Claude Code breaks a path that is wider than the pane in the middle of a word.
  @Test(arguments: [
    [" /Users/me/.sb/cha", " ts/g4rvrf"], [" /Users/me/.sb/chats/g4rvrf"], [" /Users/me/", " .sb/chats/", " g4rvrf"],
    [" /Users/me/.sb/chats/g4rvr", "f"],
  ])
  func readsAWrappedFolder(_ rows: [String]) throws {
    let lines = try redrawnDialog("trust-open", capturedTrustLine, rows)

    #expect(ClaudeScreen.trustFolder(lines) == capturedTrustFolder)
  }

  @Test func findsNoDialogOnADeadPane() throws {
    #expect(ClaudeScreen.dialog(try screenFixture("trust-dead")) == nil)
  }

  @Test(arguments: ["perm-open", "perm-down", "q-open", "edit-open", "write-open", "read-open"])
  func aPermissionDialogIsNoTrustDialog(_ fixture: String) throws {
    #expect(ClaudeScreen.trustFolder(try dialog(fixture)) == nil)
  }

  @Test(arguments: ["trust-dead", "prompt-empty", "prompt-typed", "perm-after-yes"])
  func aScreenWithoutADialogHasNoTrustFolder(_ fixture: String) throws {
    #expect(ClaudeScreen.dialog(try screenFixture(fixture)).flatMap(ClaudeScreen.trustFolder) == nil)
  }

  /// The title must be the line right below the dialog's top rule.
  @Test(arguments: [
    [" Bash command", " Accessing workspace:"], ["", " Accessing workspace:"], [" ❯ 1. Yes", " Accessing workspace:"],
  ])
  func aTitleThatIsNotRightBelowTheRuleIsNoTrustDialog(_ rows: [String]) throws {
    let lines = try redrawnDialog("trust-open", " Accessing workspace:", rows)

    #expect(ClaudeScreen.trustFolder(lines) == nil)
  }

  @Test(arguments: [
    " Accessing workspace", " Accessing workspaces:", " Accessing workspace: now", " Accessing:",
    " accessing workspace:",
  ])
  func anotherTitleIsNoTrustDialog(_ title: String) throws {
    let lines = try redrawnDialog("trust-open", " Accessing workspace:", [title])

    #expect(ClaudeScreen.trustFolder(lines) == nil)
  }

  /// A dialog whose line below the title is not a path names no folder,
  /// because the next paragraph's prose would read as one.
  @Test(arguments: [[""], [" Review this folder"], [" ~/dev/repo"], [" dev/repo"]])
  func aTrustDialogWithoutAFolderLineNamesNoFolder(_ rows: [String]) throws {
    let lines = try redrawnDialog("trust-open", capturedTrustLine, rows)

    #expect(ClaudeScreen.trustFolder(lines) == nil)
  }

  @Test func highlightsNoExitFirst() throws {
    let item = try #require(ClaudeScreen.highlighted(try dialog("trust-open")))

    #expect(item == "No, exit")
    #expect(ClaudeScreen.isTrustNo(item))
    #expect(!ClaudeScreen.isTrustYes(item))
  }

  /// The highlight on Yes, as Down draws it, built from the capture so that
  /// nobody presses keys in a live session.
  @Test func aHighlightMovedToYesIsTrustYes() throws {
    let lines = try redrawnDialog(
      "trust-open",
      [(" ❯ No, exit", ["   No, exit"]), ("   Yes, I trust this folder", [" ❯ Yes, I trust this folder"])])
    let item = try #require(ClaudeScreen.highlighted(lines))

    #expect(item == "Yes, I trust this folder")
    #expect(ClaudeScreen.isTrustYes(item))
    #expect(ClaudeScreen.trustFolder(lines) == capturedTrustFolder)
  }

  @Test func showsATrustCardForItsFolder() throws {
    let lines = try dialog("trust-open")

    #expect(ClaudeScreen.shows(trustCard(capturedTrustFolder), lines))
    #expect(ClaudeScreen.mayShow(trustCard(capturedTrustFolder), lines))
  }

  @Test func showsATrustCardForItsWrappedFolder() throws {
    let lines = try redrawnDialog("trust-open", capturedTrustLine, [" /Users/me/.sb/cha", "ts/g4rvrf"])

    #expect(ClaudeScreen.shows(trustCard(capturedTrustFolder), lines))
  }

  @Test(arguments: [
    "/Users/me/.sb/chats/other", "/Users/me/.sb/chats/g4rv", "/Users/me/.sb/chats/g4rvrf/",
    "/Users/me/.sb/chats/g4rvrf/sub", "/Users/me/.sb/chats", "/private/Users/me/.sb/chats/g4rvrf", "",
  ])
  func showsATrustCardOnlyForItsFolder(_ folder: String) throws {
    let lines = try dialog("trust-open")

    #expect(!ClaudeScreen.shows(trustCard(folder), lines))
    #expect(!ClaudeScreen.mayShow(trustCard(folder), lines))
  }

  @Test(arguments: ["perm-open", "q-open", "edit-open"])
  func anotherDialogShowsNoTrustCard(_ fixture: String) throws {
    let lines = try dialog(fixture)

    #expect(!ClaudeScreen.shows(trustCard(capturedTrustFolder), lines))
    #expect(!ClaudeScreen.mayShow(trustCard(capturedTrustFolder), lines))
  }

  /// A dialog that names another folder, as when the screen changed after
  /// the card opened, never takes the card's answer.
  @Test func anotherFoldersTrustDialogShowsNoTrustCard() throws {
    let lines = try redrawnDialog("trust-open", capturedTrustLine, [" /Users/me/dev/other"])

    #expect(!ClaudeScreen.shows(trustCard(capturedTrustFolder), lines))
  }

  /// Keys for a permission card must never land on the trust dialog.
  @Test func theTrustDialogShowsNoPermissionOrQuestionCard() throws {
    let lines = try dialog("trust-open")

    #expect(!ClaudeScreen.shows(bashCard(capturedCommand), lines))
    #expect(!ClaudeScreen.shows(fruitCard(), lines))
  }

  @Test(arguments: [
    ("Yes, I trust this folder", true, false), ("2. Yes, I trust this folder", true, false),
    ("No, exit", false, true), ("1. No, exit", false, true), ("Yes", false, false), ("1. Yes", false, false),
    ("Yes, I trust this folder and its parents", false, false), ("Yes, I trust this", false, false),
    ("No", false, false), ("2. No", false, false), ("No, exit now", false, false), ("No, exit.", false, false),
    ("❯ Yes, I trust this folder", false, false),
  ])
  func isTrustYesAndIsTrustNo(_ item: String, _ yes: Bool, _ no: Bool) {
    #expect(ClaudeScreen.isTrustYes(item) == yes)
    #expect(ClaudeScreen.isTrustNo(item) == no)
  }

  /// A permission card's typed Yes must not pick the trust dialog's Yes.
  @Test func theTrustDialogsYesIsNotAPermissionsYes() {
    #expect(!ClaudeScreen.isYes("Yes, I trust this folder"))
  }
}
