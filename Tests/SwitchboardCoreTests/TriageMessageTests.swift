import Foundation
import Testing

@testable import SwitchboardCore

/// The session as the service builds it: its item, with the details that
/// need the session's own fields.
private func message(
  _ facts: SessionFacts, _ verdict: Verdict? = nil, reply: String? = nil, notes: [Note] = [], waits: [Wait] = [],
  pr: PRSummary? = nil
) -> TriageMessage? {
  let verdict = verdict ?? Attention.evaluate(session(), facts, now: 1000)
  var s = SessionSummary(
    id: "s1", name: "s1", cwd: "/", repo: nil, branch: nil, claudeSessionId: "s1", state: verdict.state,
    reason: verdict.reason, since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false,
    lastReply: reply ?? facts.lastReply, waits: waits, notes: notes, cards: facts.cards, pr: pr)
  s.triage = Triage.item(facts, verdict, kind: .work)
  let details = Triage.details(for: s)
  s.triage?.details = details
  return s.triage?.message
}

private let longCommand = "git push origin main && " + String(repeating: "echo done; ", count: 30) + "rm -rf build"

private func longCommandTurn() -> [Event] {
  let call = tool("Bash", ["command": .string(longCommand)], id: "b1")
  return promptTurn(call, tool("Bash", ["command": .string(longCommand)]))
}

@Suite struct TriageMessageSections {
  @Test func aPermissionCardPutsTheCallInSummaryAndTheButtonsInAction() throws {
    let m = try #require(message(facts(permissionTurn())))

    #expect(m.summary.text == "Claude asks to run `touch x`.")
    #expect(m.action.options.map(\.label) == ["Allow", "Deny"])
    #expect(m.action.primary == 0)
    #expect(m.details.toolInput == TriageDetails.ToolInput(tool: "Bash", text: "touch x"))
    #expect(m.details.openByDefault == false)
  }

  @Test func aCallThatTheSummaryCutsOpensDetailsWithTheWholeCall() throws {
    let m = try #require(message(facts(longCommandTurn())))

    #expect(m.summary.text.count < longCommand.count)
    #expect(m.summary.text.contains(String(longCommand.prefix(100))))
    #expect(m.details.toolInput?.text == longCommand)
    #expect(m.details.openByDefault)
  }

  @Test func aCommandOfTwoHundredCharactersFitsInTheSummary() throws {
    let command = String(repeating: "x", count: TriageCard.lineLength)
    let call = tool("Bash", ["command": .string(command)], id: "b1")
    let m = try #require(message(facts(promptTurn(call, tool("Bash", ["command": .string(command)])))))

    #expect(m.summary.text == "Claude asks to run `\(command)`.")
    #expect(m.details.openByDefault == false)
  }

  @Test func aToolWhoseSummaryNamesOnlyAFileOpensDetails() throws {
    let input: [String: JSON] = ["file_path": "/a/b.swift", "content": "let x = 1"]
    let call = tool("Write", input, id: "w1")
    let m = try #require(message(facts(promptTurn(call, tool("Write", input)))))

    #expect(m.summary.text == "Claude asks to run Write b.swift.")
    #expect(m.details.toolInput?.tool == "Write")
    #expect(m.details.toolInput?.text.contains("let x = 1") == true)
    #expect(m.details.openByDefault)
  }

  @Test func anEditCardWhoseHookClosedOpensDetailsWithTheWholeEdit() throws {
    let f = facts(editTurn() + [event("card_closed", 4, ["card": 3])])
    #expect(f.cards.map(\.hookClosed) == [true])
    let m = try #require(message(f))

    #expect(m.details.toolInput?.tool == "Edit")
    #expect(m.details.toolInput?.text.contains("\"old_string\" : \"beta\"") == true)
    #expect(m.details.toolInput?.text.contains("\"new_string\" : \"BETA\"") == true)
    #expect(m.details.openByDefault)
  }

  @Test func aShortCommandWithALineBreakOpensDetails() throws {
    let command = "cd build\nrm -rf out"
    let call = tool("Bash", ["command": .string(command)], id: "b1")
    let m = try #require(message(facts(promptTurn(call, tool("Bash", ["command": .string(command)])))))

    #expect(m.details.toolInput?.text.contains("rm -rf out") == true)
    #expect(m.details.openByDefault)
  }

