import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

// The callers of a remote site's guard: the poller, the launch, the caches by path, and the refusals.

private func isUnread(_ error: any Error) -> Bool { (error as? HostUnread)?.hostName == "mini" }

private func sh(_ script: String, in folder: String) throws {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", script]
  p.currentDirectoryURL = URL(fileURLWithPath: folder)
  p.environment = [
    "PATH": "/usr/bin:/bin", "HOME": folder, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.com",
  ]
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  try p.run()
  p.waitUntilExit()
  guard p.terminationStatus == 0 else { throw APIError("\(script) exited with \(p.terminationStatus)") }
}

/// A repo on the branch `feature` whose origin is github.com/mac/repo.
private func makeRepo(_ path: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  try sh(
    "git init -q -b main . && git commit -q --allow-empty -m first && git checkout -q -b feature"
      + " && git remote add origin https://github.com/mac/repo.git", in: path)
}

/// The box's git. It exits with the status in the home's `git-status` file, prints the home's `box-config` file
/// as the repo's config, and runs git otherwise. A test writes it before setup, which then finds it first.
private func installBoxGit(_ b: SiteBench) throws {
  let path = "\(b.home)/box-bin/git"
  let script = """
    #!/bin/sh
    d=\(shellQuote(b.home))
    if [ -f "$d/git-status" ]; then exit "$(cat "$d/git-status")"; fi
    case " $* " in
    *" config --get-regexp "*) if [ -f "$d/box-config" ]; then cat "$d/box-config"; exit 0; fi ;;
    esac
    exec /usr/bin/git "$@"

    """
  try Data(script.utf8).write(to: URL(fileURLWithPath: path))
  chmod(path, 0o755)
}

private func poller(_ service: Service) -> GitHubPoller {
  GitHubPoller(
    service: service, settings: service.config.github, depot: service.config.depot, trunk: service.config.trunk)
}

private func watched(
  _ id: String, cwd: String, at site: any SessionSite, configDir: String, facts: SessionFacts = SessionFacts()
) -> GitHubPoller.Watched {
  GitHubPoller.Watched(
    id: id, cwd: cwd, claudeSessionId: "u-\(id)", configDir: configDir, site: site, branch: nil, facts: facts)
}

private func remoteSession(_ id: String, cwd: String = "/srv/repo") -> Session {
  var s = Session(id: id, name: id, cwd: cwd, claudeSessionId: "u-\(id)", created: 5)
  s.host = "mini"
  s.started = true
  return s
}

private func withBench(scripts: Bool = true, _ body: (SiteBench) throws -> Void) throws {
  let b = try SiteBench(scripts: scripts)
  defer { b.close() }
  try body(b)
}

// MARK: The poller

/// The poller's reads of a session on a host. It keeps what it knew unless the host answered every read.
@Suite struct RemotePollerTests {
  /// A drop of the connection needs a bench without `scripts`, whose host shell is one process.
  private func withPoller(scripts: Bool = true, _ body: (SiteBench, GitHubPoller, String) throws -> Void) throws {
    try withBench(scripts: scripts) { b in
      try installBoxGit(b)
      try b.ready()
      let repo = "\(b.home)/repo"
      try makeRepo(repo)
      try withHostService { service, _ in try body(b, poller(service), repo) }
    }
  }

  private func refresh(_ p: GitHubPoller, _ s: GitHubPoller.Watched, shared: inout GitHubPoller.Shared) {
    p.queue.sync { p.refreshLocal(s, all: false, now: nowMs(), shared: &shared) }
  }

  private func refresh(_ p: GitHubPoller, _ s: GitHubPoller.Watched) {
    var shared = GitHubPoller.Shared()
    refresh(p, s, shared: &shared)
  }

