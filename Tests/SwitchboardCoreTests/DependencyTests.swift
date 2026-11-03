import Foundation
import Testing

@testable import SwitchboardCore

private let own = "acme/widgets"

/// Each ref as owner/repo#N, with " deploy" for a deploy ref.
private func names(_ refs: [PRRef]) -> [String] {
  refs.map { "\($0.repo)#\($0.number)\($0.deploy ? " deploy" : "")" }
}

private func refs(_ body: String) -> [String] {
  names(Dependencies.refs(inBody: body, repo: own))
}

@Suite struct DependencyBodyParsing {
  @Test(arguments: [
    ("Depends on #123", ["acme/widgets#123"]),
    ("Depends on PostHog/posthog#456", ["PostHog/posthog#456"]),
    ("Depends on https://github.com/PostHog/charts/pull/789", ["PostHog/charts#789"]),
    ("Depends on PostHog/posthog.com#20992", ["PostHog/posthog.com#20992"]),
    ("Depends on [the runbook](https://github.com/PostHog/charts/pull/18303)", ["PostHog/charts#18303"]),
  ])
  func lineNamesARefInEachForm(_ body: String, _ expected: [String]) {
    #expect(refs(body) == expected)
  }

  @Test func lineWithSeveralRefsGivesEachInOrder() {
    let body = "Depends on #1, PostHog/charts#2 and https://github.com/PostHog/posthog/pull/3"

    #expect(refs(body) == ["acme/widgets#1", "PostHog/charts#2", "PostHog/posthog#3"])
  }

  @Test func eachDependsOnLineInTheBodyCounts() {
    let body = "## Summary\n\nAdds the cache.\n\nDepends on #1\nDepends on PostHog/charts#2\n"

    #expect(refs(body) == ["acme/widgets#1", "PostHog/charts#2"])
  }

  @Test(arguments: [
    "depends on #5", "DEPENDS ON #5", "Depends On #5", "- Depends on #5", "* Depends on #5", "> Depends on #5",
    "> - Depends on #5", "  - Depends on #5", "\tDepends on #5", "**Depends on** #5", "_Depends on #5_",
    "__Depends on #5__",
  ])
  func caseAndLeadingMarkdownStillMatch(_ line: String) {
    #expect(refs(line) == ["acme/widgets#5"])
  }

  @Test(arguments: [
    ("Depends on PostHog/posthog#456 (deployed)", ["PostHog/posthog#456 deploy"]),
    ("Depends on the deploy of #5", ["acme/widgets#5 deploy"]),
    ("Depends on #5 (DEPLOYED)", ["acme/widgets#5 deploy"]),
    ("Depends on #5 and #6 (deployed)", ["acme/widgets#5 deploy", "acme/widgets#6 deploy"]),
  ])
  func lineThatSaysDeployGivesDeployRefs(_ body: String, _ expected: [String]) {
    #expect(refs(body) == expected)
  }

  @Test func deployAppliesOnlyToItsOwnLine() {
    #expect(refs("Depends on #5 (deployed)\nDepends on #6") == ["acme/widgets#5 deploy", "acme/widgets#6"])
  }

  /// GitHub stores bodies that people type in its web editor with CRLF line ends.
  @Test func crlfLineEndsSplitTheLines() {
    #expect(refs("Depends on #5\r\nDepends on #6 (deployed)\r\n") == ["acme/widgets#5", "acme/widgets#6 deploy"])
  }

  @Test(arguments: [
    "", "See #5", "Fixes #5", "Closes PostHog/posthog#5", "This depends on #5", "Related: depends on #5",
    "Depends onto #5", "Dependson #5", "Depends upon #5", "Follow-up to https://github.com/PostHog/charts/pull/5",
    "Depends on nothing yet", "Depends on https://github.com/PostHog/posthog/issues/5",
  ])
  func lineWithoutALeadingDependsOnGivesNothing(_ body: String) {
    #expect(refs(body).isEmpty)
  }

