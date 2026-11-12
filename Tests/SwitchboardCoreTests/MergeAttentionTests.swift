import Foundation
import Testing

@testable import SwitchboardCore

/// A PR that every ready-to-merge condition passes: open, not a draft,
/// mergeable, its checks passed, no review required, and a repository that
/// the poller read has no `.trunk` folder and a base branch without a merge
/// queue.
private func readyPR(
  draft: Bool = false, headSha: String = samplePRHead, base: String = "main", defaultBranch: String? = "main",
  mergeable: Mergeable? = .mergeable, reviewDecision: ReviewDecision? = nil, verdicts: [Review] = [],
  checks: String? = "SUCCESS", mergedBase: Int? = nil, queue: TrunkQueueState? = nil, reviewRequests: [String]? = nil,
  trunkConfig: Bool? = false, mergeQueue: Bool? = false
) -> PullRequest {
  var pr = samplePR(
    draft: draft, headSha: headSha, base: base, defaultBranch: defaultBranch, mergeable: mergeable,
    reviewDecision: reviewDecision, verdicts: verdicts, checks: checks, mergedBase: mergedBase, queue: queue,
    reviewRequests: reviewRequests)
  pr.trunkConfig = trunkConfig
  pr.mergeQueue = mergeQueue
  pr.reviewDecisionRead = true
  return pr
}

func mergeEvent(_ t: Int64, head: String, _ result: String, error: String? = nil) -> Event {
  var fields: [String: JSON] = ["head": .string(head), "result": .string(result)]
  if let error { fields["error"] = .string(error) }
  return event("merge", t, fields)
}

/// An acknowledgment of the Ready to merge verdict with `reason`.
private func ackEvent(_ t: Int64, _ reason: String, head: String) throws -> Event {
  let data = try JSON(encoding: Acknowledgment(state: .readyToMerge, reason: reason, head: head))
  return event("ack", t, data.object ?? [:])
}

func dependenciesEvent(_ t: Int64, _ deps: [Dependency]) throws -> Event {
  event("dependencies", t, ["dependencies": try JSON(encoding: deps)])
}

private let trunkBotComment = PRComment(
  id: "IC_trunk", author: TrunkComments.author, createdAt: "2026-10-25T00:00:00Z", body: "<!-- Trunk Merge -->")

private let now: Int64 = 10

private func verdict(_ facts: SessionFacts, _ s: Session = session()) -> Verdict {
  Attention.shown(
    Attention.evaluate(s, facts, now: now), facts, now: now, acknowledgedMs: RecheckSettings().acknowledgedMs)
}

/// The suites nest under one name, so `--filter MergeAttentionTests` runs them all.
@Suite struct MergeAttentionTests {}

extension MergeAttentionTests {
  @Suite struct ReadyToMergeState {
    @Test func readyToMergeComesRightAfterNeedsYou() {
      let all = AttentionState.allCases

      #expect(all.firstIndex(of: .readyToMerge) == all.firstIndex(of: .needsYou)! + 1)
    }

    @Test func readyToMergeIsTitledReadyToMerge() {
      #expect(AttentionState.readyToMerge.title == "Ready to merge")
    }

    @Test func readyToMergeEncodesAsSnakeCase() {
      #expect(AttentionState.readyToMerge.rawValue == "ready_to_merge")
    }
  }
}

extension MergeAttentionTests {
  @Suite struct MergeFacts {
    @Test func mergeEventSetsTheMergeAttempt() {
      let f = facts([mergeEvent(1, head: "abc", "failed", error: "not mergeable")])

      #expect(f.merge == MergeAttempt(head: "abc", result: .failed, error: "not mergeable"))
    }

    @Test func laterMergeEventReplacesTheEarlierOne() {
      let f = facts([mergeEvent(1, head: "abc", "failed", error: "boom"), mergeEvent(2, head: "abc", "merged")])

      #expect(f.merge == MergeAttempt(head: "abc", result: .merged))
    }

    /// An event that sbd recorded before Acknowledge can hold `dismissed`, which MergeAttempt does not decode.
    @Test func dismissedMergeEventNoLongerDecodes() {
      let f = facts([mergeEvent(1, head: "abc", "dismissed")])

      #expect(f.merge == nil)
    }
  }
}

extension MergeAttentionTests {
  @Suite struct MergeAttention {
    @Test func readyPRIsReadyToMerge() throws {
      let f = try prFacts(readyPR())

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    @Test func prWhoseDefaultBranchDidNotLoadIsReadyToMerge() throws {
      let f = try prFacts(readyPR(defaultBranch: nil))

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test(arguments: [
      ([sampleVerdict("alice", "APPROVED")], "#42 is ready to merge, approved by alice"),
      (
        [sampleVerdict("bob", "APPROVED"), sampleVerdict("alice", "APPROVED")],
        "#42 is ready to merge, approved by alice and bob"
      ),
    ])
    func approvedReadyPRNamesItsApprovers(_ verdicts: [Review], _ reason: String) throws {
      let f = try prFacts(readyPR(reviewDecision: .approved, verdicts: verdicts))

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: reason))
    }

    @Test func readyPRWithoutAReviewDecisionButWithAnApprovalNamesTheApprover() throws {
      let f = try prFacts(readyPR(reviewDecision: nil, verdicts: [sampleVerdict("alice", "APPROVED")]))

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge, approved by alice"))
    }

