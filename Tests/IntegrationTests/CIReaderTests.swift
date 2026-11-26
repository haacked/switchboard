import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// Makes the stub's CI reader judge answer with `cause` and `message`, as Fixtures/claude-stub reads
  /// `$SB_HOME/ci-judge-answer.json`.
  func answerCIJudge(_ cause: String, message: String = CIReaderTests.message) throws {
    let json: JSON = ["cause": .string(cause), "message": .string(message)]
    try json.text.write(toFile: "\(home.path)/ci-judge-answer.json", atomically: true, encoding: .utf8)
  }

  /// The model of each CI reader judge call that the stub answered, oldest first.
  func ciJudgeCalls() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/ci-judge-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// The prompt of the last CI reader judge call.
  func ciJudgeInput() -> String {
    (try? String(contentsOfFile: "\(home.path)/ci-judge-input.txt", encoding: .utf8)) ?? ""
  }

  /// Makes gh-merge-stub print `runs` for `gh run list --repo <repo> --commit <head>`.
  func serveRuns(_ runs: [JSON], repo: String = MergeTests.charts, head: String) throws {
    try serveGh("run/\(repo)/commit/\(head)", .array(runs))
  }

  /// Makes gh-merge-stub print `log` for `gh run view <run> --repo <repo> --log-failed`.
  func serveFailedLog(_ log: String, repo: String = MergeTests.charts, run: Int) throws {
    try serveGhText("run/\(repo)/\(run)/log-failed.txt", log)
  }

  /// Makes gh-merge-stub refuse `gh run rerun <run> --repo <repo>` with `text` on stderr.
  func ghRerunFails(repo: String = MergeTests.charts, run: Int, with text: String) throws {
    try serveGhText("run/\(repo)/\(run)/rerun.error", text)
  }
}

