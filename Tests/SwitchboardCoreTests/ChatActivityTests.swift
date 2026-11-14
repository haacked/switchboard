import Foundation
import Testing

@testable import SwitchboardCore

// MARK: - Fixtures

/// A Stop event of the main session, with `message` as its last assistant message.
private func stopReply(_ t: Int64, _ message: String = "Done.") -> Event {
  event("Stop", t, ["last_assistant_message": .string(message)])
}

/// A `chat-read` event, with no `replies` when `count` is nil.
private func chatRead(_ t: Int64, _ count: Int?) -> Event {
  event(ChatActivity.readEvent, t, count.map { ["replies": .number(Double($0))] } ?? [:])
}

/// A prompt that the user typed.
private func userPrompt(_ t: Int64, _ text: String = "go") -> Event {
  event("UserPromptSubmit", t, ["prompt": .string(text)])
}

/// The events of `count` turns, each a user prompt and a reply, starting at `start`.
private func turns(_ count: Int, start: Int64 = 1000) -> [Event] {
  (0..<count).flatMap { i -> [Event] in
    let t = start + Int64(i) * 1000
    return [userPrompt(t, "turn \(i)"), stopReply(t + 500, "Done: turn \(i)")]
  }
}

/// A group chat's session, so that `Attention.evaluate` applies the chat's rules.
private func chatSession() -> Session {
  var s = session()
  s.chat = "g1"
  return s
}

/// A card as sbd lists it. A send card holds a message to group g1.
private func markCard(_ id: Int64, _ kind: Card.Kind, summary: String = "`touch x`") -> Card {
  var json: [String: JSON] = [
    "id": .number(Double(id)), "session": "c", "kind": .string(kind.rawValue), "tool": "Bash",
    "summary": .string(summary), "input": [:], "questions": [], "since": 0, "deferred": false, "hookClosed": false,
  ]
  if kind == .send {
    json["tool"] = "send_group"
    json["send"] = ["group": "g1", "groupName": "Flags", "text": "Rebase.", "targets": [], "expires": 0]
  }
  return try! JSONCoding.convert(JSON.object(json), to: Card.self)
}

/// A group chat's summary as sbd builds it. `activity` nil is what an sbd from before read state sends.
private func chatSummary(
  state: AttentionState = .needsYou, reason: String = "read its last reply and decide what's next",
  activity: ChatActivity? = ChatActivity(replies: 0, unread: 0), cards: [Card] = [], openPrompt: Bool = false
) -> SessionSummary {
  var s = SessionSummary(
    id: "c", name: "Flags chat", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "c", state: state,
    reason: reason, since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil,
    waits: [], notes: [], cards: cards, openPrompt: openPrompt)
  s.kind = .chat
  s.chat = "g1"
  s.activity = activity
  return s
}

// MARK: - Facts

/// The reply count, the read count, and the last message time that
/// `SessionFacts.apply` builds from a chat's events.
@Suite struct ChatActivityFacts {
  // MARK: What counts as a reply

  @Test func twoStopsWithMessagesAreTwoReplies() {
    let f = facts([stopReply(1), stopReply(2)])

    #expect(f.replies == 2)
  }

  @Test(
    arguments: [
      [:],
      ["last_assistant_message": ""],
      ["last_assistant_message": .null],
    ] as [[String: JSON]])
  func aStopWithoutAMessageCountsNone(_ data: [String: JSON]) {
    let f = facts([event("Stop", 1, data)])

    #expect(f.replies == 0)
  }

  @Test func aStopWithoutAMessageLeavesTheLastMessageTime() {
    let f = facts([stopReply(1), event("Stop", 2, ["last_assistant_message": ""])])

    #expect(f.lastMessageAt == 1)
  }

  @Test func aSubagentsStopCountsNone() {
    let f = facts([event("Stop", 1, ["last_assistant_message": "Found it.", "agent_id": "a1"])])

    #expect(f.replies == 0)
    #expect(f.lastMessageAt == nil)
  }

  /// `StopFailure` and `idle` end a turn without a reply. `SubagentStop` is a subagent's. A remote host's
  /// `reconciled` carries a reply that this Mac never counts, because chats run on this Mac only.
  @Test(arguments: [
    event("StopFailure", 1, ["last_assistant_message": "API Error: 529"]),
    event("idle", 1),
    event("SubagentStop", 1, ["last_assistant_message": "Found it.", "agent_id": "a1"]),
    event("reconciled", 1, ["lastReply": "Done.", "lastActivity": 1]),
  ])
  func anEventThatIsNotAMainSessionStopCountsNone(_ e: Event) {
    let f = facts([e])

    #expect(f.replies == 0)
    #expect(f.lastMessageAt == nil)
  }

