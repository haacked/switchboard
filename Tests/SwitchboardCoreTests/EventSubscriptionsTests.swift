import Testing

@testable import SwitchboardCore

@Suite struct EventSubscriptionsTests {

  @Test func theDefaultSystemPromptHoldsTheGuidance() {
    #expect(TriageSettings().systemPrompt.contains(EventSubscriptions.guidance))
  }

  @Test func theManagerGuideHoldsTheGuidance() {
    #expect(Manager.guide.contains(EventSubscriptions.guidance))
  }

  @Test(arguments: ["`sb wait`", "`set_wait`", "`gh event listen`", "`gh event subscription create`"])
  func theGuidanceNames(_ name: String) {
    #expect(EventSubscriptions.guidance.contains(name))
  }
}
