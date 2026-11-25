import SwiftUI

/// The part of the app that a shortcut works in. The shortcuts overlay shows one section per area.
enum ShortcutArea: CaseIterable, Identifiable {
  case navigation, sessions, inboxDecisions, board, messageField, terminal

  var id: Self { self }

  var title: String {
    switch self {
    case .navigation: "Navigation"
    case .sessions: "Sessions"
    case .inboxDecisions: "Inbox decisions"
    case .board: "Board"
    case .messageField: "Message field"
    case .terminal: "Terminal"
    }
  }
}

/// How the app binds a shortcut.
enum ShortcutKind: Equatable {
  /// A main-menu item binds it through `shortcut(_:)`.
  case menu
  /// An ⌥ alternate menu item inherits it from the item it replaces, so no `shortcut(_:)` call binds it.
  case menuAlternate
  /// A button in a view binds it through `shortcut(_:)`.
  case view
  /// An `onKeyPress` handler, a key monitor, or the terminal handles it. Nothing binds it.
  case handler
}

/// Every keyboard shortcut in the app. The menus and buttons bind their keys from here, and the shortcuts
/// overlay lists these entries, so the overlay can't drift from the real bindings.
///
/// Menu shortcuts carry ⌘, because a focused terminal keeps every other key. SwiftTerm offers a ⌘ key to the
/// menu bar before the terminal's program, as long as `shouldSendCommandKeyToTerminal` stays nil.
enum AppShortcut: CaseIterable, Identifiable {
  // Navigation
  case showInbox, showBoard, showIssues, showLoops, filterSessions
  case back, forward, showRecentPlaces, nextNeedingYou, nextSession, previousSession
  case searchSessions, quickAsk, focusList, keyboardShortcuts
  case listNext, listPrevious, listOpen
  case searchResultMove, searchResultOpen, searchClose
  // Sessions
  case newSession, newSessionInGroup, newConversation, importSessions, openManager, openOperatorTranscript
  case stopClaude, resumeClaude, markDone, acknowledge, deleteSelection
  case startIssueSession, startFollowup, reloadImport
  // Inbox decisions
  case primaryAction, decisionNext, decisionPrevious, decisionReview, decisionOther, decisionSkip, decisionAsk
  case decisionPick
  // Board
  case newGroup, boardMove, boardOpen, boardExtend, boardToggle, boardClear
  // Message field
  case messageClaude, sendMessage, messageNewline, slashMove, slashAccept, messageEscape, pasteImage
  // Terminal
  case focusTerminal, sidebarToTerminal, terminalNewline

  var id: Self { self }

  var kind: ShortcutKind {
    switch self {
    case .openOperatorTranscript: .menuAlternate
    case .primaryAction, .sendMessage, .startIssueSession, .startFollowup, .reloadImport: .view
    case .listNext, .listPrevious, .listOpen, .searchResultMove, .searchResultOpen, .searchClose, .deleteSelection,
      .decisionNext, .decisionPrevious, .decisionReview, .decisionOther, .decisionSkip, .decisionAsk, .decisionPick,
      .boardMove, .boardOpen, .boardExtend, .boardToggle, .boardClear, .messageNewline, .slashMove, .slashAccept,
      .messageEscape, .pasteImage, .sidebarToTerminal, .terminalNewline:
      .handler
    default: .menu
    }
  }

  var area: ShortcutArea {
    switch self {
    case .showInbox, .showBoard, .showIssues, .showLoops, .filterSessions, .back, .forward, .showRecentPlaces,
      .nextNeedingYou, .nextSession, .previousSession, .searchSessions, .quickAsk, .focusList, .keyboardShortcuts,
      .listNext, .listPrevious, .listOpen, .searchResultMove, .searchResultOpen, .searchClose:
      .navigation
    case .newSession, .newSessionInGroup, .newConversation, .importSessions, .openManager, .openOperatorTranscript,
      .stopClaude, .resumeClaude, .markDone, .acknowledge, .deleteSelection, .startIssueSession, .startFollowup,
      .reloadImport:
      .sessions
    case .primaryAction, .decisionNext, .decisionPrevious, .decisionReview, .decisionOther, .decisionSkip,
      .decisionAsk, .decisionPick:
      .inboxDecisions
    case .newGroup, .boardMove, .boardOpen, .boardExtend, .boardToggle, .boardClear: .board
    case .messageClaude, .sendMessage, .messageNewline, .slashMove, .slashAccept, .messageEscape, .pasteImage:
      .messageField
    case .focusTerminal, .sidebarToTerminal, .terminalNewline: .terminal
    }
  }

