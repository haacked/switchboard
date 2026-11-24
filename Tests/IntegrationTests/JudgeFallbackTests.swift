import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// Makes the stub's reply gate judge answer with `answer`, `question`, and `reason`, as Fixtures/claude-stub
  /// reads `$SB_HOME/judge-answer.json`.
  func answerJudge(_ answer: String, question: String = "", reason: String = "The reply says so.") throws {
    let json: JSON = ["answer": .string(answer), "question": .string(question), "reason": .string(reason)]
    try json.text.write(toFile: "\(home.path)/judge-answer.json", atomically: true, encoding: .utf8)
  }

  /// The model of each reply gate judge call that the stub answered, oldest first.
  func judgeCalls() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/judge-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// The prompt of the last reply gate judge call.
  func judgeInput() -> String {
    (try? String(contentsOfFile: "\(home.path)/judge-input.txt", encoding: .utf8)) ?? ""
  }
}

/// A FIFO that a stub reads one line from before it answers, so each call that reaches it waits until the test
/// passes it. Fixtures/gh-merge-stub reads one at `<key>.gate` for a live read and at `gh-merge-gate` for a merge.
struct StubGate {
  let path: String

  init(_ path: String) throws {
    self.path = path
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard mkfifo(path, 0o600) == 0 else { throw TestError(description: "mkfifo \(path) failed") }
  }

  /// The gate of every compare read of the PR that `live` describes.
  init(compare live: LiveGitHub, in sbd: Instance) throws {
    try self.init("\(sbd.home.path)/gh-live/api/repos/\(live.repo)/compare/\(live.base)...\(live.head).gate")
  }

  /// The gate of every `gh pr merge`.
  init(mergeIn sbd: Instance) throws {
    try self.init("\(sbd.home.path)/gh-merge-gate")
  }

  /// Lets one waiting call go. A non-blocking open for writing fails until the call has opened the FIFO, so it
  /// tries again until then and the line is never lost.
  func pass(timeout: Double = 30) throws {
    let deadline = Date().addingTimeInterval(timeout * Instance.timeoutScale)
    while Date() < deadline {
      let writer = open(path, O_WRONLY | O_NONBLOCK)
      if writer >= 0 {
        _ = "go\n".withCString { write(writer, $0, 3) }
        close(writer)
        return
      }
      usleep(20_000)
    }
    throw TestError(description: "no call opened \(path)")
  }

  /// Removes the FIFO, so later calls run at once.
  func remove() { unlink(path) }
}

/// Expects the fields of a `judge` event that records one call that Fixtures/claude-stub answered with `answer`.
/// The token measurement reads `inputTokens` and `outputTokens`, so those names are fixed.
func expectJudgeEvent(
  _ data: JSON, session: String, wait: String, head: String, answer: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let comment = Comment(rawValue: data.text)
  #expect(data["session"]?.string == session, comment, sourceLocation: sourceLocation)
  #expect(data["wait"]?.string == wait, comment, sourceLocation: sourceLocation)
  #expect(data["head"]?.string == head, comment, sourceLocation: sourceLocation)
  #expect(data["model"]?.string == "sonnet", comment, sourceLocation: sourceLocation)
  #expect(data["inputTokens"]?.int == stubUsage.input, comment, sourceLocation: sourceLocation)
  #expect(data["outputTokens"]?.int == stubUsage.output, comment, sourceLocation: sourceLocation)
  #expect(data["answer"]?.string == answer, comment, sourceLocation: sourceLocation)
  #expect(data["error"] == nil, comment, sourceLocation: sourceLocation)
}

