import Foundation
import SwitchboardCore
import Testing

/// `sb spawn` and the `spawn` request: a session in a new worktree of a repo
/// that `--repo` names, or a follow-up that waits to start there.
@Suite(.timeLimit(.minutes(2))) struct SpawnTests {
  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  func instance(_ repos: Repos, _ extra: [String: JSON] = [:]) throws -> Instance {
    try Instance(config: ["repoRoots": [.string(repos.root)]].merging(extra) { $1 })
  }

  func spawn(_ sbd: Instance, _ args: [String: JSON]) throws -> SessionSummary {
    try sbd.client.call("spawn", args, as: SessionSummary.self)
  }

  func spawnCLI(_ sbd: Instance, _ args: [String], env: [String: String] = [:]) throws -> SessionSummary {
    try JSONCoding.decode(SessionSummary.self, from: try sbd.sb(["spawn", "--json"] + args, env: env))
  }

  /// Runs `sb spawn --json` with `dir` as its working folder, which a
  /// relative --repo resolves against.
  func spawnCLI(_ sbd: Instance, from dir: String, _ args: [String]) throws -> SessionSummary {
    let r = try runCommand(
      "/bin/sh", ["-c", #"cd "$1" && shift && exec "$@""#, "sh", dir, "\(Instance.bin)/sb", "spawn", "--json"] + args,
      env: sbd.environment())
    guard r.status == 0 else { throw TestError(description: "sb spawn \(args) in \(dir) failed: \(r.stderr)") }
    return try JSONCoding.decode(SessionSummary.self, from: r.stdout)
  }

  func groups(_ sbd: Instance) throws -> GroupList {
    try JSONCoding.decode(GroupList.self, from: try sbd.sb("group", "ls", "--json"))
  }

  func group(_ sbd: Instance, _ name: String, _ sessions: String...) throws -> GroupSummary {
    try JSONCoding.decode(GroupSummary.self, from: try sbd.sb(["group", "add", "--json", name] + sessions))
  }

  /// The path with every symlink resolved, since /tmp is a link to /private/tmp.
  func real(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  func git(_ dir: String, _ args: String...) throws -> CommandResult {
    try runCommand("/usr/bin/git", ["-C", dir] + args)
  }

  func currentBranch(_ dir: String) throws -> String {
    try git(dir, "branch", "--show-current").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func branchExists(_ checkout: String, _ branch: String) throws -> Bool {
    try git(checkout, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)").status == 0
  }

  /// Every worktree of the checkout, the main one included, with symlinks resolved.
  func worktrees(of checkout: String) throws -> [String] {
    try git(checkout, "worktree", "list", "--porcelain").stdout.split(separator: "\n")
      .filter { $0.hasPrefix("worktree ") }.map { real(String($0.dropFirst("worktree ".count))) }
  }

  /// The folders under the instance's worktreeRoot.
  func worktreeFolders(_ sbd: Instance) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: "\(sbd.home.path)/worktrees")) ?? []
  }

  /// Checks that the session runs in a new worktree of the checkout on the branch.
  func expectWorktree(
    _ sbd: Instance, _ s: SessionSummary, of checkout: String, branch: String, folder: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    #expect(s.state != .notStarted, sourceLocation: sourceLocation)
    #expect(s.cwd == "\(sbd.home.path)/worktrees/\(folder)/\(branch)", sourceLocation: sourceLocation)
    #expect(s.branch == branch, sourceLocation: sourceLocation)
    #expect(real(s.repo ?? "") == real(checkout), sourceLocation: sourceLocation)
    #expect(try currentBranch(s.cwd) == branch, sourceLocation: sourceLocation)
    #expect(try worktrees(of: checkout).contains(real(s.cwd)), sourceLocation: sourceLocation)
  }

  /// Checks that a refused spawn left no session, follow-up, worktree, or claude behind.
  func expectNothingCreated(
    _ sbd: Instance, checkouts: [String] = [], sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    #expect(try sbd.client.sessions().isEmpty, sourceLocation: sourceLocation)
    #expect(
      try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty, sourceLocation: sourceLocation)
    #expect(sbd.stubArgs().isEmpty, sourceLocation: sourceLocation)
    for checkout in checkouts {
      #expect(try worktrees(of: checkout) == [real(checkout)], sourceLocation: sourceLocation)
    }
  }

  // MARK: A started spawn

  @Test func spawnStartsClaudeWithThePromptInANewWorktreeOnTheBranch() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos, ["branchPrefix": "haacked/"])

    let s = try spawnCLI(
      sbd, ["--repo", "acme/widgets", "--branch", "feature/x", "--prompt", "Fix the cache. It reads twice."])

    try expectWorktree(sbd, s, of: checkout, branch: "feature/x", folder: "widgets")
    #expect(s.name == "feature/x")
    #expect(s.followup == nil)
    #expect(s.parent == nil)
    try sbd.waitFor(s.id, "the first turn") { $0.lastReply == "Done: Fix the cache. It reads twice." }
    #expect(
      sbd.stubArgs()
        == ["--session-id \(s.claudeSessionId) --settings \(sbd.home.claudeSettings) -- Fix the cache. It reads twice."]
    )
  }

  @Test func theSpawnRequestStartsASessionWithTheGivenName() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)

    let s = try spawn(
      sbd, ["repository": "acme/widgets", "branch": "b1", "prompt": "Rename the flag.", "name": "worker"])

    try expectWorktree(sbd, s, of: checkout, branch: "b1", folder: "widgets")
    #expect(s.name == "worker")
    try sbd.waitFor(s.id, "the first turn") { $0.lastReply == "Done: Rename the flag." }
  }

  // MARK: Inside a session

  @Test func spawnInsideAGroupedSessionRecordsTheParentAndJoinsItsGroup() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(repos)
    let parent = try sbd.new(name: "parent")
    let g = try group(sbd, "Flags", parent.id)

    let kid = try spawnCLI(
      sbd, ["--repo", "acme/widgets", "--branch", "kid", "--prompt", "Write the tests."], env: inside(parent.id))

    #expect(kid.parent == parent.id)
    #expect(kid.group == g.id)
    #expect(Set(try groups(sbd).groups.first?.sessions ?? []) == [parent.id, kid.id])
  }

  @Test func theSpawnRequestWithAParentJoinsItsGroup() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(repos)
    let parent = try sbd.new(name: "parent")
    let g = try group(sbd, "Flags", parent.id)

    let kid = try spawn(
      sbd, ["repository": "acme/widgets", "branch": "kid", "prompt": "Write the tests.", "parent": .string(parent.id)])

    #expect(kid.parent == parent.id)
    #expect(kid.group == g.id)
  }

  @Test func followupSpawnInsideAGroupedSessionRecordsTheParentAndJoinsItsGroup() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(repos)
    let parent = try sbd.new(name: "parent")
    let g = try group(sbd, "Flags", parent.id)

    let f = try spawnCLI(
      sbd, ["--repo", "acme/widgets", "--branch", "later", "--prompt", "Clean up.", "--followup"],
      env: inside(parent.id))

    #expect(f.state == .notStarted)
    #expect(f.parent == parent.id)
    #expect(f.group == g.id)
  }

  @Test func spawnTypedInTheShellPaneOfASessionRecordsNoParent() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(repos)
    let parent = try sbd.new(name: "parent")
    _ = try group(sbd, "Flags", parent.id)

    let typed = try spawnCLI(
      sbd, ["--repo", "acme/widgets", "--branch", "typed", "--prompt", "Look around."],
      env: ["SB_SESSION_ID": parent.id])

    #expect(typed.parent == nil)
    #expect(typed.group == nil)
  }

  // MARK: --followup

  @Test func followupSpawnWaitsUnstartedWithoutAWorktreeUntilItStarts() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos, ["branchPrefix": "haacked/"])

    let f = try spawnCLI(
      sbd,
      [
        "--repo", "acme/widgets", "--branch", "feature/later", "--prompt", "Fix the cache. It reads twice.",
        "--followup",
      ])

    #expect(f.state == .notStarted)
    #expect(f.cwd == "")
    #expect(f.name == "Fix the cache")
    #expect(f.branch == "feature/later")
    #expect(f.followup?.repository == "acme/widgets")
    #expect(f.followup?.prompt == "Fix the cache. It reads twice.")
    #expect(f.followup?.trigger.kind == .manual)
    #expect(try worktrees(of: checkout) == [real(checkout)])
    #expect(try !branchExists(checkout, "feature/later"))
    #expect(worktreeFolders(sbd).isEmpty)
    #expect(sbd.stubArgs().isEmpty)
    #expect(try sbd.events(f.id).map(\.kind) == ["followup"])

    let s = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("followup", "start", "--json", f.id))

    #expect(s.id == f.id)
    try expectWorktree(sbd, s, of: checkout, branch: "feature/later", folder: "widgets")
    try sbd.waitFor(f.id, "the follow-up's first turn") { $0.lastReply == "Done: Fix the cache. It reads twice." }
  }

  /// The command and the request make the same follow-up.
  @Test func theFollowupSpawnRequestMatchesTheCommand() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(repos)

    let byCommand = try spawnCLI(
      sbd, ["--repo", "acme/widgets", "--branch", "one", "--prompt", "Tidy the docs.", "--followup"])
    let byRequest = try spawn(
      sbd, ["repository": "acme/widgets", "branch": "two", "prompt": "Tidy the docs.", "followup": true])

    #expect(byRequest.state == byCommand.state)
    #expect(byRequest.cwd == byCommand.cwd)
    #expect(byRequest.name == byCommand.name)
    #expect(byRequest.reason == byCommand.reason)
    #expect(byRequest.followup?.repository == byCommand.followup?.repository)
    #expect(byRequest.followup?.prompt == byCommand.followup?.prompt)
    #expect(byRequest.followup?.trigger == byCommand.followup?.trigger)
    #expect(byRequest.branch == "two")
  }

  // MARK: --after

  @Test(arguments: ["pr:12", "#12", "acme/widgets#12", "https://github.com/acme/widgets/pull/12"])
  func followupAfterAPRWaitsForThatPRToMerge(after: String) throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(repos)

    let f = try spawn(
      sbd,
      [
        "repository": "acme/widgets", "branch": "retarget", "prompt": "Retarget the stack.", "followup": true,
        "after": .string(after),
      ])

    #expect(f.followup?.trigger.kind == .merge)
    #expect(f.followup?.trigger.pr == Wait.PullRequest(repository: "acme/widgets", number: 12))
    #expect(f.reason == "acme/widgets · ready when acme/widgets#12 merges")
  }

  /// `pr:<N>` names a PR in the repo that --repo resolved to, whatever form it took.
  @Test func prAfterABareNameOrAPathNamesThePRInTheResolvedRepo() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)

    for (branch, repository) in [("by-name", "widgets"), ("by-path", checkout)] {
      let f = try spawn(
        sbd,
        [
          "repository": .string(repository), "branch": .string(branch), "prompt": "Retarget.", "followup": true,
          "after": "pr:12",
        ])
      #expect(f.followup?.trigger.pr == Wait.PullRequest(repository: "acme/widgets", number: 12), "\(repository)")
    }
  }

  @Test func followupAfterAPRBecomesReadyWhenThePollSeesThePRMerge() throws {
    let github = try FakeGitHub()
    let repos = try Repos()
    try repos.make("PostHog/posthog")
    let sbd = try instance(
      repos,
      [
        "github": [
          "gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url), "pollSeconds": 0,
        ],
        "tickSeconds": 1,
      ])
    let f = try spawnCLI(
      sbd,
      [
        "--repo", "PostHog/posthog", "--branch", "haacked/clean-up", "--prompt", "Clean up.", "--followup", "--after",
        "pr:122953",
      ])
    #expect(f.followup?.trigger.pr == Wait.PullRequest(repository: "PostHog/posthog", number: 122953))

    try sbd.poll()
    #expect(try sbd.get(f.id).state == .notStarted)
    github.change(122953) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
    }
    try sbd.poll()

    let ready = try sbd.get(f.id)
    #expect(ready.state == .needsYou)
    #expect(ready.reason == "ready to start: PostHog/posthog#122953 merged")
    #expect(ready.followup?.ready != nil)
    #expect(ready.cwd == "")
    #expect(try sbd.events(f.id).filter { $0.kind == "followup-ready" }.count == 1)
    #expect(sbd.stubArgs().isEmpty)
  }

  // MARK: Refusals

  @Test(arguments: [("nobody/nothing", false), ("nobody/nothing", true), ("nothing", false), ("nothing", true)])
  func refusesAnUnknownRepo(repository: String, followup: Bool) throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)
    var args: [String: JSON] = ["repository": .string(repository), "branch": "b1", "prompt": "Go."]
    if followup { args["followup"] = true }

    #expect(failure(sbd, "spawn", args).contains(repository))
    let r = try sbd.run(
      ["spawn", "--json", "--repo", repository, "--branch", "b1", "--prompt", "Go."] + (followup ? ["--followup"] : []))
    #expect(r.status != 0)
    #expect(r.stderr.contains(repository))

    try expectNothingCreated(sbd, checkouts: [checkout])
    #expect(worktreeFolders(sbd).isEmpty)
  }

  @Test(arguments: [false, true])
  func refusesAPathThatIsNotACheckout(followup: Bool) throws {
    let repos = try Repos()
    let plain = "\(repos.root)/plain-folder"
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    let sbd = try instance(repos)

    for path in [plain, "\(repos.root)/missing-folder"] {
      var args: [String: JSON] = ["repository": .string(path), "branch": "b1", "prompt": "Go."]
      if followup { args["followup"] = true }
      let message = failure(sbd, "spawn", args)
      #expect(message != "no error", "\(path)")
      #expect(message.contains((path as NSString).lastPathComponent), "\(path)")
    }

    try expectNothingCreated(sbd)
    #expect(worktreeFolders(sbd).isEmpty)
  }

  @Test(arguments: [false, true])
  func refusesABareNameThatMatchesTwoReposUnderTheRoots(followup: Bool) throws {
    let repos = try Repos()
    let acme = try repos.make("acme/widgets")
    let other = try repos.make("other/widgets")
    let sbd = try instance(repos)
    var args: [String: JSON] = ["repository": "widgets", "branch": "b1", "prompt": "Go."]
    if followup { args["followup"] = true }

    let message = failure(sbd, "spawn", args)
    #expect(message.contains("acme/widgets"))
    #expect(message.contains("other/widgets"))
    let r = try sbd.run(
      ["spawn", "--json", "--repo", "widgets", "--branch", "b1", "--prompt", "Go."] + (followup ? ["--followup"] : []))
    #expect(r.status != 0)
    #expect(r.stderr.contains("acme/widgets") && r.stderr.contains("other/widgets"))

    try expectNothingCreated(sbd, checkouts: [acme, other])
    #expect(worktreeFolders(sbd).isEmpty)
  }

  @Test func refusesABareNameThatMatchesAReposKeyAndAFolderUnderTheRoots() throws {
    let repos = try Repos()
    let elsewhere = try Repos()
    let acme = try repos.make("acme/widgets")
    let mine = try elsewhere.make("haacked/widgets")
    let sbd = try instance(repos, ["repos": ["haacked/widgets": .string(mine)]])

    let message = failure(sbd, "spawn", ["repository": "widgets", "branch": "b1", "prompt": "Go."])

    #expect(message.contains("acme/widgets"))
    #expect(message.contains("haacked/widgets"))
    try expectNothingCreated(sbd, checkouts: [acme, mine])
  }

  enum Taken: String, CaseIterable {
    /// The branch exists in the checkout.
    case branch
    /// The folder that the branch's worktree would use exists.
    case folder
  }

  @Test(arguments: Taken.allCases, [false, true])
  func refusesATakenBranch(taken: Taken, followup: Bool) throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)
    switch taken {
    case .branch:
      #expect(try git(checkout, "branch", "taken-branch").status == 0)
    case .folder:
      try FileManager.default.createDirectory(
        atPath: "\(sbd.home.path)/worktrees/widgets/taken-branch", withIntermediateDirectories: true)
    }
    var args: [String: JSON] = ["repository": "acme/widgets", "branch": "taken-branch", "prompt": "Go."]
    if followup { args["followup"] = true }

    #expect(failure(sbd, "spawn", args).contains("taken-branch"))
    let r = try sbd.run(
      ["spawn", "--json", "--repo", "acme/widgets", "--branch", "taken-branch", "--prompt", "Go."]
        + (followup ? ["--followup"] : []))
    #expect(r.status != 0)
    #expect(r.stderr.contains("taken-branch"))

    try expectNothingCreated(sbd, checkouts: [checkout])
  }

  @Test func refusesAfterWithoutFollowup() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)

    let message = failure(
      sbd, "spawn", ["repository": "acme/widgets", "branch": "b1", "prompt": "Go.", "after": "pr:12"])
    #expect(message.contains("--after needs --followup"))
    let r = try sbd.run(
      ["spawn", "--json", "--repo", "acme/widgets", "--branch", "b1", "--prompt", "Go.", "--after", "pr:12"])
    #expect(r.status != 0)
    #expect(r.stderr.contains("--after needs --followup"))

    try expectNothingCreated(sbd, checkouts: [checkout])
    #expect(try !branchExists(checkout, "b1"))
  }

  @Test func refusesBaseWithFollowup() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)

    let message = failure(
      sbd, "spawn",
      ["repository": "acme/widgets", "branch": "b1", "prompt": "Go.", "followup": true, "base": "origin/release"])
    #expect(message.contains("--base needs a started spawn"))
    let r = try sbd.run(
      [
        "spawn", "--json", "--repo", "acme/widgets", "--branch", "b1", "--prompt", "Go.", "--followup", "--base",
        "main",
      ])
    #expect(r.status != 0)
    #expect(r.stderr.contains("--base needs a started spawn"))

    try expectNothingCreated(sbd, checkouts: [checkout])
  }

  @Test func followupSpawnKeepsItsNameModelAndAccount() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try Instance(
      accounts: ["A", "B"], inheriting: .unset, config: ["repoRoots": [.string(repos.root)]])
    try sbd.sb("account", "use", "A")

    let f = try spawnCLI(
      sbd,
      [
        "--repo", "acme/widgets", "--branch", "b1", "--prompt", "Go.", "--followup", "--name", "worker", "--model",
        "sonnet", "--account", "B",
      ])

    #expect(f.name == "worker")
    #expect(f.account == sbd.account("B"))
    let s = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("followup", "start", "--json", f.id))
    try expectWorktree(sbd, s, of: checkout, branch: "b1", folder: "widgets")
    try sbd.waitFor(f.id, "the follow-up's first turn") { $0.lastReply == "Done: Go." }
    let launch = sbd.stubCalls().last { !$0.args.hasPrefix("agents") }
    #expect(launch?.args.contains("--model sonnet") == true)
    #expect(launch?.account == sbd.account("B"))
  }

  /// The request's fields, without the one that the case leaves out or empties.
  enum Missing: String, CaseIterable {
    case noPrompt, emptyPrompt, blankPrompt, noBranch, emptyBranch

    var field: String { rawValue.lowercased().hasSuffix("prompt") ? "prompt" : "branch" }

    var args: [String: JSON] {
      var args: [String: JSON] = ["repository": "acme/widgets", "branch": "b1", "prompt": "Go."]
      switch self {
      case .noPrompt: args["prompt"] = nil
      case .emptyPrompt: args["prompt"] = ""
      case .blankPrompt: args["prompt"] = "   \n"
      case .noBranch: args["branch"] = nil
      case .emptyBranch: args["branch"] = ""
      }
      return args
    }
  }

  @Test(arguments: Missing.allCases, [false, true])
  func refusesAMissingPromptOrBranch(missing: Missing, followup: Bool) throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)
    var args = missing.args
    if followup { args["followup"] = true }

    #expect(failure(sbd, "spawn", args).contains(missing.field))

    try expectNothingCreated(sbd, checkouts: [checkout])
  }

  @Test(arguments: ["--prompt", "--branch"])
  func theCommandRefusesAMissingPromptOrBranch(flag: String) throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(repos)
    var args = ["spawn", "--json", "--repo", "acme/widgets", "--branch", "b1", "--prompt", "Go."]
    let at = try #require(args.firstIndex(of: flag))
    args.removeSubrange(at...(at + 1))

    let r = try sbd.run(args)

    #expect(r.status != 0)
    #expect(r.stderr.contains(String(flag.dropFirst(2))))
    try expectNothingCreated(sbd, checkouts: [checkout])
  }

  /// A follow-up stores only owner/name. It needs a checkout whose remote is on github.com.
  @Test func followupRefusesAPathWithoutAGitHubRemoteButAStartedSpawnRunsThere() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets", remote: "https://gitlab.com/acme/widgets.git")
    let sbd = try instance(repos)

    let message = failure(
      sbd, "spawn", ["repository": .string(checkout), "branch": "b1", "prompt": "Go.", "followup": true])

    #expect(message.contains("github.com"))
    try expectNothingCreated(sbd, checkouts: [checkout])

    let s = try spawn(sbd, ["repository": .string(checkout), "branch": "b2", "prompt": "Go."])

    try expectWorktree(sbd, s, of: checkout, branch: "b2", folder: "widgets")
  }

  // MARK: Resolving --repo

  @Test func aBareNameThatMatchesOneRepoUnderTheRootsResolvesToIt() throws {
    let repos = try Repos()
    let widgets = try repos.make("acme/widgets")
    try repos.make("acme/gadgets")
    let sbd = try instance(repos)

    let s = try spawnCLI(sbd, ["--repo", "widgets", "--branch", "b1", "--prompt", "Go."])
    try expectWorktree(sbd, s, of: widgets, branch: "b1", folder: "widgets")

    let f = try spawn(sbd, ["repository": "widgets", "branch": "b2", "prompt": "Later.", "followup": true])
    #expect(f.followup?.repository == "acme/widgets")
  }

  @Test func aBareNameMatchesAReposKeyWithoutRegardToCase() throws {
    let repos = try Repos()
    let dotfiles = try repos.make("haacked/dotfiles", at: "\(repos.root)/elsewhere/.dotfiles")
    let sbd = try instance(repos, ["repos": ["haacked/dotfiles": .string(dotfiles)]])

    let s = try spawn(sbd, ["repository": "DOTFILES", "branch": "b1", "prompt": "Tidy the zshrc."])
    try expectWorktree(sbd, s, of: dotfiles, branch: "b1", folder: ".dotfiles")

    let f = try spawn(sbd, ["repository": "dotfiles", "branch": "b2", "prompt": "Later.", "followup": true])
    #expect(f.followup?.repository == "haacked/dotfiles")
  }

  /// A repos key and a folder under the roots that differ only in case are one repository.
  @Test func aBareNameWhoseReposKeyNamesAFolderUnderTheRootsResolvesToIt() throws {
    let repos = try Repos()
    let checkout = try repos.make("PostHog/posthog")
    let sbd = try instance(repos, ["repos": ["posthog/posthog": .string(checkout)]])

    let s = try spawn(sbd, ["repository": "posthog", "branch": "b1", "prompt": "Go."])
    try expectWorktree(sbd, s, of: checkout, branch: "b1", folder: "posthog")
  }

  @Test func aBareNameSkipsAFolderUnderTheRootsWithoutAMatchingRemote() throws {
    let repos = try Repos()
    let acme = try repos.make("acme/widgets")
    let other = try repos.make("other/widgets", remote: "https://gitlab.com/other/widgets.git")
    let sbd = try instance(repos)

    let s = try spawn(sbd, ["repository": "widgets", "branch": "b1", "prompt": "Go."])
    try expectWorktree(sbd, s, of: acme, branch: "b1", folder: "widgets")
    #expect(try worktrees(of: other) == [real(other)])
  }

  @Test func anAbsolutePathResolvesToTheTopFolderOfItsCheckout() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sub = "\(checkout)/Sources/Deep"
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
    let sbd = try instance(repos)

    let byRequest = try spawn(sbd, ["repository": .string(checkout), "branch": "b1", "prompt": "Go."])
    try expectWorktree(sbd, byRequest, of: checkout, branch: "b1", folder: "widgets")

    let fromSub = try spawn(sbd, ["repository": .string(sub), "branch": "b2", "prompt": "Go."])
    try expectWorktree(sbd, fromSub, of: checkout, branch: "b2", folder: "widgets")

    let byCommand = try spawnCLI(sbd, ["--repo", checkout, "--branch", "b3", "--prompt", "Go."])
    try expectWorktree(sbd, byCommand, of: checkout, branch: "b3", folder: "widgets")
  }

  @Test func aFollowupFromAPathTakesTheRepositoryOfItsUpstreamElseItsOrigin() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let fork = try repos.make("haacked/widgets")
    #expect(try git(fork, "remote", "add", "upstream", "https://github.com/acme/widgets.git").status == 0)
    let sbd = try instance(repos)

    let fromOrigin = try spawn(
      sbd, ["repository": .string(checkout), "branch": "b1", "prompt": "Later.", "followup": true])
    let fromUpstream = try spawn(
      sbd, ["repository": .string(fork), "branch": "b2", "prompt": "Later.", "followup": true])

    #expect(fromOrigin.followup?.repository == "acme/widgets")
    #expect(fromUpstream.followup?.repository == "acme/widgets")
  }

  @Test func aRelativePathResolvesAgainstTheCommandsFolder() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sub = "\(checkout)/Sources"
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
    let sbd = try instance(repos)

    let fromRoot = try spawnCLI(
      sbd, from: repos.root, ["--repo", "./acme/widgets", "--branch", "b1", "--prompt", "Go."])
    try expectWorktree(sbd, fromRoot, of: checkout, branch: "b1", folder: "widgets")

    let fromCheckout = try spawnCLI(sbd, from: checkout, ["--repo", ".", "--branch", "b2", "--prompt", "Go."])
    try expectWorktree(sbd, fromCheckout, of: checkout, branch: "b2", folder: "widgets")

    let fromSub = try spawnCLI(sbd, from: sub, ["--repo", "..", "--branch", "b3", "--prompt", "Go."])
    try expectWorktree(sbd, fromSub, of: checkout, branch: "b3", folder: "widgets")
  }
}