/// A merge-armed session whose checks fail at one head on two ticks `operator.holdRetrySeconds` apart, while the
/// session is idle, gets a headless CI reader. sbd reads the failed runs with `gh run list --commit` and their logs with
/// `gh run view --log-failed`, asks the reader, and then sends the session the reader's summary (`real`, `timeout`),
/// reruns the failed runs once (`flake`), or raises a judgment message to the Operator. Fixtures/gh-merge-stub serves
/// the runs and the logs, and Fixtures/claude-stub answers the reader from `ci-judge-answer.json`.
///
/// `holdRetrySeconds` is 60, not a second or two: sbd ticks on real time, so a window that short would
/// pass on real ticks alone, and every check that the reader has not run yet would race. The tests move sbd's clock
/// instead.
///
/// The tests arm waits from the test runner, which counts as the user, so the Operator exists without a launch and
/// any `sent` event on it comes from sbd. Each arms the merge wait while the checks already fail, so the subject is
/// never Ready to merge and the merge action does not run.
@Suite(.blocking(timeLimit: .seconds(120))) struct CIReaderTests {
  let follow = FollowThroughTests()

  static let charts = MergeTests.charts
  static let number = MergeTests.number
  static let holdRetrySeconds = 60
  /// Past `holdRetrySeconds`.
  static let pastHoldRetry: Int64 = 61_000
  /// Past the default `github.idlePollSeconds` (300) plus `holdRetrySeconds`.
  static let pastIdlePollAndHoldRetry: Int64 = 361_000
  static let message = "parsesTitles() fails on a nil title in TitleParser.swift."
  /// The id of the failed run that the default setup serves.
  static let failed = 501
  /// The start of sbd's message to the session, before the short head.
  static let framing = "Switchboard: the checks on #\(number) failed at "
  static let reader = "sbd's CI reader, which read the failed logs, says: "
  static let nextStep =
    " Check this against the logs. If your change caused it, fix it and push. sbd runs the merge when the PR is Ready "
    + "to merge."
  static let failingLine = "✘ Test parsesTitles() failed"

  /// One run as `gh run list --json databaseId,name,workflowName,conclusion,status` prints it.
  static func run(_ id: Int, _ conclusion: String = "failure", workflow: String = "Swift CI") -> JSON {
    [
      "databaseId": .number(Double(id)), "name": .string(workflow), "workflowName": .string(workflow),
      "conclusion": .string(conclusion), "status": "completed",
    ]
  }

  /// A failed log as `gh run view --log-failed` prints it: the job, the step, and the timestamped text, split by tabs.
  static func log(_ line: String = failingLine, job: String = "swift-test") -> String {
    [
      "\(job)\tRun bin/test\t2026-11-19T10:00:00.0000000Z Building for debugging…",
      "\(job)\tRun bin/test\t2026-11-19T10:00:05.0000000Z \(line)",
    ].joined(separator: "\n") + "\n"
  }

  /// The line that gh-merge-stub logs for sbd's `gh run rerun` of `run`.
  static func rerunCall(_ run: Int) -> String { "run rerun \(run) --failed --repo \(charts)" }

  /// The start of each `gh run rerun` line in gh-merge-stub's call log, for `ghCalls`.
  static let reruns = "run rerun "

  static func operatorSettings(_ mergeRepos: [String]) -> JSON {
    ["mergeRepos": .array(mergeRepos.map(JSON.string)), "holdRetrySeconds": .number(Double(holdRetrySeconds))]
  }

  /// A private sbd with Fixtures/gh-merge-stub as its gh that merges in PostHog/charts. `config` replaces the whole
  /// `operator` object, so it carries `mergeRepos` too.
  func instance(_ github: FakeGitHub) throws -> Instance {
    try Instance.withMergeStub(github, config: ["operator": Self.operatorSettings([Self.charts])])
  }

  func head(_ github: FakeGitHub) -> String { follow.head(github) }

  /// A fix-cache on #18303's branch whose checks failed, idle in Needs you.
  func failingTarget(_ github: FakeGitHub, _ sbd: Instance) throws -> SessionSummary {
    github.checks(Self.number, "FAILURE")
    let s = try sbd.session(in: Self.charts, branch: MergeTests.branch, name: WaitActionTests.target)
    try sbd.poll()
    return try sbd.waitFor(s.id, "the failed checks on #18303") {
      $0.pr?.number == Self.number && $0.state == .needsYou
    }
  }

  /// `failingTarget` with `runs` served for the head and `log` for each failed run in `runs`, and a merge wait on it
  /// that the user armed. Nil `runs` or `log` serves nothing, so the read fails.
  func armedFailure(
    _ github: FakeGitHub, _ sbd: Instance, runs: [JSON]? = [CIReaderTests.run(CIReaderTests.failed)],
    log: String? = CIReaderTests.log()
  ) throws -> (s: SessionSummary, wait: String) {
    let s = try failingTarget(github, sbd)
    if let runs {
      try sbd.serveRuns(runs, head: head(github))
      if let log {
        for run in runs where ["failure", "timed_out"].contains(run["conclusion"]?.string ?? "") {
          try sbd.serveFailedLog(log, run: try #require(run["databaseId"]?.int))
        }
      }
    }
    let wait = try follow.arm(sbd, follow.arming.mergeArgs(s))
    return (s, wait)
  }

  func operatorsWait(_ sbd: Instance, _ id: String) throws -> Wait? { try follow.operatorsWait(sbd, id) }

  func ciCheck(_ sbd: Instance, _ wait: String) throws -> CICheck? { try operatorsWait(sbd, wait)?.ciCheck }

  /// Runs a tick and waits until the wait records the failure at `head` as seen, later than `after` when it is set.
  /// Returns when the failure was seen.
  @discardableResult
  func waitForSeen(_ sbd: Instance, _ wait: String, head: String, after: Int64? = nil) throws -> Int64 {
    try follow.tick(sbd)
    var since: Int64 = 0
    try sbd.waitFor("the CI reader to see the failure at \(head.prefix(7))", timeout: 30) {
      guard let check = try ciCheck(sbd, wait), check.head == head, check.step == .seen else { return false }
      if let after, check.since <= after { return false }
      since = check.since
      return true
    }
    return since
  }

  /// Sees the failure at `head`, then runs a tick past `holdRetrySeconds` later, which starts the reader.
  func failTwice(_ sbd: Instance, _ wait: String, head: String) throws {
    try waitForSeen(sbd, wait, head: head)
    try sbd.advanceClock(Self.pastHoldRetry)
  }

  func waitForCIJudgeCalls(_ sbd: Instance, _ count: Int) throws {
    try sbd.waitFor("CI judge call \(count)", timeout: 30) { sbd.ciJudgeCalls().count >= count }
  }

  /// sbd's messages to `s` that carry the CI reader's summary.
  func ciMessages(_ sbd: Instance, _ s: SessionSummary) throws -> [String] {
    try sbd.messagesFromSbd(s.id).filter { $0.hasPrefix(Self.framing) }
  }

  /// Waits for sbd's `count`th message to `s` that carries the CI reader's summary, and returns it.
  @discardableResult
  func ciMessage(_ sbd: Instance, _ s: SessionSummary, count: Int = 1) throws -> String {
    var found: [String] = []
    try sbd.waitFor("CI message \(count) to \(s.name)", timeout: 30) {
      found = try ciMessages(sbd, s)
      return found.count >= count
    }
    return found[count - 1]
  }

  /// sbd's judgment messages to the Operator about the wait `id` that offer no approval. The reply gate's question
  /// about the last reply offers `sb operator approve`, so it is not one of them.
  func ciJudgments(_ sbd: Instance, _ id: String) throws -> [String] {
    try follow.operatorMessages(sbd).filter {
      $0.contains("judgment needed for wait \(id)") && !$0.contains("sb operator approve")
    }.map {
      // Clearing the wait would cancel the merge that sbd still runs once the checks pass.
      #expect(!$0.contains("--clear"), Comment(rawValue: $0))
      return $0
    }
  }

  /// Waits for sbd's `count`th judgment message to the Operator about the wait `id` that offers no approval.
  @discardableResult
  func ciJudgment(_ sbd: Instance, _ id: String, count: Int = 1) throws -> String {
    var found: [String] = []
    try sbd.waitFor("CI judgment \(count) about \(id)", timeout: 30) {
      found = try ciJudgments(sbd, id)
      return found.count >= count
    }
    return found[count - 1]
  }

  /// The Operator's `judge` events of the CI reader, oldest first.
  func ciJudgeEvents(_ sbd: Instance) throws -> [Event] {
    try sbd.events(try follow.theOperator(sbd).id).filter {
      $0.kind == OperatorJudge.event && $0.data["kind"]?.string == "ci-failure"
    }
  }

  /// Moves the clock past `holdRetrySeconds` twice more with ticks between, so a reader that repeats would run again.
  func passMoreTicks(_ sbd: Instance) throws {
    for _ in 0..<2 {
      try sbd.advanceClock(Self.pastHoldRetry)
      try follow.tick(sbd, 2)
    }
  }

  /// Moves the clock past `holdRetrySeconds` twice with ticks between, for a case where the reader must not start.
  func passTwoWindows(_ sbd: Instance) throws {
    try follow.tick(sbd)
    try passMoreTicks(sbd)
  }

  /// Expects that the reader read nothing, asked nothing, and told nobody.
  func expectNoReader(
    _ sbd: Instance, _ s: SessionSummary, _ wait: String?, sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    #expect(sbd.ghCalls("run ").isEmpty, "\(sbd.ghCalls("run "))", sourceLocation: sourceLocation)
    #expect(sbd.ciJudgeCalls().isEmpty, "\(sbd.ciJudgeCalls())", sourceLocation: sourceLocation)
    #expect(try ciMessages(sbd, s).isEmpty, sourceLocation: sourceLocation)
    if let wait { #expect(try ciJudgments(sbd, wait).isEmpty, sourceLocation: sourceLocation) }
  }
}

// MARK: real and timeout

extension CIReaderTests {
  /// Decision 43: `real` and `timeout` send the subject the reader's summary, framed as the reader's, by sbd.
  @Test(arguments: ["real", "timeout"])
  func aFailureOnTwoTicksAtOneHeadSendsTheSessionTheFramedMessage(_ cause: String) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerCIJudge(cause)
    let (s, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    let text = try ciMessage(sbd, s)
    #expect(text.hasPrefix(Self.framing + head(github).prefix(7)), Comment(rawValue: text))
    #expect(text.contains(Self.reader + Self.message + Self.nextStep), Comment(rawValue: text))
  }

  /// Decision 42: nothing repeats for the same head across ticks.
  @Test(arguments: ["real", "timeout"])
  func theFramedMessageGoesOncePerHead(_ cause: String) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerCIJudge(cause)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)

    try passMoreTicks(sbd)

    let messages = try ciMessages(sbd, s)
    #expect(messages.count == 1, "\(messages)")
    #expect(sbd.ciJudgeCalls().count == 1, "\(sbd.ciJudgeCalls())")
  }

  /// A sent message records the head as judged on the wait. A `real` cause sends the Operator nothing and reruns
  /// nothing.
  @Test func aSentMessageRecordsTheHeadAsJudgedAndARealCauseSendsTheOperatorNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    try ciMessage(sbd, s)
    try sbd.waitFor("the judged step", timeout: 30) { try ciCheck(sbd, wait)?.step == .judged }
    #expect(try ciCheck(sbd, wait)?.head == head(github))
    try passMoreTicks(sbd)
    try follow.expectNoSentToOperator(sbd)
    #expect(sbd.ghCalls(Self.reruns).isEmpty, "\(sbd.ghCalls(Self.reruns))")
  }

  /// Decision 43: the reader reads the PR, the failed runs' workflow and job names, and their failed log lines.
  @Test func theReaderReadsThePRTheJobsAndTheirFailedLogLines() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    try waitForCIJudgeCalls(sbd, 1)
    let prompt = sbd.ciJudgeInput()
    for text in ["<ci-log", Self.failingLine, "swift-test", "Swift CI", "\(Self.charts)#\(Self.number)"] {
      #expect(prompt.contains(text), "\(text) in \(prompt)")
    }
    #expect(prompt.contains(head(github).prefix(7)), Comment(rawValue: prompt))
  }

  /// Decision 43: the reads are `gh run list --commit` at the head and `gh run view --log-failed` of the failed run.
  @Test func theReaderListsTheRunsAtTheHeadAndReadsTheFailedRunsLog() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFailure(github, sbd, runs: [Self.run(Self.failed), Self.run(503, "success")])

    try failTwice(sbd, wait, head: head(github))

    try waitForCIJudgeCalls(sbd, 1)
    let lists = sbd.ghCalls("run list ")
    let views = sbd.ghCalls("run view ")
    #expect(lists.count == 1 && lists.allSatisfy { $0.contains("--commit \(head(github))") }, "\(lists)")
    #expect(views.count == 1, "\(views)")
    #expect(views.allSatisfy { $0.contains("\(Self.failed)") && $0.contains("--log-failed") }, "\(views)")
  }

  /// Decision 39: each judge call records a `judge` event on the Operator. The token measurement reads `.data.inputTokens` and
  /// `.data.outputTokens`.
  @Test func aReaderCallRecordsACIFailureJudgeEventOnTheOperator() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    var events: [Event] = []
    try sbd.waitFor("the CI judge event", timeout: 30) {
      events = try ciJudgeEvents(sbd)
      return !events.isEmpty
    }
    expectJudgeEvent(events[0].data, session: s.id, wait: wait, head: head(github), answer: "real")
  }

  @Test func aReaderCallShowsInHeadlessUsageAsCIFailure() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    let row = try sbd.waitForHeadlessUsageRow("ciFailure", calls: 1)
    #expect(headlessUsage(row["usage"]) == stubUsage, Comment(rawValue: row.text))
  }
}