/// A merge action's question about the last reply goes to a one-shot `claude -p` judge first. `merge` merges through
/// the approval path, `ask` records a needs-you report about the subject, and anything else sends the Operator the
/// question that it would get without the judge. Fixtures/claude-stub answers the judge from `judge-answer.json`, and
/// `unsure` without one.
///
/// The tests arm waits from the test runner, which counts as the user, so the Operator exists without a launch and
/// any `sent` event on it comes from sbd.
@Suite(.blocking(timeLimit: .seconds(120))) struct JudgeFallbackTests {
  let follow = FollowThroughTests()

  static let charts = MergeTests.charts
  static let number = MergeTests.number
  static let question = "Drop the old table first?"
  /// The prompt and the reply that the subject's last turn gets in `askedAndAnsweredAgain`.
  static let newPrompt = "dropped the old table too"

  /// A private sbd with Fixtures/gh-merge-stub as its gh that merges in PostHog/charts. `config` replaces top-level
  /// keys of config.json. A `triage` key replaces Instance's, so it keeps `systemPrompt` empty.
  func instance(_ github: FakeGitHub, config: [String: JSON] = [:]) throws -> Instance {
    try Instance.withMergeStub(github, mergeRepos: [Self.charts], config: config)
  }

  /// `instance` with `triage.timeoutSeconds`, which the judge call uses.
  func instance(_ github: FakeGitHub, timeoutSeconds: Double) throws -> Instance {
    try instance(github, config: ["triage": ["systemPrompt": "", "timeoutSeconds": .number(timeoutSeconds)]])
  }

  func theOperator(_ sbd: Instance) throws -> SessionSummary { try follow.theOperator(sbd) }

  func head(_ github: FakeGitHub) -> String { follow.head(github) }

  /// A Ready to merge fix-cache on #18303 with every live read passing. With `prompt`, its last reply is the stub's
  /// reply to that prompt, `reply` or else "Done: <prompt>".
  func readyTarget(_ github: FakeGitHub, _ sbd: Instance, prompt: String? = nil, reply: String? = nil) throws
    -> SessionSummary
  {
    try sbd.serve(LiveGitHub(github))
    let s = try follow.arming.readyTarget(sbd)
    guard let prompt else { return s }
    let expected = reply ?? "Done: \(prompt)"
    try sbd.sb("send", s.id, prompt)
    return try sbd.waitFor(s.id, "the reply to \(prompt.prefix(20))", timeout: 30) {
      $0.lastReply == expected && $0.state == .readyToMerge
    }
  }

  /// Arms a merge wait on `s` from the user's terminal and returns the id of the wait that the Operator holds. The
  /// subject is Ready to merge, so the action runs at once.
  func arm(_ sbd: Instance, _ s: SessionSummary) throws -> String {
    try follow.arm(sbd, follow.arming.mergeArgs(s))
  }

  /// The pair that a question about `s`'s last reply at the PR's head covers.
  func pair(_ github: FakeGitHub, _ s: SessionSummary) -> MergeGuard.Approval {
    MergeGuard.Approval(head: head(github), replyDigest: MergeGuard.replyDigest(s.lastReply))
  }

  func status(_ sbd: Instance, _ wait: String) throws -> ActionStatus? {
    try follow.operatorsWait(sbd, wait)?.actionStatus
  }

  /// The Operator's `judge` events, oldest first.
  func judgeEvents(_ sbd: Instance) throws -> [Event] {
    try sbd.events(try theOperator(sbd).id).filter { $0.kind == "judge" }
  }

  /// Waits for the Operator's `count`th `judge` event and returns it.
  @discardableResult
  func judgeEvent(_ sbd: Instance, count: Int = 1) throws -> Event {
    var events: [Event] = []
    try sbd.waitFor("judge event \(count)", timeout: 30) {
      events = try judgeEvents(sbd)
      return events.count >= count
    }
    return events[count - 1]
  }

  func waitForJudgeCalls(_ sbd: Instance, _ count: Int) throws {
    try sbd.waitFor("judge call \(count)", timeout: 30) { sbd.judgeCalls().count >= count }
  }

  /// Waits until the run that started has ended, with the action no longer running.
  func waitForTheRunsEnd(_ sbd: Instance, _ wait: String) throws {
    try sbd.waitFor("the run's end", timeout: 30) { try status(sbd, wait)?.kind != .running }
  }

  /// Waits for the Operator's first report and returns every report that `sb operator reports --json` lists.
  func reportsOnceOneExists(_ sbd: Instance) throws -> [JSON] {
    var rows: [JSON] = []
    try sbd.waitFor("the report", timeout: 30) {
      rows = try follow.listedReports(sbd)
      return !rows.isEmpty
    }
    return rows
  }

  /// `count` ASCII characters of sentences, without a trailing space.
  static func reply(length count: Int) -> String {
    let words = String(repeating: "The work is done and nothing is open. ", count: count / 30 + 1)
    return String(words.prefix(count - 1)) + "!"
  }
}

