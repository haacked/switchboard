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

  @Test func theGuideNamesOnlyCommandsThatSbHas() throws {
    let sbd = try Instance()
    let usage = try sbd.sb("help")
    let commands = Manager.guide.components(separatedBy: "`sb ").dropFirst().map {
      String($0.prefix { $0.isLetter })
    }
    #expect(commands.count >= 8)
    for command in commands {
      #expect(usage.contains("\n  \(command) "), "sb \(command)")
    }
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

  @Test func aParentHearsWhenAChildNeedsYou() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    let kid = try child(sbd, of: parent.id, name: "kid", prompt: "hello")
    let told = try sbd.waitFor(parent.id, "the message") { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }
    #expect(
      told.lastReply
        == "Done: Switchboard: sessions you started changed: kid (\(kid.id)) needs you: read its last reply and decide what's next."
    )
    #expect(try sbd.events(parent.id).filter { $0.kind == "sent" }.count == 1)
  }

  @Test func aParentHearsWhenAChildReachesDone() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    let kid = try child(sbd, of: parent.id, name: "kid")
    try sbd.waitFor(parent.id, "the first message") { $0.lastReply?.contains("needs you") == true }
    try sbd.sb("done", kid.id)
    try sbd.waitFor(parent.id, "the done message") { $0.lastReply?.hasSuffix("kid (\(kid.id)) is done.") == true }
  }

  /// Waits for a message from sbd that contains `text` and comes after the first `after` messages. It returns the messages after the first `after`.
  @discardableResult
  func waitForNotice(_ sbd: Instance, _ id: String, after: Int, containing text: String, timeout: Double = 30) throws
    -> [String]
  {
    let fetch = { Array(try sbd.messagesFromSbd(id).dropFirst(after)) }
    return try sbd.waitFor("a message with \(text)", timeout: timeout, fetch: fetch) {
      $0.contains { $0.contains(text) }
    }
  }

  @Test func aParentHearsWhenAChildOpensAPR() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let parent = try idle(sbd, name: "p")
    let kid = try sbd.session(
      in: ReadyForReviewTests.charts, branch: ReadyForReviewTests.branch, folder: "charts", parent: parent.id,
      name: "kid")
    try sbd.waitFor(parent.id, "the needs-you message", timeout: 30) { $0.lastReply?.contains("needs you") == true }
    try sbd.poll()
    let told = try sbd.waitFor(parent.id, "the PR message", timeout: 30) { $0.lastReply?.contains("opened PR") == true }
    #expect(
      told.lastReply
        == "Done: Switchboard: sessions you started changed: kid (\(kid.id)) opened PR #18303: https://github.com/PostHog/charts/pull/18303; kid (\(kid.id)): #18303 is ready to merge, approved by stamphog."
    )
  }

  @Test func aBusyParentHearsManyChangesInOneMessage() throws {
    let sbd = try Instance()
    // The parent's turn lasts until the test writes the report file. All three children change during the turn.
    let parent = try sbd.new(prompt: "slow held", name: "p")
    try sbd.waitFor(parent.id, "its turn") { $0.state == .working }
    let a = try child(sbd, of: parent.id, name: "a")
    let b = try child(sbd, of: parent.id, name: "b")
    let c = try child(sbd, of: parent.id, name: "c")
    for kid in [a, b, c] {
      try sbd.waitFor(kid.id, "\(kid.name)'s first reply", timeout: 30) {
        $0.lastReply == "Done: hello" && $0.state == .needsYou
      }
    }
    try #require(try sbd.get(parent.id).state == .working, "the parent's turn ended before the children's replies")
    try #require(try sbd.messagesFromSbd(parent.id).isEmpty)
    sbd.hold("report")
    let told = try sbd.waitFor(parent.id, "the message", timeout: 30) {
      $0.lastReply?.hasPrefix("Done: Switchboard:") == true
    }
    for kid in [a, b, c] { #expect(told.lastReply?.contains("(\(kid.id)) needs you") == true) }
    #expect(try sbd.events(parent.id).filter { $0.kind == "sent" }.count == 1)
  }

  // Issue #157.
  @Test func aBusyParentHearsAChildThatNeedsYouTwiceInOneLine() throws {
    let sbd = try Instance()
    let parent = try sbd.new(prompt: "slow 20", name: "p")
    try sbd.waitFor(parent.id, "its turn") { $0.state == .working }
    let kid = try child(sbd, of: parent.id, name: "kid")
    let first = try sbd.waitFor(kid.id, "the first reply", timeout: 30) {
      $0.lastReply == "Done: hello" && $0.state == .needsYou
    }
    // sbd ticks every 0.2 s. The wait lets a tick see the first Needs you.
    sleep(2)
    try sbd.sb("send", kid.id, "slow 3")
    try sbd.waitFor(kid.id, "the second turn") { $0.state == .working }
    let second = try sbd.waitFor(kid.id, "the second reply", timeout: 30) {
      $0.lastReply == "Slept 3 s." && $0.state == .needsYou
    }
    try #require(second.reason == first.reason)
    try #require(try sbd.get(parent.id).state == .working, "the parent's turn ended before the kid's second reply")
    try #require(try sbd.messagesFromSbd(parent.id).isEmpty)

    let told = try waitForNotice(sbd, parent.id, after: 0, containing: "(\(kid.id)) needs you", timeout: 45)

    let lines = told.joined().components(separatedBy: "(\(kid.id)) needs you").count - 1
    #expect(lines == 1, "\(told)")
  }

  // Issue #158.
  @Test func aParentHearsOfAChildsPROnlyOnceAcrossARestart() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let parent = try idle(sbd, name: "p")
    let kid = try sbd.session(
      in: ReadyForReviewTests.charts, branch: ReadyForReviewTests.branch, folder: "charts", parent: parent.id,
      name: "kid")
    try waitForNotice(sbd, parent.id, after: 0, containing: "needs you")
    try sbd.poll()
    try waitForNotice(sbd, parent.id, after: 0, containing: "opened PR #18303")

    // A branch without a PR drops the kid's PR, and the kid needs you again.
    try sbd.git(kid.cwd, "branch", "haacked/no-pr-yet")
    func dropPR() throws {
      let heard = try sbd.messagesFromSbd(parent.id).count
      try sbd.git(kid.cwd, "checkout", "-q", "haacked/no-pr-yet")
      try sbd.poll()
      try #require(try sbd.get(kid.id).pr == nil)
      try waitForNotice(sbd, parent.id, after: heard, containing: "(\(kid.id)) needs you")
    }
    /// Brings the PR back as `number` and returns how many messages the parent had before.
    func returnPR(as number: Int) throws -> Int {
      let heard = try sbd.messagesFromSbd(parent.id).count
      try sbd.git(kid.cwd, "checkout", "-q", ReadyForReviewTests.branch)
      try sbd.poll()
      try sbd.waitFor(kid.id, "PR #\(number)") { $0.pr?.number == number }
      return heard
    }
    // The PR's line comes before its state's line, in the same message or an earlier one.
    func expectNoSecondAnnouncement(after heard: Int) throws {
      let told = try waitForNotice(sbd, parent.id, after: heard, containing: "#18303 is ready to merge")
      #expect(!told.contains { $0.contains("opened PR #18303") }, "\(told)")
    }

    try dropPR()
    try expectNoSecondAnnouncement(after: try returnPR(as: 18303))

    try dropPR()
    // A restart in the middle of a paste leaves the pasted text in claude's
    // prompt box, and that text holds every later message.
    try sbd.waitFor(parent.id, "the parent's reply to the notice") {
      $0.lastReply?.contains("(\(kid.id)) needs you") == true
    }
    try sbd.restart(setting: "tickSeconds", to: 0.2)
    try #require(try sbd.get(kid.id).pr == nil)
    try expectNoSecondAnnouncement(after: try returnPR(as: 18303))

    // The same branch's PR comes back as one the parent never heard of.
    try dropPR()
    github.change(18303) {
      $0["number"] = 18304
      $0["url"] = "https://github.com/PostHog/charts/pull/18304"
    }
    try waitForNotice(
      sbd, parent.id, after: try returnPR(as: 18304),
      containing: "kid (\(kid.id)) opened PR #18304: https://github.com/PostHog/charts/pull/18304")
  }

  @Test func aStoppedParentResumesWithTheMessage() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    try sbd.sb("stop", parent.id)
    try sbd.waitFor(parent.id, "the stop") { !$0.live }
    let kid = try child(sbd, of: parent.id, name: "kid")
    try sbd.waitFor(parent.id, "the resumed turn", timeout: 30) {
      $0.lastReply?.contains("(\(kid.id)) needs you") == true
    }
    #expect(sbd.stubArgs().contains { $0.hasPrefix("--resume \(parent.claudeSessionId) ") })
  }

  @Test func aRestartedSbdDoesNotRepeatWhatItAlreadyTold() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    let kid = try child(sbd, of: parent.id, name: "kid")
    try sbd.waitFor(parent.id, "the message") { $0.lastReply?.contains("(\(kid.id)) needs you") == true }
    let sent = try sbd.events(parent.id).filter { $0.kind == "sent" }.count
    try sbd.restart(setting: "tickSeconds", to: 0.2)
    sleep(2)
    #expect(try sbd.events(parent.id).filter { $0.kind == "sent" }.count == sent)
  }

  @Test func aFollowupIsNotAChildOfTheSessionThatCapturedIt() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    try sbd.sb("followup", "add", "look at the cache", "--repo", "o/r", "--parent", parent.id)
    sleep(1)
    #expect(try sbd.events(parent.id).filter { $0.kind == "sent" }.isEmpty)
  }
}
