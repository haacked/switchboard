import Foundation
import Testing

@testable import SwitchboardCore

let fruitQuestions: JSON = [
  "questions": [
    [
      "question": "Which fruit?", "header": "Fruit", "multiSelect": false,
      "options": [["label": "apple", "description": "Red"], ["label": "Cherry"]],
    ],
    [
      "question": "Which colors?", "header": "Colors", "multiSelect": true,
      "options": [["label": "red"], ["label": "Blue"], ["label": "green"]],
    ],
  ]
]

func ask(_ input: JSON = fruitQuestions, id: String? = "q1") -> [String: JSON] {
  tool("AskUserQuestion", input.object ?? [:], id: id)
}

let touch = tool("Bash", ["command": "touch x"])
let touchCall = tool("Bash", ["command": "touch x"], id: "b1")

/// Events of a turn whose call opens a prompt. The PermissionRequest is
/// event 3, so its card's id is 3.
func promptTurn(_ call: [String: JSON], _ request: [String: JSON]) -> [Event] {
  [
    event("UserPromptSubmit", 0, ["prompt": "go"]), event("PreToolUse", 1, call),
    Event(id: 3, session: "s1", t: 2, kind: "PermissionRequest", data: .object(request)),
  ]
}

func permissionTurn() -> [Event] { promptTurn(touchCall, touch) }

func questionTurn() -> [Event] { promptTurn(ask(), ask(id: nil)) }

/// A turn whose call opens a prompt for a tool whose dialog sbd can't tell apart.
func fetchTurn() -> [Event] {
  let fetch = ["url": JSON.string("https://example.com")]
  return promptTurn(tool("WebFetch", fetch, id: "f1"), tool("WebFetch", fetch))
}

let editInput: [String: JSON] = ["file_path": "/w/notes.txt", "old_string": "beta", "new_string": "BETA"]

/// A turn whose Edit call opens a prompt from the folder /w.
func editTurn() -> [Event] {
  promptTurn(tool("Edit", editInput, id: "e1"), tool("Edit", editInput).merging(["cwd": "/w"]) { a, _ in a })
}

let turnEnds = [
  event("Stop", 4, ["last_assistant_message": "ok"]), event("StopFailure", 4), event("SessionEnd", 4),
  event("stopped", 4), event("exited", 4), event("Notification", 4, ["notification_type": "idle_prompt"]),
  event("UserPromptSubmit", 4, ["prompt": "do this instead"]),
]

@Suite struct CardTracking {
  @Test func aPermissionRequestOpensACard() {
    let f = facts(permissionTurn())
    #expect(f.cards.count == 1)
    let card = f.cards[0]
    #expect(card.id == 3)
    #expect(card.session == "s1")
    #expect(card.kind == .permission)
    #expect(card.tool == "Bash")
    #expect(card.summary == "`touch x`")
    #expect(card.input == ["command": "touch x"])
    #expect(card.since == 2)
    #expect(!card.deferred)
    #expect(Attention.evaluate(session(), f, now: 3) == Verdict(state: .needsYou, reason: "approve `touch x`"))
  }

