import Testing

@testable import SwitchboardCore

@Suite struct TurnProbeTests {
  private func check(_ p: inout TurnProbe, activity: Int64, now: Int64) -> Bool {
    p.check(activity: activity, now: now)
  }

  @Test func waitsTenSecondsAfterTheLastEvent() {
    var p = TurnProbe()
    #expect(!check(&p, activity: 1000, now: 10_999))
    #expect(check(&p, activity: 1000, now: 11_000))
  }

  @Test func backsOffBetweenChecksUpToAMinute() {
    var p = TurnProbe()
    var now: Int64 = 10_000
    var gaps: [Int64] = []
    var last: Int64 = 0
    while gaps.count < 6 {
      if check(&p, activity: 0, now: now) {
        gaps.append(now - last)
        last = now
      }
      now += 1000
    }
    #expect(gaps == [10_000, 20_000, 40_000, 60_000, 60_000, 60_000])
  }

  @Test func aNewEventStartsTheWaitAgain() {
    var p = TurnProbe()
    #expect(check(&p, activity: 0, now: 10_000))
    #expect(check(&p, activity: 0, now: 30_000))
    #expect(!check(&p, activity: 25_000, now: 34_999))
    #expect(check(&p, activity: 25_000, now: 35_000))
    // The back-off restarted: the next check is 20 s later, not 40 s.
    #expect(!check(&p, activity: 25_000, now: 54_999))
    #expect(check(&p, activity: 25_000, now: 55_000))
  }
}
