import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// An Operator-held wait that is overdue shows as an item on the session that it is about (#410, Decision 38). The
/// waits stay on the Operator, so for an item with a `held:` ref the card's `WaitPanel` reads and clears the waits
/// on the Operator.
@MainActor
@Suite struct DecisionCardWaitsHolder {
  static let hour: Int64 = 3_600_000
  static let now: Int64 = 100 * hour

  /// The Operator, holding a merge wait on `k1` that is past its recheck time.
  static func theOperator() -> SessionSummary {
    var s = needsItem("op", manager: true, state: .waiting)
    s.kind = .operator
    s.name = Manager.operatorName
    var wait = Wait(
      id: "w1", kind: .session, session: Wait.SessionTarget(id: "k1", name: "k1"), state: .readyToMerge, by: .claude,
      created: now - 3 * hour, recheck: now - hour)
    wait.action = WaitAction(kind: .merge)
    s.waits = [wait]
    return s
  }

  /// An item that names the overdue wait `w1`: the held-wait item that sbd routes to `k1`, or with a `rule:` ref
  /// the wait rule's item on the session that holds the wait.
  static func overdueItem(ref: String = "held:w1") -> TriageItem {
    TriageItem(
      title: "sbd still waits to merge", kind: .question, summary: "", source: ref.hasPrefix("held:") ? .report : .rule,
      ref: ref, details: TriageDetails(overdueWaits: ["w1"]))
  }

  /// A model under an org filter and a group filter, which list `k1` and the Operator.
  static func filteredModel() -> BoardModel {
    var owner = groupedSession("k1", group: "g1")
    owner.triage = overdueItem()
    let model = orgFilterModel(posthogOnly, groupFilter: GroupFilter(keys: ["g1"]))
    model.apply(.success([owner, theOperator()]), followups: nil)
    return model
  }

  @Test func aHeldItemsPanelReadsTheOperatorsSession() throws {
    let model = Self.filteredModel()
    let owner = try #require(model.allSessions.first { $0.id == "k1" })

    let resolved = DecisionCard.waitPanelSession(Self.overdueItem(), on: owner, sessions: model.allSessions)

    #expect(resolved?.id == "op")
  }

  @Test func aHeldItemGivesNoPanelSessionWhileNoOperatorIsListed() {
    let owner = groupedSession("k1", group: "g1")

    #expect(DecisionCard.waitPanelSession(Self.overdueItem(), on: owner, sessions: [owner]) == nil)
  }

  /// The owner holds none of the waits, so a panel on the owner would show no row.
  @Test func theOperatorsSessionGivesThePanelItsOverdueWait() throws {
    let model = Self.filteredModel()
    let owner = try #require(model.allSessions.first { $0.id == "k1" })
    let item = Self.overdueItem()
    let resolved = try #require(DecisionCard.waitPanelSession(item, on: owner, sessions: model.allSessions))

    let rows = WaitPanel.rows(
      session: resolved, ids: item.details.overdueWaits, sessions: model.allSessions, reference: { _ in nil },
      now: Self.now)

    #expect(rows.map(\.id) == ["w1"])
  }

  @Test func anotherItemsPanelReadsTheItemsOwnSession() throws {
    var owner = needsItem("a")
    owner.waits = [
      Wait(id: "w1", kind: .ci, created: Self.now - 3 * Self.hour, recheck: Self.now - Self.hour)
    ]
    let model = appliedModel([owner, Self.theOperator()])

    let resolved = DecisionCard.waitPanelSession(
      Self.overdueItem(ref: "rule:CI is still running"), on: owner, sessions: model.allSessions)

    #expect(resolved?.id == "a")
  }
}
