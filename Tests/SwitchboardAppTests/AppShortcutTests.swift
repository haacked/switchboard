import AppKit
import SwiftUI
import Testing

@testable import SwitchboardApp

/// A key and its ⌘, ⌥, ⌃, and ⇧ bits, compared exactly. Unlike `AppShortcut.Press`, it keeps a stored "}" apart from
/// a stored "]" with ⇧, so a test that pins a stored character can see the difference.
private struct Exact: Hashable, CustomStringConvertible {
  var key: Character
  var modifiers: Int

  init(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    self.key = key.character
    self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
  }

  init(_ shortcut: KeyboardShortcut) { self.init(shortcut.key, shortcut.modifiers) }

  var withoutShift: Exact {
    var copy = self
    copy.modifiers &= ~EventModifiers.shift.rawValue
    return copy
  }

  var description: String { "\(key.unicodeScalars.map { String($0.value, radix: 16) }) \(modifiers)" }
}

private let menuKinds: Set<ShortcutKind> = [.menu, .menuAlternate]

/// The `.menu` and `.menuAlternate` entries, which a main-menu item carries.
private var menuEntries: [AppShortcut] { AppShortcut.allCases.filter { menuKinds.contains($0.kind) } }

/// The entries that a menu item or a view binds, which have a first key.
private let boundEntries = AppShortcut.allCases.filter { $0.kind != .handler }

/// The entries whose `binding` the precondition admits.
private let bindableEntries = AppShortcut.allCases.filter { $0.kind == .menu || $0.kind == .view }

private let viewEntries = AppShortcut.allCases.filter { $0.kind == .view }

private let nonMenuEntries = AppShortcut.allCases.filter { !menuKinds.contains($0.kind) }

private let labeledEntries = AppShortcut.allCases.filter { $0.label != nil }

/// The entries whose `menuTitles` name a menu item titled `title`. An exact title wins. Otherwise an entry title
/// names every item title that starts with it, after any trailing "…" is dropped, and the longest such title wins.
/// That is how "New Session in Flags…" reaches the group item and not New Session….
private func entries(forMenuTitle title: String) -> [AppShortcut] {
  let exact = AppShortcut.allCases.filter { $0.menuTitles.contains(title) }
  if !exact.isEmpty { return exact }
  let stems = AppShortcut.allCases.flatMap { entry in
    entry.menuTitles.map { (entry, $0.hasSuffix("…") ? String($0.dropLast()) : $0) }
  }
  let matching = stems.filter { title.hasPrefix($0.1) }
  guard let longest = matching.map({ $0.1.count }).max() else { return [] }
  return matching.filter { $0.1.count == longest }.map(\.0)
}

// MARK: - Pinning against the menu literals at 0db20f94

@Suite struct AppShortcutPinning {
  /// A menu item's title and the key that `App.swift` bound to it at 0db20f94.
  struct Literal: Sendable, CustomTestStringConvertible {
    var title: String
    var key: Character
    var modifiers: EventModifiers
    var testDescription: String { title }

    init(_ title: String, _ key: Character, _ modifiers: EventModifiers = .command) {
      self.title = title
      self.key = key
      self.modifiers = modifiers
    }
  }

  /// Copied from `App.swift` and `KeyboardNavigation.swift` (`NavShortcuts`) at 0db20f94, character for character.
  /// `KeyboardShortcut("n")` and `KeyEquivalent(view.shortcutKey)` default to ⌘. Next and Previous Session store
  /// "}" and "{", because a US keyboard sends ⇧⌘] as "}" with ⌘ and ⇧.
  static let literals: [Literal] = [
    Literal("New Session…", "n"),
    Literal("New Session in Group…", "n", [.command, .shift]),
    Literal("New Session in Flags…", "n", [.command, .shift]),
    Literal("New Conversation", "n", [.command, .option]),
    Literal("Import Sessions…", "i", [.command, .shift]),
    Literal("New Group", "g", [.command, .shift]),
    Literal("Show Inbox", "1"),
    Literal("Show Board", "2"),
    Literal("Show Issues", "3"),
    Literal("Show Loops", "4"),
    Literal("Filter Sessions…", "o", [.command, .shift]),
    Literal("Back", "["),
    Literal("Forward", "]"),
    Literal("Show Recent Places", "y"),
    Literal("Next Needing You", "j"),
    Literal("Next Session", "}"),
    Literal("Previous Session", "{"),
    Literal("Open Manager", "m", [.command, .shift]),
    Literal("Search Sessions…", "k"),
    Literal("Ask Switchboard…", "k", [.command, .shift]),
    Literal("Move Focus to List", "l"),
    Literal("Move Focus to Terminal", "t"),
    Literal("Message Claude", "e", [.command, .shift]),
    Literal("Stop Claude", "."),
    Literal("Resume Claude", "r", [.command, .shift]),
    Literal("Mark Done", "d", [.command, .shift]),
    Literal("Mark Not Done", "d", [.command, .shift]),
    Literal("Acknowledge", "a", [.command, .shift]),
    Literal("Undo Acknowledge", "a", [.command, .shift]),
  ]

  @Test(arguments: literals)
  func eachMenuTitleNamesExactlyOneEntry(_ literal: Literal) {
    #expect(entries(forMenuTitle: literal.title).count == 1, "\(entries(forMenuTitle: literal.title))")
  }

  /// The stored character, not the key press, so a "}" that became "]" with ⇧ fails here.
  @Test(arguments: literals)
  func menuBindingsMatchThePreRefactorLiterals(_ literal: Literal) throws {
    let entry = try #require(entries(forMenuTitle: literal.title).first)
    let binding = try #require(entry.keys.first)

    #expect(binding.key.character == literal.key, "\(entry) stores \(binding.key.character)")
    #expect(binding.modifiers.rawValue == literal.modifiers.rawValue, "\(entry)")
  }

  /// Open Operator Transcript is the ⌥ alternate of Open Manager. It inherits ⇧⌘M and adds ⌥, so App.swift has no
  /// literal for it.
  @Test func theOperatorTranscriptAlternateIsOptionShiftCommandM() throws {
    let entry = try #require(entries(forMenuTitle: "Open Operator Transcript").first)

    #expect(entry.kind == .menuAlternate)
    #expect(Exact(entry.keys[0]) == Exact("m", [.command, .shift, .option]))
  }

