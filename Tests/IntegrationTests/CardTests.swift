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
    #expect(try runCommand(t.tmux, ["-S", t.socket, "send-keys", "-t", "=\(t.claude):", "Enter"]).status == 0)
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
    let after = try sbd.waitFor(s.id, "the end of the turn") { $0.reason == "read its last reply and decide what's next" }
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

  @Test func holdsThePermissionRequestHookForADay() throws {
    let sbd = try Instance()
    let settings = try #require(JSON.parse(try String(contentsOfFile: sbd.home.claudeSettings, encoding: .utf8)))
    let timeout = { (event: String) in settings["hooks"]?[event]?.array?.first?["hooks"]?.array?.first?["timeout"] }
    #expect(timeout("PermissionRequest") == .number(Double(Card.holdSeconds)))
    #expect(timeout("Stop") == 30)
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

  @Test func removesTheCardWhenTheTerminalRefuses() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch z")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.type(s.id, "esc")
    let after = try sbd.waitFor(s.id, "the closed card") { $0.cards.isEmpty }
    #expect(after.state == .needsYou)
    #expect(try sbd.events(s.id).contains { $0.kind == "card_closed" })
  }

  @Test func keepsThePromptOpenWhenTheHookTimesOut() throws {
    let sbd = try Instance(idleStopSeconds: 1)
    let s = try sbd.new(prompt: "perm touch v")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sbd.type(s.id, "timeout")
    let closed = try sbd.waitFor(s.id, "the closed card") { $0.cards.isEmpty }
    #expect(closed.reason == "approve `touch v`")
    // The stop rule waits for the prompt that Claude Code's dialog still shows.
    sleep(3)
    #expect(try sbd.get(s.id).live)
    try sbd.type(s.id, "y")
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch v" }
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
