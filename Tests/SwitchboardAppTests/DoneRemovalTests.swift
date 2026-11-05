import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct DoneRemovalTextTests {
  func item(worktree: String? = nil, branch: String? = nil, remoteBranch: Bool = false) -> DoneRemovalPlan.Item {
    DoneRemovalPlan.Item(
      id: "s1", name: "one", pr: 7, worktree: worktree, branch: branch, remoteBranch: remoteBranch)
  }

  // MARK: summary

  @Test func summaryNamesTheRemovedAndTheSkipped() {
    #expect(DoneRemovalText.summary(removed: 9, skipped: 2) == "Removed 9, skipped 2")
  }

  @Test func summaryLeavesOutTheSkippedWhenNoneWereSkipped() {
    #expect(DoneRemovalText.summary(removed: 1, skipped: 0) == "Removed 1")
  }

  // MARK: progress

  @Test(arguments: [(0, 9, "Removing 1 of 9…"), (2, 9, "Removing 3 of 9…"), (8, 9, "Removing 9 of 9…")])
  func progressShowsTheSessionBeingRemoved(_ done: Int, _ total: Int, _ expected: String) {
    #expect(DoneRemovalText.progress(done: done, total: total) == expected)
  }

  @Test func progressNeverCountsPastTheTotal() {
    #expect(DoneRemovalText.progress(done: 9, total: 9) == "Removing 9 of 9…")
  }

  @Test func progressEndsWithAnEllipsisCharacter() {
    let text = DoneRemovalText.progress(done: 2, total: 9)

    #expect(text.hasSuffix("\u{2026}"))
    #expect(!text.contains("..."))
  }

  // MARK: deletes

  @Test func deletesOnlyTheSessionWithoutAWorktree() {
    #expect(DoneRemovalText.deletes(item()) == "session")
  }

  @Test func deletesTheSessionAndWorktreeWithoutABranch() {
    #expect(DoneRemovalText.deletes(item(worktree: "/wt/one")) == "session and worktree")
  }

  @Test func deletesTheBranchOfAMergedPR() {
    #expect(DoneRemovalText.deletes(item(worktree: "/wt/one", branch: "feat")) == "session, worktree, and branch")
  }

  @Test func deletesTheRemoteBranchWhenAsked() {
    let text = DoneRemovalText.deletes(item(worktree: "/wt/one", branch: "feat", remoteBranch: true))

    #expect(text == "session, worktree, branch, and remote branch")
  }
}

/// The app decodes what sbd's `rm-done` sends.
@Suite struct DoneRemovalPlanDecoding {
  @Test func decodesARemovalWithCamelCaseRemoteBranch() throws {
    let text = #"""
      {"remove":[{"id":"s1","name":"one","pr":122953,"worktree":"/wt/one","branch":"feat","remoteBranch":true}],
       "skip":[]}
      """#

    let plan = try JSONCoding.decode(DoneRemovalPlan.self, from: text)

    #expect(
      plan.remove == [
        DoneRemovalPlan.Item(
          id: "s1", name: "one", pr: 122953, worktree: "/wt/one", branch: "feat", remoteBranch: true)
      ])
  }

  @Test func decodesNullPRWorktreeAndBranch() throws {
    let text = #"""
      {"remove":[{"id":"s1","name":"one","pr":null,"worktree":null,"branch":null,"remoteBranch":false}],"skip":[]}
      """#

    let plan = try JSONCoding.decode(DoneRemovalPlan.self, from: text)

    #expect(
      plan.remove == [
        DoneRemovalPlan.Item(id: "s1", name: "one", pr: nil, worktree: nil, branch: nil, remoteBranch: false)
      ])
  }

  @Test func decodesASkipWithItsReason() throws {
    let text = #"{"remove":[],"skip":[{"id":"s2","name":"two","reason":"has uncommitted files"}]}"#

    let plan = try JSONCoding.decode(DoneRemovalPlan.self, from: text)

    #expect(plan.skip == [DoneRemovalPlan.Skip(id: "s2", name: "two", reason: "has uncommitted files")])
  }

  @Test func encodesRemoteBranchInCamelCase() throws {
    let plan = DoneRemovalPlan(
      remove: [DoneRemovalPlan.Item(id: "s1", name: "one", pr: nil, worktree: nil, branch: nil, remoteBranch: true)],
      skip: [])

    let json = try JSON(encoding: plan)

    #expect(json["remove"]?.array?.first?["remoteBranch"] == .bool(true))
  }
}

final class SentArgs: @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [[String: JSON]] = []
  var value: [[String: JSON]] { lock.withLock { sent } }
  func append(_ args: [String: JSON]) { lock.withLock { sent.append(args) } }
}

@MainActor
@Suite struct BoardModelDoneRemoval {
  @Test func removesOneSessionPerRequestAndSkipsARequestThatFails() async {
    let sent = SentArgs()
    let model = offlineModel()
    model.send = { op, args in
      #expect(op == "rm-done")
      sent.append(args)
      let id = args["targets"]?.array?.first?.string ?? ""
      if id == "b" { throw Refusal(description: "the socket closed") }
      return try JSON(encoding: DoneRemovalResult(removed: [id], skipped: [], partial: []))
    }
    let plan = DoneRemovalPlan(
      remove: ["a", "b", "c"].map { .init(id: $0, name: $0, pr: nil, worktree: nil, branch: nil, remoteBranch: false) },
      skip: [.init(id: "d", name: "d", reason: "has uncommitted files")])
    model.doneRemoval = .confirming(plan)
    model.selection = "a"

    model.removeDone(plan)
    await settle { if case .finished = model.doneRemoval { true } else { false } }

    guard case .finished(let result) = model.doneRemoval else {
      Issue.record("Delete All did not finish")
      return
    }
    #expect(result.removed == ["a", "c"])
    #expect(result.skipped.map(\.id) == ["d", "b"])
    #expect(result.skipped.last?.reason == "the socket closed")
    #expect(model.selection == nil)
    #expect(sent.value.map { $0["targets"]?.array?.compactMap(\.string) ?? [] } == [["a"], ["b"], ["c"]])
    for args in sent.value {
      #expect(args["confirmed"] == .bool(true))
      #expect(args["worktree"] == .bool(true))
      #expect(args["remote_branch"] == .bool(true))
    }
  }
}
