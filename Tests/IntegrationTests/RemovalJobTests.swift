import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// How many times the stub ran with the session's conversation, which counts the launches of its claude.
  fileprivate func launches(_ s: SessionSummary) -> Int {
    stubArgs().filter { $0.contains(s.claudeSessionId) }.count
  }

  /// Starts `sb rm --worktree` on the session without waiting for it.
  fileprivate func startRm(_ id: String) throws -> BackgroundSb { try BackgroundSb(self, ["rm", id, "--worktree"]) }

  /// A session in its own worktree whose claude asked a question and then stopped, so its card is deferred. Each of
  /// `send`, `resume`, `open`, and `answer` would launch its claude again.
  fileprivate func stoppedSessionWithADeferredQuestion(_ repo: String, branch: String) throws -> SessionSummary {
    let s = try client.call(
      "new", ["path": .string(repo), "branch": .string(branch), "prompt": "pick"], as: SessionSummary.self)
    try waitFor(s.id, "the card") { !$0.cards.isEmpty }
    try sb("stop", s.id)
    return try waitFor(s.id, "the stop and the deferred card") { !$0.live && $0.cards.first?.deferred == true }
  }
}

/// The `skipped` entry for the session, or nil when the list doesn't name it.
private func skipped(_ result: JSON, _ id: String) -> JSON? {
  result["skipped"]?.array?.first { $0["id"]?.string == id }
}

/// How many launches, resumes, and prompts the session's log holds. Each one shows that the session came back.
private func comebackEvents(_ sbd: Instance, _ id: String) throws -> Int {
  try sbd.events(id).filter { ["started", "resumed", "UserPromptSubmit"].contains($0.kind) }.count
}

private func paneExists(_ t: Terminals, _ target: String) throws -> Bool {
  try runCommand(t.tmux, ["-S", t.socket, "has-session", "-t", "=\(target)"]).status == 0
}

/// Whether the process has exec'd sleep.
private func runsSleep(_ pid: pid_t) -> Bool {
  guard let r = try? runCommand("/bin/ps", ["-o", "comm=", "-p", String(pid)]) else { return false }
  return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("sleep")
}

/// A `sleep 100` that works in the folder, outside every pane. While it runs, a removal's pane stop waits up to
/// 5 s for it to exit and then fails. Fixtures/reap can't find it, so a test calls `end` in a `defer`.
private final class FolderHold {
  let process = Process()

  init(_ sbd: Instance, _ folder: String) throws {
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["100"]
    process.currentDirectoryURL = URL(fileURLWithPath: folder)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let pid = process.processIdentifier
    try sbd.waitFor("the folder's sleep to start") { runsSleep(pid) }
  }

  func end() {
    guard process.isRunning else { return }
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
  }
}

