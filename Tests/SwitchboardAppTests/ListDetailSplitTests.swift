import CoreGraphics
import SwiftUI
import Testing

@testable import SwitchboardApp

private typealias Split = ListDetailSplit<EmptyView, EmptyView>

/// The split's width in a 1024 pt window beside the sidebar at its ideal width.
@MainActor private let besideTheSidebar = 1024 - ContentView.sidebarIdealWidth

/// `ListDetailSplit.listWidth(stored:available:)` keeps the list between its bounds and leaves the detail at least
/// `detailMinWidth`, but never goes below `listMinWidth`.
@MainActor
@Suite struct ListDetailSplitListWidth {
  @Test(arguments: [200, 360, 420] as [CGFloat])
  func aStoredWidthInBoundsIsKept(_ stored: CGFloat) {
    #expect(Split.listWidth(stored: stored, available: 1024) == stored)
  }

  @Test(arguments: [-50, 0, 150] as [CGFloat])
  func aNarrowStoredWidthGivesTheMinimum(_ stored: CGFloat) {
    #expect(Split.listWidth(stored: stored, available: 1024) == Split.listMinWidth)
  }

  @Test(arguments: [1024, 4000] as [CGFloat])
  func aWideStoredWidthGivesTheMaximum(_ available: CGFloat) {
    #expect(Split.listWidth(stored: 500, available: available) == Split.listMaxWidth)
  }

  /// 600 - 1 - 340 leaves 259 for the list.
  @Test func aNarrowSplitShrinksTheListToKeepTheDetail() {
    #expect(Split.listWidth(stored: 360, available: 600) == 259)
  }

  /// At 1024 with the sidebar showing, a list over 383 would leave the detail under 340.
  @Test(arguments: [384, 420, 500] as [CGFloat])
  func aWideStoredWidthBesideTheSidebarLeavesTheDetailItsMinimum(_ stored: CGFloat) {
    #expect(Split.listWidth(stored: stored, available: besideTheSidebar) == 383)
  }

  /// Under 541 the split has no room for both minimums, and the list's minimum wins.
  @Test(arguments: [100, 400, 541] as [CGFloat])
  func aSplitTooNarrowForBothGivesTheMinimum(_ available: CGFloat) {
    #expect(Split.listWidth(stored: 500, available: available) == Split.listMinWidth)
  }

  /// A split that has not been measured applies only the list's own bounds.
  @Test(arguments: [(nil, 280), (150, 200), (360, 360), (500, 420)] as [(CGFloat?, CGFloat)])
  func anUnmeasuredSplitAppliesOnlyTheListsBounds(_ stored: CGFloat?, _ expected: CGFloat) {
    #expect(Split.listWidth(stored: stored, available: 0) == expected)
  }

  /// Every width that has room for both minimums keeps the list in its bounds and the detail at its minimum or more.
  @Test(
    arguments: [nil, -50, 0, 150, 200, 280, 383, 420, 500, 10_000] as [CGFloat?],
    [541, 600, 724, 783, 1024, 1440, 4000] as [CGFloat])
  func theClampHoldsEveryBound(_ stored: CGFloat?, _ available: CGFloat) {
    let width = Split.listWidth(stored: stored, available: available)

    #expect(width >= Split.listMinWidth)
    #expect(width <= Split.listMaxWidth)
    #expect(available - Split.dividerWidth - width >= Split.detailMinWidth)
  }
}

/// A split in a window, with its list width stored in a private defaults suite.
@MainActor
@Suite struct ListDetailSplitStoredWidth {
  static let key = "listWidth.test"

  /// Runs `body` with a defaults suite that holds `stored`, and removes the suite afterward.
  func withDefaults(stored: Double?, _ body: (UserDefaults) throws -> Void) throws {
    let name = "ListDetailSplitTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    if let stored { defaults.set(stored, forKey: Self.key) }
    try body(defaults)
  }

  func host(width: CGFloat, defaults: UserDefaults) -> HostedView {
    HostedView(
      ListDetailSplit(widthKey: Self.key) {
        Color.clear.accessibilityElement().accessibilityLabel("List")
      } detail: {
        Text("Detail")
      }
      .frame(width: width, height: 300)
      .defaultAppStorage(defaults))
  }

  func listWidth(_ hosted: HostedView) throws -> CGFloat {
    try #require(hosted.elements.first { $0.label == "List" }?.frame?.width)
  }

  @Test func aStoredWidthSetsTheList() throws {
    try withDefaults(stored: 360) { defaults in
      let width = try listWidth(host(width: 1024, defaults: defaults))
      #expect(width == 360)
    }
  }

  @Test func noStoredWidthGivesTheIdealWidth() throws {
    try withDefaults(stored: nil) { defaults in
      let width = try listWidth(host(width: 1024, defaults: defaults))
      #expect(width == Split.listIdealWidth)
    }
  }

  @Test func aWideStoredWidthLeavesTheDetailItsMinimum() throws {
    try withDefaults(stored: 500) { defaults in
      let width = try listWidth(host(width: besideTheSidebar, defaults: defaults))
      #expect(width == 383)
      #expect(defaults.double(forKey: Self.key) == 500)
    }
  }

  @Test func incrementStoresAWiderList() throws {
    try withDefaults(stored: 300) { defaults in
      let hosted = host(width: 1024, defaults: defaults)
      let divider = try #require(hosted.elements.first { $0.label == "List width" })

      #expect(divider.increment())

      #expect(abs(defaults.double(forKey: Self.key) - (300 + Split.accessibilityStep)) < 0.5)
    }
  }
}
