import Foundation
import Testing

@testable import SwitchboardCore

/// These tests build each reason with sbd's own code, `Attention.evaluate` or
/// `Attention.toolSummary`. A change to how sbd writes a Bash reason fails them.
@Suite struct PlainReason {
  private func plain(_ verdict: Verdict) -> String {
    Attention.plainReason(verdict.reason, working: verdict.state == .working)
  }

  private func running(_ name: String, _ input: [String: JSON], for ms: Int64) -> Verdict {
    let f = facts([
      event("SessionStart", 0), event("UserPromptSubmit", 1000, ["prompt": "go"]),
      event("PreToolUse", 2000, tool(name, input, id: "t1")),
    ])
    return Attention.evaluate(session(), f, now: 2000 + ms)
  }

  @Test(arguments: [(Int64(3 * 60_000), " (3 min)"), (10_000, " (<1 min)")])
  func runningBashCommandReadsAsRunningAShellCommand(_ ms: Int64, _ time: String) {
    #expect(plain(running("Bash", ["command": "make test"], for: ms)) == "Running a shell command" + time)
  }

  @Test func commandWithBackticksReadsAsRunningAShellCommand() {
    let v = running("Bash", ["command": "git commit -m \"Fix `foo` bar\""], for: 60_000)
    #expect(plain(v) == "Running a shell command (1 min)")
  }

  @Test func permissionForABashCommandReadsAsApproveAShellCommand() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("PermissionRequest", 1, tool("Bash", ["command": "rm -rf build"])),
    ])
    #expect(plain(Attention.evaluate(session(), f, now: 2)) == "approve a shell command")
  }

  @Test func commandLongerThanTheCutReadsAsRunningAShellCommand() {
    let reason = Attention.toolSummary("Bash", ["command": .string(String(repeating: "x", count: 300))])
    #expect(Attention.plainReason(reason, working: true) == "Running a shell command")
  }

  @Test func otherToolStays() {
    let v = running("Edit", ["file_path": "/x/Main.swift"], for: 3 * 60_000)
    #expect(plain(v) == v.reason)
  }

  @Test func turnWithoutAToolStays() {
    let f = facts([event("SessionStart", 0), event("UserPromptSubmit", 1000, ["prompt": "go"])])
    let v = Attention.evaluate(session(), f, now: 1000 + 2 * 60_000)
    #expect(plain(v) == v.reason)
  }

  @Test func waitNoteThatIsACodeSpanStays() {
    let note = Attention.toolSummary("Bash", ["command": "swift build"])
    #expect(Attention.plainReason(note, working: false) == note)
  }
}