// MARK: Twice in a row on one head

extension CIReaderTests {
  /// Decision 41: the first tick that sees the failure records the head and reads nothing yet, so the session's own
  /// ci-monitor gets `holdRetrySeconds` to rerun or fix first.
  @Test func theFirstFailingTickRecordsTheHeadAsSeenAndReadsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)

    try waitForSeen(sbd, wait, head: head(github))

    try expectNoReader(sbd, s, wait)
  }

  @Test func aSecondTickWithinHoldRetrySecondsReadsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try waitForSeen(sbd, wait, head: head(github))

    try sbd.advanceClock(Self.pastHoldRetry - 31_000)
    try follow.tick(sbd, 2)

    try expectNoReader(sbd, s, wait)
    try sbd.advanceClock(31_000)
    try ciMessage(sbd, s)
  }

  /// Decision 41: a rollup that flips back to pending starts the count again. The failure at T, pending at T+31,
  /// and the failure again at about T+32 put the second tick at T+93 or later, not at T+60.
  @Test func pendingChecksBetweenTheTicksStartTheCountAgain() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    let first = try waitForSeen(sbd, wait, head: head(github))
    github.checks(Self.number, "PENDING")
    try sbd.advanceClock(30_000)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the checks running") { $0.state != .needsYou }
    try follow.tick(sbd)
    github.checks(Self.number, "FAILURE")
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the checks failing again") { $0.state == .needsYou }
    let again = try waitForSeen(sbd, wait, head: head(github), after: first)

    let now = try sbd.now()
    try sbd.advanceClock(first + Self.pastHoldRetry + 1_000 - now)
    try follow.tick(sbd, 2)
    try #require(try sbd.now() < again + Int64(Self.holdRetrySeconds) * 1000)

    try expectNoReader(sbd, s, wait)
    try sbd.advanceClock(Self.pastHoldRetry)
    try ciMessage(sbd, s)
  }

  /// Decision 41: the reader runs only while the subject's turn is not running. Once the turn ends, it runs.
  @Test func aSessionWhoseTurnRunsGetsNothingUntilTheTurnEnds() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try sbd.sb("send", s.id, "slow held")
    try sbd.waitFor(s.id, "the held turn", timeout: 30) { $0.state == .working }

    try passTwoWindows(sbd)

    try expectNoReader(sbd, s, wait)
    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    try sbd.waitFor(s.id, "the turn's end", timeout: 30) { $0.state == .needsYou }
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
  }

  /// Decision 41: only a subject whose PR is in `operator.mergeRepos` gets the reader. sbd reads config.json on each
  /// use, so the edit applies without a restart, and putting the repository back starts the reader.
  @Test func aSessionWhosePRIsNotInMergeReposGetsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try sbd.set("operator", to: Self.operatorSettings(["PostHog/other"]))

    try passTwoWindows(sbd)

    try expectNoReader(sbd, s, wait)
    try sbd.set("operator", to: Self.operatorSettings([Self.charts]))
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
  }

  /// Decision 41: the reader looks only at merge action waits. Arming one afterward starts it.
  @Test func aSessionWithFailingChecksAndNoMergeWaitGetsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try failingTarget(github, sbd)
    try sbd.serveRuns([Self.run(Self.failed)], head: head(github))
    try sbd.serveFailedLog(Self.log(), run: Self.failed)

    try passTwoWindows(sbd)

    try expectNoReader(sbd, s, nil)
    let wait = try follow.arm(sbd, follow.arming.mergeArgs(s))
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
  }

  /// Decision 42: a new head replaces the CI state, so a failure at the new head gets a reader of its own.
  @Test func aNewHeadGetsAReaderOfItsOwn() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
    try sbd.waitFor(s.id, "the reply to the message", timeout: 30) {
      $0.state == .needsYou && $0.lastReply?.contains(Self.framing) == true
    }
    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    try sbd.serveRuns([Self.run(601)], head: pushed)
    try sbd.serveFailedLog(Self.log("✘ Test parsesDates() failed"), run: 601)
    try sbd.poll(all: true)

    try failTwice(sbd, wait, head: pushed)

    let text = try ciMessage(sbd, s, count: 2)
    #expect(text.hasPrefix(Self.framing + pushed.prefix(7)), Comment(rawValue: text))
    #expect(sbd.ciJudgeInput().contains("✘ Test parsesDates() failed"), Comment(rawValue: sbd.ciJudgeInput()))
    #expect(sbd.ciJudgeCalls().count == 2, "\(sbd.ciJudgeCalls())")
  }

  /// A push while the reader reads the old head's runs makes its answer stale, so sbd drops it, sends nothing, and
  /// counts the new head from its first failure.
  @Test func aPushDuringTheReadDropsTheReadersAnswer() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    let gate = try StubGate("\(sbd.home.path)/gh-live/run/\(Self.charts)/commit/\(head(github)).gate")
    defer { gate.remove() }
    try failTwice(sbd, wait, head: head(github))
    try sbd.waitFor("the held run list", timeout: 30) { !sbd.ghCalls("run list ").isEmpty }

    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    try sbd.poll(all: true)
    try gate.pass()
    gate.remove()

    try sbd.waitFor("the CI judge event", timeout: 30) { try !ciJudgeEvents(sbd).isEmpty }
    try sbd.waitFor("the new head seen", timeout: 30) {
      try follow.tick(sbd)
      let check = try ciCheck(sbd, wait)
      return check?.head == pushed && check?.step == .seen
    }
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(try ciJudgments(sbd, wait).isEmpty)
  }

  /// A turn that starts while the reader reads makes its answer stale, because the session may fix the checks in that
  /// turn. sbd drops the answer: it tells the session nothing, reruns nothing, asks the Operator nothing, and records
  /// nothing as judged. The turn stays held to the end, so no later read starts.
  @Test(arguments: Path.allCases)
  func aTurnThatStartsDuringTheReadDropsTheReadersAnswer(_ path: Path) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armed(path, github, sbd)
    let gate = try StubGate("\(sbd.home.path)/gh-live/run/\(Self.charts)/commit/\(head(github)).gate")
    defer { gate.remove() }
    try failTwice(sbd, wait, head: head(github))
    try sbd.waitFor("the held run list", timeout: 30) { !sbd.ghCalls("run list ").isEmpty }

    try sbd.sb("send", s.id, "slow held")
    try sbd.waitFor(s.id, "the held turn", timeout: 30) { $0.state == .working }
    try gate.pass()
    gate.remove()

    // A tick skips the wait while the read runs, so the step leaves `seen` only after the read ends.
    try sbd.waitFor("the read's end", timeout: 30) {
      try follow.tick(sbd)
      return try ciCheck(sbd, wait)?.step != .seen
    }
    #expect(try ciCheck(sbd, wait) == nil)
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(try ciJudgments(sbd, wait).isEmpty)
    #expect(sbd.ghCalls(Self.reruns).isEmpty, "\(sbd.ghCalls(Self.reruns))")
  }

  /// Decision 42: the state is stored with the wait, so a restart does not send the message again. sbd's clock
  /// offset lives in memory and starts again at zero, so the test moves the clock past where it was before the
  /// restart. Without that, the stored `since` would be in the future and nothing would run for the wrong reason.
  @Test func aRestartDoesNotRepeatTheMessage() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
    try sbd.waitFor("the judged step", timeout: 30) { try ciCheck(sbd, wait)?.step == .judged }
    let before = try sbd.now()

    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.now()
    try sbd.advanceClock(max(before - after, 0) + Self.pastHoldRetry)
    try sbd.poll(all: true)
    try passMoreTicks(sbd)

    let messages = try ciMessages(sbd, s)
    #expect(messages.count == 1, "\(messages)")
    #expect(sbd.ciJudgeCalls().count == 1, "\(sbd.ciJudgeCalls())")
    #expect(try ciCheck(sbd, wait)?.step == .judged)
  }

  /// A run that hit its time limit counts as failed, so the reader reads its log and the session gets the summary.
  @Test func aTimedOutRunReachesTheReader() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerCIJudge("timeout")
    let (s, wait) = try armedFailure(github, sbd, runs: [Self.run(Self.failed, "timed_out")])

    try failTwice(sbd, wait, head: head(github))

    let text = try ciMessage(sbd, s)
    #expect(text.contains(Self.reader + Self.message + Self.nextStep), Comment(rawValue: text))
    #expect(sbd.ciJudgeInput().contains(Self.failingLine), Comment(rawValue: sbd.ciJudgeInput()))
  }

  /// A read in flight keeps the ticks during it from starting another read of the wait, so the wait gets one judge
  /// call.
  @Test func ticksDuringAReadStartNoSecondRead() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    let gate = try StubGate("\(sbd.home.path)/gh-live/run/\(Self.charts)/commit/\(head(github)).gate")
    defer { gate.remove() }
    try failTwice(sbd, wait, head: head(github))
    try sbd.waitFor("the held run list", timeout: 30) { !sbd.ghCalls("run list ").isEmpty }

    try follow.tick(sbd, 3)
    try gate.pass()
    gate.remove()

    try ciMessage(sbd, s)
    try follow.tick(sbd, 2)
    #expect(sbd.ghCalls("run list ").count == 1, "\(sbd.ghCalls("run list "))")
    #expect(sbd.ciJudgeCalls().count == 1, "\(sbd.ciJudgeCalls())")
  }
}