  @Test func mentionOnTheNextLineIsNotADependency() {
    #expect(refs("Depends on #5\nSee also #6 and PostHog/charts#7") == ["acme/widgets#5"])
  }

  @Test func hashRefUsesTheRepoItWasGiven() {
    #expect(names(Dependencies.refs(inBody: "Depends on #9", repo: "PostHog/charts")) == ["PostHog/charts#9"])
  }
}

@Suite struct DependencyResolution {
  @Test(arguments: [
    (PRState.merged, false, Bool?.none, true),
    (PRState.merged, true, Bool?.some(true), true),
    (PRState.merged, true, Bool?.some(false), false),
    (PRState.merged, true, Bool?.none, false),
    (PRState.open, false, Bool?.none, false),
    (PRState.open, true, Bool?.some(true), false),
    (PRState.closed, false, Bool?.none, false),
    (PRState.closed, true, Bool?.some(true), false),
  ])
  func resolvedOnlyOnceMergedAndDeployedWhenTheEdgeAsks(
    _ state: PRState, _ deploy: Bool, _ deployed: Bool?, _ resolved: Bool
  ) {
    let d = Dependency(via: .body, repo: own, number: 41, deploy: deploy, state: state, deployed: deployed)

    #expect(d.resolved == resolved)
  }

  @Test(arguments: [false, true])
  func unreadEdgeIsUnresolved(_ deploy: Bool) {
    let d = Dependency(via: .body, repo: own, number: 41, deploy: deploy, state: nil)

    #expect(d.resolved == false)
  }

  @Test(arguments: [(PRState?.some(.closed), true), (.some(.open), false), (.some(.merged), false), (.none, false)])
  func closedOnlyWhenClosedUnmerged(_ state: PRState?, _ closed: Bool) {
    let d = Dependency(via: .stack, repo: own, number: 41, base: "haacked/base", state: state)

    #expect(d.closed == closed)
  }
}

@Suite struct DependencyCoding {
  @Test func viaEncodesAsItsName() throws {
    #expect(Dependency.Via.stack.rawValue == "stack")
    #expect(Dependency.Via.body.rawValue == "body")
  }

  @Test func dependencyRoundTrips() throws {
    let d = Dependency(
      via: .stack, repo: own, number: 41, base: "haacked/base", deploy: true, state: .merged, deployed: false,
      session: "s2")

    let decoded = try JSONCoding.decode(Dependency.self, from: try JSON(encoding: d).text)

    #expect(decoded == d)
  }

  @Test func dependencyEncodesTheStateAsGitHubNamesIt() throws {
    let json = try JSON(encoding: Dependency(via: .body, repo: own, number: 41, state: .merged))

    #expect(json["via"]?.string == "body")
    #expect(json["state"]?.string == "MERGED")
  }

  @Test func prRefRoundTrips() throws {
    let r = PRRef(repo: "PostHog/posthog", number: 456, deploy: true)

    #expect(try JSONCoding.decode(PRRef.self, from: try JSON(encoding: r).text) == r)
  }

  @Test func pullRequestKeepsItsDependsOn() throws {
    var pr = samplePR()
    pr.dependsOn = [PRRef(repo: own, number: 41, deploy: false)]

    let decoded = try JSONCoding.decode(PullRequest.self, from: try JSON(encoding: pr).text)

    #expect(decoded.dependsOn == [PRRef(repo: own, number: 41, deploy: false)])
  }

  @Test func pullRequestThatAnOlderSbdRecordedHasNoDependsOn() throws {
    var pr = samplePR()
    pr.dependsOn = [PRRef(repo: own, number: 41, deploy: false)]
    var object = try #require(try JSON(encoding: pr).object)
    object["dependsOn"] = nil

    let decoded = try JSONCoding.decode(PullRequest.self, from: JSON.object(object).text)

    #expect(decoded.dependsOn == nil)
  }

  @Test func pullRequestInitTakesDependsOnLast() {
    let pr = PullRequest(
      id: "PR_1", number: 1, url: "u", repo: own, dependsOn: [PRRef(repo: own, number: 2, deploy: true)])

    #expect(pr.dependsOn == [PRRef(repo: own, number: 2, deploy: true)])
  }
}

