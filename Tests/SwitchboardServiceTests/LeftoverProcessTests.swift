import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// `Service.leftovers` compares a session's `created`, in milliseconds since the epoch, with each row's `startTime`,
/// in microseconds since the epoch. The values have real magnitudes, so a comparison that mixes the units includes
/// or excludes every process.
@Suite struct LeftoverProcessTests {
  private static let created: Int64 = 1_700_000_000_000
  private static let createdMicroseconds = created * 1000
  private static let pid = 4242

  private func user(_ pid: Int = Self.pid, _ use: FolderUse = .workingFolder) -> FolderUser {
    FolderUser(pid: pid, use: use, path: "/Users/x/dev/worktrees/repo/branch")
  }

  private func row(
    _ pid: Int = Self.pid, ppid: Int = 1, startTime: Int64 = Self.createdMicroseconds + 5_000_000,
    isZombie: Bool = false
  ) -> ProcessRow {
    ProcessRow(pid: pid, ppid: ppid, pgid: pid, startTime: startTime, isZombie: isZombie)
  }

  private static let sessionId = "swb_k92d2"

  private func leftovers(
    _ users: [FolderUser], _ rows: [ProcessRow], sparing: Set<Int> = [],
    environment: [String] = ["PATH=/bin", "SB_SESSION_ID=\(sessionId)"]
  ) -> Set<Int> {
    Set(
      Service.leftovers(
        users, in: ProcessTable(nativeRows: rows), sessionId: Self.sessionId, startedSince: Self.created,
        sparing: sparing, environment: { _ in environment }
      ).keys)
  }

  // MARK: Included

  @Test(arguments: [FolderUse.workingFolder, .program, .openFile])
  func anOrphanThatStartedAfterTheSessionIsALeftover(use: FolderUse) {
    let result = leftovers([user(Self.pid, use)], [row()])

    #expect(result == [Self.pid])
  }

  @Test func anOrphanThatStartedAtTheSessionsCreatedTimeIsALeftover() {
    let result = leftovers([user()], [row(startTime: Self.createdMicroseconds)])

    #expect(result == [Self.pid])
  }

  /// The start time falls inside the millisecond that `created` names.
  @Test func anOrphanThatStartedWithinTheCreatedMillisecondIsALeftover() {
    let result = leftovers([user()], [row(startTime: Self.createdMicroseconds + 999)])

    #expect(result == [Self.pid])
  }

  // MARK: Excluded

  @Test func anOrphanThatStartedBeforeTheSessionIsNotALeftover() {
    let result = leftovers([user()], [row(startTime: Self.createdMicroseconds - 60_000_000)])

    #expect(result.isEmpty)
  }

  /// One microsecond before `created` rounds up to `created` when the start time is rounded to milliseconds.
  @Test func anOrphanThatStartedOneMicrosecondBeforeTheSessionIsNotALeftover() {
    let result = leftovers([user()], [row(startTime: Self.createdMicroseconds - 1)])

    #expect(result.isEmpty)
  }

  /// ppid 0 is the parent of launchd itself.
  @Test(arguments: [0, 2, 501, 98_765])
  func aProcessWhoseParentIsNotLaunchdIsNotALeftover(ppid: Int) {
    let result = leftovers([user()], [row(ppid: ppid)])

    #expect(result.isEmpty)
  }

  @Test func aZombieOrphanIsNotALeftover() {
    let result = leftovers([user()], [row(isZombie: true)])

    #expect(result.isEmpty)
  }

  @Test func aUserThatTheTableDoesNotListIsNotALeftover() {
    let result = leftovers([user(Self.pid)], [row(Self.pid + 1)])

    #expect(result.isEmpty)
  }

  /// A table parsed from `ps` text has no start times, so no row can show that it started after the session.
  @Test func anOrphanInATableParsedFromPsIsNotALeftover() {
    let table = ProcessTable.parse("\(Self.pid) 1 \(Self.pid) /bin/sleep 100\n")

    let result = Service.leftovers(
      [user()], in: table, sessionId: Self.sessionId, startedSince: Self.created,
      environment: { _ in ["SB_SESSION_ID=\(Self.sessionId)"] })

    #expect(result.isEmpty)
  }

  /// Another session's id, no id, an id that extends the session's, and an environment that the kernel would not
  /// read all leave the process to the user.
  @Test(arguments: [
    ["SB_SESSION_ID=swb_other"], ["PATH=/bin"], ["SB_SESSION_ID=\(sessionId)x"], ["X_SB_SESSION_ID=\(sessionId)"], [],
  ])
  func anOrphanThatTheSessionDidNotStartIsNotALeftover(environment: [String]) {
    let result = leftovers([user()], [row()], environment: environment)

    #expect(result.isEmpty)
  }

  /// sbd's tmux server has launchd as its parent. A server that inherited a session's id would otherwise qualify.
  @Test func aSparedPidIsNotALeftover() {
    let result = leftovers([user()], [row()], sparing: [Self.pid])

    #expect(result.isEmpty)
  }

  @Test func noUsersHaveNoLeftovers() {
    let result = leftovers([], [row()])

    #expect(result.isEmpty)
  }

  // MARK: Mixed

  @Test func onlyTheOrphansThatStartedSinceTheSessionAreLeftovers() {
    let users = [
      user(100, .workingFolder), user(101, .program), user(102, .openFile), user(103), user(104), user(105),
    ]
    let rows = [
      row(100),
      row(101, startTime: Self.createdMicroseconds),
      row(102, startTime: Self.createdMicroseconds - 1),
      row(103, ppid: 100),
      row(104, isZombie: true),
      row(106),
    ]

    let result = leftovers(users, rows)

    #expect(result == [100, 101])
  }

  // MARK: Spared

  /// The server 500 is not an ancestor of the pane's process, so only the server's own entry spares it.
  @Test func paneAncestryHoldsEachPanesProcessItsAncestorsAndItsServer() throws {
    try withService { service, _ in
      let spared = service.queue.sync {
        service.mac.snapshot.panes["a-claude"] = PaneRow(pid: 300, dead: false, clients: 0, server: 500)
        service.mac.snapshot.processes = ProcessTable(nativeRows: [
          ProcessRow(pid: 300, ppid: 250, pgid: 300), ProcessRow(pid: 250, ppid: 1, pgid: 250),
          ProcessRow(pid: 500, ppid: 1, pgid: 500), ProcessRow(pid: 400, ppid: 1, pgid: 400),
        ])
        return service.paneAncestry()
      }

      #expect(spared.isSuperset(of: [300, 250, 500]))
      #expect(!spared.contains(400))
    }
  }
}