// MARK: flake

extension CIReaderTests {
  static let flakeRuns = [run(failed), run(502), run(503, "success")]

  /// `armedFailure` with the reader answering `flake` for two failed runs and one that passed.
  func armedFlake(_ github: FakeGitHub, _ sbd: Instance) throws -> (s: SessionSummary, wait: String) {
    try sbd.answerCIJudge("flake", message: "The runner lost its network during setup.")
    return try armedFailure(github, sbd, runs: Self.flakeRuns)
  }

  func waitForReruns(_ sbd: Instance, _ count: Int) throws {
    try sbd.waitFor("rerun \(count)", timeout: 30) { sbd.ghCalls(Self.reruns).count >= count }
  }

  /// `armedFlake`, the reruns, then the checks running again and failing again at the same head. With `pastWindow`,
  /// the clock then moves past `holdRetrySeconds`.
  func rerunThenFailAgain(_ github: FakeGitHub, _ sbd: Instance, pastWindow: Bool = true) throws -> (
    s: SessionSummary, wait: String
  ) {
    let (s, wait) = try armedFlake(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try waitForReruns(sbd, 2)
    github.checks(Self.number, "PENDING")
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the rerun's checks running") { $0.state != .needsYou }
    try follow.tick(sbd)
    github.checks(Self.number, "FAILURE")
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the rerun's checks failing") { $0.state == .needsYou }
    try follow.tick(sbd)
    if pastWindow { try sbd.advanceClock(Self.pastHoldRetry) }
    return (s, wait)
  }

  /// Decision 43: `flake` reruns each failed run once with `--failed`, and not the run that passed. It records the
  /// rerun on the wait and sends the session and the Operator nothing.
  @Test func aFlakeRerunsEachFailedRunOnceAndSendsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFlake(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    try waitForReruns(sbd, 2)
    try sbd.waitFor("the reran step", timeout: 30) { try ciCheck(sbd, wait)?.step == .reran }
    #expect(try ciCheck(sbd, wait)?.head == head(github))
    try passMoreTicks(sbd)
    let reruns = sbd.ghCalls(Self.reruns)
    #expect(reruns.sorted() == [Self.rerunCall(Self.failed), Self.rerunCall(502)], "\(reruns)")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    try follow.expectNoSentToOperator(sbd)
  }

  /// Decision 43: a second failure at the head after the rerun raises one judgment message to the Operator. The wait
  /// stores the rerun, so each head reruns once. The pending rollup between the two failures must not clear that
  /// record.
  @Test func aSecondFailureAfterTheRerunRaisesOneOperatorJudgmentAndRerunsNothingMore() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try rerunThenFailAgain(github, sbd)

    try ciJudgment(sbd, wait)

    try passMoreTicks(sbd)
    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.count == 1, "\(judgments)")
    #expect(sbd.ghCalls(Self.reruns).count == 2, "\(sbd.ghCalls(Self.reruns))")
    #expect(sbd.ciJudgeCalls().count == 1, "\(sbd.ciJudgeCalls())")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(try ciCheck(sbd, wait)?.step == .judged)
  }

  /// A second failure after the rerun waits `holdRetrySeconds`, so the session's own CI monitor gets that long to act.
  @Test func aSecondFailureAfterTheRerunWaitsHoldRetrySecondsBeforeTheJudgment() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try rerunThenFailAgain(github, sbd, pastWindow: false)

    try follow.tick(sbd, 2)
    #expect(try ciJudgments(sbd, wait).isEmpty)

    try sbd.advanceClock(Self.pastHoldRetry)
    try ciJudgment(sbd, wait)
  }

  /// A rerun that fails again before a PR read sees it running leaves the session's state as it was. sbd asks the
  /// Operator once the checks still fail one idle poll and `holdRetrySeconds` after the rerun.
  @Test func aRerunThatFailsAgainBeforeAReadRaisesOneOperatorJudgmentAfterAnIdlePoll() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFlake(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try waitForReruns(sbd, 2)
    try sbd.waitFor("the reran step", timeout: 30) { try ciCheck(sbd, wait)?.step == .reran }

    try passMoreTicks(sbd)
    #expect(try ciJudgments(sbd, wait).isEmpty)

    try sbd.advanceClock(Self.pastIdlePollAndHoldRetry)
    try ciJudgment(sbd, wait)
    try passMoreTicks(sbd)
    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.count == 1, "\(judgments)")
    #expect(sbd.ghCalls(Self.reruns).count == 2, "\(sbd.ghCalls(Self.reruns))")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(try ciCheck(sbd, wait)?.step == .judged)
  }

  /// The rerun passed, so nothing about CI reaches the session or the Operator.
  @Test func aRerunThatPassesRaisesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFlake(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try waitForReruns(sbd, 2)
    // The subject becomes Ready to merge, so the merge action's live reads must pass.
    try sbd.serve(LiveGitHub(github))

    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)
    try passMoreTicks(sbd)

    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.isEmpty, "\(judgments)")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(sbd.ghCalls(Self.reruns).count == 2, "\(sbd.ghCalls(Self.reruns))")
  }

  /// A push while gh reruns the old head's jobs makes gh's refusal about a head that no longer matters, so sbd asks
  /// the Operator nothing and counts the new head from its first failure. The clock stays within `holdRetrySeconds`
  /// of that failure, so any judgment would be about the old head.
  @Test func aRerunRefusalAfterAPushAsksTheOperatorNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerCIJudge("flake")
    try sbd.ghRerunFails(run: Self.failed, with: "HTTP 403: Resource not accessible by integration")
    let (_, wait) = try armedFailure(github, sbd)
    let gate = try StubGate("\(sbd.home.path)/gh-live/run/\(Self.charts)/\(Self.failed)/rerun.gate")
    defer { gate.remove() }
    try failTwice(sbd, wait, head: head(github))
    try waitForReruns(sbd, 1)

    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    try sbd.poll(all: true)
    try gate.pass()
    gate.remove()

    try sbd.waitFor("the new head seen", timeout: 30) {
      try follow.tick(sbd)
      let check = try ciCheck(sbd, wait)
      return check?.head == pushed && check?.step == .seen
    }
    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.isEmpty, "\(judgments)")
  }
}

