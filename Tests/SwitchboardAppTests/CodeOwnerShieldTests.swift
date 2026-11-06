import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let satisfied = CodeOwnerStatus(
  satisfied: true, groups: [CodeOwnerGroup(owners: ["@PostHog/hogql"], approved: true)])
private let waiting = CodeOwnerStatus(
  satisfied: false, groups: [CodeOwnerGroup(owners: ["@PostHog/hogql"], approved: false)])
private let partlyApproved = CodeOwnerStatus(
  satisfied: false,
  groups: [
    CodeOwnerGroup(owners: ["@PostHog/hogql"], approved: true),
    CodeOwnerGroup(owners: ["@PostHog/team-devex"], approved: false),
  ])

/// Groups named `@PostHog/team-0` through `@PostHog/team-<count - 1>`. Even
/// numbered groups are approved.
private func groups(_ count: Int, approved: Bool? = nil) -> [CodeOwnerGroup] {
  (0..<count).map { CodeOwnerGroup(owners: ["@PostHog/team-\($0)"], approved: approved ?? ($0 % 2 == 0)) }
}

/// An open PR whose base requires `owners`. Its author and code owner
/// requests are read, so Core can build a status for it.
private func ownedPR(_ owners: [[String]], verdicts: [Review] = []) -> PullRequest {
  var pr = PullRequest(
    id: "PR_1", number: 1, url: "https://github.com/PostHog/posthog/pull/1", repo: "PostHog/posthog",
    state: .open, headSha: "head", verdicts: verdicts, author: "x", codeOwnerRequests: [])
  pr.codeOwners = CodeOwnerRequirement(groups: owners)
  return pr
}

@Suite struct CodeOwnerShieldLook {
  @Test func showsTheCheckmarkShieldForASatisfiedStatus() {
    #expect(CodeOwnerShield.symbol(for: satisfied) == "checkmark.shield.fill")
  }

  @Test func colorsASatisfiedStatusGreen() {
    #expect(CodeOwnerShield.color(for: satisfied) == .green)
  }

  @Test(arguments: [waiting, partlyApproved])
  func showsThePlainShieldWhileAGroupWaits(_ status: CodeOwnerStatus) {
    #expect(CodeOwnerShield.symbol(for: status) == "shield")
  }

  @Test(arguments: [waiting, partlyApproved])
  func colorsAWaitingStatusInTheReviewRequiredColor(_ status: CodeOwnerStatus) {
    #expect(CodeOwnerShield.color(for: status) == PRStatus.reviewRequired.color)
  }

  @Test(arguments: [satisfied, waiting, partlyApproved])
  func neverUsesTheNeedsYouColor(_ status: CodeOwnerStatus) {
    #expect(CodeOwnerShield.color(for: status) != AttentionState.needsYou.color)
  }
}

@Suite struct CodeOwnerShieldLabel {
  @Test(arguments: [satisfied, waiting])
  func labelsOneGroupOnOneLine(_ status: CodeOwnerStatus) {
    let label = CodeOwnerShield.label(for: status)

    #expect(label == status.text(separator: "\n"))
    #expect(!label.contains("\n"))
  }

  @Test(arguments: [
    partlyApproved,
    CodeOwnerStatus(satisfied: true, groups: groups(3, approved: true)),
    CodeOwnerStatus(satisfied: false, groups: groups(3)),
  ])
  func labelsSeveralGroupsWithALineForEach(_ status: CodeOwnerStatus) {
    let label = CodeOwnerShield.label(for: status)

    #expect(label == status.text(separator: "\n"))
    #expect(label.split(separator: "\n").count == status.groups.count + 1)
  }

  @Test func labelsEveryGroupOfManyWithoutTruncating() {
    let status = CodeOwnerStatus(satisfied: false, groups: groups(12))

    let label = CodeOwnerShield.label(for: status)

    #expect(label == status.text(separator: "\n"))
    #expect(label.split(separator: "\n").count == 13)
    for group in status.groups {
      #expect(label.contains("\(group.owners[0]): \(group.approved ? "approved" : "waiting")"))
    }
  }

  @Test func labelsAGroupWithSeveralOwnersAsAlternatives() {
    let status = CodeOwnerStatus(
      satisfied: false,
      groups: [
        CodeOwnerGroup(owners: ["@alice", "@PostHog/team-x"], approved: false),
        CodeOwnerGroup(owners: ["@PostHog/hogql"], approved: true),
      ])

    let label = CodeOwnerShield.label(for: status)

    #expect(label == status.text(separator: "\n"))
    #expect(label.contains("@alice or @PostHog/team-x: waiting"))
  }
}

@Suite struct CodeOwnerShieldPresence {
  @Test func showsNoShieldForAPRWithoutARequirement() {
    let summary = PRSummary(
      PullRequest(
        id: "PR_1", number: 1, url: "https://github.com/haacked/switchboard/pull/1", repo: "haacked/switchboard"))

    #expect(summary.codeOwners == nil)
    #expect(CodeOwnerShield.status(for: summary) == nil)
  }

  @Test func showsNoShieldWhenThePollDidNotReadTheAuthor() {
    var pr = ownedPR([["@PostHog/hogql"]])
    pr.author = nil

    #expect(CodeOwnerShield.status(for: PRSummary(pr)) == nil)
  }

  @Test(arguments: [PRState.merged, .closed])
  func showsNoShieldForAPRThatIsNotOpen(_ state: PRState) {
    var pr = ownedPR([["@PostHog/hogql"]])
    pr.state = state

    #expect(CodeOwnerShield.status(for: PRSummary(pr)) == nil)
  }

  @Test func showsTheSummarysStatusForAPRWithARequirement() {
    let summary = PRSummary(ownedPR([["@PostHog/hogql"]]))

    let status = CodeOwnerShield.status(for: summary)

    #expect(status != nil)
    #expect(status == summary.codeOwners)
  }

  @Test func showsAWaitingBlueShieldForAnUnapprovedRequirement() throws {
    let status = try #require(CodeOwnerShield.status(for: PRSummary(ownedPR([["@PostHog/hogql"]]))))

    #expect(CodeOwnerShield.symbol(for: status) == "shield")
    #expect(CodeOwnerShield.color(for: status) == PRStatus.reviewRequired.color)
  }

  @Test func showsAGreenCheckmarkShieldOnceAnOwnerApprovesTheHead() throws {
    let pr = ownedPR([["@bob"]], verdicts: [Review(author: "bob", state: "APPROVED", commit: "head")])

    let status = try #require(CodeOwnerShield.status(for: PRSummary(pr)))

    #expect(CodeOwnerShield.symbol(for: status) == "checkmark.shield.fill")
    #expect(CodeOwnerShield.color(for: status) == .green)
  }
}
