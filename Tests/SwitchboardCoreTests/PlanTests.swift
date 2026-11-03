import Foundation
import Testing

@testable import SwitchboardCore

private let start = "<!-- sb:status -->"
private let end = "<!-- /sb:status -->"

private func pr(_ repo: String, _ number: Int) -> PlanLink { PlanLink(repo: repo, number: number) }

private func url(_ repo: String, _ number: Int) -> String { "https://github.com/\(repo)/pull/\(number)" }

@Suite struct PlanSourceParsing {
  @Test(arguments: ["/Users/me/notes/plan.md", "/tmp/flag evaluations.md", "/tmp/notes#1.md"])
  func absolutePathIsAFile(_ doc: String) throws {
    let source = try PlanSource(parsing: doc, path: nil)

    #expect(source.kind == .file)
    #expect(source.path == doc)
    #expect(source.repo == nil)
    #expect(source.number == nil)
  }

  @Test(arguments: [
    "PostHog/requests-for-comments-internal#1300",
    "https://github.com/PostHog/requests-for-comments-internal/issues/1300",
    "https://github.com/PostHog/requests-for-comments-internal/issues/1300/",
    "https://github.com/PostHog/requests-for-comments-internal/issues/1300#issuecomment-123",
  ])
  func issueInEachFormNamesItsRepoAndNumber(_ doc: String) throws {
    let source = try PlanSource(parsing: doc, path: nil)

    #expect(source.kind == .issue)
    #expect(source.repo == "PostHog/requests-for-comments-internal")
    #expect(source.number == 1300)
    #expect(source.path == nil)
  }

  @Test(arguments: [
    "PostHog/requests-for-comments-internal#1209",
    "https://github.com/PostHog/requests-for-comments-internal/pull/1209",
    "https://github.com/PostHog/requests-for-comments-internal/pull/1209/files",
    "https://github.com/PostHog/requests-for-comments-internal/pull/1209#discussion_r1",
  ])
  func prWithAPathNamesItsRepoNumberAndPath(_ doc: String) throws {
    let source = try PlanSource(parsing: doc, path: "rfcs/flag-evaluations.md")

    #expect(source.kind == .pr)
    #expect(source.repo == "PostHog/requests-for-comments-internal")
    #expect(source.number == 1209)
    #expect(source.path == "rfcs/flag-evaluations.md")
  }

  @Test(arguments: [
    "https://github.com/PostHog/requests-for-comments-internal/pull/1209",
    "https://github.com/PostHog/requests-for-comments-internal/pull/1209/files",
  ])
  func prURLWithoutAPathIsRefused(_ doc: String) {
    #expect(throws: (any Error).self) { try PlanSource(parsing: doc, path: nil) }
  }

  @Test(arguments: [
    // An issue holds no file.
    ("https://github.com/PostHog/requests-for-comments-internal/issues/1300", "rfcs/plan.md"),
    // --path names a file in a PR, not in a local file.
    ("/Users/me/notes/plan.md", "rfcs/plan.md"),
  ])
  func pathWithADocThatIsNotAPRIsRefused(_ doc: String, _ path: String) {
    #expect(throws: (any Error).self) { try PlanSource(parsing: doc, path: path) }
  }

  @Test(arguments: [
    "",
    "https://github.com/PostHog/posthog",
    "https://github.com/PostHog/posthog/pull/abc",
    "https://github.com/PostHog/posthog/issues/",
    "https://example.com/PostHog/posthog/issues/5",
  ])
  func docThatNamesNoFileIssueOrPRIsRefused(_ doc: String) {
    #expect(throws: (any Error).self) { try PlanSource(parsing: doc, path: nil) }
  }
}