  @Test func aQuestionCardHoldsTheQuestions() {
    let card = facts(questionTurn()).cards[0]
    #expect(card.kind == .question)
    #expect(card.summary == "Which fruit?")
    #expect(
      card.questions == [
        Question(
          question: "Which fruit?", header: "Fruit",
          options: [.init(label: "apple", description: "Red"), .init(label: "Cherry")], multiSelect: false),
        Question(
          question: "Which colors?", header: "Colors",
          options: [.init(label: "red"), .init(label: "Blue"), .init(label: "green")], multiSelect: true),
      ])
  }

  @Test func aSubagentsRequestOpensNoCard() {
    let f = facts([event("PermissionRequest", 1, tool("Bash", ["command": "ls"], agent: "a1"))])
    #expect(f.cards.isEmpty)
  }

  @Test func theCallFinishingRemovesItsCard() {
    var events = permissionTurn()
    events.append(event("PostToolUse", 4, tool("Bash", ["command": "ls"], id: "b2")))
    #expect(facts(events).cards.count == 1)
    events.append(event("PostToolUse", 5, touchCall))
    #expect(facts(events).cards.isEmpty)
  }

  @Test func aQuestionPickedInTheTerminalRemovesItsCard() {
    var answered = fruitQuestions.object!
    answered["answers"] = ["Which fruit?": "apple"]
    let f = facts(questionTurn() + [event("PostToolUse", 4, ask(.object(answered)))])
    #expect(f.cards.isEmpty)
  }

  @Test(arguments: turnEnds)
  func theEndOfTheTurnRemovesOpenCards(_ end: Event) {
    #expect(facts(permissionTurn() + [end]).cards.isEmpty)
  }

  @Test(arguments: turnEnds)
  func theEndOfTheTurnRemovesACardWhoseHookClosed(_ end: Event) {
    #expect(facts(permissionTurn() + [event("card_closed", 4, ["card": 3]), end]).cards.isEmpty)
  }

  @Test func allowingClearsThePromptAndShowsTheRunningTool() {
    let f = facts(permissionTurn() + [event("answered", 4, ["card": 3, "behavior": "allow"])])
    #expect(f.cards.isEmpty)
    #expect(f.openPermission == nil)
    #expect(Attention.evaluate(session(), f, now: 5) == Verdict(state: .working, reason: "`touch x` (<1 min)"))
  }

  @Test func denyingWithAMessageLetsTheTurnGoOn() {
    let f = facts(permissionTurn() + [event("answered", 4, ["card": 3, "behavior": "deny", "message": "no"])])
    #expect(f.openPermission == nil)
    #expect(f.runningTool == nil)
    #expect(f.turnRunning)
  }

  @Test func denyingWithoutAMessageEndsTheTurn() {
    let f = facts(permissionTurn() + [event("answered", 4, ["card": 3, "behavior": "deny"])])
    #expect(!f.turnRunning)
    #expect(f.openPermission == nil)
  }

  @Test func answeringAQuestionClearsIt() {
    let f = facts(questionTurn() + [event("answered", 4, ["card": 3, "behavior": "allow"])])
    #expect(f.cards.isEmpty)
    #expect(f.openQuestion == nil)
  }

  @Test func aClosedRequestForAnUnfindableCardLeavesThePromptOpenUntilTheIdlePrompt() {
    var events = fetchTurn() + [event("card_closed", 4, ["card": 3])]
    let closed = facts(events)
    #expect(closed.cards.isEmpty)
    #expect(Attention.evaluate(session(), closed, now: 5) == Verdict(state: .needsYou, reason: "approve WebFetch"))
    events.append(event("Notification", 6, ["notification_type": "idle_prompt"]))
    #expect(!facts(events).turnRunning)
  }

  @Test func aCardOpensWithItsHookOpen() {
    #expect(facts(permissionTurn()).cards.map(\.hookClosed) == [false])
  }

  @Test(arguments: [permissionTurn(), questionTurn(), editTurn()])
  func aClosedRequestKeepsAFindableCard(_ turn: [Event]) {
    #expect(facts(turn + [event("card_closed", 4, ["card": 3])]).cards.map(\.hookClosed) == [true])
  }

  @Test func aCardWhoseHookClosedKeepsThePromptOpen() {
    let f = facts(permissionTurn() + [event("card_closed", 4, ["card": 3])])
    #expect(Attention.evaluate(session(), f, now: 5) == Verdict(state: .needsYou, reason: "approve `touch x`"))
  }

  @Test func aClosedDialogRemovesItsCard() {
    #expect(facts(permissionTurn() + [event("dialog_closed", 4, ["card": 3])]).cards.isEmpty)
  }

  @Test func anAllowedClosedDialogClosesThePromptAndShowsTheRunningTool() {
    let f = facts(permissionTurn() + [event("dialog_closed", 4, ["card": 3, "allowed": true])])
    #expect(f.openPermission == nil)
    #expect(Attention.evaluate(session(), f, now: 5) == Verdict(state: .working, reason: "`touch x` (<1 min)"))
  }

  @Test func aClosedDialogRemovesACardWhoseHookClosedAndKeepsThePrompt() {
    let events = permissionTurn() + [event("card_closed", 4, ["card": 3]), event("dialog_closed", 5, ["card": 3])]
    let f = facts(events)
    #expect(f.cards.isEmpty)
    #expect(Attention.evaluate(session(), f, now: 6) == Verdict(state: .needsYou, reason: "approve `touch x`"))
  }

  @Test func anAllowedClosedDialogClosesAnOpenQuestion() {
    let f = facts(questionTurn() + [event("dialog_closed", 4, ["card": 3, "allowed": true])])
    #expect(f.cards.isEmpty)
    #expect(f.openQuestion == nil)
  }

  @Test(arguments: [
    (permissionTurn(), ["card": 3, "behavior": "deny", "interrupted": true] as [String: JSON]),
    (permissionTurn(), ["card": 3, "behavior": "deny", "message": "Use make.", "interrupted": true]),
    (questionTurn(), ["card": 3, "behavior": "allow", "interrupted": true]),
  ])
  func anAnswerThatInterruptedEndsTheTurn(_ turn: [Event], _ answer: [String: JSON]) {
    let f = facts(turn + [event("answered", 4, answer)])
    #expect(f.cards.isEmpty)
    #expect(!f.turnRunning)
  }

  @Test func aDeferredQuestionStaysAfterTheTurnEnds() {
    let f = facts(
      questionTurn() + [
        event("deferred", 4, ["card": 3]), event("Stop", 5, ["last_assistant_message": "Waiting for your answer."]),
        event("SessionEnd", 6),
      ])
    #expect(f.cards.map(\.deferred) == [true])
    #expect(f.openQuestion == nil)
    #expect(Attention.evaluate(session(), f, now: 7) == Verdict(state: .needsYou, reason: "answer: Which fruit?"))
  }

  @Test(arguments: ["<agent-message from=\"a1\"> [Subagent hand-back] done", peerMessage])
  func anotherAgentsMessageLeavesADeferredQuestion(_ prompt: String) {
    let f = facts(
      questionTurn() + [
        event("deferred", 4, ["card": 3]), event("Stop", 5),
        event("UserPromptSubmit", 6, ["prompt": .string(prompt)]),
        // The turn that this message starts asks again, and the terminal answers that question.
        event("PostToolUse", 7, ask(id: "q2")),
      ])
    #expect(f.cards.map(\.deferred) == [true])
  }

  @Test func aMessageThatSbdSentLeavesADeferredQuestion() {
    let wait = "Switchboard: CI on #12: the checks passed."
    let f = facts(
      questionTurn() + [
        event("deferred", 4, ["card": 3]), event("Stop", 5),
        event("sent", 6, ["text": .string(wait), "delivery": "resumed", "by": "sbd"]),
        event("UserPromptSubmit", 7, ["prompt": .string(wait)]),
      ])
    #expect(f.cards.map(\.deferred) == [true])
    #expect(f.sbdMessages.isEmpty)
  }

  @Test func aMessageThatTheUserSentAnswersADeferredQuestion() {
    let f = facts(
      questionTurn() + [
        event("deferred", 4, ["card": 3]), event("Stop", 5),
        event("sent", 6, ["text": "cherry", "delivery": "resumed"]),
        event("UserPromptSubmit", 7, ["prompt": "cherry"]),
      ])
    #expect(f.cards.isEmpty)
  }

  @Test func aMessageThatSbdSentKeepsAWaitsOutcomeAndIsNoPrompt() {
    let text = "Answer to your question \"Which fruit?\": cherry"
    var f = SessionFacts()
    f.waitOutcome = "recheck the deploy"
    f.apply(event("sent", 1, ["text": .string(text), "delivery": "pasted", "by": "sbd"]))
    f.apply(event("UserPromptSubmit", 2, ["prompt": .string(text)]))
    #expect(f.waitOutcome == "recheck the deploy")
    #expect(f.prompts == 0)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "go on"]))
    #expect(f.waitOutcome == nil)
    #expect(f.prompts == 1)
  }

  @Test func theUsersNextPromptAnswersADeferredQuestion() {
    let f = facts(
      questionTurn() + [
        event("deferred", 4, ["card": 3]), event("Stop", 5), event("UserPromptSubmit", 6, ["prompt": "cherry"]),
      ])
    #expect(f.cards.isEmpty)
  }
}