  /// What the overlay says the shortcut does.
  var title: String {
    switch self {
    case .showInbox: "Show the Inbox"
    case .showBoard: "Show the Board"
    case .showIssues: "Show Issues"
    case .showLoops: "Show Loops"
    case .filterSessions: "Filter sessions by org or group"
    case .back: "Back"
    case .forward: "Forward"
    case .showRecentPlaces: "Show recent places"
    case .nextNeedingYou: "Next session that needs you"
    case .nextSession: "Next session"
    case .previousSession: "Previous session"
    case .searchSessions: "Search sessions"
    case .quickAsk: "Ask Switchboard"
    case .focusList: "Move focus to the list"
    case .keyboardShortcuts: "Show keyboard shortcuts"
    case .listNext: "Next item in a list"
    case .listPrevious: "Previous item in a list"
    case .listOpen: "Open the selected item"
    case .searchResultMove: "Move through search results"
    case .searchResultOpen: "Open the search result"
    case .searchClose: "Close search"
    case .newSession: "New session"
    case .newSessionInGroup: "New session in the selected group"
    case .newConversation: "New Manager conversation"
    case .importSessions: "Import sessions"
    case .openManager: "Open the Manager"
    case .openOperatorTranscript: "Open the operator transcript"
    case .stopClaude: "Stop Claude"
    case .resumeClaude: "Resume Claude"
    case .markDone: "Mark done or not done"
    case .acknowledge: "Acknowledge"
    case .deleteSelection: "Delete the selected sessions"
    case .startIssueSession: "Start a session on the issue"
    case .startFollowup: "Start the follow-up"
    case .reloadImport: "Reload sessions to import"
    case .primaryAction: "Choose the highlighted answer, go to the next decision, or submit"
    case .decisionNext: "Next decision"
    case .decisionPrevious: "Previous decision"
    case .decisionReview: "Review every answer"
    case .decisionOther: "Write another answer"
    case .decisionSkip: "Skip the decision"
    case .decisionAsk: "Ask about the decision"
    case .decisionPick: "Pick an option"
    case .newGroup: "New group"
    case .boardMove: "Move between cards"
    case .boardOpen: "Open the card"
    case .boardExtend: "Extend the selection"
    case .boardToggle: "Select or deselect the card"
    case .boardClear: "Clear the selection"
    case .messageClaude: "Message Claude"
    case .sendMessage: "Send the message"
    case .messageNewline: "Insert a new line"
    case .slashMove: "Move through slash commands"
    case .slashAccept: "Accept the slash command"
    case .messageEscape: "Close completions, hide an empty field, or clear it (twice)"
    case .pasteImage: "Paste an image"
    case .focusTerminal: "Move focus to the terminal"
    case .sidebarToTerminal: "Move focus from the sidebar to the terminal"
    case .terminalNewline: "Insert a new line in Claude's prompt"
    }
  }

  /// Every title the entry's menu item can show. An entry that ends in "…" matches a title that starts with the
  /// rest, for the item whose title names the selected group. Empty for entries that no menu item carries.
  var menuTitles: [String] {
    switch self {
    case .showInbox: ["Show Inbox"]
    case .showBoard: ["Show Board"]
    case .showIssues: ["Show Issues"]
    case .showLoops: ["Show Loops"]
    case .filterSessions: ["Filter Sessions…"]
    case .back: ["Back"]
    case .forward: ["Forward"]
    case .showRecentPlaces: ["Show Recent Places"]
    case .nextNeedingYou: ["Next Needing You"]
    case .nextSession: ["Next Session"]
    case .previousSession: ["Previous Session"]
    case .searchSessions: ["Search Sessions…"]
    case .quickAsk: ["Ask Switchboard…"]
    case .focusList: ["Move Focus to List"]
    case .keyboardShortcuts: ["Keyboard Shortcuts"]
    case .newSession: ["New Session…"]
    case .newSessionInGroup: ["New Session in …"]
    case .newConversation: ["New Conversation"]
    case .importSessions: ["Import Sessions…"]
    case .openManager: ["Open Manager"]
    case .openOperatorTranscript: ["Open Operator Transcript"]
    case .stopClaude: ["Stop Claude"]
    case .resumeClaude: ["Resume Claude"]
    case .markDone: ["Mark Done", "Mark Not Done"]
    case .acknowledge: ["Acknowledge", "Undo Acknowledge"]
    case .newGroup: ["New Group"]
    case .messageClaude: ["Message Claude"]
    case .focusTerminal: ["Move Focus to Terminal"]
    default: []
    }
  }

