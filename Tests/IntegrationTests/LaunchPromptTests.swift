import Foundation
import SwitchboardCore
import Testing

/// A session that sbd launched with a prompt reads Working until claude takes the prompt or ends.
@Suite(.blocking(timeLimit: .seconds(120))) struct LaunchPromptTests {
  @Test func aHeldLaunchWithAPromptReadsWorkingAndStaysOutOfTheInbox() throws {
    let sbd = try Instance()
    sbd.hold("hold-start")
    let s = try sbd.new(prompt: "hello", name: "held")
    try sbd.waitFor(s.id, "claude to run") { $0.claudePid != nil }

    let held = try sbd.get(s.id)
    #expect(held.state == .working, "\(held.state) \(held.reason)")
    #expect(try !sbd.triage().map(\.id).contains(s.id))

    try sbd.release("hold-start")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply != nil }
  }

  @Test func aLaunchWithoutAPromptNeedsAFirstPrompt() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "bare")
    try sbd.waitFor(s.id, "its first prompt card") { $0.state == .needsYou && $0.reason == "give it a first prompt" }
    #expect(try sbd.triage().map(\.id).contains(s.id))
  }

  @Test func aClaudeThatEndsBeforeTakingTheLaunchPromptNeedsYou() throws {
    let sbd = try Instance()
    sbd.hold("hold-start")
    let s = try sbd.new(prompt: "hello", name: "killed")
    let pid = try #require(try sbd.waitFor(s.id, "claude to run") { $0.claudePid != nil }.claudePid)
    try #require(try sbd.get(s.id).state == .working)

    kill(pid_t(pid), SIGTERM)

    try sbd.waitFor(s.id, "the session to need you") { $0.state == .needsYou }
    try sbd.release("hold-start")
  }
}
