import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelGroupMove {
  func work(_ id: String, group: String?, name: String? = nil, state: AttentionState = .working) -> SessionSummary {
    var s = needsItem(id, state: state)
    s.name = name ?? id
    s.group = group
    return s
  }

  /// Three groups, one of them empty. `charlie` names a group that sbd removed.
  /// `zulu` is the session that a refusal test moves after the refused drop.
  /// `echo` is a follow-up that waits to start, so only `followup-ls` lists it.
  func model() -> BoardModel {
    let model = appliedModel(
      [
        work("alpha", group: "grp-flags"),
        work("bravo", group: nil),
        work("charlie", group: "gone"),
        work("delta", group: "grp-billing", name: "Checkout"),
        work("zulu", group: nil),
        needsItem("manager", manager: true, state: .working),
        chatItem("chat-flags", group: "grp-flags", state: .working),
      ],
      followups: [work("echo", group: nil, state: .notStarted)])
    model.groups = [
      GroupSummary(SessionGroup(id: "grp-flags", name: "Flags", created: 0), sessions: ["alpha"]),
      GroupSummary(SessionGroup(id: "grp-billing", name: "Billing", created: 0), sessions: ["delta"]),
      GroupSummary(SessionGroup(id: "grp-empty", name: "Empty", created: 0), sessions: []),
    ]
    return model
  }

  /// The group of the session's card, which can come from `sessions` or `followups`.
  func group(_ model: BoardModel, _ id: String) -> String?? {
    model.board.first { $0.id == id }.map(\.group)
  }

  /// Runs `action` with a `send` that records requests, and returns the first
  /// request. It returns nil without waiting when `action` returns false,
  /// because then `action` claims that it sent nothing.
  func firstSent(_ model: BoardModel, _ action: () -> Bool) async -> (op: String, args: [String: JSON])? {
    let resumed = Counter()
    return await withCheckedContinuation { (first: CheckedContinuation<(op: String, args: [String: JSON])?, Never>) in
      model.send = { op, args in
        if resumed.increment() == 1 { first.resume(returning: (op, args)) }
        return .null
      }
      if !action(), resumed.increment() == 1 { first.resume(returning: nil) }
    }
  }

  /// Drops `session` on `target`. It returns the request and the card's
  /// group right after the call. A refresh after sbd answers can replace the
  /// sessions, so the group is read before the test awaits.
  func drop(_ model: BoardModel, _ session: String, on target: String?) async
    -> (request: (op: String, args: [String: JSON])?, shown: String??)
  {
    var shown: String??
    let request = await firstSent(model) {
      let moved = model.moveToGroup(session, target)
      shown = group(model, session)
      return moved
    }
    return (request, shown)
  }

  @Test(
    arguments: [
      ("bravo", "grp-flags"),
      // From one group to another.
      ("delta", "grp-flags"),
      // A group with no sessions.
      ("alpha", "grp-empty"),
      // A session whose group sbd removed sits in the Ungrouped lane.
      ("charlie", "grp-flags"),
      // sbd keeps a follow-up that waits to start as a session, so `group-move` finds it.
      ("echo", "grp-flags"),
    ])
  func dropOnAnotherGroupSendsTheMoveAndMovesTheCard(session: String, target: String) async {
    let (request, shown) = await drop(model(), session, on: target)

    #expect(request?.op == "group-move")
    #expect(request?.args == ["sessions": [.string(session)], "group": .string(target)])
    #expect(shown == .some(target))
  }

  @Test func dropOnUngroupedSendsUngroupedAndMovesTheCard() async {
    let (request, shown) = await drop(model(), "alpha", on: nil)

    #expect(request?.op == "group-move")
    #expect(request?.args == ["sessions": ["alpha"], "ungrouped": true])
    #expect(shown == .some(nil))
  }

  /// The drop is refused: it returns false, the card stays, and the first
  /// request sbd gets is the `zulu` move that follows it. Requests go out one
  /// at a time in order, so a request from the refused drop would come first.
  @Test(
    arguments: [
      // The session's own lane.
      ("alpha", "grp-flags"),
      ("bravo", nil),
      // A group that is not in `groups` counts as Ungrouped.
      ("charlie", nil),
      // Not a work session on the Board. The drop text can come from another
      // app, and sbd finds a session by id, unique id prefix, or name.
      ("manager", "grp-flags"),
      ("manager", nil),
      ("chat-flags", "grp-billing"),
      ("chat-flags", nil),
      ("https://example.com", "grp-flags"),
      ("", "grp-flags"),
      ("Checkout", "grp-flags"),
      ("delt", "grp-flags"),
      ("delt", nil),
      // A group that sbd didn't list. sbd finds a group by id, unique id prefix, or name.
      ("bravo", "gone"),
      ("bravo", "Flags"),
      ("bravo", "grp-f"),
      ("bravo", ""),
    ] as [(String, String?)])
  func refusedDropSendsNothingAndLeavesTheCard(session: String, target: String?) async {
    let model = model()
    let before = group(model, session)
    var moved = true
    var after: String??

    let first = await firstSent(model) {
      moved = model.moveToGroup(session, target)
      after = group(model, session)
      return model.moveToGroup("zulu", "grp-flags")
    }

    #expect(!moved)
    #expect(after == before)
    #expect(first?.args == ["sessions": ["zulu"], "group": "grp-flags"])
  }
}