    @Test(arguments: [
      ("draft", readyPR(draft: true)),
      ("conflicting", readyPR(mergeable: .conflicting)),
      ("mergeability unknown", readyPR(mergeable: .unknown)),
      ("mergeability not read", readyPR(mergeable: nil)),
      ("checks failed", readyPR(checks: "FAILURE")),
      ("checks errored", readyPR(checks: "ERROR")),
      ("checks pending", readyPR(checks: "PENDING")),
      ("checks expected", readyPR(checks: "EXPECTED")),
      ("no checks", readyPR(checks: nil)),
      ("review required", readyPR(reviewDecision: .reviewRequired)),
      ("changes requested", readyPR(reviewDecision: .changesRequested)),
      (
        "changes requested on the head without a decision",
        readyPR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: samplePRHead)])
      ),
      (
        "changes requested on an older commit without a decision",
        readyPR(verdicts: [sampleVerdict("alice", "CHANGES_REQUESTED", on: "older")])
      ),
      ("merged base", readyPR(base: "haacked/parent", mergedBase: 41)),
      ("stacked on another branch", readyPR(base: "haacked/parent")),
      ("review requested", readyPR(reviewRequests: ["alice"])),
    ])
    func prThatCannotMergeIsNotReadyToMerge(_ label: String, _ pr: PullRequest) throws {
      let f = try prFacts(pr)

      #expect(verdict(f).state != .readyToMerge, "\(label)")
    }

    @Test(arguments: [
      TrunkQueueState.submitted, .pending, .testing, .passed, .failing, .queued, .merged, .removed, .unknown,
    ])
    func prWithATrunkQueueStateIsNotReadyToMerge(_ queue: TrunkQueueState) throws {
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], queue: queue))

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test func prWithATrunkCommentAmongOtherCommentsOffersEnqueue() throws {
      let comments = [
        PRComment(id: "IC_gh", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:00Z"), trunkBotComment,
      ]
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")]), comments: comments)

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge, approved by alice"))
      #expect(verdict(f).options.map(\.label) == ["Enqueue #42", "Acknowledge"])
    }

    /// A busy PR in a Trunk repository: Trunk's comment is outside the
    /// comments the poller reads, so only the repository's `.trunk` folder
    /// shows the queue.
    @Test func prInARepositoryWithATrunkFolderOffersEnqueue() throws {
      let comments = (0..<25).map {
        PRComment(id: "IC_\($0)", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:\(10 + $0)Z")
      }
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], trunkConfig: true),
        comments: comments)

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge, approved by alice"))
      #expect(verdict(f).options.map(\.label) == ["Enqueue #42", "Acknowledge"])
    }

    @Test(arguments: [(Bool?.none, Bool?.some(false)), (false, nil), (nil, nil)])
    func prWhoseMergeMethodWasNotReadHasNoMergeOption(_ trunkConfig: Bool?, _ mergeQueue: Bool?) throws {
      let f = try prFacts(readyPR(trunkConfig: trunkConfig, mergeQueue: mergeQueue))

      #expect(
        verdict(f)
          == Verdict(
            state: .readyToMerge,
            reason: "#42 is ready to merge; can't tell how acme/widgets merges, so merge it on GitHub"))
      #expect(verdict(f).options.map(\.action) == [.dismiss])
    }

    @Test func prWithOnlyOtherBotCommentsIsReadyToMerge() throws {
      let comments = [PRComment(id: "IC_gh", author: "github-actions[bot]", createdAt: "2026-10-24T00:00:00Z")]
      let f = try prFacts(readyPR(), comments: comments)

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test(arguments: [PRState.merged, .closed])
    func finishedPRIsNotReadyToMerge(_ state: PRState) throws {
      var pr = readyPR()
      pr.state = state
      let f = try prFacts(pr, dirty: 0)

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test(arguments: [
      Dependency(via: .body, repo: "acme/widgets", number: 7, state: .open),
      Dependency(via: .body, repo: "acme/widgets", number: 7, state: nil),
      Dependency(via: .stack, repo: "acme/widgets", number: 7, state: .open),
      Dependency(via: .body, repo: "acme/widgets", number: 7, deploy: true, state: .merged, deployed: false),
    ])
    func prThatADependencyHoldsIsNotReadyToMerge(_ dependency: Dependency) throws {
      let f = try prFacts(readyPR(), then: [try dependenciesEvent(3, [dependency])])

      #expect(verdict(f).state != .readyToMerge)
    }

    @Test func prWhoseDependenciesResolvedIsReadyToMerge() throws {
      let resolved = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .merged)
      let f = try prFacts(readyPR(), then: [try dependenciesEvent(3, [resolved])])

      #expect(verdict(f).state == .readyToMerge)
    }

    // An idle session only

    @Test func readyPRWhileATurnRunsIsWorking() throws {
      let f = try prFacts(readyPR(), then: [event("UserPromptSubmit", 4, ["prompt": "keep going"])])

      #expect(verdict(f).state == .working)
    }

    @Test func readyPRWithAnOpenPermissionNeedsYou() throws {
      let f = try prFacts(
        readyPR(),
        then: [
          event("UserPromptSubmit", 4, ["prompt": "keep going"]),
          event("PermissionRequest", 5, tool("Bash", ["command": "rm -rf build"])),
        ])

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "approve `rm -rf build`"))
    }

    @Test func readyPRWithAnOpenQuestionNeedsYou() throws {
      let input: [String: JSON] = ["questions": [["question": "Which fruit?"]]]
      let f = try prFacts(
        readyPR(),
        then: [
          event("UserPromptSubmit", 4, ["prompt": "keep going"]),
          event("PreToolUse", 5, tool("AskUserQuestion", input, id: "q")),
        ])

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "answer: Which fruit?"))
    }

    @Test func readyPRWithAnOpenWaitIsReadyForReview() throws {
      let f = try prFacts(readyPR(reviewDecision: .reviewRequired))

      #expect(
        verdict(f, session(wait: "the deploy of #42"))
          == sampleReadyForReview("the deploy of #42", checks: "checks success"))
    }

    @Test func readyPRStaysReadyToMergeAfterTheStaleInterval() throws {
      let f = try prFacts(readyPR())

      #expect(Attention.evaluate(session(), f, now: Attention.staleAfterMs + 10).state == .readyToMerge)
    }

    // Conflict reason

    @Test(arguments: [
      ("main", "merge main in; #42 conflicts with main"), ("develop", "merge develop in; #42 conflicts with develop"),
    ])
    func conflictReasonNamesTheBaseBranch(_ base: String, _ reason: String) throws {
      let f = try prFacts(readyPR(base: base, mergeable: .conflicting))

      #expect(verdict(f) == Verdict(state: .needsYou, reason: reason))
    }

    // Merge attempts

    @Test func oldDismissedEventAtTheHeadLeavesThePRReadyToMerge() throws {
      let f = try prFacts(readyPR(), then: [mergeEvent(3, head: samplePRHead, "dismissed")])

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    // Acknowledgments

    @Test func acknowledgedApprovedPRIsWaitingWithItsReason() throws {
      let reason = "#42 is ready to merge, approved by alice"
      let f = try prFacts(
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")]),
        then: [try ackEvent(3, reason, head: samplePRHead)])

      let v = verdict(f)

      #expect(v == Verdict(state: .waiting, reason: reason))
      #expect(v.acknowledged)
    }

    @Test func pushAfterAnAcknowledgmentMakesThePRReadyAgain() throws {
      let f = try prFacts(
        readyPR(),
        then: [
          try ackEvent(3, "#42 is ready to merge", head: samplePRHead),
          event("pr", 4, ["pr": try JSON(encoding: readyPR(headSha: "pushed"))]),
        ])

      let v = verdict(f)

      #expect(v.state == .readyToMerge)
      #expect(!v.acknowledged)
    }

    @Test func acknowledgmentStaysAcrossPollsOfTheSameHead() throws {
      var retitled = readyPR()
      retitled.title = "a new title"
      let f = try prFacts(
        readyPR(),
        then: [
          try ackEvent(3, "#42 is ready to merge", head: samplePRHead),
          event("pr", 4, ["pr": try JSON(encoding: retitled)]),
        ])

      #expect(verdict(f).acknowledged)
    }

    @Test func newTurnAfterAnAcknowledgmentMakesThePRReadyAgain() throws {
      let f = try prFacts(
        readyPR(),
        then: [
          try ackEvent(3, "#42 is ready to merge", head: samplePRHead),
          event("UserPromptSubmit", 4, ["prompt": "one more thing"]),
          event("Stop", 5, ["last_assistant_message": "Pushed."]),
        ])

      let v = verdict(f)

      #expect(v.state == .readyToMerge)
      #expect(!v.acknowledged)
    }

    @Test func failedAttemptAtTheHeadStaysReadyToMerge() throws {
      let f = try prFacts(
        readyPR(), then: [mergeEvent(3, head: samplePRHead, "failed", error: "Pull request is not mergeable")])

      #expect(verdict(f) == Verdict(state: .readyToMerge, reason: "#42 is ready to merge"))
    }

    @Test func mergedAttemptAtTheHeadIsNotReadyToMerge() throws {
      let f = try prFacts(readyPR(), then: [mergeEvent(3, head: samplePRHead, "merged")])

      #expect(verdict(f) == Verdict(state: .waiting, reason: "#42 merged; GitHub has not reported it yet"))
    }

    @Test func mergedAttemptAtAnOlderHeadIsReadyToMerge() throws {
      let f = try prFacts(readyPR(), then: [mergeEvent(3, head: "older", "merged")])

      #expect(verdict(f).state == .readyToMerge)
    }
  }
}

