import Foundation
import SwitchboardCore
import Testing

/// The live GitHub answers that a merge action reads for one PR, which Fixtures/gh-merge-stub serves from files in
/// `$SB_HOME/gh-live`. The default answers pass every check: the PR is open, mergeable, and green at the poller's
/// head, its head contains the base, and the base tip is green.
struct LiveGitHub {
  var repo = MergeTests.charts
  var number: Int
  var head: String
  var state = "OPEN"
  var draft = false
  var mergeable = "MERGEABLE"
  var base = "main"
  /// The conclusion of the PR head's one check run: SUCCESS, FAILURE, or PENDING for a run in progress.
  var checks = "SUCCESS"
  var behindBy = 0
  var baseTip = FakeGitHub.sha(9001)
  /// The base tip's rollup: SUCCESS, FAILURE, or PENDING.
  var baseChecks = "SUCCESS"
  var files = ["docs/runbooks/cdp-dead-letter.md"]
  /// The `mergeCommit` that `gh pr view` prints for the PR. nil leaves the field out.
  var mergeCommit: String?

  /// The answers for PR `number` as `github` records it, so the live head is the poller's head.
  init(_ github: FakeGitHub, number: Int = MergeTests.number) {
    self.number = number
    head = MergeTests().head(github, number)
  }

  /// One check run as `gh pr view --json statusCheckRollup` prints it.
  static func checkRun(_ checks: String) -> JSON {
    checks == "PENDING"
      ? ["__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "IN_PROGRESS", "conclusion": ""]
      : [
        "__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "COMPLETED",
        "conclusion": .string(checks),
      ]
  }

  /// The files that the stub serves, by key: `pr/<repo>/<number>` for `gh pr view`, and `api/<path>` for `gh api`.
  /// The base tip's rollup is served both as check runs and as a combined status, for the tip's sha and for the
  /// base branch's name, and the base branch's tip is served from `commits/<base>` and `branches/<base>`.
  var answers: [String: JSON] {
    let rest = "api/repos/\(repo)"
    let lower = baseChecks.lowercased()
    let completed = baseChecks != "PENDING"
    var pr: [String: JSON] = [
      "number": .number(Double(number)), "url": .string("https://github.com/\(repo)/pull/\(number)"),
      "headRefOid": .string(head), "state": .string(state), "isDraft": .bool(draft),
      "mergeable": .string(mergeable), "baseRefName": .string(base),
      "statusCheckRollup": [LiveGitHub.checkRun(checks)],
    ]
    if let mergeCommit { pr["mergeCommit"] = ["oid": .string(mergeCommit)] }
    var answers: [String: JSON] = [
      "pr/\(repo)/\(number)": .object(pr),
      "\(rest)/compare/\(base)...\(head)": [
        "status": .string(behindBy == 0 ? "ahead" : "diverged"), "ahead_by": 1, "behind_by": .number(Double(behindBy)),
        "base_commit": ["sha": .string(baseTip)], "merge_base_commit": ["sha": .string(FakeGitHub.sha(9000))],
      ],
      "\(rest)/pulls/\(number)/files": .array(
        files.map { file -> JSON in
          ["filename": .string(file), "status": "modified", "additions": 3, "deletions": 1]
        }),
      "\(rest)/commits/\(base)": ["sha": .string(baseTip)],
      "\(rest)/branches/\(base)": ["name": .string(base), "commit": ["sha": .string(baseTip)]],
    ]
    for ref in [baseTip, base] {
      answers["\(rest)/commits/\(ref)/check-runs"] = [
        "total_count": 1,
        "check_runs": [
          [
            "name": "test", "status": .string(completed ? "completed" : "in_progress"),
            "conclusion": completed ? .string(lower) : .null, "head_sha": .string(baseTip),
          ]
        ],
      ]
      answers["\(rest)/commits/\(ref)/status"] = [
        "state": .string(lower), "sha": .string(baseTip), "total_count": 1,
        "statuses": [["context": "ci", "state": .string(lower)]],
      ]
    }
    return answers
  }
}

extension Instance {
  /// Makes gh-merge-stub print `json` for the call that it keys as `key`.
  func serveGh(_ key: String, _ json: JSON) throws {
    try serveGhText("\(key).json", json.text)
  }

  /// Writes `text` to `path` under gh-merge-stub's `gh-live` folder. `path` carries the file's extension, such as
  /// `.json`, `.txt`, or `.error`.
  func serveGhText(_ path: String, _ text: String) throws {
    let file = "\(home.path)/gh-live/\(path)"
    try FileManager.default.createDirectory(
      atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: file, atomically: true, encoding: .utf8)
  }

  /// Serves every live read of one PR's merge action.
  func serve(_ live: LiveGitHub) throws {
    for (key, json) in live.answers { try serveGh(key, json) }
  }