  @Test(arguments: ["New Loop…", "Open Shell", "Close Shell"])
  func aMenuItemWithNoShortcutHasNoEntry(_ title: String) {
    #expect(entries(forMenuTitle: title).isEmpty)
  }

  /// The View menu's ForEach binds each MainView through `MainView.shortcut`, under the title "Show <title>".
  @Test func theViewMenuForEachBindsTheShowEntries() {
    #expect(MainView.allCases.map(\.shortcut) == [.showInbox, .showBoard, .showIssues, .showLoops])
  }

  @Test(arguments: MainView.allCases)
  func eachMainViewsEntryCarriesItsShowTitle(_ view: MainView) {
    #expect(view.shortcut.menuTitles.contains("Show \(view.title)"))
  }

  /// `bin/test-gui shell` compares an exact string built from these stored characters in this order.
  @MainActor
  @Test func theNavKeysKeepTheOrderAndCharactersThatTheShellCheckExpects() {
    #expect(
      ShellSelfTest.navKeys == [
        .nextSession, .previousSession, .focusList, .focusTerminal, .back, .forward, .showRecentPlaces,
        .searchSessions,
      ])
    #expect(String(ShellSelfTest.navKeys.map { $0.keys[0].key.character }) == "}{lt[]yk")
  }

  @MainActor
  @Test func everyNavKeyIsAMenuEntry() {
    #expect(ShellSelfTest.navKeys.allSatisfy { $0.kind == .menu })
  }
}

// MARK: - The list's shape

@Suite struct AppShortcutShape {
  @Test func theAreasAreTheSixSectionsInOrder() {
    #expect(
      ShortcutArea.allCases.map(\.title) == [
        "Navigation", "Sessions", "Inbox decisions", "Board", "Message field", "Terminal",
      ])
  }

  /// The tables in the plan's inventory assign each shortcut to one area.
  static let areas: [ShortcutArea: Set<AppShortcut>] = [
    .navigation: [
      .showInbox, .showBoard, .showIssues, .showLoops, .filterSessions, .back, .forward, .showRecentPlaces,
      .nextNeedingYou, .nextSession, .previousSession, .searchSessions, .quickAsk, .focusList, .keyboardShortcuts,
      .listNext, .listPrevious, .listOpen, .searchResultMove, .searchResultOpen, .searchClose,
    ],
    .sessions: [
      .newSession, .newSessionInGroup, .newConversation, .importSessions, .openManager, .openOperatorTranscript,
      .stopClaude, .resumeClaude, .markDone, .acknowledge, .deleteSelection, .startIssueSession, .startFollowup,
      .reloadImport,
    ],
    .inboxDecisions: [
      .primaryAction, .decisionNext, .decisionPrevious, .decisionReview, .decisionOther, .decisionSkip, .decisionAsk,
      .decisionPick,
    ],
    .board: [.newGroup, .boardMove, .boardOpen, .boardExtend, .boardToggle, .boardClear],
    .messageField: [
      .messageClaude, .sendMessage, .messageNewline, .slashMove, .slashAccept, .messageEscape, .pasteImage,
    ],
    .terminal: [.focusTerminal, .sidebarToTerminal, .terminalNewline],
  ]

  @Test(arguments: ShortcutArea.allCases)
  func eachAreaHoldsTheEntriesThePlanAssigns(_ area: ShortcutArea) {
    #expect(Set(AppShortcut.allCases.filter { $0.area == area }) == Self.areas[area])
  }

  @Test func onlyTheOperatorTranscriptIsAMenuAlternate() {
    #expect(AppShortcut.allCases.filter { $0.kind == .menuAlternate } == [.openOperatorTranscript])
  }

  /// ⇧⌘↩, the Inbox field's ⌘↩, Issues' and Follow-up's ⌘↩, and Import's ⌘R.
  @Test func theViewEntriesAreTheFiveButtonBindings() {
    #expect(
      Set(AppShortcut.allCases.filter { $0.kind == .view }) == [
        .primaryAction, .sendMessage, .startIssueSession, .startFollowup, .reloadImport,
      ])
  }

  @Test(arguments: AppShortcut.allCases)
  func everyEntryHasATitle(_ entry: AppShortcut) {
    #expect(!entry.title.trimmingCharacters(in: .whitespaces).isEmpty)
  }

  @Test(arguments: boundEntries)
  func everyBoundEntryHasAKey(_ entry: AppShortcut) {
    #expect(!entry.keys.isEmpty)
  }

  @Test(arguments: AppShortcut.allCases)
  func everyEntryShowsSomeGlyphs(_ entry: AppShortcut) {
    #expect(!entry.glyphs.isEmpty)
  }

  @Test(arguments: menuEntries)
  func everyMenuEntryHasAMenuTitle(_ entry: AppShortcut) {
    #expect(!entry.menuTitles.isEmpty)
  }

  @Test(arguments: nonMenuEntries)
  func noOtherEntryHasAMenuTitle(_ entry: AppShortcut) {
    #expect(entry.menuTitles.isEmpty)
  }

  /// The GUI menu walk finds an item's entry by title, so two entries can't claim one title.
  @Test func noTwoEntriesShareAMenuTitle() {
    let titles = AppShortcut.allCases.flatMap(\.menuTitles)

    #expect(Set(titles).count == titles.count, "\(titles)")
  }

  /// `shortcut(_:)` binds `binding`, whose precondition admits only these kinds. Reading `binding` on any other
  /// kind would stop the test process, so the filter comes first.
  @Test(arguments: bindableEntries)
  func theBindingIsTheFirstKey(_ entry: AppShortcut) {
    #expect(Exact(entry.binding) == Exact(entry.keys[0]))
  }

  /// A focused terminal passes only ⌘ keys to the menu bar.
  @Test(arguments: menuEntries)
  func everyMenuEntryUsesCommand(_ entry: AppShortcut) {
    #expect(entry.keys[0].modifiers.contains(.command))
  }
}

// MARK: - Glyphs

@Suite struct AppShortcutGlyphs {
  struct Expected: Sendable, CustomTestStringConvertible {
    var entry: AppShortcut
    var glyphs: String
    var testDescription: String { "\(entry)" }
  }