// MARK: - Merge summary

private let gist = "It lets a sibling decide the result in either order."
private let briefText = "It makes cohorts with unknown groups match the same way in any order."
private let approvedFacts = "4 files, +315 -208. Approved by stamphog. Checks passed."

private func approvedPR(
  base: String = "main", mergeable: Mergeable? = .mergeable, checks: String? = "SUCCESS", headSha: String = samplePRHead
) -> PullRequest {
  readyPR(
    headSha: headSha, base: base, mergeable: mergeable, reviewDecision: .approved,
    verdicts: [sampleVerdict("stamphog", "APPROVED")], checks: checks)
}

/// Details that `GitHub.parseMergeDetails` could give for #42.
private func mergeDetails(
  threads: Int = 0, threadsRead: Int? = nil, openThreads: Int = 0, gist: String? = gist, testGaps: [String] = []
) -> MergeDetails {
  MergeDetails(
    additions: 315, deletions: 208, changedFiles: 4, threads: threads, threadsRead: threadsRead ?? threads,
    openThreads: openThreads, description: "The description.", gist: gist, testGaps: testGaps)
}

private func withDetails(_ pr: PullRequest, _ details: MergeDetails?) -> PullRequest {
  var pr = pr
  pr.mergeDetails = details
  return pr
}

private func briefEvent(
  _ t: Int64, pr: Int = 42, head: String = samplePRHead, text: String? = nil, error: String? = nil,
  skipped: String? = nil
) -> Event {
  var fields: [String: JSON] = ["pr": .number(Double(pr)), "head": .string(head)]
  if let text { fields["text"] = .string(text) }
  if let error { fields["error"] = .string(error) }
  if let skipped { fields["skipped"] = .string(skipped) }
  return event(MergeBrief.event, t, fields)
}

/// A ready, approved PR #42 with `details` and then `then`.
private func summaryFacts(
  _ pr: PullRequest = approvedPR(), details: MergeDetails? = mergeDetails(), then: [Event] = []
) throws -> SessionFacts {
  try prFacts(withDetails(pr, details), then: then)
}