  /// The live reads that the stub ran, oldest first: `gh pr view` and every `gh api` call but GraphQL.
  func ghLiveReads() -> [String] {
    ghCalls().filter { $0.hasPrefix("pr view ") || ($0.hasPrefix("api ") && !$0.hasPrefix("api graphql")) }
  }
}

/// When an action wait's condition is met, sbd runs the action with its checks, records the
/// result, and raises anything that needs judgment. A merge always asks the Operator one question about the last
/// reply first, so the merge tests answer it with `sb operator approve` from the Operator's pane.
///
/// The tests arm waits from the test runner, which counts as the user, so the Operator exists without a launch and
/// any `sent` event on it comes from sbd.
@Suite(.blocking(timeLimit: .seconds(120))) struct FollowThroughTests {
  let arming = WaitActionTests()
  let operatorHelpers = OperatorTests()

  static let charts = MergeTests.charts
  static let number = MergeTests.number
  static let mergeMain = "Merge origin/main into your branch, resolve any conflicts, run the tests, and push."
  static let note = "tell the user to run bin/update"
  /// Past `operator.holdRetrySeconds`, whose default is 120.
  static let pastHoldRetry: Int64 = 121_000

  func instance(_ github: FakeGitHub) throws -> Instance { try arming.instance(github) }

  func theOperator(_ sbd: Instance) throws -> SessionSummary { try arming.theOperator(sbd) }

  func head(_ github: FakeGitHub, _ number: Int = MergeTests.number) -> String { MergeTests().head(github, number) }

  func ghMerge(_ head: String, _ number: Int = MergeTests.number) -> String {
    "pr merge \(number) --repo \(Self.charts) --merge --match-head-commit \(head)"
  }

  /// Arms the wait from the user's terminal for the conversation `c`, or for a new conversation when `c` is nil, and
  /// returns the id of the wait that the Operator holds.
  func arm(_ sbd: Instance, _ args: [String], from c: SessionSummary? = nil) throws -> String {
    let conversation = try c ?? arming.conversation(sbd)
    let r = try sbd.run(["wait", "--json", conversation.id] + args)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    return try arming.operatorsLastWait(sbd).id
  }

  /// The Operator's wait with `id`, or nil when it is gone.
  func operatorsWait(_ sbd: Instance, _ id: String) throws -> Wait? {
    try theOperator(sbd).waits.first { $0.id == id }
  }

  /// Waits until the Operator's wait `id` has an action status of `kind`.
  func waitForStatus(_ sbd: Instance, _ id: String, _ kind: ActionStatus.Kind) throws {
    try sbd.waitFor("wait \(id) to be \(kind.rawValue)", timeout: 30) {
      try operatorsWait(sbd, id)?.actionStatus?.kind == kind
    }
  }

  /// The texts of the messages that sbd itself sent to the Operator.
  func operatorMessages(_ sbd: Instance) throws -> [String] { try sbd.messagesFromSbd(try theOperator(sbd).id) }

  /// Waits for sbd's `count`th message to the Operator that asks about the wait `id` with its approve command, and
  /// returns it.
  @discardableResult
  func judgment(_ sbd: Instance, about id: String, count: Int = 1) throws -> String {
    var asked: [String] = []
    try sbd.waitFor("judgment message \(count) about \(id)", timeout: 30) {
      asked = try operatorMessages(sbd).filter { $0.contains("sb operator approve \(id)") }
      return asked.count >= count
    }
    return asked[count - 1]
  }

  /// Waits for sbd's message to the Operator that holds `text`, and returns it.
  @discardableResult
  func operatorMessage(_ sbd: Instance, holding text: String) throws -> String {
    var found: String?
    try sbd.waitFor("the Operator's message holding \"\(text)\"", timeout: 30) {
      found = try operatorMessages(sbd).first { $0.contains(text) }
      return found != nil
    }
    return found!
  }

  /// Runs `sb operator approve <id>` in the Operator's pane. Each call needs its own `name`, because a script's
  /// result file stays after it ran.
  func approve(_ sbd: Instance, _ id: String, name: String = "approve") throws -> CommandResult {
    try arming.sbInPane(sbd, of: try theOperator(sbd), ["operator", "approve", id], name: name)
  }

  /// Moves sbd's clock by one tick `count` times. Each clock request runs a tick.
  func tick(_ sbd: Instance, _ count: Int = 1) throws {
    for _ in 0..<count { try sbd.advanceClock(1000) }
  }

  /// A Ready to merge fix-cache on #18303, every live read passing, and a merge wait on it that the conversation
  /// handed to the Operator. Returns the session and the wait's id once sbd has asked the Operator.
  func askedMerge(_ github: FakeGitHub, _ sbd: Instance, live: LiveGitHub? = nil) throws -> (
    s: SessionSummary, wait: String
  ) {
    try sbd.serve(live ?? LiveGitHub(github))
    let s = try arming.readyTarget(sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))
    try judgment(sbd, about: wait)
    return (s, wait)
  }

  /// `askedMerge`, then the Operator's approval, then the merge.
  func approvedMerge(_ github: FakeGitHub, _ sbd: Instance) throws -> (s: SessionSummary, wait: String) {
    let (s, wait) = try askedMerge(github, sbd)
    let r = try approve(sbd, wait)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    return (s, wait)
  }

  /// Marks #18303 merged on the fake GitHub, with `head` as its head when it is set.
  func mergeOnGitHub(_ github: FakeGitHub, head: String? = nil) {
    github.change(MergeTests.number) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = "2026-10-26T00:00:00Z"
      if let head { $0["headRefOid"] = .string(head) }
    }
  }

  /// A session in a worktree that sbd made on #18303's branch of a PostHog/charts checkout, whose origin is a bare
  /// repo in the home. Its one commit is pushed, so only the PR's state and the worktree's files decide `remove`.
  func chartsWorktreeSession(_ sbd: Instance) throws -> SessionSummary {
    let url = "https://github.com/\(Self.charts).git"
    let repo = try Repos.create("\(sbd.home.path)/charts", origin: url)
    let origin = "\(sbd.home.path)/charts-origin.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", origin)
    try sbd.git(repo, "config", "url.\(origin).insteadOf", url)
    try sbd.git(repo, "push", "-q", "origin", "main")
    let s = try sbd.worktreeSession(repo, branch: MergeTests.branch)
    try sbd.commit(s.cwd, "runbook.md")
    try sbd.git(s.cwd, "push", "-q", "origin", MergeTests.branch)
    try sbd.poll()
    return try sbd.waitFor(s.id, "the poller's read of #18303") { $0.pr?.number == MergeTests.number }
  }

  /// Merges #18303 on the fake GitHub at the worktree's tip, polls, and waits until the session is Done.
  func mergeAndWaitForDone(_ github: FakeGitHub, _ sbd: Instance, _ s: SessionSummary) throws {
    mergeOnGitHub(github, head: try sbd.git(s.cwd, "rev-parse", "HEAD"))
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "Done") { $0.state == .done }
  }

  func sessionIds(_ sbd: Instance) throws -> [String] { try sbd.client.sessions().map(\.id) }

  /// A successful `rm`, `rm-worktree`, or `report` records no `sent` event on the Operator, so it never wakes. Two
  /// ticks first give a late message the time to show.
  func expectNoSentToOperator(_ sbd: Instance, sourceLocation: SourceLocation = #_sourceLocation) throws {
    try tick(sbd, 2)
    let sent = try sbd.events(try theOperator(sbd).id).filter { $0.kind == "sent" }
    #expect(sent.isEmpty, "\(sent.map(\.data.text))", sourceLocation: sourceLocation)
  }

  func reportEvents(_ sbd: Instance) throws -> [Event] {
    try sbd.events(try theOperator(sbd).id).filter { $0.kind == OperatorReport.event }
  }

  /// The Operator's `wait-resolved` event for the wait `id`.
  func resolvedEvent(_ sbd: Instance, _ id: String) throws -> Event? {
    try arming.handoff.waitEvent(sbd, try theOperator(sbd).id, "wait-resolved", wait: id)
  }
}

// MARK: The question about the last reply