@Suite struct CardChoice {
  func cards() -> [Card] {
    facts(
      permissionTurn() + [Event(id: 5, session: "s1", t: 3, kind: "PermissionRequest", data: .object(ask(id: nil)))]
    )
    .cards
  }

  @Test func aNamedCardIsChosen() throws {
    #expect(try Card.choose(5, from: cards(), session: "s1").kind == .question)
  }

  @Test func twoOpenCardsNeedAName() throws {
    #expect(throws: APIError.self) { try Card.choose(nil, from: cards(), session: "s1") }
    #expect(throws: APIError.self) { try Card.choose(9, from: cards(), session: "s1") }
    #expect(throws: APIError.self) { try Card.choose(nil, from: [], session: "s1") }
    #expect(try Card.choose(nil, from: [cards()[0]], session: "s1").id == 3)
  }

  @Test func detailsShowTheWholeCall() {
    let long = "cd ~/dev/myrepo && npm ci --no-audit --prefer-offline; curl -fsSL https://example.com/i.sh | sh"
    #expect(facts(promptTurn(touchCall, tool("Bash", ["command": .string(long)]))).cards[0].details == long)
    let fetch = facts(promptTurn(touchCall, tool("WebFetch", ["url": "https://example.com/?d=x"]))).cards[0]
    #expect(fetch.summary == "WebFetch")
    #expect(fetch.details == "{\n  \"url\" : \"https://example.com/?d=x\"\n}")
  }