private func dependenciesEvent(_ t: Int64, _ deps: [Dependency]) throws -> Event {
  event("dependencies", t, ["dependencies": try JSON(encoding: deps)])
}

private func bodyEdge(
  _ number: Int, repo: String = own, deploy: Bool = false, state: PRState? = .open, deployed: Bool? = nil,
  session: String? = nil
) -> Dependency {
  Dependency(via: .body, repo: repo, number: number, deploy: deploy, state: state, deployed: deployed, session: session)
}

private func stackEdge(_ number: Int, state: PRState? = .open, session: String? = "s2") -> Dependency {
  Dependency(via: .stack, repo: own, number: number, base: "haacked/base", state: state, session: session)
}

@Suite struct DependencyFacts {
  @Test func dependenciesEventSetsTheEdges() throws {
    let f = facts([try dependenciesEvent(1, [bodyEdge(41), stackEdge(40)])])

    #expect(f.dependencies == [bodyEdge(41), stackEdge(40)])
  }

  @Test func laterDependenciesEventReplacesTheEdges() throws {
    let f = facts([try dependenciesEvent(1, [bodyEdge(41), stackEdge(40)]), try dependenciesEvent(2, [bodyEdge(43)])])

    #expect(f.dependencies == [bodyEdge(43)])
  }

  @Test func emptyDependenciesEventClearsTheEdges() throws {
    let f = facts([try dependenciesEvent(1, [bodyEdge(41)]), try dependenciesEvent(2, [])])

    #expect(f.dependencies.isEmpty)
  }

  @Test func dependenciesEventIsNotActivity() throws {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Pushed."]),
      try dependenciesEvent(5, [bodyEdge(41)]),
    ])

    #expect(f.lastActivity == 1)
  }
}

private func prEvent(_ t: Int64, _ pr: PullRequest?, comments: [PRComment]) throws -> Event {
  event("pr", t, ["pr": try pr.map { try JSON(encoding: $0) } ?? .null, "comments": try JSON(encoding: comments)])
}

/// The facts of a session whose turn ended with `reply`, then got its PR and
/// then its edges. `then` holds the events that arrive after the edges.
private func edgeFacts(
  _ pr: PullRequest?, _ deps: [Dependency], comments: [PRComment] = [], dirty: Int? = nil,
  reply: String = "Pushed.", then: [Event] = []
) throws -> SessionFacts {
  var events = [
    event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": .string(reply)]),
    try prEvent(2, pr, comments: comments), try dependenciesEvent(3, deps),
  ]
  if let dirty { events.append(event("worktree", 4, ["dirty": .number(Double(dirty))])) }
  return facts(events + then)
}

private let trunk = PRComment(
  id: "IC_trunk", author: "trunk-io[bot]", createdAt: "2026-10-25T00:00:00Z", body: "<!-- Trunk Merge -->")
private let readsTheReply = Verdict(state: .needsYou, reason: "read its last reply and decide what's next")
private let conflict = Verdict(state: .needsYou, reason: "rebase; #42 conflicts with its base")
private let held41 = Verdict(state: .waiting, reason: "waits on #41")
private let replaces41 = Verdict(state: .needsYou, reason: "decide what replaces #41, which closed unmerged")
private let approvedByAlice = samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")])

@Suite struct ClosedDependencyAttention {
  static let now: Int64 = 10

  @Test(arguments: [false, true])
  func closedDependencyNeedsYou(_ stack: Bool) throws {
    let edge = stack ? stackEdge(41, state: .closed) : bodyEdge(41, state: .closed)
    let f = try edgeFacts(samplePR(), [edge])

    #expect(Attention.evaluate(session(), f, now: Self.now) == replaces41)
  }