extension FollowThroughTests {
  @Test func aMetMergeWaitAsksTheOperatorWithTheWaitThePRTheHeadAndTheApproveCommand() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)

    let (_, wait) = try askedMerge(github, sbd)

    let text = try judgment(sbd, about: wait)
    #expect(text.hasPrefix("Switchboard:"), Comment(rawValue: text))
    #expect(text.contains(wait), Comment(rawValue: text))
    #expect(text.contains("#\(Self.number)"), Comment(rawValue: text))
    #expect(text.contains(head(github).prefix(7)), Comment(rawValue: text))
    #expect(text.contains("sb operator approve \(wait)"), Comment(rawValue: text))
  }

  /// The Operator gets one question, and nothing merges while the question is open.
  @Test func nothingMergesBeforeTheOperatorApprovesAndSbdAsksOnce() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)

    try tick(sbd, 5)

    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
    let messages = try operatorMessages(sbd)
    #expect(messages.count == 1, "\(messages)")
    #expect(try operatorsWait(sbd, wait) != nil)
  }

  @Test func theQuestionPutsTheWaitInAwaitingJudgment() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)

    let (_, wait) = try askedMerge(github, sbd)

    #expect(try operatorsWait(sbd, wait)?.actionStatus?.kind == .awaitingJudgment)
  }

  /// `callerArg` reads SB_SESSION_ID, which a work session can set to the Operator's id. Only the pane counts.
  @Test func approvalFromAWorkPaneWithTheOperatorsIdIsRefusedAndMergesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    let op = try theOperator(sbd)
    let worker = try sbd.idleSession(name: "worker")

    let r = try arming.sbInPane(
      sbd, of: worker, ["operator", "approve", wait], env: ["SB_SESSION_ID": op.id], name: "spoofed-approve")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    try tick(sbd, 2)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
    #expect(try operatorsWait(sbd, wait) != nil)
  }

  /// Only the Operator's pane may approve, so the user's terminal can't either.
  @Test func approvalFromOutsideEveryPaneWithTheOperatorsIdIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    let op = try theOperator(sbd)

    let r = try sbd.run(["operator", "approve", wait], env: ["SB_SESSION_ID": op.id])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    try tick(sbd, 2)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// The wait's target is not Ready to merge, so sbd never asked. An approval has nothing to answer.
  @Test func approvalOfAWaitThatIsNotAwaitingJudgmentIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.serve(LiveGitHub(github))
    let s = try arming.notReadyTarget(github, sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))
    _ = try operatorHelpers.idleOperator(sbd)

    let r = try approve(sbd, wait)

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  @Test func theMCPApproveToolFromTheOperatorsPaneMerges() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)

    let result = try arming.toolInPane(sbd, of: try theOperator(sbd), "approve", ["wait": .string(wait)], name: "mcp")

    #expect(!result.isError, Comment(rawValue: result.text))
    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    #expect(sbd.ghMerges() == [ghMerge(head(github))])
  }

  @Test func theMCPApproveToolFromAWorkSessionsServerWithTheOperatorsIdIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    let op = try theOperator(sbd)
    let worker = try sbd.idleSession(name: "worker")

    let result = try arming.toolInPane(
      sbd, of: worker, "approve", ["wait": .string(wait)], env: ["SB_SESSION_ID": op.id], name: "mcp")

    #expect(result.isError, Comment(rawValue: result.text))
    try tick(sbd, 2)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }
}

// MARK: The approved merge

extension FollowThroughTests {
  @Test func anApprovedMergeRunsOneGhMergeWithMatchHeadCommit() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)

    _ = try approvedMerge(github, sbd)

    try tick(sbd, 3)
    #expect(sbd.ghMerges() == [ghMerge(head(github))], "\(sbd.ghCalls())")
  }

  @Test func anApprovedMergeRecordsMergeAndFollowThroughOnTheSession() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)

    let (s, wait) = try approvedMerge(github, sbd)

    let follow = try sbd.waitFor(
      "the follow-through event", timeout: 30,
      fetch: { try sbd.events(s.id).last { $0.kind == "follow-through" } }, until: { _ in true })
    #expect(follow.data["wait"]?.string == wait, Comment(rawValue: follow.data.text))
    #expect(follow.data["action"]?.string == "merge", Comment(rawValue: follow.data.text))
    let merges = try sbd.events(s.id).filter { $0.kind == "merge" }
    #expect(merges.count == 1)
    #expect(merges.first?.data["result"]?.string == "merged", Comment(rawValue: merges.first?.data.text ?? ""))
    #expect(merges.first?.data["head"]?.string == head(github))
  }

  @Test func anApprovedMergeResolvesTheWaitWithItsActionAndAnInfoReport() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)

    let (_, wait) = try approvedMerge(github, sbd)

    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    let resolved = try #require(try resolvedEvent(sbd, wait))
    #expect(resolved.data["action"]?["kind"]?.string == "merge", Comment(rawValue: resolved.data.text))
    #expect(resolved.data["action"]?["result"]?.string == "merged", Comment(rawValue: resolved.data.text))
    let report = try #require(try reportEvents(sbd).last)
    #expect(report.data["needsYou"]?.bool != true, Comment(rawValue: report.data.text))
    #expect(report.data["text"]?.string?.contains("#\(Self.number)") == true, Comment(rawValue: report.data.text))
  }

  /// The question is the only message sbd sends the Operator for a merge that goes through.
  @Test func anApprovedMergeSendsTheOperatorOnlyTheQuestion() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)

    let (_, wait) = try approvedMerge(github, sbd)

    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    try tick(sbd, 2)
    let messages = try operatorMessages(sbd)
    #expect(messages.count == 1, "\(messages)")
    #expect(messages.first?.contains("sb operator approve \(wait)") == true, "\(messages)")
  }

  /// `sb merge` parity: the action lands the PR through `landPR`, so the session gets `sb merge`'s message.
  @Test func anApprovedMergeResumesTheSessionAsSbMergeDoes() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)

    let (s, _) = try approvedMerge(github, sbd)

    try sbd.waitFor("the post-merge message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id) == [MergeTests.message])
  }
}

// MARK: Asking again

extension FollowThroughTests {
  /// A push after the question: the approval covered the old head, so sbd asks about the new one.
  @Test func aPushAfterTheQuestionMakesSbdAskAgainAndMergeNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    var live = LiveGitHub(github)
    live.head = pushed
    try sbd.serve(live)
    try sbd.poll(all: true)

    let r = try approve(sbd, wait)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let again = try judgment(sbd, about: wait, count: 2)
    #expect(again.contains(pushed.prefix(7)), Comment(rawValue: again))
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// A new reply after the question: the approval covered the old reply.
  @Test func aNewReplyAfterTheQuestionMakesSbdAskAgainAndMergeNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try askedMerge(github, sbd)
    try sbd.sb("send", s.id, "should I also drop the old table")
    try sbd.waitFor(s.id, "the new reply") {
      $0.lastReply == "Done: should I also drop the old table" && $0.state == .readyToMerge
    }

    let r = try approve(sbd, wait)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try judgment(sbd, about: wait, count: 2)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }
}

// MARK: Changes during the live reads

