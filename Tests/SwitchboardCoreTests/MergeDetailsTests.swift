import Foundation
import Testing

@testable import SwitchboardCore

/// Fixtures/prs holds real PR bodies. posthog-133856.md is the body of
/// PostHog/posthog#133856 on 2026-11-11, from
/// `gh pr view 133856 -R PostHog/posthog --json body -q .body`.
private func prBody(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/prs/\(name)")
  return try String(contentsOf: url, encoding: .utf8)
}

private let title133856 = "fix(flags): let siblings decide cohorts with unsupported group types"
private let head133856 = "8d0fdba9ba58d5eba512a7b2905fffc22ed5c4c4"

/// PostHog's PR template as an author leaves it: each section holds only
/// the template's HTML comment.
private let templateBody = """
  ## Problem

  <!-- Who are we building for, what are their needs, why is this important? -->

  ## Changes

  <!-- If there are frontend changes, please include screenshots. -->
  <!-- If a reference design was involved, include a link to the relevant Figma frame! -->

  ## How did you test this code?

  <!-- Briefly describe the steps you took. Not run: anything you skipped? -->
  <!--
  - [ ] Ran the unit tests
  - [ ] Ran the e2e suite
  -->

  ## Release status

  - [ ] Behind a feature flag <!-- release-status: flag -->
  """

/// A node of `GitHub.mergeDetailsQuery`'s response. `threads` gives each
/// review thread's `isResolved`, and nil gives a null node.
private func detailsNode(
  id: JSON = "PR_kwDOJ6Ng5c7Bv2xQ", head: JSON = .string(head133856),
  title: String = title133856, body: String = "", additions: Int = 315, deletions: Int = 208, changedFiles: Int = 4,
  totalCount: Int? = nil, threads: [Bool?] = []
) -> JSON {
  var reviewThreads: [String: JSON] = [
    "nodes": .array(threads.map { $0.map { ["isResolved": .bool($0)] } ?? .null })
  ]
  reviewThreads["totalCount"] = .number(Double(totalCount ?? threads.count))
  return [
    "id": id, "headRefOid": head, "title": .string(title), "body": .string(body),
    "additions": .number(Double(additions)), "deletions": .number(Double(deletions)),
    "changedFiles": .number(Double(changedFiles)), "reviewThreads": .object(reviewThreads),
  ]
}

private func removing(_ key: String, from node: JSON) -> JSON {
  var object = node.object ?? [:]
  object[key] = nil
  return .object(object)
}

/// The suites nest under one name, so `--filter MergeDetailsTests` runs them all.
@Suite struct MergeDetailsTests {}

// MARK: - The real #133856 body

extension MergeDetailsTests {
  @Suite struct Fixture133856 {
    @Test(arguments: ["Agent context", "claude.ai", "Closes", "<!--", "Release status"])
    func descriptionLeavesOutWhatTheReaderDoesNotNeed(_ excluded: String) throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(!description.contains(excluded))
    }

    @Test func descriptionLeavesOutTheTestSection() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(!description.contains("database-backed suites"))
    }

    @Test func descriptionLeavesOutTheDetailsBlock() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(!description.contains("More context for AI agents"))
    }

    @Test func descriptionKeepsTheProblem() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(description.contains("the result depends on child order"))
    }

    @Test func descriptionKeepsTheTableAsText() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(description.contains("no match"))
    }

    @Test func gistHasAtMost300Characters() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(gist.count <= 300)
    }

    @Test func gistSaysWhatTheProblemIs() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(gist.contains("the result depends on child order"))
    }

    @Test func gistDoesNotRepeatTheTitle() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(!gist.contains(title133856))
    }

    @Test func gistIsPlainText() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(!gist.contains("`"))
      #expect(!gist.contains("]("))
    }

    /// The release-status line holds an inline comment, and the docs section
    /// is a list. Neither is in a test section.
    @Test func testGapsAreOnlyTheSuitesThatDidNotRun() throws {
      let gaps = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").testGaps

      #expect(gaps == ["Not run: the database-backed suites."])
    }
  }
}

// MARK: - Description stripping

