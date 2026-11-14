import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func command(_ name: String, _ source: SlashCommand.Source = .listing) -> SlashCommand {
  SlashCommand(name: name, description: nil, source: source)
}

/// Rows in the order `rank` gives for an empty query, as the panel shows them after `/`.
private let probeRows = ["probe-cmd-plain", "probe-cmd-user-only", "probe-default", "probe-user-only"].map {
  command($0)
}

// MARK: - Query

@MainActor
@Suite struct SlashCompletionQueryTests {
  @Test(arguments: [("/", ""), ("/co", "co"), ("/anthropic-skills:pdf", "anthropic-skills:pdf")])
  func textThatStartsWithASlashAndHoldsNoWhitespaceIsAQuery(_ text: String, _ query: String) {
    #expect(SlashCompletion.query(text) == query)
  }

  /// Decision 9: a leading space, a second word, a new line, or a slash after index 0 is not a query.
  @Test(arguments: ["", "co", "/co x", " /co", "/co\n", "/co\t", "/\n", "a/co", "/co ", "\n/co"])
  func textThatIsNotACommandNameGivesNoQuery(_ text: String) {
    #expect(SlashCompletion.query(text) == nil)
  }

  /// The trailing space that accept adds closes the list.
  @Test(arguments: ["clear", "anthropic-skills:pdf"])
  func acceptedTextIsNotAQuery(_ name: String) {
    #expect(SlashCompletion.query(SlashCompletion.accepted(name)) == nil)
  }
}

// MARK: - Rows

@MainActor
@Suite struct SlashCompletionRowsTests {
  static let commands = [
    command("commit"), command("anthropic-skills:computer-use"), command("decode"), command("code-review"),
    command("clear", .builtIn), command("go"),
  ]

  @Test func anEmptyQueryListsEveryRowByName() {
    let rows = SlashCompletion.rows(commands: Self.commands, query: "")

    #expect(rows.map(\.name) == Self.commands.map(\.name).sorted())
  }

  @Test func rowsAreRankedAsCoreRanksThem() {
    let rows = SlashCompletion.rows(commands: Self.commands, query: "co")

    #expect(rows == SlashCommands.rank(Self.commands, query: "co"))
    #expect(rows.map(\.name) == ["code-review", "commit", "anthropic-skills:computer-use", "decode"])
  }

  @Test func aQueryThatMatchesNothingGivesNoRows() {
    #expect(SlashCompletion.rows(commands: Self.commands, query: "zzz").isEmpty)
  }
}

// MARK: - Accept

@MainActor
@Suite struct SlashCompletionAcceptTests {
  @Test func acceptGivesTheNameAfterASlashAndATrailingSpace() {
    #expect(SlashCompletion.accepted("probe-default") == "/probe-default ")
  }

  @Test func acceptKeepsAColonInTheName() {
    #expect(SlashCompletion.accepted("anthropic-skills:pdf") == "/anthropic-skills:pdf ")
  }
}

// MARK: - Highlight

@MainActor
@Suite struct SlashCompletionHighlightTests {
  @Test func aNewCompletionHighlightsTheFirstRow() {
    let completion = SlashCompletion()

    #expect(completion.highlight(in: probeRows) == "probe-cmd-plain")
  }

  @Test func noRowsGiveNoHighlight() {
    let completion = SlashCompletion()

    #expect(completion.highlight(in: []) == nil)
  }

  /// The first row shows as highlighted before any arrow, so one Down must reach the second row.
  @Test func oneDownFromANewCompletionHighlightsTheSecondRow() {
    let completion = SlashCompletion()

    completion.move(1, in: probeRows)

    #expect(completion.highlight(in: probeRows) == "probe-cmd-user-only")
  }

  @Test func upFromTheFirstRowStaysOnIt() {
    let completion = SlashCompletion()

    completion.move(-1, in: probeRows)

    #expect(completion.highlight(in: probeRows) == "probe-cmd-plain")
  }

  @Test func downFromTheLastRowStaysOnIt() {
    let completion = SlashCompletion()
    for _ in 0..<probeRows.count + 2 { completion.move(1, in: probeRows) }

    #expect(completion.highlight(in: probeRows) == "probe-user-only")
  }

  @Test func upAfterDownReturnsToTheRowBefore() {
    let completion = SlashCompletion()
    completion.move(1, in: probeRows)
    completion.move(1, in: probeRows)

    completion.move(-1, in: probeRows)

    #expect(completion.highlight(in: probeRows) == "probe-cmd-user-only")
  }