  static let expected: [Expected] = [
    Expected(entry: .nextSession, glyphs: "⇧⌘]"),
    Expected(entry: .previousSession, glyphs: "⇧⌘["),
    Expected(entry: .back, glyphs: "⌘["),
    Expected(entry: .forward, glyphs: "⌘]"),
    Expected(entry: .openOperatorTranscript, glyphs: "⌥⇧⌘M"),
    Expected(entry: .focusList, glyphs: "⌘L"),
    Expected(entry: .markDone, glyphs: "⇧⌘D"),
    Expected(entry: .stopClaude, glyphs: "⌘."),
    Expected(entry: .sendMessage, glyphs: "⌘↩ or ↩"),
    // IssuesView's help said "(⌘Return)" before the list. It now shows the glyph.
    Expected(entry: .startIssueSession, glyphs: "⌘↩"),
    Expected(entry: .primaryAction, glyphs: "⇧⌘↩"),
    Expected(entry: .searchClose, glyphs: "⎋"),
    Expected(entry: .deleteSelection, glyphs: "⌘⌫"),
    Expected(entry: .slashAccept, glyphs: "⇥"),
    Expected(entry: .boardToggle, glyphs: "Space"),
    Expected(entry: .messageNewline, glyphs: "⇧↩ or ⌥↩"),
  ]

  @Test(arguments: expected)
  func anEntryShowsItsGlyphs(_ expected: Expected) {
    #expect(expected.entry.glyphs == expected.glyphs)
  }

  /// The plan writes this as "j or ↓" and also says letters are upper-case, so the case is left open here.
  @Test func severalKeysJoinWithOr() {
    #expect(AppShortcut.listNext.glyphs.lowercased() == "j or ↓")
  }

  @Test func modifiersShowInMacOrder() {
    let all = KeyboardShortcut("x", modifiers: [.command, .shift, .option, .control])

    #expect(AppShortcut.glyphs(all) == "⌃⌥⇧⌘X")
  }

  @Test(arguments: [KeyEquivalent.leftArrow, .rightArrow, .upArrow, .downArrow])
  func arrowsShowAsArrows(_ key: KeyEquivalent) {
    let names: [Character: String] = [
      KeyEquivalent.leftArrow.character: "←", KeyEquivalent.rightArrow.character: "→",
      KeyEquivalent.upArrow.character: "↑", KeyEquivalent.downArrow.character: "↓",
    ]

    #expect(AppShortcut.glyphs(KeyboardShortcut(key, modifiers: [])) == names[key.character])
  }

  @Test(arguments: labeledEntries)
  func aLabelReplacesTheKeys(_ entry: AppShortcut) {
    #expect(entry.glyphs == entry.label)
  }

  /// The plan spells the range "1–9". The exact text is left open; it must name both ends.
  @Test func thePickRangeNamesOneAndNine() throws {
    let label = try #require(AppShortcut.decisionPick.label)

    #expect(label.contains("1") && label.contains("9"))
  }
}

// MARK: - Press normalization

@Suite struct AppShortcutPresses {
  @Test func aStoredRightBraceIsShiftCommandRightBracket() {
    #expect(
      AppShortcut.Press(KeyboardShortcut("}", modifiers: .command))
        == AppShortcut.Press(KeyboardShortcut("]", modifiers: [.command, .shift])))
  }

  @Test func aStoredLeftBraceIsShiftCommandLeftBracket() {
    #expect(
      AppShortcut.Press(KeyboardShortcut("{", modifiers: .command))
        == AppShortcut.Press(KeyboardShortcut("[", modifiers: [.command, .shift])))
  }

  /// Back is ⌘[ and Previous Session is ⇧⌘[. Normalizing must not merge them.
  @Test func anUnshiftedBracketStaysApartFromItsBrace() {
    #expect(
      AppShortcut.Press(KeyboardShortcut("[", modifiers: .command))
        != AppShortcut.Press(KeyboardShortcut("{", modifiers: .command)))
    #expect(
      AppShortcut.Press(KeyboardShortcut("]", modifiers: .command))
        != AppShortcut.Press(KeyboardShortcut("}", modifiers: .command)))
  }

  @Test func aPlainKeyKeepsItsKeyAndModifiers() {
    let press = AppShortcut.Press(KeyboardShortcut("k", modifiers: [.command, .option]))

    #expect(press.key == "k")
    #expect(press.modifiers.rawValue == EventModifiers([.command, .option]).rawValue)
  }

  @Test func theShiftedCharacterTakesShiftWithoutLosingTheOtherModifiers() {
    let press = AppShortcut.Press(KeyboardShortcut("}", modifiers: [.command, .option]))

    #expect(press.key == "]")
    #expect(press.modifiers.rawValue == EventModifiers([.command, .option, .shift]).rawValue)
  }
}

// MARK: - Collisions

@Suite struct AppShortcutCollisions {
  /// The standard menu items every Mac app has. ⌘P is the macOS Print key, which SwiftUI may add to the default
  /// File menu. ⌘E is Use Selection for Find.
  static let standardKeys: [KeyboardShortcut] = [
    KeyboardShortcut("q"), KeyboardShortcut("w"), KeyboardShortcut("h"),
    KeyboardShortcut("h", modifiers: [.command, .option]), KeyboardShortcut("m"),
    KeyboardShortcut("m", modifiers: [.command, .option]), KeyboardShortcut(","), KeyboardShortcut("c"),
    KeyboardShortcut("v"), KeyboardShortcut("x"), KeyboardShortcut("a"), KeyboardShortcut("z"),
    KeyboardShortcut("z", modifiers: [.command, .shift]), KeyboardShortcut("f", modifiers: [.command, .control]),
    KeyboardShortcut("p"), KeyboardShortcut("e"),
  ]

  /// The pairs of `entries` whose first keys are one key press.
  func clashes(_ entries: [AppShortcut]) -> [String] {
    var seen: [AppShortcut.Press: AppShortcut] = [:]
    var found: [String] = []
    for entry in entries {
      let press = AppShortcut.Press(entry.keys[0])
      if let other = seen[press] { found.append("\(other) and \(entry)") } else { seen[press] = entry }
    }
    return found
  }

