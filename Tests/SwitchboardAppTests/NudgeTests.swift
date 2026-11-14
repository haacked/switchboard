import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000
private let minute: Int64 = 60_000
private let hour: Int64 = 60 * minute
private let day: Int64 = 24 * hour

private let flagsGist = "It caches flag reads per request."
private let url1234 = "https://github.com/PostHog/posthog/pull/1234"

private func nudgePR(
  number: Int = 1234, repo: String = "PostHog/posthog", title: String = "Cache flag reads", gist: String? = nil,
  additions: Int? = nil, deletions: Int? = nil, codeOwners: CodeOwnerStatus? = nil, rereview: Rereview? = nil
) -> PRSummary {
  var pr = PRSummary(
    PullRequest(id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo))
  pr.title = title
  pr.gist = gist
  pr.additions = additions
  pr.deletions = deletions
  pr.codeOwners = codeOwners
  pr.rereview = rereview
  return pr
}

/// A work session whose PR entered `column` at `since`. Only an In review placement names reviewers, as sbd
/// places it.
private func placed(
  _ column: BoardColumn, since: Int64, reviewers: [String]? = ["alice"], pr: PRSummary? = nudgePR(),
  state: AttentionState = .waiting, id: String = "s1"
) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.pr = pr
  s.board = BoardPlacement(column: column, since: since, reviewers: column == .inReview ? reviewers : nil)
  return s
}

/// A Waiting card whose change request the author answered at `repliedAt`. `reviewers` sets the
/// placement's reviewers, which sbd leaves nil in Waiting, so a test can show they are not what decides.
private func rereviewCard(
  repliedAt: Int64, rereviewers: [String] = ["mariusandra"], since: Int64 = now - 3 * day,
  reviewers: [String]? = nil, pr: PRSummary = nudgePR(), state: AttentionState = .waiting, id: String = "s1"
) -> SessionSummary {
  var withRereview = pr
  withRereview.rereview = Rereview(reviewers: rereviewers, repliedAt: repliedAt)
  var s = needsItem(id, state: state)
  s.pr = withRereview
  s.board = BoardPlacement(
    column: .waiting, since: since, line: "changes requested by \(englishList(rereviewers))", holder: .you,
    reviewers: reviewers)
  return s
}

/// An In review card `id` for PR `number`, which entered review at `since` and waits on `reviewers`.
private func reviewCard(
  _ id: String, number: Int, since: Int64 = now - 5 * hour, reviewers: [String] = ["@PostHog/team-hogql"],
  title: String = "Cache flag reads", gist: String? = nil, codeOwners: CodeOwnerStatus? = nil,
  state: AttentionState = .waiting
) -> SessionSummary {
  placed(
    .inReview, since: since, reviewers: reviewers,
    pr: nudgePR(number: number, title: title, gist: gist, codeOwners: codeOwners), state: state, id: id)
}

private func teamOwners(_ owners: [String]) -> CodeOwnerStatus {
  CodeOwnerStatus(satisfied: false, groups: [CodeOwnerGroup(owners: owners, approved: false)])
}

/// A code owner status with a group for each entry, each an owner list and whether the group approved.
private func ownerGroups(_ groups: [([String], Bool)]) -> CodeOwnerStatus {
  CodeOwnerStatus(
    satisfied: groups.allSatisfy { $0.1 }, groups: groups.map { CodeOwnerGroup(owners: $0.0, approved: $0.1) })
}

/// A session in `repository`, whose folder every session of that repository shares, so each repository
/// gets its own Board lane. An In review card waits on team-hogql.
private func laneCard(_ id: String, _ repository: String, number: Int, _ column: BoardColumn) -> SessionSummary {
  var s = orgSession(id, repository, state: .waiting)
  s.repo = "/r/\(repository)"
  s.pr = nudgePR(number: number, repo: repository, gist: flagsGist)
  s.board = BoardPlacement(
    column: column, since: now - 5 * hour, reviewers: column == .inReview ? ["@PostHog/team-hogql"] : nil)
  return s
}

/// The PR numbers of a Nudge all message's bullets, which read `- #N: …`.
private func bulletNumbers(_ text: String) -> Set<Int> {
  Set(
    text.split(separator: "\n").compactMap { line -> Int? in
      guard line.hasPrefix("- #") else { return nil }
      return Int(line.dropFirst(3).prefix { $0.isNumber })
    })
}

/// The teams that the Nudge all parity board names.
private let candidateTeams = ["@PostHog/team-flags", "@PostHog/team-hogql", "@PostHog/team-replay"]

@Suite struct NudgeTests {
  // MARK: The ask

  @Suite struct Ask {
    @Test func oneTeamAndAGist() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["@PostHog/team-flags"])

