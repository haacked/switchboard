import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The chat of group `group`, whose triage item is a decision.
func chatItem(_ id: String, group: String, state: AttentionState = .needsYou) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.chat = group
  s.kind = .chat
  return s
}

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

  @Test func theInboxAndTheBadgeLeaveOutAChat() {
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

  @Test func loadChatLogAsksForTheSessionsLog() async {
    let sent = await firstRequest { $0.loadChatLog("c") }

    #expect(sent.op == "chat-log")
    #expect(sent.args == ["session": "c"])
  }

  @Test func loadBlockSourcesAsksForClaudesMessagesOnly() async {
    let sent = await firstRequest { $0.loadBlockSources("w") { _ in } }

    #expect(sent.op == "chat-log")
    #expect(
      sent.args == ["session": "w", "role": "assistant", "limit": .number(Double(BoardModel.blockSourceMessageCount))])
  }

  @Test func loadChatLogAsksForAManagerConversationsLog() async {
    let sent = await firstRequest { $0.loadChatLog("m") }

    #expect(sent.op == "chat-log")
    #expect(sent.args == ["session": "m"])
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
}