  @Test func noTwoMenuEntriesShareAKeyPress() {
    #expect(clashes(menuEntries).isEmpty, "\(clashes(menuEntries))")
  }

  /// Three view entries share ⌘↩ on purpose, because each one works only in its own view. None may take a menu key.
  @Test(arguments: viewEntries)
  func noViewEntryTakesAMenuKey(_ entry: AppShortcut) {
    let taken = menuEntries.filter { AppShortcut.Press($0.keys[0]) == AppShortcut.Press(entry.keys[0]) }

    #expect(taken.isEmpty, "\(taken)")
  }

  @Test(arguments: boundEntries)
  func noBoundEntryTakesAStandardMacKey(_ entry: AppShortcut) {
    let standard = Self.standardKeys.map { AppShortcut.Press($0) }

    #expect(!standard.contains(AppShortcut.Press(entry.keys[0])))
  }

  /// ⌘T is Move Focus to Terminal, so New Conversation takes ⌥⌘N, and ⌘K is Search Sessions, so Ask takes ⇧⌘K.
  @Test func theNeighborsOfEarlierCollisionsStayApart() {
    #expect(
      AppShortcut.Press(AppShortcut.newConversation.keys[0]) != AppShortcut.Press(AppShortcut.focusTerminal.keys[0]))
    #expect(AppShortcut.Press(AppShortcut.quickAsk.keys[0]) != AppShortcut.Press(AppShortcut.searchSessions.keys[0]))
    #expect(AppShortcut.Press(AppShortcut.messageClaude.keys[0]) != AppShortcut.Press(KeyboardShortcut("e")))
  }
}

// MARK: - Handler parity

/// Each handler key in the list goes to the handler that the plan names, and the handler does what the list
/// claims. Where the key space is small, the reverse holds too: a key the handler acts on is a listed key.
@Suite struct AppShortcutHandlerParity {
  /// The key of `entry` whose KeyEquivalent is `key`.
  func key(_ entry: AppShortcut, _ key: KeyEquivalent) throws -> KeyboardShortcut {
    try #require(entry.keys.first { $0.key == key }, "\(entry) lists no \(key.character)")
  }

  /// The keys of `entries` that `covered` leaves out.
  func uncovered(_ entries: [AppShortcut], _ covered: [(AppShortcut, KeyEquivalent)]) -> [String] {
    entries.flatMap { entry in
      entry.keys.filter { k in !covered.contains { $0.0 == entry && $0.1 == k.key } }.map {
        "\(entry) \($0.key.character)"
      }
    }
  }

  // MARK: NavKey.action

  static let navRows: [(AppShortcut, KeyEquivalent, NavAction)] = [
    (.listNext, .downArrow, .move(.down)), (.listPrevious, .upArrow, .move(.up)), (.listOpen, .return, .open),
    (.boardMove, .upArrow, .move(.up)), (.boardMove, .downArrow, .move(.down)),
    (.boardMove, .leftArrow, .move(.left)), (.boardMove, .rightArrow, .move(.right)),
    (.boardOpen, .return, .open), (.sidebarToTerminal, .return, .open),
  ]

  @Test func navKeyDoesWhatTheListSays() throws {
    for (entry, k, action) in Self.navRows {
      let shortcut = try key(entry, k)

      #expect(NavKey.action(shortcut.key, modifiers: shortcut.modifiers) == action, "\(entry)")
    }
  }

  @Test func everyNavKeyEntryKeyHasARow() {
    let entries: [AppShortcut] = [.listOpen, .boardMove, .boardOpen, .sidebarToTerminal]

    #expect(uncovered(entries, Self.navRows.map { ($0.0, $0.1) }).isEmpty)
  }

