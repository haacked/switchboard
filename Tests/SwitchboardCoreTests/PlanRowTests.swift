import Foundation
import Testing

@testable import SwitchboardCore

private let start = "<!-- sb:status -->"
private let end = "<!-- /sb:status -->"

private func url(_ repo: String, _ number: Int) -> String { "https://github.com/\(repo)/pull/\(number)" }

private func setFields(_ r: inout PlanRow, number: String?, item: String?, status: String?) {
  r.number = number
  r.item = item
  r.status = status
}

private let breakerRow = "| 1 | Breaker counts | In review ([posthog#122953](\(url("PostHog/posthog", 122953)))) |"
private let docsRow = "| 2 | Docs | Not started |"
private let runbookRow = "| 3 | Runbook | In progress |"

/// The flag evaluations RFC's work table: a row with a PR link, a Not
/// started row, and an In progress row.
private let workTable = """
  # Flag evaluations

  | # | Item | Status |
  | --- | --- | --- |
  \(breakerRow)
  \(docsRow)
  \(runbookRow)
  """

private func rows(_ markdown: String) -> [Plans.Content.Row] { Plans.parse(markdown).rows }

/// A one-row work table under `header`.
private func table(_ header: String, _ row: String) -> String {
  let columns = header.split(separator: "|", omittingEmptySubsequences: true).count
  let separator = "|" + String(repeating: " --- |", count: columns)
  return "\(header)\n\(separator)\n\(row)\n"
}

@Suite struct PlanRowHeaders {
  @Test func notStartedRowWithoutALinkIsARow() {
    #expect(rows(workTable).map(\.text) == [breakerRow, docsRow])
  }

  @Test func notStartedRowHasItsNumberItemAndStatus() throws {
    let docs = try #require(rows(workTable).first { $0.text == docsRow })

    #expect(docs.number == "2")
    #expect(docs.item == "Docs")
    #expect(docs.status == "Not started")
  }

  @Test func notStartedRowHasNoLinks() throws {
    let docs = try #require(rows(workTable).first { $0.text == docsRow })

    #expect(docs.links.isEmpty)
  }

  /// Each way a header can name the columns: the names compare without case
  /// and trimmed, and the columns can sit anywhere among others.
  static let headers: [(String, String)] = [
    ("| # | Item | Status |", "| 2 | Docs | Not started |"),
    ("|#|item|status|", "|2|Docs|Not started|"),
    ("|  #  |  ITEM  |  STATUS  |", "|  2  |  Docs  |  Not started  |"),
    ("| # | Owner | Item | Notes | Status |", "| 2 | Ana | Docs | Ask first | Not started |"),
    ("| Status | Item | # |", "| Not started | Docs | 2 |"),
  ]

  @Test(arguments: headers)
  func headerInEachFormGivesTheRowItsFields(_ header: String, _ row: String) throws {
    let parsed = try #require(rows(table(header, row)).first)

    #expect(parsed.text == row)
    #expect(parsed.number == "2")
    #expect(parsed.item == "Docs")
    #expect(parsed.status == "Not started")
  }

  @Test func tableWithoutANumberColumnGivesRowsWithoutANumber() throws {
    let parsed = try #require(rows(table("| Item | Status |", "| Docs | Not started |")).first)

    #expect(parsed.number == nil)
    #expect(parsed.item == "Docs")
  }

  /// Each header that lacks an `Item` column or a `Status` column.
  static let headersWithoutItemAndStatus: [(String, String)] = [
    ("| # | Task | State |", "| 2 | Docs | Not started |"),
    ("| # | Item | State |", "| 2 | Docs | Not started |"),
    ("| # | Task | Status |", "| 2 | Docs | Not started |"),
    ("| Status |", "| Not started |"),
    ("| Items | Statuses |", "| Docs | Not started |"),
    ("| Work item | Status |", "| Docs | Not started |"),
  ]

  @Test(arguments: headersWithoutItemAndStatus)
  func tableWithoutItemAndStatusGivesNoRowWithoutALink(_ header: String, _ row: String) {
    #expect(rows(table(header, row)).isEmpty)
  }