  @Test func aReplyToATurnThatAWaitOutcomeStartedCounts() {
    let outcome = "Switchboard: the wait on CI ended. CI passed."
    let f = facts([
      event("sent", 1, ["text": .string(outcome), "delivery": "resumed", "by": "sbd"]),
      event("UserPromptSubmit", 2, ["prompt": .string(outcome)]),
      stopReply(3),
    ])

    #expect(f.replies == 1)
  }

  // MARK: Last message time

  @Test func aUserPromptSetsTheLastMessageTime() {
    let f = facts([userPrompt(5)])

    #expect(f.lastMessageAt == 5)
  }

  @Test func aReplySetsTheLastMessageTime() {
    let f = facts([userPrompt(5), stopReply(9)])

    #expect(f.lastMessageAt == 9)
  }

  @Test func aPromptAfterTheReplyMovesTheLastMessageTime() {
    let f = facts([userPrompt(5), stopReply(9), userPrompt(12)])

    #expect(f.lastMessageAt == 12)
  }

  @Test func sbdsOwnNoticeDoesNotMoveTheLastMessageTime() {
    let notice = "Switchboard: the wait on CI ended. CI passed."
    let f = facts([
      stopReply(3),
      event("sent", 4, ["text": .string(notice), "delivery": "pasted", "by": "sbd"]),
      event("UserPromptSubmit", 5, ["prompt": .string(notice)]),
    ])

    #expect(f.lastMessageAt == 3)
  }

  @Test(arguments: [
    "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n</task-notification>",
    "<agent-message from=\"a1\">Found it.</agent-message>",
    peerMessage,
  ])
  func aPromptThatIsNotTheUsersDoesNotMoveTheLastMessageTime(_ prompt: String) {
    let f = facts([stopReply(3), event("UserPromptSubmit", 5, ["prompt": .string(prompt)])])

    #expect(f.lastMessageAt == 3)
  }

  /// `applyReplies` must read the prompt check that `apply` already made. A second call of `isUserPrompt` on the
  /// first prompt would consume the second notice's remembered text, so the second notice would count as the user's.
  @Test func twoSbdNoticesWithTheSameTextMoveNeitherTheLastMessageTimeNorThePromptCount() {
    let notice = "Switchboard: the wait on CI ended. CI passed."
    let f = facts([
      stopReply(1),
      event("sent", 2, ["text": .string(notice), "delivery": "queued", "by": "sbd"]),
      event("sent", 3, ["text": .string(notice), "delivery": "queued", "by": "sbd"]),
      event("UserPromptSubmit", 4, ["prompt": .string(notice)]),
      event("UserPromptSubmit", 5, ["prompt": .string(notice)]),
    ])

    #expect(f.lastMessageAt == 1)
    #expect(f.prompts == 0)
  }

  // MARK: chat-read

  @Test func noReadEventLeavesTheReadCountUnknown() {
    let f = facts(turns(2))

    #expect(f.repliesRead == nil)
  }

  /// Plan step 4: `unread = max(0, replies - (repliesRead ?? 0))`.
  @Test func aChatWithNoReadEventShowsEveryReplyUnread() {
    let activity = ChatActivity(facts(turns(2)))

    #expect(activity.unread == 2)
  }

  @Test func aReadOfZeroSetsTheReadCountToZero() {
    let f = facts([chatRead(1, 0)] + turns(2, start: 10))

    #expect(f.repliesRead == 0)
    #expect(ChatActivity(f).unread == 2)
  }

  @Test func aReadOfOneAfterThreeRepliesLeavesTwoUnread() {
    let f = facts([chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, 1)])

