import Foundation

@testable import SwitchboardCore

/// Responses that Phase 0 test 6 recorded from GitHub's GraphQL API.
enum GitHubFixtures {
  /// The integration tests serve the same recorded responses from this folder.
  static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("IntegrationTests/Fixtures").path

  static func nodes(_ file: String) -> [JSON] {
    let text = (try? String(contentsOfFile: "\(folder)/\(file)", encoding: .utf8)) ?? ""
    return JSON.parse(text)?["data"]?["nodes"]?.array ?? []
  }

  /// The nodes of a `GitHub.statusQuery` response for eight PRs.
  static let statusNodes = nodes("github-status.json")

  /// The nodes of a `GitHub.bodyQuery` response for the trunk-io and
  /// deployment-status-posthog comments of the PRs in `statusNodes`.
  static let bodyNodes = nodes("github-bodies.json")

  static func statusNode(_ number: Int) -> JSON? { statusNodes.first { $0["number"]?.int == number } }

  /// The PRs of `statusNodes`, in their order.
  static let statusPRs: [PullRequest] = [
    PullRequest(
      id: "PR_kwDODg-Tdc8AAAABKXWYeg",
      number: 122953,
      url: "https://github.com/PostHog/posthog/pull/122953",
      repo: "PostHog/posthog",
      title: "fix(cdp): count parked lookup failures toward the dead-letter breaker",
      state: .open,
      draft: false,
      head: "haacked/cdp-dlq-breaker-counts-lookups",
      headSha: "89918967ababc0def2d9c2d50d3a5069ea799dc0",
      base: "master",
      defaultBranch: "master",
      mergeable: .unknown,
      reviewDecision: .reviewRequired,
      verdicts: [],
      reviews: [
        Review(author: "copilot-pull-request-reviewer", state: "COMMENTED", submittedAt: "2026-10-23T23:30:00Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-23T23:31:12Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-25T02:38:45Z"),
        Review(author: "parameterai", state: "COMMENTED", submittedAt: "2026-10-25T02:53:38Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-25T03:23:59Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-10-25T21:25:33Z"),
      ],
      labels: ["skip-inkeep-docs"],
      checks: "SUCCESS",
      mergedBase: nil,
      mergedAt: nil,
      closedAt: nil,
      trunkConfig: true, reviewDecisionRead: true),
    PullRequest(
      id: "PR_kwDOJsIKrs8AAAABKhgNxg",
      number: 18303,
      url: "https://github.com/PostHog/charts/pull/18303",
      repo: "PostHog/charts",
      title: "chore(cdp): document lookup records in the dead-letter runbook",
      state: .open,
      draft: false,
      head: "haacked/cdp-dlq-runbook-lookup-step",
      headSha: "04e3f33e9804c4ff6fbd57f41ebd75e6c1e50547",
      base: "main",
      defaultBranch: "main",
      mergeable: .mergeable,
      reviewDecision: .approved,
      verdicts: [
        Review(
          author: "stamphog", state: "APPROVED", submittedAt: "2026-10-25T20:56:17Z",
          commit: "04e3f33e9804c4ff6fbd57f41ebd75e6c1e50547")
      ],
      reviews: [
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-25T02:49:45Z"),
        Review(author: "stamphog", state: "DISMISSED", submittedAt: "2026-10-25T03:31:36Z"),
        Review(author: "stamphog", state: "DISMISSED", submittedAt: "2026-10-25T03:56:47Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-25T03:58:37Z"),
        Review(author: "stamphog", state: "DISMISSED", submittedAt: "2026-10-25T04:20:09Z"),
        Review(author: "stamphog", state: "APPROVED", submittedAt: "2026-10-25T20:56:17Z"),
      ],
      labels: ["stamphog"],
      checks: "SUCCESS",
      mergedBase: nil,
      mergedAt: nil,
      closedAt: nil,
      trunkConfig: false, reviewDecisionRead: true),
    PullRequest(
      id: "PR_kwDODg-Tdc8AAAABKWMoSw",
      number: 122896,
      url: "https://github.com/PostHog/posthog/pull/122896",
      repo: "PostHog/posthog",
      title: "feat(mcp): return condition_id from experiment tools",
      state: .open,
      draft: false,
      head: "haacked/mcp-experiment-condition-ids",
      headSha: "f57bc1ee40d8361716f04f3bb176d5b3b403281c",
      base: "master",
      defaultBranch: "master",
      mergeable: .unknown,
      reviewDecision: .reviewRequired,
      verdicts: [],
      reviews: [
        Review(author: "copilot-pull-request-reviewer", state: "COMMENTED", submittedAt: "2026-10-23T21:13:56Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-23T21:15:44Z"),
        Review(author: "stamphog", state: "DISMISSED", submittedAt: "2026-10-24T00:17:35Z"),
        Review(author: "stamphog", state: "COMMENTED", submittedAt: "2026-10-25T03:13:53Z"),
      ],
      labels: [],
      checks: "SUCCESS",
      mergedBase: nil,
      mergedAt: nil,
      closedAt: nil,
      trunkConfig: true, reviewDecisionRead: true),
    PullRequest(
      id: "PR_kwDOFbb7KM70tBuL",
      number: 1209,
      url: "https://github.com/PostHog/requests-for-comments-internal/pull/1209",
      repo: "PostHog/requests-for-comments-internal",
      title: "RFC: Move flag evaluation events out of the events table",
      state: .open,
      draft: false,
      head: "posthog-code/flag-evaluations-table",
      headSha: "c7c8e3031c48f7faf3151bdf846f038e00af603f",
      base: "main",
      defaultBranch: "main",
      mergeable: .mergeable,
      reviewDecision: .changesRequested,
      verdicts: [
        Review(
          author: "benjackwhite", state: "CHANGES_REQUESTED", submittedAt: "2026-08-04T07:31:31Z",
          commit: "33c547cbe8c34ff6cac5a0733b316da22f641c39"),
        Review(
          author: "nickbest-ph", state: "APPROVED", submittedAt: "2026-07-29T17:45:38Z",
          commit: "33c547cbe8c34ff6cac5a0733b316da22f641c39"),
        Review(
          author: "eli-r-ph", state: "APPROVED", submittedAt: "2026-07-28T23:44:39Z",
          commit: "33c547cbe8c34ff6cac5a0733b316da22f641c39"),
      ],
      reviews: [
        Review(author: "mjwarren3", state: "COMMENTED", submittedAt: "2026-07-22T17:36:44Z"),
        Review(author: "mjwarren3", state: "COMMENTED", submittedAt: "2026-07-22T17:45:33Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-07-22T18:00:06Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-07-22T19:08:22Z"),
        Review(author: "z0br0wn", state: "COMMENTED", submittedAt: "2026-07-22T19:41:25Z"),
        Review(author: "benjackwhite", state: "CHANGES_REQUESTED", submittedAt: "2026-07-23T08:14:09Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-07-23T18:55:42Z"),
        Review(author: "eli-r-ph", state: "APPROVED", submittedAt: "2026-07-28T23:44:39Z"),
        Review(author: "nickbest-ph", state: "APPROVED", submittedAt: "2026-07-29T17:45:38Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-07-31T00:22:02Z"),
        Review(author: "benjackwhite", state: "CHANGES_REQUESTED", submittedAt: "2026-08-04T07:31:31Z"),
        Review(author: "jose-sequeira", state: "COMMENTED", submittedAt: "2026-08-04T08:00:46Z"),
        Review(author: "jose-sequeira", state: "COMMENTED", submittedAt: "2026-08-04T08:05:03Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-08-04T17:18:21Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-08-04T17:23:54Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-08-04T17:25:48Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-08-04T20:11:59Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-08-24T18:45:05Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-08-24T18:45:59Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-08-24T19:45:22Z"),
      ],
      labels: [],
      checks: "SUCCESS",
      mergedBase: nil,
      mergedAt: nil,
      closedAt: nil,
      trunkConfig: false, reviewDecisionRead: true),
    PullRequest(
      id: "PR_kwDOD4evDM8AAAABHcbdjA",
      number: 20992,
      url: "https://github.com/PostHog/posthog.com/pull/20992",
      repo: "PostHog/posthog.com",
      title: "docs(flags): document where PostHog stores flag calls",
      state: .open,
      draft: false,
      head: "haacked/flag-calls-move-docs",
      headSha: "f2ea91e80208dcdfd93c862fd217bdff5775a6cd",
      base: "master",
      defaultBranch: "master",
      mergeable: .mergeable,
      reviewDecision: nil,
      verdicts: [
        Review(
          author: "gewenyu99", state: "APPROVED", submittedAt: "2026-10-13T23:10:13Z",
          commit: "3e026481e8142bb2bbc29079333f1db5e860c52d")
      ],
      reviews: [
        Review(author: "gewenyu99", state: "COMMENTED", submittedAt: "2026-10-12T15:08:40Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-10-13T22:51:32Z"),
        Review(author: "gewenyu99", state: "APPROVED", submittedAt: "2026-10-13T23:10:13Z"),
        Review(author: "gewenyu99", state: "COMMENTED", submittedAt: "2026-10-13T23:12:20Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-10-14T15:36:34Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-10-14T15:39:53Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-10-14T16:28:17Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-14T19:20:10Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-14T20:02:50Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-14T20:24:34Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-10-23T18:26:41Z"),
      ],
      labels: ["docs", "content"],
      checks: "SUCCESS",
      mergedBase: nil,
      mergedAt: nil,
      closedAt: nil,
      trunkConfig: false, reviewDecisionRead: true),
    PullRequest(
      id: "PR_kwDOQXvSnc8AAAABKo4i1A",
      number: 189,
      url: "https://github.com/haacked/review-code/pull/189",
      repo: "haacked/review-code",
      title: "Isolate eval review state and freeze benchmark PR descriptions",
      state: .open,
      draft: true,
      head: "haacked/better-hogql-reviews",
      headSha: "bb1e367917f85444b8b832747aff67b815cde10f",
      base: "main",
      defaultBranch: "main",
      mergeable: .mergeable,
      reviewDecision: .reviewRequired,
      verdicts: [],
      reviews: [],
      labels: [],
      checks: "SUCCESS",
      mergedBase: nil,
      mergedAt: nil,
      closedAt: nil,
      trunkConfig: false, reviewDecisionRead: true),
    PullRequest(
      id: "PR_kwDODg-Tdc8AAAABKD3FTQ",
      number: 122179,
      url: "https://github.com/PostHog/posthog/pull/122179",
      repo: "PostHog/posthog",
      title: "fix(groups): stop the groups list query from running out of memory",
      state: .merged,
      draft: false,
      head: "posthog/groups-list-two-phase-dedup",
      headSha: "189c31fc88b1b719e17b5b4bbc15b1834caf1279",
      base: "master",
      defaultBranch: "master",
      mergeable: .unknown,
      reviewDecision: .approved,
      verdicts: [
        Review(
          author: "stamphog", state: "APPROVED", submittedAt: "2026-10-23T18:50:05Z",
          commit: "189c31fc88b1b719e17b5b4bbc15b1834caf1279")
      ],
      reviews: [
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-22T18:33:02Z"),
        Review(author: "haacked", state: "COMMENTED", submittedAt: "2026-10-23T18:23:11Z"),
        Review(author: "stamphog", state: "APPROVED", submittedAt: "2026-10-23T18:50:05Z"),
      ],
      labels: ["stamphog"],
      checks: "FAILURE",
      mergedBase: nil,
      mergedAt: "2026-10-23T21:57:32Z",
      closedAt: "2026-10-23T21:57:32Z",
      trunkConfig: true, reviewDecisionRead: true),
    PullRequest(
      id: "PR_kwDODg-Tdc8AAAABJ8lAUA",
      number: 121847,
      url: "https://github.com/PostHog/posthog/pull/121847",
      repo: "PostHog/posthog",
      title: "fix(cohorts): bump the store stamp when a replay mark from another topic first lands",
      state: .closed,
      draft: true,
      head: "haacked/cohort-store-stamp-other-topic-marks",
      headSha: "2d8ad82c72ad72f191c82e0e44f27401ca112c07",
      base: "haacked/cohort-processor-per-topic-offsets",
      defaultBranch: "master",
      mergeable: .conflicting,
      reviewDecision: nil,
      verdicts: [],
      reviews: [
        Review(author: "copilot-pull-request-reviewer", state: "COMMENTED", submittedAt: "2026-10-22T05:13:55Z"),
        Review(author: "posthog", state: "COMMENTED", submittedAt: "2026-10-22T05:15:44Z"),
      ],
      labels: ["feature/cohorts", "team/feature-flags"],
      checks: "SUCCESS",
      mergedBase: nil,
      mergedAt: nil,
      closedAt: "2026-10-22T16:24:56Z",
      trunkConfig: true, reviewDecisionRead: true),
  ]

