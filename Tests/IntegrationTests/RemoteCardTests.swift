import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"

/// The cards of a session on a remote host. The PermissionRequest hook of the claude on the box waits in the box's
/// shim, which holds a connection to sbd through the forward, and `sb allow`, `sb deny`, and `sb answer` answer it
/// there. A card whose hook is gone gets its answer typed into the pane on the box.
@Suite(.blocking(timeLimit: .seconds(240))) struct RemoteCardTests {
  private typealias Remote = (id: String, claudeSessionId: String, cwd: String, pid: Int)

  /// A session on mini whose first prompt opened a card.
  private func asking(_ sbd: Instance, _ prompt: String) throws -> (session: Remote, asked: SessionSummary) {
    let s = try sbd.startOnHost(prompt: prompt)
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    return (s, asked)
  }

  /// A session on mini whose card's hook timed out while the stub's dialog still shows.
  private func timedOut(_ sbd: Instance, _ prompt: String) throws -> Remote {
    let (s, _) = try asking(sbd, prompt)
    try sbd.type(s.id, "timeout")
    try sbd.waitFor(s.id, "the closed hook") { $0.cards.first?.hookClosed == true }
    return s
  }

  /// Runs several ticks, so that every rule of the tick has seen the session.
  private func tick(_ sbd: Instance) throws {
    for _ in 0..<3 { try sbd.advanceClock(1_000) }
  }

  // MARK: Through the held hook

  @Test func aPermissionPromptOnTheBoxOpensACard() throws {
    let sbd = try Instance.remote()

    let (s, asked) = try asking(sbd, "perm touch x")

    #expect(asked.state == .needsYou)
    #expect(asked.reason == "approve `touch x`")
    #expect(asked.host == "mini")
    let card = try #require(try sbd.cards().first)
    #expect(card.session == s.id)
    #expect(card.kind == .permission)
    #expect(card.input == ["command": "touch x"])
    #expect(card.hookClosed == false)
    #expect(sbd.boxHeldHookRuns(), "the hook on the box ended while its card is open")
  }

  @Test func allowAnswersTheCardThroughTheHeldHookAcrossTheForward() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm touch x")

    let answer = try JSON.parse(sbd.sb("allow", "--json", s.id))
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch x" }

    #expect(answer?["delivery"]?.string == "hook")
    #expect(try sbd.cards().isEmpty)
    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["behavior"] == "allow" })
    try sbd.waitFor("the held hook on the box to end") { !sbd.boxHeldHookRuns() }
  }

  @Test func denyWithAMessageAnswersTheCardThroughTheHeldHook() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm rm -rf build")

    let answer = try JSON.parse(sbd.sb("deny", "--json", s.id, "Use", "make", "clean"))
    try sbd.waitFor(s.id, "the reply to the denial") { $0.lastReply == "Denied: Use make clean" }

    #expect(answer?["delivery"]?.string == "hook")
    #expect(try sbd.cards().isEmpty)
    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["behavior"] == "deny" })
  }

  @Test func denyWithoutAMessageStopsTheRemoteTurn() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm rm -rf build")

    try sbd.sb("deny", s.id, "--json")
    let after = try sbd.waitFor(s.id, "the end of the turn", timeout: 30) {
      $0.reason == "read its last reply and decide what's next"
    }

    #expect(after.lastReply == nil)
    #expect(try sbd.cards().isEmpty)
  }

  @Test func aQuestionOnTheBoxOpensACardAndTheAnswerReachesItsClaude() throws {
    let sbd = try Instance.remote()
    let (s, asked) = try asking(sbd, "pick")
    let card = asked.cards[0]

    try sbd.sb("answer", "--card", String(card.id), s.id, "Cherry", "blue,red")
    try sbd.waitFor(s.id, "the answered turn") {
      $0.lastReply == #"Picked: {"Which colors?":"blue, red","Which fruit?":"cherry"}"#
    }

    #expect(asked.reason == "answer: Which fruit?")
    #expect(card.kind == .question)
    #expect(card.questions.map(\.header) == ["Fruit", "Colors"])
    #expect(card.questions.map(\.multiSelect) == [false, true])
    #expect(try sbd.cards().isEmpty)
  }

  @Test func anAnswerThatDoesNotFitARemoteCardIsRefusedAndKeepsTheCard() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "pick")

    #expect(throws: TestError.self) { try sbd.sb("answer", s.id, "cherry") }
    #expect(throws: TestError.self) { try sbd.sb("allow", s.id) }

    #expect(try sbd.cards().count == 1)
    #expect(sbd.boxHeldHookRuns())
  }

  // MARK: The dialog was answered in the terminal

  @Test func aCardWhoseDialogWasAllowedInTheBoxesTerminalCloses() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm touch y")
    try #require(sbd.boxHeldHookRuns())

    try sbd.type(s.id, "y")
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch y" && $0.cards.isEmpty }

    try sbd.waitFor("the held hook on the box to end") { !sbd.boxHeldHookRuns() }
    #expect(throws: TestError.self) { try sbd.sb("allow", s.id) }
  }

  @Test func aCardWhoseDialogClosedBeforeASlowCommandFinishedCloses() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm sleep 3")
    try sbd.waitFor("the dialog") { try sbd.screen(s.id).contains("Esc to cancel") }
    // sbd removes a card whose hook is open only after a check saw its dialog.
    sleep(1)

    try sbd.press(s.id, "Enter")
    let running = try sbd.waitFor(s.id, "the removed card") { $0.cards.isEmpty }
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran sleep 3" }

    #expect(running.state == .working)
    let kinds = try sbd.events(s.id).map(\.kind)
    let closed = try #require(kinds.firstIndex(of: "dialog_closed"))
    let finished = try #require(kinds.firstIndex(of: "PostToolUse"))
    #expect(closed < finished)
    #expect(try sbd.events(s.id).first { $0.kind == "dialog_closed" }?.data["allowed"] == true)
  }

  /// The link is up, so the hook that Escape ended is a hook that Claude Code closed.
  @Test func aCardWhoseDialogWasRefusedInTheBoxesTerminalCloses() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm touch z")

    try sbd.press(s.id, "Escape")
    let after = try sbd.waitFor(s.id, "the removed card") { $0.cards.isEmpty }

    #expect(after.reason == "approve `touch z`")
    let events = try sbd.events(s.id)
    #expect(events.contains { $0.kind == "card_closed" })
    #expect(events.contains { $0.kind == "dialog_closed" && $0.data["allowed"] == nil })
  }

  // MARK: The hook closed while the link is up

  @Test func aCardWhoseHookTimedOutOnTheBoxStaysAndNamesTheClosedHook() throws {
    let sbd = try Instance.remote()

    let s = try timedOut(sbd, "perm touch v")

    #expect(try sbd.events(s.id).contains { $0.kind == "card_closed" })
    let after = try sbd.get(s.id)
    #expect(after.cards.map(\.hookClosed) == [true])
    #expect(after.reason == "approve `touch v`")
  }

  @Test func allowTypesYesIntoTheBoxesPaneAfterTheHookTimedOut() throws {
    let sbd = try Instance.remote()
    let s = try timedOut(sbd, "perm touch u")

    let answer = try JSON.parse(sbd.sb("allow", "--json", s.id))
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch u" && $0.cards.isEmpty }

    #expect(answer?["delivery"]?.string == "terminal")
  }

  @Test func denyWithAMessageInterruptsAndSendsTheMessageToTheBoxAfterTheHookTimedOut() throws {
    let sbd = try Instance.remote()
    let s = try timedOut(sbd, "perm rm -rf build")

    try sbd.sb("deny", s.id, "Use", "make", "clean")
    try sbd.waitFor(s.id, "the reply to the message", timeout: 30) { $0.lastReply == "Done: Use make clean" }

    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["interrupted"] == true })
    #expect(sbd.boxStubInput().contains { $0.contains("Use make clean") })
  }

  // MARK: The link drops while a card is held

  @Test func aCardHeldWhenTheLinkDropsStaysListedAndRecordsNoClosedCard() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm touch x")
    let before = try sbd.events(s.id).last?.id ?? 0

    try sbd.dropLinkAndRefuse(refusal)
    try tick(sbd)
    sleep(1)

    let cards = try sbd.cards()
    #expect(cards.map(\.session) == [s.id])
    let after = try sbd.events(s.id).filter { $0.id > before }.map(\.kind)
    #expect(!after.contains("card_closed"), "\(after)")
    #expect(!after.contains("dialog_closed"), "\(after)")
    #expect(!after.contains("exited"), "\(after)")
    #expect(sbd.runs(s.pid))
  }

  @Test func allowingACardWhileTheLinkIsDownFailsWithTheReasonAndKeepsTheCard() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm touch x")
    try sbd.dropLinkAndRefuse(refusal)

    let r = try sbd.run("allow", s.id)

    #expect(r.status == 1)
    #expect(r.stderr.contains("mini is not connected"), "\(r.stderr)")
    #expect(try sbd.cards().map(\.session) == [s.id])
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
  }

  @Test func afterTheReconnectAllowTypesYesIntoTheBoxesPaneForACardThatWasHeldWhenTheLinkDropped() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm touch x")
    try sbd.dropLinkAndRefuse(refusal)
    try tick(sbd)
    try #require(try sbd.cards().count == 1)

    try sbd.restoreLink()
    try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }
    let listed = try sbd.cards()
    let answer = try JSON.parse(sbd.sb("allow", "--json", s.id))
    try sbd.waitFor(s.id, "the command's reply", timeout: 30) { $0.lastReply == "Ran touch x" && $0.cards.isEmpty }

    #expect(listed.map(\.session) == [s.id])
    #expect(answer?["delivery"]?.string == "terminal")
    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["behavior"] == "allow" })
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
    #expect(try !sbd.events(s.id).contains { $0.kind == "exited" })
  }

  @Test func afterTheReconnectACardWhoseDialogWasAnsweredInTheTerminalCloses() throws {
    let sbd = try Instance.remote()
    let (s, _) = try asking(sbd, "perm touch x")
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.restoreLink()
    try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }

    try sbd.type(s.id, "y")

    try sbd.waitFor(s.id, "the command's reply", timeout: 30) { $0.lastReply == "Ran touch x" && $0.cards.isEmpty }
  }

  // MARK: Nothing runs on this Mac

  @Test func aSendAndACardOfARemoteSessionLeaveNoLineInTheMacsMachineLog() throws {
    let sbd = try Instance.remote()
    // A local session shows that the log records a session's calls at all.
    let local = try sbd.new()
    _ = try sbd.waitForMachineCall("the new-session call of the local session") {
      $0.runs("tmux") && $0.has("new-session") && $0.has("\(local.id)-claude")
    }
    let s = try sbd.startOnHost(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }

    try sbd.sb("send", s.id, "second message")
    try sbd.waitFor(s.id, "the reply to the sent message", timeout: 30) { $0.lastReply == "Done: second message" }
    try sbd.sb("send", s.id, "perm touch x")
    try sbd.waitFor(s.id, "the card", timeout: 30) { !$0.cards.isEmpty }
    try sbd.sb("allow", s.id)
    try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch x" }
    try sbd.sb("send", s.id, "perm touch y")
    try sbd.waitFor(s.id, "the second card", timeout: 30) { !$0.cards.isEmpty }
    try sbd.type(s.id, "timeout")
    try sbd.waitFor(s.id, "the closed hook") { $0.cards.first?.hookClosed == true }
    try sbd.sb("allow", s.id)
    try sbd.waitFor(s.id, "the typed answer's reply") { $0.lastReply == "Ran touch y" }
    // Two ticks more, so that a read that the tick makes for the session is in the log too.
    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    let calls = try sbd.macCalls(
      id: s.id, cwd: s.cwd, claudeSessionId: s.claudeSessionId, pid: s.pid,
      also: ["second message", "touch x", "touch y"])
    #expect(calls.isEmpty, "this Mac ran \(calls.count) calls for the remote session, first: \(calls.prefix(3))")
    #expect(sbd.stubInput().isEmpty, "a pane on this Mac read \(sbd.stubInput())")
    #expect(!FileManager.default.fileExists(atPath: sbd.home.sessionFolder(s.id)))
  }

  // MARK: Parity

  /// A card of a remote session and a card of a local one hold the same fields, and one answer closes both the
  /// same way.
  @Test(arguments: ["perm touch x", "pick fruit"])
  func aRemoteCardMatchesTheCardOfALocalSessionForTheSamePrompt(prompt: String) throws {
    let sbd = try Instance.remote()
    let local = try sbd.new(prompt: prompt)
    let localAsked = try sbd.waitFor(local.id, "the local card") { !$0.cards.isEmpty }
    let (s, remoteAsked) = try asking(sbd, prompt)

    let (near, far) = (try #require(localAsked.cards.first), try #require(remoteAsked.cards.first))
    #expect(far.kind == near.kind)
    #expect(far.questions == near.questions)
    #expect(far.hookClosed == near.hookClosed)
    #expect(far.deferred == near.deferred)
    #expect(remoteAsked.reason == localAsked.reason)
    #expect(remoteAsked.state == localAsked.state)
    #expect(far.session == s.id)
    if near.kind == .permission { #expect(far.input == near.input) }
  }
}
