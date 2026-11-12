import AppKit
import Combine
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelPlanFollowups {
  @Test func followUpSendsPlanFollowupWithThePlanAndRow() async {
    let sent = await firstRequest { $0.followUp(plan: "p1", row: "2") }

    #expect(sent.op == "plan-followup")
    #expect(sent.args == ["plan": "p1", "row": "2"])
  }

  @Test func ignoresASecondFollowUpWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.followUp(plan: "p1", row: "2")
      model.followUp(plan: "p1", row: "2")
      #expect(model.followingUp == ["p1 2"])
    }
    #expect(sent.count == 1)
  }

  /// The row leaves `canFollowUp` in the same turn that turns its button
  /// back on, before the refresh lists the plan again.
  @Test func aMadeFollowUpDropsItsRowBeforeTheButtonTurnsBackOn() async {
    let model = offlineModel()
    var plan = PlanDocument(id: "p1", source: PlanSource(kind: .file, path: "/tmp/plan.md"), group: "g", attached: 0)
    plan.update(from: "| # | Item | Status |\n| --- | --- | --- |\n| 2 | Docs | Not started |\n", now: 1)
    var group = GroupSummary(SessionGroup(id: "g", name: "G", created: 0), sessions: [])
    group.plans = [PlanSummary(plan)]
    model.groups = [group]
    model.send = { _, _ in .null }
    func rows() -> [PlanRow]? { model.groups.first?.plans?.first?.canFollowUp }

    // `@Published` publishes before it stores the new value, so the sink runs
    // in the turn that turns the button back on.
    var turnedOn: AnyCancellable?
    let rowsWhenTheButtonTurnsOn = await withCheckedContinuation { done in
      turnedOn = model.$followingUp.dropFirst().first(where: \.isEmpty).sink { _ in
        done.resume(returning: MainActor.assumeIsolated { rows() })
      }
      model.followUp(plan: "p1", row: "2")
    }
    turnedOn?.cancel()
    #expect(rowsWhenTheButtonTurnsOn?.isEmpty == true)

    // The refresh that the follow-up started finds no sbd and sets `unreachable`.
    for await problem in model.$unreachable.values where problem != nil { break }
    #expect(rows()?.isEmpty == true)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelProposalAnswers {
  @Test(arguments: [(true, "plan-apply"), (false, "plan-reject")])
  func answerSendsTheOpWithTheProposal(_ apply: Bool, _ op: String) async {
    let sent = await firstRequest { apply ? $0.applyProposal("u1") : $0.rejectProposal("u1") }

    #expect(sent.op == op)
    #expect(sent.args == ["proposal": "u1"])
  }

  @Test func ignoresASecondAnswerWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.applyProposal("u1")
      model.rejectProposal("u1")
      #expect(model.answeringProposals == ["u1"])
    }
    #expect(sent.count == 1)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelArtifactAnswers {
  @Test(arguments: [(true, "plan-artifact-apply"), (false, "plan-artifact-reject")])
  func answerSendsTheOpForApplyOrReject(_ apply: Bool, _ op: String) async {
    let sent = await firstRequest { $0.answerArtifact(plan: "p1", apply: apply) }

    #expect(sent.op == op)
    #expect(sent.args == ["plan": "p1"])
  }

  @Test func ignoresASecondAnswerWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.answerArtifact(plan: "p1", apply: true)
      model.answerArtifact(plan: "p1", apply: false)
      #expect(model.answeringArtifacts == ["p1"])
    }
    #expect(sent.count == 1)
  }

  /// sbd's reply replaces the plan's summary in the same turn that turns the
  /// buttons back on, before the refresh lists the plan again.
  @Test func answerTakesThePlanFromSbdsReply() async throws {
    let model = offlineModel()
    var plan = PlanDocument(
      id: "p1", source: PlanSource(kind: .artifact, url: "https://claude.ai/artifact/a"), group: "g", attached: 0)
    plan.artifact?.copy = "a\n"
    plan.artifact?.proposal = ArtifactProposal(rows: [], base: "a\n", version: nil, text: "b\n", created: 1)
    var group = GroupSummary(SessionGroup(id: "g", name: "G", created: 0), sessions: [])
    group.plans = [PlanSummary(plan)]
    model.groups = [group]
    var answered = plan
    answered.artifact?.proposal = nil
    let reply = try JSONCoding.convert(answered, to: JSON.self)
    model.send = { _, _ in reply }

    // `@Published` publishes before it stores the new value, so the sink runs
    // in the turn that turns the buttons back on.
    var turnedOn: AnyCancellable?
    let proposalGoneWhenTheButtonsTurnOn = await withCheckedContinuation { done in
      turnedOn = model.$answeringArtifacts.dropFirst().first(where: \.isEmpty).sink { _ in
        done.resume(returning: MainActor.assumeIsolated { model.groups.first?.plans?.first?.proposal == nil })
      }
      model.answerArtifact(plan: "p1", apply: false)
    }
    turnedOn?.cancel()
    #expect(proposalGoneWhenTheButtonsTurnOn)
  }
}
