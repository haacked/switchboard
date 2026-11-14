import Foundation
import SwitchboardCore
import Testing

/// `sb spawn --host` from this Mac, end to end over the ssh stub: the host's `repos`, the box's git, and the launch
/// on the box. The unit suite `RemoteSpawnUnitTests` covers the lookup's other shapes and the refusals.
@Suite(.blocking(timeLimit: .seconds(180))) struct RemoteSpawnTests {
  @Test func spawnWithAHostFromTheMacStartsOnTheBoxInAWorktreeOfTheCheckoutThatTheHostsReposName() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    let repo = try Repos.create("\(sbd.boxHome)/sb-box-repo", origin: "https://github.com/o/n.git")
    try sbd.restart(
      setting: "hosts",
      to: ["mini": Instance.remoteHost(Instance.boxDestination, ["repos": ["o/n": .string(repo)]])])
    try sbd.connectHost()

    let summary = try #require(
      JSON.parse(
        try sbd.sb("spawn", "--host", "mini", "--repo", "o/n", "--branch", "b", "--prompt", "p", "--json")))

    let id = try sbd.id(of: summary)
    let cwd = try #require(summary["cwd"]?.string)
    #expect(summary["host"] == "mini")
    #expect(real(cwd) == real("\(sbd.boxHome)/worktrees/sb-box-repo/b"), "\(cwd)")
    #expect(try sbd.git(cwd, "branch", "--show-current") == "b")
    #expect(real(try sbd.git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")) == real("\(repo)/.git"))
    let onMac = (try? FileManager.default.contentsOfDirectory(atPath: "\(sbd.home.path)/worktrees")) ?? []
    #expect(onMac.isEmpty, "this Mac's worktree root holds \(onMac)")
    try sbd.waitFor(id, "the first reply on the box", timeout: 30) { $0.lastReply == "Done: p" }

    // sb passes a path for a host as typed, so the box resolves its ~.
    let byPath = try #require(
      JSON.parse(
        try sbd.sb("spawn", "--host", "mini", "--repo", "~/sb-box-repo", "--branch", "c", "--prompt", "p", "--json")))
    #expect(byPath["host"] == "mini")
    #expect(byPath["repo"]?.string.map(real) == real(repo))
  }
}
