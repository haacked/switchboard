import Foundation
import SwitchboardCore
import Testing

/// A repo for one bin/changelog test. Its main branch starts with the commit `first`.
private final class ChangelogRepo {
  let repos: Repos
  let dir: String
  let first: String

  init() throws {
    repos = try Repos()
    dir = try Repos.create("\(repos.root)/r")
    first = try Repos.git(dir, "rev-parse", "HEAD")
  }

  @discardableResult
  func git(_ args: String...) throws -> String { try Repos.git(dir, args) }

  @discardableResult
  func commit(_ message: String) throws -> String { try Repos.commit(dir, message) }

  /// Commits `commits` on a new branch from main.
  func branch(_ name: String, commits: [String] = ["work"]) throws {
    try git("switch", "-q", "-c", name, "main")
    for c in commits { try commit(c) }
    try git("switch", "-q", "main")
  }

  /// Merges `branch` into main with a merge commit whose message is `message`, kept verbatim.
  func merge(_ branch: String, message: String) throws {
    let file = "\(repos.root)/merge-message"
    try message.write(toFile: file, atomically: true, encoding: .utf8)
    try Repos.git(dir, Repos.identity + ["merge", "-q", "--no-ff", "--cleanup=verbatim", "-F", file, branch])
  }

  /// Makes a branch and merges it with a GitHub merge commit message: the subject, a blank line, then the PR title.
  func mergePullRequest(_ number: Int, title: String, branch name: String, commits: [String] = ["work"]) throws {
    try branch(name, commits: commits)
    try merge(name, message: "Merge pull request #\(number) from o/\(name)\n\n\(title)\n")
  }

  func changelog(_ args: String...) throws -> CommandResult {
    let script = Instance.root.appendingPathComponent("bin/changelog").path
    return try runCommand("/bin/bash", [script] + args, timeout: 30, cwd: dir)
  }
}

/// The lines of stdout. A missing final newline or a blank line shows up as a mismatch.
private func lines(_ r: CommandResult) -> [String] {
  r.stdout.hasSuffix("\n") ? r.stdout.dropLast().components(separatedBy: "\n") : [r.stdout, "<no final newline>"]
}

/// Text that a shell, echo, or printf could reinterpret.
private let trickyText = ["-n", "-e", "50% done", #"back\nslash"#, "$HOME and `date`", "*", "\"quoted\" 'single'"]

@Suite(.blocking(timeLimit: .seconds(60))) struct ChangelogTests {
  @Test func aMergeCommitPrintsItsPullRequestTitleAndNumber() throws {
    let repo = try ChangelogRepo()
    try repo.mergePullRequest(42, title: "Add the kanban board", branch: "board")

    let r = try repo.changelog(repo.first, "HEAD")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["Add the kanban board (#42)"])
  }

  @Test func aDirectCommitPrintsOnlyItsSubjectLine() throws {
    let repo = try ChangelogRepo()
    try repo.commit("Fix the build script\n\nThe body explains why.")

    let r = try repo.changelog(repo.first)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["Fix the build script"])
  }

  @Test func mixedHistoryIsOldestFirstAndOmitsTheMergedBranchCommits() throws {
    let repo = try ChangelogRepo()
    try repo.commit("Direct one")
    try repo.mergePullRequest(7, title: "First PR", branch: "a", commits: ["a inside one", "a inside two"])
    try repo.commit("Direct two")
    try repo.mergePullRequest(8, title: "Second PR", branch: "b", commits: ["b inside"])

    let r = try repo.changelog(repo.first)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["Direct one", "First PR (#7)", "Direct two", "Second PR (#8)"])
  }

  /// The merged branch starts before FROM, so its own commits are new to FROM..TO but sit on a second parent.
  @Test func aBranchStartedBeforeFromStillOmitsItsCommits() throws {
    let repo = try ChangelogRepo()
    try repo.branch("old", commits: ["old inside"])
    let from = try repo.commit("Direct before")
    try repo.merge("old", message: "Merge pull request #9 from o/old\n\nOld PR\n")

    let r = try repo.changelog(from, "HEAD")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["Old PR (#9)"])
  }

  @Test func anEmptyRangePrintsNothing() throws {
    let repo = try ChangelogRepo()

    let r = try repo.changelog(repo.first)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout == "")
  }

  @Test func toLimitsTheRange() throws {
    let repo = try ChangelogRepo()
    let to = try repo.commit("Included")
    try repo.commit("After TO")

    let r = try repo.changelog(repo.first, to)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["Included"])
  }

  @Test func fromAndToAcceptRefNames() throws {
    let repo = try ChangelogRepo()
    try repo.git("tag", "v1")
    try repo.commit("Tagged range")

    let r = try repo.changelog("v1", "main")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["Tagged range"])
  }

  @Test func aPullRequestMergeWithNoBodyPrintsItsSubject() throws {
    let repo = try ChangelogRepo()
    try repo.branch("nobody")
    try repo.merge("nobody", message: "Merge pull request #5 from o/nobody\n")

    let r = try repo.changelog(repo.first)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["Merge pull request #5 from o/nobody"])
  }

  @Test func theTitleIsTheBodysFirstNonEmptyLine() throws {
    let repo = try ChangelogRepo()
    try repo.branch("multi")
    try repo.merge(
      "multi", message: "Merge pull request #11 from o/multi\n\n\n\nThe real title\nSecond line\n\nMore detail\n")

    let r = try repo.changelog(repo.first)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == ["The real title (#11)"])
  }

  /// Only the GitHub subject form takes the title from the body. Other merges print their subject.
  @Test func aMergeThatIsNotAPullRequestPrintsItsSubject() throws {
    let repo = try ChangelogRepo()
    let subjects = [
      "Merge branch 'main' into feature",
      "Merge remote-tracking branch 'origin/main'",
      "Merge pull request from o/branch",
      "Merge pull request #abc from o/branch",
    ]
    for (i, subject) in subjects.enumerated() {
      try repo.branch("other\(i)")
      try repo.merge("other\(i)", message: "\(subject)\n\nA body line\n")
    }

    let r = try repo.changelog(repo.first)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == subjects)
  }

  @Test func subjectsAndTitlesPrintVerbatim() throws {
    let repo = try ChangelogRepo()
    for text in trickyText { try repo.commit(text) }
    for (i, text) in trickyText.enumerated() { try repo.mergePullRequest(i + 1, title: text, branch: "odd\(i)") }

    let r = try repo.changelog(repo.first)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r) == trickyText + trickyText.enumerated().map { "\($1) (#\($0 + 1))" })
  }
}