// MARK: Raised to the Operator

extension CIReaderTests {
  /// Each way the reader can't decide, which raises a judgment message to the Operator once per head.
  enum Undecided: String, CaseIterable, CustomTestStringConvertible {
    case judgeFails = "the judge fails"
    case noFailedRun = "only a passing run"
    case noRuns = "no runs"
    case runListFails = "gh run list fails"
    case logReadFails = "gh run view fails"
    case rerunRefused = "gh refuses the rerun"

    var testDescription: String { rawValue }

    /// The CI judge calls that the case makes.
    var judgeCalls: Int { [.judgeFails, .rerunRefused].contains(self) ? 1 : 0 }
  }

  /// A merge wait on a failing fix-cache whose reader can't decide in the way `undecided` says.
  func armedUndecided(_ undecided: Undecided, _ github: FakeGitHub, _ sbd: Instance) throws -> (
    s: SessionSummary, wait: String
  ) {
    switch undecided {
    case .judgeFails:
      return try armedFailure(github, sbd, log: Self.log("✘ FAIL-CI-JUDGE"))
    case .noFailedRun:
      return try armedFailure(github, sbd, runs: [Self.run(503, "success")])
    case .noRuns:
      return try armedFailure(github, sbd, runs: [])
    case .runListFails:
      return try armedFailure(github, sbd, runs: nil)
    case .logReadFails:
      return try armedFailure(github, sbd, log: nil)
    case .rerunRefused:
      try sbd.answerCIJudge("flake")
      try sbd.ghRerunFails(run: Self.failed, with: "HTTP 403: Resource not accessible by integration")
      return try armedFailure(github, sbd)
    }
  }

