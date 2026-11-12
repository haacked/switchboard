import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000
private let minute: Int64 = 60_000
private let hour: Int64 = 60 * minute
private let day: Int64 = 24 * hour

private func nudgePR(
  number: Int = 1234, repo: String = "PostHog/posthog", title: String = "Cache flag reads",
  codeOwners: CodeOwnerStatus? = nil
) -> PRSummary {
  var pr = PRSummary(
    PullRequest(id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo))
  pr.title = title
  pr.codeOwners = codeOwners
  return pr
}

/// A work session whose PR entered `column` at `since`, with the reviewers that the placement names.
private func placed(
  _ column: BoardColumn, since: Int64, reviewers: [String]? = ["alice"], pr: PRSummary? = nudgePR(),
  state: AttentionState = .waiting
) -> SessionSummary {
  var s = needsItem("s1", state: state)
  s.pr = pr
  s.board = BoardPlacement(column: column, since: since, reviewers: column == .inReview ? reviewers : nil)
  return s
}

/// Each wait and how the nudge words it: whole hours under a day, rounded down, then whole days.
private let waits: [(Int64, String)] = [
  (4 * hour, "4 hours"),
  (5 * hour, "5 hours"),
  (5 * hour + 59 * minute, "5 hours"),
  (23 * hour + 59 * minute, "23 hours"),
  (day, "1 day"),
  (day + 23 * hour, "1 day"),
  (2 * day, "2 days"),
  (9 * day + 3 * hour, "9 days"),
]

private func teamOwners(_ owners: [String]) -> CodeOwnerStatus {
  CodeOwnerStatus(satisfied: false, groups: [CodeOwnerGroup(owners: owners, approved: false)])
}

@Suite struct NudgeTests {
  // MARK: Text

  @Suite struct Text {
    @Test func namesTheReviewerThePRItsTitleTheWaitAndTheURL() {
      let text = Nudge.text(pr: nudgePR(), reviewers: ["@PostHog/team-flags"], waited: 5 * hour)

      #expect(
        text
          == "@PostHog/team-flags could you take a look at #1234 (Cache flag reads)? It has waited for review for 5 hours. https://github.com/PostHog/posthog/pull/1234"
      )
    }

    @Test func twoReviewersAreJoinedWithAnd() {
      let text = Nudge.text(pr: nudgePR(), reviewers: ["alice", "bob"], waited: 5 * hour)

      #expect(text.hasPrefix("@alice and @bob could you take a look at #1234"))
    }

    @Test func everyReviewerIsMentionedOnce() {
      let text = Nudge.text(pr: nudgePR(), reviewers: ["alice", "bob", "@PostHog/team-flags"], waited: 5 * hour)

      for mention in ["@alice", "@bob", "@PostHog/team-flags"] {
        #expect(text.components(separatedBy: mention).count == 2, "\(mention) in \(text)")
      }
    }

    /// An In review card can wait on a review that nobody was asked for, so the nudge names no one.
    @Test func noReviewersAsksWithoutAMention() {
      let text = Nudge.text(pr: nudgePR(), reviewers: [], waited: 5 * hour)

      #expect(
        text
          == "Could you take a look at #1234 (Cache flag reads)? It has waited for review for 5 hours. https://github.com/PostHog/posthog/pull/1234"
      )
    }

    @Test func anEmptyTitleLeavesOutTheParentheses() {
      let text = Nudge.text(pr: nudgePR(title: ""), reviewers: ["alice"], waited: 5 * hour)

      #expect(text.hasPrefix("@alice could you take a look at #1234? It has waited"))
    }

    @Test func aTitleWithParenthesesIsKeptAsIs() {
      let text = Nudge.text(pr: nudgePR(title: "Fix (again) the cache"), reviewers: ["alice"], waited: 5 * hour)

      #expect(text.contains("#1234 (Fix (again) the cache)?"))
    }

    @Test func endsWithThePRsURL() {
      let text = Nudge.text(
        pr: nudgePR(number: 77, repo: "haacked/switchboard"), reviewers: ["alice"], waited: 5 * hour)

      #expect(text.hasSuffix(" https://github.com/haacked/switchboard/pull/77"))
    }

    @Test(arguments: waits)
    func theWaitReadsInHoursThenDays(_ waited: Int64, _ words: String) {
      let text = Nudge.text(pr: nudgePR(), reviewers: ["alice"], waited: waited)

      #expect(text.contains("It has waited for review for \(words). "), "\(text)")
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
      let pr = nudgePR(codeOwners: teamOwners(["@PostHog/team-flags"]))

      let text = Nudge.text(pr: pr, reviewers: ["team-flags", "alice", "@bob"], waited: 5 * hour)

      #expect(text.hasPrefix("@PostHog/team-flags, @alice, and @bob could you"))
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

    @Test(arguments: [BoardColumn.inProgress, .waiting, .approved, .merging, .done])
    func neverShowsOutsideInReviewHoweverLongTheCardWaited(_ column: BoardColumn) {
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
    @Test func isTheTextForThePlacementsReviewersAndTimeInReview() {
      let s = placed(.inReview, since: now - 5 * hour, reviewers: ["alice"])

      #expect(Nudge.text(for: s, now: now) == Nudge.text(pr: nudgePR(), reviewers: ["alice"], waited: 5 * hour))
    }

    /// The code owner `@org/team` form exists only in the placement, because `PRSummary` carries no code
    /// owner requests. So the nudge reads the placement's reviewers, not the PR's review requests.
    @Test func readsThePlacementsReviewersNotThePRsReviewRequests() throws {
      var pr = nudgePR()
      pr.reviewRequests = ["carol"]
      let s = placed(.inReview, since: now - 5 * hour, reviewers: ["@PostHog/team-flags"], pr: pr)

      let text = try #require(Nudge.text(for: s, now: now))

      #expect(text.hasPrefix("@PostHog/team-flags could you"))
      #expect(!text.contains("carol"))
    }

    @Test func aPlacementWithoutReviewersAsksWithoutAMention() throws {
      let s = placed(.inReview, since: now - 5 * hour, reviewers: nil)

      let text = try #require(Nudge.text(for: s, now: now))

      #expect(text.hasPrefix("Could you take a look at #1234"))
    }

    @Test func isNilWhileTheNudgeDoesNotShow() {
      #expect(Nudge.text(for: placed(.inReview, since: now - hour), now: now) == nil)
      #expect(Nudge.text(for: placed(.waiting, since: now - 3 * day), now: now) == nil)
      #expect(Nudge.text(for: placed(.inReview, since: now - 3 * day, pr: nil), now: now) == nil)
    }
  }
}
