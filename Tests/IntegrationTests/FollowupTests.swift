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

@Suite(.timeLimit(.minutes(2))) struct FollowupTests {
  @Test func addsListsAndRemovesAFollowupThatNeverRuns() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    let out = try sbd.sb(
      ["followup", "add", "--json", "--repo", "acme/widgets", "--link", "https://x.dev/1", "Fix the cache. It reads twice."],
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

    let refused = Date()
    for op in ["open", "send", "resume", "terminals"] {
      #expect(failure(sbd, op, ["session": .string(f.id), "text": "hi"]).contains("hasn't started"))
    }
    #expect(Date().timeIntervalSince(refused) < 2)
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
        == ["--session-id \(f.claudeSessionId) --settings \(sbd.home.claudeSettings) -- Fix the cache. It reads twice."])
    #expect(try sbd.events(f.id).prefix(3).map(\.kind) == ["followup", "followup-started", "started"])
    #expect(failure(sbd, "followup-start", ["session": .string(f.id)]).contains("isn't a follow-up"))

    // A branch made from a title is new work, so a start refuses one that exists.
    let same = try add(sbd, ["prompt": "Fix the cache. Again.", "repository": "acme/widgets"])
    #expect(failure(sbd, "followup-start", ["session": .string(same.id)]).contains("branch haacked/fix-the-cache exists"))
    #expect(try sbd.get(same.id).state == .notStarted)
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
    try sbd.advanceClock(3_600_000)
    let ready = try sbd.waitFor(f.id, "the trigger") { $0.state == .needsYou }
    #expect(ready.reason.hasPrefix("ready to start: ") && ready.reason.hasSuffix(" passed"))
    #expect(ready.followup?.ready != nil)
    #expect(try sbd.events(f.id).map(\.kind) == ["followup", "followup-ready"])
    #expect(try sbd.client.sessions().map(\.id) == [f.id])
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

  @Test func aMergeTriggerFiresWhenThePollerReportsTheMerge() throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Retarget the stack.", "repository": "acme/widgets", "after": "#12"])
    #expect(f.reason == "acme/widgets · ready when acme/widgets#12 merges")
    #expect(try sbd.client.call("pr-merged", ["pr": "acme/widgets#13"], as: [SessionSummary].self).isEmpty)
    let fired = try sbd.client.call(
      "pr-merged", ["pr": "https://github.com/ACME/widgets/pull/12"], as: [SessionSummary].self)
    #expect(fired.map(\.id) == [f.id])
    #expect(fired.first?.reason == "ready to start: acme/widgets#12 merged")
    #expect(try sbd.client.call("pr-merged", ["pr": "acme/widgets#12"], as: [SessionSummary].self).isEmpty)
    #expect(try sbd.get(f.id).state == .needsYou)
  }

  @Test func importsOpenItemsOnceAndKeepsThemAcrossARestart() throws {
    let sbd = try Instance()
    let file = "\(sbd.home.path)/Followups.md"
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
    let first = try JSONCoding.decode(JSON.self, from: try sbd.sb("followup", "import", "--json", "--file", file))
    #expect(first["imported"]?.array?.count == 3)
    #expect(first["skipped"]?.int == 0)
    #expect(try String(contentsOfFile: file, encoding: .utf8) == text)

    let listed = try sbd.client.call("followup-ls", as: [SessionSummary].self)
    #expect(listed.map(\.name) == [
      "Archived rows stay visible (PR #21)", "Move the lookups into one script",
      "Should we have code protections on the flag service",
    ])
    #expect(listed.map(\.reason) == ["haacked/docket", "haacked/dotfiles", "no repository"])
    #expect(listed[0].followup?.link == "https://github.com/haacked/docket/pull/21")
    #expect(listed[1].followup?.sourceBranch == "haacked/standup-archive-gate")
    #expect(listed[1].since == Wait.parseTime("2026-10-24", now: 0))
    #expect(try sbd.sb("followup", "import", "--file", file) == "Imported 0 follow-ups from \(file).\nSkipped 3 lines that an earlier import read.\n")

    // A removed follow-up stays skipped. A new line imports.
    try sbd.sb("followup", "rm", listed[0].id)
    let added = text.replacingOccurrences(of: "## Open\n\n", with: "## Open\n\n- [ ] 2026-10-26 · [acme/widgets] A new one.\n")
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
}