/// `text` without the backslashes and word joiners that `MarkdownText.escaped` adds.
private func unescaped(_ text: String) -> String {
  var out = ""
  var escaping = false
  for c in text where c != "\u{2060}" {
    if !escaping, c == "\\" {
      escaping = true
      continue
    }
    escaping = false
    out.append(c)
  }
  return out
}

/// The verdict's Summary as the card shows it.
private func shownSummary(_ v: Verdict) -> String? { v.summary.map(unescaped) }

/// A ready PR whose author is haacked, with a code owner requirement and the
/// code owner requests that GitHub made.
private func ownedPR(_ groups: [[String]]?, requests: [String]?, verdicts: [Review] = []) -> PullRequest {
  var pr = readyPR(verdicts: verdicts)
  pr.author = "haacked"
  pr.codeOwners = groups.map { CodeOwnerRequirement(groups: $0) }
  pr.codeOwnerRequests = requests
  return pr
}

private func textHasLinkOrImage(_ text: MarkdownText) -> Bool {
  text.runs.contains { $0.link != nil || $0.image != nil }
}

/// Whether any block, at any depth, holds a link or an image.
private func blockHasLinkOrImage(_ block: MarkdownBlock) -> Bool {
  switch block {
  case .heading(_, let text), .paragraph(let text): textHasLinkOrImage(text)
  case .images: true
  case .list(_, let items): items.contains { $0.blocks.contains(where: blockHasLinkOrImage) }
  case .code, .rule: false
  case .quote(let blocks): blocks.contains(where: blockHasLinkOrImage)
  case .table(let header, _, let rows): (header + rows.flatMap { $0 }).contains(where: textHasLinkOrImage)
  case .details(let summary, _, let blocks):
    textHasLinkOrImage(summary) || blocks.contains(where: blockHasLinkOrImage)
  case .footnotes(let notes): notes.contains { $0.blocks.contains(where: blockHasLinkOrImage) }
  }
}

private func rendersALinkOrImage(_ markdown: String) -> Bool {
  MarkdownBlock.parse(markdown).contains(where: blockHasLinkOrImage)
}

/// The text of `markdown` when it parses to one paragraph, and nil otherwise.
private func paragraphText(_ markdown: String) -> String? {
  let blocks = MarkdownBlock.parse(markdown)
  guard blocks.count == 1, case .paragraph(let text) = blocks[0] else { return nil }
  return text.plain
}

/// Text that a PR's author or the model controls and that would render as a
/// link or an image if it reached the card as Markdown.
private let hostileText = [
  "[x](file:///etc/passwd)",
  "[x](javascript:alert(1))",
  "<https://evil.example>",
  "<file:///etc/passwd>",
  "![i](https://x.example/y.png)",
  // What `.plain` makes of the escaped `\[x\](y)`.
  "[x](y)",
  "\\[x\\](file:///etc/passwd)",
  "<a href=\"file:///etc/passwd\">x</a>",
  "<img src=\"https://x.example/y.png\">",
  "[x][ref] [ref]: file:///etc/passwd",
  "[x][ref]\n\n[ref]: file:///etc/passwd",
  // GitHub's autolink extension links these without any syntax.
  "see https://evil.example/x now",
  "see www.evil.example now",
  "mail a@evil.example now",
  // U+0600 is a prepend mark and U+0301 a combining mark. Each forms one grapheme cluster with the bracket beside it.
  "\u{0600}[x\u{0600}](file:///etc/passwd)",
  "[\u{0301}x\u{0600}](y:z)",
  "\u{0600}!\u{0600}[i\u{0600}](https://x.example/y.png)",
  "\u{0600}\\[x\u{0600}\\](file:///etc/passwd)",
]

/// Where PR-derived text enters the card.
enum HostilePath: String, CaseIterable, CustomStringConvertible, Sendable {
  case gist, testGap, brief
  var description: String { rawValue }
}

extension MergeAttentionTests {
  @Suite struct MergeSummaryFacts {
    @Test func prEventCarriesTheDetails() throws {
      let f = try summaryFacts()

      #expect(f.pr?.mergeDetails == mergeDetails())
    }

    @Test func laterPREventReplacesTheDetails() throws {
      let f = try summaryFacts(then: [try prEvent(4, withDetails(approvedPR(), mergeDetails(openThreads: 1)))])

      #expect(f.pr?.mergeDetails == mergeDetails(openThreads: 1))
    }

    @Test func prWithoutDetailsHasNoDetails() throws {
      #expect(try summaryFacts(details: nil).pr?.mergeDetails == nil)
    }

    @Test func mergeBriefEventWithTextSetsTheBrief() throws {
      let f = try summaryFacts(then: [briefEvent(4, text: briefText)])

      #expect(f.mergeBrief == MergeBrief(pr: 42, head: samplePRHead, text: briefText))
    }

    @Test func mergeBriefErrorKeepsTheLastBrief() throws {
      let f = try summaryFacts(then: [briefEvent(4, text: briefText), briefEvent(5, error: "claude timed out")])

      #expect(f.mergeBrief?.text == briefText)
    }

    @Test func mergeBriefSkipKeepsTheLastBrief() throws {
      let f = try summaryFacts(then: [
        briefEvent(4, text: briefText), briefEvent(5, skipped: "the hourly limit was reached"),
      ])

      #expect(f.mergeBrief?.text == briefText)
    }

    @Test func mergeBriefWithTextCountsAsASummaryCall() {
      let f = facts([briefEvent(50, text: briefText)])

      #expect(f.summaryCalls == [50])
    }

    @Test func failedMergeBriefCountsAsASummaryCall() {
      let f = facts([briefEvent(50, error: "claude timed out")])

      #expect(f.summaryCalls == [50])
    }

