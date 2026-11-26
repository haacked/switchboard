import Foundation
import SwitchboardCore
import Testing

/// A work session that never had a PR reaches Done once the user acknowledges its last reply and the poller finds
/// the folder clean with HEAD on the remote's default branch.
@Suite(.blocking(timeLimit: .seconds(120))) struct FinishedWithoutPRTests {
  static let reason = "finished without a PR; nothing to commit or push"

  /// A session on a branch without a PR, cut from `main`, whose clone knows `origin/main` as the default branch.
  func finishedSession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/nothing-to-change")
    _ = try sbd.git(s.cwd, "update-ref", "refs/remotes/origin/main", "main")
    _ = try sbd.git(s.cwd, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    return s
  }

  @Test func anAcknowledgedSessionWithACleanFolderIsDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try finishedSession(sbd)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state == .needsYou)
    // Before the acknowledgment, the poller does not read the folder.
    #expect(try sbd.events(s.id).filter { $0.kind == "worktree" }.isEmpty)

    try sbd.sb("ack", s.id)
    try sbd.poll()

    let done = try sbd.get(s.id)
    #expect(done.state == .done)
    #expect(done.reason == Self.reason)
    #expect(done.markedDone == false)
  }

  @Test func anUntrackedFileOrACommitOfItsOwnKeepsTheSessionOutOfDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try finishedSession(sbd)
    try sbd.sb("ack", s.id)
    let file = "\(s.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state != .done)

    try FileManager.default.removeItem(atPath: file)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state == .done)

    _ = try sbd.git(
      s.cwd, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q",
      "--allow-empty", "-m", "mine")
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state != .done)
  }

  @Test func aFolderWithoutARemoteDefaultBranchIsNotDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: "PostHog/charts", branch: "haacked/nothing-to-change")
    try sbd.sb("ack", s.id)
    try sbd.poll(all: true)
    #expect(try sbd.get(s.id).state == .waiting)

    // A fetch moves no activity, so the poller sees the new default branch at its next idle-interval count.
    _ = try sbd.git(s.cwd, "update-ref", "refs/remotes/origin/main", "main")
    _ = try sbd.git(s.cwd, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    try sbd.poll()
    #expect(try sbd.get(s.id).state == .waiting)
    try sbd.advanceClock(300_000)
    try sbd.poll()
    #expect(try sbd.get(s.id).state == .done)
  }

  @Test func undoingTheAcknowledgmentTakesTheSessionOutOfDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try finishedSession(sbd)
    try sbd.sb("ack", s.id)
    try sbd.poll()
    #expect(try sbd.get(s.id).state == .done)

    try sbd.sb("ack", "--undo", s.id)

    #expect(try sbd.get(s.id).state == .needsYou)
  }

  @Test func aNewPromptTakesTheSessionOutOfDone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try finishedSession(sbd)
    try sbd.sb("ack", s.id)
    try sbd.poll()
    #expect(try sbd.get(s.id).state == .done)

    try sbd.sb("send", s.id, "one more thing")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: one more thing" }

    #expect(try sbd.get(s.id).state == .needsYou)
  }
}
