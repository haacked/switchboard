import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct ViewPickerLabels {
  @Test func showsTheCountWithoutParentheses() {
    #expect(ContentView.viewLabel("Inbox", 5) == "Inbox 5")
  }

  @Test func leavesOutAZeroCount() {
    #expect(ContentView.viewLabel("Issues", 0) == "Issues")
  }

  /// The toolbar picker and the View menu's Show items read these titles.
  @Test func mainViewTitlesKeepThePickerAndMenuOrder() {
    #expect(MainView.allCases.map(\.title) == ["Inbox", "Board", "Issues", "Loops"])
  }

  /// The View menu binds Show Inbox, Show Board, Show Issues, and Show Loops to ⌘1 to ⌘4.
  @Test func mainViewShortcutKeysAreOneToFour() {
    #expect(MainView.allCases.map { $0.shortcut.binding } == ["1", "2", "3", "4"].map { KeyboardShortcut($0) })
  }

  /// The navigation history menu shows these symbols next to each place.
  @Test func mainViewSymbolsMatchTheHistoryIcons() {
    #expect(
      MainView.allCases.map(\.symbol) == [
        "tray", "square.grid.3x3", "smallcircle.filled.circle", "clock.arrow.circlepath",
      ])
  }
}

/// The bar that a Manager's view shows over the Message Claude field in place of sending a work skill's command.
@Suite struct WorkSkillOfferViewLabels {
  @Test func theButtonsReadSpawnRunHereAndCancel() {
    #expect(WorkSkillOfferBar.spawnTitle == "Spawn a session with this")
    #expect(WorkSkillOfferBar.runHereTitle == "Run here anyway")
    #expect(WorkSkillOfferBar.cancelTitle == "Cancel")
  }

  /// The block reason of sbd's hook names the first two buttons, so a user who reads it finds them.
  @Test func theBlockReasonNamesTheSpawnAndRunHereButtons() {
    let reason = ManagerSkillGate.promptReason(skill: "go", session: "m")

    #expect(reason.contains(WorkSkillOfferBar.spawnTitle), "\(reason)")
    #expect(reason.contains(WorkSkillOfferBar.runHereTitle), "\(reason)")
  }

  @Test func theMessageNamesTheCommandAndTheCost() {
    #expect(
      WorkSkillOfferBar.message(skill: "go")
        == "/go is a work skill. A Manager conversation pays for its text on every later turn.")
  }
}
