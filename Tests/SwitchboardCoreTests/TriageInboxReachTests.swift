import Foundation
import Testing

@testable import SwitchboardCore

/// A shape of what a session holds when its turn ends or stops, and whether
/// a work session and a conversation (the Manager or a group chat) with it
/// reach the Inbox.
struct InboxShape: CustomTestStringConvertible, Sendable {
  var name: String
  var events: @Sendable () throws -> [Event]
  var done = false
  var work: Bool
  var conversation: Bool
  var testDescription: String { name }
}

private let reply = [event("UserPromptSubmit", 0, ["prompt": "go"]), stop(5, 1, proseQuestion)]

private let permissionDialog = [
  event("UserPromptSubmit", 0, ["prompt": "go"]),
  event("Notification", 1, ["notification_type": "permission_prompt", "message": "Allow Bash?"]),
]

let inboxShapes: [InboxShape] = [
  InboxShape(name: "a reply", events: { reply }, work: true, conversation: false),
  InboxShape(name: "a summary of the reply", events: { reply + [triageEvent(5)] }, work: true, conversation: false),
  InboxShape(
    name: "an sb summary set card", events: { [try summaryEvent(9, 2, sessionCard)] }, work: true,
    conversation: false),
  InboxShape(name: "a send card", events: { [sendPending()] }, work: true, conversation: false),
  InboxShape(name: "a permission card", events: { permissionTurn() }, work: true, conversation: true),
  InboxShape(name: "a question card", events: { questionTurn() }, work: true, conversation: true),
  InboxShape(name: "a trust card", events: { trustLaunch() }, work: true, conversation: true),
  InboxShape(
    name: "a send card, then a permission card", events: { [sendPending()] + permissionTurn() }, work: true,
    conversation: true),
  InboxShape(
    name: "a permission card, then a send card", events: { permissionTurn() + [sendPending()] }, work: true,
    conversation: true),
  InboxShape(
    name: "a send card and a permission dialog without a card",
    events: {
      [
        sendPending(), event("UserPromptSubmit", 11, ["prompt": "go"]),
        event("Notification", 12, ["notification_type": "permission_prompt", "message": "Allow Bash?"]),
      ]
    }, work: true, conversation: true),
  InboxShape(
    name: "a send card and a dialog whose card's hook closed",
    events: { [sendPending()] + fetchTurn() + [event("card_closed", 11, ["card": 3])] }, work: true,
    conversation: true),
  InboxShape(name: "a permission dialog without a card", events: { permissionDialog }, work: true, conversation: true),
  InboxShape(
    name: "a question dialog without a card",
    events: { [event("UserPromptSubmit", 0, ["prompt": "go"]), event("PreToolUse", 1, ask())] }, work: true,
    conversation: true),
  InboxShape(
    name: "an exit at the trust dialog", events: { trustLaunch() + [trustClosed(5)] }, work: true,
    conversation: false),
  InboxShape(
    name: "a send card and an exit at the trust dialog",
    events: {
      [TriageConversations.earlySend] + trustLaunch() + [trustClosed(5)]
    },
    work: true, conversation: false),
  InboxShape(
    name: "a permission card on a done session", events: { permissionTurn() }, done: true, work: false,
    conversation: false),
]

@Suite struct TriageInboxReach {
  func session(_ kind: SessionKind, done: Bool) -> Session {
    var s = SwitchboardCoreTests.session(done: done)
    s.manager = kind == .manager ? true : nil
    s.chat = kind == .chat ? "g1" : nil
    return s
  }

  /// The session as sbd lists it, with the item that sbd builds.
  func summary(_ kind: SessionKind, _ f: SessionFacts, done: Bool) -> SessionSummary {
    let verdict = Attention.evaluate(session(kind, done: done), f, now: 1000)
    var s = SessionSummary(
      id: "s1", name: "s1", cwd: "/", repo: nil, branch: nil, claudeSessionId: "s1", state: verdict.state,
      reason: verdict.reason, since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false,
      lastReply: f.lastReply, waits: [], notes: [], cards: f.cards,
      openPrompt: f.openPermission != nil || f.openQuestion != nil)
    s.kind = kind
    s.triage = Triage.item(f, verdict, kind: kind)
    return s
  }

  @Test(arguments: inboxShapes, [SessionKind.work, .manager, .chat])
  func eachKindsItemsReachTheInboxAsExpected(_ shape: InboxShape, _ kind: SessionKind) throws {
    let s = summary(kind, facts(try shape.events()), done: shape.done)
    let expected = kind == .work ? shape.work : shape.conversation

    #expect((s.triage != nil) == expected)
    #expect(Triage.inInbox(s) == (kind == .work || expected))
    #expect(Triage.order([s]).map(\.id) == (expected ? ["s1"] : []))
  }

  @Test func summarizesOnlyWorkSessions() {
    #expect(Triage.summarizes(.work))
    #expect(!Triage.summarizes(.manager))
    #expect(!Triage.summarizes(.chat))
  }

  @Test func theOpenPromptVerdictIsTheVerdictOfASessionWithoutACard() {
    for events in [permissionDialog, [event("UserPromptSubmit", 0, ["prompt": "go"]), event("PreToolUse", 1, ask())]] {
      let f = facts(events)
      #expect(Attention.openPromptVerdict(f) == Attention.evaluate(session(.work, done: false), f, now: 1000))
    }
    #expect(Attention.openPromptVerdict(facts(reply)) == nil)
    #expect(Attention.openPromptVerdict(facts(trustLaunch() + [trustClosed(5)])) == nil)
  }
}
