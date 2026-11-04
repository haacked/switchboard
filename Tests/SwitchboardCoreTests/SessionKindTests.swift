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

  @Test(
    arguments: [(nil, nil, SessionKind.work), (true, nil, .manager), (nil, "g1", .chat)]
      as [(Bool?, String?, SessionKind)])
  func aSummaryFromAnOlderSbdTakesItsKindFromItsManagerAndChatFields(
    _ manager: Bool?, _ chat: String?, _ kind: SessionKind
  ) {
    var s = SessionSummary(
      id: "s1", name: "s", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "c1", state: .working, reason: "",
      since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.manager = manager
    s.chat = chat
    #expect(s.kind == nil)
    #expect(s.sessionKind == kind)
  }

  @Test func eachKindEncodesAsItsName() throws {
    let encoded = try JSON(encoding: [SessionKind.work, .manager, .chat])

    #expect(encoded == ["work", "manager", "chat"])
  }
}