extension FollowThroughTests {
  /// Holds the next compare read of the PR that `live` describes on the stub's FIFO, and returns the function that
  /// lets it go. The FIFO goes with the release, so later reads run at once.
  func holdCompare(_ sbd: Instance, _ live: LiveGitHub) throws -> () -> Void {
    let gate = "\(sbd.home.path)/gh-live/api/repos/\(live.repo)/compare/\(live.base)...\(live.head).gate"
    try FileManager.default.createDirectory(
      atPath: (gate as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    return {
      let writer = open(gate, O_WRONLY | O_NONBLOCK)
      if writer >= 0 {
        _ = "go\n".withCString { write(writer, $0, 3) }
        close(writer)
      }
      unlink(gate)
    }
  }

  func compareReads(_ sbd: Instance) -> Int { sbd.ghCalls().filter { $0.contains("/compare/") }.count }

  /// The Operator approves, then clears the wait while sbd's live reads run. sbd merges nothing.
  @Test func aWaitClearedDuringTheChecksMergesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    let op = try theOperator(sbd)
    let reads = compareReads(sbd)
    let release = try holdCompare(sbd, LiveGitHub(github))
    let r = try approve(sbd, wait)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the compare read", timeout: 30) { compareReads(sbd) > reads }

    try sbd.sb("wait", op.id, "--clear", "--id", wait)
    release()

    try sbd.waitFor("the run's end", timeout: 30) {
      ((try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? "").contains("wait \(wait) of \(op.id) went")
    }
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// A new reply arrives while sbd's live reads run after the approval. The approval covered the old reply, so sbd
  /// merges nothing and asks about the new one.
  @Test func aNewReplyDuringTheChecksMergesNothingAndAsksAgain() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try askedMerge(github, sbd)
    let reads = compareReads(sbd)
    let release = try holdCompare(sbd, LiveGitHub(github))
    let r = try approve(sbd, wait)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the compare read", timeout: 30) { compareReads(sbd) > reads }

    try sbd.sb("send", s.id, "should I also drop the old table")
    try sbd.waitFor(s.id, "the new reply") {
      $0.lastReply == "Done: should I also drop the old table" && $0.state == .readyToMerge
    }
    release()

    let again = try judgment(sbd, about: wait, count: 2)
    #expect(again.contains("should I also drop the old table"), Comment(rawValue: again))
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// A poll records an unresolved review thread at the same head while sbd's live reads run after the approval.
  /// Ready to merge stays, with the merge option demoted to "anyway", so sbd must check the threads again before it
  /// merges.
  @Test func aReviewThreadOpenedDuringTheChecksHoldsTheMerge() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try askedMerge(github, sbd)
    let reads = compareReads(sbd)
    let release = try holdCompare(sbd, LiveGitHub(github))
    let r = try approve(sbd, wait)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the compare read", timeout: 30) { compareReads(sbd) > reads }

    github.reviewThreads(Self.number, resolved: [false])
    try sbd.advanceClock(600_000)
    try sbd.poll(all: true)
    try sbd.waitFor("the open thread", timeout: 30) {
      try sbd.getJSON(s.id)["triage"]?["message"]?["review"]?["threads"]?["open"]?.int == 1
    }
    release()

    try sbd.waitFor("the run's end", timeout: 30) { try operatorsWait(sbd, wait)?.actionStatus?.kind != .running }
    let status = try operatorsWait(sbd, wait)?.actionStatus
    #expect(status?.kind == .held, "\(String(describing: status))")
    #expect(status?.reason?.contains("unresolved review threads") == true, "\(String(describing: status))")
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// The user takes the repository off `operator.mergeRepos` after the wait was armed. sbd reads config.json again
  /// before the merge, so nothing merges and the Operator is asked.
  @Test func aRepositoryTakenOffTheAllowlistAfterArmingMergesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    try sbd.set("operator", to: ["mergeRepos": []])

    let r = try approve(sbd, wait)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try operatorMessage(sbd, holding: "operator.mergeRepos")
    try tick(sbd, 2)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }

  /// A config.json that doesn't decode refuses the merge, the way an empty allowlist does.
  @Test func aConfigFileThatDoesNotDecodeMergesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    try "{".write(toFile: sbd.home.config, atomically: true, encoding: .utf8)

    let r = try approve(sbd, wait)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try operatorMessage(sbd, holding: "operator.mergeRepos")
    try tick(sbd, 2)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }
}

// MARK: Two merges in one repository

extension FollowThroughTests {
  static let secondNumber = 18_304
  static let secondBranch = "haacked/cdp-dlq-runbook-second-step"

  /// Two merge waits in PostHog/charts whose PRs share a file both reach Ready to merge on one poll. The earlier
  /// wait goes on to the question, and the later one holds without one until the earlier merge resolves.
  @Test func twoOverlappingMergesOnOneTickMergeOneAndHoldTheOther() throws {
    let github = try FakeGitHub()
    github.addPR(
      copying: Self.number, number: Self.secondNumber, branch: Self.secondBranch, head: FakeGitHub.sha(18_304))
    let approved = github.pr(Self.number)
    for n in [Self.number, Self.secondNumber] {
      github.change(n) {
        $0["reviewDecision"] = "REVIEW_REQUIRED"
        $0["latestOpinionatedReviews"] = ["nodes": []]
      }
    }
    let sbd = try instance(github)
    try sbd.serve(LiveGitHub(github))
    try sbd.serve(LiveGitHub(github, number: Self.secondNumber))
    let first = try sbd.session(in: Self.charts, branch: MergeTests.branch, name: "fix-cache")
    let second = try sbd.session(in: Self.charts, branch: Self.secondBranch, folder: "charts-2", name: "second")
    try sbd.poll()
    try sbd.waitFor(second.id, "the poller's read of #18304") { $0.pr?.number == Self.secondNumber }
    let c = try arming.conversation(sbd)
    let firstWait = try arm(sbd, arming.mergeArgs(first), from: c)
    let secondWait = try arm(sbd, arming.mergeArgs(second), from: c)
    for n in [Self.number, Self.secondNumber] {
      github.change(n) {
        $0["reviewDecision"] = approved["reviewDecision"]!
        $0["latestOpinionatedReviews"] = approved["latestOpinionatedReviews"]!
      }
    }

    try sbd.poll(all: true)

    try judgment(sbd, about: firstWait)
    try waitForStatus(sbd, secondWait, .held)
    try tick(sbd, 3)
    let asked = try operatorMessages(sbd)
    #expect(asked.allSatisfy { !$0.contains(secondWait) }, "\(asked)")
    #expect(try operatorsWait(sbd, secondWait)?.actionStatus?.kind == .held)
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")

    let r = try approve(sbd, firstWait)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the first merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    try tick(sbd, 2)
    try judgment(sbd, about: secondWait)
    #expect(sbd.ghMerges() == [ghMerge(head(github))], "\(sbd.ghCalls())")
  }
}

// MARK: A pending base after sbd's own merge

extension FollowThroughTests {
  /// sbd merged #18303 and restarted while the base's checks still run. #18304 shares a file with #18303, so its
  /// merge holds without a question, because sbd rebuilds its last merge from the log.
  @Test func aPendingBaseAfterSbdsOverlappingMergeHoldsTheNextMergeAcrossARestart() throws {
    let github = try FakeGitHub()
    github.addPR(
      copying: Self.number, number: Self.secondNumber, branch: Self.secondBranch, head: FakeGitHub.sha(18_304))
    let sbd = try instance(github)
    let (_, first) = try approvedMerge(github, sbd)
    try sbd.waitFor("the first wait to go", timeout: 30) { try operatorsWait(sbd, first) == nil }
    sbd.killSbd()
    try sbd.startSbd()
    var live = LiveGitHub(github, number: Self.secondNumber)
    live.baseChecks = "PENDING"
    try sbd.serve(live)
    let second = try sbd.session(in: Self.charts, branch: Self.secondBranch, folder: "charts-2", name: "second")
    try sbd.poll()
    try sbd.waitFor(second.id, "Ready to merge") { $0.state == .readyToMerge }

    let wait = try arm(sbd, arming.mergeArgs(second))

    try waitForStatus(sbd, wait, .held)
    let asked = try operatorMessages(sbd)
    #expect(asked.allSatisfy { !$0.contains(wait) }, "\(asked)")
    #expect(sbd.ghMerges().count == 1, "\(sbd.ghCalls())")
  }

