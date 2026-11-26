import Foundation
import SwitchboardCore
import Testing

/// Every interval and clock move here stays under 30 minutes past a schedule's
/// creation, so no schedule comes due once sbd fires them.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScheduleTests {
  static let thirtyMinutes: Int64 = 1_800_000

  func row(_ text: String) throws -> ScheduleRow { try JSONCoding.decode(ScheduleRow.self, from: text) }

  func rows(_ text: String) throws -> [ScheduleRow] { try JSONCoding.decode([ScheduleRow].self, from: text) }

  /// Adds a schedule through `sb schedule <session> --every <every> <prompt> --json`.
  func schedule(
    _ sbd: Instance, _ session: String, every: String = "30m", _ prompt: String = "check the queue",
    env: [String: String] = [:]
  ) throws -> ScheduleRow {
    try row(sbd.sb(["schedule", session, "--every", every, prompt, "--json"], env: env))
  }

  /// `sb schedule ls [<session>] --json`.
  func list(_ sbd: Instance, _ session: String? = nil) throws -> [ScheduleRow] {
    try rows(sbd.sb(["schedule", "ls"] + (session.map { [$0] } ?? []) + ["--json"]))
  }

  func ids(_ rows: [ScheduleRow]) -> [String] { rows.map(\.schedule.id) }

  // MARK: Adding

  @Test func addingReturnsARowWithTheIntervalTheNextRunAndTheAuthor() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "manager")
    let before = try sbd.now()

    let r = try row(sbd.sb("schedule", s.id, "--every", "30m", "check the queue", "--json"))

    let after = try sbd.now()
    #expect(r.session == s.id)
    #expect(r.name == "manager")
    #expect(r.schedule.id.hasPrefix("r"))
    #expect(r.schedule.prompt == "check the queue")
    #expect(r.schedule.every == ScheduleTests.thirtyMinutes)
    #expect((before + ScheduleTests.thirtyMinutes...after + ScheduleTests.thirtyMinutes).contains(r.schedule.next))
    #expect((before...after).contains(r.schedule.created))
    #expect(r.schedule.by == .you)
    #expect(r.schedule.paused == nil)
    #expect(r.schedule.last == nil)
  }

  /// The Manager guide schedules loops on the operator by name before any wait has created it.
  @Test func schedulingTheOperatorByNameCreatesIt() throws {
    let sbd = try Instance()

    let r = try schedule(sbd, Manager.operatorName)

    let op = try #require(try sbd.client.call("ls", as: [SessionSummary].self).first { $0.kind == .operator })
    #expect(r.session == op.id)
    #expect(try sbd.get(op.id).schedules == [r.schedule])
  }

  @Test func getLsAndScheduleLsShowTheSameSchedule() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let got = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("get", s.id, "--json"))
    let listed = try JSONCoding.decode([SessionSummary].self, from: sbd.sb("ls", "--json"))

    #expect(got.schedules == [r.schedule])
    #expect(listed.first { $0.id == s.id }?.schedules == [r.schedule])
    #expect(try list(sbd).map(\.schedule) == [r.schedule])
    #expect(try list(sbd, s.id).map(\.schedule) == [r.schedule])
    #expect(try list(sbd).map(\.session) == [s.id])
  }

  @Test func aSessionWithNoSchedulesShowsNone() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    #expect(try sbd.get(s.id).schedules == nil)
    #expect(try list(sbd).isEmpty)
  }

  @Test func getPrintsAScheduleLine() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let lines = try sbd.sb("get", s.id).split(separator: "\n")

    #expect(lines.contains { $0.contains("schedule:") && $0.contains(r.schedule.id) })
  }

  @Test func scheduleLsPrintsEachScheduleForAPerson() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id, "look at the flags")

    let out = try sbd.sb("schedule", "ls")

    #expect(out.contains(r.schedule.id))
    #expect(out.contains("look at the flags"))
    #expect(out.contains("30m"))
  }

  @Test func aScheduleThatClaudeSetsIsByClaude() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let r = try schedule(sbd, s.id, env: ["CLAUDECODE": "1", "SB_SESSION_ID": s.id])

    #expect(r.schedule.by == .claude)
  }

  @Test func unquotedPromptWordsAreJoined() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let r = try row(sbd.sb("schedule", s.id, "--every", "30m", "check", "the", "queue", "--json"))

    #expect(r.schedule.prompt == "check the queue")
  }

  @Test func aSlashCommandPromptIsKeptVerbatim() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let r = try schedule(sbd, s.id, "/audit-waiting")

    #expect(r.schedule.prompt == "/audit-waiting")
  }

  @Test func schedulesListInTheOrderOfTheirNextRun() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "a")
    let b = try sbd.new(name: "b")
    let later = try schedule(sbd, a.id, every: "2h", "later")
    let sooner = try schedule(sbd, b.id, every: "30m", "sooner")
    let soonerOnA = try schedule(sbd, a.id, every: "1h", "sooner on a")

    #expect(try ids(list(sbd)) == [sooner, soonerOnA, later].map(\.schedule.id))
    #expect(try ids(list(sbd, a.id)) == [soonerOnA, later].map(\.schedule.id))
  }

  @Test func idsAreUniqueAcrossSessions() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "a")
    let b = try sbd.new(name: "b")

    let made = try (0..<5).flatMap { i in
      [try schedule(sbd, a.id, "a \(i)").schedule.id, try schedule(sbd, b.id, "b \(i)").schedule.id]
    }

    #expect(Set(made).count == made.count)
    #expect(made.allSatisfy { $0.hasPrefix("r") && $0.count == 6 })
  }

  @Test func eachChangeRecordsAnEventThatLeavesTheLastActivity() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    try sbd.passIdleStopToSessionEnd(s.id)
    let before = try sbd.get(s.id).lastActivity

    let r = try schedule(sbd, s.id)
    try sbd.sb("schedule", "pause", r.schedule.id)
    try sbd.sb("schedule", "resume", r.schedule.id)
    try sbd.sb("schedule", "rm", r.schedule.id)

    let kinds = try sbd.events(s.id).map(\.kind)
    for kind in ["schedule", "schedule-paused", "schedule-resumed", "schedule-removed"] {
      #expect(kinds.contains(kind), "no \(kind) event in \(kinds)")
    }
    #expect(try sbd.get(s.id).lastActivity == before)
  }

  // MARK: Refusals

  /// Each refusal leaves the session with no schedule.
  @Test func refusesAnIntervalItCantUse() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    for every in ["30s", "59s", "0m", "soon", "30", "1h30m", "30M", "99999999999999w"] {
      let r = try sbd.run(["schedule", s.id, "--every", every, "check the queue", "--json"])
      #expect(r.status != 0, "--every \(every) was accepted")
    }
    let missing = try sbd.run(["schedule", s.id, "check the queue", "--json"])

    #expect(missing.status != 0)
    #expect(try sbd.get(s.id).schedules == nil)
  }

  @Test func refusesAnIntervalUnderOneMinuteWithTheShortest() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let r = try sbd.run(["schedule", s.id, "--every", "30s", "check the queue"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("the shortest interval is 1m"))
  }

  @Test func refusesAnEmptyPrompt() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    for prompt in [[""], ["   "], []] {
      let r = try sbd.run(["schedule", s.id, "--every", "30m"] + prompt + ["--json"])
      #expect(r.status != 0, "the prompt \(prompt) was accepted")
    }

    #expect(try sbd.get(s.id).schedules == nil)
  }

  /// sbd refuses on its own, for a caller such as the MCP server that skips the CLI.
  @Test func theScheduleRequestRefusesWhatTheCLIRefuses() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let session = JSON.string(s.id)

    let cases: [([String: JSON], String)] = [
      (["session": session, "every": "30s", "prompt": "check"], "the shortest interval is 1m"),
      (["session": session, "every": "soon", "prompt": "check"], "every"),
      (["session": session, "every": "1h30m", "prompt": "check"], "90m"),
      (["session": session, "prompt": "check"], "every"),
      (["session": session, "every": "30m"], "prompt"),
      (["session": session, "every": "30m", "prompt": " \n "], "prompt"),
      (["session": session, "every": "30m", "prompt": "check", "by": "robot"], "by"),
    ]
    for (args, mentions) in cases {
      let error = failure(sbd, "schedule", args)
      #expect(error != "no error", "\(args) was accepted")
      #expect(error.contains(mentions), "\(args) failed with \(error)")
    }

    #expect(try sbd.get(s.id).schedules == nil)
  }

  /// An account or a model belongs only to a headless schedule, so a schedule that sends its prompt into the session
  /// refuses both.
  @Test func theScheduleRequestRefusesAnAccountOrAModelWithoutTheHeadlessRunner() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let session = JSON.string(s.id)
    let base: [String: JSON] = ["session": session, "every": "30m", "prompt": "git fetch"]

    for extra: [String: JSON] in [["account": "work"], ["model": "haiku"], ["runner": "session", "model": "haiku"]] {
      let error = failure(sbd, "schedule", base.merging(extra) { $1 })
      #expect(error.contains("--headless"), "\(extra) failed with \(error)")
    }
    #expect(try sbd.get(s.id).schedules == nil)
  }

  /// The headless runner is stored in `jobs` and listed with the session's schedules.
  @Test func theScheduleRequestStoresAHeadlessSchedule() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let added = try sbd.client.call(
      "schedule",
      ["session": .string(s.id), "every": "30m", "prompt": "git fetch", "runner": "headless", "model": "haiku"],
      as: ScheduleRow.self)

    #expect(added.schedule.runner == .headless)
    #expect(added.schedule.model == "haiku")
    #expect(try sbd.get(s.id).schedules == [added.schedule])
  }

  /// A schedule that sends its prompt into the session has no run of its own to time out.
  @Test func aTimeoutOnAScheduleThatSendsItsPromptIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let added = failure(
      sbd, "schedule", ["session": .string(s.id), "every": "30m", "prompt": "check", "timeout": "5m"])
    #expect(added.contains("has no timeout"), "\(added)")
    #expect(try sbd.get(s.id).schedules == nil)

    let id = try schedule(sbd, s.id).schedule.id
    let edited = failure(sbd, "edit-schedule", ["schedule": .string(id), "timeout": "5m"])
    #expect(edited.contains("has no timeout"), "\(edited)")
  }

  @Test func refusesAnEleventhScheduleOnASession() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "a")
    let b = try sbd.new(name: "b")
    for i in 1...10 { _ = try schedule(sbd, a.id, "check \(i)") }

    let r = try sbd.run(["schedule", a.id, "--every", "30m", "check 11", "--json"])

    #expect(r.status != 0)
    #expect(try list(sbd, a.id).count == 10)
    #expect(try schedule(sbd, b.id).session == b.id)
  }

  @Test func refusesAFollowupThatHasNotStarted() throws {
    let sbd = try Instance()
    let f = try JSONCoding.decode(
      SessionSummary.self, from: try sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."))

    let r = try sbd.run(["schedule", f.id, "--every", "30m", "check the queue", "--json"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("follow-up"))
    #expect(try sbd.get(f.id).schedules == nil)
  }

  @Test func refusesASpawnedFollowup() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try Instance(config: ["repoRoots": [.string(repos.root)]])
    let f = try JSONCoding.decode(
      SessionSummary.self,
      from: try sbd.sb(
        ["spawn", "--json", "--repo", "acme/widgets", "--branch", "b1", "--prompt", "hello", "--followup"]))

    let r = try sbd.run(["schedule", f.id, "--every", "30m", "check the queue", "--json"])

    #expect(r.status != 0)
    #expect(try sbd.get(f.id).schedules == nil)
  }

  // MARK: Pausing, resuming, removing

  @Test func pausingThenResumingStartsTheIntervalAgain() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let paused = try row(sbd.sb("schedule", "pause", r.schedule.id, "--json"))
    #expect(paused.schedule.paused == true)
    #expect(try sbd.get(s.id).schedules?.first?.paused == true)

    try sbd.advanceClock(5 * 60_000)
    let before = try sbd.now()
    let resumed = try row(sbd.sb("schedule", "resume", r.schedule.id, "--json"))
    let after = try sbd.now()

    #expect(resumed.schedule.paused == nil)
    #expect(
      (before + ScheduleTests.thirtyMinutes...after + ScheduleTests.thirtyMinutes).contains(resumed.schedule.next))
    #expect(try sbd.get(s.id).schedules == [resumed.schedule])
  }

  /// Resuming an active schedule, or pausing a paused one, changes nothing and records no event.
  @Test func aRepeatedPauseOrResumeChangesNothing() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)
    try sbd.advanceClock(5 * 60_000)

    let resumed = try row(sbd.sb("schedule", "resume", r.schedule.id, "--json"))
    try sbd.sb("schedule", "pause", r.schedule.id)
    let pausedAgain = try row(sbd.sb("schedule", "pause", r.schedule.id, "--json"))

    #expect(resumed.schedule == r.schedule)
    #expect(pausedAgain.schedule.paused == true)
    #expect(pausedAgain.schedule.next == r.schedule.next)
    let kinds = try sbd.events(s.id).map(\.kind)
    #expect(kinds.filter { $0 == "schedule-paused" }.count == 1)
    #expect(!kinds.contains("schedule-resumed"))
  }

  @Test func removingDeletesTheScheduleAndReturnsIt() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let removed = try row(sbd.sb("schedule", "rm", r.schedule.id, "--json"))

    #expect(removed.schedule == r.schedule)
    #expect(try list(sbd).isEmpty)
    #expect(try sbd.get(s.id).schedules == nil)
  }

  @Test func removingOneScheduleKeepsTheOthers() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let gone = try schedule(sbd, s.id, "gone")
    let kept = try schedule(sbd, s.id, every: "1h", "kept")

    try sbd.sb("schedule", "rm", gone.schedule.id)

    #expect(try sbd.get(s.id).schedules == [kept.schedule])
  }

  @Test func removingOrPausingAnUnknownIdFails() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    for args in [["schedule", "rm", "rzzzzz"], ["schedule", "pause", "rzzzzz"], ["schedule", "resume", "rzzzzz"]] {
      #expect(try sbd.run(args).status != 0, "\(args) succeeded")
    }

    #expect(try sbd.get(s.id).schedules == [r.schedule])
  }

  @Test func aRequestThatNamesAnotherSessionFails() throws {
    let sbd = try Instance()
    let owner = try sbd.new(name: "owner")
    let other = try sbd.new(name: "other")
    let r = try schedule(sbd, owner.id)
    let id = JSON.string(r.schedule.id)

    let removing = failure(sbd, "remove-schedule", ["schedule": id, "session": .string(other.id)])
    let pausing = failure(sbd, "pause-schedule", ["schedule": id, "session": .string(other.id)])

    #expect(removing.contains("has no schedule \(r.schedule.id)"), "\(removing)")
    #expect(pausing.contains("has no schedule \(r.schedule.id)"), "\(pausing)")
    #expect(try sbd.get(owner.id).schedules == [r.schedule])
  }

  @Test func aRequestThatNamesTheOwnerSucceeds() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let named: [String: JSON] = ["schedule": .string(r.schedule.id), "session": .string(s.id)]

    let paused = try sbd.client.call("pause-schedule", named, as: ScheduleRow.self)
    let resumed = try sbd.client.call(
      "pause-schedule", named.merging(["paused": false]) { $1 }, as: ScheduleRow.self)
    let removed = try sbd.client.call("remove-schedule", named, as: ScheduleRow.self)

    #expect(paused.schedule.paused == true)
    #expect(resumed.schedule.paused == nil)
    #expect(removed.schedule.id == r.schedule.id)
    #expect(try sbd.get(s.id).schedules == nil)
  }

  // MARK: Lifetime

  @Test func schedulesSurviveAnSbdRestart() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "a")
    let b = try sbd.new(name: "b")
    _ = try schedule(sbd, a.id)
    let paused = try schedule(sbd, b.id, every: "1h", "paused")
    try sbd.sb("schedule", "pause", paused.schedule.id)
    let before = try list(sbd)

    sbd.stopSbd()
    try sbd.startSbd()

    let after = try list(sbd)
    #expect(after.map(\.schedule) == before.map(\.schedule))
    #expect(after.map(\.session) == before.map(\.session))
  }

  @Test func removingTheSessionRemovesItsSchedules() throws {
    let sbd = try Instance()
    let gone = try sbd.new(name: "gone")
    let kept = try sbd.new(name: "kept")
    _ = try schedule(sbd, gone.id)
    let r = try schedule(sbd, kept.id)

    try sbd.sb("rm", gone.id)

    #expect(try list(sbd).map(\.schedule) == [r.schedule])
  }

  @Test func removingTheOnlyScheduledSessionLeavesTheListEmpty() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    _ = try schedule(sbd, s.id)

    try sbd.sb("rm", s.id)

    #expect(try list(sbd).isEmpty)
  }

  // MARK: Group scope

  /// Session `a` is in group Flags, `b` in group Billing, and `loose` in no
  /// group. `caller` is in no group either, as a group chat is in none. Each
  /// has one schedule.
  struct Scoped {
    let sbd: Instance
    let flags: String
    let a: ScheduleRow
    let b: ScheduleRow
    let loose: ScheduleRow
    let caller: ScheduleRow

    func args(_ extra: [String: JSON]) -> [String: JSON] {
      extra.merging(["group": .string(flags), "caller": .string(caller.session)]) { $1 }
    }

    func call(_ op: String, _ extra: [String: JSON]) throws -> ScheduleRow {
      try sbd.client.call(op, args(extra), as: ScheduleRow.self)
    }

    func refusal(_ op: String, _ extra: [String: JSON]) -> String { failure(sbd, op, args(extra)) }

    /// The rows with no scope.
    func all() throws -> [ScheduleRow] { try sbd.client.call("schedules", as: [ScheduleRow].self) }

    func stored(_ row: ScheduleRow) throws -> [Schedule]? { try sbd.get(row.session).schedules }
  }

  func scoped() throws -> Scoped {
    let sbd = try Instance()
    let a = try sbd.new(name: "a")
    let b = try sbd.new(name: "b")
    let loose = try sbd.new(name: "loose")
    let caller = try sbd.new(name: "caller")
    let flags = try sbd.client.call(
      "group-add", ["name": "Flags", "sessions": [.string(a.id)]], as: GroupSummary.self)
    _ = try sbd.client.call("group-add", ["name": "Billing", "sessions": [.string(b.id)]], as: GroupSummary.self)
    return Scoped(
      sbd: sbd, flags: flags.id, a: try schedule(sbd, a.id, "a"), b: try schedule(sbd, b.id, "b"),
      loose: try schedule(sbd, loose.id, "loose"), caller: try schedule(sbd, caller.id, "caller"))
  }

  @Test func aScopedListHasOnlyTheGroupsAndTheCallersRows() throws {
    let s = try scoped()

    let listed = try s.sbd.client.call("schedules", s.args([:]), as: [ScheduleRow].self)

    #expect(Set(listed.map(\.schedule.id)) == [s.a.schedule.id, s.caller.schedule.id])
  }

  @Test func aScopedListOfAnotherGroupsSessionHasNoRows() throws {
    let s = try scoped()

    let listed = try s.sbd.client.call(
      "schedules", s.args(["session": .string(s.b.session)]), as: [ScheduleRow].self)

    #expect(listed.isEmpty)
  }

  @Test func aScopedRequestActsOnAMembersSchedule() throws {
    let s = try scoped()
    let id = JSON.string(s.a.schedule.id)

    let paused = try s.call("pause-schedule", ["schedule": id])
    let removed = try s.call("remove-schedule", ["schedule": id])

    #expect(paused.schedule.paused == true)
    #expect(removed.schedule.id == s.a.schedule.id)
    #expect(try s.stored(s.a) == nil)
  }

  @Test func aScopedRequestActsOnTheCallersOwnSchedule() throws {
    let s = try scoped()
    let id = JSON.string(s.caller.schedule.id)

    let paused = try s.call("pause-schedule", ["schedule": id])
    let removed = try s.call("remove-schedule", ["schedule": id])

    #expect(paused.schedule.paused == true)
    #expect(removed.schedule.id == s.caller.schedule.id)
  }

  @Test func aScopedAddWorksForAMemberAndTheCaller() throws {
    let s = try scoped()

    let member = try s.call("schedule", ["session": .string(s.a.session), "every": "1h", "prompt": "more"])
    let own = try s.call("schedule", ["session": .string(s.caller.session), "every": "1h", "prompt": "more"])

    #expect(member.session == s.a.session)
    #expect(own.session == s.caller.session)
  }

  /// Another group's session and an ungrouped one are both outside the scope.
  @Test(arguments: ["b", "loose"])
  func aScopedRequestRefusesAScheduleOutsideTheGroup(_ which: String) throws {
    let s = try scoped()
    let target = which == "b" ? s.b : s.loose
    let id = JSON.string(target.schedule.id)

    let removing = s.refusal("remove-schedule", ["schedule": id])
    let pausing = s.refusal("pause-schedule", ["schedule": id])

    #expect(removing.contains("not in group"), "\(removing)")
    #expect(pausing.contains("not in group"), "\(pausing)")
    #expect(try s.stored(target) == [target.schedule])
  }

  @Test(arguments: ["b", "loose"])
  func aScopedAddRefusesASessionOutsideTheGroup(_ which: String) throws {
    let s = try scoped()
    let target = which == "b" ? s.b : s.loose

    let adding = s.refusal("schedule", ["session": .string(target.session), "every": "1h", "prompt": "more"])

    #expect(adding.contains("not in group"), "\(adding)")
    #expect(try s.stored(target) == [target.schedule])
  }

  @Test func aScopedRequestRefusesAnUnknownId() throws {
    let s = try scoped()

    #expect(s.refusal("remove-schedule", ["schedule": "rzzzzz"]) != "no error")
    #expect(s.refusal("pause-schedule", ["schedule": "rzzzzz"]) != "no error")
  }

  /// The chat saw `a` in its group, and then `a` left the group.
  @Test func aScopedRequestRefusesASessionThatLeftTheGroup() throws {
    let s = try scoped()
    _ = try s.sbd.client.call("group-move", ["sessions": [.string(s.a.session)], "ungrouped": true])
    let id = JSON.string(s.a.schedule.id)

    let removing = s.refusal("remove-schedule", ["schedule": id])
    let pausing = s.refusal("pause-schedule", ["schedule": id])
    let adding = s.refusal("schedule", ["session": .string(s.a.session), "every": "1h", "prompt": "more"])
    let listed = try s.sbd.client.call("schedules", s.args([:]), as: [ScheduleRow].self)

    #expect(removing.contains("not in group"), "\(removing)")
    #expect(pausing.contains("not in group"), "\(pausing)")
    #expect(adding.contains("not in group"), "\(adding)")
    #expect(!listed.map(\.schedule.id).contains(s.a.schedule.id))
    #expect(try s.stored(s.a) == [s.a.schedule])
  }

  /// A `group` that isn't a group id refuses, so it never reads as no scope.
  @Test(arguments: [JSON.number(5), .string(""), .bool(true)])
  func aMalformedScopeRefuses(_ group: JSON) throws {
    let s = try scoped()
    let args: [String: JSON] = ["group": group, "caller": .string(s.caller.session)]

    let listing = failure(s.sbd, "schedules", args)
    let removing = failure(s.sbd, "remove-schedule", args.merging(["schedule": .string(s.b.schedule.id)]) { $1 })
    let adding = failure(
      s.sbd, "schedule", args.merging(["session": .string(s.b.session), "every": "1h", "prompt": "more"]) { $1 })

    #expect(listing.contains("group"), "\(listing)")
    #expect(removing.contains("group"), "\(removing)")
    #expect(adding.contains("group"), "\(adding)")
    #expect(try s.stored(s.b) == [s.b.schedule])
  }

  @Test func anUnscopedListHasEveryRow() throws {
    let s = try scoped()

    #expect(Set(try s.all().map(\.schedule.id)) == Set([s.a, s.b, s.loose, s.caller].map(\.schedule.id)))
  }
}

