import CoreGraphics
import SwiftUI
import Testing

@testable import SwitchboardApp

/// The window in CI's gui-test.
private let narrow: CGFloat = 1024
/// The window that `bin/screenshots` captures.
private let wide: CGFloat = 1440

/// A fit that has measured `width` once while the detail column shows a list and detail view, or not.
@MainActor private func measured(_ width: CGFloat, listDetail: Bool) -> SidebarFit {
  var fit = SidebarFit()
  fit.update(windowWidth: width, isListDetail: listDetail)
  return fit
}

/// The fit at 1024 on the Inbox after the user showed the sidebar that the rule hid.
@MainActor private func userShownOnTheInbox() throws -> SidebarFit {
  var fit = measured(narrow, listDetail: false)
  fit.update(windowWidth: narrow, isListDetail: true)
  try #require(!fit.showsSidebar)
  fit.userSet(.all)
  try #require(fit.showsSidebar)
  return fit
}

@MainActor
@Suite struct SidebarFitThreshold {
  /// CI's window collapses. The default window and the screenshot window do not.
  @Test(arguments: [(1024, true), (1400, false), (1440, false)] as [(CGFloat, Bool)])
  func onlyTheCIWindowCollapses(_ width: CGFloat, _ collapses: Bool) {
    let fit = measured(width, listDetail: true)

    #expect(fit.showsSidebar == !collapses)
  }

  @Test func aWidthAtTheThresholdDoesNotCollapse() {
    let fit = measured(SidebarFit.collapseBelow, listDetail: true)

    #expect(fit.showsSidebar)
  }

  @Test func aWidthOnePointUnderTheThresholdCollapses() {
    let fit = measured(SidebarFit.collapseBelow - 1, listDetail: true)

    #expect(!fit.showsSidebar)
  }

  /// `ContentView.windowMinWidth` is the narrowest window.
  @Test func theNarrowestWindowCollapses() {
    let fit = measured(ContentView.windowMinWidth, listDetail: true)

    #expect(!fit.showsSidebar)
  }
}

/// The rule hides the sidebar when a list and detail view shows in a narrow window, and shows it again when that
/// stops, if the rule hid it.
@MainActor
@Suite struct SidebarFitRule {
  @Test func startsShown() {
    #expect(SidebarFit().showsSidebar)
  }

  @Test func theBoardInANarrowWindowShowsTheSidebar() {
    let fit = measured(narrow, listDetail: false)

    #expect(fit.showsSidebar)
  }

  @Test func enteringTheInboxFromTheBoardInANarrowWindowHidesTheSidebar() {
    var fit = measured(narrow, listDetail: false)

    fit.update(windowWidth: narrow, isListDetail: true)

    #expect(!fit.showsSidebar)
  }

  @Test func returningToTheBoardInANarrowWindowShowsTheSidebar() {
    var fit = measured(narrow, listDetail: false)
    fit.update(windowWidth: narrow, isListDetail: true)

    fit.update(windowWidth: narrow, isListDetail: false)

    #expect(fit.showsSidebar)
  }

  @Test func aWideWindowNeverHidesTheSidebar() {
    var fit = measured(wide, listDetail: false)
    var seen: [Bool] = []

    for listDetail in [true, false, true] {
      fit.update(windowWidth: wide, isListDetail: listDetail)
      seen.append(fit.showsSidebar)
    }

    #expect(seen == [true, true, true])
  }

  @Test func narrowingOnTheInboxHidesTheSidebar() {
    var fit = measured(wide, listDetail: true)

    fit.update(windowWidth: narrow, isListDetail: true)

    #expect(!fit.showsSidebar)
  }

  @Test func wideningOnTheInboxShowsTheSidebar() {
    var fit = measured(wide, listDetail: true)
    fit.update(windowWidth: narrow, isListDetail: true)

    fit.update(windowWidth: wide, isListDetail: true)

    #expect(fit.showsSidebar)
  }

  /// `onGeometryChange` reports widths while the user drags the window edge, so a hidden sidebar stays hidden
  /// through every width under the threshold.
  @Test func resizingWithinTheNarrowRangeKeepsTheSidebarHidden() {
    var fit = measured(narrow, listDetail: true)
    var seen: [Bool] = []

    for width in [narrow, 1030, 900, SidebarFit.collapseBelow - 1] as [CGFloat] {
      fit.update(windowWidth: width, isListDetail: true)
      seen.append(fit.showsSidebar)
    }

    #expect(seen == [false, false, false, false])
  }