  /// The app draws the Summary as GitHub Flavored Markdown. A command that
  /// Markdown would cut, restyle, or hide still shows as one code span that
  /// holds the whole command, so Details stays closed.
  @Test(arguments: [
    "echo `date`", "echo ``two``", "`", "printf '%s' a``b`c", " ls ", "echo  two  spaces",
    "echo *not emphasis* and _this_", "echo <b>x</b> <!-- hidden -->", "echo [a](https://x.example)",
    "echo \\`x\\`", "echo a\tb", "x | y | z",
  ])
  func theSummaryShowsTheWholeCommand(_ command: String) throws {
    let call = tool("Bash", ["command": .string(command)], id: "b1")
    let m = try #require(message(facts(promptTurn(call, tool("Bash", ["command": .string(command)])))))

    #expect(!m.details.openByDefault, "\(command)")
    let blocks = MarkdownBlock.parse(m.summary.text)
    guard case .paragraph(let text) = try #require(blocks.first), blocks.count == 1 else {
      Issue.record("the Summary is not one paragraph: \(blocks)")
      return
    }
    #expect(text.runs.filter { $0.style.contains(.code) }.map(\.text) == [command])
  }

  @Test func aCommandThatMarkdownWouldRestyleStillShowsInTheSummary() throws {
    for command in ["echo `date`", "echo ``two``", "echo *x*", " ls ", "echo  two  spaces"] {
      let call = tool("Bash", ["command": .string(command)], id: "b1")
      let m = try #require(message(facts(promptTurn(call, tool("Bash", ["command": .string(command)])))))
      #expect(m.details.openByDefault == false, "\(command)")
    }
  }

  @Test func aQuestionCardPutsTheQuestionInSummaryAndTheOptionsInAction() throws {
    let one: JSON = [
      "questions": [["question": "Which fruit?", "options": [["label": "apple"], ["label": "cherry"]]]]
    ]
    let m = try #require(message(facts(promptTurn(ask(one), ask(one, id: nil)))))

    #expect(m.summary.text == "Which fruit?")
    #expect(m.action.options.map(\.label) == ["apple", "cherry"])
    #expect(m.action.primary == nil)
    #expect(m.details.toolInput == nil)
    #expect(m.details.openByDefault == false)
  }

  @Test func aSessionCardPutsItsLinesAndCalloutsInSummaryAndItsOptionsInAction() throws {
    var f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    let own = TriageSummary(
      title: "Pick how to land #98", kind: .decision, summary: "Opened #98.\nTwo items need a call.",
      options: [
        TriageOption(label: "Fix", message: "Fix them.", recommended: true),
        TriageOption(label: "Merge", action: .merge),
      ], callouts: [Callout(kind: .warning, title: "Drops events_old", body: "The migration deletes it.")])
    f.apply(event("summary", 2, try #require(JSON(encoding: own).object)))
    f.apply(event("Stop", 3, ["last_assistant_message": "All the details."]))

    let m = try #require(message(f, Verdict(state: .needsYou, reason: "read it", source: .reply)))

    #expect(m.summary.text == "Opened #98.\nTwo items need a call.")
    #expect(m.summary.callouts.map(\.title) == ["Drops events_old"])
    #expect(m.action.options.map(\.label) == ["Fix", "Merge"])
    #expect(m.action.primary == 0)
    #expect(m.details.lastReply == "All the details.")
  }

  @Test func aProseReplyWithNoSummaryPutsItsLastParagraphInSummaryAndTheWholeReplyInDetails() throws {
    var f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    f.apply(stop(1, 5, proseQuestion))

    let m = try #require(message(f, Attention.replyVerdict(proseQuestion)))

    #expect(m.summary.text == "Which database should I use, Postgres or SQLite?")
    #expect(m.action.options.isEmpty)
    #expect(m.details.lastReply == proseQuestion)
  }

  @Test func aRuleWithOptionsGivesThemToAction() throws {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    let rule = Verdict(
      state: .needsYou, reason: "rebase; #9 conflicts with main",
      options: [TriageOption(label: "Rebase", message: "Rebase onto main.")],
      callouts: [Callout(kind: .warning, title: "#9 conflicts with main")])

    let m = try #require(message(f, rule))

    #expect(m.summary.text == "Rebase; #9 conflicts with main.")
    #expect(m.summary.callouts.map(\.title) == ["#9 conflicts with main"])
    #expect(m.action.options.map(\.label) == ["Rebase"])
    #expect(m.action.primary == 0)
  }

  @Test func detailsHoldTheWaitsNotesAndPR() throws {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    let rule = Verdict(state: .needsYou, reason: "tidy the folder", kind: .review)
    let note = Note(id: "n1", text: "Check the logs", by: .you, t: 1)
    let wait = Wait(id: "w1", kind: .manual, note: "later", created: 1)
    let pr = PRSummary(samplePR())

    let m = try #require(message(f, rule, notes: [note], waits: [wait], pr: pr))

    #expect(m.details.notes == ["Check the logs"])
    #expect(m.details.waits == [wait.line])
    #expect(m.details.pullRequest == .init(line: pr.line, title: pr.title, url: pr.url))
  }

  @Test func aGroupMessageCardPutsItsTargetsAndTextInDetails() throws {
    var f = facts(permissionTurn())
    var card = f.cards[0]
    card.send = GroupMessage(
      group: "g1", groupName: "inbox", text: "Rebase now.",
      targets: [GroupSend.Target(id: "s2", name: "alpha"), GroupSend.Target(id: "s3", name: "beta")], expires: 9)
    f.cards = [card]

    let m = try #require(message(f))

    #expect(
      m.summary.text == "Claude asks to send a message to 2 sessions in inbox. Nothing is sent until you send it.")
    #expect(m.action.options.map(\.label) == ["Send", "Cancel"])
    #expect(m.details.targets == ["alpha (s2)", "beta (s3)"])
    #expect(m.details.toolInput?.text == "Rebase now.")
    #expect(m.details.openByDefault)
  }
}