  /// The keys the overlay shows, in order. For a `.menu`, `.menuAlternate`, or `.view` entry, the first is
  /// the binding.
  var keys: [KeyboardShortcut] {
    switch self {
    case .showInbox: [Self.command("1")]
    case .showBoard: [Self.command("2")]
    case .showIssues: [Self.command("3")]
    case .showLoops: [Self.command("4")]
    case .filterSessions: [Self.command("o", .shift)]
    // An unshifted ⌘[ sends "[", so it can't match Previous Session's "{".
    case .back: [Self.command("[")]
    case .forward: [Self.command("]")]
    case .showRecentPlaces: [Self.command("y")]
    case .nextNeedingYou: [Self.command("j")]
    // A US keyboard sends ⇧⌘] as "}" with ⌘ and ⇧. A menu item that stores "]" with ⇧⌘ does not match that
    // event, so these store the shifted characters, as Safari's Show Next Tab does.
    case .nextSession: [Self.command("}")]
    case .previousSession: [Self.command("{")]
    case .searchSessions: [Self.command("k")]
    case .quickAsk: [Self.command("k", .shift)]
    case .focusList: [Self.command("l")]
    // A bare "?" on a menu item would take the character from every text field, and ⇧⌘/ is the system's
    // Help search.
    case .keyboardShortcuts: [Self.command("/"), KeyboardShortcut("?", modifiers: [])]
    case .listNext: [KeyboardShortcut("j", modifiers: []), KeyboardShortcut(.downArrow, modifiers: [])]
    case .listPrevious: [KeyboardShortcut("k", modifiers: []), KeyboardShortcut(.upArrow, modifiers: [])]
    case .listOpen, .boardOpen, .searchResultOpen: [KeyboardShortcut(.return, modifiers: [])]
    case .searchResultMove, .slashMove:
      [KeyboardShortcut(.downArrow, modifiers: []), KeyboardShortcut(.upArrow, modifiers: [])]
    case .searchClose, .boardClear, .messageEscape: [KeyboardShortcut(.escape, modifiers: [])]
    case .newSession: [Self.command("n")]
    case .newSessionInGroup: [Self.command("n", .shift)]
    // ⌘T is Move Focus to Terminal, so a new conversation takes ⌥⌘N.
    case .newConversation: [Self.command("n", .option)]
    case .importSessions: [Self.command("i", .shift)]
    case .openManager: [Self.command("m", .shift)]
    case .openOperatorTranscript: [Self.command("m", [.shift, .option])]
    case .stopClaude: [Self.command(".")]
    case .resumeClaude: [Self.command("r", .shift)]
    case .markDone: [Self.command("d", .shift)]
    case .acknowledge: [Self.command("a", .shift)]
    case .deleteSelection: [KeyboardShortcut(.delete, modifiers: .command)]
    case .startIssueSession, .startFollowup: [KeyboardShortcut(.return, modifiers: .command)]
    case .sendMessage: [KeyboardShortcut(.return, modifiers: .command), KeyboardShortcut(.return, modifiers: [])]
    case .reloadImport: [Self.command("r")]
    case .primaryAction: [KeyboardShortcut(.return, modifiers: [.command, .shift])]
    case .decisionNext: [KeyboardShortcut("]", modifiers: []), KeyboardShortcut(.rightArrow, modifiers: [])]
    case .decisionPrevious: [KeyboardShortcut("[", modifiers: []), KeyboardShortcut(.leftArrow, modifiers: [])]
    case .decisionReview: [KeyboardShortcut("r", modifiers: [])]
    case .decisionOther: [KeyboardShortcut("o", modifiers: [])]
    case .decisionSkip: [KeyboardShortcut("s", modifiers: [])]
    case .decisionAsk: [KeyboardShortcut("a", modifiers: []), KeyboardShortcut("/", modifiers: [])]
    case .decisionPick: (1...9).map { KeyboardShortcut(KeyEquivalent(Character(String($0))), modifiers: []) }
    case .newGroup: [Self.command("g", .shift)]
    case .boardMove: [.upArrow, .downArrow, .leftArrow, .rightArrow].map { KeyboardShortcut($0, modifiers: []) }
    case .boardExtend: [.upArrow, .downArrow, .leftArrow, .rightArrow].map { KeyboardShortcut($0, modifiers: .shift) }
    case .boardToggle: [KeyboardShortcut(.space, modifiers: [])]
    // A focused terminal passes only ⌘ keys to the menu bar, and ⌘E is the system's Use Selection for Find.
    case .messageClaude: [Self.command("e", .shift)]
    case .messageNewline: [KeyboardShortcut(.return, modifiers: .shift), KeyboardShortcut(.return, modifiers: .option)]
    case .slashAccept: [KeyboardShortcut(.tab, modifiers: [])]
    case .pasteImage: [Self.command("v")]
    case .focusTerminal: [Self.command("t")]
    case .sidebarToTerminal: [KeyboardShortcut(.return, modifiers: [])]
    case .terminalNewline: [KeyboardShortcut(.return, modifiers: .shift)]
    }
  }

  /// What the overlay shows in place of the keys, for a run of keys that reads better as a range.
  var label: String? {
    switch self {
    case .decisionPick: "1 to 9"
    case .boardMove: "← → ↑ ↓"
    case .boardExtend: "⇧ ← → ↑ ↓"
    default: nil
    }
  }