  /// `listKeys` builds its j/k character set from these entries, and NavKey handles their arrows.
  @Test func theListStepEntriesAreJOrDownAndKOrUp() {
    #expect(
      Set(AppShortcut.listNext.keys.map { Exact($0) }) == [Exact("j", []), Exact(.downArrow, [])])
    #expect(
      Set(AppShortcut.listPrevious.keys.map { Exact($0) }) == [Exact("k", []), Exact(.upArrow, [])])
  }

  // MARK: SearchPanelKeys.action

  static let searchRows: [(AppShortcut, KeyEquivalent, SearchPanelKeys.Action)] = [
    (.searchResultMove, .downArrow, .move(1)), (.searchResultMove, .upArrow, .move(-1)),
    (.searchResultOpen, .return, .open), (.searchClose, .escape, .close),
  ]

  @Test func theSearchPanelDoesWhatTheListSays() throws {
    for (entry, k, action) in Self.searchRows {
      let shortcut = try key(entry, k)

      #expect(
        SearchPanelKeys.action(shortcut.key, modifiers: shortcut.modifiers, composing: false) == action, "\(entry)")
    }
  }

  @Test func everySearchPanelEntryKeyHasARow() {
    let entries: [AppShortcut] = [.searchResultMove, .searchResultOpen, .searchClose]

    #expect(uncovered(entries, Self.searchRows.map { ($0.0, $0.1) }).isEmpty)
  }

  // MARK: DecisionSteps.keyAction

  static let decisionEntries: [AppShortcut] = [
    .decisionNext, .decisionPrevious, .decisionReview, .decisionOther, .decisionSkip, .decisionAsk, .decisionPick,
    .primaryAction,
  ]

  static let decisionKeyRows: [(AppShortcut, KeyEquivalent, DecisionKeyAction)] = [
    (.decisionNext, "]", .next), (.decisionNext, .rightArrow, .next),
    (.decisionPrevious, "[", .previous), (.decisionPrevious, .leftArrow, .previous),
    (.decisionReview, "r", .review), (.decisionOther, "o", .focusOther), (.decisionSkip, "s", .skip),
    (.decisionAsk, "a", .focusAsk), (.decisionAsk, "/", .focusAsk), (.primaryAction, .return, .next),
  ]

  static let pickRows: [(AppShortcut, KeyEquivalent, DecisionKeyAction)] = (1...9).map { n in
    (AppShortcut.decisionPick, KeyEquivalent(Character(String(n))), DecisionKeyAction.pick(n))
  }

  static let decisionRows = decisionKeyRows + pickRows

  static func decisionAction(_ shortcut: KeyboardShortcut, onReview: Bool) -> DecisionKeyAction? {
    DecisionSteps.keyAction(shortcut.key, modifiers: shortcut.modifiers, onReview: onReview, options: 9)
  }

  @Test func theDecisionStepsDoWhatTheListSays() throws {
    for (entry, k, action) in Self.decisionRows {
      let shortcut = try key(entry, k)

      #expect(Self.decisionAction(shortcut, onReview: false) == action, "\(entry) \(k.character)")
    }
  }

  @Test func onReviewThePrimaryKeySubmits() {
    #expect(Self.decisionAction(AppShortcut.primaryAction.keys[0], onReview: true) == .submit)
  }

  @Test func everyDecisionEntryKeyHasARow() {
    #expect(uncovered(Self.decisionEntries, Self.decisionRows.map { ($0.0, $0.1) }).isEmpty)
  }

  /// Printable ASCII, the arrows, Return, and Esc, with every set of ⌘, ⌥, ⌃, and ⇧, on a decision and on Review.
  /// A key that gives an action must be listed. The handler ignores ⇧ on every key but Return by design, and a
  /// shifted printable key arrives as its own character, which the sweep also sends. So ⇧ counts only on Return.
  @Test(arguments: [false, true])
  func onlyListedKeysGiveADecisionAction(onReview: Bool) {
    let listed = Set(Self.decisionEntries.flatMap(\.keys).map { Exact($0) })
    let keys =
      (0x20...0x7E).map { KeyEquivalent(Character(Unicode.Scalar(UInt8($0)))) }
      + [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape]
    var unlisted: [String] = []

    for key in keys {
      for modifiers in ReturnKeyTests.allModifiers {
        guard
          DecisionSteps.keyAction(key, modifiers: modifiers, onReview: onReview, options: 9) != nil
        else { continue }
        let press = Exact(key, modifiers)
        let isListed =
          key == .return
          ? listed.contains(press) : listed.contains { $0.withoutShift == press.withoutShift }
        if !isListed { unlisted.append(press.description) }
      }
    }

    #expect(unlisted.isEmpty, "\(unlisted)")
  }

  // MARK: SelectionKey.action (the Board and the Sidebar)

  static let selectionEntries: [AppShortcut] = [.boardClear, .boardToggle, .deleteSelection, .boardExtend]

  static let selectionRows: [(AppShortcut, KeyEquivalent, SelectionKeyAction)] = [
    (.boardClear, .escape, .clear), (.boardToggle, .space, .toggle), (.deleteSelection, .delete, .delete),
    (.boardExtend, .upArrow, .extend(.up)), (.boardExtend, .downArrow, .extend(.down)),
    (.boardExtend, .leftArrow, .extend(.left)), (.boardExtend, .rightArrow, .extend(.right)),
  ]

  @Test func theSelectionKeysDoWhatTheListSays() throws {
    for (entry, k, action) in Self.selectionRows {
      let shortcut = try key(entry, k)

      #expect(SelectionKey.action(shortcut.key, modifiers: shortcut.modifiers) == action, "\(entry)")
    }
  }

  @Test func everySelectionEntryKeyHasARow() {
    #expect(uncovered(Self.selectionEntries, Self.selectionRows.map { ($0.0, $0.1) }).isEmpty)
  }

  @Test func onlyListedKeysChangeTheSelection() {
    let listed = Set(Self.selectionEntries.flatMap(\.keys).map { Exact($0) })
    let keys: [KeyEquivalent] = [
      .escape, .space, .delete, .deleteForward, .return, .tab, .upArrow, .downArrow, .leftArrow, .rightArrow, "a", "x",
    ]
    var unlisted: [String] = []

    for key in keys {
      for modifiers in ReturnKeyTests.allModifiers where SelectionKey.action(key, modifiers: modifiers) != nil {
        if !listed.contains(Exact(key, modifiers)) { unlisted.append(Exact(key, modifiers).description) }
      }
    }

    #expect(unlisted.isEmpty, "\(unlisted)")
  }

  // MARK: ReturnKey.action

  @Test func shiftReturnInsertsANewLine() throws {
    let shortcut = try key(.messageNewline, .return)
    try #require(shortcut.modifiers == .shift)

    #expect(ReturnKey.action(modifiers: shortcut.modifiers, composing: false) == .newline)
  }

  /// The handler leaves ⌥↩ alone, and the field inserts the new line itself.
  @Test func optionReturnIsLeftToTheFieldWhichInsertsANewLine() throws {
    let shortcut = try #require(AppShortcut.messageNewline.keys.first { $0.key == .return && $0.modifiers == .option })

    #expect(ReturnKey.action(modifiers: shortcut.modifiers, composing: false) == nil)
  }

  @Test func everyNewlineKeyIsShiftOrOptionReturn() {
    #expect(
      Set(AppShortcut.messageNewline.keys.map { Exact($0) }) == [Exact(.return, .shift), Exact(.return, .option)])
  }

  /// The plan's handler table: in a message field, Return sends.
  @Test func aMessageFieldEntryListsReturnAndReturnSends() {
    let sends = AppShortcut.allCases.filter { entry in
      entry.area == .messageField && entry.keys.contains { Exact($0) == Exact(.return, []) }
    }

    #expect(!sends.isEmpty)
    #expect(ReturnKey.action(modifiers: [], composing: false) == .send)
  }

  /// The handler passes ⌘↩ on, so the Inbox field's Send button gets it.
  @Test func commandReturnReachesTheSendButton() {
    #expect(ReturnKey.action(modifiers: AppShortcut.sendMessage.keys[0].modifiers, composing: false) == nil)
  }

  // MARK: TerminalReturnKey.sendsNewline

  static func flags(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
    let pairs: [(EventModifiers, NSEvent.ModifierFlags)] = [
      (.shift, .shift), (.command, .command), (.option, .option), (.control, .control),
    ]
    return pairs.reduce(into: NSEvent.ModifierFlags()) { if modifiers.contains($1.0) { $0.insert($1.1) } }
  }

  @Test func everyTerminalNewlineKeySendsTheNewline() {
    for shortcut in AppShortcut.terminalNewline.keys {
      #expect(shortcut.key == .return)
      #expect(
        TerminalReturnKey.sendsNewline(
          keyCode: TerminalReturnKey.returnKeyCode, modifiers: Self.flags(shortcut.modifiers), composing: false,
          kittyKeyboard: false))
    }
  }
}