    @Test func skippedMergeBriefDoesNotCountAsASummaryCall() {
      let f = facts([briefEvent(50, skipped: "the hourly limit was reached")])

      #expect(f.summaryCalls.isEmpty)
    }

    @Test func mergeBriefAndTriageShareTheSummaryCalls() {
      let f = facts([
        event("triage", 40, ["stop": 1, "error": "timed out"]),
        briefEvent(50, text: briefText),
      ])

      #expect(f.summaryCalls == [40, 50])
    }
  }
}

extension MergeAttentionTests {
  @Suite struct MergeSummary {
    // The Summary text

    @Test func readyPRWithDetailsShowsTheGistThenTheFacts() throws {
      let v = verdict(try summaryFacts())

      #expect(shownSummary(v) == "\(gist)\n\n\(approvedFacts)")
    }

    @Test func readyPRSummarizesThePR() throws {
      #expect(verdict(try summaryFacts()).summarizesPR)
    }

    @Test func readyPRKeepsItsTitleReason() throws {
      let v = verdict(try summaryFacts())

      #expect(v == Verdict(state: .readyToMerge, reason: "#42 is ready to merge, approved by stamphog"))
    }

    @Test func readyPRWithoutDetailsShowsTheFactsLineWithoutTheSize() throws {
      let v = verdict(try summaryFacts(details: nil))

      #expect(shownSummary(v) == "Approved by stamphog. Checks passed.")
      #expect(v.summarizesPR)
    }

    @Test func readyPRWithoutAGistShowsTheFactsLineAlone() throws {
      let v = verdict(try summaryFacts(details: mergeDetails(gist: nil)))

      #expect(shownSummary(v) == approvedFacts)
    }

    @Test func readyPRWithAnUnknownMergeMethodSaysToMergeOnGitHub() throws {
      let v = verdict(try summaryFacts(readyPR(trunkConfig: nil, mergeQueue: nil)))

      #expect(shownSummary(v)?.hasSuffix("sbd can't tell how acme/widgets merges, so merge it on GitHub.") == true)
    }

    @Test func readyPRThatNobodyApprovedSaysNoReviewIsRequired() throws {
      let v = verdict(try summaryFacts(readyPR()))

      #expect(shownSummary(v) == "\(gist)\n\n4 files, +315 -208. No review required. Checks passed.")
    }

    @Test func summaryDoesNotRepeatTheCardTitle() throws {
      let v = verdict(try summaryFacts(details: nil))

      #expect(shownSummary(v)?.contains("ready to merge") == false)
    }

    @Test func approvedPRWithoutChecksNeedsYouWithTheSummary() throws {
      let v = verdict(try summaryFacts(approvedPR(checks: nil)))

      #expect(v == Verdict(state: .needsYou, reason: "merge #42, approved by stamphog"))
      #expect(shownSummary(v) == "\(gist)\n\n4 files, +315 -208. Approved by stamphog. No checks ran.")
      #expect(v.summarizesPR)
    }

    @Test func approvedPRStackedOnAnotherBranchNeedsYouWithTheSummary() throws {
      let v = verdict(try summaryFacts(approvedPR(base: "haacked/parent")))

      #expect(v.state == .needsYou)
      #expect(shownSummary(v) == "\(gist)\n\n\(approvedFacts)")
      #expect(v.summarizesPR)
    }

    @Test(arguments: [
      ("review required", readyPR(reviewDecision: .reviewRequired)),
      ("conflict", approvedPR(mergeable: .conflicting)),
      ("checks failed", approvedPR(checks: "FAILURE")),
      ("checks running", approvedPR(checks: "PENDING")),
      ("draft", readyPR(draft: true, reviewDecision: .approved, verdicts: [sampleVerdict("stamphog", "APPROVED")])),
      ("changes requested", readyPR(reviewDecision: .changesRequested)),
    ])
    func otherVerdictsDoNotSummarizeThePR(_ label: String, _ pr: PullRequest) throws {
      let v = verdict(try summaryFacts(pr))

      #expect(!v.summarizesPR, "\(label)")
      #expect(shownSummary(v)?.contains(gist) != true, "\(label)")
    }

    // A push

    @Test func detailsAtTheNewHeadAfterAPushShow() throws {
      let newer = withDetails(approvedPR(headSha: "pushed"), mergeDetails(gist: "It also drops the old path."))
      let v = verdict(try summaryFacts(then: [try prEvent(4, newer)]))

      #expect(shownSummary(v) == "It also drops the old path.\n\n\(approvedFacts)")
    }

    // The brief

    @Test func briefAtTheCurrentHeadReplacesTheGist() throws {
      let v = verdict(try summaryFacts(then: [briefEvent(4, text: briefText)]))

      #expect(shownSummary(v) == "\(briefText)\n\n\(approvedFacts)")
    }

    @Test func briefAtAnOlderHeadIsIgnored() throws {
      let v = verdict(try summaryFacts(then: [briefEvent(4, head: "older", text: briefText)]))

      #expect(shownSummary(v) == "\(gist)\n\n\(approvedFacts)")
    }

    @Test func briefForAnotherPRIsIgnored() throws {
      let v = verdict(try summaryFacts(then: [briefEvent(4, pr: 41, text: briefText)]))

      #expect(shownSummary(v) == "\(gist)\n\n\(approvedFacts)")
    }

    @Test func failedBriefLeavesTheGist() throws {
      let v = verdict(try summaryFacts(then: [briefEvent(4, error: "claude timed out")]))

      #expect(shownSummary(v) == "\(gist)\n\n\(approvedFacts)")
    }

    @Test func skippedBriefLeavesTheGist() throws {
      let v = verdict(try summaryFacts(then: [briefEvent(4, skipped: "the hourly limit was reached")]))

      #expect(shownSummary(v) == "\(gist)\n\n\(approvedFacts)")
    }

