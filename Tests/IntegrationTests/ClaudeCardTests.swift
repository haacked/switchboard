import Foundation
import SwitchboardCore
import Testing

/// Cards against the real claude: a dialog that leaves the screen, and
/// answers that sbd types after the PermissionRequest hook has closed.
extension ClaudeTests {
  @Test func removesTheCardWhenYesInTheTerminalClosesTheDialog() throws {
    let c = try ClaudeInstance(ask: ["Bash(./slow.sh:*)"])
    let prompt = "Run exactly this command with the Bash tool: ./slow.sh 8\nThen reply with DONE and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    try c.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try c.sbd.waitFor("the dialog") { try c.answer(s.id, .proceed) }
    // The command still runs, so its PostToolUse hasn't come.
    let closed = try c.waitFor(s.id, "the closed dialog", timeout: 5) { $0.cards.isEmpty }
    #expect(!closed.reason.hasPrefix("approve"))
    #expect(try c.sbd.events(s.id).contains { $0.kind == "dialog_closed" })
    #expect(try !c.sbd.hooks(s.id).contains { $0.kind == "PostToolUse" })
    try c.waitFor(s.id, "the reply") { $0.lastReply != nil }
  }

  @Test func typesYesAfterTheHookCloses() throws {
    let c = try ClaudeInstance(ask: ["Bash(touch:*)"])
    let command = "touch \(c.nonce).txt"
    let s = try c.sbd.new(
      prompt: "Run exactly this command with the Bash tool: \(command)\nThen reply with DONE and nothing else.")
    try c.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try c.sbd.waitFor("the dialog") { try c.screen(s.id).contains("Do you want to proceed") }
    try killHook(c, s.id)
    try c.waitFor(s.id, "the closed hook") { $0.cards.first?.hookClosed == true }
    #expect(try JSON.parse(c.sbd.sb("allow", "--json", s.id))?["delivery"]?.string == "terminal")
    try c.waitFor(s.id, "the reply after the approval") { $0.lastReply != nil }
    #expect(FileManager.default.fileExists(atPath: "\(c.sbd.work)/\(c.nonce).txt"))
  }

  @Test func typesYesIntoAnEditDialogAfterTheHookCloses() throws {
    let c = try ClaudeInstance()
    let file = "\(c.sbd.work)/notes.txt"
    try "alpha\nbeta\ngamma\n".write(toFile: file, atomically: true, encoding: .utf8)
    let s = try c.sbd.new(
      prompt: "Use the Edit tool to replace the line \"beta\" with \"\(c.nonce)\" in notes.txt.\n"
        + "Then reply with DONE and nothing else.")
    try c.waitFor(s.id, "the card") { $0.cards.first?.tool == "Edit" }
    try c.sbd.waitFor("the dialog") { try c.screen(s.id).contains("Do you want to make this edit") }
    try killHook(c, s.id)
    try c.waitFor(s.id, "the closed hook") { $0.cards.first?.hookClosed == true }
    #expect(try JSON.parse(c.sbd.sb("allow", "--json", s.id))?["delivery"]?.string == "terminal")
    try c.waitFor(s.id, "the reply after the approval") { $0.lastReply != nil }
    #expect(try String(contentsOfFile: file, encoding: .utf8).contains(c.nonce))
  }

  @Test func answersAQuestionAfterTheHookClosesByCancellingTheDialog() throws {
    let c = try ClaudeInstance()
    let prompt =
      "Use the AskUserQuestion tool once to ask me two questions: \"Which fruit?\" (header Fruit, options apple, "
      + "cherry) and \"Which colors?\" (header Colors, multiSelect true, options red, blue, green). Then reply with "
      + "my answers and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    try c.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try c.sbd.waitFor("the question dialog") { try c.screen(s.id).contains("Esc to cancel") }
    // The dialog then shows the second question and not the first.
    try c.press(s.id, "Right")
    usleep(500_000)
    #expect(ClaudeScreen.dialog(try c.screen(s.id))?.contains { $0.contains("Which fruit?") } == false)
    try killHook(c, s.id)
    let closed = try c.waitFor(s.id, "the closed hook") { $0.cards.first?.hookClosed == true }
    sleep(2)
    #expect(try c.sbd.get(s.id).cards.map(\.id) == closed.cards.map(\.id))
    #expect(
      try JSON.parse(c.sbd.sb("answer", "--json", s.id, "cherry", "red, blue"))?["delivery"]?.string == "terminal")
    let done = try c.waitFor(s.id, "the reply to the answers") { $0.lastReply?.lowercased().contains("cherry") == true }
    #expect(done.cards.isEmpty)
  }

  /// Kills the `sb hook` process that holds the session's PermissionRequest,
  /// as the hook's timeout ends it.
  private func killHook(_ c: ClaudeInstance, _ id: String) throws {
    let pid = try #require(try c.sbd.get(id).claudePid)
    let children = Processes.byParent()
    var level = children[pid] ?? []
    var hooks: [ProcessRow] = []
    while !level.isEmpty {
      hooks += level.filter { $0.command.hasSuffix(" hook") }
      level = level.flatMap { children[$0.pid] ?? [] }
    }
    try #require(!hooks.isEmpty)
    for hook in hooks { kill(pid_t(hook.pid), SIGKILL) }
  }
}