      #expect(
        text == "Could someone from @PostHog/team-flags review #1234? It caches flag reads per request. \(url1234)")
    }

    @Test func oneLoginAndAGist() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["alice"])

      #expect(text == "@alice could you review #1234? It caches flag reads per request. \(url1234)")
    }

    @Test func twoLoginsAskOneOfThem() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["alice", "bob"])

      #expect(text == "@alice and @bob, could one of you review #1234? It caches flag reads per request. \(url1234)")
    }

    @Test func twoTeamsAskOneOfThem() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["@PostHog/team-flags", "@PostHog/team-hogql"])

      #expect(
        text
          == "@PostHog/team-flags and @PostHog/team-hogql, could one of you review #1234? It caches flag reads per request. \(url1234)"
      )
    }

    @Test func aMixedListUsesTheEnglishList() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["@PostHog/team-flags", "alice", "@bob"])

      #expect(
        text
          == "@PostHog/team-flags, @alice, and @bob, could one of you review #1234? It caches flag reads per request. \(url1234)"
      )
    }

    /// An In review card can wait on a review that nobody was asked for, so the nudge names no one.
    @Test func noReviewersAsksForAReview() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: [])

      #expect(text == "Could I get a review of #1234? It caches flag reads per request. \(url1234)")
    }

    @Test func everyReviewerIsMentionedOnce() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["alice", "bob", "@PostHog/team-flags"])

      for mention in ["@alice", "@bob", "@PostHog/team-flags"] {
        #expect(text.components(separatedBy: mention).count == 2, "\(mention) in \(text)")
      }
    }

    @Test func endsWithThePRsURL() {
      let text = Nudge.text(pr: nudgePR(number: 77, repo: "haacked/switchboard", gist: flagsGist), reviewers: ["alice"])

      #expect(text.hasSuffix(" https://github.com/haacked/switchboard/pull/77"))
    }
  }

  // MARK: The title fallback

  /// Without a gist the ask keeps the title in parentheses. With a gist the title is left out.
  @Suite struct TitleFallback {
    @Test func aTeamAskWithoutAGistNamesTheTitle() {
      let text = Nudge.text(pr: nudgePR(), reviewers: ["@PostHog/team-flags"])

      #expect(text == "Could someone from @PostHog/team-flags review #1234 (Cache flag reads)? \(url1234)")
    }

    @Test func aLoginAskWithoutAGistNamesTheTitle() {
      let text = Nudge.text(pr: nudgePR(), reviewers: ["alice"])

      #expect(text == "@alice could you review #1234 (Cache flag reads)? \(url1234)")
    }

    @Test func anAskOfNobodyWithoutAGistNamesTheTitle() {
      let text = Nudge.text(pr: nudgePR(), reviewers: [])

      #expect(text == "Could I get a review of #1234 (Cache flag reads)? \(url1234)")
    }

    @Test func anEmptyTitleLeavesOutTheParentheses() {
      let text = Nudge.text(pr: nudgePR(title: ""), reviewers: ["alice"])

      #expect(text == "@alice could you review #1234? \(url1234)")
    }

    @Test func aTitleWithParenthesesIsKeptAsIs() {
      let text = Nudge.text(pr: nudgePR(title: "Fix (again) the cache"), reviewers: ["alice"])

      #expect(text.contains("#1234 (Fix (again) the cache)?"))
    }

    @Test func aGistLeavesOutTheTitle() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["alice"])

      #expect(!text.contains("Cache flag reads"))
    }
  }

  // MARK: Size

  @Suite struct Size {
    @Test func theSmallThresholdIsAHundredLines() {
      #expect(Nudge.smallLines == 100)
    }

    @Test func aSmallPRSaysSoAfterTheGist() {
      let text = Nudge.text(
        pr: nudgePR(gist: flagsGist, additions: 30, deletions: 12), reviewers: ["@PostHog/team-flags"])

      #expect(
        text
          == "Could someone from @PostHog/team-flags review #1234? It caches flag reads per request. This is a small one. \(url1234)"
      )
    }

    @Test func aSmallPRWithoutAGistSaysSoAfterTheAsk() {
      let text = Nudge.text(pr: nudgePR(additions: 30, deletions: 12), reviewers: ["alice"])

      #expect(text == "@alice could you review #1234 (Cache flag reads)? This is a small one. \(url1234)")
    }

    /// The additions and deletions add up to the changed lines, and exactly 100 is still small.
    @Test(arguments: [(60, 40, true), (100, 0, true), (0, 100, true), (0, 0, true), (60, 41, false), (101, 0, false)])
    func smallMeansAtMostAHundredChangedLines(_ additions: Int, _ deletions: Int, _ small: Bool) {
      let text = Nudge.text(
        pr: nudgePR(gist: flagsGist, additions: additions, deletions: deletions), reviewers: ["alice"])

      #expect(text.contains("This is a small one.") == small, "\(text)")
    }

    @Test(arguments: [(Int?.none, Int?.none), (30, nil), (nil, 12)])
    func anUnknownSizeSaysNothing(_ additions: Int?, _ deletions: Int?) {
      let text = Nudge.text(
        pr: nudgePR(gist: flagsGist, additions: additions, deletions: deletions), reviewers: ["alice"])

      #expect(!text.contains("small"), "\(text)")
    }
  }

  // MARK: The code-owner sentence

  /// The owners asked are the addressees, in their mention form and lowercased, that own a group that has
  /// not approved.
  @Suite struct CodeOwner {
    @Test func theAskedTeamOwningAWaitingGroupIsYourTeam() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@PostHog/team-flags"]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags"])

      #expect(
        text
          == "Could someone from @PostHog/team-flags review #1234? It caches flag reads per request. It needs a code-owner approval from your team. \(url1234)"
      )
    }

    @Test func theAskedLoginOwningAWaitingGroupIsYourApproval() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@alice"]))

      let text = Nudge.text(pr: pr, reviewers: ["alice"])

      #expect(
        text
          == "@alice could you review #1234? It caches flag reads per request. It needs your code-owner approval. \(url1234)"
      )
    }

    @Test func twoAskedOwnersOfOneWaitingGroupAreOneOfYou() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@alice", "@bob"]))

      let text = Nudge.text(pr: pr, reviewers: ["alice", "bob"])

      #expect(
        text
          == "@alice and @bob, could one of you review #1234? It caches flag reads per request. It needs a code-owner approval from one of you. \(url1234)"
      )
    }

    @Test func aTeamAndALoginOfOneWaitingGroupAreOneOfYou() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@PostHog/team-flags", "@alice"]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags", "alice"])

      #expect(text.contains(" It needs a code-owner approval from one of you. "), "\(text)")
    }

    @Test func anApprovedGroupGivesNoSentence() {
      let pr = nudgePR(gist: flagsGist, codeOwners: ownerGroups([(["@PostHog/team-flags"], true)]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags"])

      #expect(
        text == "Could someone from @PostHog/team-flags review #1234? It caches flag reads per request. \(url1234)")
    }

    /// The asked team approved its group, and another team's group waits.
    @Test func anAskedOwnerOfOnlyAnApprovedGroupGivesNoSentence() {
      let pr = nudgePR(
        gist: flagsGist,
        codeOwners: ownerGroups([(["@PostHog/team-flags"], true), (["@PostHog/team-hogql"], false)]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags"])

      #expect(!text.contains("code-owner"), "\(text)")
    }

    @Test func noCodeOwnersGivesNoSentence() {
      let text = Nudge.text(pr: nudgePR(gist: flagsGist, codeOwners: nil), reviewers: ["@PostHog/team-flags"])

      #expect(!text.contains("code-owner"), "\(text)")
    }

    @Test func aTeamOwnerInAnotherCaseStillMatches() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@posthog/Team-Flags"]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags"])

      #expect(text.contains(" It needs a code-owner approval from your team. "), "\(text)")
    }

    @Test func aBareSlugThatResolvesToTheOwningTeamMatches() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@PostHog/team-flags"]))

      let text = Nudge.text(pr: pr, reviewers: ["team-flags"])

      #expect(
        text
          == "Could someone from @PostHog/team-flags review #1234? It caches flag reads per request. It needs a code-owner approval from your team. \(url1234)"
      )
    }

    /// A code owner team of another org does not resolve the bare slug, so it stays `@team-flags`.
    @Test func aBareSlugThatDoesNotResolveDoesNotMatch() {
      let pr = nudgePR(
        gist: flagsGist,
        codeOwners: ownerGroups([(["@acme/team-flags"], false), (["@PostHog/team-replay"], false)]))

      let text = Nudge.text(pr: pr, reviewers: ["team-flags"])

      #expect(!text.contains("code-owner"), "\(text)")
    }

    @Test func anAddresseeInNoGroupGivesNoSentence() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@carol"]))

      let text = Nudge.text(pr: pr, reviewers: ["alice"])

      #expect(!text.contains("code-owner"), "\(text)")
    }

    @Test func oneOwnerAmongTheAddresseesIsNamed() {
      let pr = nudgePR(gist: flagsGist, codeOwners: teamOwners(["@PostHog/team-flags"]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags", "alice"])

      #expect(
        text
          == "@PostHog/team-flags and @alice, could one of you review #1234? It caches flag reads per request. It needs code-owner approval from @PostHog/team-flags. \(url1234)"
      )
    }

    @Test func addresseesInTwoWaitingGroupsAreListed() {
      let pr = nudgePR(
        gist: flagsGist,
        codeOwners: ownerGroups([(["@PostHog/team-flags"], false), (["@PostHog/team-hogql"], false)]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags", "@PostHog/team-hogql"])

      #expect(
        text
          == "@PostHog/team-flags and @PostHog/team-hogql, could one of you review #1234? It caches flag reads per request. It needs code-owner approval from @PostHog/team-flags and @PostHog/team-hogql. \(url1234)"
      )
    }

    /// The parts run ask, gist, size, code owner, then the URL, because Slack does not link `#N`.
    @Test func thePartsRunInOrder() {
      let pr = nudgePR(
        gist: flagsGist, additions: 30, deletions: 12, codeOwners: teamOwners(["@PostHog/team-flags"]))

      let text = Nudge.text(pr: pr, reviewers: ["@PostHog/team-flags"])

      #expect(
        text
          == "Could someone from @PostHog/team-flags review #1234? It caches flag reads per request. This is a small one. It needs a code-owner approval from your team. \(url1234)"
      )
    }
  }

  // MARK: Re-review

  @Suite struct Rereviews {
    @Test func oneReviewerIsAskedForAnotherLook() {
      let text = Nudge.rereviewText(pr: nudgePR(), rereview: Rereview(reviewers: ["mariusandra"], repliedAt: now))

      #expect(
        text
          == "@mariusandra could you take another look at #1234? Ready for a re-review (I replied to the feedback). \(url1234)"
      )
    }

    @Test func twoReviewersGetACommaBeforeCould() {
      let text = Nudge.rereviewText(
        pr: nudgePR(), rereview: Rereview(reviewers: ["alice", "mariusandra"], repliedAt: now))

      #expect(
        text
          == "@alice and @mariusandra, could you take another look at #1234? Ready for a re-review (I replied to the feedback). \(url1234)"
      )
    }

    @Test func threeReviewersUseTheEnglishList() {
      let text = Nudge.rereviewText(
        pr: nudgePR(), rereview: Rereview(reviewers: ["alice", "bob", "mariusandra"], repliedAt: now))

      #expect(text.hasPrefix("@alice, @bob, and @mariusandra, could you take another look at #1234?"))
    }

    /// The reviewer already knows the PR.
    @Test func leavesOutTheGistSizeAndCodeOwnerSentence() {
      let pr = nudgePR(
        gist: flagsGist, additions: 30, deletions: 12, codeOwners: teamOwners(["@mariusandra"]))

      let text = Nudge.rereviewText(pr: pr, rereview: Rereview(reviewers: ["mariusandra"], repliedAt: now))

      #expect(
        text
          == "@mariusandra could you take another look at #1234? Ready for a re-review (I replied to the feedback). \(url1234)"
      )
    }

    @Test func showsOnAWaitingCardFromFourHoursAfterTheReply() {
      #expect(Nudge.shows(rereviewCard(repliedAt: now - 5 * hour), now: now))
      #expect(Nudge.shows(rereviewCard(repliedAt: now - 4 * hour), now: now))
    }

    @Test func hidesOnAWaitingCardBeforeFourHoursAfterTheReply() {
      #expect(!Nudge.shows(rereviewCard(repliedAt: now - 3 * hour), now: now))
      #expect(!Nudge.shows(rereviewCard(repliedAt: now - 4 * hour + minute), now: now))
    }

    /// The delay counts from the reply, not from when the card entered Waiting.
    @Test func countsFromTheReplyNotThePlacement() {
      #expect(Nudge.shows(rereviewCard(repliedAt: now - 5 * hour, since: now - minute), now: now))
      #expect(!Nudge.shows(rereviewCard(repliedAt: now - 3 * hour, since: now - 3 * day), now: now))
    }

    @Test func neverShowsOnADoneSession() {
      #expect(!Nudge.shows(rereviewCard(repliedAt: now - 5 * hour, state: .done), now: now))
    }

    @Test(arguments: [BoardColumn.inProgress, .approved, .merging, .done])
    func neverShowsOutsideWaiting(_ column: BoardColumn) {
      var s = rereviewCard(repliedAt: now - 5 * hour)
      s.board?.column = column

      #expect(!Nudge.shows(s, now: now))
    }

    @Test func theSessionsNudgeIsTheReReviewText() {
      let s = rereviewCard(repliedAt: now - 5 * hour)

      #expect(
        Nudge.text(for: s, now: now)
          == "@mariusandra could you take another look at #1234? Ready for a re-review (I replied to the feedback). \(url1234)"
      )
    }

    @Test func theSessionsNudgeIsNilBeforeTheDelay() {
      #expect(Nudge.text(for: rereviewCard(repliedAt: now - 3 * hour), now: now) == nil)
    }
  }

  // MARK: Mentions

  /// A reviewer name comes in one of these forms. A code owner request is `@login` or `@org/team`. A review
  /// request is a bare login or a bare team slug, and sbd does not record which. So a bare name counts as a
  /// team only when the PR's code owner groups name that team, and then it takes its org from `pr.repo`.
  @Suite struct Mentions {
    @Test(arguments: ["@alice", "@PostHog/team-flags", "@posthog/Team-Flags"])
    func aCodeOwnerFormIsKeptAsIs(_ name: String) {
      #expect(Nudge.mention(name, pr: nudgePR()) == name)
    }

    @Test func aBareLoginGetsAnAt() {
      #expect(Nudge.mention("alice", pr: nudgePR()) == "@alice")
    }

    @Test func aBareOrgAndTeamGetsAnAt() {
      #expect(Nudge.mention("PostHog/team-flags", pr: nudgePR()) == "@PostHog/team-flags")
    }

    @Test func aBareSlugOfACodeOwnerTeamTakesItsOrgFromTheRepo() {
      let pr = nudgePR(repo: "PostHog/posthog", codeOwners: teamOwners(["@PostHog/team-flags"]))

      #expect(Nudge.mention("team-flags", pr: pr) == "@PostHog/team-flags")
    }

    /// The org keeps the case that `pr.repo` gives it, which is the case GitHub shows.
    @Test func theTeamsOrgKeepsTheRepoOwnersCase() {
      let pr = nudgePR(repo: "PostHog/posthog", codeOwners: teamOwners(["@posthog/team-flags"]))

      #expect(Nudge.mention("team-flags", pr: pr) == "@PostHog/team-flags")
    }

    @Test func aBareSlugMatchesACodeOwnerTeamWithoutRegardToCase() {
      let pr = nudgePR(repo: "PostHog/posthog", codeOwners: teamOwners(["@PostHog/Team-Flags"]))

      #expect(Nudge.mention("team-flags", pr: pr) == "@PostHog/team-flags")
    }

    /// A code owner team in another org is not this team: GitHub only asks teams of the repo's own org.
    @Test func aCodeOwnerTeamOfAnotherOrgDoesNotMakeABareNameATeam() {
      let pr = nudgePR(repo: "PostHog/posthog", codeOwners: teamOwners(["@acme/team-flags"]))

      #expect(Nudge.mention("team-flags", pr: pr) == "@team-flags")
    }

    @Test func aBareNameThatMatchesACodeOwnerLoginStaysALogin() {
      let pr = nudgePR(codeOwners: teamOwners(["@alice", "@PostHog/team-flags"]))

      #expect(Nudge.mention("alice", pr: pr) == "@alice")
    }

    @Test func aBareNameThatNoCodeOwnerTeamNamesIsALogin() {
      let pr = nudgePR(codeOwners: teamOwners(["@PostHog/team-flags"]))

      #expect(Nudge.mention("team-replay", pr: pr) == "@team-replay")
    }

    @Test func aPRWithoutCodeOwnersMakesEveryBareNameALogin() {
      #expect(Nudge.mention("team-flags", pr: nudgePR(codeOwners: nil)) == "@team-flags")
    }

    @Test func theTextUsesTheMentionForms() {
      let pr = nudgePR(gist: flagsGist, codeOwners: ownerGroups([(["@PostHog/team-flags"], true)]))

      let text = Nudge.text(pr: pr, reviewers: ["team-flags", "alice", "@bob"])

      #expect(text.hasPrefix("@PostHog/team-flags, @alice, and @bob, could one of you review #1234"))
    }
  }

  // MARK: Showing

  @Suite struct Showing {
    @Test func theDelayIsFourHours() {
      #expect(Nudge.delay == 4 * hour)
    }

    /// "After 4 hours" reads as from the 4-hour mark on.
    @Test func showsOnAnInReviewCardFromFourHoursInReview() {
      #expect(Nudge.shows(placed(.inReview, since: now - 4 * hour), now: now))
      #expect(Nudge.shows(placed(.inReview, since: now - 3 * day), now: now))
    }

    @Test func hidesOnAnInReviewCardBeforeFourHoursInReview() {
      #expect(!Nudge.shows(placed(.inReview, since: now - 4 * hour + minute), now: now))
      #expect(!Nudge.shows(placed(.inReview, since: now), now: now))
    }

    /// A card outside In review shows Nudge only for a re-review, which these PRs lack.
    @Test(arguments: [BoardColumn.inProgress, .waiting, .approved, .merging, .done])
    func neverShowsOutsideInReviewWithoutAReReview(_ column: BoardColumn) {
      #expect(!Nudge.shows(placed(column, since: now - 3 * day), now: now))
    }

    @Test func neverShowsWithoutAPlacement() {
      var s = placed(.inReview, since: now - 3 * day)
      s.board = nil

      #expect(!Nudge.shows(s, now: now))
    }

    @Test func neverShowsWithoutAPR() {
      #expect(!Nudge.shows(placed(.inReview, since: now - 3 * day, pr: nil), now: now))
    }

    /// The card's time in review is the placement's, not the time the session entered its state.
    @Test func countsFromWhenThePREnteredReviewNotTheSessionsState() {
      var fresh = placed(.inReview, since: now - minute)
      fresh.since = now - 3 * day
      var old = placed(.inReview, since: now - 5 * hour)
      old.since = now

      #expect(!Nudge.shows(fresh, now: now))
      #expect(Nudge.shows(old, now: now))
    }

    /// The Done footer draws a Done session whatever its placement says, and nobody reviews a finished task.
    @Test func neverShowsOnADoneSession() {
      #expect(!Nudge.shows(placed(.inReview, since: now - 3 * day, state: .done), now: now))
    }

    /// Needs you never moves a card out of In review, so its Nudge still shows.
    @Test func showsOnANeedsYouCardInReview() {
      #expect(Nudge.shows(placed(.inReview, since: now - 5 * hour, state: .needsYou), now: now))
    }
  }

  // MARK: The session's nudge

  @Suite struct ForASession {
    @Test func isTheTextForThePlacementsReviewers() {
      let s = placed(.inReview, since: now - 5 * hour, reviewers: ["alice"])

      #expect(Nudge.text(for: s, now: now) == Nudge.text(pr: nudgePR(), reviewers: ["alice"]))
    }

    /// The code owner `@org/team` form exists only in the placement, because `PRSummary` carries no code
    /// owner requests. So the nudge reads the placement's reviewers, not the PR's review requests.
    @Test func readsThePlacementsReviewersNotThePRsReviewRequests() throws {
      var pr = nudgePR()
      pr.reviewRequests = ["carol"]
      let s = placed(.inReview, since: now - 5 * hour, reviewers: ["@PostHog/team-flags"], pr: pr)

      let text = try #require(Nudge.text(for: s, now: now))

      #expect(text.hasPrefix("Could someone from @PostHog/team-flags review #1234"))
      #expect(!text.contains("carol"))
    }

    @Test func aPlacementWithoutReviewersAsksForAReview() throws {
      let s = placed(.inReview, since: now - 5 * hour, reviewers: nil)

      let text = try #require(Nudge.text(for: s, now: now))

      #expect(text.hasPrefix("Could I get a review of #1234"))
    }

    @Test func isNilWhileTheNudgeDoesNotShow() {
      #expect(Nudge.text(for: placed(.inReview, since: now - hour), now: now) == nil)
      #expect(Nudge.text(for: placed(.waiting, since: now - 3 * day), now: now) == nil)
      #expect(Nudge.text(for: placed(.inReview, since: now - 3 * day, pr: nil), now: now) == nil)
    }
  }

  // MARK: No wait time

  @Suite struct NoWaitTime {
    @Test func noNudgeNamesTheWait() throws {
      let single = Nudge.text(pr: nudgePR(gist: flagsGist), reviewers: ["alice"])
      let titled = Nudge.text(pr: nudgePR(), reviewers: [])
      let session = try #require(Nudge.text(for: placed(.inReview, since: now - 9 * day), now: now))
      let rereview = try #require(Nudge.text(for: rereviewCard(repliedAt: now - 9 * day), now: now))
      let team = try #require(
        Nudge.teams([reviewCard("a", number: 1, since: now - 9 * day), reviewCard("b", number: 2)], now: now).first)

      for text in [single, titled, session, rereview, Nudge.allText(team)] {
        #expect(!text.contains("waited"), "\(text)")
      }
    }
  }

  // MARK: Nudge all

  @Suite struct NudgeAll {
    /// Three PRs on team-hogql, given out of board order. The newest has no gist.
    private static let hogqlCards = [
      reviewCard("c", number: 103, since: now - 5 * hour, title: "Fix the parser"),
      reviewCard(
        "a", number: 101, since: now - 3 * day, gist: "It caches flag reads per request. It also logs each miss."),
      reviewCard("b", number: 102, since: now - 2 * day, gist: "It retries failed exports."),
    ]

    @Test func listsEachPRWithItsLeadOrTitleInBoardOrder() throws {
      let team = try #require(Nudge.teams(Self.hogqlCards, now: now).first)

      #expect(
        Nudge.allText(team) == """
          Could someone from @PostHog/team-hogql review these 3 PRs?

          - #101: It caches flag reads per request. https://github.com/PostHog/posthog/pull/101
          - #102: It retries failed exports. https://github.com/PostHog/posthog/pull/102
          - #103: Fix the parser https://github.com/PostHog/posthog/pull/103
          """)
    }

    @Test func theTeamIsTheOneTheCardsWaitOn() {
      let teams = Nudge.teams(Self.hogqlCards, now: now)

      #expect(teams.map(\.mention) == ["@PostHog/team-hogql"])
    }

    @Test func theSessionsAreInBoardOrder() throws {
      let team = try #require(Nudge.teams(Self.hogqlCards, now: now).first)

      #expect(team.sessions.map(\.id) == ["a", "b", "c"])
    }

    /// `MergeBoard.cards` breaks a tie in time by the session's id.
    @Test func cardsThatEnteredReviewTogetherGoInIdOrder() throws {
      let cards = [reviewCard("y", number: 2, since: now - day), reviewCard("x", number: 1, since: now - day)]

      let team = try #require(Nudge.teams(cards, now: now).first)

      #expect(team.sessions.map(\.id) == ["x", "y"])
    }

    @Test func everyPRNeedingTheTeamsApprovalSaysSoOnce() throws {
      let owners = teamOwners(["@PostHog/team-hogql"])
      let cards = [
        reviewCard(
          "a", number: 101, since: now - 3 * day, gist: "It caches flag reads per request.", codeOwners: owners),
        reviewCard("b", number: 102, since: now - 2 * day, gist: "It retries failed exports.", codeOwners: owners),
        reviewCard("c", number: 103, since: now - 5 * hour, gist: "It fixes the parser.", codeOwners: owners),
      ]
      let team = try #require(Nudge.teams(cards, now: now).first)

      #expect(
        Nudge.allText(team) == """
          Could someone from @PostHog/team-hogql review these 3 PRs? Each needs a code-owner approval from your team.

          - #101: It caches flag reads per request. https://github.com/PostHog/posthog/pull/101
          - #102: It retries failed exports. https://github.com/PostHog/posthog/pull/102
          - #103: It fixes the parser. https://github.com/PostHog/posthog/pull/103
          """)
    }

    @Test func onlyThePRsNeedingTheTeamsApprovalSaySo() throws {
      let cards = [
        reviewCard("a", number: 101, since: now - 3 * day, gist: "It caches flag reads per request."),
        reviewCard(
          "b", number: 102, since: now - 2 * day, gist: "It retries failed exports.",
          codeOwners: teamOwners(["@PostHog/team-hogql"])),
        reviewCard("c", number: 103, since: now - 5 * hour, gist: "It fixes the parser."),
      ]
      let team = try #require(Nudge.teams(cards, now: now).first)

      #expect(
        Nudge.allText(team) == """
          Could someone from @PostHog/team-hogql review these 3 PRs?

          - #101: It caches flag reads per request. https://github.com/PostHog/posthog/pull/101
          - #102: It retries failed exports. Needs your code-owner approval. https://github.com/PostHog/posthog/pull/102
          - #103: It fixes the parser. https://github.com/PostHog/posthog/pull/103
          """)
    }

    /// An approved group does not need the team, so no PR says it does.
    @Test func anApprovedGroupDoesNotNeedTheTeam() throws {
      let cards = [
        reviewCard(
          "a", number: 101, since: now - 3 * day, gist: "It caches flag reads per request.",
          codeOwners: ownerGroups([(["@PostHog/team-hogql"], true)])),
        reviewCard("b", number: 102, since: now - 2 * day, gist: "It retries failed exports."),
      ]
      let team = try #require(Nudge.teams(cards, now: now).first)

      #expect(!Nudge.allText(team).contains("code-owner"))
    }
  }

  // MARK: Nudge all grouping

  /// The forms one team's mention takes across cards, and the cards that Nudge all leaves out.
  @Suite struct TeamGrouping {
    @Test func aTeamInTwoCasesIsOneGroup() {
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day, reviewers: ["@PostHog/team-flags"]),
        reviewCard("b", number: 2, since: now - day, reviewers: ["@posthog/Team-Flags"]),
      ]

      let teams = Nudge.teams(cards, now: now)

      #expect(teams.count == 1)
      #expect(teams.first?.sessions.map(\.id) == ["a", "b"])
    }

    /// The display form is the first card's mention.
    @Test func aTeamInTwoCasesShowsTheFirstCardsForm() {
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day, reviewers: ["@PostHog/team-flags"]),
        reviewCard("b", number: 2, since: now - day, reviewers: ["@posthog/Team-Flags"]),
      ]

      #expect(Nudge.teams(cards, now: now).map(\.mention) == ["@PostHog/team-flags"])
    }

    /// The bare slug is the team only where a code owner group names it.
    @Test func aBareSlugJoinsTheTeamOnlyWhereItResolves() {
      let cards = [
        reviewCard(
          "a", number: 1, since: now - 3 * day, reviewers: ["team-flags"],
          codeOwners: teamOwners(["@PostHog/team-flags"])),
        reviewCard("b", number: 2, since: now - 2 * day, reviewers: ["team-flags"]),
        reviewCard("c", number: 3, since: now - day, reviewers: ["@PostHog/team-flags"]),
      ]

      let teams = Nudge.teams(cards, now: now)

      #expect(teams.map(\.mention) == ["@PostHog/team-flags"])
      #expect(teams.first?.sessions.map(\.id) == ["a", "c"])
    }

    @Test func aPRUnderFourHoursIsLeftOut() {
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day), reviewCard("b", number: 2, since: now - day),
        reviewCard("young", number: 3, since: now - 3 * hour),
      ]

      #expect(Nudge.teams(cards, now: now).first?.sessions.map(\.id) == ["a", "b"])
    }

    @Test func aDoneSessionIsLeftOut() {
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day), reviewCard("b", number: 2, since: now - day),
        reviewCard("done", number: 3, since: now - 3 * day, state: .done),
      ]

      #expect(Nudge.teams(cards, now: now).first?.sessions.map(\.id) == ["a", "b"])
    }

    /// A re-review card addresses people, even when its placement names the team.
    @Test func aReReviewCardIsLeftOut() {
      let rereview = rereviewCard(
        repliedAt: now - 9 * hour, reviewers: ["@PostHog/team-hogql"], pr: nudgePR(number: 3), id: "rereview")
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day), reviewCard("b", number: 2, since: now - day), rereview,
      ]

      #expect(Nudge.shows(rereview, now: now))
      #expect(Nudge.teams(cards, now: now).first?.sessions.map(\.id) == ["a", "b"])
    }

    @Test func oneQualifyingPRGivesNoTeam() {
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day), reviewCard("young", number: 2, since: now - hour),
      ]

      #expect(Nudge.teams(cards, now: now).isEmpty)
    }

    @Test func aPRWaitingOnTwoTeamsIsUnderBoth() throws {
      let cards = [
        reviewCard(
          "both", number: 1, since: now - 3 * day, reviewers: ["@PostHog/team-hogql", "@PostHog/team-flags"]),
        reviewCard("hogql", number: 2, since: now - 2 * day, reviewers: ["@PostHog/team-hogql"]),
        reviewCard("flags", number: 3, since: now - day, reviewers: ["@PostHog/team-flags"]),
      ]

      let teams = Nudge.teams(cards, now: now)
      let hogql = try #require(teams.first { $0.mention == "@PostHog/team-hogql" })
      let flags = try #require(teams.first { $0.mention == "@PostHog/team-flags" })

      #expect(teams.count == 2)
      #expect(hogql.sessions.map(\.id) == ["both", "hogql"])
      #expect(flags.sessions.map(\.id) == ["both", "flags"])
    }

    @Test func loginsAreNeverATeam() {
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day, reviewers: ["alice"]),
        reviewCard("b", number: 2, since: now - day, reviewers: ["@alice"]),
      ]

      #expect(Nudge.teams(cards, now: now).isEmpty)
    }

    /// A bare team slug on a PR without code owner groups has no org, so it is not a team.
    @Test func anOrglessSlugIsNotATeam() {
      let cards = [
        reviewCard("a", number: 1, since: now - 2 * day, reviewers: ["team-flags"]),
        reviewCard("b", number: 2, since: now - day, reviewers: ["team-flags"]),
      ]

      #expect(Nudge.teams(cards, now: now).isEmpty)
    }
  }

  // MARK: Nudge all parity

  /// For each team, the Nudge all bullets are exactly the cards that show Nudge and whose single nudge
  /// addresses that team. The expected side runs `Nudge.shows` and `Nudge.text(for:now:)`.
  @Suite struct TeamParity {
    /// Every form of a team mention and every card that Nudge all leaves out, on one board, plus a
    /// login-only PR.
    private static let board: [SessionSummary] = [
      reviewCard("flags-upper", number: 1, since: now - 6 * day, reviewers: ["@PostHog/team-flags"]),
      reviewCard("flags-lower", number: 2, since: now - 5 * day, reviewers: ["@posthog/Team-Flags"]),
      reviewCard(
        "flags-bare-resolved", number: 3, since: now - 4 * day, reviewers: ["team-flags"],
        codeOwners: teamOwners(["@PostHog/team-flags"])),
      reviewCard("flags-bare-orgless", number: 4, since: now - 4 * day, reviewers: ["team-flags"]),
      reviewCard("flags-young", number: 5, since: now - 2 * hour, reviewers: ["@PostHog/team-flags"]),
      reviewCard("flags-done", number: 6, since: now - 3 * day, reviewers: ["@PostHog/team-flags"], state: .done),
      rereviewCard(
        repliedAt: now - 2 * day, reviewers: ["@PostHog/team-flags"], pr: nudgePR(number: 7), id: "flags-rereview"),
      reviewCard(
        "two-teams", number: 8, since: now - 3 * day, reviewers: ["@PostHog/team-hogql", "@PostHog/team-flags"]),
      reviewCard("hogql", number: 9, since: now - 2 * day, reviewers: ["@PostHog/team-hogql"]),
      reviewCard("replay-alone", number: 10, since: now - 2 * day, reviewers: ["@PostHog/team-replay"]),
      reviewCard("login", number: 11, since: now - 2 * day, reviewers: ["alice", "bob"]),
    ]

    /// The PR numbers of the cards that show Nudge and whose single nudge names `team`.
    private static func singleNudgeNumbers(addressing team: String) -> Set<Int> {
      Set(
        board.filter { s in
          Nudge.shows(s, now: now)
            && (Nudge.text(for: s, now: now)?.lowercased().contains(team.lowercased()) ?? false)
        }.compactMap { $0.pr?.number })
    }

    @Test(arguments: candidateTeams)
    func theBulletsAreTheCardsWhoseSingleNudgeAddressesTheTeam(_ team: String) {
      let expected = Self.singleNudgeNumbers(addressing: team)
      let group = Nudge.teams(Self.board, now: now).first { $0.mention.lowercased() == team.lowercased() }

      if expected.count >= 2 {
        #expect(group.map { bulletNumbers(Nudge.allText($0)) } == expected, "\(team)")
      } else {
        #expect(group?.mention == nil, "\(team)")
      }
    }

    @Test func everyTeamIsACandidate() {
      let candidates = Set(candidateTeams.map { $0.lowercased() })

      for team in Nudge.teams(Self.board, now: now) {
        #expect(candidates.contains(team.mention.lowercased()), "\(team.mention)")
      }
    }

    /// Guards against a board on which the parity check compares only empty sets.
    @Test func theBoardHasTwoTeams() {
      #expect(Nudge.teams(Self.board, now: now).count == 2)
    }

    @Test func eachTeamsSessionsMatchItsBullets() {
      for team in Nudge.teams(Self.board, now: now) {
        #expect(Set(team.sessions.compactMap { $0.pr?.number }) == bulletNumbers(Nudge.allText(team)))
      }
    }
  }

  // MARK: The Board's In review cells

  /// `NudgeAllMenu` reads the In review cells of every lane, so one team's PRs in two repos form one group.
  @MainActor
  @Suite struct BoardSource {
    private static let sessions = [
      laneCard("ph", "PostHog/posthog", number: 1, .inReview),
      laneCard("web", "PostHog/posthog.com", number: 2, .inReview),
      laneCard("wait", "PostHog/posthog", number: 3, .waiting),
    ]

    @Test func theCardsSpanEveryLane() {
      let layout = appliedModel(Self.sessions).boardLayout(lanes: .repo)

      #expect(layout.lanes.count == 2)
      #expect(Set(layout.cards.map(\.id)) == ["ph", "web", "wait"])
    }

    @Test func oneTeamGathersPRsFromBothLanes() throws {
      let layout = appliedModel(Self.sessions).boardLayout(lanes: .repo)

      let teams = Nudge.teams(layout.cards, now: now)

      let team = try #require(teams.first)
      #expect(teams.count == 1)
      #expect(Set(team.sessions.map(\.id)) == ["ph", "web"])
    }
  }

  // MARK: The draft's reset button

  @Suite struct DraftReset {
    @Test(arguments: [
      ("Could I get a review of #1234?", "Could I get a review of #1234?", false),
      ("Could I get a review of #1234? Thanks!", "Could I get a review of #1234?", true),
      ("Could I get a review of #1234? ", "Could I get a review of #1234?", true),
      ("", "Could I get a review of #1234?", true),
    ])
    func showsOnlyWhileTheTextDiffersFromTheGenerated(_ text: String, _ generated: String, _ shows: Bool) {
      #expect(NudgeDraftView.showsReset(text: text, generated: generated) == shows)
    }
  }
}
