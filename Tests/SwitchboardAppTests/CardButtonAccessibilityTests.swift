import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// Session "a", whose PR #98's repository merges by `method`.
private func readySession(_ method: MergeMethod?) -> SessionSummary {
  var s = needsItem("a", state: .readyToMerge)
  var pr = PRSummary(
    PullRequest(id: "PR_a", number: 98, url: "https://github.com/acme/widgets/pull/98", repo: "acme/widgets"))
  pr.mergeMethod = method
  s.pr = pr
  return s
}

private func sessionWithoutPR() -> SessionSummary {
  needsItem("a", state: .readyToMerge)
}

@Suite struct CardButtonAccessibility {
  /// A nil merge method reads as Merge.
  @Test(arguments: [MergeMethod?.none, .merge])
  func aMergeButtonNamesItsPRAndSession(_ method: MergeMethod?) {
    #expect(readySession(method).mergeButtonLabel == "Merge #98 of a")
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func anEnqueueButtonNamesItsPRAndSession(_ method: MergeMethod) {
    #expect(readySession(method).mergeButtonLabel == "Enqueue #98 of a")
  }

  @Test func aMergeButtonWithoutAPRNamesThePR() {
    #expect(sessionWithoutPR().mergeButtonLabel == "Merge the PR of a")
  }

  @Test func aNudgeButtonNamesItsPRAndSession() {
    #expect(readySession(.merge).nudgeButtonLabel == "Draft a nudge for #98 of a")
  }

  @Test func aNudgeButtonWithoutAPRNamesThePR() {
    #expect(sessionWithoutPR().nudgeButtonLabel == "Draft a nudge for the PR of a")
  }

  @Test(arguments: ["main", "release/2.0"])
  func aConflictButtonNamesTheBaseThePRAndTheSession(_ base: String) {
    #expect(readySession(.merge).mergeBaseButtonLabel(base: base) == "Merge \(base) into #98 of a")
  }
}