  /// Decision 43: no failed run, a failed read, a judge failure, or a refused rerun raises one judgment message, and
  /// sends the session nothing.
  @Test(arguments: Undecided.allCases)
  func aReaderThatCannotDecideRaisesOneOperatorJudgmentAndSendsTheSessionNothing(_ undecided: Undecided) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedUndecided(undecided, github, sbd)
    try failTwice(sbd, wait, head: head(github))

    try ciJudgment(sbd, wait)

    try passMoreTicks(sbd)
    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.count == 1, "\(judgments)")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(sbd.ciJudgeCalls().count == undecided.judgeCalls, "\(sbd.ciJudgeCalls())")
    #expect(try ciCheck(sbd, wait)?.step == .judged)
  }

  /// Decision 38: no quota left on the judge's account raises one judgment message with no judge call. The case has
  /// its own sbd, because `triage.account` and the usage reader are set when sbd starts.
  @Test func noQuotaOnTheJudgesAccountRaisesOneOperatorJudgmentWithoutAJudgeCall() throws {
    let fake = try FakeUsage()
    // The limit resets in 2099, so it stays spent for the whole test.
    fake.reply(#"{"limits":[{"kind":"weekly_all","percent":100,"resets_at":"2099-01-01T00:00:00+00:00"}]}"#)
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(
      github, accounts: ["A"],
      config: [
        "operator": Self.operatorSettings([Self.charts]),
        "usage": ["url": .string(fake.url), "pollSeconds": 0, "keychain": false],
      ])
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "account": .string(sbd.account("A"))])
    try sbd.signIn("A", token: "token-a")
    _ = try sbd.usage()
    let (s, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    let text = try ciJudgment(sbd, wait)
    #expect(text.contains("sbd's CI reader did not run"), Comment(rawValue: text))
    #expect(sbd.ciJudgeCalls().isEmpty, "\(sbd.ciJudgeCalls())")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    withExtendedLifetime(fake) {}
  }

  /// Decision 44: the CI question names the PR and offers no approval, because no reply is being approved.
  @Test func theOperatorsCIJudgmentNamesThePRAndOffersNoApproval() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedUndecided(.judgeFails, github, sbd)
    try failTwice(sbd, wait, head: head(github))

    let text = try ciJudgment(sbd, wait)

    #expect(text.hasPrefix("Switchboard: judgment needed for wait \(wait)"), Comment(rawValue: text))
    #expect(text.contains("#\(Self.number)"), Comment(rawValue: text))
    #expect(!text.contains("sb operator approve"), Comment(rawValue: text))
  }

  @Test func aJudgeThatFailsRecordsTheErrorOnTheJudgeEvent() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedUndecided(.judgeFails, github, sbd)
    try failTwice(sbd, wait, head: head(github))

    try ciJudgment(sbd, wait)

    let event = try #require(try ciJudgeEvents(sbd).first)
    #expect(event.data["error"] != nil, Comment(rawValue: event.data.text))
    #expect(event.data["head"]?.string == head(github), Comment(rawValue: event.data.text))
  }

  /// A question that can't reach the Operator stays on the wait, and sbd sends it again once `holdRetrySeconds` have
  /// passed. The Operator's folder is gone at first, so its stopped claude can't start for the message.
  @Test func aCIJudgmentThatCannotReachTheOperatorGoesAgainAfterHoldRetrySeconds() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedUndecided(.judgeFails, github, sbd)
    let op = try follow.theOperator(sbd)
    // A running claude takes the message as a paste, which never checks the folder.
    try sbd.stop(op.id)
    let away = op.cwd + ".away"
    try FileManager.default.moveItem(atPath: op.cwd, toPath: away)
    try failTwice(sbd, wait, head: head(github))
    try sbd.waitFor("the judged step", timeout: 30) { try ciCheck(sbd, wait)?.step == .judged }
    try #require(try ciJudgments(sbd, wait).isEmpty)

    try FileManager.default.moveItem(atPath: away, toPath: op.cwd)
    try follow.tick(sbd, 2)
    #expect(try ciJudgments(sbd, wait).isEmpty)
    try sbd.advanceClock(Self.pastHoldRetry)

    try ciJudgment(sbd, wait)
    try passMoreTicks(sbd)
    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.count == 1, "\(judgments)")
  }

  /// A question that sbd could not send is about the failure, so checks that stop failing drop it. Pending checks
  /// keep the subject away from Ready to merge, so the merge action does not run.
  @Test func anUnsentCIJudgmentIsDroppedOnceTheChecksStopFailing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedUndecided(.judgeFails, github, sbd)
    let op = try follow.theOperator(sbd)
    try sbd.stop(op.id)
    let away = op.cwd + ".away"
    try FileManager.default.moveItem(atPath: op.cwd, toPath: away)
    try failTwice(sbd, wait, head: head(github))
    try sbd.waitFor("the unsent question", timeout: 30) { try ciCheck(sbd, wait)?.unsent != nil }

    github.checks(Self.number, "PENDING")
    try sbd.poll(all: true)
    try sbd.waitFor("the dropped question", timeout: 30) { try ciCheck(sbd, wait)?.unsent == nil }
    try FileManager.default.moveItem(atPath: away, toPath: op.cwd)
    try sbd.advanceClock(Self.pastHoldRetry)
    try passMoreTicks(sbd)

    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.isEmpty, "\(judgments)")
  }
}

