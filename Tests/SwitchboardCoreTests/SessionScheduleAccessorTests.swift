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

private func make(_ id: String, prompt: String, runner: String) throws -> Schedule {
  let request = try JSONCoding.decode(
    ScheduleRequest.self,
    from: JSON.object(["every": .string("30m"), "prompt": .string(prompt), "runner": .string(runner)]).text)
  return try request.makeSchedule(id: id, now: now)
}

extension SessionScheduleAccessorTests {
  /// Decision 2: headless and script schedules live in `jobs`, which an older sbd ignores, and prompt schedules stay in
  /// `schedules`. Only the accessors know about the split.
  @Suite struct Jobs {
    @Test(arguments: ["headless", "script"])
    func aDetachedScheduleGoesToJobs(_ runner: String) throws {
      var s = bare()
      let job = try make("rj1", prompt: "git fetch", runner: runner)

      s.addSchedule(job)

      #expect(s.jobs == [job])
      #expect(s.schedules == nil)
    }

    @Test(arguments: [nil, "session"] as [String?])
    func aSessionScheduleGoesToSchedules(_ runner: String?) throws {
      var s = bare()
      let schedule =
        try runner.map { try make("rk3x9p", prompt: "/audit-waiting", runner: $0) }
        ?? make("rk3x9p", prompt: "/audit-waiting")

      s.addSchedule(schedule)

      #expect(s.schedules == [schedule])
      #expect(s.jobs == nil)
    }

    @Test func allSchedulesListsBothKinds() throws {
      var s = bare()
      let prompt = try make("rk3x9p", prompt: "/audit-waiting")
      let headless = try make("rj1", prompt: "summarize the open PRs", runner: "headless")
      let script = try make("rj2", prompt: "git fetch", runner: "script")

      s.addSchedule(prompt)
      s.addSchedule(headless)
      s.addSchedule(script)

      #expect(Set(s.allSchedules.map(\.id)) == ["rk3x9p", "rj1", "rj2"])
      #expect(s.allSchedules.count == 3)
    }

    @Test func aJobIsFoundByItsId() throws {
      var s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])
      let job = try make("rj1", prompt: "git fetch", runner: "script")
      s.addSchedule(job)

      #expect(s.schedule("rj1") == job)
    }

    @Test func changingAJobChangesItInJobs() throws {
      var s = bare()
      s.addSchedule(try make("rj1", prompt: "git fetch", runner: "script"))

      s.changeSchedule("rj1") { $0.paused = true }

      #expect(s.jobs?.first?.paused == true)
      #expect(s.schedule("rj1")?.paused == true)
    }

    @Test func changingAJobLeavesThePromptSchedules() throws {
      let prompt = try make("rk3x9p", prompt: "/audit-waiting")
      var s = withSchedules([prompt])
      s.addSchedule(try make("rj1", prompt: "git fetch", runner: "script"))

      s.changeSchedule("rj1") { $0.running = now }

      #expect(s.schedules == [prompt])
    }

    @Test func changingAPromptScheduleLeavesTheJobs() throws {
      var s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])
      let job = try make("rj1", prompt: "git fetch", runner: "script")
      s.addSchedule(job)

      s.changeSchedule("rk3x9p") { $0.paused = true }

      #expect(s.jobs == [job])
    }

    @Test func aMissingIdLeavesNoJobsAsNil() throws {
      var s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])

      s.changeSchedule("rj1") { $0.paused = true }

      #expect(s.jobs == nil)
    }

    @Test func removingTheLastJobSetsJobsToNilAndKeepsSchedules() throws {
      let prompt = try make("rk3x9p", prompt: "/audit-waiting")
      var s = withSchedules([prompt])
      s.addSchedule(try make("rj1", prompt: "git fetch", runner: "script"))

      s.removeSchedule("rj1")

      #expect(s.jobs == nil)
      #expect(s.schedules == [prompt])
    }

    @Test func removingTheLastPromptScheduleKeepsTheJobs() throws {
      var s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])
      let job = try make("rj1", prompt: "git fetch", runner: "script")
      s.addSchedule(job)

      s.removeSchedule("rk3x9p")

      #expect(s.schedules == nil)
      #expect(s.jobs == [job])
    }

    @Test func removingOneOfTwoJobsKeepsTheOther() throws {
      var s = bare()
      let first = try make("rj1", prompt: "git fetch", runner: "script")
      let second = try make("rj2", prompt: "summarize", runner: "headless")
      s.addSchedule(first)
      s.addSchedule(second)

      s.removeSchedule("rj1")

      #expect(s.jobs == [second])
    }

    @Test func addingThenRemovingAJobRestoresTheSession() throws {
      let before = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])
      var s = before
      s.addSchedule(try make("rj1", prompt: "git fetch", runner: "script"))

      s.removeSchedule("rj1")

      #expect(s == before)
    }

    /// A change can't move a schedule between the arrays, so a job never lands in `schedules`, where an older sbd would
    /// send its command into the session.
    @Test func aChangeKeepsTheRunner() throws {
      var s = bare()
      s.addSchedule(try make("rj1", prompt: "git fetch", runner: "script"))
      s.addSchedule(try make("rk3x9p", prompt: "/audit-waiting"))

      s.changeSchedule("rj1") { $0.runner = nil }
      s.changeSchedule("rk3x9p") { $0.runner = .script }

      #expect(s.jobs?.map(\.runner) == [.script])
      #expect(s.schedules?.map(\.runner) == [nil])
    }

    @Test func aSessionRowWithJobsRoundTrips() throws {
      var s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])
      s.addSchedule(try make("rj1", prompt: "git fetch", runner: "script"))
      s.addSchedule(try make("rj2", prompt: "summarize", runner: "headless"))

      #expect(try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s)) == s)
    }

    @Test func aSessionWithoutJobsEncodesNoJobsKey() throws {
      let s = withSchedules([try make("rk3x9p", prompt: "/audit-waiting")])

      let object = try #require(JSON.parse(try JSONCoding.encode(s))?.object)

      #expect(object["jobs"] == nil)
    }
  }
}
