import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// Pane pids that no test signals. `snapshot.claudePids` stays empty, so `beginPaneStop` sends SIGTERM to no
/// process, and the tests can use pids that name live processes of other programs.
private let claudePane = 4242
private let shellPane = 4343
private let caller = 5151
private let session = "s1"

/// The refusal that `beginPaneStop` throws for a caller inside the session.
private func refusal(_ command: String) -> String {
  "`\(command)` runs inside \(session), so it would stop itself. Run it from a terminal outside the session."
}

/// A `Service` in a temporary home whose snapshot holds the session's Claude and shell panes. The service never
/// loads, so it starts no tmux server and no claude.
private func withPanes(claude: PaneRow, shell: PaneRow, _ body: (Service) throws -> Void) throws {
  let home = Home(path: try makeShortTempFolder())
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  let service = try Service(home: home, sbPath: "/usr/bin/true")
  service.queue.sync {
    service.snapshot.panes[service.paneName(session, .claude)] = claude
    service.snapshot.panes[service.paneName(session, .shell)] = shell
  }
  try body(service)
}

private func live(_ pid: Int) -> PaneRow { PaneRow(pid: pid, dead: false, clients: 0) }
private func dead(_ pid: Int) -> PaneRow { PaneRow(pid: pid, dead: true, clients: 0) }

/// sbd refuses `sb rm --worktree`, `sb cleanup`, and `sb rm --done --worktree` from a process below one of the
/// session's panes, before it stops anything.
@Suite struct SelfRemovalGuardTests {
  // MARK: beginPaneStop

  /// The last ancestry is `exec sb rm …` in the shell pane, which makes sb the pane's own process.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [[caller, 900, claudePane, 1], [caller, shellPane, 1], [shellPane, 1]] as [Set<Int>],
    ["sb rm --worktree", "sb cleanup"])
  func beginPaneStopRefusesACallerBelowALivePane(ancestry: Set<Int>, command: String) throws {
    try withPanes(claude: live(claudePane), shell: live(shellPane)) { service in
      do {
        _ = try service.queue.sync { try service.beginPaneStop(session, caller: ancestry, command: command) }
        Issue.record("beginPaneStop accepted the ancestry \(ancestry)")
      } catch {
        #expect("\(error)" == refusal(command))
      }
    }
  }

  /// A dead pane keeps its last pid in tmux, and that pid no longer runs. `.inProcess` callers, such as sbd's
  /// automatic cleanup, have no ancestry to check.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      (true, [caller, shellPane, 1]), (false, nil), (false, [caller, 900, 1]),
    ] as [(Bool, Set<Int>?)])
  func beginPaneStopAcceptsACallerOutsideTheSession(shellDead: Bool, ancestry: Set<Int>?) throws {
    try withPanes(claude: live(claudePane), shell: shellDead ? dead(shellPane) : live(shellPane)) { service in
      #expect(throws: Never.self) {
        _ = try service.queue.sync { try service.beginPaneStop(session, caller: ancestry, command: "sb rm --worktree") }
      }
    }
  }

  // MARK: Caller.ancestry

  @Test func anInProcessCallerHasNoAncestry() throws {
    #expect(try Caller.inProcess.ancestry(command: "sb rm --worktree") == nil)
  }

  @Test func theAncestryOfThisProcessHoldsThisProcess() throws {
    let ancestry = try Caller.client(pid: Int(getpid())).ancestry(command: "sb rm --worktree")
    #expect(ancestry?.contains(Int(getpid())) == true)
  }

  /// sbd can't show that such a caller runs outside the session, so it refuses. `Int32.max` passes
  /// `Processes.isValidPid` and names no process, so the refusal comes from the failed lookup.
  @Test(arguments: [nil, 0, Int(Int32.max)] as [Int?])
  func aCallerWhosePidCantBeReadIsRefused(pid: Int?) throws {
    do {
      let ancestry = try Caller.client(pid: pid).ancestry(command: "sb cleanup")
      Issue.record("ancestry returned \(String(describing: ancestry))")
    } catch {
      #expect("\(error)".contains("can't tell"), "\(error)")
      #expect("\(error)".contains("`sb cleanup`"), "\(error)")
    }
  }
}
