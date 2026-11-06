import Foundation
import Testing

@testable import SwitchboardCore

/// A plan with one "status as of" line and a table whose rows the rewrite does not name.
private func plan(_ dateLine: String) -> String {
  "# Plan\n\n\(dateLine)\n\n| # | Item | Status |\n| --- | --- | --- |\n| 1 | Docs | Not started |\n"
}

private func rewrite(_ old: String, _ new: String) throws {
  try Plans.checkRewrite(base: plan(old), text: plan(new), rows: [])
}

/// The rewrites of a "status as of" line that `checkRewrite` accepts and refuses.
@Suite struct StatusDateRewrite {
  static let accepted: [(String, String)] = [
    ("Status as of 2026-11-01.", "Status as of 2026-11-05."),
    ("Status as of November 1, 2026.", "Status as of November 5, 2026."),
    ("Status as of Nov 1, 2026.", "Status as of Nov 5, 2026."),
    ("Status as of Nov. 1, 2026.", "Status as of Nov. 5, 2026."),
    ("Status as of 1 November 2026.", "Status as of 5 November 2026."),
    ("Status as of 1 Nov 2026.", "Status as of 5 Nov 2026."),
    ("Status as of 1 Nov. 2026.", "Status as of 5 Nov. 2026."),
    ("Status as of 1 October 2026.", "Status as of 5 November 2026."),
    ("Status as of 1 Oct 2026.", "Status as of 5 Nov 2026."),
    ("Status as of 1 Oct. 2026.", "Status as of 5 Nov. 2026."),
    ("Status as of Sept 1, 2026.", "Status as of Sept 5, 2026."),
    ("**STATUS AS OF** 2026-11-01", "**STATUS AS OF** 2026-11-05"),
    ("Status as of: 2026-11-01", "Status as of: 2026-11-05"),
    ("_status as of Nov 1, 2026_", "_status as of Nov 5, 2026_"),
    // "May" is a full month name and a short one, so either shape may follow it.
    ("Status as of May 1, 2026.", "Status as of Nov 5, 2026."),
    ("Status as of May 1, 2026.", "Status as of November 5, 2026."),
    // The status date is the earliest date on the line, whatever its shape.
    ("Status as of 1 Nov 2026, kickoff 2026-10-01.", "Status as of 5 Nov 2026, kickoff 2026-10-01."),
  ]

  @Test(arguments: accepted)
  func dateInAKnownShapeMayChange(_ old: String, _ new: String) throws {
    try rewrite(old, new)
  }

  static let refused: [(String, String)] = [
    // A date in no known shape.
    ("Status as of 11/01/2026.", "Status as of 11/05/2026."),
    ("Status as of 01.11.2026.", "Status as of 05.11.2026."),
    ("Status as of 2026/11/01.", "Status as of 2026/11/05."),
    ("Status as of 2026-11-1.", "Status as of 2026-11-5."),
    ("Status as of 3 merged.", "Status as of 4 merged."),
    // The text after the date changes.
    ("Status as of 2026-11-01 3 PRs open.", "Status as of 2026-11-05 7 PRs open."),
    ("Status as of 2026-11-01 14:30.", "Status as of 2026-11-05 09:15."),
    ("Status as of 2026-11-01; status as of 2026-10-01.", "Status as of 2026-11-05; status as of 2026-11-05."),
    ("Status as of 2026-11-01. Done.", "Status as of 2026-11-05. Publish now."),
    ("Status as of 1 Nov 2026, kickoff 2026-10-01.", "Status as of 1 Nov 2026, kickoff 2026-10-05."),
    // Other text sits between the phrase and the date, so the date may not be the status date.
    ("Status as of this week, launch is 2026-12-01.", "Status as of this week, launch is 2027-03-01."),
    ("Server status as offline since 2026-11-01.", "Server status as offline since 2026-01-01."),
    // The text before the date changes.
    ("Status as of 2026-11-01.", "Note: status as of 2026-11-05."),
    ("Status as of 2026-11-01.", "Status as of  2026-11-05."),
    // The date takes another shape. The chat was asked to keep the line's format.
    ("Status as of 2026-11-01.", "Status as of 11/05/2026."),
    ("Status as of 2026-11-01.", "Status as of 2026-11-5."),
    ("Status as of 2026-11-01.", "Status as of Nov 5, 2026."),
    ("Status as of Nov 1, 2026.", "Status as of 2026-11-05."),
    ("Status as of Nov 1, 2026.", "Status as of November 5, 2026."),
    // A date goes away or appears.
    ("Status as of 2026-11-01.", "Status as of ."),
    ("Status as of .", "Status as of 2026-11-05."),
  ]

  @Test(arguments: refused)
  func rewriteThatChangesMoreThanTheDateIsRefused(_ old: String, _ new: String) {
    #expect(throws: (any Error).self) { try rewrite(old, new) }
  }

  /// A rewrite that `PlanUpdates.dated` would make is one `checkRewrite` accepts.
  @Test(
    arguments: PlanUpdateEdits.dateLines.map(\.0) + ["Status as of Sept 1, 2026.", "Status as of May 1, 2026."])
  func planUpdateDateIsAnAcceptedRewrite(_ line: String) throws {
    let today = try #require(ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z"))
    let new = try #require(PlanUpdates.dated(line, today: today, timeZone: TimeZone(identifier: "UTC")!))
    #expect(new != line)

    try rewrite(line, new)
  }

  /// "May" matches the full month shape first, so plan updates write the full month name.
  @Test func mayDateTakesTheFullMonthName() throws {
    let today = try #require(ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z"))

    #expect(
      PlanUpdates.dated("Status as of May 1, 2026.", today: today, timeZone: TimeZone(identifier: "UTC")!)
        == "Status as of November 5, 2026.")
  }

  @Test(arguments: [
    "Status as of this week, launch is 2026-12-01.", "Server status as offline since 2026-11-01.",
  ])
  func dateAfterOtherTextIsNotDated(_ line: String) throws {
    let today = try #require(ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z"))

    #expect(PlanUpdates.dated(line, today: today, timeZone: TimeZone(identifier: "UTC")!) == nil)
  }
}
