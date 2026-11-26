import Foundation
import SwitchboardCore
import Testing

/// Script schedules: `sb schedule <session> --every <interval> --script <command>` stores a shell command that sbd
/// runs in the session's folder, outside the session's conversation, under the hold and blocker rules of a prompt
/// schedule. Only the user, sbd, and a Manager conversation may store a script or change its command or timeout.
/// Claude in any other session except the Operator proposes the script through a card that stores nothing, which
/// ScriptProposalTests covers. The Operator is refused.
///
/// A command that the test runner starts runs outside every pane, which counts as the user. A test makes a script
/// due with Run Now, or with a clock move where the interval is what it tests. Each script writes what it shows to
/// files under SB_HOME by absolute path, so no test depends on the run's environment except the ones that check it.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScheduleScriptTests {
  let fire = ScheduleFireTests()
  let waits = WaitActionTests()
  let operatorHelpers = OperatorTests()

  /// sbd's refusal for a caller that the proposal card will serve.
  static let refusal = "only you or a Manager conversation can add a script schedule"

  // MARK: Helpers

  func row(_ text: String) throws -> ScheduleRow { try JSONCoding.decode(ScheduleRow.self, from: text) }

  /// Adds a script through `sb schedule <session> --every <every> [--timeout <timeout>] --script <command> --json`
  /// from a terminal outside Switchboard.
  @discardableResult
  func addScript(
    _ sbd: Instance, _ session: String, _ command: String, every: String = "30m", timeout: String? = nil
  ) throws -> Schedule {
    let limit = timeout.map { ["--timeout", $0] } ?? []
    let added = try row(sbd.sb(["schedule", session, "--every", every] + limit + ["--script", command, "--json"]))
    // An sb that doesn't know --script would store the command as a prompt to paste into the session.
    try #require(added.schedule.runner == .script, "\(added.schedule)")
    return added.schedule
  }

  func current(_ sbd: Instance, _ session: String, _ id: String) throws -> Schedule? {
    try fire.current(sbd, session, id)
  }

  func runNow(_ sbd: Instance, _ id: String) throws { try sbd.sb("schedule", "run", id) }

  /// Waits until the schedule records a run other than the one at `after`, and returns it.
  @discardableResult
  func waitForRun(
    _ sbd: Instance, _ session: String, _ id: String, after: Int64? = nil, timeout: Double = 30
  ) throws -> Schedule.Run {
    try sbd.waitFor(
      "a run of \(id)", timeout: timeout, fetch: { try current(sbd, session, id)?.last },
      until: { $0.t != after })
  }

  /// A file in the home, by absolute path.
  func path(_ sbd: Instance, _ name: String) -> String { "\(sbd.home.path)/\(name)" }

  /// The file's lines, or none when it doesn't exist.
  func lines(_ file: String) -> [String] {
    ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  /// The last line that isn't blank. A login shell can print before the command does.
  func lastLine(_ text: String) -> String? {
    text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
  }

  /// The folder that holds the schedule's run logs.
  func logFolder(_ sbd: Instance, _ session: String, _ id: String) -> String {
    "\(sbd.home.sessionFolder(session))/schedules/\(id)"
  }

  /// The `.log` files in the schedule's log folder.
  func logFiles(_ sbd: Instance, _ session: String, _ id: String) -> Set<String> {
    Set(
      ((try? FileManager.default.contentsOfDirectory(atPath: logFolder(sbd, session, id))) ?? [])
        .filter { $0.hasSuffix(".log") })
  }

  /// The command that runs sb against this instance's sbd. With `unsetsCaller`, the command drops SB_SESSION_ID
  /// and CLAUDECODE, so sb claims no caller and only the client's ancestry can place it.
  func sbCommand(_ sbd: Instance, unsetsCaller: Bool, _ args: [String]) -> String {
    let unset = unsetsCaller ? ["env", "-u", "SB_SESSION_ID", "-u", "CLAUDECODE"] : ["env"]
    return (unset + ["SB_HOME=\(sbd.home.path)", "\(Instance.bin)/sb"] + args).map(shellQuote).joined(separator: " ")
  }

  /// `command` with its stdout, stderr, and exit status in `<name>.out`, `<name>.err`, and `<name>.status` in the
  /// home, which `Instance.scriptResult` reads.
  func recorded(_ sbd: Instance, _ name: String, _ command: String) -> String {
    "\(command) >\(shellQuote(path(sbd, "\(name).out"))) 2>\(shellQuote(path(sbd, "\(name).err"))); "
      + "echo $? >\(shellQuote(path(sbd, "\(name).status")))"
  }

  /// A copy of /bin/sleep in the home with an ad hoc signature. The kernel can hide the environment of a program
  /// that ships with macOS, and sbd finds an orphaned run by its environment. The copy's path holds the home, so
  /// Fixtures/reap stops what a failed test leaves running.
  func homeSleep(_ sbd: Instance) throws -> String {
    let copy = path(sbd, "run-bin/sleep")
    if FileManager.default.fileExists(atPath: copy) { return copy }
    try FileManager.default.createDirectory(atPath: path(sbd, "run-bin"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy)
    let signed = try runCommand("/usr/bin/codesign", ["--force", "-s", "-", copy])
    try #require(signed.status == 0, "codesign: \(signed.stderr)")
    return copy
  }

  /// A command that writes its shell's pid to `file` in the home and then becomes a long sleep, so the pid in the
  /// file is the run's process until it ends.
  func sleeper(_ sbd: Instance, pidFile file: String) throws -> String {
    "echo $$ >\(shellQuote(path(sbd, file))); exec \(shellQuote(try homeSleep(sbd))) 600"
  }

  /// Waits until the command that `sleeper` wrote has recorded its pid.
  func runPid(_ sbd: Instance, _ file: String) throws -> pid_t {
    try sbd.waitFor("the run's pid in \(file)", timeout: 15, fetch: { sbd.stubPid(file) }, until: { _ in true })
  }

  /// A command that appends `start` to `marks`, waits until the gate file exists, and appends `end`.
  func gated(_ sbd: Instance, marks: String, gate: String, start: String = "start") -> String {
    let m = shellQuote(path(sbd, marks))
    return "echo \(start) >>\(m); while [ ! -f \(shellQuote(sbd.gate(gate))) ]; do sleep 0.1; done; echo end >>\(m)"
  }

  /// Expects that `r` proposed a script: sb printed `{pending: N, decision: "pending"}`, and N is the one `script`
  /// card on the proposer.
  func expectProposed(
    _ r: CommandResult, _ sbd: Instance, on proposer: SessionSummary, sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    try #require(
      r.status == 0, Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"), sourceLocation: sourceLocation)
    let answer = try #require(JSON.parse(r.stdout), Comment(rawValue: r.stdout), sourceLocation: sourceLocation)
    #expect(answer["decision"]?.string == "pending", Comment(rawValue: answer.text), sourceLocation: sourceLocation)
    let cards = try sbd.get(proposer.id).cards.filter { $0.kind == .script }
    #expect(
      cards.map(\.id) == [answer["pending"]?.int].compactMap { $0 }.map(Int64.init), sourceLocation: sourceLocation)
  }

  // MARK: Run and record

  @Test func aScriptFromATerminalRunsOnItsIntervalAndRecordsItsExitAndLastLine() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo hi", every: "1m")
    try #require(made.runner == .script)
    #expect(made.prompt == "echo hi")
    #expect(made.by == .you)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let last = try waitForRun(sbd, s.id, made.id)
    #expect(last.outcome == .ran)
    #expect(last.exit == 0)
    #expect(last.tail == "hi")
    #expect(last.error == nil)
    #expect(last.ms != nil)
    let stored = try #require(try current(sbd, s.id, made.id))
    #expect(stored.running == nil)
    #expect(stored.next == last.t + ScheduleFireTests.every)
    #expect(lastLine(try sbd.sb("schedule", "log", made.id)) == "hi")
  }

  @Test func theScheduleRanEventCarriesTheRunnerTheExitAndTheTail() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo hi")

    try runNow(sbd, made.id)

    try waitForRun(sbd, s.id, made.id)
    let ran = try fire.scheduleRan(sbd, s.id)
    try #require(ran.count == 1, "\(ran)")
    #expect(ran[0].data["outcome"]?.string == "ran")
    #expect(ran[0].data["runner"]?.string == "script")
    #expect(ran[0].data["exit"]?.int == 0)
    #expect(ran[0].data["tail"]?.string == "hi")
  }

  /// Decision 4: the run's environment names the session and the run, and Decision 6: it runs in the session's
  /// folder.
  @Test func aScriptRunsInTheSessionsFolderWithTheSessionAndRunInItsEnvironment() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, #"pwd -P; echo "$SB_SESSION_ID $SB_SCHEDULE_RUN""#)

    try runNow(sbd, made.id)

    let last = try waitForRun(sbd, s.id, made.id)
    #expect(last.outcome == .ran, "\(last)")
    #expect(last.tail == "\(s.id) \(made.id):\(last.t)")
    let log = try sbd.sb("schedule", "log", made.id)
    #expect(log.split(separator: "\n").contains { $0 == real(s.cwd) }, Comment(rawValue: log))
  }

  @Test func aNonZeroExitRecordsAFailedRunWithTheExitAndTheLastLine() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo boom; exit 3")

    try runNow(sbd, made.id)

    let last = try waitForRun(sbd, s.id, made.id)
    #expect(last.outcome == .failed)
    #expect(last.exit == 3)
    #expect(last.tail == "boom")
    #expect(last.error != nil)
    #expect(try fire.status(sbd, made.id)?.state == .failed)
    #expect(try fire.listedLine(sbd, made.id)?.contains("exit 3") == true)
  }

  @Test func scheduleLsShowsTheCommandAndTheLastRunsExitAndTail() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo listed")
    #expect(try fire.listedLine(sbd, made.id)?.contains("$ echo listed") == true)

    try runNow(sbd, made.id)

    try waitForRun(sbd, s.id, made.id)
    let line = try #require(try fire.listedLine(sbd, made.id))
    #expect(line.contains("$ echo listed"), Comment(rawValue: line))
    #expect(line.contains("last: ran"), Comment(rawValue: line))
    #expect(line.contains("exit 0 · listed"), Comment(rawValue: line))
  }

  // MARK: Timeout

  /// The script forks a child that would outlive it, so only a signal to the run's process group ends both.
  @Test func aTimeoutEndsTheScriptAndTheChildItForked() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let sleep = shellQuote(try homeSleep(sbd))
    let made = try addScript(
      sbd, s.id, "\(sleep) 600 & echo $! >\(shellQuote(path(sbd, "child.pid"))); \(sleep) 600", timeout: "10s")
    #expect(made.timeout == 10_000)

    try runNow(sbd, made.id)

    let child = try runPid(sbd, "child.pid")
    let last = try waitForRun(sbd, s.id, made.id, timeout: 40)
    #expect(last.outcome == .failed)
    #expect(last.error?.contains("timed out after 10s") == true, "\(last)")
    try sbd.waitFor("the forked child to end", timeout: 10) { !Processes.exists(Int(child)) }
    #expect(try current(sbd, s.id, made.id)?.running == nil)
  }

  @Test func aTimeoutLongerThanTheIntervalIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()

    let r = try sbd.run(["schedule", s.id, "--every", "1m", "--timeout", "5m", "--script", "echo hi", "--json"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("longer than the interval"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).schedules == nil)
  }

  @Test func anEditThatShortensTheIntervalBelowTheTimeoutIsRefusedNamingBoth() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo hi", every: "30m", timeout: "20m")
    #expect(made.timeout == 1_200_000)

    let r = try sbd.run(["schedule", "edit", made.id, "--every", "10m"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("20m") && r.stderr.contains("10m"), Comment(rawValue: r.stderr))
    #expect(try current(sbd, s.id, made.id) == made)
  }

  // MARK: Holds

  @Test func aRunningTurnHoldsTheScriptAndItRunsOnceAfterTheTurn() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let marks = path(sbd, "marks")
    let made = try addScript(sbd, s.id, "echo ran >>\(shellQuote(marks))")
    try fire.holdATurn(sbd, s.id)

    try runNow(sbd, made.id)
    sleep(2)

    #expect(lines(marks).isEmpty)
    #expect(try current(sbd, s.id, made.id)?.last == nil)
    sbd.hold("report")
    #expect(try waitForRun(sbd, s.id, made.id).outcome == .ran)
    sleep(2)
    #expect(lines(marks) == ["ran"])
    #expect(try fire.scheduleRan(sbd, s.id).count == 1)
  }

  /// Run Now refuses a held session, so the clock makes the script due.
  @Test func aPausedSessionHoldsTheScriptAndItRunsOnceAfterTheResume() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let marks = path(sbd, "marks")
    let made = try addScript(sbd, s.id, "echo ran >>\(shellQuote(marks))", every: "1m")
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)

    try sbd.advanceClock(3 * ScheduleFireTests.every + 30_000)
    sleep(2)

    #expect(lines(marks).isEmpty)
    #expect(try current(sbd, s.id, made.id)?.last == nil)
    #expect(try fire.scheduleRan(sbd, s.id).isEmpty)
    try sbd.sb("resume", s.id, "--message", "go on")
    #expect(try waitForRun(sbd, s.id, made.id).outcome == .ran)
    sleep(2)
    #expect(lines(marks) == ["ran"])
  }

  // MARK: Runs in flight

  /// Decision 9: at most two detached runs at once across sbd. A due schedule over the cap stays due.
  @Test func atMostTwoScriptsRunAtOnceAndTheThirdRunsAfterOneEnds() throws {
    let sbd = try Instance()
    let sessions = try (1...3).map { try sbd.idleSession(name: "s\($0)") }
    let made = try sessions.map { s in
      try addScript(sbd, s.id, gated(sbd, marks: "starts", gate: "go", start: s.id))
    }

    for m in made { try runNow(sbd, m.id) }

    try sbd.waitFor("two runs to start") { lines(path(sbd, "starts")).count >= 2 }
    sleep(2)
    #expect(lines(path(sbd, "starts")).count == 2)
    let inFlight = try zip(sessions, made).filter { try current(sbd, $0.id, $1.id)?.running != nil }
    #expect(inFlight.count == 2)
    sbd.hold("go")
    for (s, m) in zip(sessions, made) {
      #expect(try waitForRun(sbd, s.id, m.id).outcome == .ran)
    }
    #expect(Set(lines(path(sbd, "starts")).filter { $0 != "end" }) == Set(sessions.map(\.id)))
  }

  /// Decision 8: a schedule whose run is in flight stays due and is not dispatched again. It runs once more when
  /// the run ends.
  @Test func aScheduleNeverHasTwoRunsInFlight() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, gated(sbd, marks: "marks", gate: "go"), every: "1m")
    try runNow(sbd, made.id)
    try sbd.waitFor("the first run to start") { lines(path(sbd, "marks")) == ["start"] }

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    _ = try sbd.run(["schedule", "run", made.id])
    sleep(2)

    #expect(lines(path(sbd, "marks")) == ["start"])
    sbd.hold("go")
    try sbd.waitFor("the second run", timeout: 30) { try current(sbd, s.id, made.id)?.runs?.count == 2 }
    #expect(lines(path(sbd, "marks")) == ["start", "end", "start", "end"])
  }

  /// Decision 7: a run and the session's turn never overlap, so a run in flight holds the session's prompt schedules.
  /// The prompt goes in once, after the run ends.
  @Test func aScriptInFlightHoldsTheSessionsPromptUntilItEnds() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, gated(sbd, marks: "marks", gate: "go"))
    let prompt = try fire.add(sbd, s.id, every: "30m", "tick after the run")
    // sbd pastes only `pasteSettleSeconds` after SessionStart, so a run right after the first reply would be queued.
    try sbd.advanceClock(2_000)
    try runNow(sbd, made.id)
    try sbd.waitFor("the run to start") { lines(path(sbd, "marks")) == ["start"] }

    try runNow(sbd, prompt.schedule.id)
    sleep(2)

    #expect(try fire.runs(sbd, s.id, "tick after the run").isEmpty)
    #expect(try current(sbd, s.id, prompt.schedule.id)?.last == nil)
    sbd.hold("go")
    #expect(try waitForRun(sbd, s.id, made.id).outcome == .ran)
    try sbd.waitFor(s.id, "the reply to the prompt", timeout: 30) { $0.lastReply == "Done: tick after the run" }
    #expect(try fire.runs(sbd, s.id, "tick after the run").count == 1)
  }

  // MARK: Restart and removal

  /// Decision 19: a run in flight across a restart records a failed run, and sbd stops the orphan that launchd
  /// adopted by its SB_SCHEDULE_RUN marker. A SIGKILL leaves sbd no chance to stop the run itself.
  @Test func aRunInFlightAcrossARestartIsRecordedAsFailedAndItsOrphanIsStopped() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, try sleeper(sbd, pidFile: "orphan.pid"))
    try runNow(sbd, made.id)
    let orphan = try runPid(sbd, "orphan.pid")
    try sbd.waitFor("the run to show as running") { try current(sbd, s.id, made.id)?.running != nil }

    sbd.killSbd()
    try sbd.waitFor("launchd to adopt the run") { ProcessTable.readLocal().row(Int(orphan))?.ppid == 1 }
    try sbd.startSbd()

    let last = try waitForRun(sbd, s.id, made.id, timeout: 15)
    #expect(last.outcome == .failed)
    #expect(last.error?.contains("sbd restarted during the run") == true, "\(last)")
    #expect(try current(sbd, s.id, made.id)?.running == nil)
    try sbd.waitFor("sbd to stop the orphan", timeout: 15) { !Processes.exists(Int(orphan)) }
  }

  /// Decision 20: the removal cancels the session's runs, which no pane stop reaches because sbd started them.
  @Test func aRunInFlightWhenTheSessionsRemovalStartsIsCancelled() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, try sleeper(sbd, pidFile: "run.pid"))
    try runNow(sbd, made.id)
    let run = try runPid(sbd, "run.pid")

    try sbd.sb("rm", s.id)

    try sbd.waitFor("the run to end", timeout: 15) { !Processes.exists(Int(run)) }
    try sbd.waitFor("the removal", timeout: 30) { try sbd.client.sessions().allSatisfy { $0.id != s.id } }
  }

  @Test func removingAScheduleCancelsItsRunAndDeletesItsLogs() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, try sleeper(sbd, pidFile: "run.pid"))
    try runNow(sbd, made.id)
    let run = try runPid(sbd, "run.pid")
    let folder = logFolder(sbd, s.id, made.id)
    try #require(FileManager.default.fileExists(atPath: folder), "no log folder at \(folder)")

    try sbd.sb("schedule", "rm", made.id)

    try sbd.waitFor("the run to end", timeout: 15) { !Processes.exists(Int(run)) }
    try sbd.waitFor("the log folder to go", timeout: 5) { !FileManager.default.fileExists(atPath: folder) }
    #expect(try sbd.get(s.id).schedules == nil)
  }

  // MARK: Logs

  /// Decision 12: sbd keeps the logs of the `Schedule.maxRuns` newest runs, one file per run named by its time.
  @Test func eachRunKeepsALogAndSbdKeepsOnlyTheNewestTen() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo pruned")
    var previous: Int64?

    for _ in 1...(Schedule.maxRuns + 1) {
      try runNow(sbd, made.id)
      previous = try waitForRun(sbd, s.id, made.id, after: previous).t
    }

    let runs = try #require(try current(sbd, s.id, made.id)?.runs)
    #expect(runs.count == Schedule.maxRuns)
    let expected = Set(runs.map { "\($0.t).log" })
    try sbd.waitFor("the oldest log to go", timeout: 5) { logFiles(sbd, s.id, made.id).count == Schedule.maxRuns }
    #expect(logFiles(sbd, s.id, made.id) == expected)
  }

  @Test func scheduleLogPrintsTheNewestRunOrTheNthNewest() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let counter = shellQuote(path(sbd, "count"))
    let made = try addScript(
      sbd, s.id, "n=$(cat \(counter) 2>/dev/null || echo 0); n=$((n+1)); echo $n >\(counter); echo \"run $n\"")
    var previous: Int64?
    for _ in 1...2 {
      try runNow(sbd, made.id)
      previous = try waitForRun(sbd, s.id, made.id, after: previous).t
    }

    #expect(lastLine(try sbd.sb("schedule", "log", made.id)) == "run 2")
    #expect(lastLine(try sbd.sb("schedule", "log", made.id, "--run", "1")) == "run 2")
    #expect(lastLine(try sbd.sb("schedule", "log", made.id, "--run", "2")) == "run 1")
    let missing = try sbd.run(["schedule", "log", made.id, "--run", "3"])
    #expect(missing.status != 0, Comment(rawValue: missing.stdout))
  }

  /// The wire request behind `sb schedule log`.
  @Test func theScheduleLogRequestReturnsTheTextAndWhetherItWasCut() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo logged")
    try runNow(sbd, made.id)
    try waitForRun(sbd, s.id, made.id)

    let answer = try sbd.client.call("schedule-log", ["schedule": .string(made.id), "run": 1])

    #expect(lastLine(answer["text"]?.string ?? "") == "logged", Comment(rawValue: answer.text))
    #expect(answer["truncated"]?.bool == false, Comment(rawValue: answer.text))
  }

  /// Decision 12: the log keeps the first 1 MiB and ends with the cut marker, and the run keeps reading past the cap,
  /// so the command's last line still reaches the run's tail.
  @Test func aLogPastOneMiBIsCutAndTheRequestSaysSo() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "head -c 2000000 /dev/zero | tr '\\0' x; echo; echo done")
    try runNow(sbd, made.id)
    let last = try waitForRun(sbd, s.id, made.id)
    #expect(last.outcome == .ran, "\(last)")
    #expect(last.tail == "done")

    let answer = try sbd.client.call("schedule-log", ["schedule": .string(made.id)])

    #expect(answer["truncated"]?.bool == true)
    let text = answer["text"]?.string ?? ""
    #expect(lastLine(text) == DetachedRun.cutMarker)
    #expect(text.utf8.count <= DetachedRun.logCap + DetachedRun.cutMarker.utf8.count + 2)
    let printed = try sbd.run(["schedule", "log", made.id])
    #expect(printed.status == 0, Comment(rawValue: printed.stderr))
    #expect(lastLine(printed.stdout) == DetachedRun.cutMarker)
  }

  // MARK: Who may add or change a script (Risk 1)

  @Test func aScriptsCommandAndTimeoutEditFromATerminalIsStored() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try addScript(sbd, s.id, "echo hi")

    try sbd.sb("schedule", "edit", made.id, "--timeout", "2m", "echo bye")

    let stored = try #require(try current(sbd, s.id, made.id))
    #expect(stored.prompt == "echo bye")
    #expect(stored.timeout == 120_000)
    #expect(stored.runner == .script)
  }

  /// A schedule's runner is fixed at creation, so an edit can't turn a prompt into a command.
  @Test func anEditCantTurnAPromptScheduleIntoAScript() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try row(sbd.sb("schedule", s.id, "--every", "30m", "check the queue", "--json")).schedule

    let error = failure(
      sbd, "edit-schedule", ["schedule": .string(made.id), "runner": "script", "prompt": "touch pwned"])

    #expect(error != "no error")
    #expect(try current(sbd, s.id, made.id) == made)
  }

  @Test func aHostSessionRefusesAScript() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello"))

    let r = try sbd.run(["schedule", id, "--every", "30m", "--script", "echo hi", "--json"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("run only for a session on this Mac"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(id).schedules == nil)
  }

  /// A work session's Claude may not add a script, to itself or to another session. It proposes the script through a
  /// card on itself, which stores nothing until the user allows it.
  @Test(arguments: [true, false])
  func aWorkSessionsClaudePaneProposesAScriptAndStoresNothing(_ toItself: Bool) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let target = toItself ? worker : try sbd.idleSession(name: "target")

    let r = try waits.sbInPane(
      sbd, of: worker, ["schedule", target.id, "--every", "30m", "--script", "echo hi", "--json"])

    try expectProposed(r, sbd, on: worker)
    #expect(try sbd.get(target.id).schedules == nil)
  }

  /// A session's Claude can type into its own shell pane with `tmux send-keys`, so the shell pane counts too.
  @Test func aWorkSessionsShellPaneProposesAScriptAndStoresNothing() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let terminals = try sbd.client.terminals(worker.id)
    // A tick installs a snapshot that holds the shell pane's pid.
    try sbd.advanceClock(1)
    try sbd.writeSbScript("shell-add", ["schedule", worker.id, "--every", "30m", "--script", "echo hi", "--json"])

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/shell-add.sh\"")
    let r = try sbd.scriptResult("shell-add")

    try expectProposed(r, sbd, on: worker)
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  @Test func aManagerConversationsClaudePaneAddsAScript() throws {
    let sbd = try Instance()
    let c = try waits.conversation(sbd)
    let kid = try sbd.idleSession(name: "kid")

    let r = try waits.sbInPane(sbd, of: c, ["schedule", kid.id, "--every", "30m", "--script", "echo hi", "--json"])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let stored = try #require(try sbd.get(kid.id).schedules?.first)
    #expect(stored.runner == .script)
    #expect(stored.prompt == "echo hi")
    #expect(stored.by == .claude)
  }

  /// The Operator may not add a script, through sb or through MCP.
  @Test func theOperatorsPaneCannotAddAScript() throws {
    let sbd = try Instance()
    let op = try operatorHelpers.idleOperator(sbd)
    let kid = try sbd.idleSession(name: "kid")

    let r = try waits.sbInPane(sbd, of: op, ["schedule", kid.id, "--every", "30m", "--script", "echo hi", "--json"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try sbd.get(kid.id).schedules == nil)
    #expect(try sbd.get(op.id).schedules == nil)
    // A command from a terminal is stored, so the refusal came from who sent it.
    #expect(try addScript(sbd, kid.id, "echo from the terminal").runner == .script)
  }

  @Test func theOperatorsMCPServerCannotAddAScript() throws {
    let sbd = try Instance()
    let op = try operatorHelpers.idleOperator(sbd)
    let kid = try sbd.idleSession(name: "kid")

    let result = try waits.toolInPane(
      sbd, of: op, "add_schedule", ["session": .string(kid.id), "every": "30m", "script": "echo hi"],
      name: "operator-mcp-add")

    #expect(result.isError, Comment(rawValue: result.text))
    #expect(try sbd.get(kid.id).schedules == nil)
    // A call from a server outside every pane is the user's, so the refusal came from who sent it.
    let user = try MCPClient(sbd).call(
      "add_schedule", ["session": .string(kid.id), "every": "30m", "script": "echo from the terminal"])
    #expect(try user.decode(ScheduleRow.self).schedule.runner == .script)
  }

  @Test func aManagerConversationsMCPServerAddsAScript() throws {
    let sbd = try Instance()
    let c = try waits.conversation(sbd)
    let kid = try sbd.idleSession(name: "kid")

    let result = try waits.toolInPane(
      sbd, of: c, "add_schedule", ["session": .string(kid.id), "every": "30m", "script": "echo from mcp"],
      name: "manager-mcp-add")

    let added = try result.decode(ScheduleRow.self)
    #expect(added.schedule.runner == .script)
    #expect(added.schedule.prompt == "echo from mcp")
    #expect(try sbd.get(kid.id).schedules == [added.schedule])
  }

  @Test func aWorkSessionsMCPServerProposesAScriptAndStoresNothing() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let result = try waits.toolInPane(
      sbd, of: worker, "add_schedule", ["session": .string(worker.id), "every": "30m", "script": "echo hi"],
      name: "worker-mcp-add")

    #expect(!result.isError, Comment(rawValue: result.text))
    #expect(result.json?["decision"]?.string == "pending", Comment(rawValue: result.text))
    #expect(try sbd.get(worker.id).cards.filter { $0.kind == .script }.count == 1)
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  /// A shell pane that opened after the last tick's snapshot. The tick runs once an hour here, so only the fresh
  /// snapshot that the request takes holds the pane's pid. The command drops SB_SESSION_ID, so without that
  /// snapshot the client would be below sbd's tmux server in no known pane, which is refused.
  @Test func aManagerConversationsShellPaneThatOpenedSinceTheLastSnapshotAddsAScript() throws {
    let sbd = try Instance(config: ["tickSeconds": 3600])
    let c = try waits.conversation(sbd)
    _ = try sbd.client.call("shell", ["session": .string(c.id), "open": true])
    let terminals = try sbd.client.terminals(c.id)
    try sbd.writeScript(
      "late-add",
      sbCommand(sbd, unsetsCaller: true, ["schedule", c.id, "--every", "30m", "--script", "echo late", "--json"]))

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/late-add.sh\"")
    let r = try sbd.scriptResult("late-add")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let stored = try #require(try sbd.get(c.id).schedules?.first)
    #expect(stored.runner == .script)
    #expect(stored.prompt == "echo late")
  }

  /// The work session's side of the test above. Without a fresh snapshot, the installed one may know no pane and no
  /// tmux server, so a client that claims no caller would pass as the user. The fresh snapshot places the client in
  /// the work session, which proposes.
  @Test func aWorkSessionsShellPaneThatOpenedSinceTheLastSnapshotProposesAScript() throws {
    let sbd = try Instance(config: ["tickSeconds": 3600])
    let worker = try sbd.idleSession(name: "worker")
    _ = try sbd.client.call("shell", ["session": .string(worker.id), "open": true])
    let terminals = try sbd.client.terminals(worker.id)
    try sbd.writeScript(
      "late-add",
      sbCommand(
        sbd, unsetsCaller: true, ["schedule", worker.id, "--every", "30m", "--script", "echo late", "--json"]))

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/late-add.sh\"")
    let r = try sbd.scriptResult("late-add")

    try expectProposed(r, sbd, on: worker)
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  /// Decision 3 guards a script's command and timeout. The work session's pane changes neither. Its edit opens a card
  /// that holds the command and timeout before the edit.
  @Test(arguments: [["touch pwned"], ["--timeout", "2m"]])
  func aWorkSessionsPaneProposesAChangeOfAScriptsCommandOrTimeout(_ change: [String]) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try addScript(sbd, worker.id, "echo hi")

    let r = try waits.sbInPane(sbd, of: worker, ["schedule", "edit", made.id] + change + ["--json"])

    try expectProposed(r, sbd, on: worker)
    #expect(try current(sbd, worker.id, made.id) == made)
    let proposal = try #require(try sbd.get(worker.id).cards.first { $0.kind == .script }?.scriptProposal)
    #expect(proposal.schedule == made.id)
    #expect(proposal.before?.command == "echo hi")
  }

  /// An interval changes when the script runs, not what runs, so it keeps today's rules.
  @Test func aWorkSessionsPaneCanChangeAScriptsInterval() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try addScript(sbd, worker.id, "echo hi")

    let r = try waits.sbInPane(sbd, of: worker, ["schedule", "edit", made.id, "--every", "1h"])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let stored = try #require(try current(sbd, worker.id, made.id))
    #expect(stored.every == 3_600_000)
    #expect(stored.prompt == "echo hi")
  }

  // MARK: A run writes nothing into its session's state (Risk 5)

  /// A headless run's claude can fire `sb hook` from the account's or the worktree's settings. Its SessionStart would
  /// point the session at a conversation that the run never saves. The second hook, without the run's marker, is the
  /// control: the same payload moves the session's conversation.
  @Test func sbHookInsideARunSendsNothing() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let before = try sbd.get(s.id)
    let unsaved = "00000000-0000-4000-8000-0000000000be"
    let payload: JSON = ["hook_event_name": "SessionStart", "session_id": .string(unsaved), "source": "startup"]
    func hook(_ extra: [String: String]) throws -> CommandResult {
      try runCommand(
        "\(Instance.bin)/sb", ["hook"], env: sbd.environment(["SB_SESSION_ID": s.id].merging(extra) { $1 }),
        input: Data(payload.text.utf8))
    }

    let inRun = try hook([ScheduleRun.marker: "r1:1"])

    #expect(inRun.status == 0, Comment(rawValue: inRun.stderr))
    #expect(inRun.stdout.isEmpty, Comment(rawValue: inRun.stdout))
    #expect(try sbd.get(s.id).claudeSessionId == before.claudeSessionId)
    #expect(try sbd.events(s.id).filter { $0.data["session_id"]?.string == unsaved }.isEmpty)

    let outside = try hook([:])

    #expect(outside.status == 0, Comment(rawValue: outside.stderr))
    #expect(try sbd.get(s.id).claudeSessionId == unsaved)
  }

  // MARK: A run has its session's authority (Risk 2)

  /// sb in the run claims the work session from SB_SESSION_ID. With the variable unset, only the run's pid in the
  /// client's ancestry places sb inside the work session.
  @Test(arguments: [false, true])
  func aScriptOnAWorkSessionCannotArmMerge(_ unsetsCaller: Bool) throws {
    let github = try FakeGitHub()
    let sbd = try waits.instance(github)
    let s = try waits.notReadyTarget(github, sbd)
    let c = try waits.conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")
    let arm = sbCommand(sbd, unsetsCaller: unsetsCaller, ["wait", c.id] + waits.mergeArgs(s))
    let made = try addScript(sbd, worker.id, recorded(sbd, "run-merge", arm))

    try runNow(sbd, made.id)
    let r = try sbd.scriptResult("run-merge")

    try waits.expectRefused(r, sbd)
  }

  /// sb in the run claims the work session, or only the run's pid places it there, so the nested add proposes.
  @Test(arguments: [false, true])
  func aScriptOnAWorkSessionProposesAScriptAndStoresNothing(_ unsetsCaller: Bool) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let nested = sbCommand(
      sbd, unsetsCaller: unsetsCaller, ["schedule", worker.id, "--every", "1h", "--script", "echo nested", "--json"])
    let made = try addScript(sbd, worker.id, recorded(sbd, "run-add", nested))

    try runNow(sbd, made.id)
    let r = try sbd.scriptResult("run-add")

    try expectProposed(r, sbd, on: worker)
    #expect(try sbd.get(worker.id).schedules?.map(\.id) == [made.id])
  }

}
