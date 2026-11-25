import Foundation
import SwitchboardCore
import Testing

/// `sb wait --kind reply` (#504): a wait that resolves when someone other than you replies in a Slack thread after
/// the wait was set. sbd's Slack poll reads the thread, and the next tick resolves the wait from the stored row.
///
/// On a fresh sbd, sbd refuses every Slack call once at init and retries it, so the tests wait on the stored row,
/// the events, and the summary, never on raw run counts. The tests read the reply wait as JSON. Each reply's ts comes
/// from the wait's `created` on sbd's clock.
@Suite(.blocking(timeLimit: .seconds(240))) struct ReplyWaitTests {
  static let config: [String: JSON] = ["slack": ["pollSeconds": 1200]]
  static let windowMs: Int64 = 3 * 24 * 60 * 60 * 1000
  static let other = "U0OTHER"
  /// The stub's default profile id.
  static let selfId = "U0EXAMPLESELF"
  static let secondChannel = "C0EXAMPLE02"
  static let secondTs = "1794965100.000200"
  static let secondThread = "https://example.slack.com/archives/C0EXAMPLE02/p1794965100000200"
  static let summaryOfRoot = "a reply in Slack thread in C0EXAMPLE01"

  /// The link of a reply as D1 builds it: `p` and the ts without its dot, then the root.
  static func replyLink(_ ts: String, channel: String = SlackExample.channel, root: String = SlackExample.rootTs)
    -> String
  {
    let digits = ts.replacingOccurrences(of: ".", with: "")
    return "https://example.slack.com/archives/\(channel)/p\(digits)?thread_ts=\(root)&cid=\(channel)"
  }

  /// Sets a reply wait and returns it as `sb wait --json` lists it.
  @discardableResult
  func setReplyWait(_ sbd: Instance, _ session: String, _ flags: [String] = []) throws -> JSON {
    let summary = try #require(JSON.parse(try sbd.sb(["wait", "--json", session, "--kind", "reply"] + flags)))
    return try #require(summary["waits"]?.array?.last { $0["kind"]?.string == "reply" }, "\(summary)")
  }

  func created(_ wait: JSON) throws -> Int64 { Int64(try #require(wait["created"]?.int)) }

  func waitId(_ wait: JSON) throws -> String { try #require(wait["id"]?.string) }

  /// The text of the refusal of `sb` with the arguments. It fails when the command succeeds.
  func refusal(_ sbd: Instance, _ args: [String]) throws -> String {
    let r = try sbd.run(args)
    try #require(r.status != 0, "sb \(args.joined(separator: " ")) succeeded: \(r.stdout)")
    return r.stderr
  }

  func openWaits(_ sbd: Instance, _ session: String) throws -> [JSON] {
    try sbd.summaryJSON(session)["waits"]?.array ?? []
  }

  func resolvedEvents(_ sbd: Instance, _ session: String) throws -> [Event] {
    try sbd.events(session).filter { $0.kind == "wait-resolved" }
  }

  /// Moves the clock by `ms` so a scan is due, waits until the scan stored a read of the thread, then moves the clock
  /// one second so a tick runs after the poll applied. A reply wait resolves on that tick.
  func pollThenTick(
    _ sbd: Instance, channel: String = SlackExample.channel, thread: String = SlackExample.rootTs,
    by ms: Int64 = SlackFixtures.step
  ) throws {
    let due = try sbd.advanceToPoll(by: ms)
    _ = try sbd.waitFor(
      "a read of \(channel)/\(thread) at or after \(due)", timeout: 30,
      fetch: { try sbd.slackThreadRow(channel: channel, thread: thread) },
      until: { Int64($0["read"]?.int ?? 0) >= due })
    try sbd.advanceClock(1000)
  }

  @discardableResult
  func waitForResolve(_ sbd: Instance, _ session: String) throws -> Event {
    try sbd.waitFor(
      "the wait-resolved event", timeout: 30, fetch: { try resolvedEvents(sbd, session).last }, until: { _ in true })
  }

  /// Checks the condition every 0.2 s for the seconds, and fails at the first check that is false.
  func stays(_ what: String, for seconds: Double = 2, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      try #require(try condition(), "\(what)")
      usleep(200_000)
    }
  }

  /// The session's row as sbd stored it, read with sqlite3 while sbd runs.
  func storedSession(_ sbd: Instance, _ id: String) throws -> JSON {
    let r = try runCommand(
      "/usr/bin/sqlite3", ["-cmd", ".timeout 5000", sbd.home.database, "SELECT json FROM sessions WHERE id = '\(id)'"])
    try #require(r.status == 0, "\(r.stderr)")
    return try #require(JSON.parse(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), "\(r.stdout)")
  }

  // MARK: Resolving

  /// The issue's case: a reply from someone else after the wait resolves it, and the session resumes with the reply's
  /// name and link.
  @Test func replyFromSomeoneElseResolvesTheWait() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    let alice = SlackFixtures.ts(try created(wait) + 60_000)
    try sbd.writeSlackThread([SlackReply(ts: alice, user: Self.other, name: "Alice")])

    try pollThenTick(sbd)

    let resolved = try waitForResolve(sbd, s.id)
    let outcome = "Alice replied: \(Self.replyLink(alice))"
    #expect(resolved.data["outcome"]?.string == outcome)
    #expect(resolved.data["changedAt"]?.double == Double(try created(wait) + 60_000))
    #expect(resolved.data["wait"]?["id"]?.string == (try waitId(wait)))
    try sbd.waitFor(s.id, "the resumed turn", timeout: 30) {
      $0.lastReply == "Done: Switchboard: \(Self.summaryOfRoot): \(outcome)."
    }
    #expect(try openWaits(sbd, s.id).isEmpty)
  }

  @Test func notifyMovesTheSessionToNeedsYou() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id, ["--then", "notify"])
    let alice = SlackFixtures.ts(try created(wait) + 60_000)
    try sbd.writeSlackThread([SlackReply(ts: alice, user: Self.other, name: "Alice")])

    try pollThenTick(sbd)

    let resolved = try waitForResolve(sbd, s.id)
    #expect(resolved.data["outcome"]?.string == "Alice replied: \(Self.replyLink(alice))")
    let after = try sbd.waitFor(s.id, "Needs you", timeout: 30) { $0.state == .needsYou }
    #expect(after.reason.hasPrefix("\(Self.summaryOfRoot): Alice replied"), "\(after.reason)")
    #expect(after.waits.isEmpty)
  }

  /// The issue's case: your own reply leaves the wait open. The tests wait for the status, which shows the reply.
  @Test func yourOwnReplyDoesNotResolve() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    try sbd.writeSlackThread([
      SlackReply(ts: SlackFixtures.ts(try created(wait) + 60_000), user: Self.selfId, name: "Me")
    ])

    try pollThenTick(sbd)
    _ = try sbd.waitFor(
      "the wait's status after the poll", timeout: 30, fetch: { try openWaits(sbd, s.id).first?["threadStatus"] },
      until: { $0["replies"]?.int == 1 })
    try sbd.advanceClock(1000)
    try sbd.advanceClock(1000)

    try stays("the wait stays open") { try resolvedEvents(sbd, s.id).isEmpty }
    #expect(try openWaits(sbd, s.id).map { $0["id"] } == [wait["id"]])
  }

  /// The issue's case: a reply that landed before the wait was set doesn't answer it.
  @Test func aReplyFromBeforeTheWaitDoesNotResolve() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    let alice = SlackFixtures.ts(try created(wait) - 60_000)
    try sbd.writeSlackThread([SlackReply(ts: alice, user: Self.other, name: "Alice")])

    try pollThenTick(sbd)
    try sbd.advanceClock(1000)

    let row = try #require(try sbd.slackThreadRow())
    try #require(row["lastOtherReplyTs"]?.string == alice, "the poll stored Alice's reply: \(row)")
    try stays("the wait stays open") { try resolvedEvents(sbd, s.id).isEmpty }
    #expect(try openWaits(sbd, s.id).map { $0["id"] } == [wait["id"]])
  }

  /// Risk 1's sharpest input: your reply at the wait's exact ms and Alice's a ms before it.
  @Test func repliesAtAndJustBeforeTheWaitDoNotResolve() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    let t = try created(wait)
    try sbd.writeSlackThread([
      SlackReply(ts: SlackFixtures.ts(t - 1), user: Self.other, name: "Alice"),
      SlackReply(ts: SlackFixtures.ts(t), user: Self.selfId, name: "Me"),
    ])

    try pollThenTick(sbd)
    try sbd.advanceClock(1000)

    let row = try #require(try sbd.slackThreadRow())
    try #require(row["lastOtherReplyTs"]?.string == SlackFixtures.ts(t - 1), "the poll stored Alice's reply: \(row)")
    try #require(row["lastReplyTs"]?.string == SlackFixtures.ts(t), "the poll stored your reply: \(row)")
    try #require(row["lastReplyUser"]?.string == Self.selfId, "\(row)")
    try stays("the wait stays open") { try resolvedEvents(sbd, s.id).isEmpty }
    #expect(try openWaits(sbd, s.id).map { $0["id"] } == [wait["id"]])
  }

  /// D2: Alice replies after the wait, then you reply before the poll. The wait still resolves and names Alice.
  @Test func someoneElsesReplyThenYoursStillResolves() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    let alice = SlackFixtures.ts(try created(wait) + 60_000)
    try sbd.writeSlackThread([
      SlackReply(ts: alice, user: Self.other, name: "Alice"),
      SlackReply(ts: SlackFixtures.ts(try created(wait) + 120_000), user: Self.selfId, name: "Me"),
    ])

    try pollThenTick(sbd)

    let resolved = try waitForResolve(sbd, s.id)
    #expect(resolved.data["outcome"]?.string == "Alice replied: \(Self.replyLink(alice))")
    #expect(resolved.data["changedAt"]?.double == Double(try created(wait) + 60_000))
  }

  /// One row serves every session that links the thread, so one reply resolves a wait in each.
  @Test func twoSessionsWaitingOnOneThreadBothResolve() throws {
    let sbd = try Instance(config: Self.config)
    let first = try sbd.idleSession(name: "flags-cache")
    let second = try sbd.idleSession(name: "flags-docs")
    _ = try sbd.addLink(first.id, SlackExample.root)
    _ = try sbd.addLink(second.id, SlackExample.root)
    let firstWait = try setReplyWait(sbd, first.id)
    let secondWait = try setReplyWait(sbd, second.id)
    let alice = SlackFixtures.ts(max(try created(firstWait), try created(secondWait)) + 60_000)
    try sbd.writeSlackThread([SlackReply(ts: alice, user: Self.other, name: "Alice")])

    try pollThenTick(sbd)

    let outcome = "Alice replied: \(Self.replyLink(alice))"
    #expect(try waitForResolve(sbd, first.id).data["outcome"]?.string == outcome)
    #expect(try waitForResolve(sbd, second.id).data["outcome"]?.string == outcome)
  }

  /// D4: sbd resolves no wait of a Done session, as for every kind.
  @Test func aDoneSessionsReplyWaitDoesNotResolve() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    try sbd.sb("done", s.id)
    let alice = SlackFixtures.ts(try created(wait) + 60_000)
    try sbd.writeSlackThread([SlackReply(ts: alice, user: Self.other, name: "Alice")])

    try pollThenTick(sbd)
    try sbd.advanceClock(1000)

    let row = try #require(try sbd.slackThreadRow())
    try #require(row["lastOtherReplyTs"]?.string == alice, "the poll stored Alice's reply: \(row)")
    try stays("the wait stays open") { try resolvedEvents(sbd, s.id).isEmpty }
    #expect(try openWaits(sbd, s.id).map { $0["id"] } == [wait["id"]])
  }

  // MARK: Recheck and the hand

  /// The issue's case: with no reply, the wait goes overdue at its recheck and stays open.
  @Test func recheckOverdueMovesTheSessionToNeedsYou() throws {
    let sbd = try Instance(config: Self.config.merging(["recheckSeconds": ["reply": 600]]) { $1 })
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    #expect(wait["recheck"]?.int.map(Int64.init) == (try created(wait)) + 600_000)

    try sbd.advanceClock(11 * 60_000)

    let due = try sbd.waitFor(s.id, "the recheck", timeout: 30) { $0.state == .needsYou }
    #expect(due.reason == "\(Self.summaryOfRoot): still open after 10m")
    #expect(try openWaits(sbd, s.id).map { $0["id"] } == [wait["id"]])
    let details = try sbd.getJSON(s.id)["triage"]?["message"]?["details"]
    #expect(details?["overdueWaits"] == .array([wait["id"] ?? .null]), "\(String(describing: details))")
    #expect(try resolvedEvents(sbd, s.id).isEmpty)
  }

  /// D12: the default recheck is a day.
  @Test func aReplyWaitRechecksADayAfterItWasSet() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)

    let wait = try setReplyWait(sbd, s.id)

    #expect(wait["kind"]?.string == "reply")
    #expect(wait["url"]?.string == SlackExample.root)
    #expect(wait["recheck"]?.int.map(Int64.init) == (try created(wait)) + 86_400_000)
  }

  /// The issue's case.
  @Test func resolveByHand() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    try setReplyWait(sbd, s.id)

    try sbd.sb("wait", s.id, "--resolve", "Alice answered in a DM")

    let resolved = try waitForResolve(sbd, s.id)
    #expect(resolved.data["outcome"]?.string == "Alice answered in a DM")
    #expect(try openWaits(sbd, s.id).isEmpty)
  }

  // MARK: The target

  /// D5: without --target, the wait takes the session's one Slack thread. A reply's link and its thread's link are
  /// one thread.
  @Test func aReplyLinkAndItsThreadsLinkAreOneDefaultTarget() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    // The list can fold the reply's link into its thread's entry, so the test doesn't require a second entry.
    try sbd.sb("link", "add", s.id, SlackExample.reply)
    _ = try sbd.addLink(s.id, "https://linear.app/example/issue/ENG-123")

    let wait = try setReplyWait(sbd, s.id)

    let url = try #require(wait["url"]?.string)
    #expect([SlackExample.root, SlackExample.reply].contains(url), "\(url)")
  }

  @Test func noSlackThreadAmongTheLinksRefusesAWaitWithoutATarget() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, "https://linear.app/example/issue/ENG-123")

    let text = try refusal(sbd, ["wait", s.id, "--kind", "reply"])

    #expect(
      text.contains("flags-cache has no Slack thread among its links, so give the thread's link as --target"),
      "\(text)")
  }

  @Test func twoSlackThreadsAmongTheLinksRefuseAWaitWithoutATargetAndListBoth() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    _ = try sbd.addLink(s.id, Self.secondThread)

    let text = try refusal(sbd, ["wait", s.id, "--kind", "reply"])

    #expect(text.contains("flags-cache has 2 Slack threads among its links, so give one as --target"), "\(text)")
    #expect(text.contains(SlackExample.root), "\(text)")
    #expect(text.contains(Self.secondThread), "\(text)")
  }

  @Test(arguments: [
    "https://github.com/PostHog/posthog/pull/1204", "https://example.slack.com/archives/C0EXAMPLE01",
  ])
  func targetMustBeASlackMessageLink(_ target: String) throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")

    let text = try refusal(sbd, ["wait", s.id, "--kind", "reply", "--target", target])

    #expect(text.contains("\(target) isn't a Slack message link"), "\(text)")
  }

  /// D11: the integration default turns the poll off.
  @Test func aReplyWaitNeedsThePoll() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)

    let text = try refusal(sbd, ["wait", s.id, "--kind", "reply", "--target", SlackExample.root])

    #expect(text.contains("sbd doesn't read Slack threads while slack.pollSeconds is 0"), "\(text)")
  }

  // MARK: What the poll reads (D4)

  /// The target is not among the session's links, and another thread is.
  @Test func anUnlistedTargetIsRead() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id, ["--target", Self.secondThread])
    let alice = SlackFixtures.ts(try created(wait) + 60_000)
    try sbd.writeSlackThread(
      channel: Self.secondChannel, ts: Self.secondTs, [SlackReply(ts: alice, user: Self.other, name: "Alice")])

    try pollThenTick(sbd, channel: Self.secondChannel, thread: Self.secondTs)

    #expect(sbd.slackAsks().last?.contains { $0["message_ts"]?.string == Self.secondTs } == true)
    let resolved = try waitForResolve(sbd, s.id)
    let link = Self.replyLink(alice, channel: Self.secondChannel, root: Self.secondTs)
    #expect(resolved.data["outcome"]?.string == "Alice replied: \(link)")
  }

  /// A session with no links at all still has its wait's thread read. On a fresh sbd the first scan is due at once,
  /// so it can start just after the wait is set and read the reply. The wait then resolves, and the next due scan drops the thread's row because no link or open wait
  /// names the thread. So the test waits for the resolution, not for a stored read.
  @Test func aTargetOfASessionWithNoLinksIsRead() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    let wait = try setReplyWait(sbd, s.id, ["--target", SlackExample.reply])
    let alice = SlackFixtures.ts(try created(wait) + 60_000)
    try sbd.writeSlackThread([SlackReply(ts: alice, user: Self.other, name: "Alice")])

    _ = try sbd.advanceToPoll()

    let resolved = try waitForResolve(sbd, s.id)
    #expect(resolved.data["outcome"]?.string == "Alice replied: \(Self.replyLink(alice))")
    #expect(sbd.slackAsks().contains { $0.contains { $0["message_ts"]?.string == SlackExample.rootTs } })
  }

  @Test func theThreadStaysWatchedPastItsLinksWindowWhileTheWaitIsOpen() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    try setReplyWait(sbd, s.id)
    try pollThenTick(sbd)

    try pollThenTick(sbd, by: Self.windowMs)

    #expect(sbd.slackAsks().last?.contains { $0["message_ts"]?.string == SlackExample.rootTs } == true)
    let status = try sbd.sessionLinks(s.id)?.first { $0["url"]?.string == SlackExample.root }?["status"]
    #expect(status?["watched"]?.bool == true, "\(String(describing: status))")
  }

  @Test func theThreadStaysWatchedAfterItsLinkIsRemoved() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    let link = try sbd.addLink(s.id, SlackExample.root)
    try setReplyWait(sbd, s.id)
    try pollThenTick(sbd)
    try sbd.sb("link", "rm", s.id, try #require(link["id"]?.string))
    let asks = sbd.slackAsks().count

    try pollThenTick(sbd)

    #expect(sbd.slackAsks().count > asks)
    #expect(sbd.slackAsks().last?.contains { $0["message_ts"]?.string == SlackExample.rootTs } == true)
    #expect(try sbd.slackThreadRow() != nil)
  }

  // MARK: Check now (D15)

  /// After one scan asks for both threads, they were asked for at once, so the link's thread goes first until Check
  /// now puts the wait's unlisted thread first.
  @Test func checkNowPutsTheThreadFirstAtTheNextPoll() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id, ["--target", Self.secondThread])
    try pollThenTick(sbd, channel: Self.secondChannel, thread: Self.secondTs)
    try pollThenTick(sbd, channel: Self.secondChannel, thread: Self.secondTs)
    let before = try #require(sbd.slackAsks().last)
    try #require(before.first?["message_ts"]?.string == SlackExample.rootTs, "\(before)")

    _ = try sbd.client.call(
      "wait-check", ["session": .string(s.id), "wait": .string(try waitId(wait)), "by": "you"])
    try pollThenTick(sbd, channel: Self.secondChannel, thread: Self.secondTs)

    let after = try #require(sbd.slackAsks().last)
    #expect(after.first?["message_ts"]?.string == Self.secondTs, "\(after)")
  }

  /// Revised D15: Check now only orders the next scheduled scan.
  @Test func checkNowStartsNoScan() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    try pollThenTick(sbd)
    let runs = sbd.slackRuns("slack-calls.log").count

    _ = try sbd.client.call(
      "wait-check", ["session": .string(s.id), "wait": .string(try waitId(wait)), "by": "you"])
    try sbd.advanceClock(1000)

    try stays("no Slack scan") { sbd.slackRuns("slack-calls.log").count == runs }
  }

  @Test func checkNowIsOnlyForYouAndOnlyForAReplyWait() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let reply = try setReplyWait(sbd, s.id)
    let manual = try #require(
      JSON.parse(try sbd.sb("wait", "--json", s.id, "--kind", "manual", "--note", "ask Alex"))?["waits"]?.array?.last {
        $0["kind"]?.string == "manual"
      })

    let byClaude = failure(
      sbd, "wait-check", ["session": .string(s.id), "wait": .string(try waitId(reply)), "by": "claude"])
    let notReply = failure(
      sbd, "wait-check", ["session": .string(s.id), "wait": .string(try waitId(manual)), "by": "you"])
    let noWait = failure(sbd, "wait-check", ["session": .string(s.id), "wait": "wnope1", "by": "you"])

    #expect(byClaude != "no error", "\(byClaude)")
    #expect(notReply != "no error", "\(notReply)")
    #expect(noWait != "no error", "\(noWait)")
  }

  @Test func checkNowIsRefusedWhileThePollIsOff() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    sbd.stopSbd()
    try sbd.set("slack", to: ["pollSeconds": 0])
    try sbd.startSbd()

    let text = failure(sbd, "wait-check", ["session": .string(s.id), "wait": .string(try waitId(wait)), "by": "you"])

    #expect(text.contains("slack.pollSeconds"), "\(text)")
  }

  // MARK: The status (D14, Risk 5)

  @Test func statusIsOnlyInTheSummary() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.idleSession(name: "flags-cache")
    _ = try sbd.addLink(s.id, SlackExample.root)
    let wait = try setReplyWait(sbd, s.id)
    try sbd.writeSlackThread([
      SlackReply(ts: SlackFixtures.ts(try created(wait) + 60_000), user: Self.selfId, name: "Me")
    ])
    try pollThenTick(sbd)

    let status = try sbd.waitFor(
      "the wait's status", timeout: 30, fetch: { try openWaits(sbd, s.id).first?["threadStatus"] },
      until: { $0["replies"]?.int == 1 })

    #expect(status["lastReply"]?["you"]?.bool == true, "\(status)")
    #expect(status["watched"]?.bool == true, "\(status)")
    let stored = try storedSession(sbd, s.id)["waits"]?.array?.first
    #expect(stored?["url"]?.string == SlackExample.root, "\(String(describing: stored))")
    #expect(stored?["threadStatus"] == nil, "\(String(describing: stored))")
    let set = try #require(try sbd.events(s.id).last { $0.kind == "wait" })
    #expect(set.data["wait"]?["threadStatus"] == nil, "\(set.data)")
    let mcp = try MCPClient(sbd)
    let got = try #require(try mcp.call("get_session", ["session": .string(s.id), "full": true]).json)
    #expect(got["waits"]?.array?.first?["threadStatus"]?["replies"]?.int == 1, "\(got)")

    try sbd.sb("wait", s.id, "--resolve", "Alice answered in a DM")

    let resolved = try waitForResolve(sbd, s.id)
    #expect(resolved.data["wait"]?["threadStatus"] == nil, "\(resolved.data)")
  }

  /// D17: a reply still only sets the mark.
  @Test func aReplyWithoutAWaitRaisesNoItem() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let link = try sbd.addLink(s.id, SlackExample.root)
    let before = try sbd.summaryJSON(s.id)
    let t = Int64(try #require(link["t"]?.int))
    try sbd.writeSlackThread([SlackReply(ts: SlackFixtures.ts(t + 60_000), user: Self.other, name: "Alice")])

    try pollThenTick(sbd)

    let status = try sbd.waitFor(
      "the mark", timeout: 30,
      fetch: { try sbd.sessionLinks(s.id)?.first { $0["url"]?.string == SlackExample.root }?["status"] },
      until: { $0["newReply"]?.bool == true })
    #expect(status["replies"]?.int == 1)
    // A session without a first prompt is already in Needs you, so the reply must leave its state and item as they were.
    let after = try sbd.summaryJSON(s.id)
    #expect(after["state"] == before["state"], "\(after)")
    #expect(after["reason"] == before["reason"], "\(after)")
    #expect(after["triage"]?["ref"] == before["triage"]?["ref"], "\(after)")
  }

  // MARK: Help

  @Test func theHelpAndTheMCPToolNameTheReplyKind() throws {
    let sbd = try Instance(config: Self.config)

    let help = try sbd.sb("help")
    let mcp = try MCPClient(sbd)
    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "set_wait" })

    #expect(help.contains("reply takes a Slack message link"), "\(help)")
    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["kind"]?["description"]?.string?.contains("reply") == true, "\(properties)")
    #expect(properties["target"]?["description"]?.string?.contains("Slack") == true, "\(properties)")
    #expect(tool["description"]?.string?.contains("reply") == true, "\(tool)")
  }
}