  @Test func closedDependencyInAnotherRepoNamesItsRepo() throws {
    let f = try edgeFacts(samplePR(), [bodyEdge(7, repo: "acme/gears", state: .closed)])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "decide what replaces acme/gears#7, which closed unmerged"))
  }

  @Test(arguments: [
    PRAttention.everyRule,
    samplePR(mergeable: .conflicting),
    samplePR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)]),
    samplePR(base: "haacked/parent", mergedBase: 41),
    approvedByAlice,
    samplePR(queue: .removed),
    samplePR(reviewRequests: ["alex"]),
  ])
  func closedDependencyWinsOverThePRRules(_ pr: PullRequest) throws {
    let f = try edgeFacts(pr, [bodyEdge(41, state: .closed)], comments: [trunk])

    #expect(Attention.evaluate(session(), f, now: Self.now) == replaces41)
  }

  @Test func closedDependencyWinsOverAnEarlierUnresolvedOne() throws {
    let f = try edgeFacts(samplePR(), [bodyEdge(40), bodyEdge(41, state: .closed)])

    #expect(Attention.evaluate(session(), f, now: Self.now) == replaces41)
  }

  @Test func closedDependencyWinsOverStale() throws {
    let f = try edgeFacts(samplePR(), [bodyEdge(41, state: .closed)])

    #expect(Attention.evaluate(session(), f, now: Attention.staleAfterMs + 10) == replaces41)
  }

  @Test func runningTurnWinsOverAClosedDependency() throws {
    let f = try edgeFacts(
      samplePR(), [bodyEdge(41, state: .closed)], then: [event("UserPromptSubmit", 5, ["prompt": "keep going"])])

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .working)
  }
}

@Suite struct BusyBaseAttention {
  static let now: Int64 = 10
  static let busy = Verdict(state: .waiting, reason: "rebase onto #41 once its turn ends")

  private func verdict(_ deps: [Dependency], working: String) throws -> Verdict {
    let f = try edgeFacts(samplePR(mergeable: .conflicting), deps)
    return Attention.evaluate(session(), f, now: Self.now) { $0 == working ? .working : .needsYou }
  }

  @Test func conflictWhileTheBaseSessionWorksWaits() throws {
    #expect(try verdict([stackEdge(41, session: "s2")], working: "s2") == Self.busy)
  }

  @Test(arguments: [AttentionState.needsYou, .canContinue, .waiting, .done, .stale])
  func conflictWithAnIdleBaseNeedsYou(_ base: AttentionState) throws {
    let f = try edgeFacts(samplePR(mergeable: .conflicting), [stackEdge(41, session: "s2")])

    #expect(Attention.evaluate(session(), f, now: Self.now) { $0 == "s2" ? base : nil } == conflict)
  }

  @Test func conflictWithAnUnknownBaseSessionNeedsYou() throws {
    let f = try edgeFacts(samplePR(mergeable: .conflicting), [stackEdge(41, session: "s2")])

    #expect(Attention.evaluate(session(), f, now: Self.now) == conflict)
  }

  @Test func conflictWhileAnotherSessionWorksNeedsYou() throws {
    #expect(try verdict([stackEdge(41, session: "s2")], working: "s3") == conflict)
  }

  @Test func conflictWhileABodyDependencysSessionWorksNeedsYou() throws {
    #expect(try verdict([bodyEdge(41, session: "s2")], working: "s2") == conflict)
  }

  @Test func busyBaseWithoutAConflictIsHeldOnTheEdge() throws {
    let f = try edgeFacts(samplePR(), [stackEdge(41, session: "s2")])

    #expect(Attention.evaluate(session(), f, now: Self.now) { $0 == "s2" ? .working : nil } == held41)
  }

  @Test func busyBaseWinsOverTheLaterPRRules() throws {
    let pr = samplePR(
      mergeable: .conflicting, reviewDecision: .approved,
      verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)])
    let f = try edgeFacts(pr, [stackEdge(41, session: "s2")])

    #expect(Attention.evaluate(session(), f, now: Self.now) { $0 == "s2" ? .working : nil } == Self.busy)
  }
}

@Suite struct ApprovedWithDependencyAttention {
  static let now: Int64 = 10