    #expect(f.repliesRead == 1)
    #expect(ChatActivity(f).unread == 2)
  }

  @Test func aReadAboveTheReplyCountClampsToTheReplies() {
    let f = facts([chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, 9)])

    #expect(f.repliesRead == 3)
    #expect(ChatActivity(f).unread == 0)
  }

  /// Without the clamp, the read of 9 would also hide the fourth reply.
  @Test func aReplyAfterAReadAboveTheCountIsUnread() {
    let f = facts([chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, 9), stopReply(9500, "Done: four")])

    #expect(ChatActivity(f).unread == 1)
  }

  @Test func aReadWithoutACountMarksEveryReplyRead() {
    let f = facts([chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, nil)])

    #expect(f.repliesRead == 3)
    #expect(ChatActivity(f).unread == 0)
  }

  @Test func aReadWithoutACountLeavesALaterReplyUnread() {
    let f = facts([chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, nil), stopReply(9500)])

    #expect(ChatActivity(f).unread == 1)
  }

  @Test(arguments: [0, 1, 2])
  func aLaterLowerReadDoesNotLowerTheReadCount(_ lower: Int) {
    let f = facts([chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, 3), chatRead(9100, lower)])

    #expect(f.repliesRead == 3)
    #expect(ChatActivity(f).unread == 0)
  }

  @Test func aNegativeReadCountChangesNothing() {
    let f = facts([chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, 1), chatRead(9100, -5)])

    #expect(f.repliesRead == 1)
  }

  // MARK: chat-read is not activity

  /// Histories that a read can follow: idle after a reply, in a turn, with an open permission prompt, and with an
  /// acknowledged Inbox item.
  static let histories: [(String, [Event])] = [
    ("idle after a reply", [chatRead(1, 0)] + turns(2, start: 10)),
    ("in a turn", [chatRead(1, 0)] + turns(1, start: 10) + [userPrompt(5000, "slow")]),
    (
      "with an open prompt",
      [chatRead(1, 0)] + turns(1, start: 10) + [
        userPrompt(5000, "perm"), event("PreToolUse", 5100, tool("Bash", ["command": "rm x"], id: "t1")),
        event("PermissionRequest", 5200, tool("Bash", ["command": "rm x"])),
      ]
    ),
    (
      "acknowledged",
      [chatRead(1, 0)] + turns(1, start: 10) + [
        event(
          "ack", 5000,
          (try! JSON(
            encoding: Acknowledgment(state: .needsYou, reason: "read its last reply and decide what's next", head: nil)))
            .object ?? [:])
      ]
    ),
  ]

  @Test(arguments: histories.map { $0.0 })
  func aReadChangesNoFactButTheReadCount(_ name: String) throws {
    let events = try #require(Self.histories.first { $0.0 == name }?.1)
    let before = facts(events)
    let readAt = (events.last?.t ?? 0) + 60_000

    var after = facts(events + [chatRead(readAt, nil)])
    after.repliesRead = before.repliesRead

    #expect(after == before)
  }

  @Test(arguments: histories.map { $0.0 })
  func aReadLeavesTheVerdictUnchanged(_ name: String) throws {
    let events = try #require(Self.histories.first { $0.0 == name }?.1)
    let readAt = (events.last?.t ?? 0) + 60_000
    let now = readAt + 1000

    let before = Attention.evaluate(chatSession(), facts(events), now: now)
    let after = Attention.evaluate(chatSession(), facts(events + [chatRead(readAt, nil)]), now: now)

    #expect(after == before)
    #expect(after.kind == before.kind)
    #expect(after.source == before.source)
  }

  @Test func aReadLeavesLastActivityAndStateSince() {
    var f = facts([chatRead(1, 0)] + turns(2, start: 10))
    f.stateSince = 777
    let lastActivity = f.lastActivity

    f.apply(chatRead(f.lastActivity + 60_000, nil))

    #expect(f.lastActivity == lastActivity)
    #expect(f.stateSince == 777)
  }

  // MARK: Replay

  @Test func replayingTheSameEventsIntoFreshFactsGivesEqualFacts() {
    let events = [chatRead(1, 0)] + turns(3, start: 10) + [chatRead(9000, 1), userPrompt(9500)]

    #expect(facts(events) == facts(events))
  }

  /// sbd builds facts from a snapshot plus the events after it. At every cut, that must give what a full replay
  /// gives, so a restart keeps the unread count.
  @Test func aSnapshotAndItsTailBuildTheReplyCountsThatAFullReplayBuilds() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let chat = chatSession()
    var t: Int64 = 0
    func e(_ kind: String, _ data: [String: JSON] = [:]) -> Event {
      t += 1000
      return Event(session: chat.id, t: t, kind: kind, data: .object(data))
    }
    let events = [
      e("created"), e(ChatActivity.readEvent, ["replies": 0]), e("SessionStart"),
      e("UserPromptSubmit", ["prompt": "one"]), e("Stop", ["last_assistant_message": "Done: one"]),
      e("UserPromptSubmit", ["prompt": "two"]), e("Stop", ["last_assistant_message": "Done: two"]),
      e(ChatActivity.readEvent, ["replies": 1]),
      e("sent", ["text": "Switchboard: wait ended.", "delivery": "pasted", "by": "sbd"]),
      e("UserPromptSubmit", ["prompt": "Switchboard: wait ended."]),
      e("Stop", ["last_assistant_message": "Done: wait"]), e("Stop", ["last_assistant_message": ""]),
      e("UserPromptSubmit", ["prompt": "three"]),
    ]
    for cut in 1..<events.count {
      try store.delete(session: chat.id)
      try store.save(chat)
      for event in events[..<cut] { try store.append(event) }
      _ = try Snapshots.refresh(store, chat, build: "b1")
      for event in events[cut...] { try store.append(event) }

      let fromSnapshot = try Snapshots.refresh(store, chat, build: "b1").snapshot.replay.facts
      let full = SessionReplay.replaying(try store.events(session: chat.id), session: chat).facts

      #expect(fromSnapshot.replies == full.replies, "cut \(cut)")
      #expect(fromSnapshot.repliesRead == full.repliesRead, "cut \(cut)")
      #expect(fromSnapshot.lastMessageAt == full.lastMessageAt, "cut \(cut)")
      #expect(fromSnapshot == full, "cut \(cut)")
    }
    let full = SessionReplay.replaying(try store.events(session: chat.id), session: chat).facts
    #expect(full.replies == 3)
    #expect(full.repliesRead == 1)
  }

  // MARK: Not an MCP tool

  /// Only the user marks a chat read, so no session reaches it through the switchboard MCP server.
  @Test func noMCPToolMarksAChatRead() {
    let names = MCPToolServer.allTools.map(\.name)

    let marksRead = names.filter {
      $0.contains("unread") || $0.contains("mark") || ($0.contains("read") && $0.contains("chat"))
    }

    #expect(marksRead.isEmpty, "\(names)")
  }
}

