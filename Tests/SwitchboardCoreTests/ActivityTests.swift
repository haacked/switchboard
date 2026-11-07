import Foundation
import Testing

@testable import SwitchboardCore

/// The session's `lastActivity` after a Stop at 1 and then an event of `kind` at 500.
private func activity(after kind: String) -> Int64 {
  facts([event("Stop", 1), event(kind, 500)]).lastActivity
}

@Suite struct ActivityKindTests {
  @Test(arguments: SessionFacts.hookKinds)
  func aHookEventIsActivity(_ kind: String) {
    #expect(activity(after: kind) == 500)
  }

  @Test(arguments: [
    "created", "imported", "followup", "started", "resumed", "followup-started", "sent", "answered",
    "dialog_closed", "card_closed", "wait", "wait-cleared", "note", "note-removed", "note-resolved", "done", "undone",
    "account-moved", "idle",
  ])
  func anSbdEventThatUsesTheSessionIsActivity(_ kind: String) {
    #expect(activity(after: kind) == 500)
  }

  @Test(arguments: [
    "running", "exited", "stopped", "deferred", "followup-ready", "wait-resolved", "delivered", "requeued",
    "pr", "worktree", "triage", "job", "cleanup", "auto-continue", "dependencies",
  ])
  func anSbdEventThatOnlyObservesTheSessionIsNotActivity(_ kind: String) {
    #expect(activity(after: kind) == 1)
  }

  /// A kind that sbd starts to record later does not count until it joins `activityKinds`.
  @Test(arguments: ["some-new-kind", "SomeNewHook"])
  func anUnknownKindIsNotActivity(_ kind: String) {
    #expect(activity(after: kind) == 1)
  }
}
