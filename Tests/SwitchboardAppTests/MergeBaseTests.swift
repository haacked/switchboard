import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A session whose PR is in `state` and conflicts with main.
private func conflicted(_ state: PRState = .open, session: AttentionState = .needsYou) -> SessionSummary {
  var s = needsItem("a", state: session)
  s.pr = PRSummary(
    PullRequest(
      id: "PR_a", number: 1, url: "https://github.com/acme/widgets/pull/1", repo: "acme/widgets", state: state,
      mergeable: .conflicting))
  return s
}

@Suite struct MergeBaseTests {
  @Test func openPRThatConflictsOffersItsBase() {
    #expect(conflicted().mergeBase == "main")
  }

  @Test(arguments: [PRState.merged, .closed])
  func prThatIsNotOpenOffersNoMerge(_ state: PRState) {
    #expect(conflicted(state).mergeBase == nil)
  }

  @Test func sessionWithoutAFolderOffersNoMerge() {
    var s = conflicted()
    s.cwd = ""
    #expect(s.mergeBase == nil)
  }

  @Test func prSummaryWithoutABaseOffersNoMerge() {
    var s = conflicted()
    s.pr?.base = nil
    #expect(s.mergeBase == nil)
  }

  @Test func workingSessionOffersNoMerge() {
    #expect(conflicted(session: .working).mergeBase == nil)
  }

  @Test func prThatMergesCleanlyOffersNoMerge() {
    var s = conflicted()
    s.pr?.mergeable = .mergeable
    #expect(s.mergeBase == nil)
  }
}
