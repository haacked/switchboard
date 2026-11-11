import SwiftUI
import Testing

@testable import SwitchboardApp

@Suite struct ReturnKeyTests {
  /// Every combination of Shift, Command, Option, and Control.
  static let allModifiers: [EventModifiers] = (0..<16).map { bits in
    [EventModifiers.shift, .command, .option, .control].enumerated()
      .filter { bits & (1 << $0.offset) != 0 }
      .reduce(into: EventModifiers()) { $0.insert($1.element) }
  }

  @Test func returnAloneSends() {
    #expect(ReturnKey.action(modifiers: [], composing: false) == .send)
  }

  @Test func shiftReturnInsertsANewLine() {
    #expect(ReturnKey.action(modifiers: .shift, composing: false) == .newline)
  }

  @Test func capsLockChangesNothing() {
    #expect(ReturnKey.action(modifiers: .capsLock, composing: false) == .send)
    #expect(ReturnKey.action(modifiers: [.shift, .capsLock], composing: false) == .newline)
  }

  /// The input method commits its marked text on Return. The key must not
  /// also send or add a line.
  @Test(arguments: allModifiers)
  func returnWhileComposingIsLeftToTheField(modifiers: EventModifiers) {
    #expect(ReturnKey.action(modifiers: modifiers, composing: true) == nil)
  }

  @Test(arguments: allModifiers.filter { !$0.isDisjoint(with: [.command, .option, .control]) })
  func returnWithCommandOptionOrControlIsLeftToTheField(modifiers: EventModifiers) {
    #expect(ReturnKey.action(modifiers: modifiers, composing: false) == nil)
  }
}
