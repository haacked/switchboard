/// Claude Code's permission modes, by the names that hook payloads carry.
public enum PermissionMode {
  public static let auto = "auto"
  /// The modes whose permission prompts offer to switch to auto mode: manual and accept edits.
  public static let offeringAutoMode: Set = ["default", "acceptEdits"]

  /// The card's action that allows the call and switches the session to auto mode.
  public static let approveLabel = "Approve and enable auto mode"
  /// What a card tells the user before they approve with auto mode.
  public static let autoModeNote = "auto mode: Claude's classifier decides further permissions"

  /// The mode as Claude Code's status line names it. Its payloads call manual mode `default`.
  public static func title(_ mode: String) -> String {
    switch mode {
    case "default": "manual"
    case "acceptEdits": "accept edits"
    case "bypassPermissions": "bypass permissions"
    case "dontAsk": "don't ask"
    default: mode
    }
  }
}
