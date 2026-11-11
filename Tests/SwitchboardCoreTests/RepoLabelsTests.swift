import Testing

@testable import SwitchboardCore

private let other = "/Users/me/dev/acme/other"

private func session(
  _ id: String, repo: String? = nil, checkout: String? = nil, repository: String? = nil, pr: String? = nil,
  followup: Followup? = nil, manager: Bool = false
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: repo ?? "/tmp", repo: repo, branch: nil, claudeSessionId: id, state: .working,
    reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [],
    notes: [], pr: pr.map(prSummary))
  s.followup = followup
  s.checkout = checkout
  s.repository = repository
  if manager {
    s.manager = true
    s.kind = .manager
  }
  return s
}

private func prSummary(_ repo: String) -> PRSummary {
  PRSummary(PullRequest(id: repo, number: 1, url: "https://github.com/\(repo)/pull/1", repo: repo))
}

private func followup(_ repository: String?) -> Followup {
  Followup(prompt: "p", repository: repository)
}

@Suite struct RepoLabelsTests {

  struct SourceCase: Sendable, CustomTestStringConvertible {
    var name: String
    var repo: String?
    var pr: String?
    var followup: String?
    var label: String
    var testDescription: String { name }
  }

  @Test(arguments: [
    SourceCase(name: "folder", repo: "/Users/me/dev/haacked/switchboard", label: "switchboard"),
    SourceCase(name: "PR without a folder", pr: "PostHog/posthog", label: "posthog"),
    SourceCase(name: "follow-up without a folder or PR", followup: "PostHog/posthog", label: "posthog"),
    SourceCase(name: "PR before follow-up", pr: "acme/widgets", followup: "acme/gadgets", label: "widgets"),
    SourceCase(
      name: "folder before follow-up", repo: "/Users/me/dev/acme/widgets", followup: "acme/gadgets",
      label: "widgets"),
  ])
  func labelsASessionWithTheShortNameOfItsFirstRepoSource(_ c: SourceCase) {
    let sessions = [
      session("s", repo: c.repo, pr: c.pr, followup: c.followup.map(followup)), session("o", repo: other),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels["s"] == c.label)
  }