  /// sbd stores the merge commit of its own merge. After the merged session is removed, a pending base on another
  /// commit doesn't hold an overlapping merge.
  @Test func aPendingBaseOnAnotherCommitDoesNotHoldAnOverlappingMergeAfterSbdsMergedSessionIsRemoved() throws {
    let github = try FakeGitHub()
    github.addPR(
      copying: Self.number, number: Self.secondNumber, branch: Self.secondBranch, head: FakeGitHub.sha(18_304))
    let sbd = try instance(github)
    var firstLive = LiveGitHub(github)
    firstLive.mergeCommit = FakeGitHub.sha(9100)
    let (s, first) = try askedMerge(github, sbd, live: firstLive)
    let r = try approve(sbd, first)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the first wait to go", timeout: 30) { try operatorsWait(sbd, first) == nil }
    let resolved = try #require(try resolvedEvent(sbd, first))
    #expect(resolved.data["action"]?["commit"]?.string == FakeGitHub.sha(9100), Comment(rawValue: resolved.data.text))
    try sbd.waitFor(s.id, "the reply to the post-merge message") { $0.lastReply?.hasPrefix("Done: PR #") == true }
    try sbd.sb("rm", s.id)
    var live = LiveGitHub(github, number: Self.secondNumber)
    live.baseChecks = "PENDING"
    try sbd.serve(live)
    let second = try sbd.session(in: Self.charts, branch: Self.secondBranch, folder: "charts-2", name: "second")
    try sbd.poll()
    try sbd.waitFor(second.id, "Ready to merge") { $0.state == .readyToMerge }

    let wait = try arm(sbd, arming.mergeArgs(second))

    try judgment(sbd, about: wait)
    #expect(sbd.ghMerges().count == 1, "\(sbd.ghCalls())")
  }
}

// MARK: Holds

extension FollowThroughTests {
  /// The poller never read the merge details, so the guard holds. A poll that reads them lets it go on to the
  /// question at the next retry.
  @Test func missingMergeDetailsHoldTheMergeUntilAPollReadsThem() throws {
    let github = try FakeGitHub()
    github.fail(Self.number, in: .mergeDetails)
    let sbd = try instance(github)
    try sbd.serve(LiveGitHub(github))
    let s = try arming.readyTarget(sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))

    try waitForStatus(sbd, wait, .held)

    try tick(sbd, 3)
    let messages = try operatorMessages(sbd)
    #expect(messages.isEmpty, "\(messages)")
    #expect(sbd.ghMerges().isEmpty)

    github.recover(Self.number, in: .mergeDetails)
    try sbd.poll(all: true)
    try sbd.advanceClock(Self.pastHoldRetry)

    try judgment(sbd, about: wait)
  }

  /// sbd sends the session one fixed message per (head, base tip) and holds the action.
  @Test func aHeadBehindTheBaseSendsTheSessionOneMergeMainMessageAndHolds() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    var live = LiveGitHub(github)
    live.behindBy = 2
    try sbd.serve(live)
    let s = try arming.readyTarget(sbd)

    let wait = try arm(sbd, arming.mergeArgs(s))

    try sbd.waitFor("the merge-main message") { try sbd.messagesFromSbd(s.id).contains(Self.mergeMain) }
    try waitForStatus(sbd, wait, .held)
    let messages = try operatorMessages(sbd)
    #expect(messages.isEmpty, "\(messages)")
    #expect(sbd.ghMerges().isEmpty)
  }

  /// The session for `aHeadBehindTheBase…`, once its turn for the merge-main message has ended and the hold that
  /// follows it has settled.
  func settledBehindHold(_ github: FakeGitHub, _ sbd: Instance) throws -> (s: SessionSummary, wait: String) {
    var live = LiveGitHub(github)
    live.behindBy = 2
    try sbd.serve(live)
    let s = try arming.readyTarget(sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))
    try sbd.waitFor(s.id, "the reply to the merge-main message") {
      $0.lastReply == "Done: \(Self.mergeMain)" && $0.state == .readyToMerge
    }
    // The turn moved the session's state twice, which may start one more check. It ends held again.
    try tick(sbd, 2)
    try waitForStatus(sbd, wait, .held)
    return (s, wait)
  }

  /// A hold has a retry time, so ticks with unchanged facts run no live read and send nothing.
  @Test func aHeldMergeRunsNoGhCallAndSendsNothingOnTicksWithUnchangedFacts() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, _) = try settledBehindHold(github, sbd)
    let reads = sbd.ghLiveReads().count
    let messages = try sbd.messagesFromSbd(s.id).count

    try tick(sbd, 5)

    #expect(sbd.ghLiveReads().count == reads, "\(sbd.ghLiveReads())")
    #expect(try sbd.messagesFromSbd(s.id).count == messages)
    #expect(try sbd.messagesFromSbd(s.id).filter { $0 == Self.mergeMain }.count == 1)
  }

  /// A change of the subject's state retries the hold before its retry time. The head and the base
  /// tip are the same, so sbd sends no second merge-main message.
  @Test func aHeldMergeChecksAgainAfterTheSubjectsStateChanges() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, _) = try settledBehindHold(github, sbd)
    let reads = sbd.ghLiveReads().count

    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: again" && $0.state == .readyToMerge }
    try tick(sbd, 2)

    try sbd.waitFor("another live read", timeout: 30) { sbd.ghLiveReads().count > reads }
    #expect(try sbd.messagesFromSbd(s.id).filter { $0 == Self.mergeMain }.count == 1)
  }

  /// An action held for one reason for `operator.holdLimitSeconds` (6 h) becomes a question.
  @Test func aMergeHeldForSixHoursAsksTheOperator() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try settledBehindHold(github, sbd)

    try sbd.advanceClock(21_600_001)

    let text = try operatorMessage(sbd, holding: "still held after 6 h")
    #expect(text.contains(wait), Comment(rawValue: text))
    try waitForStatus(sbd, wait, .awaitingJudgment)
    #expect(sbd.ghMerges().isEmpty)
  }

  /// sbd reads `operator.holdLimitSeconds` again on each hold, so a limit that the user lowers during the hold applies.
  @Test func aHoldLimitLoweredDuringTheHoldAsksTheOperatorAtTheNewLimit() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try settledBehindHold(github, sbd)
    try sbd.set("operator", to: ["mergeRepos": [.string(Self.charts)], "holdLimitSeconds": 7200])

    try sbd.advanceClock(7_200_001)

    let text = try operatorMessage(sbd, holding: "still held after 2 h")
    #expect(text.contains(wait), Comment(rawValue: text))
  }

  /// After the session merged the base in, the guard goes on to the question.
  @Test func aHeldMergeGoesOnOnceTheHeadContainsTheBase() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try settledBehindHold(github, sbd)
    try sbd.serve(LiveGitHub(github))

    try sbd.sb("send", s.id, "merged main and pushed")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: merged main and pushed" && $0.state == .readyToMerge }
    try tick(sbd, 2)

    try judgment(sbd, about: wait)
  }
}

