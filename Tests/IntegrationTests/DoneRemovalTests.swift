import Foundation
import SwitchboardCore
import Testing

/// The GitHub URL of the repo that the recorded PRs belong to.
private let posthog = "https://github.com/PostHog/posthog.git"

/// A recorded PR in PostHog/posthog and its head branch.
private struct RecordedPR {
  let number: Int
  let branch: String

  static let breaker = RecordedPR(number: 122953, branch: "haacked/cdp-dlq-breaker-counts-lookups")
  static let groups = RecordedPR(number: 122179, branch: "posthog/groups-list-two-phase-dedup")
  static let cohort = RecordedPR(number: 121847, branch: "haacked/cohort-store-stamp-other-topic-marks")
}

/// An sbd whose poller asks a FakeGitHub, and a PostHog/posthog checkout whose origin is a bare repo in
/// the home that holds main.
private struct Setup {
  let github: FakeGitHub
  let sbd: Instance
  let repo: String
  let origin: String

  init() throws {
    github = try FakeGitHub()
    sbd = try Instance.withGitHub(github)
    repo = try Repos.create("\(sbd.home.path)/posthog", origin: posthog)
    origin = "\(sbd.home.path)/origin.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", origin)
    try sbd.git(repo, "config", "url.\(origin).insteadOf", posthog)
    try sbd.git(repo, "push", "-q", "origin", "main")
  }

  /// A session in a worktree that sbd made on the PR's branch, after a commit. GitHub reports the PR in
  /// `state` with that commit as its head. The commit is on no remote unless `push` is true.
  func finished(_ pr: RecordedPR, state: String, push: Bool = false) throws -> SessionSummary {
    let s = try sbd.worktreeSession(repo, branch: pr.branch)
    try sbd.commit(s.cwd, "\(pr.number).txt")
    if push { try sbd.git(s.cwd, "push", "-q", "origin", pr.branch) }
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(pr.number) {
      $0["state"] = .string(state)
      $0["headRefOid"] = .string(tip)
    }
    return s
  }

  /// Polls GitHub and waits until each session is Done.
  func pollUntilDone(_ sessions: SessionSummary...) throws {
    try sbd.poll(all: true)
    for s in sessions { try sbd.waitFor(s.id, "Done") { $0.state == .done } }
  }
}

extension Instance {
  fileprivate func rmDone(_ flags: String..., env: [String: String] = [:]) throws -> CommandResult {
    try run(["rm", "--done"] + flags, env: env)
  }

  /// Marks the session Done and waits until its state is Done.
  @discardableResult
  fileprivate func markDone(_ id: String) throws -> SessionSummary {
    try sb("done", id)
    return try waitFor(id, "Done") { $0.state == .done }
  }

