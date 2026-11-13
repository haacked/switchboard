import Foundation
import Testing

@testable import SwitchboardCore

/// The Manager's and a group chat's Inbox items: a prompt that blocks the
/// conversation until the user answers it, and nothing else.
@Suite struct TriageConversations {
  static let conversations: [SessionKind] = [.manager, .chat]

  func conversation(_ kind: SessionKind) -> Session {
    var s = session()
    switch kind {
    case .work: break
    case .manager: s.manager = true
    case .chat: s.chat = "g1"
    }
    return s
  }

  func verdict(_ f: SessionFacts, _ kind: SessionKind) -> Verdict {
    Attention.evaluate(conversation(kind), f, now: 1000)
  }

  func conversationItem(_ f: SessionFacts, _ kind: SessionKind) -> TriageItem? {
    Triage.item(f, verdict(f, kind), kind: kind)
  }

  /// A `send_pending` event that comes before the turn's own events, as card 1.
  static let earlySend = Event(id: 1, session: "s1", t: 0, kind: "send_pending", data: .object(sendPendingData()))

  /// A card of each kind, as the events open it.
  static func card(_ kind: Card.Kind) -> Card {
    switch kind {
    case .permission: facts(permissionTurn()).cards[0]
    case .question: facts(questionTurn()).cards[0]
    case .send: facts([sendPending()]).cards[0]
    case .trust: trustCard()
    }
  }

  // MARK: The item

  /// The card that blocks the turn, and where a send card sits next to it.
  enum CardOrder: CaseIterable, Sendable {
    case sendThenPermission, permissionThenSend, sendThenQuestion, sendThenTrust

    var events: [Event] {
      switch self {
      case .sendThenPermission: [TriageConversations.earlySend] + permissionTurn()
      case .permissionThenSend: permissionTurn() + [sendPending()]
      case .sendThenQuestion: [TriageConversations.earlySend] + questionTurn()
      case .sendThenTrust: [TriageConversations.earlySend] + trustLaunch()
      }
    }

    var blockingRef: String { self == .sendThenTrust ? "card:5" : "card:3" }
  }

  @Test(arguments: conversations, CardOrder.allCases)
  func aConversationsItemIsItsFirstBlockingCard(_ kind: SessionKind, _ order: CardOrder) throws {
    let f = facts(order.events)
    try #require(f.cards.count == 2)

    let item = try #require(conversationItem(f, kind))

    #expect(item.source == .card)
    #expect(item.ref == order.blockingRef)
  }

  @Test(arguments: conversations)
  func aConversationsPermissionCardBehindASendCardGivesItsAllowAndDeny(_ kind: SessionKind) throws {
    let f = facts(CardOrder.sendThenPermission.events)

    let item = try #require(conversationItem(f, kind))

    #expect(item.title == "Approve `touch x`")
    #expect(item.options.map(\.action).prefix(2) == [.allow, .deny])
  }

  /// A prompt that shows with no card behind it, each with an open send card.
  enum OpenPrompt: CaseIterable, Sendable {
    /// A Notification reported the dialog, and no PermissionRequest came.
    case notification
    /// Claude Code closed the hook of a card whose dialog sbd can't find, so
    /// sbd removed the card and the dialog stays open.
    case closedHook
    /// An AskUserQuestion call started, and no PermissionRequest came.
    case question

    var events: [Event] {
      let turn: [Event] =
        switch self {
        case .notification:
          [
            event("UserPromptSubmit", 0, ["prompt": "go"]),
            event("Notification", 1, ["notification_type": "permission_prompt", "message": "Allow Bash?"]),
          ]
        case .closedHook: fetchTurn() + [event("card_closed", 4, ["card": 3])]
        case .question: [event("UserPromptSubmit", 0, ["prompt": "go"]), event("PreToolUse", 1, ask())]
        }
      return [TriageConversations.earlySend] + turn
    }

    var titlePrefix: String { self == .question ? "Answer: " : "Approve " }
  }

  @Test(arguments: conversations, OpenPrompt.allCases)
  func aConversationsOpenPromptWithoutACardGivesThePromptsItem(_ kind: SessionKind, _ prompt: OpenPrompt) throws {
    let f = facts(prompt.events)
    try #require(f.cards.map(\.kind) == [.send])
    try #require(f.openPermission != nil || f.openQuestion != nil)

    let item = try #require(conversationItem(f, kind))

    #expect(item.source == .rule)
    #expect(item.title.hasPrefix(prompt.titlePrefix))
    #expect(item.ref == "rule:\(item.title)")
  }

  @Test(arguments: conversations)
  func aConversationsPromptFromANotificationIsTitledByThePrompt(_ kind: SessionKind) throws {
    let f = facts(OpenPrompt.notification.events)

    let item = try #require(conversationItem(f, kind))

    #expect(item.title == "Approve Allow Bash?")
  }

  /// The prompt that the conversation waits on, after a decision list opened.
  enum PromptAfterDecisions: CaseIterable, Sendable {
    case card, openPrompt

