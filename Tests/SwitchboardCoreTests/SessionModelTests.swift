import Testing

@testable import SwitchboardCore

private let coordinators: [SessionKind] = [.manager, .operator, .chat]
private let allKinds: [SessionKind] = [.work] + coordinators

/// The model that a new session stores, and the model that sbd passes with `--model` at each launch. A work
/// session stores config.json's `model`. A Manager conversation, the operator, and a group chat store none. The
/// operator runs `operator.model` at each launch, and the others run `manager.model`.
@Suite struct SessionModelTests {
  // MARK: Stored at creation

  @Test(arguments: allKinds)
  func theCallersModelWinsForEveryKind(_ kind: SessionKind) {
    #expect(SessionModel.stored(kind: kind, requested: "sonnet", workModel: "opus") == "sonnet")
  }

  @Test(arguments: ["opus", "haiku", "claude-opus-5-5", "opus[1m]"])
  func aWorkSessionWithoutACallersModelStoresTheWorkModel(_ workModel: String) {
    #expect(SessionModel.stored(kind: .work, requested: nil, workModel: workModel) == workModel)
  }

  @Test(arguments: coordinators)
  func aCoordinatorWithoutACallersModelStoresNoneEvenWithAWorkModel(_ kind: SessionKind) {
    #expect(SessionModel.stored(kind: kind, requested: nil, workModel: "opus") == nil)
  }

  // MARK: Passed at launch

  @Test(arguments: [SessionKind.work, .manager, .chat])
  func aStoredModelWinsForEveryKindButTheOperator(_ kind: SessionKind) {
    #expect(
      SessionModel.launch(kind: kind, stored: "opus", coordinatorModel: "haiku", operatorModel: "sonnet") == "opus")
  }

  @Test(arguments: [nil, "opus"])
  func theOperatorRunsTheOperatorModelWhateverItStores(_ stored: String?) {
    #expect(
      SessionModel.launch(kind: .operator, stored: stored, coordinatorModel: "opus", operatorModel: "haiku") == "haiku")
  }

  @Test(arguments: [SessionKind.manager, .chat])
  func aConversationWithoutAStoredModelRunsTheCoordinatorModel(_ kind: SessionKind) {
    #expect(SessionModel.launch(kind: kind, stored: nil, coordinatorModel: "haiku", operatorModel: "sonnet") == "haiku")
  }

  /// A work session created before work sessions stored their model, or an imported one, resumes on the model its
  /// transcript was saved on, so sbd passes no `--model`.
  @Test(arguments: ["haiku", "sonnet", "opus"])
  func aWorkSessionWithoutAStoredModelRunsNoModel(_ coordinatorModel: String) {
    #expect(
      SessionModel.launch(kind: .work, stored: nil, coordinatorModel: coordinatorModel, operatorModel: coordinatorModel)
        == nil)
  }
}
