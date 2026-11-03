import Foundation
import SwitchboardCore
import Testing

extension Instance {
  func cards() throws -> [Card] {
    try JSONCoding.decode([Card].self, from: try sb("cards", "--json"))
  }

  /// Types a line into the session's Claude pane, where the stub's dialog
  /// reads the terminal's answer.
  func type(_ id: String, _ line: String) throws {
    let t = try client.terminals(id)
    #expect(try runCommand(t.tmux, ["-S", t.socket, "send-keys", "-t", "=\(t.claude):", "-l", line]).status == 0)
    try press(id, "Enter")
  }

  /// The item that the cursor of the stub's dialog is on, or nil when no
  /// dialog shows.
  func highlighted(_ id: String) throws -> String? {
    ClaudeScreen.dialog(try screen(id)).flatMap(ClaudeScreen.highlighted)
  }

  /// Whether the PermissionRequest hook that the stub ran last still runs.
  func heldHookRuns() -> Bool {
    guard let pid = stubPid("held-hook.pid") else { return false }
    return kill(pid, 0) == 0
  }
}

@Suite(.timeLimit(.minutes(2))) struct CardTests {
  @Test func allowsAPermissionPrompt() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch x")
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(asked.state == .needsYou)
    #expect(asked.reason == "approve `touch x`")
    let card = try #require(try sbd.cards().first)
    #expect(card.session == s.id)
    #expect(card.kind == .permission)
    #expect(card.input == ["command": "touch x"])
    let answer = try JSON.parse(sbd.sb("allow", "--json", s.id))
    #expect(answer?["delivery"]?.string == "hook")
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch x" }
    #expect(try sbd.cards().isEmpty)
    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["behavior"] == "allow" })
  }

  @Test func deniesWithAMessage() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm rm -rf build")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.sb("deny", s.id, "Use", "make", "clean")
    try sbd.waitFor(s.id, "the reply to the denial") { $0.lastReply == "Denied: Use make clean" }
  }

  @Test func denyingWithoutAMessageStopsTheTurn() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm rm -rf build")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    // A flag after the session is a flag, not the message.
    try sbd.sb("deny", s.id, "--json")
    // The stub sends no hook after an interruption, and a reply after a message.
    let after = try sbd.waitFor(s.id, "the end of the turn") {
      $0.reason == "read its last reply and decide what's next"
    }
    #expect(after.lastReply == nil)
  }

  @Test func refusesToAnswerInsideClaudeCode() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(throws: TestError.self) { try sbd.sb("allow", s.id, env: ["CLAUDECODE": "1"]) }
    #expect(try sbd.cards().count == 1)
  }

  @Test func listsTheWholeCallThatAllowApproves() throws {
    let sbd = try Instance()
    let command = "cd /tmp/one/two/three && touch a-file-whose-name-runs-past-fifty-characters.txt"
    let s = try sbd.new(prompt: "perm \(command)")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(try sbd.sb("cards").contains("      \(command)\n"))
  }

  @Test func subscribesClaudeToEveryHookAndHoldsThePermissionRequestForADay() throws {
    let sbd = try Instance()
    let settings = try #require(JSON.parse(try String(contentsOfFile: sbd.home.claudeSettings, encoding: .utf8)))
    let timeout = { (event: String) in settings["hooks"]?[event]?.array?.first?["hooks"]?.array?.first?["timeout"] }
    #expect(timeout("PermissionRequest") == .number(Double(Card.holdSeconds)))
    #expect(timeout("Stop") == 30)
    #expect(Set(settings["hooks"]?.object?.keys.map { $0 } ?? []) == Set(SessionFacts.hookKinds))
  }

  @Test func answersTwoQuestionsWithTheChosenLabels() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "pick")
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(asked.reason == "answer: Which fruit?")
    let card = asked.cards[0]
    #expect(card.kind == .question)
    #expect(card.questions.map(\.header) == ["Fruit", "Colors"])
    #expect(card.questions[0].options.map(\.description) == ["A red fruit", "A small fruit"])
    #expect(card.questions.map(\.multiSelect) == [false, true])
    try sbd.sb("answer", "--card", String(card.id), s.id, "Cherry", "blue,red")
    try sbd.waitFor(s.id, "the answered turn") {
      $0.lastReply == #"Picked: {"Which colors?":"blue, red","Which fruit?":"cherry"}"#
    }
  }

  @Test func refusesAnAnswerThatDoesNotFitTheCard() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "pick")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(throws: TestError.self) { try sbd.sb("answer", s.id, "cherry") }
    #expect(throws: TestError.self) { try sbd.sb("allow", s.id) }
    #expect(throws: TestError.self) { try sbd.sb("answer", "--card", "999999", s.id, "cherry", "red") }
    #expect(try sbd.cards().count == 1)
  }

  @Test func removesTheCardWhenTheTerminalAllowsFirst() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch y")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(sbd.heldHookRuns())
    try sbd.type(s.id, "y")
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch y" && $0.cards.isEmpty }
    // sbd answered the request that the terminal left open, so its hook ended.
    try sbd.waitFor("the held hook to end") { !sbd.heldHookRuns() }
    #expect(throws: TestError.self) { try sbd.sb("allow", s.id) }
  }

  @Test func removesTheCardWhenYesClosesTheDialogBeforeASlowCommandFinishes() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm sleep 3")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.waitFor("the dialog") { try sbd.screen(s.id).contains("Esc to cancel") }
    // sbd removes a card whose hook is open only after a check saw its dialog.
    sleep(1)
    try sbd.press(s.id, "Enter")
    let running = try sbd.waitFor(s.id, "the removed card") { $0.cards.isEmpty }
    #expect(running.state == .working)
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran sleep 3" }
    let kinds = try sbd.events(s.id).map(\.kind)
    let closed = try #require(kinds.firstIndex(of: "dialog_closed"))
    #expect(try sbd.events(s.id).first { $0.kind == "dialog_closed" }?.data["allowed"] == true)
    let finished = try #require(kinds.firstIndex(of: "PostToolUse"))
    #expect(closed < finished)
  }

  @Test func removesTheCardWhenEscapeRefusesInTheTerminal() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch z")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.press(s.id, "Escape")
    let after = try sbd.waitFor(s.id, "the removed card") { $0.cards.isEmpty }
    // The turn stays until claude reports it idle, and the prompt with it.
    #expect(after.reason == "approve `touch z`")
    let events = try sbd.events(s.id)
    #expect(events.contains { $0.kind == "card_closed" })
    #expect(events.contains { $0.kind == "dialog_closed" && $0.data["allowed"] == nil })
  }

  /// A session whose card's PermissionRequest hook timed out while the
  /// stub's dialog still shows.
  func timedOut(_ prompt: String, idleStopSeconds: Int = 600) throws -> (Instance, SessionSummary) {
    let sbd = try Instance(idleStopSeconds: idleStopSeconds)
    let s = try sbd.new(prompt: prompt)
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.type(s.id, "timeout")
    try sbd.waitFor(s.id, "the closed hook") { $0.cards.first?.hookClosed == true }
    return (sbd, s)
  }

  @Test func keepsTheCardWhenTheHookTimesOut() throws {
    let (sbd, s) = try timedOut("perm touch v", idleStopSeconds: 1)
    #expect(try sbd.events(s.id).contains { $0.kind == "card_closed" })
    // The stop rule waits for the prompt that Claude Code's dialog still shows.
    sleep(3)
    let after = try sbd.get(s.id)
    #expect(after.live)
    #expect(after.cards.map(\.hookClosed) == [true])
    #expect(after.reason == "approve `touch v`")
    try sbd.type(s.id, "y")
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch v" && $0.cards.isEmpty }
  }

  @Test func listsACardWhoseHookClosed() throws {
    let (sbd, _) = try timedOut("perm touch v")
    #expect(try sbd.sb("cards").contains(", hook closed"))
  }

  @Test func allowTypesYesAfterTheHookTimesOut() throws {
    let (sbd, s) = try timedOut("perm touch u")
    let answer = try JSON.parse(sbd.sb("allow", "--json", s.id))
    #expect(answer?["delivery"]?.string == "terminal")
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch u" && $0.cards.isEmpty }
  }

  @Test func allowMovesTheCursorBackToYesAfterTheHookTimesOut() throws {
    let (sbd, s) = try timedOut("perm touch u")
    try sbd.press(s.id, "Down")
    try sbd.waitFor("the cursor on No") { try sbd.highlighted(s.id)?.contains("No") == true }
    try sbd.sb("allow", s.id)
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch u" }
  }

  @Test func denyInterruptsAfterTheHookTimesOut() throws {
    let (sbd, s) = try timedOut("perm rm -rf build")
    let answer = try JSON.parse(sbd.sb("deny", "--json", s.id))
    #expect(answer?["delivery"]?.string == "terminal")
    let after = try sbd.waitFor(s.id, "the end of the turn") {
      $0.reason == "read its last reply and decide what's next" && $0.cards.isEmpty
    }
    #expect(after.lastReply == nil)
    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["interrupted"] == true })
  }

  @Test func denyWithAMessageInterruptsAndSendsTheMessageAfterTheHookTimesOut() throws {
    let (sbd, s) = try timedOut("perm rm -rf build")
    try sbd.sb("deny", s.id, "Use", "make", "clean")
    try sbd.waitFor(s.id, "the reply to the message") { $0.lastReply == "Done: Use make clean" }
    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["interrupted"] == true })
  }

  @Test func answerCancelsTheQuestionAndSendsTheAnswersAfterTheHookTimesOut() throws {
    let (sbd, s) = try timedOut("pick")
    let answer = try JSON.parse(sbd.sb("answer", "--json", s.id, "apple", "green"))
    #expect(answer?["delivery"]?.string == "terminal")
    let message = "Answer to your question \"Which fruit?\": apple\nAnswer to your question \"Which colors?\": green"
    try sbd.waitFor(s.id, "the reply to the answers") {
      $0.lastReply?.hasSuffix("Answer to your question \"Which colors?\": green") == true && $0.cards.isEmpty
    }
    let prompts = try sbd.events(s.id).filter { $0.kind == "UserPromptSubmit" }.compactMap { $0.data["prompt"]?.string }
    #expect(prompts.joined(separator: "\n").contains(message))
  }

  @Test func defersAQuestionAndResumesWithTheAnswer() throws {
    let sbd = try Instance(idleStopSeconds: 2)
    let s = try sbd.new(prompt: "pick")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    let deferred = try sbd.waitFor(s.id, "the deferred card") { $0.cards.first?.deferred == true }
    #expect(deferred.reason == "answer: Which fruit?")
    try sbd.waitFor(s.id, "the reply to the deferral") { $0.lastReply == "Waiting for your answer." }
    let stopped = try sbd.waitFor(s.id, "the idle stop", timeout: 15) { !$0.live }
    #expect(stopped.state == .needsYou)
    #expect(stopped.cards.count == 1)
    let answer = try JSON.parse(sbd.sb("answer", "--json", s.id, "apple", "green"))
    #expect(answer?["delivery"]?.string == "resumed")
    let prompt = "Answer to your question \"Which fruit?\": apple\nAnswer to your question \"Which colors?\": green"
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: \(prompt)" }
    #expect(try sbd.cards().isEmpty)
  }

  @Test func stoppingASessionDefersItsQuestion() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "pick")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.sb("stop", s.id)
    let stopped = try sbd.waitFor(s.id, "the stop") { !$0.live }
    #expect(stopped.cards.map(\.deferred) == [true])
    #expect(try sbd.sb("answer", s.id, "cherry", "red") == "resumed\n")
  }

  @Test func keepsAQuestionHeldInASessionWithAnOpenWait() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1190")
    try sbd.sb("send", s.id, "pick")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    // A session with an open wait stops 2 s after its turn. A question waits for idleStopSeconds.
    sleep(3)
    #expect(try sbd.get(s.id).cards.map(\.deferred) == [false])
  }

  @Test func keepsAQuestionHeldWhileATerminalShowsTheSession() throws {
    let sbd = try Instance(idleStopSeconds: 1)
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    let detach = try sbd.attach(s.id)
    try sbd.waitFor(s.id, "the attached flag") { $0.attached }
    try sbd.sb("send", s.id, "pick")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    sleep(3)
    #expect(try sbd.get(s.id).cards.map(\.deferred) == [false])
    detach()
    try sbd.waitFor(s.id, "the deferral after detaching") { $0.cards.first?.deferred == true }
  }

  @Test func aWaitsMessageLeavesADeferredQuestion() throws {
    let sbd = try Instance(idleStopSeconds: 1)
    let s = try sbd.new(prompt: "pick")
    try sbd.waitFor(s.id, "the deferred card") { $0.cards.first?.deferred == true }
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1190")
    try sbd.sb("wait", s.id, "--resolve", "#1190 merged")
    try sbd.waitFor(s.id, "the wait's message") { $0.lastReply?.hasPrefix("Done: Switchboard: ") == true }
    let after = try sbd.get(s.id)
    #expect(after.cards.map(\.deferred) == [true])
    #expect(after.reason == "answer: Which fruit?")
  }

  @Test func keepsADeferredQuestionAcrossARestartOfSbd() throws {
    let sbd = try Instance(idleStopSeconds: 1)
    let s = try sbd.new(prompt: "pick")
    try sbd.waitFor(s.id, "the deferred card") { $0.cards.first?.deferred == true }
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.cards.map(\.deferred) == [true])
    #expect(after.reason == "answer: Which fruit?")
  }

  @Test func aMessageFromTheUserAnswersADeferredQuestion() throws {
    let sbd = try Instance(idleStopSeconds: 1)
    let s = try sbd.new(prompt: "pick")
    try sbd.waitFor(s.id, "the deferred card") { $0.cards.first?.deferred == true }
    try sbd.sb("send", s.id, "cherry and red")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: cherry and red" }
    #expect(try sbd.cards().isEmpty)
  }

  @Test func dropsAHeldCardWhenSbdRestarts() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch w")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.cards.isEmpty)
    // Claude Code's own dialog still waits, so the session still needs you.
    #expect(after.reason == "approve `touch w`")
    try sbd.type(s.id, "y")
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch w" }
  }
}