// MARK: merge

extension JudgeFallbackTests {
  @Test func aMergeAnswerRunsOneGhMergeAtTheHead() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let s = try readyTarget(github, sbd)

    _ = try arm(sbd, s)

    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    try follow.tick(sbd, 3)
    #expect(sbd.ghMerges() == [follow.ghMerge(head(github))], "\(sbd.ghCalls())")
  }

  /// The Operator never wakes for a merge that the judge approved.
  @Test func aMergeAnswerSendsTheOperatorNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let s = try readyTarget(github, sbd)
    let wait = try arm(sbd, s)

    try sbd.waitFor("the wait to go", timeout: 30) { try follow.operatorsWait(sbd, wait) == nil }

    try follow.expectNoSentToOperator(sbd)
  }

  /// The token measurement reads `.data.inputTokens` and `.data.outputTokens`, so those names are fixed.
  @Test func aMergeAnswerRecordsAJudgeEventWithItsTokensAndModelOnTheOperator() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let s = try readyTarget(github, sbd)
    let wait = try arm(sbd, s)

    let event = try judgeEvent(sbd)

    let data = event.data
    #expect(data["kind"]?.string == "reply-gate", Comment(rawValue: data.text))
    expectJudgeEvent(data, session: s.id, wait: wait, head: head(github), answer: "merge")
    #expect(headlessUsage(data["usage"]) == stubUsage, Comment(rawValue: data.text))
  }

  @Test func theJudgeReadsTheLastReplyThePRAndTheSession() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try readyTarget(github, sbd, prompt: "wrote the runbook step")

    _ = try arm(sbd, s)

    try waitForJudgeCalls(sbd, 1)
    let prompt = sbd.judgeInput()
    #expect(prompt.contains("<session-reply>"), Comment(rawValue: prompt))
    #expect(prompt.contains("Done: wrote the runbook step"), Comment(rawValue: prompt))
    #expect(prompt.contains("\(Self.charts)#\(Self.number)"), Comment(rawValue: prompt))
    #expect(prompt.contains(WaitActionTests.target), Comment(rawValue: prompt))
  }

  /// sbd reads `operator.model` from config.json on each call, so an edit after sbd started applies.
  @Test func theJudgeRunsTheModelThatOperatorModelNamesWhenItRuns() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.set("operator", to: ["mergeRepos": [.string(Self.charts)], "model": "opus"])
    let s = try readyTarget(github, sbd)

    _ = try arm(sbd, s)

    let event = try judgeEvent(sbd)
    #expect(event.data["model"]?.string == "opus", Comment(rawValue: event.data.text))
    #expect(sbd.judgeCalls() == ["opus"])
  }

  /// Each judge call stores a `headless_calls` row of its own kind, which `sb usage headless` sums.
  @Test func aJudgeCallShowsInHeadlessUsageAsReplyGate() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try readyTarget(github, sbd)

    _ = try arm(sbd, s)

    let row = try sbd.waitForHeadlessUsageRow("replyGate", calls: 1)
    #expect(headlessUsage(row["usage"]) == stubUsage, Comment(rawValue: row.text))
    #expect(row["models"]?.array?.compactMap(\.string) == ["sonnet"], Comment(rawValue: row.text))
  }
}

// MARK: ask

extension JudgeFallbackTests {
  @Test func anAskAnswerRecordsOneOpenNeedsYouReportAboutTheSubjectWithTheQuestion() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("ask", question: Self.question)
    let s = try readyTarget(github, sbd)

    _ = try arm(sbd, s)