@Suite struct TriageMessageJSON {
  private func encoded(_ m: TriageMessage) throws -> JSON { try JSON(encoding: m) }

  @Test func theSectionsHaveStableFieldNames() throws {
    let m = try #require(message(facts(permissionTurn())))
    let json = try encoded(m)

    #expect(Set(json.object?.keys.map { $0 } ?? []) == ["summary", "action", "details"])
    #expect(json["summary"]?["text"]?.string == "Claude asks to run `touch x`.")
    #expect(json["summary"]?["callouts"]?.array?.isEmpty == true)
    #expect(json["action"]?["options"]?.array?.count == 2)
    #expect(json["action"]?["multiSelect"]?.bool == false)
    #expect(json["action"]?["primary"]?.int == 0)
    #expect(json["details"]?["openByDefault"]?.bool == false)
    #expect(json["details"]?["toolInput"]?["tool"]?.string == "Bash")
    #expect(json["details"]?["toolInput"]?["text"]?.string == "touch x")
  }

  @Test func aDetailsPartThatDoesNotExistIsLeftOut() throws {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    let m = try #require(message(f, Verdict(state: .needsYou, reason: "tidy the folder", kind: .review)))
    let details = try #require(try encoded(m)["details"]?.object)

    #expect(Set(details.keys.map { $0 }) == ["openByDefault"])
  }

  @Test func primaryIsNullWhenNoOptionIsTheMainOne() throws {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    let rule = Verdict(
      state: .needsYou, reason: "pick",
      options: [TriageOption(label: "a", message: "a"), TriageOption(label: "b", message: "b")])
    let m = try #require(message(f, rule))

    #expect(try encoded(m)["action"]?["primary"] == .null)
  }

  @Test func theItemEncodesTheMessageBesideItsFlatFields() throws {
    var f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    f.apply(stop(1, 5, proseQuestion))
    let item = try #require(Triage.item(f, Attention.replyVerdict(proseQuestion), kind: .work))
    let json = try JSON(encoding: item)

    #expect(json["summary"]?.string == item.summary)
    #expect(json["message"]?["summary"]?["text"]?.string == item.summary)
    #expect(json["message"]?["action"]?["options"]?.array?.count == item.options.count)
  }

