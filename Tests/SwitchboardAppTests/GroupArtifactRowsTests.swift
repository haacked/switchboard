import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000
private let minute: Int64 = 60_000
private let uuid = "00000000-1111-2222-3333-444444444444"
private let shortLink = "https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv"

private func row(
  url: String = shortLink, artifactId: String? = uuid, title: String = "Delta Rates", updated: Int64 = now - 5 * minute,
  removed: Int64? = nil, session: String = "s1", sessionName: String = "fix-cache"
) -> GroupArtifact {
  GroupArtifact(
    url: url, artifactId: artifactId, title: title, published: updated, updated: updated, removed: removed,
    session: session, sessionName: sessionName)
}

private func group(
  _ artifacts: [GroupArtifact]?, plans: [PlanSource] = [], links: [GroupLink]? = nil
) -> GroupSummary {
  var g = GroupSummary(SessionGroup(id: "g", name: "G", created: 0, links: links), sessions: ["s1"])
  g.artifacts = artifacts
  if !plans.isEmpty {
    g.plans = plans.enumerated().map { i, source in
      PlanSummary(PlanDocument(id: "p\(i + 1)", source: source, group: "g", attached: 0))
    }
  }
  return g
}

private func rows(
  _ artifacts: [GroupArtifact]?, plans: [PlanSource] = [], links: [GroupLink]? = nil,
  liveNames: [String: String] = ["s1": "fix-cache"]
) -> [GroupArtifactRows.Row] {
  GroupArtifactRows(group: group(artifacts, plans: plans, links: links), liveNames: liveNames, now: now).rows
}

/// A group link to an artifact, added five minutes before `now`.
private func groupLink(url: String = shortLink, by author: Author = .you) -> GroupLink {
  GroupLink(id: "l1", title: "Flag evaluations plan", url: url, by: author, t: now - 5 * minute)
}

/// The row of the group link.
private func linkRow(_ link: GroupLink = groupLink()) throws -> GroupArtifact {
  try #require(GroupArtifact(link: link))
}

@Suite struct GroupArtifactRowsTests {
  @Test func aLiveArtifactWithoutAPlanOffersUseAsPlan() {
    #expect(rows([row()]).map(\.action) == [.useAsPlan])
  }

  @Test func aRemovedArtifactSaysRemoved() {
    #expect(rows([row(removed: now - minute)]).map(\.action) == [.removed])
  }

  @Test func aGroupWithoutArtifactsHasNoRows() {
    #expect(rows(nil).isEmpty)
  }

  @Test func rowsKeepTheOrderThatSbdSorted() {
    let artifacts = [
      row(url: "https://claude.ai/artifact/b", artifactId: nil, updated: now - minute),
      row(url: "https://claude.ai/artifact/a", artifactId: nil, updated: now - 5 * minute),
    ]

    #expect(rows(artifacts).map(\.artifact.url) == artifacts.map(\.url))
  }

  @Test func captionSaysWhenTheArtifactWasLastUpdated() {
    #expect(rows([row(updated: now - 5 * minute)]).map(\.caption) == ["updated 5m ago"])
  }

  /// A plan "names" an artifact by the same rule that sbd uses to merge rows: the same normalized link, or a
  /// `/code/artifact/<uuid>` link whose uuid is the artifact's id. Only an artifact plan counts.
  @Test(arguments: [
    (PlanSource(kind: .artifact, url: shortLink), uuid as String?, GroupArtifactRows.Action.plan),
    (PlanSource(kind: .artifact, url: shortLink), nil, .plan),
    (PlanSource(kind: .artifact, url: "https://claude.ai/code/artifact/\(uuid)"), uuid, .plan),
    (PlanSource(kind: .artifact, url: "https://claude.ai/code/artifact/\(uuid)"), nil, .useAsPlan),
    (
      PlanSource(kind: .artifact, url: "https://claude.ai/code/artifact/99999999-1111-2222-3333-444444444444"), uuid,
      .useAsPlan
    ),
    (PlanSource(kind: .artifact, url: "https://claude.ai/artifact/SomeOtherArtifact"), uuid, .useAsPlan),
    (PlanSource(kind: .issue, url: shortLink), uuid, .useAsPlan),
    (PlanSource(kind: .artifact, url: nil), uuid, .useAsPlan),
    (PlanSource(kind: .file, path: "/tmp/plan.md"), uuid, .useAsPlan),
  ])
  func aPlanThatNamesTheArtifactTurnsUseAsPlanIntoPlan(
    _ plan: PlanSource, _ artifactId: String?, _ action: GroupArtifactRows.Action
  ) {
    #expect(rows([row(artifactId: artifactId)], plans: [plan]).map(\.action) == [action])
  }

