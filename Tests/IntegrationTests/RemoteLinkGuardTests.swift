import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"

/// A remote session while sbd can't read its host. sbd decides nothing about the session from a read that the host
/// did not answer: it records no `exited`, starts no claude, signals nothing, and reports no folder gone. A request
/// that needs the host waits up to 15 s for it, so each refused request here takes that long.
@Suite(.blocking(timeLimit: .seconds(180))) struct RemoteLinkGuardTests {
  private struct Running {
    var id: String
    var claudeSessionId: String
    var cwd: String
    var pid: Int
  }

  /// A session on mini in `~/sb-box-repo` whose claude runs and has answered its first prompt.
  private func start(_ sbd: Instance) throws -> Running {
    try sbd.makeBoxFolder()
    let summary = try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello")
    let id = try sbd.id(of: summary)
    let claudeSessionId = try #require(summary["claudeSessionId"]?.string)
    let pid = try #require(try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }.claudePid)
    try sbd.waitFor("the first turn's transcript on the box") { !sbd.boxTranscripts(claudeSessionId).isEmpty }
    return Running(id: id, claudeSessionId: claudeSessionId, cwd: try #require(summary["cwd"]?.string), pid: pid)
  }

  /// Runs several ticks, the idle rule's 10 s among them, so that every rule of the tick has seen the session.
  private func tick(_ sbd: Instance) throws {
    for _ in 0..<3 { try sbd.advanceClock(11_000) }
  }

  private func kinds(_ sbd: Instance, _ id: String, after: Int64 = 0) throws -> [String] {
    try sbd.events(id).filter { $0.id > after }.map(\.kind)
  }

  private func lastEvent(_ sbd: Instance, _ id: String) throws -> Int64 { try sbd.events(id).last?.id ?? 0 }

  /// The Mac's calls that name the session, its folder, the box, or its claude's pid in a signal.
  private func macCalls(_ sbd: Instance, for s: Running) throws -> [Instance.MachineCall] {
    let named = try sbd.macCalls(holding: sbd.namesOfRemoteSession(s.id, cwd: s.cwd) + [s.claudeSessionId])
    let signalled = try sbd.machineCalls().filter {
      ($0.has("signal") || $0.has("stopClaude") || $0.has("alive")) && $0.has(String(s.pid))
    }
    return named + signalled
  }

  // MARK: The link drops

  @Test func aLinkThatDroppedBeforeATickLeavesNoExitAndNoRelaunch() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    let before = try lastEvent(sbd, s.id)

    try sbd.dropLinkAndRefuse(refusal)
    try tick(sbd)

    let after = try kinds(sbd, s.id, after: before)
    #expect(!after.contains("exited"), "\(after)")
    #expect(!after.contains("stopped"), "\(after)")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
    #expect(sbd.runs(s.pid))
    #expect(try macCalls(sbd, for: s).isEmpty)
  }

  @Test func aSessionWhoseLinkIsDownHasNoClaudePidAndNamesTheLinksState() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)

    try sbd.dropLinkAndRefuse(refusal)
    try tick(sbd)

    // A link that is down retries, so it reads `connecting` during each attempt.
    let summary = try sbd.waitFor(
      "the summary to name the unreachable link", fetch: { try sbd.summaryJSON(s.id) },
      until: { $0["link"] == "unreachable" })
    #expect(summary.object?.keys.contains("claudePid") == false, "\(summary.text)")
    #expect(summary["host"] == "mini")
  }

  @Test func aLinkThatDropsWhileTheBatchedReadRunsLeavesNoExitAndNoRelaunch() throws {
    let sbd = try Instance.remote(boxBin: true)
    try sbd.installBoxPsGate()
    let s = try start(sbd)
    let before = try lastEvent(sbd, s.id)

    sbd.hold("ps-gate")
    try? FileManager.default.removeItem(atPath: sbd.gate("ps-waiting"))
    try sbd.waitFor("a batched read to reach the box's ps") {
      FileManager.default.fileExists(atPath: sbd.gate("ps-waiting"))
    }
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.release("ps-gate")
    try tick(sbd)

    let after = try kinds(sbd, s.id, after: before)
    #expect(!after.contains("exited"), "\(after)")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
    #expect(sbd.runs(s.pid))
    #expect(try sbd.summaryJSON(s.id).object?.keys.contains("claudePid") == false)
    #expect(try macCalls(sbd, for: s).isEmpty)
  }

  @Test func theSessionReadsAsRunningAgainAfterTheLinkReconnects() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    let before = try lastEvent(sbd, s.id)
    try sbd.dropLinkAndRefuse(refusal)
    try tick(sbd)

    try sbd.restoreLink()
    let back = try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }

    #expect(back.claudePid == s.pid)
    #expect(try sbd.summaryJSON(s.id)["link"] == "connected")
    let after = try kinds(sbd, s.id, after: before)
    #expect(!after.contains("exited"), "\(after)")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  @Test func aLinkThatReconnectsOnItsOwnLeavesNoExitAndNoRelaunch() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    let before = try lastEvent(sbd, s.id)

    let first = try sbd.dropLink("mini")
    try sbd.waitFor("a new master") { try sbd.sshStubPid(Instance.boxDestination).map { $0 != first } ?? false }
    try sbd.waitForLink("mini", .connected)
    let back = try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }
    try tick(sbd)

    #expect(back.claudePid == s.pid)
    let after = try kinds(sbd, s.id, after: before)
    #expect(!after.contains("exited"), "\(after)")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  // MARK: Requests while the link is down

  @Test func stopWithTheLinkDownFailsWithTheReasonAndSignalsNothing() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.dropLinkAndRefuse(refusal)
    let before = try lastEvent(sbd, s.id)

    let r = try sbd.run("stop", s.id)

    #expect(r.status == 1)
    #expect(r.stderr.contains("mini is not connected"), "\(r.stderr)")
    #expect(r.stderr.contains(refusal), "\(r.stderr)")
    #expect(sbd.runs(s.pid))
    #expect(!(try kinds(sbd, s.id, after: before)).contains("stopped"))
    #expect(try macCalls(sbd, for: s).isEmpty)
  }

  @Test(arguments: ["resume", "open"])
  func aLaunchWithTheLinkDownFailsWithTheReasonAndStartsNothing(verb: String) throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }
    try sbd.dropLinkAndRefuse(refusal)

    let r = try sbd.run(verb, s.id)
    try tick(sbd)

    #expect(r.status == 1)
    #expect(r.stderr.contains("mini is not connected"), "\(r.stderr)")
    #expect(r.stderr.contains(refusal), "\(r.stderr)")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac: \(sbd.stubArgs())")
    #expect(try macCalls(sbd, for: s).isEmpty)
  }

  /// The session's folder exists on the box and also resolves on this Mac, because the stub's box is a folder here.
  /// A check on this Mac would pass, and an unanswered check on the host reads as "missing".
  @Test(arguments: ["resume", "open"])
  func aFolderThatExistsOnTheBoxIsNotReportedGoneWhileTheLinkIsDown(verb: String) throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }
    try sbd.dropLinkAndRefuse(refusal)

    let r = try sbd.run(verb, s.id)
    try tick(sbd)

    #expect(r.status == 1)
    #expect(!r.stderr.contains("is gone"), "\(r.stderr)")
    #expect(!r.stderr.contains("can't start there"), "\(r.stderr)")
    #expect(!(try kinds(sbd, s.id)).contains("worktree"))
    #expect(FileManager.default.fileExists(atPath: s.cwd))
  }

  @Test func screenWithTheLinkDownFailsWithTheReason() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.dropLinkAndRefuse(refusal)

    let r = try sbd.run("screen", s.id)

    #expect(r.status == 1)
    #expect(r.stderr.contains("mini is not connected"), "\(r.stderr)")
    #expect(r.stdout.isEmpty)
    #expect(try macCalls(sbd, for: s).isEmpty)
  }

  // MARK: After the reconnect

  @Test func stopWorksAfterTheLinkReconnects() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.dropLinkAndRefuse(refusal)
    let refused = try sbd.run("stop", s.id)
    try sbd.restoreLink()
    try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }

    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }

    #expect(refused.status == 1)
    #expect(!sbd.runs(s.pid))
    #expect(try kinds(sbd, s.id).filter { $0 == "stopped" }.count == 1)
  }

  @Test(arguments: ["resume", "open"])
  func aLaunchWorksAfterTheLinkReconnectsAndResumesTheConversation(verb: String) throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }
    try sbd.dropLinkAndRefuse(refusal)
    let refused = try sbd.run(verb, s.id)
    try sbd.restoreLink()

    try sbd.sb(verb, s.id)
    let back = try sbd.waitFor(s.id, "claude to run after \(verb)") { $0.claudePid != nil }

    #expect(refused.status == 1)
    #expect(back.claudePid != s.pid)
    let args = sbd.boxStubArgs()
    try #require(args.count == 2, "\(args)")
    #expect(args[1].hasPrefix("--resume \(s.claudeSessionId)"), "\(args[1])")
  }

  @Test func screenWorksAfterTheLinkReconnects() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.restoreLink()

    let screen = try sbd.waitFor(
      "the screen after the reconnect", fetch: { try sbd.sb("screen", s.id) },
      until: { $0.contains("claude-stub \(s.claudeSessionId) (startup)") })

    #expect(screen.contains("⏺ Done: hello"))
  }

  // MARK: A host that left config.json

  @Test func aSessionWhoseHostLeftTheConfigNeverRunsOnThisMac() throws {
    let sbd = try Instance.remote()
    let s = try start(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }

    try sbd.restart(setting: "hosts", to: [:])
    let resume = try sbd.run("resume", s.id)
    let stop = try sbd.run("stop", s.id)
    try tick(sbd)

    #expect(resume.status == 1)
    #expect(resume.stderr.contains("mini"), "\(resume.stderr)")
    #expect(stop.status == 1)
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac: \(sbd.stubArgs())")
    #expect(sbd.boxStubArgs().count == 1)
    #expect(try sbd.summaryJSON(s.id)["host"] == "mini")
    #expect(try macCalls(sbd, for: s).isEmpty)
  }
}
