import Foundation
import SwitchboardCore
import Testing

/// A group write from a process below a session's pane counts as Claude's, even with CLAUDECODE unset. A
/// user-written description and the user's links go into the system prompt of every session in the group.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupAuthorCallerTests {
  let panes = WaitActionTests()
  let shared = GroupTests()

  /// Runs `sb` with `args` as a tool call of `owner`'s claude, without CLAUDECODE.
  func sbWithoutClaudeCode(_ sbd: Instance, of owner: SessionSummary, _ args: [String], name: String) throws
    -> CommandResult
  {
    let sb = ([shellQuote("\(Instance.bin)/sb")] + args.map(shellQuote)).joined(separator: " ")
    try sbd.writeScript(name, "env -u CLAUDECODE \(sb)")
    return try panes.runInPane(sbd, of: owner, name)
  }

  func group(_ sbd: Instance, _ id: String) throws -> GroupSummary {
    try #require(try shared.list(sbd).groups.first { $0.id == id })
  }

  @Test func aDescriptionFromAClaudePaneWithoutClaudeCodeIsClaudes() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let worker = try sbd.idleSession(name: "worker")

    let r = try sbWithoutClaudeCode(
      sbd, of: worker, ["group", "describe", "Flags", "Ship it Friday."], name: "describe")

    #expect(r.status == 0, "\(r.stderr)")
    let after = try group(sbd, g.id)
    #expect(after.description == "Ship it Friday.")
    #expect(after.descriptionBy == .claude)
  }

  /// Claude can add only a claude.ai artifact link, so a link to any other page from a pane is refused.
  @Test func aLinkFromAClaudePaneWithoutClaudeCodeIsRefused() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let worker = try sbd.idleSession(name: "worker")

    let r = try sbWithoutClaudeCode(
      sbd, of: worker, ["group", "link", "add", "Flags", "https://example.com/rfc", "--title", "RFC"], name: "link")

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("from a terminal outside the sessions"), "\(r.stderr)")
    #expect(try group(sbd, g.id).links == nil)
  }

  /// A window that `tmux new-window` opens runs below sbd's tmux server and outside every session's pane.
  @Test func aDescriptionFromANewTmuxWindowIsClaudes() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let worker = try sbd.idleSession(name: "worker")
    let sb = shellQuote("\(Instance.bin)/sb")
    try sbd.writeScript(
      "window",
      "tmux new-window -d \(shellQuote("env -u CLAUDECODE \(sb) group describe Flags 'From a window.'")); sleep 3")

    let r = try panes.runInPane(sbd, of: worker, "window")

    #expect(r.status == 0, "\(r.stderr)")
    let after = try sbd.waitFor("the description", fetch: { try self.group(sbd, g.id) }) { $0.description != nil }
    #expect(after.descriptionBy == .claude)
  }
}
