import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let posthog = "PostHog/posthog"

private func bodyIssue(_ number: Int, _ repo: String = posthog) -> SessionIssue {
  SessionIssue(repo: repo, number: number, via: .body, url: "https://github.com/\(repo)/issues/\(number)")
}

private let branchIssue = SessionIssue(repo: nil, number: 123, via: .branch, url: nil)

@Suite struct IssueBadgeTests {
  @Suite struct Label {
    @Test func oneIssueShowsItsNumber() {
      #expect(IssueBadge.label(for: [bodyIssue(174)], prRepo: posthog) == "#174")
    }

    @Test func moreIssuesShowTheFirstAndHowManyMore() {
      #expect(IssueBadge.label(for: [bodyIssue(174), bodyIssue(9, "PostHog/charts")], prRepo: posthog) == "#174 +1")
      #expect(IssueBadge.label(for: [bodyIssue(1), bodyIssue(2), bodyIssue(3)], prRepo: posthog) == "#1 +2")
    }

    @Test func firstIssueInAnotherRepoShowsItsRepo() {
      #expect(IssueBadge.label(for: [bodyIssue(9, "PostHog/charts")], prRepo: posthog) == "PostHog/charts#9")
    }

    @Test(arguments: ["posthog/posthog", "POSTHOG/POSTHOG", "PostHog/PostHog"])
    func firstIssueInThePRsRepoMatchesWithoutRegardToCase(_ prRepo: String) {
      #expect(IssueBadge.label(for: [bodyIssue(174)], prRepo: prRepo) == "#174")
    }

    @Test func branchIssueWithoutAPRShowsItsNumber() {
      #expect(IssueBadge.label(for: [branchIssue], prRepo: nil) == "#123")
    }

    @Test func noIssuesGiveAnEmptyLabel() {
      #expect(IssueBadge.label(for: [], prRepo: posthog) == "")
    }
  }

  @Suite struct Tooltip {
    @Test func namesTheIssueAndThePRBody() {
      #expect(IssueBadge.tooltip(for: [bodyIssue(174)], prRepo: posthog) == "Issue #174 (PR body)")
    }

    @Test func namesTheBranchName() {
      #expect(IssueBadge.tooltip(for: [branchIssue], prRepo: nil) == "Issue #123 (branch name)")
    }

    @Test func namesAnIssueSetByHand() {
      let set = SessionIssue(repo: posthog, number: 5, via: .set, url: "https://github.com/PostHog/posthog/issues/5")

      #expect(IssueBadge.tooltip(for: [set], prRepo: posthog).hasPrefix("Issue #5 ("))
    }

    @Test func listsEveryIssueOnePerLine() {
      let tooltip = IssueBadge.tooltip(for: [bodyIssue(174), bodyIssue(9, "PostHog/charts")], prRepo: posthog)

      #expect(tooltip == "Issue #174 (PR body)\nIssue PostHog/charts#9 (PR body)")
    }
  }

  @Suite struct Link {
    @Test func linkIsTheFirstIssuesLink() {
      let issues = [bodyIssue(174), bodyIssue(9, "PostHog/charts")]

      #expect(IssueBadge.link(for: issues) == URL(string: "https://github.com/PostHog/posthog/issues/174"))
    }

    @Test func firstIssueWithoutAURLHasNoLinkEvenWhenALaterOneHas() {
      #expect(IssueBadge.link(for: [branchIssue, bodyIssue(174)]) == nil)
    }

    @Test func noIssuesHaveNoLink() {
      #expect(IssueBadge.link(for: []) == nil)
    }

    /// Any local process can record a `pr` event, and the app opens the link
    /// with NSWorkspace, so a decoded url that isn't https gives no link.
    @Test(arguments: [
      "file:///tmp/x", "http://github.com/PostHog/posthog/issues/174", "javascript:alert(1)", "",
      "/Applications/Calculator.app",
    ])
    func urlThatIsNotHttpsGivesNoLink(_ url: String) throws {
      let json: JSON = ["repo": .string(posthog), "number": 174, "via": "body", "url": .string(url)]
      let issue = try JSONCoding.convert(json, to: SessionIssue.self)

      #expect(IssueBadge.link(for: [issue]) == nil)
    }
  }
}
