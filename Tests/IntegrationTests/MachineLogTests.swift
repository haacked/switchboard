import Foundation
import SwitchboardCore
import Testing

/// With `machineLog` on, sbd logs every call on this Mac's machine and site. A later test of a remote session
/// asserts that the log holds none of that session's ids and paths. These tests show that the log does hold a
/// local session's.
@Suite(.blocking(timeLimit: .seconds(120))) struct MachineLogTests {
  private func logging() throws -> Instance { try Instance(config: Instance.machineLogConfig) }

  @Test func aLocalSessionsStartLogsTheTmuxCommandThatCreatesItsClaudePane() throws {
    let sbd = try logging()

    let s = try sbd.new()

    let call = try sbd.waitForMachineCall("the new-session call of \(s.id)'s Claude pane") {
      $0.runs("tmux") && $0.has("new-session") && $0.has("\(s.id)-claude")
    }
    #expect(call.has(s.cwd), "\(call)")
  }

  @Test func aLocalSessionsStartLogsTheGitCommandThatReadsItsFolder() throws {
    let sbd = try logging()

    let s = try sbd.new()

    _ = try sbd.waitForMachineCall("a git call in \(s.cwd)") {
      $0.runs("git") && $0.has(s.cwd) && $0.has("--show-current")
    }
  }

  @Test func aSessionOnANewBranchLogsTheGitCommandThatAddsItsWorktree() throws {
    let sbd = try logging()
    let repo = try sbd.makeRepo()

    let s = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "haacked/logged"], as: SessionSummary.self)

    let call = try sbd.waitForMachineCall("the worktree add call for \(s.cwd)") {
      $0.runs("git") && $0.has("worktree") && $0.has("add") && $0.has(s.cwd)
    }
    #expect(call.has(repo), "\(call)")
    #expect(call.has("haacked/logged"), "\(call)")
  }

  @Test func stoppingALocalSessionLogsTheSitesStopWithTheClaudePid() throws {
    let sbd = try logging()
    let s = try sbd.new(prompt: "hello")
    let pid = try #require(try sbd.waitFor(s.id, "claude to run") { $0.claudePid != nil }.claudePid)

    try sbd.sb("stop", s.id)

    _ = try sbd.waitForMachineCall("the stopClaude call for pid \(pid)") {
      $0.has("stopClaude") && $0.has(String(pid))
    }
  }

  @Test func removingALocalWorktreeLogsTheSitesProcessAndPathChecksOfItsFolder() throws {
    let sbd = try logging()
    let s = try sbd.worktreeSession(try sbd.repoWithOrigin())
    let pid = try #require(try sbd.waitFor(s.id, "claude to run") { $0.claudePid != nil }.claudePid)

    let removed = try sbd.deleteSession(s.id)

    try #require(removed.status == 0, "\(removed.stderr)")
    let calls = try sbd.machineCalls()
    #expect(calls.contains { $0.has("folderUsers") && $0.has(s.cwd) })
    #expect(calls.contains { $0.has("alive") && $0.has(String(pid)) })
    #expect(calls.contains { $0.has("samePath") && $0.has(s.cwd) })
  }

  @Test func sbdWritesNoLogWhenTheKeyIsOff() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")

    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }

    #expect(!FileManager.default.fileExists(atPath: sbd.machineLog))
  }
}
