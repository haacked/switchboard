import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

// `spawn` and `new` with a host, a remote parent, or `local`, run in process against the bench's host mini.

private func run(_ script: String, in folder: String) throws -> String {
  let p = Process()
  let out = Pipe()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", script]
  p.currentDirectoryURL = URL(fileURLWithPath: folder)
  p.environment = [
    "PATH": "/usr/bin:/bin", "HOME": folder, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.com",
  ]
  p.standardOutput = out
  p.standardError = FileHandle.nullDevice
  try p.run()
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  guard p.terminationStatus == 0 else { throw APIError("\(script) exited with \(p.terminationStatus)") }
  return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A checkout on branch main with one commit, whose origin is github.com/`repository`.
private func makeCheckout(_ path: String, _ repository: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  _ = try run(
    "git init -q -b main . && git commit -q --allow-empty -m first"
      + " && git remote add origin https://github.com/\(repository).git", in: path)
}

private func real(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// The checkouts that this Mac's config.json and mini's `repos` name. The Mac and mini name different checkouts
/// for the same `owner/name`, so a lookup in the wrong map lands in the wrong folder. The bench's box shares this
/// Mac's files, so every path here also exists on the box.
private struct Layout {
  let root: String
  var macN: String { "\(root)/mac/n" }
  var macTrees: String { "\(root)/trees" }
  var boxN: String { "\(root)/box/n" }
  var account: String { "\(root)/account" }

  init() throws {
    root = try makeShortTempFolder()
    try makeCheckout(macN, "o/n")
    try makeCheckout("\(root)/mac/widgets", "solo/widgets")
    try makeCheckout("\(root)/mac/nothere", "x/nothere")
    try makeCheckout("\(root)/roots/y/rootonly", "y/rootonly")
    try makeCheckout(boxN, "o/n")
    try makeCheckout("\(root)/box/acme-widgets", "acme/widgets")
    try makeCheckout("\(root)/box/other-widgets", "other/widgets")
    try FileManager.default.createDirectory(atPath: macTrees, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(account)/.claude.json"))
  }

  func close() { try? FileManager.default.removeItem(atPath: root) }

  var hostRepos: JSON {
    [
      "o/n": .string(boxN), "acme/widgets": .string("\(root)/box/acme-widgets"),
      "other/widgets": .string("\(root)/box/other-widgets"), "t/tilde": "~/tilderepo",
    ]
  }

  /// A local session that a test starts by mistake runs no claude or tmux and makes its worktree in `macTrees`.
  var macConfig: [String: JSON] {
    [
      "claude": "/usr/bin/true", "tmux": "/usr/bin/true", "worktreeRoot": .string(macTrees),
      "repos": [
        "o/n": .string(macN), "solo/widgets": .string("\(root)/mac/widgets"),
        "x/nothere": .string("\(root)/mac/nothere"),
      ],
      "repoRoots": [.string("\(root)/roots")], "claudeConfigDirs": [.string(account)],
    ]
  }

  /// The folders under this Mac's worktree root.
  func macWorktrees() -> [String] { (try? FileManager.default.subpathsOfDirectory(atPath: macTrees)) ?? [] }
}

private func withSpawnBench(_ body: (Service, BoxFacts, Layout) throws -> Void) throws {
  let layout = try Layout()
  defer { layout.close() }
  try withReadyService(host: ["repos": layout.hostRepos], config: layout.macConfig) { _, service, facts in
    try body(service, facts, layout)
  }
}

private func spawnArgs(_ repository: String, _ branch: String, _ extra: [String: JSON] = [:]) -> JSON {
  .object(
    ["repository": .string(repository), "branch": .string(branch), "prompt": "hello"].merging(extra) { $1 })
}

/// A started session on mini with the id `box`.
private func addParentOnMini(_ service: Service, _ facts: BoxFacts) throws {
  let cwd = "\(facts.home)/work"
  try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
  var parent = Session(id: "box", name: "box", cwd: cwd, claudeSessionId: "u-box", created: 5)
  parent.host = "mini"
  parent.started = true
  service.queue.sync { service.entries["box"] = Service.Entry(session: parent) }
}

private func ids(_ service: Service) -> Set<String> { service.queue.sync { Set(service.entries.keys) } }

/// The folder of a worktree on `branch` of the checkout at `repo` under mini's worktree root, which is the host's
/// default `~/worktrees`.
private func boxWorktree(_ facts: BoxFacts, repo: String, _ branch: String) -> String {
  "\(real(facts.home))/worktrees/\((real(repo) as NSString).lastPathComponent)/\(branch)"
}

/// The text of the session's claude.sh on the box, with its conversation id replaced.
private func launcher(_ service: Service, _ facts: BoxFacts, _ id: String) throws -> String {
  let claudeSessionId = try #require(service.queue.sync { service.entries[id]?.session.claudeSessionId })
  let text = try String(contentsOfFile: "\(facts.home)/.sb/sessions/\(id)/claude.sh", encoding: .utf8)
  return text.replacingOccurrences(of: claudeSessionId, with: "<conversation>")
}

@Suite struct RemoteSpawnUnitTests {
  // MARK: The repository lookup on a host

  @Test(.timeLimit(.minutes(2)), arguments: ["o/n", "O/N", "n"])
  func aSpawnWithAHostStartsInAWorktreeOfTheCheckoutThatTheHostsReposName(repository: String) throws {
    try withSpawnBench { service, facts, layout in
      let s = try service.spawn(spawnArgs(repository, "b1", ["host": "mini"]))

      #expect(s.host == "mini")
      #expect(s.repo.map(real) == real(layout.boxN))
      #expect(real(s.cwd) == boxWorktree(facts, repo: layout.boxN, "b1"))
      #expect(
        try run("git rev-parse --path-format=absolute --git-common-dir", in: s.cwd) == real("\(layout.boxN)/.git"))
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
    }
  }

  /// A checkout path in `repos` that starts with `~` names a folder under the host's home.
  @Test(.timeLimit(.minutes(2)))
  func aSpawnWithAHostExpandsATildeInTheHostsReposOnTheHost() throws {
    try withSpawnBench { service, facts, layout in
      try makeCheckout("\(facts.home)/tilderepo", "t/tilde")

      let s = try service.spawn(spawnArgs("t/tilde", "b1", ["host": "mini"]))

      #expect(s.host == "mini")
      #expect(s.repo.map(real) == real("\(facts.home)/tilderepo"))
    }
  }

  @Test(.timeLimit(.minutes(2)))
  func aSpawnWithAHostRefusesABareNameThatMatchesSeveralOfTheHostsRepos() throws {
    try withSpawnBench { service, _, layout in
      do {
        _ = try service.spawn(spawnArgs("widgets", "b1", ["host": "mini"]))
        Issue.record("spawn picked one of two repositories named widgets")
      } catch {
        #expect("\(error)".contains("acme/widgets"), "\(error)")
        #expect("\(error)".contains("other/widgets"), "\(error)")
      }

      #expect(ids(service).isEmpty)
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
    }
  }

  /// A host looks repositories up in its own `repos` only, never in this Mac's `repos` or `repoRoots`.
  @Test(.timeLimit(.minutes(2)), arguments: ["nothere", "x/nothere", "rootonly", "y/rootonly"])
  func aSpawnWithAHostRefusesARepositoryThatOnlyThisMacKnows(repository: String) throws {
    try withSpawnBench { service, _, layout in
      #expect(throws: (any Error).self) { try service.spawn(spawnArgs(repository, "b1", ["host": "mini"])) }

      #expect(ids(service).isEmpty)
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
    }
  }

  /// `<home>` stands for the box's home.
  @Test(.timeLimit(.minutes(2)), arguments: ["~/pathrepo", "~/pathrepo/sub", "<home>/pathrepo"])
  func aSpawnWithAHostResolvesAPathToItsCheckoutOnTheHost(path: String) throws {
    try withSpawnBench { service, facts, layout in
      try makeCheckout("\(facts.home)/pathrepo", "p/pathrepo")
      try FileManager.default.createDirectory(atPath: "\(facts.home)/pathrepo/sub", withIntermediateDirectories: true)
      let repository = path.replacingOccurrences(of: "<home>", with: facts.home)

      let s = try service.spawn(spawnArgs(repository, "b1", ["host": "mini"]))

      #expect(s.host == "mini")
      #expect(s.repo.map(real) == real("\(facts.home)/pathrepo"))
      #expect(real(s.cwd) == boxWorktree(facts, repo: "\(facts.home)/pathrepo", "b1"))
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
    }
  }

  /// The branch check runs on the host's checkout. This Mac's checkout of o/n has no branch `taken`.
  @Test(.timeLimit(.minutes(2)))
  func aSpawnWithAHostRefusesABranchThatTheHostsCheckoutHas() throws {
    try withSpawnBench { service, _, layout in
      _ = try run("git branch taken", in: layout.boxN)

      do {
        _ = try service.spawn(spawnArgs("o/n", "taken", ["host": "mini"]))
        Issue.record("spawn started a session on a branch that the host's checkout has")
      } catch {
        #expect("\(error)".contains("branch taken"), "\(error)")
      }

      #expect(ids(service).isEmpty)
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
    }
  }

  // MARK: Refusals before the host

  /// mini's link never connected, so a refusal that waited on the host would connect it and fail after 30 s.
  /// Without the host, each request succeeds on this Mac, whose config.json resolves o/n and the account.
  @Test(.timeLimit(.minutes(1)), arguments: ["followup", "after", "account"])
  func aSpawnWithAHostAndAFollowupAfterOrAccountFailsBeforeItTouchesTheHost(shape: String) throws {
    let layout = try Layout()
    defer { layout.close() }
    let hosts: [String: JSON] = [
      "mini": ["kind": "ssh", "destination": .string(LinkBench.destination), "repos": layout.hostRepos]
    ]
    let config = layout.macConfig.merging(["hostWaitSeconds": 30]) { $1 }
    try withHostService(hosts: hosts, config: config) { service, _ in
      let link = try #require(service.hostLinks["mini"])
      let before = link.status.state
      let extra: [String: JSON] =
        switch shape {
        case "followup": ["followup": true]
        case "after": ["followup": true, "after": "pr:12"]
        default: ["account": .string(layout.account)]
        }

      do {
        _ = try service.spawn(spawnArgs("o/n", "b1", extra.merging(["host": "mini"]) { $1 }))
        Issue.record("spawn with a host took \(shape)")
      } catch {
        #expect(!(error is HostUnread), "\(error)")
        let text = "\(error)"
        let named = shape == "account" ? text.contains("account") : text.contains("after") || text.contains("follow")
        #expect(named, "\(error)")
      }

      #expect(link.status.state == before)
      #expect(ids(service).isEmpty)
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
    }
  }

  // MARK: The parent's host

  @Test(.timeLimit(.minutes(2)))
  func aSpawnWithAParentOnAHostAndNoHostStartsOnTheParentsHost() throws {
    try withSpawnBench { service, facts, layout in
      try addParentOnMini(service, facts)

      let s = try service.spawn(spawnArgs("o/n", "b1", ["parent": "box"]))

      #expect(s.host == "mini")
      #expect(s.parent == "box")
      #expect(s.repo.map(real) == real(layout.boxN))
      #expect(real(s.cwd) == boxWorktree(facts, repo: layout.boxN, "b1"))
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
    }
  }

  @Test(.timeLimit(.minutes(2)))
  func aSpawnWithLocalAndAParentOnAHostStartsOnThisMac() throws {
    try withSpawnBench { service, facts, layout in
      try addParentOnMini(service, facts)

      let s = try service.spawn(spawnArgs("o/n", "b1", ["parent": "box", "host": "local"]))

      #expect(s.host == nil)
      #expect(s.parent == "box")
      #expect(s.repo.map(real) == real(layout.macN))
      #expect(real(s.cwd) == real("\(layout.macTrees)/n/b1"))
      #expect(service.queue.sync { service.entries[s.id]?.session.host } == nil)
    }
  }

  /// A session on a host runs under the host's login, so a child that takes its parent's host takes no account.
  @Test(.timeLimit(.minutes(2)))
  func aSpawnWithAParentOnAHostAndAnAccountFails() throws {
    try withSpawnBench { service, facts, layout in
      try addParentOnMini(service, facts)

      do {
        _ = try service.spawn(spawnArgs("o/n", "b1", ["parent": "box", "account": .string(layout.account)]))
        Issue.record("spawn took an account for a session on mini")
      } catch {
        #expect("\(error)".contains("takes no account"), "\(error)")
      }

      #expect(ids(service) == ["box"])
      #expect(!FileManager.default.fileExists(atPath: "\(facts.home)/worktrees"))
    }
  }

  /// A follow-up starts on this Mac later, so it never takes its parent's host.
  @Test(.timeLimit(.minutes(2)))
  func aFollowupWithAParentOnAHostStaysOnThisMac() throws {
    try withSpawnBench { service, facts, _ in
      try addParentOnMini(service, facts)

      let s = try service.spawn(spawnArgs("o/n", "f1", ["parent": "box", "followup": true]))

      #expect(s.host == nil)
      #expect(service.queue.sync { service.entries[s.id]?.session.host } == nil)
      #expect(!FileManager.default.fileExists(atPath: "\(facts.home)/worktrees"))
    }
  }

  /// A parent that sbd doesn't hold has no host to give.
  @Test(.timeLimit(.minutes(2)))
  func aSpawnWhoseParentSbdDoesNotHoldNeverStartsOnAHost() throws {
    try withSpawnBench { service, _, _ in
      let s = try? service.spawn(spawnArgs("o/n", "b1", ["parent": "gone"]))

      #expect(s.map { $0.host == nil } ?? true, "\(String(describing: s))")
    }
  }

  // MARK: new

  /// `sb new` expanded the folder on this Mac, so it is not a folder on the parent's host.
  @Test(.timeLimit(.minutes(2)))
  func newWithAParentOnAHostAndNoHostFailsAndMakesNoFolder() throws {
    try withSpawnBench { service, facts, layout in
      try addParentOnMini(service, facts)

      do {
        _ = try service.newSession(NewSession(path: layout.macN, branch: "b9", prompt: "hello", parent: "box"))
        Issue.record("new started a session with a parent on mini and no host")
      } catch {
        #expect(
          "\(error)".contains("name --host mini or --host local: a folder typed on this Mac is not a folder on mini"),
          "\(error)")
      }

      #expect(ids(service) == ["box"])
      #expect(layout.macWorktrees().isEmpty, "\(layout.macWorktrees())")
      #expect(!FileManager.default.fileExists(atPath: "\(facts.home)/worktrees"))
    }
  }

  @Test(.timeLimit(.minutes(2)), arguments: [nil, "box"] as [String?])
  func newWithLocalStartsOnThisMacInTheFolderAsGiven(parent: String?) throws {
    try withSpawnBench { service, facts, layout in
      try addParentOnMini(service, facts)

      let s = try service.newSession(NewSession(path: layout.macN, prompt: "hello", parent: parent, host: "local"))

      #expect(s.host == nil)
      #expect(real(s.cwd) == real(layout.macN))
      #expect(service.queue.sync { service.entries[s.id]?.session.host } == nil)
    }
  }

  // MARK: Parity

  /// `spawn --host mini` from this Mac and `spawn` with a parent on mini launch the same claude in the same
  /// worktree root, for each way to name the repository.
  @Test(.timeLimit(.minutes(3)), arguments: ["o/n", "n", "~/pathrepo"])
  func aSpawnWithAHostAndASpawnWithAParentOnThatHostLaunchTheSame(repository: String) throws {
    try withSpawnBench { service, facts, _ in
      try makeCheckout("\(facts.home)/pathrepo", "p/pathrepo")
      try addParentOnMini(service, facts)

      let named = try service.spawn(spawnArgs(repository, "p1", ["host": "mini"]))
      let inherited = try service.spawn(spawnArgs(repository, "p2", ["parent": "box"]))

      #expect(named.host == "mini")
      #expect(inherited.host == named.host)
      #expect(inherited.repo.map(real) == named.repo.map(real))
      #expect(
        (real(inherited.cwd) as NSString).deletingLastPathComponent
          == (real(named.cwd) as NSString).deletingLastPathComponent)
      #expect(try launcher(service, facts, inherited.id) == launcher(service, facts, named.id))
    }
  }
}