// MARK: Unmet outcomes run nothing

extension FollowThroughTests {
  enum Pending: String, CaseIterable, CustomTestStringConvertible {
    case held, awaitingJudgment
    var testDescription: String { rawValue }
  }

  /// An unmet outcome still resolves a wait whose action is held or awaits judgment, so the wait never stays on
  /// the Operator.
  @Test(arguments: Pending.allCases)
  func aPendingMergeWhoseSubjectIsRemovedResolvesUnmet(_ pending: Pending) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    var live = LiveGitHub(github)
    live.behindBy = pending == .held ? 2 : 0
    try sbd.serve(live)
    let s = try arming.readyTarget(sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))
    try waitForStatus(sbd, wait, pending == .held ? .held : .awaitingJudgment)

    try sbd.sb("rm", s.id)

    try operatorMessage(sbd, holding: "sbd did not merge, because it was removed.")
    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    #expect(sbd.ghMerges().isEmpty)
  }

  /// The subject goes while the merge's live reads run, so the hold's message to it fails. The wait still leaves
  /// the running state, and the removal then resolves it unmet.
  @Test func aSubjectRemovedWhileTheMergeRunsStillResolvesUnmet() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    var live = LiveGitHub(github)
    live.behindBy = 2
    try sbd.serve(live)
    let release = try holdCompare(sbd, live)
    let s = try arming.readyTarget(sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))
    try sbd.waitFor("the compare read", timeout: 30) { compareReads(sbd) > 0 }

    try sbd.sb("rm", s.id)
    release()

    try operatorMessage(sbd, holding: "sbd did not merge, because it was removed.")
    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test func aMergeWaitWhoseSubjectIsRemovedBeforeReadyToMergeRunsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.serve(LiveGitHub(github))
    let s = try arming.notReadyTarget(github, sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))

    try sbd.sb("rm", s.id)

    let text = try operatorMessage(sbd, holding: "sbd did not merge")
    #expect(text.hasPrefix("Switchboard: \(WaitActionTests.target) to reach Ready to merge: it was removed."))
    #expect(text.contains("sbd did not merge, because it was removed."), Comment(rawValue: text))
    #expect(sbd.ghLiveReads().isEmpty, "\(sbd.ghLiveReads())")
    #expect(try operatorsWait(sbd, wait) == nil)
  }

  /// `sb wait --resolve` never sends `met`, so the user's resolve runs nothing.
  @Test func theUsersResolveOfAMergeWaitRunsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.serve(LiveGitHub(github))
    let s = try arming.notReadyTarget(github, sbd)
    let c = try arming.conversation(sbd)
    let wait = try arm(sbd, arming.mergeArgs(s), from: c)

    let r = try sbd.run(["wait", c.id, "--resolve", "the user merged it by hand", "--id", wait])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try operatorMessage(sbd, holding: "sbd did not merge, because the user merged it by hand.")
    #expect(sbd.ghLiveReads().isEmpty, "\(sbd.ghLiveReads())")
  }

  /// Only sbd's poller says whether a condition was met. A `resolve-wait` that sends `met` is refused, so it starts no
  /// action. `rm` needs no GitHub, so the test sees the action by its effect.
  @Test func resolveWaitWithMetFromAnotherClientDoesNotRemoveTheSession() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    let wait = try arm(sbd, ["--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm"])
    let op = try theOperator(sbd)

    #expect(throws: (any Error).self) {
      try sbd.client.call(
        "resolve-wait", ["session": .string(op.id), "wait": .string(wait), "outcome": "it did", "met": true])
    }

    try tick(sbd, 3)
    #expect(try sessionIds(sbd).contains(kid.id))
    #expect(try operatorsWait(sbd, wait) != nil)
  }

  @Test func resolveWaitWithMetFromAnotherClientDoesNotStartAMerge() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.serve(LiveGitHub(github))
    let s = try arming.notReadyTarget(github, sbd)
    let wait = try arm(sbd, arming.mergeArgs(s))
    let op = try theOperator(sbd)

    #expect(throws: (any Error).self) {
      try sbd.client.call(
        "resolve-wait", ["session": .string(op.id), "wait": .string(wait), "outcome": "it did", "met": true])
    }

    try tick(sbd, 3)
    #expect(sbd.ghLiveReads().isEmpty, "\(sbd.ghLiveReads())")
    #expect(sbd.ghMerges().isEmpty)
    #expect(try operatorsWait(sbd, wait) != nil)
  }

  /// A GitHub merge queue removal is not met, so a report on that queue wait is not recorded.
  @Test func aGitHubMergeQueueRemovalRecordsNoReport() throws {
    let github = try FakeGitHub()
    github.change(Self.number) { $0["isMergeQueueEnabled"] = true }
    let sbd = try instance(github)
    let s = try sbd.session(in: Self.charts, branch: MergeTests.branch, name: WaitActionTests.target)
    try sbd.poll()
    try sbd.waitFor(s.id, "the poller's read of #18303") { $0.pr?.number == Self.number }
    _ = try arm(
      sbd,
      ["--kind", "queue", "--target", "\(Self.charts)#\(Self.number)", "--then", "report", "--note", Self.note])
    github.change(Self.number) { $0["isInMergeQueue"] = true }
    try sbd.poll(all: true)
    github.change(Self.number) { $0["isInMergeQueue"] = false }

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    let text = try operatorMessage(sbd, holding: "GitHub removed it from the merge queue")
    #expect(text.contains("sbd did not "), Comment(rawValue: text))
    #expect(text.contains(", because GitHub removed it from the merge queue."), Comment(rawValue: text))
    let reports = try reportEvents(sbd)
    #expect(reports.isEmpty, "\(reports.map(\.data.text))")
  }
}

// MARK: A restart while an action runs

extension FollowThroughTests {
  /// sbd dies while `gh pr merge` runs, and GitHub merged the PR. At startup the running action is checked again,
  /// sees the merge, and finishes without a second `gh pr merge`.
  @Test func aRestartDuringTheMergeFinishesWithoutASecondMerge() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try askedMerge(github, sbd)
    let gate = "\(sbd.home.path)/gh-merge-gate"
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    let op = try theOperator(sbd)
    try sbd.writeScript(
      "approve-held", "CLAUDECODE=1 \(shellQuote("\(Instance.bin)/sb")) operator approve \(shellQuote(wait))")
    try sbd.advanceClock(1)
    try sbd.sb("operator", "run approve-held")
    try sbd.waitFor("gh to start the merge", timeout: 30) { sbd.ghMerges().count == 1 }
    #expect(try operatorsWait(sbd, wait) != nil, "the wait stays while its action runs")

