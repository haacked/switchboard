import Foundation
import SwitchboardCore
import Testing

private let widgetsOrigin = "https://github.com/acme/widgets.git"

/// The line's fields, with each run of spaces as one separator.
private func fields(_ line: Substring) -> [String] {
  line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
}

@Suite(.blocking(timeLimit: .seconds(120))) struct RepoListTests {
  private func new(_ sbd: Instance, _ path: String, _ name: String, branch: String? = nil) throws -> SessionSummary {
    var args: [String: JSON] = ["path": .string(path), "name": .string(name)]
    if let branch { args["branch"] = .string(branch) }
    return try sbd.client.call("new", args, as: SessionSummary.self)
  }

  private func list(_ sbd: Instance) throws -> [KnownRepo] {
    try JSONCoding.decode([KnownRepo].self, from: try sbd.sb("repo", "ls", "--json"))
  }

  private func add(_ sbd: Instance, _ path: String, env: [String: String] = [:]) throws -> KnownRepo {
    try JSONCoding.decode(KnownRepo.self, from: try sbd.sb(["repo", "add", path, "--json"], env: env))
  }

  private func refusedAdd(_ sbd: Instance, _ path: String) throws -> CommandResult {
    try sbd.run(["repo", "add", path, "--json"])
  }

  private func folder(_ sbd: Instance, _ name: String) throws -> String {
    let path = "\(sbd.home.path)/\(name)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func commit(_ sbd: Instance, _ dir: String) throws {
    try sbd.git(
      dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty",
      "-m", "first")
  }

  // MARK: Derivation

  @Test func listsTheRepoOfEachSessionInGit() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha")
    let widgets = try Repos.create("\(sbd.home.path)/widgets", origin: widgetsOrigin)
    _ = try new(sbd, alpha, "a")
    _ = try new(sbd, widgets, "w")

    let repos = try list(sbd)

    #expect(Set(repos.map(\.path)) == [real(alpha), real(widgets)])
    #expect(repos.count == 2)
    #expect(repos.first { $0.path == real(alpha) }?.name == "alpha")
    #expect(repos.first { $0.path == real(widgets) }?.name == "acme/widgets")
    #expect(repos.allSatisfy { $0.used != nil })
    #expect(try sbd.client.call("repos", as: [KnownRepo].self) == repos)
  }

  @Test func leavesOutASessionInAFolderOutsideGit() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha")
    _ = try new(sbd, sbd.work, "plain")
    _ = try new(sbd, alpha, "a")

    let repos = try list(sbd)

    #expect(repos.map(\.path) == [real(alpha)])
  }

  @Test func listsARepoFromTheReposSetting() throws {
    let checkouts = try Repos()
    let widgets = try checkouts.make("acme/widgets", at: "\(checkouts.root)/mine")
    let sbd = try Instance(config: ["repos": ["acme/widgets": .string(widgets)]])

    let repos = try list(sbd)

    #expect(repos == [KnownRepo(path: real(widgets), name: "acme/widgets", used: nil)])
  }

  @Test func keepsARepoAfterItsSessionIsRemoved() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha")
    let s = try new(sbd, alpha, "a")
    let before = try list(sbd)

    try sbd.sb("rm", s.id)

    #expect(try sbd.client.sessions().isEmpty)
    #expect(before.map(\.path) == [real(alpha)])
    #expect(try list(sbd) == before)
  }

  @Test func keepsARepoAfterItsWorktreeSessionIsRemoved() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let s = try new(sbd, beta, "b", branch: "feat-b")
    let before = try list(sbd)

    try sbd.sb("rm", s.id)

    #expect(try sbd.client.sessions().isEmpty)
    #expect(before.map(\.path) == [real(beta)])
    #expect(try list(sbd) == before)
  }

  @Test func keepsARepoAfterItsFollowupSessionIsRemoved() throws {
    let repos = try Repos()
    let widgets = try repos.make("acme/widgets")
    let sbd = try Instance(config: ["repoRoots": [.string(repos.root)], "branchPrefix": "haacked/"])
    let f = try sbd.client.call(
      "followup-add", ["prompt": "Fix the cache.", "repository": "acme/widgets"], as: SessionSummary.self)
    _ = try sbd.client.call("followup-start", ["session": .string(f.id)], as: SessionSummary.self)

    try sbd.sb("rm", f.id)

    #expect(try sbd.client.sessions().isEmpty)
    #expect(try list(sbd).map(\.path) == [real(widgets)])
  }

  // MARK: Most recently used ordering

  @Test func listsTheRepoOfTheNewestSessionFirst() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha")
    let beta = try sbd.makeRepo("beta")
    _ = try new(sbd, alpha, "a1")
    try sbd.advanceClock(60_000)
    _ = try new(sbd, beta, "b")

    let afterBeta = try list(sbd)
    try sbd.advanceClock(60_000)
    _ = try new(sbd, alpha, "a2")
    let afterAlpha = try list(sbd)

    #expect(afterBeta.map(\.path) == [real(beta), real(alpha)])
    #expect(afterAlpha.map(\.path) == [real(alpha), real(beta)])
  }

  @Test func addingARepoMovesItToTheFront() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha")
    let beta = try sbd.makeRepo("beta")
    _ = try new(sbd, alpha, "a")
    try sbd.advanceClock(60_000)
    _ = try new(sbd, beta, "b")
    try sbd.advanceClock(60_000)
    let before = try list(sbd)

    let added = try add(sbd, alpha)

    let after = try list(sbd)
    #expect(before.map(\.path) == [real(beta), real(alpha)])
    #expect(after.map(\.path) == [real(alpha), real(beta)])
    #expect(after.first == added)
    #expect(try #require(added.used) > (try #require(before.first?.used)))
  }

  @Test func listsAReposSettingEntryAfterUsedRepos() throws {
    let checkouts = try Repos()
    let configured = try checkouts.make("acme/aaa")
    let sbd = try Instance(config: ["repos": ["acme/aaa": .string(configured)]])
    let used = try sbd.makeRepo("zzz")
    _ = try new(sbd, used, "z")

    let repos = try list(sbd)

    #expect(repos.map(\.path) == [real(used), real(configured)])
    #expect(repos.map(\.name) == ["zzz", "acme/aaa"])
    #expect(repos.last?.used == nil)
  }

  // MARK: Dedupe of worktrees to the main repo

  @Test func listsOneEntryForSessionsInTheMainCheckoutAndItsWorktrees() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let tree = try sbd.addWorktree(beta, "feat-b")
    _ = try new(sbd, beta, "made", branch: "feat-b2")
    let external = try new(sbd, tree, "external")
    let main = try new(sbd, beta, "main")
    _ = try sbd.waitFor("the checkouts", fetch: { try sbd.client.sessions() }) { all in
      all.allSatisfy { ![external.id, main.id].contains($0.id) || $0.checkout != nil }
    }

    let repos = try list(sbd)

    #expect(repos.map(\.path) == [real(beta)])
    #expect(repos.map(\.name) == ["beta"])
  }

  @Test func addingAWorktreeAfterItsMainCheckoutAddsNoEntry() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let tree = try sbd.addWorktree(beta, "feat-b")
    let first = try add(sbd, beta)

    let second = try add(sbd, tree)

    #expect(second.path == first.path)
    #expect(try list(sbd).map(\.path) == [real(beta)])
  }

  // MARK: Add and validate

  @Test func addAcceptsAGitRepo() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let widgets = try Repos.create("\(sbd.home.path)/widgets", origin: widgetsOrigin)
    let before = try sbd.now()

    let added = try add(sbd, beta)
    let named = try sbd.client.call("repo-add", ["path": .string(widgets)], as: KnownRepo.self)

    let after = try sbd.now()
    #expect(added.path == real(beta))
    #expect(added.name == "beta")
    #expect((before...after).contains(try #require(added.used)))
    #expect(named.path == real(widgets))
    #expect(named.name == "acme/widgets")
    #expect(try list(sbd).map(\.path).sorted() == [real(beta), real(widgets)])
  }

  @Test func addResolvesAWorktreeToItsMainCheckout() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let tree = try sbd.addWorktree(beta, "feat-b")
    let inside = "\(tree)/Sources/deep"
    try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)

    let fromRoot = try add(sbd, tree)
    let fromSubfolder = try add(sbd, inside)

    #expect(fromRoot.path == real(beta))
    #expect(fromRoot.name == "beta")
    #expect(fromSubfolder.path == real(beta))
    #expect(try list(sbd).map(\.path) == [real(beta)])
  }

  @Test func addResolvesASubfolderAndASymlinkToTheMainCheckout() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let tree = try sbd.addWorktree(beta, "feat-b")
    let subfolder = "\(beta)/Sources/deep"
    try FileManager.default.createDirectory(atPath: subfolder, withIntermediateDirectories: true)
    let links = try folder(sbd, "links")
    let shapes = [
      "a subfolder": subfolder,
      "a trailing slash": beta + "/",
      "a path with ..": "\(beta)/Sources/../Sources/deep",
      "a link to the main checkout": "\(links)/main",
      "a link to a subfolder": "\(links)/subfolder",
      "a link to a worktree": "\(links)/tree",
    ]
    try FileManager.default.createSymbolicLink(atPath: "\(links)/main", withDestinationPath: beta)
    try FileManager.default.createSymbolicLink(atPath: "\(links)/subfolder", withDestinationPath: subfolder)
    try FileManager.default.createSymbolicLink(atPath: "\(links)/tree", withDestinationPath: tree)

    for (shape, path) in shapes {
      let added = try add(sbd, path)

      #expect(added.path == real(beta), "\(shape)")
      #expect(added.name == "beta", "\(shape)")
    }
    let relative = try runCommand(
      "\(Instance.bin)/sb", ["repo", "add", "Sources/deep", "--json"], env: sbd.environment(), cwd: beta)
    #expect(relative.status == 0, "\(relative.stderr)")
    #expect(try JSONCoding.decode(KnownRepo.self, from: relative.stdout).path == real(beta))
    #expect(try list(sbd).map(\.path) == [real(beta)])
  }

  /// Foundation expands `~` with CFFIXED_USER_HOME and ignores HOME, so the test sets both.
  @Test func addAcceptsAPathWithATilde() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let home = ["HOME": sbd.home.path, "CFFIXED_USER_HOME": sbd.home.path]

    let added = try add(sbd, "~/beta", env: home)

    #expect(added.path == real(beta))
    #expect(try list(sbd).map(\.path) == [real(beta)])
  }

  @Test func addRefusesAFolderOutsideGit() throws {
    let sbd = try Instance()

    let refused = try refusedAdd(sbd, sbd.work)

    #expect(refused.status != 0)
    #expect(refused.stdout.isEmpty)
    #expect(refused.stderr.contains("\(sbd.work) isn't in a git repository"))
    #expect(try list(sbd).isEmpty)
  }

  @Test func addRefusesAPathThatDoesNotExist() throws {
    let sbd = try Instance()
    let missing = "\(sbd.home.path)/missing"

    let refused = try refusedAdd(sbd, missing)
    let empty = try refusedAdd(sbd, "")

    #expect(refused.status != 0)
    #expect(refused.stdout.isEmpty)
    #expect(refused.stderr.contains("no folder \(missing)"))
    #expect(empty.status != 0)
    #expect(empty.stdout.isEmpty)
    #expect(throws: (any Error).self) { try sbd.client.call("repo-add", ["path": ""]) }
    #expect(throws: (any Error).self) { try sbd.client.call("repo-add", ["path": "missing"]) }
    #expect(throws: (any Error).self) { try sbd.client.call("repo-add") }
    #expect(try list(sbd).isEmpty)
  }

  @Test func addRefusesAFile() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let file = "\(beta)/README.md"
    try "# beta\n".write(toFile: file, atomically: true, encoding: .utf8)

    let refused = try refusedAdd(sbd, file)

    #expect(refused.status != 0)
    #expect(refused.stdout.isEmpty)
    #expect(refused.stderr.contains("no folder \(file)"))
    #expect(try list(sbd).isEmpty)
  }

  @Test func addRefusesABareRepo() throws {
    let sbd = try Instance()
    let source = try sbd.makeRepo("source")
    let bare = "\(sbd.home.path)/bare.git"
    try sbd.git(sbd.home.path, "clone", "-q", "--bare", source, bare)
    let tree = "\(sbd.home.path)/bare-tree"
    try sbd.git(bare, "worktree", "add", "-q", "-b", "feat", tree, "main")
    let message = "is in a bare repository, which has no checkout to run in"

    let refused = try refusedAdd(sbd, bare)
    let refusedTree = try refusedAdd(sbd, tree)

    #expect(refused.status != 0)
    #expect(refused.stdout.isEmpty)
    #expect(refused.stderr.contains("\(bare) \(message)"))
    #expect(refusedTree.status != 0)
    #expect(refusedTree.stdout.isEmpty)
    #expect(refusedTree.stderr.contains("\(tree) \(message)"))
    #expect(try list(sbd).isEmpty)
  }

  /// A linked worktree outlives its main checkout only when the repository keeps its git folder
  /// outside the checkout. With the git folder inside the checkout, git no longer reads the
  /// worktree as a repository.
  @Test func addRefusesAWorktreeWhoseMainCheckoutIsGone() throws {
    let sbd = try Instance()
    let store = "\(sbd.home.path)/store.git"
    let main = "\(sbd.home.path)/separate"
    try sbd.git(sbd.home.path, "init", "-q", "-b", "main", "--separate-git-dir", store, main)
    try commit(sbd, main)
    let tree = "\(sbd.home.path)/separate-tree"
    try sbd.git(main, "worktree", "add", "-q", "-b", "feat", tree)
    let plain = try sbd.makeRepo("plain")
    let plainTree = try sbd.addWorktree(plain, "feat-p")
    try FileManager.default.removeItem(atPath: main)
    try FileManager.default.removeItem(atPath: plain)

    let refused = try refusedAdd(sbd, tree)
    let refusedPlain = try refusedAdd(sbd, plainTree)

    #expect(refused.status != 0)
    #expect(refused.stdout.isEmpty)
    #expect(refused.stderr.contains("the main checkout of \(tree) is gone: "))
    #expect(refusedPlain.status != 0)
    #expect(refusedPlain.stdout.isEmpty)
    #expect(try list(sbd).isEmpty)
  }

  /// A row for a refused folder would stay hidden while the folder is no repository, so the
  /// test makes each refused folder a repository before it reads the list again.
  @Test func aRefusedAddStoresNothing() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha")
    _ = try add(sbd, alpha)
    let missing = "\(sbd.home.path)/missing"
    let outside = try folder(sbd, "outside")
    let file = "\(alpha)/README.md"
    try "# alpha\n".write(toFile: file, atomically: true, encoding: .utf8)
    let bare = "\(sbd.home.path)/bare.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", bare)
    let before = try list(sbd)

    let refusals = try [missing, outside, file, bare].map { try refusedAdd(sbd, $0) }
    let unchanged = try list(sbd)
    try Repos.create(missing)
    try Repos.create(outside)

    #expect(refusals.allSatisfy { $0.status != 0 })
    #expect(before.map(\.path) == [real(alpha)])
    #expect(unchanged == before)
    #expect(try list(sbd) == before)
  }

  // MARK: Read-time check

  @Test func leavesOutARememberedRepoWhoseFolderIsGone() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha")
    let beta = try sbd.makeRepo("beta")
    let kept = try add(sbd, alpha)
    try sbd.advanceClock(60_000)
    _ = try add(sbd, beta)
    let before = try list(sbd)
    let expected = [real(beta), real(alpha)]

    try FileManager.default.removeItem(atPath: beta)

    #expect(before.map(\.path) == expected)
    #expect(try list(sbd) == [kept])
  }

  // MARK: sb repo ls

  @Test func lsWithoutJSONPrintsTheNameAndThePath() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let widgets = try Repos.create("\(sbd.home.path)/widgets", origin: widgetsOrigin)
    _ = try add(sbd, beta)
    try sbd.advanceClock(60_000)
    _ = try add(sbd, widgets)

    let text = try sbd.sb("repo", "ls")
    let bare = try sbd.sb("repo")
    let added = try sbd.sb("repo", "add", beta)

    #expect(text.split(separator: "\n").map(fields) == [["acme/widgets", real(widgets)], ["beta", real(beta)]])
    #expect(bare == text)
    #expect(added.split(separator: "\n").map(fields) == [["beta", real(beta)]])
  }
}
