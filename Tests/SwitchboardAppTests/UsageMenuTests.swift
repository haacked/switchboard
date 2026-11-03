import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct UsageMenuText {
  let limits = [
    UsageLimit(kind: "session", label: "Session (5h)", percent: 52.4, resetsAt: 7_200_000 + 300_000),
    UsageLimit(kind: "weekly_all", label: "Week (all models)", percent: 21),
    UsageLimit(kind: "weekly_scoped", label: "Week (Fable)", percent: 63.6),
  ]

  @Test func theLabelShowsTheSessionAndTheHighestWeeklyPercent() {
    let reading = AccountUsage(name: "a", folder: "/a", limits: limits)
    #expect(UsageMenu.label(reading) == "5h 52% · wk 64%")
  }

  @Test func theLabelSaysUsageWithoutAReading() {
    #expect(UsageMenu.label(nil) == "Usage")
    #expect(UsageMenu.label(AccountUsage(name: "a", folder: "/a", error: "not signed in")) == "Usage")
  }

  @Test func aRowNamesTheResetTimeWhenThereIsOne() {
    #expect(UsageMenu.row(limits[0], now: 0) == "Session (5h): 52% · resets in 2h 5m")
    #expect(UsageMenu.row(limits[1], now: 0) == "Week (all models): 21%")
  }
}
