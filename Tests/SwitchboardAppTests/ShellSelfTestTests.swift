import AppKit
import SwiftTerm
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct ShellSelfTestClickPoint {
  // The pane's label starts at the column's edge, which is the padded view's edge, not the inset terminal's.
  @Test func theClickIsMeasuredFromThePaddedPanesEdge() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let column = NSRect(x: 100, y: 50, width: 400, height: 300)
    let padded = PaddedTerminalView(frame: column)
    root.addSubview(padded)

    let point = ShellSelfTest.labelPoint(of: padded.terminal, offset: 6)

    let buttonX = column.minX + SessionView.labelPadding + SessionView.labelWidth + SessionView.labelSpacing
    #expect(point == NSPoint(x: buttonX + 6, y: column.maxY + 9))
  }

  @Test func aTerminalOutsideAPaddedViewHasNoClickPoint() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let terminal = ThemedTerminalView(frame: NSRect(x: 100, y: 50, width: 400, height: 300))
    root.addSubview(terminal)

    #expect(ShellSelfTest.labelPoint(of: terminal, offset: 6) == nil)
  }
}
