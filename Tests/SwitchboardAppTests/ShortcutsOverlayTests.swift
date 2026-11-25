import AppKit
import SwiftTerm
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A view that takes typed text but is neither an NSTextView nor a terminal. The guard must refuse it, because the
/// property it checks is "the responder takes typed text", not a list of known text views.
private final class TypingView: NSView, NSTextInputClient {
  nonisolated func insertText(_ string: Any, replacementRange: NSRange) {}
  nonisolated func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
  nonisolated func unmarkText() {}
  nonisolated func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  nonisolated func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  nonisolated func hasMarkedText() -> Bool { false }
  nonisolated func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  nonisolated func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
  nonisolated func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

// MARK: - The ? guard

/// Each test breaks one condition of `ShortcutsKey.action` and leaves the rest as they are when `?` opens the
/// overlay. The suite runs on the main actor, so the terminal case tests the same cast that the monitor makes.
@MainActor
@Suite struct ShortcutsKeyTests {
  /// Where the key went and what the model shows. The fields follow the plan's conditions one to one.
  struct Scene {
    /// The event's window is the main window.
    var inMainWindow = true
    /// The event's window is the sheet attached to the main window.
    var inMainWindowSheet = false
    /// The main window has an attached sheet, which a confirmation dialog is too.
    var mainWindowHasSheet = false
    var presentingSheet = false
    var overlayOpen = false

    /// The overlay shows, and the key went to its sheet.
    static let overlay = Scene(
      inMainWindow: false, inMainWindowSheet: true, mainWindowHasSheet: true, presentingSheet: true, overlayOpen: true)

    var place: ShortcutsKey.Place {
      ShortcutsKey.Place(
        isMainWindow: inMainWindow, isMainWindowSheet: inMainWindowSheet, mainWindowHasSheet: mainWindowHasSheet,
        presentingSheet: presentingSheet, overlayOpen: overlayOpen)
    }
  }

  func action(
    _ characters: String = "?", _ modifiers: NSEvent.ModifierFlags = .shift, responder: NSResponder? = nil,
    isRepeat: Bool = false, composing: Bool = false, in scene: Scene = Scene()
  ) -> ShortcutsKey.Action? {
    ShortcutsKey.action(
      characters: characters, modifiers: modifiers, isRepeat: isRepeat, responder: responder, composing: composing,
      place: scene.place)
  }

  /// Holding ? sends repeats, which would open and close the overlay over and over.
  @Test func aRepeatedQuestionMarkIsLeftAlone() {
    #expect(action(isRepeat: true) == nil)
    #expect(action(isRepeat: true, in: .overlay) == nil)
  }

  // MARK: Opening

  @Test func questionMarkInTheIdleMainWindowOpens() {
    #expect(action() == .open)
  }

  /// A layout can type ? without ⇧.
  @Test func questionMarkWithoutShiftOpens() {
    #expect(action("?", []) == .open)
  }

  /// Caps Lock, the numeric pad and function flags, and the device bits that a left-Shift press sets do not count.
  nonisolated static let flagsThatDoNotCount: [UInt] = [
    NSEvent.ModifierFlags([.shift, .capsLock]).rawValue,
    NSEvent.ModifierFlags([.shift, .numericPad]).rawValue,
    NSEvent.ModifierFlags([.shift, .function]).rawValue,
    NSEvent.ModifierFlags.shift.rawValue | 0x102,
  ]

  @Test(arguments: flagsThatDoNotCount)
  func flagsOtherThanCommandOptionAndControlStillOpen(_ raw: UInt) {
    #expect(action("?", NSEvent.ModifierFlags(rawValue: raw)) == .open)
  }

  // MARK: The key

  /// ⌘/ is the Help menu's key, and the menu takes it. ⇧⌘/ is the system's Help search.
  nonisolated static let blockingModifiers: [UInt] = [
    NSEvent.ModifierFlags.command.rawValue, NSEvent.ModifierFlags.option.rawValue,
    NSEvent.ModifierFlags.control.rawValue, NSEvent.ModifierFlags([.shift, .command]).rawValue,
    NSEvent.ModifierFlags([.shift, .option]).rawValue, NSEvent.ModifierFlags([.shift, .control]).rawValue,
  ]

  @Test(arguments: ["?", "/"], blockingModifiers)
  func aKeyWithCommandOptionOrControlIsLeftAlone(_ characters: String, _ raw: UInt) {
    #expect(action(characters, NSEvent.ModifierFlags(rawValue: raw)) == nil)
  }

