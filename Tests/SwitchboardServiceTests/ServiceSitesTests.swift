import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// The site lookups and site writes of `Service+Sites.swift`.
@Suite struct ServiceSitesTests {
  struct Unused: Error {}

  /// A site that names a host and whose machine is this Mac, so a write that ignores the host name lands in `folder`.
  final class HostSite: SessionSite {
    let hostName: String? = "mini"
    let machine: any Machine = LocalMachine()
    let folder: String
    init(folder: String) { self.folder = folder }
    func terminals() throws -> TerminalHost { throw Unused() }
    func requireReady() throws { throw Unused() }
    func sbFolder() throws -> String { folder }
    func userHome() throws -> String { throw Unused() }
    func git() throws -> String { throw Unused() }
    func worktreeRoot() throws -> String { throw Unused() }
    func sessionFolder(_ id: String) throws -> String { "\(folder)/sessions/\(id)" }
    func confirmed<T>(_ what: String, _ body: (any Machine) throws -> T) throws -> T { throw Unused() }
    func readSnapshot(claudeProgram: String) throws -> Service.Snapshot { throw Unused() }
    func processes(claudeProgram: String) throws -> ProcessTable { throw Unused() }
    func alive(_ pids: Set<Int>) throws -> Set<Int> { throw Unused() }
    func folderUsers(_ folder: String) throws -> [FolderUser] { throw Unused() }
    func samePath(_ a: String, _ b: String) throws -> Bool { throw Unused() }
    func realPath(_ path: String) throws -> String? { throw Unused() }
    func folderGone(_ path: String) throws -> Bool { throw Unused() }
    func stopClaude(_ pid: Int, below pane: Int, program: String) throws { throw Unused() }
  }

  @Test(.timeLimit(.minutes(1)))
  func theSiteOfAnIdThatSbdDoesNotHoldThrows() throws {
    try withService { service, _ in
      do {
        _ = try service.queue.sync { try service.site(of: "nope") }
        Issue.record("nope has a site")
      } catch {
        #expect("\(error)" == "no session nope", "\(error)")
      }
    }
  }

  /// The write for a site that names a host runs through the site's `confirmed`, which this site refuses.
  @Test(.timeLimit(.minutes(1)))
  func theLauncherWriteForASiteThatNamesAHostWritesNothingOnThisMac() throws {
    try withService { service, home in
      let site = HostSite(folder: "\(home.path)/host")
      #expect(throws: Unused.self) {
        try service.queue.sync { try service.writeLauncher("claude\n", for: "s1", at: site) }
      }
      #expect(!FileManager.default.fileExists(atPath: site.folder))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theLauncherWriteLandsInTheSessionFolderOfThisMac() throws {
    try withService { service, home in
      try service.queue.sync { try service.writeLauncher("claude\n", for: "s1", at: service.mac) }
      #expect(try String(contentsOfFile: "\(home.sessionFolder("s1"))/claude.sh", encoding: .utf8) == "claude\n")
    }
  }
}
