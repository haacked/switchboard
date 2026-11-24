import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A question about one decision runs a turn in the session. sbd keeps the state, reason, item, and `since` that the
/// session showed when the user asked, so the app fires no banner across that turn, even though the session's
/// activity, reply, and exchanges change.
@MainActor
@Suite struct BoardModelDecisionAsk {
  /// A step of the ask, as the app sees it in sbd's snapshots.
  enum Step: CaseIterable {
    /// The list is open and no question was asked.
    case open
    /// sbd recorded the ask and sent the question.
    case asked
    /// claude reported the question as its prompt.
    case prompted
    /// The clarifying turn's Stop filed the reply under decision 2.
    case stopped
  }

  /// Session "a" at `step` of an ask that holds `state`, with the three decisions under ref `session:5`.
  func snapshot(_ state: AttentionState, _ step: Step) throws -> SessionSummary {
    var s = needsItem("a", state: state)
    s.reason = "read its last reply and decide what's next"
    s.since = 1_000
    s.triage?.ref = "session:5"
    let decisions = [1, 2, 3].map(yesNoDecision)
    s.triage?.decisions = decisions
    s.lastReply = "I planned it. Three decisions need you."
    var exchanges: [DecisionExchange] = []
    switch step {
    case .open:
      s.lastActivity = 1_000
    case .asked:
      s.lastActivity = 1_100
      exchanges = [decisionExchange("ask-1", about: 2, pending: true)]
    case .prompted:
      s.lastActivity = 1_200
      exchanges = [decisionExchange("ask-1", about: 2, pending: true)]
    case .stopped:
      s.lastActivity = 1_300
      s.lastReply = "B would break the public API."
      exchanges = [decisionExchange("ask-1", about: 2, reply: "B would break the public API.", pending: false)]
    }
    s.decisions = DecisionList(decisions: decisions, ref: "session:5", exchanges: exchanges)
    return s
  }

  /// What the session would show during the clarifying turn without the hold: Working, with no item.
  func working() -> SessionSummary {
    var s = needsItem("a", state: .working)
    s.reason = "working (0 min)"
    s.since = 1_200
    s.lastActivity = 1_200
    s.triage = nil
    return s
  }

  /// Applies each snapshot in turn and returns the ids that each one would notify, before the model sees it.
  func notified(_ model: BoardModel, _ snapshots: [SessionSummary]) -> [[String]] {
    snapshots.map { next in
      let ids = model.sessionsToNotify([next]).map(\.id)
      model.apply(.success([next]), followups: nil)
      return ids
    }
  }

  @Test(arguments: [AttentionState.needsYou, .canContinue])
  func noBannerFiresAcrossTheAskThePromptAndTheStop(_ state: AttentionState) throws {
    let model = appliedModel([try snapshot(state, .open)])

    let fired = notified(model, try [Step.asked, .prompted, .stopped].map { try snapshot(state, $0) })

    #expect(fired == [[], [], []])
  }

  /// The control: without the hold, the turn reads Working and its reply's Needs you fires a banner. The sequence
  /// above would fire it too if sbd dropped the hold.
  @Test(arguments: [AttentionState.needsYou, .canContinue])
  func aBannerFiresWhenTheTurnReadsWorkingAndThenNeedsYou(_ state: AttentionState) throws {
    let model = appliedModel([try snapshot(state, .open)])
    var needsYou = try snapshot(.needsYou, .stopped)
    needsYou.since = 1_300

    let fired = notified(model, [working(), needsYou])

    #expect(fired == [[], ["a"]])
  }
}