  @Test func wideningToExactlyTheThresholdShowsTheSidebar() {
    var fit = measured(narrow, listDetail: true)

    fit.update(windowWidth: SidebarFit.collapseBelow, isListDetail: true)

    #expect(fit.showsSidebar)
  }
}

/// A user toggle while the rule's condition holds overrides the rule until the window reaches the threshold. A user
/// toggle while it does not hold just sets the visibility, and the rule never shows a sidebar that the user hid.
@MainActor
@Suite struct SidebarFitUserToggle {
  @Test func aUserShowOnTheInboxSurvivesALeaveAndAReturn() throws {
    var fit = try userShownOnTheInbox()

    fit.update(windowWidth: narrow, isListDetail: false)
    fit.update(windowWidth: narrow, isListDetail: true)

    #expect(fit.showsSidebar)
  }

  @Test func aUserShowOnTheInboxShowsOnTheBoard() throws {
    var fit = try userShownOnTheInbox()

    fit.update(windowWidth: narrow, isListDetail: false)

    #expect(fit.showsSidebar)
  }

  /// The rule acts when its condition starts to hold. A repeated or narrower width while it holds is no new start.
  @Test func aUserShowSurvivesResizesUnderTheThreshold() throws {
    var fit = try userShownOnTheInbox()
    var seen: [Bool] = []

    for width in [narrow, 1030, 900, SidebarFit.collapseBelow - 1] as [CGFloat] {
      fit.update(windowWidth: width, isListDetail: true)
      seen.append(fit.showsSidebar)
    }

    #expect(seen == [true, true, true, true])
  }

  @Test func wideningPastTheThresholdAndNarrowingAgainClearsAUserShow() throws {
    var fit = try userShownOnTheInbox()

    fit.update(windowWidth: wide, isListDetail: true)
    fit.update(windowWidth: narrow, isListDetail: true)

    #expect(!fit.showsSidebar)
  }

  @Test func wideningToExactlyTheThresholdClearsAUserShow() throws {
    var fit = try userShownOnTheInbox()

    fit.update(windowWidth: SidebarFit.collapseBelow, isListDetail: true)
    fit.update(windowWidth: narrow, isListDetail: true)

    #expect(!fit.showsSidebar)
  }

  @Test func wideningToOnePointUnderTheThresholdKeepsAUserShow() throws {
    var fit = try userShownOnTheInbox()

    fit.update(windowWidth: SidebarFit.collapseBelow - 1, isListDetail: true)
    fit.update(windowWidth: narrow, isListDetail: true)

    #expect(fit.showsSidebar)
  }

  @Test func aSidebarTheUserHidOnTheBoardStaysHiddenThroughTheInbox() {
    var fit = measured(wide, listDetail: false)
    fit.userSet(.detailOnly)
    var seen: [Bool] = [fit.showsSidebar]

    for (width, listDetail) in [(narrow, false), (narrow, true), (narrow, false)] as [(CGFloat, Bool)] {
      fit.update(windowWidth: width, isListDetail: listDetail)
      seen.append(fit.showsSidebar)
    }

    #expect(seen == [false, false, false, false])
  }

  @Test func aSidebarTheUserHidStaysHiddenAfterWidening() {
    var fit = measured(wide, listDetail: false)
    fit.userSet(.detailOnly)
    fit.update(windowWidth: narrow, isListDetail: true)

    fit.update(windowWidth: wide, isListDetail: true)
    fit.update(windowWidth: wide, isListDetail: false)

    #expect(!fit.showsSidebar)
  }

  @Test func aSidebarTheUserHidOnTheInboxInAWideWindowStaysHiddenAfterNarrowingAndWidening() {
    var fit = measured(wide, listDetail: true)
    fit.userSet(.detailOnly)

    fit.update(windowWidth: narrow, isListDetail: true)
    fit.update(windowWidth: wide, isListDetail: true)

    #expect(!fit.showsSidebar)
  }

  @Test func aUserShowOutsideTheConditionSetsTheVisibility() {
    var fit = measured(wide, listDetail: false)
    fit.userSet(.detailOnly)

    fit.userSet(.all)

    #expect(fit.showsSidebar)
  }

  /// A toggle on a view that is not a list and detail view does not stop the rule from hiding the sidebar later.
  @Test func aUserToggleOutsideTheConditionLeavesTheRuleOn() {
    var fit = measured(narrow, listDetail: false)
    fit.userSet(.detailOnly)
    fit.userSet(.all)

    fit.update(windowWidth: narrow, isListDetail: true)

    #expect(!fit.showsSidebar)
  }

