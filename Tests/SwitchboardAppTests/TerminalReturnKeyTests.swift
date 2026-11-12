import AppKit
import Testing

@testable import SwitchboardApp

@Suite struct TerminalReturnKeyTests {
  static let keypadEnter: UInt16 = 76

  /// Every combination of Shift, Control, Option, and Command.
  static let allModifiers: [NSEvent.ModifierFlags] = (0..<16).map { bits in
    [NSEvent.ModifierFlags.shift, .control, .option, .command].enumerated()
      .filter { bits & (1 << $0.offset) != 0 }
      .reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.element) }
  }

  /// Flags that must not change the result. A real key event also carries device-dependent bits below the
  /// device-independent mask. A left-Shift press sets 0x102.
  static let otherFlags: [NSEvent.ModifierFlags] = [
    [], .capsLock, .numericPad, .function, .help, NSEvent.ModifierFlags(rawValue: 0x102),
  ]

  static func sendsNewline(
    keyCode: UInt16 = TerminalReturnKey.returnKeyCode, _ modifiers: NSEvent.ModifierFlags, composing: Bool = false,
    kittyKeyboard: Bool = false
  ) -> Bool {
    TerminalReturnKey.sendsNewline(
      keyCode: keyCode, modifiers: modifiers, composing: composing, kittyKeyboard: kittyKeyboard)
  }

  @Test(arguments: allModifiers, otherFlags)
  func onlyShiftReturnSendsNewline(modifiers: NSEvent.ModifierFlags, extra: NSEvent.ModifierFlags) {
    #expect(Self.sendsNewline(modifiers.union(extra)) == (modifiers == .shift))
  }

  /// The input method commits its marked text on Return.
  @Test(arguments: allModifiers)
  func returnWhileComposingIsLeftToTheInputMethod(modifiers: NSEvent.ModifierFlags) {
    #expect(!Self.sendsNewline(modifiers, composing: true))
  }

  /// A program that turned on the kitty keyboard protocol reads Shift+Return from SwiftTerm's own encoding.
  @Test(arguments: allModifiers)
  func returnInKittyKeyboardModeIsLeftToTheTerminal(modifiers: NSEvent.ModifierFlags) {
    #expect(!Self.sendsNewline(modifiers, kittyKeyboard: true))
  }

  @Test(arguments: allModifiers)
  func keypadEnterIsLeftToTheTerminal(modifiers: NSEvent.ModifierFlags) {
    #expect(!Self.sendsNewline(keyCode: Self.keypadEnter, modifiers))
  }

  @Test(arguments: [UInt16(0), 48, 49, 51, 52, 53])
  func shiftWithAKeyOtherThanReturnIsLeftToTheTerminal(keyCode: UInt16) {
    #expect(!Self.sendsNewline(keyCode: keyCode, .shift))
  }
}