  fileprivate func branchExists(_ repo: String, _ name: String) throws -> Bool {
    try runCommand("/usr/bin/git", ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0
  }

  fileprivate func sessionIds() throws -> Set<String> { Set(try client.sessions().map(\.id)) }

  /// The `rm-done` preview.
  fileprivate func planDoneRemoval(worktree: Bool = true, remoteBranch: Bool = false) throws -> JSON {
    try client.call("rm-done", ["worktree": .bool(worktree), "remote_branch": .bool(remoteBranch)])
  }

  /// The confirmed `rm-done` on `targets`.
  fileprivate func removeDone(_ targets: [String], worktree: Bool = true) throws -> JSON {
    try client.call(
      "rm-done",
      ["worktree": .bool(worktree), "confirmed": true, "targets": .array(targets.map(JSON.string))],
      timeout: 300)
  }
}

/// The ids in the result's `removed`.
private func removed(_ result: JSON) -> Set<String> { Set(result["removed"]?.array?.compactMap(\.string) ?? []) }

/// The `skipped` or `skip` entry for the session, or nil when the list doesn't name it.
private func skip(_ list: JSON?, _ id: String) -> JSON? { list?.array?.first { $0["id"]?.string == id } }

/// The ids in a preview's `remove`.
private func planned(_ plan: JSON) -> Set<String> {
  Set(plan["remove"]?.array?.compactMap { $0["id"]?.string } ?? [])
}

private func item(_ plan: JSON, _ id: String) -> JSON? { plan["remove"]?.array?.first { $0["id"]?.string == id } }

/// A field that the preview sends as null, or leaves out as Swift's encoder does for nil.
private func isNull(_ value: JSON?) -> Bool { value == nil || value == .null }

private func parse(_ r: CommandResult) throws -> JSON {
  try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
}

@Suite(.blocking(timeLimit: .seconds(120))) struct DoneRemovalTests {
  // MARK: Removal

  @Test func removesMergedDoneSessionsWithTheirWorktreesAndBranches() throws {
    let s = try Setup()
    let a = try s.finished(.breaker, state: "MERGED")
    let b = try s.finished(.groups, state: "MERGED")
    try s.pollUntilDone(a, b)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try parse(r)
    #expect(removed(result) == [a.id, b.id])
    #expect(result["skipped"]?.array?.isEmpty == true)
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
    #expect(try !s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
    #expect(try !s.sbd.branchExists(s.repo, RecordedPR.groups.branch))
  }

  @Test func resultDecodesAsADoneRemovalResult() throws {
    let s = try Setup()
    let a = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(a)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    let result = try JSONCoding.decode(DoneRemovalResult.self, from: r.stdout)
    #expect(result.removed == [a.id])
    #expect(result.skipped.isEmpty)
  }

  @Test func skipsUnpushedCommitsOfAClosedPRAndUncommittedFiles() throws {
    let s = try Setup()
    let unpushed = try s.finished(.cohort, state: "CLOSED")
    let dirty = try s.sbd.worktreeSession(s.repo, branch: "haacked/dirty")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try s.pollUntilDone(unpushed)
    try s.sbd.markDone(dirty.id)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result).isEmpty)
    let unpushedReason = try #require(skip(result["skipped"], unpushed.id)?["reason"]?.string)
    #expect(unpushedReason.contains("not on a pushed branch"), Comment(rawValue: unpushedReason))
    let dirtyReason = try #require(skip(result["skipped"], dirty.id)?["reason"]?.string)
    #expect(dirtyReason.contains("uncommitted"), Comment(rawValue: dirtyReason))
    #expect(try s.sbd.sessionIds() == [unpushed.id, dirty.id])
    #expect(FileManager.default.fileExists(atPath: unpushed.cwd))
    #expect(FileManager.default.fileExists(atPath: "\(dirty.cwd)/notes.txt"))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.cohort.branch))
  }

  /// A merged PR that the transcript linked from another repo makes the
  /// session Done, but only a merged PR of the session's own branch lets
  /// removal delete the branch. A PR whose head has the branch's name in
  /// another repo fails on its head commit.
  @Test(arguments: [
    (nil as String?, "has no merged PR"), ("haacked/no-pr-yet", "has commits that are not in its merged PR"),
  ])
  func skipsADoneSessionWhoseMergedPRIsFromAnotherRepo(_ head: String?, _ refusal: String) throws {
    let s = try Setup()
    let foreign = try s.sbd.worktreeSession(s.repo, branch: "haacked/no-pr-yet")
    try s.sbd.commit(foreign.cwd, "unpushed.txt")
    let tip = try s.sbd.git(foreign.cwd, "rev-parse", "HEAD")
    try s.sbd.link(foreign, "haacked/review-code", 189)
    s.github.change(189) {
      $0["state"] = "MERGED"
      if let head { $0["headRefName"] = .string(head) }
    }
    try s.pollUntilDone(foreign)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result).isEmpty)
    let reason = try #require(skip(result["skipped"], foreign.id)?["reason"]?.string)
    #expect(reason.contains(refusal), Comment(rawValue: reason))
    #expect(FileManager.default.fileExists(atPath: foreign.cwd))
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/haacked/no-pr-yet") == tip)
  }

  @Test func skipsALockedWorktreeAndRemovesTheRest() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let locked = try sbd.worktreeSession(repo, branch: "haacked/locked")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markDone(locked.id)
    try sbd.markDone(clean.id)
    try sbd.git(repo, "worktree", "lock", "--reason", "Supacode", locked.cwd)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], locked.id)?["reason"]?.string)
    #expect(reason.contains("locked"), Comment(rawValue: reason))
    #expect(try sbd.intact(locked))
    #expect(removed(result) == [clean.id])
    #expect(!FileManager.default.fileExists(atPath: clean.cwd))
  }

  @Test func keepsTheBranchOfAClosedPRAndDeletesTheBranchOfAMergedPR() throws {
    let s = try Setup()
    let closed = try s.finished(.cohort, state: "CLOSED", push: true)
    let merged = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(closed, merged)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [closed.id, merged.id])
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: closed.cwd))
    #expect(try !s.sbd.git(s.repo, "worktree", "list", "--porcelain").contains(closed.cwd))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.cohort.branch))
    #expect(try !s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
  }

  @Test func leavesSessionsThatAreNotDone() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let done = try sbd.worktreeSession(repo, branch: "haacked/done")
    let active = try sbd.worktreeSession(repo, branch: "haacked/active")
    try sbd.markDone(done.id)
    #expect(try sbd.get(active.id).state != .done)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result) == [done.id])
    #expect(skip(result["skipped"], active.id) == nil)
    #expect(try sbd.intact(active))
    #expect(try sbd.get(active.id).live)
    #expect(try sbd.branchExists(repo, "haacked/active"))
  }

  @Test func withoutWorktreeRemovesOnlyTheSessions() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(merged)

    let r = try s.sbd.rmDone("--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id])
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(FileManager.default.fileExists(atPath: merged.cwd))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
  }

  @Test func deleteRemoteBranchDeletesTheRemoteBranchOfAMergedPR() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)
    #expect(try s.sbd.branchExists(s.origin, RecordedPR.breaker.branch))

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id])
    #expect(try !s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
    #expect(try !s.sbd.branchExists(s.origin, RecordedPR.breaker.branch))
  }

  @Test func withoutDeleteRemoteBranchKeepsTheRemoteBranch() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try !s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
    #expect(try s.sbd.branchExists(s.origin, RecordedPR.breaker.branch))
  }

  /// The remote branch moved after the merge, so `rm` removes the session and keeps the remote branch.
  @Test func reportsARemovalThatKeptTheRemoteBranchAsRemovedAndPartial() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)
    let other = "\(s.sbd.home.path)/other"
    try s.sbd.git(s.sbd.home.path, "clone", "-q", s.origin, other)
    try s.sbd.git(other, "checkout", "-q", RecordedPR.breaker.branch)
    try s.sbd.commit(other, "later.txt")
    try s.sbd.git(other, "push", "-q", "origin", RecordedPR.breaker.branch)

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try parse(r)
    #expect(removed(result) == [merged.id])
    let reason = try #require(skip(result["partial"], merged.id)?["reason"]?.string)
    #expect(reason.contains("kept the remote branch"), Comment(rawValue: reason))
    #expect(skip(result["skipped"], merged.id) == nil)
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(try s.sbd.branchExists(s.origin, RecordedPR.breaker.branch))
  }

  // MARK: Every rm check skips the session

  @Test func skipsAWorktreeThatAnotherSessionRunsIn() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let done = try sbd.worktreeSession(repo, branch: "haacked/shared")
    let other = try sbd.worktreeSession(repo, branch: "haacked/shared")
    #expect(other.cwd == done.cwd)
    try sbd.markDone(done.id)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], done.id)?["reason"]?.string)
    #expect(reason.contains("also runs in"), Comment(rawValue: reason))
    #expect(removed(result).isEmpty)
    #expect(try sbd.intact(done))
    #expect(try sbd.intact(other))
  }

  @Test func skipsAMergedBranchWithACommitAfterTheMerge() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(merged)
    try s.sbd.commit(merged.cwd, "later.txt")
    try s.sbd.markDone(merged.id)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], merged.id)?["reason"]?.string)
    #expect(reason.contains("not in its merged PR"), Comment(rawValue: reason))
    #expect(try s.sbd.intact(merged))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
  }

  @Test func skipsAFolderThatIsNoLongerAWorktreeOfTheRepo() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/replaced")
    try sbd.markDone(s.id)
    try sbd.git(repo, "worktree", "remove", "--force", s.cwd)
    try FileManager.default.createDirectory(atPath: s.cwd, withIntermediateDirectories: true)
    let keep = "\(s.cwd)/mine.txt"
    try "x".write(toFile: keep, atomically: true, encoding: .utf8)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string)
    #expect(reason.contains("is not a worktree of"), Comment(rawValue: reason))
    #expect(FileManager.default.fileExists(atPath: keep))
    #expect(try sbd.sessionIds() == [s.id])
  }

  /// sbd didn't make the main checkout, so neither the preview nor the removal may delete it.
  @Test func neverRemovesAFolderThatSbdDidNotMake() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.client.call("new", ["path": .string(repo), "prompt": "hello"], as: SessionSummary.self)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.markDone(s.id)

    let plan = try sbd.planDoneRemoval()
    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(isNull(try #require(item(plan, s.id))["worktree"]))
    #expect(removed(result) == [s.id])
    #expect(FileManager.default.fileExists(atPath: "\(repo)/.git"))
    #expect(try sbd.git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "main")
  }

  // MARK: Which sessions

  @Test func previewLeavesOutTheManagerAndAnUnstartedFollowupMarkedDone() throws {
    let sbd = try Instance()
    let manager = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("manager", "--json"))
    let followup = try add(sbd, ["prompt": "Check the rollout.", "repository": "acme/widgets"])
    let done = try sbd.new(prompt: "hello", name: "done")
    try sbd.waitFor(done.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.markDone(manager.id)
    try sbd.markDone(followup.id)
    try sbd.markDone(done.id)

    let plan = try sbd.planDoneRemoval()

    #expect(planned(plan) == [done.id])
    #expect(skip(plan["skip"], manager.id) == nil)
    #expect(skip(plan["skip"], followup.id) == nil)
  }

  @Test func confirmedRemovalRefusesTheManagerAndAnUnstartedFollowupEvenAsTargets() throws {
    let sbd = try Instance()
    let manager = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("manager", "--json"))
    let followup = try add(sbd, ["prompt": "Check the rollout.", "repository": "acme/widgets"])
    try sbd.markDone(manager.id)
    try sbd.markDone(followup.id)

    let result = try sbd.removeDone([manager.id, followup.id])

    #expect(removed(result).isEmpty)
    #expect(try sbd.get(manager.id).manager == true)
    #expect(try sbd.get(followup.id).state == .done)
  }

  // MARK: Confirmation

  @Test func refusesInsideClaudeWithoutYes() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markDone(s.id)

    let r = try sbd.rmDone("--worktree", env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("--yes"), Comment(rawValue: r.stderr))
    #expect(!r.stderr.contains("without asking"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
  }

  /// runCommand gives sb /dev/null as stdin, which is not a terminal.
  @Test func refusesWithoutATerminalWithoutYes() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markDone(s.id)

    let r = try sbd.rmDone("--worktree")

    #expect(r.status != 0)
    #expect(r.stderr.contains("without asking"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
  }

  @Test func refusesASessionArgument() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let named = try sbd.worktreeSession(repo, branch: "haacked/named")
    let other = try sbd.worktreeSession(repo, branch: "haacked/other")
    try sbd.markDone(named.id)
    try sbd.markDone(other.id)

    let r = try sbd.run(["rm", named.id, "--done", "--worktree", "--yes"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("takes no session"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(named))
    #expect(try sbd.intact(other))
  }

  @Test func jsonWithoutYesPrintsThePreviewAndRemovesNothing() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED")
    let dirty = try s.sbd.worktreeSession(s.repo, branch: "haacked/dirty")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try s.pollUntilDone(merged)
    try s.sbd.markDone(dirty.id)

    let r = try s.sbd.rmDone("--worktree", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let plan = try parse(r)
    #expect(plan["remove"]?.array != nil)
    #expect(plan["skip"]?.array != nil)
    #expect(planned(plan) == [merged.id])
    #expect(skip(plan["skip"], dirty.id)?["reason"]?.string?.contains("uncommitted") == true)
    #expect(try s.sbd.intact(merged))
    #expect(try s.sbd.intact(dirty))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
  }

  // MARK: The preview

  @Test func previewDescribesWhatEachRemovalDeletes() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    let closed = try s.finished(.cohort, state: "CLOSED", push: true)
    try s.pollUntilDone(merged, closed)

    let plan = try s.sbd.planDoneRemoval(remoteBranch: true)

    let m = try #require(item(plan, merged.id))
    #expect(m["name"]?.string == merged.name)
    #expect(m["pr"]?.int == RecordedPR.breaker.number)
    #expect(m["worktree"]?.string == merged.cwd)
    #expect(m["branch"]?.string == RecordedPR.breaker.branch)
    #expect(m["remoteBranch"] == .bool(true))
    let c = try #require(item(plan, closed.id))
    #expect(c["pr"]?.int == RecordedPR.cohort.number)
    #expect(c["worktree"]?.string == closed.cwd)
    #expect(isNull(c["branch"]))
    #expect(c["remoteBranch"] == .bool(false))
  }

  @Test func previewOffersTheRemoteBranchOnlyWhenAsked() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let plan = try s.sbd.planDoneRemoval(remoteBranch: false)

    #expect(item(plan, merged.id)?["remoteBranch"] == .bool(false))
  }

  @Test func previewWithoutWorktreeListsNoWorktreeOrBranch() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let plan = try s.sbd.planDoneRemoval(worktree: false, remoteBranch: true)

    let m = try #require(item(plan, merged.id))
    #expect(isNull(m["worktree"]))
    #expect(isNull(m["branch"]))
    #expect(m["remoteBranch"] == .bool(false))
  }

  @Test func previewDecodesAsADoneRemovalPlan() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--json")

    let plan = try JSONCoding.decode(DoneRemovalPlan.self, from: r.stdout)
    #expect(plan.remove.map(\.id) == [merged.id])
    #expect(plan.remove.first?.remoteBranch == true)
  }

  @Test func previewRemovesNothing() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markDone(s.id)

    _ = try sbd.planDoneRemoval()

    #expect(try sbd.intact(s))
    #expect(try sbd.branchExists(repo, "haacked/done"))
  }

  // MARK: The confirmed op

  @Test func confirmedRemovalSkipsATargetThatLeftDoneAndRemovesTheOthers() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let left = try sbd.worktreeSession(repo, branch: "haacked/left")
    let stays = try sbd.worktreeSession(repo, branch: "haacked/stays")
    try sbd.markDone(left.id)
    try sbd.markDone(stays.id)
    #expect(planned(try sbd.planDoneRemoval()) == [left.id, stays.id])
    try sbd.sb("undone", left.id)
    try sbd.waitFor(left.id, "not Done") { $0.state != .done }

    let result = try sbd.removeDone([left.id, stays.id])

    #expect(removed(result) == [stays.id])
    let reason = try #require(skip(result["skipped"], left.id)?["reason"]?.string)
    #expect(reason.lowercased().contains("done"), Comment(rawValue: reason))
    #expect(try sbd.intact(left))
    #expect(!FileManager.default.fileExists(atPath: stays.cwd))
  }

  /// The confirmed op runs rm's checks again, so a change after the preview skips that target.
  @Test func confirmedRemovalSkipsATargetThatFailsACheckAfterThePreviewAndRemovesTheOthers() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let failing = try sbd.worktreeSession(repo, branch: "haacked/failing")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markDone(failing.id)
    try sbd.markDone(clean.id)
    #expect(planned(try sbd.planDoneRemoval()) == [failing.id, clean.id])
    try "x".write(toFile: "\(failing.cwd)/notes.txt", atomically: true, encoding: .utf8)

    let result = try sbd.removeDone([failing.id, clean.id])

    let reason = try #require(skip(result["skipped"], failing.id)?["reason"]?.string)
    #expect(reason.contains("uncommitted"), Comment(rawValue: reason))
    #expect(removed(result) == [clean.id])
    #expect(FileManager.default.fileExists(atPath: "\(failing.cwd)/notes.txt"))
    #expect(try sbd.sessionIds() == [failing.id])
  }

  @Test func confirmedRemovalSkipsATargetThatNamesNoSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markDone(s.id)

    let result = try sbd.removeDone(["snope1", s.id])

    #expect(removed(result) == [s.id])
    #expect(skip(result["skipped"], "snope1")?["reason"]?.string?.isEmpty == false)
  }

  @Test func confirmedRemovalAccountsForEveryTarget() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let active = try sbd.worktreeSession(repo, branch: "haacked/active")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try sbd.markDone(clean.id)
    try sbd.markDone(dirty.id)
    let targets = [clean.id, dirty.id, active.id]

    let result = try sbd.removeDone(targets)

    let skipped = Set(result["skipped"]?.array?.compactMap { $0["id"]?.string } ?? [])
    #expect(removed(result).union(skipped) == Set(targets))
    #expect(removed(result).isDisjoint(with: skipped))
  }

  // MARK: To-dos

  /// Without --worktree, rm skips its worktree checks. The to-do check must still run.
  @Test(arguments: [true, false])
  func previewSkipsASessionWithAnOpenToDoAndNamesTheToDo(worktree: Bool) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.worktreeSession(repo, branch: "haacked/held")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markDone(held.id)
    try sbd.markDone(clean.id)
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")

    let plan = try sbd.planDoneRemoval(worktree: worktree)

    #expect(planned(plan) == [clean.id])
    let reason = try #require(skip(plan["skip"], held.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(
      reason.contains("\(held.name) has an open to-do: \(todo.id) \"tell Alex in #flags that the fix shipped\""),
      Comment(rawValue: reason))
    #expect(try sbd.intact(held))
  }

  @Test(arguments: [true, false])
  func confirmedRemovalSkipsATargetWhoseToDoWasAddedAfterThePreview(worktree: Bool) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.worktreeSession(repo, branch: "haacked/held")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markDone(held.id)
    try sbd.markDone(clean.id)
    #expect(planned(try sbd.planDoneRemoval(worktree: worktree)) == [held.id, clean.id])
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")

    let result = try sbd.removeDone([held.id, clean.id], worktree: worktree)

    #expect(removed(result) == [clean.id])
    let reason = try #require(skip(result["skipped"], held.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(
      reason.contains("has an open to-do: \(todo.id) \"tell Alex in #flags that the fix shipped\""),
      Comment(rawValue: reason))
    #expect(try sbd.intact(held))
    #expect(try sbd.isOpenTodo(held.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  // MARK: Removal from inside a session

  /// sb runs below a's shell pane, so removing a's worktree would stop sb's own parents. The preview skips a with
  /// rm's refusal, and the confirmed run removes b and leaves a and its claude running.
  @Test func rmDoneSkipsTheCallersOwnSession() throws {
    let s = try Setup()
    let a = try s.finished(.breaker, state: "MERGED")
    let b = try s.finished(.groups, state: "MERGED")
    // The shell pane starts before a is Done, so it can't change a's state.
    let terminals = try s.sbd.client.terminals(a.id)
    let claude = try #require(try s.sbd.waitFor(a.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    try s.pollUntilDone(a, b)
    // The preview reads the installed snapshot. A tick installs one that holds the shell pane's pid.
    try s.sbd.advanceClock(1)
    try s.sbd.writeSbScript("preview", ["rm", "--done", "--worktree", "--json"])
    try s.sbd.writeSbScript("confirmed", ["rm", "--done", "--worktree", "--yes", "--json"])
    let refusal = insideRefusal("sb rm --worktree", a.id)

    try s.sbd.typeInShell(terminals, "sh \"$SB_HOME/preview.sh\"")
    let preview = try s.sbd.scriptResult("preview")
    try s.sbd.typeInShell(terminals, "sh \"$SB_HOME/confirmed.sh\"")
    let confirmed = try s.sbd.scriptResult("confirmed")

    #expect(preview.status == 0, Comment(rawValue: preview.stderr))
    let plan = try parse(preview)
    #expect(planned(plan) == [b.id])
    let planReason = try #require(skip(plan["skip"], a.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(planReason.contains(refusal), Comment(rawValue: planReason))
    let result = try parse(confirmed)
    #expect(removed(result) == [b.id])
    let reason = try #require(skip(result["skipped"], a.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains(refusal), Comment(rawValue: reason))
    #expect(try s.sbd.sessionIds() == [a.id])
    #expect(FileManager.default.fileExists(atPath: a.cwd))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
    #expect(Processes.exists(claude), "sbd ended a's claude")
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
    #expect(try !s.sbd.branchExists(s.repo, RecordedPR.groups.branch))
  }

  /// sb sends only the preview's `remove` as targets, so a perl client in a's shell pane sends the confirmed op
  /// with a as a target. The confirmed op must skip a with the refusal that the preview gives.
  @Test func confirmedRmDoneFromInsideASessionSkipsThatSessionAsATarget() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/inside")
    let terminals = try sbd.client.terminals(a.id)
    let claude = try #require(try sbd.waitFor(a.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    try sbd.markDone(a.id)
    // A tick installs a snapshot that holds the shell pane's pid, so `doneTarget` skips a before `rm` runs.
    try sbd.advanceClock(1)
    let request: JSON = [
      "op": "rm-done", "args": ["worktree": true, "confirmed": true, "targets": .array([.string(a.id)])],
    ]
    let client = [
      #"$s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "connect: $!\n";"#,
      #"print $s "$ARGV[1]\n";"#,
      "print scalar <$s>",
    ].joined(separator: " ")
    try sbd.writeScript(
      "confirmed",
      "perl -MIO::Socket::UNIX -e \(shellQuote(client)) \"$SB_HOME/sbd.sock\" \(shellQuote(request.text))")

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/confirmed.sh\"")
    let r = try sbd.scriptResult("confirmed")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let response = try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    let result = try #require(response["result"], Comment(rawValue: response.text))
    #expect(removed(result).isEmpty)
    let reason = try #require(skip(result["skipped"], a.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains(insideRefusal("sb rm --worktree", a.id)), Comment(rawValue: reason))
    #expect(try sbd.intact(a))
    #expect(try sbd.branchExists(repo, "haacked/inside"))
    #expect(Processes.exists(claude), "sbd ended a's claude")
  }
}

