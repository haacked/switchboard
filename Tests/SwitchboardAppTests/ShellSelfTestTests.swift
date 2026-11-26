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

/// `anchors` reports an anchor as `in` when its frame lies inside its window's content bounds and inside the
/// container anchor's frame, with 1 pt of tolerance.
@MainActor
@Suite struct ShellSelfTestAnchorPlacement {
  static let window = NSRect(x: 0, y: 0, width: 1024, height: 700)
  static let container = NSRect(x: 700, y: 0, width: 240, height: 700)
  static let inside = NSRect(x: 710, y: 100, width: 200, height: 30)

  enum Edge: CaseIterable, Sendable { case left, right, bottom, top }

  /// The row moved `by` points past the container's `edge`.
  static func row(past edge: Edge, of bounds: NSRect, by points: CGFloat) -> NSRect {
    var r = inside
    switch edge {
    case .left: r.origin.x = bounds.minX - points
    case .right: r.origin.x = bounds.maxX - r.width + points
    case .bottom: r.origin.y = bounds.minY - points
    case .top: r.origin.y = bounds.maxY - r.height + points
    }
    return r
  }

  @Test func anAnchorInsideTheContainerIsIn() {
    #expect(ShellSelfTest.anchorIsInside(Self.inside, window: Self.window, container: Self.container))
  }

  @Test func anAnchorInsideTheWindowWithoutAContainerIsIn() {
    #expect(ShellSelfTest.anchorIsInside(Self.inside, window: Self.window, container: nil))
  }

  @Test(arguments: Edge.allCases, [0, 0.5, 1] as [CGFloat])
  func anAnchorPastTheContainersEdgeByAtMostOnePointIsIn(_ edge: Edge, _ points: CGFloat) {
    let frame = Self.row(past: edge, of: Self.container, by: points)

    #expect(ShellSelfTest.anchorIsInside(frame, window: Self.window, container: Self.container))
  }

  @Test(arguments: Edge.allCases, [1.5, 2, 40] as [CGFloat])
  func anAnchorPastTheContainersEdgeByMoreThanOnePointIsOut(_ edge: Edge, _ points: CGFloat) {
    let frame = Self.row(past: edge, of: Self.container, by: points)

    #expect(!ShellSelfTest.anchorIsInside(frame, window: Self.window, container: Self.container))
  }

  /// The side panel lies inside the window, so a row past the panel's left edge is still inside the window.
  @Test func anAnchorOutsideTheContainerButInsideTheWindowIsOut() throws {
    let frame = Self.row(past: .left, of: Self.container, by: 20)
    try #require(Self.window.contains(frame))

    #expect(!ShellSelfTest.anchorIsInside(frame, window: Self.window, container: Self.container))
  }

  @Test(arguments: Edge.allCases, [1.5, 40] as [CGFloat])
  func anAnchorPastTheWindowsEdgeByMoreThanOnePointIsOutWithoutAContainer(_ edge: Edge, _ points: CGFloat) {
    let frame = Self.row(past: edge, of: Self.window, by: points)

    #expect(!ShellSelfTest.anchorIsInside(frame, window: Self.window, container: nil))
  }

  @Test(arguments: Edge.allCases)
  func anAnchorPastTheWindowsEdgeByOnePointIsInWithoutAContainer(_ edge: Edge) {
    let frame = Self.row(past: edge, of: Self.window, by: 1)

    #expect(ShellSelfTest.anchorIsInside(frame, window: Self.window, container: nil))
  }

  /// A container that reaches past the window does not make an anchor outside the window count as in.
  @Test func anAnchorInsideTheContainerButPastTheWindowIsOut() {
    let wide = NSRect(x: 900, y: 0, width: 240, height: 700)
    let frame = NSRect(x: 1030, y: 100, width: 100, height: 30)

    #expect(!ShellSelfTest.anchorIsInside(frame, window: Self.window, container: wide))
  }
}

/// `toolbar` reports the window toolbar's items in order, each as `<title>:in` when it is in the toolbar's visible
/// items or `<title>:out` when the overflow menu holds it, joined by commas. Items with no title are left out.
@MainActor
@Suite struct ShellSelfTestToolbarReport {
  @Test func reportsEveryVisibleItemAsInInOrder() {
    let report = ShellSelfTest.toolbarReport([
      (title: "Back", visible: true), (title: "Stop Claude", visible: true), (title: "New Session", visible: true),
    ])

    #expect(report == "Back:in,Stop Claude:in,New Session:in")
  }

  @Test func reportsAnItemInTheOverflowMenuAsOut() {
    let report = ShellSelfTest.toolbarReport([
      (title: "Stop Claude", visible: true), (title: "Delete…", visible: false), (title: "New Session", visible: true),
    ])

    #expect(report == "Stop Claude:in,Delete…:out,New Session:in")
  }

  /// A spacer has no title, so it never shows in the report.
  @Test func leavesOutAnItemWithNoTitle() {
    let report = ShellSelfTest.toolbarReport([
      (title: "Back", visible: true), (title: nil, visible: true), (title: "New Session", visible: false),
    ])

    #expect(report == "Back:in,New Session:out")
  }

  @Test(arguments: [true, false])
  func leavesOutAnItemWithAnEmptyTitle(_ visible: Bool) {
    let report = ShellSelfTest.toolbarReport([(title: "", visible: visible), (title: "Notes", visible: true)])

    #expect(report == "Notes:in")
  }

  @Test func reportsNothingForAToolbarWithNoTitledItems() {
    #expect(ShellSelfTest.toolbarReport([(title: nil, visible: true), (title: nil, visible: false)]) == "")
  }

  @Test func reportsNothingForAnEmptyToolbar() {
    #expect(ShellSelfTest.toolbarReport([]) == "")
  }
}