// MARK: Status, edit, and the usage

extension ScheduleTests {
  /// `sb schedule edit <id> <more…> --json`.
  func edit(_ sbd: Instance, _ id: String, _ more: [String], env: [String: String] = [:]) throws -> ScheduleRow {
    try row(sbd.sb(["schedule", "edit", id] + more + ["--json"], env: env))
  }

  func edited(_ sbd: Instance, _ session: String) throws -> [Event] { try sbd.events(session, kind: "schedule-edited") }

  @Test func usageNamesEditAndRun() throws {
    let sbd = try Instance()

    let usage = try sbd.sb("help")

    #expect(usage.contains("schedule edit <id>"))
    #expect(usage.contains("schedule run <id>"))
  }

  // MARK: Status

  @Test func aFreshLoopIsActive() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    _ = try schedule(sbd, s.id)

    let status = try #require(try list(sbd).first?.status)

    #expect(status.state == .active)
    #expect(status.text.hasPrefix("next in "), "\(status.text)")
  }

  @Test func aPausedLoopIsPaused() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)
    try sbd.sb("schedule", "pause", r.schedule.id)

    let status = try #require(try list(sbd).first?.status)

    #expect(status.state == .paused)
    #expect(status.text == "paused")
  }

  /// `status` and its `state` are on the wire, so an agent reads them from `sb schedule ls --json`.
  @Test func scheduleLsJSONCarriesTheStatusStateAndText() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    _ = try schedule(sbd, s.id)

    let listed = try #require(JSON.parse(try sbd.sb("schedule", "ls", "--json"))?.array?.first)

    #expect(listed["status"]?["state"]?.string == "active")
    #expect(listed["status"]?["text"]?.string?.isEmpty == false)
  }

  /// Every request that returns a row computes its status (Decision 2). `run-schedule` is in `ScheduleRunNowTests`.
  @Test func everyScheduleRequestReturnsARowWithAStatus() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let id = JSON.string(try schedule(sbd, s.id).schedule.id)

    let added = try sbd.client.call(
      "schedule", ["session": .string(s.id), "every": "1h", "prompt": "more"], as: ScheduleRow.self)
    let listed = try sbd.client.call("schedules", as: [ScheduleRow].self)
    let editedRow = try sbd.client.call("edit-schedule", ["schedule": id, "every": "45m"], as: ScheduleRow.self)
    let paused = try sbd.client.call("pause-schedule", ["schedule": id], as: ScheduleRow.self)
    let resumed = try sbd.client.call("pause-schedule", ["schedule": id, "paused": false], as: ScheduleRow.self)
    let removed = try sbd.client.call("remove-schedule", ["schedule": id], as: ScheduleRow.self)

    #expect(added.status?.state == .active)
    #expect(listed.count == 2)
    #expect(listed.allSatisfy { $0.status?.state == .active })
    #expect(editedRow.status?.state == .active)
    #expect(paused.status?.state == .paused)
    #expect(resumed.status?.state == .active)
    #expect(removed.status != nil)
  }

  /// `sb get` computes the status from the summary with the same Core function. A paused loop does not depend on
  /// the clock, which `sb` reads without sbd's test offset.
  @Test func getAndScheduleLsPrintTheSameStatusText() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id, "look at the flags")
    try sbd.sb("schedule", "pause", r.schedule.id)

    let got = try sbd.sb("get", s.id).split(separator: "\n").first { $0.contains(r.schedule.id) }
    let listed = try sbd.sb("schedule", "ls").split(separator: "\n").first { $0.contains(r.schedule.id) }

    #expect(got?.contains("every 30m · paused") == true, "\(String(describing: got))")
    #expect(listed?.contains("every 30m · paused") == true, "\(String(describing: listed))")
  }

  // MARK: Edit

  @Test func editingTheIntervalMovesTheNextRunToTheSoonerOfTheTwo() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)
    let before = try sbd.now()

    let changed = try edit(sbd, r.schedule.id, ["--every", "2m"])

    let after = try sbd.now()
    #expect(changed.schedule.every == 120_000)
    let sooner = min(r.schedule.next, before + 120_000)...min(r.schedule.next, after + 120_000)
    #expect(sooner.contains(changed.schedule.next), "\(changed.schedule.next) not in \(sooner)")
    #expect(changed.schedule.prompt == r.schedule.prompt)
    #expect(try sbd.get(s.id).schedules == [changed.schedule])
  }

  @Test func lengtheningTheIntervalKeepsTheNextRun() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let changed = try edit(sbd, r.schedule.id, ["--every", "1d"])

    #expect(changed.schedule.every == 86_400_000)
    #expect(changed.schedule.next == r.schedule.next)
  }

  @Test func editingThePromptChangesOnlyThePrompt() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let changed = try edit(sbd, r.schedule.id, ["new", "prompt", "words"])

    var expected = r.schedule
    expected.prompt = "new prompt words"
    #expect(changed.schedule == expected)
    #expect(try sbd.get(s.id).schedules == [expected])
  }

  @Test func editingBothChangesBoth() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let changed = try edit(sbd, r.schedule.id, ["--every", "1h", "look at the flags"])

    #expect(changed.schedule.every == 3_600_000)
    #expect(changed.schedule.prompt == "look at the flags")
    #expect(changed.schedule.next == r.schedule.next)
    #expect(changed.schedule.id == r.schedule.id)
  }

  @Test func aRealEditRecordsAnEventWithTheScheduleBefore() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let changed = try edit(sbd, r.schedule.id, ["--every", "1h", "look at the flags"])

    let events = try edited(sbd, s.id)
    try #require(events.count == 1, "\(events)")
    let before = try #require(events[0].data["before"])
    #expect(try JSONCoding.convert(before, to: Schedule.self) == r.schedule)
    #expect(events[0].data["schedule"]?["prompt"]?.string == changed.schedule.prompt)
  }

  /// An edit to the current values is like a pause of a paused schedule: it returns the row and records nothing.
  @Test func anEditThatChangesNothingRecordsNoEvent() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let same = try edit(sbd, r.schedule.id, ["--every", "30m", r.schedule.prompt])

    #expect(same.schedule == r.schedule)
    #expect(try edited(sbd, s.id).isEmpty)
    #expect(try sbd.get(s.id).schedules == [r.schedule])
  }

  /// `by` records who created the loop, so an edit keeps it even when the request names another author.
  @Test func anEditKeepsTheAuthor() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id, env: ["CLAUDECODE": "1", "SB_SESSION_ID": s.id])
    try #require(r.schedule.by == .claude)

    let changed = try sbd.client.call(
      "edit-schedule", ["schedule": .string(r.schedule.id), "every": "1h", "by": "you"], as: ScheduleRow.self)

    #expect(changed.schedule.every == 3_600_000)
    #expect(changed.schedule.by == .claude)
  }

  @Test func editWithNeitherAnIntervalNorAPromptFails() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let result = try sbd.run(["schedule", "edit", r.schedule.id])

    #expect(result.status != 0)
    #expect(
      result.stderr.contains("schedule edit needs --every, --timeout, --account, --model, or a prompt"),
      "\(result.stderr)")
    #expect(try sbd.get(s.id).schedules == [r.schedule])
  }

  @Test func editRefusesABadIntervalAndKeepsTheRow() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    for every in ["30s", "soon", "1h30m", "30M"] {
      let result = try sbd.run(["schedule", "edit", r.schedule.id, "--every", every, "--json"])
      #expect(result.status != 0, "--every \(every) was accepted")
    }

    #expect(try sbd.get(s.id).schedules == [r.schedule])
    #expect(try edited(sbd, s.id).isEmpty)
  }

  @Test func editRefusesAnEmptyPromptAndKeepsTheRow() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)
    let id = JSON.string(r.schedule.id)

    let blank = try sbd.run(["schedule", "edit", r.schedule.id, "   ", "--json"])
    let empty = failure(sbd, "edit-schedule", ["schedule": id, "prompt": ""])
    let spaces = failure(sbd, "edit-schedule", ["schedule": id, "prompt": " \n "])

    #expect(blank.status != 0)
    #expect(empty.contains("prompt"), "\(empty)")
    #expect(spaces.contains("prompt"), "\(spaces)")
    #expect(try sbd.get(s.id).schedules == [r.schedule])
  }

  @Test func editRefusesAnEmptyPromptArgumentWithAnIntervalAndKeepsTheRow() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let result = try sbd.run(["schedule", "edit", r.schedule.id, "--every", "1h", "", "--json"])

    #expect(result.status != 0)
    #expect(try sbd.get(s.id).schedules == [r.schedule])
  }

  /// `--json` before the subcommand still lets `edit` read its flags.
  @Test func aLeadingFlagStillReadsTheEditsInterval() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let changed = try row(sbd.sb(["schedule", "--json", "edit", r.schedule.id, "--every", "1h"]))

    #expect(changed.schedule.every == 3_600_000)
    #expect(changed.schedule.prompt == r.schedule.prompt)
  }

  /// sbd refuses on its own, for a caller that skips the CLI.
  @Test func theEditRequestRefusesWhatTheCLIRefuses() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)
    let id = JSON.string(r.schedule.id)

    let cases: [([String: JSON], String)] = [
      (["schedule": id, "every": "30s"], "the shortest interval is 1m"),
      (["schedule": id, "every": "soon"], "soon"),
      (["schedule": id, "every": "1h30m"], "90m"),
      (["schedule": id, "every": "1h", "prompt": "  "], "prompt"),
      (["every": "1h"], "schedule"),
    ]
    for (args, mentions) in cases {
      let error = failure(sbd, "edit-schedule", args)
      #expect(error != "no error", "\(args) was accepted")
      #expect(error.contains(mentions), "\(args) failed with \(error)")
    }
    #expect(failure(sbd, "edit-schedule", ["schedule": id]) != "no error", "an edit of neither field was accepted")

    #expect(try sbd.get(s.id).schedules == [r.schedule])
  }

  @Test func editingAnUnknownIdFails() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let result = try sbd.run(["schedule", "edit", "rzzzzz", "--every", "1h"])

    #expect(result.status != 0)
    #expect(try sbd.get(s.id).schedules == [r.schedule])
  }

  @Test func anEditThatNamesAnotherSessionFails() throws {
    let sbd = try Instance()
    let owner = try sbd.new(name: "owner")
    let other = try sbd.new(name: "other")
    let r = try schedule(sbd, owner.id)

    let error = failure(
      sbd, "edit-schedule", ["schedule": .string(r.schedule.id), "session": .string(other.id), "every": "1h"])

    #expect(error.contains("has no schedule \(r.schedule.id)"), "\(error)")
    #expect(try sbd.get(owner.id).schedules == [r.schedule])
  }

  @Test func anEditThatNamesTheOwnerSucceeds() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)

    let changed = try sbd.client.call(
      "edit-schedule", ["schedule": .string(r.schedule.id), "session": .string(s.id), "prompt": "new words"],
      as: ScheduleRow.self)

    #expect(changed.schedule.prompt == "new words")
  }

  @Test func anEditSurvivesAnSbdRestart() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try schedule(sbd, s.id)
    let changed = try edit(sbd, r.schedule.id, ["--every", "1h", "look at the flags"])

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try list(sbd).map(\.schedule) == [changed.schedule])
  }

  // MARK: Edit in a group scope

  @Test func aScopedEditActsOnAMembersSchedule() throws {
    let s = try scoped()

    let changed = try s.call("edit-schedule", ["schedule": .string(s.a.schedule.id), "prompt": "new words"])

    #expect(changed.schedule.prompt == "new words")
    #expect(try s.stored(s.a)?.first?.prompt == "new words")
  }

  @Test func aScopedEditActsOnTheCallersOwnSchedule() throws {
    let s = try scoped()

    let changed = try s.call("edit-schedule", ["schedule": .string(s.caller.schedule.id), "every": "1h"])

    #expect(changed.schedule.every == 3_600_000)
  }

  @Test(arguments: ["b", "loose"])
  func aScopedEditRefusesAScheduleOutsideTheGroup(_ which: String) throws {
    let s = try scoped()
    let target = which == "b" ? s.b : s.loose

    let error = s.refusal("edit-schedule", ["schedule": .string(target.schedule.id), "prompt": "new words"])

    #expect(error.contains("not in group"), "\(error)")
    #expect(try s.stored(target) == [target.schedule])
  }

  @Test func aScopedEditRefusesAnUnknownId() throws {
    let s = try scoped()

    #expect(s.refusal("edit-schedule", ["schedule": "rzzzzz", "prompt": "new words"]) != "no error")
  }

  @Test func aScopedEditRefusesASessionThatLeftTheGroup() throws {
    let s = try scoped()
    _ = try s.sbd.client.call("group-move", ["sessions": [.string(s.a.session)], "ungrouped": true])

    let error = s.refusal("edit-schedule", ["schedule": .string(s.a.schedule.id), "prompt": "new words"])

    #expect(error.contains("not in group"), "\(error)")
    #expect(try s.stored(s.a) == [s.a.schedule])
  }
}