@Suite(.blocking(timeLimit: .seconds(180))) struct RemovalJobTests {
  // MARK: rm-queue

  /// The sleep in a's folder keeps the removal in its pane stop for 5 s, so an rm-queue that waited for it could
  /// not return within the bound.
  @Test func rmQueueReturnsTheQueuedIdsBeforeTheRemovalFinishes() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)
    let hold = try FolderHold(sbd, a.cwd)
    defer { hold.end() }

    let started = Date()
    let result = try sbd.queueRemoval([a.id])
    let elapsed = Date().timeIntervalSince(started)
    hold.end()

    #expect(elapsed < 3, "rm-queue took \(elapsed) s")
    #expect(queued(result) == [a.id], Comment(rawValue: result.text))
    #expect(result["skipped"]?.array?.isEmpty == true, Comment(rawValue: result.text))
    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
  }

  @Test func lsShowsTheRemovalRunningAndQueuedAndThenTheSessionsGo() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    try sbd.markSessionDone(a.id)
    try sbd.markSessionDone(b.id)
    sbd.hold(holdRemoval)

    let result = try sbd.queueRemoval([a.id, b.id])

    #expect(queued(result) == [a.id, b.id], Comment(rawValue: result.text))
    let running = try sbd.waitForRemoval(a.id, "running")
    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    let removals = Dictionary(
      uniqueKeysWithValues: listed.compactMap { s in s["id"]?.string.map { ($0, s["removal"]) } })
    #expect(removals[a.id]??["state"]?.string == "running", Comment(rawValue: listed.description))
    #expect(removals[b.id]??["state"]?.string == "queued", Comment(rawValue: listed.description))
    #expect(running["worktree"] == .bool(true), Comment(rawValue: running.text))
    #expect(running["requested"]?.int != nil, Comment(rawValue: running.text))
    #expect(FileManager.default.fileExists(atPath: a.cwd))
    try sbd.release(holdRemoval)
    try sbd.waitUntilGone(a.id, b.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
  }

  /// Delete All's rule holds when the caller names the targets.
  @Test func rmQueueForDoneSkipsASessionThatIsNotDone() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let done = try sbd.worktreeSession(repo, branch: "haacked/done")
    let active = try sbd.worktreeSession(repo, branch: "haacked/active")
    try sbd.markSessionDone(done.id)
    try #require(try sbd.get(active.id).state != .done)
    sbd.hold(holdRemoval)

    let result = try sbd.queueRemoval([active.id, done.id], scope: "done")

    #expect(queued(result) == [done.id], Comment(rawValue: result.text))
    let reason = try #require(skipped(result, active.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("is no longer in Done"), Comment(rawValue: reason))
    #expect(try sbd.removal(active.id) == nil)
    #expect(try sbd.intact(active))
  }

  @Test func rmQueueForWorkSkipsTheManager() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let work = try sbd.worktreeSession(repo, branch: "haacked/work")
    let manager = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("manager", "--json"))
    sbd.hold(holdRemoval)

    let result = try sbd.queueRemoval([manager.id, work.id], scope: "work")

    #expect(queued(result) == [work.id], Comment(rawValue: result.text))
    let reason = try #require(skipped(result, manager.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("is the Manager"), Comment(rawValue: reason))
    #expect(try sbd.removal(manager.id) == nil)
  }

  @Test func rmQueueSkipsATargetThatNamesNoSession() throws {
    let sbd = try Instance()

    let result = try sbd.queueRemoval(["nope"], scope: "work")

    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    let reason = try #require(skipped(result, "nope")?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("no longer exists"), Comment(rawValue: reason))
  }

  /// Without `resolve`, with an empty `resolve`, and with a `resolve` that lists only another session's to-do, the
  /// session's own to-do stays unlisted.
  @Test(arguments: [nil, [], ["other"]] as [[String]?])
  func rmQueueSkipsASessionWithAnOpenToDoThatResolveDoesNotList(_ resolve: [String]?) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.worktreeSession(repo, branch: "haacked/held")
    let other = try sbd.worktreeSession(repo, branch: "haacked/other")
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")
    let otherTodo = try sbd.addTodo(other.id, "close the incident")
    sbd.hold(holdRemoval)

    let result = try sbd.queueRemoval(
      [held.id], scope: "work", resolve: resolve?.map { $0 == "other" ? otherTodo.id : $0 })

    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    let reason = try #require(skipped(result, held.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(
      reason.contains("\(held.name) has an open to-do: \(todo.id) \"tell Alex in #flags that the fix shipped\""),
      Comment(rawValue: reason))
    #expect(try sbd.removal(held.id) == nil)
    #expect(try sbd.isOpenTodo(held.id, todo.id))
  }

  /// sb runs below a's shell pane, so a removal of a's worktree would stop sb's own parents. rm-queue skips a with
  /// rm's refusal, as rm-done does.
  @Test func rmQueueFromInsideASessionSkipsThatSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/inside")
    let terminals = try sbd.client.terminals(a.id)
    let claude = try #require(try sbd.waitFor(a.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    // A tick installs a snapshot that holds the shell pane's pid.
    try sbd.advanceClock(1)
    let request: JSON = [
      "op": "rm-queue", "args": ["scope": "work", "worktree": true, "targets": .array([.string(a.id)])],
    ]
    let client = [
      #"$s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "connect: $!\n";"#,
      #"print $s "$ARGV[1]\n";"#,
      "print scalar <$s>",
    ].joined(separator: " ")
    try sbd.writeScript(
      "queue", "perl -MIO::Socket::UNIX -e \(shellQuote(client)) \"$SB_HOME/sbd.sock\" \(shellQuote(request.text))")

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/queue.sh\"")
    let r = try sbd.scriptResult("queue")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let response = try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    let result = try #require(response["result"], Comment(rawValue: response.text))
    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    let reason = try #require(skipped(result, a.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains(insideRefusal("sb rm --worktree", a)), Comment(rawValue: reason))
    #expect(try sbd.removal(a.id) == nil)
    #expect(try sbd.intact(a))
    #expect(Processes.exists(claude), "sbd ended a's claude")
  }

  // MARK: resolve

  /// Each session takes the ids in `resolve` that name its own open to-dos. Passing the whole list to each session's
  /// to-do check would refuse both, because each list holds the other session's to-do.
  @Test func rmQueueWithResolveRemovesSessionsWhoseToDosItListsAndResolvesThem() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    let c = try sbd.worktreeSession(repo, branch: "haacked/c")
    let aTodo = try sbd.addTodo(a.id, "tell Alex in #flags that the fix shipped")
    let bTodo = try sbd.addTodo(b.id, "close the incident")
    let cTodo = try sbd.addTodo(c.id, "update the runbook")
    sbd.hold(holdRemoval)

    let result = try sbd.queueRemoval([a.id, b.id, c.id], scope: "work", resolve: [aTodo.id, bTodo.id])

    #expect(Set(queued(result)) == [a.id, b.id], Comment(rawValue: result.text))
    let reason = try #require(skipped(result, c.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("has an open to-do: \(cTodo.id)"), Comment(rawValue: reason))
    let aResolve = try sbd.removal(a.id)?["resolve"]?.array?.compactMap(\.string)
    let bResolve = try sbd.removal(b.id)?["resolve"]?.array?.compactMap(\.string)
    #expect(aResolve == [aTodo.id])
    #expect(bResolve == [bTodo.id])
    try sbd.release(holdRemoval)
    try sbd.waitUntilGone(a.id, b.id)
    #expect(Set(try sbd.resolvedTodoIds()) == [aTodo.id, bTodo.id])
    #expect(try sbd.intact(c))
    #expect(try sbd.isOpenTodo(c.id, cTodo.id))
  }

  /// A second rm-queue must not queue a session twice, nor queue a failed removal again behind rm-retry's back.
  @Test func rmQueueSkipsASessionThatAlreadyHasARemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let running = try sbd.worktreeSession(repo, branch: "haacked/running")
    let waiting = try sbd.worktreeSession(repo, branch: "haacked/queued")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    #expect(queued(try sbd.queueRemoval([dirty.id], scope: "work")) == [dirty.id])
    try sbd.waitForRemoval(dirty.id, "failed")
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([running.id, waiting.id], scope: "work")) == [running.id, waiting.id])
    try sbd.waitForRemoval(running.id, "running")

    let result = try sbd.queueRemoval([dirty.id, running.id, waiting.id], scope: "work")

    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    for (s, reason) in [(dirty, "failed to delete"), (running, "is being deleted"), (waiting, "is being deleted")] {
      let skip = try #require(skipped(result, s.id)?["reason"]?.string, Comment(rawValue: result.text))
      #expect(skip.contains(reason), Comment(rawValue: skip))
    }
    #expect(try sbd.removalState(dirty.id) == "failed")
    #expect(try sbd.removalState(running.id) == "running")
    #expect(try sbd.removalState(waiting.id) == "queued")
  }

  /// The store refuses the one transaction, so every target is skipped with the store's error and none keeps a
  /// removal that sbd never saved.
  @Test func aStoreThatRefusesRmQueueSkipsEveryTargetAndLeavesNoRemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    try sbd.block("INSERT", on: "sessions")

    let result = try sbd.queueRemoval([a.id, b.id], scope: "work")

    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    for s in [a, b] {
      let reason = try #require(skipped(result, s.id)?["reason"]?.string, Comment(rawValue: result.text))
      #expect(reason.contains("read-only"), Comment(rawValue: reason))
      #expect(try sbd.removal(s.id) == nil)
      #expect(try sbd.intact(s))
    }
  }

  /// The to-do arrives after rm-queue checked the session's to-dos, so the worker's own to-do check must refuse it.
  @Test func aToDoAddedAfterTheSessionWasQueuedKeepsTheSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let listed = try sbd.addTodo(a.id, "tell Alex in #flags that the fix shipped")
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work", resolve: [listed.id])) == [a.id])
    try sbd.waitForRemoval(a.id, "running")
    let late = try sbd.addTodo(a.id, "close the incident")

    try sbd.release(holdRemoval)

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains(late.id), Comment(rawValue: error))
    #expect(try sbd.intact(a))
    #expect(try sbd.isOpenTodo(a.id, listed.id))
    #expect(try sbd.isOpenTodo(a.id, late.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  /// The user resolved one listed to-do by hand while the session waited. The removal resolves the other and does
  /// not fail on the one that is no longer open.
  @Test func aListedToDoResolvedByHandWhileQueuedDoesNotKeepTheSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let byHand = try sbd.addTodo(a.id, "tell Alex in #flags that the fix shipped")
    let listed = try sbd.addTodo(a.id, "close the incident")
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work", resolve: [byHand.id, listed.id])) == [a.id])
    try sbd.waitForRemoval(a.id, "running")
    try sbd.resolveTodo(a.id, byHand.id)

    try sbd.release(holdRemoval)

    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try sbd.resolvedTodoIds().contains(listed.id))
  }

  /// The sleep in a's folder holds the job in its pane stop, after the job's first to-do checks passed. A to-do
  /// resolved by hand there must not fail the forget that follows the worktree's delete.
  @Test func aListedToDoResolvedByHandDuringThePaneStopDoesNotKeepTheSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let byHand = try sbd.addTodo(a.id, "tell Alex in #flags that the fix shipped")
    let listed = try sbd.addTodo(a.id, "close the incident")
    let terminals = try sbd.client.terminals(a.id)
    let hold = try FolderHold(sbd, a.cwd)
    defer { hold.end() }
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work", resolve: [byHand.id, listed.id])) == [a.id])
    try sbd.waitFor("the removal to close a's Claude pane") { try !paneExists(terminals, terminals.claude) }
    try sbd.resolveTodo(a.id, byHand.id)

    hold.end()

    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try sbd.resolvedTodoIds().contains(listed.id))
  }

  // MARK: The worker

  /// The uncommitted file appears after rm-queue, so only the worker's own checks can find it.
  @Test func queuesThreeSessionsAndFailsOnlyTheOneWithUncommittedFiles() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    for s in [dirty, a, b] { try sbd.markSessionDone(s.id) }
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([dirty.id, a.id, b.id])) == [dirty.id, a.id, b.id])
    let file = "\(dirty.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)

    try sbd.release(holdRemoval)

    try sbd.waitUntilGone(a.id, b.id)
    let failed = try sbd.waitForRemoval(dirty.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("uncommitted"), Comment(rawValue: error))
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
    #expect(FileManager.default.fileExists(atPath: file))
    #expect(try sbd.intact(dirty))
    #expect(try sbd.localBranch(repo, "haacked/dirty"))
    let summary = try sbd.get(dirty.id)
    #expect(summary.state == .needsYou)
    let reason = "Delete failed: \(error)"
    #expect(summary.reason == reason || summary.reason == oneLine(reason), Comment(rawValue: summary.reason))
  }

  /// The sleep in a's folder holds the worker in a's pane stop for up to 5 s. A send that waited behind the worker
  /// could not answer within that time.
  @Test func aSendToAnotherSessionAnswersWhileTheRemovalRuns() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let other = try sbd.worktreeSession(repo, branch: "haacked/other")
    try sbd.markSessionDone(a.id)
    let terminals = try sbd.client.terminals(a.id)
    let hold = try FolderHold(sbd, a.cwd)
    defer { hold.end() }
    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])
    try sbd.waitForRemoval(a.id, "running")
    try sbd.waitFor("the removal to close a's Claude pane") { try !paneExists(terminals, terminals.claude) }

    let started = Date()
    let r = try sbd.run(["send", other.id, "still here"])
    let elapsed = Date().timeIntervalSince(started)
    hold.end()

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(elapsed < 3, "send took \(elapsed) s")
    try sbd.waitFor(other.id, "the reply") { $0.lastReply == "Done: still here" }
    try sbd.waitUntilGone(a.id)
  }

  /// The local branch moves after `git worktree remove`, so the branch check fails after the session's folder went.
  @Test func aBranchThatFailsAfterTheWorktreeGoesRecordsARemovalNotice() throws {
    let s = try MergedPRRepo()
    let merged = try s.merged(.breaker)
    try s.sbd.runAfterWorktreeRemoval(s.repo, "git -C \"$REPO\" branch -f \(RemovalPR.breaker.branch) main")
    // The restart drops the polled PR, so poll it again.
    try s.pollUntilDone(merged)

    #expect(queued(try s.sbd.queueRemoval([merged.id])) == [merged.id])

    try s.sbd.waitUntilGone(merged.id)
    #expect(!FileManager.default.fileExists(atPath: merged.cwd))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    let notice = try #require(try s.sbd.removalNotice(for: merged.id), "no removal notice names \(merged.id)")
    #expect(notice.message.contains("not in its merged PR"), Comment(rawValue: notice.message))
    #expect(notice.name == merged.name)
  }

  /// The remote branch moved after the merge, so the removal forgets the session and keeps the remote branch.
  @Test func aRemovalNoticePersistsAcrossARestartUntilItIsDismissed() throws {
    let s = try MergedPRRepo()
    let merged = try s.merged(.breaker, push: true)
    try s.pollUntilDone(merged)
    let other = "\(s.sbd.home.path)/other"
    try s.sbd.git(s.sbd.home.path, "clone", "-q", s.origin, other)
    try s.sbd.git(other, "checkout", "-q", RemovalPR.breaker.branch)
    try s.sbd.commit(other, "later.txt")
    try s.sbd.git(other, "push", "-q", "origin", RemovalPR.breaker.branch)
    #expect(queued(try s.sbd.queueRemoval([merged.id], remoteBranch: true)) == [merged.id])
    try s.sbd.waitUntilGone(merged.id)
    let notice = try #require(try s.sbd.removalNotice(for: merged.id), "no removal notice names \(merged.id)")
    #expect(notice.message.contains("kept the remote branch"), Comment(rawValue: notice.message))

    s.sbd.stopSbd()
    try s.sbd.startSbd()

    let kept = try #require(try s.sbd.removalNotice(for: merged.id), "the restart dropped the notice")
    _ = try s.sbd.client.call("removal-notice-dismiss", ["id": .number(Double(kept.id))])
    #expect(try s.sbd.removalNotice(for: merged.id) == nil)
    s.sbd.stopSbd()
    try s.sbd.startSbd()
    #expect(try s.sbd.removalNotice(for: merged.id) == nil)
  }

  // MARK: rm-retry and rm-keep

  /// The session fails on its uncommitted file, which the test then deletes. A removal that the gate holds keeps the
  /// worker busy, so the retried removal waits in `queued`.
  @Test func rmRetrySetsAFailedRemovalBackToQueued() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let busy = try sbd.worktreeSession(repo, branch: "haacked/busy")
    try sbd.markSessionDone(dirty.id)
    try sbd.markSessionDone(busy.id)
    let file = "\(dirty.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    #expect(queued(try sbd.queueRemoval([dirty.id])) == [dirty.id])
    try sbd.waitForRemoval(dirty.id, "failed")
    try FileManager.default.removeItem(atPath: file)
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([busy.id])) == [busy.id])
    try sbd.waitForRemoval(busy.id, "running")

    _ = try sbd.client.call("rm-retry", ["session": .string(dirty.id)])

    let retried = try #require(try sbd.removal(dirty.id))
    #expect(retried["state"]?.string == "queued", Comment(rawValue: retried.text))
    #expect(try sbd.get(dirty.id).state != .needsYou)
    try sbd.release(holdRemoval)
    try sbd.waitUntilGone(dirty.id, busy.id)
    #expect(!FileManager.default.fileExists(atPath: dirty.cwd))
  }

  /// `sb rm --keep` sends the Keep button's `rm-keep`, so a Manager or a script can clear a stuck failed delete.
  /// Before the delete fails, sbd refuses the session. `--keep` refuses a delete's flags before it sends anything.
  @Test func sbRmKeepClearsAFailedRemovalAndTheSessionIsBackInDone() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    try sbd.markSessionDone(dirty.id)
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)

    let refused = try sbd.run("rm", "--keep", dirty.id)
    #expect(refused.status != 0)
    #expect(refused.stderr.contains("has no failed removal"), Comment(rawValue: refused.stderr))
    for flags in [["--done"], ["--worktree"], ["--delete-branch"], ["--delete-remote-branch"], ["--resolve", "1"]] {
      let r = try sbd.run(["rm", "--keep", dirty.id] + flags)
      #expect(r.stderr.contains("--keep and \(flags[0]) conflict"), Comment(rawValue: r.stderr))
    }

    #expect(queued(try sbd.queueRemoval([dirty.id])) == [dirty.id])
    try sbd.waitForRemoval(dirty.id, "failed")
    try #require(try sbd.get(dirty.id).state == .needsYou)

    let kept = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("rm", "--keep", dirty.id, "--json"))

    #expect(kept.id == dirty.id)
    #expect(kept.removal == nil)
    #expect(try sbd.removal(dirty.id) == nil)
    try sbd.waitFor(dirty.id, "Done") { $0.state == .done }
    #expect(try sbd.intact(dirty))
    #expect(FileManager.default.fileExists(atPath: "\(dirty.cwd)/notes.txt"))
  }

  /// rm-retry and rm-keep apply only to a failed removal. A keep that cleared a running removal would leave a
  /// session whose claude the worker already stopped, and the worker would still go on to delete it.
  @Test(arguments: ["rm-retry", "rm-keep"])
  func refusesARemovalThatIsNotFailed(_ op: String) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let running = try sbd.worktreeSession(repo, branch: "haacked/running")
    let waiting = try sbd.worktreeSession(repo, branch: "haacked/queued")
    let none = try sbd.worktreeSession(repo, branch: "haacked/none")
    try sbd.markSessionDone(running.id)
    try sbd.markSessionDone(waiting.id)
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([running.id, waiting.id])) == [running.id, waiting.id])
    try sbd.waitForRemoval(running.id, "running")

    for (s, state) in [(running, "running"), (waiting, "queued"), (none, nil)] as [(SessionSummary, String?)] {
      #expect(failure(sbd, op, ["session": .string(s.id)]) != "no error", "\(op) on \(state ?? "no removal")")
      #expect(try sbd.removalState(s.id) == state)
    }
  }

  // MARK: A session that comes back drops its failed removal (#378)

  /// The removal fails on the uncommitted file. The prompt shows that the user went back to the session, so sbd
  /// clears the removal as Keep does, and the session leaves Needs you with its folder and file in place.
  @Test func aPromptToASessionWhoseRemovalFailedClearsTheRemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    try sbd.markSessionDone(dirty.id)
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    #expect(queued(try sbd.queueRemoval([dirty.id])) == [dirty.id])
    try sbd.waitForRemoval(dirty.id, "failed")
    try #require(try sbd.get(dirty.id).state == .needsYou)

    try sbd.sb("send", dirty.id, "keep going")

    try sbd.waitFor("\(dirty.id)'s failed removal to clear", timeout: 30) { try sbd.removal(dirty.id) == nil }
    let got = try #require(JSON.parse(try sbd.sb("get", "--json", dirty.id)))
    #expect(got["removal"] == nil || got["removal"] == .null, Comment(rawValue: got.text))
    #expect(got["state"]?.string != AttentionState.needsYou.rawValue, Comment(rawValue: got.text))
    #expect(try sbd.intact(dirty))
    #expect(FileManager.default.fileExists(atPath: "\(dirty.cwd)/notes.txt"))
  }

  /// The trash check fails, and the move back finds a folder at `cwd`, so the worktree's folder stays in the trash.
  /// The prompt must not clear the removal, because the purge would then delete the folder. sbd logs why it kept it.
  @Test func aPromptToASessionWhoseFolderIsInTheTrashKeepsTheRemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    let trash = sbd.trashFolder(a.id)
    try "late".write(toFile: "\(trash)/notes.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: a.cwd, withIntermediateDirectories: false)
    try sbd.release(holdTrashCheck)
    try sbd.waitForRemoval(a.id, "failed")
    let comebacks = try comebackEvents(sbd, a.id)
    let logBefore = (try? String(contentsOfFile: sbd.home.log, encoding: .utf8))?.count ?? 0

    try sbd.sb("send", a.id, "keep going")

    // sbd records the launch or the prompt and runs the drop's guard in the same step, so once the event is in the
    // log, the guard has decided.
    try sbd.waitFor("the send to launch or reach \(a.id)", timeout: 30) { try comebackEvents(sbd, a.id) > comebacks }
    #expect(try sbd.removalState(a.id) == "failed")
    #expect(FileManager.default.fileExists(atPath: "\(trash)/notes.txt"), "the folder left the trash")
    #expect(try sbd.get(a.id).reason.hasPrefix("Delete failed"))
    let log = String(((try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? "").dropFirst(logBefore))
    let kept = log.split(separator: "\n").filter { $0.contains(a.id) && $0.contains("trash") }
    #expect(!kept.isEmpty, Comment(rawValue: "sbd logged no line about keeping the removal:\n\(log)"))
  }

  // MARK: Launches refuse a session that is being deleted

  /// Each target's claude stopped with a deferred question and has a wait that resumes it, so each launching op
  /// would start claude. `terminals` and `shell` would start panes in a folder that the worker is about to delete.
  /// The first target runs at the gate and the second waits behind it.
  @Test(arguments: ["send", "resume", "open", "answer", "resolve-wait", "terminals", "shell"])
  func anOpOnAProcessIsRefusedForASessionWithAQueuedOrRunningRemoval(_ op: String) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let running = try sbd.stoppedSessionWithADeferredQuestion(repo, branch: "haacked/running")
    let waiting = try sbd.stoppedSessionWithADeferredQuestion(repo, branch: "haacked/queued")
    var waits: [String: String] = [:]
    for s in [running, waiting] {
      let set = try JSONCoding.decode(
        SessionSummary.self, from: sbd.sb("wait", "--json", s.id, "--kind", "merge", "--target", "1190"))
      waits[s.id] = try #require(set.waits.first?.id)
    }
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([running.id, waiting.id], scope: "work")) == [running.id, waiting.id])
    try sbd.waitForRemoval(running.id, "running")
    #expect(try sbd.removalState(waiting.id) == "queued")
    let before = [running.id: sbd.launches(running), waiting.id: sbd.launches(waiting)]

    for s in [running, waiting] {
      let session = JSON.string(s.id)
      let args: [String: JSON] =
        switch op {
        case "send": ["session": session, "text": "hello"]
        case "answer": ["session": session, "answers": .array([.string("cherry"), .string("red")])]
        case "resolve-wait": ["session": session, "wait": .string(waits[s.id]!), "outcome": "#1190 merged"]
        case "shell": ["session": session, "open": true]
        default: ["session": session]
        }
      let message = failure(sbd, op, args)
      #expect(message.contains("\(s.id) is being deleted"), Comment(rawValue: message))
    }

    sleep(1)
    for s in [running, waiting] {
      #expect(sbd.launches(s) == before[s.id], "claude started for \(s.id)")
      #expect(try sbd.get(s.id).live == false)
    }
  }

  /// The ops that the launch test above doesn't name. `send-group` reports the refusal per target.
  @Test func rmCleanupStopAndOtherOpsRefuseASessionWithAQueuedRemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let busy = try sbd.worktreeSession(repo, branch: "haacked/busy")
    let s = try sbd.worktreeSession(repo, branch: "haacked/target")
    let group = try JSONCoding.decode(GroupSummary.self, from: sbd.sb("group", "add", "--json", "Flags", s.id))
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([busy.id, s.id], scope: "work")) == [busy.id, s.id])
    try sbd.waitForRemoval(busy.id, "running")
    try #require(try sbd.removalState(s.id) == "queued")
    let refusal = "\(s.id) is being deleted"

    let rm = try sbd.run(["rm", s.id, "--worktree"])
    #expect(rm.status != 0)
    #expect(rm.stderr.contains(refusal), Comment(rawValue: rm.stderr))
    for (op, args) in [
      ("cleanup", ["session": JSON.string(s.id)]), ("stop", ["session": .string(s.id)]),
      ("dependency-resolved", ["session": .string(s.id), "message": "#1190 merged"]),
    ] as [(String, [String: JSON])] {
      let message = failure(sbd, op, args)
      #expect(message.contains(refusal), "\(op): \(message)")
    }
    let sent = try sbd.client.call(
      "send-group",
      [
        "group": .string(group.id), "text": "Rebase on main.", "confirmed": true,
        "targets": .array([.string(s.id)]),
      ], as: GroupSend.self)
    #expect(sent.deliveries?.first?.error?.contains(refusal) == true, "\(sent)")

    #expect(try sbd.removalState(s.id) == "queued")
    #expect(try sbd.intact(s))
    #expect(try sbd.events(s.id).allSatisfy { $0.data["text"] != "Rebase on main." })
  }

  @Test func accountMoveBlocksASessionWithAQueuedRemoval() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let s = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([s.id], scope: "work")) == [s.id])
    try sbd.waitForRemoval(s.id, "running")

    let result = try JSONCoding.decode(AccountMove.self, from: sbd.sb("account", "move", "--json", "B"))

    #expect(result.moved.isEmpty, "\(result)")
    let blocked = try #require(result.blocked.first { $0.session == s.id }, "\(result)")
    #expect(blocked.reason.contains("\(s.id) is being deleted"), Comment(rawValue: blocked.reason))
    #expect(try sbd.get(s.id).account == sbd.account("A"))
  }

  /// The sleep in a's folder holds rm in its pane stop, so rm still removes a when rm-queue arrives.
  @Test func rmQueueSkipsASessionThatRmIsRemoving() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let terminals = try sbd.client.terminals(a.id)
    let hold = try FolderHold(sbd, a.cwd)
    defer { hold.end() }
    let rm = try sbd.startRm(a.id)
    try sbd.waitFor("rm to close a's shell pane") { try !paneExists(terminals, terminals.shell) }

    let result = try sbd.queueRemoval([a.id], scope: "work")
    hold.end()
    let removed = try rm.finish(within: 60)

    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    let reason = try #require(skipped(result, a.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("is being deleted"), Comment(rawValue: reason))
    #expect(removed.status == 0, Comment(rawValue: removed.stderr))
    try sbd.waitUntilGone(a.id)
  }

  /// A second rm or a cleanup that fails must not clear the first rm's mark, or rm-queue would then queue the
  /// session while the first rm still removes it.
  @Test func rmAndCleanupAreRefusedForASessionThatRmIsRemoving() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let terminals = try sbd.client.terminals(a.id)
    let hold = try FolderHold(sbd, a.cwd)
    defer { hold.end() }
    let rm = try sbd.startRm(a.id)
    try sbd.waitFor("rm to close a's shell pane") { try !paneExists(terminals, terminals.shell) }

    let second = try sbd.run("rm", a.id, "--worktree")
    let cleanup = try sbd.run("cleanup", a.id)
    let result = try sbd.queueRemoval([a.id], scope: "work")
    hold.end()
    let removed = try rm.finish(within: 60)

    for r in [second, cleanup] {
      #expect(r.status != 0)
      #expect(r.stderr.contains("\(a.id) is being deleted"), Comment(rawValue: r.stderr))
    }
    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    #expect(removed.status == 0, Comment(rawValue: removed.stderr))
    try sbd.waitUntilGone(a.id)
  }

  /// A retry that queued the session while rm removes it would run the job's checks, pane stop, and worktree delete
  /// alongside rm's.
  @Test func rmRetryIsRefusedForASessionThatRmIsRemoving() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)
    let file = "\(a.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])
    try sbd.waitForRemoval(a.id, "failed")
    try FileManager.default.removeItem(atPath: file)
    let terminals = try sbd.client.terminals(a.id)
    let hold = try FolderHold(sbd, a.cwd)
    defer { hold.end() }
    let rm = try sbd.startRm(a.id)
    try sbd.waitFor("rm to close a's shell pane") { try !paneExists(terminals, terminals.shell) }

    let refusal = failure(sbd, "rm-retry", ["session": .string(a.id)])
    let state = try sbd.removalState(a.id)
    hold.end()
    let removed = try rm.finish(within: 60)

    #expect(refusal.contains("\(a.id) is being deleted"), Comment(rawValue: refusal))
    #expect(state == "failed")
    #expect(removed.status == 0, Comment(rawValue: removed.stderr))
    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try sbd.removalNotice(for: a.id) == nil)
  }

  /// The Inbox shows the job's error next to a Retry button, so a pane stop that fails in the job names retry, not
  /// a command.
  @Test func aPaneStopThatFailsInTheJobSaysToRetryTheDelete() throws {
    let sbd = try Instance(config: Instance.shortStopWait)
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)
    let hold = try FolderHold(sbd, a.cwd)
    defer { hold.end() }

    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.lowercased().contains("retry the delete"), Comment(rawValue: error))
    #expect(!error.contains("sb rm"), Comment(rawValue: error))
    #expect(FileManager.default.fileExists(atPath: a.cwd))
  }

  @Test func rmQueueSkipsASessionWhoseMergeRuns() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    let gate = "\(sbd.home.path)/gh-merge-gate"
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    let merge = Process()
    merge.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sb")
    merge.arguments = ["merge", s.id]
    merge.environment = sbd.environment()
    merge.standardOutput = FileHandle.nullDevice
    merge.standardError = FileHandle.nullDevice
    try merge.run()
    try sbd.waitFor("gh to start the merge") { sbd.ghMerges().count == 1 }

    let result = try sbd.queueRemoval([s.id], scope: "work")

    let writer = try #require(FileHandle(forWritingAtPath: gate))
    writer.write(Data("go\n".utf8))
    try writer.close()
    merge.waitUntilExit()
    #expect(queued(result).isEmpty, Comment(rawValue: result.text))
    let reason = try #require(skipped(result, s.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("is merging its PR"), Comment(rawValue: reason))
    #expect(try sbd.removal(s.id) == nil)
    #expect(merge.terminationStatus == 0)
  }

  /// The merge would send the session its post-merge message, which the removal refuses after gh already merged.
  @Test func mergeIsRefusedForASessionWithAQueuedRemoval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([s.id], scope: "work")) == [s.id])
    try sbd.waitForRemoval(s.id, "running")

    let r = try sbd.run(["merge", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(s.id) is being deleted"), Comment(rawValue: r.stderr))
    #expect(sbd.ghMerges().isEmpty)
  }

  @Test func sbSendToAQueuedSessionIsRefusedAndClaudeDoesNotStart() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let busy = try sbd.worktreeSession(repo, branch: "haacked/busy")
    let s = try sbd.worktreeSession(repo, branch: "haacked/target")
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop") { !$0.live }
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([busy.id, s.id], scope: "work")) == [busy.id, s.id])
    try sbd.waitForRemoval(busy.id, "running")
    try #require(try sbd.removalState(s.id) == "queued")
    let launches = sbd.launches(s)

    let r = try sbd.run(["send", s.id, "hello"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(s.id) is being deleted"), Comment(rawValue: r.stderr))
    sleep(1)
    #expect(sbd.launches(s) == launches)
    #expect(try sbd.get(s.id).live == false)
    #expect(try sbd.events(s.id).allSatisfy { $0.data["text"] != "hello" })
  }

  // MARK: Restarts

  /// a runs at the gate and b waits in `queued` when sbd dies. The restarted sbd resumes both.
  @Test func killingSbdWhileRemovalsAreQueuedAndRunningResumesThemAfterTheRestart() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    try sbd.markSessionDone(a.id)
    try sbd.markSessionDone(b.id)
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([a.id, b.id])) == [a.id, b.id])
    try sbd.waitForRemoval(a.id, "running")
    try #require(try sbd.removalState(b.id) == "queued")

    sbd.killSbd()
    try sbd.startSbd()

    #expect(try sbd.removal(a.id) != nil, "the restart dropped a's removal")
    #expect(try sbd.removal(b.id) != nil, "the restart dropped b's removal")
    try sbd.release(holdRemoval)
    try sbd.waitUntilGone(a.id, b.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
  }

  /// Only a queued or running removal resumes. The test deletes the file that failed the removal, so a load that
  /// resumed the failed removal would delete a session that the user never retried.
  @Test func aFailedRemovalStaysFailedAfterARestart() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    try sbd.markSessionDone(dirty.id)
    let file = "\(dirty.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    #expect(queued(try sbd.queueRemoval([dirty.id])) == [dirty.id])
    try sbd.waitForRemoval(dirty.id, "failed")
    try FileManager.default.removeItem(atPath: file)

    sbd.stopSbd()
    try sbd.startSbd()

    sleep(3)
    #expect(try sbd.removalState(dirty.id) == "failed")
    #expect(try sbd.intact(dirty))
    #expect(try sbd.get(dirty.id).state == .needsYou)
  }

  // MARK: Messages that wait for the turn to end

  /// The message waits behind the slow turn. The removal takes the session before the turn ends, so the delivery
  /// that the turn's Stop starts must skip the session.
  @Test func aQueuedMessageIsNotPastedIntoASessionThatIsBeingDeleted() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let started = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "haacked/slow", "prompt": "slow 4"], as: SessionSummary.self)
    let s = try sbd.waitFor(started.id, "the slow turn") { $0.state == .working }
    let text = "sent before the delete"
    try #require(try sbd.sb("send", s.id, text) == "queued\n")
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([s.id], scope: "work")) == [s.id])
    try sbd.waitForRemoval(s.id, "running")

    try sbd.waitFor("the slow turn's Stop", timeout: 20) { try sbd.count("Stop", of: s.id) >= 1 }

    sleep(2)
    let pasted = try sbd.events(s.id).filter {
      ($0.kind == "pasting" || $0.kind == "delivered") && $0.data["text"]?.string == text
    }
    #expect(pasted.isEmpty, Comment(rawValue: pasted.map(\.kind).joined(separator: ", ")))
  }
}