  @Test func rowsWithoutASeparatorAboveThemHaveNoHeader() {
    let markdown = "| # | Item | Status |\n| 2 | Docs | Not started |\n"

    #expect(rows(markdown).isEmpty)
  }

  /// A second table's header is its own. The first table's `Item` and
  /// `Status` columns don't carry over to it.
  @Test(arguments: ["\n\nBetween the tables.\n\n", "\n\n", "\n"])
  func headerOfOneTableDoesNotCarryToTheNext(_ between: String) {
    let markdown =
      "| # | Item | Status |\n| --- | --- | --- |\n\(docsRow)"
      + between
      + "| A | B | C |\n| --- | --- | --- |\n| 4 | Dashboards | Not started |\n"

    #expect(rows(markdown).map(\.text) == [docsRow])
  }

  @Test func notStartedRowInTheGeneratedBlockIsLeftOut() {
    let markdown = "\(start)\n| # | Item | Status |\n| --- | --- | --- |\n| 9 | Generated | Not started |\n\(end)\n"

    #expect(rows(markdown).isEmpty)
  }

  @Test func rowWithoutAStatusCellIsNoRow() {
    #expect(rows(table("| # | Item | Status |", "| 2 | Docs |")).isEmpty)
  }

  @Test func repeatedHeaderLineBelowItsSeparatorIsNoRow() {
    let markdown = "| # | Item | Status |\n| --- | --- | --- |\n| # | Item | Status |\n\(docsRow)\n"

    #expect(rows(markdown).map(\.text) == [docsRow])
  }
}

@Suite struct PlanRowCells {
  @Test func escapedPipeReadsAsAPipeInTheItem() throws {
    let row = #"| 3 | Split the a\|b parser | Not started |"#

    let parsed = try #require(rows(table("| # | Item | Status |", row)).first)

    #expect(parsed.item == "Split the a|b parser")
    #expect(parsed.status == "Not started")
  }

  /// Split on every pipe, this row's third cell would read Not started.
  @Test func escapedPipeDoesNotShiftTheStatusColumn() {
    let row = #"| 3 | Runbook \| Not started | In progress |"#

    #expect(rows(table("| # | Item | Status |", row)).isEmpty)
  }

