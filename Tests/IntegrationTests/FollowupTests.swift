import Foundation
import SwitchboardCore
import Testing

func add(_ sbd: Instance, _ args: [String: JSON]) throws -> SessionSummary {
  try sbd.client.call("followup-add", args, as: SessionSummary.self)
}

/// The message of the error that a request fails with.
func failure(_ sbd: Instance, _ op: String, _ args: [String: JSON]) -> String {
  do {
    _ = try sbd.client.call(op, args)
    return "no error"
  } catch {
    return "\(error)"
  }
}

/// What a request on another thread returned.
final class Outcome<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<T, Error>?
  var result: Result<T, Error>? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
  let done = DispatchSemaphore(value: 0)

  /// Runs the body on a thread of its own, because the global queue gets no
  /// thread while the parallel tests block every thread of Swift's
  /// cooperative pool.
  static func detached(_ body: @escaping () throws -> T) -> Outcome<T> {
    let outcome = Outcome<T>()
    Thread.detachNewThread {
      outcome.result = Result { try body() }
      outcome.done.signal()
    }
    return outcome
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct FollowupTests {
  @Test func addsListsAndRemovesAFollowupThatNeverRuns() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    let out = try sbd.sb(
      [
        "followup", "add", "--json", "--repo", "acme/widgets", "--link", "https://x.dev/1",
        "Fix the cache. It reads twice.",
      ],
      env: ["SB_SESSION_ID": parent.id])
    let f = try JSONCoding.decode(SessionSummary.self, from: out)
    #expect(f.state == .notStarted)
    #expect(f.reason == "acme/widgets")
    #expect(f.name == "Fix the cache")
    #expect(f.cwd == "")
    #expect(f.parent == parent.id)
    #expect(f.followup?.prompt == "Fix the cache. It reads twice.")
    #expect(f.followup?.link == "https://x.dev/1")
    #expect(try sbd.events(f.id).map(\.kind) == ["followup"])

    let listed = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("followup", "ls", "--json"))
    #expect(listed.map(\.id) == [f.id])
    let all = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
    #expect(all.map(\.id) == [parent.id])
    let table = try sbd.sb("ls")
    #expect(!table.contains(f.id))
    #expect(table.contains("1 follow-up hasn't started"))
    #expect(try sbd.sb("get", f.id).contains("prompt:  Fix the cache. It reads twice."))

    // A refusal that waited for the missing pane to settle would take 5 s.
    for op in ["open", "send", "resume", "terminals"] {
      let asked = Date()
      #expect(failure(sbd, op, ["session": .string(f.id), "text": "hi"]).contains("hasn't started"))
      #expect(Date().timeIntervalSince(asked) < 5, "\(op)")
    }
    #expect(failure(sbd, "wait", ["session": .string(f.id), "kind": "manual"]).contains("hasn't started"))
    _ = try sbd.client.call("note", ["session": .string(f.id), "text": "Ask Ana first."])
    #expect(try sbd.sb("get", f.id).contains("Ask Ana first."))
    #expect(sbd.stubArgs().count == 1)
    #expect(failure(sbd, "followup-rm", ["session": .string(parent.id)]).contains("has started"))
    #expect(failure(sbd, "followup-start", ["session": .string(parent.id)]).contains("isn't a follow-up"))
    #expect(failure(sbd, "followup-add", ["prompt": "x", "parent": "nobody"]).contains("no session nobody"))
    try sbd.sb("followup", "rm", f.id)
    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty)
  }

  @Test func startsAFollowupInANewWorktreeWithItsPrompt() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try Instance(config: ["repoRoots": [.string(repos.root)], "branchPrefix": "haacked/"])
    let f = try add(sbd, ["prompt": "Fix the cache. It reads twice.", "repository": "acme/widgets"])
    let s = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("followup", "start", "--json", f.id))
    #expect(s.id == f.id)
    #expect(s.state != .notStarted)
    #expect(s.branch == "haacked/fix-the-cache")
    #expect(s.cwd == "\(sbd.home.path)/worktrees/widgets/haacked/fix-the-cache")
    #expect(s.repo?.hasSuffix("/acme/widgets") == true)
    let branch = try runCommand("/usr/bin/git", ["-C", s.cwd, "branch", "--show-current"])
    #expect(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "haacked/fix-the-cache")
    try sbd.waitFor(f.id, "the follow-up's first turn") { $0.lastReply == "Done: Fix the cache. It reads twice." }
    #expect(
      sbd.stubArgs()
        == [
          "--session-id \(f.claudeSessionId) --settings \(sbd.home.claudeSettings(f.id)) -- Fix the cache. It reads twice."
        ]
    )
    #expect(try sbd.events(f.id).prefix(3).map(\.kind) == ["followup", "followup-started", "started"])
    #expect(failure(sbd, "followup-start", ["session": .string(f.id)]).contains("isn't a follow-up"))

    // A branch made from a title is new work, so a start refuses one that exists.
    let same = try add(sbd, ["prompt": "Fix the cache. Again.", "repository": "acme/widgets"])
    #expect(
      failure(sbd, "followup-start", ["session": .string(same.id)]).contains("branch haacked/fix-the-cache exists"))
    #expect(try sbd.get(same.id).state == .notStarted)

    let named = try add(sbd, ["prompt": "Name it.", "repository": "acme/widgets", "branch": "feature/x"])
    let started = try sbd.client.call("followup-start", ["session": .string(named.id)], as: SessionSummary.self)
    #expect(started.branch == "feature/x")
    #expect(started.cwd == "\(sbd.home.path)/worktrees/widgets/feature/x")
  }

  @Test func refusesRequestsWithoutWaitingForASharedServerThatIsStarting() throws {
    let gate = try MCPGate()
    let sbd = try Instance(config: ["mcpServers": ["stuck": Instance.stubServer("stuck", gate: gate)]])
    let f = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets"])
    // A request waits up to 10 s for a starting server only when it can start claude.
    for op in ["open", "send", "resume", "terminals"] {
      let asked = Date()
      #expect(failure(sbd, op, ["session": .string(f.id), "text": "hi"]).contains("hasn't started"))
      #expect(Date().timeIntervalSince(asked) < 5, "\(op)")
    }
  }

  @Test func aStartWaitsForASharedServerThatIsStarting() throws {
    let repos = try Repos()
    let repo = try repos.make("acme/widgets")
    // sbd waits for the server for 10 s from the server's start. git can
    // take that long under load. The hook holds git until the test restarts
    // the server.
    let hold = try repos.holdCheckouts(in: repo)
    let gate = try MCPGate(open: true)
    let sbd = try Instance(config: [
      "repoRoots": [.string(repos.root)], "mcpServers": ["slow": Instance.stubServer("slow", gate: gate)],
    ])
    let slow = try sbd.waitForRunning("slow")
    let f = try add(sbd, ["prompt": "mcp slow", "repository": "acme/widgets"])
    let folder = "\(sbd.home.path)/worktrees/widgets/mcp-slow"
    let started = Outcome.detached { try Client(home: sbd.home).call("followup-start", ["session": .string(f.id)]) }
    // git makes the folder before it checks out the files. The test waits
    // for the hook instead of the folder.
    try sbd.waitFor("git to reach the post-checkout hook in \(folder)", timeout: 60) {
      if let result = started.result { _ = try result.get() }
      return FileManager.default.fileExists(atPath: hold + ".held")
    }
    let restarted = try sbd.restartServer(slow, behind: gate)
    try FileManager.default.removeItem(atPath: hold)
    _ = try gate.open(sbd, after: started)
    try sbd.waitFor(f.id, "the call to slow") { $0.lastReply == "MCP slow: slow \(restarted.pid!)" }
    #expect(try sbd.events(f.id).first { $0.kind == "started" }?.data["mcp"] == ["slow"])
  }

  @Test func leavesAFollowupAloneWhileItsWorktreeIsMade() throws {
    let repos = try Repos()
    let repo = try repos.make("acme/widgets")
    let hold = try repos.holdCheckouts(in: repo)
    let sbd = try Instance(config: ["repoRoots": [.string(repos.root)]])
    let f = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets", "on": "1h"])
    let folder = "\(sbd.home.path)/worktrees/widgets/fix-the-cache"
    let started = Outcome.detached {
      try Client(home: sbd.home).call("followup-start", ["session": .string(f.id)], as: SessionSummary.self)
    }
    // git is slow when many tests run it at once. A start that ends before
    // git makes the folder fails with its own error.
    try sbd.waitFor("git to make \(folder)", timeout: 60) {
      if let result = started.result { _ = try result.get() }
      return FileManager.default.fileExists(atPath: folder)
    }

    for op in ["followup-start", "followup-rm", "rm"] {
      let message = failure(sbd, op, ["session": .string(f.id)])
      #expect(message.contains("\(f.name) (\(f.id)) is starting"), "\(op): \(message)")
    }
    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).map(\.state) == [.notStarted])
    #expect(try sbd.client.sessions().isEmpty)
    // The trigger's time passes while git runs, and two ticks of 0.2 s leave it alone.
    try sbd.advanceClock(3_600_000)
    usleep(400_000)
    #expect(try sbd.events(f.id).map(\.kind) == ["followup"])

    try FileManager.default.removeItem(atPath: hold)
    #expect(started.done.wait(timeout: .now() + 30) == .success)
    #expect(try started.result?.get().cwd == folder)
    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty)
  }

  @Test func findsTheCheckoutAndRefusesOneWithAnotherRemote() throws {
    let repos = try Repos()
    let dotfiles = try repos.make("haacked/dotfiles", at: "\(repos.root)/elsewhere/.dotfiles")
    let other = try repos.make("acme/widgets", remote: "https://github.com/someone/else.git")
    let sbd = try Instance(config: [
      "repoRoots": [.string(repos.root)], "repos": ["haacked/dotfiles": .string(dotfiles)],
    ])
    let dot = try add(sbd, ["prompt": "Tidy the zshrc.", "repository": "haacked/dotfiles"])
    let started = try sbd.client.call("followup-start", ["session": .string(dot.id)], as: SessionSummary.self)
    #expect(started.cwd == "\(sbd.home.path)/worktrees/.dotfiles/tidy-the-zshrc")

    let widget = try add(sbd, ["prompt": "Fix it.", "repository": "acme/widgets"])
    #expect(
      failure(sbd, "followup-start", ["session": .string(widget.id)])
        .contains("has no remote on github.com for acme/widgets"))
    // A fork's upstream names the repository, not its origin.
    _ = try runCommand(
      "/usr/bin/git", ["-C", other, "remote", "add", "upstream", "https://github.com/acme/widgets.git"])
    #expect(try add(sbd, ["prompt": "From the fork.", "cwd": .string(other)]).followup?.repository == "acme/widgets")
    let missing = try add(sbd, ["prompt": "Fix it.", "repository": "nobody/nothing"])
    #expect(failure(sbd, "followup-start", ["session": .string(missing.id)]).contains("can't find a checkout"))
    let loose = try add(sbd, ["prompt": "Look into it."])
    #expect(failure(sbd, "followup-start", ["session": .string(loose.id)]).contains("Pass --path"))
    // --path is the user's choice, so its remote isn't checked.
    let s = try sbd.client.call(
      "followup-start", ["session": .string(loose.id), "path": .string(other), "branch": "b1"], as: SessionSummary.self)
    #expect(s.cwd == "\(sbd.home.path)/worktrees/widgets/b1")
    // An empty branch gets the title's branch, so the start still makes a worktree.
    let again = try add(sbd, ["prompt": "Look again.", "branch": ""])
    #expect(again.branch == nil)
    let slugged = try sbd.client.call(
      "followup-start", ["session": .string(again.id), "path": .string(other), "branch": ""], as: SessionSummary.self)
    #expect(slugged.cwd == "\(sbd.home.path)/worktrees/widgets/look-again")
    // A title with no ASCII letters makes no branch name, so the start
    // refuses rather than run in the checkout.
    let blank = try add(sbd, ["prompt": "…"])
    #expect(
      failure(sbd, "followup-start", ["session": .string(blank.id), "path": .string(other)])
        .contains("can't make a branch name"))
    #expect(try sbd.get(blank.id).state == .notStarted)

    // Without a repository, add takes the folder's GitHub remote and branch.
    let here = try add(sbd, ["prompt": "From a folder.", "cwd": .string(dotfiles)])
    #expect(here.followup?.repository == "haacked/dotfiles")
    #expect(here.followup?.sourceBranch == "main")
    #expect(try add(sbd, ["prompt": "Nowhere.", "cwd": .string(repos.root)]).followup?.repository == nil)
  }

  @Test func aDateTriggerMovesTheFollowupToNeedsYouWithoutStartingIt() throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Check the rollout.", "repository": "acme/widgets", "on": "1h"])
    #expect(f.state == .notStarted)
    #expect(f.reason.hasPrefix("acme/widgets · ready at "))
    let done = try add(sbd, ["prompt": "Check it again.", "on": "1h"])
    _ = try sbd.client.call("done", ["session": .string(done.id)])
    // A minute before the time, two ticks of 0.2 s leave the trigger alone.
    try sbd.advanceClock(3_540_000)
    usleep(400_000)
    #expect(try sbd.get(f.id).state == .notStarted)
    try sbd.advanceClock(60_000)
    let ready = try sbd.waitFor(f.id, "the trigger") { $0.state == .needsYou }
    #expect(try sbd.get(done.id).followup?.ready == nil)
    #expect(ready.reason.hasPrefix("ready to start: ") && ready.reason.hasSuffix(" passed"))
    #expect(ready.followup?.ready != nil)
    #expect(try sbd.events(f.id).map(\.kind) == ["followup", "followup-ready"])
    #expect(try sbd.client.sessions().map(\.id).sorted() == [done.id, f.id].sorted())
    #expect(sbd.stubArgs().isEmpty)
  }

  @Test func refusesTriggersThatCantFire() throws {
    let sbd = try Instance()
    #expect(failure(sbd, "followup-add", ["prompt": "x", "on": "2020-01-01"]).contains("has passed"))
    #expect(failure(sbd, "followup-add", ["prompt": "x", "on": "someday"]).contains("can't read the time"))
    #expect(failure(sbd, "followup-add", ["prompt": "x", "after": "#12"]).contains("can't read the PR"))
    #expect(failure(sbd, "followup-add", ["prompt": "x", "on": "1d", "after": "a/b#1"]).contains("not both"))
    #expect(failure(sbd, "followup-add", ["prompt": "x", "repository": "widgets"]).contains("Use owner/name"))
    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty)
  }

  @Test func refusesPrMergedAsAnUnknownRequest() throws {
    let sbd = try Instance()
    #expect(failure(sbd, "pr-merged", ["pr": "acme/widgets#12"]).contains("unknown request pr-merged"))
  }

  @Test func importsOpenItemsOnceAndKeepsThemAcrossARestart() throws {
    let notes = try Repos()
    let file = "\(notes.root)/Followups.md"
    let sbd = try Instance(config: ["followupsFile": .string(file)])
    let text = """
      # Followups

      ## Open

      - [ ] 2026-10-24 · [haacked/dotfiles · haacked/standup-archive-gate] Move the lookups into one script. More.
      - [x] 2026-10-22 · [PostHog/posthog · haacked/done] A closed item.
      - [ ] 2026-09-28 · [haacked/docket] Archived rows stay visible ([PR #21](https://github.com/haacked/docket/pull/21))
      - [ ] Should we have code protections on the flag service

      ## Archive

      - [ ] 2026-01-01 · [PostHog/posthog] Old.

      """
    try text.write(toFile: file, atomically: true, encoding: .utf8)
    let first = try JSONCoding.decode(JSON.self, from: try sbd.sb("followup", "import", "--json"))
    #expect(first["file"]?.string == file)
    #expect(first["imported"]?.array?.count == 3)
    #expect(first["skipped"]?.int == 0)
    #expect(try String(contentsOfFile: file, encoding: .utf8) == text)

    let listed = try sbd.client.call("followup-ls", as: [SessionSummary].self)
    #expect(
      listed.map(\.name) == [
        "Archived rows stay visible (PR #21)", "Move the lookups into one script",
        "Should we have code protections on the flag service",
      ])
    #expect(listed.map(\.reason) == ["haacked/docket", "haacked/dotfiles", "no repository"])
    #expect(listed[0].followup?.link == "https://github.com/haacked/docket/pull/21")
    #expect(listed[1].followup?.sourceBranch == "haacked/standup-archive-gate")
    #expect(listed[1].since == Wait.parseTime("2026-10-24", now: 0))
    #expect(
      try sbd.sb("followup", "import", "--file", file)
        == "Imported 0 follow-ups from \(file).\nSkipped 3 lines that an earlier import read.\n")

    // A removed follow-up stays skipped. A new line imports.
    try sbd.sb("followup", "rm", listed[0].id)
    let added = text.replacingOccurrences(
      of: "## Open\n\n", with: "## Open\n\n- [ ] 2026-10-26 · [acme/widgets] A new one.\n")
    try added.write(toFile: file, atomically: true, encoding: .utf8)
    let third = try JSONCoding.decode(JSON.self, from: try sbd.sb("followup", "import", "--json", "--file", file))
    #expect(third["imported"]?.array?.compactMap { $0["name"]?.string } == ["A new one"])
    #expect(third["skipped"]?.int == 3)

    let before = try sbd.client.call("followup-ls", as: [SessionSummary].self)
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.client.call("followup-ls", as: [SessionSummary].self)
    #expect(after == before)
    #expect(after.count == 3)
  }

  // MARK: To-dos

  private func followupIds(_ sbd: Instance) throws -> [String] {
    try sbd.client.call("followup-ls", as: [SessionSummary].self).map(\.id)
  }

  @Test func followupRmRefusesAnUnstartedFollowupThatHoldsAnOpenToDo() throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets"])
    let todo = try sbd.addTodo(f.id, "tell Alex in #flags that the fix shipped")
    // shortId never uses 0. Therefore n00000 names no note.
    let lists: [(String, JSON?)] = [
      ("no resolve", nil),
      ("an unknown id", ["n00000"]),
      ("the open id and an unknown id", [.string(todo.id), "n00000"]),
      ("a boolean", true),
    ]

    for (what, resolve) in lists {
      var args: [String: JSON] = ["session": .string(f.id)]
      args["resolve"] = resolve

      let message = failure(sbd, "followup-rm", args)

      #expect(message != "no error", "\(what)")
      #expect(try followupIds(sbd) == [f.id], "\(what)")
      #expect(try sbd.isOpenTodo(f.id, todo.id), "\(what)")
      #expect(try sbd.resolvedTodos().isEmpty, "\(what)")
    }
    let message = failure(sbd, "followup-rm", ["session": .string(f.id)])
    #expect(message.contains("has an open to-do"), Comment(rawValue: message))
    #expect(message.contains(todo.id), Comment(rawValue: message))
  }

  @Test func followupRmWithResolveRemovesTheFollowupAndKeepsTheRecord() throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets"])
    let todo = try sbd.addTodo(f.id, "tell Alex in #flags that the fix shipped")

    try sbd.sb("followup", "rm", f.id, "--resolve", todo.id)

    #expect(try followupIds(sbd).isEmpty)
    let rows = try sbd.resolvedTodos()
    #expect(rows.map { $0["note"]?.string } == [todo.id])
    #expect(rows.first?["session"]?.string == f.id)
    #expect(rows.first?["text"]?.string == todo.text)
    #expect(rows.first?["how"]?.string == "resolved and deleted the session")
  }

  /// `followup-rm` has no store check before `forgetSession`. The failed delete happens there. The follow-up
  /// stays in sbd, and its to-do stays open.
  @Test func followupRmThatTheStoreCannotDeleteKeepsTheFollowupAndItsToDo() throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets"])
    let todo = try sbd.addTodo(f.id, "tell Alex in #flags that the fix shipped")
    try sbd.block("DELETE", on: "sessions")

    let message = failure(sbd, "followup-rm", ["session": .string(f.id), "resolve": [.string(todo.id)]])

    #expect(message.contains("store is read-only"), Comment(rawValue: message))
    #expect(try followupIds(sbd) == [f.id])
    #expect(try sbd.isOpenTodo(f.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  @Test func followupRmResolveInsideClaudeCodeExitsWithAnError() throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets"])
    let todo = try sbd.addTodo(f.id, "tell Alex in #flags that the fix shipped")

    let r = try sbd.run(["followup", "rm", f.id, "--resolve", todo.id], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(try followupIds(sbd) == [f.id])
    #expect(try sbd.isOpenTodo(f.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }
}
