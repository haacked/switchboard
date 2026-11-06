import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct FolderUsersTests {
  /// A folder in the temporary folder, whose path goes through the /var symlink, and a sibling whose
  /// name starts with the folder's name.
  private func folders() throws -> (folder: String, sibling: String) {
    let base = "\(NSTemporaryDirectory())sb-folder-users-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: "\(base)/w", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(base)/wx", withIntermediateDirectories: true)
    try "x".write(toFile: "\(base)/w/file", atomically: true, encoding: .utf8)
    try "x".write(toFile: "\(base)/wx/file", atomically: true, encoding: .utf8)
    return ("\(base)/w", "\(base)/wx")
  }

  private func start(_ args: [String], cwd: String) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    try p.run()
    return p
  }

  /// Waits for the process to reach the `sleep` that `exec` starts, which keeps the shell's fds.
  private func waitForSleep(_ p: Process) throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if Processes.byParent().values.joined().contains(where: {
        $0.pid == Int(p.processIdentifier) && $0.command.contains("sleep")
      }) {
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  @Test func findsAProcessWhoseWorkingFolderIsInside() throws {
    let (folder, sibling) = try folders()
    let inside = try start(["exec /bin/sleep 30"], cwd: folder)
    defer { inside.terminate() }
    let beside = try start(["exec /bin/sleep 30"], cwd: sibling)
    defer { beside.terminate() }
    try waitForSleep(inside)
    try waitForSleep(beside)

    let pids = Processes.using(folder).map(\.pid)

    #expect(pids.contains(Int(inside.processIdentifier)))
    #expect(!pids.contains(Int(beside.processIdentifier)))
  }

  @Test func findsAProcessWithAnOpenFileInside() throws {
    let (folder, sibling) = try folders()
    let open = try start(["exec 3<\"$0\"; exec /bin/sleep 30", "\(folder)/file"], cwd: "/")
    defer { open.terminate() }
    let beside = try start(["exec 3<\"$0\"; exec /bin/sleep 30", "\(sibling)/file"], cwd: "/")
    defer { beside.terminate() }
    try waitForSleep(open)
    try waitForSleep(beside)

    let users = Processes.using(folder)

    let found = try #require(users.first { $0.pid == Int(open.processIdentifier) })
    #expect(found.path.hasSuffix("/w/file"))
    #expect(!users.map(\.pid).contains(Int(beside.processIdentifier)))
  }

  @Test func aFolderThatIsGoneHasNoUsers() {
    #expect(Processes.using("\(NSTemporaryDirectory())sb-folder-users-gone-\(UUID().uuidString)").isEmpty)
  }

  @Test func descendantsIncludeTheRootsAndEveryLevelBelow() {
    let rows = [
      ProcessRow(pid: 2, ppid: 1, pgid: 2, command: ""), ProcessRow(pid: 3, ppid: 2, pgid: 3, command: ""),
      ProcessRow(pid: 4, ppid: 9, pgid: 4, command: ""),
    ]
    #expect(Processes.descendants(of: [1], in: Dictionary(grouping: rows, by: \.ppid)) == [1, 2, 3])
  }
}