    let rows = try reportsOnceOneExists(sbd)
    try follow.tick(sbd, 2)
    let all = try follow.listedReports(sbd)
    #expect(all.count == 1, "\(all.map(\.text))")
    let row = try #require(rows.first)
    #expect(row["needsYou"]?.bool == true, Comment(rawValue: row.text))
    #expect(row["open"]?.bool == true, Comment(rawValue: row.text))
    #expect(row["about"]?.string == s.id, Comment(rawValue: row.text))
    #expect(row["text"]?.string?.contains(Self.question) == true, Comment(rawValue: row.text))
  }

  @Test func anAskAnswerSendsTheOperatorNothingAndMergesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("ask", question: Self.question)
    let s = try readyTarget(github, sbd)

    _ = try arm(sbd, s)

    _ = try reportsOnceOneExists(sbd)
    try follow.expectNoSentToOperator(sbd)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// Decision 37: the parked `ask` stores the pair it judged and the subject's `stateSince`, so a change of the
  /// subject's state runs the checks again.
  @Test func anAskAnswerParksTheWaitWithTheJudgedPairAndTheSubjectsStateSince() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("ask", question: Self.question)
    let s = try readyTarget(github, sbd)

    let wait = try arm(sbd, s)

    _ = try reportsOnceOneExists(sbd)
    try follow.waitForStatus(sbd, wait, .awaitingJudgment)
    let parked = try #require(try status(sbd, wait))
    #expect(parked.judged == pair(github, s), "\(parked)")
    #expect(parked.subjectSince != nil, "\(parked)")
  }

  /// Decision 36: the subject leaves Ready to merge and comes back at the same head with the same reply. The run
  /// that follows re-parks the `ask` without a second judge call or a second report. The ask shows on the subject
  /// and holds it in Needs you, so the user acknowledges it first.
  @Test func aSecondRunAtTheSameHeadAndReplyCallsTheJudgeOnce() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("ask", question: Self.question)
    let s = try readyTarget(github, sbd)
    let wait = try arm(sbd, s)
    _ = try reportsOnceOneExists(sbd)
    try follow.waitForStatus(sbd, wait, .awaitingJudgment)
    try sbd.waitFor(s.id, "the ask on the subject") { $0.state == .needsYou && $0.triage?.source == .report }
    try sbd.sb("ack", s.id)
    try sbd.waitFor(s.id, "Ready to merge after the ack") { $0.state == .readyToMerge }
    let reads = sbd.ghLiveReads().count
    let approved = github.pr(Self.number)

    github.change(Self.number) {
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
    }
    try sbd.advanceClock(1000)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "not Ready to merge") { $0.state != .readyToMerge }
    github.change(Self.number) {
      $0["reviewDecision"] = approved["reviewDecision"]!
      $0["latestOpinionatedReviews"] = approved["latestOpinionatedReviews"]!
    }
    try sbd.advanceClock(1000)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "Ready to merge again") { $0.state == .readyToMerge && $0.lastReply == s.lastReply }
    try follow.tick(sbd, 2)

    try sbd.waitFor("the second run's live reads", timeout: 30) { sbd.ghLiveReads().count > reads }
    try sbd.waitFor("the second run's end", timeout: 30) { try status(sbd, wait)?.kind == .awaitingJudgment }
    try follow.tick(sbd, 2)
    #expect(sbd.judgeCalls().count == 1, "\(sbd.judgeCalls())")
    #expect(try follow.listedReports(sbd).count == 1)
    try follow.expectNoSentToOperator(sbd)
  }

  /// Decision 37: the user answers the session, which replies again and returns to Ready to merge. The new digest
  /// gets a judge call of its own.
  @Test func aNewReplyAfterAnAskCallsTheJudgeAgainOnTheNewReply() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("ask", question: Self.question)
    let s = try readyTarget(github, sbd)
    let wait = try arm(sbd, s)
    _ = try reportsOnceOneExists(sbd)
    try follow.waitForStatus(sbd, wait, .awaitingJudgment)

    try sbd.sb("send", s.id, Self.newPrompt)
    try sbd.waitFor(s.id, "the new reply", timeout: 30) { $0.lastReply == "Done: \(Self.newPrompt)" }
    // The judge's question stays on the subject until the user answers or acknowledges it.
    try sbd.sb("ack", s.id)
    try sbd.waitFor(s.id, "Ready to merge after the ack", timeout: 30) { $0.state == .readyToMerge }
    try follow.tick(sbd, 2)

    try waitForJudgeCalls(sbd, 2)
    #expect(sbd.judgeInput().contains("Done: \(Self.newPrompt)"), Comment(rawValue: sbd.judgeInput()))
  }
}