extension MergeDetailsTests {
  @Suite struct Description {
    @Test func removesAnInlineHTMLComment() {
      let body = "## Problem\n\nThe cache drops writes. <!-- fill this in later -->"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("fill this in later"))
      #expect(description.contains("The cache drops writes."))
    }

    @Test func removesABlockHTMLComment() {
      let body = "## Problem\n\n<!--\nWho are we building for?\n-->\n\nThe cache drops writes."

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Who are we building for"))
      #expect(description.contains("The cache drops writes."))
    }

    @Test func removesADetailsBlock() {
      let body = """
        ## Problem

        The cache drops writes.

        <details>
        <summary>Logs</summary>

        stack trace here

        </details>
        """

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("stack trace here"))
      #expect(!description.contains("Logs"))
    }

    @Test func removesAnImage() {
      let body = "## Changes\n\nIt flushes before close.\n\n![screenshot](https://example.com/shot.png)"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("https://example.com/shot.png"))
    }

    @Test func removesATaskList() {
      let body = "## Changes\n\nIt flushes before close.\n\n- [ ] Update the runbook\n- [x] Add a metric"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Update the runbook"))
      #expect(!description.contains("Add a metric"))
    }

    @Test func removesALineThatIsOnlyAURL() {
      let body = "## Changes\n\nIt flushes before close.\n\nhttps://claude.ai/code/session_01ABC"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("https://claude.ai/code/session_01ABC"))
    }

    @Test(arguments: [
      "Closes #12", "Fixes #12", "Resolves #12", "closes #12", "Closed #12", "Fixed #12", "Resolved #12", "Fix #12",
      "Close #12", "Resolve #12", "Closes: #12", "Closes acme/widgets#12",
      "Closes https://github.com/acme/widgets/issues/12",
    ])
    func removesALineThatIsOnlyAClosingKeyword(_ line: String) {
      let body = "## Problem\n\nThe cache drops writes.\n\n\(line)"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("12"), "\(line)")
    }

    @Test(arguments: [
      "Testing", "How did you test this code?", "Test plan", "Release notes", "Release status", "Docs", "Docs update",
      "Documentation", "🤖 Agent context", "Checklist", "Screenshots", "Changelog", "TESTING",
    ])
    func dropsASectionWhoseHeadingNamesIt(_ heading: String) {
      let body =
        "## Problem\n\nThe cache drops writes.\n\n## \(heading)\n\nDropped words here.\n\n## Changes\n\nKept words."

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Dropped words here"), "\(heading)")
      #expect(description.contains("Kept words"), "\(heading)")
    }

    @Test(arguments: ["Latest numbers", "Attestation flow", "Contest rules", "Reagent costs"])
    func keepsASectionWhoseHeadingHasTheWordInsideAnotherWord(_ heading: String) {
      let body = "## Problem\n\nThe cache drops writes.\n\n## \(heading)\n\nKept words.\n\n- [ ] follow up"

      let read = MergeDetails.read(body: body, title: "")

      #expect(read.description.contains("Kept words"), "\(heading)")
      #expect(read.testGaps == [], "\(heading)")
    }

    @Test func dropsTheSubsectionsOfADroppedSection() {
      let body = "## Testing\n\n### Unit\n\nDropped words here.\n\n## Changes\n\nKept words."

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Dropped words here"))
      #expect(description.contains("Kept words"))
    }

    @Test func keepsAListAsText() {
      let body = "## Changes\n\n- Adds a flush before close\n- Removes the retry loop"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(description.contains("Adds a flush before close"))
      #expect(description.contains("Removes the retry loop"))
    }

    @Test func keepsATableAsText() {
      let body = "## Changes\n\n| Input | Result |\n| --- | --- |\n| empty | no write |"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(description.contains("no write"))
    }

    @Test func hasAtMost4000Characters() {
      let body = "## Problem\n\n" + String(repeating: "The cache drops writes under load. ", count: 400)

      let description = MergeDetails.read(body: body, title: "").description

      #expect(description.count <= 4000)
    }

    @Test func emptyBodyGivesAnEmptyDescription() {
      #expect(MergeDetails.read(body: "", title: "").description == "")
    }
  }
}

