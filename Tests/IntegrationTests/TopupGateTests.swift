import Foundation
import SwitchboardCore
import Testing

/// A schedule with a top-up gate (`sb schedule <session> --topup …`). On each due time sbd counts the active work
/// sessions of the gate's group in the gate's repository. When the group has its target and nothing needs the
/// Operator, sbd records the check and sends nothing. Otherwise it sends the fallback message: the queue status, the
/// prompt, the rubric, and the template. TopupTests covers a group short of its target, which starts sessions. This
/// sbd's gh can't list issues, so a top-up here fails and sends the fallback message.
///
/// The counted session has a long date wait, which puts it in Waiting. An idle session is in Needs you, which the
/// gate does not count. Each clock move stays well short of the idle stop and of the date wait.
@Suite(.blocking(timeLimit: .seconds(180))) struct TopupGateTests {
  let fire = ScheduleFireTests()
  let actions = WaitActionTests()
  let operatorHelpers = OperatorTests()

  static let repo = "acme/widgets"
  static let charts = MergeTests.charts
  static let groupName = "Queue"
  static let prompt = "tick the queue"
  static let rubric = "Bugs before features. Older issues first."
  static let template = "Fix {url}: {title}"
  static let flags = ["--group", "--repo", "--target", "--template-file", "--rubric-file"]

  struct GateFiles {
    let template: String
    let rubric: String
  }

  /// Writes the template and the rubric to files in the instance's home. Each file ends with a newline, which the
  /// stored gate trims.
  func gateFiles(_ sbd: Instance) throws -> GateFiles {
    let files = GateFiles(template: "\(sbd.home.path)/topup-template.md", rubric: "\(sbd.home.path)/topup-rubric.md")
    try "\(Self.template)\n".write(toFile: files.template, atomically: true, encoding: .utf8)
    try "\(Self.rubric)\n".write(toFile: files.rubric, atomically: true, encoding: .utf8)
    return files
  }

  /// `sb schedule <session> --every <every> --topup --group … --repo … --target … --template-file …
  /// --rubric-file … [<prompt>] --json`, without the flag `dropping`.
  func topupArgs(
    _ session: String, _ files: GateFiles, group: String = groupName, repo: String = repo, target: String = "1",
    prompt: String? = prompt, every: String = "1m", dropping: String? = nil
  ) -> [String] {
    let values = [group, repo, target, files.template, files.rubric]
    let flags = zip(Self.flags, values).filter { $0.0 != dropping }.flatMap { [$0.0, $0.1] }
    return ["schedule", session, "--every", every, "--topup"] + flags + (prompt.map { [$0] } ?? []) + ["--json"]
  }

  /// Adds a gated schedule from the test runner, which counts as the user, and checks that sbd stored a gate.
  /// Before Stage 3 sb sends no gate, and the flags' values join the prompt of a plain schedule.
  func addTopup(
    _ sbd: Instance, _ session: String, group: String = groupName, repo: String = repo, target: Int = 1,
    prompt: String? = prompt, every: String = "1m"
  ) throws -> Schedule {
    let files = try gateFiles(sbd)
    let row = try JSONCoding.decode(
      ScheduleRow.self,
      from: sbd.sb(
        topupArgs(session, files, group: group, repo: repo, target: String(target), prompt: prompt, every: every)))
    try #require(row.schedule.gate != nil, "sbd stored no gate: \(row.schedule)")
    return row.schedule
  }

  func addGroup(_ sbd: Instance, _ sessions: String...) throws -> GroupSummary {
    try sbd.client.call(
      "group-add", ["name": .string(Self.groupName), "sessions": .array(sessions.map(JSON.string))],
      as: GroupSummary.self)
  }

  func move(_ sbd: Instance, _ session: String, into group: GroupSummary) throws {
    _ = try sbd.client.call("group-move", ["sessions": [.string(session)], "group": .string(group.id)])
  }

  /// A work session in `repo` whose repository sbd has read, with a date wait that puts it in Waiting, so the gate
  /// counts it.
  func waitingSession(_ sbd: Instance, in repo: String = repo, name: String = "work", folder: String? = nil) throws
    -> SessionSummary
  {
    let s = try sbd.session(in: repo, branch: "haacked/no-pr-yet", folder: folder, name: name)
    try sbd.waitFor(s.id, "sbd's read of the repository") { $0.repository == repo }
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "2h", "--note", "check later")
    return try sbd.waitFor(s.id, "the date wait's Waiting") { $0.state == .waiting }
  }

  /// A session on #18303's branch that is Ready to merge, with no wait that merges it.
  func readyToMerge(_ sbd: Instance) throws -> SessionSummary {
    let s = try actions.readyTarget(sbd)
    try #require(s.repository == Self.charts, "the repository is \(String(describing: s.repository))")
    return s
  }

  /// A private sbd whose poller asks `github`, with no `operator.mergeRepos`, as on the live Mac today.
  func gitHubInstance(_ github: FakeGitHub) throws -> Instance { try Instance.withMergeStub(github) }

  func gate(_ sbd: Instance, _ session: String, _ id: String) throws -> Schedule.Gate? {
    try fire.current(sbd, session, id)?.gate
  }

  /// Waits until the gate has closed on `count` due times since the schedule's last run.
  @discardableResult
  func waitForGated(_ sbd: Instance, _ session: String, _ id: String, count: Int) throws -> Schedule.Gate {
    try sbd.waitFor(
      "gated check \(count) of \(id)", fetch: { try gate(sbd, session, id) },
      until: { $0.gated == count && $0.last?.result == .gated })
  }

  func gatedEvents(_ sbd: Instance, _ session: String) throws -> [Event] {
    try sbd.events(session, kind: "schedule-gated")
  }

  /// Every message that reached the session after the event `mark`, from anyone.
  func sent(_ sbd: Instance, _ session: String, after mark: Int64) throws -> [Event] {
    try sbd.events(session, after: mark).filter { $0.kind == "sent" }
  }

  // MARK: A gated due time

  @Test func aGatedDueTimeRecordsTheCheckAndSendsNothing() throws {
    let sbd = try Instance()
    let work = try waitingSession(sbd)
    _ = try addGroup(sbd, work.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, target: 1)
    let mark = try sbd.lastEventId(op.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let gate = try waitForGated(sbd, op.id, made.id, count: 1)
    try sbd.waitFor("the schedule-gated event") { try !gatedEvents(sbd, op.id).isEmpty }
    sleep(1)
    #expect(gate.last?.active == 1, "\(gate)")
    #expect(gate.last?.target == 1, "\(gate)")
    #expect(gate.last?.started == [], "\(gate)")
    #expect(try sent(sbd, op.id, after: mark).isEmpty)
    #expect(try gatedEvents(sbd, op.id).count == 1)
    let after = try #require(try fire.current(sbd, op.id, made.id))
    #expect(after.last == nil, "a gated due time appended a run: \(after)")
    #expect(after.next > (try sbd.now()), "the gated check left the schedule due: \(after)")
    #expect(try fire.scheduleRan(sbd, op.id).isEmpty)
  }

  /// Decision 35: only a repository that sbd hasn't read is unknown. A group session whose folder sbd has read and
  /// found off GitHub can't be in the gate's repository, so it doesn't keep the gate open.
  @Test func aGroupSessionOffGitHubDoesNotOpenTheGate() throws {
    let sbd = try Instance()
    let work = try waitingSession(sbd)
    let plain = try sbd.new(prompt: "hello", name: "notes")
    try sbd.waitFor(plain.id, "sbd's read of the folder") { $0.repositoryRead == true && $0.repository == nil }
    _ = try addGroup(sbd, work.id, plain.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, target: 1)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let gate = try waitForGated(sbd, op.id, made.id, count: 1)
    #expect(gate.last?.active == 1, "\(gate)")
  }

  @Test func aSecondGatedDueTimeCountsTwo() throws {
    let sbd = try Instance()
    let work = try waitingSession(sbd)
    _ = try addGroup(sbd, work.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, target: 1)
    let mark = try sbd.lastEventId(op.id)
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForGated(sbd, op.id, made.id, count: 1)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try waitForGated(sbd, op.id, made.id, count: 2)
    sleep(1)
    #expect(try gatedEvents(sbd, op.id).count == 2)
    #expect(try sent(sbd, op.id, after: mark).isEmpty)
    #expect(try fire.current(sbd, op.id, made.id)?.last == nil)
  }

  /// The row of a session in another repository, and of a session outside the group, count for nothing, so the
  /// one counted session gates a target of 1.
  @Test func sessionsOutsideTheGroupOrTheRepositoryDoNotOpenTheGate() throws {
    let sbd = try Instance()
    let work = try waitingSession(sbd)
    let elsewhere = try waitingSession(sbd, in: "acme/gadgets", name: "elsewhere")
    let loose = try sbd.session(in: Self.repo, branch: "haacked/loose", folder: "loose", name: "loose")
    try sbd.waitFor(loose.id, "sbd's read of the repository") { $0.repository == Self.repo }
    _ = try addGroup(sbd, work.id, elsewhere.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, target: 1)
    let mark = try sbd.lastEventId(op.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let gate = try waitForGated(sbd, op.id, made.id, count: 1)
    #expect(gate.last?.active == 1, "\(gate)")
    #expect(try sent(sbd, op.id, after: mark).isEmpty)
  }

  // MARK: An open gate

  /// Decision 35: a Ready to merge session with no merge wait needs the Operator, so the gate opens and sends the
  /// fallback message, which starts with the status and names the session.
  @Test func aReadyToMergeSessionWithoutAMergeWaitOpensTheGate() throws {
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try gitHubInstance(github)
    let work = try waitingSession(sbd, in: Self.charts, folder: "charts-work")
    let ready = try readyToMerge(sbd)
    _ = try addGroup(sbd, work.id, ready.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, repo: Self.charts, target: 1)
    let mark = try sbd.lastEventId(op.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let run = try fire.waitForRun(sbd, op.id, made.id, timeout: 30)
    sleep(2)
    let messages = try sbd.sbdMessages(op.id, after: mark)
    try #require(messages.count == 1, "\(messages)")
    let text = messages[0].data["text"]?.string ?? ""
    #expect(text.hasPrefix("Work queue: "), "\(text)")
    #expect(text.contains(Self.prompt), "\(text)")
    #expect(text.contains(Self.rubric), "\(text)")
    #expect(text.contains(Self.template), "\(text)")
    #expect(text.contains(ready.id), "\(text)")
    #expect(run.outcome == .pasted, "\(run)")
    #expect(run.gated == nil, "\(run)")
    let stored = try #require(try self.gate(sbd, op.id, made.id))
    #expect(stored.last?.result == .prompted, "\(stored)")
    #expect(try gatedEvents(sbd, op.id).isEmpty)
  }

  /// Decision 35 counts an action wait only when sbd will run it. sbd skips the waits of a holder marked done, so a
  /// Done session whose only removal wait sits on such a holder needs the Operator, and the gate opens. sbd puts a
  /// merge wait only on the Operator, which can't be marked done, so only a removal wait can sit on a done holder.
  @Test func aDoneSessionWhoseOnlyRemovalWaitSitsOnADoneHolderOpensTheGate() throws {
    let sbd = try Instance()
    let work = try waitingSession(sbd)
    let finished = try sbd.session(in: Self.repo, branch: "haacked/finished", folder: "finished", name: "finished")
    try sbd.waitFor(finished.id, "sbd's read of the repository") { $0.repository == Self.repo }
    let holder = try sbd.idleSession(name: "holder")
    let r = try sbd.run(
      [
        "wait", "--json", holder.id, "--kind", "session", "--target", finished.id, "--state", "done", "--then",
        "rm-worktree",
      ])
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try #require(
      try sbd.get(holder.id).waits.contains { $0.action?.kind == .rmWorktree && $0.actionSubject?.id == finished.id })
    try sbd.sb("done", holder.id)
    try sbd.sb("done", finished.id)
    try sbd.waitFor(finished.id, "Done") { $0.state == .done }
    _ = try addGroup(sbd, work.id, finished.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, target: 1)
    let mark = try sbd.lastEventId(op.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let run = try fire.waitForRun(sbd, op.id, made.id, timeout: 30)
    sleep(2)
    let messages = try sbd.sbdMessages(op.id, after: mark)
    try #require(messages.count == 1, "\(messages)")
    let text = messages[0].data["text"]?.string ?? ""
    #expect(text.hasPrefix("Work queue: 1/1 "), "\(text)")
    #expect(text.contains(finished.id), "\(text)")
    #expect(run.outcome == .pasted, "\(run)")
    #expect(try gatedEvents(sbd, op.id).isEmpty)
  }

  /// The run after gated due times takes their count, and the gate's count starts again.
  @Test func theRunAfterAGatedDueTimeCarriesTheGatedCount() throws {
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try gitHubInstance(github)
    let work = try waitingSession(sbd, in: Self.charts, folder: "charts-work")
    let ready = try readyToMerge(sbd)
    let group = try addGroup(sbd, work.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, repo: Self.charts, target: 1)
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForGated(sbd, op.id, made.id, count: 1)
    let mark = try sbd.lastEventId(op.id)
    try move(sbd, ready.id, into: group)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let run = try fire.waitForRun(sbd, op.id, made.id, timeout: 30)
    #expect(run.gated == 1, "\(run)")
    #expect(run.text().contains("· 1 gated"), "\(run.text())")
    let stored = try #require(try self.gate(sbd, op.id, made.id))
    #expect((stored.gated ?? 0) == 0, "\(stored)")
    let messages = try sbd.sbdMessages(op.id, after: mark)
    try #require(messages.count == 1, "\(messages)")
    #expect(messages[0].data["text"]?.string?.hasPrefix("Work queue: ") == true, "\(messages[0])")
  }

  /// A group short of its target starts a top-up. This sbd's gh can't list the issues, so the top-up fails and the
  /// Operator gets the fallback message with the failure first.
  @Test func aGroupShortOfItsTargetWhoseIssueReadFailsGetsTheFallbackMessage() throws {
    // gh-merge-stub answers `issue list` with a 404 when the test writes no list, so no real gh runs.
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try gitHubInstance(github)
    let work = try waitingSession(sbd)
    _ = try addGroup(sbd, work.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, target: 3)
    let mark = try sbd.lastEventId(op.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    _ = try fire.waitForRun(sbd, op.id, made.id, timeout: 30)
    let messages = try sbd.sbdMessages(op.id, after: mark)
    try #require(messages.count == 1, "\(messages)")
    let text = messages[0].data["text"]?.string ?? ""
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.first?.hasPrefix("The top-up failed: ") == true, "\(text)")
    #expect(lines.dropFirst().first?.hasPrefix("Work queue: 1/3 ") == true, "\(text)")
    #expect(text.contains(Self.rubric), "\(text)")
    #expect(try gatedEvents(sbd, op.id).isEmpty)
  }

  // MARK: A busy Operator

  /// Decision 43: a gated check sends nothing, so it runs while the Operator's turn runs. An open gate waits for
  /// the Operator to be free, as a plain schedule does, and then sends once.
  @Test func aBusyOperatorStillRecordsAGatedCheckAndGetsAnOpenGatesMessageOnceFree() throws {
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try gitHubInstance(github)
    let work = try waitingSession(sbd, in: Self.charts, folder: "charts-work")
    let ready = try readyToMerge(sbd)
    let group = try addGroup(sbd, work.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, repo: Self.charts, target: 1)
    let mark = try sbd.lastEventId(op.id)
    try sbd.sb("operator", "slow held")
    try fire.waitForPrompt(sbd, op.id, "slow held")

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForGated(sbd, op.id, made.id, count: 1)
    try move(sbd, ready.id, into: group)
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    sleep(2)

    #expect(try sbd.sbdMessages(op.id, after: mark).isEmpty)
    let held = try #require(try fire.current(sbd, op.id, made.id))
    #expect(held.last == nil, "\(held)")
    #expect(held.next <= (try sbd.now()), "the open gate did not stay due: \(held)")
    sbd.hold("report")
    let run = try fire.waitForRun(sbd, op.id, made.id, timeout: 30)
    sleep(2)
    let messages = try sbd.sbdMessages(op.id, after: mark)
    try #require(messages.count == 1, "\(messages)")
    #expect(messages[0].data["text"]?.string?.hasPrefix("Work queue: ") == true, "\(messages[0])")
    #expect(run.gated == 1, "\(run)")
  }

  /// A plain schedule that sorts first and waits on the busy Operator doesn't hold back the gated check after it.
  @Test func aPlainScheduleWaitingOnABusyOperatorDoesNotHoldBackAGatedCheck() throws {
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try gitHubInstance(github)
    let work = try waitingSession(sbd, in: Self.charts, folder: "charts-work")
    _ = try addGroup(sbd, work.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let plain = try ScheduleTests().schedule(sbd, op.id, every: "1m", "/audit-waiting")
    try sbd.advanceClock(1000)
    let made = try addTopup(sbd, op.id, repo: Self.charts, target: 1)
    try #require(plain.schedule.next < made.next, "the plain schedule must sort first: \(plain.schedule) \(made)")
    try sbd.sb("operator", "slow held")
    try fire.waitForPrompt(sbd, op.id, "slow held")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try waitForGated(sbd, op.id, made.id, count: 1)
    #expect(try fire.current(sbd, op.id, plain.schedule.id)?.last == nil)
  }

  // MARK: Storing the gate

  @Test func aTopupStoresTheGateWithTheFilesTextAndTheGroupsId() throws {
    let sbd = try Instance()
    let group = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)

    let made = try addTopup(sbd, op.id, target: 4, every: "30m")

    let gate = try #require(made.gate)
    #expect(gate.group == group.id)
    #expect(gate.repo == Self.repo)
    #expect(gate.target == 4)
    #expect(gate.template == Self.template)
    #expect(gate.rubric == Self.rubric)
    #expect(made.prompt == Self.prompt)
    #expect(made.by == .you)
    #expect(try sbd.get(op.id).schedules == [made])
  }

  @Test(arguments: [true, false]) func aTopupNamesItsGroupByNameOrId(_ byName: Bool) throws {
    let sbd = try Instance()
    let group = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)

    let made = try addTopup(sbd, op.id, group: byName ? group.name : group.id, every: "30m")

    #expect(made.gate?.group == group.id)
  }

  @Test func aTopupWithoutAPromptStoresTheDefaultPrompt() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)

    let made = try addTopup(sbd, op.id, target: 2, prompt: nil, every: "30m")

    #expect(made.prompt == Schedule.Gate.defaultPrompt(groupName: Self.groupName, repo: Self.repo, target: 2))
  }

  @Test func aTopupInAnUnknownGroupIsRefused() throws {
    let sbd = try Instance()
    let op = try operatorHelpers.openOperator(sbd)

    let r = try sbd.run(topupArgs(op.id, try gateFiles(sbd), group: "Nowhere", every: "30m"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("Nowhere"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  @Test(arguments: [("widgets", "owner/name"), ("acme/widgets/extra", "owner/name")])
  func aTopupWithABadRepositoryIsRefused(_ repo: String, _ mentions: String) throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)

    let r = try sbd.run(topupArgs(op.id, try gateFiles(sbd), repo: repo, every: "30m"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(mentions), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  @Test(arguments: ["0", "21"]) func aTopupWithATargetOutsideOneToTwentyIsRefused(_ target: String) throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)

    let r = try sbd.run(topupArgs(op.id, try gateFiles(sbd), target: target, every: "30m"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("1 to 20"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  // MARK: The CLI flags

  @Test(arguments: TopupGateTests.flags) func topupWithoutEachFlagFailsNamingIt(_ missing: String) throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)

    let r = try sbd.run(topupArgs(op.id, try gateFiles(sbd), every: "30m", dropping: missing))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(missing), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  /// Without `--topup`, sb would otherwise drop the flag or join its value to the prompt of a plain schedule.
  @Test(arguments: TopupGateTests.flags) func eachTopupFlagWithoutTopupFails(_ flag: String) throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let files = try gateFiles(sbd)
    let value = [
      "--group": Self.groupName, "--repo": Self.repo, "--target": "1", "--template-file": files.template,
      "--rubric-file": files.rubric,
    ][flag]!

    let r = try sbd.run(["schedule", op.id, "--every", "30m", flag, value, Self.prompt, "--json"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(flag), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  @Test(arguments: ["--template-file", "--rubric-file"]) func aFileThatIsNotThereFailsNamingIt(_ flag: String) throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let real = try gateFiles(sbd)
    let gone = "\(sbd.home.path)/no-such-file.md"
    let files = GateFiles(
      template: flag == "--template-file" ? gone : real.template, rubric: flag == "--rubric-file" ? gone : real.rubric)

    let r = try sbd.run(topupArgs(op.id, files, every: "30m"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(gone), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  @Test func scheduleLsAndGetShowTheGateLineBeforeAndAfterACheck() throws {
    let sbd = try Instance()
    let work = try waitingSession(sbd)
    _ = try addGroup(sbd, work.id)
    let op = try operatorHelpers.idleOperator(sbd)
    let made = try addTopup(sbd, op.id, target: 1)
    let lead = "topup \(Self.groupName) \(Self.repo)"

    let listedBefore = try sbd.sb("schedule", "ls")
    let gotBefore = try sbd.sb("get", op.id)
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForGated(sbd, op.id, made.id, count: 1)
    let listedAfter = try sbd.sb("schedule", "ls")
    let gotAfter = try sbd.sb("get", op.id)

    #expect(listedBefore.contains("\(lead) · target 1 · never checked"), Comment(rawValue: listedBefore))
    #expect(gotBefore.contains("\(lead) · target 1 · never checked"), Comment(rawValue: gotBefore))
    #expect(listedAfter.contains("\(lead) 1/1 · checked"), Comment(rawValue: listedAfter))
    #expect(listedAfter.contains(": gated"), Comment(rawValue: listedAfter))
    #expect(gotAfter.contains("\(lead) 1/1 · checked"), Comment(rawValue: gotAfter))
  }

  @Test func helpListsTheTopupFlags() throws {
    let sbd = try Instance()

    let usage = try sbd.sb("help")

    for flag in ["--topup"] + Self.flags { #expect(usage.contains(flag), "sb help has no \(flag)") }
  }

  // MARK: Duplicates (Decision 44)

  @Test(arguments: ["check the queue", "  check the queue  "])
  func aSecondScheduleWithTheSamePromptIsRefused(_ again: String) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let first = try ScheduleTests().schedule(sbd, s.id, "check the queue")

    let r = try sbd.run(["schedule", s.id, "--every", "1h", again, "--json"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("already sends this prompt"), Comment(rawValue: r.stderr))
    #expect(r.stderr.contains(first.schedule.id), Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).schedules == [first.schedule])
  }

  @Test func aTopupWithThePromptOfAPlainScheduleIsRefused() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let plain = try ScheduleTests().schedule(sbd, op.id, Self.prompt)

    let r = try sbd.run(topupArgs(op.id, try gateFiles(sbd), every: "30m"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("already sends this prompt"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == [plain.schedule])
  }

  /// The repository matches with any case, and the group matches by id whichever way the request names it.
  @Test(arguments: [(TopupGateTests.repo, true), ("ACME/Widgets", false)])
  func aSecondTopupForTheSameGroupAndRepositoryIsRefused(_ repo: String, _ byName: Bool) throws {
    let sbd = try Instance()
    let group = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let first = try addTopup(sbd, op.id, every: "30m")

    let r = try sbd.run(
      topupArgs(
        op.id, try gateFiles(sbd), group: byName ? group.name : group.id, repo: repo, prompt: "another tick",
        every: "1h"))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("already tops up"), Comment(rawValue: r.stderr))
    #expect(r.stderr.contains(first.id), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == [first])
  }

  @Test func aDifferentPromptOnTheSameSessionIsAccepted() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let first = try ScheduleTests().schedule(sbd, s.id, "check the queue")

    let second = try ScheduleTests().schedule(sbd, s.id, "check the flags")

    #expect(try sbd.get(s.id).schedules?.map(\.id) == [first.schedule.id, second.schedule.id])
  }

  /// The live loop rm76hh has a different prompt and no gate, so the top-up can be added beside it.
  @Test func aTopupBesideAPlainScheduleWithAnotherPromptIsAccepted() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let plain = try ScheduleTests().schedule(sbd, op.id, "/audit-waiting")

    let made = try addTopup(sbd, op.id, every: "30m")

    #expect(try sbd.get(op.id).schedules?.map(\.id).sorted() == [plain.schedule.id, made.id].sorted())
  }

  @Test func aSecondTopupForAnotherRepositoryIsAccepted() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let first = try addTopup(sbd, op.id, every: "30m")

    let second = try addTopup(sbd, op.id, repo: "acme/gadgets", prompt: "tick the gadgets", every: "1h")

    #expect(try sbd.get(op.id).schedules?.map(\.id).sorted() == [first.id, second.id].sorted())
  }

  // MARK: Who may add a top-up (Decision 38)

  /// A work session's Claude may not plant a top-up, which would start `--yolo` sessions.
  @Test func aWorkSessionCannotAddATopup() throws {
    let sbd = try Instance()
    let files = try gateFiles(sbd)
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let worker = try sbd.idleSession(name: "worker")

    let r = try actions.sbInPane(sbd, of: worker, topupArgs(op.id, files, every: "30m"), name: "topup")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(WaitActionTests.refusal), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  /// Only the ancestry counts, so a work session that claims a Manager conversation's id is still refused.
  @Test func aWorkSessionThatSetsAConversationsIdCannotAddATopup() throws {
    let sbd = try Instance()
    let files = try gateFiles(sbd)
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let c = try actions.conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")

    let r = try actions.sbInPane(
      sbd, of: worker, topupArgs(op.id, files, every: "30m"), env: ["SB_SESSION_ID": c.id], name: "topup")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(WaitActionTests.refusal), Comment(rawValue: r.stderr))
    #expect(try sbd.get(op.id).schedules == nil)
  }

  /// A plain schedule keeps today's rules, so the same work session may still add one.
  @Test func aWorkSessionCanStillAddAPlainSchedule() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let r = try actions.sbInPane(
      sbd, of: worker, ["schedule", worker.id, "--every", "30m", "check my PR", "--json"], name: "plain")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.get(worker.id).schedules?.count == 1)
  }

  @Test func aWorkSessionCannotEditATopup() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let made = try addTopup(sbd, op.id, every: "30m")
    let worker = try sbd.idleSession(name: "worker")

    let r = try actions.sbInPane(
      sbd, of: worker, ["schedule", "edit", made.id, "--every", "2m", "--json"], name: "edit")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(WaitActionTests.refusal), Comment(rawValue: r.stderr))
    #expect(try fire.current(sbd, op.id, made.id) == made)
  }

  @Test func theUserCanEditATopup() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    let made = try addTopup(sbd, op.id, every: "30m")

    let edited = try ScheduleTests().edit(sbd, made.id, ["--every", "1h"])

    #expect(edited.schedule.every == 3_600_000)
    #expect(edited.schedule.gate == made.gate)
  }

  /// A group chat's MCP server sends `group`. sbd arms actions for a gated schedule, so a scoped request may not
  /// add one, even on a member of its own group. The request sends no `caller`, so the scope alone refuses it.
  @Test func aScopedScheduleRequestWithAGateIsRefused() throws {
    let sbd = try Instance()
    let member = try sbd.new(name: "member")
    let group = try addGroup(sbd, member.id)
    let gate: JSON = [
      "group": .string(group.id), "repo": .string(Self.repo), "target": 1, "template": .string(Self.template),
      "rubric": .string(Self.rubric),
    ]

    let error = failure(
      sbd, "schedule",
      [
        "session": .string(member.id), "every": "30m", "prompt": .string(Self.prompt), "gate": gate,
        "group": .string(group.id),
      ])

    #expect(error.contains("a group chat can't add or edit a top-up"), Comment(rawValue: error))
    #expect(try sbd.get(member.id).schedules == nil)
  }

  /// Decision 38: sbd refuses a scoped `edit-schedule` of a gated schedule too, even on a member of the scope's group.
  @Test func aScopedEditOfATopupIsRefused() throws {
    let sbd = try Instance()
    let member = try sbd.new(name: "member")
    let group = try addGroup(sbd, member.id)
    let made = try addTopup(sbd, member.id)

    let error = failure(
      sbd, "edit-schedule", ["schedule": .string(made.id), "every": "1h", "group": .string(group.id)])

    #expect(error.contains("a group chat can't add or edit a top-up"), Comment(rawValue: error))
    #expect(try fire.current(sbd, member.id, made.id)?.every == made.every)
  }
}