// MARK: Back to the Operator

extension JudgeFallbackTests {
  /// The judge's reason follows the question as one sentence.
  @Test func anUnsureAnswerSendsTheOperatorTheQuestionWithTheJudgesReason() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("unsure", reason: "The reply lists a follow-up for the user")
    let s = try readyTarget(github, sbd)

    let wait = try arm(sbd, s)

    let text = try follow.judgment(sbd, about: wait)
    #expect(text.hasPrefix("Switchboard:"), Comment(rawValue: text))
    #expect(text.contains("The reply lists a follow-up for the user"), Comment(rawValue: text))
  }

  @Test func anApprovalAfterAnUnsureAnswerMergesWithoutAnotherJudgeCall() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("unsure")
    let s = try readyTarget(github, sbd)
    let wait = try arm(sbd, s)
    try follow.judgment(sbd, about: wait)

    let r = try follow.approve(sbd, wait)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    #expect(sbd.ghMerges() == [follow.ghMerge(head(github))], "\(sbd.ghCalls())")
    #expect(sbd.judgeCalls().count == 1, "\(sbd.judgeCalls())")
  }

  /// Decision 37: a question that went to the Operator stores no `subjectSince`, so it never retries on its own.
  @Test func anUnsureAnswerStoresTheJudgedPairAndNoSubjectSince() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try readyTarget(github, sbd)

    let wait = try arm(sbd, s)

    try follow.judgment(sbd, about: wait)
    let asked = try #require(try status(sbd, wait))
    #expect(asked.kind == .awaitingJudgment, "\(asked)")
    #expect(asked.judged == pair(github, s), "\(asked)")
    #expect(asked.subjectSince == nil, "\(asked)")
  }

  /// The schema allows only merge, ask, and unsure, so another word is a parse error.
  @Test func anUnknownAnswerWordSendsTheOperatorTheQuestion() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("yes")
    let s = try readyTarget(github, sbd)

    let wait = try arm(sbd, s)

    try follow.judgment(sbd, about: wait)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
    let event = try judgeEvent(sbd)
    #expect(event.data["error"] != nil, Comment(rawValue: event.data.text))
  }

  @Test func anAskWithAnEmptyQuestionSendsTheOperatorTheQuestion() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("ask", question: "")
    let s = try readyTarget(github, sbd)

    let wait = try arm(sbd, s)

    try follow.judgment(sbd, about: wait)
    #expect(try follow.listedReports(sbd).isEmpty)
  }

  @Test func aJudgeThatFailsSendsTheOperatorTheQuestionAndRecordsTheError() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let s = try readyTarget(github, sbd, prompt: "FAIL-JUDGE")

    let wait = try arm(sbd, s)

    try follow.judgment(sbd, about: wait)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
    let event = try judgeEvent(sbd)
    #expect(event.data["error"] != nil, Comment(rawValue: event.data.text))
    #expect(event.data["kind"]?.string == "reply-gate", Comment(rawValue: event.data.text))
  }

  @Test func aJudgeThatOutlastsTheTriageTimeoutSendsTheOperatorTheQuestion() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github, timeoutSeconds: 2)
    try sbd.answerJudge("merge")
    let s = try readyTarget(github, sbd, prompt: "SLOW-JUDGE")

    let wait = try arm(sbd, s)

    try follow.judgment(sbd, about: wait)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// Decision 33: the judge runs on `followThroughQueue`, never on the state queue. A request during the judge call
  /// returns while the action still runs. Were the judge on the state queue, the request would wait for the
  /// timeout and then for `finish`, which sends the question.
  @Test func sbdAnswersRequestsWhileTheJudgeRuns() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github, timeoutSeconds: 20)
    let s = try readyTarget(github, sbd, prompt: "SLOW-JUDGE")
    let wait = try arm(sbd, s)
    try waitForJudgeCalls(sbd, 1)

    _ = try sbd.client.sessions()

    #expect(try status(sbd, wait)?.kind == .running)
    #expect(try follow.operatorMessages(sbd).isEmpty)
  }

  /// Decision 35: the judge never reads part of a reply. A reply of `OperatorJudge.maxReply` characters goes to the
  /// judge, and one character more goes to the Operator with no judge call.
  @Test(arguments: zip([20_000, 20_001], [1, 0]))
  func aReplyLongerThanTwentyThousandCharactersSkipsTheJudge(_ length: Int, _ calls: Int) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let long = Self.reply(length: length)
    try long.write(toFile: "\(sbd.home.path)/long.md", atomically: true, encoding: .utf8)
    let s = try readyTarget(github, sbd, prompt: "reply long", reply: long)
    try #require(s.lastReply?.count == length)

    let wait = try arm(sbd, s)

    if calls == 0 {
      try follow.judgment(sbd, about: wait)
      #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
    } else {
      try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    }
    #expect(sbd.judgeCalls().count == calls, "\(sbd.judgeCalls())")
  }

  /// Decision 38: no quota left on the judge's account sends the question to the Operator with no judge call.
  /// `triage.account` names that account, and sbd reads it when it starts.
  @Test func noQuotaOnTheJudgesAccountSendsTheOperatorTheQuestionWithoutAJudgeCall() throws {
    let fake = try FakeUsage()
    // The limit resets in 2099, so it stays spent for the whole test.
    fake.reply(#"{"limits":[{"kind":"weekly_all","percent":100,"resets_at":"2099-01-01T00:00:00+00:00"}]}"#)
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(
      github, mergeRepos: [Self.charts], accounts: ["A"],
      config: ["usage": ["url": .string(fake.url), "pollSeconds": 0, "keychain": false]])
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "account": .string(sbd.account("A"))])
    try sbd.signIn("A", token: "token-a")
    _ = try sbd.usage()
    try sbd.answerJudge("merge")
    let s = try readyTarget(github, sbd)

    let wait = try arm(sbd, s)

    try follow.judgment(sbd, about: wait)
    #expect(sbd.judgeCalls().isEmpty, "\(sbd.judgeCalls())")
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
    withExtendedLifetime(fake) {}
  }

  /// Decision 33: only a question about the last reply goes to the judge. A hold past `operator.holdLimitSeconds`
  /// asks the Operator directly.
  @Test func aQuestionThatIsNotAboutTheReplyGoesToTheOperatorWithoutAJudgeCall() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let (_, wait) = try follow.settledBehindHold(github, sbd)
    try #require(try status(sbd, wait)?.subjectSince != nil)

    try sbd.advanceClock(21_600_001)

    let text = try follow.operatorMessage(sbd, holding: "still held after 6 h")
    #expect(text.contains(wait), Comment(rawValue: text))
    #expect(sbd.judgeCalls().isEmpty, "\(sbd.judgeCalls())")
    // Decision 37: the question stores no state of the subject, so a change of state never runs it on its own.
    let asked = try #require(try status(sbd, wait))
    #expect(asked.kind == .awaitingJudgment, "\(asked)")
    #expect(asked.subjectSince == nil, "\(asked)")
  }
}

