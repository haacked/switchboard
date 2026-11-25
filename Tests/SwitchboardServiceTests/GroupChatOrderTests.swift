import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A chat of the group `g`, with the activity and creation time that order a group's chats.
private func chat(_ id: String, activity: Int64, created: Int64 = 0, done: Bool = false, group: String = "g")
  -> Service.Entry
{
  var s = makeSession(id, name: "g chat")
  s.chat = group
  s.created = created
  s.done = done
  var e = Service.Entry(session: s)
  e.facts.lastActivity = activity
  return e
}

/// The order of a group's chats, which picks the chat that a request for the group reaches.
@Suite struct GroupChatOrderTests {
  private func chats(_ entries: [Service.Entry]) throws -> (all: [String], recent: String?) {
    var result: (all: [String], recent: String?) = ([], nil)
    try withService { service, _ in
      result = service.queue.sync {
        for e in entries { service.entries[e.session.id] = e }
        return (service.chats(of: "g"), service.mostRecentChat(of: "g"))
      }
    }
    return result
  }

  @Test func aGroupWithNoChatHasNone() throws {
    let found = try chats([chat("other", activity: 5, group: "h")])
    #expect(found.all.isEmpty)
    #expect(found.recent == nil)
  }

  @Test func aGroupsOnlyChatIsItsMostRecentEvenWhenDone() throws {
    #expect(try chats([chat("c1", activity: 5, done: true)]).recent == "c1")
  }

  @Test func chatsListNewestActivityFirstThenNewestCreated() throws {
    let found = try chats([
      chat("old", activity: 5), chat("new", activity: 9), chat("later", activity: 5, created: 3),
      chat("other", activity: 99, group: "h"),
    ])
    #expect(found.all == ["new", "later", "old"])
    #expect(found.recent == "new")
  }

  @Test func aDoneChatListsAfterEveryChatThatIsNotDone() throws {
    let found = try chats([chat("done", activity: 9, done: true), chat("live", activity: 1)])
    #expect(found.all == ["live", "done"])
    #expect(found.recent == "live")
  }

  @Test func equalActivityAndCreationListByID() throws {
    #expect(
      try chats([chat("b", activity: 5), chat("a", activity: 5), chat("c", activity: 5)]).all == ["a", "b", "c"])
  }
}