  @Test func aChangedTextReturnsTheHighlightToTheFirstRow() {
    let completion = SlashCompletion()
    completion.move(1, in: probeRows)
    completion.move(1, in: probeRows)

    completion.reset()

    #expect(completion.highlight(in: probeRows) == "probe-cmd-plain")
  }

  /// A refreshed answer from sbd can drop the highlighted row.
  @Test func aHighlightThatLeftTheRowsFallsBackToTheFirstRow() {
    let completion = SlashCompletion()
    completion.move(1, in: probeRows)
    let fewer = [command("probe-cmd-plain"), command("probe-default")]

    #expect(completion.highlight(in: fewer) == "probe-cmd-plain")
  }

  /// A refreshed answer that still holds the highlighted row keeps it.
  @Test func aHighlightThatStaysInTheRowsIsKept() {
    let completion = SlashCompletion()
    completion.move(1, in: probeRows)
    let more = [command("aaa")] + probeRows

    #expect(completion.highlight(in: more) == "probe-cmd-user-only")
  }
}

// MARK: - Open and dismissal

@MainActor
@Suite struct SlashCompletionOpenTests {
  @Test func aQueryWithRowsInAFocusedFieldIsOpen() {
    let completion = SlashCompletion()

    #expect(completion.isOpen(text: "/probe", rows: probeRows, focused: true, composing: false))
  }

  // Decision 9 has four conditions. Each test below breaks one of them.

  @Test func aFieldWithoutFocusIsClosed() {
    let completion = SlashCompletion()

    #expect(!completion.isOpen(text: "/probe", rows: probeRows, focused: false, composing: false))
  }

  @Test func aComposingInputMethodClosesIt() {
    let completion = SlashCompletion()

    #expect(!completion.isOpen(text: "/probe", rows: probeRows, focused: true, composing: true))
  }

  @Test func noRowsCloseIt() {
    let completion = SlashCompletion()

    #expect(!completion.isOpen(text: "/zzz", rows: [], focused: true, composing: false))
  }

  @Test(arguments: ["", "probe", " /probe", "/probe x", "/probe\n", "/probe "])
  func textThatIsNotAQueryClosesIt(_ text: String) {
    let completion = SlashCompletion()

    #expect(!completion.isOpen(text: text, rows: probeRows, focused: true, composing: false))
  }

  @Test func escapeClosesItForTheSameText() {
    let completion = SlashCompletion()

    completion.dismiss(at: "/co")

    #expect(!completion.isOpen(text: "/co", rows: probeRows, focused: true, composing: false))
  }

  @Test func aChangedTextOpensItAgainAfterEscape() {
    let completion = SlashCompletion()
    completion.dismiss(at: "/co")

    completion.reset()

    #expect(completion.isOpen(text: "/con", rows: probeRows, focused: true, composing: false))
  }

  /// Typing a letter and deleting it changes the text twice. Remembering the dismissed text alone would keep the
  /// list closed.
  @Test func textThatReturnsToTheDismissedTextOpensIt() {
    let completion = SlashCompletion()
    completion.dismiss(at: "/co")
    completion.reset()

    completion.reset()

    #expect(completion.isOpen(text: "/co", rows: probeRows, focused: true, composing: false))
  }
}

// MARK: - Keys

/// The keys the list takes while it is open.
private let listKeys: [KeyEquivalent] = [.upArrow, .downArrow, .tab, .return, .escape]
/// Keys the list never takes.
private let otherKeys: [KeyEquivalent] = [.leftArrow, .rightArrow, .space, .delete, KeyEquivalent("a")]
private let allKeys = listKeys + otherKeys
/// Every combination of Command, Option, Control, and Shift that has at least one of them.
private let anyOfTheFour = ReturnKeyTests.allModifiers.filter { !$0.isEmpty }
/// Flags that macOS or SwiftUI set without the user holding a modifier. SwiftUI adds the numeric pad flag to arrow
/// keys. SwiftUI deprecates its function flag for apps, so the tests leave it out.
private let passiveFlags: [EventModifiers] = [[], .capsLock, .numericPad, [.capsLock, .numericPad]]

@MainActor
@Suite struct SlashCompletionKeyTests {
  static func action(
    _ key: KeyEquivalent, _ modifiers: EventModifiers = [], composing: Bool = false, open: Bool = true,
    text: String = "/c", highlighted: String = "clear"
  ) -> SlashCompletion.Action? {
    SlashCompletion.action(
      key: key, modifiers: modifiers, composing: composing, open: open, text: text, highlighted: highlighted)
  }

  @Test func downMovesTheHighlightDown() {
    #expect(Self.action(.downArrow) == .move(1))
  }

