/// The model that a session stores when it is created, and the model that sbd passes with `--model` when it starts
/// claude for the session. Neither rule reads the parent session's model.
public enum SessionModel {
  /// The model that a new session stores. The caller's model wins. Otherwise a work session stores `workModel`. A
  /// Manager conversation, the operator, and a group chat store none and take their model at launch.
  public static func stored(kind: SessionKind, requested: String?, workModel: String) -> String? {
    if let requested { return requested }
    return kind.isConversation ? nil : workModel
  }

  /// The model that sbd passes with `--model`. The operator always runs `operatorModel`, because a model stored on
  /// it came from config.json's `model` when an older sbd created it. For every other kind a stored model wins.
  /// Otherwise a Manager conversation and a group chat run `coordinatorModel`. A work session without a stored model
  /// gets nil. Such a session was created before work sessions stored their model, and it resumes on the model it ran.
  public static func launch(
    kind: SessionKind, stored: String?, coordinatorModel: String, operatorModel: String
  ) -> String? {
    if kind == .operator { return operatorModel }
    if let stored { return stored }
    return kind.isConversation ? coordinatorModel : nil
  }

  /// A model from config.json, or nil when the key is missing or null. A value that `Manager.modelProblem` refuses
  /// logs a line and returns nil, and the setting keeps its default. Throwing would make sbd ignore all of
  /// config.json.
  public static func configModel(_ value: JSON?, key: String) -> String? {
    guard let value, value != .null else { return nil }
    if let model = value.string, Manager.modelProblem(model) == nil { return model }
    logLine("skipping \(key): its value must be a model name, such as sonnet")
    return nil
  }
}