  /// The comments of each PR in `statusNodes`, oldest first.
  static let statusComments: [Int: [PRComment]] = [
    122953: [
      PRComment(id: "IC_kwDODg-Tdc8AAAABfBZM8A", author: "trunk-io[bot]", createdAt: "2026-10-23T23:29:49Z"),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABfBZWrg", author: "github-actions[bot]", createdAt: "2026-10-23T23:30:02Z",
        editedAt: "2026-10-25T21:38:22Z", edited: true),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABfBlIDw", author: "trunk-io[bot]", createdAt: "2026-10-23T23:45:43Z",
        editedAt: "2026-10-25T21:51:06Z", edited: true),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABfQgVPg", author: "parameterai[bot]", createdAt: "2026-10-25T02:50:57Z",
        editedAt: "2026-10-25T21:40:15Z", edited: true),
      PRComment(id: "IC_kwDODg-Tdc8AAAABfQ7HFw", author: "haacked", createdAt: "2026-10-25T03:44:45Z"),
    ],
    18303: [
      PRComment(
        id: "IC_kwDOJsIKrs8AAAABfQYpDA", author: "github-actions[bot]", createdAt: "2026-10-25T02:35:54Z",
        editedAt: "2026-10-25T21:01:31Z", edited: true),
      PRComment(
        id: "IC_kwDOJsIKrs8AAAABfQZFMQ", author: "github-actions[bot]", createdAt: "2026-10-25T02:36:45Z",
        editedAt: "2026-10-25T20:57:36Z", edited: true),
    ],
    122896: [
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABe_kU3w", author: "github-actions[bot]", createdAt: "2026-10-23T21:15:41Z",
        editedAt: "2026-10-25T03:13:37Z", edited: true),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABfB0cdA", author: "parameterai[bot]", createdAt: "2026-10-24T00:05:21Z",
        editedAt: "2026-10-24T00:07:01Z", edited: true),
      PRComment(id: "IC_kwDODg-Tdc8AAAABfCDouw", author: "trunk-io[bot]", createdAt: "2026-10-24T00:26:23Z"),
      PRComment(id: "IC_kwDODg-Tdc8AAAABfQrqdw", author: "trunk-io[bot]", createdAt: "2026-10-25T03:13:28Z"),
    ],
    1209: [
      PRComment(id: "IC_kwDOFbb7KM8AAAABMKMMEQ", author: "github-actions[bot]", createdAt: "2026-07-28T23:44:46Z"),
      PRComment(id: "IC_kwDOFbb7KM8AAAABMjqyYQ", author: "haacked", createdAt: "2026-07-31T00:23:00Z"),
      PRComment(id: "IC_kwDOFbb7KM8AAAABMjq5OA", author: "github-actions[bot]", createdAt: "2026-07-31T00:23:14Z"),
    ],
    20992: [
      PRComment(
        id: "IC_kwDOD4evDM8AAAABaeqi4w", author: "github-actions[bot]", createdAt: "2026-10-09T00:46:59Z",
        editedAt: "2026-10-23T18:37:01Z", edited: true),
      PRComment(
        id: "IC_kwDOD4evDM8AAAABaeuS4A", author: "github-actions[bot]", createdAt: "2026-10-09T00:52:49Z",
        editedAt: "2026-10-23T18:19:50Z", edited: true),
      PRComment(
        id: "IC_kwDOD4evDM8AAAABaeyj2Q", author: "github-actions[bot]", createdAt: "2026-10-09T00:59:27Z",
        editedAt: "2026-10-23T18:32:12Z", edited: true),
    ],
    189: [],
    122179: [
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABei9jZw", author: "trunk-io[bot]", createdAt: "2026-10-22T15:44:27Z",
        editedAt: "2026-10-23T21:57:35Z", edited: true),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABei9xJQ", author: "github-actions[bot]", createdAt: "2026-10-22T15:44:37Z",
        editedAt: "2026-10-23T18:46:45Z", edited: true),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABejgvfA", author: "trunk-io[bot]", createdAt: "2026-10-22T16:11:06Z",
        editedAt: "2026-10-23T19:03:24Z", edited: true),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABe8w5MQ", author: "parameterai[bot]", createdAt: "2026-10-23T18:28:38Z",
        editedAt: "2026-10-23T18:30:48Z", edited: true),
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABfAhApw", author: "deployment-status-posthog[bot]", createdAt: "2026-10-23T22:20:27Z",
        editedAt: "2026-10-23T22:34:45Z", edited: true),
    ],
    121847: [
      PRComment(
        id: "IC_kwDODg-Tdc8AAAABeX5gew", author: "github-actions[bot]", createdAt: "2026-10-22T05:13:53Z",
        editedAt: "2026-10-22T05:15:53Z", edited: true),
      PRComment(id: "IC_kwDODg-Tdc8AAAABeYMJPg", author: "trunk-io[bot]", createdAt: "2026-10-22T05:36:44Z"),
    ],
  ]
}