// MARK: - Gist

extension MergeDetailsTests {
  @Suite struct Gist {
    @Test func takesTheFirstSentenceOfEachOfTheFirstTwoSections() throws {
      let body = """
        ## Problem

        The cache drops writes. It happens under load.

        ## Changes

        It flushes before close. It also logs.

        ## Notes

        Third section words.
        """

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.contains("The cache drops writes."))
      #expect(gist.contains("It flushes before close."))
      #expect(!gist.contains("It happens under load"))
      #expect(!gist.contains("It also logs"))
      #expect(!gist.contains("Third section words"))
    }

    @Test func withoutHeadingsTakesTheFirstTwoParagraphs() throws {
      let body = "The cache drops writes. It happens under load.\n\nIt flushes before close.\n\nThird words."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.contains("The cache drops writes."))
      #expect(gist.contains("It flushes before close."))
      #expect(!gist.contains("It happens under load"))
      #expect(!gist.contains("Third words"))
    }

    @Test func withoutHeadingsTakesTheFirstTwoListItems() throws {
      let body = "- Adds a flush before close. Also a log.\n- Removes the retry loop.\n- Third item words."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.contains("Adds a flush before close."))
      #expect(gist.contains("Removes the retry loop."))
      #expect(!gist.contains("Also a log"))
      #expect(!gist.contains("Third item words"))
    }

    @Test func skipsASentenceThatEqualsTheTitle() throws {
      let body = "## Summary\n\nFlush the cache\n\n## Changes\n\nIt flushes before close."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(!gist.contains("Flush the cache"))
      #expect(gist.contains("It flushes before close."))
    }

    @Test func isNilWhenOnlyTheTitleIsLeft() {
      let body = "## Summary\n\nFlush the cache"

      #expect(MergeDetails.read(body: body, title: "Flush the cache").gist == nil)
    }

    @Test func isNilForAnEmptyBody() {
      #expect(MergeDetails.read(body: "", title: "Flush the cache").gist == nil)
    }

    @Test func hasAtMost300Characters() throws {
      let long = String(repeating: "word ", count: 120)
      let body = "## Problem\n\n\(long)ends here.\n\n## Changes\n\n\(long)ends here too."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.count <= 300)
    }

    @Test func isPlainText() throws {
      let body = "## Problem\n\nThe `XOR` group [fails](https://example.com/x) on **child order**."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(!gist.contains("`"))
      #expect(!gist.contains("**"))
      #expect(!gist.contains("https://example.com/x"))
      #expect(gist.contains("fails on child order"))
    }

    @Test func isOneLine() throws {
      let body = "The cache drops\nwrites under load.\n\nIt flushes\nbefore close."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(!gist.contains("\n"))
    }
  }
}

// MARK: - Test gaps

extension MergeDetailsTests {
  @Suite struct TestGaps {
    @Test func templateWhoseTestSectionIsOnlyACommentHasNoGaps() {
      #expect(MergeDetails.read(body: templateBody, title: "").testGaps == [])
    }