  /// The check reads the produced character, so "/" alone, an empty string, or a longer string is not ?.
  @Test(arguments: ["/", "", "??", "¿", "a", " "])
  func anyOtherCharacterIsLeftAlone(_ characters: String) {
    #expect(action(characters, []) == nil)
  }

  // MARK: The responder

  /// The responders that take typed text.
  enum TypingResponder: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The field editor of every TextField and search field.
    case fieldEditor
    /// TextEditor's view, as in notes and the new-session prompt.
    case textView
    /// The Claude and shell panes.
    case claudeTerminal
    case swiftTermView
    case otherTextInputClient

    var testDescription: String { rawValue }

    @MainActor func make() -> NSResponder? {
      switch self {
      case .fieldEditor:
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
          defer: true)
        return window.fieldEditor(true, for: nil)
      case .textView: return NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
      case .claudeTerminal: return ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
      case .swiftTermView: return TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
      case .otherTextInputClient: return TypingView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
      }
    }
  }

  @Test(arguments: TypingResponder.allCases)
  func aResponderThatTakesTypedTextKeepsTheQuestionMark(_ kind: TypingResponder) throws {
    let responder = try #require(kind.make())

    #expect(action(responder: responder) == nil)
  }

  /// The SwiftUI and AppKit views that have focus without taking typed text: the Inbox, Issues, and Loops lists, the
  /// Board, the decision step view, and the sidebar's table.
  enum OtherResponder: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case none, plainView, tableView, hostingView, window

    var testDescription: String { rawValue }

    @MainActor func make() -> NSResponder? {
      switch self {
      case .none: return nil
      case .plainView: return NSView(frame: .zero)
      case .tableView: return NSTableView(frame: .zero)
      case .hostingView: return NSHostingView(rootView: Text("list"))
      case .window:
        return NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
          defer: true)
      }
    }
  }

  @Test(arguments: OtherResponder.allCases)
  func aResponderThatTakesNoTypedTextLetsTheQuestionMarkOpen(_ kind: OtherResponder) {
    #expect(action(responder: kind.make()) == .open)
  }

  @Test func aComposingInputMethodKeepsTheQuestionMark() {
    #expect(action(composing: true) == nil)
  }

  // MARK: The window and the model

  /// A popover, the hover card, Settings, the menu bar window, or a sheet other than the overlay.
  @Test func aKeyOutsideTheMainWindowIsLeftAlone() {
    #expect(action(in: Scene(inMainWindow: false)) == nil)
  }

  /// A confirmation dialog attaches a sheet that `presentingSheet` does not count.
  @Test func anAttachedSheetKeepsTheOverlayShut() {
    #expect(action(in: Scene(mainWindowHasSheet: true)) == nil)
  }

  @Test func aSheetThatTheModelPresentsKeepsTheOverlayShut() {
    #expect(action(in: Scene(presentingSheet: true)) == nil)
  }

  // MARK: Closing

  /// Opening the overlay sets `presentingSheet`, which must not stop the close.
  @Test func questionMarkInTheOverlaySheetCloses() {
    #expect(action(in: .overlay) == .close)
  }

  @Test func questionMarkWithoutShiftInTheOverlaySheetCloses() {
    #expect(action("?", [], in: .overlay) == .close)
  }

  @Test func questionMarkInTheMainWindowWhileTheOverlayShowsIsLeftAlone() {
    let scene = Scene(
      inMainWindow: true, inMainWindowSheet: false, mainWindowHasSheet: true, presentingSheet: true, overlayOpen: true)

    #expect(action(in: scene) == nil)
  }

  /// Another sheet, such as New Session, whose focus is on a button.
  @Test func questionMarkInAnotherSheetIsLeftAlone() {
    var scene = Scene.overlay
    scene.overlayOpen = false

    #expect(action(in: scene) == nil)
  }

  @Test func questionMarkInAnotherWindowWhileTheOverlayShowsIsLeftAlone() {
    var scene = Scene.overlay
    scene.inMainWindowSheet = false

    #expect(action(in: scene) == nil)
  }

  @Test(arguments: blockingModifiers)
  func aModifiedKeyInTheOverlaySheetIsLeftAlone(_ raw: UInt) {
    #expect(action("?", NSEvent.ModifierFlags(rawValue: raw), in: .overlay) == nil)
  }

  @Test func aComposingInputMethodInTheOverlaySheetKeepsTheQuestionMark() {
    #expect(action(composing: true, in: .overlay) == nil)
  }

  @Test func aTextViewInTheOverlaySheetKeepsTheQuestionMark() {
    #expect(action(responder: NSTextView(frame: .zero), in: .overlay) == nil)
  }

  // MARK: The list's entry

  /// The overlay lists `?` under the Help item's entry. Each of the entry's keys without ⌘ is one that the guard
  /// takes in the idle main window.
  @Test func theEntrysPlainKeysOpenTheOverlay() {
    let plain = AppShortcut.keyboardShortcuts.keys.filter { !$0.modifiers.contains(.command) }

    #expect(!plain.isEmpty)
    for key in plain {
      let flags: NSEvent.ModifierFlags = key.modifiers.contains(.shift) ? .shift : []
      #expect(action(String(key.key.character), flags) == .open, "\(key.key.character)")
    }
  }
}