    sbd.killSbd()
    mergeOnGitHub(github)
    var live = LiveGitHub(github)
    live.state = "MERGED"
    try sbd.serve(live)
    // The stub that sbd started still waits on the gate. A non-blocking open finds it, or finds that it is gone.
    let writer = open(gate, O_WRONLY | O_NONBLOCK)
    if writer >= 0 {
      _ = "go\n".withCString { write(writer, $0, 3) }
      close(writer)
    }
    try sbd.startSbd()
    try sbd.poll(all: true)

    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    #expect(sbd.ghMerges().count == 1, "\(sbd.ghCalls())")
    #expect(try sbd.messagesFromSbd(op.id).allSatisfy { !$0.contains("sbd did not merge") })
  }

  /// sbd recorded a merge of the PR's head before the action ran. The poller has not read the merge yet. sbd
  /// leaves this state when it dies between `landPR`'s record and the end of the action. The record finishes the
  /// action as merged, so GitHub's later Done does not resolve the wait unmet.
  @Test func aMergeThatSbdRecordedBeforeTheRunFinishesAsMerged() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try askedMerge(github, sbd)
    let op = try theOperator(sbd)
    try sbd.sb("merge", s.id)

    let r = try approve(sbd, wait)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the run's end", timeout: 30) { try operatorsWait(sbd, wait)?.actionStatus?.kind != .running }
    mergeOnGitHub(github)
    try sbd.poll(all: true)

    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    let resolved = try #require(try resolvedEvent(sbd, wait))
    #expect(resolved.data["action"]?["result"]?.string == "merged", Comment(rawValue: resolved.data.text))
    #expect(try sbd.messagesFromSbd(op.id).allSatisfy { !$0.contains("sbd did not merge") })
    #expect(sbd.ghMerges().count == 1, "\(sbd.ghCalls())")
  }
}

// MARK: A PR that merged before the run

extension FollowThroughTests {
  /// The live read shows the PR merged, so the action finishes with the merge commit from that read and asks gh for
  /// nothing more.
  @Test func aPRThatTheLiveReadShowsMergedFinishesWithItsLiveMergeCommit() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    var live = LiveGitHub(github)
    live.state = "MERGED"
    live.mergeCommit = FakeGitHub.sha(9100)
    try sbd.serve(live)
    let s = try arming.readyTarget(sbd)
    let conversation = try arming.conversation(sbd)

    // The action can finish before `arm` reads the Operator's waits, so the test finds the wait by its event.
    let r = try sbd.run(["wait", "--json", conversation.id] + arming.mergeArgs(s))

    try #require(r.status == 0, Comment(rawValue: r.stderr))
    let op = try theOperator(sbd)
    let resolved = try sbd.waitFor(
      "the merge wait to resolve", timeout: 30,
      fetch: { try sbd.events(op.id).last { $0.kind == "wait-resolved" && $0.data["action"] != nil } },
      until: { _ in true })
    #expect(resolved.data["action"]?["result"]?.string == "merged", Comment(rawValue: resolved.data.text))
    #expect(resolved.data["action"]?["commit"]?.string == FakeGitHub.sha(9100), Comment(rawValue: resolved.data.text))
    #expect(!sbd.ghCalls("pr view ").contains { $0.hasSuffix("--json mergeCommit") }, "\(sbd.ghCalls())")
    #expect(sbd.ghMerges().isEmpty, "\(sbd.ghCalls())")
  }
}

// MARK: rm-worktree

extension FollowThroughTests {
  func rmWorktreeArgs(_ s: SessionSummary) -> [String] {
    ["--kind", "session", "--target", s.id, "--state", "done", "--then", "rm-worktree"]
  }

  var mergeWaitArgs: [String] { ["--kind", "merge", "--target", "\(Self.charts)#\(Self.number)", "--then"] }

  @Test func rmWorktreeOnAMergedCleanSessionRemovesItAndItsWorktree() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try chartsWorktreeSession(sbd)
    let wait = try arm(sbd, rmWorktreeArgs(s))

    try mergeAndWaitForDone(github, sbd, s)

