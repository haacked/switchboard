import Foundation
import SwitchboardCore
import Testing

private let posthog = "PostHog/posthog"
/// #122953's head branch.
private let baseBranch = "haacked/cdp-dlq-breaker-counts-lookups"
/// #122896's head branch.
private let dependentBranch = "haacked/mcp-experiment-condition-ids"
/// The stack edge from #122896 to #122953.
private let edgeReason = "#122896 depends on #122953"

/// Makes #122896's base #122953's head branch, as a stacked PR's base is.
/// The base ref names no merged PR, so the retarget rule does not fire.
private func stack(_ github: FakeGitHub) {
  github.change(122896) {
    $0["baseRefName"] = .string(baseBranch)
    $0["baseRef"] = ["associatedPullRequests": ["nodes": []]]
  }
}

/// Group suggestions from dependencies. The helpers come from `GroupTests`.
extension GroupTests {
  /// An sbd whose GitHub stacks #122896 on #122953. The fake must live as
  /// long as the test, because the poller asks it.
  func stackedInstance() throws -> (FakeGitHub, Instance) {
    let github = try FakeGitHub()
    stack(github)
    return (github, try Instance.withGitHub(github))
  }

  func accept(_ sbd: Instance, _ id: String) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb("group", "suggest", "--json", "--accept", id))
  }

  func mergeId(_ a: GroupSummary, _ b: GroupSummary) -> String {
    "merge:" + [a.id, b.id].sorted().joined(separator: ":")
  }

  /// Two groups that the stack edge from top (#122896) to base (#122953) links.
  struct Linked {
    /// The poller asks it, so it lives as long as the test.
    let github: FakeGitHub
    let sbd: Instance
    let flags: GroupSummary
    let docs: GroupSummary
    /// In Flags, placed by hand.
    let base: SessionSummary
    /// In Docs, from its parent lead, so not placed by hand.
    let top: SessionSummary
    let lead: SessionSummary
  }

  /// Flags holds base and lead, both placed by hand. Docs holds only top,
  /// which took Docs from its parent lead before lead moved to Flags. Flags
  /// has more sessions placed by hand, so it survives a merge that moves top.
  func linkedGroups() throws -> Linked {
    let (github, sbd) = try stackedInstance()
    let lead = try sbd.new(name: "lead")
    let docs = try add(sbd, "Docs", lead.id)
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top", parent: lead.id)
    try #require(top.group == docs.id)
    let base = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let flags = try add(sbd, "Flags", base.id)
    try sbd.sb("group", "move", lead.id, "--to", "Flags")
    try sbd.pollTwice()
    return Linked(github: github, sbd: sbd, flags: flags, docs: docs, base: base, top: top, lead: lead)
  }

  // MARK: Merges

  @Test func anEdgeAcrossGroupsSuggestsMergingThem() throws {
    let l = try linkedGroups()

    let found = try suggestions(l.sbd)

    #expect(
      found == [
        GroupSuggestion(
          id: mergeId(l.flags, l.docs), name: "Flags", group: l.flags.id, sessions: [l.top.id], reason: edgeReason,
          merge: GroupSuggestion.Merge(group: l.docs.id, name: "Docs"))
      ])
  }

  @Test func acceptingAMergeMovesTheSessionDeletesTheAbsorbedGroupAndKeepsItsNotes() throws {
    let l = try linkedGroups()
    try l.sbd.sb("group", "note", "Flags", "Flags first.")
    try l.sbd.sb("group", "note", "Docs", "Ship by Friday")
    try l.sbd.sb("group", "note", "Docs", "Ask Ana first.")

    let accepted = try accept(l.sbd, mergeId(l.flags, l.docs))

    #expect(accepted.id == l.flags.id)
    #expect(Set(accepted.sessions) == [l.base.id, l.lead.id, l.top.id])
    #expect(try l.sbd.get(l.top.id).group == l.flags.id)
    let groups = try list(l.sbd).groups
    #expect(groups.map(\.id) == [l.flags.id])
    #expect(groups.first?.notes.map(\.text) == ["Flags first.", "Ship by Friday", "Ask Ana first."])
    #expect(try suggestions(l.sbd).isEmpty)
  }

  @Test func suggestPrintsAMergeAsWhatItDoes() throws {
    let l = try linkedGroups()

    let text = try l.sbd.sb("group", "suggest")

    #expect(text.contains("\(mergeId(l.flags, l.docs))  merge Docs into Flags: \(l.top.id) (\(edgeReason))"))
  }

  // MARK: Declines

  @Test func aDeclinedSuggestionStaysDeclinedAfterAPollAndARestart() throws {
    let l = try linkedGroups()
    let id = mergeId(l.flags, l.docs)

    let declined = try decode(JSON.self, l.sbd.sb("group", "suggest", "--json", "--decline", id))

    #expect(declined["declined"]?.string == id)
    #expect(try !suggestions(l.sbd).contains { $0.id == id })
    try l.sbd.pollTwice()
    #expect(try !suggestions(l.sbd).contains { $0.id == id })
    l.sbd.stopSbd()
    try l.sbd.startSbd()
    try l.sbd.pollTwice()
    // The edge is still there, so only the decline keeps the merge out.
    #expect(try l.sbd.edges(l.top.id)?.map(\.session) == [l.base.id])
    #expect(try !suggestions(l.sbd).contains { $0.id == id })
    #expect(try l.sbd.get(l.top.id).group == l.docs.id)
  }

  @Test func declinePrintsTheId() throws {
    let l = try linkedGroups()
    let id = mergeId(l.flags, l.docs)

    let text = try l.sbd.sb("group", "suggest", "--decline", id)

    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "declined \(id)")
  }

  @Test func declineRefusesAnIdThatTheSuggestionsDontHave() throws {
    let l = try linkedGroups()

    let declined = try l.sbd.run(["group", "suggest", "--json", "--decline", "merge:gnone1:gnone2"])

    #expect(declined.status != 0)
    #expect(try suggestions(l.sbd).map(\.id) == [mergeId(l.flags, l.docs)])
  }

  // MARK: Sessions placed by hand

  @Test func aSessionPlacedByHandStaysInItsGroupWhichSurvivesTheMerge() throws {
    let (github, sbd) = try stackedInstance()
    defer { withExtendedLifetime(github) {} }
    // Docs holds lead, placed by hand, and its child top.
    let lead = try sbd.new(name: "lead")
    let docs = try add(sbd, "Docs", lead.id)
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top", parent: lead.id)
    // Flags holds two sessions placed by hand, so it survives.
    let base = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let other = try sbd.new(name: "other")
    let flags = try add(sbd, "Flags", base.id, other.id)
    try sbd.sb("group", "note", "Docs", "Ship by Friday")
    try sbd.pollTwice()
    let merge = try #require(try suggestions(sbd).first { $0.merge != nil })
    #expect(merge.group == flags.id)
    #expect(merge.sessions == [top.id])
    #expect(merge.stays == [lead.id])

    _ = try accept(sbd, merge.id)

    #expect(try sbd.get(top.id).group == flags.id)
    #expect(try sbd.get(lead.id).group == docs.id)
    let kept = try #require(try list(sbd).groups.first { $0.id == docs.id })
    #expect(kept.sessions == [lead.id])
    #expect(kept.notes.map(\.text) == ["Ship by Friday"])
    #expect(try suggestions(sbd).isEmpty)
  }

  // MARK: Ungrouped sessions

  /// Which end of the edge starts in the group.
  enum GroupedEnd: CaseIterable { case base, top }

  @Test(arguments: GroupedEnd.allCases)
  func anUngroupedSessionGetsAJoinAndAcceptingPlacesIt(_ end: GroupedEnd) throws {
    let (github, sbd) = try stackedInstance()
    defer { withExtendedLifetime(github) {} }
    let base = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")
    let (grouped, loose) = end == .base ? (base, top) : (top, base)
    let flags = try add(sbd, "Flags", grouped.id)
    try sbd.pollTwice()

    let join = try #require(try suggestions(sbd).first { $0.sessions.contains(loose.id) })
    #expect(join.id == "dependency:\(loose.id):\(flags.id)")
    #expect(join.group == flags.id)
    #expect(join.name == "Flags")
    #expect(join.sessions == [loose.id])
    #expect(join.reason == edgeReason)

    let accepted = try accept(sbd, join.id)

    #expect(accepted.id == flags.id)
    #expect(Set(accepted.sessions) == [base.id, top.id])
    #expect(try sbd.get(loose.id).group == flags.id)
    #expect(try !suggestions(sbd).contains { $0.sessions.contains(loose.id) })
  }
}
