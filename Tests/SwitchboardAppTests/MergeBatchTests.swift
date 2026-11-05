import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A Ready to merge session whose PR's repository merges by `method`.
private func readySession(
  _ id: String, _ method: MergeMethod?, since: Int64 = 0, state: AttentionState = .readyToMerge
) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.since = since
  var pr = PRSummary(
    PullRequest(id: "PR_\(id)", number: 1, url: "https://github.com/acme/widgets/pull/1", repo: "acme/widgets"))
  pr.mergeMethod = method
  s.pr = pr
  return s
}

@Suite struct MergeBatchTests {
  @Test func batchLeavesOutOtherSessionsWhoseMethodIsUnknown() {
    let a = readySession("a", .merge)
    let b = readySession("b", .unknown, since: 1)
    let c = readySession("c", .trunk, since: 2)

    #expect(a.readyToMergeSessions(all: [a, b, c]).map(\.id) == ["a", "c"])
  }

  @Test func batchFromASessionWhoseMethodIsUnknownIsEmpty() {
    let a = readySession("a", .unknown)
    let b = readySession("b", .merge)

    #expect(a.readyToMergeSessions(all: [a, b]).isEmpty)
  }

  @Test func batchKeepsEveryMethodThatMergesOrEnqueuesOldestFirst() {
    let a = readySession("a", .merge, since: 5)
    let b = readySession("b", .trunk, since: 3)
    let c = readySession("c", .mergeQueue, since: 1)
    let d = readySession("d", .merge, since: 2)

    #expect(a.readyToMergeSessions(all: [a, b, c, d]).map(\.id) == ["a", "c", "d", "b"])
  }

  @Test func batchLeavesOutSessionsThatAreNotReadyToMerge() {
    let a = readySession("a", .merge)
    let b = readySession("b", .merge, since: 1, state: .waiting)

    #expect(a.readyToMergeSessions(all: [a, b]).map(\.id) == ["a"])
  }

  @Test(arguments: [[MergeMethod.merge], [.merge, .merge]])
  func titleIsMergeAllWhenEverySessionMerges(_ methods: [MergeMethod]) {
    let sessions = methods.enumerated().map { readySession("s\($0.offset)", $0.element) }

    #expect(mergeBatchTitle(sessions) == "Merge All")
  }

  @Test(arguments: [[MergeMethod.trunk], [.mergeQueue], [.trunk, .mergeQueue], [.mergeQueue, .mergeQueue]])
  func titleIsEnqueueAllWhenEverySessionEnqueues(_ methods: [MergeMethod]) {
    let sessions = methods.enumerated().map { readySession("s\($0.offset)", $0.element) }

    #expect(mergeBatchTitle(sessions) == "Enqueue All")
  }

  @Test(arguments: [[MergeMethod.merge, .trunk], [.mergeQueue, .merge], [.trunk, .merge, .mergeQueue]])
  func titleIsMergeAndEnqueueAllWhenTheMethodsMix(_ methods: [MergeMethod]) {
    let sessions = methods.enumerated().map { readySession("s\($0.offset)", $0.element) }

    #expect(mergeBatchTitle(sessions) == "Merge and Enqueue All")
  }
}
