import AppKit
import Testing

@testable import SwitchboardApp

@Suite struct MarkedTextTests {
  @Test func startsEmptyWithNoMarkedRange() {
    let marked = MarkedText()
    #expect(!marked.hasMarkedText)
    #expect(marked.markedRange.location == NSNotFound)
  }

  @Test func acceptsStringAndAttributedString() {
    var marked = MarkedText()
    let first = marked.set("´")
    #expect(first)
    #expect(marked.text == "´")
    let second = marked.set(NSAttributedString(string: "にほん"))
    #expect(second)
    #expect(marked.text == "にほん")
  }

  @Test func rangeCountsUTF16Units() {
    var marked = MarkedText()
    marked.set("a😀")
    #expect(marked.markedRange == NSRange(location: 0, length: 3))
  }

  @Test func ignoresOtherTypesAndKeepsWhatWasMarked() {
    var marked = MarkedText()
    marked.set("ab")
    let accepted = marked.set(42)
    #expect(!accepted)
    #expect(marked.text == "ab")
  }

  @Test func clearEndsTheComposition() {
    var marked = MarkedText()
    marked.set("ab")
    marked.clear()
    #expect(!marked.hasMarkedText)
  }

  @Test func settingEmptyTextEndsTheComposition() {
    var marked = MarkedText()
    marked.set("ab")
    marked.set("")
    #expect(!marked.hasMarkedText)
  }
}

@Suite struct KeyDispatchTests {
  @Test func plainKeySendsItsTypedText() {
    let dispatch = KeyDispatch(committed: [], typed: "a", markedBefore: false, markedAfter: false)
    #expect(dispatch.texts == ["a"])
    #expect(!dispatch.composing)
  }

  @Test func deadKeyStartsAComposition() {
    let dispatch = KeyDispatch(committed: [], typed: "´", markedBefore: false, markedAfter: true)
    #expect(dispatch.composing)
  }

  @Test func deadKeyThenLetterSendsOnlyTheComposedCharacter() {
    let dispatch = KeyDispatch(committed: ["é"], typed: "e", markedBefore: true, markedAfter: false)
    #expect(dispatch.texts == ["é"])
    #expect(!dispatch.composing)
  }

  @Test func keyThatCancelsACompositionIsStillComposing() {
    let dispatch = KeyDispatch(committed: [], typed: nil, markedBefore: true, markedAfter: false)
    #expect(dispatch.composing)
  }

  @Test func eachCommittedStringIsSent() {
    let dispatch = KeyDispatch(committed: ["日", "本"], typed: nil, markedBefore: true, markedAfter: false)
    #expect(dispatch.texts == ["日", "本"])
  }

  @Test func committedControlAndFunctionKeyTextIsNotSentAsText() {
    for text in ["\r", "\u{1B}", "\t", "\u{F700}", "\u{F72B}"] {
      let dispatch = KeyDispatch(committed: [text], typed: nil, markedBefore: false, markedAfter: false)
      #expect(dispatch.texts == [nil], "\(text.unicodeScalars.map(\.value))")
    }
  }

  @Test func sendableKeepsDeleteAndMultiScalarText() {
    #expect(KeyDispatch.sendable("\u{7F}") == "\u{7F}")
    #expect(KeyDispatch.sendable("e\u{301}") == "e\u{301}")
    #expect(KeyDispatch.sendable("") == nil)
    #expect(KeyDispatch.sendable(nil) == nil)
  }

  @Test func typedTextAppliesTheKeyRules() {
    #expect(KeyDispatch.typedText("a", withoutControl: { "x" }) == "a")
    #expect(KeyDispatch.typedText("\u{03}", withoutControl: { "c" }) == "c")
    #expect(KeyDispatch.typedText("\u{F701}", withoutControl: { "x" }) == nil)
    #expect(KeyDispatch.typedText("", withoutControl: { "x" }) == nil)
    #expect(KeyDispatch.typedText(nil, withoutControl: { "x" }) == nil)
    #expect(KeyDispatch.typedText("é", withoutControl: { "x" }) == "é")
  }
}

@Suite struct ModifierKeyTests {
  // Left and right device bits from IOLLEvent.h.
  let leftShift: UInt = 0x2
  let rightShift: UInt = 0x4