/// `SlashCompletion` and `MessageField.Draft` run on the main actor.
@MainActor
@Suite struct AppShortcutMessageFieldParity {
  func press(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> SlashCompletion.Action? {
    SlashCompletion().press(
      key, modifiers: modifiers, isRepeat: false, composing: false, open: true, text: "/cl", highlighted: "clear")
  }

  @Test func theSlashListDoesWhatTheListSays() throws {
    let rows: [(AppShortcut, KeyEquivalent, SlashCompletion.Action)] = [
      (.slashMove, .downArrow, .move(1)), (.slashMove, .upArrow, .move(-1)), (.slashAccept, .tab, .accept),
      (.messageEscape, .escape, .close),
    ]

    for (entry, k, action) in rows {
      let shortcut = try #require(entry.keys.first { $0.key == k }, "\(entry)")

      #expect(press(shortcut.key, shortcut.modifiers) == action, "\(entry)")
    }
  }

  @Test func theSlashEntriesListOnlyTheKeysThatTheListHandles() {
    #expect(Set(AppShortcut.slashMove.keys.map { Exact($0) }) == [Exact(.downArrow, []), Exact(.upArrow, [])])
    #expect(AppShortcut.slashAccept.keys.map { Exact($0) } == [Exact(.tab, [])])
  }

  /// Esc twice within the window clears a draft, as the entry's title says.
  @Test func twoEscapesClearTheDraft() throws {
    try #require(AppShortcut.messageEscape.keys.map { Exact($0) } == [Exact(.escape, [])])
    let draft = MessageField.Draft()
    draft.text = "hello"
    let start = Date(timeIntervalSince1970: 1_000)
    _ = draft.escape(at: start)

    let cleared = draft.escape(at: start.addingTimeInterval(MessageField.Draft.escapeWindow / 2))

    #expect(cleared)
    #expect(draft.text.isEmpty)
  }
}

// MARK: - Source scan

/// Reads Swift source as text. It knows comments, string literals, raw strings, multi-line strings, and
/// interpolation, which is all the scans need.
enum SourceScan {
  /// `source` with every comment blanked to spaces, so each line keeps its number. With `maskStrings`, the text
  /// inside each string literal is blanked too. The quotes stay, so a scan can still see that a literal was there.
  static func stripped(_ source: String, maskStrings: Bool) -> [Unicode.Scalar] {
    enum Context {
      case interpolation(depth: Int)
      case string(hashes: Int, multiline: Bool)
    }
    let s = Array(source.unicodeScalars)
    var out: [Unicode.Scalar] = []
    out.reserveCapacity(s.count)
    var stack: [Context] = []
    var i = 0

    func starts(_ text: String, at j: Int) -> Bool {
      let t = Array(text.unicodeScalars)
      return j + t.count <= s.count && s[j..<(j + t.count)].elementsEqual(t)
    }
    func blank(_ c: Unicode.Scalar) -> Unicode.Scalar { c == "\n" ? "\n" : " " }
    func literal(_ c: Unicode.Scalar) -> Unicode.Scalar { maskStrings ? blank(c) : c }

    while i < s.count {
      let c = s[i]
      if case .string(let hashes, let multiline)? = stack.last {
        let pounds = String(repeating: "#", count: hashes)
        if starts("\\" + pounds + "(", at: i) {
          out += s[i..<(i + hashes + 2)].map(literal)
          stack.append(.interpolation(depth: 1))
          i += hashes + 2
        } else if starts("\\" + pounds, at: i), i + hashes + 1 < s.count {
          out += s[i..<(i + hashes + 2)].map(literal)
          i += hashes + 2
        } else if starts((multiline ? "\"\"\"" : "\"") + pounds, at: i) {
          let n = (multiline ? 3 : 1) + hashes
          out += s[i..<(i + n)]
          stack.removeLast()
          i += n
        } else if c == "\n" && !multiline {
          out.append(c)
          stack.removeLast()
          i += 1
        } else {
          out.append(literal(c))
          i += 1
        }
        continue
      }
      if starts("//", at: i) {
        while i < s.count, s[i] != "\n" {
          out.append(" ")
          i += 1
        }
        continue
      }
      if starts("/*", at: i) {
        var depth = 0
        repeat {
          if starts("/*", at: i) {
            depth += 1
            out += [" ", " "]
            i += 2
          } else if starts("*/", at: i) {
            depth -= 1
            out += [" ", " "]
            i += 2
          } else {
            out.append(blank(s[i]))
            i += 1
          }
        } while depth > 0 && i < s.count
        continue
      }
      var hashes = 0
      while i + hashes < s.count, s[i + hashes] == "#" { hashes += 1 }
      if i + hashes < s.count, s[i + hashes] == "\"" {
        let multiline = starts("\"\"\"", at: i + hashes)
        let n = hashes + (multiline ? 3 : 1)
        out += s[i..<(i + n)]
        stack.append(.string(hashes: hashes, multiline: multiline))
        i += n
        continue
      }
      if case .interpolation(let depth)? = stack.last {
        if c == "(" {
          stack[stack.count - 1] = .interpolation(depth: depth + 1)
        } else if c == ")" {
          if depth == 1 { stack.removeLast() } else { stack[stack.count - 1] = .interpolation(depth: depth - 1) }
        }
        out.append(literal(c))
        i += 1
        continue
      }
      out.append(c)
      i += 1
    }
    return out
  }

  static func isIdentifier(_ c: Unicode.Scalar) -> Bool { c == "_" || CharacterSet.alphanumerics.contains(c) }

