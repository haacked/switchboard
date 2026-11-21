/// config.json's `manager` section, for sessions of kind `manager`.
public struct ManagerSettings: Codable, Equatable, Sendable {
  /// The model that a Manager conversation, the operator, and a group chat run, unless the session has its own.
  public var model = "sonnet"
  /// The auto-compact window, in tokens, that sbd sets as `CLAUDE_CODE_AUTO_COMPACT_WINDOW` when it starts or
  /// resumes a Manager conversation. Claude Code compacts about 33k tokens below the window, so 183000 compacts
  /// near 150k. Claude Code reads a value under 100000 as 100000. With 0, sbd sets nothing and claude uses its own window.
  public var autoCompactWindow = AutoCompact.defaultWindow

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ManagerSettings()
    model = SessionModel.configModel(try c.decodeIfPresent(JSON.self, forKey: .model), key: "manager.model") ?? d.model
    autoCompactWindow = try c.decodeIfPresent(Int.self, forKey: .autoCompactWindow) ?? d.autoCompactWindow
  }
}

/// Claude Code's auto-compact window, which sbd sets for the kinds of session that config.json gives a window.
public enum AutoCompact {
  /// The window that Manager conversations and the operator get unless config.json sets one.
  public static let defaultWindow = 183_000

  /// Sets `CLAUDE_CODE_AUTO_COMPACT_WINDOW` to `window`, in place of a value that config.json's `env` set. A
  /// window of 0 or less leaves the environment as it is.
  public static func apply(window: Int, to env: inout [String: String]) {
    guard window > 0 else { return }
    env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(window)
  }
}

extension Manager {
  /// Why `model` can't be the Manager's model, or nil when it can. claude reads a value that starts with a dash
  /// as an option.
  public static func modelProblem(_ model: String) -> String? {
    if model.isEmpty { return "the model needs a name, such as sonnet" }
    if model.contains(where: \.isWhitespace) { return "the model name can't contain spaces" }
    if model.hasPrefix("-") { return "the model name can't start with a dash" }
    return nil
  }
}