  @Test(.timeLimit(.minutes(1)))
  func theRefreshReadsTheBranchOfAFolderOnTheHost() throws {
    try withPoller { b, p, repo in
      let s = watched("s1", cwd: repo, at: b.site, configDir: "\(b.boxHome)/.claude")

      refresh(p, s)

      #expect(p.tracked["s1"]?.branch.name == "feature")
      #expect(p.tracked["s1"]?.branch.key != nil)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["a file check that its timeout ended", "git that its timeout ended"])
  func theRefreshKeepsTheLastValuesWhenAReadGotNoAnswer(shape: String) throws {
    try withPoller { b, p, repo in
      let s = watched("s1", cwd: repo, at: b.site, configDir: "\(b.boxHome)/.claude")
      refresh(p, s)
      let before = try #require(p.tracked["s1"])
      try sh("git checkout -q -b other && git remote set-url origin https://github.com/mac/moved.git", in: repo)

      if shape.hasPrefix("git") {
        // The poller runs git when the HEAD file changed.
        try b.set("git-status", "143")
      } else {
        try b.set("script-status", "143")
      }
      var shared = GitHubPoller.Shared()
      refresh(p, s, shared: &shared)

      let kept = try #require(p.tracked["s1"])
      #expect(kept.branch.name == "feature")
      #expect(kept.branch.head == before.branch.head)
      #expect(kept.branch.key == before.branch.key)
      #expect(kept.branch.gitDir == before.branch.gitDir)
      #expect(shared.configs.isEmpty && shared.projects.isEmpty, "a poll that got no answer shares nothing")

      try FileManager.default.removeItem(atPath: "\(b.home)/\(shape.hasPrefix("git") ? "git-status" : "script-status")")
      refresh(p, s)

      #expect(p.tracked["s1"]?.branch.name == "other")
      #expect(p.tracked["s1"]?.branch.key != before.branch.key)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theRefreshKeepsTheLastValuesWhenTheLinkDropped() throws {
    try withPoller(scripts: false) { b, p, repo in
      let s = watched("s1", cwd: repo, at: b.site, configDir: "\(b.boxHome)/.claude")
      refresh(p, s)
      let before = try #require(p.tracked["s1"])
      try sh("git checkout -q -b other", in: repo)

      try b.reconnect()
      refresh(p, s)

      #expect(p.tracked["s1"]?.branch.name == "feature")
      #expect(p.tracked["s1"]?.branch.head == before.branch.head)
      #expect(p.tracked["s1"]?.branch.key == before.branch.key)
    }
  }

  /// A first poll that got no answer tracks nothing, so the session keeps the PR of the event log.
  @Test(.timeLimit(.minutes(1)))
  func aFirstRefreshThatGotNoAnswerTracksNothing() throws {
    try withPoller { b, p, repo in
      try b.set("script-status", "143")

      refresh(p, watched("s1", cwd: repo, at: b.site, configDir: "\(b.boxHome)/.claude"))

      #expect(p.tracked["s1"] == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theCountOfAFolderOnTheHostIsTheHostsAnswer() throws {
    try withPoller { b, p, repo in
      try Data("x".utf8).write(to: URL(fileURLWithPath: "\(repo)/new-file"))
      let s = watched("s1", cwd: repo, at: b.site, configDir: "\(b.boxHome)/.claude")
      let missing = watched("s2", cwd: "\(b.home)/missing", at: b.site, configDir: "\(b.boxHome)/.claude")

      let count = try #require(p.worktreeCount(s))
      let gone = try #require(p.worktreeCount(missing))

      #expect(count.dirty == 1 && !count.gone)
      #expect(gone.dirty == nil && gone.gone)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [137, 143])
  func theCountIsNilWhenGitsTimeoutEndedIt(status: Int) throws {
    try withPoller { b, p, repo in
      let s = watched("s1", cwd: repo, at: b.site, configDir: "\(b.boxHome)/.claude")
      try b.set("git-status", String(status))

      #expect(p.worktreeCount(s) == nil, "git gave no count, and the folder exists")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theCountIsNilWhenTheLinkDropped() throws {
    try withPoller(scripts: false) { b, p, repo in
      let s = watched("s1", cwd: "\(b.home)/missing", at: b.site, configDir: "\(b.boxHome)/.claude")

      try b.reconnect()

      #expect(p.worktreeCount(s) == nil, "a folder is not gone because the host did not answer")
    }
  }

  /// git answered that it can't count, and the folder exists: the answer is a count of nil and a folder that is not gone.
  @Test(.timeLimit(.minutes(1)))
  func gitsOwnFailureIsAnAnswer() throws {
    try withPoller { b, p, repo in
      let s = watched("s1", cwd: repo, at: b.site, configDir: "\(b.boxHome)/.claude")
      try b.set("git-status", "128")

      let count = try #require(p.worktreeCount(s))

      #expect(count.dirty == nil && !count.gone)
    }
  }
}

// MARK: One path at two sites

/// A host can hold the paths that this Mac holds. What sbd remembers about a path at one site must not answer
/// for the other.
@Suite struct RemoteSessionCacheTests {
  /// The box's git reports another origin for the same repo folder.
  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func onePollReadsTheGitConfigOfEachSite(macFirst: Bool) throws {
    try withBench { b in
      try installBoxGit(b)
      try b.ready()
      let repo = "\(b.home)/repo"
      try makeRepo(repo)
      try b.set(
        "box-config",
        "remote.origin.url https://github.com/box/repo.git\nbranch.feature.remote origin\n")
      try withHostService { service, _ in
        let p = poller(service)
        let onMac = watched("mac", cwd: repo, at: service.mac, configDir: "\(b.home)/account")
        let onBox = watched("box", cwd: repo, at: b.site, configDir: "\(b.home)/account")
        var shared = GitHubPoller.Shared()

        for s in macFirst ? [onMac, onBox] : [onBox, onMac] {
          p.queue.sync { p.refreshLocal(s, all: false, now: nowMs(), shared: &shared) }
        }

        let mac = try #require(p.tracked["mac"]?.branch.key)
        let box = try #require(p.tracked["box"]?.branch.key)
        #expect("\(mac)".contains("mac/repo"), "\(mac)")
        #expect("\(box)".contains("box/repo"), "\(box)")
      }
    }
  }

  /// The box lists another project folder below the same account folder.
  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func onePollListsTheProjectFoldersOfEachSite(macFirst: Bool) throws {
    try withBench { b in
      try b.ready()
      let account = "\(b.home)/account"
      let folder = "\(account)/projects/real"
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      for id in ["mac", "box"] { try Data("{}\n".utf8).write(to: URL(fileURLWithPath: "\(folder)/u-\(id).jsonl")) }
      try b.set("box-list", "elsewhere\0")
      try withHostService { service, _ in
        let p = poller(service)
        let cwd = "\(b.home)/work"
        let onMac = watched("mac", cwd: cwd, at: service.mac, configDir: account)
        let onBox = watched("box", cwd: cwd, at: b.site, configDir: account)
        var shared = GitHubPoller.Shared()

        for s in macFirst ? [onMac, onBox] : [onBox, onMac] {
          p.queue.sync { p.refreshLocal(s, all: false, now: nowMs(), shared: &shared) }
        }

        #expect(p.tracked["mac"]?.transcript.path == "\(folder)/u-mac.jsonl")
        #expect(p.tracked["box"] != nil)
        #expect(p.tracked["box"]?.transcript.path == nil, "the box lists no folder that holds the transcript")
      }
    }
  }

  private func localSession(_ id: String, cwd: String) -> Session {
    var s = Session(id: id, name: id, cwd: cwd, claudeSessionId: "u-\(id)", created: 5)
    s.started = true
    return s
  }

  /// `checkout` answers from what an earlier lookup stored, and looks the folder up off the queue otherwise.
  @Test(.timeLimit(.minutes(1)))
  func theCheckoutThatThisMacStoredDoesNotAnswerForTheSameFolderOnAHost() throws {
    try withHostService { service, home in
      let local = localSession("mac", cwd: "\(home.path)/repo")
      let remote = remoteSession("box", cwd: local.cwd)
      service.queue.sync {
        service.checkouts[SitePath(local.cwd, at: service.mac)] = ("/main/checkout", nowMs())

        #expect(service.checkout(local) == "/main/checkout")
        #expect(service.checkout(remote) == nil)
        #expect(service.checkoutLookups == [SitePath(remote.cwd, at: service.site(for: remote))])
      }
    }
  }

  /// A lookup that found no checkout is not repeated for a minute.
  @Test(.timeLimit(.minutes(1)))
  func aFailedLookupOnAHostDoesNotAnswerForTheSameFolderOnThisMac() throws {
    try withHostService { service, home in
      let local = localSession("mac", cwd: "\(home.path)/repo")
      let remote = remoteSession("box", cwd: local.cwd)
      service.queue.sync {
        service.checkouts[SitePath(remote.cwd, at: service.site(for: remote))] = (nil, nowMs())

        #expect(service.checkout(remote) == nil)
        #expect(service.checkoutLookups.isEmpty, "the host's folder was read less than a minute ago")
        #expect(service.checkout(local) == nil)
        #expect(service.checkoutLookups == [SitePath(local.cwd, at: service.mac)])
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSessionSharesItsFolderOnlyWithASessionAtItsSite() throws {
    try withHostService { service, _ in
      service.queue.sync {
        service.entries["mac"] = Service.Entry(session: localSession("mac", cwd: "/srv/repo"))
        service.entries["box"] = Service.Entry(session: remoteSession("box"))

        #expect(service.sharedSession(service.entries["mac"]!.session) == nil)
        #expect(service.sharedSession(service.entries["box"]!.session) == nil)

        service.entries["box2"] = Service.Entry(session: remoteSession("box2"))
        service.entries["mac2"] = Service.Entry(session: localSession("mac2", cwd: "/srv/repo"))

        #expect(service.sharedSession(service.entries["box"]!.session) == "box2")
        #expect(service.sharedSession(service.entries["mac"]!.session) == "mac2")
      }
    }
  }
}

// MARK: The launch

/// A `Service` whose host mini runs through the bench's ssh wrapper, with setup done.
private func withReadyService(
  host extra: [String: JSON] = [:], config: [String: JSON] = [:],
  _ body: (SiteBench, Service, BoxFacts) throws -> Void
) throws {
  try withBench { b in
    var host: [String: JSON] = [
      "kind": "ssh", "destination": .string(LinkBench.destination), "tmux": .string("\(b.home)/fake-tmux"),
      "claude": "/usr/bin/true",
    ]
    host.merge(extra) { $1 }
    try withHostService(hosts: ["mini": .object(host)], ssh: "\(b.home)/ssh-wrapper", config: config) { service, home in
      try FileManager.default.createDirectory(
        atPath: "\(home.path)/ssh-stub/home", withIntermediateDirectories: true)
      let link = try #require(service.hostLinks["mini"])
      link.connect()
      #expect(waitUntil(seconds: 10) { link.status.state == .connected }, "\(link.status)")
      let facts = try #require(service.remoteSites["mini"]).prepare()
      try body(b, service, facts)
    }
  }
}

/// `--session-id` on a conversation that exists starts it again. The launch picks it only when the host
/// answered that the conversation has no transcript.
@Suite struct RemoteTranscriptLookupTests {
  private func addSession(_ service: Service, _ facts: BoxFacts, transcript: Bool) throws -> Session {
    let cwd = "\(facts.home)/work"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    let session = remoteSession("s1", cwd: cwd)
    if transcript {
      let folder = "\(facts.home)/.claude/projects/elsewhere"
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      try Data("{}\n".utf8).write(to: URL(fileURLWithPath: "\(folder)/u-s1.jsonl"))
    }
    service.queue.sync {
      service.entries["s1"] = Service.Entry(session: session)
      var read = Service.Snapshot()
      read.taken = nowMs()
      read.connection = facts.epoch
      service.install(read, onHost: "mini")
    }
    return session
  }

  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func theLookupReturnsTheHostsAnswer(transcript: Bool) throws {
    try withReadyService { _, service, facts in
      let session = try addSession(service, facts, transcript: transcript)

      #expect(try service.queue.sync { try service.hasTranscript(session) } == transcript)
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["script-status 143", "script-status 127", "script-status 2", "a timeout", "a dropped link"])
  func aLookupThatGotNoAnswerThrowsAndTheLaunchStartsNothing(shape: String) throws {
    try withReadyService { b, service, facts in
      let session = try addSession(service, facts, transcript: true)
      let launcher = "\(facts.home)/.sb/sessions/s1/claude.sh"

      switch shape {
      case "a timeout":
        try b.set("script-hangs", "")
        try b.set("short-timeouts", "")
      case "a dropped link":
        service.hostLinks["mini"]?.disconnect()
      default:
        try b.set("script-status", String(shape.split(separator: " ")[1]))
      }

      #expect { try service.queue.sync { try service.hasTranscript(session) } } throws: { isUnread($0) }
      #expect { try service.queue.sync { try service.startClaude("s1", prompt: nil) } } throws: { isUnread($0) }
      #expect(!FileManager.default.fileExists(atPath: launcher), "no launcher names --session-id or --resume")
      #expect(service.queue.sync { service.paneRow("s1", .claude) } == nil)
    }
  }
}

// MARK: The refusals

@Suite struct RemoteRefusalTests {
  private func merged() -> PullRequest {
    var pr = PullRequest(id: "PR_1", number: 7, url: "u", repo: "mac/repo")
    pr.state = .merged
    return pr
  }

  /// The cleanup checks read git and the folder with no proof that the host answered, so cleanup refuses first.
  @Test(.timeLimit(.minutes(1)))
  func cleanupRefusesASessionOnAHostAndSendsTheHostNothing() throws {
    try withReadyService { b, service, facts in
      var session = remoteSession("s1", cwd: "\(facts.home)/work")
      session.repo = "\(facts.home)/repo"
      session.branch = "feature"
      var entry = Service.Entry(session: session)
      entry.facts.pr = merged()
      service.queue.sync { service.entries["s1"] = entry }
      let sentBefore = b.bench.logText

      let blocker = service.cleanupBlocker("s1", pr: merged())
      #expect(blocker == "sbd can't clean up a worktree on mini yet.")
      do {
        _ = try service.cleanup(["session": "s1"])
        Issue.record("cleanup ran for a session on a host")
      } catch {
        #expect("\(error)" == "sbd can't clean up a worktree on mini yet.", "\(error)")
      }

      #expect(service.queue.sync { service.entries["s1"]?.facts.cleanedUp } == nil)
      #expect(b.bench.logText == sentBefore)
    }
  }

  /// A session with no host and the same record passes that refusal and fails a later check.
  @Test(.timeLimit(.minutes(1)))
  func cleanupOfALocalSessionReachesTheChecksOfItsFolder() throws {
    try withHostService { service, home in
      var session = Session(id: "s1", name: "s1", cwd: "\(home.path)/missing", claudeSessionId: "u-s1", created: 5)
      session.repo = "\(home.path)/repo"
      service.queue.sync { service.entries["s1"] = Service.Entry(session: session) }

      let blocker = try #require(service.cleanupBlocker("s1", pr: merged()))

      #expect(blocker.contains("is gone"), "\(blocker)")
    }
  }

  private func canContinue() -> Verdict { Verdict(state: .canContinue, reason: "it can continue") }

  private func blocker(_ service: Service, _ facts: BoxFacts) -> String? {
    service.queue.sync {
      service.entries["s1"] = Service.Entry(session: remoteSession("s1", cwd: "\(facts.home)/work"))
      var read = Service.Snapshot()
      read.taken = nowMs()
      read.connection = facts.epoch
      service.install(read, onHost: "mini")
      return service.autoContinueBlocker("s1", canContinue(), live: 0, now: nowMs())
    }
  }

  private static let noAccount = "mini names no account in config.json, so its quota can't be checked"

  @Test(.timeLimit(.minutes(1)))
  func autoContinueSkipsASessionWhoseHostNamesNoAccount() throws {
    try withReadyService(config: ["claudeConfigDirs": []]) { _, service, facts in
      #expect(blocker(service, facts) == Self.noAccount)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func autoContinueSkipsASessionWhoseHostNamesAnAccountThatDoesNotResolve() throws {
    try withReadyService(host: ["account": "nobody"], config: ["claudeConfigDirs": []]) { b, service, facts in
      #expect(blocker(service, facts) == Self.noAccount)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func autoContinueChecksTheQuotaOfTheAccountThatTheHostNames() throws {
    let account = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: account) }
    try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(account)/.claude.json"))
    try withReadyService(
      host: ["account": .string(account)], config: ["claudeConfigDirs": [.string(account)]]
    ) { _, service, facts in
      #expect(blocker(service, facts) != Self.noAccount)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func autoContinueSkipsASessionWhoseHostHasNotAnswered() throws {
    try withHostService(config: ["claudeConfigDirs": []]) { service, _ in
      let reason = service.queue.sync {
        service.entries["s1"] = Service.Entry(session: remoteSession("s1"))
        return service.autoContinueBlocker("s1", canContinue(), live: 0, now: nowMs())
      }

      #expect(reason == "mini is not connected")
    }
  }
}
