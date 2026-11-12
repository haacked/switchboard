import Foundation
import SwitchboardCore
import Testing

/// A repo and an installed app for one test. The app holds only the Info.plist that bin/bundle writes.
private final class GuardRepo {
  let repos: Repos
  let dir: String
  let app: String

  init() throws {
    repos = try Repos()
    dir = try repos.make("o/r")
    app = "\(repos.root)/Applications/Switchboard.app"
  }

  @discardableResult
  func git(_ args: String...) throws -> String { try Repos.git(dir, args) }

  @discardableResult
  func commit(_ message: String) throws -> String { try Repos.commit(dir, message) }

  func head() throws -> String { try git("rev-parse", "HEAD") }

  /// Writes the installed app's Info.plist with the two keys that bin/bundle records. It leaves out each nil key.
  func install(commit: String?, dirty: Bool? = false) throws {
    var keys = ""
    if let commit { keys += "<key>SBBuildCommit</key><string>\(commit)</string>\n" }
    if let dirty { keys += "<key>SBBuildDirty</key><\(dirty)/>\n" }
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0">
      <dict>
      <key>CFBundleIdentifier</key><string>com.haacked.switchboard</string>
      \(keys)</dict>
      </plist>
      """
    try FileManager.default.createDirectory(atPath: "\(app)/Contents", withIntermediateDirectories: true)
    try plist.write(toFile: "\(app)/Contents/Info.plist", atomically: true, encoding: .utf8)
  }

  func requireNewerThanInstalled(_ rev: String = "HEAD") throws -> CommandResult {
    let helper = Instance.root.appendingPathComponent("bin/lib/install-guard.sh").path
    let body = """
      set -euo pipefail
      source \(shellQuote(helper))
      require_newer_than_installed \(shellQuote(app)) \(shellQuote(rev))
      """
    return try runCommand("/bin/bash", ["-c", body], timeout: 30, cwd: dir)
  }
}

@Suite(.blocking(timeLimit: .seconds(60))) struct InstallGuardTests {
  @Test func noInstalledAppInstalls() throws {
    let repo = try GuardRepo()

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
  }

  @Test func aBuildThatContainsTheInstalledCommitInstalls() throws {
    let repo = try GuardRepo()
    try repo.install(commit: try repo.head())
    try repo.commit("newer")

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
  }

  @Test func theInstalledCommitItselfInstalls() throws {
    let repo = try GuardRepo()
    try repo.install(commit: try repo.head())

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 0, "\(r.stderr)")
  }

  /// The incident: a branch that started from an older main installs over a build of the newer main.
  @Test func aBranchBehindTheInstalledMainIsRefused() throws {
    let repo = try GuardRepo()
    try repo.git("switch", "-q", "-c", "feature")
    try repo.commit("feature work")
    try repo.git("switch", "-q", "main")
    try repo.install(commit: try repo.commit("newer main"))
    try repo.git("switch", "-q", "feature")

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 1)
    #expect(r.stderr.contains("HEAD lacks"), "\(r.stderr)")
    #expect(r.stderr.contains("newer main"), "\(r.stderr)")
  }

  /// Two branches from the same main: neither contains the other's commit.
  @Test func aSiblingBranchIsRefused() throws {
    let repo = try GuardRepo()
    try repo.git("switch", "-q", "-c", "a")
    try repo.install(commit: try repo.commit("branch a"))
    try repo.git("switch", "-q", "-c", "b", "main")
    try repo.commit("branch b")

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 1)
    #expect(r.stderr.contains("HEAD lacks"), "\(r.stderr)")
  }

  @Test func theRevisionArgumentIsWhatIsCompared() throws {
    let repo = try GuardRepo()
    let first = try repo.head()
    try repo.install(commit: try repo.commit("newer"))

    #expect(try repo.requireNewerThanInstalled(first).status == 1)
    #expect(try repo.requireNewerThanInstalled("main").status == 0)
  }

  @Test func anInstallWithoutABuildCommitIsRefused() throws {
    let repo = try GuardRepo()
    try repo.install(commit: nil, dirty: nil)

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 1)
    #expect(r.stderr.contains("records no build commit"), "\(r.stderr)")
  }

  @Test func anInstallFromUncommittedChangesIsRefused() throws {
    let repo = try GuardRepo()
    let first = try repo.head()
    try repo.commit("newer")
    try repo.install(commit: first, dirty: true)

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 1)
    #expect(r.stderr.contains("uncommitted changes"), "\(r.stderr)")
  }

  @Test func anInstalledCommitThisCheckoutLacksIsRefused() throws {
    let repo = try GuardRepo()
    try repo.install(commit: String(repeating: "ab", count: 20))

    let r = try repo.requireNewerThanInstalled()

    #expect(r.status == 1)
    #expect(r.stderr.contains("does not have commit"), "\(r.stderr)")
  }

  @Test(arguments: ["bin/install", "bin/update"])
  func anUnknownArgumentIsRejectedBeforeAnythingRuns(_ script: String) throws {
    let path = Instance.root.appendingPathComponent(script).path

    let r = try runCommand("/bin/bash", [path, "--bogus"], timeout: 30)

    #expect(r.status == 2)
    #expect(r.stderr.contains("Usage: \(script) [--force]"), "\(r.stderr)")
  }

  @Test func installRefusesBeforeItBuilds() throws {
    let repo = try GuardRepo()
    try repo.install(commit: nil, dirty: nil)
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = repo.repos.root
    let path = Instance.root.appendingPathComponent("bin/install").path

    let r = try runCommand("/bin/bash", [path], env: env, timeout: 30)

    #expect(r.status == 1)
    #expect(r.stderr.contains("records no build commit"), "\(r.stderr)")
  }
}