  /// Whether the app binds the entry on a Mac whose macOS major version is `macOSMajor`. macOS 14 has no
  /// alternate menu items, so Open Operator Transcript has no key there.
  func isAvailable(macOSMajor: Int) -> Bool { self != .openOperatorTranscript || macOSMajor >= 15 }

  /// The entries that the app binds on this Mac, in list order.
  static var available: [AppShortcut] {
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return allCases.filter { $0.isAvailable(macOSMajor: major) }
  }

  /// The key that a `.menu` or `.view` entry binds.
  var binding: KeyboardShortcut {
    precondition(kind == .menu || kind == .view, "\(self) is not bound by a menu item or a view")
    return keys[0]
  }

  /// The keys as the overlay and help tags show them, such as "⇧⌘]" or "⌘/ or ?".
  var glyphs: String { label ?? keys.map(Self.glyphs).joined(separator: " or ") }

  /// A help tag that ends with the shortcut, such as "Back (⌘[)".
  func help(_ text: String) -> String { "\(text) (\(glyphs))" }

  private static func command(_ key: Character, _ more: EventModifiers = []) -> KeyboardShortcut {
    KeyboardShortcut(KeyEquivalent(key), modifiers: more.union(.command))
  }

  /// A shortcut as the key a US keyboard types: AppKit can store ⇧⌘] as ⌘}, and both name one key press.
  struct Press: Hashable {
    var key: Character
    var modifiers: EventModifiers

    init(_ key: Character, _ modifiers: EventModifiers = .command) {
      self.modifiers = NavKey.modifiers(modifiers)
      switch key {
      case "}":
        self.key = "]"
        self.modifiers.insert(.shift)
      case "{":
        self.key = "["
        self.modifiers.insert(.shift)
      default:
        self.key = Character(key.lowercased())
      }
    }

    init(_ shortcut: KeyboardShortcut) { self.init(shortcut.key.character, shortcut.modifiers) }

    static func == (a: Press, b: Press) -> Bool { a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue }
    func hash(into hasher: inout Hasher) {
      hasher.combine(key)
      hasher.combine(modifiers.rawValue)
    }
  }

  /// The keys that AppKit and SwiftUI put in every Mac app's menus, such as Quit, Close, and the Edit menu, and
  /// ⌘P, which SwiftUI may add to the File menu. No entry may take one.
  static let systemPresses: Set<Press> = [
    Press("q"), Press("h"), Press("h", [.command, .option]), Press(","), Press("w"), Press("w", [.command, .option]),
    Press("m"), Press("m", [.command, .option]), Press("f", [.command, .control]), Press("z"),
    Press("z", [.command, .shift]), Press("x"), Press("c"), Press("v"), Press("v", [.command, .option, .shift]),
    Press("a"), Press("p"), Press("e"), Press("e", [.command, .control]), Press(" ", [.command, .control]),
    Press("/", [.command, .shift]),
  ]

  /// The entry that names a menu item titled `title`: an exact title first, then the longest title that ends in "…"
  /// and starts the item's title, so "New Session in Work…" finds the group item and "New Session…" finds New Session.
  static func entry(menuTitle title: String) -> AppShortcut? {
    if let exact = allCases.first(where: { $0.menuTitles.contains(title) }) { return exact }
    return allCases.flatMap { entry in entry.menuTitles.map { (entry, $0) } }
      .filter { $0.1.hasSuffix("…") && title.hasPrefix(String($0.1.dropLast())) }
      .max { $0.1.count < $1.1.count }?.0
  }

  static func glyphs(_ shortcut: KeyboardShortcut) -> String {
    let press = Press(shortcut)
    let order: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    return order.filter { press.modifiers.contains($0.0) }.map(\.1).joined() + keyName(press.key)
  }

  private static func keyName(_ key: Character) -> String {
    switch key {
    case KeyEquivalent.return.character: "↩"
    case KeyEquivalent.escape.character: "⎋"
    case KeyEquivalent.delete.character: "⌫"
    case KeyEquivalent.tab.character: "⇥"
    case KeyEquivalent.space.character: "Space"
    case KeyEquivalent.upArrow.character: "↑"
    case KeyEquivalent.downArrow.character: "↓"
    case KeyEquivalent.leftArrow.character: "←"
    case KeyEquivalent.rightArrow.character: "→"
    default: key.uppercased()
    }
  }
}

extension View {
  /// Binds the key of a `.menu` or `.view` entry. It has its own name so the source scan in `AppShortcutTests`
  /// can tell a listed binding from a raw `keyboardShortcut` call.
  /// A nil `entry` binds no key.
  func shortcut(_ entry: AppShortcut?) -> some View { keyboardShortcut(entry?.binding) }
}