  /// A plan stays attached after a delete removes its artifact.
  @Test func aRemovedArtifactThatAPlanNamesSaysPlan() {
    let plan = PlanSource(kind: .artifact, url: shortLink)

    #expect(rows([row(removed: now - minute)], plans: [plan]).map(\.action) == [.plan])
  }

  @Test func onlyTheArtifactThatThePlanNamesSaysPlan() {
    let artifacts = [
      row(url: shortLink, artifactId: uuid, updated: now - minute),
      row(url: "https://claude.ai/artifact/Other", artifactId: nil, updated: now - 5 * minute),
    ]
    let plan = PlanSource(kind: .artifact, url: "https://claude.ai/code/artifact/\(uuid)")

    #expect(rows(artifacts, plans: [plan]).map(\.action) == [.plan, .useAsPlan])
  }

  /// The row's `sessionName` is the name when sbd built or kept it. A live session's current name wins.
  @Test func aLiveSessionIsLabeledWithItsCurrentName() {
    let label = rows([row(session: "s1", sessionName: "old-name")], liveNames: ["s1": "new-name"]).map(\.sessionLabel)

    #expect(label == ["by new-name"])
  }

  @Test func aRemovedSessionIsLabeledWithTheNameTheRowKept() {
    let label = rows([row(session: "s9", sessionName: "gone-session")], liveNames: ["s1": "fix-cache"]).map(
      \.sessionLabel)

    #expect(label == ["by gone-session"])
  }

  @Test func linkTitleIsNilForAGroupWithoutArtifacts() {
    #expect(GroupArtifactRows(group: group(nil), liveNames: [:], now: now).linkTitle == nil)
  }

  @Test func linkTitleCountsOnlyTheArtifactsThatAreNotRemoved() {
    let artifacts = [
      row(url: "https://claude.ai/artifact/a", artifactId: nil),
      row(url: "https://claude.ai/artifact/b", artifactId: nil, removed: now - minute),
      row(url: "https://claude.ai/artifact/c", artifactId: nil),
    ]

    #expect(GroupArtifactRows(group: group(artifacts), liveNames: [:], now: now).linkTitle == "Artifacts 2")
  }

  /// The link shows whenever the list is not empty, so a group whose artifacts were all deleted still lists them.
  @Test func linkTitleLeavesOutAZeroCountWhenEveryArtifactIsRemoved() {
    let artifacts = [row(removed: now - minute)]

    #expect(GroupArtifactRows(group: group(artifacts), liveNames: [:], now: now).linkTitle == "Artifacts")
  }

  // MARK: A row from a group link

  @Test(arguments: [(Author.you, "added by you"), (.claude, "added by Claude")])
  func aLinkOnlyRowIsLabeledWithWhoAddedTheLink(_ author: Author, _ label: String) throws {
    let link = groupLink(by: author)

    #expect(rows([try linkRow(link)], links: [link]).map(\.sessionLabel) == [label])
  }

  @Test func aLinkOnlyRowsCaptionSaysWhenTheLinkWasAdded() throws {
    #expect(rows([try linkRow()], links: [groupLink()]).map(\.caption) == ["added 5m ago"])
  }

  @Test func aLinkOnlyRowOffersUseAsPlan() throws {
    #expect(rows([try linkRow()], links: [groupLink()]).map(\.action) == [.useAsPlan])
  }

  @Test func aLinkOnlyRowThatAPlanNamesSaysPlan() throws {
    let plan = PlanSource(kind: .artifact, url: shortLink)

    #expect(rows([try linkRow()], plans: [plan], links: [groupLink()]).map(\.action) == [.plan])
  }

  /// A session row that a link also names keeps the session's label and caption.
  @Test func aSessionRowWithALinkIsLabeledWithTheSession() throws {
    var r = row(session: "s1", sessionName: "fix-cache")
    r.link = "l1"

    let labeled = try #require(rows([r], links: [groupLink(by: .claude)]).first)

    #expect(labeled.sessionLabel == "by fix-cache")
    #expect(labeled.caption == "updated 5m ago")
  }

  @Test func linkTitleCountsLinkRows() throws {
    let artifacts = [
      row(url: "https://claude.ai/artifact/a", artifactId: nil),
      try linkRow(groupLink(url: "https://claude.ai/artifact/b")),
    ]

    #expect(GroupArtifactRows(group: group(artifacts), liveNames: [:], now: now).linkTitle == "Artifacts 2")
  }
}