  @Test func upMovesTheHighlightUp() {
    #expect(Self.action(.upArrow) == .move(-1))
  }

  @Test func tabAccepts() {
    #expect(Self.action(.tab) == .accept)
  }

  /// Tab adds the trailing space even when the text already names the row.
  @Test func tabAcceptsWhenTheTextEqualsTheHighlightedRow() {
    #expect(Self.action(.tab, text: "/clear") == .accept)
  }

  @Test func returnAcceptsAPartialName() {
    #expect(Self.action(.return, text: "/cle") == .accept)
  }

  /// `/clear` then Return sends at once.
  @Test func returnSendsWhenTheTextEqualsTheHighlightedRow() {
    #expect(Self.action(.return, text: "/clear") == .send)
  }

  /// Only the highlighted row counts. A text that names another row still accepts the highlighted one.
  @Test func returnAcceptsWhenTheTextNamesARowThatIsNotHighlighted() {
    #expect(Self.action(.return, text: "/clear", highlighted: "clear-all") == .accept)
  }

  @Test func escapeCloses() {
    #expect(Self.action(.escape) == .close)
  }

  @Test(
    arguments: [
      (KeyEquivalent.downArrow, SlashCompletion.Action.move(1)), (.upArrow, .move(-1)), (.tab, .accept),
      (.return, .accept), (.escape, .close),
    ], passiveFlags)
  func flagsOtherThanTheFourChangeNothing(
    _ mapping: (KeyEquivalent, SlashCompletion.Action), _ modifiers: EventModifiers
  ) {
    #expect(Self.action(mapping.0, modifiers) == mapping.1)
  }

  /// Shift+Return inserts a line, Command+Return reaches the Send button, Shift+Tab moves focus back, and
  /// Shift+arrows select text. Each keeps today's behavior while the list is open.
  @Test(arguments: listKeys, anyOfTheFour)
  func aListKeyWithCommandOptionControlOrShiftIsLeftToTheField(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    #expect(Self.action(key, modifiers) == nil)
  }

  /// The input method commits its marked text on Return and cancels it on Esc.
  @Test(arguments: allKeys, ReturnKeyTests.allModifiers)
  func everyKeyWhileComposingIsLeftToTheField(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    #expect(Self.action(key, modifiers, composing: true) == nil)
  }

  @Test(arguments: otherKeys, passiveFlags)
  func aKeyThatTypesOrMovesTheCursorIsLeftToTheField(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    #expect(Self.action(key, modifiers) == nil)
  }

  /// A closed or dismissed list gives today's behavior for every key, so `action` must leave every key alone.
  @Test(arguments: allKeys, ReturnKeyTests.allModifiers)
  func everyKeyWhileClosedIsLeftToTheField(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    for composing in [false, true] {
      for text in ["", "/c", "/clear", "hello"] {
        #expect(Self.action(key, modifiers, composing: composing, open: false, text: text) == nil)
      }
    }
  }
}

// MARK: - Held keys

/// A held key sends a down press and then repeats. A row is accepted only on the down press.
@MainActor
@Suite struct SlashCompletionHeldKeyTests {
  static func press(
    _ completion: SlashCompletion, _ key: KeyEquivalent, _ modifiers: EventModifiers = [], isRepeat: Bool,
    open: Bool, text: String, highlighted: String? = "probe-default"
  ) -> SlashCompletion.Action? {
    completion.press(
      key, modifiers: modifiers, isRepeat: isRepeat, composing: false, open: open, text: text,
      highlighted: highlighted)
  }

  /// After the accept the text is `/probe-default ` and the list is closed, so a repeat would otherwise send or
  /// move focus.
  @Test(arguments: [KeyEquivalent.return, .tab])
  func aRepeatAfterTheDownPressAcceptedDoesNothing(_ key: KeyEquivalent) {
    let completion = SlashCompletion()

    #expect(Self.press(completion, key, isRepeat: false, open: true, text: "/probe-d") == .accept)
    for _ in 0..<3 {
      #expect(Self.press(completion, key, isRepeat: true, open: false, text: "/probe-default ") == .discard)
    }
  }

  /// A held Return with the list closed sends on every repeat, as it does without the list.
  @Test(arguments: ["", "hello", "/probe-default "])
  func aReturnRepeatWithTheListClosedFromTheStartIsLeftToTheField(_ text: String) {
    let completion = SlashCompletion()

    #expect(Self.press(completion, .return, isRepeat: false, open: false, text: text) == nil)
    #expect(Self.press(completion, .return, isRepeat: true, open: false, text: text) == nil)
  }

