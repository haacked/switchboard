import Testing

@testable import SwitchboardCore

private let now: Int64 = 1_800_000_000_000
private let second: Int64 = 1000
private let minute: Int64 = 60 * second
private let hour: Int64 = 60 * minute
private let day: Int64 = 24 * hour

@Suite struct AgoTests {
  @Test(arguments: [
    (Int64(0), "0s"),
    (59 * second, "59s"),
    (60 * second, "1m"),
    (3599 * second, "59m"),
    (3600 * second, "1h"),
    (86399 * second, "23h"),
    (86400 * second, "1d"),
    (10 * day, "10d"),
  ])
  func bandBoundaries(_ elapsed: Int64, _ text: String) {
    #expect(ago(now - elapsed, now: now) == text)
  }

  @Test func partialSecondsRoundDown() {
    #expect(ago(now - 59_999, now: now) == "59s")
  }

  @Test(arguments: [Int64(1), second, day])
  func futureTimestampClampsToZeroSeconds(_ ahead: Int64) {
    #expect(ago(now + ahead, now: now) == "0s")
  }

  @Test func defaultNowReadsTheClock() {
    #expect(ago(nowMs() - 2 * hour - 30 * minute) == "2h")
  }
}
