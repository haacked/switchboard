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

  @Test(arguments: [
    event("Stop", 4, ["last_assistant_message": "ok"]), event("StopFailure", 4), event("SessionEnd", 4),
    event("stopped", 4), event("exited", 4), event("Notification", 4, ["notification_type": "idle_prompt"]),
    event("UserPromptSubmit", 4, ["prompt": "do this instead"]),
  ])
  func theEndOfTheTurnRemovesOpenCards(_ end: Event) {
    #expect(facts(permissionTurn() + [end]).cards.isEmpty)
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

  @Test func aClosedRequestLeavesThePromptOpenUntilTheIdlePrompt() {
    var events = permissionTurn() + [event("card_closed", 4, ["card": 3])]
    let closed = facts(events)
    #expect(closed.cards.isEmpty)
    #expect(Attention.evaluate(session(), closed, now: 5) == Verdict(state: .needsYou, reason: "approve `touch x`"))
    events.append(event("Notification", 6, ["notification_type": "idle_prompt"]))
    #expect(!facts(events).turnRunning)
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

  @Test func aSubagentResultLeavesADeferredQuestion() {
    let f = facts(
      questionTurn() + [
        event("deferred", 4, ["card": 3]), event("Stop", 5),
        event("UserPromptSubmit", 6, ["prompt": "<agent-message from=\"a1\"> [Subagent hand-back] done"]),
      ])
    #expect(f.cards.count == 1)
  }

  @Test func theUsersNextPromptAnswersADeferredQuestion() {
    let f = facts(
      questionTurn() + [
        event("deferred", 4, ["card": 3]), event("Stop", 5), event("UserPromptSubmit", 6, ["prompt": "cherry"]),
      ])
    #expect(f.cards.isEmpty)
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
