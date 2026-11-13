import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelChats {
  @Test func theSidebarLeavesOutAChatWhateverItsState() {
    for state in [AttentionState.working, .needsYou, .done] {
      let model = appliedModel([chatItem("c", group: "g1", state: state), needsItem("a", state: state)])

      let ids = model.sidebarGroups.flatMap { $0.rows.map(\.id) }

      #expect(ids == ["a"])
    }
  }

  @Test func theBoardsWorkSessionsLeaveOutChatsAndTheManager() {
    let model = appliedModel([
      chatItem("c", group: "g1"), needsItem("m", manager: true), needsItem("a"),
    ])

    #expect(model.workBoard.map(\.id) == ["a"])
  }

  @Test func theInboxAndTheBadgeLeaveOutAChatWithOnlyAReply() {
    let model = appliedModel([chatItem("c", group: "g1"), needsItem("a")])

    #expect(model.triage.map(\.id) == ["a"])
    #expect(model.needsUser.map(\.id) == ["a"])
  }

  @Test func chatOfAGroupFindsThatGroupsChatOnly() {
    let model = appliedModel([chatItem("c1", group: "g1"), chatItem("c2", group: "g2"), needsItem("a")])

    #expect(model.chat(of: "g1")?.id == "c1")
    #expect(model.chat(of: "g2")?.id == "c2")
    #expect(model.chat(of: "g3") == nil)
  }

  @Test func openChatStartsAGroupsFirstChatWithTheGroup() async {
    let sent = await firstRequest { $0.openChat("g1") }

    #expect(sent.op == "chat")
    #expect(sent.args == ["group": "g1"])
  }

  @Test func openChatSelectsAChatThatExistsWithoutAskingSbd() {
    let model = appliedModel([chatItem("c", group: "g1"), needsItem("a")])
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }

    model.openChat("g1")

    #expect(model.selection == "c")
    Thread.sleep(forTimeInterval: 0.2)
    #expect(sent.value == 0)
  }

  // MARK: A chat's blocking prompts

  @Test(arguments: [Card.Kind.permission, .question, .trust])
  func aChatsBlockingCardReachesTheInboxBadgeAndMenuBar(_ kind: Card.Kind) throws {
    let model = appliedModel([try chatCard("c", group: "g1", kind: kind), needsItem("a")])

    #expect(model.triage.map(\.id) == ["c", "a"])
    #expect(Set(model.needsUser.map(\.id)) == ["c", "a"])
  }

  @Test func aChatsSendCardStaysOut() throws {
    let model = appliedModel([try chatCard("c", group: "g1", kind: .send), needsItem("a")])

    #expect(model.triage.map(\.id) == ["a"])
    #expect(model.needsUser.map(\.id) == ["a"])
  }

  @Test func aChatCardNotifiesWhenTheChatMovesFromAReplyToTheCard() throws {
    let model = appliedModel([chatItem("c", group: "g1"), needsItem("a")])

    let next = [try chatCard("c", group: "g1"), needsItem("a")]

    #expect(model.sessionsToNotify(next).map(\.id) == ["c"])
  }

  @Test func aChatCardDoesNotNotifyTwice() throws {
    let model = appliedModel([chatItem("c", group: "g1")])
    let first = [try chatCard("c", group: "g1", card: 1)]
    try #require(model.sessionsToNotify(first).map(\.id) == ["c"])
    model.apply(.success(first), followups: nil)

    let second = [try chatCard("c", group: "g1", card: 2)]

    #expect(model.sessionsToNotify(first).isEmpty)
    #expect(model.sessionsToNotify(second).isEmpty)
  }

  @Test func aChatMovingFromACardToAReplyDoesNotNotify() throws {
    let model = appliedModel([try chatCard("c", group: "g1")])

    let next = [chatItem("c", group: "g1")]

    #expect(model.sessionsToNotify(next).isEmpty)
  }

  @Test func nextNeedingYouVisitsAChatCard() throws {
    let model = appliedModel([try chatCard("c", group: "g1"), needsItem("a")])
    model.show(.inbox)
    var inbox: Set<String?> = []
    for _ in 0..<2 {
      model.selectNextNeedingYou()
      inbox.insert(model.currentInboxItem)
    }
    model.show(.board)
    var board: Set<String?> = []
    for _ in 0..<2 {
      model.selectNextNeedingYou()
      board.insert(model.selection)
    }

    #expect(inbox == ["c", "a"])
    #expect(board == ["c", "a"])
  }

  @Test func revealingAChatItemSelectsTheChat() throws {
    let model = appliedModel([try chatCard("c", group: "g1"), needsItem("a")])
    let item = try #require(model.triage.first)

    model.reveal(item.id)

    #expect(model.selection == "c")
    #expect(model.selected?.chat == "g1")
  }

  @Test func aChatsInboxNameIsItsGroupsCurrentName() throws {
    let model = appliedModel([try chatCard("c", group: "g1")])
    let chat = try #require(model.triage.first)
    model.groups = [GroupSummary(SessionGroup(id: "g1", name: "Billing", description: nil, created: 0), sessions: [])]
    #expect(model.inboxName(chat) == "Billing chat")

    model.groups = [GroupSummary(SessionGroup(id: "g2", name: "Flags", description: nil, created: 0), sessions: [])]
    #expect(model.inboxName(chat) == chat.name)
  }
}
