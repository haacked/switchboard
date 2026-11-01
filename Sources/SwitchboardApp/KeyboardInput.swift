import AppKit

// The parts of the Ghostty pane's keyboard handling that need neither libghostty nor a window, so
// unit tests can cover them. GhosttySurfaceView+Input.swift connects them to AppKit and libghostty.

/// The text an input method is composing and has not committed yet.
struct MarkedText: Equatable {
  private(set) var text = ""

  var hasMarkedText: Bool { !text.isEmpty }

  /// AppKit's "no marked text" range is a location of NSNotFound.
  var markedRange: NSRange {
    hasMarkedText ? NSRange(location: 0, length: text.utf16.count) : NSRange(location: NSNotFound, length: 0)
  }

  /// Replaces the marked text. Returns false for a value that is neither a String nor an NSAttributedString.
  @discardableResult
  mutating func set(_ value: Any) -> Bool {
    guard let string = Self.string(from: value) else { return false }
    text = string
    return true
  }

  mutating func clear() { text = "" }

  static func string(from value: Any) -> String? {
    switch value {
    case let attributed as NSAttributedString: attributed.string
    case let string as String: string
    default: nil
    }
  }
}

/// What a key-down sends to the terminal once the input context has seen the event.
struct KeyDispatch: Equatable {
  /// One entry per key event to send. A nil entry is a key event with no text.
  var texts: [String?]
  /// True when the key only edited the composition, so the terminal must not encode it.
  var composing: Bool

  /// - Parameters:
  ///   - committed: the strings the input context inserted while handling the event.
  ///   - typed: the text the key types by itself, used when nothing was inserted.
  ///   - markedBefore: whether text was marked before the event.
  ///   - markedAfter: whether text is marked after the event.
  init(committed: [String], typed: String?, markedBefore: Bool, markedAfter: Bool) {
    if committed.isEmpty {
      // A key that ends a composition, such as Backspace in a Japanese IME, leaves no marked text
      // but must not delete a character in the terminal.
      texts = [typed]
      composing = markedBefore || markedAfter
    } else {
      // A committed string is the result of a composition, so it is never itself composing.
      texts = committed.map { Self.sendable($0) }
      composing = false
    }
  }

  /// The text of a key event as libghostty takes it. Control characters and the private-use range that
  /// AppKit uses for function keys are encoded by libghostty from the key, not from text.
  static func sendable(_ text: String?) -> String? {
    guard let text, let scalar = text.unicodeScalars.first else { return nil }
    if scalar.value < 0x20 { return nil }
    if text.unicodeScalars.count == 1, (0xF700...0xF8FF).contains(scalar.value) { return nil }
    return text
  }

  /// The text a key event types. A lone control character gives the text without Control applied,
  /// so Control-C types "c" and libghostty encodes the 0x03 from the modifiers.
  static func typedText(_ characters: String?, withoutControl: () -> String?) -> String? {
    guard let characters, let scalar = characters.unicodeScalars.first else { return nil }
    if characters.unicodeScalars.count == 1 {
      if scalar.value < 0x20 { return withoutControl() }
      if (0xF700...0xF8FF).contains(scalar.value) { return nil }
    }
    return characters
  }
}

/// The modifier keys, for the key events that AppKit sends as flagsChanged.
enum ModifierKey {
  case capsLock, shift, control, option, command

  enum Action: Equatable { case press, release }

  init?(keyCode: UInt16) {
    switch keyCode {
    case 0x39: self = .capsLock
    case 0x38, 0x3C: self = .shift
    case 0x3B, 0x3E: self = .control
    case 0x3A, 0x3D: self = .option
    case 0x37, 0x36: self = .command
    default: return nil
    }
  }

  var flag: NSEvent.ModifierFlags {
    switch self {
    case .capsLock: .capsLock
    case .shift: .shift
    case .control: .control
    case .option: .option
    case .command: .command
    }
  }

  /// The device-dependent bits of the flags (IOLLEvent.h NX_DEVICE*KEYMASK) for the left and right key.
  private var deviceBits: (left: UInt, right: UInt) {
    switch self {
    case .capsLock: (0, 0)
    case .shift: (0x2, 0x4)
    case .control: (0x1, 0x2000)
    case .option: (0x20, 0x40)
    case .command: (0x8, 0x10)
    }
  }

  private static let rightKeyCodes: Set<UInt16> = [0x3C, 0x3E, 0x3D, 0x36]

  /// Whether the flagsChanged event for `keyCode` pressed or released its key.
  ///
  /// With both Shift keys held, releasing one leaves the Shift flag set. The device bits tell which key
  /// went up. Events that carry no device bits at all, such as synthetic ones, count as a press when the
  /// flag is set.
  static func action(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Action? {
    guard let key = ModifierKey(keyCode: keyCode) else { return nil }
    guard flags.contains(key.flag) else { return .release }
    let (left, right) = key.deviceBits
    if left == 0 { return .press }
    let raw = flags.rawValue
    if raw & (left | right) == 0 { return .press }
    let mine = rightKeyCodes.contains(keyCode) ? right : left
    return raw & mine != 0 ? .press : .release
  }
}

enum KeyTranslation {
  /// `flags` with the shift, control, option, and command bits replaced by the ones libghostty keeps for
  /// text translation (its `macos-option-as-alt` setting removes Option, for one). Other bits stay, because
  /// some dead keys depend on them.
  static func apply(
    to flags: NSEvent.ModifierFlags, keeping kept: NSEvent.ModifierFlags
  ) -> NSEvent.ModifierFlags {
    var result = flags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if kept.contains(flag) { result.insert(flag) } else { result.remove(flag) }
    }
    return result
  }
}

enum IMEGeometry {
  /// libghostty reports the cursor cell with `y` as the cell's bottom edge, measured down from the top of the
  /// view. AppKit measures up from the bottom, so the same edge becomes the rectangle's origin and the
  /// rectangle extends upward over the cell.
  static func viewRect(x: Double, y: Double, width: Double, height: Double, viewHeight: Double) -> NSRect {
    NSRect(x: x, y: viewHeight - y, width: width, height: height)
  }
}

enum KeyEquivalent {
  /// AppKit offers Control-Return and Control-/ to the menu and the responder chain before keyDown, and
  /// answers with a context menu and a beep. This returns the characters of the key-down that the terminal
  /// should get instead (Control-/ is Control-_), or nil for a key that takes the normal path.
  static func terminalCharacters(charactersIgnoringModifiers: String?, flags: NSEvent.ModifierFlags) -> String? {
    guard flags.contains(.control), !flags.contains(.command) else { return nil }
    switch charactersIgnoringModifiers {
    case "\r": return "\r"
    case "/": return flags.isDisjoint(with: [.shift, .option]) ? "_" : nil
    default: return nil
    }
  }
}