  @Test func theActionCarriesTheItemsDecisions() throws {
    let decision = PendingDecision(
      number: 2, header: "Name", question: "What is it called?",
      options: [.init(label: "to-do", recommended: true), .init(label: "follow-up")])
    let item = TriageItem(
      title: "Answer", kind: .decision, summary: "It planned.\nIt needs decisions.", decisions: [decision],
      source: .session)

    #expect(item.message.action.decisions == [decision])
    let json = try #require(JSON.parse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self)))
    #expect(json["message"]?["action"]?["decisions"]?.array?.first?["header"]?.string == "Name")
    #expect(json["decisions"] == json["message"]?["action"]?["decisions"])
    #expect(try JSONDecoder().decode(TriageItem.self, from: try JSONEncoder().encode(item)) == item)
  }

  @Test func anItemWithoutDecisionsHasAnEmptyDecisionsArray() throws {
    let item = TriageItem(title: "t", kind: .info, summary: "s", source: .session)
    let json = try #require(JSON.parse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self)))

    #expect(json["message"]?["action"]?["decisions"]?.array?.isEmpty == true)
  }

  @Test func theItemRoundTripsWithItsDetails() throws {
    var built = try #require(item(facts(longCommandTurn())))
    built.details = TriageDetails(
      openByDefault: true, lastReply: "reply", toolInput: .init(tool: "Bash", text: "ls"),
      pullRequest: .init(line: "#9 Open", title: "T", url: "https://github.com/o/r/pull/9"), waits: ["w"],
      notes: ["n"], targets: ["a (s2)"])

    let decoded = try JSONCoding.convert(try JSON(encoding: built), to: TriageItem.self)

    #expect(decoded == built)
  }

  @Test func anItemFromAnOlderSbdHasNoDetails() throws {
    let old: JSON = [
      "title": "t", "kind": "info", "summary": "s", "options": [], "callouts": [], "source": "rule", "ref": "r",
    ]

    let decoded = try JSONCoding.convert(old, to: TriageItem.self)

    #expect(decoded.details == TriageDetails())
    #expect(decoded.message.summary.text == "s")
  }
}

@Suite struct TriageSummaryRule {
  @Test func aSummaryKeepsItsFirstThreeLines() throws {
    let raw: JSON = ["summary": "a\n\nb\nc\nd"]

    let result = try TriageCard.clean(raw)

    #expect(TriageCard.summaryLines == 3)
    #expect(result.card.summary == "a\nb\nc")
    #expect(result.dropped == ["lines after the first 3 of the summary"])
  }

  @Test func theInstructionsStateTheRuleForTheSummary() {
    #expect(TriageCard.instructions.contains("Details"))
    #expect(TriageSummarizer.system.contains("Details"))
    #expect(TriageCard.instructions.contains("Two to three lines"))
    #expect(TriageSummarizer.system.contains("two to three lines"))
  }
}

@Suite struct PRSummaryHead {
  static func pr(head: String) -> PullRequest {
    PullRequest(
      id: "PR_1", number: 18303, url: "https://github.com/PostHog/charts/pull/18303", repo: "PostHog/charts", head: head
    )
  }

  @Test func carriesThePRsHeadBranch() {
    #expect(PRSummary(Self.pr(head: "haacked/x")).head == "haacked/x")
  }

  @Test func anEmptyHeadIsNil() {
    #expect(PRSummary(Self.pr(head: "")).head == nil)
  }

  @Test func decodesJSONThatAnOlderSbdWroteWithoutAHead() throws {
    let summary = PRSummary(Self.pr(head: "haacked/x"))
    var object = try #require(try JSON(encoding: summary).object)
    object["head"] = nil

    let decoded = try JSONCoding.convert(JSON.object(object), to: PRSummary.self)

    #expect(decoded.head == nil)
    #expect(decoded.number == 18303)
  }