// MARK: The head and the reply that the judge read

extension JudgeFallbackTests {
  /// The judge answered `merge` for head H1. A push moves the head to H2 while the merge run's live reads run, so
  /// `takeForMerge` finds a different head and holds.
  @Test func aMergeAnswerWhoseHeadMovesBeforeTheMergeMergesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let live = LiveGitHub(github)
    let gate = try StubGate(compare: live, in: sbd)
    defer { gate.remove() }
    let s = try readyTarget(github, sbd)
    let wait = try arm(sbd, s)
    try sbd.waitFor("the first run's compare read", timeout: 30) { follow.compareReads(sbd) >= 1 }
    try gate.pass()
    try sbd.waitFor("the merge run's compare read", timeout: 30) { follow.compareReads(sbd) >= 2 }
    try #require(sbd.judgeCalls().count == 1, "\(sbd.judgeCalls())")
    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    try sbd.poll(all: true)
    try sbd.answerJudge("unsure")

    try gate.pass()

    try waitForTheRunsEnd(sbd, wait)
    let held = try #require(try status(sbd, wait))
    #expect(held.kind == .held, "\(held)")
    #expect(held.reason?.contains("moved") == true, "\(held)")
    try follow.tick(sbd, 2)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// The session replies again while the run's live reads run, so the run's question covers a reply that is no
  /// longer the last. The judge reads only the new reply, and the `ask` parks on its digest. Were the judge to read
  /// the old reply, the park would store the state that the new reply brought and never run the checks again.
  @Test func aReplyDuringTheLiveReadsReachesTheJudgeInPlaceOfTheOldOne() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("ask", question: Self.question)
    let gate = try StubGate(compare: LiveGitHub(github), in: sbd)
    defer { gate.remove() }
    let s = try readyTarget(github, sbd)
    let wait = try arm(sbd, s)
    try sbd.waitFor("the first run's compare read", timeout: 30) { follow.compareReads(sbd) >= 1 }
    let newReply = "Done: \(Self.newPrompt)"
    try sbd.sb("send", s.id, Self.newPrompt)
    try sbd.waitFor(s.id, "the new reply", timeout: 30) { $0.lastReply == newReply && $0.state == .readyToMerge }

