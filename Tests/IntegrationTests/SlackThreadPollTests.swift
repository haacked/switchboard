import Foundation
import SwitchboardCore
import Testing

/// A reply in a thread fixture of the stub's `<slack-threads>` branch.
private struct SlackReply {
  var ts: String
  var user: String
  var name: String
}

/// The files of the stub's `<slack-self>` and `<slack-threads>` branches in SB_HOME. Every assumption about their
/// format lives here.
extension Instance {
  /// The runs that the stub logged in the file, oldest first, each as its arguments. The stub writes each argument
  /// followed by a NUL, so a run starts at each `-p`.
  fileprivate func slackRuns(_ file: String) -> [[String]] {
    let text = (try? String(contentsOfFile: "\(home.path)/\(file)", encoding: .utf8)) ?? ""
    var runs: [[String]] = []
    // The text after the last NUL is empty, or a record that the stub is writing.
    for record in text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) {
      if record == "-p" {
        runs.append([record])
      } else if !runs.isEmpty {
        runs[runs.count - 1].append(record)
      }
    }
    return runs
  }

  /// The threads that each `<slack-threads>` input asked for, oldest first, as `[{channel_id, message_ts, oldest?}]`.
  fileprivate func slackAsks() -> [[JSON]] {
    let text = (try? String(contentsOfFile: "\(home.path)/slack-inputs.log", encoding: .utf8)) ?? ""
    return text.components(separatedBy: "<slack-threads>").dropFirst().compactMap { block in
      guard let end = block.range(of: "</slack-threads>") else { return nil }
      return JSON.parse(String(block[..<end.lowerBound]))?.array
    }
  }

  fileprivate func writeSlackThread(
    channel: String = SlackExample.channel, ts: String = SlackExample.rootTs, _ replies: [SlackReply]
  ) throws {
    let json: JSON = [
      "replies": .array(replies.map { ["ts": .string($0.ts), "user": .string($0.user), "name": .string($0.name)] })
    ]
    try json.text.write(toFile: "\(home.path)/slack-thread-\(channel)-\(ts).json", atomically: true, encoding: .utf8)
  }

  fileprivate func writeSlackSwitch(_ name: String, _ text: String = "") throws {
    try text.write(toFile: "\(home.path)/\(name)", atomically: true, encoding: .utf8)
  }

  fileprivate func removeSlackSwitch(_ name: String) {
    try? FileManager.default.removeItem(atPath: "\(home.path)/\(name)")
  }

  fileprivate func slackFileExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: "\(home.path)/\(name)")
  }
}

