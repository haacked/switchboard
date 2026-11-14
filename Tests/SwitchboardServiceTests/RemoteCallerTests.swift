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

  /// A follow-up of a host session runs on this Mac. The host's account would give its claude no login.
  @Test(.timeLimit(.minutes(1)))
  func aNewSessionOnThisMacDoesNotTakeTheAccountOfAParentOnAHost() throws {
    try withHostService { service, _ in
      let account = try service.queue.sync {
        service.entries["box"] = Service.Entry(session: remoteSession("box"))
        return try service.accountForNew(named: nil, parent: "box", for: localSession("child", cwd: "/srv/repo"))
      }

      #expect(account == nil)
    }
  }
}

// MARK: The launch

/// A `Service` whose host mini runs through the bench's ssh wrapper, with setup done.
func withReadyService(
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

  /// Triage and the reply lookup read the transcript that the finder names.
  @Test(.timeLimit(.minutes(1)))
  func theFinderOfASessionOnAHostSearchesTheHostsClaudeFolder() throws {
    try withReadyService { _, service, facts in
      _ = try addSession(service, facts, transcript: true)

      let find = service.queue.sync { service.transcriptFinder("s1") }

      #expect(find() == "\(facts.home)/.claude/projects/elsewhere/u-s1.jsonl")
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["script-status 143", "script-status 127", "script-status 2", "a timeout", "a dropped link"])
  func aLookupThatGotNoAnswerThrowsAndTheLaunchStartsNothing(shape: String) throws {
    try withReadyService { b, service, facts in
      let session = try addSession(service, facts, transcript: true)
      let launcher = "\(facts.home)/.sb/sessions/s1/claude.sh"

      try makeUnanswered(shape, b, service)

      #expect { try service.queue.sync { try service.hasTranscript(session) } } throws: { isUnread($0) }
      #expect { try service.queue.sync { try service.startClaude("s1", prompt: nil, trigger: .open) } } throws: {
        isUnread($0)
      }
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

  /// The cleanup checks read the folder on the host, and the host answers that it is gone, so cleanup refuses
  /// and records nothing.
  @Test(.timeLimit(.minutes(1)))
  func cleanupRefusesASessionWhoseFolderTheHostReportsGone() throws {
    try withReadyService { _, service, facts in
      var session = remoteSession("s1", cwd: "\(facts.home)/work")
      session.repo = "\(facts.home)/repo"
      session.branch = "feature"
      var entry = Service.Entry(session: session)
      entry.facts.pr = merged()
      service.queue.sync { service.entries["s1"] = entry }
      let gone = "\(facts.home)/work is gone. `sb rm --worktree` removes the session and the worktree's record."

      let blocker = service.cleanupBlocker("s1", pr: merged())
      #expect(blocker == gone)
      do {
        _ = try service.cleanup(["session": "s1"], caller: .inProcess)
        Issue.record("cleanup ran for a session whose folder is gone on its host")
      } catch {
        #expect("\(error)" == gone, "\(error)")
      }

      #expect(service.queue.sync { service.entries["s1"]?.facts.cleanedUp } == nil)
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
      // A session on a host reads its snapshot only on a connection whose reconcile finished.
      service.reconciledOn["mini"] = facts.epoch
      service.install(read, onHost: "mini")
      return service.autoContinueBlocker("s1", canContinue(), live: 0, now: nowMs())
    }
  }

  private static let noAccount = "mini names no account in config.json, so its quota can't be checked"

  /// A quota that only `account` has spent.
  private struct SpentFor: QuotaBudget {
    let account: String
    func hasBudget(account: String) -> Bool { account != self.account }
  }

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
      let resolved = try service.queue.sync { try service.resolveAccount(account) }
      service.quota = SpentFor(account: resolved)

      #expect(blocker(service, facts) == "no quota left for \(resolved)")
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

// MARK: The screen and the paste

/// The ways a `/bin/sh -c` command can come back with no answer from the host.
private func makeUnanswered(_ shape: String, _ b: SiteBench, _ service: Service) throws {
  switch shape {
  case "a timeout":
    try b.set("script-hangs", "")
    try b.set("short-timeouts", "")
  case "a dropped link":
    service.hostLinks["mini"]?.disconnect()
  default:
    try b.set("script-status", String(shape.split(separator: " ")[1]))
  }
}

/// A tmux that prints `screen` for `capture-pane`, or fails with `refusal` when that is set. While the folder
/// that `body` gets holds a file named `hang`, a capture runs until its timeout ends it.
private func withScreenTmux(
  _ screen: String, refusal: String? = nil, _ body: (SiteBench, Service, String) throws -> Void
) throws {
  let folder = try makeShortTempFolder()
  defer { try? FileManager.default.removeItem(atPath: folder) }
  try Data(screen.utf8).write(to: URL(fileURLWithPath: "\(folder)/screen"))
  let prints = refusal.map { "printf '%s\\n' \(shellQuote($0)) >&2; exit 1" } ?? "cat \(shellQuote("\(folder)/screen"))"
  let script = """
    #!/bin/sh
    case " $* " in
    *" capture-pane "*)
      if [ -f \(shellQuote("\(folder)/hang")) ]; then exec /bin/sleep 20; fi
      \(prints)
      ;;
    esac
    exit 0

    """
  try Data(script.utf8).write(to: URL(fileURLWithPath: "\(folder)/tmux"))
  chmod("\(folder)/tmux", 0o755)
  try withReadyService(host: ["tmux": .string("\(folder)/tmux")]) { b, service, _ in try body(b, service, folder) }
}

/// A machine that answers every command with one result.
private struct CannedMachine: Machine {
  var result: CommandResult

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult { result }
  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? { nil }
  func size(_ path: String) -> UInt64? { nil }
  func exists(_ path: String) -> Bool { false }
  func isFolder(_ path: String) -> Bool { false }
  func modified(_ path: String) -> Date? { nil }
  func list(_ folder: String) -> [String] { [] }
  func createFolder(_ path: String) throws {}
  func signal(_ pid: Int, _ signal: Int32) {}
}

/// A screen of a pane on a host decides whether a dialog closed and whether the prompt box is empty. A tmux
/// command that its timeout ends exits 0 with no output, which must not read as an empty screen.
@Suite struct RemoteScreenGuardTests {
  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["one line", "two\nlines\n", "ends in blank lines\n\n\n", "", "\n", "x", "  spaces  \n", "ünï ✓\n"])
  func theScreenIsTheTextThatTheHostsTmuxPrinted(screen: String) throws {
    try withScreenTmux(screen) { _, service, _ in
      let site = try #require(service.remoteSites["mini"])

      #expect(try site.screen("s1-claude") == screen)
      #expect(try site.screen("s1-claude", colors: true) == screen)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["a capture that its timeout ends", "a dropped link"])
  func aScreenReadThatGotNoAnswerThrowsHostUnread(shape: String) throws {
    try withScreenTmux("a screen\n") { b, service, folder in
      let site = try #require(service.remoteSites["mini"])
      if shape == "a dropped link" {
        service.hostLinks["mini"]?.disconnect()
      } else {
        try Data().write(to: URL(fileURLWithPath: "\(folder)/hang"))
        try b.set("short-timeouts", "")
      }

      #expect { try site.screen("s1-claude") } throws: { isUnread($0) }
    }
  }

  /// The first is what a tmux command gives when its timeout ends it: status 0 and no output.
  @Test(arguments: ["", "0", "0\0", "0\0a screen", "0\0a screen\0", "0\0a screenx", "\0\0", "a screenx\0", "0\0\0"])
  func outputThatIsNotInTheAnsweredFormNeverReadsAsAScreen(output: String) throws {
    let terminals = TerminalHost(
      tmux: "/usr/bin/tmux", socket: "/tmp/s", conf: "/tmp/c", shell: "/bin/sh", baseEnv: [:], timeout: 5,
      machine: CannedMachine(result: CommandResult(status: 0, stdout: "", stderr: "")))
    let machine = CannedMachine(result: CommandResult(status: 0, stdout: output, stderr: ""))

    #expect(throws: (any Error).self) { try terminals.answeredScreen("s1-claude", on: machine) }
  }

  @Test(arguments: [(Int32(0), "0\0a screen\nx\0", "a screen\n"), (0, "0\0x\0", "")])
  func outputInTheAnsweredFormIsTheScreen(status: Int32, output: String, screen: String) throws {
    let machine = CannedMachine(result: CommandResult(status: status, stdout: output, stderr: ""))
    let terminals = TerminalHost(
      tmux: "/usr/bin/tmux", socket: "/tmp/s", conf: "/tmp/c", shell: "/bin/sh", baseEnv: [:], timeout: 5,
      machine: machine)

    #expect(try terminals.answeredScreen("s1-claude", on: machine) == screen)
  }

  @Test(arguments: [(Int32(143), "0\0a screenx\0"), (1, "0\0a screenx\0"), (0, "1\0no serverx\0")])
  func aFailedCaptureThrows(status: Int32, output: String) throws {
    let machine = CannedMachine(result: CommandResult(status: status, stdout: output, stderr: ""))
    let terminals = TerminalHost(
      tmux: "/usr/bin/tmux", socket: "/tmp/s", conf: "/tmp/c", shell: "/bin/sh", baseEnv: [:], timeout: 5,
      machine: machine)

    #expect(throws: (any Error).self) { try terminals.answeredScreen("s1-claude", on: machine) }
  }

  @Test(.timeLimit(.minutes(1)))
  func aCaptureThatTmuxRefusesThrowsTmuxsText() throws {
    try withScreenTmux("", refusal: "can't find session: s1-claude") { _, service, _ in
      let site = try #require(service.remoteSites["mini"])

      #expect {
        try site.screen("s1-claude")
      } throws: { "\($0)".contains("can't find session: s1-claude") }
    }
  }

  /// `dialogClosed` lets a paste follow an Escape. A screen that got no answer shows no dialog, and must not
  /// count as a closed one.
  @Test(.timeLimit(.minutes(1)))
  func aDialogDoesNotCountAsClosedFromAScreenThatGotNoAnswer() throws {
    try withScreenTmux("no dialog here\n") { b, service, folder in
      service.queue.sync { service.entries["s1"] = Service.Entry(session: remoteSession("s1")) }
      let card = Card(
        Event(
          id: 1, session: "s1", t: 0, kind: "PermissionRequest",
          data: ["tool_name": "Bash", "tool_input": ["command": "touch x"]]))

      let answered = service.queue.sync { service.dialogClosed(card) }
      try Data().write(to: URL(fileURLWithPath: "\(folder)/hang"))
      try b.set("short-timeouts", "")
      let unanswered = service.queue.sync { service.dialogClosed(card) }

      #expect(answered)
      #expect(!unanswered)
    }
  }
}

/// A paste records the transcript's size first, and a restart looks for the message after that size.
@Suite struct RemotePasteGuardTests {
  private func addSession(_ service: Service, _ facts: BoxFacts) throws {
    let cwd = "\(facts.home)/work"
    let folder = "\(facts.home)/.claude/projects/elsewhere"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: URL(fileURLWithPath: "\(folder)/u-s1.jsonl"))
    service.queue.sync { service.entries["s1"] = Service.Entry(session: remoteSession("s1", cwd: cwd)) }
  }

  private func pastings(_ service: Service) throws -> [Event] {
    try service.queue.sync { try service.store.events(session: "s1").filter { $0.kind == "pasting" } }
  }

  @Test(.timeLimit(.minutes(1)))
  func aPasteRecordsTheTranscriptsPathAndSizeThatTheHostAnswered() throws {
    try withReadyService { _, service, facts in
      try addSession(service, facts)

      let started = service.queue.sync { service.startPaste("s1", Service.QueuedMessage(text: "hello")) }

      #expect(started)
      let pasting = try #require(try pastings(service).first)
      #expect(pasting.data["text"] == "hello")
      #expect(pasting.data["transcript"]?.string?.hasSuffix("/u-s1.jsonl") == true)
      #expect(pasting.data["transcript_bytes"] == 3)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["script-status 143", "script-status 127", "a timeout", "a dropped link"])
  func aPasteWhoseTranscriptSizeGotNoAnswerDoesNotStartAndRequeuesItsMessage(shape: String) throws {
    try withReadyService { b, service, facts in
      try addSession(service, facts)
      try makeUnanswered(shape, b, service)

      let started = service.queue.sync { service.startPaste("s1", Service.QueuedMessage(text: "hello")) }

      #expect(!started)
      #expect(try pastings(service).isEmpty, "a paste started with a transcript size that the host did not answer")
      #expect(service.queue.sync { service.entries["s1"]?.pending.map(\.text) } == ["hello"])
    }
  }
}

// MARK: Setup of the hooks

/// What setup leaves on the host for the hooks of its claudes, and the forward that it asks ssh for.
@Suite struct BoxShimSetupTests {
  private func inode(_ path: String) -> UInt64? {
    var info = stat()
    return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
  }

  private func mode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
  }

  /// Drops the link, connects it again, and runs setup on the new connection.
  private func reconnect(_ service: Service) throws -> BoxFacts {
    let link = try #require(service.hostLinks["mini"])
    let before = link.status.connection
    link.disconnect()
    link.connect()
    #expect(waitUntil(seconds: 10) { link.status.state == .connected && link.status.connection > before })
    return try #require(service.remoteSites["mini"]).prepare()
  }

  @Test(.timeLimit(.minutes(1)))
  func setupWritesTheShimAndTheSettingsForTheUserOnly() throws {
    try withReadyService { _, service, facts in
      let shim = "\(facts.home)/.sb/bin/sb-shim"
      let settings = "\(facts.home)/.sb/claude-settings.json"

      let shimText = try String(contentsOfFile: shim, encoding: .utf8)
      let settingsText = try String(contentsOfFile: settings, encoding: .utf8)
      #expect(shimText == BoxShim.source)
      #expect(settingsText == BoxShim.settings(for: facts))
      #expect(mode(shim) == 0o700)
      #expect(mode(settings) == 0o600)
      let command = JSON.parse(BoxShim.settings(for: facts))?["hooks"]?["Stop"]?.array?.first?["hooks"]?.array?.first?[
        "command"]?.string
      #expect(command == "\(shellQuote(facts.python)) \(shellQuote(shim)) hook")
      var info = stat()
      #expect(lstat("\(facts.home)/.sb/sbd.sock", &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)
    }
  }

  /// Setup writes a file only when its text differs.
  @Test(.timeLimit(.minutes(1)))
  func theNextConnectionKeepsAFileWhoseTextIsTheSameAndReplacesOneThatDiffers() throws {
    try withReadyService { _, service, facts in
      let shim = "\(facts.home)/.sb/bin/sb-shim"
      let settings = "\(facts.home)/.sb/claude-settings.json"
      try "# an older shim\n".write(toFile: shim, atomically: false, encoding: .utf8)
      let (oldShim, oldSettings) = (inode(shim), inode(settings))

      _ = try reconnect(service)

      #expect(try String(contentsOfFile: shim, encoding: .utf8) == BoxShim.source)
      #expect(inode(shim) != oldShim)
      #expect(mode(shim) == 0o700)
      #expect(inode(settings) == oldSettings, "setup wrote a settings file whose text was the same")
      var info = stat()
      #expect(lstat("\(facts.home)/.sb/sbd.sock", &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)
    }
  }

  /// ssh reads a colon as the end of a path, so a forward of such a path would bind another one.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ("/tmp/a:b/sbd.sock", "/tmp/x.sock"), ("/tmp/a.sock", "/tmp/x:y.sock"),
      ("relative/a.sock", "/tmp/x.sock"), ("/tmp/a.sock", "x.sock"), ("", "/tmp/x.sock"),
    ])
  func aForwardOfAPathThatSshWouldMisreadIsRefusedBeforeSshRuns(remote: String, local: String) throws {
    try withReadyService { b, service, _ in
      let link = try #require(service.hostLinks["mini"])
      let before = b.bench.logText

      #expect(throws: (any Error).self) { try link.forward(remote: remote, local: local) }

      #expect(b.bench.logText == before, "sbd ran ssh for a forward that it refused")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aForwardOnALinkThatIsNotConnectedThrows() throws {
    try withHostService { service, _ in
      let link = try #require(service.hostLinks["mini"])

      #expect(throws: (any Error).self) { try link.forward(remote: "/tmp/a.sock", local: "/tmp/b.sock") }
    }
  }
}

// MARK: Removal and cleanup

/// A `Service` like `withReadyService`'s, whose box runs git through a wrapper. The wrapper exits 143 with no output,
/// as a command that its timeout ended does, for a run whose arguments hold the text of the home's `git-end-word`
/// file. It runs git otherwise. Setup finds the wrapper, so it is in place before setup runs.
private func withRemovalService(_ body: (SiteBench, Service, BoxFacts) throws -> Void) throws {
  try withBench { b in
    let path = "\(b.home)/box-bin/git"
    let script = """
      #!/bin/sh
      d=\(shellQuote(b.home))
      if [ -f "$d/git-end-word" ]; then
        case " $* " in *"$(cat "$d/git-end-word")"*) exit 143 ;; esac
      fi
      exec /usr/bin/git "$@"

      """
    try Data(script.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
    let host: [String: JSON] = [
      "kind": "ssh", "destination": .string(LinkBench.destination), "tmux": .string("\(b.home)/fake-tmux"),
      "claude": "/usr/bin/true",
    ]
    try withHostService(hosts: ["mini": .object(host)], ssh: "\(b.home)/ssh-wrapper") { service, home in
      try FileManager.default.createDirectory(atPath: "\(home.path)/ssh-stub/home", withIntermediateDirectories: true)
      let link = try #require(service.hostLinks["mini"])
      link.connect()
      #expect(waitUntil(seconds: 10) { link.status.state == .connected }, "\(link.status)")
      let facts = try #require(service.remoteSites["mini"]).prepare()
      #expect(facts.git.hasSuffix("/box-bin/git"), "setup did not find the box's git wrapper: \(facts.git)")
      try body(b, service, facts)
    }
  }
}

/// Holds the session in the service, with the host's snapshot installed on a connection whose reconcile finished,
/// so the session does not read `.unknown`.
private func hold(_ entry: Service.Entry, in service: Service, _ facts: BoxFacts, snapshot: Service.Snapshot = .init())
{
  service.queue.sync {
    service.entries[entry.session.id] = entry
    var read = snapshot
    read.taken = nowMs()
    read.connection = facts.epoch
    service.reconciledOn["mini"] = facts.epoch
    service.install(read, onHost: "mini")
  }
}

/// The cleanup checks of a session on a host run on the host. Each check that gets no answer blocks the cleanup,
/// though its empty output would read as a pass: an empty `git status` reads as a clean folder.
@Suite struct RemoteCleanupCheckTests {
  /// A repo on the box on main, and a linked worktree of it on `topic` with one commit, which a merged PR has at
  /// its head. The commit is on no remote, which the merged PR allows.
  private func addSession(_ service: Service, _ facts: BoxFacts) throws {
    let repo = "\(facts.home)/repo"
    try makeRepo(repo)
    try sh(
      "git checkout -q main && git worktree add -q -b topic ../topic-tree && cd ../topic-tree"
        + " && git commit -q --allow-empty -m work", in: repo)
    let tree = "\(facts.home)/topic-tree"
    let tip = try runCommand("/usr/bin/git", ["-C", tree, "rev-parse", "HEAD"]).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var session = remoteSession("s1", cwd: tree)
    session.repo = repo
    session.branch = "topic"
    var entry = Service.Entry(session: session)
    entry.facts.pr = PullRequest(
      id: "PR_1", number: 7, url: "https://github.com/mac/repo/pull/7", repo: "mac/repo", state: .merged,
      head: "topic", headSha: tip)
    hold(entry, in: service, facts)
  }

  private func blocker(_ service: Service) -> String? {
    guard let pr = service.queue.sync(execute: { service.entries["s1"]?.facts.pr }) else { return "no PR" }
    return service.cleanupBlocker("s1", pr: pr)
  }

  @Test(.timeLimit(.minutes(1)))
  func aCleanWorktreeOnTheHostWhosePRMergedHasNoBlocker() throws {
    try withRemovalService { _, service, facts in
      try addSession(service, facts)

      #expect(blocker(service) == nil)
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "status --porcelain", "ls-files -v", "rev-list --count", "worktree list", "branch --show-current",
      "rev-parse HEAD",
    ])
  func aCheckThatGotNoAnswerBlocksTheCleanup(word: String) throws {
    try withRemovalService { b, service, facts in
      try addSession(service, facts)
      try b.set("git-end-word", word)

      #expect(blocker(service) != nil, "cleanup could run though `git \(word)` got no answer")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aDroppedLinkBlocksTheCleanupWithTheHostsName() throws {
    try withRemovalService { _, service, facts in
      try addSession(service, facts)
      service.hostLinks["mini"]?.disconnect()

      let reason = try #require(blocker(service))

      #expect(reason.contains("mini"), "\(reason)")
    }
  }

  /// A host's folder is not gone because a check got no answer.
  @Test(.timeLimit(.minutes(1)))
  func aFolderCheckThatGotNoAnswerDoesNotReportTheFolderGone() throws {
    try withRemovalService { b, service, facts in
      try addSession(service, facts)
      try b.set("script-status", "143")

      let reason = try #require(blocker(service))

      #expect(!reason.contains("is gone"), "\(reason)")
    }
  }
}

/// The pane stop of a remote session's removal: sbd signals only the session's claude, waits for the session's
/// processes on the host, and refuses when the host does not answer.
@Suite struct RemotePaneStopTests {
  /// A remote session whose Claude pane runs `command` below it, and whose host snapshot names that child as the
  /// session's claude. The host's claude is `/usr/bin/true`, so a `sleep` child is not claude.
  private func addSession(
    _ b: SiteBench, _ service: Service, _ facts: BoxFacts, running command: String = "sleep 300"
  ) throws -> (Session, SiteBench.Tree) {
    let tree = try b.tree(command)
    try b.setPanes([("s1-claude", tree.pane, false)])
    let folder = "\(facts.home)/work"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let session = remoteSession("s1", cwd: folder)
    var read = Service.Snapshot()
    read.panes["s1-claude"] = PaneRow(pid: tree.pane, dead: false, clients: 0)
    read.claudePids["s1"] = tree.child
    read.children = [tree.pane: [ProcessRow(pid: tree.child, ppid: tree.pane, pgid: tree.pane, command: command)]]
    hold(Service.Entry(session: session), in: service, facts, snapshot: read)
    return (session, tree)
  }

  /// Puts this Mac's lsof on the box's PATH. macOS keeps lsof in /usr/sbin.
  private func addLsof(_ b: SiteBench) throws {
    let path = "\(b.home)/box-bin/lsof"
    try Data("#!/bin/sh\nexec /usr/sbin/lsof \"$@\"\n".utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
  }

  @Test(.timeLimit(.minutes(1)))
  func theStopOfTheRemovalSignalsNoProcessThatIsNotTheSessionsClaude() throws {
    try withReadyService { b, service, facts in
      let (_, tree) = try addSession(b, service, facts)

      #expect {
        try service.queue.sync { try service.beginPaneStop("s1", ancestry: nil, command: "sb rm --worktree") }
      } throws: { "\($0)".contains("the claude process changed") }

      #expect(b.stillRuns(tree.child))
      #expect(b.runs(tree.pane))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theWaitForTheSessionsProcessesThrowsHostUnreadWhenTheLinkDroppedAndSignalsNothing() throws {
    try withReadyService { b, service, facts in
      let (session, tree) = try addSession(b, service, facts)
      service.hostLinks["mini"]?.disconnect()

      #expect {
        try service.finishPaneStop(
          session, PaneStop(claudePid: nil, processes: [tree.child]), command: "sb rm --worktree")
      } throws: { isUnread($0) }

      #expect(b.stillRuns(tree.child))
    }
  }

  /// sbd waits 5 s for the session's processes, then refuses and leaves them running.
  @Test(.timeLimit(.minutes(1)))
  func theWaitRefusesWhileAProcessOfTheSessionStillRunsOnTheHostAndLeavesItRunning() throws {
    try withReadyService { b, service, facts in
      try addLsof(b)
      let (session, tree) = try addSession(b, service, facts)

      #expect {
        try service.finishPaneStop(
          session, PaneStop(claudePid: nil, processes: [tree.child]), command: "sb rm --worktree")
      } throws: { "\($0)".contains("still run") }

      #expect(b.stillRuns(tree.child))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theWaitReturnsOnceTheSessionsProcessesExitedAndNoProcessUsesTheFolder() throws {
    try withReadyService { b, service, facts in
      try addLsof(b)
      let (session, tree) = try addSession(b, service, facts)
      kill(pid_t(tree.child), SIGKILL)
      try b.bench.waitForExit(Int32(tree.child))

      try service.finishPaneStop(
        session, PaneStop(claudePid: nil, processes: [tree.child]), command: "sb rm --worktree")
    }
  }

  /// The box has neither /proc nor lsof, so sbd can't tell whether a process still writes to the folder.
  @Test(.timeLimit(.minutes(1)))
  func theWaitRefusesWhenTheHostCantCheckWhichProcessesUseTheFolder() throws {
    try withReadyService { b, service, facts in
      let (session, tree) = try addSession(b, service, facts)
      kill(pid_t(tree.child), SIGKILL)
      try b.bench.waitForExit(Int32(tree.child))

      #expect {
        try service.finishPaneStop(
          session, PaneStop(claudePid: nil, processes: [tree.child]), command: "sb rm --worktree")
      } throws: { "\($0)".contains("can't check which processes use \(session.cwd) on mini") }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theWaitRefusesWhileAProcessThatTheSessionDidNotStartUsesTheFolderOnTheHost() throws {
    try withReadyService { b, service, facts in
      try addLsof(b)
      let (session, tree) = try addSession(b, service, facts)
      kill(pid_t(tree.child), SIGKILL)
      try b.bench.waitForExit(Int32(tree.child))
      let user = Process()
      user.executableURL = URL(fileURLWithPath: "/bin/sleep")
      user.arguments = ["30"]
      user.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
      try user.run()
      defer { user.terminate() }

      #expect {
        try service.finishPaneStop(
          session, PaneStop(claudePid: nil, processes: [tree.child]), command: "sb rm --worktree")
      } throws: { "\($0)".contains(String(user.processIdentifier)) }

      #expect(user.isRunning)
    }
  }
}

/// A removal closes a remote session's panes from answers of the host. `TerminalHost.kill` reads a close that got
/// no answer as done, so the removal never uses it for a pane on a host.
@Suite struct RemotePaneCloseTests {
  /// A host whose tmux answers `kill-session` as the file `kill` in the folder says: `gone` prints tmux's own
  /// "can't find session", `ended` exits 143 with no output, as a command that its timeout ended does.
  private func withKillTmux(_ body: (Service, String) throws -> Void) throws {
    let folder = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let kill = shellQuote("\(folder)/kill")
    let script = """
      #!/bin/sh
      case " $* " in
      *" kill-session "*)
        case $(cat \(kill) 2>/dev/null) in
        gone) echo "can't find session: nope" >&2; exit 1 ;;
        ended) exit 143 ;;
        esac
        ;;
      esac
      exit 0

      """
    try Data(script.utf8).write(to: URL(fileURLWithPath: "\(folder)/tmux"))
    chmod("\(folder)/tmux", 0o755)
    try withReadyService(host: ["tmux": .string("\(folder)/tmux")]) { _, service, facts in
      service.queue.sync { service.entries["s1"] = Service.Entry(session: remoteSession("s1", cwd: facts.home)) }
      try body(service, folder)
    }
  }

  private func close(_ service: Service) throws {
    try service.queue.sync { try service.closePane("s1", .claude, at: try service.site(of: "s1")) }
  }

  @Test(.timeLimit(.minutes(1)))
  func aPaneThatTmuxClosedOrNeverHadIsClosed() throws {
    try withKillTmux { service, folder in
      try close(service)
      try Data("gone".utf8).write(to: URL(fileURLWithPath: "\(folder)/kill"))
      try close(service)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aCloseThatGotNoAnswerThrows() throws {
    try withKillTmux { service, folder in
      try Data("ended".utf8).write(to: URL(fileURLWithPath: "\(folder)/kill"))

      #expect(throws: (any Error).self) { try close(service) }
    }
  }

  /// Holds s1 with a live shell pane in the host's snapshot.
  private func holdShell(_ service: Service) throws {
    let facts = try #require(service.remoteSites["mini"]?.facts)
    var read = Service.Snapshot()
    read.panes["s1-shell"] = PaneRow(pid: 42, dead: false, clients: 0)
    hold(try #require(service.queue.sync { service.entries["s1"] }), in: service, facts, snapshot: read)
    try #require(service.queue.sync { service.paneRow("s1", .shell) } != nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func aShellCloseThatTheHostAnsweredDropsThePane() throws {
    try withKillTmux { service, _ in
      try holdShell(service)

      try service.queue.sync { try service.closeShell("s1") }

      #expect(service.queue.sync { service.paneRow("s1", .shell) } == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aShellCloseThatGotNoAnswerThrowsAndKeepsThePane() throws {
    try withKillTmux { service, folder in
      try holdShell(service)
      try Data("ended".utf8).write(to: URL(fileURLWithPath: "\(folder)/kill"))

      #expect(throws: (any Error).self) { try service.queue.sync { try service.closeShell("s1") } }
      #expect(service.queue.sync { service.paneRow("s1", .shell) } != nil)
    }
  }
}

/// A remote session that `rm` stopped and has not forgotten yet. sbd launches nothing for it, because sbd closes no
/// pane on a host after it forgets the session.
@Suite struct RemoteRemovingTests {
  private func addSession(_ service: Service, _ facts: BoxFacts, queuedSince: Int64? = nil) throws {
    let cwd = "\(facts.home)/work"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    var entry = Service.Entry(session: remoteSession("s1", cwd: cwd))
    entry.queuedSince = queuedSince
    hold(entry, in: service, facts)
  }

  private func launcher(_ facts: BoxFacts) -> String { "\(facts.folder)/sessions/s1/claude.sh" }

  @Test(.timeLimit(.minutes(1)))
  func aMessageToASessionThatRmIsRemovingLaunchesNothingAndStoresNoMessage() throws {
    try withReadyService { _, service, facts in
      try addSession(service, facts)
      service.queue.sync { _ = service.removing.insert("s1") }

      #expect { try service.queue.sync { try service.send("s1", "hello", trigger: .send) } } throws: {
        "\($0)".contains("is being removed")
      }

      #expect(!FileManager.default.fileExists(atPath: launcher(facts)))
      let sent = try service.queue.sync { try service.store.events(session: "s1").filter { $0.kind == "sent" } }
      #expect(sent.isEmpty)
      #expect(service.queue.sync { service.entries["s1"]?.pending.isEmpty } == true)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aQueuedStartOfASessionThatRmIsRemovingKeepsItsPlaceAndLaunchesNothing() throws {
    try withReadyService { _, service, facts in
      try addSession(service, facts, queuedSince: 1_000)
      service.queue.sync { _ = service.removing.insert("s1") }

      service.queue.sync { service.runQueuedStarts(now: nowMs()) }

      #expect(!FileManager.default.fileExists(atPath: launcher(facts)))
      #expect(service.queue.sync { service.entries["s1"]?.queuedSince } == 1_000)
    }
  }

  /// The host gives no answer to the start's commands. It may answer later, so the start keeps its place.
  @Test(.timeLimit(.minutes(1)))
  func aQueuedStartThatTheHostGaveNoAnswerKeepsItsPlace() throws {
    try withReadyService { b, service, facts in
      try addSession(service, facts, queuedSince: 1_000)
      try b.set("script-status", "143")

      service.queue.sync { service.runQueuedStarts(now: nowMs()) }

      #expect(!FileManager.default.fileExists(atPath: launcher(facts)))
      #expect(service.queue.sync { service.entries["s1"]?.queuedSince } == 1_000)
    }
  }
}

/// A link at the box's folder, its `sessions`, or a launcher folder would lead the write of claude.sh into the
/// folder that it leads to.
@Suite struct RemoteLauncherLinkTests {
  @Test(.timeLimit(.minutes(1)), arguments: [".sb", ".sb/sessions", ".sb/sessions/s1"])
  func theLauncherWriteRefusesALinkAndWritesNothingWhereItLeads(linked: String) throws {
    try withReadyService { b, service, facts in
      let target = "\(b.home)/elsewhere"
      try replaceWithLink("\(facts.home)/\(linked)", to: target, keeping: "\(b.home)/moved")
      let site = try #require(service.remoteSites["mini"])

      #expect(throws: (any Error).self) { try service.writeLauncher("exec claude\n", for: "s1", at: site) }

      #expect(try paths(inside: target).isEmpty)
    }
  }
}

/// The turn check runs `claude agents` on the host through the shell that starts the Claude pane, with the same
/// flags, so both find the same claude.
@Suite struct RemoteTurnCheckShellTests {
  /// A box whose bash finds `sb-rc-claude` only through `.bashrc`, as Ubuntu's `.profile` and `.bashrc` give an
  /// nvm or npm claude. `.bashrc` returns early unless the shell is interactive, and then runs `rcOutput`.
  private func writeRcFiles(_ home: String, rcOutput: String) throws {
    try FileManager.default.createDirectory(atPath: "\(home)/rc-bin", withIntermediateDirectories: true)
    let claude = "\(home)/rc-bin/sb-rc-claude"
    try Data(
      """
      #!/bin/sh
      [ "$1" = agents ] || exit 2
      echo '[{"sessionId":"u-s1","cwd":"/w","status":"idle"}]'

      """.utf8
    ).write(to: URL(fileURLWithPath: claude))
    chmod(claude, 0o755)
    try Data("if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n".utf8)
      .write(to: URL(fileURLWithPath: "\(home)/.bash_profile"))
    try Data(
      """
      case $- in *i*) ;; *) return ;; esac
      \(rcOutput)
      PATH=$HOME/rc-bin:$PATH

      """.utf8
    ).write(to: URL(fileURLWithPath: "\(home)/.bashrc"))
  }

  /// An interactive shell ignores the SIGTERM of the host's timeout, so a slow rc file ends only with the
  /// SIGKILL 2 s later. The box's `wc`, which builds each answer, then takes 1.5 s more, as a slow round trip
  /// does. The answer still arrives before the local deadline, so the link stays on its connection, and the run
  /// reads as unanswered.
  @Test(.timeLimit(.minutes(1)))
  func aTurnCheckWhoseRcFileOutlastsTheTimeoutKeepsTheLinkAndReadsAsUnanswered() throws {
    try withReadyService(host: ["shell": "/bin/bash", "claude": "sb-rc-claude"]) { b, service, facts in
      try writeRcFiles(facts.home, rcOutput: "/bin/sleep 8")
      let wc = "\(b.home)/box-bin/wc"
      try Data(
        """
        #!/bin/sh
        if [ -f \(shellQuote(b.home))/slow-answer ]; then /bin/sleep 1.5; fi
        exec /usr/bin/wc "$@"

        """.utf8
      ).write(to: URL(fileURLWithPath: wc))
      chmod(wc, 0o755)
      let site = try #require(service.remoteSites["mini"])
      try b.set("slow-answer", "")
      defer { try? FileManager.default.removeItem(atPath: "\(b.home)/slow-answer") }

      #expect { try service.agentRows(at: site, seen: 1, timeout: 1) } throws: { $0 is HostUnread }

      #expect(site.link.status.state == .connected)
      #expect(site.link.status.connection == facts.epoch)
      #expect(site.facts?.epoch == facts.epoch)
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "", #"echo '[{"sessionId":"u-rc","cwd":"/"}]'; echo 'Welcome to mini'; printf 'no newline'"#,
    ])
  func aRemoteTurnCheckFindsTheClaudeThatOnlyTheInteractiveRcFilePutsOnThePath(rcOutput: String) throws {
    try withReadyService(host: ["shell": "/bin/bash", "claude": "sb-rc-claude"]) { _, service, facts in
      try writeRcFiles(facts.home, rcOutput: rcOutput)
      let site = try #require(service.remoteSites["mini"])

      let rows = try service.agentRows(at: site, seen: 1, timeout: 15)

      #expect(rows.map(\.id) == ["u-s1"])
      #expect(rows.first?.status == "idle")
    }
  }
}