  @Test func otherBranchIsTheHeadWhenItDiffers() {
    #expect(PRSummary(Self.pr(head: "haacked/x")).otherBranch(than: "haacked/x-v2") == "haacked/x")
  }

  @Test(arguments: [("haacked/x", "haacked/x"), ("", "haacked/x-v2")])
  func otherBranchIsNilWhenTheHeadMatchesOrIsUnknown(_ head: String, _ branch: String) {
    #expect(PRSummary(Self.pr(head: head)).otherBranch(than: branch) == nil)
  }
}

/// The callout that says which branch the session's PR uses.
@Suite struct TriageBranchCallout {
  static let expected = Callout(kind: .info, title: "#18303 uses haacked/x", body: "This folder is on haacked/x-v2.")

  static func session(
    title: String, summary: String = "", source: TriageSource = .fallback, branch: String = "haacked/x-v2",
    head: String? = "haacked/x"
  ) -> SessionSummary {
    let pr = head.map {
      PRSummary(
        PullRequest(
          id: "PR_1", number: 18303, url: "https://github.com/PostHog/charts/pull/18303", repo: "PostHog/charts",
          head: $0))
    }
    var s = SessionSummary(
      id: "s1", name: "s1", cwd: "/", repo: "PostHog/charts", branch: branch, claudeSessionId: "s1",
      state: .canContinue, reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false,
      lastReply: nil, waits: [], notes: [], pr: pr)
    s.triage = TriageItem(title: title, kind: .approval, summary: summary, source: source)
    return s
  }

  @Test(arguments: [
    "Delete the branch haacked/x-v2?",
    "Delete haacked/x-v2",
    "Delete haacked/x-v2.",
    "Delete haacked/x-v2. Then push.",
    "Delete `haacked/x-v2`?",
    "Delete it (haacked/x-v2)?",
    "Merge haacked/x into main?",
    "Merge `haacked/x`?",
  ])
  func aTitleThatNamesEitherBranchGetsTheCallout(_ title: String) {
    #expect(Triage.branchCallout(for: Self.session(title: title)) == Self.expected)
  }

  @Test func aSummaryThatNamesEitherBranchGetsTheCallout() {
    let s = Self.session(
      title: "Delete it?",
      summary: "The `haacked/x-v2` branch still exists on origin with the same commits. Do you want me to delete it?")

    #expect(Triage.branchCallout(for: s) == Self.expected)
  }

  /// A longer name holds the branch's name, but it is another branch.
  @Test(arguments: [
    "Delete haacked/x-v2-old?",
    "Open haacked/x-v2.md?",
    "Delete haacked/x-v22?",
    "Delete haacked/x-v2_tmp?",
    "Push origin/haacked/x-v2?",
    "Delete my_haacked/x-v2?",
    "Delete xhaacked/x-v2?",
    "Delete 1haacked/x-v2?",
    "Delete -haacked/x-v2?",
    "Delete haacked/x-old?",
    "Run the tests?",
  ])
  func aTitleThatNamesNeitherBranchAsAWholeTokenGetsNone(_ title: String) {
    #expect(Triage.branchCallout(for: Self.session(title: title)) == nil)
  }

  @Test(arguments: [TriageSource.card, .session, .rule, .summary, .fallback])
  func everyItemSourceGetsTheCallout(_ source: TriageSource) {
    let s = Self.session(title: "Approve `git push origin --delete haacked/x-v2`", source: source)

    #expect(Triage.branchCallout(for: s) == Self.expected)
  }

  @Test func aPRWhoseHeadIsTheFoldersBranchGetsNone() {
    let s = Self.session(title: "Delete haacked/x-v2?", head: "haacked/x-v2")

    #expect(Triage.branchCallout(for: s) == nil)
  }

  @Test(arguments: [nil, ""] as [String?])
  func aSessionWithoutAPRHeadGetsNone(_ head: String?) {
    #expect(Triage.branchCallout(for: Self.session(title: "Delete haacked/x-v2?", head: head)) == nil)
  }

  @Test func aSessionWithoutAnItemGetsNone() {
    var s = Self.session(title: "Delete haacked/x-v2?")
    s.triage = nil

    #expect(Triage.branchCallout(for: s) == nil)
  }
}
