import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelGroups {
  func group(_ id: String, _ name: String, sessions: [String] = []) -> GroupSummary {
    GroupSummary(SessionGroup(id: id, name: name, created: 0), sessions: sessions)
  }

  func model(_ groups: GroupSummary...) -> BoardModel {
    let model = offlineModel()
    model.groups = groups
    return model
  }

  /// The first request that sbd gets after `action` runs. A `stop` follows
  /// the action, and the model sends requests in order on one queue. A first
  /// request of `stop` therefore means that the action sent nothing. The
  /// action reads the model's state before the test awaits, because a
  /// refresh after sbd answers can replace the groups.
  func firstSent(_ model: BoardModel, _ action: () -> Void) async -> (op: String, args: [String: JSON]) {
    let sent = Counter()
    return await withCheckedContinuation { first in
      model.send = { op, args in
        if sent.increment() == 1 { first.resume(returning: (op, args)) }
        return .null
      }
      action()
      model.stop("end")
    }
  }

  // MARK: startNewGroup

  @Test func startNewGroupShowsTheBoardAndOpensTheNameField() {
    let model = model()
    model.mainView = .inbox
    model.selection = "s1"

    model.startNewGroup()

    #expect(model.mainView == .board)
    #expect(model.selection == nil)
    #expect(model.namingGroup)
  }

  // MARK: createGroup

  /// sbd judges the name, so the model sends it as typed.
  @Test func createGroupSendsTheNameAndClosesTheFieldWhenSbdAnswers() async {
    let model = model()
    model.namingGroup = true
    var naming = false

    let (op, args) = await firstSent(model) {
      model.createGroup("  Flags ")
      naming = model.namingGroup
    }
    await settle { !model.namingGroup }

    #expect(op == "group-add")
    #expect(args == ["name": "  Flags "])
    #expect(naming)
    #expect(!model.namingGroup)
  }

  /// A name that sbd refuses, such as one another group has, keeps the field open and shows sbd's reason.
  @Test func createGroupKeepsTheFieldOpenWhenSbdRefusesTheName() async {
    let model = model(group("g1", "Flags"))
    model.namingGroup = true
    model.send = { _, _ in throw APIError("a group named Flags exists") }

    model.createGroup("Flags")
    await settle { model.actionError != nil }

    #expect(model.namingGroup)
    #expect(model.actionError?.contains("a group named Flags exists") == true)
  }

  // MARK: requestDeleteGroup

  @Test func requestDeleteGroupDeletesAnEmptyGroupAtOnce() async {
    let flags = group("g1", "Flags")
    let model = model(flags)
    var confirming: GroupSummary?

    let (op, args) = await firstSent(model) {
      model.requestDeleteGroup(flags)
      confirming = model.confirmingGroupDelete
    }

    #expect(op == "group-rm")
    #expect(args == ["group": "g1"])
    #expect(confirming == nil)
  }

  /// How the Board lists a group's member.
  enum Member: CaseIterable { case live, done, unlisted }

  func summary(_ id: String, _ member: Member) -> SessionSummary? {
    switch member {
    case .live:
      return needsItem(id)
    case .done:
      var s = needsItem(id, state: .done)
      s.triage = nil
      s.live = false
      s.markedDone = true
      return s
    case .unlisted:
      return nil
    }
  }

  /// A group whose members are all Done still has members, so it asks.
  @Test(arguments: Member.allCases) func requestDeleteGroupAsksBeforeDeletingAGroupWithMembers(_ member: Member) async {
    let flags = group("g1", "Flags", sessions: ["s1"])
    let model = appliedModel([summary("s1", member)].compactMap { $0 })
    model.groups = [flags]
    var confirming: GroupSummary?

    let (op, _) = await firstSent(model) {
      model.requestDeleteGroup(flags)
      confirming = model.confirmingGroupDelete
    }

    #expect(confirming == flags)
    #expect(op == "stop")
  }

  // MARK: deleteGroup

  @Test func deleteGroupSendsGroupRmAndRemovesTheGroupBeforeSbdAnswers() async {
    let model = model(group("g1", "Flags", sessions: ["s1"]), group("g2", "Billing"))
    var shown: [String] = []

    let (op, args) = await firstSent(model) {
      model.deleteGroup("g1")
      shown = model.groups.map(\.id)
    }

    #expect(op == "group-rm")
    #expect(args == ["group": "g1"])
    #expect(shown == ["g2"])
  }

  @Test func deleteGroupClosesTheConfirmation() {
    let flags = group("g1", "Flags", sessions: ["s1"])
    let model = model(flags)
    model.send = { _, _ in .null }
    model.requestDeleteGroup(flags)
    #expect(model.confirmingGroupDelete == flags)

    model.deleteGroup("g1")

    #expect(model.confirmingGroupDelete == nil)
  }

  // MARK: GroupDeletion

  func withPlan(_ group: GroupSummary) -> GroupSummary {
    var group = group
    let plan = PlanDocument(
      id: "p1", source: PlanSource(kind: .file, path: "/tmp/plan.md"), group: group.id, attached: 0)
    group.plans = [PlanSummary(plan)]
    return group
  }

  /// `group-rm` detaches a group's plans, so a group with a plan and no sessions still asks.
  @Test func requestDeleteGroupAsksBeforeDeletingAnEmptyGroupWithAPlan() async {
    let flags = withPlan(group("g1", "Flags"))
    let model = model(flags)

    let (op, _) = await firstSent(model) { model.requestDeleteGroup(flags) }

    #expect(op == "stop")
    #expect(model.confirmingGroupDelete == flags)
  }

  @Test func deletionMessageSaysWhatHappensToSessionsChatAndPlans() {
    #expect(
      GroupDeletion.message(group("g1", "Flags", sessions: ["s1"]), hasChat: false)
        == "Its session moves to Ungrouped and keeps running.")
    #expect(
      GroupDeletion.message(withPlan(group("g1", "Flags", sessions: ["s1", "s2"])), hasChat: true)
        == "Its 2 sessions move to Ungrouped and keep running. Its chat is marked done. "
        + "Switchboard detaches its plans. The plan documents stay.")
  }
}