    @Test func briefFromBeforeAPushIsIgnored() throws {
      let newer = withDetails(approvedPR(headSha: "pushed"), mergeDetails(gist: "It also drops the old path."))
      let v = verdict(try summaryFacts(then: [briefEvent(4, text: briefText), try prEvent(5, newer)]))

      #expect(shownSummary(v) == "It also drops the old path.\n\n\(approvedFacts)")
    }

    /// The brief matches the head on its own, so it shows before the poller
    /// reads the details at that head. The facts line then has no size.
    @Test func briefAtTheCurrentHeadShowsWithoutDetails() throws {
      let v = verdict(try summaryFacts(details: nil, then: [briefEvent(4, text: briefText)]))

      #expect(shownSummary(v) == "\(briefText)\n\nApproved by stamphog. Checks passed.")
    }

    @Test func briefOnTheNeedsYouMergeCardReplacesTheGist() throws {
      let v = verdict(try summaryFacts(approvedPR(checks: nil), then: [briefEvent(4, text: briefText)]))

      #expect(shownSummary(v) == "\(briefText)\n\n4 files, +315 -208. Approved by stamphog. No checks ran.")
    }
  }
}

extension MergeAttentionTests {
  @Suite struct MergeCallouts {
    @Test func readyPRWithNothingToPauseHasNoCallouts() throws {
      #expect(verdict(try summaryFacts()).callouts.isEmpty)
    }

    // Code owners

    @Test func waitingCodeOwnerGroupGivesARequiredCallout() throws {
      let v = verdict(try summaryFacts(ownedPR([["@PostHog/team-flags"]], requests: [])))

      #expect(v.callouts.map(\.kind) == [.warning])
      #expect(v.callouts.map(\.title) == ["Code owner review still required"])
      #expect(v.callouts.map { unescaped($0.body) } == ["@PostHog/team-flags"])
    }

    @Test func requiredCalloutJoinsAGroupsOwnersWithOr() throws {
      let v = verdict(try summaryFacts(ownedPR([["@alice", "@bob"]], requests: [])))

      #expect(v.callouts.map(\.kind) == [.warning])
      #expect(v.callouts.map(\.title) == ["Code owner review still required"])
      #expect(v.callouts.map { unescaped($0.body) } == ["@alice or @bob"])
    }

    @Test func requiredCalloutNamesEveryWaitingGroup() throws {
      let v = verdict(try summaryFacts(ownedPR([["@PostHog/team-flags"], ["@alice", "@bob"]], requests: [])))

      let callout = try #require(v.callouts.first)
      #expect(callout.title == "Code owner review still required")
      #expect(unescaped(callout.body).contains("@PostHog/team-flags"))
      #expect(unescaped(callout.body).contains("@alice or @bob"))
      #expect(unescaped(callout.body).contains("; "))
    }

    @Test func requiredCalloutLeavesOutAnApprovedGroup() throws {
      let pr = ownedPR(
        [["@PostHog/team-flags"], ["@carol"]], requests: [],
        verdicts: [sampleVerdict("carol", "APPROVED", on: samplePRHead)])

      let v = verdict(try summaryFacts(pr))

      #expect(v.callouts.map(\.title) == ["Code owner review still required"])
      #expect(v.callouts.map { unescaped($0.body) } == ["@PostHog/team-flags"])
    }

    @Test func satisfiedCodeOwnersGiveNoCallout() throws {
      let pr = ownedPR([["@carol"]], requests: [], verdicts: [sampleVerdict("carol", "APPROVED", on: samplePRHead)])

      #expect(verdict(try summaryFacts(pr)).callouts.isEmpty)
    }

    @Test func openCodeOwnerRequestGivesARequestedCallout() throws {
      let v = verdict(try summaryFacts(ownedPR(nil, requests: ["@PostHog/team-flags"])))

      let callout = try #require(v.callouts.first)
      #expect(v.callouts.count == 1)
      #expect(callout.kind == .warning)
      #expect(callout.title == "Code owners still requested")
      #expect(unescaped(callout.body).contains("@PostHog/team-flags"))
    }

    @Test(arguments: [[String]?.none, []])
    func noCodeOwnerRequestGivesNoCallout(_ requests: [String]?) throws {
      #expect(verdict(try summaryFacts(ownedPR(nil, requests: requests))).callouts.isEmpty)
    }

    // Review threads

    @Test(arguments: [
      (1, 1, 1, "1 open review thread"),
      (2, 2, 2, "2 open review threads"),
      (5, 5, 3, "3 open review threads"),
      (150, 100, 3, "At least 3 open review threads"),
      (150, 100, 0, "Not every review thread was read"),
    ])
    func openThreadsGiveACallout(_ threads: Int, _ read: Int, _ open: Int, _ title: String) throws {
      let v = verdict(try summaryFacts(details: mergeDetails(threads: threads, threadsRead: read, openThreads: open)))

      #expect(v.callouts.map(\.title) == [title])
      #expect(v.callouts.allSatisfy { $0.kind == .warning })
    }

    @Test(arguments: [(150, 100, 3), (150, 100, 0), (3, 2, 1)])
    func unreadThreadsSayHowManyWereRead(_ threads: Int, _ read: Int, _ open: Int) throws {
      let v = verdict(try summaryFacts(details: mergeDetails(threads: threads, threadsRead: read, openThreads: open)))

      #expect(v.callouts.map(\.body) == ["#42 has \(threads) review threads, and sbd read \(read)."])
    }

    @Test(arguments: [(0, 0), (4, 4)])
    func everyThreadReadAndResolvedGivesNoCallout(_ threads: Int, _ read: Int) throws {
      let v = verdict(try summaryFacts(details: mergeDetails(threads: threads, threadsRead: read, openThreads: 0)))

      #expect(v.callouts.isEmpty)
    }

