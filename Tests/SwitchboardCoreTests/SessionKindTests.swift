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
    arguments: [
      (true, true, nil, SessionKind.operator), (true, nil, nil, .operator), (true, true, "g1", .operator),
      (false, true, nil, .manager), (nil, true, nil, .manager), (false, nil, nil, .work),
    ] as [(Bool?, Bool?, String?, SessionKind)])
  func isOperatorWinsOverTheManagerAndChatFields(
    _ isOperator: Bool?, _ manager: Bool?, _ chat: String?, _ kind: SessionKind
  ) {
    var s = session(manager: manager, chat: chat)
    s.isOperator = isOperator

    #expect(s.kind == kind)
  }

  // MARK: Which sessions a multi-select delete may remove

  /// Sets `kind` with `manager` and `chat`, as sbd does, because `kind` defaults to `.work`.
  func summary(
    state: AttentionState = .waiting, manager: Bool? = nil, chat: String? = nil, followup: Followup? = nil
  ) -> SessionSummary {
    var s = SessionSummary(
      id: "s1", name: "s", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "c1", state: state, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.manager = manager
    s.chat = chat
    s.kind = SessionKind(manager: manager, chat: chat)
    s.followup = followup
    return s
  }

  static func startedFollowup() -> Followup {
    var f = Followup(prompt: "p")
    f.started = 1
    return f
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .notStarted })
  func aWorkSessionIsRemovableWorkInEveryState(_ state: AttentionState) {
    #expect(summary(state: state).isRemovableWork)
  }

  @Test func theManagerIsNotRemovableWork() {
    #expect(!summary(manager: true).isRemovableWork)
  }

  @Test func aChatIsNotRemovableWork() {
    #expect(!summary(chat: "g1").isRemovableWork)
  }

  @Test func theOperatorIsNotRemovableWork() {
    var s = summary(manager: true)
    s.kind = .operator
    #expect(!s.isRemovableWork)
  }

  @Test func aFollowupThatHasNotStartedIsNotRemovableWorkInAnyState() {
    for state in AttentionState.allCases {
      #expect(!summary(state: state, followup: Followup(prompt: "p")).isRemovableWork, "\(state)")
    }
  }

  @Test func aFollowupThatStartedIsRemovableWork() {
    #expect(summary(followup: Self.startedFollowup()).isRemovableWork)
  }

  /// Delete All's rule is the multi-select rule limited to Done.
  @Test(
    arguments: AttentionState.allCases,
    [(nil, nil, nil), (true, nil, nil), (nil, "g1", nil), (nil, nil, false), (nil, nil, true)]
      as [(Bool?, String?, Bool?)])
  func isRemovableDoneIsRemovableWorkInDone(_ state: AttentionState, _ fields: (Bool?, String?, Bool?)) {
    let (manager, chat, started) = fields
    let followup = started.map { $0 ? Self.startedFollowup() : Followup(prompt: "p") }
    let s = summary(state: state, manager: manager, chat: chat, followup: followup)

    #expect(s.isRemovableDone == (s.isRemovableWork && state == .done))
  }

  @Test func eachKindEncodesAsItsName() throws {
    let encoded = try JSON(encoding: [SessionKind.work, .manager, .chat, .operator])

    #expect(encoded == ["work", "manager", "chat", "operator"])
  }

  @Test func theOperatorKindDecodesFromItsName() throws {
    #expect(try JSONCoding.decode([SessionKind].self, from: #"["operator"]"#) == [.operator])
  }

  @Test(
    arguments: [(SessionKind.work, false), (.manager, true), (.chat, true), (.operator, true)] as [(SessionKind, Bool)])
  func onlyAWorkSessionIsNotAConversation(_ kind: SessionKind, _ isConversation: Bool) {
    #expect(kind.isConversation == isConversation)
  }

  @Test(
    arguments: [(SessionKind.work, false), (.manager, true), (.chat, true), (.operator, false)] as [(SessionKind, Bool)]
  )
  func onlyAManagerConversationOrAGroupChatIsAUserConversation(_ kind: SessionKind, _ isUserConversation: Bool) {
    #expect(kind.isUserConversation == isUserConversation)
  }

  @Test func theOperatorsLabelIsTheOperator() {
    #expect(SessionKind.operator.label == "the operator")
  }

  @Test func theOperatorIsNotSummarized() {
    #expect(!Triage.summarizes(.operator))
  }
}
