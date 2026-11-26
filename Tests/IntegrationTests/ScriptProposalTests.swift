import Foundation
import SwitchboardCore
import Testing

/// A session that may not add a script itself proposes it, which opens a `script` card
/// on the proposing session and stores nothing. The schedule exists only after the user allows the card from outside
/// every session: the app's `answer` or `choose`, or `sb allow` in a terminal. Allow stores exactly the values that
/// the card holds. Deny, expiry after a day, and a stale edit close the card and store nothing.
///
/// A command that the test runner starts runs outside every pane, so it stands for the user and for the app. A
/// command that `WaitActionTests.runInPane` runs descends from the session's Claude pane, as a tool call of Claude's
/// would.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScriptProposalTests {
  let waits = WaitActionTests()
  let scripts = ScheduleScriptTests()
  let operatorHelpers = OperatorTests()

  static let expiryMs = ScriptProposal.expirySeconds * 1000

  // MARK: Helpers

  /// Runs `sb schedule <target> --every <every> [--timeout <timeout>] --script <command> --json` in `owner`'s Claude
  /// pane. The target is the owner itself when `target` is nil.
  func proposeInPane(
    _ sbd: Instance, of owner: SessionSummary, for target: SessionSummary? = nil, _ command: String = "git fetch",
    every: String = "1h", timeout: String? = nil, json: Bool = true, name: String = "propose"
  ) throws -> CommandResult {
    let limit = timeout.map { ["--timeout", $0] } ?? []
    let args =
      ["schedule", (target ?? owner).id, "--every", every] + limit + ["--script", command] + (json ? ["--json"] : [])
    return try waits.sbInPane(sbd, of: owner, args, name: name)
  }

  /// The card id of a proposal's `{pending: N, decision: "pending"}` answer.
  func pendingCard(_ r: CommandResult, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int64 {
    try #require(
      r.status == 0, Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"), sourceLocation: sourceLocation)
    let answer = try #require(JSON.parse(r.stdout), Comment(rawValue: r.stdout), sourceLocation: sourceLocation)
    #expect(answer["decision"]?.string == "pending", Comment(rawValue: answer.text), sourceLocation: sourceLocation)
    let card = try #require(answer["pending"]?.int, Comment(rawValue: answer.text), sourceLocation: sourceLocation)
    return Int64(card)
  }

  /// Proposes from `owner`'s Claude pane and returns the card's id.
  func propose(
    _ sbd: Instance, of owner: SessionSummary, for target: SessionSummary? = nil, _ command: String = "git fetch",
    every: String = "1h", timeout: String? = nil, name: String = "propose"
  ) throws -> Int64 {
    try pendingCard(try proposeInPane(sbd, of: owner, for: target, command, every: every, timeout: timeout, name: name))
  }

  /// Proposes an edit of a script's command from `owner`'s Claude pane and returns the card's id.
  func proposeEdit(
    _ sbd: Instance, of owner: SessionSummary, _ schedule: String, _ change: [String], name: String = "propose-edit"
  ) throws -> Int64 {
    try pendingCard(
      try waits.sbInPane(sbd, of: owner, ["schedule", "edit", schedule] + change + ["--json"], name: name))
  }

  /// The session's open `script` cards.
  func scriptCards(_ sbd: Instance, _ id: String) throws -> [Card] {
    try sbd.get(id).cards.filter { $0.kind == .script }
  }

  /// The session's script schedules.
  func storedScripts(_ sbd: Instance, _ id: String) throws -> [Schedule] {
    try sbd.get(id).allSchedules.filter { $0.runner == .script }
  }

  /// What `sb schedule --pending <card> --json` reports without waiting. A proposal that still waits may exit with an
  /// error, so this reads stdout whatever the status.
  func status(_ sbd: Instance, _ card: Int64) throws -> JSON {
    let r = try sbd.run(["schedule", "--pending", String(card), "--timeout", "0", "--json"])
    return try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
  }

  /// Who decides: `sb allow` or `sb deny` in a terminal, or the app's `answer` request.
  enum Decider: CaseIterable { case cli, app }

  func decide(_ sbd: Instance, _ how: Decider, _ session: String, _ card: Int64, allow: Bool) throws {
    switch how {
    case .cli:
      try sbd.sb(allow ? "allow" : "deny", session, "--card", String(card))
    case .app:
      _ = try sbd.client.call(
        "answer",
        ["session": .string(session), "card": .number(Double(card)), "behavior": .string(allow ? "allow" : "deny")])
    }
  }

  func decided(_ sbd: Instance, _ id: String) throws -> [Event] { try sbd.events(id, kind: "script_decided") }

  /// Runs sb with `args` in `owner`'s Claude pane with SB_SESSION_ID and CLAUDECODE unset, as a session can unset
  /// them. sb then claims no caller and doesn't know it runs inside Claude, so only sbd's ancestry check is left.
  func unsetInPane(_ sbd: Instance, of owner: SessionSummary, _ args: [String], name: String) throws -> CommandResult {
    try sbd.writeScript(name, scripts.sbCommand(sbd, unsetsCaller: true, args))
    return try waits.runInPane(sbd, of: owner, name)
  }

  /// Expects that an allow was refused: the command failed, the card is still open, and no script was stored.
  func expectRefusedAllow(
    _ r: CommandResult, _ sbd: Instance, card: Int64, on proposer: SessionSummary, target: SessionSummary,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    #expect(r.status != 0, Comment(rawValue: r.stdout), sourceLocation: sourceLocation)
    #expect(try scriptCards(sbd, proposer.id).map(\.id) == [card], sourceLocation: sourceLocation)
    #expect(try storedScripts(sbd, target.id).isEmpty, sourceLocation: sourceLocation)
    #expect(try decided(sbd, proposer.id).isEmpty, sourceLocation: sourceLocation)
  }

  /// The schedule without the fields that differ between two adds of the same values.
  func comparable(_ s: Schedule) -> Schedule {
    var s = s
    s.id = ""
    s.created = 0
    s.next = 0
    s.by = .you
    return s
  }

  // MARK: Opening the card

  @Test func aWorkSessionsProposalPrintsThatItWaitsForApprovalAndStoresNothing() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let r = try proposeInPane(sbd, of: worker, json: false)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let card = try #require(try scriptCards(sbd, worker.id).first)
    #expect(r.stdout.contains("waiting for your approval: card \(card.id)"), Comment(rawValue: r.stdout))
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  @Test func aProposalAnswersPendingWithItsCard() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let card = try propose(sbd, of: worker)

    #expect(try scriptCards(sbd, worker.id).map(\.id) == [card])
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  @Test func pendingReportsPendingBeforeADecision() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    let answer = try status(sbd, card)

    #expect(answer["pending"]?.int == Int(card), Comment(rawValue: answer.text))
    #expect(answer["decision"]?.string == "pending", Comment(rawValue: answer.text))
    #expect(answer["schedule"] == nil || answer["schedule"] == .null, Comment(rawValue: answer.text))
  }

  @Test func theCardOpensWithAScriptProposedEventOnTheProposerWhoseIdIsTheCard() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let card = try propose(sbd, of: worker, "git fetch --prune")

    let events = try sbd.events(worker.id, kind: "script_proposed")
    #expect(events.map(\.id) == [card])
    #expect(events.first?.data["command"]?.string == "git fetch --prune")
  }

  /// Decision 26: a work session may propose for another session, and the card sits on the proposer.
  @Test func theCardHoldsTheTargetItsFolderTheIntervalTheTimeoutAndTheCommand() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let target = try sbd.idleSession(name: "target")

    let card = try propose(sbd, of: worker, for: target, "git fetch --prune", every: "2h", timeout: "5m")

    let open = try #require(try scriptCards(sbd, worker.id).first)
    #expect(open.id == card)
    #expect(open.session == worker.id)
    let proposal = try #require(open.scriptProposal)
    #expect(proposal.target == target.id)
    #expect(proposal.targetName == "target")
    #expect(proposal.folder == target.cwd)
    #expect(proposal.every == 7_200_000)
    #expect(proposal.timeout == 300_000)
    #expect(proposal.command == "git fetch --prune")
    #expect(proposal.schedule == nil)
    #expect(try sbd.get(target.id).cards.isEmpty)
    #expect(try sbd.get(target.id).schedules == nil)
  }

  /// A proposal without --timeout stores no timeout, as an add from the user does, so the runner's default applies.
  @Test func aProposalWithoutATimeoutHoldsNone() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    _ = try propose(sbd, of: worker)

    #expect(try scriptCards(sbd, worker.id).first?.scriptProposal?.timeout == nil)
  }

  @Test func theCardExpiresADayAfterItOpens() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let before = nowMs()

    _ = try propose(sbd, of: worker)

    let expires = try #require(try scriptCards(sbd, worker.id).first?.scriptProposal?.expires)
    #expect(expires >= before + Self.expiryMs)
    #expect(expires <= nowMs() + Self.expiryMs)
  }

  @Test func sbCardsPrintsTheTargetItsFolderTheIntervalTheTimeoutAndTheCommandEscaped() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let target = try sbd.idleSession(name: "target")
    _ = try propose(sbd, of: worker, for: target, "echo \u{1B}[2Khidden", every: "2h", timeout: "5m")

    let text = try sbd.sb("cards")

    #expect(text.contains("target"), Comment(rawValue: text))
    #expect(text.contains(target.cwd), Comment(rawValue: text))
    #expect(text.contains("2h"), Comment(rawValue: text))
    #expect(text.contains("5m"), Comment(rawValue: text))
    #expect(text.contains("echo \\u{1b}[2Khidden"), Comment(rawValue: text))
    #expect(!text.contains("\u{1B}"), Comment(rawValue: text))
  }

  @Test func sbCardsPrintsTheOldCommandOfAnEdit() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try scripts.addScript(sbd, worker.id, "git fetch --prune")
    _ = try proposeEdit(sbd, of: worker, made.id, ["git pull --rebase"])

    let text = try sbd.sb("cards")

    #expect(text.contains("git fetch --prune"), Comment(rawValue: text))
    #expect(text.contains("git pull --rebase"), Comment(rawValue: text))
  }

  @Test func theProposerNeedsYouWhileTheCardIsOpen() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    _ = try propose(sbd, of: worker)

    let s = try sbd.waitFor(worker.id, "the card's attention") { $0.state == .needsYou }
    #expect(s.reason.hasPrefix("approve a script"), "\(s.reason)")
    #expect(s.triage?.source == .card)
    #expect(s.triage?.options.map(\.label) == ["Allow", "Deny"])
  }

  @Test func mcpAddScheduleWithAScriptFromAWorkSessionReturnsPending() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let result = try waits.toolInPane(
      sbd, of: worker, "add_schedule", ["session": .string(worker.id), "every": "1h", "script": "git fetch"],
      name: "worker-mcp-propose")

    #expect(!result.isError, Comment(rawValue: result.text))
    let answer = try #require(result.json, Comment(rawValue: result.text))
    #expect(answer["decision"]?.string == "pending", Comment(rawValue: answer.text))
    let card = try #require(answer["pending"]?.int)
    #expect(try scriptCards(sbd, worker.id).map(\.id) == [Int64(card)])
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  @Test func mcpEditScheduleOfAScriptsCommandFromAWorkSessionReturnsPending() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try scripts.addScript(sbd, worker.id, "git fetch")

    let result = try waits.toolInPane(
      sbd, of: worker, "edit_schedule", ["schedule": .string(made.id), "script": "git pull"],
      name: "worker-mcp-edit")

    #expect(!result.isError, Comment(rawValue: result.text))
    #expect(result.json?["decision"]?.string == "pending", Comment(rawValue: result.text))
    let proposal = try #require(try scriptCards(sbd, worker.id).first?.scriptProposal)
    #expect(proposal.schedule == made.id)
    #expect(proposal.command == "git pull")
    #expect(proposal.before?.command == "git fetch")
    #expect(try scripts.current(sbd, worker.id, made.id) == made)
  }

  /// Risk 8: a session has at most one open `script` card, so a second proposal can't hide behind the first.
  @Test func aSecondProposalFromTheSameSessionIsRefusedWithTheOpenCardsId() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    let r = try proposeInPane(sbd, of: worker, "touch pwned", name: "second")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("card \(card)"), Comment(rawValue: r.stderr))
    #expect(try scriptCards(sbd, worker.id).map(\.id) == [card])
    #expect(try scriptCards(sbd, worker.id).first?.scriptProposal?.command == "git fetch")
  }

  /// Risk 8: the card shows the whole command, so sbd refuses one longer than 2,000 characters.
  @Test(arguments: [2_001, 10_000])
  func aCommandLongerThanTwoThousandCharactersIsRefusedAndOpensNoCard(_ length: Int) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let command = "echo " + String(repeating: "x", count: length - 5)

    let r = try proposeInPane(sbd, of: worker, command)

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try scriptCards(sbd, worker.id).isEmpty)
  }

  @Test func aCommandOfExactlyTwoThousandCharactersOpensACard() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let command = "echo " + String(repeating: "x", count: 1_995)

    _ = try propose(sbd, of: worker, command)

    #expect(try scriptCards(sbd, worker.id).first?.scriptProposal?.command == command)
  }

  /// sbd checks the proposal as an add would, so a card never holds values that no approval could store.
  @Test(arguments: [["30s", "-"], ["1m", "5m"], ["1h", "3h"]])
  func aProposalThatAnAddWouldRefuseOpensNoCard(_ values: [String]) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")

    let r = try proposeInPane(sbd, of: worker, every: values[0], timeout: values[1] == "-" ? nil : values[1])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try scriptCards(sbd, worker.id).isEmpty)
  }

  @Test func theOperatorCantProposeAScript() throws {
    let sbd = try Instance()
    let op = try operatorHelpers.idleOperator(sbd)
    let kid = try sbd.idleSession(name: "kid")

    let r = try proposeInPane(sbd, of: op, for: kid)

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try scriptCards(sbd, op.id).isEmpty)
    #expect(try sbd.get(kid.id).schedules == nil)
  }

  // MARK: Allow

  @Test(arguments: Decider.allCases) func allowStoresTheScheduleWithTheCardsValues(_ how: Decider) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let target = try sbd.idleSession(name: "target")
    let card = try propose(sbd, of: worker, for: target, "git fetch --prune", every: "2h", timeout: "5m")

    try decide(sbd, how, worker.id, card, allow: true)

    let stored = try storedScripts(sbd, target.id)
    try #require(stored.count == 1, "\(stored)")
    #expect(stored[0].prompt == "git fetch --prune")
    #expect(stored[0].every == 7_200_000)
    #expect(stored[0].timeout == 300_000)
    #expect(stored[0].by == .claude)
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  @Test(arguments: Decider.allCases) func allowClosesTheCardWithAnApprovedDecisionNamingTheSchedule(_ how: Decider)
    throws
  {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    try decide(sbd, how, worker.id, card, allow: true)

    let stored = try #require(try storedScripts(sbd, worker.id).first)
    #expect(try scriptCards(sbd, worker.id).isEmpty)
    let closing = try decided(sbd, worker.id)
    #expect(closing.count == 1)
    #expect(closing.first?.data["card"]?.int == Int(card))
    #expect(closing.first?.data["decision"]?.string == "approved")
    #expect(closing.first?.data["schedule"]?.string == stored.id)
  }

  @Test func pendingReturnsTheScheduleAfterAnApproval() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)
    try decide(sbd, .cli, worker.id, card, allow: true)

    let answer = try status(sbd, card)

    let stored = try #require(try storedScripts(sbd, worker.id).first)
    #expect(answer["decision"]?.string == "approved", Comment(rawValue: answer.text))
    #expect(answer["schedule"]?.string == stored.id, Comment(rawValue: answer.text))
  }

  @Test func pendingWaitsForTheDecision() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var waited: Result<CommandResult, Error>?
    DispatchQueue(label: "pendingWaitsForTheDecision").async {
      waited = Result { try sbd.run(["schedule", "--pending", String(card), "--timeout", "30", "--json"]) }
      done.signal()
    }
    #expect(try status(sbd, card)["decision"]?.string == "pending")
    #expect(done.wait(timeout: .now() + 1) == .timedOut)

    try decide(sbd, .cli, worker.id, card, allow: true)

    #expect(done.wait(timeout: .now() + 30 * Instance.timeoutScale) == .success)
    let result = try #require(waited).get()
    let answer = try #require(JSON.parse(result.stdout))
    #expect(answer["decision"]?.string == "approved", Comment(rawValue: answer.text))
  }

  /// The Inbox's Allow sends `choose` from the app. sbd turns it into an `answer` with the app as the caller.
  @Test func chooseAllowFromTheAppStoresTheSchedule() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    _ = try propose(sbd, of: worker)

    _ = try sbd.client.call("choose", ["session": .string(worker.id), "option": "Allow"])

    #expect(try storedScripts(sbd, worker.id).map(\.prompt) == ["git fetch"])
    #expect(try scriptCards(sbd, worker.id).isEmpty)
  }

  /// The guard's parity: an approval stores what a terminal's add stores for the same values, except who wrote it.
  @Test func theApprovedScheduleEqualsTheOneATerminalAddStoresForTheSameValues() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let a = try sbd.idleSession(name: "a")
    let b = try sbd.idleSession(name: "b")
    let card = try propose(sbd, of: worker, for: a, "git fetch --prune", every: "2h", timeout: "5m")

    try decide(sbd, .app, worker.id, card, allow: true)
    let fromTerminal = try scripts.addScript(sbd, b.id, "git fetch --prune", every: "2h", timeout: "5m")

    let approved = try #require(try storedScripts(sbd, a.id).first)
    #expect(comparable(approved) == comparable(fromTerminal))
    #expect(approved.by == .claude)
    #expect(fromTerminal.by == .you)
  }

  @Test func anApprovedScriptRunsAsAScriptSchedule() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker, "echo approved")
    try decide(sbd, .cli, worker.id, card, allow: true)
    let stored = try #require(try storedScripts(sbd, worker.id).first)

    try scripts.runNow(sbd, stored.id)

    let last = try scripts.waitForRun(sbd, worker.id, stored.id)
    #expect(last.outcome == .ran, "\(last)")
    #expect(last.tail == "approved")
  }

  @Test func anApprovedEditChangesOnlyTheCommand() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try scripts.addScript(sbd, worker.id, "git fetch", every: "1h")
    let card = try proposeEdit(sbd, of: worker, made.id, ["git pull --rebase"])

    try decide(sbd, .app, worker.id, card, allow: true)

    let edited = try #require(try scripts.current(sbd, worker.id, made.id))
    #expect(edited.prompt == "git pull --rebase")
    #expect(edited.every == made.every)
    #expect(edited.timeout == made.timeout)
    #expect(try decided(sbd, worker.id).first?.data["decision"]?.string == "approved")
  }

  @Test func anApprovedTimeoutEditChangesOnlyTheTimeout() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try scripts.addScript(sbd, worker.id, "git fetch", every: "1h")
    let card = try proposeEdit(sbd, of: worker, made.id, ["--timeout", "2m"])

    try decide(sbd, .cli, worker.id, card, allow: true)

    let edited = try #require(try scripts.current(sbd, worker.id, made.id))
    #expect(edited.timeout == 120_000)
    #expect(edited.prompt == "git fetch")
  }

  // MARK: Deny

  @Test(arguments: Decider.allCases) func denyClosesTheCardAndStoresNothing(_ how: Decider) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    try decide(sbd, how, worker.id, card, allow: false)

    #expect(try scriptCards(sbd, worker.id).isEmpty)
    #expect(try sbd.get(worker.id).schedules == nil)
    #expect(try decided(sbd, worker.id).first?.data["decision"]?.string == "denied")
    #expect(try status(sbd, card)["decision"]?.string == "denied")
  }

  /// A deny stores nothing, so it follows the other cards' rules wherever it comes from.
  @Test func aDenyFromInsideTheProposersPaneClosesTheCard() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    let r = try unsetInPane(sbd, of: worker, ["deny", worker.id, "--card", String(card)], name: "deny-inside")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try scriptCards(sbd, worker.id).isEmpty)
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  // MARK: Approval is the user's alone (Risk 1)

  /// A session can unset CLAUDECODE, so sb's own check doesn't stop it. sbd's ancestry check does.
  @Test func anAllowFromTheProposersClaudePaneWithCLAUDECODEUnsetIsRefused() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    let r = try unsetInPane(sbd, of: worker, ["allow", worker.id, "--card", String(card)], name: "allow-inside")

    try expectRefusedAllow(r, sbd, card: card, on: worker, target: worker)
  }

  @Test func anAllowFromAnotherWorkSessionsPaneIsRefused() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let other = try sbd.idleSession(name: "other")
    let card = try propose(sbd, of: worker)

    let r = try unsetInPane(sbd, of: other, ["allow", worker.id, "--card", String(card)], name: "allow-other")

    try expectRefusedAllow(r, sbd, card: card, on: worker, target: worker)
  }

  /// Decision 29: a Manager conversation may add a script itself, but the card asks the user.
  @Test func anAllowFromAManagerConversationsPaneIsRefused() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let c = try waits.conversation(sbd)
    let card = try propose(sbd, of: worker)

    let r = try unsetInPane(sbd, of: c, ["allow", worker.id, "--card", String(card)], name: "allow-manager")

    try expectRefusedAllow(r, sbd, card: card, on: worker, target: worker)
  }

  @Test func anAllowFromAManagerConversationsPaneThatClaimsItIsRefused() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let c = try waits.conversation(sbd)
    let card = try propose(sbd, of: worker)

    // Only CLAUDECODE goes, so sb still claims the conversation from the pane's SB_SESSION_ID.
    let command = [
      "env", "-u", "CLAUDECODE", "SB_HOME=\(sbd.home.path)", "\(Instance.bin)/sb", "allow", worker.id, "--card",
      String(card),
    ]
    try sbd.writeScript("allow-claimed", command.map(shellQuote).joined(separator: " "))
    let r = try waits.runInPane(sbd, of: c, "allow-claimed")

    try expectRefusedAllow(r, sbd, card: card, on: worker, target: worker)
  }

  /// The same check runs in sbd for `choose`, so the Inbox's Allow from inside Claude is refused too.
  @Test func chooseAllowFromInsideClaudeIsRefused() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    let r = try unsetInPane(sbd, of: worker, ["choose", worker.id, "Allow"], name: "choose-inside")

    try expectRefusedAllow(r, sbd, card: card, on: worker, target: worker)
  }

  /// A script that the user added runs below its session's run, which places it inside that session. An open card
  /// holds every schedule of its session (Decision 7), so the proposer's own scripts wait while the card is open, and
  /// the run here is another session's. ScheduleScriptCallerTests places a client below a run of the proposer.
  @Test func anAllowFromBelowAnotherSessionsRunningScriptIsRefused() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let other = try sbd.idleSession(name: "other")
    let card = try propose(sbd, of: worker)
    let allow = scripts.sbCommand(sbd, unsetsCaller: true, ["allow", worker.id, "--card", String(card)])
    let made = try scripts.addScript(sbd, other.id, scripts.recorded(sbd, "run-allow", allow))

    try scripts.runNow(sbd, made.id)
    let r = try sbd.scriptResult("run-allow")

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try scriptCards(sbd, worker.id).map(\.id) == [card])
    #expect(try storedScripts(sbd, worker.id).isEmpty)
    #expect(try storedScripts(sbd, other.id).map(\.id) == [made.id])
  }

  // MARK: A decision is final, and the card's values are fixed (Risk 8)

  @Test(arguments: Decider.allCases) func aSecondAllowIsRefusedAndStoresOneSchedule(_ how: Decider) throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)
    try decide(sbd, .cli, worker.id, card, allow: true)

    #expect(throws: (any Error).self) { try decide(sbd, how, worker.id, card, allow: true) }

    #expect(try storedScripts(sbd, worker.id).count == 1)
    #expect(try decided(sbd, worker.id).count == 1)
  }

  @Test func aDenyAfterAnAllowIsRefusedAndKeepsTheSchedule() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)
    try decide(sbd, .cli, worker.id, card, allow: true)

    #expect(throws: (any Error).self) { try decide(sbd, .app, worker.id, card, allow: false) }

    #expect(try storedScripts(sbd, worker.id).count == 1)
    #expect(try status(sbd, card)["decision"]?.string == "approved")
  }

  /// The card names the target by id, so a rename changes where nothing runs.
  @Test func aTargetRenamedBeforeTheApprovalStillGetsTheSchedule() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let target = try sbd.idleSession(name: "target")
    let card = try propose(sbd, of: worker, for: target)
    try sbd.sb("rename", target.id, "renamed")

    try decide(sbd, .cli, worker.id, card, allow: true)

    #expect(try storedScripts(sbd, target.id).map(\.prompt) == ["git fetch"])
  }

  /// A proposal's values live in its event, so nothing the session sends after the card opened changes them.
  @Test func aRefusedSecondProposalLeavesTheFirstCardsValues() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker, "git fetch")
    _ = try proposeInPane(sbd, of: worker, "touch pwned", every: "1m", name: "second")

    try decide(sbd, .cli, worker.id, card, allow: true)

    let stored = try storedScripts(sbd, worker.id)
    #expect(stored.map(\.prompt) == ["git fetch"])
    #expect(stored.map(\.every) == [3_600_000])
  }

  @Test func theCardSurvivesARestartOfSbdAndAllowStillStores() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    sbd.killSbd()
    try sbd.startSbd()

    #expect(try scriptCards(sbd, worker.id).map(\.id) == [card])
    try decide(sbd, .cli, worker.id, card, allow: true)
    #expect(try storedScripts(sbd, worker.id).map(\.prompt) == ["git fetch"])
  }

  // MARK: Expiry

  @Test func aProposalExpiresAfterADay() throws {
    let sbd = try Instance(idleStopSeconds: 2 * 86_400)
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    try sbd.advanceClock(Self.expiryMs)

    #expect(try status(sbd, card)["decision"]?.string == "expired")
    #expect(try scriptCards(sbd, worker.id).isEmpty)
    let closing = try decided(sbd, worker.id)
    #expect(closing.first?.data["card"]?.int == Int(card))
    #expect(closing.first?.data["decision"]?.string == "expired")
    #expect(try sbd.get(worker.id).schedules == nil)
  }

  @Test func aProposalAMinuteBeforeItsExpiryStillWaits() throws {
    let sbd = try Instance(idleStopSeconds: 2 * 86_400)
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)

    try sbd.advanceClock(Self.expiryMs - 60_000)

    #expect(try status(sbd, card)["decision"]?.string == "pending")
    #expect(try scriptCards(sbd, worker.id).map(\.id) == [card])
  }

  @Test(arguments: Decider.allCases) func anAllowAfterExpiryIsRefusedAndStoresNothing(_ how: Decider) throws {
    let sbd = try Instance(idleStopSeconds: 2 * 86_400)
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker)
    try sbd.advanceClock(Self.expiryMs)

    #expect(throws: (any Error).self) { try decide(sbd, how, worker.id, card, allow: true) }

    #expect(try sbd.get(worker.id).schedules == nil)
    #expect(try status(sbd, card)["decision"]?.string == "expired")
  }

  // MARK: An allow whose values no longer hold

  /// Decision 28: the user changed the schedule's command after the card opened.
  @Test func anAllowOfAnEditWhoseCommandChangedSinceIsRefusedAsStale() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try scripts.addScript(sbd, worker.id, "git fetch")
    let card = try proposeEdit(sbd, of: worker, made.id, ["touch pwned"])
    try sbd.sb("schedule", "edit", made.id, "git fetch --prune")

    #expect(throws: (any Error).self) { try decide(sbd, .cli, worker.id, card, allow: true) }

    #expect(try scripts.current(sbd, worker.id, made.id)?.prompt == "git fetch --prune")
    #expect(try decided(sbd, worker.id).first?.data["decision"]?.string == "stale")
    #expect(try status(sbd, card)["decision"]?.string == "stale")
    #expect(try scriptCards(sbd, worker.id).isEmpty)
  }

  @Test func anAllowOfAnEditWhoseTimeoutChangedSinceIsRefusedAsStale() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try scripts.addScript(sbd, worker.id, "git fetch", every: "1h")
    let card = try proposeEdit(sbd, of: worker, made.id, ["touch pwned"])
    try sbd.sb("schedule", "edit", made.id, "--timeout", "3m")

    #expect(throws: (any Error).self) { try decide(sbd, .app, worker.id, card, allow: true) }

    #expect(try scripts.current(sbd, worker.id, made.id)?.prompt == "git fetch")
    #expect(try decided(sbd, worker.id).first?.data["decision"]?.string == "stale")
  }

  @Test func anAllowOfAnEditWhoseScheduleWasRemovedIsRefusedAsStale() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let made = try scripts.addScript(sbd, worker.id, "git fetch")
    let card = try proposeEdit(sbd, of: worker, made.id, ["touch pwned"])
    try sbd.sb("schedule", "rm", made.id)

    #expect(throws: (any Error).self) { try decide(sbd, .cli, worker.id, card, allow: true) }

    #expect(try sbd.get(worker.id).schedules == nil)
    #expect(try decided(sbd, worker.id).first?.data["decision"]?.string == "stale")
  }

  /// A target that reached `Schedule.maxPerSession` since the card opened. The card stays, so the user can remove
  /// a schedule and allow it again.
  @Test func anAllowForATargetThatNowHasTenSchedulesIsRefusedAndTheCardStays() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let target = try sbd.idleSession(name: "target")
    for i in 1..<Schedule.maxPerSession { try sbd.sb("schedule", target.id, "--every", "30m", "check \(i)") }
    let card = try propose(sbd, of: worker, for: target)
    try sbd.sb("schedule", target.id, "--every", "30m", "check the last")

    let r = try sbd.run(["allow", worker.id, "--card", String(card)])

    try expectRefusedAllow(r, sbd, card: card, on: worker, target: target)
    #expect(r.stderr.contains("\(Schedule.maxPerSession) schedules"), Comment(rawValue: r.stderr))
  }

  @Test func anAllowThatWouldDuplicateAScriptIsRefusedAndTheCardStays() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let card = try propose(sbd, of: worker, "git fetch")
    let made = try scripts.addScript(sbd, worker.id, "git fetch")

    let r = try sbd.run(["allow", worker.id, "--card", String(card)])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(made.id), Comment(rawValue: r.stderr))
    #expect(try scriptCards(sbd, worker.id).map(\.id) == [card])
    #expect(try storedScripts(sbd, worker.id).map(\.id) == [made.id])
  }

  @Test func anAllowForATargetThatWasRemovedIsRefused() throws {
    let sbd = try Instance()
    let worker = try sbd.idleSession(name: "worker")
    let target = try sbd.idleSession(name: "target")
    let card = try propose(sbd, of: worker, for: target)
    try sbd.sb("rm", target.id)
    try sbd.waitFor("the removal", timeout: 30) { try sbd.client.sessions().allSatisfy { $0.id != target.id } }

    let r = try sbd.run(["allow", worker.id, "--card", String(card)])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try sbd.client.sessions().allSatisfy { $0.id != target.id })
    #expect(try storedScripts(sbd, worker.id).isEmpty)
  }
}