  @Test func approvedPRWithAnUnresolvedDependencyIsNotMerged() throws {
    let f = try edgeFacts(approvedByAlice, [bodyEdge(41)])

    #expect(Attention.evaluate(session(), f, now: Self.now) == held41)
  }

  @Test func approvedPRThatTrunkManagesWithAnUnresolvedDependencyIsNotEnqueued() throws {
    let f = try edgeFacts(approvedByAlice, [stackEdge(41)], comments: [trunk])

    #expect(Attention.evaluate(session(), f, now: Self.now) == held41)
  }

  @Test func approvedPRWithAnUnreadDependencyIsNotMerged() throws {
    let f = try edgeFacts(approvedByAlice, [bodyEdge(41, state: nil)])

    #expect(Attention.evaluate(session(), f, now: Self.now) == held41)
  }

  @Test func approvedPRWithAnUndeployedDependencyIsNotMerged() throws {
    let f = try edgeFacts(approvedByAlice, [bodyEdge(41, deploy: true, state: .merged, deployed: false)])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .waiting, reason: "waits on the deploy of #41"))
  }

  @Test(arguments: [(false, Bool?.none), (true, Bool?.some(true))])
  func approvedPRWithResolvedDependenciesIsMerged(_ deploy: Bool, _ deployed: Bool?) throws {
    let f = try edgeFacts(approvedByAlice, [bodyEdge(41, deploy: deploy, state: .merged, deployed: deployed)])

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "merge #42, approved by alice"))
  }

  @Test func approvedPRWithAnUnresolvedDependencyAndAQuestionAnswersTheQuestion() throws {
    let f = try edgeFacts(approvedByAlice, [bodyEdge(41)], reply: "Which approach do you prefer?")

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .needsYou, reason: "answer: Which approach do you prefer?"))
  }
}

@Suite struct HeldAttention {
  static let now: Int64 = 10

  private func verdict(_ deps: [Dependency], pr: PullRequest = samplePR(), reply: String = "Pushed.") throws -> Verdict
  {
    Attention.evaluate(session(), try edgeFacts(pr, deps, reply: reply), now: Self.now)
  }

  @Test(arguments: [PRState?.some(.open), .none])
  func unresolvedBodyDependencyWaits(_ state: PRState?) throws {
    #expect(try verdict([bodyEdge(41, state: state)]) == held41)
  }

  @Test func unresolvedStackDependencyWaits() throws {
    #expect(try verdict([stackEdge(41)]) == held41)
  }

