import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// `MacSite` holds the local code that `Service` ran itself before sessions had sites. Each test checks a member
/// against the function it replaced, or against the result that function gave, on one temporary folder.
@Suite struct MacSiteTests {
  struct Failure: Error {}

  /// A site whose home is a new folder under /tmp, which is a symlink to /private/tmp. Its tmux is a script that
  /// starts no server. For `list-panes` the script prints the home's `panes` file, or fails with the text of the
  /// home's `panes-error` file when that exists.
  private func withSite(
    _ configure: (inout Config) -> Void = { _ in }, _ body: (MacSite, Home) throws -> Void
  ) throws {
    var template = Array("/tmp/sbm.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let tmux = "\(dir)/tmux"
    let script = """
      #!/bin/sh
      case " $* " in
      *" list-panes "*)
        if [ -f '\(dir)/panes-error' ]; then cat '\(dir)/panes-error' >&2; exit 1; fi
        cat '\(dir)/panes'
        ;;
      esac
      exit 0

      """
    try script.write(toFile: tmux, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux)
    var config = Config()
    config.tmux = tmux
    configure(&config)
    let home = Home(path: dir)
    try body(try MacSite(home: home, config: config), home)
  }

  private func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  /// Starts a program that the test ends.
  private func start(_ executable: String, _ args: [String], cwd: String? = nil) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
  }

  private func end(_ p: Process) {
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
  }

  private func waitUntil(_ what: String, _ ok: () throws -> Bool) throws {
    for _ in 0..<100 {
      if try ok() { return }
      usleep(50_000)
    }
    throw APIError("timed out waiting for \(what)")
  }

  // MARK: What the site is

  @Test func theMacsSiteNamesNoHost() throws {
    try withSite { site, _ in
      #expect(site.hostName == nil)
    }
  }

  @Test func gitIsTheGitThatThisMacFinds() throws {
    try withSite { site, _ in
      let git = site.git()

      #expect(git == findExecutable("git"))
    }
  }

  @Test func terminalsIsTheTmuxServerOfTheHome() throws {
    try withSite { site, home in
      let terminals = site.terminals()

      #expect(terminals.socket == home.tmuxSocket)
      #expect(terminals.tmux == "\(home.path)/tmux")
      #expect(site.terminals() === terminals)
    }
  }

  @Test func worktreeRootResolvesTheTildeOfTheConfiguredRoot() throws {
    try withSite({ $0.worktreeRoot = "~/dev/sb-trees" }) { site, _ in
      let root = try site.worktreeRoot()

      #expect(root == "~/dev/sb-trees".expandingTilde)
      #expect(root.hasPrefix("/"))
    }
  }

  @Test func worktreeRootKeepsAnAbsoluteRoot() throws {
    try withSite({ $0.worktreeRoot = "/tmp/sb-trees" }) { site, _ in
      let root = try site.worktreeRoot()

      #expect(root == "/tmp/sb-trees")
    }
  }

  @Test func sessionFolderIsTheHomesSessionFolder() throws {
    try withSite { site, home in
      let folder = try site.sessionFolder("s9azgg")

      #expect(folder == home.sessionFolder("s9azgg"))
      #expect(folder == "\(home.path)/sessions/s9azgg")
    }
  }

  @Test func theMachineReadsThisMacsFiles() throws {
    try withSite { site, home in
      try "hello".write(toFile: "\(home.path)/file", atomically: true, encoding: .utf8)

      #expect(site.machine.text("\(home.path)/file") == "hello")
      #expect(try site.machine.run("/bin/echo", ["hi"]).stdout == "hi\n")
    }
  }

  // MARK: confirmed

  @Test func confirmedRunsItsBodyWithTheMacsMachineAndReturnsItsResult() throws {
    try withSite { site, home in
      try "hello".write(toFile: "\(home.path)/file", atomically: true, encoding: .utf8)

      let text = try site.confirmed("read a file") { machine in machine.text("\(home.path)/file") }

      #expect(text == "hello")
    }
  }

  /// On this Mac a missing file is an answer, so `confirmed` returns the nil.
  @Test func confirmedReturnsAMissingResultAsAnAnswer() throws {
    try withSite { site, home in
      let text = try site.confirmed("read a missing file") { machine in machine.text("\(home.path)/missing") }

      #expect(text == nil)
    }
  }