/// sbd reads the Slack threads among the sessions' links through a headless `claude -p` call on the claude.ai
/// Slack connector, and shows each one's reply count, last reply, and last read as the link's `status`.
///
/// On a fresh sbd, sbd refuses every call once at init and retries it, so the tests assert on the status and on
/// the arguments of the runs, not on raw run counts. A link can land before sbd's first scan, so a poll may run before
/// the first clock advance. Each test waits for a status that only a poll after the advance gives.
@Suite(.blocking(timeLimit: .seconds(240))) struct SlackThreadPollTests {
  static let config: [String: JSON] = ["slack": ["pollSeconds": 1200]]
  /// A little more than `slack.pollSeconds`, so a scan is due whether "due" means after or at.
  static let step: Int64 = 20 * 60_000 + 1000
  /// D6: 3 days.
  static let windowMs: Int64 = 3 * 24 * 60 * 60 * 1000
  static let other = "U0OTHER"
  static let readTool = "mcp__claude_ai_Slack__slack_read_thread"
  static let profileTool = "mcp__claude_ai_Slack__slack_read_user_profile"
  static let sendTool = "mcp__claude_ai_Slack__slack_send_message"
  static let secondChannel = "C0EXAMPLE02"
  static let secondTs = "1794965100.000200"
  static let secondThread = "https://example.slack.com/archives/C0EXAMPLE02/p1794965100000200"

  /// A Slack ts for a time in ms.
  static func ts(_ ms: Int64) -> String { String(format: "%lld.%06lld", ms / 1000, (ms % 1000) * 1000) }

  static func value(after flag: String, in run: [String]) -> String? {
    guard let i = run.firstIndex(of: flag), i + 1 < run.count else { return nil }
    return run[i + 1]
  }

  /// The entries of `--disallowedTools`, or an empty set without the flag. The flag takes each value up to the next
  /// flag, and a value can list several entries split by commas or spaces.
  static func disallowed(_ run: [String]) -> Set<String> {
    guard let i = run.firstIndex(of: "--disallowedTools") else { return [] }
    let values = run[(i + 1)...].prefix { !$0.hasPrefix("--") }
    return Set(values.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) })
  }

  /// Adds the link by hand and returns it as `sb link add --json` lists it.
  func addLink(_ sbd: Instance, _ session: String, _ url: String) throws -> JSON {
    let summary = try #require(JSON.parse(try sbd.sb(["link", "add", "--json", session, url])))
    return try #require(summary["links"]?.array?.first { $0["url"]?.string == url }, "no link to \(url)")
  }

  func time(_ link: JSON) throws -> Int64 { Int64(try #require(link["t"]?.int)) }

  func status(_ sbd: Instance, _ session: String, _ url: String = SlackExample.root) throws -> JSON? {
    try sbd.sessionLinks(session)?.first { $0["url"]?.string == url }?["status"]
  }

  @discardableResult
  func waitForStatus(
    _ sbd: Instance, _ session: String, url: String = SlackExample.root, _ what: String,
    _ match: (JSON) -> Bool
  ) throws -> JSON {
    try sbd.waitFor(what, timeout: 30, fetch: { try status(sbd, session, url) }, until: match)
  }

  /// Moves the clock so a scan is due, and returns the earliest time that a poll after the move records as `read`.
  func advanceToPoll(_ sbd: Instance, by ms: Int64 = SlackThreadPollTests.step) throws -> Int64 {
    let due = try sbd.now() + ms
    try sbd.advanceClock(ms)
    return due
  }

  /// Moves the clock so a scan is due, and waits for the read of a poll after the move.
  @discardableResult
  func pollAndRead(_ sbd: Instance, _ session: String, _ url: String = SlackExample.root) throws -> JSON {
    let due = try advanceToPoll(sbd)
    return try waitForStatus(sbd, session, url: url, "a read at or after \(due)") { ($0["read"]?.int ?? 0) >= due }
  }

  /// The status fields that a failed read keeps.
  func kept(_ status: JSON) -> [JSON?] { [status["replies"], status["lastReply"], status["read"]] }

  // MARK: The mark

  /// #503 requires this case.
  @Test func newReplyFromSomeoneElseShowsTheMark() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])

    let status = try pollAndRead(sbd, s.id)

    #expect(status["replies"]?.int == 1)
    #expect(status["lastReply"]?["user"]?.string == Self.other)
    #expect(status["lastReply"]?["name"]?.string == "Alice")
    #expect(status["lastReply"]?["t"]?.int.map(Int64.init) == t + 60_000)
    #expect(status["lastReply"]?["you"]?.bool == false)
    #expect(status["newReply"]?.bool == true)
    #expect(status["watched"]?.bool == true)
    #expect(status["error"] == nil)
    let text = try sbd.sb("get", s.id)
    #expect(text.contains("1 reply"), "\(text)")
    #expect(text.contains("new reply"), "\(text)")
  }

  /// #503 requires this case. The stub's profile answer gives the id in `slack-self-id`.
  @Test func replyYouWroteIsNotNew() throws {
    let sbd = try Instance(config: Self.config)
    try sbd.writeSlackSwitch("slack-self-id", "U0EXAMPLEME")
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: "U0EXAMPLEME", name: "Me")])

    let status = try pollAndRead(sbd, s.id)

    #expect(status["replies"]?.int == 1)
    #expect(status["lastReply"]?["you"]?.bool == true)
    #expect(status["newReply"]?.bool == false)
    let text = try sbd.sb("get", s.id)
    #expect(text.contains("last from you"), "\(text)")
    #expect(!text.contains("new reply"), "\(text)")
  }

  /// #503 requires this case.
  @Test func failedReadKeepsTheLastStatus() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])
    let good = try pollAndRead(sbd, s.id)
    #expect(good["replies"]?.int == 1)

    try sbd.writeSlackSwitch("slack-fail")
    _ = try advanceToPoll(sbd)

    let failed = try waitForStatus(sbd, s.id, "a failed read") { $0["error"]?.string != nil }
    #expect(kept(failed) == kept(good))

    sbd.removeSlackSwitch("slack-fail")
    try sbd.writeSlackSwitch("slack-status", "needs-auth")
    _ = try advanceToPoll(sbd)

    let signedOut = try waitForStatus(sbd, s.id, "the connector's status in the error") {
      $0["error"]?.string?.contains("needs-auth") == true
    }
    #expect(kept(signedOut) == kept(good))
    #expect(signedOut["watched"]?.bool == true)
  }

  /// #503 requires this case.
  @Test func threadStopsBeingWatchedAfterThreeDays() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])
    let good = try pollAndRead(sbd, s.id)
    let runs = sbd.slackRuns("slack-calls.log").count

    try sbd.advanceClock(Self.windowMs)
    try waitForStatus(sbd, s.id, "the end of the watch") { $0["watched"]?.bool == false }
    try sbd.advanceClock(Self.step)

    try stays("no thread poll after the watch ended") { sbd.slackRuns("slack-calls.log").count == runs }
    let last = try #require(try status(sbd, s.id))
    #expect(last["watched"]?.bool == false)
    #expect(last["replies"]?.int == 1)
    #expect(kept(last) == kept(good))
  }

  @Test func nothingWatchedMakesNoCall() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let linear = try addLink(sbd, s.id, "https://linear.app/example/issue/ENG-123")

    try sbd.advanceClock(Self.step)

    try stays("no Slack call") {
      !sbd.slackFileExists("slack-calls.log") && !sbd.slackFileExists("slack-self-calls.log")
    }
    #expect(linear["status"] == nil)
    #expect(try sbd.sessionLinks(s.id)?.first?["status"] == nil)
  }

  // MARK: The call

  @Test func pollArgumentsFollowTheSpike() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    _ = try addLink(sbd, s.id, SlackExample.root)
    try pollAndRead(sbd, s.id)

    let run = try #require(sbd.slackRuns("slack-calls.log").last)

    #expect(Self.value(after: "--output-format", in: run) == "stream-json", "\(run)")
    #expect(run.contains("--verbose"), "\(run)")
    #expect(Self.value(after: "--setting-sources", in: run) == "user", "\(run)")
    #expect(Self.value(after: "--permission-mode", in: run) == "dontAsk", "\(run)")
    #expect(Self.value(after: "--allowedTools", in: run) == Self.readTool, "\(run)")
    #expect(Self.value(after: "--tools", in: run) == "", "\(run)")
    #expect(Self.value(after: "--model", in: run) == "haiku", "\(run)")
    #expect(run.contains("--no-session-persistence"), "\(run)")
    #expect(run.contains("--disable-slash-commands"), "\(run)")
    #expect(!run.contains("--strict-mcp-config"), "\(run)")
    let settings = try #require(Self.value(after: "--settings", in: run).flatMap { JSON.parse($0) }, "\(run)")
    #expect(settings["disableAllHooks"]?.bool == true)
    #expect(settings["autoMemoryEnabled"]?.bool == false)
    #expect(settings["claudeMdExcludes"]?.array?.isEmpty == false)
    #expect(settings["advisorModel"]?.string == "")
    let profile = try #require(sbd.slackRuns("slack-self-calls.log").last)
    #expect(Self.value(after: "--allowedTools", in: profile) == Self.profileTool, "\(profile)")
    #expect(Self.value(after: "--output-format", in: profile) == "stream-json", "\(profile)")
  }

  /// D4: on a fresh sbd, claude lists every Slack tool, so sbd refuses the first attempt of each call at init and
  /// retries it with the learned deny list. A refused call stores a `headless_calls` row with its error.
  @Test func aFreshSbdRefusesEachCallOnceAndRetries() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    _ = try addLink(sbd, s.id, SlackExample.root)
    try pollAndRead(sbd, s.id)

    let rows = try sbd.headlessUsageRows()

    // The report sums by day, and a clock move can cross midnight, so the test adds up the rows of a kind.
    for kind in ["slackSelf", "slackThreads"] {
      let mine = rows.filter { $0["kind"]?.string == kind }
      #expect(mine.reduce(0) { $0 + ($1["errors"]?.int ?? 0) } >= 1, "\(kind): \(rows)")
      #expect(mine.reduce(0) { $0 + ($1["calls"]?.int ?? 0) } >= 2, "\(kind): \(rows)")
    }
    let profiles = sbd.slackRuns("slack-self-calls.log")
    #expect(profiles.count >= 2)
    #expect(Self.disallowed(profiles.first ?? []).isEmpty, "\(profiles)")
    #expect(Self.disallowed(profiles.last ?? []).contains(Self.readTool), "\(profiles)")
    #expect(!Self.disallowed(sbd.slackRuns("slack-calls.log").last ?? []).contains(Self.readTool))
  }

  @Test func oldestAddsNewRepliesToTheCount() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    let first = SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")
    try sbd.writeSlackThread([first])
    let one = try pollAndRead(sbd, s.id)
    #expect(one["replies"]?.int == 1)

    try sbd.writeSlackThread([first, SlackReply(ts: Self.ts(t + 120_000), user: "U0CAROL", name: "Carol")])
    let two = try pollAndRead(sbd, s.id)

    #expect(two["replies"]?.int == 2)
    #expect(two["lastReply"]?["user"]?.string == "U0CAROL")
    #expect(two["lastReply"]?["t"]?.int.map(Int64.init) == t + 120_000)
    let asked = try #require(sbd.slackAsks().last?.first { $0["message_ts"]?.string == SlackExample.rootTs })
    #expect(asked["oldest"]?.string == first.ts)
    #expect(asked["channel_id"]?.string == SlackExample.channel)

    // A read that finds nothing after `oldest` keeps the count and the last reply.
    let quiet = try pollAndRead(sbd, s.id)
    #expect(quiet["replies"]?.int == 2)
    #expect(quiet["lastReply"]?["user"]?.string == "U0CAROL")
    #expect(quiet["newReply"]?.bool == true)
  }

  /// The profile call runs first, so it learns `mcp__other` before the poll's first attempt.
  @Test func extraToolIsDeniedAndRetried() throws {
    let sbd = try Instance(config: Self.config)
    try sbd.writeSlackSwitch("slack-extra-tools", "mcp__other__run\n")
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])

    let status = try pollAndRead(sbd, s.id)

    #expect(status["replies"]?.int == 1)
    #expect(status["error"] == nil)
    let profiles = sbd.slackRuns("slack-self-calls.log")
    #expect(profiles.count >= 2)
    #expect(!Self.disallowed(profiles.first ?? []).contains("mcp__other"), "\(profiles)")
    #expect(Self.disallowed(profiles.last ?? []).contains("mcp__other"), "\(profiles)")
    let poll = Self.disallowed(try #require(sbd.slackRuns("slack-calls.log").last))
    #expect(poll.contains("mcp__other"), "\(poll)")
    #expect(poll.contains(Self.sendTool), "\(poll)")
    #expect(!poll.contains(Self.readTool), "\(poll)")
    #expect(!poll.contains("mcp__claude_ai_Slack"), "\(poll)")
  }

  /// The profile id stays in memory, so only the poll meets the new server, and its log shows the refused attempt.
  @Test func addingAServerLaterIsDeniedAndRetried() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    _ = try addLink(sbd, s.id, SlackExample.root)
    let first = try pollAndRead(sbd, s.id)
    let mark = sbd.slackRuns("slack-calls.log").count

    try sbd.writeSlackSwitch("slack-extra-tools", "mcp__late__run\n")
    let second = try pollAndRead(sbd, s.id)

    #expect((second["read"]?.int ?? 0) > (first["read"]?.int ?? 0))
    #expect(second["error"] == nil)
    let later = Array(sbd.slackRuns("slack-calls.log").dropFirst(mark))
    #expect(later.count >= 2, "\(later)")
    #expect(!Self.disallowed(later.first ?? []).contains("mcp__late"), "\(later)")
    #expect(Self.disallowed(later.last ?? []).contains("mcp__late"), "\(later)")
    #expect(!Self.disallowed(later.last ?? []).contains(Self.readTool), "\(later)")
  }

  @Test func skippedThreadIsAFailedRead() throws {
    let sbd = try Instance(config: Self.config)
    try sbd.writeSlackSwitch("slack-skip", "\(Self.secondChannel)/\(Self.secondTs)\n")
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    _ = try addLink(sbd, s.id, Self.secondThread)
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])
    try sbd.writeSlackThread(
      channel: Self.secondChannel, ts: Self.secondTs,
      [SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])

    let read = try pollAndRead(sbd, s.id)

    #expect(read["replies"]?.int == 1)
    #expect(read["error"] == nil)
    let skipped = try waitForStatus(sbd, s.id, url: Self.secondThread, "the skipped thread's error") {
      $0["error"]?.string != nil
    }
    #expect(skipped["replies"] == nil)
    #expect(skipped["read"] == nil)
    #expect(skipped["watched"]?.bool == true)
  }

  // MARK: Last looked

  @Test func openingTheLinkClearsTheMark() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let link = try addLink(sbd, s.id, SlackExample.root)
    let linkId = try #require(link["id"]?.string)
    let t = try time(link)
    let first = SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")
    try sbd.writeSlackThread([first])
    let marked = try pollAndRead(sbd, s.id)
    #expect(marked["newReply"]?.bool == true)

    let opened = try sbd.client.call(
      "link-open", ["session": .string(s.id), "link": .string(linkId), "by": "you"])

    #expect(opened["links"]?.array?.first?["status"]?["newReply"]?.bool == false, "\(opened)")
    #expect(try status(sbd, s.id)?["newReply"]?.bool == false)

    let newer = SlackReply(ts: Self.ts(try sbd.now() + 60_000), user: Self.other, name: "Alice")
    try sbd.writeSlackThread([first, newer])
    let again = try pollAndRead(sbd, s.id)
    #expect(again["replies"]?.int == 2)
    #expect(again["newReply"]?.bool == true)

    let refusal = failure(
      sbd, "link-open", ["session": .string(s.id), "link": .string(linkId), "by": "claude", "caller": .string(s.id)])
    #expect(refusal.contains("Only you can open a link."), "\(refusal)")
    #expect(try status(sbd, s.id)?["newReply"]?.bool == true)
  }

  /// The app sends `link-open` through a queue with `at`, the time of the click. A reply posted between the click and
  /// the request still counts as new.
  @Test func anOpenCountsFromTheClick() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let link = try addLink(sbd, s.id, SlackExample.root)
    let linkId = try #require(link["id"]?.string)
    let first = SlackReply(ts: Self.ts(try time(link) + 60_000), user: Self.other, name: "Alice")
    try sbd.writeSlackThread([first])
    _ = try pollAndRead(sbd, s.id)
    let now = try sbd.now()
    let between = SlackReply(ts: Self.ts(now - 30_000), user: Self.other, name: "Alice")
    try sbd.writeSlackThread([first, between])

    _ = try sbd.client.call(
      "link-open",
      ["session": .string(s.id), "link": .string(linkId), "by": "you", "at": .number(Double(now - 60_000))])
    let read = try pollAndRead(sbd, s.id)

    #expect(read["replies"]?.int == 2)
    #expect(read["newReply"]?.bool == true)
    let refusal = failure(
      sbd, "link-open", ["session": .string(s.id), "link": .string(linkId), "by": "you", "at": "soon"])
    #expect(refusal.contains("at must be"), "\(refusal)")
  }

  @Test func acknowledgingClearsTheMark() throws {
    // The idle stop stays past the clock moves, so the session keeps its Inbox item.
    let sbd = try Instance(idleStopSeconds: 7200, config: Self.config)
    let s = try sbd.new(prompt: "hello", name: "flags-cache")
    try sbd.waitFor(s.id, "the summary of the first reply") { $0.state == .needsYou && $0.triage?.source == .summary }
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])
    let marked = try pollAndRead(sbd, s.id)
    #expect(marked["newReply"]?.bool == true)

    try sbd.sb("ack", s.id)

    #expect(try status(sbd, s.id)?["newReply"]?.bool == false)

    try sbd.sb("ack", "--undo", s.id)

    #expect(try status(sbd, s.id)?["newReply"]?.bool == true)
  }

  // MARK: Storage and readers

  /// A restart drops the clock offset and the profile id, so the first scan after it polls at once. The stub fails
  /// the profile call, so sbd makes no thread call (D3) and the status keeps the stored values.
  @Test func statusSurvivesARestart() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])
    let before = try pollAndRead(sbd, s.id)
    try sbd.writeSlackSwitch("slack-fail")
    let runs = sbd.slackRuns("slack-calls.log").count

    sbd.stopSbd()
    try sbd.startSbd()

    let after = try waitForStatus(sbd, s.id, "the profile error") {
      $0["error"]?.string?.contains("can't read your Slack profile") == true
    }
    #expect(after["replies"]?.int == 1)
    #expect(kept(after) == kept(before))
    #expect(sbd.slackRuns("slack-calls.log").count == runs)
  }

  @Test func mcpGetSessionCarriesTheStatus() throws {
    let sbd = try Instance(config: Self.config)
    let s = try sbd.new(name: "flags-cache")
    let t = try time(try addLink(sbd, s.id, SlackExample.root))
    try sbd.writeSlackThread([SlackReply(ts: Self.ts(t + 60_000), user: Self.other, name: "Alice")])
    try pollAndRead(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let got = try #require(try mcp.call("get_session", ["session": .string(s.id), "full": true]).json)

    let status = try #require(got["links"]?.array?.first?["status"], "\(got)")
    #expect(status["replies"]?.int == 1)
    #expect(status["newReply"]?.bool == true)
    #expect(status["lastReply"]?["user"]?.string == Self.other)
  }

  /// Checks the condition every 0.2 s for the seconds, and fails at the first check that is false.
  func stays(_ what: String, for seconds: Double = 2, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      try #require(try condition(), "\(what)")
      usleep(200_000)
    }
  }
}
