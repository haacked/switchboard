import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct LeftInboxBannerText {
  @Test func namesTheStateTheSessionMovedTo() {
    #expect(LeftInboxBanner.message(.working) == "Left the Inbox: \(AttentionState.working.title)")
  }
}

@MainActor
@Suite struct LeftInboxItem {
  /// A session that Claude works on after an answer, so it is not in the Inbox.
  static func working(_ id: String) -> SessionSummary {
    var s = needsItem(id, state: .working)
    s.triage = nil
    return s
  }

  func model(focus: String?) -> BoardModel {
    let model = appliedModel([needsItem("a"), Self.working("out")])
    model.show(.inbox)
    model.inboxFocus = focus
    return model
  }

  @Test func aFocusedSessionThatLeftTheInboxIsTheLeftItem() {
    #expect(model(focus: "out").leftInboxItem?.id == "out")
  }

  @Test func aFocusedInboxItemIsNotTheLeftItem() {
    #expect(model(focus: "a").leftInboxItem == nil)
  }

  @Test func withNoFocusTheFirstInboxItemShowsAndIsNotTheLeftItem() {
    #expect(model(focus: nil).leftInboxItem == nil)
  }
}
