import Foundation
import SwitchboardCore
import Testing

/// sbd reads each work session's GitHub repository from its folder's origin
/// remote, and `sb ls --org` and `--local` filter the list by its owner.
@Suite(.blocking(timeLimit: .seconds(120))) struct OrgDerivationTests {
  /// One session per folder shape, by name, once sbd has read every folder's remotes.
  struct Folders {
    var sbd: Instance
    var ids: [String: String]
    var listed: [String: SessionSummary]
  }

  static let names = ["posthog", "fork", "gitlab", "plain", "upstream-only", "ssh-443"]

  private func new(_ sbd: Instance, _ path: String, _ name: String) throws -> SessionSummary {
    try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("new", "--json", "--name", name, path))
  }

  private func ls(_ sbd: Instance, _ args: [String] = []) throws -> [SessionSummary] {
    try JSONCoding.decode([SessionSummary].self, from: try sbd.sb(["ls", "--json"] + args))
  }

  private func folders(_ repos: Repos) throws -> Folders {
    let sbd = try Instance()
    let posthog = try repos.make("PostHog/posthog")
    let fork = try repos.make("haacked/fork", remote: "git@github.com:haacked/fork.git")
    try sbd.git(fork, "remote", "add", "upstream", "https://github.com/PostHog/fork.git")
    let gitlab = try repos.make("acme/x", remote: "https://gitlab.com/acme/x.git")
    let plain = "\(repos.root)/plain"
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    let upstreamOnly = try Repos.create("\(repos.root)/upstream-only")
    try sbd.git(upstreamOnly, "remote", "add", "upstream", "https://github.com/PostHog/upstream-only.git")
    let ssh = try repos.make("PostHog/ssh", remote: "ssh://git@ssh.github.com:443/PostHog/ssh.git")

    let paths = [
      "posthog": posthog, "fork": fork, "gitlab": gitlab, "plain": plain, "upstream-only": upstreamOnly, "ssh-443": ssh,
    ]
    var ids: [String: String] = [:]
    for name in Self.names { ids[name] = try new(sbd, paths[name]!, name).id }
    let wanted = Set(ids.values)
    let all = try sbd.waitFor("every folder's remotes to be read", fetch: { try ls(sbd) }) { list in
      wanted.allSatisfy { id in list.first { $0.id == id }?.repositoryRead == true }
    }
    let listed = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    return Folders(sbd: sbd, ids: ids, listed: listed.filter { wanted.contains($0.key) })
  }

  @Test func readsTheOwnerAndNameOfEachFoldersOriginRemote() throws {
    let repos = try Repos()
    let f = try folders(repos)

    let repository = Dictionary(uniqueKeysWithValues: Self.names.map { ($0, f.listed[f.ids[$0]!]?.repository) })
    let keys = Dictionary(uniqueKeysWithValues: Self.names.map { ($0, f.listed[f.ids[$0]!].flatMap(OrgFilter.key)) })
    let rows = try #require(JSON.parse(try f.sbd.sb("ls", "--json"))?.array)
    let posthog = try #require(rows.first { $0["id"]?.string == f.ids["posthog"] })
    let plain = try #require(rows.first { $0["id"]?.string == f.ids["plain"] })

    #expect(
      repository == [
        "posthog": "PostHog/posthog", "fork": "haacked/fork", "gitlab": nil, "plain": nil, "upstream-only": nil,
        "ssh-443": "PostHog/ssh",
      ])
    #expect(
      keys == [
        "posthog": "posthog", "fork": "haacked", "gitlab": OrgFilter.localKey, "plain": OrgFilter.localKey,
        "upstream-only": OrgFilter.localKey, "ssh-443": "posthog",
      ])
    #expect(posthog["repository"] == .string("PostHog/posthog"))
    #expect(posthog["repositoryRead"] == .bool(true))
    #expect(plain["repositoryRead"] == .bool(true))
    #expect(plain["repository"] == nil || plain["repository"] == .null)
  }

  @Test func lsFiltersByOrgAndLocal() throws {
    let repos = try Repos()
    let f = try folders(repos)
    let byId = Dictionary(uniqueKeysWithValues: f.ids.map { ($0.value, $0.key) })
    let cases: [([String], Set<String>)] = [
      (["--org", "POSTHOG"], ["posthog", "ssh-443"]),
      (["--org", "haacked"], ["fork"]),
      (["--local"], ["gitlab", "plain", "upstream-only"]),
      (["--org", "posthog", "--local"], ["posthog", "ssh-443", "gitlab", "plain", "upstream-only"]),
      (["--org", "posthog,haacked", "--local"], Set(Self.names)),
      (["--org", "acme"], []),
    ]

    for (args, names) in cases {
      let listed = try ls(f.sbd, args)

      #expect(Set(listed.map { byId[$0.id] ?? $0.id }) == names, "sb ls --json \(args.joined(separator: " "))")
    }
  }
}
