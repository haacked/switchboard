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
  /// has its checkout. sbd reads a checkout off its state queue, after the
  /// first summary of the session.
  private func listed(_ sbd: Instance, _ ids: [String], inGit: Set<String>) throws -> [SessionSummary] {
    try sbd.waitFor("the checkouts", fetch: { try sbd.client.sessions() }) { all in
      all.allSatisfy { !inGit.contains($0.id) || $0.checkout != nil }
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
    let alpha = try sbd.makeRepo("alpha")
    let beta = try sbd.makeRepo("beta")
    let plain = try new(sbd, sbd.work, "plain")
    let a = try new(sbd, alpha, "a", branch: "feat-a")
    let made = try new(sbd, beta, "made", branch: "feat-b2")
    let external = try new(sbd, try sbd.addWorktree(beta, "feat-b"), "external")

    let sessions = try listed(sbd, [a.id, made.id, external.id, plain.id], inGit: [external.id])
    let labels = RepoLabels.labels(sessions)

    #expect(sessions[3].checkout == nil)
    #expect(labels == [a.id: "alpha", made.id: "beta", external.id: "beta"])
    let lanes = MergeBoard.repoLanes(sessions, labels: RepoLabels.labels(sessions, evenForOneRepo: true))
    #expect(lanes.map(\.title) == ["Other", "alpha", "beta"])
    #expect(Set(lanes[2].sessions.map(\.id)) == [made.id, external.id])
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
    // A session in a git folder starts a lookup. The follow-up's checkout stays nil after that lookup.
    let other = try new(sbd, try sbd.makeRepo("beta"), "beta")

    _ = try listed(sbd, [other.id], inGit: [other.id])

    let followup = try sbd.get(added.id)
    #expect(followup.cwd.isEmpty)
    #expect(followup.checkout == nil)
  }
}
