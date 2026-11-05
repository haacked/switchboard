import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The arguments of each `gh pr comment` that the stub ran, oldest first.
  func ghComments() -> [String] { ghCalls("pr comment ") }

  /// The results of the session's `merge` events, oldest first.
  fileprivate func mergeResults(_ id: String) throws -> [String] {
    try events(id).filter { $0.kind == "merge" }.compactMap { $0.data["result"]?.string }
  }
}

extension FakeGitHub {
  /// Makes the PR's repository one that merges by `method`, as the status
  /// query shows it.
  fileprivate func mergesBy(_ method: MergeMethod, _ number: Int = MergeTests.number) {
    change(number) {
      var repository = $0["repository"]?.object ?? [:]
      repository["trunkConfig"] = method == .trunk ? ["id": "TREE_trunk"] : .null
      $0["repository"] = .object(repository)
      $0["isMergeQueueEnabled"] = method == .unknown ? nil : .bool(method == .mergeQueue)
    }
  }
}

/// The merge column holds every session whose PR passed review and can land.
/// Its card merges the PR, or enqueues it in a repository that merges through
/// a queue.
@Suite(.timeLimit(.minutes(2))) struct EnqueueTests {
  /// When stamphog approved #18303, as the fixture records it.
  static let approvedAt = "2026-10-25T20:56:17Z"
  static let unknownReason =
    "#18303 is ready to merge, approved by stamphog; can't tell how PostHog/charts merges, so merge it on GitHub"
  static let enqueueNote = "enqueued; once it merges, finish the post-merge steps"

  /// A session on #18303's branch in a repository that merges by `method`,
  /// whose PR the poller has read.
  func readySession(_ github: FakeGitHub, _ sbd: Instance, _ method: MergeMethod) throws -> SessionSummary {
    github.mergesBy(method)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    return s
  }

  func head(_ github: FakeGitHub) -> String { github.pr(MergeTests.number)["headRefOid"]!.string! }

  func ghMerge(_ github: FakeGitHub) -> String {
    "pr merge 18303 --repo PostHog/charts --merge --match-head-commit \(head(github))"
  }

  static let trunkComment = "pr comment 18303 --repo PostHog/charts --body /trunk merge"

  // Review

  @Test func approvedPRIsReadyToMerge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)

    #expect(try sbd.getJSON(s.id)["state"]?.string == "ready_to_merge")
  }

  @Test func prThatStillRequiresAReviewIsNotReadyToMerge() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) {
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
    }
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)

    #expect(try sbd.getJSON(s.id)["state"]?.string != "ready_to_merge")
  }

  @Test func approvedPRWhoseChecksRunWaits() throws {
    let github = try FakeGitHub()
    github.checks(MergeTests.number, "PENDING")
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)

    let got = try sbd.get(s.id)

    #expect(got.state == .waiting)
    #expect(got.reason == "checks running on #18303; #18303 approved")
  }

  @Test func prInTheMergeQueueWaits() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) { $0["isInMergeQueue"] = true }
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .mergeQueue)

    let got = try sbd.get(s.id)

    #expect(got.state == .waiting)
    #expect(got.reason == "#18303 is in the merge queue; #18303 approved")
  }

  // What the summary shows

  @Test(arguments: [
    (MergeMethod.merge, "merge"), (.mergeQueue, "merge_queue"), (.trunk, "trunk"), (.unknown, "unknown"),
  ])
  func getShowsTheMergeMethod(_ method: MergeMethod, _ text: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)

    #expect(try sbd.getJSON(s.id)["pr"]?["mergeMethod"]?.string == text)
  }

  @Test func listShowsTheMergeMethod() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .mergeQueue)

    let rows = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)

    #expect(rows.first { $0["id"]?.string == s.id }?["pr"]?["mergeMethod"]?.string == "merge_queue")
  }

  @Test func getShowsTheReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)

    let pr = try #require(try sbd.getJSON(s.id)["pr"])

    #expect(pr["reviewDecision"]?.string == "APPROVED")
    #expect(pr["approvers"] == ["stamphog"])
    #expect(pr["approvedAt"]?.string == Self.approvedAt)
    #expect(pr["inMergeQueue"] == false)
  }

  @Test func listShowsTheReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)

    let rows = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    let pr = try #require(rows.first { $0["id"]?.string == s.id }?["pr"])

    #expect(pr["reviewDecision"]?.string == "APPROVED")
    #expect(pr["approvers"] == ["stamphog"])
    #expect(pr["approvedAt"]?.string == Self.approvedAt)
  }

  @Test func readyToMergeSessionIsSinceTheApproval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)
    let approved = try #require(ISO8601DateFormatter().date(from: Self.approvedAt))

    #expect(try sbd.get(s.id).since == Int64(approved.timeIntervalSince1970 * 1000))
  }

  @Test func readyToMergeSessionThatNobodyApprovedIsSinceSbdFirstSawThePRReady() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) {
      $0["reviewDecision"] = .null
      $0["latestOpinionatedReviews"] = ["nodes": []]
      $0["reviewRequests"] = ["nodes": []]
    }
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)
    let firstRead = try #require(try sbd.events(s.id).first { $0.kind == "pr" }).t
    try sbd.advanceClock(3_600_000)
    github.change(MergeTests.number) { $0["title"] = "a new title" }
    try sbd.poll(all: true)

    let got = try sbd.get(s.id)

    #expect(got.state == .readyToMerge)
    #expect(got.since == firstRead)
  }

  // Options

  @Test(arguments: [(MergeMethod.merge, "Merge #18303"), (.mergeQueue, "Enqueue #18303"), (.trunk, "Enqueue #18303")])
  func cardOffersTheMethodsMergeOption(_ method: MergeMethod, _ label: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)

    let options = try #require(try sbd.get(s.id).triage?.options)

    #expect(options.first { $0.action == .merge }?.label == label)
  }

  @Test func undeterminedRepositoryIsReadyToMergeWithoutAMergeOption() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .unknown)

    let got = try sbd.get(s.id)

    #expect(got.state == .readyToMerge)
    #expect(got.reason == Self.unknownReason)
    #expect(got.triage?.options.contains { $0.action == .merge } == false)
  }

  @Test func conflictedPRHasNoMergeOption() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) { $0["mergeable"] = "CONFLICTING" }
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)

    let got = try sbd.get(s.id)

    #expect(got.reason == "rebase; #18303 conflicts with main")
    #expect(got.triage?.options.map(\.label) == ["Rebase"])
  }

  // Merge

  @Test func plainRepositoryMergesOnceAndResumesTheSession() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .merge)

    let printed = try sbd.sb("merge", s.id)

    #expect(printed.contains("merged #18303 of \(s.name)"))
    #expect(sbd.ghMerges() == [ghMerge(github)])
    #expect(sbd.ghComments().isEmpty)
    #expect(try sbd.mergeResults(s.id) == ["merged"])
    try sbd.waitFor("the post-merge message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id) == ["PR #18303 merged; finish the post-merge steps"])
  }

  @Test func undeterminedRepositoryRefusesTheMergeAndNamesTheRepository() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .unknown)

    let r = try sbd.run(["merge", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("can't tell how PostHog/charts merges"))
    #expect(sbd.ghMerges().isEmpty)
    #expect(sbd.ghComments().isEmpty)
    #expect(try sbd.get(s.id).state == .readyToMerge)
  }

  // Enqueue

  @Test func mergeQueueRepositoryEnqueuesWithGhPrMerge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .mergeQueue)

    try sbd.sb("merge", s.id)

    #expect(sbd.ghMerges() == [ghMerge(github)])
    #expect(sbd.ghComments().isEmpty)
  }

  @Test func trunkRepositoryEnqueuesWithATrunkCommentAndNeverMerges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .trunk)

    try sbd.sb("merge", s.id)

    #expect(sbd.ghComments() == [Self.trunkComment])
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func enqueuePrintsEnqueued(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)

    let printed = try sbd.sb("merge", s.id)

    #expect(printed.contains("enqueued #18303 of \(s.name)"))
    #expect(!printed.contains("merged"))
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func enqueueRecordsAnEnqueuedMerge(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)

    try sbd.sb("merge", s.id)

    #expect(try sbd.mergeResults(s.id) == ["enqueued"])
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func enqueueMovesTheSessionToWaiting(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)

    let printed = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("merge", "--json", s.id))

    #expect(printed.state == .waiting)
    #expect(try sbd.get(s.id).state == .waiting)
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func enqueueSetsAQueueWaitThatResumesTheSession(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)

    try sbd.sb("merge", s.id)

    let wait = try #require(try sbd.get(s.id).waits.only)
    #expect(wait.kind == .queue)
    #expect(wait.pr == nil || wait.pr?.number == MergeTests.number)
    #expect(wait.by == .you)
    #expect(wait.then == .resume)
    #expect(wait.note == Self.enqueueNote)
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func enqueueDoesNotResumeTheSessionUntilThePRMerges(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)

    try sbd.sb("merge", s.id)
    if method == .mergeQueue { github.change(MergeTests.number) { $0["isInMergeQueue"] = true } }
    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func secondEnqueueIsRefusedAndRunsNothing(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)
    try sbd.sb("merge", s.id)

    let again = try sbd.run(["merge", s.id])

    #expect(again.status != 0)
    #expect(sbd.ghMerges().count + sbd.ghComments().count == 1)
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func mergedPRResolvesTheQueueWaitAndResumesTheSession(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)
    try sbd.sb("merge", s.id)
    github.change(MergeTests.number) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = "2026-10-26T00:00:00Z"
      $0["isInMergeQueue"] = false
    }

    try sbd.poll(all: true)

    try sbd.waitFor("the message after the merge") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id).only?.contains("finish the post-merge steps") == true)
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  /// GitHub reports no removal state, so an open PR that its merge queue no
  /// longer holds is the removal. One read is not enough, since a read while
  /// GitHub merges the PR can show it outside the queue before it shows it
  /// merged.
  @Test func prThatGitHubsMergeQueueDropsResumesTheSessionAfterTwoReads() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .mergeQueue)
    try sbd.sb("merge", s.id)
    github.change(MergeTests.number) { $0["isInMergeQueue"] = true }
    try sbd.poll(all: true)
    github.change(MergeTests.number) { $0["isInMergeQueue"] = false }

    try sbd.poll(all: true)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
    #expect(try sbd.get(s.id).waits.count == 1)

    try sbd.poll(all: true)

    try sbd.waitFor("the message after the removal") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id).only?.contains("GitHub removed it from the merge queue") == true)
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  /// A PR that GitHub's queue has not taken yet, as when GitHub waits for a
  /// check, is not a removal.
  @Test func prThatGitHubsMergeQueueHasNotTakenKeepsTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, .mergeQueue)
    try sbd.sb("merge", s.id)

    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
    #expect(try sbd.get(s.id).waits.count == 1)
  }

  @Test(arguments: [MergeMethod.mergeQueue, .trunk])
  func failedEnqueueFailsWithGhsErrorAndKeepsTheSessionReady(_ method: MergeMethod) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readySession(github, sbd, method)
    let error = "GraphQL: Pull request PostHog/charts#18303 can't be enqueued."
    try sbd.ghMergeFails(with: error)

    let r = try sbd.run(["merge", s.id])

    let after = try sbd.get(s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains(error))
    #expect(after.state == .readyToMerge)
    #expect(after.mergeError?.contains(error) == true)
    #expect(after.waits.isEmpty)
    #expect(try sbd.mergeResults(s.id) == ["failed"])
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  // One state each

  @Test func eachSessionAppearsInExactlyOneState() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let ready = try readySession(github, sbd, .trunk)
    let enqueued = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch, folder: "enqueued")
    try sbd.poll(all: true)
    try sbd.sb("merge", enqueued.id)
    let plain = try sbd.new(prompt: "hello", name: "plain")
    try sbd.waitFor(plain.id, "the first reply") { $0.lastReply == "Done: hello" }

    let rows = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    let table = try sbd.sb("ls")

    let ids = rows.compactMap { $0["id"]?.string }
    let state = Dictionary(
      uniqueKeysWithValues: rows.compactMap { r in r["id"]?.string.map { ($0, r["state"]?.string) } })
    #expect(ids.sorted() == [ready.id, enqueued.id, plain.id].sorted())
    #expect(rows.allSatisfy { $0["state"]?.string != nil })
    #expect(state[enqueued.id] == "waiting")
    #expect(state[ready.id] == "ready_to_merge")
    for id in [ready.id, enqueued.id, plain.id] {
      #expect(table.components(separatedBy: " \(id) ").count == 2, "\(id) should appear once in `sb ls`")
    }
  }
}

extension Array {
  /// The one element, or nil when there are none or several.
  fileprivate var only: Element? { count == 1 ? first : nil }
}