// MARK: - The Help item's entry

@Suite struct KeyboardShortcutsEntryTests {
  /// A bare ? on a menu item would take the character from every text field. ⇧⌘/ is the system's Help search.
  @Test func theHelpItemBindsCommandSlash() {
    let binding = AppShortcut.keyboardShortcuts.keys[0]

    #expect(AppShortcut.keyboardShortcuts.kind == .menu)
    #expect(binding.key.character == "/")
    #expect(binding.modifiers.rawValue == EventModifiers.command.rawValue)
  }

  @Test func theHelpItemIsTitledKeyboardShortcuts() {
    #expect(AppShortcut.keyboardShortcuts.menuTitles == ["Keyboard Shortcuts"])
  }

  @Test func theEntryIsUnderNavigation() {
    #expect(AppShortcut.keyboardShortcuts.area == .navigation)
  }

  /// The plan writes it as "? or ⌘/". The order is left open, because `keys[0]` has to be the ⌘/ binding.
  @Test func theOverlayShowsBothQuestionMarkAndCommandSlash() {
    let glyphs = AppShortcut.keyboardShortcuts.glyphs

    #expect(glyphs.contains("⌘/"))
    #expect(glyphs.replacingOccurrences(of: "⌘/", with: "").contains("?"))
  }

  @Test func noOtherMenuEntryTakesCommandSlash() {
    let press = AppShortcut.Press(AppShortcut.keyboardShortcuts.keys[0])
    let others = AppShortcut.allCases.filter {
      $0 != .keyboardShortcuts && $0.kind != .handler && AppShortcut.Press($0.keys[0]) == press
    }

    #expect(others.isEmpty, "\(others)")
  }
}

// MARK: - Areas for the current view

@MainActor
@Suite struct ShortcutAreasTests {
  /// What the detail pane shows when the overlay opens.
  enum Place: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case inbox, inboxWithTerminal, board, boardWithTerminalFlag, boardWithMultiSelection, issues, loops
    case session, sessionWithMultiSelection, unstartedFollowup, startedFollowup, docket

    var testDescription: String { rawValue }