  /// The user hid the sidebar last. The rule shows only a sidebar that the rule hid.
  @Test func aUserHideAfterAUserShowOnTheInboxStaysHiddenOnTheBoard() throws {
    var fit = try userShownOnTheInbox()
    fit.userSet(.detailOnly)

    fit.update(windowWidth: narrow, isListDetail: false)

    #expect(!fit.showsSidebar)
  }
}

/// SwiftUI calls the binding's setter with the value the rule just set, and with `.all` while the value is
/// `.automatic`. Neither is a user toggle.
@MainActor
@Suite struct SidebarFitEcho {
  @Test(
    arguments: [
      (narrow, true, .detailOnly), (narrow, false, .all), (wide, true, .all), (narrow, false, .doubleColumn),
      (narrow, false, .automatic),
    ] as [(CGFloat, Bool, NavigationSplitViewVisibility)])
  func aValueThatMatchesTheSidebarChangesNothing(
    _ width: CGFloat, _ listDetail: Bool, _ value: NavigationSplitViewVisibility
  ) {
    var fit = measured(width, listDetail: listDetail)
    let before = fit

    fit.userSet(value)

    #expect(fit == before)
  }
}

/// The states a zero width must leave alone.
enum ZeroWidthStart: String, CaseIterable, Sendable {
  case fresh, ruleHidden, shown, userShown

  @MainActor func fit() throws -> SidebarFit {
    switch self {
    case .fresh: SidebarFit()
    case .ruleHidden: measured(narrow, listDetail: true)
    case .shown: measured(wide, listDetail: true)
    case .userShown: try userShownOnTheInbox()
    }
  }
}

/// The window reports a width of 0 before its first layout. The rule ignores it.
@MainActor
@Suite struct SidebarFitZeroWidth {
  @Test(arguments: ZeroWidthStart.allCases, [true, false])
  func aZeroWidthChangesNothing(_ start: ZeroWidthStart, _ listDetail: Bool) throws {
    var fit = try start.fit()
    let before = fit

    fit.update(windowWidth: 0, isListDetail: listDetail)

    #expect(fit == before)
  }
}

/// At launch, SwiftUI passes the sidebar state that the window restored from the last run to the setter, before the
/// first measurement.
@MainActor
@Suite struct SidebarFitRestored {
  @Test func aHiddenSidebarThatTheRuleHidShowsOnASessionView() {
    var fit = SidebarFit(ruleHidLastRun: true)
    fit.userSet(.detailOnly)

    fit.update(windowWidth: narrow, isListDetail: false)

    #expect(fit.showsSidebar)
  }

  @Test func aHiddenSidebarThatTheRuleHidStaysHiddenOnTheInboxAndShowsWhenASessionOpens() {
    var fit = SidebarFit(ruleHidLastRun: true)
    fit.userSet(.detailOnly)

    fit.update(windowWidth: narrow, isListDetail: true)
    let onTheInbox = fit.showsSidebar
    fit.update(windowWidth: narrow, isListDetail: false)

    #expect(!onTheInbox)
    #expect(fit.showsSidebar)
  }

  @Test func aHiddenSidebarThatTheRuleHidShowsInAWideWindow() {
    var fit = SidebarFit(ruleHidLastRun: true)
    fit.userSet(.detailOnly)

    fit.update(windowWidth: wide, isListDetail: true)

    #expect(fit.showsSidebar)
  }

  @Test(arguments: [(narrow, false), (narrow, true), (wide, false), (wide, true)] as [(CGFloat, Bool)])
  func aHiddenSidebarThatTheUserHidStaysHidden(_ width: CGFloat, _ listDetail: Bool) {
    var fit = SidebarFit(ruleHidLastRun: false)
    fit.userSet(.detailOnly)

    fit.update(windowWidth: width, isListDetail: listDetail)
    fit.update(windowWidth: width, isListDetail: !listDetail)

    #expect(!fit.showsSidebar)
  }

  @Test func theRuleRecordsThatItHidTheSidebarAndThatItShowedItAgain() {
    var fit = measured(narrow, listDetail: false)

    fit.update(windowWidth: narrow, isListDetail: true)
    let hid = fit.autoHidden
    fit.update(windowWidth: narrow, isListDetail: false)

    #expect(hid)
    #expect(!fit.autoHidden)
  }

  @Test func aUserToggleClearsTheRecord() {
    var fit = measured(narrow, listDetail: true)
    fit.userSet(.all)

    #expect(!fit.autoHidden)
  }
}
