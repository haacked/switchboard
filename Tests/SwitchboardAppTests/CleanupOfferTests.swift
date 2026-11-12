import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A finished session whose worktree the poller checked, or nil `cleanup` when it never did.
func cleanupSession(
  _ cleanup: CleanupStatus?, id: String = "s1", name: String = "fix", cwd: String = "/worktrees/posthog/haacked/fix",
  branch: String? = "haacked/fix"
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: name, cwd: cwd, repo: "/repos/posthog", branch: branch, claudeSessionId: "c", state: .done,
    reason: "", since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false, lastReply: nil, waits: [],
    notes: [])
  s.cleanup = cleanup
  return s
}

@Suite struct CleanupOfferStatus {
  @Test func offersCleanUpWhenEveryCheckPassed() {
    #expect(CleanupOffer.canCleanUp(cleanupSession(CleanupStatus(state: .ready))))
    #expect(CleanupOffer(cleanupSession(CleanupStatus(state: .ready))) != nil)
  }

  @Test(arguments: [
    CleanupStatus?.none,
    CleanupStatus(state: .blocked, reason: "the worktree has uncommitted files"),
    CleanupStatus(state: .removed),
    CleanupStatus(state: .removed, reason: "kept feat"),
  ])
  func neverOffersCleanUpUnlessEveryCheckPassed(_ status: CleanupStatus?) {
    #expect(!CleanupOffer.canCleanUp(cleanupSession(status)))
    #expect(CleanupOffer(cleanupSession(status)) == nil)
  }

  @Test func showsTheFailedCheckWhenBlocked() {
    let reason = "the branch has commits that are on no remote branch"
    #expect(
      CleanupOffer.blockedNote(cleanupSession(CleanupStatus(state: .blocked, reason: reason)))?.contains(reason) == true
    )
  }

  @Test(arguments: [
    CleanupStatus?.none, CleanupStatus(state: .ready), CleanupStatus(state: .removed),
    CleanupStatus(state: .removed, reason: "kept feat"),
  ])
  func showsNoNoteUnlessBlocked(_ status: CleanupStatus?) {
    #expect(CleanupOffer.blockedNote(cleanupSession(status)) == nil)
  }
}

@Suite struct CleanupOfferConfirmation {
  @Test func namesTheSessionWorktreeAndBranch() throws {
    let offer = try #require(
      CleanupOffer(
        cleanupSession(
          CleanupStatus(state: .ready), name: "login-bug", cwd: "/worktrees/r/haacked/odd path",
          branch: "haacked/42-feature")))
    #expect(offer.title == "Clean up login-bug?")
    #expect(
      offer.message.contains("the worktree /worktrees/r/haacked/odd path and the local branch haacked/42-feature"))
    #expect(offer.message.contains("stops claude, closes both terminals"))
    #expect(offer.message.contains("The session stays in Done"))
  }
}

@MainActor
@Suite struct BoardModelCleanup {
  func model(_ send: @escaping @Sendable (String, [String: JSON]) throws -> JSON) -> BoardModel {
    let model = offlineModel()
    model.send = send
    return model
  }

  @Test func sendsTheCleanupOpOnceWhileTheFirstIsOnItsWay() async {
    let answer = DispatchSemaphore(value: 0)
    let sent = Counter()
    let model = model { op, args in
      #expect(op == "cleanup")
      #expect(args == ["session": .string("s1")])
      sent.increment()
      answer.wait()
      return .null
    }
    let ready = cleanupSession(CleanupStatus(state: .ready))
    model.cleanup(ready)
    model.cleanup(ready)
    #expect(model.cleaningUp == ["s1"])
    answer.signal()
    await settle { model.cleaningUp.isEmpty }
    #expect(model.cleaningUp.isEmpty)
    #expect(sent.value == 1)
  }

  @Test func showsTheRefusalAndAllowsAnotherTry() async {
    let model = model { _, _ in throw Refusal(description: "the worktree has uncommitted files") }
    model.cleanup(cleanupSession(CleanupStatus(state: .ready)))
    await settle { model.actionError != nil && model.cleaningUp.isEmpty }
    #expect(model.actionError == "cleanup: the worktree has uncommitted files")
    #expect(model.cleaningUp.isEmpty)
  }
}
