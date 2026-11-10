import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The group lane's account control: the request that sets or clears a
/// group's account, and the sessions that a change moves at their next launch.
@MainActor
@Suite struct BoardModelGroupAccount {
  nonisolated static let work = "/Users/me/.claude-work"
  nonisolated static let personal = "/Users/me/.claude-personal"

  /// A work session in `group` on `account`.
  func session(_ id: String, group: String? = "g1", account: String? = BoardModelGroupAccount.personal)
    -> SessionSummary
  {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: id, state: .waiting, reason: "",
      since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.group = group
    s.account = account
    return s
  }

  func model(account: String? = nil, sessions: [SessionSummary] = [], followups: [SessionSummary] = []) -> BoardModel {
    let model = appliedModel(sessions, followups: followups)
    let members = (sessions + followups).filter { $0.group == "g1" || $0.chat == "g1" }.map(\.id)
    model.groups = [
      GroupSummary(SessionGroup(id: "g1", name: "Flags", created: 0, account: account), sessions: members),
      GroupSummary(
        SessionGroup(id: "g2", name: "Docs", created: 0), sessions: sessions.filter { $0.group == "g2" }.map(\.id)),
    ]
    return model
  }

  /// The request that `setGroupAccount` sent.
  func sent(_ model: BoardModel, _ folder: String?) async -> (String, [String: JSON]) {
    await withCheckedContinuation { (sent: CheckedContinuation<(String, [String: JSON]), Never>) in
      model.send = { op, args in
        sent.resume(returning: (op, args))
        return .null
      }
      model.setGroupAccount("g1", folder)
    }
  }

  // MARK: The request

  @Test func settingTheAccountSendsTheGroupAndTheFolder() async {
    let model = model()

    let (op, args) = await sent(model, Self.work)

    #expect(op == "group-account")
    #expect(args == ["group": "g1", "account": .string(Self.work)])
  }

  @Test func clearingTheAccountSendsClear() async {
    let model = model(account: Self.work)

    let (op, args) = await sent(model, nil)

    #expect(op == "group-account")
    #expect(args == ["group": "g1", "clear": true])
  }

  // MARK: The sessions that move

  @Test func aMemberOnAnotherAccountMoves() {
    let model = model(sessions: [session("a", account: Self.personal)])

    let moves = model.groupAccountMoves(group: "g1", folder: Self.work)

    #expect(moves.map(\.id) == ["a"])
  }

  @Test func aMemberAlreadyOnTheFolderStays() {
    let model = model(sessions: [session("a", account: Self.work), session("b", account: Self.personal)])

    let moves = model.groupAccountMoves(group: "g1", folder: Self.work)

    #expect(moves.map(\.id) == ["b"])
  }

  @Test func sessionsOutsideTheGroupStay() {
    let model = model(sessions: [
      session("a"), session("other", group: "g2"), session("loose", group: nil),
    ])

    let moves = model.groupAccountMoves(group: "g1", folder: Self.work)

    #expect(moves.map(\.id) == ["a"])
  }

  /// The chat follows the group's account too, but it is not a work session,
  /// so the confirmation does not list it.
  @Test func theGroupsChatIsNotListed() {
    var chat = session("chat")
    chat.kind = .chat
    chat.chat = "g1"
    let model = model(sessions: [session("a"), chat])

    let moves = model.groupAccountMoves(group: "g1", folder: Self.work)

    #expect(moves.map(\.id) == ["a"])
  }

  /// A follow-up that has not started has no folder and no conversation, and
  /// it takes the group's account when it starts.
  @Test func anUnstartedFollowupIsNotListed() {
    var followup = session("f")
    followup.cwd = ""
    followup.state = .notStarted
    let model = model(sessions: [session("a"), followup], followups: [followup])

    let moves = model.groupAccountMoves(group: "g1", folder: Self.work)

    #expect(moves.map(\.id) == ["a"])
  }

  @Test func noMembersOnAnotherAccountListsNone() {
    let model = model(sessions: [session("a", account: Self.work)])

    let moves = model.groupAccountMoves(group: "g1", folder: Self.work)

    #expect(moves.isEmpty)
  }
}