  @Test func aTabRepeatWithTheListClosedFromTheStartIsLeftToTheField() {
    let completion = SlashCompletion()

    #expect(Self.press(completion, .tab, isRepeat: true, open: false, text: "/probe-default ") == nil)
  }

  /// The accept changes the text, and the field calls `reset` before the key's first repeat.
  @Test func aResetAfterTheAcceptStillDiscardsTheRepeat() {
    let completion = SlashCompletion()
    _ = Self.press(completion, .tab, isRepeat: false, open: true, text: "/probe-d")

    completion.reset()

    #expect(Self.press(completion, .tab, isRepeat: true, open: false, text: "/probe-default ") == .discard)
  }

  /// A second press after the accept is a new press, so Return sends and Tab moves focus.
  @Test(arguments: [KeyEquivalent.return, .tab])
  func aNewDownPressAfterTheAcceptIsLeftToTheField(_ key: KeyEquivalent) {
    let completion = SlashCompletion()
    _ = Self.press(completion, key, isRepeat: false, open: true, text: "/probe-d")

    #expect(Self.press(completion, key, isRepeat: false, open: false, text: "/probe-default ") == nil)
    #expect(Self.press(completion, key, isRepeat: true, open: false, text: "/probe-default ") == nil)
  }

  /// Shift+Return inserts a line without reaching `press`. Its repeats after Shift comes up send as they do today.
  @Test func aRepeatAfterTheTextChangedIsLeftToTheField() {
    let completion = SlashCompletion()
    _ = Self.press(completion, .return, isRepeat: false, open: true, text: "/probe-d")

    #expect(Self.press(completion, .return, isRepeat: true, open: false, text: "/probe-default \n") == nil)
  }

  @Test func anotherKeysRepeatIsNotDiscarded() {
    let completion = SlashCompletion()
    _ = Self.press(completion, .tab, isRepeat: false, open: true, text: "/probe-d")

    #expect(Self.press(completion, .return, isRepeat: true, open: false, text: "/probe-default ") == nil)
  }

  /// The list can open during a held Return that sent on its down press, when sbd's rows arrive. The repeat does not
  /// accept, and it sends as it does without the list.
  @Test(arguments: [KeyEquivalent.return, .tab])
  func aRepeatNeverAccepts(_ key: KeyEquivalent) {
    let completion = SlashCompletion()

    #expect(Self.press(completion, key, isRepeat: true, open: true, text: "/probe-d") == nil)
  }

  /// A held Return on the exact name sends, and the list closes, so the later repeats send as they do today.
  @Test func aReturnRepeatOnTheExactNameSends() {
    let completion = SlashCompletion()

    #expect(Self.press(completion, .return, isRepeat: true, open: true, text: "/probe-default") == .send)
  }

  @Test(arguments: [(KeyEquivalent.downArrow, 1), (.upArrow, -1)])
  func arrowRepeatsKeepMoving(_ key: KeyEquivalent, _ step: Int) {
    let completion = SlashCompletion()

    #expect(Self.press(completion, key, isRepeat: false, open: true, text: "/probe") == .move(step))
    #expect(Self.press(completion, key, isRepeat: true, open: true, text: "/probe") == .move(step))
  }

  @Test func aRepeatWhileComposingIsLeftToTheField() {
    let completion = SlashCompletion()
    _ = Self.press(completion, .return, isRepeat: false, open: true, text: "/probe-d")

    let action = completion.press(
      .return, modifiers: [], isRepeat: true, composing: true, open: false, text: "/probe-default ",
      highlighted: nil)

    #expect(action == nil)
  }
}

// MARK: - Placement

/// Rectangles are in AppKit screen coordinates, where y grows upward. "Under the field" means a lower y.
@MainActor
@Suite struct SlashCompletionPanelPlacementTests {
  static let screen = NSRect(x: 0, y: 40, width: 1440, height: 860)
  static let midField = NSRect(x: 300, y: 500, width: 600, height: 28)

  static func field(bottomAbove screenBottom: CGFloat) -> NSRect {
    NSRect(x: 300, y: screen.minY + screenBottom, width: 600, height: 28)
  }

  /// The distance from the field's bottom to the panel's bottom when the panel opens under the field.
  static func depthBelow(rows: Int) -> CGFloat {
    midField.minY - SlashCompletionPanel.frame(field: midField, rows: rows, screen: screen).minY
  }

  @Test func thePanelIsAsWideAsTheFieldAndLinedUpWithIt() {
    let frame = SlashCompletionPanel.frame(field: Self.midField, rows: 3, screen: Self.screen)

    #expect(frame.minX == Self.midField.minX)
    #expect(frame.width == Self.midField.width)
  }

