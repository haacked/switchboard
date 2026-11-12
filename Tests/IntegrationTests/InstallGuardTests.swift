import Foundation
import SwitchboardCore
import Testing

/// A repo for one test. Its `origin/main` is a ref that the test sets, so no remote is needed.
private final class GuardRepo {
  let repos: Repos
  let dir: String

  init() throws {
    repos = try Repos()
    dir = try repos.make("o/r")
  }

  @discardableResult
  func git(_ args: String...) throws -> String {
    let r = try runCommand("/usr/bin/git", ["-C", dir] + args)
    guard r.status == 0 else { throw TestError(description: "git \(args.joined(separator: " ")): \(r.stderr)") }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func commit(_ message: String) throws -> String {
    try git(
      "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty",
      "-m", message)
    return try git("rev-parse", "HEAD")
  }

  func setOriginMain(_ sha: String) throws { try git("update-ref", "refs/remotes/origin/main", sha) }

  /// Sources bin/lib/install-guard.sh in the repo and calls require_current_main.
  /// The script first checks that sourcing defined the function, so a missing
  /// helper can't pass as a refusal.
  func requireCurrentMain() throws -> CommandResult {
    let helper = Instance.root.appendingPathComponent("bin/lib/install-guard.sh").path
    let body = """
      set -uo pipefail
      source \(shellQuote(helper))
      declare -F require_current_main >/dev/null || { echo "require_current_main is not defined" >&2; exit 3; }
      require_current_main
      """
    return try runCommand("/bin/bash", ["-c", body], timeout: 30, cwd: dir)
  }
}

@Suite(.blocking(timeLimit: .seconds(60))) struct InstallGuardTests {
  @Test func aBranchThatContainsOriginMainInstalls() throws {
    let repo = try GuardRepo()
    try repo.setOriginMain(try repo.git("rev-parse", "HEAD"))
    try repo.git("switch", "-q", "-c", "feature")
    try repo.commit("feature work")

    let r = try repo.requireCurrentMain()

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
  }

  @Test func mainAtOriginMainInstalls() throws {
    let repo = try GuardRepo()
    try repo.setOriginMain(try repo.git("rev-parse", "HEAD"))

    let r = try repo.requireCurrentMain()

    #expect(r.status == 0, "\(r.stderr)")
  }

  /// The case that replaced a newer install: the branch started from an older main.
  @Test func aBranchBehindOriginMainIsRefused() throws {
    let repo = try GuardRepo()
    try repo.git("switch", "-q", "-c", "feature")
    try repo.commit("feature work")
    try repo.git("switch", "-q", "main")
    try repo.setOriginMain(try repo.commit("newer main"))
    try repo.git("switch", "-q", "feature")

    let r = try repo.requireCurrentMain()

    #expect(r.status == 1)
    #expect(r.stderr.contains("HEAD lacks commits of origin/main"), "\(r.stderr)")
  }

  @Test func aLocalMainBehindOriginMainIsRefused() throws {
    let repo = try GuardRepo()
    let first = try repo.git("rev-parse", "HEAD")
    try repo.setOriginMain(try repo.commit("newer main"))
    try repo.git("reset", "-q", "--hard", first)

    let r = try repo.requireCurrentMain()

    #expect(r.status == 1)
    #expect(r.stderr.contains("HEAD lacks commits of origin/main"), "\(r.stderr)")
  }

  @Test func aCheckoutWithoutOriginMainIsRefused() throws {
    let repo = try GuardRepo()

    let r = try repo.requireCurrentMain()

    #expect(r.status == 1)
    #expect(r.stderr.contains("no origin/main"), "\(r.stderr)")
  }

  @Test func installRejectsAnUnknownArgumentBeforeItBuilds() throws {
    let install = Instance.root.appendingPathComponent("bin/install").path

    let r = try runCommand("/bin/bash", [install, "--bogus"], timeout: 30)

    #expect(r.status == 2)
    #expect(r.stderr.contains("Usage: bin/install [--force]"), "\(r.stderr)")
  }
}
