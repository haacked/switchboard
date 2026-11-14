/// What an allow can do besides approving the call. Only a held card's hook
/// can apply an extra. A typed answer can't, because the dialog's item
/// differs per tool and only Bash's was captured.
public enum AllowExtra: String, CaseIterable, Sendable {
  /// Switches the session to auto mode.
  case autoMode
  /// Applies the request's `permission_suggestions`, which can save rules in a settings file.
  case always

  /// The key that asks for the extra in the `answer` op.
  public var argument: String { rawValue }

  /// The `sb allow` switch that asks for the extra.
  public var flag: String {
    switch self {
    case .autoMode: "--auto"
    case .always: "--always"
    }
  }

  /// The card's button that allows the call with the extra.
  public var label: String {
    switch self {
    case .autoMode: PermissionMode.approveLabel
    case .always: "Always allow"
    }
  }

  /// The Inbox option that allows the call with the extra, or nil when `sb choose` doesn't offer it.
  public var triageAction: TriageAction? {
    switch self {
    case .autoMode: .allowAutoMode
    case .always: nil
    }
  }

  /// What sbd can't do once the card's hook closed.
  var hookClosedVerb: String {
    switch self {
    case .autoMode: "switch the mode"
    case .always: "save the always-allow rule"
    }
  }

  /// The extra in the refusal's "Allow it without …" advice.
  public var withoutPhrase: String {
    switch self {
    case .autoMode: "auto mode"
    case .always: "always"
    }
  }
}