    @Test func calloutNeverSaysZeroOpenThreads() throws {
      let v = verdict(try summaryFacts(details: mergeDetails(threads: 150, threadsRead: 100, openThreads: 0)))

      #expect(!v.callouts.contains { $0.title.hasPrefix("0 ") || $0.title.contains(" 0 open") })
    }

    // Test plan

    @Test func testGapGivesAWarningThatNamesIt() throws {
      let v = verdict(try summaryFacts(details: mergeDetails(testGaps: ["Not run: the database-backed suites."])))

      let callout = try #require(v.callouts.first)
      #expect(v.callouts.count == 1)
      #expect(callout.kind == .warning)
      #expect(callout.title == "The test plan has gaps")
      #expect(unescaped(callout.body) == "- Not run: the database-backed suites.")
    }

    @Test func noTestGapGivesNoTestPlanCallout() throws {
      #expect(verdict(try summaryFacts(details: mergeDetails(testGaps: []))).callouts.isEmpty)
    }

    // Order

    @Test func calloutsComeInOrderMergeFailureCodeOwnersThreadsTestPlan() throws {
      var pr = approvedPR()
      pr.author = "haacked"
      pr.codeOwnerRequests = ["@PostHog/team-flags"]
      let details = mergeDetails(threads: 1, openThreads: 1, testGaps: ["Not run: the e2e suite."])
      let f = try summaryFacts(
        pr, details: details,
        then: [mergeEvent(4, head: samplePRHead, "failed", error: "Pull request is not mergeable")])

      let v = verdict(f)

      #expect(v.callouts.count == 4)
      #expect(
        Array(v.callouts.prefix(3).map(\.title)) == [
          "The last merge failed", "Code owners still requested", "1 open review thread",
        ])
      #expect(v.callouts.last?.kind == .warning)
      #expect(v.callouts.last?.title == "The test plan has gaps")
      #expect(v.callouts.last.map { unescaped($0.body) } == "- Not run: the e2e suite.")
    }

    @Test func calloutsStayUnderTheCardLimit() throws {
      var pr = approvedPR()
      pr.author = "haacked"
      pr.codeOwnerRequests = ["@PostHog/team-flags"]
      let details = mergeDetails(threads: 1, openThreads: 1, testGaps: ["Not run: the e2e suite."])
      let f = try summaryFacts(
        pr, details: details, then: [mergeEvent(4, head: samplePRHead, "failed", error: "not mergeable")])

      #expect(verdict(f).callouts.count <= TriageCard.maxCallouts)
    }

    @Test func needsYouMergeCardHasThePauseCallouts() throws {
      let details = mergeDetails(threads: 2, openThreads: 2)

      let v = verdict(try summaryFacts(approvedPR(checks: nil), details: details))

      #expect(v.callouts.map(\.title) == ["2 open review threads"])
    }
  }
}

// MARK: - Untrusted text

extension MergeAttentionTests {
  @Suite struct MergeSummaryEscaping {
    @Test(arguments: hostileText, HostilePath.allCases)
    func prTextRendersNoLinkOrImage(_ text: String, _ path: HostilePath) throws {
      let details: MergeDetails
      var then: [Event] = []
      switch path {
      case .gist: details = mergeDetails(gist: text)
      case .testGap: details = mergeDetails(testGaps: [text])
      case .brief:
        details = mergeDetails()
        then = [briefEvent(4, text: text)]
      }

      let v = verdict(try summaryFacts(details: details, then: then))

      let summary = try #require(v.summary)
      #expect(!rendersALinkOrImage(summary), "summary: \(summary)")
      for callout in v.callouts {
        #expect(!rendersALinkOrImage(callout.body), "callout body: \(callout.body)")
      }
    }

    /// The body goes through the real parse, where `.plain` turns `\[x\]` back into `[x]`.
    @Test func bodyThroughTheRealParseRendersNoLinkOrImage() throws {
      let body = """
        ## Problem

        It reads \\[x\\](file:///etc/passwd) and [y](file:///etc/passwd). See <https://evil.example> \
        and https://evil.example/z.

        ## Changes

        ![i](https://x.example/y.png) It adds <a href="file:///etc/passwd">a link</a>.

        ## How did you test this code?

        - [ ] Open \\[x\\](file:///etc/passwd) and www.evil.example
        """
      let node: JSON = [
        "id": "PR_1", "headRefOid": .string(samplePRHead), "title": "Fix it", "body": .string(body),
        "additions": 315, "deletions": 208, "changedFiles": 4, "reviewThreads": ["totalCount": 0, "nodes": []],
      ]
      let details = try #require(GitHub.parseMergeDetails(node)).details

      let v = verdict(try summaryFacts(details: details))

      let summary = try #require(v.summary)
      #expect(!rendersALinkOrImage(summary), "summary: \(summary)")
      for callout in v.callouts {
        #expect(!rendersALinkOrImage(callout.body), "callout body: \(callout.body)")
      }
    }

    @Test func plainProseRendersAsItself() {
      #expect(paragraphText(MarkdownText.escaped(gist)) == gist)
    }

    /// `sb --json` shows the escaped text, so ordinary punctuation stays bare.
    @Test(arguments: [
      "Not run: the database-backed suites.", "4 files, +315 -208. Approved by stamphog. Checks passed.",
      "OR(X, T) matches; it's (mostly) fine?",
    ])
    func ordinaryPunctuationIsNotEscaped(_ text: String) {
      #expect(MarkdownText.escaped(text) == text)
    }