  static func line(of index: Int, in code: [Unicode.Scalar]) -> Int {
    code[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
  }

  /// The index of the open parenthesis of each call of `name`, including `name.init(`. A declaration such as
  /// `func name(` is not a call.
  static func calls(of name: String, in code: [Unicode.Scalar]) -> [Int] {
    let n = Array(name.unicodeScalars)
    var found: [Int] = []
    var i = 0
    while i + n.count <= code.count {
      defer { i += 1 }
      guard code[i..<(i + n.count)].elementsEqual(n), i == 0 || !isIdentifier(code[i - 1]) else { continue }
      var j = i + n.count
      guard j == code.count || !isIdentifier(code[j]) else { continue }
      let initCall = Array(".init".unicodeScalars)
      if j + initCall.count <= code.count, code[j..<(j + initCall.count)].elementsEqual(initCall) {
        j += initCall.count
      }
      while j < code.count, code[j] == " " || code[j] == "\n" || code[j] == "\t" { j += 1 }
      guard j < code.count, code[j] == "(" else { continue }
      var k = i - 1
      while k >= 0, code[k] == " " || code[k] == "\t" || code[k] == "\n" { k -= 1 }
      var word: [Unicode.Scalar] = []
      while k >= 0, isIdentifier(code[k]) {
        word.insert(code[k], at: 0)
        k -= 1
      }
      if String(String.UnicodeScalarView(word)) == "func" { continue }
      found.append(j)
    }
    return found
  }

  /// The text between the parenthesis at `open` and its match, or nil when the source ends first.
  static func argument(from open: Int, in code: [Unicode.Scalar]) -> String? {
    var depth = 0
    for j in open..<code.count {
      if code[j] == "(" { depth += 1 }
      if code[j] == ")" {
        depth -= 1
        if depth == 0 { return String(String.UnicodeScalarView(code[(open + 1)..<j])) }
      }
    }
    return nil
  }

  static let dialogStandards: Set<String> = [
    ".cancelAction", ".defaultAction", "KeyboardShortcut.cancelAction", "KeyboardShortcut.defaultAction",
  ]

  /// Whether a `keyboardShortcut` argument can only be a dialog standard or nil: `.cancelAction`,
  /// `.defaultAction`, or a ternary whose branches are those or nil. A string literal anywhere refuses it.
  static func isDialogStandard(_ argument: String) -> Bool {
    let a = argument.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if dialogStandards.contains(a) { return true }
    guard !a.contains("\""), let question = a.range(of: " ? "),
      let colon = a.range(of: " : ", range: question.upperBound..<a.endIndex)
    else { return false }
    let branches = [String(a[question.upperBound..<colon.lowerBound]), String(a[colon.upperBound...])]
    let allowed = dialogStandards.union(["nil"])
    return branches.allSatisfy(allowed.contains) && branches.contains { $0 != "nil" }
  }

  /// The lines of every `keyboardShortcut(` call whose argument is not a dialog standard.
  static func rawShortcutBindings(in source: String) -> [Int] {
    let code = stripped(source, maskStrings: true)
    return calls(of: "keyboardShortcut", in: code).compactMap { open in
      guard let text = argument(from: open, in: code), isDialogStandard(text) else {
        return line(of: open, in: code)
      }
      return nil
    }
  }

  /// The lines that construct a `KeyboardShortcut`. A bare `KeyEquivalent` binds nothing on its own, and a key
  /// handler such as RepoPicker's builds one to compare keys.
  static func shortcutConstructions(in source: String) -> [Int] {
    let code = stripped(source, maskStrings: true)
    let opens = calls(of: "KeyboardShortcut", in: code)
    return Set(opens.map { line(of: $0, in: code) }).sorted()
  }

  static let glyphs: Set<Unicode.Scalar> = ["⌘", "⇧", "⌥", "⌃", "↩"]

  /// The lines whose code, string literals included, spells a modifier or Return glyph.
  static func shortcutGlyphLines(in source: String) -> [Int] {
    var lines: [Int] = []
    var line = 1
    var flagged = false
    for c in stripped(source, maskStrings: false) {
      if c == "\n" {
        line += 1
        flagged = false
      } else if !flagged, glyphs.contains(c) {
        lines.append(line)
        flagged = true
      }
    }
    return lines
  }
}

@Suite struct SourceScanBindings {
  @Test func aStringKeyIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: #"Button("A") {}.keyboardShortcut("x")"#) == [1])
  }

  @Test func aNamedKeyWithModifiersIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: ".keyboardShortcut(.return, modifiers: .command)") == [1])
  }

  @Test func anArgumentOnTheNextLineIsFlagged() {
    #expect(
      SourceScan.rawShortcutBindings(in: "Button(\"A\") {}\n  .keyboardShortcut(\n    \"n\", modifiers: [.command])")
        == [2])
  }

  @Test func aVariableIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: ".keyboardShortcut(shortcut)") == [1])
  }

  @Test func aConstructedShortcutIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: ".keyboardShortcut(KeyboardShortcut(\"k\"))") == [1])
  }

  /// A View extension can call the modifier without the dot.
  @Test func aCallWithoutTheDotIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: "func f() -> some View { keyboardShortcut(\"x\") }") == [1])
  }

  @Test func aTernaryWithANonStandardBranchIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: ".keyboardShortcut(flag ? .defaultAction : custom)") == [1])
  }

  @Test func aTernaryWithAStringInItsConditionIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: #".keyboardShortcut(name == "x" ? .defaultAction : nil)"#) == [1])
  }

  @Test func theSecondOfTwoChainedCallsIsFlagged() {
    #expect(SourceScan.rawShortcutBindings(in: ".keyboardShortcut(.cancelAction)\n.keyboardShortcut(\"x\")") == [2])
  }

  @Test(arguments: [
    ".keyboardShortcut(.cancelAction)",
    ".keyboardShortcut(.defaultAction)",
    ".keyboardShortcut( .defaultAction )",
    ".keyboardShortcut(KeyboardShortcut.cancelAction)",
    ".keyboardShortcut(flag ? .defaultAction : nil)",
    ".keyboardShortcut(returnOwner == .add ? .defaultAction : nil)",
    ".keyboardShortcut(flag ? .cancelAction : .defaultAction)",
    ".keyboardShortcut(\n  labelFocused\n    ? .defaultAction\n    : nil)",
  ])
  func aDialogStandardPasses(_ source: String) {
    #expect(SourceScan.rawShortcutBindings(in: source).isEmpty)
  }

  @Test(arguments: [
    "// .keyboardShortcut(\"x\")",
    "  /// Binds .keyboardShortcut(\"x\") in a doc comment.",
    "foo() // .keyboardShortcut(\"x\")",
    "/* .keyboardShortcut(\"x\") */ let a = 1",
    "/* outer /* .keyboardShortcut(\"x\") */ still a comment */",
    #"let s = ".keyboardShortcut(\"x\")""#,
    "func keyboardShortcut(_ s: String) {}",
    ".shortcut(.newSession)",
  ])
  func codeThatBindsNoRawShortcutPasses(_ source: String) {
    #expect(SourceScan.rawShortcutBindings(in: source).isEmpty)
  }
}