  @Test func confirmedThrowsWhatItsBodyThrows() throws {
    try withSite { site, _ in
      #expect(throws: Failure.self) {
        try site.confirmed("fail") { _ -> Int in throw Failure() }
      }
    }
  }

  // MARK: samePath

  @Test func samePathReadsASymlinkAndItsFolderAsOnePath() throws {
    try withSite { site, home in
      let folder = "\(home.path)/real"
      try makeFolder(folder)
      try FileManager.default.createSymbolicLink(atPath: "\(home.path)/link", withDestinationPath: folder)

      #expect(try site.samePath("\(home.path)/link", folder))
      #expect(try site.samePath(folder, "\(home.path)/link"))
      // /tmp is a symlink to /private/tmp.
      #expect(try site.samePath(folder, "/private\(folder)"))
    }
  }

  @Test func samePathReadsAPathAsItself() throws {
    try withSite { site, home in
      let folder = "\(home.path)/real"
      try makeFolder(folder)

      #expect(try site.samePath(folder, folder))
      #expect(try site.samePath(folder, "\(folder)/"))
      #expect(try site.samePath(folder, "\(home.path)/other/../real"))
    }
  }

  @Test func samePathTellsTwoFoldersApart() throws {
    try withSite { site, home in
      try makeFolder("\(home.path)/a")
      try makeFolder("\(home.path)/ab")

      #expect(try !site.samePath("\(home.path)/a", "\(home.path)/ab"))
      #expect(try !site.samePath("\(home.path)/a", home.path))
    }
  }

  /// A gone worktree may have lost its parent folders too, so the deepest folder that exists is resolved.
  @Test func samePathResolvesAGoneFolderThroughTheDeepestFolderThatExists() throws {
    try withSite { site, home in
      let folder = "\(home.path)/real"
      try makeFolder(folder)
      try FileManager.default.createSymbolicLink(atPath: "\(home.path)/link", withDestinationPath: folder)

      #expect(try site.samePath("\(home.path)/link/gone/tree", "\(folder)/gone/tree"))
      #expect(try site.samePath("\(folder)/gone", "/private\(folder)/gone"))
    }
  }

  @Test func samePathTellsTwoGoneFoldersApart() throws {
    try withSite { site, home in
      let folder = "\(home.path)/real"
      try makeFolder(folder)

      #expect(try !site.samePath("\(folder)/gone", "\(folder)/other"))
      #expect(try !site.samePath("\(folder)/gone", folder))
      #expect(try !site.samePath("\(folder)/gone/tree", "\(folder)/tree"))
    }
  }

  // MARK: realPath

  @Test func realPathResolvesAsTheLocalFunctionDoes() throws {
    try withSite { site, home in
      let folder = "\(home.path)/real"
      try makeFolder(folder)
      try FileManager.default.createSymbolicLink(atPath: "\(home.path)/link", withDestinationPath: folder)

      #expect(try site.realPath("\(home.path)/link") == "/private\(folder)")
      for path in [folder, "\(home.path)/link", "\(home.path)/missing", "\(home.path)/link/missing", ""] {
        #expect(try site.realPath(path) == realPath(path), "\(path)")
      }
    }
  }

  @Test func realPathIsNilForAPathThatDoesNotExist() throws {
    try withSite { site, home in
      let resolved = try site.realPath("\(home.path)/missing")

      #expect(resolved == nil)
    }
  }

  // MARK: folderGone

  @Test func folderGoneIsTrueForAMissingPath() throws {
    try withSite { site, home in
      let gone = try site.folderGone("\(home.path)/missing")
      let goneBelow = try site.folderGone("\(home.path)/missing/deeper")

      #expect(gone)
      #expect(goneBelow)
    }
  }

  @Test func folderGoneIsFalseForAPathThatExists() throws {
    try withSite { site, home in
      try makeFolder("\(home.path)/folder")
      try "x".write(toFile: "\(home.path)/file", atomically: true, encoding: .utf8)

      #expect(try !site.folderGone("\(home.path)/folder"))
      #expect(try !site.folderGone("\(home.path)/file"))
      #expect(try !site.folderGone(home.path))
    }
  }

  /// The poller's check follows a symlink, so a link to a missing folder is gone and a link to a folder is not.
  @Test func folderGoneFollowsASymlink() throws {
    try withSite { site, home in
      try makeFolder("\(home.path)/folder")
      try FileManager.default.createSymbolicLink(
        atPath: "\(home.path)/link", withDestinationPath: "\(home.path)/folder")
      try FileManager.default.createSymbolicLink(
        atPath: "\(home.path)/dangling", withDestinationPath: "\(home.path)/missing")

      #expect(try !site.folderGone("\(home.path)/link"))
      #expect(try site.folderGone("\(home.path)/dangling"))
    }
  }

  /// Only ENOENT counts as gone. A folder that this user can't search leaves the path unread, which is not gone.
  @Test(.enabled(if: getuid() != 0))
  func folderGoneIsFalseWhenThePathCantBeRead() throws {
    try withSite { site, home in
      let locked = "\(home.path)/locked"
      try makeFolder("\(locked)/inside")
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

      #expect(try !site.folderGone("\(locked)/inside"))
      #expect(try !site.folderGone("\(locked)/missing"))
    }
  }

  /// ENOTDIR is not ENOENT. The poller's check counted only ENOENT.
  @Test func folderGoneIsFalseForAPathBelowAFile() throws {
    try withSite { site, home in
      try "x".write(toFile: "\(home.path)/file", atomically: true, encoding: .utf8)

      #expect(try !site.folderGone("\(home.path)/file/below"))
    }
  }

  // MARK: alive

  @Test func aliveKeepsARunningChildAndDropsAnExitedOne() throws {
    try withSite { site, _ in
      let running = try start("/bin/sleep", ["60"])
      defer { end(running) }
      let exited = try start("/usr/bin/true", [])
      exited.waitUntilExit()
      let pids: Set<Int> = [Int(running.processIdentifier), Int(exited.processIdentifier)]

      let alive = try site.alive(pids)

      #expect(alive == [Int(running.processIdentifier)])
      #expect(alive == pids.filter(Processes.exists))
      #expect(alive == Processes.waitForExit(pids, seconds: 0))
    }
  }

  @Test func aliveDropsAChildOnceItExits() throws {
    try withSite { site, _ in
      let child = try start("/bin/sleep", ["60"])
      let pid = Int(child.processIdentifier)
      #expect(try site.alive([pid]) == [pid])

      end(child)

      #expect(try site.alive([pid]).isEmpty)
    }
  }

  /// `kill` reads 0 and a negative number as a process group, and no process has a pid above `Int32.max`.
  @Test func aliveDropsANumberThatNamesNoSingleProcess() throws {
    try withSite { site, _ in
      let alive = try site.alive([0, -1, -Int(getpid()), Int(Int32.max) + 1])
      let none = try site.alive([])

      #expect(alive.isEmpty)
      #expect(none.isEmpty)
    }
  }

  /// launchd belongs to root. A process that this user can't signal still runs.
  @Test func aliveKeepsAProcessOfAnotherUser() throws {
    try withSite { site, _ in
      let alive = try site.alive([1])

      #expect(alive == [1])
      #expect(Processes.exists(1))
    }
  }

  // MARK: folderUsers

  @Test func folderUsersNamesAProcessWhoseWorkingFolderIsTheFolder() throws {
    try withSite { site, home in
      let folder = "\(home.path)/work"
      try makeFolder(folder)
      let child = try start("/bin/sleep", ["60"], cwd: folder)
      defer { end(child) }
      try waitUntil("the child to use the folder") { !Processes.using(folder).isEmpty }

      let users = try site.folderUsers(folder)

      #expect(users.map(\.pid) == [Int(child.processIdentifier)])
      #expect(users.first?.use == .workingFolder)
      #expect(users.first?.path == "/private\(folder)")
      #expect(users == Processes.using(folder))
    }
  }

  @Test func folderUsersIsEmptyForAFolderThatNoProcessUses() throws {
    try withSite { site, home in
      let folder = "\(home.path)/work"
      try makeFolder(folder)
      try makeFolder("\(home.path)/workshop")
      let neighbor = try start("/bin/sleep", ["60"], cwd: "\(home.path)/workshop")
      defer { end(neighbor) }
      try waitUntil("the neighbor to use its folder") { !Processes.using("\(home.path)/workshop").isEmpty }

      #expect(try site.folderUsers(folder).isEmpty)
      #expect(try site.folderUsers("\(home.path)/missing").isEmpty)
    }
  }

  // MARK: readSnapshot

  /// A shell that stands for a pane's shell, with one `sleep` below it that stands for claude. It returns once the
  /// child runs sleep, because a forked shell names the shell's own command until it execs.
  private func paneWithChild() throws -> (pane: Process, child: Int) {
    let pane = try start("/bin/sh", ["-c", "/bin/sleep 61 & wait"])
    var child: Int?
    do {
      try waitUntil("the pane's child to run sleep") {
        let processes = ProcessTable.readLocal()
        let below = processes.children(of: Int(pane.processIdentifier))
        child = below.first { processes.command(of: $0.pid)?.hasPrefix("/bin/sleep") == true }?.pid
        return child != nil
      }
    } catch {
      end(pane)
      throw error
    }
    return (pane, try #require(child))
  }

  private func endPane(_ pane: Process, child: Int) {
    kill(pid_t(child), SIGTERM)
    end(pane)
  }

  private func write(panes: String, in home: Home) throws {
    try panes.write(toFile: "\(home.path)/panes", atomically: true, encoding: .utf8)
  }

  @Test func readSnapshotFindsTheClaudeBelowASessionsLivePane() throws {
    try withSite { site, home in
      let (pane, child) = try paneWithChild()
      defer { endPane(pane, child: child) }
      let panePid = Int(pane.processIdentifier)
      try write(panes: "s9azgg-claude\t\(panePid)\t0\t1\ns9azgg-shell\t\(panePid)\t0\t0\n", in: home)

      let snapshot = try site.readSnapshot(claudeProgram: "sleep")

      #expect(snapshot.claudePids == ["s9azgg": child])
      let processes = ProcessTable.readLocal()
      #expect(snapshot.claudePids["s9azgg"] == Service.findClaude(below: panePid, program: "sleep", in: processes))
    }
  }

  @Test func readSnapshotHoldsThePanesThatTmuxLists() throws {
    try withSite { site, home in
      let text = "s9azgg-claude\t5601\t0\t2\ns9azgg-shell\t5574\t0\t0\nold-claude\t\t1\t0\n"
      try write(panes: text, in: home)

      let snapshot = try site.readSnapshot(claudeProgram: "claude")

      let expected = PaneRow.parse(text)
      #expect(Set(snapshot.panes.keys) == Set(expected.keys))
      for (name, row) in expected {
        #expect(snapshot.panes[name]?.pid == row.pid, "\(name)")
        #expect(snapshot.panes[name]?.dead == row.dead, "\(name)")
        #expect(snapshot.panes[name]?.clients == row.clients, "\(name)")
      }
    }
  }

  @Test func readSnapshotHoldsTheProcessesOfTheSameRead() throws {
    try withSite { site, home in
      let (pane, child) = try paneWithChild()
      defer { endPane(pane, child: child) }
      try write(panes: "", in: home)

      let snapshot = try site.readSnapshot(claudeProgram: "sleep")

      #expect(snapshot.processes.children(of: Int(pane.processIdentifier)).map(\.pid) == [child])
    }
  }

  /// A dead pane, a shell pane, and a pane of no session name no claude, whatever runs below their pid.
  @Test func readSnapshotGivesNoClaudeToADeadPaneOrAPaneThatIsNotAClaudePane() throws {
    try withSite { site, home in
      let (pane, child) = try paneWithChild()
      defer { endPane(pane, child: child) }
      let panePid = Int(pane.processIdentifier)
      try write(
        panes: "dead-claude\t\(panePid)\t1\t0\ns9azgg-shell\t\(panePid)\t0\t0\nmcp-github\t\(panePid)\t0\t0\n",
        in: home)

      let snapshot = try site.readSnapshot(claudeProgram: "sleep")

      #expect(snapshot.claudePids.isEmpty)
      #expect(snapshot.panes.count == 3)
    }
  }

  @Test func readSnapshotGivesNoClaudeWhenThePanesChildRunsAnotherProgram() throws {
    try withSite { site, home in
      let (pane, child) = try paneWithChild()
      defer { endPane(pane, child: child) }
      try write(panes: "s9azgg-claude\t\(pane.processIdentifier)\t0\t1\n", in: home)

      let snapshot = try site.readSnapshot(claudeProgram: "claude")

      #expect(snapshot.claudePids.isEmpty)
      #expect(snapshot.panes["s9azgg-claude"]?.dead == false)
    }
  }

  /// tmux's own report that no server runs means no panes.
  @Test func readSnapshotHasNoPanesWhenNoTmuxServerRuns() throws {
    try withSite { site, home in
      try "no server running on \(home.tmuxSocket)\n".write(
        toFile: "\(home.path)/panes-error", atomically: true, encoding: .utf8)

      let snapshot = try site.readSnapshot(claudeProgram: "claude")

      #expect(snapshot.panes.isEmpty)
      #expect(snapshot.claudePids.isEmpty)
    }
  }

  /// Any other tmux failure leaves the panes unknown. An empty list would make sbd start the panes that it has.
  @Test func readSnapshotThrowsWhenTmuxCantListThePanes() throws {
    try withSite { site, home in
      try "error connecting to \(home.tmuxSocket) (Permission denied)\n".write(
        toFile: "\(home.path)/panes-error", atomically: true, encoding: .utf8)

      #expect(throws: (any Error).self) { try site.readSnapshot(claudeProgram: "claude") }
    }
  }

  // MARK: stopClaude

  @Test func stopClaudeSendsSIGTERMToThePid() throws {
    try withSite { site, _ in
      let child = try start("/bin/sleep", ["20"])
      defer { end(child) }

      try site.stopClaude(Int(child.processIdentifier), below: Int(getpid()), program: "sleep")

      child.waitUntilExit()
      #expect(child.terminationReason == .uncaughtSignal)
      #expect(child.terminationStatus == SIGTERM)
    }
  }

  // MARK: The machine log

  private func logging(_ config: inout Config) { config.machineLog = true }

  @Test func withTheMachineLogOnEachPathAndProcessMemberWritesOneLineWithItsArguments() throws {
    try withSite(logging) { site, home in
      let folder = "\(home.path)/work"
      try makeFolder(folder)
      let child = try start("/bin/sleep", ["60"])
      defer { end(child) }
      let pid = Int(child.processIdentifier)
      let log = "\(home.path)/mac-machine.log"

      _ = try site.samePath(folder, "\(home.path)/other")
      _ = try site.realPath(folder)
      _ = try site.folderGone(folder)
      _ = try site.alive([pid])
      _ = try site.folderUsers(folder)
      try site.stopClaude(pid, below: Int(getpid()), program: "sleep")

      let expected: [(member: String, arguments: [String])] = [
        ("samePath", [folder, "\(home.path)/other"]), ("realPath", [folder]), ("folderGone", [folder]),
        ("alive", [String(pid)]), ("folderUsers", [folder]), ("stopClaude", [String(pid)]),
      ]
      for (member, arguments) in expected {
        let lines = try MachineLogFile.lines(log, of: member)
        #expect(lines.count == 1, "\(member): \(lines)")
        for argument in arguments {
          #expect(lines.first?.contains(argument) == true, "\(member) lacks \(argument) in \(lines)")
        }
      }
    }
  }

  @Test func withTheMachineLogOnACommandOnTheSitesMachineWritesALine() throws {
    try withSite(logging) { site, home in
      let result = try site.machine.run("/bin/echo", ["a logged word"])

      #expect(result.stdout == "a logged word\n")
      let lines = try MachineLogFile.lines("\(home.path)/mac-machine.log", of: "run")
      #expect(lines.filter { $0.contains("/bin/echo") && $0.contains("a logged word") }.count == 1)
    }
  }

  @Test func withTheMachineLogOnATmuxCommandOfTheSitesTerminalsWritesALine() throws {
    try withSite(logging) { site, home in
      try site.terminals().run(["display-message", "a logged tmux word"])

      let lines = try MachineLogFile.lines("\(home.path)/mac-machine.log", of: "run")
      #expect(lines.contains { $0.contains("\(home.path)/tmux") && $0.contains("a logged tmux word") })
    }
  }

  @Test func withTheMachineLogOnTheMembersGiveTheSameResults() throws {
    try withSite(logging) { site, home in
      let folder = "\(home.path)/real"
      try makeFolder(folder)
      try FileManager.default.createSymbolicLink(atPath: "\(home.path)/link", withDestinationPath: folder)

      #expect(try site.samePath("\(home.path)/link", folder))
      #expect(try site.realPath("\(home.path)/link") == realPath(folder))
      #expect(try site.folderGone("\(home.path)/missing"))
      #expect(try !site.folderGone(folder))
      #expect(try site.alive([Int(getpid()), 0]) == [Int(getpid())])
      #expect(try site.folderUsers("\(home.path)/missing").isEmpty)
    }
  }

  @Test func withTheMachineLogOffTheSiteWritesNoLog() throws {
    try withSite { site, home in
      _ = try site.samePath(home.path, home.path)
      _ = try site.alive([Int(getpid())])
      _ = try site.machine.run("/bin/echo", ["unlogged"])
      try site.terminals().run(["display-message", "unlogged"])

      #expect(!FileManager.default.fileExists(atPath: "\(home.path)/mac-machine.log"))
    }
  }
}