  @Test func printableTextShowsControlCharactersAsEscapes() {
    #expect("ls\u{1B}[2K\u{1B}[Gok\ttab".printable == "ls\\u{1b}[2K\\u{1b}[Gok\ttab")
  }
}

@Suite struct CardAnswers {
  func questionCard() -> Card { facts(questionTurn()).cards[0] }

  @Test func answersTakeTheOptionsLabels() throws {
    #expect(try questionCard().match(["APPLE", "blue , Red"]) == ["apple", "Blue, red"])
  }

  @Test func textThatMatchesNoLabelIsATypedAnswer() throws {
    #expect(try questionCard().match(["a pear", "red, purple"]) == ["a pear", "red, purple"])
  }

  @Test func eachQuestionNeedsOneAnswer() {
    #expect(throws: APIError.self) { try questionCard().match(["apple"]) }
    #expect(throws: APIError.self) { try questionCard().match(["apple", " "]) }
  }

  @Test func allowingAQuestionAddsTheAnswersToItsInput() throws {
    var input = fruitQuestions.object!
    input["answers"] = ["Which fruit?": "Cherry", "Which colors?": "red, green"]
    #expect(
      questionCard().decision(answers: ["Cherry", "red, green"]).hookOutput
        == [
          "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow", "updatedInput": .object(input)],
          ]
        ])
  }

  @Test func answerMessageHasALinePerQuestion() {
    #expect(
      questionCard().answerMessage(["Cherry", "red"])
        == "Answer to your question \"Which fruit?\": Cherry\nAnswer to your question \"Which colors?\": red")
  }

  @Test func hookOutputs() {
    let output = { (decision: JSON) -> JSON in
      ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }
    #expect(Decision.allow(updatedInput: nil).hookOutput == output(["behavior": "allow"]))
    #expect(Decision.deny(message: "Use make.").hookOutput == output(["behavior": "deny", "message": "Use make."]))
    #expect(Decision.deny(message: nil).hookOutput == output(["behavior": "deny", "interrupt": true]))
  }
}

/// The data of a `send_pending` event for a message to alpha and bravo in Flags.
func sendPendingData(text: String = "Rebase on main.") -> [String: JSON] {
  [
    "group": "gabc23", "groupName": "Flags", "text": .string(text),
    "targets": [["id": "s2", "name": "alpha"], ["id": "s3", "name": "bravo"]], "expires": 3_600_010,
  ]
}

/// A `send_pending` event 7, so its card's id is 7.
func sendPending(text: String = "Rebase on main.") -> Event {
  Event(id: 7, session: "s1", t: 10, kind: "send_pending", data: .object(sendPendingData(text: text)))
}

