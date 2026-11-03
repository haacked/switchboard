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

@Suite struct ClaudeScreenDialog {
  @Test(arguments: ["perm-open", "perm-down", "q-open"])
  func anOpenDialogEndsAtItsFooter(_ fixture: String) throws {
    #expect(try dialog(fixture).last?.contains("Esc to cancel") == true)
  }

  @Test(arguments: ["perm-after-yes", "perm-after-esc", "q-after-esc"])
  func aScreenWithThePromptBoxShowsNoDialog(_ fixture: String) throws {
    #expect(ClaudeScreen.dialog(try screenFixture(fixture)) == nil)
  }

  @Test func aPermissionDialogHoldsItsCommandAndNotTheConversation() throws {
    let lines = try dialog("perm-open")
    #expect(lines.contains(" Bash command"))
    #expect(lines.contains(" \(capturedCommand)"))
    #expect(!lines.contains { $0.contains("⎿") || $0.contains("Run exactly this command") })
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
  @Test(arguments: [("perm-open", "1. Yes"), ("perm-down", "2. No"), ("q-open", "1. apple")])
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
    tool("Write", ["file_path": "/tmp/a", "content": "a"]), tool("mcp__github__create_issue", ["title": "a"]),
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

  @Test func aDeferredCardIsNeverReported() throws {
    var watch = DialogWatch()
    var card = fruitCard()
    card.deferred = true
    let screens = [try screenFixture("q-open"), try screenFixture("q-after-esc"), try screenFixture("q-after-esc")]
    #expect(results(&watch, [card], screens) == [[], [], []])
  }
}