    @Test(arguments: [
      "- a list", "+ a list", "1. a list", "12) a list", "=== heading", "see https://evil.example",
      "mailto:a@b.example", "www.evil.example",
    ])
    func syntaxAtTheStartOrALinkIsEscaped(_ text: String) {
      #expect(paragraphText(MarkdownText.escaped(text))?.replacingOccurrences(of: "\u{2060}", with: "") == text)
      #expect(!rendersALinkOrImage(MarkdownText.escaped(text)))
    }

    @Test(arguments: hostileText.filter { !$0.contains("\n") })
    func escapedTextRendersNoLinkOrImage(_ text: String) {
      #expect(!rendersALinkOrImage(MarkdownText.escaped(text)))
    }

    /// Each input would start Markdown syntax. Escaped, it renders as the same text.
    @Test(arguments: [
      "[x](y)", "\\[x\\](y)", "**bold**", "_em_", "`code`", "~~gone~~", "# heading", "- item", "+ item", "* item",
      "1. item", "1) item", "> quote", "<b>x</b>", "a | b", "***", "x &amp; y", "a\\b",
    ])
    func escapedTextRendersAsItself(_ text: String) {
      #expect(paragraphText(MarkdownText.escaped(text)) == text)
    }
  }
}

// MARK: - The trigger

extension MergeAttentionTests {
  /// `atMergeDecision` runs `openPR` without the session, so a running turn
  /// and an acknowledgment do not change it.
  @Suite struct AtMergeDecision {
    @Test(arguments: [
      ("ready, nobody approved", readyPR(), true),
      ("ready, approved", approvedPR(), true),
      ("ready, merge method unknown", readyPR(trunkConfig: nil, mergeQueue: nil), true),
      ("approved, no checks", approvedPR(checks: nil), true),
      (
        "approved without a decision, a review request open",
        readyPR(verdicts: [sampleVerdict("stamphog", "APPROVED")], reviewRequests: ["bob"]), true
      ),
      ("approved, stacked on another branch", approvedPR(base: "haacked/parent"), true),
      ("under review", readyPR(reviewDecision: .reviewRequired), false),
      ("review requested, nobody approved", readyPR(reviewRequests: ["bob"]), false),
      ("no checks, nobody approved", readyPR(checks: nil), false),
      ("approved, checks running", approvedPR(checks: "PENDING"), false),
      ("approved, checks expected", approvedPR(checks: "EXPECTED"), false),
      ("approved, mergeability unknown", approvedPR(mergeable: .unknown), false),
      ("approved, conflict", approvedPR(mergeable: .conflicting), false),
      ("approved, checks failed", approvedPR(checks: "FAILURE"), false),
      ("changes requested", readyPR(reviewDecision: .changesRequested), false),
      ("merged base", readyPR(base: "haacked/parent", mergedBase: 41), false),
      (
        "draft, approved",
        readyPR(draft: true, reviewDecision: .approved, verdicts: [sampleVerdict("stamphog", "APPROVED")]), false
      ),
      (
        "Trunk queue status unknown",
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("stamphog", "APPROVED")], queue: .unknown), false
      ),
      (
        "in Trunk's queue",
        readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("stamphog", "APPROVED")], queue: .queued), false
      ),
    ])
    func decidesFromThePR(_ label: String, _ pr: PullRequest, _ expected: Bool) throws {
      #expect(Attention.atMergeDecision(try prFacts(pr)) == expected, "\(label)")
    }

    @Test(arguments: [PRState.merged, .closed])
    func finishedPRIsNotAtAMergeDecision(_ state: PRState) throws {
      var pr = approvedPR()
      pr.state = state

      #expect(Attention.atMergeDecision(try prFacts(pr, dirty: 0)) == false)
    }

    @Test func approvedPRInGitHubsMergeQueueIsNotAtAMergeDecision() throws {
      var pr = approvedPR()
      pr.inMergeQueue = true

      #expect(Attention.atMergeDecision(try prFacts(pr)) == false)
    }

    @Test func sessionWithoutAPRIsNotAtAMergeDecision() throws {
      #expect(Attention.atMergeDecision(try prFacts(nil)) == false)
    }

    @Test func readyPRWhileATurnRunsIsAtAMergeDecision() throws {
      let f = try prFacts(approvedPR(), then: [event("UserPromptSubmit", 4, ["prompt": "keep going"])])

      #expect(Attention.atMergeDecision(f) == true)
    }

    @Test func acknowledgedReadyPRIsAtAMergeDecision() throws {
      let f = try prFacts(
        approvedPR(), then: [try ackEvent(3, "#42 is ready to merge, approved by stamphog", head: samplePRHead)])

      #expect(Attention.atMergeDecision(f) == true)
    }

    @Test func readyPRAfterAFailedMergeIsAtAMergeDecision() throws {
      let f = try prFacts(approvedPR(), then: [mergeEvent(3, head: samplePRHead, "failed", error: "not mergeable")])

      #expect(Attention.atMergeDecision(f) == true)
    }

    @Test func prThatSbdMergedIsNotAtAMergeDecision() throws {
      let f = try prFacts(approvedPR(), then: [mergeEvent(3, head: samplePRHead, "merged")])

      #expect(Attention.atMergeDecision(f) == false)
    }

    @Test func approvedPRThatADependencyHoldsIsNotAtAMergeDecision() throws {
      let dependency = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .open)
      let f = try prFacts(approvedPR(checks: nil), then: [try dependenciesEvent(3, [dependency])])

      #expect(Attention.atMergeDecision(f) == false)
    }

    @Test func readyPRThatADependencyHoldsIsNotAtAMergeDecision() throws {
      let dependency = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .open)
      let f = try prFacts(approvedPR(), then: [try dependenciesEvent(3, [dependency])])

      #expect(Attention.atMergeDecision(f) == false)
    }
  }
}
