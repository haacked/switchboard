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

  /// Claude Code applies the request's suggestions from the hook's
  /// `updatedPermissions`, so a later Read in the same folder asks nothing.
  @Test func alwaysAllowLetsALaterReadInTheSameFolderRunWithoutACard() throws {
    let c = try ClaudeInstance()
    let outside = "\(real(c.sbd.home.path))/outside"
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try "\(c.nonce)-A\n".write(toFile: "\(outside)/a.txt", atomically: true, encoding: .utf8)
    try "\(c.nonce)-B\n".write(toFile: "\(outside)/b.txt", atomically: true, encoding: .utf8)
    func read(_ name: String) -> String {
      "Use the Read tool to read \(outside)/\(name). Then reply with its contents and nothing else."
    }
    let s = try c.sbd.new(prompt: read("a.txt"))
    let asked = try c.waitFor(s.id, "the Read card") { $0.cards.first?.tool == "Read" }
    let card = try #require(asked.cards.first)
    let suggestions = card.permissionSuggestions?.text ?? "none"
    // A rule saved outside this session would reach the user's own settings.
    let destinations = Set(card.permissionSuggestions?.array?.compactMap { $0["destination"]?.string } ?? [])
    try #require(destinations.isSubset(of: ["session", "localSettings"]), "suggestions: \(suggestions)")
    try #require(card.offers(.always), "suggestions: \(suggestions)")

    #expect(try JSON.parse(c.sbd.sb("allow", "--always", "--json", s.id))?["delivery"]?.string == "hook")

    try c.waitFor(s.id, "the first reply") { $0.lastReply?.contains("\(c.nonce)-A") == true }
    let first = try #require(try c.sbd.hooks(s.id).last { $0.kind == "PermissionRequest" })
    try c.sbd.sb("send", s.id, read("b.txt"))
    try c.waitFor(s.id, "the second reply") { $0.lastReply?.contains("\(c.nonce)-B") == true }
    #expect(try !c.sbd.hooks(s.id, after: first.id).contains { $0.kind == "PermissionRequest" })
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