@Suite struct PlanLinkParsing {
  @Test(arguments: [
    "Done ([posthog#72466](https://github.com/PostHog/posthog/pull/72466))",
    "See https://github.com/PostHog/posthog/pull/72466.",
    "See https://github.com/PostHog/posthog/pull/72466, then ship.",
    "<https://github.com/PostHog/posthog/pull/72466>",
    "https://github.com/PostHog/posthog/pull/72466/files",
    "https://github.com/PostHog/posthog/pull/72466/commits/abc123",
    "https://github.com/PostHog/posthog/pull/72466#discussion_r1",
    "https://github.com/PostHog/posthog/pull/72466?w=1",
  ])
  func prURLInEachFormIsALink(_ text: String) {
    #expect(Plans.parse(text).links == [pr("PostHog/posthog", 72466)])
  }

  @Test(arguments: [
    "Follows PostHog/posthog#72466.",
    "Follows #72466.",
    "https://github.com/PostHog/posthog/issues/72466",
    "https://github.com/PostHog/posthog/pull/",
    "https://github.com/PostHog/posthog/pulls",
    "https://github.com/PostHog/posthog/commit/72466",
  ])
  func textThatIsNotAFullPRURLGivesNoLink(_ text: String) {
    #expect(Plans.parse(text).links.isEmpty)
  }

  @Test func linksKeepTheirFirstOrderAndRepeatOnlyOnce() {
    let markdown = """
      Starts with \(url("PostHog/charts", 18303)).

      | # | Item | Status |
      | --- | --- | --- |
      | 1 | Cache | Done ([posthog#2](\(url("PostHog/posthog", 2)))) |
      | 2 | Runbook | Done ([charts#18303](\(url("PostHog/charts", 18303)))) |
      """

    #expect(Plans.parse(markdown).links == [pr("PostHog/charts", 18303), pr("PostHog/posthog", 2)])
  }

  @Test func linkInAHeaderStillCounts() {
    let markdown = """
      | Item | Status ([tracking](\(url("PostHog/posthog", 1)))) |
      | --- | --- |
      """

    #expect(Plans.parse(markdown).links == [pr("PostHog/posthog", 1)])
  }
}

@Suite struct PlanRowParsing {
  static let table = """
    # Flag evaluations

    Status as of 2026-11-01. Tracking in \(url("PostHog/posthog", 9)).

    | # | Item | Status |
    | --- | --- | --- |
    | 1 | Breaker counts | In review ([posthog#122953](\(url("PostHog/posthog", 122953)))) |
    | 2 | Docs | Not started |
    | 3 | Runbook | Done ([charts#18303](\(url("PostHog/charts", 18303))), [posthog#122896](\(url("PostHog/posthog", 122896)))) |
    """