  func flags(_ base: NSEvent.ModifierFlags, _ bits: UInt = 0) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: base.rawValue | bits)
  }

  @Test func onlyModifierKeyCodesAreModifierKeys() {
    for code in [UInt16(0x38), 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36, 0x39] {
      #expect(ModifierKey(keyCode: code) != nil)
    }
    for code in [UInt16(0), 0x31, 0x24, 0x3F] {
      #expect(ModifierKey(keyCode: code) == nil)
    }
    #expect(ModifierKey.action(keyCode: 0, flags: .shift) == nil)
  }

  @Test func shiftPressedAndReleased() {
    #expect(ModifierKey.action(keyCode: 0x38, flags: flags(.shift, leftShift)) == .press)
    #expect(ModifierKey.action(keyCode: 0x38, flags: []) == .release)
    #expect(ModifierKey.action(keyCode: 0x3C, flags: flags(.shift, rightShift)) == .press)
    #expect(ModifierKey.action(keyCode: 0x3C, flags: []) == .release)
  }

  @Test func eventsWithNoDeviceBitsCountAsPresses() {
    for (code, flag) in [
      (UInt16(0x38), NSEvent.ModifierFlags.shift), (0x3C, .shift), (0x3B, .control), (0x3E, .control),
      (0x3A, .option), (0x3D, .option), (0x37, .command), (0x36, .command), (0x39, .capsLock),
    ] {
      #expect(ModifierKey.action(keyCode: code, flags: flag) == .press, "key code \(code)")
    }
  }

  @Test func releasingOneShiftWhileTheOtherIsHeldIsARelease() {
    let rightHeld = flags(.shift, rightShift)
    #expect(ModifierKey.action(keyCode: 0x38, flags: rightHeld) == .release)
    let leftHeld = flags(.shift, leftShift)
    #expect(ModifierKey.action(keyCode: 0x3C, flags: leftHeld) == .release)
  }

  @Test func pressingASecondShiftIsAPress() {
    let both = flags(.shift, leftShift | rightShift)
    #expect(ModifierKey.action(keyCode: 0x38, flags: both) == .press)
    #expect(ModifierKey.action(keyCode: 0x3C, flags: both) == .press)
  }

  @Test func sidedKeysOfEveryModifierFollowTheirDeviceBits() {
    // (left code, right code, flag, left bit, right bit)
    let table: [(UInt16, UInt16, NSEvent.ModifierFlags, UInt, UInt)] = [
      (0x38, 0x3C, .shift, 0x2, 0x4), (0x3B, 0x3E, .control, 0x1, 0x2000),
      (0x3A, 0x3D, .option, 0x20, 0x40), (0x37, 0x36, .command, 0x8, 0x10),
    ]
    for (leftCode, rightCode, flag, left, right) in table {
      #expect(ModifierKey.action(keyCode: leftCode, flags: flags(flag, right)) == .release)
      #expect(ModifierKey.action(keyCode: rightCode, flags: flags(flag, left)) == .release)
      #expect(ModifierKey.action(keyCode: leftCode, flags: flags(flag, left)) == .press)
      #expect(ModifierKey.action(keyCode: rightCode, flags: flags(flag, right)) == .press)
    }
  }

  @Test func capsLockFollowsItsFlag() {
    #expect(ModifierKey.action(keyCode: 0x39, flags: .capsLock) == .press)
    #expect(ModifierKey.action(keyCode: 0x39, flags: []) == .release)
  }
}

@Suite struct KeyTranslationTests {
  @Test func optionAsAltRemovesOptionAndKeepsTheRest() {
    let result = KeyTranslation.apply(to: [.option, .shift, .function], keeping: [.shift])
    #expect(result == [.shift, .function])
  }

  @Test func keptModifiersAreAddedBack() {
    #expect(KeyTranslation.apply(to: [], keeping: [.option]) == [.option])
  }

  @Test func nothingChangesWhenTranslationMatches() {
    let flags: NSEvent.ModifierFlags = [.control, .numericPad]
    #expect(KeyTranslation.apply(to: flags, keeping: [.control]) == flags)
  }
}

@Suite struct KeyEquivalentTests {
  @Test func controlReturnAndControlSlashGoToTheTerminal() {
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "\r", flags: .control) == "\r")
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "\r", flags: [.control, .shift]) == "\r")
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "/", flags: .control) == "_")
  }

  @Test func otherCombinationsTakeTheNormalPath() {
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "\r", flags: []) == nil)
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "\r", flags: [.control, .command]) == nil)
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "/", flags: [.control, .shift]) == nil)
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "/", flags: [.control, .option]) == nil)
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "/", flags: .command) == nil)
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: "j", flags: .control) == nil)
    #expect(KeyEquivalent.terminalCharacters(charactersIgnoringModifiers: nil, flags: .control) == nil)
  }
}

@Suite struct IMEGeometryTests {
  @Test func bottomEdgeOfTheCellBecomesTheRectangleOrigin() {
    // A 600 pt tall view, a 20 pt cell whose bottom edge is 100 pt from the top.
    let rect = IMEGeometry.viewRect(x: 30, y: 100, width: 10, height: 20, viewHeight: 600)
    #expect(rect == NSRect(x: 30, y: 500, width: 10, height: 20))
    // The cell spans 80 to 100 pt from the top, which is 500 to 520 from the bottom.
    #expect(rect.maxY == 520)
  }
}
