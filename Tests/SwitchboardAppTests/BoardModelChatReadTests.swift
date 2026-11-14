import AppKit
import SwitchboardCore
import Testing
import os

@testable import SwitchboardApp

/// The requests that a model sent, in order.
private final class SentRequests: Sendable {
  struct Request: Equatable, Sendable {
    var op: String
    var args: [String: JSON]
  }

  private let list = OSAllocatedUnfairLock<[Request]>(initialState: [])
  var all: [Request] { list.withLock { $0 } }
  var reads: [Request] { all.filter { $0.op == ChatActivity.readEvent } }
  func append(_ op: String, _ args: [String: JSON]) { list.withLock { $0.append(Request(op: op, args: args)) } }
}

/// The chat of group g1, or a Manager conversation when `manager` is true, with `replies` replies of which
/// `unread` are unread. A nil `replies` gives no activity, as an sbd from before read state sends.
private func readable(
  _ id: String, manager: Bool = false, replies: Int? = 3, unread: Int = 2, state: AttentionState = .needsYou
) -> SessionSummary {
  var s = manager ? needsItem(id, manager: true, state: state) : chatItem(id, group: "g1", state: state)
  s.triage = nil
  s.activity = replies.map { ChatActivity(replies: $0, unread: unread, lastMessageAt: 1000) }
  return s
}

/// A model that has applied `list`, selected `selection`, and records its requests. `active` stands for
/// `NSApp.isActive`.
@MainActor
private func readingModel(_ list: [SessionSummary], selection: String?, active: Bool = true) -> (
  BoardModel, SentRequests
) {
  let model = offlineModel()
  let sent = SentRequests()
  model.send = { op, args in
    sent.append(op, args)
    return .null
  }
  model.isAppActive = { active }
  model.apply(.success(list), followups: nil)
  model.selection = selection
  return (model, sent)
}

/// Gives a request that the model queued time to reach `send`.
@MainActor
private func quiet() async { try? await Task.sleep(nanoseconds: 300_000_000) }

@MainActor
@Suite struct BoardModelChatRead {
  // MARK: The rule

  @Test func readThroughIsTheSummarysReplyCountForAnUnreadChatInTheActiveApp() {
    #expect(BoardModel.readThrough(readable("c")) == 3)
  }

  @Test func readThroughIsTheReplyCountForAConversation() {
    #expect(BoardModel.readThrough(readable("m", manager: true)) == 3)
  }

  @Test func readThroughIsNilWithNothingUnread() {
    #expect(BoardModel.readThrough(readable("c", unread: 0)) == nil)
  }

  @Test func readThroughIsNilWithoutActivity() {
    #expect(BoardModel.readThrough(readable("c", replies: nil)) == nil)
  }

  /// A work session has no read state, even if a summary carried activity.
  @Test func readThroughIsNilForAWorkSession() {
    var work = needsItem("w")
    work.activity = ChatActivity(replies: 3, unread: 2)

    #expect(BoardModel.readThrough(work) == nil)
  }

  // MARK: What markSelectedChatRead sends

  @Test func aSelectedChatWithUnreadRepliesInTheActiveAppIsMarkedReadThroughItsReplies() async {
    let (model, sent) = readingModel([readable("c"), needsItem("a")], selection: "c")

    model.markSelectedChatRead()
    await settle { !sent.reads.isEmpty }

    #expect(sent.reads == [.init(op: ChatActivity.readEvent, args: ["session": "c", "replies": 3])])
  }

  @Test func aSelectedConversationIsMarkedReadThroughItsReplies() async {
    let (model, sent) = readingModel([readable("m", manager: true), needsItem("a")], selection: "m")

    model.markSelectedChatRead()
    await settle { !sent.reads.isEmpty }

    #expect(sent.reads.map(\.args) == [["session": "m", "replies": 3]])
  }

  @Test func aRefreshMarksTheSelectedChatRead() async {
    let list = [readable("c"), needsItem("a")]
    let (model, sent) = readingModel(list, selection: "c")

    model.apply(.success(list), followups: nil)
    await settle { !sent.reads.isEmpty }

    #expect(sent.reads.map(\.args) == [["session": "c", "replies": 3]])
  }

  @Test func nothingIsSentWhileTheAppIsInactive() async {
    let (model, sent) = readingModel([readable("c")], selection: "c", active: false)

    model.markSelectedChatRead()
    await quiet()

    #expect(sent.reads.isEmpty)
  }

  @Test func nothingIsSentWithNothingUnread() async {
    let (model, sent) = readingModel([readable("c", unread: 0)], selection: "c")

    model.markSelectedChatRead()
    await quiet()

    #expect(sent.reads.isEmpty)
  }

