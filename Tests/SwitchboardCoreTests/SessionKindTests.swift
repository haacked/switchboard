import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct SessionKindTests {
  func session(manager: Bool? = nil, chat: String? = nil) -> Session {
    var s = Session(id: "s1", name: "s", cwd: "/tmp", claudeSessionId: "c1", created: 0)
    s.manager = manager
    s.chat = chat
    return s
  }

  @Test(
    arguments: [
      (nil, nil, SessionKind.work), (true, nil, .manager), (nil, "g1", .chat), (false, nil, .work),
    ] as [(Bool?, String?, SessionKind)])
  func aSessionsKindFollowsItsManagerAndChatFields(_ manager: Bool?, _ chat: String?, _ kind: SessionKind) {
    #expect(session(manager: manager, chat: chat).kind == kind)
  }

  @Test func eachKindEncodesAsItsName() throws {
    let encoded = try JSON(encoding: [SessionKind.work, .manager, .chat])

    #expect(encoded == ["work", "manager", "chat"])
  }

  @Test(arguments: [(SessionKind.work, false), (.manager, true), (.chat, true)] as [(SessionKind, Bool)])
  func onlyAManagerConversationAndAGroupChatShowAsAChat(_ kind: SessionKind, _ showsAsChat: Bool) {
    #expect(kind.showsAsChat == showsAsChat)
  }
}