// MARK: The merge action

extension CIReaderTests {
  enum Path: String, CaseIterable, CustomTestStringConvertible {
    case message, rerun, raise
    var testDescription: String { rawValue }
  }

  /// A merge wait on a failing fix-cache whose reader takes `path`.
  func armed(_ path: Path, _ github: FakeGitHub, _ sbd: Instance) throws -> (s: SessionSummary, wait: String) {
    switch path {
    case .message: try armedFailure(github, sbd)
    case .rerun: try armedFlake(github, sbd)
    case .raise: try armedUndecided(.judgeFails, github, sbd)
    }
  }

  /// Decision 44: the CI path never changes the merge wait's `actionStatus`, so a later Ready to merge still fires
  /// the merge action.
  @Test(arguments: Path.allCases)
  func theCIPathLeavesTheMergeActionsStatusAlone(_ path: Path) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armed(path, github, sbd)
    let before = try operatorsWait(sbd, wait)?.actionStatus

    try failTwice(sbd, wait, head: head(github))

    switch path {
    case .message: try ciMessage(sbd, s)
    case .rerun: try waitForReruns(sbd, 2)
    case .raise: try ciJudgment(sbd, wait)
    }
    try follow.tick(sbd, 2)
    #expect(try operatorsWait(sbd, wait)?.actionStatus == before)
  }

  /// A subject whose checks pass later still merges through the reply gate's path.
  @Test func aSubjectWhoseChecksPassLaterStillMerges() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
    try sbd.waitFor(s.id, "the reply to the message", timeout: 30) {
      $0.state == .needsYou && $0.lastReply?.contains(Self.framing) == true
    }
    try sbd.serve(LiveGitHub(github))
    try sbd.answerJudge("merge")

    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)

    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    try follow.tick(sbd, 2)
    #expect(sbd.ghMerges() == [follow.ghMerge(head(github))], "\(sbd.ghCalls())")
  }
}
