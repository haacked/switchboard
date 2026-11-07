import AppKit
import SwiftTerm
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct PaddedTerminalViewLayout {
  let padding = PaddedTerminalView.horizontalPadding

  /// The width of the terminal's whole columns. SwiftTerm keeps its column count private.
  func columnsWidth(_ view: TerminalView) -> CGFloat { view.getOptimalFrameSize().width }

  @Test func resizingKeepsTheTerminalInsetOnBothSides() {
    let view = PaddedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

    view.setFrameSize(NSSize(width: 640, height: 300))

    let frame = view.terminal.convert(view.terminal.bounds, to: view)
    #expect(frame == NSRect(x: padding, y: 0, width: 640 - 2 * padding, height: 300))
  }

  // SwiftTerm builds its mouse tracking area from its frame, which must start at its parent's origin.
  @Test func theTerminalSitsAtItsParentsOrigin() {
    let view = PaddedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

    #expect(view.terminal.frame.origin == .zero)
  }

  @Test func aPaneNarrowerThanItsPaddingGivesTheTerminalAnEmptyFrame() {
    let view = PaddedTerminalView(frame: .zero)

    #expect(view.terminal.frame == .zero)
  }

  @Test(arguments: [2.0, 200.0, 398.0])
  func aHitInThePaddingGoesToTheTerminal(x: Double) {
    let view = PaddedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

    #expect(view.hitTest(NSPoint(x: x, y: 100)) === view.terminal)
  }

  // A bare terminal as wide as the padded one shows the column count tmux should see. Text would clip at
  // the right edge if the padded terminal reported the full width's columns.
  @Test(arguments: [400.0, 641.0, 1003.0])
  func columnsComeFromThePaddedWidth(width: Double) {
    let view = PaddedTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let narrow = ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: width - 2 * padding, height: 200))
    let full = ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: width, height: 200))

    view.setFrameSize(NSSize(width: width, height: 200))

    #expect(columnsWidth(view.terminal) == columnsWidth(narrow))
    #expect(columnsWidth(view.terminal) < columnsWidth(full))
  }

  @Test(arguments: Mode.allCases)
  func paddingMatchesTheTerminalBackground(mode: Mode) {
    let view = PaddedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.appearance = mode.other.appearance

    view.appearance = mode.appearance

    let padding = RGB(NSColor(cgColor: view.layer!.backgroundColor!)!)
    let terminal = RGB(NSColor(cgColor: view.terminal.layer!.backgroundColor!)!)
    #expect(padding.isClose(to: RGB(TerminalTheme(appearance: mode.appearance).background)))
    #expect(padding.isClose(to: terminal))
  }
}