// MARK: - Marks

/// One input shape of the Risk 3 table, with the mark that every surface must show for it.
struct ChatMarkRow: Sendable, CustomTestStringConvertible {
  var name: String
  var summary: SessionSummary?
  var expected: ChatMark
  var testDescription: String { name }
}

@Suite struct ChatMarks {
  static let send = markCard(1, .send, summary: "`Rebase.` to Flags")
  static let permission = markCard(2, .permission)
  static let question = markCard(3, .question, summary: "Which fruit?")
  static let trust = markCard(4, .trust, summary: "/tmp/chats/g1")

  static let rows: [ChatMarkRow] = [
    ChatMarkRow(name: "no chat", summary: nil, expected: .none),
    ChatMarkRow(
      name: "a chat with no messages",
      summary: chatSummary(reason: "give it a first prompt", activity: ChatActivity(replies: 0, unread: 0)),
      expected: .idle(lastMessageAt: nil)),
    ChatMarkRow(
      name: "all replies read",
      summary: chatSummary(activity: ChatActivity(replies: 3, unread: 0, lastMessageAt: 50)),
      expected: .idle(lastMessageAt: 50)),
    ChatMarkRow(
      name: "unread 2 while idle",
      summary: chatSummary(activity: ChatActivity(replies: 3, unread: 2, lastMessageAt: 50)),
      expected: .unread(2, working: false)),
    ChatMarkRow(
      name: "unread 2 while working",
      summary: chatSummary(
        state: .working, reason: "thinking", activity: ChatActivity(replies: 3, unread: 2, lastMessageAt: 50)),
      expected: .unread(2, working: true)),
    ChatMarkRow(
      name: "working with none unread",
      summary: chatSummary(
        state: .working, reason: "thinking", activity: ChatActivity(replies: 3, unread: 0, lastMessageAt: 50)),
      expected: .working),
    ChatMarkRow(
      name: "a send card only",
      summary: chatSummary(reason: send.reason, cards: [send]),
      expected: .needsMe(send.reason)),
    ChatMarkRow(
      name: "a send card then a permission card",
      summary: chatSummary(reason: permission.reason, cards: [send, permission], openPrompt: true),
      expected: .needsMe(send.reason)),
    ChatMarkRow(
      name: "a permission card with unread replies",
      summary: chatSummary(
        state: .needsYou, reason: permission.reason, activity: ChatActivity(replies: 3, unread: 2, lastMessageAt: 50),
        cards: [permission], openPrompt: true),
      expected: .needsMe(permission.reason)),
    ChatMarkRow(
      name: "a permission card mid-turn",
      summary: chatSummary(state: .working, reason: "thinking", cards: [permission], openPrompt: true),
      expected: .needsMe(permission.reason)),
    ChatMarkRow(
      name: "an open prompt with no card",
      summary: chatSummary(reason: "approve `rm -rf build`", openPrompt: true),
      expected: .needsMe("approve `rm -rf build`")),
    ChatMarkRow(
      name: "a trust card",
      summary: chatSummary(reason: trust.reason, cards: [trust]),
      expected: .needsMe(trust.reason)),
    ChatMarkRow(
      name: "a question card",
      summary: chatSummary(reason: question.reason, cards: [question], openPrompt: true),
      expected: .needsMe(question.reason)),
    ChatMarkRow(
      name: "Needs you from a reply only, read",
      summary: chatSummary(state: .needsYou, activity: ChatActivity(replies: 1, unread: 0, lastMessageAt: 50)),
      expected: .idle(lastMessageAt: 50)),
    ChatMarkRow(
      name: "Needs you from a reply only, unread",
      summary: chatSummary(state: .needsYou, activity: ChatActivity(replies: 1, unread: 1, lastMessageAt: 50)),
      expected: .unread(1, working: false)),
    ChatMarkRow(
      name: "Needs you from an expired wait",
      summary: chatSummary(
        state: .needsYou, reason: "the wait on CI expired after a day",
        activity: ChatActivity(replies: 1, unread: 0, lastMessageAt: 50)),
      expected: .idle(lastMessageAt: 50)),
    ChatMarkRow(
      name: "a Done chat",
      summary: chatSummary(
        state: .done, reason: "done", activity: ChatActivity(replies: 4, unread: 0, lastMessageAt: 70)),
      expected: .idle(lastMessageAt: 70)),
    ChatMarkRow(
      name: "activity nil while Needs you",
      summary: chatSummary(state: .needsYou, activity: nil),
      expected: .idle(lastMessageAt: nil)),
    ChatMarkRow(
      name: "activity nil while working",
      summary: chatSummary(state: .working, reason: "thinking", activity: nil),
      expected: .working),
    ChatMarkRow(
      name: "activity nil with a permission card",
      summary: chatSummary(reason: permission.reason, activity: nil, cards: [permission], openPrompt: true),
      expected: .needsMe(permission.reason)),
  ]

