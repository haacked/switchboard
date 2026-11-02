import Testing

@testable import SwitchboardCore

@Suite struct ClaudeSessionStopTests {
  private func session(
    pid: Int? = 10, status: String? = "idle", job: String? = nil, otherPids: [Int]? = nil
  ) -> ClaudeSession {
    ClaudeSession(
      id: "a1b2c3d4-0000", name: "work", cwd: "/tmp/w", account: "/tmp/a", status: status, job: job, pid: pid,
      otherPids: otherPids)
  }

  @Test func isStoppableOnlyWhenOneInteractiveClaudeIsIdle() {
    #expect(session().stoppable)
    #expect(!session(status: "busy").stoppable)
    #expect(!session(status: "waiting").stoppable)
    #expect(!session(job: "deadbeef").stoppable)
    #expect(!session(pid: nil, status: nil).stoppable)
    #expect(!session(otherPids: [11]).stoppable)
  }

  @Test func isImportableWhenNoClaudeRunsItOrImportCanExitItsClaude() {
    #expect(session(pid: nil, status: nil).importable)
    #expect(session().importable)
    #expect(!session(status: "busy").importable)
    #expect(!session(otherPids: [11]).importable)
  }

  @Test func namesEveryPidWhenSeveralClaudesRunTheSession() {
    let several = session(otherPids: [11, 12])

    #expect(several.livePids == [10, 11, 12])
    #expect(several.whereItRuns("work")?.contains("runs in several claudes") == true)
    #expect(several.whereItRuns("work")?.contains("pids 10, 11, 12") == true)
    #expect(several.whereItRuns("work")?.contains("--stop") == false)
    #expect(several.summary == "in several claudes")
  }

  @Test func offersStopOnlyForAStoppableSession() {
    #expect(session().whereItRuns("work")?.contains("--stop") == true)
    #expect(session(status: "busy").whereItRuns("work")?.contains("--stop") == false)
  }

  @Test func clearsTheProcessAndEveryOtherPidWhenNoClaudeRunsIt() {
    var s = session(otherPids: [11])

    s.clearProcess()

    #expect(s.livePids.isEmpty && s.status == nil && !s.running)
  }

  @Test func sharesThePidThatTwoSessionsHaveInCommon() {
    let a = session(pid: 10, otherPids: [11, 12])
    let b = session(pid: 12, otherPids: [13])

    #expect(a.sharedPid(with: b) == 12)
    #expect(a.sharedPid(with: session(pid: 99)) == nil)
  }
}