  @Test func dependencyInAnotherRepoNamesItsRepo() throws {
    #expect(
      try verdict([bodyEdge(7, repo: "acme/gears")]) == Verdict(state: .waiting, reason: "waits on acme/gears#7"))
  }

  @Test(arguments: [Bool?.some(false), .none])
  func mergedButUndeployedDependencyWaitsOnTheDeploy(_ deployed: Bool?) throws {
    let v = try verdict([bodyEdge(41, deploy: true, state: .merged, deployed: deployed)])

    #expect(v == Verdict(state: .waiting, reason: "waits on the deploy of #41"))
  }

  @Test func mergedButUndeployedDependencyInAnotherRepoNamesItsRepo() throws {
    let v = try verdict([bodyEdge(7, repo: "PostHog/posthog", deploy: true, state: .merged, deployed: false)])

    #expect(v == Verdict(state: .waiting, reason: "waits on the deploy of PostHog/posthog#7"))
  }

  @Test(arguments: [PRState?.some(.open), .none])
  func unmergedDeployDependencyWaitsOnTheMerge(_ state: PRState?) throws {
    #expect(try verdict([bodyEdge(41, deploy: true, state: state)]) == held41)
  }

  @Test func firstUnresolvedEdgeNamesTheReason() throws {
    let deps = [
      bodyEdge(40, state: .merged), bodyEdge(41), bodyEdge(43, deploy: true, state: .merged, deployed: false),
    ]

    #expect(try verdict(deps) == held41)
  }

  @Test func resolvedDependenciesDoNotHold() throws {
    let deps = [stackEdge(40, state: .merged), bodyEdge(43, deploy: true, state: .merged, deployed: true)]

    #expect(try verdict(deps) == readsTheReply)
  }

  @Test func noDependenciesDoNotHold() throws {
    #expect(try verdict([]) == readsTheReply)
  }

  @Test func reviewRequestWinsOverTheDependency() throws {
    #expect(
      try verdict([bodyEdge(41)], pr: samplePR(reviewRequests: ["alex"]))
        == Verdict(state: .waiting, reason: "review of #42 by alex"))
  }

  @Test func replyWithAQuestionStillNeedsYou() throws {
    #expect(
      try verdict([bodyEdge(41)], reply: "Which approach do you prefer?")
        == Verdict(state: .needsYou, reason: "answer: Which approach do you prefer?"))
  }

  @Test func replyWithAnOfferIsNotHeld() throws {
    #expect(try verdict([bodyEdge(41)], reply: "Want me to push?").state == .canContinue)
  }

  @Test func heldSessionDoesNotGoStale() throws {
    let f = try edgeFacts(samplePR(), [bodyEdge(41)])

    #expect(Attention.evaluate(session(), f, now: Attention.staleAfterMs + 10) == held41)
  }

  @Test func runningTurnIsWorkingNotHeld() throws {
    let f = try edgeFacts(samplePR(), [bodyEdge(41)], then: [event("UserPromptSubmit", 5, ["prompt": "keep going"])])

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .working)
  }

  @Test func manualWaitWinsOverTheDependency() throws {
    let f = try edgeFacts(samplePR(), [bodyEdge(41)])

    #expect(
      Attention.evaluate(session(wait: "run the app and look"), f, now: Self.now)
        == Verdict(state: .waiting, reason: "run the app and look"))
  }

  @Test(arguments: [
    (samplePR(mergeable: .conflicting), "rebase; #42 conflicts with its base"),
    (
      samplePR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)]),
      "address the changes that alice requested on #42"
    ),
    (samplePR(base: "haacked/parent", mergedBase: 40), "retarget #42; its base #40 merged"),
    (samplePR(queue: .removed), "find out why Trunk removed #42 from its queue"),
  ])
  func prRuleThatNeedsYouWinsOverTheDependency(_ pr: PullRequest, _ reason: String) throws {
    let f = try edgeFacts(pr, [bodyEdge(41)], comments: [trunk])

    #expect(Attention.evaluate(session(), f, now: Self.now) == Verdict(state: .needsYou, reason: reason))
  }
}

@Suite struct FinishedPRDependencyAttention {
  static let now: Int64 = 10

  @Test(arguments: [
    (PRState.merged, PRState?.some(.open)), (.merged, .some(.closed)), (.merged, .none), (.closed, .some(.open)),
    (.closed, .some(.closed)),
  ])
  func sessionWhoseOwnPRFinishedGetsNoDependencyRule(_ own: PRState, _ dependency: PRState?) throws {
    let f = try edgeFacts(samplePR(state: own), [bodyEdge(41, state: dependency)], dirty: 0)

    #expect(Attention.evaluate(session(), f, now: Self.now).state == .done)
  }

  @Test func mergedOwnPRWithAnUndeployedDependencyIsDone() throws {
    let f = try edgeFacts(
      samplePR(state: .merged), [bodyEdge(41, deploy: true, state: .merged, deployed: false)], dirty: 0)

    #expect(
      Attention.evaluate(session(), f, now: Self.now)
        == Verdict(state: .done, reason: "#42 merged; archive the worktree"))
  }

  @Test(arguments: [PRState?.some(.open), .some(.closed)])
  func sessionWithoutAPRGetsNoDependencyRule(_ dependency: PRState?) throws {
    let f = try edgeFacts(nil, [bodyEdge(41, state: dependency)])

    #expect(Attention.evaluate(session(), f, now: Self.now) == readsTheReply)
  }
}