  @Test func thePanelOpensUnderTheFieldWhenTheScreenHasRoom() {
    let frame = SlashCompletionPanel.frame(field: Self.midField, rows: 8, screen: Self.screen)

    #expect(frame.maxY <= Self.midField.minY)
    #expect(frame.minY >= Self.screen.minY)
  }

  @Test func thePanelOpensAboveTheFieldWhenTheScreenHasNoRoomBelow() {
    let field = Self.field(bottomAbove: 10)

    let frame = SlashCompletionPanel.frame(field: field, rows: 8, screen: Self.screen)

    #expect(frame.minY >= field.maxY)
    #expect(frame.maxY <= Self.screen.maxY)
  }

  @Test(arguments: [1, 4, 8])
  func thePanelOpensUnderTheFieldWhenItFitsExactly(rows: Int) {
    let field = Self.field(bottomAbove: Self.depthBelow(rows: rows))

    let frame = SlashCompletionPanel.frame(field: field, rows: rows, screen: Self.screen)

    #expect(frame.maxY <= field.minY)
  }

  @Test(arguments: [1, 4, 8])
  func thePanelOpensAboveTheFieldWhenItIsOnePointShort(rows: Int) {
    let field = Self.field(bottomAbove: Self.depthBelow(rows: rows) - 1)

    let frame = SlashCompletionPanel.frame(field: field, rows: rows, screen: Self.screen)

    #expect(frame.minY >= field.maxY)
  }

  @Test func moreRowsMakeATallerPanel() {
    let three = SlashCompletionPanel.frame(field: Self.midField, rows: 3, screen: Self.screen)
    let four = SlashCompletionPanel.frame(field: Self.midField, rows: 4, screen: Self.screen)

    #expect(three.height < four.height)
  }

  /// Rows past eight scroll inside the panel.
  @Test(arguments: [9, 20, 200])
  func thePanelStopsGrowingAtEightRows(rows: Int) {
    let eight = SlashCompletionPanel.frame(field: Self.midField, rows: 8, screen: Self.screen)
    let more = SlashCompletionPanel.frame(field: Self.midField, rows: rows, screen: Self.screen)

    #expect(more.height == eight.height)
  }
}

// MARK: - Panel lifetime

/// Risk 6: the panel keeps focus in the field and closes with the field's window.
@MainActor
@Suite struct SlashCompletionAnchorTests {
  static func anchored() -> (NSWindow, SlashCompletionAnchorView) {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 400, width: 600, height: 300), styleMask: [.titled], backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    let anchor = SlashCompletionAnchorView(frame: NSRect(x: 20, y: 20, width: 400, height: 28))
    window.contentView?.addSubview(anchor)
    anchor.list = SlashCompletionList(rows: probeRows, highlighted: "probe-default", accept: { _ in })
    return (window, anchor)
  }

  @Test func anOpenListShowsAChildPanelThatNeverBecomesKey() throws {
    let (window, anchor) = Self.anchored()

    #expect(anchor.panel.isVisible)
    #expect(anchor.panel.rows == probeRows)
    let child = try #require(window.childWindows?.first)
    #expect(!child.canBecomeKey)
    #expect(!child.canBecomeMain)
  }

  @Test func aClosedListHidesThePanel() {
    let (window, anchor) = Self.anchored()

    anchor.list = nil

    #expect(!anchor.panel.isVisible)
    #expect(window.childWindows?.isEmpty ?? true)
  }

  @Test func thePanelHidesWhileTheWindowIsNotKeyAndReturnsWhenItIs() {
    let (window, anchor) = Self.anchored()

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(!anchor.panel.isVisible)

    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    #expect(anchor.panel.isVisible)
  }

  @Test func anotherWindowResigningKeyLeavesThePanelOpen() {
    let (_, anchor) = Self.anchored()
    let (other, _) = Self.anchored()

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)

    #expect(anchor.panel.isVisible)
  }

  @Test func thePanelHidesWhenTheFieldLeavesTheWindow() {
    let (window, anchor) = Self.anchored()

    anchor.removeFromSuperview()

    #expect(!anchor.panel.isVisible)
    #expect(window.childWindows?.isEmpty ?? true)
  }

  @Test func thePanelFollowsTheFieldWhenItMoves() throws {
    let (window, anchor) = Self.anchored()
    let before = try #require(window.childWindows?.first?.frame)

    anchor.setFrameOrigin(NSPoint(x: 20, y: 120))

    #expect(window.childWindows?.first?.frame.minY == before.minY + 100)
  }
}