@Suite struct SourceScanConstructions {
  @Test(arguments: [
    #"static let k = KeyboardShortcut("k", modifiers: .command)"#,
    #"let k: KeyboardShortcut = KeyboardShortcut.init("k")"#,
    #"let k = SwiftUI.KeyboardShortcut("k")"#,
    "let k = KeyboardShortcut (\"k\")",
  ])
  func aConstructionIsFlagged(_ source: String) {
    #expect(SourceScan.shortcutConstructions(in: source) == [1])
  }

  @Test(arguments: [
    "// KeyboardShortcut(\"k\")",
    "let k: KeyboardShortcut? = nil",
    "func f(_ k: KeyEquivalent) {}",
    #"let e = KeyEquivalent("x")"#,
    #"let s = "KeyboardShortcut(\"k\")""#,
    "let k = MyKeyboardShortcut(\"k\")",
    "case .return: KeyEquivalent.return",
  ])
  func codeThatConstructsNoShortcutPasses(_ source: String) {
    #expect(SourceScan.shortcutConstructions(in: source).isEmpty)
  }
}

@Suite struct SourceScanGlyphs {
  /// The string literal still holds ⌘ after the trailing comment is removed.
  @Test func aGlyphInAStringBeforeATrailingCommentIsFlagged() {
    #expect(SourceScan.shortcutGlyphLines(in: #".help("Stop (⌘.)") // ⌘ here"#) == [1])
  }

  @Test func aGlyphOnlyInATrailingCommentPasses() {
    #expect(SourceScan.shortcutGlyphLines(in: #".help("Stop") // ⌘ here"#).isEmpty)
  }

  /// The `//` inside the string does not start a comment.
  @Test func aSlashSlashInsideAStringDoesNotHideTheRestOfTheString() {
    #expect(SourceScan.shortcutGlyphLines(in: #"let s = "a // b ⌘""#) == [1])
  }

  @Test func aURLInAStringBeforeACommentPasses() {
    #expect(SourceScan.shortcutGlyphLines(in: #"let url = "https://x" // ⇧"#).isEmpty)
  }

  /// An escaped quote does not end the string.
  @Test func anEscapedQuoteDoesNotEndTheString() {
    #expect(SourceScan.shortcutGlyphLines(in: #"let s = "say \"hi\" // ⌥""#) == [1])
    #expect(SourceScan.shortcutGlyphLines(in: #"let s = "say \"hi\"" // ⌥"#).isEmpty)
  }

  @Test func aGlyphInARawStringIsFlagged() {
    #expect(SourceScan.shortcutGlyphLines(in: ##"let s = #"a "b" // ⌃"#"##) == [1])
  }

  @Test func aGlyphInAMultiLineStringIsFlaggedOnItsLine() {
    #expect(SourceScan.shortcutGlyphLines(in: "let s = \"\"\"\n  Press ⌘K\n  \"\"\"\nlet t = 1 // ↩") == [2])
  }

  @Test func aGlyphInAStringInsideAnInterpolationIsFlagged() {
    #expect(SourceScan.shortcutGlyphLines(in: #"let s = "(\(flag ? "⇧" : ""))""#) == [1])
  }

  @Test func anInterpolatedGlyphPropertyPasses() {
    #expect(SourceScan.shortcutGlyphLines(in: #".help("Stop Claude (\(AppShortcut.stopClaude.glyphs))")"#).isEmpty)
  }

  @Test(arguments: [
    "/// Press ⇧⌘↩ to send.",
    "  // ⌘K opens search.",
    "/* ⌥ */ let a = 1",
  ])
  func aGlyphInACommentPasses(_ source: String) {
    #expect(SourceScan.shortcutGlyphLines(in: source).isEmpty)
  }

  @Test(arguments: ["Text(\"⇧⌘↩\")", "let a = \"⌃\"", "let r = \"↩\""])
  func aGlyphInCodeIsFlagged(_ source: String) {
    #expect(SourceScan.shortcutGlyphLines(in: source) == [1])
  }
}

/// The scans over the app's real sources. A menu shortcut can't get into App.swift without being a list entry.
@Suite struct AppShortcutSourceTree {
  static let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/SwitchboardApp")

  /// Every Swift file under the app's source folder, by path relative to it.
  static func sources() throws -> [(path: String, text: String)] {
    let paths = (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? []
    return try paths.filter { $0.hasSuffix(".swift") }.sorted().map {
      ($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8))
    }
  }

  /// Each flagged line as "path:line: text".
  static func findings(_ scan: (String) -> [Int], skipping skip: (String) -> Bool) throws -> [String] {
    try sources().filter { !skip($0.path) }.flatMap { file in
      let lines = file.text.components(separatedBy: "\n")
      return scan(file.text).map { "\(file.path):\($0): \(lines[$0 - 1].trimmingCharacters(in: .whitespaces))" }
    }
  }

  static func isList(_ path: String) -> Bool { (path as NSString).lastPathComponent == "AppShortcut.swift" }

  /// A scan of an empty or wrong folder would pass by finding nothing.
  @Test func theScanReadsTheAppSources() throws {
    let paths = try Self.sources().map(\.path)

    #expect(paths.contains("App.swift"))
    #expect(paths.contains("AppShortcut.swift"))
  }

  @Test func sourceBindsOnlyListedShortcuts() throws {
    let found = try Self.findings(SourceScan.rawShortcutBindings, skipping: Self.isList)

    #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
  }

  @Test func sourceConstructsShortcutsOnlyInTheListAndTheSelfTests() throws {
    let found = try Self.findings(SourceScan.shortcutConstructions) {
      Self.isList($0) || $0.hasSuffix("SelfTest.swift")
    }

    #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
  }

  @Test func sourceSpellsNoShortcutGlyph() throws {
    let found = try Self.findings(SourceScan.shortcutGlyphLines, skipping: Self.isList)

    #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
  }
}
