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
    let model = appliedModel(["a", "b", "c", "d"].map { needsItem($0, state: .done) })
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

/// Delete All sends `confirmed: true` only for sessions that the org filter
/// shows at the moment of the send.
@MainActor
@Suite struct DoneRemovalOrgFilterTests {
  static let done = [
    orgSession("ph", "PostHog/posthog", state: .done), orgSession("hk", "haacked/switchboard", state: .done),
    orgSession("lo", nil, state: .done), orgSession("un", nil, read: nil, state: .done),
  ]

  func item(_ id: String) -> DoneRemovalPlan.Item {
    .init(id: id, name: id, pr: nil, worktree: nil, branch: nil, remoteBranch: false)
  }

  func skip(_ id: String) -> DoneRemovalPlan.Skip { .init(id: id, name: id, reason: "has uncommitted files") }

  func model(_ filter: OrgFilter, _ list: [SessionSummary] = done) -> BoardModel {
    let model = orgFilterModel(filter)
    model.apply(.success(list), followups: nil)
    return model
  }

  /// A `send` that records every request, answers the check with `plan`, and removes each confirmed target.
  /// `beforeAnswer` runs on the main actor after a confirmed request is recorded and before it is answered.
  func recordingSend(
    _ sent: SentArgs, plan: DoneRemovalPlan, beforeAnswer: (@MainActor @Sendable (String) -> Void)? = nil
  ) -> @Sendable (String, [String: JSON]) throws -> JSON {
    { op, args in
      sent.append(args)
      guard args["confirmed"] == .bool(true) else { return try JSON(encoding: plan) }
      let id = args["targets"]?.array?.first?.string ?? ""
      if let beforeAnswer { DispatchQueue.main.sync { MainActor.assumeIsolated { beforeAnswer(id) } } }
      return try JSON(encoding: DoneRemovalResult(removed: [id], skipped: [], partial: []))
    }
  }

  func confirmedTargets(_ sent: SentArgs) -> [String] {
    sent.value.filter { $0["confirmed"] == .bool(true) }.flatMap { $0["targets"]?.array?.compactMap(\.string) ?? [] }
  }

  func confirm(_ model: BoardModel, _ plan: DoneRemovalPlan) async -> DoneRemovalResult? {
    model.doneRemoval = .confirming(plan)
    model.removeDone(plan)
    await settle { if case .finished = model.doneRemoval { true } else { false } }
    guard case .finished(let result) = model.doneRemoval else { return nil }
    return result
  }

  // MARK: The plan

  @Test func aPlanShowsOnlyTheSessionsThatTheFilterShows() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter(keys: ["posthog"]))
    let plan = DoneRemovalPlan(remove: [item("ph"), item("hk"), item("un")], skip: [skip("lo"), skip("ph2")])
    model.send = recordingSend(sent, plan: plan)

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }

    guard case .confirming(let shown) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    // The unread session shows under the filter, but its org may be hidden, so Delete All leaves it out.
    #expect(shown.remove.map(\.id) == ["ph"])
    #expect(shown.skip.isEmpty)
  }

  @Test func aPlanDropsAnIdThatTheBoardDoesNotList() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter())
    let plan = DoneRemovalPlan(remove: [item("ph"), item("ghost")], skip: [skip("phantom"), skip("lo")])
    model.send = recordingSend(sent, plan: plan)

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }

    guard case .confirming(let shown) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    #expect(shown.remove.map(\.id) == ["ph"])
    #expect(shown.skip.map(\.id) == ["lo"])
  }

  // MARK: The sends

  @Test func confirmingAfterAFilterChangeThatHidesAPlannedIdNeverSendsIt() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter())
    let plan = DoneRemovalPlan(remove: [item("ph"), item("hk"), item("lo")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    model.orgFilter = OrgFilter(keys: ["posthog"])
    let result = try #require(await confirm(model, plan))

    #expect(confirmedTargets(sent) == ["ph"])
    #expect(result.removed == ["ph"])
    #expect(result.skipped.map(\.id) == ["hk", "lo"])
    #expect(result.skipped.allSatisfy { $0.reason == "hidden by the org filter" })
  }

  @Test func aFilterChangeBetweenTwoSendsSkipsTheSecondId() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter())
    let plan = DoneRemovalPlan(remove: [item("ph"), item("hk")], skip: [])
    model.send = recordingSend(sent, plan: plan) { id in
      if id == "ph" { model.orgFilter = OrgFilter(keys: ["posthog"]) }
    }

    let result = try #require(await confirm(model, plan))

    #expect(confirmedTargets(sent) == ["ph"])
    #expect(result.skipped.map(\.id) == ["hk"])
    #expect(result.skipped.first?.reason == "hidden by the org filter")
  }

  @Test func aSessionWhoseOrgBecomesKnownAndHiddenWhileTheSheetIsOpenIsSkipped() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter(keys: ["posthog"]))
    let plan = DoneRemovalPlan(remove: [item("ph"), item("un")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    model.apply(
      .success([
        orgSession("ph", "PostHog/posthog", state: .done), orgSession("un", "haacked/late", state: .done),
      ]), followups: nil)
    let result = try #require(await confirm(model, plan))

    #expect(confirmedTargets(sent) == ["ph"])
    #expect(result.skipped.map(\.id) == ["un"])
  }

  @Test func aSessionWhoseOrgIsUnknownIsNeverSentUnderAFilter() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter(keys: ["posthog"]))
    let plan = DoneRemovalPlan(remove: [item("ph"), item("un")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    let result = try #require(await confirm(model, plan))

    #expect(model.shownIDs.contains("un"))
    #expect(confirmedTargets(sent) == ["ph"])
    #expect(result.skipped.map(\.id) == ["un"])
  }

  @Test func anIdThatTheBoardDoesNotListIsNeverSent() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter())
    let plan = DoneRemovalPlan(remove: [item("ghost"), item("ph")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    let result = try #require(await confirm(model, plan))

    #expect(confirmedTargets(sent) == ["ph"])
    #expect(result.skipped.map(\.id) == ["ghost"])
  }

  @Test func underAllOrgsTheRequestsMatchTheUnfilteredOnes() async throws {
    let sent = SentArgs()
    let model = model(OrgFilter())
    let plan = DoneRemovalPlan(remove: Self.done.map { item($0.id) }, skip: [])
    model.send = recordingSend(sent, plan: plan)

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }
    guard case .confirming(let shown) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    #expect(shown == plan)
    let result = try #require(await confirm(model, shown))

    #expect(sent.value.first == BoardModel.doneRemovalArgs)
    #expect(
      sent.value.dropFirst().map { $0["targets"]?.array?.compactMap(\.string) ?? [] } == [
        ["ph"], ["hk"], ["lo"], ["un"],
      ])
    for args in sent.value.dropFirst() {
      #expect(args["confirmed"] == .bool(true))
      #expect(args["worktree"] == .bool(true))
      #expect(args["remote_branch"] == .bool(true))
    }
    #expect(result.removed == ["ph", "hk", "lo", "un"])
    #expect(result.skipped.isEmpty)
  }
}