    try sbd.waitFor("the removal", timeout: 60) { try !sessionIds(sbd).contains(s.id) }
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    let resolved = try #require(try resolvedEvent(sbd, wait))
    #expect(resolved.data["action"]?["kind"]?.string == "rm-worktree", Comment(rawValue: resolved.data.text))
    try expectNoSentToOperator(sbd)
  }

  /// The merge action's post-merge message starts a turn, and Done shows "once it stops". sbd holds the removal
  /// while the turn runs, stops nothing, and removes the session once the turn ends.
  @Test func rmWorktreeHoldsWhileTheSubjectsTurnRunsAndRemovesAfterIt() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try chartsWorktreeSession(sbd)
    let wait = try arm(sbd, rmWorktreeArgs(s))
    try sbd.sb("send", s.id, "slow held")
    let running = try sbd.waitFor(s.id, "the held turn") { $0.state == .working }

    try mergeAndWaitForDone(github, sbd, s)

    try waitForStatus(sbd, wait, .held)
    try tick(sbd, 3)
    let during = try sbd.get(s.id)
    #expect(during.live)
    #expect(during.claudePid == running.claudePid)
    #expect(FileManager.default.fileExists(atPath: s.cwd))

    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    try sbd.waitFor(s.id, "the turn's end") { $0.lastReply == "Slept held s." }
    try sbd.advanceClock(Self.pastHoldRetry)

    try sbd.waitFor("the removal", timeout: 60) { try !sessionIds(sbd).contains(s.id) }
  }

  /// Restarts sbd with a `git` script ahead of the real one on `PATH`. Only `rm`'s checks run
  /// `status --porcelain -z` without `--ignored=matching`. For that call, the script creates the file `started` and
  /// then blocks on a FIFO until `release` runs. The poller's cleanup checks pass `--ignored=matching`, so they never
  /// block. `release` deletes the FIFO, so later calls run at once.
  func holdRemovalChecks(_ sbd: Instance) throws -> (started: String, release: () -> Void) {
    let dir = "\(sbd.home.path)/git-gate"
    let gate = "\(dir)/gate"
    let started = "\(dir)/started"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    let script = """
      #!/bin/sh
      case " $* " in
        *" --ignored=matching "*) ;;
        *" status --porcelain -z "*) if [ -p '\(gate)' ]; then : > '\(started)'; cat '\(gate)' > /dev/null; fi;;
      esac
      exec /usr/bin/git "$@"
      """
    try script.write(toFile: "\(dir)/git", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(dir)/git")
    sbd.stopSbd()
    sbd.sbdEnvironment["PATH"] = "\(dir):" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
    try sbd.startSbd()
    return (
      started,
      {
        let writer = open(gate, O_WRONLY | O_NONBLOCK)
        if writer >= 0 {
          _ = "go\n".withCString { write(writer, $0, 3) }
          close(writer)
        }
        unlink(gate)
      }
    )
  }

  /// A turn starts while `remove` runs its checks, after the guard found the session idle. sbd holds the removal
  /// instead of stopping the new turn.
  @Test func rmWorktreeHoldsForATurnThatStartsDuringTheRemovalChecks() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let gate = try holdRemovalChecks(sbd)
    let s = try chartsWorktreeSession(sbd)
    let wait = try arm(sbd, rmWorktreeArgs(s))
    let idle = try sbd.get(s.id)
    try #require(idle.live)

    try mergeAndWaitForDone(github, sbd, s)
    try sbd.waitFor("the removal checks", timeout: 60) { FileManager.default.fileExists(atPath: gate.started) }
    try sbd.sb("send", s.id, "slow held")
    try sbd.waitFor("the held turn", timeout: 30) {
      try sbd.events(s.id).contains { $0.kind == "UserPromptSubmit" && $0.data["prompt"]?.string == "slow held" }
    }
    gate.release()

    try sbd.waitFor("the run's end", timeout: 60) { try operatorsWait(sbd, wait)?.actionStatus?.kind != .running }
    let status = try operatorsWait(sbd, wait)?.actionStatus
    #expect(status?.kind == .held, "\(String(describing: status))")
    let after = try sbd.get(s.id)
    #expect(after.live)
    #expect(after.claudePid == idle.claudePid)
    #expect(FileManager.default.fileExists(atPath: s.cwd))
  }

  /// `--kind merge --then rm-worktree` stores the session with that open PR when it is set, and removes it after
  /// the PR merges.
  @Test func rmWorktreeOnAMergeWaitRemovesTheStoredSubjectAfterTheMerge() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try chartsWorktreeSession(sbd)
    _ = try arm(sbd, mergeWaitArgs + ["rm-worktree"])

    mergeOnGitHub(github, head: try sbd.git(s.cwd, "rev-parse", "HEAD"))
    try sbd.poll(all: true)

    try sbd.waitFor("the removal", timeout: 60) { try !sessionIds(sbd).contains(s.id) }
    #expect(!FileManager.default.fileExists(atPath: s.cwd))
  }

  /// `remove` refuses a worktree with an uncommitted file. sbd raises the refusal as judgment and keeps the files.
  @Test func rmWorktreeWithAnUncommittedFileAsksForJudgmentAndKeepsTheWorktree() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try chartsWorktreeSession(sbd)
    _ = try arm(sbd, mergeWaitArgs + ["rm-worktree"])
    try "scratch".write(toFile: "\(s.cwd)/notes.txt", atomically: true, encoding: .utf8)

    mergeOnGitHub(github, head: try sbd.git(s.cwd, "rev-parse", "HEAD"))
    try sbd.poll(all: true)

    let text = try operatorMessage(sbd, holding: "uncommitted")
    #expect(text.contains("sbd could not remove"), Comment(rawValue: text))
    #expect(try sessionIds(sbd).contains(s.id))
    #expect(FileManager.default.fileExists(atPath: "\(s.cwd)/notes.txt"))
  }

  /// `rm-worktree` needs a merged PR. Done after a close is judgment, and nothing goes.
  @Test func rmWorktreeOnAPRClosedUnmergedAsksForJudgmentAndRemovesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try chartsWorktreeSession(sbd)
    let wait = try arm(sbd, rmWorktreeArgs(s))

    github.change(Self.number) {
      $0["state"] = "CLOSED"
      $0["closedAt"] = "2026-10-26T00:00:00Z"
    }
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "Done") { $0.state == .done }

    try waitForStatus(sbd, wait, .awaitingJudgment)
    #expect(try !operatorMessages(sbd).isEmpty)
    #expect(try sessionIds(sbd).contains(s.id))
    #expect(FileManager.default.fileExists(atPath: s.cwd))
  }

  /// A session that the user marked done with no PR at all: every `remove` check would pass, so only the merged-PR
  /// rule refuses.
  @Test func rmWorktreeOnASessionWithNoPRAsksForJudgmentAndRemovesNothing() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo)
    let wait = try arm(sbd, rmWorktreeArgs(s))

    try sbd.sb("done", s.id)

    try waitForStatus(sbd, wait, .awaitingJudgment)
    #expect(try sessionIds(sbd).contains(s.id))
    #expect(FileManager.default.fileExists(atPath: s.cwd))
  }
}

// MARK: rm and report

extension FollowThroughTests {
  @Test func rmOnDoneRemovesTheSession() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    let wait = try arm(sbd, ["--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm"])

    try sbd.sb("done", kid.id)

    try sbd.waitFor("the removal", timeout: 30) { try !sessionIds(sbd).contains(kid.id) }
    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    #expect(try resolvedEvent(sbd, wait)?.data["action"]?["kind"]?.string == "rm")
    try expectNoSentToOperator(sbd)
  }

  @Test func reportOnAMergeWaitRecordsAnInfoReport() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    _ = try arming.notReadyTarget(github, sbd)
    let wait = try arm(sbd, mergeWaitArgs + ["report", "--note", Self.note])

    mergeOnGitHub(github)
    try sbd.poll(all: true)

    let report = try sbd.waitFor(
      "the report", timeout: 30, fetch: { try reportEvents(sbd).last }, until: { _ in true })
    #expect(report.data["text"]?.string == Self.note, Comment(rawValue: report.data.text))
    #expect(report.data["needsYou"]?.bool != true, Comment(rawValue: report.data.text))
    let rows = try listedReports(sbd)
    #expect(rows.last?["open"]?.bool == false, "\(rows)")
    try sbd.waitFor("the wait to go", timeout: 30) { try operatorsWait(sbd, wait) == nil }
    #expect(try resolvedEvent(sbd, wait)?.data["action"]?["kind"]?.string == "report")
    try expectNoSentToOperator(sbd)
  }

  @Test func reportWithNeedsYouShowsAsAnOpenReport() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    _ = try arming.notReadyTarget(github, sbd)
    _ = try arm(sbd, mergeWaitArgs + ["report", "--note", Self.note, "--needs-you"])

    mergeOnGitHub(github)
    try sbd.poll(all: true)

    let row = try sbd.waitFor(
      "the open report", timeout: 30, fetch: { try listedReports(sbd).last }, until: { _ in true })
    #expect(row["text"]?.string == Self.note, Comment(rawValue: row.text))
    #expect(row["open"]?.bool == true, Comment(rawValue: row.text))
  }

  /// `sb operator reports --json`.
  func listedReports(_ sbd: Instance) throws -> [JSON] {
    let text = try sbd.sb("operator", "reports", "--json")
    return try #require(JSON.parse(text)?.array, Comment(rawValue: text))
  }
}
