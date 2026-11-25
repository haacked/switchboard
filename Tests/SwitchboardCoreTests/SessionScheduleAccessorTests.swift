import Foundation
import Testing

@testable import SwitchboardCore

private let now: Int64 = 1_800_000_000_000

private func make(_ id: String, prompt: String, every: String = "30m") throws -> Schedule {
  try ScheduleRequest(every: every, prompt: prompt, by: nil).makeSchedule(id: id, now: now)
}

private func bare() -> Session {
  Session(id: "s1", name: "manager", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)
}

private func withSchedules(_ schedules: [Schedule]) -> Session {
  var s = bare()
  s.schedules = schedules
  return s
}

@Suite struct SessionScheduleAccessorTests {
  @Suite struct AllSchedules {
    @Test func isEmptyWhenTheSessionHasNoSchedules() {
      #expect(bare().allSchedules.isEmpty)
    }

    @Test func listsTheStoredSchedulesInTheirOrder() throws {
      let first = try make("rk3x9p", prompt: "/audit-waiting")
      let second = try make("r2mzq4", prompt: "check the queue")

      let s = withSchedules([first, second])

      #expect(s.allSchedules == [first, second])
    }
  }

  @Suite struct Lookup {
    @Test func findsAStoredScheduleByItsId() throws {
      let first = try make("rk3x9p", prompt: "/audit-waiting")
      let second = try make("r2mzq4", prompt: "check the queue")

      let s = withSchedules([first, second])

      #expect(s.schedule("r2mzq4") == second)
    }

    @Test func returnsNilForAMissingIdWhenTheSessionHasNoSchedules() {
      #expect(bare().schedule("rk3x9p") == nil)
    }

    @Test func returnsNilForAMissingIdWhenOtherSchedulesExist() throws {
      let s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])

      #expect(s.schedule("r2mzq4") == nil)
    }
  }

  @Suite struct Add {
    @Test func addingToASessionWithNoSchedulesStoresOnlyThatSchedule() throws {
      var s = bare()
      let schedule = try make("rk3x9p", prompt: "/audit-waiting")

      s.addSchedule(schedule)

      #expect(s.schedules == [schedule])
    }

    @Test func addingAppendsAfterTheExistingSchedules() throws {
      let first = try make("rk3x9p", prompt: "/audit-waiting")
      let second = try make("r2mzq4", prompt: "check the queue")
      var s = withSchedules([first])

      s.addSchedule(second)

      #expect(s.schedules == [first, second])
    }

    @Test func anAddedScheduleIsFoundByItsId() throws {
      var s = bare()
      let schedule = try make("rk3x9p", prompt: "/audit-waiting")

      s.addSchedule(schedule)

      #expect(s.schedule("rk3x9p") == schedule)
    }
  }

  @Suite struct Change {
    @Test func changesTheNamedSchedule() throws {
      var s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])

      s.changeSchedule("rk3x9p") { $0.paused = true }

      #expect(s.schedule("rk3x9p")?.paused == true)
    }

    @Test func leavesTheOtherSchedulesAsTheyWere() throws {
      let first = try make("rk3x9p", prompt: "/audit-waiting")
      let second = try make("r2mzq4", prompt: "check the queue")
      var s = withSchedules([first, second])

      s.changeSchedule("rk3x9p") { $0.prompt = "/audit-everything" }

      #expect(s.schedule("r2mzq4") == second)
    }

    @Test func keepsTheOrderOfTheSchedules() throws {
      let first = try make("rk3x9p", prompt: "/audit-waiting")
      let second = try make("r2mzq4", prompt: "check the queue")
      var s = withSchedules([first, second])

      s.changeSchedule("rk3x9p") { $0.next = now + 1 }

      #expect(s.allSchedules.map(\.id) == ["rk3x9p", "r2mzq4"])
    }

    @Test func aMissingIdLeavesTheSessionUnchanged() throws {
      let before = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])
      var s = before

      s.changeSchedule("r2mzq4") { $0.paused = true }

      #expect(s == before)
    }

    @Test func aMissingIdLeavesNoSchedulesAsNil() {
      var s = bare()

      s.changeSchedule("rk3x9p") { $0.paused = true }

      #expect(s.schedules == nil)
    }
  }

  @Suite struct Remove {
    @Test func removingTheLastScheduleSetsSchedulesToNil() throws {
      var s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])

      s.removeSchedule("rk3x9p")

      #expect(s.schedules == nil)
    }

    @Test func addingThenRemovingAScheduleRestoresTheSession() throws {
      let before = bare()
      var s = before
      s.addSchedule(try make("rk3x9p", prompt: "/audit-waiting"))

      s.removeSchedule("rk3x9p")

      #expect(s == before)
    }

    @Test func removingOneOfTwoKeepsTheOther() throws {
      let first = try make("rk3x9p", prompt: "/audit-waiting")
      let second = try make("r2mzq4", prompt: "check the queue")
      var s = withSchedules([first, second])

      s.removeSchedule("rk3x9p")

      #expect(s.schedules == [second])
    }

    @Test func aRemovedScheduleIsNoLongerFound() throws {
      var s = withSchedules([
        try make("rk3x9p", prompt: "/audit-waiting"), try make("r2mzq4", prompt: "check the queue"),
      ])

      s.removeSchedule("rk3x9p")

      #expect(s.schedule("rk3x9p") == nil)
    }

    @Test func aMissingIdLeavesTheSessionUnchanged() throws {
      let before = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])
      var s = before

      s.removeSchedule("r2mzq4")

      #expect(s == before)
    }

    @Test func aMissingIdLeavesNoSchedulesAsNil() {
      var s = bare()

      s.removeSchedule("rk3x9p")

      #expect(s.schedules == nil)
    }
  }
}
