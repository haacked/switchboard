import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct RepoCheckoutTests {
  private func new(_ sbd: Instance, _ path: String, _ name: String, branch: String? = nil) throws -> SessionSummary {
    var args: [String: JSON] = ["path": .string(path), "name": .string(name)]
    if let branch { args["branch"] = .string(branch) }
    return try sbd.client.call("new", args, as: SessionSummary.self)
  }

  /// The sessions in the order of `ids`, once each session in a git folder
  /// has its checkout, and each session in a checkout with a GitHub origin has
  /// its repository. sbd reads both off its state queue, after the first
  /// summary of the session.
  private func listed(_ sbd: Instance, _ ids: [String], inGit: Set<String>, withOrigin: Set<String> = [])
    throws -> [SessionSummary]
  {
    try sbd.waitFor("the checkouts", fetch: { try sbd.client.sessions() }) { all in
      all.allSatisfy {
        (!inGit.contains($0.id) || $0.checkout != nil) && (!withOrigin.contains($0.id) || $0.repository != nil)
      }
    }
    .filter { ids.contains($0.id) }
    .sorted { ids.firstIndex(of: $0.id)! < ids.firstIndex(of: $1.id)! }
  }

  @Test func givesAWorktreeThatSbdDidNotMakeTheMainCheckoutOfItsRepo() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta")
    let tree = try sbd.addWorktree(beta, "feat-b")
    let made = try new(sbd, beta, "made", branch: "feat-b2")
    let external = try new(sbd, tree, "external")
    let main = try new(sbd, beta, "main")

    let sessions = try listed(sbd, [made.id, external.id, main.id], inGit: [external.id, main.id])

    let checkout = real(beta)
    #expect(sessions.map(\.checkout) == [checkout, checkout, checkout])
    #expect(sessions.map(\.repo) == [beta, nil, nil])
    #expect(RepoLabels.labels(sessions).isEmpty)
    #expect(RepoLabels.labels(sessions, evenForOneRepo: true).values.sorted() == ["beta", "beta", "beta"])
  }

  @Test func labelsEachSessionWithItsRepoAndPutsBothWorktreesOfARepoInOneLane() throws {
    let sbd = try Instance()
    let alpha = try sbd.makeRepo("alpha", origin: "https://github.com/acme/alpha.git")
    let beta = try sbd.makeRepo("beta", origin: "git@github.com:acme/beta.git")
    let plain = try new(sbd, sbd.work, "plain")
    let a = try new(sbd, alpha, "a", branch: "feat-a")
    let made = try new(sbd, beta, "made", branch: "feat-b2")
    let external = try new(sbd, try sbd.addWorktree(beta, "feat-b"), "external")

    let sessions = try listed(
      sbd, [a.id, made.id, external.id, plain.id], inGit: [external.id], withOrigin: [a.id, made.id, external.id])
    let labels = RepoLabels.labels(sessions)

    #expect(sessions[3].checkout == nil)
    #expect(labels == [a.id: "alpha", made.id: "beta", external.id: "beta"])
    let lanes = MergeBoard.repoLanes(sessions, labels: RepoLabels.labels(sessions, evenForOneRepo: true))
    #expect(lanes.map(\.title) == ["Other", "alpha", "beta"])
    #expect(Set(lanes[2].sessions.map(\.id)) == [made.id, external.id])
    let fullName = MergeBoard.repoLanes(
      sessions, labels: RepoLabels.labels(sessions, evenForOneRepo: true, fullName: true))
    #expect(fullName.map(\.title) == ["Other", "acme/alpha", "acme/beta"])
    #expect(Set(fullName[2].sessions.map(\.id)) == [made.id, external.id])
  }

  @Test func givesEachSessionTheOwnerAndNameOfItsCheckoutsOrigin() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta", origin: "https://github.com/acme/beta.git")
    let tree = try sbd.addWorktree(beta, "feat-b")
    let made = try new(sbd, beta, "made", branch: "feat-b2")
    let external = try new(sbd, tree, "external")
    let main = try new(sbd, beta, "main")
    let ids = [made.id, external.id, main.id]

    let sessions = try listed(sbd, ids, inGit: [external.id, main.id], withOrigin: Set(ids))

    #expect(sessions.map(\.repository) == ["acme/beta", "acme/beta", "acme/beta"])
    #expect(sessions.map(\.repo) == [beta, nil, nil])
  }

  @Test func givesTheRepositoryToSbLsJSON() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta", origin: "https://github.com/acme/beta.git")
    let external = try new(sbd, try sbd.addWorktree(beta, "feat-b"), "external")
    _ = try listed(sbd, [external.id], inGit: [external.id], withOrigin: [external.id])

    let sessions = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))

    #expect(sessions.first { $0.id == external.id }?.repository == "acme/beta")
  }

  @Test(arguments: [
    ("no origin", nil as String?),
    ("a GitLab origin", "https://gitlab.com/acme/beta.git"),
  ])
  func givesNoRepositoryToACheckoutWithoutAGitHubOrigin(_ name: String, _ origin: String?) throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta", origin: origin)
    let external = try new(sbd, try sbd.addWorktree(beta, "feat-b"), "external")
    let main = try new(sbd, beta, "main")
    // A checkout with a GitHub origin, read after the one under test.
    let control = try new(
      sbd, try sbd.makeRepo("gamma", origin: "https://github.com/acme/gamma.git"), "control")

    let sessions = try listed(
      sbd, [external.id, main.id, control.id], inGit: [external.id, main.id, control.id], withOrigin: [control.id])

    #expect(sessions.map(\.repository) == [nil, nil, "acme/gamma"])
  }

  @Test func keepsTheRepositoryOfAnSbdWorktreeWhoseFolderIsGone() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta", origin: "https://github.com/acme/beta.git")
    let made = try new(sbd, beta, "made", branch: "feat-b2")
    sbd.stopSbd()
    try FileManager.default.removeItem(atPath: made.cwd)
    try sbd.startSbd()

    let sessions = try listed(sbd, [made.id], inGit: [], withOrigin: [made.id])

    #expect(sessions.map(\.repository) == ["acme/beta"])
    #expect(sessions.map(\.repo) == [beta])
  }

  @Test func answersForASessionWhoseFolderIsGone() throws {
    let sbd = try Instance()
    let beta = try sbd.makeRepo("beta", origin: "https://github.com/acme/beta.git")
    let tree = try sbd.addWorktree(beta, "feat-b")
    let external = try new(sbd, tree, "external")
    sbd.stopSbd()
    try FileManager.default.removeItem(atPath: tree)
    try sbd.startSbd()
    // A checkout with a GitHub origin, read after the gone folder.
    let control = try new(
      sbd, try sbd.makeRepo("gamma", origin: "https://github.com/acme/gamma.git"), "control")
    _ = try listed(sbd, [control.id], inGit: [control.id], withOrigin: [control.id])

    let ls = try sbd.run(["ls", "--json"])

    #expect(ls.status == 0)
    let gone = try #require(
      try JSONCoding.decode([SessionSummary].self, from: ls.stdout).first { $0.id == external.id })
    #expect(gone.repo == nil)
    #expect(gone.checkout == nil)
    #expect(gone.repository == nil)
  }

  @Test func keepsAWorktreeThatSbdDidNotMakeOutOfWorktreeRemoval() throws {
    let sbd = try Instance()
    let tree = try sbd.addWorktree(try sbd.makeRepo("beta"), "feat-b")
    let external = try new(sbd, tree, "external")

    let listed = try sbd.get(external.id)
    #expect(listed.cleanup == nil)
    let removal = try sbd.run(["rm", external.id, "--worktree"])
    #expect(removal.status != 0)
    #expect(removal.stderr.contains("sbd didn't make a worktree for it"))
    #expect(FileManager.default.fileExists(atPath: tree))
  }

  @Test func givesAFollowupThatHasNotStartedNoCheckout() throws {
    let sbd = try Instance()
    let added = try sbd.client.call(
      "followup-add", ["prompt": "Fix the cache.", "repository": "acme/widgets"], as: SessionSummary.self)
    // A session in a git folder starts a lookup. The follow-up's checkout
    // and repository stay nil after that lookup. sbd runs in the test's
    // folder, which can be a checkout with a GitHub origin, so git must not
    // run with the empty cwd.
    let other = try new(
      sbd, try sbd.makeRepo("beta", origin: "https://github.com/acme/beta.git"), "beta")

    _ = try listed(sbd, [other.id], inGit: [other.id], withOrigin: [other.id])

    let followup = try sbd.get(added.id)
    #expect(followup.cwd.isEmpty)
    #expect(followup.checkout == nil)
    #expect(followup.repository == nil)
  }

  @Test func readsAFolderAgainAMinuteAfterItFoundNoRepo() throws {
    let sbd = try Instance()
    let folder = "\(sbd.home.path)/later"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let later = try new(sbd, folder, "later")
    // A session in a git folder starts a lookup after the plain folder's lookup.
    let other = try new(sbd, try sbd.makeRepo("beta"), "beta")
    _ = try listed(sbd, [later.id, other.id], inGit: [other.id])
    try sbd.git(folder, "init", "-q", "-b", "main")

    #expect(try sbd.get(later.id).checkout == nil)
    try sbd.advanceClock(61_000)

    let sessions = try listed(sbd, [later.id], inGit: [later.id])
    #expect(sessions[0].checkout == real(folder))
  }
}
