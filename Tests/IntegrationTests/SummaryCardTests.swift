import Foundation
import SwitchboardCore
import Testing

/// The spec's example of the card that a session writes.
private let specCard = """
  {
    "title": "Pick how to land #98",
    "summary": "Opened #98; CI is green.\\nTwo review items need a call.",
    "options": [
      {"label": "Fix items 3 and 5, then merge", "action": "send", "message": "Fix items 3 and 5, then merge.", "recommended": true},
      {"label": "Merge as is", "action": "merge"},
      {"label": "Wait for CI", "action": "wait", "wait": {"kind": "ci", "target": "98"}},
      {"label": "Skip", "action": "done"},
      {"label": "Something else", "action": "reply", "placeholder": "What should it do?"}
    ],
    "callouts": [{"kind": "warning", "title": "Drops events_old", "body": "The migration deletes the table."}]
  }
  """

/// A usage reading whose weekly limit is spent until 2099.
private let spentReading =
  #"{"limits":[{"kind":"weekly_all","percent":100,"resets_at":"2099-01-01T00:00:00+00:00"}]}"#

/// A card with one summary line and the given options.
private func cardText(_ options: [JSON], summary: String = "It finished.\nIt needs a call.") -> String {
  JSON.object(["summary": .string(summary), "options": .array(options)]).text
}

extension Instance {
  /// Writes the file that the stub's `card <name>` prompt pipes into
  /// `sb summary set` before its Stop.
  func writeCard(_ name: String, _ text: String) throws {
    try text.write(toFile: "\(home.path)/\(name).json", atomically: true, encoding: .utf8)
  }

  /// Runs `sb summary set` with `text` on stdin, whatever its exit status.
  func setSummary(_ args: [String], _ text: String, env extra: [String: String] = [:]) throws -> CommandResult {
    try runCommand(
      "\(Instance.bin)/sb", ["summary", "set"] + args, env: environment(extra), input: Data(text.utf8))
  }

  /// Runs `sb summary set` for the session and throws when it fails.
  @discardableResult
  func setSummary(_ id: String, _ text: String) throws -> CommandResult {
    let r = try setSummary([id], text)
    guard r.status == 0 else { throw TestError(description: "sb summary set failed: \(r.stderr)") }
    return r
  }

  /// A session whose first turn ended in "Done: hello", once the model's
  /// summary of that turn arrived. A card set now belongs to that turn.
  func endedSession() throws -> SessionSummary {
    let s = try new(prompt: "hello")
    return try waitFor(s.id, "the model's summary") { $0.triage?.source == .summary }
  }

  /// Waits until the session has at least `count` `triage` events, and
  /// returns them.
  func waitForTriageEvents(_ id: String, count: Int) throws -> [Event] {
    var found: [Event] = []
    try waitFor("\(count) triage events") {
      found = try events(id).filter { $0.kind == "triage" }
      return found.count >= count
    }
    return found
  }

  func sentTexts(_ id: String) throws -> [String] {
    try events(id).filter { $0.kind == "sent" }.compactMap { $0.data["text"]?.string }
  }
}