    var events: [Event] {
      let opened = decisionsOpened(1, t: 0, ref: "summary:1")
      switch self {
      case .card: return [opened] + permissionTurn()
      case .openPrompt:
        return [
          opened, event("UserPromptSubmit", 1, ["prompt": "go"]),
          event("Notification", 2, ["notification_type": "permission_prompt", "message": "Allow Bash?"]),
        ]
      }
    }
  }

  @Test(arguments: conversations, PromptAfterDecisions.allCases)
  func aConversationsItemHasNoDecisions(_ kind: SessionKind, _ prompt: PromptAfterDecisions) throws {
    let f = facts(prompt.events)
    try #require(f.decisionList != nil)
    try #require(Triage.itemAndDecisions(f, verdict(f, .work), kind: .work).decisions != nil)

    let built = Triage.itemAndDecisions(f, verdict(f, kind), kind: kind)

    let item = try #require(built.item)
    #expect(item.decisions.isEmpty)
    #expect(built.decisions == nil)
    #expect(!built.decisionsSent)
  }

  // MARK: The guard

  @Test(
    arguments: [[], [.permission], [.question], [.trust], [.send], [.send, .permission], [.send, .send]]
      as [[Card.Kind]],
    [false, true])
  func blockingPromptReadsCardKindsAndTheOpenPrompt(_ kinds: [Card.Kind], _ openPrompt: Bool) {
    let blocks = Triage.hasBlockingPrompt(cards: kinds.map(Self.card), openPrompt: openPrompt)

    #expect(blocks == (openPrompt || kinds.contains { $0 != .send }))
  }

  /// A conversation's summary as sbd sends it: its cards, whether a dialog
  /// shows, and the item, which the app does not trust on its own.
  struct SummaryShape: Sendable, CustomTestStringConvertible {
    var cards: [Card.Kind]
    var openPrompt: Bool
    var item: TriageSource?
    var included: Bool

    var testDescription: String {
      "cards \(cards.map(\.rawValue)), openPrompt \(openPrompt), item \(item?.rawValue ?? "none")"
    }
  }

  static let summaryShapes = [
    SummaryShape(cards: [], openPrompt: false, item: .summary, included: false),
    SummaryShape(cards: [], openPrompt: false, item: .session, included: false),
    SummaryShape(cards: [], openPrompt: false, item: .rule, included: false),
    SummaryShape(cards: [], openPrompt: false, item: .fallback, included: false),
    SummaryShape(cards: [], openPrompt: false, item: .card, included: false),
    SummaryShape(cards: [.send], openPrompt: false, item: .card, included: false),
    SummaryShape(cards: [.permission], openPrompt: true, item: nil, included: false),
    SummaryShape(cards: [.trust], openPrompt: false, item: nil, included: false),
    SummaryShape(cards: [.permission], openPrompt: true, item: .card, included: true),
    SummaryShape(cards: [.question], openPrompt: true, item: .card, included: true),
    SummaryShape(cards: [.trust], openPrompt: false, item: .card, included: true),
    SummaryShape(cards: [.send, .permission], openPrompt: true, item: .card, included: true),
    SummaryShape(cards: [.send], openPrompt: true, item: .rule, included: true),
    SummaryShape(cards: [], openPrompt: true, item: .rule, included: true),
  ]

  func summary(_ kind: SessionKind, _ shape: SummaryShape) -> SessionSummary {
    var s = SessionSummary(
      id: "s1", name: "s1", cwd: "/", repo: nil, branch: nil, claudeSessionId: "s1", state: .needsYou, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [],
      cards: shape.cards.map(Self.card), openPrompt: shape.openPrompt)
    s.triage = shape.item.map { TriageItem(title: "t", kind: .approval, summary: "", source: $0) }
    s.kind = kind
    s.manager = kind == .manager ? true : nil
    s.chat = kind == .chat ? "g1" : nil
    return s
  }

  @Test(arguments: conversations, summaryShapes)
  func aConversationIsInTheInboxOnlyWithAnItemAndABlockingPrompt(_ kind: SessionKind, _ shape: SummaryShape) {
    let s = summary(kind, shape)

    #expect(Triage.inInbox(s) == shape.included)
    #expect(Triage.needsYou(s) == shape.included)
  }

  // MARK: The name

  @Test(
    arguments: [
      (SessionKind.chat, "Flags chat", "Flags", "Flags chat"),
      (.chat, "Flags chat", "Billing", "Billing chat"),
      (.chat, "my notes", "Flags", "Flags chat"),
      (.chat, "my notes", nil, "my notes"),
      (.manager, "Manager", nil, "Manager"),
      (.manager, "deploy watch", nil, "Manager: deploy watch"),
      (.manager, "deploy watch", "Flags", "Manager: deploy watch"),
      (.work, "fix-bug", "Flags", "fix-bug"),
      (.work, "fix-bug", nil, "fix-bug"),
    ] as [(SessionKind, String, String?, String)])
  func inboxNameLabelsAChatByItsGroupAndTheManagerByName(
    _ kind: SessionKind, _ name: String, _ groupName: String?, _ expected: String
  ) {
    var s = summary(kind, SummaryShape(cards: [], openPrompt: false, item: nil, included: false))
    s.name = name

    #expect(Triage.inboxName(s, groupName: groupName) == expected)
  }
}