  @Test func nothingIsSentWithoutActivity() async {
    let (model, sent) = readingModel([readable("c", replies: nil)], selection: "c")

    model.markSelectedChatRead()
    await quiet()

    #expect(sent.reads.isEmpty)
  }

  @Test func nothingIsSentForASelectedWorkSession() async {
    var work = needsItem("w")
    work.activity = ChatActivity(replies: 3, unread: 2)
    let (model, sent) = readingModel([work, readable("c")], selection: "w")

    model.markSelectedChatRead()
    await quiet()

    #expect(sent.reads.isEmpty)
  }

  @Test func nothingIsSentForAChatThatIsNotSelected() async {
    let (model, sent) = readingModel([readable("c"), readable("m", manager: true), needsItem("a")], selection: "a")

    model.markSelectedChatRead()
    await quiet()

    #expect(sent.reads.isEmpty)
  }

  @Test func nothingIsSentWithNoSelection() async {
    let (model, sent) = readingModel([readable("c")], selection: nil)

    model.markSelectedChatRead()
    await quiet()

    #expect(sent.reads.isEmpty)
  }

  // MARK: Repeats

  @Test func aSecondCallWithTheSameSummarySendsNothing() async {
    let (model, sent) = readingModel([readable("c")], selection: "c")
    model.markSelectedChatRead()
    await settle { !sent.reads.isEmpty }

    model.markSelectedChatRead()
    await quiet()

    #expect(sent.reads.count == 1)
  }

  /// sbd answers the read with the new summary, but until the next refresh the model still holds the old one. The
  /// refresh that follows must not send the same read again.
  @Test func aRefreshWithTheSameSummarySendsNothingMore() async {
    let list = [readable("c")]
    let (model, sent) = readingModel(list, selection: "c")
    model.markSelectedChatRead()
    await settle { !sent.reads.isEmpty }

    model.apply(.success(list), followups: nil)
    model.apply(.success(list), followups: nil)
    await quiet()

    #expect(sent.reads.count == 1)
  }

  @Test func aNewReplySendsAgainWithTheNewCount() async {
    let (model, sent) = readingModel([readable("c")], selection: "c")
    model.markSelectedChatRead()
    await settle { !sent.reads.isEmpty }

    model.apply(.success([readable("c", replies: 4, unread: 1)]), followups: nil)
    model.markSelectedChatRead()
    await settle { sent.reads.count >= 2 }

    #expect(sent.reads.map(\.args) == [["session": "c", "replies": 3], ["session": "c", "replies": 4]])
  }

  @Test func becomingActiveSendsTheReadThatTheInactiveAppHeldBack() async {
    let active = OSAllocatedUnfairLock(initialState: false)
    let (model, sent) = readingModel([readable("c")], selection: "c", active: false)
    model.isAppActive = { active.withLock { $0 } }
    model.markSelectedChatRead()
    await quiet()
    #expect(sent.reads.isEmpty)

    active.withLock { $0 = true }
    model.markSelectedChatRead()
    await settle { !sent.reads.isEmpty }

    #expect(sent.reads.map(\.args) == [["session": "c", "replies": 3]])
  }

  // MARK: Failure

  /// `apply` runs every second, so a failed read must not show the error banner. An older sbd has no `chat-read`.
  @Test func aFailedReadLeavesNoActionError() async {
    let (model, sent) = readingModel([readable("c")], selection: "c")
    model.send = { op, args in
      sent.append(op, args)
      throw Boom()
    }

    model.markSelectedChatRead()
    await settle { !sent.reads.isEmpty }
    await quiet()

    #expect(sent.reads.count == 1)
    #expect(model.actionError == nil)
  }

  // MARK: The Board's Chat button

  @Test func chatMarkOfAGroupWithNoChatIsNone() {
    let model = appliedModel([needsItem("a")])

    #expect(ChatMark(model.chat(of: "g1")) == .none)
  }

  @Test func chatMarkOfAGroupWithTwoUnreadRepliesIsUnread() {
    let model = appliedModel([readable("c"), needsItem("a")])

    #expect(ChatMark(model.chat(of: "g1")) == .unread(2, working: false))
  }

  @Test func chatMarkOfAGroupIsWhatChatMarkGivesForItsChat() throws {
    let chats = [
      readable("c"), readable("c", unread: 0), readable("c", state: .working),
      readable("c", replies: nil), try chatCard("c", group: "g1", kind: .send),
    ]
    for c in chats {
      let model = appliedModel([c])

      #expect(ChatMark(model.chat(of: "g1")) == ChatMark(c))
    }
  }

  @Test func chatMarkOfAnotherGroupIgnoresThisGroupsChat() {
    let model = appliedModel([readable("c")])

    #expect(ChatMark(model.chat(of: "g2")) == .none)
  }
}