@Suite(.timeLimit(.minutes(2))) struct SummaryCardTests {
  // MARK: The session's card

  @Test func aSessionsCardBecomesTheItemWithItsButtonsAndNoModelCall() throws {
    let sbd = try Instance()
    try sbd.writeCard("c1", specCard)

    let s = try sbd.new(prompt: "card c1")

    let item = try #require(try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }.triage)
    #expect(item.title == "Pick how to land #98")
    #expect(item.summary == "Opened #98; CI is green.\nTwo review items need a call.")
    #expect(
      item.options.map(\.label) == [
        "Fix items 3 and 5, then merge", "Merge as is", "Wait for CI", "Skip", "Something else",
      ])
    #expect(item.options.map(\.action) == [.send, .merge, .wait, .done, .reply])
    #expect(item.primary?.label == "Fix items 3 and 5, then merge")
    #expect(item.options.last?.placeholder == "What should it do?")
    #expect(
      item.callouts == [Callout(kind: .warning, title: "Drops events_old", body: "The migration deletes the table.")])
    let skipped = try sbd.waitForTriageEvent(s.id)
    #expect(skipped.data["skipped"] != nil)
    #expect(sbd.summaryCalls().isEmpty)
  }

  @Test func aNewTurnDropsTheSessionsCard() throws {
    let sbd = try Instance()
    try sbd.writeCard("c1", specCard)
    let s = try sbd.new(prompt: "card c1")
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    try sbd.sb("send", s.id, "hello")

    let after = try sbd.waitFor(s.id, "the next turn's summary") {
      $0.lastReply == "Done: hello" && $0.triage?.source == .summary
    }
    #expect(after.triage?.title == "Read the reply")
    #expect(sbd.summaryCalls().count == 1)
  }

  @Test func aCardSetAfterTheStopBelongsToThatTurn() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()

    try sbd.setSummary(s.id, cardText([["label": "Go on", "action": "send", "message": "Go on."]]))

    let item = try #require(try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }.triage)
    #expect(item.options.map(\.label) == ["Go on"])
    #expect(item.title == "It finished.")
  }

  @Test func dropsAnOptionOutsideTheSetAndReportsIt() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    let text = cardText([
      ["label": "Go on", "action": "send", "message": "Go on."], ["label": "Dismiss it", "action": "dismiss"],
      ["label": "Allow it", "action": "allow"], ["label": "Answer it", "action": "answer"],
    ])

    let r = try sbd.setSummary([s.id], text)

    #expect(r.status == 0)
    for label in ["Dismiss it", "Allow it", "Answer it"] {
      #expect(r.stdout.contains(label), "\(label) is not reported: \(r.stdout)")
    }
    #expect(!r.stdout.contains("Go on\""))
    let item = try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }.triage
    #expect(item?.options.map(\.label) == ["Go on"])
    let recorded = try #require(try sbd.events(s.id).last { $0.kind == "summary" })
    #expect(recorded.data["options"]?.array?.count == 1)
  }

  @Test func reportsWhatItDroppedAsJSON() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    let text = cardText([["label": "Go on", "action": "send"], ["label": "Dismiss it", "action": "dismiss"]])

    let r = try sbd.setSummary(["--json", s.id], text)

    let result = try #require(JSON.parse(r.stdout))
    let dropped = try #require(result["dropped"]?.array)
    #expect(dropped.count == 1)
    #expect(dropped.first?.string?.contains("Dismiss it") == true)
  }

  @Test(arguments: [#"{"title":"No summary"}"#, #"{"summary":""}"#, #"{"summary":"  \n "}"#, "not json", "[]", ""])
  func refusesACardWithoutASummary(_ text: String) throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()

    let r = try sbd.setSummary([s.id], text)

    #expect(r.status != 0)
    #expect(try sbd.events(s.id).allSatisfy { $0.kind != "summary" })
    #expect(try sbd.get(s.id).triage?.source == .summary)
  }

  @Test func setsTheCardOfTheSessionInSB_SESSION_ID() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()

    let r = try sbd.setSummary([], cardText([["label": "Go on", "action": "send"]]), env: ["SB_SESSION_ID": s.id])

    #expect(r.status == 0)
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }
  }

  /// A card's buttons send text as the user, so a session can't put a card on another session.
  @Test func refusesAnotherSessionsCardInsideClaudeCode() throws {
    let sbd = try Instance()
    let target = try sbd.endedSession()
    let writer = try sbd.endedSession()

    let r = try sbd.setSummary(
      [target.id], cardText([["label": "Go on", "action": "send"]]),
      env: ["CLAUDECODE": "1", "SB_SESSION_ID": writer.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("only this session's card"))
    #expect(try sbd.get(target.id).triage?.source == .summary)
    #expect(try sbd.events(target.id).allSatisfy { $0.kind != "summary" })
  }

  @Test func refusesWithoutASessionOrSB_SESSION_ID() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()

    let r = try sbd.setSummary([], cardText([["label": "Go on", "action": "send"]]))

    #expect(r.status != 0)
    #expect(try sbd.events(s.id).allSatisfy { $0.kind != "summary" })
  }

  /// The card is data. A `send` option's message is text for the session,
  /// and nothing in the card runs when sbd records it.
  @Test func recordingACardRunsNothingInIt() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    let marker = "\(sbd.home.path)/ran"
    let options: [JSON] = [
      ["label": .string("$(touch \(marker))"), "action": "send", "message": .string("`touch \(marker)`")]
    ]
    let text = cardText(
      options,
      summary: "$(touch \(marker))\n`touch \(marker)`")

    try sbd.setSummary(s.id, text)

    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }
    #expect(!FileManager.default.fileExists(atPath: marker))
    #expect(try sbd.sentTexts(s.id).isEmpty)
  }

  @Test func aStaleClickOnAReplacedCardIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, cardText([["label": "First", "action": "send", "message": "First."]]))
    let seen = try #require(try sbd.waitFor(s.id, "the first card") { $0.triage?.source == .session }.triage)
    try sbd.setSummary(s.id, cardText([["label": "Second", "action": "send", "message": "Second."]]))
    try sbd.waitFor(s.id, "the second card") { $0.triage?.options.first?.label == "Second" }

    #expect(throws: APIError.self) {
      _ = try sbd.client.call("choose", ["session": .string(s.id), "option": "1", "ref": .string(seen.ref)])
    }

    #expect(try sbd.sentTexts(s.id).isEmpty)
  }

  // MARK: The model's summary

  @Test func withoutASessionsCardTheModelSummarizes() throws {
    let sbd = try Instance()

    let s = try sbd.new(prompt: "ask")

    let item = try sbd.waitFor(s.id, "the model's summary") { $0.triage?.source == .summary }.triage
    #expect(item?.options.map(\.action) == [.send, .send])
    #expect(sbd.summaryCalls().count == 1)
    #expect(try sbd.waitForTriageEvent(s.id).data["skipped"] == nil)
  }

  @Test func aSpentQuotaSkipsTheCallAndFallsBack() throws {
    let fake = try FakeUsage()
    fake.reply(spentReading)
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")
    _ = try sbd.usage()
    #expect(try sbd.usage(of: "A").budget().isSpent)

    let s = try sbd.new(prompt: "ask")

    let event = try sbd.waitForTriageEvent(s.id)
    #expect(event.data["skipped"]?.string?.isEmpty == false)
    #expect(sbd.summaryCalls().isEmpty)
    let item = try #require(try sbd.get(s.id).triage)
    #expect(item.source == .fallback)
    #expect(item.summary == "Which database should I use, Postgres or SQLite?")
  }

  /// `triage.account` names the account that pays for the call, so its
  /// quota decides, not the session's.
  @Test func aSpentSummaryAccountSkipsTheCallWhenTheSessionsAccountHasRoom() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.restart(setting: "triage", to: ["account": .string(sbd.account("B")), "systemPrompt": ""])
    try sbd.signIn("A", token: "token-a")
    try sbd.signIn("B", token: "token-b")
    fake.reply(to: "token-b", spentReading)
    _ = try sbd.usage()
    #expect(try sbd.usage(of: "B").budget().isSpent)
    #expect(try !sbd.usage(of: "A").budget().isSpent)

    let s = try sbd.new(prompt: "ask")

    #expect(try sbd.waitForTriageEvent(s.id).data["skipped"] != nil)
    #expect(sbd.summaryCalls().isEmpty)
  }

  @Test func aSummaryAccountWithRoomRunsTheCallWhenTheSessionsAccountIsSpent() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.restart(setting: "triage", to: ["account": .string(sbd.account("B")), "systemPrompt": ""])
    try sbd.signIn("A", token: "token-a")
    try sbd.signIn("B", token: "token-b")
    fake.reply(to: "token-a", spentReading)
    _ = try sbd.usage()
    #expect(try sbd.usage(of: "A").budget().isSpent)
    #expect(try !sbd.usage(of: "B").budget().isSpent)

    let s = try sbd.new(prompt: "ask")

    try sbd.waitFor(s.id, "the model's summary") { $0.triage?.source == .summary }
    #expect(sbd.summaryCalls().count == 1)
  }

  @Test func thePerHourLimitSkipsTheCallUntilTheHourPasses() throws {
    let sbd = try Instance(config: ["triage": ["perHour": 1, "systemPrompt": ""]])
    let s = try sbd.new(prompt: "ask")
    try sbd.waitFor(s.id, "the first summary") { $0.triage?.source == .summary }

    try sbd.sb("send", s.id, "ask")

    let second = try sbd.waitForTriageEvents(s.id, count: 2)[1]
    #expect(second.data["skipped"]?.string?.isEmpty == false)
    #expect(sbd.summaryCalls().count == 1)
    #expect(try sbd.get(s.id).triage?.source == .fallback)
    try sbd.advanceClock(3_600_000 + 1_000)
    try sbd.sb("send", s.id, "ask")
    let third = try sbd.waitForTriageEvents(s.id, count: 3)[2]
    #expect(third.data["skipped"] == nil)
    #expect(sbd.summaryCalls().count == 2)
  }

  // MARK: PR rules

  @Test func aReadyToMergePRBuildsItsCardWithoutTheModel() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    try sbd.restart(setting: "triage", to: ["enabled": false, "systemPrompt": ""])

    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()

    let item = try #require(try sbd.get(s.id).triage)
    #expect(item.source == .rule)
    #expect(item.options.map(\.label) == ["Merge #18303", "Dismiss"])
    #expect(item.options.map(\.action) == [.merge, .dismiss])
    #expect(item.primary?.action == .merge)
    #expect(sbd.summaryCalls().isEmpty)
  }

  @Test func aConflictBuildsARebaseCardWithoutTheModel() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    try sbd.restart(setting: "triage", to: ["enabled": false, "systemPrompt": ""])
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    github.change(MergeTests.number) { $0["mergeable"] = "CONFLICTING" }

    try sbd.poll(all: true)

    let item = try #require(try sbd.get(s.id).triage)
    #expect(item.source == .rule)
    #expect(item.options.map(\.label) == ["Rebase"])
    #expect(item.options.first?.action == .send)
    #expect(item.options.first?.message == "Rebase onto main, resolve the conflicts, and push.")
    #expect(item.callouts.first?.kind == .warning)
    #expect(sbd.summaryCalls().isEmpty)
  }

  @Test func aFailedMergeShowsGhsErrorOnTheCard() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    let error = "the base branch policy prohibits the merge"
    try sbd.ghMergeFails(with: error)

    _ = try sbd.run(["choose", s.id, "Merge #18303"])

    let item = try #require(try sbd.get(s.id).triage)
    #expect(item.options.map(\.action) == [.merge, .dismiss])
    #expect(item.callouts.contains { $0.kind == .warning && ($0.title + " " + $0.body).contains(error) })
  }

  @Test func aConflictAfterTheSessionsCardLeadsItsCallouts() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    try sbd.setSummary(s.id, cardText([["label": "Go on", "action": "send", "message": "Go on."]]))
    github.change(MergeTests.number) { $0["mergeable"] = "CONFLICTING" }

    try sbd.poll(all: true)

    let item = try #require(try sbd.get(s.id).triage)
    #expect(item.source == .session)
    #expect(item.options.map(\.label) == ["Go on", "Rebase"])
    let lead = try #require(item.callouts.first)
    #expect(lead.kind == .warning)
    #expect((lead.title + " " + lead.body).contains("#18303 conflicts with main"))
  }

  // MARK: Choosing

  @Test func choosingMergeRunsTheMerge() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()

    try sbd.sb("choose", s.id, "Merge #18303")

    #expect(sbd.ghMerges().count == 1)
    try sbd.waitFor("the post-merge message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id) == [MergeTests.message])
  }

  @Test func choosingDismissDismissesWithoutMerging() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()

    try sbd.sb("choose", s.id, "Dismiss")

    #expect(try sbd.get(s.id).state != .readyToMerge)
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test(arguments: ["Merge #18303", "Dismiss", "1", "2"])
  func chooseRefusesMergeAndDismissInsideClaudeCode(_ option: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()

    let r = try sbd.run(["choose", s.id, option], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(sbd.ghMerges().isEmpty)
    #expect(try sbd.get(s.id).state == .readyToMerge)
  }

  @Test func theInsideClaudeFlagRefusesAMergeOverTheSocket() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()

    #expect(throws: APIError.self) {
      _ = try sbd.client.call("choose", ["session": .string(s.id), "option": "1", "insideClaude": true])
    }

    #expect(sbd.ghMerges().isEmpty)
  }

  /// A merge option in a session's card runs the same merge, so Claude Code
  /// can't merge through a card that it wrote.
  @Test func chooseRefusesASessionCardsMergeInsideClaudeCode() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch)
    try sbd.poll()
    try sbd.setSummary(s.id, cardText([["label": "Ship it", "action": "merge"]]))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let r = try sbd.run(["choose", s.id, "Ship it"], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test func aSendOptionStillWorksInsideClaudeCode() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, cardText([["label": "Go on", "action": "send", "message": "Go on."]]))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let r = try sbd.run(["choose", s.id, "Go on"], env: ["CLAUDECODE": "1"])

    #expect(r.status == 0)
    try sbd.waitFor(s.id, "the reply to the choice") { $0.lastReply == "Done: Go on." }
  }

  @Test func choosingASessionCardsMergeRefusesASessionThatIsNotReady() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, cardText([["label": "Ship it", "action": "merge"]]))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let r = try sbd.run(["choose", s.id, "Ship it"])

    #expect(r.status != 0)
    #expect(try sbd.get(s.id).triage?.source == .session)
  }

  @Test func choosingSendSendsItsMessage() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, cardText([["label": "Go on", "action": "send", "message": "Go on, then push."]]))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    try sbd.sb("choose", s.id, "Go on")

    try sbd.waitFor(s.id, "the reply to the choice") { $0.lastReply == "Done: Go on, then push." }
    #expect(try sbd.sentTexts(s.id) == ["Go on, then push."])
  }

  @Test func choosingDoneMarksTheSessionDone() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, cardText([["label": "Skip", "action": "done"]]))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    try sbd.sb("choose", s.id, "Skip")

    let after = try sbd.waitFor(s.id, "done") { $0.state == .done }
    #expect(after.triage == nil)
    #expect(try sbd.sentTexts(s.id).isEmpty)
  }

  @Test func choosingWaitSetsTheOptionsWait() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    let wait: JSON = ["kind": "manual", "note": "check back after lunch"]
    try sbd.setSummary(s.id, cardText([["label": "Later", "action": "wait", "wait": wait]]))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    try sbd.sb("choose", s.id, "Later")

    let after = try sbd.waitFor(s.id, "the wait") { !$0.waits.isEmpty }
    #expect(after.waits.map(\.kind) == [.manual])
    #expect(after.waits.map(\.note) == ["check back after lunch"])
    #expect(after.state == .waiting)
    #expect(try sbd.sentTexts(s.id).isEmpty)
  }

  @Test func choosingReplySendsTheTypedText() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    let options: [JSON] = [
      ["label": "Go on", "action": "send"], ["label": "Something else", "action": "reply", "placeholder": "What?"],
    ]
    try sbd.setSummary(s.id, cardText(options))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    try sbd.sb("choose", s.id, "2", "--text", "Use SQLite.")

    try sbd.waitFor(s.id, "the reply to the choice") { $0.lastReply == "Done: Use SQLite." }
    #expect(try sbd.sentTexts(s.id) == ["Use SQLite."])
  }

  @Test(arguments: [[String](), ["--text", ""], ["--text", "   "]])
  func choosingReplyWithoutTextIsRefused(_ text: [String]) throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, cardText([["label": "Something else", "action": "reply"]]))
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let r = try sbd.run(["choose", s.id, "1"] + text)

    #expect(r.status != 0)
    #expect(try sbd.sentTexts(s.id).isEmpty)
  }
}
