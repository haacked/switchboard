import Foundation
import SwitchboardCore
import Testing

/// Each loop run stores the id of its `sent` event in `Schedule.Run.sent`. `chat-log` with that id marks the run's
/// own prompt in the transcript with `sent`. It marks a message only when the run's byte window holds exactly one
/// user message with the run's text, in the conversation that the run went to. Every other case returns the plain
/// window with nothing marked. The loops run on Manager conversations, because `chat-log` reads only chat kinds.
@Suite(.blocking(timeLimit: .seconds(120))) struct RunReplyTests {
  let fire = ScheduleFireTests()
  let chats = ChatReadTests()

  // MARK: Helpers

  func chatLogArgs(_ session: String, sent: Int64?, limit: Int?) -> [String: JSON] {
    var args: [String: JSON] = ["session": .string(session)]
    if let sent { args["sent"] = .number(Double(sent)) }
    if let limit { args["limit"] = .number(Double(limit)) }
    return args
  }

  /// The session's `chat-log`, read with `sent` when one is given.
  func chatLog(_ sbd: Instance, _ session: String, sent: Int64? = nil, limit: Int? = nil) throws -> [ChatMessage] {
    try JSONCoding.convert(
      sbd.client.call("chat-log", chatLogArgs(session, sent: sent, limit: limit)), to: [ChatMessage].self)
  }

  /// The messages of the `chat-log` answer as sbd wrote them, before decoding.
  func rawChatLog(_ sbd: Instance, _ session: String, sent: Int64? = nil) throws -> [JSON] {
    try #require(try sbd.client.call("chat-log", chatLogArgs(session, sent: sent, limit: nil)).array)
  }

  /// The indices of every message that carries a `sent` mark.
  func marks(_ log: [ChatMessage]) -> [Int] { log.indices.filter { log[$0].sent != nil } }

  /// The index of the one marked message. It requires that the mark names `sent`, sits on a user message with the
  /// prompt, and that Claude's reply to the prompt follows it.
  func markedPrompt(_ log: [ChatMessage], _ sent: Int64, _ prompt: String) throws -> Int {
    let marked = marks(log)
    try #require(marked.count == 1, "marks at \(marked) in \(log)")
    let i = marked[0]
    #expect(log[i].sent == sent)
    #expect(log[i].role == .user)
    #expect(log[i].text == prompt)
    try #require(i + 1 < log.count, "nothing follows the marked message in \(log)")
    #expect(log[i + 1].role == .assistant)
    #expect(log[i + 1].text == "Done: \(prompt)")
    return i
  }

  /// The indices of the user messages whose text is the prompt.
  func copies(_ log: [ChatMessage], _ prompt: String) -> [Int] {
    log.indices.filter { log[$0].role == .user && log[$0].text == prompt }
  }

  func event(_ sbd: Instance, _ session: String, _ id: Int64) throws -> Event {
    try #require(try sbd.events(session).first { $0.id == id }, "no event \(id) in \(session)")
  }

  /// The session's `pasting` events of the prompt, oldest first.
  func pastings(_ sbd: Instance, _ session: String, _ prompt: String) throws -> [Event] {
    try sbd.events(session, kind: "pasting").filter { $0.data["text"]?.string == prompt }
  }

  /// The size of the conversation's transcript, which the stub writes under the home, as
  /// `Instance.transcriptContains` finds it.
  func transcriptBytes(_ sbd: Instance, _ claudeSessionId: String) throws -> Int {
    let files = FileManager.default.enumerator(atPath: sbd.home.path)?.compactMap { $0 as? String } ?? []
    let file = try #require(files.first { $0.hasSuffix("/\(claudeSessionId).jsonl") }, "no transcript")
    let attributes = try FileManager.default.attributesOfItem(atPath: "\(sbd.home.path)/\(file)")
    return try #require((attributes[.size] as? NSNumber)?.intValue)
  }

  /// A conversation with a loop whose one run was pasted and answered. It returns the run's `sent` id.
  func conversationWithOneRun(_ sbd: Instance, _ prompt: String) throws -> (SessionSummary, Schedule, Int64) {
    let c = try chats.idleConversation(sbd)
    let made = try fire.schedule(sbd, c.id, prompt)
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try sbd.waitFor(c.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: \(prompt)" }
    let run = try fire.waitForRun(sbd, c.id, made.id)
    try #require(run.outcome == .pasted, "\(run)")
    return (c, made, try #require(run.sent, "\(run)"))
  }

  // MARK: Run.sent

  /// The session row, `sb get --json`, `sb schedule ls --json`, `schedule-ran`, and the run's `pasting` all name
  /// the same `sent` event.
  @Test func aPastedRunNamesItsSentEventInEveryRecordOfTheRun() throws {
    let sbd = try Instance()
    let (c, made, sent) = try conversationWithOneRun(sbd, "tick linked")

    let sentEvents = try fire.runs(sbd, c.id, "tick linked")
    let got = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("get", c.id, "--json"))
    let rows = try JSONCoding.decode([ScheduleRow].self, from: sbd.sb("schedule", "ls", "--json"))
    let ran = try fire.scheduleRan(sbd, c.id)
    let pasting = try #require(try pastings(sbd, c.id, "tick linked").last)

    try #require(sentEvents.count == 1, "\(sentEvents)")
    #expect(sent == sentEvents[0].id)
    #expect(got.schedules?.first { $0.id == made.id }?.runs?.first?.sent == sent)
    #expect(rows.first { $0.schedule.id == made.id }?.schedule.runs?.first?.sent == sent)
    try #require(ran.count == 1, "\(ran)")
    let ranSchedule = try JSONCoding.convert(try #require(ran[0].data["schedule"]), to: Schedule.self)
    #expect(ranSchedule.runs?.first?.sent == sent)
    #expect(pasting.data["sent"]?.int == Int(sent), "\(pasting)")
    #expect(pasting.data["conversation"]?.string == c.claudeSessionId, "\(pasting)")
  }

  /// The run starts claude, so its `sent` event holds the mark: the conversation and the transcript's size before
  /// the launch. `sb stop` keeps the clock short of the schedule's next run.
  @Test func aResumedRunsSentEventHoldsTheMarkAndChatLogMarksTheRun() throws {
    let sbd = try Instance()
    let c = try chats.idleConversation(sbd)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the stop") { $0.claudePid == nil && !$0.live }
    let sizeBefore = try transcriptBytes(sbd, c.claudeSessionId)
    let made = try fire.schedule(sbd, c.id, "tick resumed")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(c.id, "the reply to the resumed run", timeout: 30) { $0.lastReply == "Done: tick resumed" }
    let run = try fire.waitForRun(sbd, c.id, made.id)
    try #require(run.outcome == .resumed, "\(run)")
    let sent = try #require(run.sent, "\(run)")
    let stored = try event(sbd, c.id, sent)
    #expect(stored.kind == "sent")
    #expect(stored.data["delivery"]?.string == "resumed", "\(stored)")
    #expect(stored.data["conversation"]?.string == c.claudeSessionId, "\(stored)")
    #expect(stored.data["transcript_bytes"]?.int == sizeBefore, "\(stored)")
    _ = try markedPrompt(try chatLog(sbd, c.id, sent: sent), sent, "tick resumed")
  }

  /// A loop slower than the idle stop resumes claude with each run's prompt, so no `pasting` follows a run. The next
  /// run's launch ends the earlier run's mark, so each run marks its own copy.
  @Test func eachOfTwoResumedRunsMarksItsOwnCopyOfThePrompt() throws {
    let sbd = try Instance()
    let c = try chats.idleConversation(sbd)
    let made = try fire.schedule(sbd, c.id, "tick slow")
    for count in 1...2 {
      try sbd.sb("stop", c.id)
      try sbd.waitFor(c.id, "the stop") { $0.claudePid == nil && !$0.live }
      try sbd.advanceClock(ScheduleFireTests.pastDue)
      try sbd.waitFor("run \(count)", timeout: 30) {
        try fire.current(sbd, c.id, made.id)?.runs?.count == count
          && fire.prompts(sbd, c.id, "tick slow").count == count
      }
      try sbd.waitFor(c.id, "the reply to run \(count)", timeout: 30) { $0.lastReply == "Done: tick slow" }
    }

    let runs = try #require(try fire.current(sbd, c.id, made.id)?.runs)
    try #require(runs.map(\.outcome) == [.resumed, .resumed], "\(runs)")
    let newer = try #require(runs[0].sent, "\(runs)")
    let older = try #require(runs[1].sent, "\(runs)")
    let olderAt = try markedPrompt(try chatLog(sbd, c.id, sent: older), older, "tick slow")
    let newerAt = try markedPrompt(try chatLog(sbd, c.id, sent: newer), newer, "tick slow")
    #expect(olderAt < newerAt)
  }

  /// A user's message that relaunches the chat with the same text ends the run's mark, so the run keeps its link.
  @Test func aSendThatRelaunchesTheChatWithTheSamePromptEndsTheRunsMark() throws {
    let sbd = try Instance()
    let c = try chats.idleConversation(sbd)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the stop") { $0.claudePid == nil && !$0.live }
    let made = try fire.schedule(sbd, c.id, "tick again")
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    let run = try fire.waitForRun(sbd, c.id, made.id)
    try #require(run.outcome == .resumed, "\(run)")
    try sbd.waitFor(c.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick again" }

    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the second stop") { $0.claudePid == nil && !$0.live }
    try sbd.sb("send", c.id, "tick again")
    try sbd.waitFor("the sent copy", timeout: 30) { try fire.prompts(sbd, c.id, "tick again").count == 2 }
    try sbd.waitFor("the reply to the send", timeout: 30) {
      try chatLog(sbd, c.id).filter { $0.role == .assistant && $0.text == "Done: tick again" }.count == 2
    }
    let send = try #require(try fire.prompts(sbd, c.id, "tick again").last)
    let stored = try #require(try sbd.events(c.id).last { $0.kind == "sent" && $0.id < send.id })
    #expect(stored.data["delivery"]?.string == "resumed", "\(stored)")

    let sent = try #require(run.sent, "\(run)")
    let log = try chatLog(sbd, c.id, sent: sent)
    let at = try markedPrompt(log, sent, "tick again")
    #expect(at < (log.lastIndex { $0.role == .user && $0.text == "tick again" } ?? -1))
  }

  /// Decision 8: only a conversation measures its transcript for a resumed run.
  @Test func aWorkSessionsResumedRunHasASentIdAndNoMark() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    try sbd.passIdleStop(s.id)
    let made = try fire.schedule(sbd, s.id, "tick work")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the resumed run", timeout: 30) { $0.lastReply == "Done: tick work" }
    let run = try fire.waitForRun(sbd, s.id, made.id)
    try #require(run.outcome == .resumed, "\(run)")
    let stored = try event(sbd, s.id, try #require(run.sent, "\(run)"))
    #expect(stored.kind == "sent")
    #expect(stored.data["text"]?.string == "tick work")
    #expect(stored.data["conversation"] == nil, "\(stored)")
    #expect(stored.data["transcript_bytes"] == nil, "\(stored)")
  }

  /// Decision 9: a run whose send threw has no `sent` event to name.
  @Test func aFailedRunHasNoSentId() throws {
    let sbd = try Instance()
    let (s, made) = try fire.doomedLoop(sbd, every: "1m", "tick gone")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let run = try fire.waitForRun(sbd, s.id, made.id)
    try #require(run.outcome == .failed, "\(run)")
    #expect(run.sent == nil)
  }

  // MARK: Which message chat-log marks

  /// Both runs send the same text, so only the byte windows tell the two copies apart. `fireOnce` waits on run
  /// and Stop counts, because the reply text is the same for both runs.
  @Test func eachOfTwoRunsOfOneLoopMarksItsOwnCopyOfThePrompt() throws {
    let sbd = try Instance()
    let c = try chats.idleConversation(sbd)
    let made = try fire.schedule(sbd, c.id, "tick twice")
    let history = ScheduleHistoryTests()

    for i in 1...2 { try history.fireOnce(sbd, c.id, made.id, count: i) }

    let runs = try #require(try fire.current(sbd, c.id, made.id)?.runs)
    try #require(runs.count == 2, "\(runs)")
    let newer = try #require(runs[0].sent, "\(runs)")
    let older = try #require(runs[1].sent, "\(runs)")
    let olderAt = try markedPrompt(try chatLog(sbd, c.id, sent: older), older, "tick twice")
    let newerAt = try markedPrompt(try chatLog(sbd, c.id, sent: newer), newer, "tick twice")
    let plain = try chatLog(sbd, c.id)
    #expect(olderAt < newerAt)
    #expect(copies(plain, "tick twice") == [olderAt, newerAt])
  }

  /// As `StoppedQueueTests.aDueScheduleRunsOnAStoppedSessionWithAQueuedMessage`, on a conversation, with the
  /// queued message holding the loop's own prompt. `StoppedQueueTests.stranded` starts from a work session under
  /// account A, so this copies its steps for a conversation stopped with `sb stop`.
  @Test func aQueuedRunBehindTheSameTextMarksTheSecondCopy() throws {
    let sbd = try Instance()
    let stopped = StoppedQueueTests()
    let prompt = "tick twin"
    let c = try chats.idleConversation(sbd)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the stop") { $0.claudePid == nil }
    let launchMark = try sbd.lastEventId(c.id)
    let pid = try stopped.launchUnreported(sbd, c, .killed, after: launchMark)
    try #require(try stopped.delivery(sbd.sb("send", "--json", c.id, prompt)) == "queued")
    let queuedSent = try #require(try sbd.events(c.id, "sent", text: prompt).last?.id)
    kill(pid_t(pid), SIGTERM)
    try sbd.waitFor(c.id, "claude to exit before SessionStart") { $0.claudePid == nil && !$0.live }
    try #require(try !sbd.events(c.id, after: launchMark).contains { $0.kind == "SessionStart" })
    try sbd.release(EarlyExit.killed.gate)
    let made = try fire.schedule(sbd, c.id, prompt)
    let mark = try sbd.lastEventId(c.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let run = try fire.waitForRun(sbd, c.id, made.id)
    try #require(run.outcome == .queued, "\(run)")
    try #require(try sbd.waitForPrompts(c.id, after: mark, count: 2) == [prompt, prompt])
    let sent = try #require(run.sent, "\(run)")
    let twins = copies(try chatLog(sbd, c.id), prompt)
    try #require(twins.count == 2, "\(twins)")
    #expect(try markedPrompt(try chatLog(sbd, c.id, sent: sent), sent, prompt) == twins[1])
    #expect(try markedPrompt(try chatLog(sbd, c.id, sent: queuedSent), queuedSent, prompt) == twins[0])
  }

  /// The plan's late-landing case can't happen with the stub. While `hold` exists, the stub has erased its prompt
  /// box and waits before it writes the prompt's line. `ClaudeScreen.promptIsEmpty` is false without a box, so
  /// sbd keeps the next run's message at the front of the queue, with no `pasting`, until the held turn ends.
  /// The next run's `pasting` therefore always comes after the held prompt landed. `TranscriptMarkTests` covers a
  /// prompt that lands after the next paste. This case covers a run whose paste waits behind an unreported prompt.
  @Test func aRunThatComesDueWhileTheLastRunsPromptIsHeldMarksItsOwnCopy() throws {
    let sbd = try Instance()
    let prompt = "tick held"
    let c = try chats.idleConversation(sbd)
    let made = try fire.schedule(sbd, c.id, prompt)
    sbd.hold("hold")
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try sbd.waitFor("the first run's paste") { try pastings(sbd, c.id, prompt).count == 1 }

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try sbd.waitFor("the second run") { try fire.current(sbd, c.id, made.id)?.runs?.count == 2 }
    sleep(1)
    sbd.hold("report")

    try sbd.waitFor("both runs' turns", timeout: 30) { try fire.prompts(sbd, c.id, prompt).count == 2 }
    let firstLanded = try #require(try fire.prompts(sbd, c.id, prompt).first)
    let secondPasting = try #require(try pastings(sbd, c.id, prompt).last)
    try #require(
      secondPasting.id > firstLanded.id,
      """
      the stub produced a late landing: the second run's paste came before the first prompt landed, so neither \
      run should mark a message
      """)
    let runs = try #require(try fire.current(sbd, c.id, made.id)?.runs)
    try #require(runs.count == 2, "\(runs)")
    let newer = try #require(runs[0].sent, "\(runs)")
    let older = try #require(runs[1].sent, "\(runs)")
    let olderAt = try markedPrompt(try chatLog(sbd, c.id, sent: older), older, prompt)
    let newerAt = try markedPrompt(try chatLog(sbd, c.id, sent: newer), newer, prompt)
    #expect(olderAt < newerAt)
  }

  /// Decision 3: a copy that the user types into the terminal lands in the run's window with no `pasting`, so the
  /// window holds two matches and nothing is marked.
  @Test func aCopyTypedIntoTheTerminalAfterTheRunMarksNothing() throws {
    let sbd = try Instance()
    let (c, _, sent) = try conversationWithOneRun(sbd, "tick typed")
    _ = try markedPrompt(try chatLog(sbd, c.id, sent: sent), sent, "tick typed")

    try sbd.type(c.id, "tick typed")
    try sbd.waitFor("the typed copy's turn", timeout: 30) { try fire.prompts(sbd, c.id, "tick typed").count == 2 }

    let plain = try chatLog(sbd, c.id)
    let anchored = try chatLog(sbd, c.id, sent: sent)
    #expect(copies(plain, "tick typed").count == 2)
    #expect(anchored == plain)
  }

  /// Decision 6: after `/clear`, the transcript that `chat-log` reads belongs to another conversation. The clear
  /// is typed, so no `pasting` in the old conversation ends the run's window. The new conversation then holds one
  /// copy of the prompt past the run's start offset, which a window that ignored the conversation would mark.
  @Test func aRunFromBeforeAClearMarksNothing() throws {
    let sbd = try Instance()
    let (c, _, sent) = try conversationWithOneRun(sbd, "tick before clear")
    let from = try #require(try pastings(sbd, c.id, "tick before clear").last?.data["transcript_bytes"]?.int)
    let next = UUID().uuidString.lowercased()

    try sbd.type(c.id, "clear \(next)")
    let cleared = try sbd.waitFor(c.id, "the new conversation") { $0.claudeSessionId == next }
    try sbd.waitFor("the new conversation's transcript") { sbd.transcriptContains(cleared, "/clear") }
    try chats.turn(sbd, c.id, "note " + String(repeating: "x", count: from + 64))
    try chats.turn(sbd, c.id, "tick before clear")

    let plain = try chatLog(sbd, c.id)
    let anchored = try chatLog(sbd, c.id, sent: sent)
    #expect(copies(plain, "tick before clear").count == 1)
    #expect(anchored == plain)
  }

  /// Decision 10: the answer holds the newest `limit` messages, or more, back to and including the run's prompt.
  @Test func aRunOlderThanTheLimitIsReachedAndMarked() throws {
    let sbd = try Instance()
    let (c, _, sent) = try conversationWithOneRun(sbd, "tick old")
    try chats.turn(sbd, c.id, "after one")
    try chats.turn(sbd, c.id, "after two")

    let anchored = try chatLog(sbd, c.id, sent: sent, limit: 2)
    let plain = try chatLog(sbd, c.id, limit: 2)

    #expect(anchored.count > 2)
    #expect(marks(anchored) == [0])
    #expect(try markedPrompt(anchored, sent, "tick old") == 0)
    #expect(Array(anchored.suffix(2)) == plain)
  }

  // MARK: The sent argument

  /// An id that names no `sent` event of the session.
  enum ForeignSent: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case anotherSessionsSentEvent
    case aPastingEventOfTheSession
    case aScheduleRanEventOfTheSession
    case anIdPastTheLastEvent

    var testDescription: String { rawValue }
  }

  /// An event id of the shape. `other` is the `sent` id of the other session's run.
  func foreignId(_ sbd: Instance, _ foreign: ForeignSent, session: String, other: Int64) throws -> Int64 {
    switch foreign {
    case .anotherSessionsSentEvent: return other
    case .aPastingEventOfTheSession: return try #require(try pastings(sbd, session, "tick shared").last?.id)
    case .aScheduleRanEventOfTheSession: return try #require(try fire.scheduleRan(sbd, session).last?.id)
    case .anIdPastTheLastEvent: return 1 << 40
    }
  }

  /// Both conversations said "tick shared" in a loop run, so a read that took another session's event could find
  /// a matching line.
  @Test(arguments: ForeignSent.allCases)
  func aSentThatIsNotASentEventOfTheSessionReturnsThePlainLog(_ foreign: ForeignSent) throws {
    let sbd = try Instance()
    let a = try chats.idleConversation(sbd, name: "a")
    let b = try chats.idleConversation(sbd, name: "b")
    let fromA = try fire.schedule(sbd, a.id, "tick shared")
    let fromB = try fire.schedule(sbd, b.id, "tick shared")
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    let runA = try fire.waitForRun(sbd, a.id, fromA.id)
    let runB = try fire.waitForRun(sbd, b.id, fromB.id)
    try sbd.waitFor(a.id, "a's run's reply", timeout: 30) { $0.lastReply == "Done: tick shared" }
    try sbd.waitFor(b.id, "b's run's reply", timeout: 30) { $0.lastReply == "Done: tick shared" }
    try #require(runA.sent != nil, "\(runA)")
    let id = try foreignId(sbd, foreign, session: a.id, other: try #require(runB.sent, "\(runB)"))

    let anchored = try chatLog(sbd, a.id, sent: id)
    let raw = try rawChatLog(sbd, a.id, sent: id)
    let plain = try chatLog(sbd, a.id)

    #expect(anchored == plain)
    #expect(copies(anchored, "tick shared").count == 1)
    #expect(raw.allSatisfy { $0["sent"] == nil }, "\(raw)")
  }

  /// Decision 11: a read without `sent` writes no `sent` key.
  @Test func aReadWithoutSentWritesNoSentKey() throws {
    let sbd = try Instance()
    let (c, _, _) = try conversationWithOneRun(sbd, "tick plain")

    let raw = try rawChatLog(sbd, c.id)

    #expect(raw.contains { $0["text"]?.string == "tick plain" })
    #expect(raw.allSatisfy { $0["sent"] == nil }, "\(raw)")
  }

  /// Decision 10: `role: assistant` drops the user messages, so it ignores `sent`.
  @Test func anAssistantOnlyReadIgnoresSent() throws {
    let sbd = try Instance()
    let (c, _, sent) = try conversationWithOneRun(sbd, "tick assistant")
    let args: [String: JSON] = ["session": .string(c.id), "role": "assistant"]

    let anchored = try sbd.client.call(
      "chat-log", args.merging(["sent": .number(Double(sent))]) { $1 }, as: [ChatMessage].self)
    let plain = try sbd.client.call("chat-log", args, as: [ChatMessage].self)

    #expect(anchored == plain)
    #expect(anchored.contains { $0.text == "Done: tick assistant" })
  }

  @Test(arguments: [JSON.string("abc"), .string("12"), .number(1.5), .bool(true)])
  func aSentThatIsNotAWholeNumberFails(_ value: JSON) throws {
    let sbd = try Instance()
    let c = try chats.idleConversation(sbd)

    let error = failure(sbd, "chat-log", ["session": .string(c.id), "sent": value])

    #expect(error.contains("sent is the id of a sent event"), Comment(rawValue: error))
  }
}