    try gate.pass()
    gate.remove()

    try follow.waitForStatus(sbd, wait, .awaitingJudgment)
    let parked = try #require(try status(sbd, wait))
    #expect(
      parked.judged == MergeGuard.Approval(head: head(github), replyDigest: MergeGuard.replyDigest(newReply)),
      "\(parked)")
    #expect(sbd.judgeCalls().count == 1, "\(sbd.judgeCalls())")
    #expect(sbd.judgeInput().contains(newReply), Comment(rawValue: sbd.judgeInput()))
  }

  /// After a judge answer, sbd merges only at the head that the judge read. The head moves to H2
  /// after the first run read H1, so the judge's `merge` for H1 merges nothing, and the merge lands only after a
  /// second judge call reads H2.
  @Test func aJudgesMergeLandsOnlyAtTheHeadThatTheJudgeRead() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerJudge("merge")
    let first = head(github)
    let gate = try StubGate(compare: LiveGitHub(github), in: sbd)
    defer { gate.remove() }
    let s = try readyTarget(github, sbd)
    _ = try arm(sbd, s)
    try sbd.waitFor("the first run's compare read", timeout: 30) { follow.compareReads(sbd) >= 1 }
    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    var moved = LiveGitHub(github)
    moved.head = pushed
    try sbd.serve(moved)
    try sbd.poll(all: true)

    try gate.pass()
    gate.remove()

    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    try follow.tick(sbd, 2)
    #expect(sbd.ghMerges() == [follow.ghMerge(pushed)], "\(sbd.ghCalls())")
    #expect(try judgeEvents(sbd).map { $0.data["head"]?.string } == [first, pushed])
  }

  enum ApprovalPath: String, CaseIterable, CustomTestStringConvertible {
    case judge, `operator`
    var testDescription: String { rawValue }
  }

  /// The judge's `merge` and `sb operator approve` reach `gh pr merge` with the same approval, the head
  /// and the digest of the last reply. The merge gate holds `gh pr merge` while the test reads the approval that the
  /// run carries.
  @Test(arguments: ApprovalPath.allCases)
  func bothApprovalPathsMergeWithTheSameApproval(_ path: ApprovalPath) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let gate: StubGate
    let wait: String
    let s: SessionSummary
    switch path {
    case .judge:
      try sbd.answerJudge("merge")
      gate = try StubGate(mergeIn: sbd)
      s = try readyTarget(github, sbd)
      wait = try arm(sbd, s)
    case .operator:
      try sbd.answerJudge("unsure")
      s = try readyTarget(github, sbd)
      wait = try arm(sbd, s)
      try follow.judgment(sbd, about: wait)
      gate = try StubGate(mergeIn: sbd)
      let r = try follow.approve(sbd, wait)
      try #require(r.status == 0, Comment(rawValue: r.stderr))
    }
    defer { gate.remove() }

    try sbd.waitFor("gh pr merge", timeout: 30) { !sbd.ghMerges().isEmpty }

    let running = try #require(try status(sbd, wait))
    #expect(running.approval == pair(github, s), "\(running)")
    try gate.pass()
    try sbd.waitFor("the wait to go", timeout: 30) { try follow.operatorsWait(sbd, wait) == nil }
    #expect(sbd.ghMerges() == [follow.ghMerge(head(github))], "\(sbd.ghCalls())")
  }
}