  @Test(arguments: rows)
  func theMarkFollowsThePrecedence(_ row: ChatMarkRow) {
    #expect(ChatMark(row.summary) == row.expected)
  }

  /// A send card waits on the user to send or cancel its message, though it stays out of the Inbox.
  @Test(arguments: [Card.Kind.permission, .question, .trust, .send])
  func everyCardKindNeedsMe(_ kind: Card.Kind) {
    #expect(ChatMark.needsMe(cards: [markCard(1, kind)], openPrompt: false))
  }

  @Test(arguments: [Card.Kind.permission, .question, .trust, .send])
  func everyCardKindGivesTheNeedsMeMarkWithItsReason(_ kind: Card.Kind) {
    let card = markCard(1, kind)

    #expect(ChatMark(chatSummary(reason: "other", cards: [card])) == .needsMe(card.reason))
  }

  @Test func anOpenPromptAloneNeedsMe() {
    #expect(ChatMark.needsMe(cards: [], openPrompt: true))
  }

  @Test func noCardAndNoPromptDoesNotNeedMe() {
    #expect(!ChatMark.needsMe(cards: [], openPrompt: false))
  }

  /// `ChatMark` counts send cards, while the Inbox keeps leaving them out.
  @Test func aSendCardNeedsMeButDoesNotBlockTheInbox() {
    #expect(ChatMark.needsMe(cards: [Self.send], openPrompt: false))
    #expect(!Triage.hasBlockingPrompt(cards: [Self.send], openPrompt: false))
  }
}
