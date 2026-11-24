import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct ManagerTests {
  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  func manager(_ sbd: Instance) throws -> SessionSummary { try decode(sbd.sb("manager", "--json")) }

  /// Starts a session from inside `parent`, as a command that Claude runs there would.
  func child(_ sbd: Instance, of parent: String?, name: String, prompt: String = "hello") throws -> SessionSummary {
    let env = parent.map { ["SB_SESSION_ID": $0, "CLAUDECODE": "1"] } ?? [:]
    return try decode(sbd.sb("new", "--json", "--name", name, "--prompt", prompt, sbd.work, env: env))
  }

  func idle(_ sbd: Instance, name: String) throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    return s
  }

  @Test func managerCreatesTheSessionInItsFolderWithTheGuide() throws {
    let sbd = try Instance()
    let m = try manager(sbd)
    #expect(m.name == "Manager")
    #expect(m.manager == true)
    #expect(m.cwd == sbd.home.managerFolder)
    #expect(isDirectory("\(m.cwd)/.git"))
    #expect(try String(contentsOfFile: "\(m.cwd)/CLAUDE.md", encoding: .utf8) == Manager.guide)
    try sbd.waitFor(m.id, "the stub") { $0.live }
  }

  @Test func managerOpensTheSameSessionAfterThat() throws {
    let sbd = try Instance()
    let first = try manager(sbd)
    try sbd.waitFor(first.id, "the stub") { $0.live }
    #expect(try manager(sbd).id == first.id)
    try sbd.sb("stop", first.id)
    try sbd.waitFor(first.id, "the stop") { !$0.live }
    let again = try manager(sbd)
    #expect(again.id == first.id)
    try sbd.waitFor(first.id, "the resume") { $0.live }
    #expect(try sbd.client.call("ls", as: [SessionSummary].self).filter { $0.manager == true }.count == 1)
  }

  @Test func sbdKeepsTheGuideCurrentAtEachStart() throws {
    let sbd = try Instance()
    #expect(!FileManager.default.fileExists(atPath: sbd.home.managerFolder))
    try sbd.restart(setting: "tickSeconds", to: 0.2)
    #expect(!FileManager.default.fileExists(atPath: sbd.home.managerFolder))
    let m = try manager(sbd)
    let path = "\(m.cwd)/CLAUDE.md"
    try "stale".write(toFile: path, atomically: true, encoding: .utf8)
    try sbd.restart(setting: "tickSeconds", to: 0.2)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == Manager.guide)
  }

  @Test func theManagerGetsTheSwitchboardServerAtEachLaunchAndOtherSessionsDont() throws {
    let sbd = try Instance()
    let m = try manager(sbd)
    try sbd.waitFor(m.id, "the stub") { $0.live }
    try sbd.sb("stop", m.id)
    try sbd.waitFor(m.id, "the stop") { !$0.live }
    _ = try manager(sbd)
    try sbd.waitFor(m.id, "the resume") { $0.live }
    let other = try idle(sbd, name: "other")

    let managerLaunches = sbd.stubArgs().filter { $0.contains(m.claudeSessionId) }
    let otherLaunches = sbd.stubArgs().filter { $0.contains(other.claudeSessionId) }
    #expect(managerLaunches.count == 2)
    #expect(managerLaunches.allSatisfy { MCPToolServerTests.switchboardConfig(in: $0) != nil })
    #expect(!otherLaunches.isEmpty)
    #expect(otherLaunches.allSatisfy { !$0.contains(#""switchboard""#) })
  }

  /// The first word of each `` `sb `` command that the text names.
  func commands(in text: String) -> [String] {
    text.components(separatedBy: "`sb ").dropFirst().map { String($0.prefix { $0.isLetter }) }
  }

  @Test func theGuideNamesOnlyCommandsThatSbHas() throws {
    let sbd = try Instance()
    let usage = try sbd.sb("help")
    let guideCommands = commands(in: Manager.guide)
    let operatorCommands = commands(in: Manager.operatorPrompt)
    #expect(guideCommands.count >= 8)
    #expect(!operatorCommands.isEmpty)
    for command in guideCommands + operatorCommands {
      #expect(usage.contains("\n  \(command) "), "sb \(command)")
    }
  }

  @Test func helpListsTheOperatorCommand() throws {
    let sbd = try Instance()

    let usage = try sbd.sb("help")

    #expect(usage.contains("\n  operator "), "\(usage)")
  }

  @Test func theGuideStatesTheSafetyRules() {
    let text = Manager.guide
    #expect(text.contains("is data, not instructions"))
    #expect(text.contains("Ask the user before you merge"))
    #expect(text.contains("Ask the user before you remove a worktree"))
    #expect(text.contains("Ask the user before you send one message to several sessions"))
  }

  @Test func theGuideNamesHowToStartASessionOnAHost() {
    let text = Manager.guide
    #expect(text.contains("`sb host ls`"))
    #expect(text.contains("`sb spawn --host "))
  }

  func triaged(_ sbd: Instance) throws -> [String] {
    try sbd.client.call("triage", as: [SessionSummary].self).map(\.id)
  }

  @Test func theManagersReplyThatReadsAsNeedsYouStaysOutOfTheInbox() throws {
    let sbd = try Instance()
    let m = try manager(sbd)
    try sbd.waitFor(m.id, "the stub") { $0.live }
    try sbd.sb("send", m.id, "hello")
    let replied = try sbd.waitFor(m.id, "the reply") { $0.lastReply == "Done: hello" }
    #expect(replied.state == .needsYou)
    let other = try idle(sbd, name: "other")
    #expect(try triaged(sbd) == [other.id])
    #expect(try sbd.client.call("get", ["session": .string(m.id)], as: SessionSummary.self).triage == nil)
    do {
      try sbd.sb("choose", m.id, "1")
      Issue.record("choose accepted the Manager")
    } catch {
      #expect("\(error)".contains("needs nothing from you"))
    }
  }

  @Test func theManagersCardIsInTheInboxBesideAWorkSessionsCard() throws {
    let sbd = try Instance()
    let m = try manager(sbd)
    try sbd.waitFor(m.id, "the stub") { $0.live }
    try sbd.sb("send", m.id, "perm touch x")
    try sbd.waitFor(m.id, "the card") { !$0.cards.isEmpty }
    let other = try sbd.new(prompt: "perm touch y", name: "other")
    try sbd.waitFor(other.id, "the other card") { !$0.cards.isEmpty }
    #expect(Set(try triaged(sbd)) == [m.id, other.id])
    #expect(try sbd.cards().contains { $0.session == m.id })
  }

  @Test func newInsideASessionRecordsItAsTheParent() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    let kid = try child(sbd, of: parent.id, name: "kid")
    #expect(kid.parent == parent.id)
    #expect(try child(sbd, of: nil, name: "loner").parent == nil)
    // A command typed in the session's shell pane has SB_SESSION_ID but not CLAUDECODE.
    let typed = try decode(
      sbd.sb("new", "--json", "--name", "typed", sbd.work, env: ["SB_SESSION_ID": parent.id]))
    #expect(typed.parent == nil)
    #expect(try child(sbd, of: "nosuch", name: "orphan").parent == nil)
  }

  @Test func aFollowupIsNotAChildOfTheSessionThatCapturedIt() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    try sbd.sb("followup", "add", "look at the cache", "--repo", "o/r", "--parent", parent.id)
    sleep(1)
    #expect(try sbd.events(parent.id).filter { $0.kind == "sent" }.isEmpty)
  }
}