  @Test(arguments: [
    ("no folder, PR, or follow-up", nil as Followup?),
    ("a follow-up with no repository", followup(nil)),
  ])
  func givesNoLabelToASessionWithNoRepo(_ name: String, _ followup: Followup?) {
    let sessions = [
      session("none", followup: followup), session("a", repo: "/Users/me/dev/a/alpha"),
      session("b", repo: "/Users/me/dev/b/beta"),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a": "alpha", "b": "beta"])
  }

  @Test func labelsOneRepoOnlyWhenAsked() {
    let folder = "/Users/me/dev/haacked/switchboard"
    let sessions = [session("a", repo: folder), session("b", repo: folder, pr: "haacked/switchboard"), session("none")]

    #expect(RepoLabels.labels(sessions).isEmpty)
    #expect(RepoLabels.labels(sessions, evenForOneRepo: true) == ["a": "switchboard", "b": "switchboard"])
  }

  @Test func evenForOneRepoGivesNoLabelWhenNoSessionHasARepo() {
    #expect(RepoLabels.labels([session("none")], evenForOneRepo: true).isEmpty)
  }

  @Test func countsAStartedFollowupWithoutAPRAndAWaitingFollowupForItsRepoAsOneRepo() {
    let sessions = [
      session("started", repo: "/Users/me/dev/haacked/switchboard", followup: followup("haacked/switchboard")),
      session("waiting", followup: followup("haacked/switchboard")),
    ]

    #expect(RepoLabels.labels(sessions).isEmpty)
  }

  @Test func labelsEverySessionWithARepoOnceASecondRepoIsPresent() {
    let sessions = [
      session("a1", repo: "/Users/me/dev/haacked/switchboard"),
      session("a2", repo: "/Users/me/dev/haacked/switchboard"),
      session("b", pr: "PostHog/posthog"),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a1": "switchboard", "a2": "switchboard", "b": "posthog"])
  }

  @Test(arguments: [
    ("no sessions", [SessionSummary]()),
    ("no session has a repo", [session("a"), session("b", followup: followup(nil))]),
    ("one folder", [session("a", repo: "/Users/me/dev/haacked/switchboard")]),
    (
      "two sessions in one folder",
      [
        session("a", repo: "/Users/me/dev/haacked/switchboard"),
        session("b", repo: "/Users/me/dev/haacked/switchboard"),
      ]
    ),
    ("one repo and a session with no repo", [session("a", repo: "/Users/me/dev/haacked/switchboard"), session("b")]),
    ("two sessions with one PR repo", [session("a", pr: "PostHog/posthog"), session("b", pr: "PostHog/posthog")]),
    (
      "a PR and a follow-up in one repo",
      [session("a", pr: "PostHog/posthog"), session("b", followup: followup("PostHog/posthog"))]
    ),
  ])
  func hidesEveryLabelWhenTheSessionsSpanFewerThanTwoRepos(_ name: String, _ sessions: [SessionSummary]) {
    #expect(RepoLabels.labels(sessions).isEmpty)
  }

  @Test func countsAFolderItsPRAndSessionsWithOnlyThatPRAsOneRepo() {
    let folder = "/Users/me/dev/haacked/switchboard"
    let sessions = [
      session("withPR", repo: folder, repository: "haacked/switchboard", pr: "haacked/switchboard"),
      session("sameFolder", repo: folder, repository: "haacked/switchboard"),
      session("imported", pr: "haacked/switchboard"), session("followup", followup: followup("haacked/switchboard")),
    ]

    #expect(RepoLabels.labels(sessions).isEmpty)
  }

  @Test func labelsAFolderAndSessionsWithOnlyItsPRTheSameWhenASecondRepoIsPresent() {
    let folder = "/Users/me/dev/haacked/switchboard"
    let sessions = [
      session("withPR", repo: folder, repository: "haacked/switchboard", pr: "haacked/switchboard"),
      session("sameFolder", repo: folder, repository: "haacked/switchboard"),
      session("imported", pr: "haacked/switchboard"), session("o", repo: other),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["withPR": "switchboard", "sameFolder": "switchboard", "imported": "switchboard", "o": "other"])
  }

  @Test(arguments: [
    ("owner and name", "PostHog/posthog", "posthog/PostHog"),
    ("owner only", "PostHog/posthog", "posthog/posthog"),
    ("name only", "acme/Widgets", "acme/widgets"),
  ])
  func comparesGitHubNamesWithoutCase(_ name: String, _ first: String, _ second: String) {
    let sessions = [session("a", pr: first), session("b", pr: second)]

    #expect(RepoLabels.labels(sessions).isEmpty)
  }

  @Test func matchesAFolderToItsPRRepoWithoutCase() {
    let folder = "/Users/me/dev/PostHog/posthog"
    let sessions = [
      session("withPR", repo: folder, repository: "PostHog/posthog", pr: "PostHog/posthog"),
      session("sameFolder", repo: folder, repository: "PostHog/posthog"), session("imported", pr: "posthog/posthog"),
    ]

    #expect(RepoLabels.labels(sessions).isEmpty)
  }

  @Test func doesNotTreatADifferenceOfCaseAsAFork() {
    let sessions = [
      session("a", repo: "/Users/me/dev/a/posthog", repository: "PostHog/posthog"),
      session("b", repo: "/Users/me/dev/b/posthog", repository: "posthog/posthog"), session("o", repo: other),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a": "posthog", "b": "posthog", "o": "other"])
  }

  @Test func showsOwnerAndNameForForksWithPRs() {
    let sessions = [
      session("fork", repo: "/Users/me/dev/haacked/posthog", repository: "haacked/posthog", pr: "haacked/posthog"),
      session("upstream", repo: "/Users/me/dev/PostHog/posthog", repository: "PostHog/posthog", pr: "PostHog/posthog"),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["fork": "haacked/posthog", "upstream": "PostHog/posthog"])
  }

  @Test func showsOwnerAndNameForForksKnownOnlyByPRs() {
    let sessions = [session("fork", pr: "haacked/posthog"), session("upstream", pr: "PostHog/posthog")]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["fork": "haacked/posthog", "upstream": "PostHog/posthog"])
  }

  @Test func showsOwnerAndNameForForksKnownByFollowups() {
    let sessions = [
      session("fork", followup: followup("haacked/posthog")),
      session("upstream", followup: followup("PostHog/posthog")),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["fork": "haacked/posthog", "upstream": "PostHog/posthog"])
  }

  @Test func showsOwnerAndNameOnASessionInAForkFolderWithoutAPR() {
    let folder = "/Users/me/dev/fork/posthog"
    let sessions = [
      session("withPR", repo: folder, repository: "haacked/posthog", pr: "haacked/posthog"),
      session("sameFolder", repo: folder, repository: "haacked/posthog"), session("upstream", pr: "PostHog/posthog"),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels["sameFolder"] == "haacked/posthog")
  }

  @Test(arguments: [
    ("/Users/me/a/switchboard", "/Users/me/b/switchboard", "a/switchboard", "b/switchboard"),
    ("/Users/me/x/a/switchboard", "/Users/me/y/a/switchboard", "x/a/switchboard", "y/a/switchboard"),
    ("/Users/me/dev/switchboard", "/Users/me/old/dev/switchboard", "me/dev/switchboard", "old/dev/switchboard"),
    ("/Users/me/a/Switchboard", "/Users/me/b/switchboard", "a/Switchboard", "b/switchboard"),
  ])
  func showsTheShortestUniqueTrailingPathForFoldersWithTheSameName(
    _ first: String, _ second: String, _ firstLabel: String, _ secondLabel: String
  ) {
    let sessions = [session("a", repo: first), session("b", repo: second)]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a": firstLabel, "b": secondLabel])
  }

  @Test func keepsTheShortNameOfARepoThatDoesNotCollide() {
    let sessions = [
      session("fork", pr: "haacked/posthog"), session("upstream", pr: "PostHog/posthog"),
      session("a", repo: "/Users/me/a/switchboard"), session("b", repo: "/Users/me/b/switchboard"),
      session("o", repo: other),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels["o"] == "other")
  }

  @Test func neverLabelsTheManager() {
    let sessions = [
      session("m", repo: "/Users/me/dev/haacked/switchboard", manager: true),
      session("a", repo: "/Users/me/dev/haacked/switchboard"), session("b", pr: "PostHog/posthog"),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels["m"] == nil)
  }

  @Test func doesNotCountTheManagerTowardTheRepos() {
    let sessions = [
      session("m", repo: "/Users/me/dev/haacked/switchboard", manager: true), session("b", pr: "PostHog/posthog"),
    ]

    #expect(RepoLabels.labels(sessions).isEmpty)
  }

  @Test func doesNotLetTheManagerCauseACollision() {
    let sessions = [
      session("m", repo: "/Users/me/old/posthog", pr: "haacked/posthog", manager: true),
      session("a", pr: "PostHog/posthog"), session("o", repo: other),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a": "posthog", "o": "other"])
  }

  @Test(arguments: [
    ("abcdefghijklmnopqrstuvwxyz0123", "abcdefghijklmnopqrstuvwxyz0123"),
    ("abcdefghijklmnopqrstuvwxyz01234", "…cdefghijklmnopqrstuvwxyz01234"),
    ("abcdefghijklmnopqrstuvwxyz0123456789", "…hijklmnopqrstuvwxyz0123456789"),
  ])
  func capsAFolderLabelAtThirtyCharactersKeepingTheEnd(_ name: String, _ label: String) {
    let sessions = [session("a", repo: "/Users/me/dev/\(name)"), session("o", repo: other)]

    let labels = RepoLabels.labels(sessions)

    #expect(labels["a"] == label)
  }

  @Test func capsAnOwnerAndNameLabelAtThirtyCharacters() {
    let sessions = [
      session("fork", pr: "haacked-long-owner/posthog-repo"), session("upstream", pr: "PostHog/posthog-repo"),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels["fork"] == "haacked-long-o…/posthog-repo")
  }

  @Test func keepsTheOwnerOfACappedForkLabel() {
    let sessions = [
      session("fork", pr: "haacked/terraform-provider-posthog-extra"),
      session("upstream", pr: "PostHog/terraform-provider-posthog-extra"),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(
      labels == ["fork": "haacked/…rovider-posthog-extra", "upstream": "PostHog/…rovider-posthog-extra"])
  }

  @Test func keepsTheParentOfACappedFolderLabel() {
    let name = "abcdefghijklmnopqrstuvwxyz0123456789"
    let sessions = [session("a", repo: "/Users/me/a/\(name)"), session("b", repo: "/Users/me/b/\(name)")]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a": "a/…jklmnopqrstuvwxyz0123456789", "b": "b/…jklmnopqrstuvwxyz0123456789"])
  }

  @Test func namesAFolderByItsLastComponentEvenWhenItsRepositoryNamesItDifferently() {
    let sessions = [
      session("a", repo: "/Users/me/dev/ph", repository: "PostHog/posthog", pr: "PostHog/posthog"),
      session("b", pr: "PostHog/posthog"), session("o", repo: other),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a": "ph", "b": "ph", "o": "other"])
  }

  /// Nothing ties a folder without a repository to an owner/name. The folder
  /// counts as a second repo. Its label grows until it differs from owner/name.
  @Test func keepsAFolderWithoutARepositoryApartFromAPRRepoOfTheSameName() {
    let sessions = [session("f", repo: "/x/haacked/switchboard"), session("p", pr: "haacked/switchboard")]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["f": "x/haacked/switchboard", "p": "haacked/switchboard"])
  }

  @Test func treatsAFolderWithATrailingSlashAsTheSameFolder() {
    let sessions = [
      session("a", repo: "/Users/me/dev/switchboard"), session("b", repo: "/Users/me/dev/switchboard/"),
      session("o", repo: other),
    ]

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["a": "switchboard", "b": "switchboard", "o": "other"])
  }

  @Test func labelsAWorktreeThatSbdDidNotMakeWithItsMainCheckoutsName() {
    let sessions = [
      session("external", checkout: "/Users/me/dev/haacked/switchboard"), session("o", repo: other),
    ]

    #expect(RepoLabels.labels(sessions) == ["external": "switchboard", "o": "other"])
  }

  @Test func countsAnSbdWorktreeAndAnotherWorktreeOfItsCheckoutAsOneRepo() {
    let sessions = [
      session("sbd", repo: "/tmp/dev/switchboard", checkout: "/private/tmp/dev/switchboard"),
      session("external", checkout: "/private/tmp/dev/switchboard"),
    ]

    #expect(RepoLabels.labels(sessions).isEmpty)
    #expect(RepoLabels.labels(sessions, evenForOneRepo: true) == ["sbd": "switchboard", "external": "switchboard"])
  }

  @Test func givesNoLabelToAFolderOutsideGitAndDoesNotCountIt() {
    let sessions = [session("plain"), session("external", checkout: "/Users/me/dev/haacked/switchboard")]

    #expect(RepoLabels.labels(sessions).isEmpty)
    #expect(RepoLabels.labels(sessions, evenForOneRepo: true) == ["external": "switchboard"])
  }

  @Test func givesNoLabelToTheManagerOrAChatInACheckout() {
    var chat = session("chat", checkout: "/Users/me/dev/acme/chat")
    chat.chat = "g1"
    chat.kind = .chat
    let sessions = [
      session("manager", checkout: "/Users/me/dev/acme/manager", manager: true), chat,
      session("a", checkout: "/Users/me/dev/a/alpha"), session("b", checkout: "/Users/me/dev/b/beta"),
    ]

    #expect(RepoLabels.labels(sessions) == ["a": "alpha", "b": "beta"])
  }

  /// sbd fills `repository` after the first summary, so one session of a
  /// checkout can have it before another does.
  @Test func takesTheRepositoryOfAnotherSessionInTheSameCheckout() {
    let checkout = "/Users/me/dev/haacked/switchboard"
    let sessions = [
      session("external", checkout: checkout),
      session("sbd", repo: checkout, checkout: checkout, repository: "haacked/switchboard", pr: "haacked/switchboard"),
      session("imported", pr: "haacked/switchboard"),
    ]

    #expect(RepoLabels.labels(sessions).isEmpty)
    #expect(
      RepoLabels.labels(sessions, evenForOneRepo: true)
        == ["sbd": "switchboard", "external": "switchboard", "imported": "switchboard"])
  }

  // MARK: Board lanes

  /// A session in the posthog checkout whose transcript linked a switchboard
  /// PR. The folder's other sessions and the switchboard checkout surround it.
  static func sessionsWithAForeignPR(foreignFirst: Bool) -> [SessionSummary] {
    let posthog = "/Users/me/dev/posthog/posthog"
    let foreign = session("foreign", checkout: posthog, repository: "PostHog/posthog", pr: "haacked/switchboard")
    let rest = [
      session("withPR", checkout: posthog, repository: "PostHog/posthog", pr: "PostHog/posthog"),
      session("noPR", checkout: posthog, repository: "PostHog/posthog"),
      session(
        "switchboard", repo: "/Users/me/dev/haacked/switchboard", repository: "haacked/switchboard",
        pr: "haacked/switchboard"),
    ]
    return foreignFirst ? [foreign] + rest : rest + [foreign]
  }

  @Test(arguments: [true, false])
  func keepsAFoldersRepositoryWhenOneSessionsPRIsFromAnotherRepo(foreignFirst: Bool) {
    let sessions = Self.sessionsWithAForeignPR(foreignFirst: foreignFirst)

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(
      labels == [
        "foreign": "PostHog/posthog", "withPR": "PostHog/posthog", "noPR": "PostHog/posthog",
        "switchboard": "haacked/switchboard",
      ])
  }

  @Test(arguments: [true, false])
  func keepsAFoldersShortLabelWhenOneSessionsPRIsFromAnotherRepo(foreignFirst: Bool) {
    let sessions = Self.sessionsWithAForeignPR(foreignFirst: foreignFirst)

    let labels = RepoLabels.labels(sessions)

    #expect(labels == ["foreign": "posthog", "withPR": "posthog", "noPR": "posthog", "switchboard": "switchboard"])
  }

  @Test func labelsALaneWithOwnerAndNameWhenFullNameIsOn() {
    let sessions = [
      session("folder", repo: "/Users/me/dev/sb", repository: "haacked/switchboard"),
      session("imported", pr: "PostHog/posthog"), session("waiting", followup: followup("acme/widgets")),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(labels == ["folder": "haacked/switchboard", "imported": "PostHog/posthog", "waiting": "acme/widgets"])
  }

  @Test func labelsOneRepoWithOwnerAndNameWhenFullNameIsOn() {
    let sessions = [session("folder", repo: "/Users/me/dev/sb", repository: "haacked/switchboard")]

    #expect(RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true) == ["folder": "haacked/switchboard"])
  }

  @Test func capsAnOwnerAndNameLaneLabelAtThirtyCharacters() {
    let sessions = [session("a", repo: "/Users/me/dev/p", repository: "haacked-long-owner/posthog-repo")]

    #expect(RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true) == ["a": "haacked-long-o…/posthog-repo"])
  }

  @Test func labelsAFolderWithoutARepositoryByItsFolderNameNotItsPR() {
    let sessions = [
      session("folder", repo: "/Users/me/dev/work/ph", pr: "PostHog/posthog"),
      session("imported", pr: "PostHog/posthog"),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(labels == ["folder": "ph", "imported": "PostHog/posthog"])
  }

  /// An sbd older than `repository` sends summaries without it.
  @Test func fallsBackToFolderFormsForASummaryWithoutRepository() {
    let sessions = [
      session("a", checkout: "/Users/me/a/switchboard"), session("b", checkout: "/Users/me/b/switchboard"),
      session("c", checkout: "/Users/me/dev/charts"),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(labels == ["a": "a/switchboard", "b": "b/switchboard", "c": "charts"])
  }

  @Test func keepsThePRRepoForASessionWithNoFolder() {
    let sessions = [
      session("folder", repo: "/Users/me/dev/posthog", repository: "PostHog/posthog"),
      session("imported", pr: "PostHog/posthog"), session("waiting", followup: followup("PostHog/posthog")),
      session("other", pr: "haacked/switchboard"),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(
      labels == [
        "folder": "PostHog/posthog", "imported": "PostHog/posthog", "waiting": "PostHog/posthog",
        "other": "haacked/switchboard",
      ])
  }

  @Test func labelsTwoClonesOfOneRepoTheSame() {
    let sessions = [
      session("a", repo: "/Users/me/dev/posthog", repository: "PostHog/posthog"),
      session("b", checkout: "/Users/me/old/posthog-clone", repository: "PostHog/posthog"),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(labels == ["a": "PostHog/posthog", "b": "PostHog/posthog"])
  }

  @Test func labelsAForkCheckoutByItsOriginWhenItsPRIsUpstream() {
    let sessions = [
      session("fork", repo: "/Users/me/dev/fork/posthog", repository: "haacked/posthog", pr: "PostHog/posthog"),
      session("upstream", repo: "/Users/me/dev/PostHog/posthog", repository: "PostHog/posthog"),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(labels == ["fork": "haacked/posthog", "upstream": "PostHog/posthog"])
  }

  @Test func prefersASessionsRepositoryToAStartedFollowupsRepository() {
    let folder = "/Users/me/dev/widgets"
    let sessions = [
      session("started", repo: folder, followup: followup("acme/gadgets")),
      session("plain", repo: folder, repository: "acme/widgets"),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(labels == ["started": "acme/widgets", "plain": "acme/widgets"])
  }

  @Test func takesAStartedFollowupsRepositoryWhenNoSessionInTheFolderHasOne() {
    let folder = "/Users/me/dev/widgets"
    let sessions = [
      session("plain", repo: folder), session("started", repo: folder, followup: followup("acme/widgets")),
    ]

    let labels = RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true)

    #expect(labels == ["plain": "acme/widgets", "started": "acme/widgets"])
  }
}