  @Test func rowIsATableLineWithAPRLink() {
    let rows = Plans.parse(PlanRowParsing.table).rows

    #expect(
      rows.map(\.text) == [
        "| 1 | Breaker counts | In review ([posthog#122953](\(url("PostHog/posthog", 122953)))) |",
        "| 3 | Runbook | Done ([charts#18303](\(url("PostHog/charts", 18303))), [posthog#122896](\(url("PostHog/posthog", 122896)))) |",
      ])
  }

  @Test func rowNamesEachOfItsPRsInOrder() {
    let rows = Plans.parse(PlanRowParsing.table).rows

    #expect(
      rows.map(\.links) == [
        [pr("PostHog/posthog", 122953)],
        [pr("PostHog/charts", 18303), pr("PostHog/posthog", 122896)],
      ])
  }

  @Test func linkOutsideATableGivesNoRow() {
    let markdown = "Tracking in \(url("PostHog/posthog", 9)).\n- [ ] Ship \(url("PostHog/posthog", 10))\n"

    let parsed = Plans.parse(markdown)

    #expect(parsed.rows.isEmpty)
    #expect(parsed.links == [pr("PostHog/posthog", 9), pr("PostHog/posthog", 10)])
  }

  @Test(arguments: ["| --- | --- |", "|---|---|", "| :--- | ---: |", "| :-: | :-: |", "|-|-|"])
  func headerAboveAnySeparatorIsNoRow(_ separator: String) {
    let markdown = "| Item | Status ([tracking](\(url("PostHog/posthog", 1)))) |\n\(separator)\n| a | b |\n"

    #expect(Plans.parse(markdown).rows.isEmpty)
  }

  @Test func rowsOfEveryTableCount() {
    let markdown = """
      | A | B |
      | --- | --- |
      | 1 | \(url("PostHog/posthog", 1)) |

      Between the tables.

      | C | D |
      | --- | --- |
      | 2 | \(url("PostHog/posthog", 2)) |
      """

    #expect(Plans.parse(markdown).rows.map(\.links) == [[pr("PostHog/posthog", 1)], [pr("PostHog/posthog", 2)]])
  }

  /// GitHub returns an issue body edited on the web with CRLF line ends.
  @Test func crlfDocumentParsesAsItsLFCopy() {
    let lf = PlanRowParsing.table + "\n\n\(start)\n| x | \(url("PostHog/posthog", 5)) |\n\(end)\n"
    let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

    let a = Plans.parse(lf)
    let b = Plans.parse(crlf)

    #expect(b.links == a.links)
    #expect(b.rows == a.rows)
    #expect(b.rows.allSatisfy { !$0.text.contains("\r") })
    #expect(
      b.statusBlock?.trimmingCharacters(in: .whitespacesAndNewlines)
        == a.statusBlock?.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

@Suite struct PlanStatusBlock {
  static let generated = """
    | Session | State | Wait | PR |
    | --- | --- | --- | --- |
    | alpha | Waiting | | \(url("PostHog/posthog", 777)) |
    """

  static let document = """
    Intro \(url("PostHog/posthog", 1)).

    \(start)
    \(generated)
    \(end)

    | # | Item | Status |
    | --- | --- | --- |
    | 1 | Cache | Done (\(url("PostHog/posthog", 2))) |
    """

  @Test func linksInTheGeneratedBlockAreLeftOut() {
    #expect(Plans.parse(PlanStatusBlock.document).links == [pr("PostHog/posthog", 1), pr("PostHog/posthog", 2)])
  }

  @Test func rowsInTheGeneratedBlockAreLeftOut() {
    #expect(Plans.parse(PlanStatusBlock.document).rows.map(\.links) == [[pr("PostHog/posthog", 2)]])
  }

  @Test func statusBlockIsTheTextBetweenTheMarkers() {
    let block = Plans.parse(PlanStatusBlock.document).statusBlock

    #expect(block?.trimmingCharacters(in: .whitespacesAndNewlines) == PlanStatusBlock.generated)
  }

  @Test func emptyBlockIsAnEmptyStatusBlock() {
    let block = Plans.parse("Intro\n\(start)\n\(end)\n").statusBlock

    #expect(block?.trimmingCharacters(in: .whitespacesAndNewlines) == "")
  }

  @Test func documentWithoutMarkersHasNoStatusBlock() {
    #expect(Plans.parse(PlanRowParsing.table).statusBlock == nil)
  }

  /// Without an end marker there is no generated block, so nothing is left out.
  @Test func startMarkerAloneLeavesNothingOut() {
    let markdown = "\(start)\n| a | \(url("PostHog/posthog", 3)) |\n"

    let parsed = Plans.parse(markdown)

    #expect(parsed.statusBlock == nil)
    #expect(parsed.links == [pr("PostHog/posthog", 3)])
  }

  @Test func onlyTheFirstPairIsTheGeneratedBlock() {
    let markdown =
      "\(start)\n| a | \(url("PostHog/posthog", 1)) |\n\(end)\n\(start)\n| b | \(url("PostHog/posthog", 2)) |\n\(end)\n"

    #expect(Plans.parse(markdown).links == [pr("PostHog/posthog", 2)])
  }
}

@Suite struct PlanSplice {
  static let table = "| Session | State | Wait | PR |\n| --- | --- | --- | --- |\n| alpha | Working | | |"

  /// Each way a document can hold one marker pair.
  static let documents: [String] = [
    "# Plan\n\nIntro.\n\n\(start)\nold table\n\(end)\n\nAfter.\n",
    "# Plan\r\n\r\nIntro.\r\n\r\n\(start)\r\nold table\r\n\(end)\r\n\r\nAfter.\r\n",
    "\(start)\n\(end)",
    "\(start)\(end)",
    "Intro.\n\(start)\nold\n\(end)",
    "\(start)\nold\n\(end)\nAfter with \(url("PostHog/posthog", 1)).\n",
  ]

  /// The text before the start marker and after the end marker.
  func outside(_ markdown: String) throws -> (String, String) {
    let s = try #require(markdown.range(of: start))
    let e = try #require(markdown.range(of: end, range: s.upperBound..<markdown.endIndex))
    return (String(markdown[..<s.lowerBound]), String(markdown[e.upperBound...]))
  }

  @Test(arguments: documents)
  func spliceReplacesOnlyTheTextBetweenTheMarkers(_ document: String) throws {
    let spliced = try Plans.splice(document, PlanSplice.table)

    #expect(try outside(spliced) == outside(document))
  }

  @Test(arguments: documents)
  func splicedTableReadsBackAsTheStatusBlock(_ document: String) throws {
    let spliced = try Plans.splice(document, PlanSplice.table)

    let block = Plans.parse(spliced).statusBlock

    #expect(block?.trimmingCharacters(in: .whitespacesAndNewlines) == PlanSplice.table)
  }

  /// An unchanged table must give an unchanged document, or every update
  /// writes again.
  @Test(arguments: documents)
  func splicingTheSameTableTwiceChangesNothing(_ document: String) throws {
    let once = try Plans.splice(document, PlanSplice.table)

    #expect(try Plans.splice(once, PlanSplice.table) == once)
  }

  @Test func spliceLeavesTheSecondPairAlone() throws {
    let document = "\(start)\nfirst\n\(end)\n\(start)\nsecond\n\(end)\n"

    let spliced = try Plans.splice(document, PlanSplice.table)

    #expect(spliced.contains("\(start)\nsecond\n\(end)"))
    #expect(!spliced.contains("first"))
  }

  @Test(arguments: [
    "# Plan\n\nNo markers.\n",
    "",
    "\(start)\nonly a start\n",
    "only an end\n\(end)\n",
    "\(end)\nend first\n\(start)\n",
    "\(end)\n\(start)\nthen a pair\n\(end)\n",
  ])
  func documentWithoutAnOrderedPairIsRefused(_ document: String) {
    #expect(throws: (any Error).self) { try Plans.splice(document, PlanSplice.table) }
  }
}

@Suite struct PlanTable {
  func session(_ name: String, state: AttentionState = .working, pr number: Int? = nil) -> SessionSummary {
    var s = SessionSummary(
      id: "s-\(name)", name: name, cwd: "/tmp", repo: "PostHog/posthog",
      branch: nil, claudeSessionId: "c", state: state, reason: "", since: 0, lastActivity: 0, live: true,
      claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    if let number {
      s.pr = PRSummary(
        PullRequest(id: "PR_\(number)", number: number, url: url("PostHog/posthog", number), repo: "PostHog/posthog"))
    }
    return s
  }

  func lines(_ table: String) -> [String] {
    table.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  /// The pipes that separate cells: those without a backslash before them.
  func cellPipes(_ line: String) -> Int {
    zip(" " + line, line).filter { $0.1 == "|" && $0.0 != "\\" }.count
  }

  @Test func headerNamesTheFourColumns() {
    let table = lines(Plans.table([session("alpha")]))

    #expect(table.first == "| Session | State | Wait | PR |")
  }

  @Test func secondLineIsASeparatorOfFourColumns() {
    let separator = lines(Plans.table([session("alpha")]))[1]

    #expect(separator.range(of: #"^\|( *:?-+:? *\|){4}$"#, options: .regularExpression) != nil)
  }

  @Test func noSessionsGivesTheHeaderAndSeparatorOnly() {
    #expect(lines(Plans.table([])).count == 2)
  }

  /// A name with a marker must not end the block early, or the next splice
  /// would leave the rest of the old table outside the markers.
  @Test func markerInANameStaysInsideTheBlock() throws {
    let table = Plans.table([session("a \(end) b"), session("c \(start) d")])
    let document = "# Plan\n\(start)\nold\n\(end)\nafter\n"

    let spliced = try Plans.splice(document, table)

    #expect(Plans.parse(spliced).statusBlock == Plans.block(table))
    #expect(try Plans.splice(spliced, table) == spliced)
  }

  @Test func rowsSortByName() {
    let table = lines(Plans.table([session("charlie"), session("alpha"), session("bravo")]))

    let names = table.dropFirst(2).map { row in ["alpha", "bravo", "charlie"].first { row.contains($0) } }
    #expect(names == ["alpha", "bravo", "charlie"])
  }

  @Test func inputOrderDoesNotChangeTheTable() {
    let sessions = [session("charlie", pr: 3), session("alpha", pr: 1), session("bravo")]

    #expect(Plans.table(sessions) == Plans.table(sessions.reversed()))
  }

  @Test func prCellLinksThePR() {
    let row = lines(Plans.table([session("alpha", pr: 122953)]))[2]

    #expect(row.contains(url("PostHog/posthog", 122953)))
  }

  @Test(arguments: ["a|b", "a | b", "|", "||"])
  func pipeInANameIsEscaped(_ name: String) {
    let row = lines(Plans.table([session(name)]))[2]

    #expect(cellPipes(row) == 5)
  }

  @Test(arguments: ["two\nlines", "cr\r\nlf", "trailing\n"])
  func lineBreakInANameStaysInItsRow(_ name: String) {
    let table = lines(Plans.table([session(name)]))

    #expect(table.count == 3)
    #expect(cellPipes(table[2]) == 5)
  }

  @Test func everyRowHasFourCells() {
    let table = lines(Plans.table([session("alpha", pr: 1), session("bravo", state: .needsYou)]))

    #expect(table.map(cellPipes) == [5, 5, 5, 5])
  }

  @Test func tableHoldsNoTimestamp() {
    var later = session("alpha", pr: 1)
    later.since = 9_999_999_999
    later.lastActivity = 9_999_999_999

    #expect(Plans.table([later]) == Plans.table([session("alpha", pr: 1)]))
  }
}

@Suite struct PlanRowOutOfDate {
  func row(_ prs: [PlanRow.PR]) -> PlanRow { PlanRow(text: "| 1 | x |", changed: 0, prs: prs) }

  func link(_ seen: PlanStage?, _ now: PlanStage?, number: Int = 1) -> PlanRow.PR {
    PlanRow.PR(repo: "PostHog/posthog", number: number, seen: seen, now: now)
  }

  @Test(arguments: [
    (PlanStage.open, PlanStage.merged),
    (.open, .deployed),
    (.open, .closed),
    (.merged, .deployed),
  ])
  func prThatMovedPastOpenMakesTheRowOutOfDate(_ seen: PlanStage, _ now: PlanStage) {
    #expect(row([link(seen, now)]).outOfDate)
  }

  static let current: [(PlanStage?, PlanStage?)] = [
    (.open, .open),
    (.merged, .merged),
    (.deployed, .deployed),
    (.closed, .closed),
    // A reopened PR is open again.
    (.closed, .open),
    // The poller hasn't read the PR since the row changed.
    (.open, nil),
    (nil, nil),
  ]

  @Test(arguments: current)
  func prThatStayedOrIsOpenLeavesTheRowCurrent(_ seen: PlanStage?, _ now: PlanStage?) {
    #expect(!row([link(seen, now)]).outOfDate)
  }

  @Test func oneMovedPRAmongSeveralMakesTheRowOutOfDate() {
    let prs = [link(.open, .open, number: 1), link(.open, .merged, number: 2), link(.merged, .merged, number: 3)]

    #expect(row(prs).outOfDate)
  }

  @Test func rowWithoutPRsIsCurrent() {
    #expect(!row([]).outOfDate)
  }
}