func sendDecided(_ card: Int64, _ decision: String, t: Int64 = 20) -> Event {
  event("send_decided", t, ["card": .number(Double(card)), "decision": .string(decision)])
}

@Suite struct SendCards {
  @Test func aSendPendingEventOpensASendCard() throws {
    let cards = facts([sendPending()]).cards

    let card = try #require(cards.first)
    #expect(cards.count == 1)
    #expect(card.id == 7)
    #expect(card.session == "s1")
    #expect(card.kind == .send)
    #expect(card.since == 10)
    #expect(!card.deferred)
  }

  @Test func aSendCardHoldsTheMessage() {
    let card = facts([sendPending()]).cards.first

    #expect(
      card?.send
        == GroupMessage(
          group: "gabc23", groupName: "Flags", text: "Rebase on main.",
          targets: [GroupSend.Target(id: "s2", name: "alpha"), GroupSend.Target(id: "s3", name: "bravo")],
          expires: 3_600_010))
  }

  @Test(arguments: ["Say \"hi\"\nthen\tstop", "null", "\u{1B}[2K\\u{1b}", "{\"targets\": []}", "  42  "])
  func aSendCardKeepsTheTextExactly(_ text: String) {
    #expect(facts([sendPending(text: text)]).cards.first?.send?.text == text)
  }

  @Test func aPermissionCardHasNoMessage() {
    #expect(facts(permissionTurn()).cards.first?.send == nil)
  }

  @Test(arguments: turnEnds) func aSendCardSurvivesTheEndOfTheTurn(_ end: Event) {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), sendPending(), end])

    #expect(f.cards.map(\.id) == [7])
  }

  @Test(
    arguments: ["PostToolUse", "PostToolUseFailure"],
    [
      tool("send_group", [:]), tool("mcp__switchboard__send_group", ["group": "Flags", "text": "Rebase on main."]),
      tool("Bash", ["command": "sb send --group Flags Rebase"]),
    ])
  func aSendCardSurvivesAToolCallFinishing(_ kind: String, _ call: [String: JSON]) {
    let f = facts([sendPending(), event(kind, 11, call)])

    #expect(f.cards.map(\.id) == [7])
  }

  @Test func theEndOfTheTurnRemovesAPermissionCardAndKeepsASendCard() {
    let f = facts(permissionTurn() + [sendPending(), event("Stop", 11, ["last_assistant_message": "ok"])])

    #expect(f.cards.map(\.kind) == [.send])
  }

  @Test(arguments: ["sent", "cancelled", "expired"]) func sendDecidedClosesItsCard(_ decision: String) {
    #expect(facts([sendPending(), sendDecided(7, decision)]).cards.isEmpty)
  }

  @Test func sendDecidedForAnotherCardLeavesTheCard() {
    #expect(facts([sendPending(), sendDecided(99, "sent")]).cards.map(\.id) == [7])
  }

  @Test func sendDecidedClosesOnlyItsOwnCard() {
    let second = Event(id: 9, session: "s1", t: 12, kind: "send_pending", data: .object(sendPendingData()))

    let f = facts([sendPending(), second, sendDecided(7, "sent")])

    #expect(f.cards.map(\.id) == [9])
  }

  /// The held requests end with sbd, but a group message waits in the event log.
  @Test func aRestartOfSbdKeepsASendCard() {
    var replay = SessionReplay.replaying(fetchTurn() + [sendPending()], session: session())

    replay.restarted()

    #expect(replay.facts.cards.map(\.id) == [7])
  }

  @Test func anOpenSendCardNeedsYouToConfirm() {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), sendPending(), event("Stop", 11)])

    let verdict = Attention.evaluate(session(), f, now: 12)

    #expect(verdict.state == .needsYou)
    #expect(verdict.reason.hasPrefix("confirm"))
  }

  @Test func aSendCardIsAnApprovalWithAllowAndDeny() {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), sendPending(), event("Stop", 11)])

    let triage = item(f, now: 12)

    #expect(triage?.source == .card)
    #expect(triage?.kind == .approval)
    #expect(triage?.ref == "card:7")
    #expect(triage?.options.map(\.action) == [.allow, .deny])
  }
}
