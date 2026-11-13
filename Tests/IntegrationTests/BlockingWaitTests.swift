import Foundation
import SwitchboardCore
import Testing

/// `sb wait --block` sets a wait, waits for sbd to resolve it, prints the
/// `wait-resolved` event, and exits 0 resolved, 2 timed out, 3 sbd
/// unreachable, or 1 for anything else.
@Suite(.blocking(timeLimit: .seconds(120))) struct BlockingWaitTests {
  static let charts = "PostHog/charts"
  static let branch = "haacked/cdp-dlq-runbook-lookup-step"

  /// A session on the branch of PostHog/charts#18303, whose PR the poller has read.
  func chartsSession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: BlockingWaitTests.charts, branch: BlockingWaitTests.branch)
    try sbd.poll()
    return s
  }

  /// Starts `sb wait` with the arguments in the background.
  func block(_ sbd: Instance, _ args: [String], env: [String: String] = [:]) throws -> BackgroundSb {
    try BackgroundSb(sbd, ["wait"] + args, env: env)
  }

  /// Waits until the session shows the blocked wait, checks that sb still
  /// blocks, and returns the wait's id. `others` are the ids of the session's
  /// waits from before.
  func blockedWaitId(_ sbd: Instance, _ s: SessionSummary, _ blocked: BackgroundSb, others: [String] = [])
    throws -> String
  {
    let waiting = try sbd.waitFor(s.id, "the blocked wait") { $0.waits.count == others.count + 1 }
    try #require(blocked.isRunning, "sb wait --block exited before its wait resolved")
    return try #require(waiting.waits.first { !others.contains($0.id) }?.id)
  }

  /// A blocked manual wait on the session, and its id.
  func blockOnManual(_ sbd: Instance, _ s: SessionSummary, env: [String: String] = [:], others: [String] = [])
    throws -> (BackgroundSb, String)
  {
    let blocked = try block(sbd, [s.id, "--block", "--kind", "manual", "--note", "ask Alex"], env: env)
    return (blocked, try blockedWaitId(sbd, s, blocked, others: others))
  }

  /// Checks that sbd sent the session nothing after `mark`, and that its state
  /// and reason are those of `idle`.
  func expectUntouched(_ sbd: Instance, _ s: SessionSummary, like idle: SessionSummary, after mark: Int64) throws {
    let after = try kinds(sbd, s, after: mark)
    #expect(!after.contains("sent"))
    #expect(!after.contains("UserPromptSubmit"))
    let session = try sbd.get(s.id)
    #expect(session.waits.isEmpty)
    #expect(session.state == idle.state)
    #expect(session.reason == idle.reason)
  }

  /// The kinds of the session's events after `mark`.
  func kinds(_ sbd: Instance, _ s: SessionSummary, after mark: Int64) throws -> [String] {
    try sbd.events(s.id, after: mark).map(\.kind)
  }

  func event(_ stdout: String) throws -> Event {
    try JSONCoding.decode(Event.self, from: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  // MARK: Resolution

  /// The skills run `sb wait --block` inside the session, with no session argument.
  @Test func aBlockedManualWaitPrintsTheResolvedEventAndSendsNoMessage() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let idle = try sbd.get(s.id)
    let blocked = try block(
      sbd, ["--block", "--kind", "manual", "--note", "ask Alex"], env: ["SB_SESSION_ID": s.id, "CLAUDECODE": "1"])
    let id = try blockedWaitId(sbd, s, blocked)
    let before = try sbd.lastEventId(s.id)

    try sbd.sb("wait", s.id, "--id", id, "--resolve", "Alex answered")
    let r = try blocked.finish(within: 15)

    #expect(blocked.terminationReason == .exit)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let e = try event(r.stdout)
    #expect(e.kind == "wait-resolved")
    #expect(e.session == s.id)
    #expect(e.data["wait"]?["id"]?.string == id)
    #expect(e.data["wait"]?["then"]?.string == "caller")
    #expect(e.data["outcome"]?.string == "Alex answered")
    try expectUntouched(sbd, s, like: idle, after: before)
  }

  @Test func aBlockedCIWaitReturnsOnceTwoPollsReadPassingChecks() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.checks(18303, "PENDING")
    let idle = try sbd.get(s.id)
    let blocked = try block(sbd, [s.id, "--block", "--kind", "ci"])
    let id = try blockedWaitId(sbd, s, blocked)
    let before = try sbd.lastEventId(s.id)

    github.checks(18303, "SUCCESS")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(blocked.isRunning)
    #expect(try sbd.poll()["resolved"]?.int == 1)
    let r = try blocked.finish(within: 15)

    #expect(blocked.terminationReason == .exit)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let e = try event(r.stdout)
    #expect(e.kind == "wait-resolved")
    #expect(e.data["wait"]?["id"]?.string == id)
    #expect(e.data["outcome"]?.string == "the checks passed")
    try expectUntouched(sbd, s, like: idle, after: before)
  }

  /// `--since` lets a loop of timed slices count a review that landed between
  /// two slices' waits.
  @Test func aBlockedBotReviewWaitWithSinceResolvesOnAReviewFromBeforeTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.review(18303, by: "greptile-apps", "COMMENTED", at: stamp(-60), bot: true)
    let blocked = try block(
      sbd, ["--block", "--kind", "bot-review", "--who", "greptile-apps", "--since", stamp(-120)],
      env: ["SB_SESSION_ID": s.id, "CLAUDECODE": "1"])
    _ = try blockedWaitId(sbd, s, blocked)

    #expect(try sbd.poll()["resolved"]?.int == 1)
    let r = try blocked.finish(within: 15)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try event(r.stdout).data["outcome"]?.string == "greptile-apps reviewed")
  }

  /// The same review, dated before the wait, counts only with `--since`.
  @Test(arguments: [true, false])
  func aBotReviewWaitCountsAReviewFromBeforeTheWaitOnlyWithSince(_ withSince: Bool) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.review(18303, by: "greptile-apps", "COMMENTED", at: stamp(-60), bot: true)
    var args = ["wait", s.id, "--kind", "bot-review", "--who", "greptile-apps", "--then", "notify"]
    if withSince { args += ["--since", stamp(-120)] }
    try sbd.sb(args)

    #expect(try sbd.poll()["resolved"]?.int == (withSince ? 1 : 0))
    #expect(try sbd.get(s.id).waits.count == (withSince ? 0 : 1))
  }

  // MARK: Ending without a resolution

  @Test func aTimedOutBlockedWaitExits2AndClearsTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.checks(18303, "PENDING")
    let before = try sbd.lastEventId(s.id)
    let start = Date()

    let blocked = try block(sbd, [s.id, "--block", "--timeout", "1", "--kind", "ci"])
    let r = try blocked.finish(within: 15)

    #expect(Date().timeIntervalSince(start) >= 0.9)
    #expect(blocked.terminationReason == .exit)
    #expect(r.status == 2, Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).waits.isEmpty)
    let set = try #require(try sbd.events(s.id, after: before).first { $0.kind == "wait" })
    let id = try #require(set.data["wait"]?["id"]?.string)
    let cleared = try sbd.events(s.id, after: before).filter { $0.kind == "wait-cleared" }
    #expect(cleared.contains { $0.data["waits"]?.array?.contains(.string(id)) == true })

    github.checks(18303, "SUCCESS")
    #expect(try sbd.poll()["resolved"]?.int == 0)
    #expect(try sbd.poll()["resolved"]?.int == 0)
    let after = try kinds(sbd, s, after: before)
    #expect(!after.contains("wait-resolved"))
    #expect(!after.contains("sent"))
  }

  /// Claude Code's Bash tool timeout sends SIGTERM.
  @Test(arguments: [(SIGINT, 130), (SIGTERM, 143), (SIGHUP, 129)] as [(Int32, Int32)])
  func aSignalClearsTheWaitAndExits128PlusTheSignal(_ signal: Int32, _ status: Int32) throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let (blocked, id) = try blockOnManual(sbd, s)
    let before = try sbd.lastEventId(s.id)

    kill(blocked.pid, signal)
    let r = try blocked.finish(within: 15)

    #expect(blocked.terminationReason == .exit)
    #expect(r.status == status, Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).waits.isEmpty)
    let cleared = try sbd.events(s.id, after: before).filter { $0.kind == "wait-cleared" }
    #expect(cleared.contains { $0.data["waits"]?.array?.contains(.string(id)) == true })
  }

  @Test func clearingTheWaitElsewhereExits1WithAMessage() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let (blocked, _) = try blockOnManual(sbd, s)

    try sbd.sb("wait", s.id, "--clear")
    let r = try blocked.finish(within: 15)

    #expect(blocked.terminationReason == .exit)
    #expect(r.status == 1)
    #expect(!r.stderr.isEmpty)
    #expect(r.stdout.isEmpty)
  }

  /// The blocked wait ends only on an event that names its own id.
  @Test func anotherWaitsClearOrResolutionLeavesTheBlockedWaitRunning() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1190", "--then", "notify")
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1191", "--then", "notify")
    let others = try sbd.get(s.id).waits.map(\.id)
    let (blocked, id) = try blockOnManual(sbd, s, others: others)

    try sbd.sb("wait", s.id, "--id", others[0], "--clear")
    try sbd.sb("wait", s.id, "--id", others[1], "--resolve", "#1191 merged")
    usleep(1_500_000)
    try #require(blocked.isRunning, "sb wait --block ended on another wait's event")

    try sbd.sb("wait", s.id, "--id", id, "--resolve", "Alex answered")
    let r = try blocked.finish(within: 15)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try event(r.stdout).data["wait"]?["id"]?.string == id)
  }

  /// `events` lists at most `Event.defaultLimit` events per answer, so the
  /// follow loop has to move past events that don't match.
  @Test func aBlockedWaitResolvesAfterMoreEventsThanOneAnswerHolds() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let (blocked, id) = try blockOnManual(sbd, s)
    let before = try sbd.lastEventId(s.id)

    for i in 0...Event.defaultLimit {
      _ = try sbd.client.call("note", ["session": .string(s.id), "text": .string("note \(i)"), "by": "you"])
    }
    #expect(try sbd.count("note", of: s.id) > Event.defaultLimit)
    try sbd.sb("wait", s.id, "--id", id, "--resolve", "Alex answered")
    let r = try blocked.finish(within: 15)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try event(r.stdout).data["wait"]?["id"]?.string == id)
    #expect(try sbd.events(s.id, after: before).contains { $0.kind == "wait-resolved" })
  }

  // MARK: sbd unreachable

  @Test(arguments: [false, true])
  func sbdThatIsDownExits3(_ crashed: Bool) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    if crashed { sbd.killSbd() } else { sbd.stopSbd() }

    let r = try sbd.run(["wait", s.id, "--block", "--timeout", "1", "--kind", "manual", "--note", "ask Alex"])

    #expect(r.status == 3, Comment(rawValue: r.stderr))
    #expect(!r.stderr.isEmpty)
  }

  /// launchd restarts sbd, and the wait and its events persist in SQLite.
  @Test func aBlockedWaitOutlastsARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let (blocked, id) = try blockOnManual(sbd, s)

    sbd.stopSbd()
    sleep(2)
    try #require(blocked.isRunning, "sb wait --block gave up while sbd restarted")
    try sbd.startSbd()
    try sbd.sb("wait", s.id, "--id", id, "--resolve", "Alex answered")
    let r = try blocked.finish(within: 15)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try event(r.stdout).data["wait"]?["id"]?.string == id)
  }

  @Test func aBlockedWaitExits3OnceSbdStaysDownPastTheGrace() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let (blocked, _) = try blockOnManual(sbd, s, env: ["SB_UNREACHABLE_SECONDS": "1"])

    sbd.stopSbd()
    let r = try blocked.finish(within: 15)

    #expect(r.status == 3, Comment(rawValue: r.stderr))
  }

  // MARK: Refusals

  @Test(arguments: [
    ["--clear"], ["--resolve", "done"], ["--kind", "ci", "--then", "notify"], ["--kind", "ci", "--then", "resume"],
    ["--kind", "manual", "--note", "x", "--then", "caller"],
  ])
  func blockRefusesFlagsThatDoNotGoWithIt(_ extra: [String]) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1190")
    let open = try sbd.get(s.id).waits

    let r = try sbd.run(["wait", s.id, "--block", "--timeout", "1"] + extra)

    #expect(r.status == 1)
    #expect(!r.stderr.isEmpty)
    #expect(try sbd.get(s.id).waits == open)
  }

  @Test func thenCallerIsRefusedWithoutBlock() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let r = try sbd.run(["wait", s.id, "--kind", "ci", "--then", "caller"])

    #expect(r.status == 1)
    #expect(r.stderr.contains("then is resume or notify"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test(arguments: ["ci", "approval", "merge", "manual"])
  func sinceIsRefusedForAKindThatDoesNotCountTime(_ kind: String) throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let r = try sbd.run(["wait", s.id, "--kind", kind, "--note", "x", "--since", stamp(-60)])

    #expect(r.status == 1)
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func sinceInTheFutureIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.new()

    let r = try sbd.run(["wait", s.id, "--kind", "bot-review", "--since", stamp(3600)])

    #expect(r.status == 1)
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func helpNamesBlockSinceAndTheExitCodes() throws {
    let r = try runCommand("\(Instance.bin)/sb", ["help"])
    let lines = r.stdout.split(separator: "\n").map(String.init)
    let start = try #require(lines.firstIndex { $0.hasPrefix("  wait ") })
    let wait = lines[start...].prefix { $0.hasPrefix("  wait ") || $0.hasPrefix("    ") }.joined(separator: "\n")

    #expect(wait.contains("--block [--timeout S]"), Comment(rawValue: wait))
    #expect(wait.contains("--since"), Comment(rawValue: wait))
    #expect(wait.lowercased().contains("exit"), Comment(rawValue: wait))
  }
}
