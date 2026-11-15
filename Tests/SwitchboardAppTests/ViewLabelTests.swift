import Testing

@testable import SwitchboardApp

@Suite struct ViewPickerLabels {
  @Test func showsTheCountWithoutParentheses() {
    #expect(ContentView.viewLabel("Inbox", 5) == "Inbox 5")
  }

  @Test func leavesOutAZeroCount() {
    #expect(ContentView.viewLabel("Issues", 0) == "Issues")
  }
}