    var expected: [ShortcutArea] {
      switch self {
      case .inbox: [.navigation, .sessions, .inboxDecisions, .messageField]
      case .inboxWithTerminal: [.navigation, .sessions, .inboxDecisions, .messageField, .terminal]
      case .board, .boardWithTerminalFlag, .boardWithMultiSelection: [.navigation, .sessions, .board]
      case .issues, .loops: [.navigation, .sessions]
      case .session, .startedFollowup: [.navigation, .sessions, .messageField, .terminal]
      case .sessionWithMultiSelection, .unstartedFollowup, .docket: [.navigation, .sessions]
      }
    }
  }

  /// A follow-up that `followup start` started, which shows SessionView.
  static func startedFollowup(_ id: String) -> SessionSummary {
    var s = needsItem(id, state: .working)
    s.followup = Followup(prompt: "p")
    s.followup?.started = 1
    return s
  }

  func arrange(_ place: Place) throws -> BoardModel {
    let model = appliedModel([
      needsItem("a"), needsItem("b"), unstartedFollowup("f"), Self.startedFollowup("g"), docketSession("d"),
    ])
    switch place {
    case .inbox, .inboxWithTerminal:
      model.show(.inbox)
      model.showingTerminal = place == .inboxWithTerminal
    case .board, .boardWithTerminalFlag, .boardWithMultiSelection:
      model.show(.board)
      if place == .boardWithTerminalFlag { model.showingTerminal = true }
      if place == .boardWithMultiSelection {
        model.multiSelection = ["a", "b"]
        try #require(model.showsMultiSelection && !model.showsMultiSelectionPane)
      }
    case .issues: model.show(.issues)
    case .loops: model.show(.loops)
    case .session:
      model.selection = "a"
      try #require(model.selected?.id == "a")
    case .sessionWithMultiSelection:
      model.selection = "a"
      model.multiSelection = ["a", "b"]
      try #require(model.showsMultiSelectionPane)
    case .unstartedFollowup:
      model.selection = "f"
      try #require(model.selected?.id == "f")
      try #require(model.selected?.followup?.started == nil)
    case .startedFollowup:
      model.selection = "g"
      try #require(model.selected?.followup?.started != nil)
    case .docket:
      model.selection = "d"
      try #require(model.selected?.docket != nil)
    }
    return model
  }

  /// Every view gets Navigation and Sessions, and the areas come in the overlay's section order.
  @Test(arguments: Place.allCases)
  func eachPlaceShowsItsAreas(_ place: Place) throws {
    let model = try arrange(place)

    #expect(model.shortcutAreas == place.expected)
  }
}

// MARK: - Opening and closing

@MainActor
@Suite struct ShortcutsOverlayStateTests {
  @Test func openingRecordsTheAreasOfTheCurrentView() {
    let model = appliedModel([needsItem("a")])
    model.show(.board)

    model.openShortcuts()

    #expect(model.shortcutsOverlay?.areas == [.navigation, .sessions, .board])
  }

  @Test func openingRecordsTheSameAreasThatTheModelReports() {
    let model = appliedModel([needsItem("a")])
    model.selection = "a"

    model.openShortcuts()

    #expect(model.shortcutsOverlay?.areas == model.shortcutAreas)
  }

  /// The overlay does not change under the user.
  @Test func theAreasStayWhenTheViewChangesUnderTheOverlay() {
    let model = appliedModel([needsItem("a")])
    model.show(.inbox)
    model.openShortcuts()

    model.show(.board)

    #expect(model.shortcutsOverlay?.areas == [.navigation, .sessions, .inboxDecisions, .messageField])
  }

  /// A presented sheet turns off the other menu commands and keeps `?` and the side buttons from acting.
  @Test func openingPresentsASheet() {
    let model = offlineModel()
    #expect(!model.presentingSheet)

    model.openShortcuts()

    #expect(model.presentingSheet)
  }

  /// The Help item opens the overlay only when no other sheet shows, and closes it while it shows.
  @Test func theHelpItemTogglesOnlyWhenNoOtherSheetShows() {
    let model = offlineModel()
    #expect(model.canToggleShortcuts)

    model.showingImport = true
    #expect(!model.canToggleShortcuts)

    model.showingImport = false
    model.openShortcuts()
    #expect(model.canToggleShortcuts)
  }

  @Test func closingClearsTheRequest() {
    let model = offlineModel()
    model.openShortcuts()

    model.closeShortcuts()

    #expect(model.shortcutsOverlay == nil)
  }

  @Test func closingEndsTheSheet() {
    let model = offlineModel()
    model.openShortcuts()

    model.closeShortcuts()

    #expect(!model.presentingSheet)
  }

  @Test func closingWhenNothingIsOpenLeavesNothingOpen() {
    let model = offlineModel()

    model.closeShortcuts()

    #expect(model.shortcutsOverlay == nil)
    #expect(!model.presentingSheet)
  }
}

// MARK: - Availability

@Suite struct ShortcutAvailabilityTests {
  /// `operatorTranscriptAlternate` adds the ⌥ item only on macOS 15 and later.
  @Test func theOperatorTranscriptKeyExistsOnlyFromMacOS15() {
    #expect(!AppShortcut.openOperatorTranscript.isAvailable(macOSMajor: 14))
    #expect(AppShortcut.openOperatorTranscript.isAvailable(macOSMajor: 15))
  }

  @Test func everyOtherEntryExistsOnMacOS14() {
    let missing = AppShortcut.allCases.filter { $0 != .openOperatorTranscript && !$0.isAvailable(macOSMajor: 14) }

    #expect(missing.isEmpty, "\(missing)")
  }
}