// MARK: - Worktrees that Supacode locked

/// The lock reason that Supacode writes.
private let supacodeLock = #"{"build":"1792934673","createdAt":1793889333,"owner":"supacode","version":"0.11.6"}"#

extension Instance {
  /// Points sbd's `supacode` at a stub, and returns the file where the stub records each call. The stub that
  /// works removes the worktree and force-deletes its branch with git, as Supacode does with its default
  /// settings. The stub that fails prints a message and exits 1.
  fileprivate func useSupacodeStub(failing: Bool = false, removes: Bool = true) throws -> String {
    let calls = "\(home.path)/supacode-calls.log"
    let stub = "\(home.path)/supacode-stub"
    let body =
      failing
      ? #"echo "Supacode is not running" >&2; exit 1"#
      : !removes
        ? "exit 0"
        : #"""
        path=$(printf '%b' "${4//%/\\x}")
        path=${path%/}
        main=$(/usr/bin/git -C "$path" worktree list --porcelain | head -1 | cut -d' ' -f2-)
        branch=$(/usr/bin/git -C "$path" branch --show-current)
        /usr/bin/git -C "$main" worktree unlock "$path" && /usr/bin/git -C "$main" worktree remove "$path" || exit 1
        [ -z "$branch" ] || /usr/bin/git -C "$main" branch -q -D "$branch"
        """#
    try "#!/bin/bash\necho \"$@\" >> \(calls)\n\(body)\n".write(toFile: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
    try restart(setting: "supacode", to: .string(stub))
    return calls
  }

  fileprivate func lockForSupacode(_ repo: String, _ cwd: String) throws {
    try git(repo, "worktree", "lock", "--reason", supacodeLock, cwd)
  }
}

private func calls(_ log: String) -> [String] {
  ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

@Suite(.blocking(timeLimit: .seconds(120))) struct SupacodeLockTests {
  @Test func deleteAllRemovesAWorktreeThatSupacodeLockedThroughSupacode() throws {
    let s = try Setup()
    let kept = try s.finished(.breaker, state: "MERGED")
    let inMain = try s.finished(.groups, state: "MERGED")
    // origin/main contains the second branch's tip, as after a merge commit. The first is like a squash merge.
    try s.sbd.git(inMain.cwd, "push", "-q", "origin", "HEAD:main")
    try s.sbd.git(s.repo, "fetch", "-q", "origin")
    try s.pollUntilDone(kept, inMain)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, kept.cwd)
    try s.sbd.lockForSupacode(s.repo, inMain.cwd)

    let plan = try s.sbd.planDoneRemoval()
    #expect(planned(plan) == [kept.id, inMain.id], Comment(rawValue: plan.text))
    #expect(isNull(item(plan, kept.id)?["branch"]))
    #expect(item(plan, inMain.id)?["branch"]?.string == RecordedPR.groups.branch)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [kept.id, inMain.id], Comment(rawValue: r.stdout))
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: kept.cwd))
    #expect(!FileManager.default.fileExists(atPath: inMain.cwd))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
    #expect(try !s.sbd.branchExists(s.repo, RecordedPR.groups.branch))
    let made = calls(log)
    #expect(made.count == 2, Comment(rawValue: made.joined(separator: "\n")))
    for call in made {
      #expect(call.hasPrefix("worktree delete --worktree %2F"), Comment(rawValue: call))
      #expect(call.hasSuffix("%2F --background"), Comment(rawValue: call))
      #expect(!call.contains("/"), Comment(rawValue: call))
    }
  }

  @Test func skipsAWorktreeThatSupacodeLockedWhenSupacodeFails() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/locked")
    try sbd.markDone(s.id)
    _ = try sbd.useSupacodeStub(failing: true)
    try sbd.lockForSupacode(repo, s.cwd)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("Supacode is not running"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains("supacode"))
  }

  @Test func skipsAWorktreeThatSupacodeSaysItDeletedWhenGitStillListsIt() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/locked")
    try sbd.markDone(s.id)
    _ = try sbd.useSupacodeStub(removes: false)
    try sbd.lockForSupacode(repo, s.cwd)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("still lists"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
  }

  @Test func skipsAWorktreeThatSupacodeLockedWhenSupacodeIsMissing() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/locked")
    try sbd.markDone(s.id)
    try sbd.restart(setting: "supacode", to: .string("\(sbd.home.path)/no-such-supacode"))
    try sbd.lockForSupacode(repo, s.cwd)

    let plan = try sbd.planDoneRemoval()

    let reason = try #require(skip(plan["skip"], s.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(reason.contains("can't find"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
  }

  @Test func skipsAWorktreeThatSupacodeLockedWithUncommittedFilesWithoutCallingSupacode() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    try sbd.markDone(s.id)
    let log = try sbd.useSupacodeStub()
    try sbd.lockForSupacode(repo, s.cwd)
    try "draft".write(toFile: "\(s.cwd)/draft.txt", atomically: true, encoding: .utf8)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("uncommitted"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
    #expect(calls(log).isEmpty)
  }

  @Test func cleanupRefusesAWorktreeThatSupacodeLockedWhenItsMergedPRIsFromAnotherRepo() throws {
    let s = try Setup()
    let session = try s.sbd.worktreeSession(s.repo, branch: "haacked/no-pr-yet")
    try s.sbd.link(session, "haacked/review-code", 189)
    s.github.change(189) { $0["state"] = "MERGED" }
    try s.pollUntilDone(session)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, session.cwd)

    let r = try s.sbd.run(["cleanup", session.id, "--json"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("has no merged PR"), Comment(rawValue: r.stderr))
    #expect(FileManager.default.fileExists(atPath: session.cwd))
    #expect(calls(log).isEmpty)
  }

  @Test func cleanupRemovesAWorktreeThatSupacodeLockedAndKeepsTheSession() throws {
    let s = try Setup()
    let session = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(session)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, session.cwd)

    let r = try s.sbd.run(["cleanup", session.id, "--json"])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(!FileManager.default.fileExists(atPath: session.cwd))
    #expect(try s.sbd.client.sessions().map(\.id) == [session.id])
    #expect(calls(log).count == 1)
    // origin/main doesn't contain the branch's tip, so the branch stays.
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
    let kept = try s.sbd.waitFor(session.id, "the kept branch in the reason") {
      $0.reason.contains("kept \(RecordedPR.breaker.branch)")
    }
    #expect(kept.state == .done)
  }

  /// Supacode deletes the branch with the worktree, and the commit after the merge is only on that branch.
  @Test func keepsABranchWithACommitAfterTheMergeThatSupacodeDeleted() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(merged)
    try s.sbd.commit(merged.cwd, "later.txt")
    try s.sbd.markDone(merged.id)
    let tip = try s.sbd.git(merged.cwd, "rev-parse", "HEAD")
    try s.sbd.git(s.repo, "config", "branch.\(RecordedPR.breaker.branch).remote", "origin")
    _ = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, merged.cwd)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id], Comment(rawValue: r.stdout))
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(RecordedPR.breaker.branch)") == tip)
    #expect(try s.sbd.git(s.repo, "config", "branch.\(RecordedPR.breaker.branch).remote") == "origin")
  }

  /// The plan keeps the squash-merged branch, so the remote branch stays too.
  @Test func keepsTheRemoteBranchOfABranchThatTheSupacodePathKeeps() throws {
    let s = try Setup()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)
    _ = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, merged.cwd)

    let plan = try s.sbd.planDoneRemoval(remoteBranch: true)
    #expect(item(plan, merged.id)?["remoteBranch"] == .bool(false), Comment(rawValue: plan.text))

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id], Comment(rawValue: r.stdout))
    #expect(try s.sbd.branchExists(s.repo, RecordedPR.breaker.branch))
    #expect(try s.sbd.branchExists(s.origin, RecordedPR.breaker.branch))
  }
}