  @Test func escapedPipeInTheHeaderDoesNotShiftItsColumns() throws {
    let markdown = #"""
      | # | Owner \| team | Item | Status |
      | --- | --- | --- | --- |
      | 2 | Ana | Docs | Not started |
      """#

    let parsed = try #require(rows(markdown).first)

    #expect(parsed.item == "Docs")
  }

  @Test func escapedPipeInTheNumberCell() throws {
    let parsed = try #require(rows(table("| # | Item | Status |", #"| 2\|b | Docs | Not started |"#)).first)

    #expect(parsed.number == "2|b")
  }

  @Test func cellsAreTrimmed() throws {
    let parsed = try #require(
      rows(table("| # | Item | Status |", "|   7   |   Write the runbook   | Not started |")).first)

    #expect(parsed.number == "7")
    #expect(parsed.item == "Write the runbook")
  }
}

@Suite struct PlanRowStatusForms {
  static let notStartedForms = [
    "Not started", "**Not started**", "not started.", "NOT STARTED", "_Not started_", "`Not started`",
    "(Not started)", "~~Not started~~", "Not started!",
  ]

  static let otherForms = [
    "Not started yet", "In progress", "", "Started", "Not yet started", "Done", "Not started, blocked",
    "Was not started",
  ]

  func row(_ status: String) -> String { "| 2 | Docs | \(status) |" }

  func document(_ status: String) -> String { table("| # | Item | Status |", row(status)) }

  @Test(arguments: notStartedForms)
  func notStartedStatusInEachFormMakesARow(_ status: String) {
    #expect(rows(document(status)).map(\.text) == [row(status)])
  }

  @Test(arguments: otherForms)
  func otherStatusWithoutALinkMakesNoRow(_ status: String) {
    #expect(rows(document(status)).isEmpty)
  }

  /// The parser's choice of rows and `PlanRow.notStarted` read the status
  /// the same way: every row a read keeps without a PR is Not started.
  @Test(arguments: notStartedForms + otherForms)
  func readRowsWithoutAPRAreExactlyTheNotStartedOnes(_ status: String) {
    var plan = PlanDocument(id: "p1", source: PlanSource(kind: .file, path: "/tmp/plan.md"), group: "g", attached: 0)

    plan.update(from: document(status), now: 1)

    #expect(plan.rows.count == (PlanRowStatusForms.notStartedForms.contains(status) ? 1 : 0))
    #expect(plan.rows.allSatisfy { $0.notStarted })
  }
}

@Suite struct PlanRowLinkedRows {
  /// `PlanRowParsing.table`'s rows with PR links, and how they parse.
  static let markdown = """
    Tracking in \(url("PostHog/posthog", 9)).

    | # | Item | Status |
    | --- | --- | --- |
    \(breakerRow)
    | 3 | Runbook | Done ([charts#18303](\(url("PostHog/charts", 18303))), [posthog#122896](\(url("PostHog/posthog", 122896)))) |

    | A | B |
    | --- | --- |
    | 1 | \(url("PostHog/posthog", 1)) |
    """

  @Test func rowsThatLinkPRsKeepTheirTextAndLinks() {
    let parsed = rows(PlanRowLinkedRows.markdown)

    #expect(parsed.map(\.text).count == 3)
    #expect(
      parsed.map(\.links) == [
        [PlanLink(repo: "PostHog/posthog", number: 122953)],
        [PlanLink(repo: "PostHog/charts", number: 18303), PlanLink(repo: "PostHog/posthog", number: 122896)],
        [PlanLink(repo: "PostHog/posthog", number: 1)],
      ])
  }

  @Test func linkedRowOfAWorkTableGetsItsFields() throws {
    let breaker = try #require(rows(PlanRowLinkedRows.markdown).first)

    #expect(breaker.number == "1")
    #expect(breaker.item == "Breaker counts")
    #expect(breaker.status == "In review ([posthog#122953](\(url("PostHog/posthog", 122953))))")
  }

  @Test func linkedRowOfATableWithoutItemAndStatusHasNoItem() throws {
    let last = try #require(rows(PlanRowLinkedRows.markdown).last)

    #expect(last.item == nil)
    #expect(last.status == nil)
  }

  @Test func linkedRowThatSaysNotStartedIsNotStartedWork() throws {
    let row = "| 4 | Dedup | Not started (\(url("PostHog/posthog", 4))) |"
    var plan = PlanDocument(id: "p1", source: PlanSource(kind: .file, path: "/tmp/plan.md"), group: "g", attached: 0)

    plan.update(from: table("| # | Item | Status |", row), now: 1)

    let parsed = try #require(plan.rows.first)
    #expect(parsed.prs.map(\.number) == [4])
    #expect(!parsed.notStarted)
  }

  /// GitHub sends an issue body edited on the web with CRLF line ends.
  @Test func crlfDocumentGivesTheSameFieldsAsItsLFCopy() {
    let lf = rows(workTable)
    let crlf = rows(workTable.replacingOccurrences(of: "\n", with: "\r\n"))

    #expect(crlf.map(\.text) == lf.map(\.text))
    #expect(crlf.map(\.number) == lf.map(\.number))
    #expect(crlf.map(\.item) == lf.map(\.item))
    #expect(crlf.map(\.status) == lf.map(\.status))
  }
}

@Suite struct PlanRowReads {
  func plan() -> PlanDocument {
    PlanDocument(id: "p1", source: PlanSource(kind: .file, path: "/tmp/plan.md"), group: "g", attached: 0)
  }

  @Test func readGivesEachRowTheParsersFields() {
    var plan = plan()

    plan.update(from: workTable, now: 1)

    let parsed = rows(workTable)
    #expect(plan.rows.map(\.text) == parsed.map(\.text))
    #expect(plan.rows.map(\.number) == parsed.map(\.number))
    #expect(plan.rows.map(\.item) == parsed.map(\.item))
    #expect(plan.rows.map(\.status) == parsed.map(\.status))
  }

  /// A row stored by an older sbd lacks the fields. A read whose text for
  /// the row is unchanged still sets them, and keeps when the row changed.
  @Test func readSetsTheFieldsOnARowWhoseTextIsUnchanged() throws {
    var plan = plan()
    plan.update(from: workTable, now: 1)
    for i in plan.rows.indices { setFields(&plan.rows[i], number: nil, item: nil, status: nil) }

    plan.update(from: workTable, now: 2)

    let docs = try #require(plan.rows.first { $0.text == docsRow })
    #expect(docs.number == "2")
    #expect(docs.item == "Docs")
    #expect(docs.status == "Not started")
    #expect(docs.changed == 1)
  }

  @Test func rowStoredByAnOlderSbdDecodesWithoutTheFields() throws {
    let row = try JSONCoding.decode(PlanRow.self, from: #"{"text":"| 2 | Docs | Not started |","changed":1,"prs":[]}"#)

    #expect(row.item == nil)
    #expect(row.followup == nil)
    #expect(!row.notStarted)
  }

  @Test func followupStoredByAnOlderSbdDecodesWithoutAPlanRow() throws {
    let f = try JSONCoding.decode(Followup.self, from: #"{"prompt":"Docs","trigger":{"kind":"manual"}}"#)

    #expect(!(f.planRow != nil))
  }

  @Test func readLeavesTheFollowupNil() {
    var plan = plan()

    plan.update(from: workTable, now: 1)

    #expect(plan.rows.allSatisfy { $0.followup == nil })
  }
}

@Suite struct PlanRowFollowUp {
  static let cases: [(Int, String?, String?, Bool)] = [
    (0, "Docs", "Not started", true),
    (0, "Docs", "**Not started**", true),
    (1, "Docs", "Not started", false),
    (0, "", "Not started", false),
    (0, nil, "Not started", false),
    (0, "Docs", "In progress", false),
    (0, "Docs", "Not started yet", false),
    (0, "Docs", nil, false),
  ]

  @Test(arguments: cases)
  func notStartedNeedsNoPRAnItemAndANotStartedStatus(_ prs: Int, _ item: String?, _ status: String?, _ expected: Bool) {
    var row = PlanRow(
      text: "| 2 | Docs | x |", changed: 0, prs: (0..<prs).map { PlanRow.PR(repo: "PostHog/posthog", number: $0 + 1) })
    setFields(&row, number: "2", item: item, status: status)

    #expect(row.notStarted == expected)
  }

  static let twoNotStarted = workTable + "\n| 4 | Dashboards | Not started |\n"

  func plan() -> PlanDocument {
    var plan = PlanDocument(id: "p1", source: PlanSource(kind: .file, path: "/tmp/plan.md"), group: "g", attached: 0)
    plan.update(from: PlanRowFollowUp.twoNotStarted, now: 1)
    return plan
  }

  @Test func canFollowUpListsTheNotStartedRows() {
    #expect(PlanSummary(plan()).canFollowUp.map(\.text) == [docsRow, "| 4 | Dashboards | Not started |"])
  }

  @Test func canFollowUpLeavesOutARowWithAFollowup() throws {
    var plan = plan()
    let i = try #require(plan.rows.firstIndex { $0.text == docsRow })
    plan.rows[i].followup = "s1"

    #expect(PlanSummary(plan).canFollowUp.map(\.text) == ["| 4 | Dashboards | Not started |"])
  }

  @Test func canFollowUpLeavesOutARowWithAPR() {
    #expect(!PlanSummary(plan()).canFollowUp.contains { $0.text == breakerRow })
  }

  @Test func planWithoutNotStartedRowsCanFollowUpNone() {
    var plan = plan()
    plan.update(from: "| # | Item | Status |\n| --- | --- | --- |\n\(breakerRow)\n\(runbookRow)\n", now: 2)

    #expect(PlanSummary(plan).canFollowUp.isEmpty)
  }

  @Test func rowsCountIncludesTheNotStartedRows() {
    #expect(PlanSummary(plan()).rows == 3)
  }
}