    @Test func bodyWithoutATestSectionHasNoGaps() {
      let body = "## Problem\n\nThe cache drops writes.\n\n## Changes\n\nIt flushes before close."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func uncheckedTaskInATestSectionIsAGap() {
      let body = "## Test plan\n\n- [ ] Ran the migration locally\n- [x] Ran the unit tests"

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Ran the migration locally"])
    }

    @Test func checkedTasksInATestSectionAreNotGaps() {
      let body = "## Test plan\n\n- [x] Ran the migration locally\n- [x] Ran the unit tests"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func uncheckedTaskOutsideATestSectionIsNotAGap() {
      let body = "## Docs update\n\n- [ ] Updated the docs\n\n## Testing\n\nUnit tests pass."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test(arguments: [
      "These were not tested on Windows.",
      "It was never tested against prod.",
      "Not run: the database-backed suites.",
      "The importer was never run.",
      "The rollback has not been verified.",
      "The rollback was never verified.",
      "The flow has not been tested.",
      "The migration is untested.",
      "I didn't test the UI.",
      "We did not run the e2e suite.",
      "I haven't verified the rollback.",
      "We have not tested Safari.",
      "I couldn't test the webhook.",
      "I could not verify the email.",
      "I DID NOT RUN the load test.",
    ])
    func sentenceThatSaysSomethingWasNotTestedIsAGap(_ sentence: String) {
      let body = "## How did you test this code?\n\n\(sentence)"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [sentence])
    }

    @Test(arguments: [
      "Tests run in CI.",
      "The unit tests ran and passed.",
      "I tested it by hand and verified the output.",
      "Nothing was skipped.",
      "Another test runs nightly.",
    ])
    func sentenceThatDoesNotSayItIsNotAGap(_ sentence: String) {
      let body = "## Testing\n\n\(sentence)"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func gapIsTheSentenceNotTheParagraph() {
      let body = "## Testing\n\nUnit tests pass. Not run: the e2e suite. CI is green."

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Not run: the e2e suite."])
    }

    @Test func phraseOutsideATestSectionIsNotAGap() {
      let body = "## Problem\n\nThe old path was never tested.\n\n## Testing\n\nUnit tests pass."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test(arguments: ["Testing", "Test plan", "How did you test this code?", "TESTS", "Manual testing"])
    func headingThatContainsTestStartsATestSection(_ heading: String) {
      let body = "## \(heading)\n\nNot run: the e2e suite."

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Not run: the e2e suite."], "\(heading)")
    }

    @Test func subheadingStaysInTheTestSection() {
      let body = "## Test plan\n\n### Manual\n\n- [ ] Clicked through the wizard"

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Clicked through the wizard"])
    }

    @Test func headingOfTheSameLevelEndsTheTestSection() {
      let body = "## Testing\n\nUnit tests pass.\n\n## Notes\n\nNot run: the e2e suite.\n\n- [ ] Tell the team"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func headingOfAHigherLevelEndsTheTestSection() {
      let body = "### Testing\n\nUnit tests pass.\n\n## Notes\n\nNot run: the e2e suite."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func inlineCommentInATestSectionIsNotAGap() {
      let body = "## Testing\n\nUnit tests pass. <!-- List anything that was not tested. -->"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func blockCommentInATestSectionIsNotAGap() {
      let body = "## Testing\n\n<!--\n- [ ] Ran the e2e suite\nNot run: anything you skipped.\n-->\n\nUnit tests pass."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func gapIsPlainText() {
      let body = "## Test plan\n\n- [ ] Check [the page](file:///etc/passwd) in `Safari`"

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Check the page in Safari"])
    }

    @Test func atMostFiveGaps() {
      let items = (1...8).map { "- [ ] Step \($0)" }.joined(separator: "\n")

      #expect(MergeDetails.read(body: "## Test plan\n\n\(items)", title: "").testGaps.count == 5)
    }

    @Test func keepsTheFirstFiveGapsInOrder() {
      let items = (1...8).map { "- [ ] Step \($0)" }.joined(separator: "\n")

      #expect(
        MergeDetails.read(body: "## Test plan\n\n\(items)", title: "").testGaps == [
          "Step 1", "Step 2", "Step 3", "Step 4", "Step 5",
        ])
    }

    @Test func eachGapFitsALine() {
      let long = String(repeating: "click ", count: 100)

      let gaps = MergeDetails.read(body: "## Test plan\n\n- [ ] \(long)", title: "").testGaps

      #expect(gaps.count == 1)
      #expect(gaps.allSatisfy { $0.count <= TriageCard.lineLength })
    }
  }
}

// MARK: - GitHub.parseMergeDetails

extension MergeDetailsTests {
  @Suite struct Parsing {
    @Test func readsTheHead() throws {
      let parsed = try #require(GitHub.parseMergeDetails(detailsNode()))

      #expect(parsed.head == head133856)
    }

    @Test func readsTheSize() throws {
      let details = try #require(GitHub.parseMergeDetails(detailsNode())).details

      #expect(details.additions == 315)
      #expect(details.deletions == 208)
      #expect(details.changedFiles == 4)
    }

    @Test func readsTheBodyIntoTheDescriptionGistAndGaps() throws {
      let body = try prBody("posthog-133856.md")

      let details = try #require(GitHub.parseMergeDetails(detailsNode(body: body))).details

      #expect(details.description == MergeDetails.read(body: body, title: title133856).description)
      #expect(details.gist?.contains("the result depends on child order") == true)
      #expect(details.testGaps == ["Not run: the database-backed suites."])
    }

    @Test func readsAnEmptyBody() throws {
      let details = try #require(GitHub.parseMergeDetails(detailsNode(body: ""))).details

      #expect(details.description == "")
      #expect(details.gist == nil)
      #expect(details.testGaps == [])
    }

    @Test(arguments: [
      // Every thread read.
      (0, [Bool?](), 0, 0, 0),
      (2, [true, true], 2, 2, 0),
      (2, [true, false], 2, 2, 1),
      (2, [false, false], 2, 2, 2),
      // GitHub returns at most 100 nodes.
      (150, [Bool?](repeating: true, count: 100), 150, 100, 0),
      (150, [Bool?](repeating: true, count: 97) + [false, false, false], 150, 100, 3),
      // A null node is not a thread that sbd read.
      (3, [true, nil, false], 3, 2, 1),
      (2, [nil, nil], 2, 0, 0),
    ])
    func countsTheThreads(
      _ totalCount: Int, _ threads: [Bool?], _ expectedThreads: Int, _ expectedRead: Int, _ expectedOpen: Int
    ) throws {
      let details = try #require(
        GitHub.parseMergeDetails(detailsNode(totalCount: totalCount, threads: threads))
      ).details

      #expect(details.threads == expectedThreads)
      #expect(details.threadsRead == expectedRead)
      #expect(details.openThreads == expectedOpen)
    }

    @Test(arguments: ["headRefOid", "additions", "deletions", "changedFiles", "reviewThreads"])
    func nodeWithoutAFieldItNeedsGivesNoDetails(_ key: String) {
      #expect(GitHub.parseMergeDetails(removing(key, from: detailsNode())) == nil, "\(key)")
    }

    @Test func nodeWithoutATotalCountGivesNoDetails() {
      let node: JSON = [
        "id": "PR_1", "headRefOid": "abc", "title": "t", "body": "", "additions": 1, "deletions": 0,
        "changedFiles": 1, "reviewThreads": ["nodes": [["isResolved": false]]],
      ]

      #expect(GitHub.parseMergeDetails(node) == nil)
    }

    @Test(arguments: [JSON.null, JSON.object([:])])
    func nodeThatIsNotAPRGivesNoDetails(_ node: JSON) {
      #expect(GitHub.parseMergeDetails(node) == nil)
    }

    @Test func nullHeadGivesNoDetails() {
      #expect(GitHub.parseMergeDetails(detailsNode(head: .null)) == nil)
    }

    @Test func queryReadsTheFieldsItParses() {
      let query = GitHub.mergeDetailsQuery

      for field in [
        "headRefOid", "title", "body", "additions", "deletions", "changedFiles", "reviewThreads(first: 100)",
        "totalCount", "isResolved",
      ] {
        #expect(query.contains(field), "\(field)")
      }
    }
  }
}

// MARK: - Lead

extension MergeDetailsTests {
  /// `lead` is the gist's first sentence, which a Nudge all bullet shows.
  @Suite struct Lead {
    @Test func aOneSentenceGistIsItsOwnLead() {
      #expect(MergeDetails.lead("It caches flag reads per request.") == "It caches flag reads per request.")
    }

    @Test func aTwoSentenceGistLeadsWithItsFirstSentence() {
      let gist = "It caches flag reads per request. It also logs each miss."

      #expect(MergeDetails.lead(gist) == "It caches flag reads per request.")
    }

    @Test func aGistWithoutASentenceEndIsItsOwnLead() {
      #expect(MergeDetails.lead("It caches flag reads per request") == "It caches flag reads per request")
    }

    @Test func aDotInsideANameDoesNotEndTheLead() {
      let gist = "It reads README.md before the build. It also logs."

      #expect(MergeDetails.lead(gist) == "It reads README.md before the build.")
    }
  }
}
