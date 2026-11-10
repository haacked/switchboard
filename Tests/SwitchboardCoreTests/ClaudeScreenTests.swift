import Foundation
import Testing

@testable import SwitchboardCore

/// A screen that `TerminalHost.screen` captured from Claude Code 2.1.317.
func screenFixture(_ name: String) throws -> String {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/screens")
  return try String(contentsOf: dir.appendingPathComponent("\(name).txt"), encoding: .utf8)
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
    "write-long", "read-open",
  ])
  func anOpenDialogEndsAtItsFooter(_ fixture: String) throws {
    #expect(try dialog(fixture).last?.contains("Esc to cancel") == true)
  }

  @Test(arguments: ["perm-after-yes", "perm-after-esc", "q-after-esc", "edit-after-esc"])
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

  @Test func anotherCardsDialogIsAMiss() throws {
    var watch = DialogWatch()
    let card = bashCard(capturedCommand)
    let screens = [try shown(), try otherCommandsScreen(), try otherCommandsScreen()]
    #expect(results(&watch, [card], screens) == [[], [], [card.id]])
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

  @Test func anotherEditsDialogIsAMiss() throws {
    var watch = DialogWatch()
    let card = editCard()
    let screens = try ["edit-open", "edit-multi", "edit-multi"].map(screenFixture)
    #expect(results(&watch, [card], screens) == [[], [], [card.id]])
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

  @Test func aClosedHooksEditDialogWhoseTopScrolledOffHasLeft() throws {
    var watch = DialogWatch()
    var card = editCard()
    card.hookClosed = true
    let screens = [try screenFixture("edit-open"), try editWithItsTopScrolledOff(), try editWithItsTopScrolledOff()]
    #expect(results(&watch, [card], screens) == [[], [], [card.id]])
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
        editCard(outside, old: "TWO", new: "2", cwd: "/private/tmp/sbt.Cap173"), try dialog("edit-outside")))
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
    arguments: parityCards,
    ["edit-open", "edit-down", "edit-multi", "write-open", "write-overwrite", "write-long", "read-open", "perm-open"])
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
